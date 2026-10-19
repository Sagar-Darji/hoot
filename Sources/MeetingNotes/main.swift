import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let speakerNotes = SpeakerNotes()
    private let assist = AIAssist()
    private let prefs = Preferences()
    private let setup = SetupStatus()
    private let updates = UpdateChecker()
    private let island = IslandModel()
    private let callDetector = CallDetector()

    private var window: FloatingPanel?            // the island — Hoot's only window
    private var geometry: NotchGeometry?
    private var outsideClick: Any?
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Hoot at a time: opening it again just brings the running one forward.
        let showcase = ProcessInfo.processInfo.environment["HOOT_SHOWCASE"]
        if showcase == nil, let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)   // no Dock icon; the island is the whole UI
        installMainMenu()

        recorder.speakerNotes = speakerNotes
        recorder.aiAssist = assist
        speakerNotes.doc.isVisible = { [weak self] in
            guard let self else { return false }
            return self.island.tab == .notes && self.speakerNotes.showDoc
        }
        assist.isVisible = { [weak self] in self?.island.tab == .assist }
        assist.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        assist.start()

        buildIsland()
        island.$tab.removeDuplicates().sink { [weak self] tab in self?.panelChanged(tab) }.store(in: &observers)

        // Light at rest: the speech model is downloaded if missing, but only loaded when a meeting starts.
        recorder.prepareModel()
        GlassFrames.shared.prepare()

        HotKeys.register(HotKeys.record.key) { [weak self] in self?.recorder.toggle() }
        HotKeys.register(HotKeys.notes.key) { [weak self] in self?.island.toggle(.notes) }
        HotKeys.register(HotKeys.assist.key) { [weak self] in self?.island.toggle(.assist) }
        HotKeys.register(HotKeys.transcript.key) { [weak self] in self?.island.toggle(.transcript) }

        callDetector.isRecording = { [weak self] in self?.recorder.state != .idle }
        callDetector.onCallStarted = { [weak self] app in self?.recorder.callHint = app }
        callDetector.onCallEnded = { [weak self] in self?.recorder.callHint = nil }
        callDetector.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NotchGeometry.current() != self.geometry else { return }
                self.buildIsland()
            }
        }

        if let showcase {
            self.showcase(showcase)
        } else {
            // First run (or something essential still missing): welcome and set up inside the island.
            if !UserDefaults.standard.bool(forKey: "onboarded") || !setup.essentialsReady {
                UserDefaults.standard.set(true, forKey: "onboarded")
                island.welcome = true
                island.open(.settings)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.updates.checkIfDue() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        speakerNotes.save()
        recorder.shutdown()
    }

    // MARK: The island

    /// Around the notch on MacBooks that have one; a virtual notch at the top centre elsewhere.
    private func buildIsland() {
        window?.orderOut(nil)
        window = nil
        guard let geometry = NotchGeometry.current() else { return }
        self.geometry = geometry
        let panel = FloatingPanel(size: geometry.notch.size)
        panel.title = "island"
        panel.allowsMenuBarOverlap = true
        panel.level = .statusBar + 1
        panel.anchorMidX = geometry.notch.midX
        panel.onCancel = { [weak self] in self?.island.close() }
        let host = NSHostingView(rootView: IslandView(
            model: island, recorder: recorder, assist: assist, updates: updates, prefs: prefs,
            notes: speakerNotes, setup: setup, notch: geometry.notch.size,
            onResize: { [weak panel] in panel?.fit($0) }))
        host.sizingOptions = []                 // the island sizes its window (once per change), not AppKit
        panel.contentView = host
        panel.setFrame(geometry.notch, display: false)
        panel.orderFrontRegardless()
        window = panel
    }

    /// The panel opened or closed: take keyboard focus for typing, and close on a click elsewhere unless pinned.
    private func panelChanged(_ tab: IslandModel.Tab?) {
        guard tab != nil else {
            if let monitor = outsideClick { NSEvent.removeMonitor(monitor) }
            outsideClick = nil
            return
        }
        window?.makeKey()
        if tab == .assist { assist.hasUnseen = false }
        if tab == .notes, speakerNotes.showDoc, !speakerNotes.doc.link.isEmpty { Task { await speakerNotes.doc.refresh() } }
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.island.pinned else { return }
                    self.island.close()
                }
            }
        }
    }

    // MARK: Showcase

    /// Opens the island on one tab with sample content, so the design can be reviewed in a screenshot.
    private func showcase(_ tab: String) {
        if ProcessInfo.processInfo.environment["HOOT_BACKDROP"] != nil { showBackdrop() }
        recorder.loadShowcase(live: tab == "live")
        assist.loadShowcase()
        speakerNotes.loadShowcase()
        switch tab {
        case "live":
            return
        case "controls":
            // Announce the sample call once the island exists, so the controls drop down like they would for real.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.recorder.callHint = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.recorder.callHint = "Zoom" }
            }
        default:
            island.pinned = true
            island.open(IslandModel.Tab(rawValue: tab) ?? .transcript)
        }
    }

    /// A clean wallpaper-like gradient behind everything, so product screenshots show no desktop content.
    private var backdrop: NSWindow?
    private func showBackdrop() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .normal
        window.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.52), Color(red: 0.45, green: 0.22, blue: 0.62),
                                    Color(red: 0.86, green: 0.38, blue: 0.56)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.25), .clear], center: UnitPoint(x: 0.3, y: 0.25), startRadius: 0, endRadius: 700)
        })
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    /// ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z and ⌘, are routed through the main menu. Hoot never shows one, but without
    /// it those shortcuts do nothing.
    private func installMainMenu() {
        let app = NSMenu(title: "Hoot")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Hoot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "Hoot", action: nil, keyEquivalent: "")
        appItem.submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit

        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { island.open(.settings) }
}

