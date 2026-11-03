import Foundation
import Testing
@testable import RouteCore

/// A pretend watch that follows una-sdk/Docs/BLE-File-Transfer-Service.md,
/// including its contiguous acknowledgements, and can lose packets.
final class FakeWatch: FileServiceLink, @unchecked Sendable {
    let maxPacket = 512
    let inbox = Inbox()

    var files: [String: Data] = [:]
    var directories: Set<String> = ["/Apps", "/Apps/RunRoute"]
    /// Offsets of data chunks to lose once each.
    var dropOnce: Set<Int> = []
    /// Pretend to store this many fewer bytes than were sent.
    var corruptDigest = false
    var neverAck = false
    private(set) var largestPacket = 0

    private var writing: (path: String, total: Int, buffer: Data)?

    func send(_ packet: Data) async throws {
        largestPacket = max(largestPacket, packet.count)
        handle(packet)
    }

    private func path(_ packet: Data, at offset: Int, length: Int) -> String {
        String(decoding: packet.subdata(in: packet.startIndex + offset..<packet.startIndex + offset + length), as: UTF8.self)
    }

    private func reply(_ packet: Packet) {
        inbox.push(packet.data)
    }

    private func handle(_ packet: Data) {
        switch packet[packet.startIndex] {
        case 0x20:
            let path = path(packet, at: 20, length: Int(packet.u16(at: 2)))
            let total = Int(packet.u32(at: 16))
            writing = (path, total, Data())
            files[path] = Data()
            pacing()
        case 0x22:
            let offset = Int(packet.u32(at: 4))
            if dropOnce.remove(offset) != nil { return }
            guard var active = writing else { return }
            if offset == active.buffer.count {
                active.buffer.append(packet.dropFirst(12))
            }
            writing = active
            if !neverAck { pacing() }
            if active.buffer.count == active.total { files[active.path] = active.buffer }
        case 0x30:
            let path = path(packet, at: 4, length: Int(packet.u16(at: 2)))
            let existed = files.removeValue(forKey: path) != nil
            reply(Packet().u8(0x31).u8(existed ? 1 : 3))
        case 0x40:
            directories.insert(path(packet, at: 16, length: Int(packet.u16(at: 2))))
            reply(Packet().u8(0x41).u8(1).u16(0).u32(0).u64(0))
        case 0x50:
            list(path(packet, at: 4, length: Int(packet.u16(at: 2))))
        case 0x60:
            let oldLength = Int(packet.u16(at: 2)), newLength = Int(packet.u16(at: 4))
            let old = path(packet, at: 6, length: oldLength)
            let new = path(packet, at: 7 + oldLength, length: newLength)
            guard let data = files.removeValue(forKey: old), files[new] == nil else {
                reply(Packet().u8(0x61).u8(2))
                return
            }
            files[new] = data
            reply(Packet().u8(0x61).u8(1))
        case 0x70:
            let path = path(packet, at: 4, length: Int(packet.u16(at: 2)))
            guard let data = files[path] else {
                reply(Packet().u8(0x71).u8(3).u16(0).u32(0).u32(0))
                return
            }
            let crc = crc32(data) ^ (corruptDigest ? 1 : 0)
            reply(Packet().u8(0x71).u8(1).u16(0).u32(data.count).u32(Int(crc)))
        default:
            break
        }
    }

    private func pacing() {
        guard let active = writing else { return }
        reply(Packet().u8(0x21).u8(1).u16(0).u32(active.buffer.count).u64(0).u32(active.total - active.buffer.count))
    }

    private func list(_ directory: String) {
        guard directories.contains(directory) else {
            reply(Packet().u8(0x51).u8(3).u16(0).u32(0).u32(0).u32(0).u64(0).u32(0))
            return
        }
        let names = files.keys.filter { ($0 as NSString).deletingLastPathComponent == directory }.sorted()
        for (index, name) in names.enumerated() {
            let raw = Data((name as NSString).lastPathComponent.utf8)
            reply(Packet().u8(0x51).u8(1).u16(raw.count).u32(index).u32(names.count).u32(0).u64(0)
                .u32(files[name]!.count).bytes(raw))
        }
        reply(Packet().u8(0x51).u8(1).u16(0).u32(names.count).u32(names.count).u32(0).u64(0).u32(0))
    }
}

private func makeService(_ watch: FakeWatch) -> FileService {
    FileService(link: watch, replySeconds: 0.5, stallSeconds: 0.05)
}

private func gpxFile(_ body: String, named name: String = "file.gpx") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(body.utf8).write(to: url)
    return url
}

private func route(_ name: String, seed: Double = 0) throws -> RouteFile {
    try RouteFile(gpx: gpxFile("""
    <gpx><metadata><name>\(name)</name></metadata><trk><trkseg>
    <trkpt lat="\(45 + seed)" lon="-122"/><trkpt lat="45.1" lon="-122.1"/>
    </trkseg></trk></gpx>
    """))
}

private func pythonPoints(_ count: Int) -> String {
    (0..<count).map { i in
        "<trkpt lat=\"\(45 + Double(i) * 0.0001)\" lon=\"\(-122 + sin(Double(i) / 3) * 0.001)\"/>"
    }.joined()
}

@Suite struct Crc {
    @Test func matchesTheStandardCheckValue() {
        #expect(crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite struct Gpx {
    @Test func keepsEveryPointAndEncodesLittleEndian() throws {
        let file = try route("Loop")
        #expect(file.name == "Loop")
        #expect(file.keptCount == 2)
        #expect(file.data.prefix(4) == Data("URTE".utf8))
        #expect(file.data.u32(at: 4) == 2)
        #expect(file.data.u32(at: 8) == 450_000_000)
        #expect(file.data.count == 8 + 2 * 8)
    }

    @Test func prefersTrackPointsOverRoutePoints() throws {
        let file = try RouteFile(gpx: gpxFile("""
        <gpx><rte><rtept lat="1" lon="1"/><rtept lat="2" lon="2"/><rtept lat="3" lon="3"/></rte>
        <trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="2" lon="2"/></trkseg></trk></gpx>
        """))
        #expect(file.keptCount == 2)
    }

    @Test func refusesAFileWithoutARoute() throws {
        #expect(throws: RouteFile.Failure.noRoute) {
            try RouteFile(gpx: gpxFile("<gpx><wpt lat=\"1\" lon=\"1\"/></gpx>"))
        }
    }

