import AppKit
import AVFoundation
import Foundation

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    let start: TimeInterval
    let text: String
}

/// Voice levels while recording. They change many times a second, so they live apart from `Recorder`:
/// only the few small views that draw them re-render, not the transcript, panels and labels.
@MainActor
final class LiveMeter: ObservableObject {
    @Published private(set) var me: Float = 0
    @Published private(set) var them: Float = 0
    var level: Float { max(me, them) }

    func update(me: Float, them: Float) {
        // Ignore changes too small to see, so a quiet room doesn't cause redraws.
        guard abs(me - self.me) > 0.015 || abs(them - self.them) > 0.015 else { return }
        self.me = me
        self.them = them
    }

    func reset() {
        me = 0
        them = 0
    }
}

@MainActor
final class Recorder: ObservableObject {
    enum State: Equatable { case idle, starting, recording, finishing }

    /// The speech engine is loaded only when it's needed and unloaded again when idle, so Hoot stays light.
    enum Engine: Equatable { case unloaded, downloading(Double), loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var pendingChunks = 0
    @Published private(set) var engine: Engine = .unloaded
    @Published var status: String?            // last error / info, shown in the overlay
    @Published private(set) var sessionFolder: URL?
    @Published private(set) var startedAt: Date?           // when the current/last recording began
    @Published private(set) var duration: TimeInterval = 0 // length of the last finished recording
    @Published private(set) var justSaved = false          // true for a few seconds after a session is saved
    @Published private(set) var summary: String?           // on-device summary of the last meeting
    @Published private(set) var summarizing = false
    @Published private(set) var summaryError: String?
    /// "Zoom" while a call app is using the mic and we're idle. Seeing a call warms up the speech engine.
    @Published var callHint: String? {
        didSet { if callHint != nil { warmUp() } }
    }
    let meter = LiveMeter()
    private var callApp: String?
    var speakerNotes: SpeakerNotes?
    var aiAssist: AIAssist?

