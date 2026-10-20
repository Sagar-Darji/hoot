import AppKit
import SwiftUI

/// The island's window: borderless, always on top, over every app, Space and full-screen call, and
/// hidden from screen sharing.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true          // first: setting it resets the level to .floating
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Keep Hoot out of screenshots and screen shares so others in the call never see it.
        sharingType = ProcessInfo.processInfo.environment["HOOT_SHOWCASE"] == nil ? .none : .readOnly
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// macOS normally keeps windows out of the menu bar; the notch island has to sit on top of it.
    var allowsMenuBarOverlap = false
    /// Esc.
    var onCancel: (() -> Void)?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsMenuBarOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    private var pendingShrink: DispatchWorkItem?
    /// The x the window stays centred on (the notch).
    var anchorMidX: CGFloat?

    /// Resizes around the notch, keeping the top edge in place. Growing happens at once; shrinking waits
    /// for the closing animation, so it isn't clipped.
    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pendingShrink?.cancel()
        func apply(_ target: CGSize) {
            guard target != frame.size else { return }
            let x = (anchorMidX ?? frame.midX) - target.width / 2
            setFrame(NSRect(x: x, y: frame.maxY - target.height, width: target.width, height: target.height), display: false)
        }
        let grown = CGSize(width: max(size.width, frame.width), height: max(size.height, frame.height))
        apply(grown)
        guard grown != size else { return }
        let shrink = DispatchWorkItem { apply(size) }
        pendingShrink = shrink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Theme.slowMotion, execute: shrink)
    }
}

/// The island's SwiftUI host. The first click acts at once (Record, a tab…) instead of only focusing
/// the panel, which would make every first click feel ignored.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A window-sized view that holds the island at a fixed size, pinned to its top centre. The window
    /// grows and shrinks around it like a viewport, so SwiftUI never sees a size change — which would
    /// otherwise be animated along with the island, sliding it about, and cost a layout pass.
    static func pinned(_ rootView: Content, canvas: CGSize, in size: CGSize) -> NSView {
        let host = IslandHostingView(rootView: rootView)
        host.sizingOptions = []
        host.frame = NSRect(x: (size.width - canvas.width) / 2, y: size.height - canvas.height,
                            width: canvas.width, height: canvas.height)
        host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(host)
        return container
    }
}

// MARK: - Transcript

final class TranscriptUIState: ObservableObject {
    @Published var copied = false
    @Published var showSummary = false
}

/// The conversation, laid out like Messages: you on the right in blue, everyone else on the left.
struct TranscriptPane: View {
    @ObservedObject var recorder: Recorder
    @StateObject private var ui = TranscriptUIState()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ThemeSegmented(selection: $ui.showSummary, items: [(false, "Conversation", nil), (true, "Summary", nil)])
                Spacer()
                ThemeIconButton(symbol: ui.copied ? "checkmark" : "doc.on.doc",
                                help: ui.showSummary ? "Copy the summary" : "Copy the transcript", action: copy)
                    .disabled(recorder.lines.isEmpty)
                if let folder = recorder.sessionFolder {
                    ThemeIconButton(symbol: "folder", help: "Show this meeting's files in Finder") { NSWorkspace.shared.open(folder) }
                }
            }
            Group {
                if ui.showSummary { SummaryView(recorder: recorder) } else { conversation }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: recorder.summary) { _, summary in if summary != nil { ui.showSummary = true } }
        .onChange(of: recorder.isRecording) { _, rec in if rec { ui.showSummary = false } }
    }

    @ViewBuilder private var conversation: some View {
        if recorder.lines.isEmpty {
            ThemeEmpty(symbol: recorder.isRecording ? "waveform" : "text.bubble",
                       title: recorder.isRecording ? "Listening" : "No transcript yet",
                       message: recorder.isRecording ? "Lines appear a few seconds after each sentence."
                                                     : "Press Record — both sides of the call will appear here.")
        } else {
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
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .onChange(of: recorder.lines) { _, lines in
                    if let last = lines.last { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func row(_ line: TranscriptLine, showName: Bool) -> some View {
        let mine = line.speaker == .me
        return HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 60) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if showName {
                    HStack(spacing: 5) {
                        Text(line.speaker.name).foregroundStyle(mine ? Theme.you : Theme.others)
                        Text(Recorder.clock(line.start)).foregroundStyle(Theme.tertiary)
                    }
                    .font(Theme.Font.caption.weight(.medium))
                    .padding(.horizontal, 10)
                }
                Text(line.text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                        .fill(mine ? Theme.you : Theme.raised))
                    .help(Recorder.clock(line.start))
            }
            if !mine { Spacer(minLength: 60) }
        }
    }

    private func copy() {
        let text = ui.showSummary && recorder.summary != nil ? recorder.summary!
            : recorder.lines.map { "[\(Recorder.clock($0.start))] \($0.speaker.name): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ui.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
    }
}

// MARK: - Summary

/// The on-device summary, rendered like a note: headings, bullets and to-dos.
struct SummaryView: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        if let summary = recorder.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownText(source: summary)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.text)
                    Label("Written on this Mac by Apple Intelligence — check important details against the transcript.",
                          systemImage: "apple.intelligence")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 12)
                }
                .textSelection(.enabled)
                .themeCard(padding: 16)
            }
            .scrollIndicators(.never)
        } else if recorder.summarizing {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Summarizing on this Mac…").font(Theme.Font.title).foregroundStyle(Theme.text)
                Text("Apple Intelligence is writing the summary and action items.")
                    .font(Theme.Font.callout).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                ThemeEmpty(symbol: "apple.intelligence",
                           title: recorder.summaryError == nil ? "No summary yet" : "Summary unavailable",
                           message: recorder.summaryError ?? (recorder.lines.isEmpty || recorder.isRecording
                                ? "When you stop recording, the summary and action items appear here."
                                : "Get the summary, decisions and action items for this conversation."))
                    .frame(maxHeight: 180)
                if !recorder.lines.isEmpty && !recorder.isRecording && Summarizer.unavailableReason == nil {
                    ThemeButton(title: "Summarize", symbol: "sparkles", role: .primary) { Task { await recorder.summarize() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
