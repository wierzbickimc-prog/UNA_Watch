import Foundation

/// The run screens RunRoute pages through, built in RouteSync's screen builder and
/// written to screens.json in RunRoute's folder. The watch reads it when the app
/// starts. The keys must match ScreenLayout.hpp; the tests compare them.
public struct ScreenLayout: Codable, Equatable, Sendable {
    public static let maxScreens = 8
    public static let maxFields = 4

    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case data, route, condition, status
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .data: "Data fields"
            case .route: "Route map"
            case .condition: "Condition"
            case .status: "Status & clock"
            }
        }
    }

    /// A value a data screen can show.
    public struct Field: Sendable, Identifiable, Hashable {
        public let key: String
        public let title: String
        public let group: String
        /// What the preview shows for it.
        public let sample: String
        public var id: String { key }
    }

    /// In the watch's Field order.
    public static let fields: [Field] = [
        Field(key: "pace", title: "Pace", group: "Pace", sample: "8:42"),
        Field(key: "avgPace", title: "Average pace", group: "Pace", sample: "8:51"),
        Field(key: "lapPace", title: "Lap pace", group: "Pace", sample: "8:37"),
        Field(key: "distance", title: "Distance", group: "Distance", sample: "3.12"),
        Field(key: "lapDistance", title: "Lap distance", group: "Distance", sample: "0.62"),
        Field(key: "time", title: "Time", group: "Time", sample: "0:27:14"),
        Field(key: "lapTime", title: "Lap time", group: "Time", sample: "5:21"),
        Field(key: "laps", title: "Lap number", group: "Time", sample: "4"),
        Field(key: "hr", title: "Heart rate", group: "Heart rate", sample: "152"),
        Field(key: "avgHr", title: "Average heart rate", group: "Heart rate", sample: "147"),
        Field(key: "maxHr", title: "Max heart rate", group: "Heart rate", sample: "164"),
        Field(key: "lapHr", title: "Lap heart rate", group: "Heart rate", sample: "150"),
        Field(key: "hrZone", title: "Heart rate zone", group: "Heart rate", sample: "3"),
        Field(key: "speed", title: "Speed", group: "Other", sample: "6.9"),
        Field(key: "avgSpeed", title: "Average speed", group: "Other", sample: "6.8"),
        Field(key: "elevation", title: "Elevation", group: "Other", sample: "612"),
        Field(key: "calories", title: "Calories", group: "Other", sample: "318"),
        Field(key: "intensity", title: "Intensity", group: "Other", sample: "0.82"),
        Field(key: "condition", title: "Condition", group: "Other", sample: "+2"),
        Field(key: "clock", title: "Time of day", group: "Other", sample: "7:41"),
        Field(key: "battery", title: "Battery", group: "Other", sample: "84%"),
    ]

    public static let groups = ["Pace", "Distance", "Time", "Heart rate", "Other"]

    public static func field(_ key: String) -> Field? {
        fields.first { $0.key == key }
    }

    /// The watch's caption for a field: short, with its unit where it has one.
    public static func caption(_ key: String, imperial: Bool = true) -> String {
        switch key {
        case "pace": "Pace"
        case "avgPace": "Avg Pace"
        case "lapPace": "Lap Pace"
        case "distance": imperial ? "Miles" : "Kilometres"
        case "lapDistance": imperial ? "Lap Miles" : "Lap km"
        case "time": "Time"
        case "lapTime": "Lap Time"
        case "laps": "Lap"
        case "hr": "HR"
        case "avgHr": "Avg HR"
        case "maxHr": "Max HR"
        case "lapHr": "Lap HR"
        case "hrZone": "HR Zone"
        case "speed": imperial ? "mph" : "km/h"
        case "avgSpeed": imperial ? "Avg mph" : "Avg km/h"
        case "elevation": imperial ? "Elevation ft" : "Elevation m"
        case "calories": "Calories"
        case "intensity": "Intensity"
        case "condition": "Condition"
        case "clock": "Time of Day"
        case "battery": "Battery"
        default: ""
        }
    }

    public struct Screen: Codable, Equatable, Sendable, Identifiable {
        /// Only for lists here; not written.
        public var id = UUID()
        public var kind: Kind
        /// Field keys, one to four, for a data screen.
        public var fields: [String]

        public init(kind: Kind, fields: [String] = []) {
            self.kind = kind
            self.fields = fields
        }

        public static func data(_ fields: String...) -> Screen {
            Screen(kind: .data, fields: fields)
        }

        enum CodingKeys: String, CodingKey { case kind, fields }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            fields = try c.decodeIfPresent([String].self, forKey: .fields) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            if kind == .data { try c.encode(fields, forKey: .fields) }
        }

        public static func == (a: Screen, b: Screen) -> Bool {
            a.kind == b.kind && a.fields == b.fields
        }

        /// Sets how many fields it has, keeping those it had and filling with
        /// ones not yet on it.
        public mutating func setFieldCount(_ count: Int) {
            let count = min(max(count, 1), ScreenLayout.maxFields)
            if fields.count > count {
                fields.removeLast(fields.count - count)
            }
            for candidate in ["pace", "distance", "time", "hr", "lapPace", "calories"] where fields.count < count {
                if !fields.contains(candidate) { fields.append(candidate) }
            }
        }
    }

    public var screens: [Screen]

    public init(screens: [Screen]) {
        self.screens = screens
    }

    /// What RunRoute had before the builder.
    public static let defaults = ScreenLayout(screens: [
        Screen(kind: .route),
        .data("hr", "lapPace", "distance"),
        .data("time", "distance", "calories"),
        Screen(kind: .condition),
        Screen(kind: .status),
    ])

    public var isDefault: Bool { self == Self.defaults }

    /// What needs fixing before it can be sent. Empty when it's fine.
    public var problems: [String] {
        var found: [String] = []
        if screens.isEmpty { found.append("Add at least one screen.") }
        if screens.count > Self.maxScreens { found.append("The watch shows at most \(Self.maxScreens) screens.") }
        for (index, screen) in screens.enumerated() where screen.kind == .data {
            if screen.fields.isEmpty || screen.fields.count > Self.maxFields {
                found.append("Screen \(index + 1) needs one to four fields.")
            }
            if screen.fields.contains(where: { Self.field($0) == nil }) {
                found.append("Screen \(index + 1) has a field the watch doesn't know.")
            }
        }
        return found
    }

    /// The contents of screens.json.
    public func screensFile() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(schema: 1, screens: screens))
    }

    public static func read(_ data: Data) -> ScreenLayout? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1 else { return nil }
        let usable = file.screens.filter { $0.kind != .data || !$0.fields.isEmpty }
        return usable.isEmpty ? nil : ScreenLayout(screens: usable)
    }

    private struct File: Codable {
        let schema: Int
        let screens: [Screen]
    }
}
