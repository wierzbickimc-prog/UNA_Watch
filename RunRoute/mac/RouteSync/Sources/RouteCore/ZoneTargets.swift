import Foundation

/// Turns 80/20 Endurance's zone labels into targets the watch can enforce. Its
/// files only name a zone in each step's notes, and its seven zones are percentages
/// of your own threshold, so they can't use the watch's five heart rate zones.
/// https://www.8020endurance.com/intensity-guidelines-for-80-20-running/
public enum ZoneMetric: Equatable, Sendable {
    /// Threshold heart rate, in beats per minute.
    case heartRate(thresholdBpm: Int)
    /// Threshold pace, in seconds per mile.
    case pace(secondsPerMile: Int)

    public static let bpmRange = 100...220
    public static let secondsPerMileRange = 240...960
}

/// One zone's band, in whole percent of threshold.
public struct ZoneRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String { zone }
    public let zone: String
    public var heartRateLow: Int
    public var heartRateHigh: Int
    public var paceLow: Int
    public var paceHigh: Int
}

public struct AppliedZones: Equatable, Sendable {
    public var workout: FitWorkout
    /// What each zone in the workout came to, in the order first used.
    public var bands: [Band] = []
    /// Steps too short for heart rate to reach a zone, left as labels.
    public var tooShort = 0
    /// Steps whose notes name no zone this understands.
    public var unmatched = 0

    public struct Band: Equatable, Sendable {
        public let zone: String
        public let text: String
    }

    public init(workout: FitWorkout) {
        self.workout = workout
    }
}

public enum ZoneTargets {
    /// Percent of threshold heart rate and of threshold speed. 80/20 gives Zone 5
    /// only as "over" a figure, and a target needs a top, so these are mine.
    public static let standardZones = [
        ZoneRow(zone: "1", heartRateLow: 72, heartRateHigh: 81, paceLow: 60, paceHigh: 76),
        ZoneRow(zone: "2", heartRateLow: 81, heartRateHigh: 90, paceLow: 76, paceHigh: 87),
        ZoneRow(zone: "X", heartRateLow: 90, heartRateHigh: 95, paceLow: 87, paceHigh: 93),
        ZoneRow(zone: "3", heartRateLow: 95, heartRateHigh: 100, paceLow: 93, paceHigh: 100),
        ZoneRow(zone: "Y", heartRateLow: 100, heartRateHigh: 102, paceLow: 100, paceHigh: 102),
        ZoneRow(zone: "4", heartRateLow: 102, heartRateHigh: 105, paceLow: 102, paceHigh: 115),
        ZoneRow(zone: "5", heartRateLow: 105, heartRateHigh: 110, paceLow: 115, paceHigh: 130),
    ]

    /// Heart rate takes minutes to settle, so a target on a shorter step would
    /// only ever say "too low". Pace has no such delay.
    public static let shortestHeartRateSeconds = 120
    public static let shortestHeartRateMetres = 800

    private static let openTarget: UInt8 = 2
    private static let speedTarget: UInt8 = 0
    private static let heartRateTarget: UInt8 = 1
    /// FIT writes a heart rate target in beats per minute as this much plus the value.
    private static let bpmOffset: UInt32 = 100

    private static func row(for notes: String, in zones: [ZoneRow]) -> ZoneRow? {
        let words = notes.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0].caseInsensitiveCompare("zone") == .orderedSame else { return nil }
        return zones.first { $0.zone == words[1].uppercased() }
    }

    /// "Zone 2" as "2", or nil if the notes don't name a zone.
    public static func zoneName(fromNotes notes: String) -> String? {
        row(for: notes, in: standardZones)?.zone
    }

    /// What a zone comes to, like "11:11-9:46 /mi".
    public static func bandText(zone: String, metric: ZoneMetric, settings: RunSettings) -> String? {
        var step = FitWorkout.Step()
        step.durationType = 0
        step.durationValue = 3_600_000
        step.targetType = openTarget
        step.notes = "Zone \(zone)"
        return apply(metric, to: FitWorkout(name: "", steps: [step]), settings: settings).bands.first?.text
    }

    /// Whether any step names a zone, so needs a threshold to be enforced.
    public static func usesZones(_ workout: FitWorkout) -> Bool {
        workout.steps.contains { row(for: $0.notes, in: standardZones) != nil }
    }

    /// Takes off targets this wrote, so a workout can be enforced afresh after a
    /// threshold changes. A target with no zone named in its notes stays.
    public static func clear(_ workout: FitWorkout) -> FitWorkout {
        var result = workout
        for index in result.steps.indices {
            let step = result.steps[index]
            guard !step.isRepeat, step.targetType == speedTarget || step.targetType == heartRateTarget,
                  step.targetValue == 0, row(for: step.notes, in: standardZones) != nil else { continue }
            result.steps[index].targetType = openTarget
            result.steps[index].customLow = FitWorkout.invalid
            result.steps[index].customHigh = FitWorkout.invalid
        }
        return result
    }

    public static func apply(_ metric: ZoneMetric, to workout: FitWorkout, settings: RunSettings = RunSettings()) -> AppliedZones {
        var result = AppliedZones(workout: workout)
        for index in workout.steps.indices {
            var step = workout.steps[index]
            // Never override a target the file really sets.
            guard !step.isRepeat, step.targetType == openTarget || step.targetType == 0xFF,
                  !step.notes.isEmpty else { continue }
            guard let row = row(for: step.notes, in: settings.zones) else {
                result.unmatched += 1
                continue
            }

            let label: String
            switch metric {
            case .heartRate(let threshold):
                if isTooShortForHeartRate(step, settings) {
                    result.tooShort += 1
                    continue
                }
                let low = UInt32((Double(row.heartRateLow) * Double(threshold) / 100).rounded())
                let high = UInt32((Double(row.heartRateHigh) * Double(threshold) / 100).rounded())
                step.targetType = heartRateTarget
                step.customLow = low + bpmOffset
                step.customHigh = high + bpmOffset
                label = "\(low)-\(high) bpm"
            case .pace(let seconds):
                let thresholdMmps = 1_609_344.0 / Double(seconds)
                step.targetType = speedTarget
                step.customLow = UInt32((Double(row.paceLow) * thresholdMmps / 100).rounded())
                step.customHigh = UInt32((Double(row.paceHigh) * thresholdMmps / 100).rounded())
                label = "\(paceText(Double(seconds) * 100 / Double(row.paceLow)))-\(paceText(Double(seconds) * 100 / Double(row.paceHigh))) /mi"
            }
            step.targetValue = 0
            result.workout.steps[index] = step
            let name = "Zone \(row.zone)"
            if !result.bands.contains(where: { $0.zone == name }) {
                result.bands.append(.init(zone: name, text: label))
            }
        }
        return result
    }

    private static func isTooShortForHeartRate(_ step: FitWorkout.Step, _ settings: RunSettings) -> Bool {
        switch step.durationType {
        case 0: return Int(step.durationValue / 1000) < settings.shortestHeartRateSeconds
        case 1: return Int(step.durationValue / 100) < settings.shortestHeartRateMetres
        default: return false
        }
    }

    public static func paceText(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "8:30" as seconds, or nil if it isn't a pace.
    public static func seconds(fromPace text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              parts[1].count == 2, minutes >= 0, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }
}
