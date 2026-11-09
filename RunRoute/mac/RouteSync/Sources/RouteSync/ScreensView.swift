import RouteCore
import SwiftUI

/// The screen builder: which screens RunRoute pages through during a run, and the
/// fields on each. Workout and interval screens still come first in those runs.
struct ScreensView: View {
    @ObservedObject var model: UploadModel
    @State private var selected: UUID?

    private var selectedIndex: Int? {
        model.screens.screens.firstIndex { $0.id == selected } ?? (model.screens.screens.isEmpty ? nil : 0)
    }

    var body: some View {
        Page(eyebrow: "RunRoute", title: "Run screens.", watchConnected: model.isMounted, onEject: model.ejectWatch) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 8) {
                        if let index = selectedIndex {
                            WatchPreview(screen: model.screens.screens[index])
                                .frame(width: 180, height: 180)
                            HStack(spacing: 10) {
                                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                                    .themedButton(small: true)
                                Text("\(index + 1) of \(model.screens.screens.count)")
                                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                                Button { step(1) } label: { Image(systemName: "chevron.right") }
                                    .themedButton(small: true)
                            }
                        } else {
                            Circle().fill(Color.black).frame(width: 180, height: 180)
                        }
                    }
                    if let index = selectedIndex {
                        editor(index)
                    }
                }
                .padding(.horizontal, 24)

                SectionTitle(title: "Screens", note: "In order. Workouts add theirs first.")
                    .padding(.horizontal, 24)
                ScrollView {
                    Card {
                        ForEach(Array(model.screens.screens.enumerated()), id: \.element.id) { index, screen in
                            if index > 0 { Hairline() }
                            row(index, screen)
                        }
                    }
                    .padding(.horizontal, 24)
                    Button {
                        add()
                    } label: {
                        Label("Add Screen", systemImage: "plus")
                    }
                    .themedButton(small: true)
                    .disabled(model.screens.screens.count >= ScreenLayout.maxScreens)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.screens.problems, id: \.self) { problem in
                    Text(problem).font(Theme.ui(12)).foregroundStyle(Theme.problem)
                }
                HStack {
                    Button("Done") { model.cancel() }.themedButton()
                    Menu("Start From") {
                        Button("RunRoute's Defaults") { model.resetScreens(); selected = nil }
                        Button("What's on the Watch") {
                            if let current = model.screensOnWatch { model.screens = current; selected = nil }
                        }
                        .disabled(model.screensOnWatch == nil)
                    }
                    .menuStyle(.button)
                    .themedButton()
                    .fixedSize()
                    Spacer()
                    Button("Send to Watch") { model.sendScreens() }
                        .themedButton(primary: true)
                        .disabled(!model.screens.problems.isEmpty)
                }
            }
        }
    }

    // MARK: The selected screen

    private func editor(_ index: Int) -> some View {
        let screen = $model.screens.screens[index]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Screen \(index + 1)").font(Theme.ui(13, .medium)).foregroundStyle(Theme.muted)
            Picker("", selection: Binding(
                get: { screen.wrappedValue.kind },
                set: { kind in
                    screen.wrappedValue.kind = kind
                    if kind == .data, screen.wrappedValue.fields.isEmpty { screen.wrappedValue.setFieldCount(3) }
                }
            )) {
                ForEach(ScreenLayout.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 220)

            if screen.wrappedValue.kind == .data {
                Picker("", selection: Binding(
                    get: { screen.wrappedValue.fields.count },
                    set: { screen.wrappedValue.setFieldCount($0) }
                )) {
                    ForEach(1...ScreenLayout.maxFields, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                ForEach(screen.wrappedValue.fields.indices, id: \.self) { slot in
                    HStack(spacing: 8) {
                        Text(slotName(slot, of: screen.wrappedValue.fields.count))
                            .font(Theme.ui(12)).foregroundStyle(Theme.dim)
                            .frame(width: 52, alignment: .leading)
                        fieldPicker(Binding(
                            get: { screen.wrappedValue.fields[slot] },
                            set: { screen.wrappedValue.fields[slot] = $0 }
                        ))
                    }
                }
            } else {
                Text(note(screen.wrappedValue.kind))
                    .font(Theme.ui(12)).foregroundStyle(Theme.dim)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fieldPicker(_ key: Binding<String>) -> some View {
        Picker("", selection: key) {
            ForEach(ScreenLayout.groups, id: \.self) { group in
                Section(group) {
                    ForEach(ScreenLayout.fields.filter { $0.group == group }) { Text($0.title).tag($0.key) }
                }
            }
        }
        .labelsHidden()
        .frame(width: 160)
    }

    private func slotName(_ slot: Int, of count: Int) -> String {
        switch (count, slot) {
        case (1, _): "Field"
        case (_, 0): "Top"
        case (4, 1): "Left"
        case (4, 2): "Right"
        case (_, count - 1): "Bottom"
        default: "Middle"
        }
    }

    private func note(_ kind: ScreenLayout.Kind) -> String {
        switch kind {
        case .data: ""
        case .route: "The route ahead, and how far is left. Comes up by itself when you go off course."
        case .condition: "Performance condition against your usual VO2max, and intensity so far."
        case .status: "GPS and heart rate sensors, the time and the battery."
        }
    }

    // MARK: The list

    private func row(_ index: Int, _ screen: ScreenLayout.Screen) -> some View {
        let isSelected = index == selectedIndex
        return HStack(spacing: 10) {
            Tick(color: isSelected ? Theme.accent : .clear).frame(height: 22)
            Text("\(index + 1)").font(Theme.ui(14, .semibold)).foregroundStyle(Theme.accent).frame(width: 16)
            Text(summary(screen)).font(Theme.ui(14)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                .themedButton(small: true).disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                .themedButton(small: true).disabled(index == model.screens.screens.count - 1)
            Button { duplicate(index) } label: { Image(systemName: "plus.square.on.square") }
                .themedButton(small: true)
                .disabled(model.screens.screens.count >= ScreenLayout.maxScreens)
                .help("Duplicate")
            Button { remove(index) } label: { Image(systemName: "trash") }
                .themedButton(small: true).disabled(model.screens.screens.count == 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Theme.surfaceAlt : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = screen.id }
    }

    private func summary(_ screen: ScreenLayout.Screen) -> String {
        guard screen.kind == .data else { return screen.kind.title }
        return screen.fields.map { ScreenLayout.field($0)?.title ?? $0 }.joined(separator: " · ")
    }

    private func step(_ by: Int) {
        guard let index = selectedIndex else { return }
        let count = model.screens.screens.count
        selected = model.screens.screens[(index + by + count) % count].id
    }

    private func add() {
        var screen = ScreenLayout.Screen(kind: .data)
        screen.setFieldCount(3)
        let at = (selectedIndex ?? model.screens.screens.count - 1) + 1
        model.screens.screens.insert(screen, at: at)
        selected = screen.id
    }

    private func duplicate(_ index: Int) {
        var copy = model.screens.screens[index]
        copy.id = UUID()
        model.screens.screens.insert(copy, at: index + 1)
        selected = copy.id
    }

    private func move(_ index: Int, by: Int) {
        model.screens.screens.swapAt(index, index + by)
    }

    private func remove(_ index: Int) {
        let wasSelected = index == selectedIndex
        model.screens.screens.remove(at: index)
        if wasSelected {
            selected = model.screens.screens[min(index, model.screens.screens.count - 1)].id
        }
    }
}

/// A screen as the watch draws it, from the slot places in DataFace.cpp, on a
/// 240-point round face scaled to fit.
struct WatchPreview: View {
    let screen: ScreenLayout.Screen

    private static let teal = Color(red: 0, green: 0.6, blue: 0.6)

    /// A value: its centre, top and width at the largest font, and that font's size.
    private struct Slot {
        let x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat
        let captionY: CGFloat, captionWidth: CGFloat
    }

    private var slots: [Slot] {
        switch screen.fields.count {
        case 1: [Slot(x: 120, top: 76, width: 210, size: 60, captionY: 50, captionWidth: 200)]
        case 2: [Slot(x: 120, top: 48, width: 190, size: 60, captionY: 26, captionWidth: 160),
                 Slot(x: 120, top: 142, width: 190, size: 40, captionY: 198, captionWidth: 140)]
        case 3: [Slot(x: 120, top: 30, width: 200, size: 40, captionY: 8, captionWidth: 140),
                 Slot(x: 120, top: 111, width: 180, size: 35, captionY: 86, captionWidth: 200),
                 Slot(x: 120, top: 162, width: 170, size: 35, captionY: 204, captionWidth: 150)]
        default: [Slot(x: 120, top: 30, width: 200, size: 40, captionY: 8, captionWidth: 140),
                  Slot(x: 68, top: 111, width: 100, size: 30, captionY: 86, captionWidth: 104),
                  Slot(x: 172, top: 111, width: 100, size: 30, captionY: 86, captionWidth: 104),
                  Slot(x: 120, top: 162, width: 170, size: 35, captionY: 204, captionWidth: 150)]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 240
            ZStack(alignment: .topLeading) {
                Circle().fill(Color.black)
                Group {
                    switch screen.kind {
                    case .data: data
                    case .route: route
                    case .condition: condition
                    case .status: status
                    }
                }
                .frame(width: 240, height: 240, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 240 * scale, height: 240 * scale, alignment: .topLeading)
            }
            .frame(width: 240 * scale, height: 240 * scale)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.border, lineWidth: 2))
        }
    }

    private var data: some View {
        let fields = screen.fields
        let arc = fields.count >= 3 && fields.first == "hr"
        return ZStack(alignment: .topLeading) {
            if arc { zoneArc }
            if fields.count >= 2 { line(y: fields.count == 2 ? 136 : 79) }
            if fields.count >= 3 { line(y: 159) }
            if fields.count == 4 {
                Rectangle().fill(Self.teal).frame(width: 3, height: 60).offset(x: 119, y: 92)
            }
            ForEach(Array(zip(fields.indices, slots)), id: \.0) { index, slot in
                let key = fields[index]
                let sample = ScreenLayout.field(key)?.sample ?? "---"
                Text(sample)
                    .font(.system(size: slot.size, weight: .semibold))
                    .foregroundStyle(key == "hrZone" ? Color.yellow : key == "condition" ? Color.green : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(width: slot.width, height: slot.size * 1.4)
                    .offset(x: slot.x - slot.width / 2, y: slot.top)
                if arc && index == 0 {
                    caption(ScreenLayout.caption(key)).offset(x: 168, y: slot.top + 20)
                } else {
                    caption(ScreenLayout.caption(key))
                        .frame(width: slot.captionWidth)
                        .offset(x: slot.x - slot.captionWidth / 2, y: slot.captionY)
                }
            }
        }
    }

    private var zoneArc: some View {
        let colors: [Color] = [.gray, Color(red: 0.5, green: 1, blue: 0), .yellow, .orange, .red]
        return ZStack {
            ForEach(0..<5, id: \.self) { zone in
                let start = Double(-64 + zone * 26)
                Circle()
                    .trim(from: (start + 270) / 360, to: (start + 24 + 270) / 360)
                    .stroke(colors[zone], style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 226, height: 226)
            }
        }
        .offset(x: 7, y: 7)
    }

    private var route: some View {
        ZStack(alignment: .topLeading) {
            Text("1.84 mi left").font(.system(size: 18)).frame(width: 240).offset(y: 30).foregroundStyle(.white)
            Path { path in
                path.move(to: CGPoint(x: 120, y: 180))
                path.addCurve(to: CGPoint(x: 150, y: 60), control1: CGPoint(x: 110, y: 130), control2: CGPoint(x: 170, y: 110))
            }
            .stroke(Color.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Circle().fill(Color.cyan).frame(width: 14, height: 14).offset(x: 113, y: 173)
        }
    }

    private var condition: some View {
        ZStack(alignment: .topLeading) {
            caption("Condition").frame(width: 240).offset(y: 40)
            Text("+2").font(.system(size: 60, weight: .semibold)).foregroundStyle(.white).frame(width: 240).offset(y: 66)
            line(y: 150)
            Text("Normal").font(.system(size: 25, weight: .medium)).foregroundStyle(.white).frame(width: 240).offset(y: 158)
            caption("Intensity 0.82").frame(width: 240).offset(y: 194)
        }
    }

    private var status: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                Image(systemName: "location.fill")
                Image(systemName: "heart.fill")
            }
            .font(.system(size: 16)).foregroundStyle(Theme.mint).frame(width: 240).offset(y: 22)
            line(y: 62)
            Text("7:41").font(.system(size: 60, weight: .semibold)).foregroundStyle(.white).frame(width: 240).offset(y: 63)
            line(y: 136)
            Image(systemName: "battery.75percent").font(.system(size: 28)).foregroundStyle(.white).frame(width: 240).offset(y: 150)
            Text("84%").font(.system(size: 25, weight: .medium)).foregroundStyle(.white).frame(width: 240).offset(y: 187)
        }
    }

    private func line(y: CGFloat) -> some View {
        Capsule().fill(Self.teal).frame(width: 170, height: 3).offset(x: 35, y: y)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 18).italic()).foregroundStyle(.white).lineLimit(1)
    }
}
