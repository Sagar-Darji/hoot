import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

final class AssistUIState: ObservableObject {
    @Published var showingDrop = false
    @Published var copied = false
    @Published var question = ""
}

/// The AI tab: answers from your AI apps (read automatically, copied, or sent from a phone), and an
/// Ask bar that puts questions about the meeting to Apple Intelligence on this Mac.
struct AssistPane: View {
    @ObservedObject var assist: AIAssist
    @ObservedObject var recorder: Recorder
    let notes: SpeakerNotes

    @StateObject private var ui = AssistUIState()

    var body: some View {
        VStack(spacing: 10) {
            header
            if assist.autoRead && !assist.axTrusted && !ui.showingDrop { permissionBanner }
            Group {
                if ui.showingDrop {
                    dropView
                } else if let entry = assist.current {
                    answer(entry)
                } else {
                    ThemeEmpty(symbol: "sparkles", title: "Ask, or bring in an answer",
                               message: "Ask about this meeting below — or ask Claude, ChatGPT or Gemini as usual and their answers appear here. Copying an answer on your iPhone works too.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !ui.showingDrop { askBar }
        }
        .onAppear { assist.hasUnseen = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let entry = assist.current, !ui.showingDrop {
                sourceChip(entry)
                (Text(entry.time, style: .relative) + Text(" ago"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.tertiary)
            } else {
                Text(ui.showingDrop ? "Send from another device" : "AI Assist")
                    .font(Theme.Font.headline).foregroundStyle(Theme.text)
            }
            Spacer()
            if assist.entries.count > 1 && !ui.showingDrop {
                ThemeIconButton(symbol: "chevron.left", help: "Older answer", size: 26) { assist.show(assist.index - 1) }
                    .disabled(assist.index == 0)
                Text("\(assist.index + 1)/\(assist.entries.count)")
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                ThemeIconButton(symbol: "chevron.right", help: "Newer answer", size: 26) { assist.show(assist.index + 1) }
                    .disabled(assist.index >= assist.entries.count - 1)
            }
            if let entry = assist.current, !ui.showingDrop, !entry.text.isEmpty {
                ThemeIconButton(symbol: ui.copied ? "checkmark" : "doc.on.doc", help: "Copy this answer") {
                    assist.copy(entry.text)
                    ui.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
                }
            }
            options
        }
    }

    private var options: some View {
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
            Divider()
            Button("Clear All Answers", role: .destructive) { assist.clear() }.disabled(assist.entries.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: Theme.control, height: Theme.control)
                .background(Circle().fill(Theme.raised))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
    }

    private func sourceChip(_ entry: AIEntry) -> some View {
        Label(entry.source, systemImage: Self.symbol(for: entry.source))
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Self.color(for: entry.source)))
    }

    // MARK: Ask bar

    private var askBar: some View {
        VStack(spacing: 8) {
            if let error = assist.askError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MeetingAI.quickPrompts, id: \.label) { quick in
                        ThemeButton(title: quick.label, symbol: quick.symbol) { send(quick.prompt) }
                            .disabled(assist.asking)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $ui.question, prompt: Text("Ask about this meeting…").foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .onSubmit { send(ui.question) }
                    .padding(.leading, 14)
                if assist.asking {
                    ProgressView().controlSize(.small).padding(.trailing, 8)
                } else {
                    Button { send(ui.question) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ui.question.isEmpty ? Theme.tertiary : .white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(ui.question.isEmpty ? Theme.raised : Theme.you))
                    }
                    .buttonStyle(.plain)
                    .disabled(ui.question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.trailing, 4)
                    .help("Ask Apple Intelligence (on this Mac)")
                }
            }
            .frame(height: 34)
            .background(Capsule().fill(Theme.raised))
        }
    }

    private func send(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty, !assist.asking else { return }
        assist.ask(question, transcript: recorder.lines, notes: notes.text)
        ui.question = ""
    }

    // MARK: Body

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Let Hoot read your AI apps").font(Theme.Font.headline).foregroundStyle(Theme.text)
                Text("New answers then appear here by themselves.").font(Theme.Font.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            ThemeButton(title: "Allow…") { assist.requestAccessibility() }
        }
        .themeCard(padding: 12)
    }

    private func answer(_ entry: AIEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let question = entry.question {
                    Text(question)
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.raisedHover))
                }
                if entry.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking on this Mac…").font(Theme.Font.body).foregroundStyle(Theme.secondary)
                    }
                } else {
                    MarkdownText(source: entry.text, fontSize: assist.fontSize)
                        .font(.system(size: assist.fontSize))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(2)
                }
            }
            .themeCard(padding: 16)
        }
        .scrollIndicators(.never)
    }

    private var dropView: some View {
        VStack(spacing: 12) {
            if assist.receiveFromDevices, let url = assist.drop.url {
                if let qr = Self.qrCode(url) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 140, height: 140)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(.white))
                }
                Text("Scan with your phone's camera on the same Wi-Fi, paste an answer, then tap Send.")
                    .font(Theme.Font.callout).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Text(url).font(Theme.Font.caption.monospaced()).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                ThemeButton(title: "Stop Receiving") { assist.receiveFromDevices = false }
            } else if assist.receiveFromDevices {
                ThemeEmpty(symbol: "wifi.slash", title: "No Wi-Fi", message: "Connect this Mac to Wi-Fi to receive answers from other devices.")
            } else {
                ThemeEmpty(symbol: "iphone.and.arrow.forward", title: "Send from another device",
                           message: "iPhone, iPad and your other Macs already work — just copy the answer. For Android or Windows, Hoot opens a private page on your Wi-Fi.")
                    .frame(maxHeight: 180)
                ThemeButton(title: "Start Receiving", role: .primary) { assist.receiveFromDevices = true }
            }
            if let error = assist.dropError {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            ThemeButton(title: "Back to Answers") { ui.showingDrop = false }
        }
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
        default: return Color.white.opacity(0.18)
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
