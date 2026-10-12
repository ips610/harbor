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

    /// A made-up newer release, for snapshots: "Update now" is shown there, and does nothing.
    private(set) var madeUp = false
    func useMadeUp(latest: String?) {
        self.latest = latest
        madeUp = latest != nil
    }

    /// `then` runs when a check that actually asked GitHub has finished. A test run, and a
    /// snapshot with a made-up release, ask GitHub nothing.
    func check(force: Bool = false, then: (@MainActor () -> Void)? = nil) {
        guard !checking, !madeUp, NSClassFromString("XCTestCase") == nil else { return }
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

    // MARK: Update now (see Updater)

    /// Is "Update now" there beside the link? Only with a newer release, and only for a copy
    /// that can hold a download to its own signing key and may replace itself where it is.
    var canUpdateNow: Bool { newer && (Updater.offered || madeUp) }
    private(set) var updating = false
    /// Why the last try didn't go through, in plain words. The app is as it was.
    private(set) var updateProblem: String?

    /// What is asked before anything is downloaded. `sharing`: something is on the network or has a public link.
    nonisolated static func updateQuestion(version: String, sharing: Bool) -> String {
        "\(AppInfo.name) downloads \(version) from GitHub, checks that it is signed with the same key as this copy, puts it in this one's place and starts again. The old one goes to the Trash."
            + (sharing ? " What is on your network, and any public link, ends with the update." : "")
    }

    /// Only ever on the owner's click. Returns nil when the update is under way, or why nothing was started.
    func updateNow() -> String? {
        guard canUpdateNow, let latest else { return "This copy can't update itself. Use the link." }
        if updating { return "The update is already under way." }
        // Not in the middle of something the owner asked for: a stop that is still waiting on its process would be cut short.
        guard Monitor.shared.busy.isEmpty else { return "\(AppInfo.name) is still stopping something. Try again when that is done." }
        if madeUp { return "This release is made up, so nothing is downloaded." }
        guard let requirement = Updater.ownRequirement(), let id = Bundle.main.bundleIdentifier else { return "\(AppInfo.name) couldn't read its own signature, so it can't update itself." }
        updating = true
        updateProblem = nil
        let installed = Bundle.main.bundleURL
        let world = Updater.World(requirement: requirement, bundleID: id, running: current,
                                  handOver: { new in DispatchQueue.main.sync { MainActor.assumeIsolated { Updater.handOver(new) } } })
        Task {
            // Every step in there has an end of its own (the download and the unpacking are both timed), so this always comes back.
            let problem = await Updater.update(to: latest, installed: installed, world: world)
            updating = false
            // Without a problem the new one was started and this process is gone. Still here: it is in place, but couldn't be started from here.
            updateProblem = problem?.text ?? "The new \(AppInfo.name) is in place. Quit this one and open \(AppInfo.name) again."
        }
        return nil
    }

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
