import AppKit
import SwiftUI

/// An always-on-top panel that floats over every app, Space and full-screen call.
/// The bubble is borderless; the others are real macOS windows (title bar, toolbar, close button).
final class FloatingPanel: NSPanel {
    init(size: NSSize, autosaveKey: String, titled: Bool = false) {
        let style: NSWindow.StyleMask = titled
            ? [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView]
            : [.nonactivatingPanel, .borderless, .fullSizeContentView]
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        isFloatingPanel = true          // first: setting it resets the level to .floating
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        if titled {
            toolbarStyle = .unifiedCompact
            // See-through window: the SwiftUI content paints Liquid Glass edge to edge (see `windowGlass()`).
            isOpaque = false
            backgroundColor = .clear
            // Like Apple's own floating panels: just a close button.
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
        } else {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
        }
        // Keep Hoot out of screenshots and screen shares so others in the call never see it.
        sharingType = ProcessInfo.processInfo.environment["HOOT_SHOWCASE"] == nil ? .none : .readOnly
        setFrameAutosaveName(autosaveKey)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// macOS normally keeps windows out of the menu bar; the notch island has to sit on top of it.
    var allowsMenuBarOverlap = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsMenuBarOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// Esc hides a panel (but never the bubble itself).
    override func cancelOperation(_ sender: Any?) {
        if title != "bubble" { orderOut(nil) }
    }

    /// Pulls the window fully back onto the nearest screen (after a drag, or when a display is unplugged).
    func keepOnScreen() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let area = (screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main ?? screens[0]).visibleFrame
        var f = frame
        f.origin.x = min(max(f.minX, area.minX), area.maxX - f.width)
        f.origin.y = min(max(f.minY, area.minY), area.maxY - f.height)
        if f.origin != frame.origin { setFrameOrigin(f.origin) }
    }

    enum Anchor { case topLeft, topCenter }
    private var pendingShrink: DispatchWorkItem?
    /// For `.topCenter`: the x the window stays centred on (the notch), whatever its current frame.
    var anchorMidX: CGFloat?

    /// Resizes to fit the content, keeping the top edge (and the left edge or the centre) in place.
    /// Growing happens at once; shrinking waits for the closing animation, so it isn't clipped.
    func fit(_ size: CGSize, anchor: Anchor = .topLeft) {
        guard size.width > 0, size.height > 0 else { return }
        pendingShrink?.cancel()
        func apply(_ target: CGSize) {
            guard target != frame.size else { return }
            let x = anchor == .topCenter ? (anchorMidX ?? frame.midX) - target.width / 2 : frame.minX
            setFrame(NSRect(x: x, y: frame.maxY - target.height, width: target.width, height: target.height), display: true)
        }
        let grown = CGSize(width: max(size.width, frame.width), height: max(size.height, frame.height))
        apply(grown)
        guard grown != size else { return }
        let shrink = DispatchWorkItem { apply(size) }
        pendingShrink = shrink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: shrink)
    }
}

/// System colours only, so Hoot follows the user's accent colour, light/dark mode and contrast settings.
enum Palette {
    static let me = Color.accentColor
    static let others = Color.secondary
    static let record = Color(nsColor: .systemRed)
}

/// Liquid Glass on macOS 26+, frosted material before that.
extension View {
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            var glass = Glass.regular
            if let tint { glass = glass.tint(tint) }
            if interactive { glass = glass.interactive() }
            return AnyView(self.glassEffect(glass, in: shape))
        } else {
            return AnyView(self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3))
        }
    }
}

extension View {
    /// Fills a whole window with Liquid Glass (frosted material before macOS 26), under the title bar too.
    @ViewBuilder func windowGlass() -> some View {
        if #available(macOS 26.0, *) {
            // A light frost over the glass keeps text readable over busy windows (code, video).
            background {
                Rectangle().fill(.clear).glassEffect(.regular, in: .rect)
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.35))
                    .ignoresSafeArea()
            }
        } else {
            background { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
        }
    }
}

// MARK: - Live transcript

