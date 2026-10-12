import Foundation

// launch.h isn't imported into Swift; the symbol lives in libSystem.
@_silgen_name("launch_activate_socket")
private func launchActivateSocket(_ name: UnsafePointer<CChar>,
                                  _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                                  _ count: UnsafeMutablePointer<Int>) -> Int32

/// The ports the two apps answer on. Each has a usual one (harbor 8470, headroom
/// 8460). launchd doesn't refuse an agent whose port another program already
/// holds on 127.0.0.1 or ::1: it loads the agent and hands over a socket that
/// isn't bound, and that address keeps going to the other program. So an app
/// whose port is taken moves to the next free one in its range and stays there,
/// and writes the port to a small file. The port-80 door reads the two files, so
/// `harbor.localhost` and `headroom.localhost` land on the apps wherever they are.
enum Ports {
    struct App: Equatable {
        let usual: Int
        let range: ClosedRange<Int>
        let file: URL
    }

    /// For tests: `HARBOR_PORTS=<folder>,<harbor's port>,<headroom's port>,<proxy's port>` keeps
    /// the port files in that folder and moves the usual ports there, so nothing real is touched.
    static let testValue = ProcessInfo.processInfo.environment["HARBOR_PORTS"]
    private static let test: (folder: URL, harbor: Int, headroom: Int, proxy: Int)? = {
        let parts = (testValue ?? "").split(separator: ",").map(String.init)
        guard parts.count == 4, let h = Int(parts[1]), let r = Int(parts[2]), let p = Int(parts[3]) else { return nil }
        return (URL(fileURLWithPath: parts[0]), h, r, p)
    }()
    static var isTest: Bool { test != nil }

    private static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    static let harbor = app(test?.harbor ?? 8470, test?.folder.appendingPathComponent("harbor-port")
        ?? support.appendingPathComponent("\(LaunchAgent.label)/port"))
    static let headroom = app(test?.headroom ?? 8460, test?.folder.appendingPathComponent("headroom-port")
        ?? support.appendingPathComponent("headroom/port"))
    /// Where names (`<project>.localhost`) are answered: past both apps' ranges.
    static let proxy = UInt16(test?.proxy ?? 8490)

    /// An app may move up to 19 ports past its usual one.
    static func app(_ usual: Int, _ file: URL) -> App { App(usual: usual, range: usual...(usual + 19), file: file) }

