import Foundation

/// Standard CRC-32, the same as the watch's DIGEST and Python's zlib.crc32.
public func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
        }
    }
    return ~crc
}

public enum FileServiceError: LocalizedError, Equatable {
    case noFile(String)
    case failed(String)
    case timedOut
    case stalled(Int)
    case disconnected(String)

    public var errorDescription: String? {
        switch self {
        case .noFile(let path): return "Not found on the watch: \(path)"
        case .failed(let what): return "The watch refused: \(what)"
        case .timedOut: return "The watch stopped replying."
        case .stalled(let byte): return "The watch stopped acknowledging at byte \(byte)."
        case .disconnected(let why): return why
        }
    }
}

/// Replies from the watch, in the order they arrived. Filled from Bluetooth's own
/// queue, so it must not hop through a Task, which wouldn't keep them in order.
public final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var waiter: (id: Int, resume: CheckedContinuation<Data, Error>)?
    private var nextWaiter = 0
    private var closed: Error?

    public init() {}

    public func push(_ packet: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let waiting = waiter {
            waiter = nil
            waiting.resume.resume(returning: packet)
        } else {
            queue.append(packet)
        }
    }

    /// Fails the current and all later reads, as when the watch disconnects.
    public func close(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        closed = error
        if let waiting = waiter {
            waiter = nil
            waiting.resume.resume(throwing: error)
        }
    }

    public func reopen() {
        lock.lock()
        defer { lock.unlock() }
        closed = nil
        queue.removeAll()
    }

    func next(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if !queue.isEmpty {
                continuation.resume(returning: queue.removeFirst())
            } else if let closed {
                continuation.resume(throwing: closed)
            } else {
                nextWaiter += 1
                let id = nextWaiter
                waiter = (id, continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.expire(id)
                }
            }
        }
    }

    private func expire(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let waiting = waiter, waiting.id == id {
            waiter = nil
            waiting.resume.resume(throwing: FileServiceError.timedOut)
        }
    }
}

/// What the file service needs from a connection to the watch.
public protocol FileServiceLink: AnyObject, Sendable {
    /// The largest packet that fits in one write.
    var maxPacket: Int { get }
    var inbox: Inbox { get }
    func send(_ packet: Data) async throws
}

