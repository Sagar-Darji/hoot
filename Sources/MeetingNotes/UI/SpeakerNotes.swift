import AppKit
import SwiftUI

/// Your private cue card. Lives in a panel that's excluded from screen capture, so you can read it
/// while sharing your screen and nobody on the call sees it. Autosaves to "Speaker Notes.md".
@MainActor
final class SpeakerNotes: ObservableObject {
    @Published var text: String {
        didSet { scheduleSave() }
    }
    @Published var fontSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "notesFontSize") as? Double ?? 16) {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "notesFontSize") }
    }
    @Published var showDoc = UserDefaults.standard.bool(forKey: "notesShowDoc") {
        didSet { UserDefaults.standard.set(showDoc, forKey: "notesShowDoc") }
    }
    let doc = LinkedDoc()

    static var fileURL: URL { Recorder.notesRoot.appendingPathComponent("Speaker Notes.md") }

    private var saveWork: DispatchWorkItem?
    /// False in showcase mode, so sample notes never overwrite the real file.
    private var persist = true

    /// Sample cue card for product screenshots (`HOOT_SHOWCASE`); never saved.
    func loadShowcase() {
        persist = false
        showDoc = false
        text = """
        Q3 review — talking points

        • Revenue up 18% YoY, led by the enterprise plan
        • Churn down to 1.8% monthly
        • Launch date: November 5 (campaign ready)

        Ask
        • Do we keep the free tier?
        • Who owns the pricing deck?
        """
    }

    init() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        guard persist else { return }
        try? FileManager.default.createDirectory(at: Recorder.notesRoot, withIntermediateDirectories: true)
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }
}

final class NotesUIState: ObservableObject {
    @Published var linkDraft = ""
    @Published var editingLink = false
}

/// Your cue card beside the call: your own notes, or a linked document that stays up to date, and a
/// teleprompter that scrolls either one while you present.
struct NotesPane: View {
    @ObservedObject var notes: SpeakerNotes
    @ObservedObject var doc: LinkedDoc

    @StateObject private var ui = NotesUIState()
    @StateObject private var prompter = PrompterState()

    init(notes: SpeakerNotes) {
        self.notes = notes
        self.doc = notes.doc
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if prompter.playing {
                    Label("Teleprompter", systemImage: "play.fill")
                        .font(Theme.Font.headline).foregroundStyle(Theme.text)
                } else {
                    ThemeSegmented(selection: Binding(get: { notes.showDoc }, set: { show in
                        notes.showDoc = show
                        if show, !doc.link.isEmpty { Task { await doc.refresh() } }
                    }), items: [(false, "My Notes", nil), (true, String((doc.title ?? "Linked Doc").prefix(22)), nil)])
                }
                Spacer()
                if notes.showDoc, !doc.link.isEmpty, !prompter.playing {
                    Text(docStatus).font(Theme.Font.caption).foregroundStyle(doc.justChanged ? Theme.you : Theme.tertiary)
                    ThemeIconButton(symbol: "arrow.clockwise", help: "Get the latest text now (also every 30 seconds)") {
                        Task { await doc.refresh() }
                    }
                }
                ThemeIconButton(symbol: prompter.playing ? "stop.fill" : "play.fill",
                                help: prompter.playing ? "Back to editing" : "Teleprompter: scroll the text while you present") {
                    if prompter.playing { prompter.playing = false } else { prompter.restart(); prompter.playing = true }
                }
                options
            }
            Group {
                if prompter.playing {
                    TeleprompterView(text: notes.showDoc ? doc.text : notes.text, fontSize: notes.fontSize, state: prompter)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                } else if notes.showDoc {
                    docPane
                } else {
                    editor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var docStatus: String {
        if doc.loading { return "Checking…" }
        if doc.justChanged { return "Just updated" }
        return "Live"
    }

    private var options: some View {
        Menu {
            if notes.showDoc, !doc.link.isEmpty {
                Button("Open in Browser") { doc.openInBrowser() }
                Button("Change Link…") {
                    ui.linkDraft = doc.link
                    ui.editingLink = true
                }
                Button("Unlink Document", role: .destructive) { doc.unlink() }
                Divider()
            }
            Picker("Teleprompter Speed", selection: $prompter.speed) {
                Text("Slow").tag(16.0)
                Text("Medium").tag(28.0)
                Text("Fast").tag(44.0)
            }
            Divider()
            Button("Bigger Text") { notes.fontSize = min(40, notes.fontSize + 2) }
            Button("Smaller Text") { notes.fontSize = max(11, notes.fontSize - 2) }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: Theme.control, height: Theme.control)
                .background(Circle().fill(Theme.raised))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text size and teleprompter speed")
    }

    // MARK: My notes

    private var editor: some View {
        TextEditor(text: $notes.text)
            .font(.system(size: notes.fontSize))
            .foregroundStyle(Theme.text)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(10)
            .overlay(alignment: .topLeading) {
                if notes.text.isEmpty {
                    Text("Talking points, numbers to mention, questions to ask…")
                        .font(.system(size: notes.fontSize))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.raised))
    }

    // MARK: Linked doc

    @ViewBuilder private var docPane: some View {
        if doc.link.isEmpty || ui.editingLink {
            linkForm
        } else if doc.text.isEmpty {
            VStack(spacing: 14) {
                ThemeEmpty(symbol: doc.error == nil ? "doc" : "exclamationmark.triangle",
                           title: doc.error == nil ? (doc.loading ? "Loading…" : "The document is empty") : "Can't load the document",
                           message: doc.error ?? (doc.loading ? "" : "Add text to it and it appears here within 30 seconds."))
                    .frame(maxHeight: 170)
                ThemeButton(title: "Open in Browser") { doc.openInBrowser() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                if let error = doc.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    Text(doc.text)
                        .font(.system(size: notes.fontSize))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .scrollIndicators(.never)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.raised))
            }
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Show a document").font(Theme.Font.title).foregroundStyle(Theme.text)
            Text("Paste a link to your script or talking points — Google Docs, Slides or Sheets shared as “Anyone with the link”, a GitHub or Gist file, any web page, or a file on this Mac. Hoot keeps it up to date.")
                .font(Theme.Font.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $ui.linkDraft, prompt: Text("https://docs.google.com/document/d/…").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.raised))
                .onSubmit(submitLink)
            if let error = doc.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.callout).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 8) {
                Spacer()
                if ui.editingLink { ThemeButton(title: "Cancel") { ui.editingLink = false } }
                ThemeButton(title: "Show Document", role: .primary, action: submitLink)
                    .disabled(ui.linkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .themeCard(padding: 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func submitLink() {
        let link = ui.linkDraft
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        ui.editingLink = false
        ui.linkDraft = ""
        Task { await doc.setLink(link) }
    }
}
