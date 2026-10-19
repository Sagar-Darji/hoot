import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// App-wide preferences that aren't owned by a feature.
@MainActor
final class Preferences: ObservableObject {
    enum Tab: Hashable { case setup, general, ai, about }

    @Published var tab: Tab = .setup
    /// Show Hoot as a Dynamic Island around the notch (on Macs that have one).
    @Published var useNotch = UserDefaults.standard.object(forKey: "useNotch") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useNotch, forKey: "useNotch")
            onPresenceChange?()
        }
    }
    @Published var launchAtLogin = LaunchAtLogin.isOn
    var onPresenceChange: (() -> Void)?

    var hasNotch: Bool { NotchGeometry.current() != nil }
}

/// Live status of everything Hoot needs, for the Setup checklist. It only polls while Settings is open.
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

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    @ObservedObject var setup: SetupStatus
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        TabView(selection: $prefs.tab) {
            SetupPane(recorder: recorder, assist: assist, setup: setup)
                .tabItem { Label("Setup", systemImage: "checklist") }.tag(Preferences.Tab.setup)
            GeneralPane(prefs: prefs, recorder: recorder)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Preferences.Tab.general)
            AIPane(assist: assist, setup: setup)
                .tabItem { Label("AI", systemImage: "sparkles") }.tag(Preferences.Tab.ai)
            AboutPane(updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }.tag(Preferences.Tab.about)
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - Setup