    @Test func refusesBadXML() throws {
        #expect(throws: RouteFile.Failure.self) {
            try RouteFile(gpx: gpxFile("<gpx><trk>"))
        }
    }

    @Test func cleansNames() {
        let path = URL(fileURLWithPath: "/tmp/fallback.gpx")
        #expect(RouteFile.routeName(gpxName: "  Café / Loop\n#2 ", path: path) == "Caf Loop2")
        #expect(RouteFile.routeName(gpxName: nil, path: path) == "fallback")
        #expect(RouteFile.routeName(gpxName: "///", path: path) == "Route")
        #expect(RouteFile.routeName(gpxName: String(repeating: "a", count: 60), path: path).count == 39)
    }

    /// The app and the command-line tool must make identical route files, or a
    /// route sent one way would look changed to the other.
    @Test(arguments: [
        ("<gpx><metadata><name><![CDATA[Morning Run]]></name></metadata><trk><trkseg>\(pythonPoints(5))</trkseg></trk></gpx>", "a.gpx"),
        ("<gpx xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name> Caf&#233; / #2  Loop </name><trkseg>\(pythonPoints(50))</trkseg></trk></gpx>", "b.gpx"),
        ("<gpx><rte><rtept lat=\"-33.8688197\" lon=\"151.2092955\"/><rtept lat=\"-33.8700001\" lon=\"151.2100005\"/></rte></gpx>", "No Name Here!.gpx"),
        ("<gpx><trk><trkseg>\(pythonPoints(4500))</trkseg></trk></gpx>", "big.gpx"),
    ])
    func matchesThePythonTool(gpx: String, fileName: String) throws {
        let input = try gpxFile(gpx, named: fileName)
        let out = input.deletingLastPathComponent().appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let tool = URL(fileURLWithPath: #filePath)
            .appendingPathComponent("../../../../../tools/gpx2route.py").standardizedFileURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", tool.path, input.path, "--out", out.path]
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let route = try RouteFile(gpx: input)
        let written = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(written == [route.name + ".bin"])
        #expect(try Data(contentsOf: out.appendingPathComponent(route.name + ".bin")) == route.data)
    }

    @Test func thinsAnOversizedRouteToTheLimit() throws {
        let points = (0..<4500).map { i in
            "<trkpt lat=\"\(45 + Double(i) * 0.0001)\" lon=\"\(-122 + sin(Double(i) / 3) * 0.001)\"/>"
        }.joined()
        let file = try RouteFile(gpx: gpxFile("<gpx><trk><trkseg>\(points)</trkseg></trk></gpx>"))
        #expect(file.pointCount == 4500)
        #expect(file.keptCount <= RouteFile.maxPoints)
    }
}

@Suite struct Transfer {
    private func content(_ size: Int) -> Data {
        Data((0..<size).map { UInt8($0 % 251) })
    }

    @Test func writesAFullSizeRoute() async throws {
        let watch = FakeWatch()
        let data = content(32_008)
        try await makeService(watch).write("/x.bin", content: data)
        #expect(watch.files["/x.bin"] == data)
        #expect(watch.largestPacket <= FileService.largestPacket)
    }

    @Test func recoversFromLostChunks() async throws {
        let watch = FakeWatch()
        let chunk = FileService.largestPacket - 12
        watch.dropOnce = [chunk * 3, chunk * 40, chunk * 41]
        let data = content(32_008)
        try await makeService(watch).write("/x.bin", content: data)
        #expect(watch.files["/x.bin"] == data)
        #expect(watch.dropOnce.isEmpty)
    }

    @Test func givesUpWhenTheWatchStopsAcknowledging() async throws {
        let watch = FakeWatch()
        watch.neverAck = true
        await #expect(throws: FileServiceError.self) {
            try await makeService(watch).write("/x.bin", content: content(5000))
        }
    }

    @Test func reportsAMissingFolder() async throws {
        await #expect(throws: FileServiceError.noFile("/nope")) {
            try await makeService(FakeWatch()).list("/nope")
        }
    }

    @Test func timesOutWhenThereIsNoReply() async throws {
        let silent = SilentLink()
        await #expect(throws: FileServiceError.timedOut) {
            try await FileService(link: silent, replySeconds: 0.05).delete("/x")
        }
    }

    @Test func disconnectingFailsTheCommandInProgress() async throws {
        let silent = SilentLink()
        let service = FileService(link: silent, replySeconds: 5)
        let start = Date()
        silent.inbox.close(FileServiceError.disconnected("gone"))
        await #expect(throws: FileServiceError.disconnected("gone")) {
            try await service.delete("/x")
        }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

final class SilentLink: FileServiceLink, @unchecked Sendable {
    let maxPacket = 217
    let inbox = Inbox()
    func send(_ packet: Data) async throws {}
}

@Suite struct Bluetooth {
    private let target = "/Apps/RunRoute/Routes/Loop.bin"

    @Test func createsTheFolderSendsAndLeavesNoTemporaryFile() async throws {
        let watch = FakeWatch()
        let store = BluetoothRouteStore(service: makeService(watch))
        try await store.put(name: "Loop", data: Data([1, 2, 3]), progress: { _ in })
        #expect(watch.directories.contains("/Apps/RunRoute/Routes"))
        #expect(watch.files[target] == Data([1, 2, 3]))
        #expect(watch.files[BluetoothRouteStore.temporary] == nil)
    }

    @Test func replacesAnExistingRoute() async throws {
        let watch = FakeWatch()
        watch.directories.insert("/Apps/RunRoute/Routes")
        watch.files[target] = Data([9])
        let store = BluetoothRouteStore(service: makeService(watch))
        try await store.put(name: "Loop", data: Data([1, 2]), progress: { _ in })
        #expect(watch.files[target] == Data([1, 2]))
    }

