import AppKit
import ApplicationServices

struct AIEntry: Identifiable, Equatable {
    let id = UUID()
    let source: String       // "Claude", "ChatGPT", "Gemini", "Browser", "iPhone", …
    var text: String
    var time: Date
    var question: String? = nil        // set for answers Hoot asked Apple Intelligence for
}

/// Collects the latest answers from your AI apps so the overlay can show them mid-meeting.
/// Three ways in: reading the AI apps directly (Accessibility), anything you copy from them
/// (incl. Universal Clipboard from your iPhone/iPad/other Mac), and a private Wi-Fi drop page.
@MainActor
final class AIAssist: ObservableObject {
    nonisolated static let apps: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.codex": "ChatGPT", "com.openai.chat": "ChatGPT",
        "com.google.GeminiMacOS": "Gemini",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "ai.perplexity.comet",
    ]

    @Published private(set) var entries: [AIEntry] = []
    @Published var index = 0                       // which entry is on screen
    @Published var hasUnseen = false
    @Published private(set) var axTrusted = AXIsProcessTrusted()

    @Published var autoRead = UserDefaults.standard.object(forKey: "assistAutoRead") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRead, forKey: "assistAutoRead") }
    }
    @Published var catchClipboard = UserDefaults.standard.object(forKey: "assistClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(catchClipboard, forKey: "assistClipboard") }
    }
    /// Off: only copies made in AI apps, browsers or other devices count. On: anything you copy.
    @Published var catchAllCopies = UserDefaults.standard.bool(forKey: "assistAllCopies") {
        didSet { UserDefaults.standard.set(catchAllCopies, forKey: "assistAllCopies") }
    }
    @Published var fontSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "assistFontSize") as? Double ?? 14) {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "assistFontSize") }
    }
    @Published var opacity: Double = UserDefaults.standard.object(forKey: "assistOpacity") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(opacity, forKey: "assistOpacity") }
    }

    let drop = DropServer()
    @Published private(set) var dropError: String?
    @Published var receiveFromDevices = UserDefaults.standard.bool(forKey: "assistDrop") {
        didSet {
            UserDefaults.standard.set(receiveFromDevices, forKey: "assistDrop")
            syncDrop()
        }
    }
    var isVisible: () -> Bool = { false }          // set by the app; auto-read only runs while it matters
    var isRecording: () -> Bool = { false }

    private var pasteboardCount = NSPasteboard.general.changeCount
    private var ignoreCount: Int?
    private var timer: Timer?
    private var lastAXPoll = Date.distantPast
    private let reader = AXReader()
    private let axQueue = DispatchQueue(label: "hoot.ax", qos: .utility)
    private var axBusy = false
    /// When each AI app was last in front. Only apps you've just used are read, which keeps this cheap
    /// for Hoot and avoids slowing the AI apps down by reading them needlessly.
    private var lastActive: [pid_t: Date] = [:]
    private var activationObserver: NSObjectProtocol?

    var current: AIEntry? { entries.indices.contains(index) ? entries[index] : nil }

    init() {
        drop.onText = { [weak self] text, device in
            Task { @MainActor in self?.add(source: device, text: text) }
        }
    }

    func start() {
        syncDrop()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.3
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, Self.apps[id] != nil else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.lastActive[pid] = Date() }
        }
    }

    private func syncDrop() {
        dropError = nil
        guard receiveFromDevices else { return drop.stop() }
        do { try drop.start() } catch { dropError = "Couldn't open the Wi-Fi drop: \(error.localizedDescription)" }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        axTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !axTrusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @Published private(set) var asking = false
    @Published var askError: String?
    private var askTask: Task<Void, Never>?

    /// Asks Apple Intelligence about the meeting; the answer streams into a new card.
    func ask(_ question: String, transcript: [TranscriptLine], notes: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askTask?.cancel()
        askError = nil
        asking = true
        entries.append(AIEntry(source: "Apple Intelligence", text: "", time: Date(), question: q))
        index = entries.count - 1
        let slot = entries[index].id
        askTask = Task { [weak self] in
            do {
                for try await text in MeetingAI.ask(q, transcript: transcript, notes: notes) {
                    guard let self, let i = self.entries.firstIndex(where: { $0.id == slot }) else { return }
                    self.entries[i].text = text
                }
            } catch {
                guard let self else { return }
                self.askError = error.localizedDescription
                self.entries.removeAll { $0.id == slot && $0.text.isEmpty }
                self.index = max(0, self.entries.count - 1)
            }
            self?.asking = false
        }
    }

    /// Copies an answer without it bouncing back in as a new entry.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ignoreCount = NSPasteboard.general.changeCount
    }

    func show(_ i: Int) {
        index = max(0, min(entries.count - 1, i))
        if index == entries.count - 1 { hasUnseen = false }
    }

    /// Sample answers for `HOOT_SHOWCASE=1` (design review screenshots only).
    func loadShowcase() {
        add(source: "ChatGPT", text: "Typical B2B SaaS net revenue retention is **100–120%**.")
        add(source: "Claude", text: "**Q3 revenue grew 18% year over year**, driven mainly by the enterprise plan (+31%).\n\nTalking points:\n• Enterprise seats up 2.4×\n• Churn down to 1.8% monthly\n• Launch on **November 5** keeps us ahead of the holiday freeze")
        hasUnseen = false
    }

    func clear() {
        entries = []
        index = 0
        hasUnseen = false
    }

    /// Everything that arrived since `date`, as Markdown, for the meeting folder.
    func markdown(since date: Date) -> String? {
        let recent = entries.filter { $0.time >= date }
        guard !recent.isEmpty else { return nil }
        let df = DateFormatter()
        df.timeStyle = .short
        return "# AI Assist\n\n" + recent.map { "## \($0.source) · \(df.string(from: $0.time))\n\n\($0.text)\n" }
            .joined(separator: "\n")
    }

    // MARK: Intake

    private func tick() {
        checkClipboard()
        if !axTrusted { axTrusted = AXIsProcessTrusted() }
        let visible = isVisible()
        guard autoRead, axTrusted, !axBusy, Date().timeIntervalSince(lastAXPoll) >= (visible ? 1.5 : 3),
              visible || isRecording() else { return }
        lastAXPoll = Date()
        let now = Date()
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
            guard let id = app.bundleIdentifier, let name = Self.apps[id] else { return nil }
            let recentlyUsed = app.isActive || now.timeIntervalSince(lastActive[app.processIdentifier] ?? .distantPast) < 180
            return recentlyUsed ? (app.processIdentifier, name) : nil
        }
        guard !running.isEmpty else { return }
        axBusy = true
        let reader = reader
        axQueue.async { [weak self] in
            let found = reader.poll(running)
            Task { @MainActor in
                guard let self else { return }
                self.axBusy = false
                for (source, text) in found { self.add(source: source, text: text) }
            }
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardCount else { return }
        pasteboardCount = pb.changeCount
        guard catchClipboard, pb.changeCount != ignoreCount else { return }
        let types = pb.types ?? []
        // Password managers mark secrets as concealed/transient — never show those.
        if types.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue) }) { return }
        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let source: String?
        if types.contains(where: { $0.rawValue == "com.apple.is-remote-clipboard" }) {
            source = "Other device"
        } else if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            if let name = Self.apps[id] { source = name }
            else if Self.browsers.contains(id) { source = "Browser" }
            else { source = catchAllCopies ? "Copied" : nil }
        } else {
            source = catchAllCopies ? "Copied" : nil
        }
        if let source { add(source: source, text: text) }
    }

    private func add(source: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A reply that is still growing (or copied right after auto-read caught it) updates the same card.
        if let last = entries.last, last.source == source || text == last.text,
           Date().timeIntervalSince(last.time) < 120,
           text == last.text || text.hasPrefix(String(last.text.prefix(80))) {
            entries[entries.count - 1].text = text
            entries[entries.count - 1].time = Date()
        } else {
            entries.append(AIEntry(source: source, text: text, time: Date()))
            if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        }
        index = entries.count - 1
        hasUnseen = !isVisible()
    }
}

