import AppKit
import Foundation

/// A document you link from Speaker Notes (Google Docs/Slides, a GitHub/Gist file, any web page or a local file).
/// Hoot pulls its text and re-checks it every 30 s while the panel is open, so edits made by you or
/// a teammate show up mid-meeting.
@MainActor
final class LinkedDoc: ObservableObject {
    @Published private(set) var link: String = UserDefaults.standard.string(forKey: "docLink") ?? ""
    @Published private(set) var text: String = (try? String(contentsOf: LinkedDoc.cacheURL, encoding: .utf8)) ?? ""
    @Published private(set) var title: String? = UserDefaults.standard.string(forKey: "docTitle")
    @Published private(set) var updated: Date? = UserDefaults.standard.object(forKey: "docUpdated") as? Date
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var justChanged = false   // briefly true when a refresh brought new text

    var isVisible: () -> Bool = { false }
    private var timer: Timer?

    private static var cacheURL: URL { WhisperServer.supportDir.appendingPathComponent("linked-doc.txt") }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.link.isEmpty, self.isVisible() else { return }
                await self.refresh()
            }
        }
    }

    func setLink(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        link = trimmed
        text = ""
        title = nil
        UserDefaults.standard.set(trimmed, forKey: "docLink")
        await refresh()
    }

    func unlink() {
        link = ""
        text = ""
        title = nil
        updated = nil
        error = nil
        for key in ["docLink", "docTitle", "docUpdated"] { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    func openInBrowser() {
        if let url = Self.resolve(link)?.page { NSWorkspace.shared.open(url) }
    }

    func refresh() async {
        guard !loading, let target = Self.resolve(link) else {
            if Self.resolve(link) == nil, !link.isEmpty { error = "That doesn't look like a link or file path." }
            return
        }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await Self.fetchText(target)
            error = nil
            if fetched.text != text {
                if !text.isEmpty { flashChanged() }
                text = fetched.text
                try? FileManager.default.createDirectory(at: WhisperServer.supportDir, withIntermediateDirectories: true)
                try? text.write(to: Self.cacheURL, atomically: true, encoding: .utf8)
            }
            if let t = fetched.title { title = t; UserDefaults.standard.set(t, forKey: "docTitle") }
            updated = Date()
            UserDefaults.standard.set(updated, forKey: "docUpdated")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func flashChanged() {
        justChanged = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.justChanged = false }
    }

    // MARK: Fetching

    enum DocError: LocalizedError {
        case privateDoc, http(Int), unreadable
        var errorDescription: String? {
            switch self {
            case .privateDoc: return "This doc is private. In Google Docs: Share › General access › “Anyone with the link”."
            case .http(404): return "Couldn't find that doc — double-check the link."
            case .http(let code): return "Couldn't load the doc (error \(code))."
            case .unreadable: return "Couldn't read any text from that link."
            }
        }
    }

    private struct Target {
        let fetch: URL           // where the text comes from
        let page: URL            // what "Open" shows
        let kind: Kind
        enum Kind { case plain, html, local }
    }

    /// Turns a pasted link into the URL that returns its plain text.
    private static func resolve(_ raw: String) -> Target? {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || raw.hasPrefix("file://") {
            let url = raw.hasPrefix("file://") ? URL(string: raw)! : URL(fileURLWithPath: expanded)
            return Target(fetch: url, page: url, kind: .local)
        }
        guard let url = URL(string: raw.hasPrefix("http") ? raw : "https://" + raw), let host = url.host else { return nil }
        let parts = url.pathComponents   // ["/", "document", "d", "<id>", "edit"]

        if host == "docs.google.com", let d = parts.firstIndex(of: "d"), d + 1 < parts.count {
            let id = parts[d + 1]
            let base = "https://docs.google.com/\(parts[1])/d/\(id)"
            switch parts[1] {
            case "document": return Target(fetch: URL(string: "\(base)/export?format=txt")!, page: url, kind: .plain)
            case "presentation": return Target(fetch: URL(string: "\(base)/export/txt")!, page: url, kind: .plain)
            case "spreadsheets": return Target(fetch: URL(string: "\(base)/export?format=csv")!, page: url, kind: .plain)
            default: break
            }
        }
        if host == "github.com", parts.count > 4, parts[3] == "blob" {
            // github.com/<user>/<repo>/blob/<branch>/<path> → raw.githubusercontent.com/<user>/<repo>/<branch>/<path>
            let rest = parts[4...].joined(separator: "/")
            return Target(fetch: URL(string: "https://raw.githubusercontent.com/\(parts[1])/\(parts[2])/\(rest)")!, page: url, kind: .plain)
        }
        if host == "gist.github.com", parts.count >= 3 {
            return Target(fetch: URL(string: "https://gist.githubusercontent.com/\(parts[1])/\(parts[2])/raw")!, page: url, kind: .plain)
        }
        if host.hasSuffix("dropbox.com") {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems = (c.queryItems ?? []).filter { $0.name != "dl" } + [URLQueryItem(name: "dl", value: "1")]
            return Target(fetch: c.url!, page: url, kind: .plain)
        }
        return Target(fetch: url, page: url, kind: .html)
    }

    /// For `MeetingNotes --fetch-doc <link>`: prints what the Doc tab would show.
    static func debugFetch(_ link: String) async -> String {
        guard let target = resolve(link) else { return "error: not a link" }
        do {
            let r = try await fetchText(target)
            return "title: \(r.title ?? "-")\nfetch: \(target.fetch)\n---\n\(r.text.prefix(600))"
        } catch {
            return "fetch: \(target.fetch)\nerror: \(error.localizedDescription)"
        }
    }

    private static func fetchText(_ target: Target) async throws -> (text: String, title: String?) {
        if target.kind == .local {
            let text = try String(contentsOf: target.fetch, encoding: .utf8)
            return (text, target.fetch.lastPathComponent)
        }
        var req = URLRequest(url: target.fetch, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh) Hoot", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let finalHost = http?.url?.host ?? ""
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        // Google answers private docs with a redirect to its sign-in page (or a 401/403).
        if finalHost.hasPrefix("accounts.google")
            || ([401, 403].contains(http?.statusCode ?? 200) && target.fetch.host == "docs.google.com") {
            throw DocError.privateDoc
        }
        if let code = http?.statusCode, !(200..<300).contains(code) { throw DocError.http(code) }

        let body = String(decoding: data, as: UTF8.self)
        var title: String?
        var text: String
        if target.kind == .html || type.contains("text/html") {
            if target.kind == .plain, target.fetch.host == "docs.google.com" { throw DocError.privateDoc }
            title = Self.htmlTitle(body)
            text = Self.htmlToText(data)
        } else {
            text = body
            if target.fetch.host == "docs.google.com" { title = await Self.googleTitle(target.page) }
            else { title = target.page.lastPathComponent }
        }
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty doc is fine (you may be about to write in it); an empty web page means we couldn't read it.
        guard !text.isEmpty || target.kind != .html else { throw DocError.unreadable }
        return (text, title)
    }

    private static func googleTitle(_ page: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: page) else { return nil }
        return htmlTitle(String(decoding: data, as: UTF8.self))?
            .replacingOccurrences(of: #" - Google (Docs|Slides|Sheets)$"#, with: "", options: .regularExpression)
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let r = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = html[r].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let decoded = htmlToText(Data(inner.utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// Readable text from a web page: scripts, styles and navigation chrome dropped; paragraphs kept.
    private static func htmlToText(_ data: Data) -> String {
        var html = String(decoding: data, as: UTF8.self)
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header"] {
            html = html.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return (try? NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil).string) ?? ""
    }
}
