import SwiftUI

/// The look of the Janie calendar: dark plum panels, warm cream text, pumpkin
/// orange actions, Georgia headings over Avenir Next.
enum Theme {
    static let background = Color(hex: 0x17141E)
    static let surface = Color(hex: 0x211D2A)
    static let surfaceAlt = Color(hex: 0x292231)
    static let hover = Color(hex: 0x382C40)
    static let border = Color(hex: 0x49384D)
    static let ink = Color(hex: 0xFFF1DC)
    static let muted = Color(hex: 0xC8B9CE)
    static let dim = Color(hex: 0xAB99B3)
    static let accent = Color(hex: 0xF5A45D)
    static let accentHover = Color(hex: 0xFFC58A)
    static let accentPressed = Color(hex: 0xD9843F)
    static let accentInk = Color(hex: 0x25170E)
    static let mint = Color(hex: 0x8CD6BE)
    static let peach = Color(hex: 0xF8A98C)
    static let problem = Color(hex: 0xF2938C)

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", size: size).weight(weight)
    }

    static func heading(_ size: CGFloat) -> Font {
        .custom("Georgia", size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Dark rounded buttons, or pumpkin orange for the main action.
struct ThemedButtonStyle: ButtonStyle {
    var primary = false
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, primary: primary, small: small, isEnabled: isEnabled)
    }

    private struct Styled: View {
        let configuration: Configuration
        let primary: Bool
        let small: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.ui(small ? 12 : 14, .semibold))
                .foregroundStyle(primary ? Theme.accentInk : Theme.ink)
                .padding(.horizontal, small ? 11 : 16)
                .padding(.vertical, small ? 5 : 9)
                .background(fill, in: RoundedRectangle(cornerRadius: small ? 8 : 11))
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: small ? 8 : 11).stroke(Theme.border, lineWidth: 1)
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: small ? 8 : 11))
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            if primary {
                return configuration.isPressed ? Theme.accentPressed : hovering ? Theme.accentHover : Theme.accent
            }
            return hovering || configuration.isPressed ? Theme.hover : Theme.surfaceAlt
        }
    }
}

extension View {
    func themedButton(primary: Bool = false, small: Bool = false) -> some View {
        buttonStyle(ThemedButtonStyle(primary: primary, small: small))
    }

    func themedField() -> some View {
        textFieldStyle(.plain)
            .font(Theme.ui(14))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

/// The small spaced-out line over a heading.
struct Eyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.ui(10.5, .medium))
            .tracking(2)
            .foregroundStyle(Theme.accent)
    }
}

/// A heading with an optional note at its right, like "This week  Nov 1-7".
struct SectionTitle: View {
    let title: String
    var note = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.heading(20)).foregroundStyle(Theme.ink)
            Spacer()
            Text(note).font(Theme.ui(12)).foregroundStyle(Theme.muted)
        }
    }
}

/// A panel of rows with hairlines between them.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 0.5)
    }
}

/// The coloured mark that starts a row.
struct Tick: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
    }
}

/// Every screen: the orange bar, a title and whether the watch is plugged in.
struct Page<Content: View, Footer: View>: View {
    let eyebrow: String
    let title: String
    let watchConnected: Bool
    /// Offers an Eject button while the watch is connected.
    var onEject: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(eyebrow)
                    Text(title).font(Theme.heading(32)).foregroundStyle(Theme.ink)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(watchConnected ? Theme.mint : Theme.dim).frame(width: 7, height: 7)
                    Text(watchConnected ? "Watch connected" : "Not plugged in")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 4)
                if watchConnected, let onEject {
                    Button(action: onEject) {
                        Label("Eject", systemImage: "eject.fill")
                    }
                    .themedButton(small: true)
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 14)

            content.frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
    }
}
