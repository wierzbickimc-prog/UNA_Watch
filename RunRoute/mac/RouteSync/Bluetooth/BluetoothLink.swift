import CoreBluetooth
import Foundation
import RouteCore

struct NearbyDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let hasFileService: Bool

    var looksLikeWatch: Bool {
        hasFileService || name.localizedCaseInsensitiveContains("una")
    }
}

enum BluetoothError: LocalizedError {
    case off
    case notAllowed
    case unavailable
    case unknownDevice
    case noFileService
    case timedOut
    case oldFirmware(UInt32)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .off: return "Bluetooth is off. Turn it on, then try again."
        case .notAllowed: return "RouteSync isn't allowed to use Bluetooth. Allow it in System Settings > Privacy & Security > Bluetooth."
        case .unavailable: return "This Mac can't use Bluetooth right now."
        case .unknownDevice: return "That watch isn't nearby. Use Find Watch to look for it again."
        case .noFileService: return "That device doesn't have the watch's file service."
        case .timedOut: return "The watch didn't respond. If it's connected to your phone, try turning off the phone's Bluetooth."
        case .oldFirmware(let version): return "The watch's file service is version \(version), and RouteSync needs 5. Update the watch's firmware."
        case .failed(let why): return why
        }
    }
}

/// The Bluetooth connection to the watch. All its state belongs to `queue`, which
/// is also where CoreBluetooth calls the delegate methods.
final class BluetoothLink: NSObject, FileServiceLink, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private static let service = CBUUID(string: "0000FEBB-0000-1000-8000-00805F9B34FB")
    private static let versionCharacteristic = CBUUID(string: "ADAF0001-4669-6C65-5472-616E73666572")
    private static let transferCharacteristic = CBUUID(string: "ADAF0002-4669-6C65-5472-616E73666572")
    private static let requiredVersion: UInt32 = 5
    /// Long enough to answer the macOS pairing request.
    private static let stepSeconds: TimeInterval = 60

    let inbox = Inbox()
    private(set) var maxPacket = 20

    /// Called on an arbitrary queue.
    var onFound: (@Sendable (NearbyDevice) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "RouteSync.bluetooth")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transfer: CBCharacteristic?
    private var seen: [UUID: CBPeripheral] = [:]
    private var scanning = false
    private var step: (id: Int, resume: CheckedContinuation<Void, Error>)?
    private var nextStep = 0
    private var version: UInt32 = 0
    private var pendingWrite: (packet: Data, resume: CheckedContinuation<Void, Error>)?

    /// Created on first use, because this is what makes macOS ask for permission.
    private func manager() -> CBCentralManager {
        if let central { return central }
        let created = CBCentralManager(delegate: self, queue: queue)
        central = created
        return created
    }

    func startScan() async throws {
        try await waitUntilPoweredOn()
        queue.async { [self] in
            scanning = true
            manager().scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() {
        queue.async { [self] in
            scanning = false
            central?.stopScan()
        }
    }

    func connect(_ id: UUID) async throws {
        try await waitUntilPoweredOn()
        inbox.reopen()
        do {
            try await runStep { [self] in
                let manager = manager()
                guard let target = seen[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first else {
                    throw BluetoothError.unknownDevice
                }
                target.delegate = self
                peripheral = target
                manager.stopScan()
                manager.connect(target)
            }
            try await runStep { [self] in peripheral?.discoverServices([Self.service]) }
            try await runStep { [self] in peripheral?.setNotifyValue(true, for: try transferOrThrow()) }
            try await runStep { [self] in
                guard let readable = peripheral?.services?.first?.characteristics?
                    .first(where: { $0.uuid == Self.versionCharacteristic }) else { throw BluetoothError.noFileService }
                peripheral?.readValue(for: readable)
            }
            let found = queue.sync { version }
            if found < Self.requiredVersion { throw BluetoothError.oldFirmware(found) }
            queue.sync {
                if let peripheral {
                    maxPacket = peripheral.maximumWriteValueLength(for: .withoutResponse)
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        queue.async { [self] in
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    func send(_ packet: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let peripheral, let transfer else {
                    continuation.resume(throwing: FileServiceError.disconnected("The watch isn't connected."))
                    return
                }
                if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(packet, for: transfer, type: .withoutResponse)
                    continuation.resume()
                } else {
                    pendingWrite = (packet, continuation)
                }
            }
        }
    }

    private func transferOrThrow() throws -> CBCharacteristic {
        guard let transfer else { throw BluetoothError.noFileService }
        return transfer
    }

    private func waitUntilPoweredOn() async throws {
        try await runStep { [self] in
            let state = manager().state
            if state == .poweredOn {
                finishStep()
            } else if state != .unknown && state != .resetting {
                throw Self.problem(state)
            }
        }
    }

    private static func problem(_ state: CBManagerState) -> Error {
        switch state {
        case .poweredOff: return BluetoothError.off
        case .unauthorized: return BluetoothError.notAllowed
        default: return BluetoothError.unavailable
        }
    }

    /// Starts one stage of connecting and waits for its delegate callback.
    private func runStep(_ start: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                nextStep += 1
                let id = nextStep
                step = (id, continuation)
                do {
                    try start()
                } catch {
                    finishStep(error)
                    return
                }
                queue.asyncAfter(deadline: .now() + Self.stepSeconds) { [self] in
                    if step?.id == id { finishStep(BluetoothError.timedOut) }
                }
            }
        }
    }

    private func finishStep(_ error: Error? = nil) {
        guard let current = step else { return }
        step = nil
        if let error {
            current.resume.resume(throwing: error)
        } else {
            current.resume.resume()
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanning { central.scanForPeripherals(withServices: nil) }
            if peripheral == nil { finishStep() }
        case .unknown, .resetting:
            break
        default:
            finishStep(Self.problem(central.state))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        seen[peripheral.identifier] = peripheral
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard !name.isEmpty || services.contains(Self.service) else { return }
        onFound?(NearbyDevice(id: peripheral.identifier, name: name.isEmpty ? "Unnamed device" : name,
                              hasFileService: services.contains(Self.service)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        finishStep()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishStep(BluetoothError.failed(error?.localizedDescription ?? "Couldn't connect to the watch."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let gone = FileServiceError.disconnected("The watch disconnected.")
        self.peripheral = nil
        transfer = nil
        inbox.close(gone)
        finishStep(gone)
        if let pending = pendingWrite {
            pendingWrite = nil
            pending.resume.resume(throwing: gone)
        }
        onDisconnect?()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishStep(BluetoothError.failed(error.localizedDescription))
        } else if let service = peripheral.services?.first(where: { $0.uuid == Self.service }) {
            peripheral.discoverCharacteristics([Self.versionCharacteristic, Self.transferCharacteristic], for: service)
        } else {
            finishStep(BluetoothError.noFileService)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            finishStep(BluetoothError.failed(error.localizedDescription))
            return
        }
        transfer = service.characteristics?.first { $0.uuid == Self.transferCharacteristic }
        finishStep(transfer == nil ? BluetoothError.noFileService : nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        finishStep(error.map { BluetoothError.failed($0.localizedDescription) })
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.transferCharacteristic {
            if let value = characteristic.value { inbox.push(value) }
        } else if characteristic.uuid == Self.versionCharacteristic {
            if let error {
                finishStep(BluetoothError.failed(error.localizedDescription))
            } else if let value = characteristic.value, value.count >= 4 {
                version = value.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                finishStep()
            } else {
                finishStep(BluetoothError.failed("The watch sent an unreadable file service version."))
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let pending = pendingWrite, let transfer else { return }
        pendingWrite = nil
        peripheral.writeValue(pending.packet, for: transfer, type: .withoutResponse)
        pending.resume.resume()
    }
}
