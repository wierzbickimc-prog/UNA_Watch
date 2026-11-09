import AppKit
import RouteCore
import UniformTypeIdentifiers

/// A route or workout waiting to be sent, with the name it will have on the watch.
struct PendingItem: Identifiable {
    enum Content {
        case route(RouteFile)
        case workout(FitWorkout)
    }

    let id = UUID()
    let source: URL
    let content: Content
    var name: String
}

@MainActor
final class UploadModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case reading
        case review
        case waitingForWatch
        case working(String)
        case finished(Ejection, sentAnything: Bool, sentWorkout: Bool)
        case manage
        case settings
        case screens
        case library
        case editor
    }

    enum Ejection: Equatable {
        case done
        case failed
        /// A problem may need fixing on the drive, or the drive was never used.
        case notTried
    }

    enum Enforcement: String, CaseIterable, Identifiable {
        case pace = "Pace"
        case heartRate = "Heart rate"
        case none = "Labels only"
        var id: String { rawValue }
    }

    private enum Key {
        static let enforcement = "zoneEnforcement"
        static let thresholdBpm = "thresholdBpm"
        static let thresholdPace = "thresholdPace"
        static let settings = "runSettings"
        static let screens = "runScreens"
    }

    @Published private(set) var phase = Phase.ready
    @Published private(set) var outcomes: [RouteUploader.Outcome] = []
    @Published private(set) var isMounted = USBRouteStore.isMounted
    @Published var items: [PendingItem] = []
    @Published private(set) var unreadable: [RouteUploader.Outcome] = []

    @Published var enforcement: Enforcement {
        didSet { UserDefaults.standard.set(enforcement.rawValue, forKey: Key.enforcement) }
    }
    @Published var thresholdBpm: String {
        didSet {
            UserDefaults.standard.set(thresholdBpm, forKey: Key.thresholdBpm)
            settings.thresholdBpm = Int(thresholdBpm.trimmingCharacters(in: .whitespaces))
        }
    }
    @Published var thresholdPace: String {
        didSet {
            UserDefaults.standard.set(thresholdPace, forKey: Key.thresholdPace)
            if let seconds = ZoneTargets.seconds(fromPace: thresholdPace) { settings.thresholdPaceSec = seconds }
        }
    }
    @Published var settings: RunSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Key.settings) }
        }
    }
    /// The watch's fitness, fatigue and usual VO2max, while it's plugged in.
    @Published var training: TrainingState?
    private var trainingOnWatch: TrainingState?
    private var settingsPending = false

    /// The run screens being built. Saved as they change.
    @Published var screens: ScreenLayout {
        didSet {
            if let data = try? JSONEncoder().encode(screens) { UserDefaults.standard.set(data, forKey: Key.screens) }
        }
    }
    private var screensPending = false

    /// The workouts built here, and the one open in the editor. Both save as they change.
    @Published private(set) var drafts: [WorkoutDraft]
    @Published var editing: WorkoutDraft? {
        didSet { saveEditing() }
    }
    private let library = WorkoutLibrary()

    @Published private(set) var watchRoutes: [String] = []
    @Published private(set) var watchWorkouts: [WatchWorkout] = []
    @Published var message: String?
    @Published private(set) var opensWithWatch = false
    /// Nil when running outside the app bundle, as launchd would have nothing to open.
    private let autoOpen = Bundle.main.bundlePath.hasSuffix(".app") ? AutoOpen(app: Bundle.main.bundlePath) : nil

    private var readsInProgress = 0
    private var approved: (routes: [RouteFile], workouts: [RouteUploader.WorkoutFile])?
    private var observers: [NSObjectProtocol] = []
    private let workoutStore = USBWorkoutStore()

    init() {
        let defaults = UserDefaults.standard
        enforcement = defaults.string(forKey: Key.enforcement).flatMap(Enforcement.init) ?? .pace
        var loaded = defaults.data(forKey: Key.settings).flatMap { try? JSONDecoder().decode(RunSettings.self, from: $0) }
            ?? RunSettings()
        let bpm = defaults.string(forKey: Key.thresholdBpm) ?? loaded.thresholdBpm.map(String.init) ?? ""
        let pace = defaults.string(forKey: Key.thresholdPace) ?? ZoneTargets.paceText(Double(loaded.thresholdPaceSec))
        // What's typed wins, so the workouts and the watch can't use different thresholds.
        loaded.thresholdBpm = Int(bpm.trimmingCharacters(in: .whitespaces))
        if let seconds = ZoneTargets.seconds(fromPace: pace) { loaded.thresholdPaceSec = seconds }
        drafts = library.load()
        screens = defaults.data(forKey: Key.screens).flatMap { try? JSONDecoder().decode(ScreenLayout.self, from: $0) }
            ?? .defaults
        settings = loaded
        thresholdBpm = bpm
        thresholdPace = pace
        try? autoOpen?.refresh()
        opensWithWatch = autoOpen?.isOn ?? false

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.drivesChanged() }
            })
        }
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    // MARK: Choosing

    func choose() {
        let panel = NSOpenPanel()
        // By extension too, because another app can claim these as its own types.
        panel.allowedContentTypes = [.gpx, .fitWorkout] + ["gpx", "fit"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose GPX routes or FIT workouts for your watch."
        if panel.runModal() == .OK { open(panel.urls) }
    }

    /// Adds to the list, because macOS can deliver files opened together one at a time.
    func open(_ files: [URL]) {
        guard !isBusy, phase != .waitingForWatch else { return }
        if phase != .review && phase != .reading {
            approved = nil
            outcomes = []
            items = []
            unreadable = []
        }
        phase = .reading
        readsInProgress += 1
        Task {
            let read = await Task.detached { Self.read(files) }.value
            let known = Set(items.map(\.source))
            items += read.items.filter { !known.contains($0.source) }
            unreadable += read.unreadable.filter { !unreadable.contains($0) }
            readsInProgress -= 1
            if readsInProgress == 0 { phase = .review }
        }
    }

    private nonisolated static func read(_ files: [URL]) -> (items: [PendingItem], unreadable: [RouteUploader.Outcome]) {
        var items: [PendingItem] = []
        var unreadable: [RouteUploader.Outcome] = []
        for file in files {
            do {
                if file.pathExtension.lowercased() == "fit" {
                    let workout = try FitWorkout(fit: Data(contentsOf: file))
                    let fallback = file.deletingPathExtension().lastPathComponent
                    let name = RouteFile.cleanName(workout.name) ?? RouteFile.cleanName(fallback) ?? "Workout"
                    items.append(PendingItem(source: file, content: .workout(workout), name: name))
                } else {
                    let route = try RouteFile(gpx: file)
                    items.append(PendingItem(source: file, content: .route(route), name: route.name))
                }
            } catch {
                unreadable.append(.unreadable(file: file.lastPathComponent, why: error.localizedDescription))
            }
        }
        return (items, unreadable)
    }

    // MARK: Zones

    var metric: ZoneMetric? {
        switch enforcement {
        case .none:
            return nil
        case .heartRate:
            guard let bpm = Int(thresholdBpm.trimmingCharacters(in: .whitespaces)),
                  ZoneMetric.bpmRange.contains(bpm) else { return nil }
            return .heartRate(thresholdBpm: bpm)
        case .pace:
            guard let seconds = ZoneTargets.seconds(fromPace: thresholdPace),
                  ZoneMetric.secondsPerMileRange.contains(seconds) else { return nil }
            return .pace(secondsPerMile: seconds)
        }
    }

    var anyWorkoutUsesZones: Bool {
        items.contains {
            if case .workout(let workout) = $0.content { return ZoneTargets.usesZones(workout) }
            return false
        }
    }

    var thresholdIsMissing: Bool {
        enforcement != .none && metric == nil && anyWorkoutUsesZones
    }

    func applied(_ workout: FitWorkout) -> AppliedZones {
        metric.map { ZoneTargets.apply($0, to: workout, settings: settings) } ?? AppliedZones(workout: workout)
    }

    // MARK: Sending

    func cancel() {
        approved = nil
        settingsPending = false
        screensPending = false
        items = []
        unreadable = []
        outcomes = []
        phase = .ready
    }

    func send() {
        guard !isBusy, !items.isEmpty, !thresholdIsMissing else { return }
        var routes: [RouteFile] = []
        var workouts: [RouteUploader.WorkoutFile] = []
        for item in items {
            switch item.content {
            case .route(let route):
                routes.append(route.renamed(item.name))
            case .workout(let original):
                var workout = applied(original).workout
                let name = RouteFile.cleanName(item.name) ?? RouteFile.cleanName(original.name) ?? "Workout"
                workout.name = name
                workouts.append(.init(name: name, data: workout.encoded()))
            }
        }
        approved = (routes, workouts)
        outcomes = unreadable
        if USBRouteStore.isMounted {
            sendApproved()
        } else {
            phase = .waitingForWatch
        }
    }

    private func drivesChanged() {
        isMounted = USBRouteStore.isMounted
        if phase == .waitingForWatch, isMounted {
            if settingsPending {
                writeSettings()
            } else if screensPending {
                writeScreens()
            } else {
                sendApproved()
            }
        } else if phase == .manage, !isMounted {
            phase = .ready
        } else if phase == .settings {
            loadTraining()
        }
    }

    private func sendApproved() {
        guard let (routes, workouts) = approved else { return }
        approved = nil
        phase = .working("Sending to the watch")
        Task {
            var results: [RouteUploader.Outcome] = []
            if !routes.isEmpty {
                results += await RouteUploader.send(routes, to: USBRouteStore()).outcomes
            }
            if !workouts.isEmpty {
                let store = workoutStore
                results += await Task.detached { RouteUploader.send(workouts, to: store) }.value
            }
            outcomes += results
            let sent = results.contains { if case .sent = $0 { return true } else { return false } }
            let sentWorkout = !workouts.isEmpty && sent
            if results.contains(where: \.isFailure) {
                phase = .finished(.notTried, sentAnything: sent, sentWorkout: sentWorkout)
                return
            }
            phase = .working("Ejecting the watch")
            let ejected = await Self.eject()
            phase = .finished(ejected ? .done : .failed, sentAnything: sent, sentWorkout: sentWorkout)
        }
    }

    /// Spotlight can hold a new drive open for a moment, so it gets a few tries.
    private static func eject() async -> Bool {
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            let done = await Task.detached { () -> Bool in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: USBRouteStore.volume)
                    return true
                } catch {
                    return false
                }
            }.value
            if done { return true }
        }
        return false
    }

    // MARK: Building workouts

    func openLibrary() {
        phase = .library
    }

    func newDraft() {
        let draft = WorkoutDraft.starter()
        drafts.insert(draft, at: 0)
        editing = draft
        phase = .editor
    }

    func edit(_ draft: WorkoutDraft) {
        editing = draft
        phase = .editor
    }

    func closeEditor() {
        editing = nil
        phase = .library
    }

    func duplicate(_ draft: WorkoutDraft) {
        var copy = draft
        copy.id = UUID()
        copy.name = String((draft.name + " Copy").prefix(RouteFile.maxName))
        drafts.insert(copy, at: 0)
        saveDrafts()
    }

    func delete(_ draft: WorkoutDraft) {
        drafts.removeAll { $0.id == draft.id }
        saveDrafts()
    }

    /// A copy to edit. The file itself isn't changed.
    func importDrafts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fitWorkout] + (UTType(filenameExtension: "fit").map { [$0] } ?? [])
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose FIT workouts to edit."
        guard panel.runModal() == .OK else { return }
        var refused: [String] = []
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            if let workout = try? FitWorkout(fit: Data(contentsOf: url)),
               let draft = WorkoutDraft(workout: workout, fallbackName: RouteFile.cleanName(name) ?? "Workout") {
                drafts.insert(draft, at: 0)
            } else {
                refused.append(url.lastPathComponent)
            }
        }
        saveDrafts()
        if !refused.isEmpty {
            message = "Couldn't import \(refused.joined(separator: ", ")). It may not be a workout, or may use steps the builder can't show."
        }
    }

    /// Goes through the same check-and-send screen as a downloaded workout.
    func sendDraft(_ draft: WorkoutDraft) {
        guard draft.problems.isEmpty else { return }
        approved = nil
        outcomes = []
        unreadable = []
        let source = URL(string: "routesync-draft:\(draft.id.uuidString)")!
        items = [PendingItem(source: source, content: .workout(draft.built), name: RouteFile.cleanName(draft.name) ?? "Workout")]
        editing = nil
        phase = .review
    }

    func export(_ draft: WorkoutDraft) {
        guard draft.problems.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (RouteFile.cleanName(draft.name) ?? "Workout") + ".fit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try applied(draft.built).workout.encoded().write(to: url)
        } catch {
            message = error.localizedDescription
        }
    }

    func bandText(zone: String) -> String? {
        metric.flatMap { ZoneTargets.bandText(zone: zone, metric: $0, settings: settings) }
    }

    private func saveEditing() {
        guard let editing, let index = drafts.firstIndex(where: { $0.id == editing.id }),
              drafts[index] != editing else { return }
        drafts[index] = editing
        saveDrafts()
    }

    private func saveDrafts() {
        do {
            try library.save(drafts)
        } catch {
            message = "Couldn't save your workouts: \(error.localizedDescription)"
        }
    }

    // MARK: Settings

    func setOpensWithWatch(_ on: Bool) {
        guard let autoOpen else { return }
        attempt { on ? try autoOpen.turnOn() : try autoOpen.turnOff() }
        opensWithWatch = autoOpen.isOn
    }

    func openSettings() {
        loadTraining()
        phase = .settings
    }

    private func loadTraining() {
        trainingOnWatch = isMounted ? USBSettingsStore().training() : nil
        training = trainingOnWatch
    }

    /// What's wrong with the settings as they stand.
    var settingsProblems: [String] {
        var found = settings.problems
        if metric == nil, enforcement != .none {
            found.append(enforcement == .pace ? "Enter a threshold pace, like 8:30." : "Enter a threshold heart rate.")
        }
        return found
    }

    func resetSettings() {
        settings = RunSettings()
        thresholdPace = ZoneTargets.paceText(Double(settings.thresholdPaceSec))
        thresholdBpm = ""
        enforcement = .pace
    }

    func sendSettings() {
        guard settingsProblems.isEmpty else { return }
        outcomes = []
        if isMounted {
            writeSettings()
        } else {
            settingsPending = true
            phase = .waitingForWatch
        }
    }

    private func writeSettings() {
        settingsPending = false
        phase = .working("Sending settings to the watch")
        let settings = settings, metric = metric
        var changedTraining: TrainingState?
        if var edited = training, edited != trainingOnWatch {
            edited.day = TrainingState.dayNumber(Date())
            edited.savedUtc = Int(Date().timeIntervalSince1970)
            changedTraining = edited
        }
        let chosen = changedTraining
        let store = workoutStore
        Task {
            let results = await Task.detached { Self.write(settings, metric: metric, training: chosen, workouts: store) }.value
            outcomes = results
            if results.contains(where: \.isFailure) {
                phase = .finished(.notTried, sentAnything: false, sentWorkout: false)
                return
            }
            phase = .working("Ejecting the watch")
            let ejected = await Self.eject()
            phase = .finished(ejected ? .done : .failed, sentAnything: false, sentWorkout: false)
        }
    }

    private nonisolated static func write(_ settings: RunSettings, metric: ZoneMetric?, training: TrainingState?,
                                          workouts: USBWorkoutStore) -> [RouteUploader.Outcome] {
        var results: [RouteUploader.Outcome] = []
        let store = USBSettingsStore()
        do {
            let apps = try store.writeSettings(settings)
            if apps.isEmpty {
                return [.failed("Settings", why: "Neither MyRun nor RunRoute is installed on the watch.")]
            }
            results.append(.updated("Settings", detail: "Written to \(apps.joined(separator: " and ")). They apply the next time each app starts."))
        } catch {
            return [.failed("Settings", why: error.localizedDescription)]
        }
        if let training {
            do {
                try store.writeTraining(training)
                results.append(.updated("Training", detail: "Fitness, fatigue and VO2max set, counting from today."))
            } catch {
                results.append(.failed("Training", why: error.localizedDescription))
            }
        }
        do {
            var changed = 0
            for workout in try workouts.workouts() {
                guard let parsed = try? FitWorkout(fit: workout.data) else { continue }
                let cleared = ZoneTargets.clear(parsed)
                let updated = metric.map { ZoneTargets.apply($0, to: cleared, settings: settings).workout } ?? cleared
                if updated != parsed {
                    try workouts.put(fileName: workout.fileName, data: updated.encoded())
                    changed += 1
                }
            }
            if changed > 0 {
                results.append(.updated("Workouts", detail: "\(changed) on the watch updated to these zones."))
            }
        } catch {
            results.append(.failed("Workouts", why: error.localizedDescription))
        }
        return results
    }

    // MARK: Screens

    func openScreens() {
        phase = .screens
    }

    /// What RunRoute has now, to start from instead of what's saved here.
    var screensOnWatch: ScreenLayout? {
        isMounted ? USBSettingsStore().screens() : nil
    }

    func resetScreens() {
        screens = .defaults
    }

    func sendScreens() {
        guard screens.problems.isEmpty else { return }
        outcomes = []
        if isMounted {
            writeScreens()
        } else {
            screensPending = true
            phase = .waitingForWatch
        }
    }

    private func writeScreens() {
        screensPending = false
        phase = .working("Sending screens to the watch")
        let layout = screens
        Task {
            let result: RouteUploader.Outcome = await Task.detached {
                do {
                    return try USBSettingsStore().writeScreens(layout)
                        ? .updated("Run screens", detail: "\(layout.screens.count) screens. They apply the next time RunRoute starts.")
                        : .failed("Run screens", why: "RunRoute isn't installed on the watch.")
                } catch {
                    return .failed("Run screens", why: error.localizedDescription)
                }
            }.value
            outcomes = [result]
            if result.isFailure {
                phase = .finished(.notTried, sentAnything: false, sentWorkout: false)
                return
            }
            phase = .working("Ejecting the watch")
            let ejected = await Self.eject()
            phase = .finished(ejected ? .done : .failed, sentAnything: false, sentWorkout: false)
        }
    }

    // MARK: What's on the watch

    func openManage() {
        guard isMounted else { return }
        reloadWatch()
        phase = .manage
    }

    private func reloadWatch() {
        do {
            watchWorkouts = try workoutStore.workouts()
        } catch {
            watchWorkouts = []
            message = error.localizedDescription
        }
        let routes = USBRouteStore.defaultApp.appendingPathComponent("Routes")
        watchRoutes = ((try? FileManager.default.contentsOfDirectory(atPath: routes.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".bin") }
            .map { String($0.dropLast(4)) }
            .sorted()
    }

    func rename(_ workout: WatchWorkout, to newName: String) {
        guard let name = RouteFile.cleanName(newName), name != workout.name else {
            reloadWatch()
            return
        }
        if name.caseInsensitiveCompare(workout.name) != .orderedSame,
           watchWorkouts.contains(where: { $0.fileName.caseInsensitiveCompare(name + ".fit") == .orderedSame }) {
            message = RouteStoreError.nameTaken(name).errorDescription
        } else {
            attempt { _ = try workoutStore.rename(workout, to: name) }
        }
        reloadWatch()
    }

    func renameRoute(_ route: String, to newName: String) {
        guard let name = RouteFile.cleanName(newName), name != route else {
            reloadWatch()
            return
        }
        attempt { try USBRouteStore().rename(name: route, to: name) }
        reloadWatch()
    }

    func delete(_ workout: WatchWorkout) {
        attempt { try workoutStore.delete(fileName: workout.fileName) }
        reloadWatch()
    }

    func deleteRoute(_ route: String) {
        let store = USBRouteStore()
        Task {
            do {
                try await store.delete(name: route)
            } catch {
                message = error.localizedDescription
            }
            reloadWatch()
        }
    }

    func ejectWatch() {
        phase = .working("Ejecting the watch")
        Task {
            let ejected = await Self.eject()
            outcomes = []
            phase = .finished(ejected ? .done : .failed, sentAnything: false, sentWorkout: false)
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            message = error.localizedDescription
        }
    }
}
