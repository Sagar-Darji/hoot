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
    @Published var opacity: Double = UserDefaults.standard.object(forKey: "notesOpacity") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(opacity, forKey: "notesOpacity") }
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

    func cycleOpacity() {
        opacity = opacity > 0.9 ? 0.75 : opacity > 0.6 ? 0.5 : 1
    }
}

final class NotesUIState: ObservableObject {
    @Published var linkDraft = ""
    @Published var editingLink = false
}

struct SpeakerNotesView: View {
    @ObservedObject var notes: SpeakerNotes
    @ObservedObject var doc: LinkedDoc

    @StateObject private var ui = NotesUIState()
    @StateObject private var prompter = PrompterState()

    init(notes: SpeakerNotes) {
        self.notes = notes
        self.doc = notes.doc
    }

    var body: some View {
        Group {
            if prompter.playing {
                TeleprompterView(text: notes.showDoc ? doc.text : notes.text, fontSize: notes.fontSize, state: prompter)
            } else if notes.showDoc { docPane } else { notesPane }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !prompter.playing {
                HStack {
                    PillSegments(selection: Binding(
                        get: { notes.showDoc },
                        set: { show in
                            notes.showDoc = show
                            if show, !doc.link.isEmpty { Task { await doc.refresh() } }
                        }), items: [
                            (false, "My Notes", "pencil"),
                            (true, String((doc.title ?? "Linked Doc").prefix(24)), "link"),
                        ])
                    Spacer()
                    if notes.showDoc && !doc.link.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if prompter.playing { prompter.playing = false } else { prompter.restart(); prompter.playing = true }
                } label: {
                    Label(prompter.playing ? "Stop Teleprompter" : "Teleprompter",
                          systemImage: prompter.playing ? "stop.fill" : "play.fill")
                }
                .help(prompter.playing ? "Back to editing" : "Scroll the text automatically while you present")
                if notes.showDoc, !doc.link.isEmpty, !prompter.playing {
                    Button { Task { await doc.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Get the latest text now (also happens every 30 seconds)")
                        .disabled(doc.loading)
                }
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
                    Divider()
                    Picker("Window Opacity", selection: $notes.opacity) {
                        Text("100%").tag(1.0)
                        Text("75%").tag(0.75)
                        Text("50%").tag(0.5)
                    }
                } label: {
                    Label("Options", systemImage: "textformat.size")
                }
                .help("Text size and opacity")
            }
        }
    }

    private var subtitle: String {
        guard notes.showDoc, !doc.link.isEmpty else { return "Hidden from screen sharing" }
        if doc.loading { return "Checking for changes…" }
        if doc.justChanged { return "Just updated" }
        if let title = doc.title { return title }
        return "Hidden from screen sharing"
    }

    // MARK: My notes

    private var notesPane: some View {
        TextEditor(text: $notes.text)
            .font(.system(size: notes.fontSize))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .overlay(alignment: .topLeading) {
                if notes.text.isEmpty {
                    Text("Talking points, numbers to mention, questions to ask…")
                        .font(.system(size: notes.fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Linked doc

    @ViewBuilder private var docPane: some View {
        if doc.link.isEmpty || ui.editingLink {
            linkForm
        } else if doc.text.isEmpty {
            ContentUnavailableView {
                Label(doc.error == nil ? (doc.loading ? "Loading…" : "Empty Document") : "Can't Load Document",
                      systemImage: doc.error == nil ? "doc" : "exclamationmark.triangle")
            } description: {
                Text(doc.error ?? (doc.loading ? "" : "Add text to the document and it appears here within 30 seconds."))
            } actions: {
                Button("Open in Browser") { doc.openInBrowser() }
            }
        } else {
            VStack(spacing: 0) {
                if let error = doc.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.orange.opacity(0.1))
                }
                ScrollView {
                    Text(doc.text)
                        .font(.system(size: notes.fontSize))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                    .overlay(alignment: .bottomTrailing) {
                    if let updated = doc.updated {
                        (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glass(in: Capsule())
                            .padding(10)
                    }
                }
            }
        }
    }

    private var linkForm: some View {
        Form {
            Section {
                TextField("Link", text: $ui.linkDraft, prompt: Text("https://docs.google.com/document/d/…"))
                    .onSubmit(submitLink)
            } header: {
                Text("Show a Document")
            } footer: {
                Text("Google Docs, Slides or Sheets shared as “Anyone with the link”, a GitHub or Gist file, any web page, or a file on this Mac. Hoot keeps it up to date while it's open.")
                    .foregroundStyle(.secondary)
            }
            if let error = doc.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if ui.editingLink { Button("Cancel") { ui.editingLink = false } }
                Button("Show Document", action: submitLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ui.linkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func submitLink() {
        let link = ui.linkDraft
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        ui.editingLink = false
        ui.linkDraft = ""
        Task { await doc.setLink(link) }
    }
}
