import SwiftUI

/// Which part of Hoot's one window is showing.
final class PanelNav: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case transcript, notes, assist
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: return "Transcript"
            case .notes: return "Notes"
            case .assist: return "AI"
            }
        }
        var symbol: String {
            switch self {
            case .transcript: return "text.bubble"
            case .notes: return "list.bullet.clipboard"
            case .assist: return "sparkles"
            }
        }
    }

    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "panelTab") ?? "") ?? .transcript {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "panelTab") }
    }
}

/// Hoot's single window: Transcript · Notes · AI, switched from the toolbar like Apple's own apps.
struct HootPanelView: View {
    @ObservedObject var nav: PanelNav
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    let notes: SpeakerNotes

    var body: some View {
        Group {
            switch nav.tab {
            case .transcript: TranscriptView(recorder: recorder)
            case .notes: SpeakerNotesView(notes: notes)
            case .assist: AssistView(assist: assist, recorder: recorder, notes: notes)
            }
        }
        .frame(minWidth: 340, minHeight: 260)
        .windowGlass()
        // Siri-style glow around the window while Apple Intelligence is answering.
        .overlay { SiriEdgeGlow(active: assist.asking, cornerRadius: 16).ignoresSafeArea() }
        .animation(.easeInOut(duration: 0.4), value: assist.asking)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TabBar(selection: $nav.tab, badge: assist.hasUnseen ? .assist : nil)
                    .help("Hidden from screen sharing — only you can see this window")
            }
        }
        .modifier(HideWindowTitle())
        .onChange(of: nav.tab) { _, tab in if tab == .assist { assist.hasUnseen = false } }
    }
}

/// The tabs replace the title, like Apple's single-window utilities.
private struct HideWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Hoot's section switcher. Custom-drawn so it stays crisp while you're typing in your meeting app
/// (system segmented controls grey out whenever the window isn't focused, which Hoot's never steals).
struct TabBar: View {
    @Binding var selection: PanelNav.Tab
    var badge: PanelNav.Tab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelNav.Tab.allCases) { tab in
                let selected = tab == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = tab } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                        Text(tab.title).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background { if selected { Capsule().fill(Color.accentColor) } }
                    .overlay(alignment: .topTrailing) {
                        if badge == tab && !selected {
                            Circle().fill(Color(nsColor: .systemBlue)).frame(width: 7, height: 7).offset(x: -2, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

/// A small always-crisp segmented control in the same style as `TabBar`.
struct PillSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String?, symbol: String?)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = item.value } } label: {
                    HStack(spacing: 4) {
                        if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        if let title = item.title { Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1) }
                    }
                    .padding(.horizontal, item.title == nil ? 7 : 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .background { if selected { Capsule().fill(.primary.opacity(0.14)) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.title ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.06)))
    }
}