    @Test func aFailedCheckKeepsTheOldRoute() async throws {
        let watch = FakeWatch()
        watch.directories.insert("/Apps/RunRoute/Routes")
        watch.files[target] = Data([9])
        watch.corruptDigest = true
        let store = BluetoothRouteStore(service: makeService(watch))
        await #expect(throws: RouteStoreError.checkFailed("Loop")) {
            try await store.put(name: "Loop", data: Data([1, 2]), progress: { _ in })
        }
        #expect(watch.files[target] == Data([9]))
        #expect(watch.files[BluetoothRouteStore.temporary] == nil)
    }

    @Test func listsOnlyRoutes() async throws {
        let watch = FakeWatch()
        watch.directories.insert("/Apps/RunRoute/Routes")
        watch.files[target] = Data([1, 2])
        watch.files["/Apps/RunRoute/Routes/.upload.tmp"] = Data([7])
        watch.files["/Apps/RunRoute/Routes/._Loop.bin"] = Data([7])
        watch.files["/Apps/RunRoute/Routes/notes.txt"] = Data([7])
        let routes = try await BluetoothRouteStore(service: makeService(watch)).routes()
        #expect(routes == [WatchRoute(name: "Loop", size: 2, crc: crc32(Data([1, 2])))])
    }

    @Test func noFolderYetMeansNoRoutes() async throws {
        let routes = try await BluetoothRouteStore(service: makeService(FakeWatch())).routes()
        #expect(routes.isEmpty)
    }

    @Test func noticesWhenTheAppIsntInstalled() async throws {
        let watch = FakeWatch()
        watch.directories = ["/Apps"]
        await #expect(throws: RouteStoreError.appNotInstalled) {
            try await BluetoothRouteStore(service: makeService(watch)).routes()
        }
    }

    @Test func deletingAMissingRouteIsFine() async throws {
        try await BluetoothRouteStore(service: makeService(FakeWatch())).delete(name: "Nope")
    }
}

@Suite struct Usb {
    private func folder() throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }

    @Test func sendsListsAndDeletes() async throws {
        let store = USBRouteStore(app: try folder())
        try await store.put(name: "Loop", data: Data([1, 2]), progress: { _ in })
        let routes = try await store.routes()
        #expect(routes == [WatchRoute(name: "Loop", size: 2, crc: crc32(Data([1, 2])))])
        try await store.delete(name: "Loop")
        let after = try await store.routes()
        #expect(after.isEmpty)
    }

    @Test func removesTheHiddenFilesMacOSLeaves() async throws {
        let apps = try folder()
        let app = apps.appendingPathComponent("RunRoute")
        let routes = app.appendingPathComponent("Routes")
        try FileManager.default.createDirectory(at: routes, withIntermediateDirectories: true)
        let strays = [apps.appendingPathComponent("._RunRoute"), app.appendingPathComponent("._Routes"),
                      routes.appendingPathComponent("._Loop.bin")]
        for stray in strays { try Data([0]).write(to: stray) }

        try await USBRouteStore(app: app).put(name: "Loop", data: Data([1]), progress: { _ in })

        for stray in strays { #expect(!FileManager.default.fileExists(atPath: stray.path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: routes.path) == ["Loop.bin"])
    }

    @Test func noticesWhenTheAppIsntInstalled() async throws {
        let store = USBRouteStore(app: URL(fileURLWithPath: "/no/such/place"))
        await #expect(throws: RouteStoreError.appNotInstalled) {
            _ = try await store.routes()
        }
    }
}

@Suite struct Uploading {
    private func app() throws -> USBRouteStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return USBRouteStore(app: folder)
    }

    private func gpx(_ name: String, seed: Double = 0) throws -> URL {
        try gpxFile("""
        <gpx><metadata><name>\(name)</name></metadata><trk><trkseg>
        <trkpt lat="\(45 + seed)" lon="-122"/><trkpt lat="45.1" lon="-122.1"/>
        </trkseg></trk></gpx>
        """, named: name + ".gpx")
    }

    @Test func readsFilesAndKeepsTheOnesThatFail() throws {
        let bad = try gpxFile("<gpx><trk>", named: "bad.gpx")
        let batch = RouteUploader.read([try gpx("Loop"), bad])
        #expect(batch.routes.map(\.name) == ["Loop"])
        #expect(batch.outcomes.count == 1)
        #expect(batch.outcomes.first?.isFailure == true)
        #expect(batch.outcomes.first?.title == "bad.gpx")
    }

    @Test func sendsThenSkipsThenReplaces() async throws {
        let store = try app()
        let first = RouteUploader.read([try gpx("Loop")])
        let sent = await RouteUploader.send(first.routes, to: store)
        #expect(sent.outcomes == [.sent("Loop", replaced: false)])

        let again = await RouteUploader.send(first.routes, to: store)
        #expect(again.outcomes == [.alreadyOnWatch("Loop")])

        let changed = RouteUploader.read([try gpx("Loop", seed: 1)])
        let replaced = await RouteUploader.send(changed.routes, to: store)
        #expect(replaced.outcomes == [.sent("Loop", replaced: true)])
        let routes = try await store.routes()
        #expect(routes.first?.crc == crc32(changed.routes[0].data))
    }

    @Test func refusesARouteWhenTheWatchIsFull() async throws {
        let store = try app()
        for index in 0..<SyncPlan.capacity {
            try await store.put(name: "R\(index)", data: Data([1]), progress: { _ in })
        }
        let batch = RouteUploader.read([try gpx("New")])
        let result = await RouteUploader.send(batch.routes, to: store)
        #expect(result.outcomes == [.noRoom("New", limit: SyncPlan.capacity)])
        #expect(result.changedWatch == false)
    }

    @Test func reportsTwoFilesWithTheSameName() async throws {
        let batch = RouteUploader.read([try gpx("Loop"), try gpx("LOOP", seed: 1)])
        let result = await RouteUploader.send(batch.routes, to: try app())
        #expect(result.outcomes == [.sent("Loop", replaced: false), .sameName("LOOP", as: "Loop")])
    }

    @Test func reportsAWatchWithoutTheApp() async throws {
        let batch = RouteUploader.read([try gpx("Loop")])
        let store = USBRouteStore(app: URL(fileURLWithPath: "/no/such/place"))
        let result = await RouteUploader.send(batch.routes, to: store)
        #expect(result.outcomes.first?.isFailure == true)
        #expect(result.outcomes.first?.detail == RouteStoreError.appNotInstalled.errorDescription)
    }

    @Test func keepsGoingAfterOneRouteFails() async throws {
        let batch = RouteUploader.read([try gpx("One"), try gpx("Two")])
        let result = await RouteUploader.send(batch.routes, to: FailingStore(failing: "One"))
        #expect(result.outcomes.first?.isFailure == true)
        #expect(result.outcomes.last == .sent("Two", replaced: false))
    }
}

