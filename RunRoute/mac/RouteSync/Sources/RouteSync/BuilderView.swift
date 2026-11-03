import RouteCore
import SwiftUI

/// The workouts built so far.
struct LibraryView: View {
    @ObservedObject var model: UploadModel
    @State private var confirmingDelete: WorkoutDraft?

    var body: some View {
        Page(eyebrow: "Workout builder", title: "Your workouts.", watchConnected: model.isMounted, onEject: model.ejectWatch) {
            ScrollView {
                VStack(spacing: 12) {
                    if model.drafts.isEmpty {
                        Card {
                            VStack(spacing: 8) {
                                Image(systemName: "figure.run").font(.system(size: 28)).foregroundStyle(Theme.accent)
                                Text("Nothing here yet").font(Theme.heading(20)).foregroundStyle(Theme.ink)
                                Text("Start a new workout, or import a FIT file to change it.")
                                    .font(Theme.ui(13))
                                    .foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(30)
                        }
                    } else {
                        Card {
                            ForEach(Array(model.drafts.enumerated()), id: \.element.id) { index, draft in
                                if index > 0 { Hairline() }
                                row(draft)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        } footer: {
            HStack {
                Button("Back") { model.cancel() }.themedButton()
                Button("Import FIT...") { model.importDrafts() }.themedButton()
                Spacer()
                Button("New Workout") { model.newDraft() }
                    .themedButton(primary: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Delete \(confirmingDelete?.name ?? "")?",
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            presenting: confirmingDelete) { draft in
            Button("Delete", role: .destructive) { model.delete(draft) }
        } message: { _ in
            Text("This removes it from this Mac. A copy already sent stays on the watch.")
        }
    }

    private func row(_ draft: WorkoutDraft) -> some View {
        HStack(spacing: 10) {
            Tick(color: Theme.peach)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.name).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(Summary.text(draft)).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Edit") { model.edit(draft) }.themedButton(small: true)
            Button("Copy") { model.duplicate(draft) }.themedButton(small: true)
            Button("Delete") { confirmingDelete = draft }.themedButton(small: true)
            Button("Send") { model.sendDraft(draft) }
                .themedButton(primary: true, small: true)
                .disabled(!draft.problems.isEmpty)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
    }
}

enum Summary {
    static func text(_ draft: WorkoutDraft) -> String {
        let built = draft.built
        var parts: [String] = []
        if built.totalSeconds > 0 { parts.append("\(built.totalSeconds / 60) min") }
        if built.totalMetres > 0 { parts.append(String(format: "%.2f mi", built.totalMetres / 1609.344)) }
        let laps = draft.blocks.reduce(0) { total, block in
            total + block.steps.filter { $0.end == .lap }.count * (block.isRepeat ? block.times : 1)
        }
        if laps > 0 { parts.append("\(laps) until lap press") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: ", ")
    }
}

/// Builds one workout. Every change saves as it's made.
struct EditorView: View {
    @ObservedObject var model: UploadModel

    private var draft: Binding<WorkoutDraft> {
        Binding(get: { model.editing ?? .starter() }, set: { model.editing = $0 })
    }

    var body: some View {
        Page(eyebrow: "Workout builder", title: "Build it.", watchConnected: model.isMounted, onEject: model.ejectWatch) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Name", text: draft.name).themedField()
                    Text(Summary.text(draft.wrappedValue))
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
                .padding(.horizontal, 24)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(draft.blocks.enumerated()), id: \.element.id) { index, $block in
                            BlockView(model: model, block: $block,
                                      moveUp: index > 0 ? { move(index, by: -1) } : nil,
                                      moveDown: index < draft.wrappedValue.blocks.count - 1 ? { move(index, by: 1) } : nil,
                                      remove: { removeBlock(block.id) })
                        }
                        HStack(spacing: 8) {
                            Button("Add Step") {
                                draft.wrappedValue.blocks.append(.single(.init(kind: .run, end: .time(seconds: 600), target: .zone("2"))))
                            }
                            .themedButton()
                            Button("Add Repeat") {
                                draft.wrappedValue.blocks.append(.repeated(3, [
                                    .init(kind: .run, end: .time(seconds: 180), target: .zone("3")),
                                    .init(kind: .rest, end: .time(seconds: 120), target: .zone("1")),
                                ]))
                            }
                            .themedButton()
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(draft.wrappedValue.problems, id: \.self) { problem in
                    Text(problem).font(Theme.ui(12)).foregroundStyle(Theme.problem)
                }
                HStack {
                    Button("Done") { model.closeEditor() }.themedButton()
                    Button("Export FIT...") { model.export(draft.wrappedValue) }
                        .themedButton()
                        .disabled(!draft.wrappedValue.problems.isEmpty)
                    Spacer()
                    // No Return shortcut: Return in a name field would send.
                    Button("Send to Watch") { model.sendDraft(draft.wrappedValue) }
                        .themedButton(primary: true)
                        .disabled(!draft.wrappedValue.problems.isEmpty)
                }
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        draft.wrappedValue.blocks.swapAt(index, index + offset)
    }

    private func removeBlock(_ id: UUID) {
        draft.wrappedValue.blocks.removeAll { $0.id == id }
    }
}

private struct BlockView: View {
    @ObservedObject var model: UploadModel
    @Binding var block: WorkoutDraft.Block
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        Card {
            if block.isRepeat {
                HStack(spacing: 8) {
                    Image(systemName: "repeat").foregroundStyle(Theme.accent)
                    Text("Repeat").font(Theme.ui(14, .semibold)).foregroundStyle(Theme.ink)
                    NumberBox(value: $block.times, width: 48)
                    Text("times").font(Theme.ui(13)).foregroundStyle(Theme.muted)
                    Spacer()
                    arrows
                }
                .padding(10)
                Hairline()
            }
            ForEach(Array($block.steps.enumerated()), id: \.element.id) { index, $step in
                if index > 0 { Hairline() }
                StepView(model: model, step: $step, trailing: {
                    if block.isRepeat {
                        Button { block.steps.removeAll { $0.id == step.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.dim)
                        .help("Remove this step")
                    } else {
                        arrows
                    }
                })
            }
            if block.isRepeat {
                Hairline()
                HStack {
                    Button("Add Step to Repeat") {
                        block.steps.append(.init(kind: .run, end: .time(seconds: 60), target: .zone("3")))
                    }
                    .themedButton(small: true)
                    Spacer()
                }
                .padding(10)
            }
        }
    }

    private var arrows: some View {
        HStack(spacing: 10) {
            iconButton("chevron.up", help: "Move up", action: moveUp)
            iconButton("chevron.down", help: "Move down", action: moveDown)
            iconButton("xmark", help: block.isRepeat ? "Remove this repeat" : "Remove this step", action: remove)
        }
    }

    private func iconButton(_ icon: String, help: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(action == nil ? Theme.border : Theme.dim)
        .disabled(action == nil)
        .help(help)
    }
}

private struct StepView<Trailing: View>: View {
    @ObservedObject var model: UploadModel
    @Binding var step: WorkoutDraft.Step
    @ViewBuilder let trailing: Trailing

    private var color: Color {
        switch step.kind {
        case .run: return Theme.accent
        case .rest: return Theme.mint
        case .warmup, .cooldown: return Theme.peach
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Tick(color: color)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Choice(title: step.kind.rawValue, options: WorkoutDraft.Step.Kind.allCases.map(\.rawValue)) {
                        if let kind = WorkoutDraft.Step.Kind(rawValue: $0) { step.kind = kind }
                    }
                    Choice(title: endTitle, options: ["Time", "Distance", "Until lap press"]) { setEnd($0) }
                    endField
                    Spacer(minLength: 0)
                    trailing
                }
                HStack(spacing: 8) {
                    Choice(title: targetTitle, options: ["No target"] + zones + ["Pace", "Heart rate"]) { setTarget($0) }
                    targetFields
                    Spacer(minLength: 0)
                }
                TextField("Note shown on the watch (optional)", text: $step.label)
                    .themedField()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
    }

    private var zones: [String] {
        model.settings.zones.map { "Zone \($0.zone)" }
    }

    private var endTitle: String {
        switch step.end {
        case .time: return "Time"
        case .distance: return "Distance"
        case .lap: return "Until lap press"
        }
    }

    private func setEnd(_ choice: String) {
        switch choice {
        case "Time": if case .time = step.end { return }; step.end = .time(seconds: 600)
        case "Distance": if case .distance = step.end { return }; step.end = .distance(miles: 1)
        default: step.end = .lap
        }
    }

    @ViewBuilder
    private var endField: some View {
        switch step.end {
        case .time(let seconds):
            TimeBox(seconds: Binding(get: { seconds }, set: { step.end = .time(seconds: $0) }))
            Text("min").font(Theme.ui(12)).foregroundStyle(Theme.muted)
        case .distance(let miles):
            NumberBox(value: Binding(get: { miles }, set: { step.end = .distance(miles: $0) }), width: 64)
            Text("mi").font(Theme.ui(12)).foregroundStyle(Theme.muted)
        case .lap:
            EmptyView()
        }
    }

    private var targetTitle: String {
        switch step.target {
        case .none: return "No target"
        case .zone(let zone): return "Zone \(zone)"
        case .pace: return "Pace"
        case .heartRate: return "Heart rate"
        }
    }

    private func setTarget(_ choice: String) {
        switch choice {
        case "No target":
            step.target = .none
        case "Pace":
            if case .pace = step.target { return }
            step.target = .pace(slowest: 600, fastest: 540)
        case "Heart rate":
            if case .heartRate = step.target { return }
            step.target = .heartRate(low: 130, high: 150)
        default:
            step.target = .zone(String(choice.dropFirst(5)))
        }
    }

    @ViewBuilder
    private var targetFields: some View {
        switch step.target {
        case .none:
            EmptyView()
        case .zone(let zone):
            if let text = model.bandText(zone: zone) {
                Text(text).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            } else {
                Text("Shown as a label").font(Theme.ui(12)).foregroundStyle(Theme.dim)
            }
        case .pace(let slowest, let fastest):
            TimeBox(seconds: Binding(get: { slowest }, set: { step.target = .pace(slowest: $0, fastest: fastest) }))
            Text("to").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            TimeBox(seconds: Binding(get: { fastest }, set: { step.target = .pace(slowest: slowest, fastest: $0) }))
            Text("/mi").font(Theme.ui(12)).foregroundStyle(Theme.muted)
        case .heartRate(let low, let high):
            NumberBox(value: Binding(get: { low }, set: { step.target = .heartRate(low: $0, high: high) }), width: 56)
            Text("to").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            NumberBox(value: Binding(get: { high }, set: { step.target = .heartRate(low: low, high: $0) }), width: 56)
            Text("bpm").font(Theme.ui(12)).foregroundStyle(Theme.muted)
        }
    }
}

/// A dropdown that matches the theme.
private struct Choice: View {
    let title: String
    let options: [String]
    let choose: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { choose(option) }
            }
        } label: {
            Text(title).font(Theme.ui(13, .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

/// Saves on each keystroke, and turns red until what's typed is a number.
private struct NumberBox<Value: LosslessStringConvertible & Equatable>: View {
    @Binding var value: Value
    let width: CGFloat
    @State private var text = ""

    private var parsed: Value? {
        Value(text.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .themedField()
            .foregroundStyle(parsed == nil ? Theme.problem : Theme.ink)
            .frame(width: width)
            .onAppear { text = value.description }
            .onChange(of: text) {
                if let parsed { value = parsed }
            }
            .onChange(of: value) {
                if parsed != value { text = value.description }
            }
    }
}

/// Minutes and seconds, like 10:00. Saves as it's typed.
private struct TimeBox: View {
    @Binding var seconds: Int
    @State private var text = ""

    private var parsed: Int? {
        ZoneTargets.seconds(fromPace: text)
    }

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .themedField()
            .foregroundStyle(parsed == nil ? Theme.problem : Theme.ink)
            .frame(width: 64)
            .onAppear { text = ZoneTargets.paceText(Double(seconds)) }
            .onChange(of: text) {
                if let parsed { seconds = parsed }
            }
            .onChange(of: seconds) {
                if parsed != seconds { text = ZoneTargets.paceText(Double(seconds)) }
            }
    }
}
