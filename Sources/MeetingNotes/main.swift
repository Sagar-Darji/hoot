import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let recorder = Recorder()
    private let speakerNotes = SpeakerNotes()
    private let assist = AIAssist()
    private let nav = PanelNav()
    private let prefs = Preferences()
    private let setup = SetupStatus()
    private let updates = UpdateChecker()
    private let callDetector = CallDetector()

    private var presence: FloatingPanel?          // the bubble or the notch island
    private var notch: NotchGeometry?             // set while Hoot lives in the notch
    private var panel: FloatingPanel!             // the one window: Transcript · Notes · AI
    private var panelPlaced = false
    private var settingsWindow: NSWindow?
    private var observers: Set<AnyCancellable> = []

    private lazy var actions = OverlayActions(
        toggleTranscript: { [weak self] in self?.toggle(.transcript) },
        toggleNotes: { [weak self] in self?.toggle(.notes) },
        toggleAssist: { [weak self] in self?.toggle(.assist) },
        togglePanel: { [weak self] in self?.togglePanel() },
        openSettings: { [weak self] in self?.showSettings() },
        quit: { NSApp.terminate(nil) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Hoot at a time: opening it again just brings the running one forward.
        let showcase = ProcessInfo.processInfo.environment["HOOT_SHOWCASE"]
        if showcase == nil, let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)   // no Dock icon; the bubble / island is the whole UI
        installMainMenu()

        // A real macOS window (toolbar, close button, resizing) floating above everything.
        panel = FloatingPanel(size: NSSize(width: 440, height: 540), autosaveKey: "HootWindow", titled: true)
        let host = NSHostingController(rootView: HootPanelView(nav: nav, recorder: recorder, assist: assist, notes: speakerNotes))
        host.sizingOptions = []                       // the user sizes the window, not the content
        host.sceneBridgingOptions = [.toolbars, .title]
        panel.contentViewController = host
        panel.title = "Hoot"
        panel.minSize = NSSize(width: 360, height: 300)
        panel.setContentSize(NSSize(width: 440, height: 540))
        // Remember where the user parks it (e.g. next to the camera); only place it the very first time.
        panelPlaced = panel.setFrameUsingName("HootWindow")

        recorder.speakerNotes = speakerNotes
        recorder.aiAssist = assist
        speakerNotes.doc.isVisible = { [weak self] in
            guard let self else { return false }
            return self.panel.isVisible && self.nav.tab == .notes && self.speakerNotes.showDoc
        }
        assist.isVisible = { [weak self] in
            guard let self else { return false }
            return self.panel.isVisible && self.nav.tab == .assist
        }
        assist.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        assist.start()

        // "Window Opacity" (Notes and AI tabs) makes the window see-through, to read what's behind it.
        Publishers.CombineLatest3(nav.$tab, speakerNotes.$opacity, assist.$opacity)
            .sink { [weak self] tab, notesOpacity, assistOpacity in
                self?.panel.alphaValue = tab == .notes ? notesOpacity : tab == .assist ? assistOpacity : 1
            }
            .store(in: &observers)

        prefs.onPresenceChange = { [weak self] in self?.buildPresence() }
        buildPresence()

        // Light at rest: the speech model is downloaded if missing, but only loaded when a meeting starts.
        recorder.prepareModel()
        GlassFrames.shared.prepare()

        HotKeys.register(HotKeys.record.key) { [weak self] in self?.recorder.toggle() }
        HotKeys.register(HotKeys.notes.key) { [weak self] in self?.toggle(.notes) }
        HotKeys.register(HotKeys.assist.key) { [weak self] in self?.toggle(.assist) }
        HotKeys.register(HotKeys.transcript.key) { [weak self] in self?.toggle(.transcript) }

        callDetector.isRecording = { [weak self] in self?.recorder.state != .idle }
        callDetector.onCallStarted = { [weak self] app in self?.recorder.callHint = app }
        callDetector.onCallEnded = { [weak self] in self?.recorder.callHint = nil }
        callDetector.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        if let showcase {
            self.showcase(showcase)
        } else {
            // First run (or something essential still missing): open the Setup checklist.
            if !UserDefaults.standard.bool(forKey: "onboarded") || !setup.essentialsReady {
                UserDefaults.standard.set(true, forKey: "onboarded")
                showSettings(.setup)
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

    // MARK: Bubble or island

    /// Puts Hoot in the notch (as a Dynamic Island) when there is one and it's wanted, else a floating bubble.
    private func buildPresence() {
        presence?.orderOut(nil)
        presence = nil
        if prefs.useNotch, let geometry = NotchGeometry.current() {
            notch = geometry
            let island = FloatingPanel(size: geometry.notch.size, autosaveKey: "")
            island.title = "island"
            island.allowsMenuBarOverlap = true
            island.level = .statusBar + 1
            let host = NSHostingView(rootView: IslandView(
                recorder: recorder, assist: assist, updates: updates, notch: geometry.notch.size, actions: actions,
                onResize: { [weak island] in island?.fit($0, anchor: .topCenter) }))
            host.sizingOptions = []                 // we size the window (fit), not AppKit
            island.contentView = host
            island.anchorMidX = geometry.notch.midX
            island.setFrame(geometry.notch, display: false)
            island.orderFrontRegardless()
            presence = island
        } else {
            notch = nil
            let bubble = FloatingPanel(size: NSSize(width: 60, height: 60), autosaveKey: "BubblePanel")
            bubble.title = "bubble"
            let host = NSHostingView(rootView: BubbleView(
                recorder: recorder, assist: assist, updates: updates, actions: actions,
                onResize: { [weak bubble] in bubble?.fit($0) }))
            host.sizingOptions = []
            bubble.contentView = host
            if !bubble.setFrameUsingName("BubblePanel"), let screen = NSScreen.main {
                let f = screen.visibleFrame
                bubble.setFrameOrigin(NSPoint(x: f.maxX - 300, y: f.maxY - 80))
            }
            bubble.keepOnScreen()
            bubble.orderFrontRegardless()
            presence = bubble
        }
    }

    /// Displays came or went (e.g. the lid closed on an external monitor): move between notch and bubble.
    private func screensChanged() {
        let wantsIsland = prefs.useNotch && NotchGeometry.current() != nil
        if wantsIsland != (notch != nil) || (wantsIsland && NotchGeometry.current() != notch) {
            buildPresence()
        } else {
            presence?.keepOnScreen()
        }
        panel.keepOnScreen()
    }

    // MARK: Window

    /// Shows the window on `tab`, or hides it if it's already showing that tab.
    private func toggle(_ tab: PanelNav.Tab) {
        if panel.isVisible && nav.tab == tab { panel.orderOut(nil); return }
        nav.tab = tab
        show()
    }

    /// From the bubble or island: opens on whatever is most useful (a new AI answer first), or hides.
    private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        if assist.hasUnseen { nav.tab = .assist }
        show()
    }

    private func show() {
        if !panelPlaced {
            placePanel()
            panelPlaced = true
        }
        panel.orderFrontRegardless()
        if nav.tab == .assist { assist.hasUnseen = false }
        if nav.tab == .notes {
            if speakerNotes.showDoc, !speakerNotes.doc.link.isEmpty { Task { await speakerNotes.doc.refresh() } }
            panel.makeKey()   // ready to type straight away
        }
    }

    /// The first time, open the window just below the island, or next to the bubble.
    private func placePanel() {
        let size = panel.frame.size
        if let notch {
            let area = notch.screenFrame
            let x = min(max(notch.notch.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: notch.notch.minY - size.height - 12))
            return
        }
        guard let bubble = presence, let screen = bubble.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let b = bubble.frame
        var y = b.minY - size.height + 4
        if y < area.minY { y = b.maxY - 4 }
        let x = min(max(b.minX + 4, area.minX + 8), area.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: min(max(y, area.minY), area.maxY - size.height)))
    }

    // MARK: Settings

    private func showSettings(_ tab: Preferences.Tab? = nil) {
        if let tab { prefs.tab = tab }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(prefs: prefs, recorder: recorder, assist: assist,
                                                                  setup: setup, updates: updates))
            let window = NSWindow(contentViewController: host)
            window.title = "Hoot Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        setup.startWatching()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { setup.stopWatching() }
    }

    // MARK: Showcase

    /// Opens the window on one tab with sample content so the design can be reviewed in a screenshot.
    private func showcase(_ tab: String) {
        if ProcessInfo.processInfo.environment["HOOT_BACKDROP"] != nil { showBackdrop() }
        recorder.loadShowcase(live: tab == "live")
        assist.loadShowcase()
        speakerNotes.loadShowcase()
        if tab == "live" { return }
        // Announce the sample call again once the island exists, so it drops down like it would for real.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recorder.callHint = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.recorder.callHint = "Zoom" }
        }
        // Prefer the built-in (Retina) display, so product shots come out sharp.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        if notch == nil { presence?.setFrameOrigin(NSPoint(x: area.minX + 40, y: area.maxY - 90)) }
        if tab == "settings" { showSettings(.setup); return }
        nav.tab = PanelNav.Tab(rawValue: tab) ?? .transcript
        panel.setFrame(NSRect(x: area.minX + 40, y: area.maxY - 640, width: 440, height: 540), display: true)
        panel.orderFrontRegardless()
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

    @objc private func openSettingsFromMenu() { showSettings() }
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
        let noActions = OverlayActions(toggleTranscript: {}, toggleNotes: {}, toggleAssist: {}, togglePanel: {}, openSettings: {}, quit: {})
        @MainActor func save(_ name: String, live: Bool, open: Bool) {
            let recorder = Recorder()
            recorder.loadShowcase(live: live)
            if live { recorder.callHint = nil }
            let view = IslandView(recorder: recorder, assist: AIAssist(), updates: UpdateChecker(), notch: notch,
                                  actions: noActions, onResize: { _ in }, forceOpen: open)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            renderer.isOpaque = false
            if let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name))
            }
        }
        save("island-live.png", live: true, open: false)
        save("island-open.png", live: false, open: true)
        save("island-open-live.png", live: true, open: true)
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