final class FailingStore: RouteStore, @unchecked Sendable {
    struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    let failing: String
    init(failing: String) { self.failing = failing }

    func routes() async throws -> [WatchRoute] { [] }

    func put(name: String, data: Data, progress: (Double) -> Void) async throws {
        if name == failing { throw Boom() }
    }

    func delete(name: String) async throws {}
}

@Suite struct Planning {
    @Test func sortsRoutesIntoActions() throws {
        let same = try route("Same"), changed = try route("Changed"), new = try route("New")
        let plan = SyncPlan(local: [same, changed, new], watch: [
            WatchRoute(name: "same", size: UInt32(same.data.count), crc: crc32(same.data)),
            WatchRoute(name: "Changed", size: 1, crc: 1),
            WatchRoute(name: "Old", size: 1, crc: 1),
        ])
        #expect(plan.items.map(\.action) == [.upToDate, .update, .add])
        #expect(plan.toSend.map(\.name) == ["Changed", "New"])
        #expect(plan.watchOnly.map(\.name) == ["Old"])
    }

    @Test func wontOverfillTheWatchButStillUpdates() throws {
        let existing = (0..<32).map { WatchRoute(name: "R\($0)", size: 1, crc: 1) }
        let plan = SyncPlan(local: [try route("New"), try route("R0")], watch: existing)
        #expect(plan.items.map(\.action) == [.noRoom, .update])
    }

    @Test func fillsTheLastSlotOnly() throws {
        let existing = (0..<31).map { WatchRoute(name: "R\($0)", size: 1, crc: 1) }
        let plan = SyncPlan(local: [try route("A"), try route("B")], watch: existing)
        #expect(plan.items.map(\.action) == [.add, .noRoom])
    }

    @Test func flagsNamesThatDifferOnlyByCase() throws {
        let plan = SyncPlan(local: [try route("Loop"), try route("LOOP", seed: 1)], watch: [])
        #expect(plan.items.map(\.action) == [.add, .sameName("Loop")])
    }
}

private func step(seconds: UInt32 = 600, notes: String = "Zone 2", intensity: UInt8 = 0) -> FitWorkout.Step {
    var result = FitWorkout.Step()
    result.durationType = 0
    result.durationValue = seconds * 1000
    result.targetType = 2
    result.targetValue = 0
    result.intensity = intensity
    result.notes = notes
    return result
}

private func repeatStep(from: UInt32, times: UInt32) -> FitWorkout.Step {
    var result = FitWorkout.Step()
    result.durationType = 6
    result.durationValue = from
    result.targetValue = times
    return result
}

/// RAe1's shape: warm up, three times (run, rest), cool down.
private let sample = FitWorkout(name: "RAe1", steps: [
    step(notes: "Zone 1", intensity: 2), step(), step(seconds: 180, notes: "Zone 1", intensity: 1),
    repeatStep(from: 1, times: 3), step(notes: "Zone 1", intensity: 3),
])

@Suite struct FitFiles {
    @Test func survivesARoundTrip() throws {
        #expect(try FitWorkout(fit: sample.encoded()) == sample)
    }

    @Test func addsUpRepeats() {
        #expect(sample.totalSeconds == 59 * 60)
        let nested = FitWorkout(name: "N", steps: [
            step(seconds: 60), step(seconds: 10), repeatStep(from: 1, times: 2), repeatStep(from: 0, times: 3), step(seconds: 5),
        ])
        #expect(nested.totalSeconds == (60 + 20) * 3 + 5)
    }

    @Test func detectsDamage() throws {
        var bytes = [UInt8](sample.encoded())
        bytes[40] ^= 0xFF
        #expect(throws: FitWorkout.Failure.damaged) { try FitWorkout(fit: Data(bytes)) }
        #expect(throws: FitWorkout.Failure.notFit) { try FitWorkout(fit: Data("not a fit file at all".utf8)) }
    }

    @Test func refusesAnActivityFile() throws {
        var bytes = [UInt8](sample.encoded())
        // The file_id type, just after the header, its definition and record header.
        let at = 14 + 6 + 9 + 1
        #expect(bytes[at] == 5)
        bytes[at] = 4
        let end = bytes.count - 2
        let crc = FitWorkout.crc(bytes[0..<end])
        bytes[end] = UInt8(crc & 0xFF)
        bytes[end + 1] = UInt8(crc >> 8)
        #expect(throws: FitWorkout.Failure.notWorkout) { try FitWorkout(fit: Data(bytes)) }
    }

    @Test func refusesOtherSports() throws {
        var cycling = sample
        cycling.sport = 2
        #expect(throws: FitWorkout.Failure.notRunning) { try FitWorkout(fit: cycling.encoded()) }
    }

    @Test func refusesABadRepeat() throws {
        let forward = FitWorkout(name: "B", steps: [step(), repeatStep(from: 5, times: 2)])
        #expect(throws: FitWorkout.Failure.badStructure) { try FitWorkout(fit: forward.encoded()) }
    }

