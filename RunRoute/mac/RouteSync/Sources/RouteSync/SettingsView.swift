import RouteCore
import SwiftUI

/// Every number RouteSync and the watch apps use. They're kept on the Mac, and go
/// to the watch with Send to Watch.
struct SettingsView: View {
    @ObservedObject var model: UploadModel

    var body: some View {
        Page(eyebrow: "Yours to set", title: "Settings.", watchConnected: model.isMounted, onEject: model.ejectWatch) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "This Mac")
                    Card {
                        HStack {
                            Text("Open RouteSync when the watch is plugged in")
                                .font(Theme.ui(14))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Toggle("", isOn: Binding(get: { model.opensWithWatch }, set: { model.setOpensWithWatch($0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(12)
                    }
                    caption("Changes right away. This also happens when you plug in just to charge.")

                    SectionTitle(title: "Threshold").padding(.top, 8)
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enforce zones by").font(Theme.ui(13, .medium)).foregroundStyle(Theme.muted)
                            EnforcementPicker(selection: $model.enforcement)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        Hairline()
                        textRow("Threshold pace", text: $model.thresholdPace, unit: "min/mile")
                        Hairline()
                        textRow("Threshold heart rate", text: $model.thresholdBpm, unit: "bpm")
                    }
                    caption("Threshold pace also sets intensity and load on the watch.")

                    group("Target alerts") {
                        field("zoneQuietSec")
                        Hairline()
                        field("zoneRepeatSec")
                        Hairline()
                        NumberRow(title: "Heart rate ignores steps under", unit: "s", value: $model.settings.shortestHeartRateSeconds)
                        Hairline()
                        NumberRow(title: "Heart rate ignores steps under", unit: "m", value: $model.settings.shortestHeartRateMetres)
                    }

                    group("You") {
                        field("weightLb")
                        Hairline()
                        field("maxHr")
                        Hairline()
                        field("vo2BaselinePct")
                    }

                    group("Condition labels") {
                        field("conditionFresh")
                        Hairline()
                        field("conditionNormal")
                        Hairline()
                        field("conditionTired")
                    }

                    group("Route alarms") {
                        field("routeOffFt")
                        Hairline()
                        field("routeBackFt")
                        Hairline()
                        field("routeDelaySec")
                        Hairline()
                        field("routeRepeatSec")
                        Hairline()
                        field("routeFinishFt")
                    }

                    SectionTitle(title: "Zones", note: "Percent of threshold").padding(.top, 8)
                    Card { zoneGrid.padding(12) }

                    SectionTitle(title: "Training on the watch").padding(.top, 8)
                    Card {
                        if model.training != nil {
                            decimal("Fitness", \.fitness)
                            Hairline()
                            decimal("Fatigue", \.fatigue)
                            Hairline()
                            decimal("Usual VO2max", \.vo2Baseline)
                        } else {
                            Text(model.isMounted ? "The watch hasn't saved any training yet."
                                                 : "Plug in the watch to see these.")
                                .font(Theme.ui(14))
                                .foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    if model.training != nil {
                        caption("Changing these sets them as of today.")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.settingsProblems, id: \.self) { problem in
                    Text(problem).font(Theme.ui(12)).foregroundStyle(Theme.problem)
                }
                HStack {
                    Button("Done") { model.cancel() }.themedButton()
                    Button("Reset to Defaults") { model.resetSettings() }.themedButton()
                    Spacer()
                    Button("Send to Watch") { model.sendSettings() }
                        .themedButton(primary: true)
                        .disabled(!model.settingsProblems.isEmpty)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title)
            Card { content() }
        }
        .padding(.top, 8)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.dim)
    }

    private func textRow(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(title).font(Theme.ui(14)).foregroundStyle(Theme.ink)
            Spacer()
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .themedField()
                .frame(width: 72)
            Text(unit).font(Theme.ui(12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func field(_ id: String) -> some View {
        let field = RunSettings.field(id)
        return NumberRow(title: field.title, unit: field.unit, value: Binding(
            get: { model.settings.value(id) },
            set: { model.settings.set(id, $0) }
        ))
    }

    private func decimal(_ title: String, _ path: WritableKeyPath<TrainingState, Double>) -> some View {
        NumberRow(title: title, unit: "", value: Binding(
            get: { model.training?[keyPath: path] ?? 0 },
            set: { model.training?[keyPath: path] = $0 }
        ))
    }

    private var zoneGrid: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Zone").gridColumnAlignment(.leading)
                Text("Heart rate from")
                Text("to")
                Text("Pace from")
                Text("to")
            }
            .font(Theme.ui(12))
            .foregroundStyle(Theme.muted)
            ForEach($model.settings.zones) { $zone in
                GridRow {
                    Text(zone.zone).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.accent)
                    NumberField(value: $zone.heartRateLow)
                    NumberField(value: $zone.heartRateHigh)
                    NumberField(value: $zone.paceLow)
                    NumberField(value: $zone.paceHigh)
                }
            }
        }
    }
}

private struct NumberRow<Value: LosslessStringConvertible & Equatable>: View {
    let title: String
    let unit: String
    @Binding var value: Value

    var body: some View {
        HStack {
            Text(title).font(Theme.ui(14)).foregroundStyle(Theme.ink)
            Spacer()
            NumberField(value: $value)
            Text(unit).font(Theme.ui(12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Saves on each keystroke, so clicking a button straight after typing can't lose
/// the number. Red until what's typed is a number.
private struct NumberField<Value: LosslessStringConvertible & Equatable>: View {
    @Binding var value: Value
    @State private var text = ""

    private var parsed: Value? {
        Value(text.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .themedField()
            .foregroundStyle(parsed == nil ? Theme.problem : Theme.ink)
            .frame(width: 72)
            .onAppear { text = value.description }
            .onChange(of: text) {
                if let parsed { value = parsed }
            }
            .onChange(of: value) {
                if parsed != value { text = value.description }
            }
    }
}
