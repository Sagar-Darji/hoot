import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// App-wide preferences that aren't owned by a feature.
@MainActor
final class Preferences: ObservableObject {
    /// Show the small crane beside the notch while Hoot is idle (so you always know it's there).
    @Published var restVisible = UserDefaults.standard.object(forKey: "restVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restVisible, forKey: "restVisible") }
    }
    @Published var launchAtLogin = LaunchAtLogin.isOn
}

/// Live status of everything Hoot needs, for the Setup checklist. It only polls while Settings is showing.
@MainActor
final class SetupStatus: ObservableObject {
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var screenAudio = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var modelOnDisk = WhisperServer.modelURL != nil
    @Published private(set) var intelligence = Summarizer.unavailableReason
    private var timer: Timer?

    /// Microphone, call audio and the speech model: without these Hoot can't take notes.
    var essentialsReady: Bool { microphone == .authorized && screenAudio && modelOnDisk }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        screenAudio = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
        modelOnDisk = WhisperServer.modelURL != nil
        intelligence = Summarizer.unavailableReason
    }

    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
}

/// Settings and first-run setup, inside the island like everything else.
struct SettingsPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    @ObservedObject var setup: SetupStatus
    @ObservedObject var updates: UpdateChecker
    let welcome: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if welcome || !setup.essentialsReady { hello }
                group("Setup") { setupRows }
                group("General") { generalRows }
                group("AI") { aiRows }
                group("Shortcuts — in any app") { shortcutRows }
                about
            }
            .padding(.bottom, 6)
        }
        .scrollIndicators(.never)
        .onAppear { setup.startWatching() }
        .onDisappear { setup.stopWatching() }
    }

    // MARK: Welcome

    private var hello: some View {
        HStack(spacing: 14) {
            GlassCrane(lift: 0.3, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(setup.essentialsReady ? "Hoot is ready" : "Welcome to Hoot")
                    .font(Theme.Font.title).foregroundStyle(Theme.text)
                Text(setup.essentialsReady
                     ? "Point at the notch anytime, or press \(HotKeys.record.label) in any app to take notes."
                     : "Three quick steps and Hoot can take notes in any call. Everything stays on this Mac.")
                    .font(Theme.Font.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themeCard(padding: 16)
    }

    // MARK: Sections

    @ViewBuilder private var setupRows: some View {
        StatusRow(symbol: "mic.fill", title: "Microphone", detail: "So your side of the call is transcribed.",
                  state: setup.microphone == .authorized ? .done : .needed,
                  actionTitle: setup.microphone == .notDetermined ? "Allow" : "Open Settings") {
            if setup.microphone == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in setup.refresh() } }
            } else {
                openPrivacy("Privacy_Microphone")
            }
        }
        divider
        StatusRow(symbol: "speaker.wave.2.fill", title: "Call audio",
                  detail: setup.screenAudio ? "Hoot can hear the other people in the call."
                                            : "Allow “Screen & System Audio Recording” — Hoot only uses the audio — then reopen Hoot.",
                  state: setup.screenAudio ? .done : .needed, actionTitle: "Allow",
                  secondaryTitle: setup.screenAudio ? nil : "Reopen Hoot", secondary: relaunch) {
            if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
        }
        divider
        StatusRow(symbol: "waveform", title: "Speech model", detail: "Transcribes on this Mac. About 550 MB, downloaded once.",
                  state: modelState, actionTitle: "Download") { recorder.prepareModel() }
        divider
        StatusRow(symbol: "sparkles", title: "Read AI apps", detail: "Optional — answers from Claude, ChatGPT and Gemini appear by themselves.",
                  state: setup.accessibility ? .done : .optional, actionTitle: "Allow") { assist.requestAccessibility() }
        divider
        StatusRow(symbol: "apple.intelligence", title: "Apple Intelligence",
                  detail: setup.intelligence ?? "Summaries and Ask, on this Mac.",
                  state: setup.intelligence == nil ? .done : .optional, actionTitle: "Open Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
        }
    }

    @ViewBuilder private var generalRows: some View {
        ToggleRow(title: "Show Hoot beside the notch", detail: "A small crane so you always know Hoot is there.", isOn: $prefs.restVisible)
        divider
        ToggleRow(title: "Open at login", isOn: Binding(
            get: { prefs.launchAtLogin },
            set: { LaunchAtLogin.set($0); prefs.launchAtLogin = LaunchAtLogin.isOn }))
        divider
        Row(title: "Language") {
            Picker("", selection: $recorder.language) {
                Text("Automatic").tag("auto")
                Divider()
                Text("English").tag("en")
                Text("Hindi").tag("hi")
                Text("Gujarati").tag("gu")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        divider
        ToggleRow(title: "Not wearing headphones", detail: "Filters the call's sound out of your microphone.", isOn: $recorder.echoCancellation)
        divider
        ToggleRow(title: "Keep separate audio tracks", detail: "One mixed recording is always kept; separate tracks use 4× the space.",
                  isOn: $recorder.keepTracks)
        divider
        Row(title: "Notes", detail: "Documents › Meeting Notes") {
            ThemeButton(title: "Show in Finder") {
                try? FileManager.default.createDirectory(at: Recorder.notesRoot, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Recorder.notesRoot)
            }
        }
    }

    @ViewBuilder private var aiRows: some View {
        ToggleRow(title: "Read answers from Claude, ChatGPT and Gemini", isOn: $assist.autoRead)
        divider
        ToggleRow(title: "Show answers I copy", detail: "Works from your iPhone and iPad too (Universal Clipboard).", isOn: $assist.catchClipboard)
        divider
        ToggleRow(title: "Receive answers over Wi-Fi", detail: "For Android or Windows: a private page protected by a secret link.",
                  isOn: $assist.receiveFromDevices)
    }

    @ViewBuilder private var shortcutRows: some View {
        Row(title: "Start or stop recording") { keys(HotKeys.record.label) }
        divider
        Row(title: "Transcript") { keys(HotKeys.transcript.label) }
        divider
        Row(title: "Speaker notes") { keys(HotKeys.notes.label) }
        divider
        Row(title: "AI Assist") { keys(HotKeys.assist.label) }
    }

    private var about: some View {
        VStack(spacing: 10) {
            Text("Hoot \(UpdateChecker.currentVersion)").font(Theme.Font.headline).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                if let update = updates.available {
                    ThemeButton(title: "Download \(update.version)", symbol: "arrow.down", role: .primary) {
                        NSWorkspace.shared.open(update.download ?? update.page)
                    }
                } else {
                    ThemeButton(title: updates.checking ? "Checking…" : "Check for Updates") { Task { await updates.check() } }
                        .disabled(updates.checking)
                }
                ThemeButton(title: "Website") { NSWorkspace.shared.open(UpdateChecker.website) }
                ThemeButton(title: "Quit Hoot") { NSApp.terminate(nil) }
            }
            if let result = updates.lastResult {
                Text(result).font(Theme.Font.caption).foregroundStyle(Theme.tertiary)
            }
            Button("Open-source notices") {
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 6) {
            ThemeSectionTitle(title)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.raised))
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 14)
    }

    private func keys(_ label: String) -> some View {
        Text(label)
            .font(Theme.Font.callout.weight(.medium).monospaced())
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raisedHover))
    }

    private var modelState: StatusRow.State {
        if let p = recorder.modelDownload { return .working(p) }
        return setup.modelOnDisk ? .done : .needed
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Rows

/// A settings row: title (and detail) on the left, a control on the right.
private struct Row<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, detail: detail) {
            ThemeSwitch(isOn: $isOn)
        }
    }
}

/// A setup step: what it's for, and either a check mark or the button that does it.
private struct StatusRow: View {
    enum State: Equatable { case done, needed, optional, working(Double) }

    let symbol: String
    let title: String
    let detail: String
    let state: State
    let actionTitle: String
    var secondaryTitle: String? = nil
    var secondary: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.text)
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if case .working(let p) = state {
                    ProgressView(value: p).progressViewStyle(.linear).tint(Theme.you).padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Theme.success)
            case .working:
                EmptyView()
            case .needed, .optional:
                VStack(alignment: .trailing, spacing: 4) {
                    ThemeButton(title: actionTitle, role: state == .needed ? .primary : .secondary, action: action)
                    if let secondaryTitle, let secondary {
                        Button(secondaryTitle, action: secondary).buttonStyle(.plain)
                            .font(Theme.Font.caption).foregroundStyle(Theme.you)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tint: Color {
        switch state {
        case .done: return Theme.success
        case .needed, .working: return Theme.you
        case .optional: return Color.white.opacity(0.18)
        }
    }
}