    @Test func readsBigEndianAndDeveloperAndCompressedRecords() throws {
        // A big-endian definition with a developer field, then a compressed record.
        var body: [UInt8] = [0x40, 0, 0, 0, 0, 1, 0, 1, 0, 0, 5]
        body += [0x61, 0, 1, 0, 27, 3, 254, 2, 0x84, 1, 1, 0, 2, 4, 0x86, 1, 9, 1, 0]
        // Local type 1 again, as a compressed timestamp record: bits 5-6 say 1.
        body += [0xA0, 0, 0, 0, 0x00, 0x01, 0x02, 0x03, 0xEE]
        var file: [UInt8] = [14, 0x10, 0, 0, UInt8(body.count), 0, 0, 0] + Array(".FIT".utf8)
        let headerCrc = FitWorkout.crc(file[0...])
        file += [UInt8(headerCrc & 0xFF), UInt8(headerCrc >> 8)] + body
        let crc = FitWorkout.crc(file[0...])
        file += [UInt8(crc & 0xFF), UInt8(crc >> 8)]

        let workout = try FitWorkout(fit: Data(file))
        #expect(workout.steps.count == 1)
        #expect(workout.steps[0].durationType == 0)
        #expect(workout.steps[0].durationValue == 0x0001_0203)
    }
}

@Suite struct Zones {
    @Test func heartRateBandsFromThreshold() {
        let result = ZoneTargets.apply(.heartRate(thresholdBpm: 160), to: sample)
        let run = result.workout.steps[1]
        #expect(run.targetType == 1)
        #expect(run.targetValue == 0)
        #expect(run.customLow == 130 + 100)   // 81% of 160
        #expect(run.customHigh == 144 + 100)  // 90% of 160
        #expect(result.bands.map(\.zone) == ["Zone 1", "Zone 2"])
        #expect(result.bands[1].text == "130-144 bpm")
    }

    @Test func paceBandsFromThreshold() {
        let result = ZoneTargets.apply(.pace(secondsPerMile: 510), to: sample)
        let run = result.workout.steps[1]
        let threshold = 1_609_344.0 / 510
        #expect(run.targetType == 0)
        #expect(run.customLow == UInt32((threshold * 0.76).rounded()))
        #expect(run.customHigh == UInt32((threshold * 0.87).rounded()))
        #expect(result.bands[1].text == "11:11-9:46 /mi")
    }

    @Test func knowsAllSevenZones() {
        for zone in ["1", "2", "X", "3", "Y", "4", "5"] {
            let workout = FitWorkout(name: "Z", steps: [step(notes: "Zone \(zone)")])
            #expect(ZoneTargets.apply(.pace(secondsPerMile: 510), to: workout).bands.first?.zone == "Zone \(zone)")
        }
    }

    @Test func leavesRepeatsAndRealTargetsAlone() {
        var real = step()
        real.targetType = 1
        real.targetValue = 3
        let workout = FitWorkout(name: "R", steps: [real, repeatStep(from: 0, times: 2)])
        #expect(ZoneTargets.apply(.pace(secondsPerMile: 510), to: workout).workout == workout)
    }

    @Test func heartRateSkipsShortStepsButPaceDoesnt() {
        let workout = FitWorkout(name: "S", steps: [step(seconds: 60, notes: "Zone 5"), step()])
        let heart = ZoneTargets.apply(.heartRate(thresholdBpm: 160), to: workout)
        #expect(heart.tooShort == 1)
        #expect(heart.workout.steps[0].targetType == 2)
        let pace = ZoneTargets.apply(.pace(secondsPerMile: 510), to: workout)
        #expect(pace.tooShort == 0)
        #expect(pace.workout.steps[0].targetType == 0)
    }

    @Test func countsNotesItCantRead() {
        let workout = FitWorkout(name: "U", steps: [step(notes: "Zone 1-2"), step(notes: "Run easy"), step(notes: "")])
        let result = ZoneTargets.apply(.pace(secondsPerMile: 510), to: workout)
        #expect(result.unmatched == 2)
        #expect(result.workout == workout)
    }

    @Test func parsesPace() {
        #expect(ZoneTargets.seconds(fromPace: " 8:30 ") == 510)
        #expect(ZoneTargets.seconds(fromPace: "8:3") == nil)
        #expect(ZoneTargets.seconds(fromPace: "8:75") == nil)
        #expect(ZoneTargets.seconds(fromPace: "fast") == nil)
    }
}

@Suite struct WorkoutFolder {
    private func store() throws -> (USBWorkoutStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (USBWorkoutStore(folder: folder), folder)
    }

    private func files(_ name: String) -> RouteUploader.WorkoutFile {
        var workout = sample
        workout.name = name
        return .init(name: name, data: workout.encoded())
    }

    @Test func sendsSkipsReplaces() throws {
        let (store, _) = try store()
        #expect(RouteUploader.send([files("A")], to: store) == [.sent("A", replaced: false)])
        #expect(RouteUploader.send([files("A")], to: store) == [.alreadyOnWatch("A")])
        var changed = sample
        changed.name = "A"
        changed.steps[0].durationValue = 1000
        #expect(RouteUploader.send([.init(name: "A", data: changed.encoded())], to: store) == [.sent("A", replaced: true)])
        #expect(try store.workouts().count == 1)
    }

    @Test func replacesAnExistingFileWhateverItsCase() throws {
        let (store, folder) = try store()
        try store.put(fileName: "RAe1.FIT", data: Data(files("RAe1").data))
        var changed = sample
        changed.steps[0].durationValue = 1000
        #expect(RouteUploader.send([.init(name: "RAe1", data: changed.encoded())], to: store) == [.sent("RAe1", replaced: true)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["RAe1.FIT"])
    }

    @Test func enforcesTheLimit() throws {
        let (store, _) = try store()
        for index in 0..<USBWorkoutStore.capacity { try store.put(fileName: "W\(index).fit", data: files("W\(index)").data) }
        #expect(RouteUploader.send([files("New")], to: store) == [.noRoom("New", limit: USBWorkoutStore.capacity)])
    }

