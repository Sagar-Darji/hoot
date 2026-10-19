import SwiftUI

/// Scrolls text up by itself while you present. Hovering over it pauses, so you can catch up or reread.
final class PrompterState: ObservableObject {
    @Published var playing = false
    @Published var hovering = false
    @Published var speed: Double = UserDefaults.standard.object(forKey: "prompterSpeed") as? Double ?? 28 {
        didSet { UserDefaults.standard.set(speed, forKey: "prompterSpeed") }
    }
    private(set) var offset: CGFloat = 0
    private var lastTick: Date?

    func advance(to now: Date, limit: CGFloat) -> CGFloat {
        if playing && !hovering, let last = lastTick {
            offset = min(limit, offset + CGFloat(now.timeIntervalSince(last) * speed))
        }
        lastTick = now
        return offset
    }

    func nudge(_ delta: CGFloat, limit: CGFloat) { offset = max(0, min(limit, offset + delta)) }
    func restart() { offset = 0; lastTick = nil }
}

struct TeleprompterView: View {
    let text: String
    let fontSize: CGFloat
    @ObservedObject var state: PrompterState

    @StateObject private var measured = HeightBox()

    var body: some View {
        GeometryReader { geo in
            let limit = max(0, measured.height - geo.size.height * 0.4)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !state.playing || state.hovering)) { context in
                Text(text.isEmpty ? "Nothing to read yet — write your notes or link a doc first." : text)
                    .font(.system(size: fontSize * 1.25, weight: .medium))
                    .lineSpacing(fontSize * 0.45)
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .frame(width: geo.size.width - 40, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in Color.clear.onAppear { measured.height = g.size.height }
                        .onChange(of: g.size.height) { _, h in measured.height = h } })
                    .padding(.horizontal, 20)
                    .padding(.top, geo.size.height * 0.35)     // start reading near the top third, like a prompter
                    .offset(y: -state.advance(to: context.date, limit: limit))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            // A reading line at eye level.
            .overlay(alignment: .top) {
                Rectangle().fill(Color.accentColor.opacity(0.35)).frame(height: 2)
                    .padding(.top, geo.size.height * 0.35 - 6)
            }
            .overlay(alignment: .bottom) {
                if state.hovering && state.playing {
                    Label("Paused while hovering", systemImage: "pause.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glass(in: Capsule())
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
            .onHover { state.hovering = $0 }
            .onScrollWheel { delta in state.nudge(-delta, limit: limit) }
        }
    }
}

final class HeightBox: ObservableObject { @Published var height: CGFloat = 0 }

/// Lets the trackpad/mouse wheel move the prompter by hand.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) { onScroll?(event.scrollingDeltaY) }
    }
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onScroll = onScroll; return v }
    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onScroll = onScroll }
}

extension View {
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        overlay(ScrollWheelCatcher(onScroll: action))
    }
}
