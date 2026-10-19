import AppKit
import Foundation

/// Checks GitHub for a newer release — at most once a day, in the background, with one small request.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL?
        let notes: String
    }

    /// Where releases are published (see release.sh).
    static let repository = "Sagar-Darji/hoot"
    static var website: URL { URL(string: "https://sagar-darji.github.io/hoot/")! }
    static var repositoryPage: URL { URL(string: "https://github.com/\(repository)")! }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check() }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hoot/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                lastResult = "Couldn't reach GitHub just now."
                return
            }
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            struct Payload: Decodable { let tag_name: String; let html_url: URL; let body: String?; let assets: [Asset] }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(version, than: Self.currentVersion) {
                let dmg = payload.assets.first { $0.name == "Hoot.dmg" } ?? payload.assets.first { $0.name.hasSuffix(".dmg") }
                available = Release(version: version, page: payload.html_url, download: dmg?.browser_download_url, notes: payload.body ?? "")
                lastResult = "Hoot \(version) is available."
            } else {
                available = nil
                lastResult = "You're up to date."
            }
        } catch {
            lastResult = "Couldn't check for updates (\(error.localizedDescription))."
        }
    }

    /// Compares dotted versions numerically ("1.10.0" > "1.9.2").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