    @Test func renamingChangesTheNameInsideAndTheFile() throws {
        let (store, folder) = try store()
        try store.put(fileName: "RAe1.fit", data: files("RAe1").data)
        _ = try store.rename(try store.workouts()[0], to: "Tuesday Intervals")
        let workouts = try store.workouts()
        #expect(workouts.map(\.fileName) == ["Tuesday Intervals.fit"])
        #expect(workouts[0].name == "Tuesday Intervals")
        #expect(try FitWorkout(fit: workouts[0].data).steps == sample.steps)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("RAe1.fit").path))
    }

    @Test func deletes() throws {
        let (store, _) = try store()
        try store.put(fileName: "A.fit", data: files("A").data)
        try store.delete(fileName: "A.fit")
        #expect(try store.workouts().isEmpty)
    }
}

private let builtDraft = WorkoutDraft(name: "Hill Session", blocks: [
    .single(.init(kind: .warmup, end: .time(seconds: 600), target: .zone("1"), label: "Easy")),
    .repeated(4, [
        .init(kind: .run, end: .distance(miles: 0.25), target: .pace(slowest: 480, fastest: 450), label: "Strong"),
        .init(kind: .rest, end: .lap),
    ]),
    .single(.init(kind: .run, end: .time(seconds: 300), target: .heartRate(low: 140, high: 155))),
    .single(.init(kind: .cooldown, end: .time(seconds: 300))),
])

@Suite struct Builder {
    @Test func buildsStepsInOrderWithRepeatsInPlace() {
        let steps = builtDraft.built.steps
        #expect(steps.count == 6)
        #expect(steps[0].durationValue == 600_000)
        #expect(steps[0].intensity == 2)
        #expect(steps[0].notes == "Zone 1")
        #expect(steps[0].name == "Easy")
        #expect(steps[1].durationType == 1)
        #expect(steps[1].durationValue == 40_234)  // A quarter mile, in cm.
        #expect(steps[1].notes == "Strong")
        #expect(steps[2].durationType == 5)
        #expect(steps[3].durationType == 6)
        #expect(steps[3].durationValue == 1)
        #expect(steps[3].targetValue == 4)
        #expect(steps[4].customLow == 240)
        #expect(steps[4].customHigh == 255)
    }

    @Test func addsUpTimeAndDistance() {
        let built = builtDraft.built
        #expect(built.totalSeconds == 600 + 300 + 300)
        #expect(abs(built.totalMetres - 1609.36) < 0.1)
    }

    @Test func survivesAFitFile() throws {
        let read = try FitWorkout(fit: builtDraft.built.encoded())
        #expect(read == builtDraft.built)
    }

    @Test func comesBackAsTheSameDraft() throws {
        let read = try FitWorkout(fit: builtDraft.built.encoded())
        let back = try #require(WorkoutDraft(workout: read))
        #expect(back.name == builtDraft.name)
        func shape(_ draft: WorkoutDraft) -> [String] {
            draft.blocks.map { block in
                "\(block.isRepeat) \(block.times) " + block.steps.map {
                    "\($0.kind) \($0.end) \($0.target) \($0.label)"
                }.joined(separator: ",")
            }
        }
        #expect(shape(back) == shape(builtDraft))
    }

    @Test func readsADownloadedShape() throws {
        let draft = try #require(WorkoutDraft(workout: sample))
        #expect(draft.blocks.count == 3)
        #expect(draft.blocks[1].isRepeat)
        #expect(draft.blocks[1].times == 3)
        #expect(draft.blocks[1].steps.map(\.target) == [.zone("2"), .zone("1")])
    }

    @Test func editingAfterEnforcingKeepsZones() throws {
        let enforced = ZoneTargets.apply(.pace(secondsPerMile: 510), to: sample).workout
        let draft = try #require(WorkoutDraft(workout: enforced))
        #expect(draft.blocks[1].steps[0].target == .zone("2"))
    }

    @Test func refusesWhatItCantShow() {
        let nested = FitWorkout(name: "N", steps: [step(), step(), repeatStep(from: 1, times: 2), repeatStep(from: 0, times: 2)])
        #expect(WorkoutDraft(workout: nested) == nil)
        var calories = step()
        calories.durationType = 4
        #expect(WorkoutDraft(workout: FitWorkout(name: "C", steps: [calories])) == nil)
    }

    @Test func findsProblems() {
        #expect(builtDraft.problems.isEmpty)
        #expect(WorkoutDraft.starter().problems.isEmpty)
        var bad = builtDraft
        bad.name = "///"
        bad.blocks[0].steps[0].end = .time(seconds: 0)
        bad.blocks[1].times = 100
        bad.blocks[1].steps[0].target = .pace(slowest: 400, fastest: 450)
        bad.blocks[2].steps[0].target = .heartRate(low: 170, high: 150)
        #expect(bad.problems.count == 5)
        #expect(!WorkoutDraft(name: "Empty", blocks: []).problems.isEmpty)
    }

    @Test func limitsTheStepCount() {
        let steps = (0..<101).map { _ in WorkoutDraft.Block.single(.init(kind: .run, end: .lap)) }
        #expect(!WorkoutDraft(name: "Long", blocks: steps).problems.isEmpty)
    }

    @Test func zoneTargetsApplyToBuiltWorkouts() {
        let applied = ZoneTargets.apply(.pace(secondsPerMile: 510), to: builtDraft.built)
        #expect(applied.workout.steps[0].targetType == 0)
        #expect(applied.bands.map(\.zone) == ["Zone 1"])
        // A pace it was given isn't touched.
        #expect(applied.workout.steps[1].customLow == builtDraft.built.steps[1].customLow)
        #expect(applied.unmatched == 0)
    }

    @Test func showsWhatAZoneComesTo() {
        #expect(ZoneTargets.bandText(zone: "2", metric: .pace(secondsPerMile: 510), settings: RunSettings()) == "11:11-9:46 /mi")
    }

