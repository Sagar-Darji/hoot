import SwiftUI

/// Hoot's design system. Everything Hoot shows grows out of the notch on one surface (like the Dynamic
/// Island), so a single set of colours, type, shapes and controls keeps every screen consistent.
enum Theme {
    // Surfaces
    static let surface = Color.black                         // the island where it meets the notch
    static let glassShade = Color.black.opacity(0.45)        // over the glass below it: readable on any background
    static let raised = Color.white.opacity(0.07)             // cards, fields, message bubbles
    static let raisedHover = Color.white.opacity(0.12)
    static let separator = Color.white.opacity(0.08)

    // Text
    static let text = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)

    // Meaning — used the same way everywhere
    static let you = Color(red: 0.30, green: 0.52, blue: 1.00)        // your voice, your lines, the accent
    static let others = Color(red: 1.00, green: 0.38, blue: 0.62)     // everyone else on the call
    static let record = Color(red: 1.00, green: 0.27, blue: 0.23)     // recording, and nothing else
    static let success = Color(red: 0.20, green: 0.80, blue: 0.42)
    static let warning = Color(red: 1.00, green: 0.66, blue: 0.20)

    // Shape
    static let radiusSmall: CGFloat = 8
    static let radius: CGFloat = 12
    static let radiusLarge: CGFloat = 18
    static let islandRadius: CGFloat = 30
    static let control: CGFloat = 30                         // height of buttons and tabs

    // Motion
    /// `HOOT_SLOWMO=10` slows the island's animations down tenfold, to check every frame of them.
    static let slowMotion = Double(ProcessInfo.processInfo.environment["HOOT_SLOWMO"] ?? "") ?? 1
    static let spring = Animation.spring(response: 0.34 * slowMotion, dampingFraction: 0.8)
    static let quick = Animation.snappy(duration: 0.2)

    // Type
    enum Font {
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let clock = SwiftUI.Font.system(size: 13, weight: .semibold).monospacedDigit()
    }
}

// MARK: - Building blocks

/// Hover state for the small controls below (SwiftUI's @State macro isn't available without Xcode's
/// macro plugins, so view-local state lives in tiny objects).
final class HoverFlag: ObservableObject { @Published var on = false }

extension View {
    /// A raised card on the island.
    func themeCard(padding: CGFloat = 14, radius: CGFloat = Theme.radius) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.raised))
    }
}

/// A round icon button.
struct ThemeIconButton: View {
    let symbol: String
    let help: String
    var badge = false
    var size: CGFloat = Theme.control
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(hover.on ? Theme.raisedHover : Theme.raised))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(Theme.you).frame(width: 8, height: 8).offset(x: -1, y: 1) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A capsule button. `.record` and `.stop` are the only red things in Hoot.
struct ThemeButton: View {
    enum Role { case primary, secondary, record, stop }
    let title: String
    var symbol: String? = nil
    var role: Role = .secondary
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(symbolColour)
                }
                Text(title).font(Theme.Font.headline).foregroundStyle(textColour)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.control)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }

    private var fill: Color {
        switch role {
        case .primary: return hover.on ? Color.white.opacity(0.88) : .white
        case .record: return hover.on ? Color.white.opacity(0.88) : .white
        case .stop: return hover.on ? Theme.record.opacity(0.85) : Theme.record
        case .secondary: return hover.on ? Theme.raisedHover : Theme.raised
        }
    }
    private var textColour: Color { role == .primary || role == .record ? .black : Theme.text }
    private var symbolColour: Color {
        switch role {
        case .record: return Theme.record
        case .primary: return .black
        default: return Theme.text
        }
    }
}

/// An on/off switch in Hoot's colours. The system switch turns grey in a window that isn't active —
/// and the island never makes Hoot the active app — so on and off would look nearly the same.
struct ThemeSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(Theme.quick) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? Theme.you : Theme.raisedHover)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// Segmented control: a quiet track with the selected item as a white capsule.
struct ThemeSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String?, symbol: String?)]
    var badge: Value? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button { withAnimation(Theme.quick) { selection = item.value } } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        if let title = item.title { Text(title).font(Theme.Font.headline).lineLimit(1) }
                    }
                    .foregroundStyle(selected ? Color.black : Theme.secondary)
                    .padding(.horizontal, item.title == nil ? 9 : 12)
                    .frame(height: Theme.control - 4)
                    .background { if selected { Capsule().fill(.white) } }
                    .overlay(alignment: .topTrailing) {
                        if badge == item.value && !selected {
                            Circle().fill(Theme.you).frame(width: 7, height: 7).offset(x: -2, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.title ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.raised))
    }
}

/// Small grey section heading.
struct ThemeSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// An "empty" message in the middle of a pane.
struct ThemeEmpty: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(Theme.tertiary)
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.text)
            Text(message).font(Theme.Font.callout).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
