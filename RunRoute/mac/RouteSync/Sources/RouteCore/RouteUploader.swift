import Foundation

/// Sends the files someone picked, adding or replacing each one.
public enum RouteUploader {
    public enum Outcome: Equatable, Sendable {
        case sent(String, replaced: Bool)
        case alreadyOnWatch(String)
        case noRoom(String, limit: Int)
        case sameName(String, as: String)
        case unreadable(file: String, why: String)
        case failed(String, why: String)
        case updated(String, detail: String)

        public var title: String {
            switch self {
            case .sent(let name, _), .alreadyOnWatch(let name), .noRoom(let name, _), .sameName(let name, _),
                 .failed(let name, _), .updated(let name, _):
                return name
            case .unreadable(let file, _):
                return file
            }
        }

        public var detail: String {
            switch self {
            case .sent(_, let replaced): return replaced ? "Replaced the copy on the watch" : "Added to the watch"
            case .alreadyOnWatch: return "Already on the watch"
            case .noRoom(_, let limit): return "Not sent: the watch already lists its limit of \(limit)"
            case .sameName(_, let other): return "Not sent: it has the same name as \(other)"
            case .unreadable(_, let why), .failed(_, let why): return why
            case .updated(_, let detail): return detail
            }
        }

        public var isFailure: Bool {
            switch self {
            case .sent, .alreadyOnWatch, .updated: return false
            default: return true
            }
        }
    }

    public struct Batch: Sendable {
        public let routes: [RouteFile]
        /// One for each file that couldn't be read.
        public let outcomes: [Outcome]
    }

    public struct Result: Sendable {
        public let outcomes: [Outcome]
        /// Whether anything on the watch changed.
        public var changedWatch: Bool {
            outcomes.contains { if case .sent = $0 { return true } else { return false } }
        }
    }

    /// A named workout, ready to send.
    public struct WorkoutFile: Sendable {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public static func send(_ workouts: [WorkoutFile], to store: USBWorkoutStore) -> [Outcome] {
        let existing: [WatchWorkout]
        do {
            existing = try store.workouts()
        } catch {
            return workouts.map { .failed($0.name, why: error.localizedDescription) }
        }
        var used = existing.count
        var seen: [String: String] = [:]
        return workouts.map { workout in
            let key = workout.name.lowercased()
            if let first = seen[key] { return .sameName(workout.name, as: first) }
            seen[key] = workout.name

            let fileName = workout.name + ".fit"
            let current = existing.first { $0.fileName.lowercased() == key + ".fit" }
            if current?.data == workout.data { return .alreadyOnWatch(workout.name) }
            if current == nil, used >= USBWorkoutStore.capacity {
                return .noRoom(workout.name, limit: USBWorkoutStore.capacity)
            }
            do {
                try store.put(fileName: current?.fileName ?? fileName, data: workout.data)
                if current == nil { used += 1 }
                return .sent(workout.name, replaced: current != nil)
            } catch {
                return .failed(workout.name, why: error.localizedDescription)
            }
        }
    }

    public static func read(_ files: [URL]) -> Batch {
        var routes: [RouteFile] = []
        var outcomes: [Outcome] = []
        for file in files {
            do {
                routes.append(try RouteFile(gpx: file))
            } catch {
                outcomes.append(.unreadable(file: file.lastPathComponent, why: error.localizedDescription))
            }
        }
        return Batch(routes: routes, outcomes: outcomes)
    }

    /// One route failing doesn't stop the others.
    public static func send(_ routes: [RouteFile], to store: RouteStore,
                            onSending: @Sendable (String) -> Void = { _ in }) async -> Result {
        let plan: SyncPlan
        do {
            plan = SyncPlan(local: routes, watch: try await store.routes())
        } catch {
            return Result(outcomes: routes.map { .failed($0.name, why: error.localizedDescription) })
        }

        var outcomes: [Outcome] = []
        for item in plan.items {
            let name = item.route.name
            switch item.action {
            case .upToDate:
                outcomes.append(.alreadyOnWatch(name))
            case .noRoom:
                outcomes.append(.noRoom(name, limit: SyncPlan.capacity))
            case .sameName(let other):
                outcomes.append(.sameName(name, as: other))
            case .add, .update:
                onSending(name)
                do {
                    try await store.put(name: name, data: item.route.data, progress: { _ in })
                    outcomes.append(.sent(name, replaced: item.action == .update))
                } catch {
                    outcomes.append(.failed(name, why: error.localizedDescription))
                }
            }
        }
        return Result(outcomes: outcomes)
    }
}
