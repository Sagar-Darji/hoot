import AppKit
import Carbon.HIToolbox
import CoreAudio
import ServiceManagement

/// System-wide keyboard shortcuts (work from any app, no extra permission needed).
@MainActor
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    static let record = (key: kVK_ANSI_R, label: "⌃⌥R")
    static let notes = (key: kVK_ANSI_N, label: "⌃⌥N")
    static let assist = (key: kVK_ANSI_A, label: "⌃⌥A")
    static let transcript = (key: kVK_ANSI_T, label: "⌃⌥T")

    /// Registers ⌃⌥ + `key`.
    static func register(_ key: Int, _ action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x484F4F54 /* 'HOOT' */), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Notices when a call app starts using the microphone, so the island can offer to take notes.
/// It never starts recording by itself.
@MainActor
final class CallDetector {
    var onCallStarted: ((String) -> Void)?
    var onCallEnded: (() -> Void)?
    var isRecording: () -> Bool = { false }

    private var timer: Timer?
    private var micWasBusy = false

    static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex", "net.whatsapp.WhatsApp": "WhatsApp",
        "com.google.Chrome": "your browser", "com.apple.Safari": "your browser", "company.thebrowser.Browser": "your browser",
        "com.microsoft.edgemac": "your browser", "com.brave.Browser": "your browser", "org.mozilla.firefox": "your browser",
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        guard !isRecording() else { micWasBusy = true; return }   // our own mic use doesn't count
        let busy = Self.defaultMicIsBusy()
        defer { micWasBusy = busy }
        if busy && !micWasBusy, let app = likelyCallApp() {
            onCallStarted?(app)
        } else if !busy && micWasBusy {
            onCallEnded?()
        }
    }

    /// Frontmost call app if there is one, else any running call app (the browser counts only when in front).
    private func likelyCallApp() -> String? {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let name = Self.callApps[id] { return name }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = Self.callApps[id], name != "your browser" { return name }
        }
        return nil
    }

    private static func defaultMicIsBusy() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

enum LaunchAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Hoot: launch at login \(on ? "register" : "unregister") failed: \(error)")
        }
    }
}
