import AppKit
import SwiftUI

/// The camera notch on recent MacBooks, in global screen coordinates.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notch: CGRect

    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let width = screen.frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            guard width > 40, height > 10 else { continue }
            return NotchGeometry(screenFrame: screen.frame,
                                 notch: CGRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height,
                                               width: width, height: height))
        }
        return nil
    }
}

/// The island's outline: flush with the top of the screen, with small inward-curving shoulders where it
/// meets the bezel (like the notch itself) and rounded bottom corners.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let f = shoulder
        let r = min(bottomRadius, rect.height - f, (rect.width - 2 * f) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Hoot as a Dynamic Island around the MacBook's notch.
/// - idle: invisible (just the notch); something new adds a small glowing dot,
/// - recording: widens around the notch — glass crane and timer on the left, live voice bars on the right,
/// - hover (or anything that needs you): drops down with a live caption, Record/Stop and quick buttons.
struct IslandView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    @ObservedObject var updates: UpdateChecker
    let notch: CGSize
    let actions: OverlayActions
    let onResize: (CGSize) -> Void
    var forceOpen = false            // for rendering the open state in product images

    @StateObject private var ui = OverlayUIState(windowTitle: "island")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mode: Equatable { case compact, alert, live, open }

    private var mode: Mode {
        if forceOpen || ui.hovering || ui.peeking || recorder.justSaved { return .open }
        if recorder.state != .idle { return .live }
        if HootStatus.needsAttention(recorder, assist) || recorder.modelDownload != nil { return .alert }
        return .compact
    }

    private let shoulder: CGFloat = 6

    /// The black body (shoulders excluded). Always at least as big as the notch so none of it peeks out.
    private var bodySize: CGSize {
        let h = notch.height + 1
        switch mode {
        case .compact: return CGSize(width: notch.width + 2, height: h)
        case .alert: return CGSize(width: notch.width + 56, height: h)
        case .live: return CGSize(width: notch.width + 176, height: h)
        case .open: return CGSize(width: max(notch.width + 260, 470), height: h + 92)
        }
    }

    var body: some View {
        let size = bodySize
        let radius: CGFloat = mode == .open ? 26 : 11
        ZStack(alignment: .top) {
            IslandShape(bottomRadius: radius, shoulder: shoulder).fill(Color.black)
            VStack(spacing: 0) {
                topRow.frame(height: notch.height)
                if mode == .open {
                    openContent.transition(.opacity.combined(with: .offset(y: -8)))
                }
            }
            .padding(.horizontal, shoulder + (mode == .open ? 20 : 12))
        }
        .frame(width: size.width + 2 * shoulder, height: size.height)
        .clipShape(IslandShape(bottomRadius: radius, shoulder: shoulder))
        .contentShape(IslandShape(bottomRadius: radius, shoulder: shoulder))
        .shadow(color: .black.opacity(mode == .open ? 0.35 : 0), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
        .onHover { ui.setHovering($0) }
        .onChange(of: recorder.status) { _, status in if status != nil { ui.peek(seconds: 8) } }
        .onChange(of: assist.hasUnseen) { _, unseen in if unseen { ui.peek() } }
        .onChange(of: recorder.callHint) { _, hint in if hint != nil { ui.peek(seconds: 12) } }
        .contextMenu { HootMenuItems(recorder: recorder, updates: updates, actions: actions) }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hoot")
        // Room for the drop shadow only while open, so the island never covers menu bar items beside the notch.
        .padding(.horizontal, mode == .open ? 24 : 0)
        .padding(.bottom, mode == .open ? 30 : 0)
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onResize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Row beside the notch

    @ViewBuilder private var topRow: some View {
        HStack(spacing: 8) {
            switch mode {
            case .compact:
                Spacer(minLength: 0)
            case .alert:
                Spacer(minLength: notch.width)
                Circle()
                    .fill(recorder.status != nil ? Color.orange : (recorder.modelDownload != nil ? Color.white.opacity(0.6) : HootMark.you))
                    .frame(width: 8, height: 8)
                    .shadow(color: HootMark.you.opacity(0.9), radius: 5)
            case .live, .open:
                crane(size: mode == .open ? 24 : 20)
                if recorder.state == .recording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(HootStatus.title(recorder))
                    }
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                } else if mode == .open {
                    Text(HootStatus.title(recorder))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: notch.width)
                if recorder.state == .recording {
                    IslandWaveform(meter: recorder.meter)
                } else if recorder.state != .idle {
                    ProgressView().controlSize(.small)
                } else if mode == .open {
                    statusChip
                }
            }
        }
    }

    private var statusChip: some View {
        let (text, colour): (String, Color) = {
            if recorder.callHint != nil { return ("Call", HootMark.you) }
            if recorder.justSaved { return ("Saved", Color(nsColor: .systemGreen)) }
            if recorder.modelDownload != nil { return ("Setting up", .white.opacity(0.6)) }
            return ("Ready", .white.opacity(0.55))
        }()
        return HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
        }
    }

    private func crane(size: CGFloat) -> some View {
        HootOrb(mood: HootStatus.mood(recorder), meter: recorder.meter, glow: false, size: size)
            .contentShape(Rectangle())
            .onTapGesture { recorder.toggle() }
            .help(recorder.isRecording ? "Stop recording (\(HotKeys.record.label))" : "Start recording (\(HotKeys.record.label))")
    }

    // MARK: Dropped-down content

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HootStatus.caption(recorder, assist, updates: updates, liveCaption: true))
                .font(.system(size: 13))
                .foregroundStyle(recorder.status != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.white.opacity(0.82)))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                recordButton
                Spacer()
                roundButton("text.bubble", "Transcript (\(HotKeys.transcript.label))", action: actions.toggleTranscript)
                roundButton("list.bullet.clipboard", "Speaker Notes (\(HotKeys.notes.label))", action: actions.toggleNotes)
                roundButton("sparkles", "AI Assist (\(HotKeys.assist.label))", badge: assist.hasUnseen, action: actions.toggleAssist)
                Menu {
                    HootMenuItems(recorder: recorder, updates: updates, actions: actions)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var recordButton: some View {
        let recording = recorder.isRecording
        return Button { recorder.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: recording ? "stop.fill" : "circle.fill")
                    .font(.system(size: recording ? 10 : 11, weight: .bold))
                    .foregroundStyle(recording ? .white : Color(nsColor: .systemRed))
                Text(recording ? "Stop" : "Record")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recording ? .white : .black)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(recording ? Color(nsColor: .systemRed) : .white))
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .starting || recorder.state == .finishing)
        .keyboardShortcut("r", modifiers: [.control, .option])
        .help(recording ? "Stop and save (\(HotKeys.record.label))" : "Start taking notes (\(HotKeys.record.label))")
    }

    private func roundButton(_ symbol: String, _ help: String, badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(HootMark.you).frame(width: 8, height: 8).offset(x: -1, y: 1) }
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Live voice bars: three for you (blue), three for the others (pink).
struct IslandWaveform: View {
    @ObservedObject var meter: LiveMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<6, id: \.self) { i in
                    let mine = i < 3
                    let level = CGFloat(mine ? meter.me : meter.them)
                    let wobble = reduceMotion ? 1 : 0.55 + 0.45 * abs(sin(t * 8 + Double(i) * 1.3))
                    Capsule()
                        .fill(mine ? HootMark.you : HootMark.others)
                        .frame(width: 3, height: 4 + 14 * level * CGFloat(wobble))
                }
            }
            .frame(height: 18)
        }
        .accessibilityHidden(true)
    }
}
