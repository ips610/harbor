import Foundation

// launch.h isn't imported into Swift; the symbol lives in libSystem.
@_silgen_name("launch_activate_socket")
private func launchActivateSocket(_ name: UnsafePointer<CChar>,
                                  _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                                  _ count: UnsafeMutablePointer<Int>) -> Int32

/// Socket activation: launchd holds 127.0.0.1:8470 and [::1]:8470 and starts
/// harbor (`--launchd`) when something connects, so typing harbor.localhost
/// in the browser opens the app. Nothing runs until then.
enum LaunchAgent {
    static let port = 8470
    static let underLaunchd = CommandLine.arguments.contains("--launchd")
    static var label: String { Bundle.main.bundleIdentifier ?? "local.harbor" }
    static var domain: String { "gui/\(getuid())" }
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // MARK: Started by launchd

    /// The listening sockets launchd hands over, if launchd started us.
    static func activatedSockets() -> [Int32] {
        var out: [Int32] = []
        for name in ["v4", "v6"] {
            var fds: UnsafeMutablePointer<Int32>?
            var count = 0
            guard launchActivateSocket(name, &fds, &count) == 0, let fds else { continue }
            for i in 0..<count { out.append(fds[i]) }
            free(fds)
        }
        return out
    }

    // MARK: Installing

    private static var wanted: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "", "--launchd"],
            "Sockets": [
                "v4": ["SockNodeName": "127.0.0.1", "SockServiceName": "\(port)", "SockFamily": "IPv4"],
                "v6": ["SockNodeName": "::1", "SockServiceName": "\(port)", "SockFamily": "IPv6"],
            ],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
    }

    /// The installed agent starts an app that is no longer there.
    static var pointsAtMissingApp: Bool {
        guard let d = NSDictionary(contentsOf: plistURL), let exe = (d["ProgramArguments"] as? [String])?.first else {
            return false
        }
        return !FileManager.default.isExecutableFile(atPath: exe)
    }

    /// Makes sure the agent exists, points at this copy of the app and is
    /// loaded. True when launchd owns the port.
    @discardableResult
    static func ensureInstalled() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.executablePath != nil else { return false }
        let loaded = launchctl(["print", "\(domain)/\(label)"])
        let current = NSDictionary(contentsOf: plistURL)
        if loaded, let current, current.isEqual(to: wanted) { return true }
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: wanted, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        if loaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        // bootout finishes asynchronously; retry bootstrap briefly.
        for _ in 0..<15 {
            if launchctl(["bootstrap", domain, plistURL.path]) { return true }
            usleep(200_000)
        }
        return false
    }

    /// Starts the launchd instance now, without waiting for a connection.
    static func kickstart() -> Bool {
        launchctl(["kickstart", "\(domain)/\(label)"])
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: "Open the page" from a Finder-started copy to the launchd one

    private static var flagURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(label).open-page")
    }

    static func requestPage() {
        try? Data().write(to: flagURL)
    }

    /// One-shot: true if a copy asked for the page in the last 30 s.
    static func takePageRequest() -> Bool {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: flagURL.path))?[.modificationDate] as? Date else {
            return false
        }
        try? FileManager.default.removeItem(at: flagURL)
        return Date().timeIntervalSince(date) < 30
    }

    /// A launch within two minutes of boot is almost certainly the login item.
    static var soonAfterBoot: Bool {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return false }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec) < 120
    }
}