/// The watch's Bluetooth file service. The protocol is in
/// una-sdk/Docs/BLE-File-Transfer-Service.md. Run one command at a time.
public final class FileService: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let size: UInt32
    }

    static let ok: UInt8 = 0x01
    static let noFile: UInt8 = 0x03
    /// The size the protocol document recommends.
    static let writeWindow = 2048
    /// MTU 220 minus 3, the size the protocol document is written around.
    static let largestPacket = 217
    static let maxStalls = 8

    private let link: FileServiceLink
    private let replySeconds: TimeInterval
    private let stallSeconds: TimeInterval

    public init(link: FileServiceLink, replySeconds: TimeInterval = 10, stallSeconds: TimeInterval = 2) {
        self.link = link
        self.replySeconds = replySeconds
        self.stallSeconds = stallSeconds
    }

    public func list(_ path: String) async throws -> [Entry] {
        let raw = Data(path.utf8)
        try await link.send(Packet().u8(0x50).u8(0).u16(raw.count).bytes(raw).data)
        var entries: [Entry] = []
        while true {
            let reply = try await reply(to: 0x51)
            try check(reply, path)
            guard reply.count >= 28 else { throw FileServiceError.failed("malformed listing of \(path)") }
            let length = Int(reply.u16(at: 2))
            let number = reply.u32(at: 4)
            let total = reply.u32(at: 8)
            if number == total && length == 0 { return entries }
            guard reply.count >= 28 + length else { throw FileServiceError.failed("malformed listing of \(path)") }
            let name = String(decoding: reply.subdata(in: reply.startIndex + 28..<reply.startIndex + 28 + length), as: UTF8.self)
            entries.append(Entry(name: name, isDirectory: reply.u32(at: 12) & 1 != 0, size: reply.u32(at: 24)))
        }
    }

    public func makeDirectory(_ path: String) async throws {
        let raw = Data(path.utf8)
        try await link.send(Packet().u8(0x40).u8(0).u16(raw.count).u32(0).u64(Self.nowNanos()).bytes(raw).data)
        try check(try await reply(to: 0x41), path)
    }

    public func delete(_ path: String) async throws {
        let raw = Data(path.utf8)
        try await link.send(Packet().u8(0x30).u8(0).u16(raw.count).bytes(raw).data)
        try check(try await reply(to: 0x31), path)
    }

    public func move(_ old: String, to new: String) async throws {
        let a = Data(old.utf8), b = Data(new.utf8)
        try await link.send(Packet().u8(0x60).u8(0).u16(a.count).u16(b.count).bytes(a).u8(0).bytes(b).data)
        try check(try await reply(to: 0x61), new)
    }

    public func digest(_ path: String) async throws -> (size: UInt32, crc: UInt32) {
        let raw = Data(path.utf8)
        try await link.send(Packet().u8(0x70).u8(0).u16(raw.count).bytes(raw).data)
        let reply = try await reply(to: 0x71)
        try check(reply, path)
        guard reply.count >= 12 else { throw FileServiceError.failed("malformed digest of \(path)") }
        return (reply.u32(at: 4), reply.u32(at: 8))
    }

    /// Streams the file within a credit window, and when acknowledgements stall
    /// resends from the last byte the watch holds without a gap.
    public func write(_ path: String, content: Data, progress: (Double) -> Void = { _ in }) async throws {
        let raw = Data(path.utf8)
        let total = content.count
        try await link.send(Packet().u8(0x20).u8(0).u16(raw.count).u32(0).u64(Self.nowNanos()).u32(total).bytes(raw).data)
        var free = try parsePacing(try await reply(to: 0x21), path)

        let chunk = min(link.maxPacket, Self.largestPacket) - 12
        var sent = 0
        var stalls = 0
        while free != 0 {
            let acked = total - free
            progress(Double(acked) / Double(max(total, 1)))
            while sent < total && sent - acked < Self.writeWindow {
                let end = min(sent + chunk, total)
                let part = content.subdata(in: content.startIndex + sent..<content.startIndex + end)
                try await link.send(Packet().u8(0x22).u8(Self.ok).u16(0).u32(sent).u32(part.count).bytes(part).data)
                sent = end
            }
            do {
                let newer = try parsePacing(try await reply(to: 0x21, timeout: stallSeconds), path)
                if newer < free { stalls = 0 }
                free = min(free, newer)
            } catch FileServiceError.timedOut {
                stalls += 1
                if stalls > Self.maxStalls { throw FileServiceError.stalled(acked) }
                sent = acked
            }
        }
        progress(1)
    }

    /// The next reply to this command. Leftover acknowledgements from an earlier
    /// command are dropped.
    private func reply(to command: UInt8, timeout: TimeInterval? = nil) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout ?? replySeconds)
        while true {
            let packet = try await link.inbox.next(timeout: max(deadline.timeIntervalSinceNow, 0.001))
            if packet.first == command { return packet }
        }
    }

    private func check(_ reply: Data, _ what: String) throws {
        guard reply.count >= 2 else { throw FileServiceError.failed("malformed reply about \(what)") }
        switch reply[reply.startIndex + 1] {
        case Self.ok: return
        case Self.noFile: throw FileServiceError.noFile(what)
        case let status: throw FileServiceError.failed("\(what) (status \(status))")
        }
    }

    private func parsePacing(_ reply: Data, _ what: String) throws -> Int {
        try check(reply, what)
        guard reply.count >= 20 else { throw FileServiceError.failed("malformed acknowledgement of \(what)") }
        return Int(reply.u32(at: 16))
    }

    private static func nowNanos() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1e9)
    }
}

struct Packet {
    var data = Data()

    func u8(_ value: UInt8) -> Packet { adding(value) }
    func u16(_ value: Int) -> Packet { adding(UInt16(value)) }
    func u32(_ value: Int) -> Packet { adding(UInt32(value)) }
    func u64(_ value: UInt64) -> Packet { adding(value) }

    func bytes(_ more: Data) -> Packet {
        var copy = self
        copy.data.append(more)
        return copy
    }

    private func adding<T: FixedWidthInteger>(_ value: T) -> Packet {
        var copy = self
        withUnsafeBytes(of: value.littleEndian) { copy.data.append(contentsOf: $0) }
        return copy
    }
}

extension Data {
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}
