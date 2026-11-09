import Foundation

/// Everything RouteSync lets you set. The watch's own settings go to app_config.json
/// in each app's folder, read when the app starts. The rest shapes the workouts sent.
public struct RunSettings: Codable, Equatable, Sendable {
    /// A number on the watch: its key in app_config.json, default and limits. These
    /// must match RunConfigLoader.cpp in MyRun and RunRoute. The tests compare them.
    public struct WatchField: Sendable {
        public let id: String
        public let title: String
        public let unit: String
        public let defaultValue: Int
        public let range: ClosedRange<Int>
    }

    public static let watchFields = [
        WatchField(id: "thresholdPaceSec", title: "Threshold pace", unit: "s/mi", defaultValue: 510, range: 240...960),
        WatchField(id: "weightLb", title: "Weight", unit: "lb", defaultValue: 165, range: 60...400),
        WatchField(id: "maxHr", title: "Max heart rate", unit: "bpm", defaultValue: 197, range: 120...230),
        WatchField(id: "vo2BaselinePct", title: "Baseline moves per run", unit: "%", defaultValue: 20, range: 0...100),
        WatchField(id: "conditionFresh", title: "Fresh from", unit: "", defaultValue: 3, range: -20...20),
        WatchField(id: "conditionNormal", title: "Normal from", unit: "", defaultValue: -2, range: -20...20),
        WatchField(id: "conditionTired", title: "Tired from", unit: "", defaultValue: -7, range: -20...20),
        WatchField(id: "zoneQuietSec", title: "Quiet start of each step", unit: "s", defaultValue: 20, range: 0...300),
        WatchField(id: "zoneRepeatSec", title: "Repeat alert every", unit: "s", defaultValue: 30, range: 5...600),
        WatchField(id: "routeOffFt", title: "Off course beyond", unit: "ft", defaultValue: 150, range: 30...1000),
        WatchField(id: "routeBackFt", title: "Back on within", unit: "ft", defaultValue: 100, range: 10...1000),
        WatchField(id: "routeDelaySec", title: "Wait before alarm", unit: "s", defaultValue: 10, range: 0...120),
        WatchField(id: "routeRepeatSec", title: "Repeat alarm every", unit: "s", defaultValue: 60, range: 10...600),
        WatchField(id: "routeFinishFt", title: "Finished within", unit: "ft", defaultValue: 66, range: 10...500),
    ]

    /// Keyed by WatchField.id. A missing key means its default.
    public var watch: [String: Int] = [:]
    public var zones = ZoneTargets.standardZones
    public var thresholdBpm: Int?
    public var shortestHeartRateSeconds = ZoneTargets.shortestHeartRateSeconds
    public var shortestHeartRateMetres = ZoneTargets.shortestHeartRateMetres

    public init() {}

    public static func field(_ id: String) -> WatchField {
        watchFields.first { $0.id == id }!
    }

    public func value(_ id: String) -> Int {
        watch[id] ?? Self.field(id).defaultValue
    }

    public mutating func set(_ id: String, _ value: Int) {
        watch[id] = value
    }

    public var thresholdPaceSec: Int {
        get { value("thresholdPaceSec") }
        set { set("thresholdPaceSec", newValue) }
    }

    /// What needs fixing before these can be used. Empty when they're fine.
    public var problems: [String] {
        var found: [String] = []
        for field in Self.watchFields where !field.range.contains(value(field.id)) {
            found.append("\(field.title) must be \(field.range.lowerBound) to \(field.range.upperBound).")
        }
        if value("conditionFresh") <= value("conditionNormal") || value("conditionNormal") <= value("conditionTired") {
            found.append("Condition labels must go down in order: Fresh, Normal, Tired.")
        }
        if value("routeBackFt") >= value("routeOffFt") {
            found.append("Back on must be closer than off course.")
        }
        if let bpm = thresholdBpm, !ZoneMetric.bpmRange.contains(bpm) {
            found.append("Threshold heart rate must be \(ZoneMetric.bpmRange.lowerBound) to \(ZoneMetric.bpmRange.upperBound).")
        }
        for zone in zones where zone.heartRateLow >= zone.heartRateHigh || zone.paceLow >= zone.paceHigh {
            found.append("Zone \(zone.zone) needs its top above its bottom.")
        }
        return found
    }