    @Test func keepsTheLibrary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/w.json")
        let library = WorkoutLibrary(file: file)
        #expect(library.load().isEmpty)
        let drafts = [builtDraft, WorkoutDraft.starter()]
        try library.save(drafts)
        #expect(library.load() == drafts)
    }
}

/// Files the app writes, read by UNA's own reader. Needs una-sdk/ and a compiler,
/// so it passes quietly without them. Set ROUTESYNC_FIT_SAMPLES to a folder of FIT
/// workouts to compare each with its converted copy as well.
@Suite(.serialized) struct UnaReader {
    private static let sdk = URL(fileURLWithPath: #filePath)
        .appendingPathComponent("../../../../../../una-sdk").standardizedFileURL
    private static let source = URL(fileURLWithPath: #filePath)
        .appendingPathComponent("../../../Tools/una_reader_check.cpp").standardizedFileURL

    private static let tool: URL? = {
        guard FileManager.default.fileExists(atPath: sdk.path) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("una_reader_check-\(UUID().uuidString)")
        let fit = sdk.appendingPathComponent("Libs/Source/Fit")
        let result = run("/usr/bin/env", ["clang++", "-std=c++17", "-I", sdk.appendingPathComponent("Libs/Header").path,
                                          "-o", out.path, source.path,
                                          fit.appendingPathComponent("FitWorkoutReader.cpp").path,
                                          fit.appendingPathComponent("FitCrc.cpp").path])
        return result.status == 0 ? out : nil
    }()

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func read(_ data: Data) throws -> [String]? {
        guard let tool = Self.tool else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fit")
        try data.write(to: file)
        return Self.run(tool.path, [file.path]).output.split(separator: "\n").map(String.init)
    }

    @Test func acceptsWhatTheAppWrites() throws {
        guard FileManager.default.fileExists(atPath: Self.sdk.path) else { return }
        #expect(Self.tool != nil)
        let pace = ZoneTargets.apply(.pace(secondsPerMile: 510), to: sample).workout
        let lines = try #require(try read(pace.encoded()))
        #expect(lines.first == "ok")
        #expect(lines[1] == "workout|RAe1|1|5|0")
        // A speed target, from 76 to 87 percent of threshold.
        #expect(lines[3].hasSuffix("target|1|2398|2745|0|0|0"))

        let heart = ZoneTargets.apply(.heartRate(thresholdBpm: 160), to: sample).workout
        let heartLines = try #require(try read(heart.encoded()))
        #expect(heartLines.first == "ok")
        // A heart rate target in beats per minute.
        #expect(heartLines[3].hasSuffix("target|2|0|0|1|130|144"))
    }

    @Test func acceptsWhatTheBuilderMakes() throws {
        guard FileManager.default.fileExists(atPath: Self.sdk.path) else { return }
        let applied = ZoneTargets.apply(.pace(secondsPerMile: 510), to: builtDraft.built).workout
        let lines = try #require(try read(applied.encoded()))
        #expect(lines.first == "ok")
        #expect(lines[1] == "workout|Hill Session|1|6|0")
        // Warm up by time, on a Zone 1 pace.
        #expect(lines[2].hasPrefix("step|0|600000|"))
        #expect(lines[2].hasSuffix("target|1|1893|2398|0|0|0"))
        // A quarter mile at 8:00 to 7:30.
        #expect(lines[3].hasPrefix("step|1|0|40234|"))
        #expect(lines[3].contains("|Strong|"))
        #expect(lines[3].hasSuffix("target|1|3353|3576|0|0|0"))
        // Rest until the lap button.
        #expect(lines[4].hasPrefix("step|2|"))
        // The repeat, four times from the second step.
        #expect(lines[5].hasPrefix("step|3|0|0|1|4|"))
        // Heart rate in beats per minute.
        #expect(lines[6].hasSuffix("target|2|0|0|1|140|155"))
    }

    @Test func convertingOnlyChangesTargets() throws {
        guard let folder = ProcessInfo.processInfo.environment["ROUTESYNC_FIT_SAMPLES"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.lowercased().hasSuffix(".fit") }
        #expect(!files.isEmpty)
        func withoutTarget(_ lines: [String]) -> [String] {
            lines.map { $0.components(separatedBy: "target|")[0] }
        }
        for file in files {
            let original = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(file))
            let before = try #require(try read(original))
            #expect(before.first == "ok", "\(file)")
            for metric in [ZoneMetric.pace(secondsPerMile: 510), .heartRate(thresholdBpm: 160)] {
                let workout = try FitWorkout(fit: original)
                let applied = ZoneTargets.apply(metric, to: workout)
                #expect(applied.unmatched == 0, "\(file)")
                let after = try #require(try read(applied.workout.encoded()))
                #expect(after.first == "ok", "\(file)")
                #expect(withoutTarget(after) == withoutTarget(before), "\(file)")
                #expect(!after[1].hasSuffix("|1"), "\(file) came out simplified")
            }
        }
    }
}

@Suite struct Settings {
    private func watchFolder(apps: [String] = ["MyRun", "RunRoute"]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for app in apps {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(app), withIntermediateDirectories: true)
        }
        return folder
    }