/// `MeetingNotes --transcribe-file <audio>` runs a file through the same chunker + Whisper path
/// as live recording and prints the result. Handy for testing and for re-transcribing old sessions.
func transcribeFile(_ path: String) async {
    do {
        let server = WhisperServer()
        try await server.start(language: UserDefaults.standard.string(forKey: "language") ?? "auto")
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let resampler = MonoResampler()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mn-test.wav")
        let track = Track(speaker: .them, sessionStart: ProcessInfo.processInfo.systemUptime, fileURL: tmp)
        var chunks: [SpeechChunk] = []
        track.onChunk = { chunks.append($0) }
        let block: AVAudioFrameCount = 4096
        while file.framePosition < file.length,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) {
            try file.read(into: buf, frameCount: block)
            track.append(resampler.process(buf))
        }
        track.finish()
        for chunk in chunks {
            let raw = try await server.transcribe(chunk.samples, prompt: nil)
            let text = TextCleaner.clean(raw, voicedRatio: chunk.voicedRatio) ?? "<dropped: \(raw)>"
            print("[\(Recorder.clock(chunk.start))] (\(String(format: "%.1f", chunk.duration))s) \(text)")
        }
        server.stop()
    } catch {
        print("error: \(error.localizedDescription)")
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ax-dump" {
    try? AXReader.dump().write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
    exit(0)
}

/// `MeetingNotes --render-orbs <png>`: draws the orb in every state, large, for design review.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-orbs" {
    MainActor.assumeIsolated {
        GlassFrames.shared.prepareNow(pixels: 192)
        let row = HStack(spacing: 36) {
            ForEach(Array([(HootOrb.Mood.idle, Float(0), Float(0), false), (.sleeping, 0, 0, false), (.listening, 0.8, 0.05, false),
                           (.listening, 0.05, 0.8, false), (.busy, 0, 0, false), (.saved, 0, 0, false), (.idle, 0, 0, true)].enumerated()),
                    id: \.offset) { _, item in
                let meter = LiveMeter()
                let _ = meter.update(me: item.1, them: item.2)
                HootOrb(mood: item.0, meter: meter, glow: item.3, size: 96)
                    .frame(width: 140, height: 140)
            }
        }
        .padding(30)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
    exit(0)
}

/// `MeetingNotes --render-icon <png>`: draws the 1024×1024 app icon artwork.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: HootIconArt())
        renderer.scale = 1
        if let cg = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
    exit(0)
}

