import AppKit
import SwiftUI

/// Where the island sits: around the MacBook's camera notch, or — on displays without one — a
/// "virtual notch" of the same shape at the top centre, so Hoot looks and works the same on every Mac.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notch: CGRect
    let hardware: Bool

    /// The built-in display's notch if there is one, otherwise a virtual notch on the main display.
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let width = screen.frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            guard width > 40, height > 10 else { continue }
            return NotchGeometry(screenFrame: screen.frame,
                                 notch: CGRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height,
                                               width: width, height: height),
                                 hardware: true)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat = 190
        return NotchGeometry(screenFrame: screen.frame,
                             notch: CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
                             hardware: false)
    }
}

/// The island's outline: flush with the top of the screen, small inward-curving shoulders where it meets
/// the bezel (like the notch itself), rounded bottom corners.
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

/// What the island is showing. Everything opens inside the island — Hoot has no other windows.
@MainActor
final class IslandModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case transcript, notes, assist, settings
    }

    /// nil: collapsed. Otherwise the island is open as a panel on this tab.
    @Published private(set) var tab: Tab?
    @Published var hovering = false
    @Published var peeking = false            // briefly opens the controls to announce something
    /// Keep the panel open when clicking elsewhere (e.g. reading notes while presenting).
    @Published var pinned = UserDefaults.standard.bool(forKey: "islandPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "islandPinned") }
    }
    @Published var welcome = false            // first run: Settings opens as a welcome checklist

    private var lastTab = Tab(rawValue: UserDefaults.standard.string(forKey: "islandTab") ?? "") ?? .transcript
    private var exitWatch: Timer?
    private var peekWork: DispatchWorkItem?

    var isOpen: Bool { tab != nil }

    func open(_ target: Tab? = nil) {
        let next = target ?? lastTab
        tab = next
        peeking = false
        if next != .settings {
            lastTab = next
            UserDefaults.standard.set(next.rawValue, forKey: "islandTab")
        }
    }

    func close() {
        tab = nil
        welcome = false
    }

    func toggle(_ target: Tab) { tab == target ? close() : open(target) }
    func togglePanel() { tab == nil ? open() : close() }

    /// macOS sometimes never sends "mouse exited" to a floating panel (e.g. when it resizes under the
    /// pointer), so while hovering we also check where the mouse really is.
    func setHovering(_ on: Bool) {
        hovering = on
        exitWatch?.invalidate()
        exitWatch = nil
        guard on else { return }
        exitWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                guard let window = NSApp.windows.first(where: { $0 is FloatingPanel && $0.title == "island" }) else { return }
                if !window.frame.insetBy(dx: 2, dy: 2).contains(NSEvent.mouseLocation) {
                    self.hovering = false
                    timer.invalidate()
                }
            }
        }
    }

    func peek(seconds: Double = 6) {
        peekWork?.cancel()
        peeking = true
        let work = DispatchWorkItem { [weak self] in self?.peeking = false }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Hoot as a Dynamic Island: one continuous surface that grows out of the notch, black where it meets it.
/// - rest: a small glass crane beside the notch, so you always know Hoot is there,
/// - live (recording): crane and timer on the left, live voice bars on the right,
/// - controls (hover, or a call/answer to announce): a live caption, Record and quick links,
/// - panel: Transcript · Notes · AI · Settings, all inside the island.
struct IslandView: View {
    enum Mode: Equatable { case rest, alert, live, controls, panel }

    @ObservedObject var model: IslandModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var prefs: Preferences
    let notes: SpeakerNotes
    let setup: SetupStatus
    let notch: CGSize
    let onResize: (CGSize) -> Void
    var forceMode: Mode? = nil        // for rendering product images

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shoulder: CGFloat = 6

    /// Content fades in just behind the growing shape, and leaves at once when it closes.
    private static let reveal = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18 * Theme.slowMotion).delay(0.05 * Theme.slowMotion)),
        removal: .opacity.animation(.easeIn(duration: 0.08 * Theme.slowMotion)))

    private var mode: Mode {
        if let forceMode { return forceMode }
        if model.isOpen { return .panel }
        if model.hovering || model.peeking || recorder.justSaved { return .controls }
        if recorder.state != .idle { return .live }
        if HootStatus.needsAttention(recorder, assist) || recorder.modelDownload != nil { return .alert }
        return .rest
    }

    private var open: Bool { mode == .controls || mode == .panel }

    /// The body (shoulders excluded). Never smaller than the notch, so none of it peeks out.
    private func bodySize(_ mode: Mode) -> CGSize {
        let h = notch.height + 1
        switch mode {
        case .rest: return CGSize(width: notch.width + (prefs.restVisible ? 64 : 2), height: h)
        case .alert: return CGSize(width: notch.width + 64, height: h)
        case .live: return CGSize(width: notch.width + 184, height: h)
        case .controls: return CGSize(width: max(notch.width + 280, 480), height: h + 92)
        case .panel: return CGSize(width: 600, height: h + 560)
        }
    }

    /// What's below the header — the controls or the panel — at its full size. It's laid out once at
    /// this size and revealed by the growing shape (or cut off by the shrinking one), rather than being
    /// laid out again on every frame of the animation.
    private func contentSize(_ mode: Mode) -> CGSize {
        let size = bodySize(mode)
        return CGSize(width: size.width - 36, height: size.height - notch.height)
    }

    /// The window's size for a mode: the body plus room for the shadow while open. The window is set
    /// to this once per change (not on every animation frame), and the shape animates inside it.
    private func windowSize(_ mode: Mode) -> CGSize {
        let body = bodySize(mode)
        let opened = mode == .controls || mode == .panel
        return CGSize(width: body.width + 2 * shoulder + (opened ? 56 : 0), height: body.height + (opened ? 36 : 0))
    }

    /// The fixed area the island is drawn in: room for its largest states (the panel, the controls).
    static func canvas(notch: CGSize) -> CGSize {
        CGSize(width: max(600, notch.width + 280) + 2 * 6 + 56, height: notch.height + 1 + 560 + 36)
    }

    var body: some View {
        let size = bodySize(mode)
        let shape = IslandShape(bottomRadius: open ? Theme.islandRadius : 11, shoulder: shoulder)
        ZStack(alignment: .top) {
            surface(shape)
            ZStack(alignment: .top) {
                header
                    .frame(height: notch.height)
                    .padding(.horizontal, shoulder + (open ? 18 : 10))
                    .frame(width: size.width + 2 * shoulder)
                switch mode {
                case .controls: below(controls, .controls)
                case .panel: below(panel, .panel)
                default: EmptyView()
                }
            }
            .frame(width: size.width + 2 * shoulder, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: size.width + 2 * shoulder, height: size.height, alignment: .top)
        .contentShape(shape)
        .environment(\.colorScheme, .dark)
        .onHover { model.setHovering($0) }
        .onChange(of: recorder.status) { _, status in if status != nil { model.peek(seconds: 8) } }
        .onChange(of: assist.hasUnseen) { _, unseen in if unseen && !model.isOpen { model.peek() } }
        .onChange(of: recorder.callHint) { _, hint in if hint != nil { model.peek(seconds: 12) } }
        .onChange(of: mode) { _, new in onResize(windowSize(new)) }
        .onChange(of: prefs.restVisible) { _, _ in onResize(windowSize(mode)) }
        .onAppear { onResize(windowSize(mode)) }
        .contextMenu { HootMenuItems(recorder: recorder, updates: updates, model: model) }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Theme.spring, value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hoot")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Black where the island meets the notch, so the two read as one; below that, dark glass that lets
    /// what's behind show through. Closed, the island is only the black row.
    private func surface(_ shape: IslandShape) -> some View {
        let solid = notch.height + 1
        let band = solid + 26
        return ZStack(alignment: .top) {
            // The shadow is drawn from the plain shape only — cheap — and only outside it: inside, the
            // glass would pick it up.
            shape.fill(.black)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                .mask {
                    Rectangle().padding(-64)
                        .overlay(shape.blendMode(.destinationOut))
                        .compositingGroup()
                }
                .opacity(open ? 1 : 0)
            Color.clear.glassEffect(.regular, in: shape)
            // An overlay, so the band's height never adds to the island's (a taller child would push
            // the header up out of the closed island).
            shape.fill(Theme.glassShade)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(LinearGradient(stops: [.init(color: Theme.surface, location: solid / band),
                                                     .init(color: Theme.surface.opacity(0), location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: band)
                }
                .clipShape(shape)
        }
    }

    private func below(_ content: some View, _ mode: Mode) -> some View {
        let size = contentSize(mode)
        return content
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.top, notch.height)
            .transition(Self.reveal)
    }

    // MARK: The row beside the notch

    /// The bird and the title keep their identity from state to state, so they glide along with the
    /// island's edge as it grows instead of fading out in one place and in at another.
    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if mode != .rest || prefs.restVisible {
                crane(size: open ? 22 : (mode == .live ? 20 : 18))
            }
            if mode == .live || open { title.transition(Self.reveal) }
            Spacer(minLength: mode == .rest ? 0 : notch.width)
            switch mode {
            case .rest:
                EmptyView()
            case .alert:
                Circle()
                    .fill(recorder.status != nil ? Theme.warning : (recorder.modelDownload != nil ? Theme.secondary : Theme.you))
                    .frame(width: 8, height: 8)
                    .shadow(color: Theme.you.opacity(0.9), radius: 5)
            case .live:
                IslandWaveform(meter: recorder.meter)
            case .controls:
                statusChip
            case .panel:
                panelHeaderControls
            }
        }
    }

    /// The running clock while recording, otherwise "Hoot" or what's happening.
    @ViewBuilder private var title: some View {
        if recorder.state == .recording {
            TimelineView(.periodic(from: .now, by: 1)) { _ in Text(HootStatus.title(recorder)) }
                .font(Theme.Font.clock)
                .foregroundStyle(Theme.text)
        } else {
            Text(HootStatus.title(recorder)).font(Theme.Font.headline).foregroundStyle(Theme.text)
        }
    }

    private func crane(size: CGFloat) -> some View {
        HootOrb(mood: HootStatus.mood(recorder), meter: recorder.meter, glow: false, size: size)
            .contentShape(Rectangle())
            .onTapGesture { recorder.toggle() }
            .help(recorder.isRecording ? "Stop recording (\(HotKeys.record.label))" : "Start recording (\(HotKeys.record.label))")
    }

    private var statusChip: some View {
        let (text, colour): (String, Color) = {
            if recorder.state == .recording { return ("Recording", Theme.record) }
            if recorder.callHint != nil { return ("Call", Theme.you) }
            if recorder.justSaved { return ("Saved", Theme.success) }
            if recorder.modelDownload != nil { return ("Setting up", Theme.secondary) }
            return ("Ready", Theme.tertiary)
        }()
        return HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(text).font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.secondary)
        }
    }

    private var panelHeaderControls: some View {
        HStack(spacing: 6) {
            recordButton()
            ThemeIconButton(symbol: model.pinned ? "pin.fill" : "pin",
                            help: model.pinned ? "Unpin (closes when you click elsewhere)" : "Keep open while you work",
                            size: 26) { model.pinned.toggle() }
            ThemeIconButton(symbol: "chevron.up", help: "Close (Esc)", size: 26) { model.close() }
        }
    }

    // MARK: Controls (hover)

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HootStatus.caption(recorder, assist, updates: updates, liveCaption: true))
                .font(Theme.Font.body)
                .foregroundStyle(recorder.status != nil ? Theme.warning : Theme.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                recordButton()
                Spacer()
                ThemeIconButton(symbol: "text.bubble", help: "Transcript (\(HotKeys.transcript.label))") { model.open(.transcript) }
                ThemeIconButton(symbol: "list.bullet.clipboard", help: "Speaker Notes (\(HotKeys.notes.label))") { model.open(.notes) }
                ThemeIconButton(symbol: "sparkles", help: "AI Assist (\(HotKeys.assist.label))", badge: assist.hasUnseen) { model.open(.assist) }
                ThemeIconButton(symbol: "gearshape", help: "Settings") { model.open(.settings) }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private func recordButton() -> some View {
        let recording = recorder.isRecording
        return ThemeButton(title: recording ? "Stop" : "Record", symbol: recording ? "stop.fill" : "circle.fill",
                           role: recording ? .stop : .record) { recorder.toggle() }
            .disabled(recorder.state == .starting || recorder.state == .finishing)
            .help(recording ? "Stop and save (\(HotKeys.record.label))" : "Start taking notes (\(HotKeys.record.label))")
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 12) {
            ThemeSegmented(selection: Binding(get: { model.tab ?? .transcript }, set: { model.open($0) }),
                           items: [(IslandModel.Tab.transcript, "Transcript", "text.bubble"),
                                   (.notes, "Notes", "list.bullet.clipboard"),
                                   (.assist, "AI", "sparkles"),
                                   (.settings, nil, "gearshape")],
                           badge: assist.hasUnseen ? .assist : nil)
            Group {
                switch model.tab ?? .transcript {
                case .transcript: TranscriptPane(recorder: recorder)
                case .notes: NotesPane(notes: notes)
                case .assist: AssistPane(assist: assist, recorder: recorder, notes: notes)
                case .settings: SettingsPane(prefs: prefs, recorder: recorder, assist: assist, setup: setup,
                                             updates: updates, welcome: model.welcome)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

/// Live voice bars: three for you (blue), three for the others (pink). Redrawn only when the voices
/// change (at most 15 times a second), so silence costs nothing.
struct IslandWaveform: View {
    @ObservedObject var meter: LiveMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let t = Date().timeIntervalSinceReferenceDate
        HStack(spacing: 2.5) {
            ForEach(0..<6, id: \.self) { i in
                let mine = i < 3
                let level = CGFloat(mine ? meter.me : meter.them)
                let wobble = reduceMotion ? 1 : 0.55 + 0.45 * abs(sin(t * 8 + Double(i) * 1.3))
                Capsule()
                    .fill(mine ? Theme.you : Theme.others)
                    .frame(width: 3, height: 4 + 14 * level * CGFloat(wobble))
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}