final class TranscriptUIState: ObservableObject {
    @Published var copied = false
    @Published var showSummary = false
}

/// Laid out like Messages: you on the right in your accent colour, everyone else on the left.
struct TranscriptView: View {
    @ObservedObject var recorder: Recorder

    @StateObject private var ui = TranscriptUIState()

    var body: some View {
        Group {
            if ui.showSummary { SummaryView(recorder: recorder) } else { conversation }
        }
        .onChange(of: recorder.summary) { _, summary in if summary != nil { ui.showSummary = true } }
        .onChange(of: recorder.isRecording) { _, rec in if rec { ui.showSummary = false } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                PillSegments(selection: $ui.showSummary, items: [
                    (false, nil, "text.bubble"), (true, nil, "list.bullet.rectangle"),
                ])
                .disabled(recorder.isRecording)
                .help("Conversation or Apple Intelligence summary")
                Button(action: copy) {
                    Label(ui.copied ? "Copied" : "Copy", systemImage: ui.copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(recorder.lines.isEmpty)
                .help(ui.showSummary ? "Copy the summary" : "Copy the whole transcript")
                if let folder = recorder.sessionFolder {
                    Button { NSWorkspace.shared.open(folder) } label: { Label("Show in Finder", systemImage: "folder") }
                        .help("Show this meeting's files in Finder")
                }
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(recorder.lines.enumerated()), id: \.element.id) { i, line in
                        let first = i == 0 || recorder.lines[i - 1].speaker != line.speaker
                        row(line, showName: first)
                            .padding(.top, first && i > 0 ? 10 : 0)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: recorder.lines) { _, lines in
                if let last = lines.last { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .overlay {
            if recorder.lines.isEmpty {
                ContentUnavailableView {
                    Label(recorder.isRecording ? "Listening" : "No Transcript",
                          systemImage: recorder.isRecording ? "waveform" : "text.bubble")
                } description: {
                    Text(recorder.isRecording ? "Text appears a few seconds after each sentence."
                                              : "Start recording to see the conversation here.")
                }
            }
        }
    }


    private func row(_ line: TranscriptLine, showName: Bool) -> some View {
        let mine = line.speaker == .me
        return HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if showName {
                    Text("\(line.speaker.name)  \(Recorder.clock(line.start))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(mine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                    .help(Recorder.clock(line.start))
            }
            if !mine { Spacer(minLength: 48) }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func copy() {
        let text = ui.showSummary && recorder.summary != nil ? recorder.summary! : recorder.lines.map { "[\(Recorder.clock($0.start))] \($0.speaker.name): \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ui.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
    }
}

// MARK: - Summary

/// The on-device summary, rendered like a note: headings, bullets and checkable action items.
struct SummaryView: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        if let summary = recorder.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownText(source: summary)
                    Label("Written on this Mac by Apple Intelligence — check important details against the transcript.",
                          systemImage: "apple.intelligence")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else if recorder.summarizing {
            ContentUnavailableView {
                Label { Text("Summarizing…") } icon: { ProgressView().controlSize(.large) }
            } description: {
                Text("Apple Intelligence is writing the summary and action items on this Mac.")
            }
        } else {
            ContentUnavailableView {
                Label(recorder.summaryError == nil ? "No Summary Yet" : "Summary Unavailable", systemImage: "apple.intelligence")
            } description: {
                Text(recorder.summaryError ?? (recorder.lines.isEmpty
                     ? "Record a meeting and its summary appears here when you stop."
                     : "Get a summary, decisions and action items for this conversation."))
            } actions: {
                if !recorder.lines.isEmpty && !recorder.isRecording && Summarizer.unavailableReason == nil {
                    Button("Summarize") { Task { await recorder.summarize() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder private static func render(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            Text(inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                .font(.headline)
                .padding(.top, 8)
        } else if line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") {
            Label { Text(inline(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))) } icon: {
                Image(systemName: line.hasPrefix("- [x]") ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.accentColor)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(line.dropFirst(2))))
            }
        } else if !line.isEmpty {
            Text(inline(line))
        }
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
