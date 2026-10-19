import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

final class AssistUIState: ObservableObject {
    @Published var showingDrop = false
    @Published var copied = false
    @Published var question = ""
}

/// The AI tab: answers from your AI apps (read automatically, copied, or sent from a phone),
/// plus an Ask bar that puts questions about the meeting to Apple Intelligence on this Mac.
struct AssistView: View {
    @ObservedObject var assist: AIAssist
    @ObservedObject var recorder: Recorder
    let notes: SpeakerNotes

    @StateObject private var ui = AssistUIState()

    var body: some View {
        VStack(spacing: 0) {
            if assist.autoRead && !assist.axTrusted && !ui.showingDrop { permissionBanner }
            Group {
                if ui.showingDrop {
                    dropView
                } else if let entry = assist.current {
                    answer(entry)
                } else {
                    ContentUnavailableView {
                        Label("Ask or Bring In an Answer", systemImage: "sparkles")
                    } description: {
                        Text("Ask about this meeting below, or ask Claude, ChatGPT or Gemini as usual — their answers appear here. Copying an answer on your iPhone works too.")
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if !ui.showingDrop { askBar }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if assist.entries.count > 1 && !ui.showingDrop {
                    ControlGroup {
                        Button { assist.show(assist.index - 1) } label: { Label("Older", systemImage: "chevron.left") }
                            .disabled(assist.index == 0)
                        Button { assist.show(assist.index + 1) } label: { Label("Newer", systemImage: "chevron.right") }
                            .disabled(assist.index >= assist.entries.count - 1)
                    }
                    .help("Answer \(assist.index + 1) of \(assist.entries.count)")
                }
                if let entry = assist.current, !ui.showingDrop, !entry.text.isEmpty {
                    Button {
                        assist.copy(entry.text)
                        ui.copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
                    } label: { Label("Copy", systemImage: ui.copied ? "checkmark" : "doc.on.doc") }
                        .help("Copy this answer")
                }
                settingsMenu
            }
        }
        .onAppear { assist.hasUnseen = false }
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Read Answers from Claude, ChatGPT & Gemini", isOn: $assist.autoRead)
            Toggle("Show Answers I Copy", isOn: $assist.catchClipboard)
            Toggle("Show Anything I Copy", isOn: $assist.catchAllCopies)
                .disabled(!assist.catchClipboard)
            Divider()
            Button(ui.showingDrop ? "Back to Answers" : "Send from Another Device…") { ui.showingDrop.toggle() }
            Divider()
            Button("Bigger Text") { assist.fontSize = min(36, assist.fontSize + 2) }
            Button("Smaller Text") { assist.fontSize = max(10, assist.fontSize - 2) }
            Picker("Window Opacity", selection: $assist.opacity) {
                Text("100%").tag(1.0)
                Text("75%").tag(0.75)
                Text("50%").tag(0.5)
            }
            Divider()
            Button("Clear All Answers", role: .destructive) { assist.clear() }.disabled(assist.entries.isEmpty)
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
        .help("Options")
    }

    // MARK: Ask bar

    private var askBar: some View {
        VStack(spacing: 8) {
            if let error = assist.askError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MeetingAI.quickPrompts, id: \.label) { quick in
                        Button { send(quick.prompt, label: quick.label) } label: {
                            Label(quick.label, systemImage: quick.symbol)
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .glass(in: Capsule(), interactive: true)
                        .disabled(assist.asking)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $ui.question)
                    .textFieldStyle(.plain)
                    .onSubmit { send(ui.question) }
                    .padding(.leading, 12)
                if assist.asking {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                } else {
                    Button { send(ui.question) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, ui.question.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(ui.question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Ask Apple Intelligence (on this Mac)")
                }
            }
            .frame(height: 34)
            .glass(in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }

    private func send(_ question: String, label: String? = nil) {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty, !assist.asking else { return }
        assist.ask(question, transcript: recorder.lines, notes: notes.text)
        ui.question = ""
    }

    // MARK: Body

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Allow Hoot to read your AI apps").font(.callout.weight(.semibold))
                Text("New answers then appear automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Allow…") { assist.requestAccessibility() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08))
    }

    private func answer(_ entry: AIEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Label(entry.source, systemImage: Self.symbol(for: entry.source))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Self.color(for: entry.source)))
                    (Text(entry.time, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let question = entry.question {
                    Text(question)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
                }
                if entry.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking on this Mac…").foregroundStyle(.secondary)
                    }
                } else {
                    MarkdownText(source: entry.text, fontSize: assist.fontSize)
                        .font(.system(size: assist.fontSize))
                        .lineSpacing(2)
                }
            }
            .padding(16)
        }
    }

    private var dropView: some View {
        VStack(spacing: 12) {
            if assist.receiveFromDevices, let url = assist.drop.url {
                if let qr = Self.qrCode(url) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 140, height: 140)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                }
                Text("Scan with your phone's camera on the same Wi-Fi, paste an answer, then tap Send.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(url).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Stop Receiving") { assist.receiveFromDevices = false }
            } else if assist.receiveFromDevices {
                ContentUnavailableView("No Wi-Fi", systemImage: "wifi.slash",
                                       description: Text("Connect this Mac to Wi-Fi to receive answers from other devices."))
            } else {
                ContentUnavailableView {
                    Label("Send from Another Device", systemImage: "iphone.and.arrow.forward")
                } description: {
                    Text("iPhone, iPad and your other Macs already work — just copy the answer. For Android or Windows, Hoot opens a private page on your Wi-Fi.")
                } actions: {
                    Button("Start Receiving") { assist.receiveFromDevices = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = assist.dropError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Button("Back to Answers") { ui.showingDrop = false }.buttonStyle(.link)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    /// Each assistant's own colour, so you can tell at a glance where an answer came from.
    private static func color(for source: String) -> Color {
        switch source {
        case "Claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "ChatGPT": return Color(red: 0.06, green: 0.6, blue: 0.48)
        case "Gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "Apple Intelligence": return Color(red: 0.55, green: 0.35, blue: 0.95)
        default: return Color(nsColor: .systemGray)
        }
    }

    private static func symbol(for source: String) -> String {
        switch source {
        case "Apple Intelligence": return "apple.intelligence"
        case "Browser": return "safari"
        case "iPhone", "Android": return "iphone"
        case "iPad": return "ipad"
        case "Other device", "Other Mac", "Windows PC": return "laptopcomputer"
        case "Copied": return "doc.on.clipboard"
        default: return "sparkles"
        }
    }

    private static func qrCode(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