    /// What a port file says: plain digits, inside the app's range. Anything else (and no
    /// file) means the usual port.
    static func parse(_ text: String?, _ app: App) -> Int {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), (1...5).contains(t.utf8.count),
              t.utf8.allSatisfy({ (48...57).contains($0) }), let port = Int(t), app.range.contains(port) else { return app.usual }
        return port
    }

    /// The port the app is on.
    static func reserved(_ app: App) -> Int {
        parse(try? String(contentsOf: app.file, encoding: .utf8), app)
    }

    /// Writes the app's port: plain digits, 0600, put in place in one step. Nothing is written
    /// while the file (or its absence) already says so.
    static func record(_ port: Int, _ app: App) {
        guard app.range.contains(port), reserved(app) != port else { return }
        try? FileManager.default.createDirectory(at: app.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let new = app.file.path + ".new"
        unlink(new)
        let fd = open(new, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let digits = Array(String(port).utf8)
        let written = write(fd, digits, digits.count) == digits.count
        close(fd)
        if written { rename(new, app.file.path) } else { unlink(new) }
    }

    /// May this copy write the port it is on into the port file? The copy launchd runs may,
    /// and so may one installed in Applications that runs without an agent (launchd wouldn't
    /// load one). A stray second copy, opened from Downloads or a build folder beside the
    /// real one, lands on another port and must not move harbor's.
    static func mayRecord(underLaunchd: Bool, installed: Bool, agentLoaded: @autoclosure () -> Bool) -> Bool {
        underLaunchd || (installed && !agentLoaded())
    }

    /// Can 127.0.0.1 and ::1 both be bound on this port right now? A program listening on all
    /// interfaces doesn't count: launchd binds the two loopback addresses beside it and gets
    /// their connections. One that holds a loopback address itself does.
    static func isFree(_ port: Int) -> Bool {
        guard let p = UInt16(exactly: port), let bound = WebServer.bindLoopback(p) else { return false }
        bound.0.forEach { close($0) }
        return true
    }

    /// Does another listener really hold this port on a loopback address? Not being able to
    /// bind it isn't enough: for half a minute after an agent is unloaded, the connections it
    /// just closed keep the port from being bound here, while launchd can bind it again. So
    /// taken means it can't be bound and something answers on it.
    static func isTaken(_ port: Int) -> Bool {
        guard !isFree(port), let p = UInt16(exactly: port) else { return false }
        return ["127.0.0.1", "::1"].contains { address in
            guard let fd = Sock.connect([address], port: p, within: 1) else { return false }
            close(fd)
            return true
        }
    }

    /// The port to reserve: the current one while it is the app's own agent's (`ours`) or
    /// nobody else's (`taken`), else the first free one in the range. It doesn't hop back
    /// while the current one works. nil when the whole range is taken.
    static func choose(_ app: App, current: Int, ours: Bool, taken: (Int) -> Bool = Ports.isTaken,
                       isFree: (Int) -> Bool = Ports.isFree) -> Int? {
        ours || !taken(current) ? current : app.range.first(where: isFree)
    }
}

/// Socket activation: launchd holds harbor's port (8470 unless it had to move, see
/// Ports) on 127.0.0.1 and ::1 and starts harbor (`--launchd`) when something
/// connects, so typing harbor.localhost in the browser opens the app. Nothing runs
/// until then. It holds the proxy's port for names the same way, so a visit to a
/// project's name starts harbor too, and no other program can take that port.
enum LaunchAgent {
    /// harbor's port, as the port file has it. The running app writes that file (WebServer).
    static var port: Int { Ports.reserved(Ports.harbor) }
    /// The proxy's two sockets in the agent, next to the page's "v4" and "v6".
    static let proxySockets = ["p4", "p6"]
    static let underLaunchd = CommandLine.arguments.contains("--launchd")
    static var label: String { Bundle.main.bundleIdentifier ?? "local.harbor" }
    static var domain: String { "gui/\(getuid())" }
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Is this executable a copy installed in Applications (the Mac's or the user's)? Only
    /// that copy may write, repoint or reload the agents. One opened from Downloads, a build
    /// folder, a disk image or App Translocation must never point them at a path that won't
    /// last, or take the door away from the installed copy. headroom's launcher has the same rule.
    static func isInstalled(_ executable: String, home: String = NSHomeDirectory()) -> Bool {
        let real = ((executable as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        return (real.hasPrefix("/Applications/") || real.hasPrefix(home + "/Applications/")) && !real.contains("/AppTranslocation/")
    }

    /// This copy may manage the agents: an app in Applications, and not a debug run.
    static var mayManage: Bool {
        guard !DebugCLI.isDebugRun, Bundle.main.bundleURL.pathExtension == "app", let exe = Bundle.main.executablePath else { return false }
        return isInstalled(exe)
    }

    // MARK: Started by launchd

    /// The listening sockets launchd hands over, if launchd started us: the
    /// page's, or the proxy's (`proxySockets`). Each set can be taken once.
    static func activatedSockets(_ names: [String] = ["v4", "v6"]) -> [Int32] {
        var out: [Int32] = []
        for name in names {
            var fds: UnsafeMutablePointer<Int32>?
            var count = 0
            guard launchActivateSocket(name, &fds, &count) == 0, let fds else { continue }
            for i in 0..<count { out.append(fds[i]) }
            free(fds)
        }
        return out
    }

    // MARK: Installing

    static func agent(label: String, program: [String], port: Int, extra: [String: Any] = [:]) -> [String: Any] {
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": program,
            "Sockets": [
                "v4": ["SockNodeName": "127.0.0.1", "SockServiceName": "\(port)", "SockFamily": "IPv4"],
                "v6": ["SockNodeName": "::1", "SockServiceName": "\(port)", "SockFamily": "IPv6"],
                "p4": ["SockNodeName": "127.0.0.1", "SockServiceName": "\(Proxy.port)", "SockFamily": "IPv4"],
                "p6": ["SockNodeName": "::1", "SockServiceName": "\(Proxy.port)", "SockFamily": "IPv6"],
            ],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        return agent.merging(extra) { _, new in new }
    }

    /// What `refresh` found: the loaded agent was already this version's, it was written and
    /// loaded anew (a running copy under the old one is gone), or it couldn't be.
    enum Refresh: Equatable { case current, replaced, failed }

    /// Makes the loaded agent this version's. When the installed plist isn't exactly what
    /// this version writes (the program's path, the sockets, anything), it is rewritten, the
    /// old one is booted out and the new one loaded. That is what an update needs: the copy
    /// that is running then is the old one, under an agent that doesn't hold the proxy's port.
    /// `quitOld` asks such a copy to go first. Only an installed copy does any of this.
    static func refresh(quitOld: () -> Void = {}) -> Refresh {
        guard mayManage, let exe = Bundle.main.executablePath else { return .failed }
        return install(label: label, plist: plistURL, program: [exe, "--launchd"], app: Ports.harbor, quitOld: quitOld)
    }

    /// Installs or refreshes an agent on the app's port. Whenever the agent has to be
    /// written, the port is checked first: if another program holds it, the app moves to
    /// the next free one in its range, and the port file says so from then on. (Also run
    /// by `--test-agent`, with a throwaway label and high ports; `extra` is that job's log
    /// and environment. `run` is launchctl; a test passes its own.)
    static func install(label: String, plist: URL, program: [String], app: Ports.App, extra: [String: Any] = [:],
                        quitOld: () -> Void = {}, run launchctl: ([String]) -> Bool = { LaunchAgent.launchctl($0) }) -> Refresh {
        let reserved = Ports.reserved(app)
        let loaded = launchctl(["print", "\(domain)/\(label)"])
        let current = NSDictionary(contentsOf: plist)
        // Loaded and exactly this version's: launchd holds the port for the app already.
        if loaded && current?.isEqual(to: agent(label: label, program: program, port: reserved, extra: extra)) == true { return .current }
        quitOld()
        if loaded { _ = launchctl(["bootout", "\(domain)/\(label)"]) }
        // Is the port taken? By another program: move now. By nobody that can be seen, it may
        // only be ours still: launchd letting go after the bootout, or a copy of harbor on its
        // way out. Give that a few seconds, or harbor would move for no reason and stay moved.
        var waited = 0
        while Ports.isTaken(reserved), waited < 25 {
            if let other = holder(of: reserved), !Names.isHarbor(other.path) { break }
            usleep(200_000)
            waited += 1
        }
        // A copy of harbor that still has the port is no reason to move either: launchd gets
        // the port when that copy ends.
        let stuckCopy = Ports.isTaken(reserved) && holder(of: reserved).map { Names.isHarbor($0.path) } == true
        guard let port = stuckCopy ? reserved : Ports.choose(app, current: reserved, ours: false) else { return .failed }
        if port != reserved { DebugCLI.log("port \(reserved) is taken (waited \(waited)): moving to \(port)") }
        Ports.record(port, app)
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: agent(label: label, program: program, port: port, extra: extra), format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
        } catch {
            return .failed
        }
        // The old job may still be going: retry bootstrap briefly.
        for _ in 0..<15 {
            if launchctl(["bootstrap", domain, plist.path]) { return .replaced }
            usleep(200_000)
        }
        return .failed
    }

    /// A program of this user's, not this process, that listens on `port` on a loopback
    /// address. (Root's and other users' programs can't be seen from here.)
    private static func holder(of port: Int) -> PortRow? {
        let holder = Scanner().fullScan(sampleCPU: false).ports.first { Int($0.port) == port && $0.scope != .all && !$0.isSelf }
        if let holder { DebugCLI.log("port \(port) is held by \(holder.processName) (pid \(holder.pid)) on \(holder.addressLabel)") }
        return holder
    }

    /// Starts the launchd instance now, without waiting for a connection.
    static func kickstart(_ label: String = label) -> Bool {
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

    // MARK: Staying quit

    /// Debug runs keep a marker of their own, so a test can't make the installed copy stay quit.
    private static var quitMarkerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(label)\(DebugCLI.isDebugRun ? ".debug" : "")/quit")
    }

    static var quitMarkerSet: Bool { FileManager.default.fileExists(atPath: quitMarkerURL.path) }

    static func setQuitMarker() {
        try? FileManager.default.createDirectory(at: quitMarkerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: quitMarkerURL)
    }

    static func clearQuitMarker() {
        try? FileManager.default.removeItem(at: quitMarkerURL)
    }

    /// Sockets taken by the gate, and the connection that woke harbor, for the
    /// web server to use (launch_activate_socket is only called once). The same
    /// for the proxy, when the visit was to a project's name.
    static var gatedSockets: [Int32]?
    static var pendingClient: Int32?
    static var gatedProxySockets: [Int32]?
    static var pendingProxyClient: Int32?

    /// Is this request a visit to the page? Only a top-level GET of / that didn't
    /// come from another website. The page is public now, so this is what keeps a
    /// quit harbor quit: a background poll, or an old tab's own /api/invite or
    /// /api/login, is not a visit.
    ///
    /// And only for a Host the page's server would answer (its allowlist, for the port the
    /// request came in on). Another website's name pointed at this Mac never wakes harbor.
    static func isPageVisit(_ head: String, port: UInt16 = UInt16(LaunchAgent.port)) -> Bool {
        let (method, path, header) = request(head)
        let mode = header("sec-fetch-mode")
        return method == "GET" && (path == "/" || path.hasPrefix("/?"))
            && (mode == nil || mode == "navigate") && header("sec-fetch-site") != "cross-site"
            && WebServer.hostAllowed(header("host"), port: port)
    }

    /// The same question on the proxy's port: is this a visit to a project's name?
    /// Only a browser going to a page there (typed, a bookmark, a reload), any path.
    /// A dev page left open keeps retrying its hot-reload socket and its fetches;
    /// those say so in Sec-Fetch-Mode, and must not bring a quit harbor back.
    /// And only for a Host the proxy would look up: a `<name>.localhost`, not the apps' own.
    static func isNameVisit(_ head: String) -> Bool {
        let (method, _, header) = request(head)
        let dest = header("sec-fetch-dest")
        return method == "GET" && header("sec-fetch-mode") == "navigate" && (dest == nil || dest == "document")
            && header("sec-fetch-site") != "cross-site"
            && Names.route(host: header("host"), in: Names.Table()) != .refuse
    }

    /// The method and path of a request head, and a lookup for its headers (lowercased
    /// values). Only the head, up to its blank line; a header given twice counts as not given.
    private static func request(_ head: String) -> (method: String, path: String, header: (String) -> String?) {
        let lines = head.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        return (parts.first.map(String.init) ?? "", parts.count > 1 ? String(parts[1]) : "", { name in
            let found = lines.dropFirst().filter { $0.lowercased().hasPrefix(name + ":") }
            return found.count == 1 ? found[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[1]
                .trimmingCharacters(in: .whitespaces).lowercased() : nil
        })
    }

    /// Started by launchd after a Quit: look at the request that woke us before
    /// any app or menu bar item exists. A tab's background poll gets "quit" and
    /// harbor exits; a visit to the page clears the marker and harbor starts.
    ///
    /// The proxy's port is gated the same way: a visit to a project's name starts
    /// harbor, anything else on that port gets a small "was quit" page. The gate
    /// stays for 10 s after the last refusal instead of exiting at once: a dev page
    /// left open retries every second or so, and each retry would otherwise have
    /// launchd start harbor again just to be refused.
    static func gate() {
        let page = activatedSockets(), proxy = activatedSockets(proxySockets)
        guard !page.isEmpty || !proxy.isEmpty else { return }
        gatedSockets = page
        gatedProxySockets = proxy
        var pfds = (page + proxy).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        var quiet = 0
        while quiet < 10 {
            // Opened from Applications meanwhile (that clears the marker): start for real.
            if !quitMarkerSet { return }
            guard poll(&pfds, nfds_t(pfds.count), 1000) > 0,
                  let ready = pfds.first(where: { $0.revents & Int16(POLLIN) != 0 }) else {
                quiet += 1
                continue
            }
            let client = accept(ready.fd, nil, nil)
            guard client >= 0 else { continue }
            quiet = 0
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // Peek, so the request is still there for the web server if we start.
            var buf = [UInt8](repeating: 0, count: 8192)
            var head = ""
            for _ in 0..<40 {
                let n = recv(client, &buf, buf.count, MSG_PEEK)
                if n <= 0 { break }
                head = String(decoding: buf[0..<n], as: UTF8.self)
                if head.contains("\r\n\r\n") { break }
                usleep(50_000)
            }
            let forName = proxy.contains(ready.fd)
            if forName ? isNameVisit(head) : isPageVisit(head, port: Sock.port(of: ready.fd)) {
                clearQuitMarker()
                if forName { pendingProxyClient = client } else { pendingClient = client }
                return
            }
            // Everything else, the page's own /api/invite and /api/login included, is
            // told harbor has quit and never starts it. Read what was sent first:
            // closing with it unread would reset the connection under the reply.
            _ = recv(client, &buf, buf.count, MSG_DONTWAIT)
            let body = #"{"quit":true}"#
            let reply = forName
                ? Proxy.page(503, "\(AppInfo.name) was quit. Open it again, then reload this page.")
                : Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                    + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + body).utf8)
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
        exit(0)
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
