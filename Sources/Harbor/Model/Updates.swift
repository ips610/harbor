import AppKit
import Foundation
import Observation

/// Is there a newer harbor on GitHub? Asked at most once a day, when the menu or the page
/// opens, or right away from Check for Updates. GitHub answers /releases/latest with a
/// redirect to /releases/tag/v1.2; reading that needs no API key and isn't held to the
/// API's hourly limit, which everyone behind one campus or office address shares.
@MainActor @Observable
final class Updates {
    static let shared = Updates()
    nonisolated static let releases = URL(string: "https://github.com/ips610/harbor/releases")!
    /// Where the project lives: the page's header links there too.
    nonisolated static let home = URL(string: "https://github.com/ips610/harbor")!

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private(set) var latest = DebugCLI.defaults.string(forKey: "update.latest")
    private(set) var checking = false
    private(set) var failed = false
    private var checked = DebugCLI.defaults.object(forKey: "update.checked") as? Date

    var newer: Bool { latest.map { Self.isNewer($0, than: current) } ?? false }
    var url: URL { newer ? Self.releases.appending(path: "tag/v\(latest!)") : Self.releases }

    /// `then` runs when a check that actually asked GitHub has finished.
    func check(force: Bool = false, then: (@MainActor () -> Void)? = nil) {
        guard !checking else { return }
        if !force, let checked, Date().timeIntervalSince(checked) < 86_400 { return }
        checking = true
        failed = false
        Task {
            let found = await Self.newestRelease()
            checking = false
            checked = Date()  // a failure waits a day too, instead of asking on every menu open
            if let found {
                latest = found
                DebugCLI.defaults.set(found, forKey: "update.latest")
                DebugCLI.defaults.set(checked, forKey: "update.checked")
            } else {
                failed = true
            }
            then?()
        }
    }

    func download() { NSWorkspace.shared.open(url) }

    /// What to say after Check for Updates.
    var summary: String {
        if failed { return "GitHub didn't answer. Try again later." }
        if newer, let latest { return "\(AppInfo.name) \(latest) is out." }
        return "You have the newest \(AppInfo.name) (\(current))."
    }

    nonisolated static func newestRelease() async -> String? {
        var request = URLRequest(url: releases.appending(path: "latest"), timeoutInterval: 10)
        request.httpMethod = "HEAD"
        // URLSession follows the redirect; the address it ends on names the release.
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url, final.deletingLastPathComponent().lastPathComponent == "tag" else { return nil }
        let version = String(final.lastPathComponent.drop { $0 == "v" })
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return version
    }

    /// "1.10" is newer than "1.9"; missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