    /// The contents of app_config.json. Only values that differ from the default
    /// are written, so a default the watch app changes later still reaches it.
    public func appConfigFile() throws -> Data {
        var values: [String: Int] = [:]
        for field in Self.watchFields where value(field.id) != field.defaultValue {
            values[field.id] = value(field.id)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(AppConfigFile(schema: 1, values: values))
    }

    private struct AppConfigFile: Codable {
        let schema: Int
        let values: [String: Int]
    }
}

/// Fitness, fatigue and the usual VO2max, as the watch keeps them in training.json.
public struct TrainingState: Codable, Equatable, Sendable {
    public var day: Int
    public var fitness: Double
    public var fatigue: Double
    public var vo2Baseline: Double
    public var savedUtc: Int

    enum CodingKeys: String, CodingKey {
        case day, fitness, fatigue
        case vo2Baseline = "vo2_baseline"
        case savedUtc = "saved_utc"
    }

    public init(day: Int, fitness: Double, fatigue: Double, vo2Baseline: Double, savedUtc: Int) {
        self.day = day
        self.fitness = fitness
        self.fatigue = fatigue
        self.vo2Baseline = vo2Baseline
        self.savedUtc = savedUtc
    }

    /// Days since 1970, the way the watch counts them: by local date.
    public static func dayNumber(_ date: Date, calendar: Calendar = .current) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Int(utc.date(from: parts)!.timeIntervalSince1970 / 86400)
    }
}

/// The settings files on the plugged-in watch.
public final class USBSettingsStore: @unchecked Sendable {
    public static let apps = ["MyRun", "RunRoute"]

    private let appsFolder: URL

    public init(appsFolder: URL = USBRouteStore.volume.appendingPathComponent("Apps")) {
        self.appsFolder = appsFolder
    }

    private var installed: [URL] {
        Self.apps.map { appsFolder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Which apps it was written to.
    @discardableResult
    public func writeSettings(_ settings: RunSettings) throws -> [String] {
        let data = try settings.appConfigFile()
        for app in installed { try write(data, to: app.appendingPathComponent("app_config.json")) }
        return installed.map(\.lastPathComponent)
    }

    /// Only RunRoute has the screen builder; MyRun keeps its own screens.
    public static let screensApp = "RunRoute"

    /// False when RunRoute isn't installed.
    @discardableResult
    public func writeScreens(_ layout: ScreenLayout) throws -> Bool {
        let app = appsFolder.appendingPathComponent(Self.screensApp)
        guard FileManager.default.fileExists(atPath: app.path) else { return false }
        try write(try layout.screensFile(), to: app.appendingPathComponent("screens.json"))
        return true
    }

    /// What RunRoute has now, or nil for its defaults.
    public func screens() -> ScreenLayout? {
        let file = appsFolder.appendingPathComponent(Self.screensApp).appendingPathComponent("screens.json")
        return (try? Data(contentsOf: file)).flatMap(ScreenLayout.read)
    }

    /// The newest copy, as the watch apps choose between theirs.
    public func training() -> TrainingState? {
        installed.compactMap { app -> TrainingState? in
            guard let data = try? Data(contentsOf: app.appendingPathComponent("training.json")) else { return nil }
            return try? JSONDecoder().decode(TrainingState.self, from: data)
        }.max { $0.savedUtc < $1.savedUtc }
    }

    /// To every app, and newest, so each one uses it.
    public func writeTraining(_ state: TrainingState) throws {
        let data = try JSONEncoder().encode(state)
        for app in installed { try write(data, to: app.appendingPathComponent("training.json")) }
    }

    private func write(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".upload.tmp")
        try data.write(to: temporary)
        guard try Data(contentsOf: temporary) == data else {
            try? FileManager.default.removeItem(at: temporary)
            throw RouteStoreError.checkFailed(target.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        let folder = target.deletingLastPathComponent()
        for stray in [folder.appendingPathComponent("._\(target.lastPathComponent)"),
                      folder.appendingPathComponent("._.upload.tmp")] {
            try? FileManager.default.removeItem(at: stray)
        }
    }
}
