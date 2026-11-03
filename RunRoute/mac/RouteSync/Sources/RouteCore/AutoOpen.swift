import Foundation

/// Opens RouteSync when the watch's drive appears, by way of launchd: it runs a
/// one-line check each time any drive mounts, and nothing stays running between.
public struct AutoOpen: Sendable {
    public static let label = "local.routesync.open-on-watch"

    public enum Failure: LocalizedError, Equatable {
        case launchctl(String)

        public var errorDescription: String? {
            switch self {
            case .launchctl(let why): return "macOS wouldn't change this setting. \(why)"
            }
        }
    }

    let agentFile: URL
    let app: String
    let volume: String

    public init(app: String, volume: String = USBRouteStore.volume.path,
                agentFile: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents/\(AutoOpen.label).plist")) {
        self.app = app
        self.volume = volume
        self.agentFile = agentFile
    }

    public var isOn: Bool {
        FileManager.default.fileExists(atPath: agentFile.path)
    }

    /// A drive mounted while the app is open shouldn't pull it to the front.
    var command: String {
        "[ -d \(Self.quoted(volume)) ] && ! /usr/bin/pgrep -x RouteSync >/dev/null && /usr/bin/open \(Self.quoted(app))"
    }

    func agent() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": Self.label,
            "ProgramArguments": ["/bin/sh", "-c", command],
            "StartOnMount": true,
        ] as [String: Any], format: .xml, options: 0)
    }

    public func turnOn() throws {
        try FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try agent().write(to: agentFile, options: .atomic)
        _ = Self.launchctl(["bootout", "\(Self.session)/\(Self.label)"])
        let result = Self.launchctl(["bootstrap", Self.session, agentFile.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: agentFile)
            throw Failure.launchctl(result.output)
        }
    }

    public func turnOff() throws {
        _ = Self.launchctl(["bootout", "\(Self.session)/\(Self.label)"])
        if isOn { try FileManager.default.removeItem(at: agentFile) }
    }

    /// Follows the app if it has moved since this was turned on.
    public func refresh() throws {
        guard isOn, let current = try? Data(contentsOf: agentFile), try current != agent() else { return }
        try turnOn()
    }

    private static var session: String { "gui/\(getuid())" }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
