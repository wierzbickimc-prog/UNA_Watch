import Foundation

public struct WatchWorkout: Equatable, Sendable, Identifiable {
    public var id: String { fileName }
    public let fileName: String
    public let name: String
    public let data: Data
}

/// The workouts on the watch, in the folder at the top of its USB drive that all
/// its apps read and none can change. So this is the only way to remove one.
public final class USBWorkoutStore: @unchecked Sendable {
    /// SDK::Workout::Library::kMaxEntries.
    public static let capacity = 64
    public static let defaultFolder = USBRouteStore.volume.appendingPathComponent("Workouts")

    private let folder: URL

    public init(folder: URL = USBWorkoutStore.defaultFolder) {
        self.folder = folder
    }

    public func workouts() throws -> [WatchWorkout] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return try names.filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".fit") }.sorted().map { file in
            let data = try Data(contentsOf: folder.appendingPathComponent(file))
            let name = (try? FitWorkout(fit: data).name).flatMap { $0.isEmpty ? nil : $0 } ?? String(file.dropLast(4))
            return WatchWorkout(fileName: file, name: name, data: data)
        }
    }

    /// The new copy is complete and checked before it replaces any old one.
    public func put(fileName: String, data: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".upload.tmp")
        try data.write(to: temporary)
        guard try Data(contentsOf: temporary) == data else {
            try? FileManager.default.removeItem(at: temporary)
            throw RouteStoreError.checkFailed(fileName)
        }
        try delete(fileName: fileName)
        try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(fileName))
        removeStrays(fileName)
    }

    public func delete(fileName: String) throws {
        let target = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        removeStrays(fileName)
    }

    /// The name is inside the file, and the watch lists by that.
    public func rename(_ workout: WatchWorkout, to name: String) throws -> String {
        var edited = try FitWorkout(fit: workout.data)
        edited.name = name
        let fileName = name + ".fit"
        try put(fileName: fileName, data: edited.encoded())
        if fileName.caseInsensitiveCompare(workout.fileName) != .orderedSame {
            try delete(fileName: workout.fileName)
        }
        return fileName
    }

    private func removeStrays(_ fileName: String) {
        for stray in [folder.appendingPathComponent("._\(fileName)"), folder.appendingPathComponent("._.upload.tmp"),
                      folder.deletingLastPathComponent().appendingPathComponent("._\(folder.lastPathComponent)")] {
            try? FileManager.default.removeItem(at: stray)
        }
    }
}
