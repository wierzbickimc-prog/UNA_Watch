import Foundation

/// A workout being built on the Mac: steps, and repeats of steps. Building gives
/// the FitWorkout that gets sent, so it goes through the same zones and checks as
/// a downloaded file.
public struct WorkoutDraft: Codable, Equatable, Identifiable, Sendable {
    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case warmup = "Warm up"
            case run = "Run"
            case rest = "Rest"
            case cooldown = "Cool down"

            var intensity: UInt8 {
                switch self {
                case .run: return 0
                case .rest: return 1
                case .warmup: return 2
                case .cooldown: return 3
                }
            }

            init?(intensity: UInt8) {
                guard let kind = Self.allCases.first(where: { $0.intensity == intensity }) else { return nil }
                self = kind
            }
        }

        public enum End: Codable, Equatable, Sendable {
            case time(seconds: Int)
            case distance(miles: Double)
            /// Runs until you press the lap button.
            case lap
        }

        public enum Target: Codable, Equatable, Sendable {
            case none
            /// An 80/20 zone, turned into a target when it's sent.
            case zone(String)
            /// Seconds per mile: slow is the larger number.
            case pace(slowest: Int, fastest: Int)
            case heartRate(low: Int, high: Int)
        }

        public var id = UUID()
        public var kind: Kind
        public var end: End
        public var target: Target
        /// Shown on the watch during the step.
        public var label = ""

        public init(kind: Kind, end: End, target: Target = .none, label: String = "") {
            self.kind = kind
            self.end = end
            self.target = target
            self.label = label
        }
    }

    /// One step, or steps that repeat.
    public struct Block: Codable, Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var isRepeat: Bool
        public var times: Int
        public var steps: [Step]

        public static func single(_ step: Step) -> Block {
            Block(isRepeat: false, times: 1, steps: [step])
        }

        public static func repeated(_ times: Int, _ steps: [Step]) -> Block {
            Block(isRepeat: true, times: times, steps: steps)
        }
    }

    public var id = UUID()
    public var name: String
    public var blocks: [Block]

    public init(name: String, blocks: [Block]) {
        self.name = name
        self.blocks = blocks
    }

    /// Somewhere to start: warm up, run, cool down, all by feel in easy zones.
    public static func starter(name: String = "New Workout") -> WorkoutDraft {
        WorkoutDraft(name: name, blocks: [
            .single(Step(kind: .warmup, end: .time(seconds: 600), target: .zone("1"))),
            .single(Step(kind: .run, end: .time(seconds: 1200), target: .zone("2"))),
            .single(Step(kind: .cooldown, end: .time(seconds: 600), target: .zone("1"))),
        ])
    }

    /// What needs fixing before this can be sent. Empty when it's fine.
    public var problems: [String] {
        var found: [String] = []
        if RouteFile.cleanName(name) == nil { found.append("Give it a name, using letters or numbers.") }
        if blocks.allSatisfy(\.steps.isEmpty) { found.append("Add at least one step.") }
        let count = blocks.reduce(0) { $0 + $1.steps.count + ($1.isRepeat ? 1 : 0) }
        if count > FitWorkout.maxSteps { found.append("It has \(count) steps, and the watch holds \(FitWorkout.maxSteps).") }
        for block in blocks where block.isRepeat {
            if !(1...Int(FitWorkout.maxRepeatCount)).contains(block.times) {
                found.append("A repeat must run 1 to \(FitWorkout.maxRepeatCount) times.")
            }
            if block.steps.isEmpty { found.append("A repeat needs at least one step.") }
        }
        for step in blocks.flatMap(\.steps) {
            switch step.end {
            case .time(let seconds) where seconds <= 0: found.append("A step's time must be above zero.")
            case .distance(let miles) where miles <= 0: found.append("A step's distance must be above zero.")
            default: break
            }
            switch step.target {
            case .pace(let slowest, let fastest) where fastest <= 0 || slowest <= fastest:
                found.append("A pace target needs its slower pace first, like 10:00 to 9:00.")
            case .heartRate(let low, let high) where low < 30 || high > 255 || low >= high:
                found.append("A heart rate target must go up, within 30 to 255.")
            default: break
            }
        }
        var unique: [String] = []
        for problem in found where !unique.contains(problem) { unique.append(problem) }
        return unique
    }

    /// With repeats expanded, for showing before it's sent.
    public var built: FitWorkout {
        var steps: [FitWorkout.Step] = []
        for block in blocks {
            let start = steps.count
            steps += block.steps.map(Self.fitStep)
            if block.isRepeat {
                var repeatStep = FitWorkout.Step()
                repeatStep.durationType = 6
                repeatStep.durationValue = UInt32(start)
                repeatStep.targetValue = UInt32(max(block.times, 1))
                steps.append(repeatStep)
            }
        }
        return FitWorkout(name: RouteFile.cleanName(name) ?? "Workout", steps: steps)
    }

    private static func fitStep(_ step: Step) -> FitWorkout.Step {
        var fit = FitWorkout.Step()
        fit.intensity = step.kind.intensity
        switch step.end {
        case .time(let seconds):
            fit.durationType = 0
            fit.durationValue = UInt32(seconds) * 1000
        case .distance(let miles):
            fit.durationType = 1
            fit.durationValue = UInt32((miles * 160_934.4).rounded())
        case .lap:
            fit.durationType = 5
        }
        fit.targetValue = 0
        fit.notes = step.label
        switch step.target {
        case .none:
            fit.targetType = 2
        case .zone(let zone):
            // The zone's name must be the notes, so the label goes in the step's name.
            fit.targetType = 2
            fit.notes = "Zone \(zone)"
            fit.name = step.label
        case .pace(let slowest, let fastest):
            fit.targetType = 0
            fit.customLow = UInt32((1_609_344.0 / Double(slowest)).rounded())
            fit.customHigh = UInt32((1_609_344.0 / Double(fastest)).rounded())
        case .heartRate(let low, let high):
            fit.targetType = 1
            fit.customLow = UInt32(low) + 100
            fit.customHigh = UInt32(high) + 100
        }
        return fit
    }

    /// A draft from an existing workout, or nil if it does something the builder
    /// can't show, like a repeat inside a repeat or an end by calories.
    public init?(workout: FitWorkout, fallbackName: String = "Workout") {
        var blocks: [Block] = []
        var pendingIndexes: [Int] = []  // The fit index that each block starts at.
        for (index, fit) in workout.steps.enumerated() {
            if fit.durationType == 6 {
                let from = Int(fit.durationValue)
                guard let first = pendingIndexes.firstIndex(of: from) else { return nil }
                let inner = blocks[first...]
                guard inner.allSatisfy({ !$0.isRepeat }) else { return nil }
                let steps = inner.flatMap(\.steps)
                let times = fit.targetValue == FitWorkout.invalid ? 1 : Int(fit.targetValue)
                blocks.removeSubrange(first...)
                pendingIndexes.removeSubrange(first...)
                blocks.append(.repeated(times, steps))
                pendingIndexes.append(from)
            } else if fit.isRepeat {
                return nil
            } else {
                guard let step = Self.draftStep(fit) else { return nil }
                blocks.append(.single(step))
                pendingIndexes.append(index)
            }
        }
        self.init(name: RouteFile.cleanName(workout.name) ?? fallbackName, blocks: blocks)
    }

    private static func draftStep(_ fit: FitWorkout.Step) -> Step? {
        let end: Step.End
        switch fit.durationType {
        case 0: end = .time(seconds: Int(fit.durationValue / 1000))
        case 1: end = .distance(miles: (Double(fit.durationValue) / 160_934.4 * 100).rounded() / 100)
        case 5: end = .lap
        default: return nil
        }
        // A zone in the notes wins over any target, since this app writes those.
        if let zone = ZoneTargets.zoneName(fromNotes: fit.notes) {
            return Step(kind: Step.Kind(intensity: fit.intensity) ?? .run, end: end, target: .zone(zone), label: fit.name)
        }
        let label = fit.notes.isEmpty ? fit.name : fit.notes
        let kind = Step.Kind(intensity: fit.intensity) ?? .run
        switch fit.targetType {
        case 2, 0xFF:
            return Step(kind: kind, end: end, label: label)
        case 0 where fit.targetValue == 0 || fit.targetValue == FitWorkout.invalid:
            guard fit.customLow != FitWorkout.invalid, fit.customHigh != FitWorkout.invalid,
                  fit.customLow > 0, fit.customHigh > 0 else { return nil }
            return Step(kind: kind, end: end,
                        target: .pace(slowest: Int((1_609_344.0 / Double(fit.customLow)).rounded()),
                                      fastest: Int((1_609_344.0 / Double(fit.customHigh)).rounded())),
                        label: label)
        case 1 where fit.targetValue == 0 || fit.targetValue == FitWorkout.invalid:
            guard fit.customLow != FitWorkout.invalid, fit.customHigh != FitWorkout.invalid,
                  fit.customLow > 100, fit.customHigh > 100 else { return nil }
            return Step(kind: kind, end: end,
                        target: .heartRate(low: Int(fit.customLow) - 100, high: Int(fit.customHigh) - 100), label: label)
        default:
            return nil
        }
    }
}

/// The workouts built so far, kept on the Mac.
public final class WorkoutLibrary: @unchecked Sendable {
    public static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RouteSync/workouts.json")

    private let file: URL

    public init(file: URL = WorkoutLibrary.defaultFile) {
        self.file = file
    }

    public func load() -> [WorkoutDraft] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([WorkoutDraft].self, from: data)) ?? []
    }

    public func save(_ drafts: [WorkoutDraft]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(drafts).write(to: file, options: .atomic)
    }
}