    /// Both apps must read the same keys, defaults and limits as this offers.
    @Test(arguments: ["MyRun", "RunRoute"])
    func matchesTheWatchApps(app: String) throws {
        let source = URL(fileURLWithPath: #filePath)
            .appendingPathComponent("../../../../../../\(app)/Software/Libs/Sources/RunConfigLoader.cpp").standardizedFileURL
        let text = try String(contentsOf: source, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"intField\("(\w+)", (-?\d+), (-?\d+), (-?\d+)\)"#)
        let found = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match -> [String] in
            (1...4).map { String(text[Range(match.range(at: $0), in: text)!]) }
        }
        #expect(found.count == RunSettings.watchFields.count)
        for row in found {
            let field = RunSettings.field(row[0])
            #expect(field.defaultValue == Int(row[1]), "\(row[0])")
            #expect(field.range == Int(row[2])!...Int(row[3])!, "\(row[0])")
        }
    }

    @Test func writesOnlyWhatDiffersFromTheDefaults() throws {
        var settings = RunSettings()
        #expect(String(decoding: try settings.appConfigFile(), as: UTF8.self) == #"{"schema":1,"values":{}}"#)
        settings.thresholdPaceSec = 480
        settings.set("routeOffFt", 200)
        settings.set("weightLb", 165)
        #expect(String(decoding: try settings.appConfigFile(), as: UTF8.self)
                == #"{"schema":1,"values":{"routeOffFt":200,"thresholdPaceSec":480}}"#)
    }

    @Test func findsProblems() {
        var settings = RunSettings()
        #expect(settings.problems.isEmpty)
        settings.thresholdPaceSec = 100
        settings.set("routeBackFt", 500)
        settings.set("conditionNormal", 10)
        settings.zones[0].paceHigh = 10
        #expect(settings.problems.count == 4)
    }

    @Test func customZonesAreUsed() {
        var settings = RunSettings()
        settings.zones[1].paceLow = 80
        settings.zones[1].paceHigh = 90
        let run = ZoneTargets.apply(.pace(secondsPerMile: 510), to: sample, settings: settings).workout.steps[1]
        let threshold = 1_609_344.0 / 510
        #expect(run.customLow == UInt32((threshold * 0.80).rounded()))
        #expect(run.customHigh == UInt32((threshold * 0.90).rounded()))
    }

    @Test func shortStepLimitCanChange() {
        var settings = RunSettings()
        settings.shortestHeartRateSeconds = 30
        let workout = FitWorkout(name: "S", steps: [step(seconds: 60, notes: "Zone 5")])
        #expect(ZoneTargets.apply(.heartRate(thresholdBpm: 160), to: workout, settings: settings).tooShort == 0)
    }

    @Test func clearingLetsAWorkoutBeEnforcedAfresh() {
        let first = ZoneTargets.apply(.pace(secondsPerMile: 510), to: sample).workout
        #expect(ZoneTargets.clear(first).steps[1].targetType == 2)
        let again = ZoneTargets.apply(.pace(secondsPerMile: 480), to: ZoneTargets.clear(first)).workout
        #expect(again == ZoneTargets.apply(.pace(secondsPerMile: 480), to: sample).workout)
    }

    @Test func clearingLeavesARealTargetAlone() {
        var real = step(notes: "Hold steady")
        real.targetType = 0
        real.customLow = 3000
        real.customHigh = 3100
        let workout = FitWorkout(name: "R", steps: [real])
        #expect(ZoneTargets.clear(workout) == workout)
    }

    @Test func writesToEveryInstalledAppOnly() throws {
        let folder = try watchFolder(apps: ["RunRoute"])
        let names = try USBSettingsStore(appsFolder: folder).writeSettings(RunSettings())
        #expect(names == ["RunRoute"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("RunRoute/app_config.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("MyRun").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("RunRoute/.upload.tmp").path))
    }

    @Test func readsTheNewestTrainingAndWritesItToBoth() throws {
        let folder = try watchFolder()
        let old = #"{"day":20000,"fitness":1.5,"fatigue":2,"vo2_baseline":50,"saved_utc":100}"#
        let new = #"{"day":20001,"fitness":12,"fatigue":24.5,"vo2_baseline":51,"saved_utc":200}"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("MyRun/training.json"))
        try Data(new.utf8).write(to: folder.appendingPathComponent("RunRoute/training.json"))
        let store = USBSettingsStore(appsFolder: folder)
        var state = try #require(store.training())
        #expect(state.fatigue == 24.5)

        state.fitness = 30
        state.savedUtc = 300
        try store.writeTraining(state)
        for app in USBSettingsStore.apps {
            let data = try Data(contentsOf: folder.appendingPathComponent("\(app)/training.json"))
            #expect(try JSONDecoder().decode(TrainingState.self, from: data).fitness == 30)
            // The watch's reader needs these exact keys, in under 256 bytes.
            let text = String(decoding: data, as: UTF8.self)
            for key in ["day", "fitness", "fatigue", "vo2_baseline", "saved_utc"] { #expect(text.contains("\"\(key)\":")) }
            #expect(data.count < 256)
        }
    }

    @Test func noTrainingFileIsFine() throws {
        #expect(USBSettingsStore(appsFolder: try watchFolder()).training() == nil)
    }

    @Test func countsDaysByLocalDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2 November 2026, 11 pm in Los Angeles, is already the 3rd in UTC.
        let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 23))!
        #expect(TrainingState.dayNumber(late, calendar: calendar) == 20759)
    }
}

@Suite struct AutoOpenAgent {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What launchd would run, with `open` replaced by something that leaves a mark.
    private func run(_ agent: AutoOpen, mark: URL) throws -> Bool {
        let command = agent.command.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        return FileManager.default.fileExists(atPath: mark.path)
    }

    @Test func runsOnEveryMountAndStaysOff() throws {
        let agent = AutoOpen(app: "/Apps/RouteSync.app", agentFile: try folder().appendingPathComponent("a.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: agent.agent(), format: nil) as? [String: Any])
        #expect(plist["StartOnMount"] as? Bool == true)
        #expect(plist["KeepAlive"] == nil)
        #expect(plist["RunAtLoad"] == nil)
        #expect((plist["ProgramArguments"] as? [String])?.last == agent.command)
    }

    @Test func checksForTheWatchAndCopesWithOddPaths() throws {
        let base = try folder()
        let watch = base.appendingPathComponent("UNA WATCH")
        let mark = base.appendingPathComponent("it's open")
        let agent = AutoOpen(app: mark.path, volume: watch.path, agentFile: base.appendingPathComponent("a.plist"))
        // Only meaningful with RouteSync closed: the command also skips an open app.
        #expect(try !run(agent, mark: mark))
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        if !isRouteSyncRunning() { #expect(try run(agent, mark: mark)) }
    }

    private func isRouteSyncRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "RouteSync"]
        process.standardOutput = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