    @Published var echoCancellation = UserDefaults.standard.object(forKey: "echoCancellation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation") }
    }
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" {
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            restartServer()
        }
    }
    /// Off by default: after a meeting only the mixed conversation.m4a is kept (≈0.5 MB/min), not the
    /// two raw tracks (≈2 MB/min each).
    @Published var keepTracks = UserDefaults.standard.bool(forKey: "keepTracks") {
        didSet { UserDefaults.standard.set(keepTracks, forKey: "keepTracks") }
    }

    var serverReady: Bool { engine == .ready }
    var modelDownload: Double? { if case .downloading(let p) = engine { return p } else { return nil } }
    /// Live while recording; the final length afterwards.
    var elapsed: TimeInterval {
        if state == .recording || state == .starting, let startedAt { return Date().timeIntervalSince(startedAt) }
        return duration
    }

    nonisolated static var notesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Notes", isDirectory: true)
    }

    private let whisper = WhisperServer()
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var meTrack: Track?
    private var themTrack: Track?
    private var timer: Timer?
    private var unloadTask: Task<Void, Never>?
    private var queue: [SpeechChunk] = []
    private var worker: Task<Void, Never>?

    var isRecording: Bool { state == .recording }

    // MARK: Speech engine

    /// At launch: make sure the speech model is on disk (downloading it the first time), but don't load it.
    func prepareModel() {
        guard WhisperServer.modelURL == nil, modelDownload == nil else { return }
        engine = .downloading(0)
        let progress: (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in if case .downloading = self?.engine { self?.engine = .downloading(fraction) } }
        }
        Task {
            do {
                _ = try await WhisperServer.downloadModel(progress: progress)
                engine = .unloaded
                if status?.hasPrefix("Couldn't download") == true { status = nil }
            } catch {
                engine = .failed(error.localizedDescription)
                status = error.localizedDescription
            }
        }
    }

    /// Loads the speech engine if it isn't already (when recording starts, or as soon as a call is detected).
    func warmUp() {
        unloadTask?.cancel()
        unloadTask = nil
        switch engine {
        case .ready, .loading, .downloading: return
        case .unloaded, .failed: break
        }
        engine = .loading
        let progress: (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.engine = .downloading(fraction) }
        }
        Task {
            do {
                try await whisper.start(language: language, onDownload: progress)
                engine = .ready
                if status?.hasPrefix("Couldn't download") == true || status?.hasPrefix("Hoot's speech") == true { status = nil }
            } catch {
                engine = .failed(error.localizedDescription)
                status = error.localizedDescription
            }
        }
    }

    /// Frees the engine's memory (~0.6 GB) a few minutes after the last meeting, unless another starts.
    private func scheduleUnload(after seconds: Double = 180) {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.state == .idle, self.pendingChunks == 0, self.callHint == nil else { return }
            self.whisper.stop()
            self.engine = .unloaded
        }
    }

    private func restartServer() {
        guard state == .idle, engine == .ready else { return }
        whisper.stop()
        engine = .unloaded
        warmUp()
    }

    /// Most recent meeting folders first.
    nonisolated static func recentMeetings(limit: Int) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: notesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // names start with yyyy-MM-dd HH.mm
            .prefix(limit).map { $0 }
    }

    /// Writes summary, decisions and action items on-device, then saves them with the transcript.
    func summarize() async {
        guard !summarizing, !lines.isEmpty else { return }
        summarizing = true
        summaryError = nil
        defer { summarizing = false }
        do {
            let text = try await Summarizer.summarize(lines)
            summary = text
            if let folder = sessionFolder {
                try? text.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
                writeTranscript()
            }
        } catch {
            summaryError = error.localizedDescription
        }
    }

    /// Sample conversation for `HOOT_SHOWCASE=…` (design review screenshots only). `live` fakes a recording
    /// in progress (no audio is captured) so the recording UI can be reviewed.
    func loadShowcase(live: Bool = false) {
        engine = .ready                    // don't load the real speech engine for a screenshot
        lines = [
            TranscriptLine(speaker: .them, start: 3, text: "Hi everyone, thanks for joining. Let's review the quarterly roadmap."),
            TranscriptLine(speaker: .me, start: 9, text: "Sounds good. I think we should launch on November 5th."),
            TranscriptLine(speaker: .me, start: 14, text: "Marketing already has the campaign ready."),
            TranscriptLine(speaker: .them, start: 21, text: "Great. What did revenue look like last quarter?"),
            TranscriptLine(speaker: .me, start: 27, text: "Up 18% year over year, mostly from the enterprise plan."),
        ]
        if live {
            startedAt = Date().addingTimeInterval(-754)
            state = .recording
            meter.update(me: 0.75, them: 0.35)
        } else {
            callHint = "Zoom"
        }
    }

    func shutdown() {
        unloadTask?.cancel()
        whisper.stop()
    }

    // MARK: Recording

    func toggle() {
        switch state {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        default: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        state = .starting
        status = nil
        lines = []
        duration = 0
        warmUp()        // load the engine while the audio starts; early speech queues until it's ready

        guard await requestMicAccess() else {
            status = "Microphone access denied — enable it in System Settings › Privacy › Microphone."
            state = .idle
            return
        }

        callApp = Self.frontmostCallApp()
        justSaved = false
        summary = nil
        summaryError = nil
        callHint = nil
        let folder = Self.notesRoot.appendingPathComponent(Self.folderName(for: Date(), app: callApp), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessionFolder = folder

        let uptime = ProcessInfo.processInfo.systemUptime
        let me = Track(speaker: .me, sessionStart: uptime, fileURL: folder.appendingPathComponent("me.wav"))
        let them = Track(speaker: .them, sessionStart: uptime, fileURL: folder.appendingPathComponent("them.wav"))
        for track in [me, them] {
            track.onChunk = { [weak self] chunk in
                Task { @MainActor in self?.enqueue(chunk) }
            }
        }
        meTrack = me
        themTrack = them

        // System audio (other participants).
        let sys = SystemAudioCapture()
        sys.onSamples = { [weak them] in them?.append($0) }
        sys.onError = { [weak self] error in
            Task { @MainActor in self?.status = "System audio stopped: \(error.localizedDescription)" }
        }
        do {
            try await sys.start()
            system = sys
        } catch {
            status = "Can’t hear the call yet — allow Hoot in System Settings › Privacy › Screen & System Audio Recording, then reopen Hoot. (\(error.localizedDescription))"
        }

        // Microphone (me).
        let m = MicCapture()
        m.onSamples = { [weak me] in me?.append($0) }
        m.onRestartFailed = { [weak self] error in
            Task { @MainActor in self?.status = "Lost your microphone after a device change: \(error.localizedDescription)" }
        }
        do {
            try m.start(echoCancellation: echoCancellation)
            mic = m
        } catch {
            // Voice processing isn't available on every device; fall back to the raw mic.
            let plain = MicCapture()
            plain.onSamples = { [weak me] in me?.append($0) }
            do {
                try plain.start(echoCancellation: false)
                mic = plain
            } catch {
                status = "Microphone failed: \(error.localizedDescription)"
            }
        }

        if mic == nil && system == nil {
            state = .idle
            return
        }

        startedAt = Date()
        state = .recording
        // Only the meter is updated this often, and only the views that draw it re-render.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.meter.update(me: self.meTrack?.level ?? 0, them: self.themTrack?.level ?? 0)
            }
        }
        writeTranscript()
    }

    func stop() async {
        guard state == .recording else { return }
        duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        state = .finishing
        timer?.invalidate()
        timer = nil
        meter.reset()

        mic?.stop()
        await system?.stop()
        mic = nil
        system = nil
        meTrack?.finish()
        themTrack?.finish()
        meTrack = nil
        themTrack = nil

        // Let queued chunks finish transcribing.
        while pendingChunks > 0 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        writeTranscript()
        if let folder = sessionFolder {
            Self.mixConversation(in: folder, deleteTracks: !keepTracks)
            // Keep a copy of what you had on your cue card alongside this meeting's transcript.
            if let notes = speakerNotes?.text, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? notes.write(to: folder.appendingPathComponent("speaker-notes.md"), atomically: true, encoding: .utf8)
            }
            if let answers = aiAssist?.markdown(since: startedAt ?? .distantPast) {
                try? answers.write(to: folder.appendingPathComponent("ai-assist.md"), atomically: true, encoding: .utf8)
            }
        }
        state = .idle
        justSaved = true
        scheduleUnload()
        if lines.count >= 2 { Task { await summarize() } }
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if state == .idle { justSaved = false }
        }
    }

    // MARK: Transcription queue

    private func enqueue(_ chunk: SpeechChunk) {
        queue.append(chunk)
        pendingChunks += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.dequeue() {
                await self.transcribe(next)
                self.pendingChunks -= 1
            }
            self?.worker = nil
        }
    }

    private func dequeue() -> SpeechChunk? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func transcribe(_ chunk: SpeechChunk) async {
        // Wait for the engine if it is still loading (or downloading the first time).
        if engine == .unloaded { warmUp() }
        for _ in 0..<600 where !serverReady {
            if case .failed = engine { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // The last thing this speaker said helps Whisper keep names and context consistent.
        let prompt = lines.last(where: { $0.speaker == chunk.speaker })?.text
        do {
            let raw: String
            do {
                raw = try await whisper.transcribe(chunk.samples, prompt: prompt)
            } catch {
                // The speech engine may have crashed; bring it back and give this bit one more try.
                guard await !whisper.isHealthy() else { throw error }
                status = "Speech engine hiccup — restarting it…"
                whisper.stop()
                engine = .loading
                try await whisper.start(language: language)
                engine = .ready
                raw = try await whisper.transcribe(chunk.samples, prompt: prompt)
                if status?.hasPrefix("Speech engine") == true { status = nil }
            }
            guard let text = TextCleaner.clean(raw, voicedRatio: chunk.voicedRatio) else { return }
            if chunk.speaker == .me, isEcho(text, at: chunk.start) { return }
            insert(TranscriptLine(speaker: chunk.speaker, start: chunk.start, text: text))
        } catch {
            status = error.localizedDescription
        }
    }

    /// Without headphones the mic hears the other side too; drop "Me" lines that repeat "Them".
    private func isEcho(_ text: String, at start: TimeInterval) -> Bool {
        let words = TextCleaner.words(text)
        guard words.count >= 3 else { return false }
        for line in lines where line.speaker == .them && abs(line.start - start) < 25 {
            let other = TextCleaner.words(line.text)
            let overlap = Double(words.intersection(other).count) / Double(words.count)
            if overlap > 0.6 { return true }
        }
        return false
    }

    private func insert(_ line: TranscriptLine) {
        let index = lines.firstIndex(where: { $0.start > line.start }) ?? lines.endIndex
        lines.insert(line, at: index)
        writeTranscript()
    }

    // MARK: Output

    private func writeTranscript() {
        guard let folder = sessionFolder else { return }
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        var md = "# \(callApp.map { "\($0) call" } ?? "Meeting") — \(df.string(from: startedAt ?? Date()))\n\n"
        if state != .recording && state != .starting {
            md += "Duration: \(Self.clock(elapsed))\n\n"
        }
        if let summary { md += summary + "\n\n## Transcript\n" }
        var lastSpeaker: Speaker?
        for line in lines {
            if line.speaker != lastSpeaker {
                md += "\n**[\(Self.clock(line.start))] \(line.speaker.name):** "
                lastSpeaker = line.speaker
            } else {
                md += " "
            }
            md += line.text
        }
        md += "\n"
        try? md.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    /// Mixes both tracks into one listenable conversation.m4a with AVFoundation (no extra tools needed).
    nonisolated static func mixConversation(in folder: URL, deleteTracks: Bool = false, then done: (@Sendable () -> Void)? = nil) {
        Task.detached(priority: .utility) {
            let composition = AVMutableComposition()
            for name in ["me.wav", "them.wav"] {
                let asset = AVURLAsset(url: folder.appendingPathComponent(name))
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      let duration = try? await asset.load(.duration),
                      let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            }
            guard !composition.tracks.isEmpty,
                  let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return }
            let output = folder.appendingPathComponent("conversation.m4a")
            try? FileManager.default.removeItem(at: output)
            if #available(macOS 15.0, *) {
                try? await export.export(to: output, as: .m4a)
            }
            // Only remove the raw tracks once the mix really exists.
            if deleteTracks, let size = try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int, size > 1_000 {
                for name in ["me.wav", "them.wav"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            }
            done?()
        }
    }

    private func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    nonisolated static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Date first so folders sort in order, then the call app, e.g. "2026-10-19 09.10 · Zoom".
    private static func folderName(for date: Date, app: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        return df.string(from: date) + (app.map { " · \($0)" } ?? "")
    }

    /// The bubble never takes focus, so the frontmost app is usually the call you're in.
    private static func frontmostCallApp() -> String? {
        let known = [
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
            "com.apple.FaceTime": "FaceTime",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.hnc.Discord": "Discord",
            "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex",
            "net.whatsapp.WhatsApp": "WhatsApp",
            "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan": "Google Meet",
        ]
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return known[id]
    }
}

enum TextCleaner {
    /// Phrases Whisper tends to invent on near-silence.
    private static let hallucinations: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "you", "bye", "okay",
        "please subscribe", "subtitles by the amaraorg community", "so", "uh", "um",
    ]

    static func clean(_ raw: String, voicedRatio: Double) -> String? {
        var text = raw.replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*\\)|\\*[^*]*\\*",
                                            with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let normalized = words(text).sorted().joined(separator: " ")
        let plain = text.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if hallucinations.contains(plain) && voicedRatio < 0.5 { return nil }
        if normalized.isEmpty { return nil }
        return text
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}