private struct SetupPane: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var assist: AIAssist
    @ObservedObject var setup: SetupStatus

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(setup.essentialsReady ? "Hoot is ready" : "Set up Hoot")
                            .font(.title3.weight(.semibold))
                        Text(setup.essentialsReady
                             ? "Click the bird (or press \(HotKeys.record.label)) during any call to take notes."
                             : "Three quick steps and Hoot can take notes in any call. Everything stays on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Required") {
                SetupRow(symbol: "mic.fill", title: "Microphone",
                         detail: "So your side of the call is transcribed.",
                         state: microphoneState, actionTitle: setup.microphone == .notDetermined ? "Allow…" : "Open Settings…") {
                    if setup.microphone == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in setup.refresh() } }
                    } else {
                        openPrivacy("Privacy_Microphone")
                    }
                }
                SetupRow(symbol: "speaker.wave.2.fill", title: "Screen & System Audio Recording",
                         detail: "So Hoot can hear the other people in the call. Hoot only uses the audio — it never records your screen. Reopen Hoot after allowing.",
                         state: setup.screenAudio ? .done : .needed, actionTitle: "Allow…",
                         secondaryTitle: setup.screenAudio ? nil : "Reopen Hoot", secondary: relaunch) {
                    if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
                }
                SetupRow(symbol: "waveform", title: "Speech model",
                         detail: "Transcribes on this Mac, nothing is uploaded. About 550 MB, downloaded once.",
                         state: modelState, actionTitle: "Download") {
                    recorder.prepareModel()
                }
            }
            Section("Optional") {
                SetupRow(symbol: "sparkles", title: "Accessibility",
                         detail: "Lets AI Assist pick up answers from Claude, ChatGPT and Gemini by itself.",
                         state: setup.accessibility ? .done : .optional, actionTitle: "Allow…") {
                    assist.requestAccessibility()
                }
                SetupRow(symbol: "apple.intelligence", title: "Apple Intelligence",
                         detail: setup.intelligence ?? "Writes meeting summaries and answers questions about the meeting, on this Mac.",
                         state: setup.intelligence == nil ? .done : .optional, actionTitle: "Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var microphoneState: SetupRow.State {
        switch setup.microphone {
        case .authorized: return .done
        default: return .needed
        }
    }

    private var modelState: SetupRow.State {
        if let p = recorder.modelDownload { return .working(p) }
        if case .failed = recorder.engine, !setup.modelOnDisk { return .needed }
        return setup.modelOnDisk ? .done : .needed
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct SetupRow: View {
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .working(let p) = state {
                    ProgressView(value: p).progressViewStyle(.linear).padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .done:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .help("Done")
            case .working:
                EmptyView()
            case .needed, .optional:
                VStack(alignment: .trailing, spacing: 6) {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .tint(state == .needed ? .accentColor : .gray)
                    if let secondaryTitle, let secondary {
                        Button(secondaryTitle, action: secondary).buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var tint: Color {
        switch state {
        case .done: return Color(nsColor: .systemGreen)
        case .needed, .working: return Color.accentColor
        case .optional: return Color(nsColor: .systemGray)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var recorder: Recorder

    var body: some View {
        Form {
            Section("Where Hoot lives") {
                Toggle("Show Hoot in the notch (Dynamic Island)", isOn: $prefs.useNotch)
                    .disabled(!prefs.hasNotch)
                Text(prefs.hasNotch
                     ? "Hoot wraps around the camera notch and opens when you point at it. Turn this off for a floating bubble you can drag anywhere."
                     : "This display has no notch, so Hoot floats as a bubble you can drag anywhere.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Open Hoot at login", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { LaunchAtLogin.set($0); prefs.launchAtLogin = LaunchAtLogin.isOn }))
            }
            Section("Transcription") {
                Picker("Language", selection: $recorder.language) {
                    Text("Automatic").tag("auto")
                    Divider()
                    Text("English").tag("en")
                    Text("Hindi").tag("hi")
                    Text("Gujarati").tag("gu")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                }
                Toggle("I'm not wearing headphones (filter echo)", isOn: $recorder.echoCancellation)
                Toggle("Keep separate audio tracks for each side", isOn: $recorder.keepTracks)
                Text("Hoot always keeps one mixed recording (conversation.m4a). Separate tracks take about 4× more space.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Notes") {
                LabeledContent("Saved to") {
                    HStack {
                        Text("Documents › Meeting Notes").foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: Recorder.notesRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(Recorder.notesRoot)
                        }
                    }
                }
            }
            Section("Keyboard shortcuts (work in any app)") {
                LabeledContent("Start or stop recording", value: HotKeys.record.label)
                LabeledContent("Transcript", value: HotKeys.transcript.label)
                LabeledContent("Speaker notes", value: HotKeys.notes.label)
                LabeledContent("AI Assist", value: HotKeys.assist.label)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

private struct AIPane: View {
    @ObservedObject var assist: AIAssist
    @ObservedObject var setup: SetupStatus

    var body: some View {
        Form {
            Section("Bring in answers from your AI apps") {
                Toggle("Read answers from Claude, ChatGPT and Gemini", isOn: $assist.autoRead)
                if assist.autoRead && !setup.accessibility {
                    HStack {
                        Text("Needs Accessibility permission.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow…") { assist.requestAccessibility() }
                    }
                }
                Toggle("Show answers I copy", isOn: $assist.catchClipboard)
                Toggle("Show anything I copy, from any app", isOn: $assist.catchAllCopies)
                    .disabled(!assist.catchClipboard)
                Text("Copying works from your iPhone and iPad too, through Universal Clipboard.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Other devices") {
                Toggle("Receive answers over Wi-Fi from Android or Windows", isOn: $assist.receiveFromDevices)
                Text("Opens a private page on your network, protected by a secret link. Turn it off when you don't need it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Apple Intelligence") {
                LabeledContent("Meeting summaries & Ask", value: setup.intelligence == nil ? "On this Mac" : "Unavailable")
                if let reason = setup.intelligence {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 10)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Hoot").font(.title.weight(.semibold))
                Text("Version \(UpdateChecker.currentVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Private meeting notes for your Mac — transcribed on-device.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let update = updates.available {
                    Button("Download Hoot \(update.version)") { NSWorkspace.shared.open(update.download ?? update.page) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(updates.checking ? "Checking…" : "Check for Updates") { Task { await updates.check() } }
                        .disabled(updates.checking)
                }
                Button("Website") { NSWorkspace.shared.open(UpdateChecker.website) }
                Button("GitHub") { NSWorkspace.shared.open(UpdateChecker.repositoryPage) }
            }
            if let result = updates.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Third-Party Notices") {
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }
}