/// Reads the visible conversation in each AI app through the Accessibility tree and reports what's new
/// once it stops changing (i.e. the reply finished streaming). Runs on a background queue.
final class AXReader: @unchecked Sendable {
    private struct AppState {
        var last: [String]? = nil
        var pending: [String]? = nil
        var pendingSince = Date()
        var recentInputs: [String] = []
    }
    private var states: [pid_t: AppState] = [:]

    func poll(_ apps: [(pid: pid_t, name: String)]) -> [(String, String)] {
        var out: [(String, String)] = []
        for (pid, name) in apps {
            var st = states[pid] ?? AppState()
            defer { states[pid] = st }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.6)
            if st.last == nil {
                // Electron/Chromium apps (Claude) only build their accessibility tree when asked to.
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            let focused = Self.attr(app, "AXFocusedWindow").map { $0 as! AXUIElement }
            guard let window = focused ?? (Self.attr(app, "AXWindows") as? [AXUIElement])?.first else { continue }

            var texts: [String] = []
            var inputs: [String] = []
            var budget = 12_000
            Self.collect(window, depth: 0, budget: &budget, texts: &texts, inputs: &inputs)
            for input in inputs where !input.isEmpty && !st.recentInputs.contains(input) {
                st.recentInputs.append(input)
                if st.recentInputs.count > 6 { st.recentInputs.removeFirst() }
            }

            guard let last = st.last else { st.last = texts; continue }   // first look: just learn what's there
            if texts == last { st.pending = nil; continue }
            if texts != st.pending { st.pending = texts; st.pendingSince = Date(); continue }
            guard Date().timeIntervalSince(st.pendingSince) >= 1.4 else { continue }

            st.last = texts
            st.pending = nil
            if let reply = Self.newReply(old: last, new: texts, inputs: st.recentInputs) {
                out.append((name, reply))
            }
        }
        return out
    }

