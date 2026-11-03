import RouteCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx")
    static let fitWorkout = UTType(importedAs: "com.garmin.fit")
}

struct ContentView: View {
    @ObservedObject var model: UploadModel
    @State private var dropTargeted = false

    var body: some View {
        Group {
            switch model.phase {
            case .ready:
                ready
            case .reading:
                busy("Reading")
            case .review:
                ReviewView(model: model)
            case .waitingForWatch:
                waiting
            case .working(let what):
                busy(what)
            case .finished(let ejection, let sentAnything, let sentWorkout):
                finished(ejection, sentAnything: sentAnything, sentWorkout: sentWorkout)
            case .manage:
                ManageView(model: model)
            case .settings:
                SettingsView(model: model)
            case .library:
                LibraryView(model: model)
            case .editor:
                EditorView(model: model)
            }
        }
        .frame(width: 540, height: 660)
        .background {
            // Behind the hidden title bar too.
            Theme.background
                .overlay(alignment: .top) { Rectangle().fill(Theme.accent).frame(height: 3) }
                .ignoresSafeArea()
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: 3).padding(6)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            let usable = urls.filter { ["gpx", "fit"].contains($0.pathExtension.lowercased()) }
            guard !usable.isEmpty else { return false }
            model.open(usable)
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert("RouteSync", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var ready: some View {
        Page(eyebrow: "Routes, workouts & settings", title: "Your watch.", watchConnected: model.isMounted, onEject: model.ejectWatch) {
            VStack(spacing: 14) {
                Button {
                    model.choose()
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "figure.run").font(.system(size: 34)).foregroundStyle(Theme.accent)
                        Text("Send something to your watch").font(Theme.heading(20)).foregroundStyle(Theme.ink)
                        Text("Drop a GPX route or a FIT workout here, or click to choose.")
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                menuRow(icon: "figure.run.square.stack", title: "Workout builder", detail: "Make, edit and send your own workouts") {
                    model.openLibrary()
                }
                menuRow(icon: "slider.horizontal.3", title: "Settings", detail: "Threshold, zones, alerts and route alarms") {
                    model.openSettings()
                }
                if model.isMounted {
                    menuRow(icon: "list.bullet", title: "What's on the watch", detail: "Rename or delete routes and workouts") {
                        model.openManage()
                    }
                }
            }
            .padding(.horizontal, 24)
        } footer: {
            HStack {
                Spacer()
                Button("Choose Files...") { model.choose() }
                    .themedButton(primary: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func menuRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        MenuRowButton(icon: icon, title: title, detail: detail, action: action)
    }

    private func busy(_ what: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(what).font(Theme.heading(20)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            Image(systemName: "cable.connector").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Plug in your watch").font(Theme.heading(26)).foregroundStyle(Theme.ink)
            Text("Sending starts as soon as the watch appears. That can take a moment.")
                .font(Theme.ui(14))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
            ProgressView().controlSize(.small).padding(.vertical, 4)
            Button("Cancel") { model.cancel() }.themedButton()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finished(_ ejection: UploadModel.Ejection, sentAnything: Bool, sentWorkout: Bool) -> some View {
        let failed = model.outcomes.contains(where: \.isFailure)
        // Just ejecting, with nothing sent.
        let onlyEjected = model.outcomes.isEmpty && !sentAnything
        return Page(eyebrow: failed || ejection == .failed ? "Something needs a look" : "All done",
                    title: onlyEjected ? (ejection == .failed ? "Still plugged in." : "Safe to unplug.")
                        : failed ? "Not quite." : "On your watch.",
                    watchConnected: model.isMounted,
                    onEject: model.ejectWatch) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.outcomes.isEmpty {
                        Card {
                            ForEach(Array(model.outcomes.enumerated()), id: \.offset) { index, outcome in
                                if index > 0 { Hairline() }
                                OutcomeRow(outcome: outcome)
                            }
                        }
                    }
                    if sentWorkout {
                        note("Find workouts under Workouts in MyRun and RunRoute, after you reopen the app.")
                    } else if sentAnything {
                        note("Find routes under Routes in RunRoute, after you reopen the app.")
                    }
                }
                .padding(.horizontal, 24)
            }
        } footer: {
            HStack {
                ejectionNote(ejection)
                Spacer()
                Button("Done") { model.cancel() }
                    .themedButton(primary: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.ui(13)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder
    private func ejectionNote(_ ejection: UploadModel.Ejection) -> some View {
        switch ejection {
        case .done:
            note("Ejected. You can unplug the watch.")
        case .failed:
            Text("Couldn't eject. Try again before unplugging.")
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.accent)
        case .notTried:
            if model.isMounted {
                Text("Still connected. Eject before unplugging.")
                    .font(Theme.ui(13, .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

private struct MenuRowButton: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(hovering ? Theme.hover : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct OutcomeRow: View {
    let outcome: RouteUploader.Outcome

    var body: some View {
        HStack(spacing: 12) {
            Tick(color: outcome.isFailure ? Theme.problem : Theme.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.title).font(Theme.ui(14, .medium)).foregroundStyle(Theme.ink)
                Text(outcome.detail).font(Theme.ui(12)).foregroundStyle(outcome.isFailure ? Theme.problem : Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}

/// Check names and how zones will be enforced before anything is sent.
private struct ReviewView: View {
    @ObservedObject var model: UploadModel

    var body: some View {
        Page(eyebrow: "Check before sending", title: "Ready to go.", watchConnected: model.isMounted) {
            VStack(spacing: 12) {
                ScrollView {
                    Card {
                        ForEach(Array($model.items.enumerated()), id: \.element.id) { index, $item in
                            if index > 0 { Hairline() }
                            ItemRow(model: model, item: $item)
                        }
                        ForEach(Array(model.unreadable.enumerated()), id: \.offset) { index, outcome in
                            if index > 0 || !model.items.isEmpty { Hairline() }
                            OutcomeRow(outcome: outcome)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                // Stays in view however long the list is: it decides every target.
                if model.anyWorkoutUsesZones {
                    zones.padding(.horizontal, 24)
                }
            }
        } footer: {
            HStack {
                Button("Cancel") { model.cancel() }.themedButton()
                Spacer()
                if !model.isMounted {
                    Text("You can plug in the watch next.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
                // No Return shortcut: Return in a name field would send.
                Button("Send to Watch") { model.send() }
                    .themedButton(primary: true)
                    .disabled(model.items.isEmpty || model.thresholdIsMissing)
            }
        }
    }

    private var zones: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enforce zones by").font(Theme.ui(13, .medium)).foregroundStyle(Theme.muted)
                EnforcementPicker(selection: $model.enforcement)
                switch model.enforcement {
                case .pace:
                    threshold("Threshold pace", text: $model.thresholdPace, unit: "min/mile",
                              hint: "Pace from GPS follows zones well on the flat, but ignores hills and heat.")
                case .heartRate:
                    threshold("Threshold heart rate", text: $model.thresholdBpm, unit: "bpm",
                              hint: "Heart rate lags, so very short steps stay as labels.")
                case .none:
                    Text("The watch shows each zone's name, and gives no alerts about it.")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func threshold(_ title: String, text: Binding<String>, unit: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.ui(14)).foregroundStyle(Theme.ink)
                Spacer()
                if model.thresholdIsMissing {
                    Text("Enter a threshold").font(Theme.ui(12)).foregroundStyle(Theme.problem)
                }
                TextField("", text: text)
                    .multilineTextAlignment(.trailing)
                    .themedField()
                    .frame(width: 72)
                Text(unit).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
            Text(hint).font(Theme.ui(12)).foregroundStyle(Theme.dim)
        }
    }
}

/// The Weeks / Months buttons from the calendar.
struct EnforcementPicker: View {
    @Binding var selection: UploadModel.Enforcement

    var body: some View {
        HStack(spacing: 6) {
            ForEach(UploadModel.Enforcement.allCases) { option in
                Button(option.rawValue) { selection = option }
                    .themedButton(primary: option == selection)
            }
        }
    }
}

private struct ItemRow: View {
    @ObservedObject var model: UploadModel
    @Binding var item: PendingItem

    private var isRoute: Bool {
        if case .route = item.content { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Tick(color: isRoute ? Theme.mint : Theme.peach)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Name", text: $item.name).themedField()
                    Button {
                        model.items.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Don't send this")
                }
                Text(summary).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if !zoneLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(zoneLines, id: \.self) { line in
                            Text(line).font(Theme.ui(12)).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }

    private var summary: String {
        switch item.content {
        case .route(let route):
            let thinned = route.keptCount < route.pointCount ? ", thinned from \(route.pointCount) points" : ""
            return String(format: "Route, %.2f mi, %d points", route.miles, route.keptCount) + thinned
        case .workout(let workout):
            var parts = ["Workout"]
            if workout.totalSeconds > 0 { parts.append("\(workout.totalSeconds / 60) min") }
            if workout.totalMetres > 0 { parts.append(String(format: "%.1f mi", workout.totalMetres / 1609.344)) }
            return parts.joined(separator: ", ")
        }
    }

    private var zoneLines: [String] {
        guard case .workout(let workout) = item.content else { return [] }
        let applied = model.applied(workout)
        var lines = applied.bands.map { "\($0.zone): \($0.text)" }
        if applied.tooShort > 0 {
            lines.append("\(applied.tooShort) short step\(applied.tooShort == 1 ? "" : "s") stay as labels")
        }
        if applied.unmatched > 0 {
            lines.append("\(applied.unmatched) step\(applied.unmatched == 1 ? " doesn't" : "s don't") name a zone")
        }
        return lines
    }
}

/// Rename or remove what's on the plugged-in watch. Apps on the watch can't change
/// its workouts folder, so this is the only way to tidy it.
private struct ManageView: View {
    @ObservedObject var model: UploadModel
    @State private var confirming: Removal?

    private enum Removal: Identifiable {
        case workout(WatchWorkout)
        case route(String)

        var id: String {
            switch self {
            case .workout(let workout): return "w:" + workout.fileName
            case .route(let name): return "r:" + name
            }
        }

        var name: String {
            switch self {
            case .workout(let workout): return workout.name
            case .route(let name): return name
            }
        }
    }

    var body: some View {
        Page(eyebrow: "Rename or delete", title: "On your watch.", watchConnected: model.isMounted) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Workouts", note: "\(model.watchWorkouts.count) of \(USBWorkoutStore.capacity)")
                    Card {
                        if model.watchWorkouts.isEmpty { empty("No workouts yet") }
                        ForEach(Array(model.watchWorkouts.enumerated()), id: \.element.id) { index, workout in
                            if index > 0 { Hairline() }
                            NameRow(color: Theme.peach, name: workout.name, rename: { model.rename(workout, to: $0) },
                                    remove: { confirming = .workout(workout) })
                        }
                    }
                    SectionTitle(title: "Routes", note: "\(model.watchRoutes.count) of \(SyncPlan.capacity)")
                        .padding(.top, 8)
                    Card {
                        if model.watchRoutes.isEmpty { empty("No routes yet") }
                        ForEach(Array(model.watchRoutes.enumerated()), id: \.element) { index, route in
                            if index > 0 { Hairline() }
                            NameRow(color: Theme.mint, name: route, rename: { model.renameRoute(route, to: $0) },
                                    remove: { confirming = .route(route) })
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        } footer: {
            HStack {
                Text("Edit a name to rename it.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                Spacer()
                // No Return shortcut: Return in a name field would eject.
                Button("Eject Watch") { model.ejectWatch() }.themedButton(primary: true)
            }
        }
        .confirmationDialog("Delete \(confirming?.name ?? "") from the watch?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { removal in
            Button("Delete", role: .destructive) {
                switch removal {
                case .workout(let workout): model.delete(workout)
                case .route(let name): model.deleteRoute(name)
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(14))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}

private struct NameRow: View {
    let color: Color
    let name: String
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Tick(color: color)
            TextField("Name", text: $text)
                .focused($focused)
                .onSubmit { rename(text) }
                .onChange(of: focused) { if !focused { rename(text) } }
                .themedField()
            Button("Delete", action: remove).themedButton(small: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .onAppear { text = name }
        .onChange(of: name) { text = name }
    }
}
