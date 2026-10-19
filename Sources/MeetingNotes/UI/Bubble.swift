import AppKit
import SwiftUI

/// The floating bubble (used on Macs without a notch, or when the island is turned off): the glass
/// crane is the record button; the label beside it opens the window. Drag anywhere to move it.
struct BubbleView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    @ObservedObject var updates: UpdateChecker
    let actions: OverlayActions
    let onResize: (CGSize) -> Void

    @StateObject private var ui = OverlayUIState(windowTitle: "bubble")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassSpace

    private var expanded: Bool {
        recorder.state != .idle || ui.hovering || ui.peeking || recorder.justSaved || recorder.modelDownload != nil
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) { liquidBody } else { classicBody }
        }
        .onHover { ui.setHovering($0) }
        .onChange(of: recorder.status) { _, status in if status != nil { ui.peek(seconds: 8) } }
        .onChange(of: assist.hasUnseen) { _, unseen in if unseen { ui.peek() } }
        .onChange(of: recorder.callHint) { _, hint in if hint != nil { ui.peek(seconds: 12) } }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: expanded)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: recorder.state)
        .gesture(drag)
        .contextMenu { HootMenuItems(recorder: recorder, updates: updates, actions: actions) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hoot")
        .padding(10)   // room for the glass shadow
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onResize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Liquid Glass: the crane and the label are separate drops of glass; the label flows out of the
    /// crane when the bubble opens and melts back into it when it closes.
    @available(macOS 26.0, *)
    private var liquidBody: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 6) {
                orb
                    .padding(5)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("orb", in: glassSpace)
                if expanded {
                    labels
                        .padding(.leading, 14).padding(.trailing, 12)
                        .frame(height: 42)
                        .contentShape(Capsule())
                        .onTapGesture(perform: actions.togglePanel)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("labels", in: glassSpace)
                        .help("Show transcript, notes and AI")
                }
            }
        }
    }

    /// Before macOS 26: one frosted capsule.
    private var classicBody: some View {
        HStack(spacing: 10) {
            orb
            if expanded {
                labels
                    .contentShape(Rectangle())
                    .onTapGesture(perform: actions.togglePanel)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, expanded ? 12 : 5)
        .padding(.vertical, 5)
        .glass(in: Capsule(), interactive: true)
    }

    private var orb: some View {
        HootOrb(mood: HootStatus.mood(recorder), meter: recorder.meter, glow: assist.hasUnseen || assist.asking)
            .scaleEffect(ui.hovering && recorder.state == .idle ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ui.hovering)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .onTapGesture { recorder.toggle() }
            .overlay(alignment: .topTrailing) {
                // Collapsed reminders: orange = a message to read, blue = something new.
                if !expanded, HootStatus.needsAttention(recorder, assist) {
                    Circle()
                        .fill(recorder.status != nil ? Color.orange : Color(nsColor: .systemBlue))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            .help(recorder.isRecording ? "Stop recording (\(HotKeys.record.label))" : "Start recording (\(HotKeys.record.label))")
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            .accessibilityAddTraits(.isButton)
    }

    private var labels: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if recorder.state == .recording {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in Text(HootStatus.title(recorder)) }
                    } else {
                        Text(HootStatus.title(recorder))
                    }
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(HootStatus.caption(recorder, assist, updates: updates, liveCaption: false))
                    .font(.system(size: 11))
                    .foregroundStyle(recorder.status != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .frame(maxWidth: 230, alignment: .leading)
            }
            Image(systemName: "chevron.down.circle.fill")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .overlay(alignment: .topTrailing) {
                    if assist.hasUnseen {
                        Circle().fill(Color(nsColor: .systemBlue)).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
        }
    }

    /// Drag anywhere on the bubble to move it; a click without movement still works as a tap.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                guard let window = NSApp.windows.first(where: { $0 is FloatingPanel && $0.title == "bubble" }) else { return }
                let mouse = NSEvent.mouseLocation
                if ui.dragStartMouse == nil {
                    ui.dragStartMouse = mouse
                    ui.dragStartOrigin = window.frame.origin
                }
                guard let m0 = ui.dragStartMouse, let o0 = ui.dragStartOrigin else { return }
                window.setFrameOrigin(NSPoint(x: o0.x + mouse.x - m0.x, y: o0.y + mouse.y - m0.y))
            }
            .onEnded { _ in
                ui.dragStartMouse = nil
                ui.dragStartOrigin = nil
                (NSApp.windows.first { $0 is FloatingPanel && $0.title == "bubble" } as? FloatingPanel)?.keepOnScreen()
            }
    }
}