    /// Diagnostic: what Hoot can read from each running AI app (`open -a Hoot --args --ax-dump <file>`).
    static func dump() -> String {
        var out = "trusted: \(AXIsProcessTrusted())\n"
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let name = AIAssist.apps[id] else { continue }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 2)
            AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 1.5)
            let windows = (attr(el, "AXWindows") as? [AXUIElement]) ?? []
            out += "\n===== \(name) (\(id)) windows: \(windows.count)\n"
            for w in windows {
                var texts: [String] = [], inputs: [String] = [], budget = 25_000
                collect(w, depth: 0, budget: &budget, texts: &texts, inputs: &inputs)
                out += "--- window \"\(attr(w, "AXTitle") as? String ?? "")\" texts: \(texts.count) inputs: \(inputs.count)\n"
                for t in texts.suffix(60) { out += "  · \(t.replacingOccurrences(of: "\n", with: "⏎").prefix(160))\n" }
                for i in inputs { out += "  [input] \(i.prefix(120))\n" }
            }
        }
        return out
    }

    /// What was inserted between the unchanged top of the conversation and the unchanged app chrome below it.
    private static func newReply(old: [String], new: [String], inputs: [String]) -> String? {
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        // Most of the page changed: that's switching chats or scrolling, not a new answer.
        if old.count > 20, p < old.count / 3 { return nil }
        let inserted = new[p..<(new.count - s)].filter { piece in
            !inputs.contains { echoes(piece, $0) }       // drop your own question
        }
        let text = inserted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 25 ? text : nil
    }

    private static func echoes(_ a: String, _ b: String) -> Bool {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines), b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return long.hasPrefix(short) && Double(short.count) / Double(long.count) > 0.7
    }

    private static func collect(_ e: AXUIElement, depth: Int, budget: inout Int,
                                texts: inout [String], inputs: inout [String]) {
        budget -= 1
        guard budget > 0, depth < 90 else { return }
        let role = attr(e, "AXRole") as? String ?? ""
        switch role {
        case "AXStaticText":
            if let v = attr(e, "AXValue") as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { texts.append(v) }
            return
        case "AXTextArea", "AXTextField":
            // Only the box you type in is editable; AI apps also show answers/"thinking" in read-only text areas.
            guard let v = attr(e, "AXValue") as? String else { return }
            var editable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(e, "AXValue" as CFString, &editable)
            if editable.boolValue { inputs.append(v) } else if !v.trimmingCharacters(in: .whitespaces).isEmpty { texts.append(v) }
            return
        default:
            break
        }
        for child in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
            collect(child, depth: depth + 1, budget: &budget, texts: &texts, inputs: &inputs)
        }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
