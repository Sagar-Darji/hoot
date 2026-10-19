import AppKit
import SwiftUI

/// The words and states the island shows, in one place so every view agrees.
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

/// The right-click menu on the island.
struct HootMenuItems: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var updates: UpdateChecker
    let model: IslandModel

    var body: some View {
        Button {
            recorder.toggle()
        } label: {
            Label(recorder.isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: recorder.isRecording ? "stop.circle" : "record.circle")
        }
        .keyboardShortcut("r", modifiers: [.control, .option])
        Divider()
        Button { model.open(.transcript) } label: { Label("Transcript", systemImage: "text.bubble") }
            .keyboardShortcut("t", modifiers: [.control, .option])
        Button { model.open(.notes) } label: { Label("Speaker Notes", systemImage: "list.bullet.clipboard") }
            .keyboardShortcut("n", modifiers: [.control, .option])
        Button { model.open(.assist) } label: { Label("AI Assist", systemImage: "sparkles") }
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
        Button { model.open(.settings) } label: { Label("Settings…", systemImage: "gearshape") }
        Button("Quit Hoot") { NSApp.terminate(nil) }
    }
}

/// The crane as transparent glass, picked from frames rendered at a few wing positions.
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
