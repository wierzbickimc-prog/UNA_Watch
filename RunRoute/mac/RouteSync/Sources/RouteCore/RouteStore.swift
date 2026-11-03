import Foundation

public struct WatchRoute: Equatable, Sendable {
    public let name: String
    public let size: UInt32
    public let crc: UInt32

    public init(name: String, size: UInt32, crc: UInt32) {
        self.name = name
        self.size = size
        self.crc = crc
    }
}

public enum RouteStoreError: LocalizedError, Equatable {
    case appNotInstalled
    case checkFailed(String)
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .appNotInstalled: return "RunRoute isn't installed on the watch."
        case .checkFailed(let name): return "\(name) arrived damaged, so the watch's copy wasn't changed."
        case .nameTaken(let name): return "The watch already has something called \(name)."
        }
    }
}

/// The routes on the watch. Either way of reaching it replaces a route only once
/// the new copy is complete, because a partial route would still appear in the
/// watch's list. RunRoute ignores the temporary file: it doesn't end in ".bin".
public protocol RouteStore: AnyObject, Sendable {
    func routes() async throws -> [WatchRoute]
    func put(name: String, data: Data, progress: (Double) -> Void) async throws
    func delete(name: String) async throws
}

public final class BluetoothRouteStore: RouteStore, @unchecked Sendable {
    static let app = "/Apps/RunRoute"
    static let folder = "/Apps/RunRoute/Routes"
    static let temporary = "/Apps/RunRoute/Routes/.upload.tmp"

    private let service: FileService

    public init(service: FileService) {
        self.service = service
    }

    public func routes() async throws -> [WatchRoute] {
        let entries: [FileService.Entry]
        do {
            entries = try await service.list(Self.folder)
        } catch FileServiceError.noFile {
            do {
                _ = try await service.list(Self.app)
            } catch FileServiceError.noFile {
                throw RouteStoreError.appNotInstalled
            }
            return []
        }
        var routes: [WatchRoute] = []
        for entry in entries where !entry.isDirectory && !entry.name.hasPrefix(".") && entry.name.hasSuffix(".bin") {
            let digest = try await service.digest("\(Self.folder)/\(entry.name)")
            routes.append(WatchRoute(name: String(entry.name.dropLast(4)), size: digest.size, crc: digest.crc))
        }
        return routes
    }

    public func put(name: String, data: Data, progress: (Double) -> Void) async throws {
        do {
            _ = try await service.list(Self.folder)
        } catch FileServiceError.noFile {
            try await service.makeDirectory(Self.folder)
        }
        try await service.write(Self.temporary, content: data, progress: progress)

        let digest = try await service.digest(Self.temporary)
        guard digest.size == data.count, digest.crc == crc32(data) else {
            try? await service.delete(Self.temporary)
            throw RouteStoreError.checkFailed(name)
        }

        try await delete(name: name)
        try await service.move(Self.temporary, to: "\(Self.folder)/\(name).bin")
    }

    public func delete(name: String) async throws {
        do {
            try await service.delete("\(Self.folder)/\(name).bin")
        } catch FileServiceError.noFile {
        }
    }
}

/// The watch plugged in over USB, where it mounts as a drive.
public final class USBRouteStore: RouteStore, @unchecked Sendable {
    public static let defaultApp = URL(fileURLWithPath: "/Volumes/UNA WATCH/Apps/RunRoute")

    private let app: URL
    private var folder: URL { app.appendingPathComponent("Routes") }

    public init(app: URL = USBRouteStore.defaultApp) {
        self.app = app
    }

    public static let volume = URL(fileURLWithPath: "/Volumes/UNA WATCH")

    public static var isMounted: Bool {
        FileManager.default.fileExists(atPath: volume.path)
    }

    public func routes() async throws -> [WatchRoute] {
        guard FileManager.default.fileExists(atPath: app.path) else { throw RouteStoreError.appNotInstalled }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return try names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".bin") }.map { file in
            let data = try Data(contentsOf: folder.appendingPathComponent(file))
            return WatchRoute(name: String(file.dropLast(4)), size: UInt32(data.count), crc: crc32(data))
        }
    }

    public func put(name: String, data: Data, progress: (Double) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: app.path) else { throw RouteStoreError.appNotInstalled }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".upload.tmp")
        let target = folder.appendingPathComponent(name + ".bin")
        try data.write(to: temporary)
        guard try Data(contentsOf: temporary) == data else {
            try? FileManager.default.removeItem(at: temporary)
            throw RouteStoreError.checkFailed(name)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        removeStrays(name: name)
        progress(1)
    }

    public func delete(name: String) async throws {
        let target = folder.appendingPathComponent(name + ".bin")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        removeStrays(name: name)
    }

    /// RunRoute forgets a selected route that's renamed, as if it had been deleted.
    public func rename(name: String, to newName: String) throws {
        let old = folder.appendingPathComponent(name + ".bin")
        let new = folder.appendingPathComponent(newName + ".bin")
        if FileManager.default.fileExists(atPath: new.path), name.caseInsensitiveCompare(newName) != .orderedSame {
            throw RouteStoreError.nameTaken(newName)
        }
        try FileManager.default.moveItem(at: old, to: new)
        removeStrays(name: newName)
    }

    /// macOS can leave these beside new files on the watch's drive.
    private func removeStrays(name: String) {
        for stray in [folder.appendingPathComponent("._\(name).bin"), folder.appendingPathComponent("._.upload.tmp"),
                      app.appendingPathComponent("._Routes"),
                      app.deletingLastPathComponent().appendingPathComponent("._\(app.lastPathComponent)")] {
            try? FileManager.default.removeItem(at: stray)
        }
    }
}