/// `MeetingNotes --render-forms <png>`: the icon in each abstract bird form, side by side.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-forms" {
    MainActor.assumeIsolated {
        let sheet = HStack(spacing: 0) {
            ForEach(HootMark.Form.allCases, id: \.self) { form in
                VStack(spacing: 0) {
                    HootIconArt(form: form)
                    Text(form.rawValue.capitalized).font(.system(size: 64, weight: .semibold)).foregroundStyle(.white)
                        .padding(.bottom, 40)
                }
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 0.5
        if let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
    exit(0)
}

/// `MeetingNotes --render-island <dir>`: the island's states as transparent PNGs, for the website.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-island" {
    MainActor.assumeIsolated {
        GlassFrames.shared.prepareNow(pixels: 96)
        let dir = URL(fileURLWithPath: CommandLine.arguments[2])
        let notch = CGSize(width: 185, height: 32)
        @MainActor func save(_ name: String, live: Bool, mode: IslandView.Mode, tab: IslandModel.Tab? = nil) {
            let recorder = Recorder()
            recorder.loadShowcase(live: live)
            if live { recorder.callHint = nil }
            let assist = AIAssist()
            assist.loadShowcase()
            let notes = SpeakerNotes()
            notes.loadShowcase()
            let model = IslandModel()
            if let tab { model.open(tab) }
            let view = IslandView(model: model, recorder: recorder, assist: assist, updates: UpdateChecker(), prefs: Preferences(),
                                  notes: notes, setup: SetupStatus(), notch: notch, onResize: { _ in }, forceMode: mode)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            renderer.isOpaque = false
            if let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name))
            }
        }
        save("island-rest.png", live: false, mode: .rest)
        save("island-live.png", live: true, mode: .live)
        save("island-open.png", live: false, mode: .controls)
        save("island-open-live.png", live: true, mode: .controls)
        save("island-transcript.png", live: true, mode: .panel, tab: .transcript)
        save("island-notes.png", live: false, mode: .panel, tab: .notes)
        save("island-ai.png", live: false, mode: .panel, tab: .assist)
    }
    exit(0)
}

/// `MeetingNotes --summarize-demo`: runs the on-device summarizer on a short sample conversation.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--summarize-demo" {
    Task { @MainActor in
        let sample: [TranscriptLine] = [
            TranscriptLine(speaker: .them, start: 3, text: "Thanks for joining. Let's review the roadmap and pick a launch date."),
            TranscriptLine(speaker: .me, start: 9, text: "I think we should launch on November 5th. Marketing has the campaign ready."),
            TranscriptLine(speaker: .them, start: 21, text: "Agreed, November 5th it is. Can you send the pricing deck to Priya by Friday?"),
            TranscriptLine(speaker: .me, start: 27, text: "Yes, I'll send it Friday. Revenue was up 18% last quarter, mostly enterprise."),
            TranscriptLine(speaker: .them, start: 35, text: "We still need to decide whether the free tier stays. Let's revisit next week."),
        ]
        do { print(try await Summarizer.summarize(sample)) } catch { print("error: \(error.localizedDescription)") }
        print("\n--- Ask: What should I say? (streaming)")
        var updates = 0, last = ""
        do {
            for try await text in MeetingAI.ask(MeetingAI.quickPrompts[1].prompt, transcript: sample, notes: "Mention the beta waitlist (2,300 signups).") {
                updates += 1; last = text
            }
            print(last); print("(\(updates) streamed updates)")
        } catch { print("error: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
}

/// `MeetingNotes --mix-folder <dir>`: mixes me.wav + them.wav into conversation.m4a, like after a meeting.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--mix-folder" {
    Recorder.mixConversation(in: URL(fileURLWithPath: CommandLine.arguments[2])) { exit(0) }
    RunLoop.main.run()
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fetch-doc" {
    // The fetcher runs on the main actor, so keep the main run loop free instead of blocking on a semaphore.
    Task { @MainActor in
        print(await LinkedDoc.debugFetch(CommandLine.arguments[2]))
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe-file" {
    let done = DispatchSemaphore(value: 0)
    Task { await transcribeFile(CommandLine.arguments[2]); done.signal() }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
