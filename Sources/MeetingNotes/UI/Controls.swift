import AppKit
import SwiftUI

/// What the bubble / notch island can ask the app to do.
struct OverlayActions {
    var toggleTranscript: () -> Void
    var toggleNotes: () -> Void
    var toggleAssist: () -> Void
    var togglePanel: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// Hover and "peek" state shared by the bubble and the island (SwiftUI's @State macro isn't available
/// without Xcode's macro plugins, so view-local state lives in small objects like this one).
final class OverlayUIState: ObservableObject {
    @Published var hovering = false
    @Published var peeking = false          // briefly open to announce something (a call, a new answer, an error)
    var dragStartMouse: NSPoint?
    var dragStartOrigin: NSPoint?
    let windowTitle: String
    private var exitWatch: Timer?
    private var peekWork: DispatchWorkItem?

    init(windowTitle: String) { self.windowTitle = windowTitle }

    /// macOS sometimes never sends "mouse exited" to a floating panel (e.g. when it resizes under the
    /// pointer or a button was clicked), so while hovering we also check where the mouse really is.
    func setHovering(_ on: Bool) {
        hovering = on
        exitWatch?.invalidate()
        exitWatch = nil
        guard on else { return }
        let title = windowTitle
        exitWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.dragStartMouse == nil,
                  let window = NSApp.windows.first(where: { $0 is FloatingPanel && $0.title == title }) else { return }
            if !window.frame.insetBy(dx: 2, dy: 2).contains(NSEvent.mouseLocation) {
                self.hovering = false
                timer.invalidate()
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

/// The words and states the bubble and island show, in one place so they always agree.
@MainActor
enum HootStatus {
    static func mood(_ recorder: Recorder) -> HootOrb.Mood {
        switch recorder.state {
        case .recording: return .listening
        case .starting, .finishing: return .busy
        case .idle:
            if recorder.justSaved { return .saved }
            if recorder.modelDownload != nil { return .sleeping }
            if case .failed = recorder.engine { return .sleeping }
            return .idle
        }
    }

    /// The headline: "Hoot", a running clock while recording, or what's happening.
    static func title(_ recorder: Recorder) -> String {
        switch recorder.state {
        case .recording: return Recorder.clock(recorder.elapsed)
        case .starting: return "Starting…"
        case .finishing: return "Saving…"
        case .idle: return recorder.justSaved ? "Notes Saved" : "Hoot"
        }
    }

    /// One short line of context, most important first.
    static func caption(_ recorder: Recorder, _ assist: AIAssist, updates: UpdateChecker, liveCaption: Bool) -> String {
        if let status = recorder.status { return status }
        if let app = recorder.callHint, recorder.state == .idle { return "\(app) call detected — record it?" }
        if assist.hasUnseen, let entry = assist.entries.last { return "New answer from \(entry.source)" }
        switch recorder.state {
        case .starting: return "Connecting microphone and call audio"
        case .finishing: return recorder.pendingChunks > 0 ? "Transcribing the last \(recorder.pendingChunks)…" : "Writing transcript"
        case .recording:
            if let d = recorder.modelDownload { return "Listening · setting up speech \(Int(d * 100))%" }
            if recorder.engine == .loading { return "Listening · speech engine starting" }
            if liveCaption, let last = recorder.lines.last { return "\(last.speaker.name): \(last.text)" }
            let n = recorder.lines.count
            return n == 0 ? "Listening…" : "Listening · \(n) \(n == 1 ? "line" : "lines")"
        case .idle:
            if recorder.justSaved {
                let n = recorder.lines.count
                return "\(n) \(n == 1 ? "line" : "lines") · \(Recorder.clock(recorder.duration))" + (recorder.summarizing ? " · summarizing…" : "")
            }
            if let d = recorder.modelDownload { return "Setting up · downloading speech model \(Int(d * 100))%" }
            if let update = updates.available { return "Hoot \(update.version) is available" }
            return "Ready · \(HotKeys.record.label) to record"
        }
    }

    /// Something worth a glance even while collapsed: a message, a new answer, a call.
    static func needsAttention(_ recorder: Recorder, _ assist: AIAssist) -> Bool {
        recorder.status != nil || assist.hasUnseen || recorder.callHint != nil
    }
}

/// The right-click menu, shared by the bubble and the island.
struct HootMenuItems: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var updates: UpdateChecker
    let actions: OverlayActions

    var body: some View {
        Button {
            recorder.toggle()
        } label: {
            Label(recorder.isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: recorder.isRecording ? "stop.circle" : "record.circle")
        }
        .keyboardShortcut("r", modifiers: [.control, .option])
        Divider()
        Button(action: actions.toggleTranscript) { Label("Transcript", systemImage: "text.bubble") }
            .keyboardShortcut("t", modifiers: [.control, .option])
        Button(action: actions.toggleNotes) { Label("Speaker Notes", systemImage: "list.bullet.clipboard") }
            .keyboardShortcut("n", modifiers: [.control, .option])
        Button(action: actions.toggleAssist) { Label("AI Assist", systemImage: "sparkles") }
            .keyboardShortcut("a", modifiers: [.control, .option])
        Divider()
        Button {
            try? FileManager.default.createDirectory(at: Recorder.notesRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Recorder.notesRoot)
        } label: { Label("Show All Notes in Finder", systemImage: "folder") }
        let recent = Recorder.recentMeetings(limit: 8)
        if !recent.isEmpty {
            Menu {
                ForEach(recent, id: \.self) { folder in
                    Button(folder.lastPathComponent) {
                        let summary = folder.appendingPathComponent("summary.md")
                        let file = FileManager.default.fileExists(atPath: summary.path) ? summary : folder.appendingPathComponent("transcript.md")
                        NSWorkspace.shared.open(file)
                    }
                }
            } label: { Label("Recent Meetings", systemImage: "clock") }
        }
        if recorder.status != nil {
            Button("Dismiss Message") { recorder.status = nil }
        }
        Divider()
        if let update = updates.available {
            Button { NSWorkspace.shared.open(update.download ?? update.page) } label: {
                Label("Update to Hoot \(update.version)…", systemImage: "arrow.down.circle")
            }
        }
        Button(action: actions.openSettings) { Label("Settings…", systemImage: "gearshape") }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit Hoot", action: actions.quit)
    }
}

/// The record button's crane as transparent glass, picked from frames rendered at a few wing positions.
struct GlassCrane: View {
    var lift: CGFloat
    var size: CGFloat
    @ObservedObject private var glass = GlassFrames.shared

    var body: some View {
        Group {
            if let frames = glass.frames(at: lift) {
                ZStack {
                    Image(nsImage: frames.lower).resizable().interpolation(.high)
                    Image(nsImage: frames.upper).resizable().interpolation(.high).opacity(frames.mix)
                }
            } else {
                HootMark(size: size, lift: lift * 0.10).offset(y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}
