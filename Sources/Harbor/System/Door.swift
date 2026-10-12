import Foundation
import OSLog

/// The shared "door" on port 80 (also used by headroom): launchd holds
/// 127.0.0.1:80 and [::1]:80 and starts `harbor --door` on a connection. It
/// redirects the two apps' bare names to their real ports, and hands any other
/// `<name>.localhost` to harbor's proxy, bytes both ways (so the name stays in
/// the address bar). No NSApplication, no menu bar item; it exits 10 s after
/// the last connection has gone.
enum Door {
    static let label = "local.localhost.door"
    /// Where the two apps are right now: read from their port files on every request (a file
    /// that is missing or doesn't hold a port in the app's range means its usual port).
    static func routes(harbor: Ports.App = Ports.harbor, headroom: Ports.App = Ports.headroom) -> [String: Int] {
        ["headroom.localhost": Ports.reserved(headroom), "harbor.localhost": Ports.reserved(harbor)]
    }
    private static let idleExit: Double = 10
    /// Connections it carries to the proxy at once; more are closed.
    private static let maxRelays = 128

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // MARK: Serving (`--door`)

    private static let queue = DispatchQueue(label: "local.harbor.door")
    // Touched only on `queue`.
    private static var sources: [DispatchSourceRead] = []
    private static var lastActivity = Date()
    private static var active = 0

    /// A debug door's own ports: `--door --door-port N [--proxy-port N]`.
    private static func argument(_ flag: String) -> UInt16? {
        let args = CommandLine.arguments
        return args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? UInt16(args[$0 + 1]) : nil }
    }
    private static let proxyPort = argument("--proxy-port") ?? Proxy.port

    static func run() -> Never {
        // A socket launchd couldn't bind (another program holds that address on port 80) is no use.
        var fds = LaunchAgent.activatedSockets().filter { Sock.port(of: $0) != 0 }
        // For testing next to the real door: a door on a high port that binds it itself.
        if fds.isEmpty, let port = argument("--door-port") { fds = WebServer.bindLoopback(port)?.0 ?? [] }
        if fds.isEmpty { exit(1) }  // not started by launchd: nothing to serve
        queue.sync {
            for fd in fds {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                src.setEventHandler { acceptAll(fd) }
                src.resume()
                sources.append(src)
            }
            scheduleIdleCheck()
            // launchd is taking the door away (harbor does that itself for a moment when the
            // first project goes on the network, see `aside`): nothing of what is still open
            // may stay behind on the port, so every socket is dropped, not closed.
            signal(SIGTERM, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            term.setEventHandler {
                var now = linger(l_onoff: 1, l_linger: 0)
                for fd in 3..<getdtablesize() { setsockopt(fd, SOL_SOCKET, SO_LINGER, &now, socklen_t(MemoryLayout<linger>.size)) }
                exit(0)
            }
            term.resume()
            terminate = term
        }
        dispatchMain()
    }
    private static var terminate: DispatchSourceSignal?

    private static func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + 2) {
            // A connection it is still carrying (an open page's hot-reload socket) keeps it up.
            if active == 0 && Date().timeIntervalSince(lastActivity) >= idleExit { exit(0) }
            scheduleIdleCheck()
        }
    }

    private static func acceptAll(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            lastActivity = Date()
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 1, tv_usec: 0)  // short reads, so the 5 s deadline below is enforced
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard active < maxRelays else { Sock.drop(fd); continue }
            active += 1
            // A thread each, not the GCD pool: a carried connection can last as long as its tab.
            Thread.detachNewThread {
                answer(fd)
                queue.async { active -= 1; lastActivity = Date() }
            }
        }
    }

    /// Reads the request head (blocking, 5 s timeout) and answers by Host.
    private static func answer(_ fd: Int32) {
        // Not a plain close: see Sock.closeLeavingNothing.
        defer { Sock.closeLeavingNothing(fd) }
        var head = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // A deadline for the whole request, not per read: a slow client that
        // dribbles one byte per read can't hold the thread past 5 s.
        let deadline = Date().addingTimeInterval(5)
        while head.count < 16_384, head.range(of: Data("\r\n\r\n".utf8)) == nil {
            if Date() >= deadline { return }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if n < 0 && errno == EAGAIN && Date() < deadline { continue }  // read timed out, still time left
                return
            }
            head.append(contentsOf: chunk[0..<n])
        }
        switch route(head) {
        case .reply(let data):
            write(fd, data)
        case .proxy:
            // The slow-client rule for a carried connection: the head had its 5 s above; from
            // here the door only copies bytes, and it ends when the client or harbor's proxy
            // closes. The proxy has the limits (one request per connection, a silent one dropped
            // after 10 minutes, no limit only once the server has agreed to a WebSocket).
            guard let proxy = Sock.connect(["127.0.0.1", "::1"], port: proxyPort, within: 2) else {
                return write(fd, Proxy.page(503, "\(AppInfo.name) isn't running, so this name can't open. Open \(AppInfo.name), then reload this page."))
            }
            defer { close(proxy) }
            Sock.prepare(fd)
            Sock.relay(fd, proxy, first: head, idle: nil)
        }
    }

    enum Route: Equatable { case reply(Data), proxy }

    /// What a request gets, by its Host: a redirect for the two apps, harbor's proxy for any
    /// other `.localhost` name, and 404 for the rest (so no other website's name gets anywhere).
    static func route(_ head: Data, routes: [String: Int] = routes()) -> Route {
        // Only the head counts, up to its blank line: a "Host:" line in a body is not a header.
        // It is read the way the proxy reads it (exactly one Host, plain header names), so the
        // two can't disagree about where a request goes. Anything else has no host here.
        var host = ""
        if let end = head.range(of: Data("\r\n\r\n".utf8)), let request = ProxyHead(head.subdata(in: head.startIndex..<end.upperBound)) {
            host = Names.hostName(request.host) ?? ""
        }
        // 302, never 301: browsers cache 301 forever.
        if let port = routes[host] {
            return .reply(Data(("HTTP/1.1 302 Found\r\nLocation: http://\(host):\(port)/\r\nCache-Control: no-store\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8))
        }
        if host.hasSuffix(Names.suffix) { return .proxy }
        let body = "Nothing here. Try harbor.localhost or headroom.localhost.\n"
        return .reply(Data(("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8))
    }

    private static func write(_ fd: Int32, _ data: Data) {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            sent += n
        }
    }

    /// The door as the app needs to know it: is it harbor's and loaded, and does port 80
    /// really reach it. One answer that is slow in coming isn't "another program has port 80",
    /// so that is asked up to three times. Monitor asks again later while it isn't right.
    static func check() -> (ours: Bool, reaches: Bool) {
        settled(installed: ensureInstalled(), reach: { reachable() })
    }

    static func settled(installed: Bool, reach: () -> Bool, pause: () -> Void = { sleep(1) }) -> (ours: Bool, reaches: Bool) {
        guard installed else { return (false, false) }
        for attempt in 0..<3 {
            if reach() { return (true, true) }
            if attempt < 2 { pause() }
        }
        return (true, false)
    }

    /// Does port 80 on this Mac really reach a door? launchd loads the agent even when another
    /// program already holds 127.0.0.1:80 or [::1]:80, and the bare names then go to that
    /// program instead. harbor only says so, it doesn't try to fix it.
    static func reachable(port: UInt16 = 80) -> Bool {
        ["127.0.0.1", "::1"].allSatisfy { address in
            guard let fd = Sock.connect([address], port: port, within: 2) else { return false }
            defer { close(fd) }
            Sock.send(fd, Data("GET / HTTP/1.1\r\nHost: \(WebServer.host)\r\n\r\n".utf8), within: 2)
            guard case .ok(let head, _) = Sock.readHead(fd, max: 4096, within: 3) else { return false }
            return String(decoding: head, as: UTF8.self).contains("\r\nLocation: http://\(WebServer.host):")
        }
    }

    // MARK: Making room for the network listener

    /// What became of opening a listener on the door's port.
    enum Opening: Equatable {
        case open
        /// Another program answers on that port.
        case taken
        /// Nobody answers there, and still it can't be bound yet: connections that closed a
        /// moment ago keep it for up to half a minute.
        case busy
    }

    /// Door changes one at a time: this, `install`, and whatever asks while one of them runs.
    private static let changing = NSRecursiveLock()

    /// Makes room on the door's port for a listener on every interface, and puts the door back.
    ///
    /// launchd holds the door's two loopback addresses on port 80, and its sockets are
    /// root's. While they are there nobody else can bind every interface on that port,
    /// whatever options they set: the kernel keeps one user's port from another's. The other
    /// way round works: with harbor's listener there first, launchd binds the door's
    /// addresses beside it, and each gets its own connections. So the door is unloaded,
    /// `bind` is run (it binds the listener, and the same port on IPv6), and the door is
    /// loaded again.
    ///
    /// - Whoever loads the door again in between (headroom's launcher, harbor's own check)
    ///   is unloaded again, a few times over.
    /// - The door goes back whatever came of the bind, before anything is reported; a
    ///   refused bootstrap is tried again as `install` does. `doorBack` is false only when
    ///   that didn't work, and then the owner is told.
    /// - When the bind fails, `answers` says whether another program is on the port.
    /// - Unloading the door cuts what is open through it at that moment (a page at
    ///   name.localhost reconnects by itself). That happens once, when the first project
    ///   goes on the network; later ones use the listener that is already there.
    ///
    /// (`run` is launchctl; a test passes its own.)
    static func aside(label: String = label, plist: URL = plistURL, bind: () -> Bool, answers: () -> Bool,
                      run: ([String]) -> Bool = { LaunchAgent.launchctl($0) }, pause: () -> Void = { usleep(200_000) })
        -> (opening: Opening, doorBack: Bool) {
        changing.lock()
        defer { changing.unlock() }
        let service = "\(LaunchAgent.domain)/\(label)"
        var opening = Opening.busy
        for attempt in 0..<5 {
            if run(["print", service]) { _ = run(["bootout", service]) }
            if bind() {
                opening = .open
                break
            }
            if attempt < 4 { pause() }      // launchd letting go, or somebody loading the door again
        }
        if opening != .open, answers() { opening = .taken }
        // No file, no door to put back (it was never installed; `check` sees to that).
        var back = !FileManager.default.fileExists(atPath: plist.path)
        for attempt in 0..<15 where !back {
            back = run(["bootstrap", LaunchAgent.domain, plist.path]) || run(["print", service])
            if !back, attempt < 14 { pause() }
        }
        Logger(subsystem: "local.harbor", category: "door").notice("door \(label, privacy: .public) stepped aside: port \(String(describing: opening), privacy: .public), door back=\(back, privacy: .public)")
        return (opening, back)
    }

    // MARK: Installing

    /// Makes the door harbor's: names only work through harbor's door, so a door
    /// that headroom installed (or one left pointing at a copy that moved) is
    /// pointed at this copy and loaded again. headroom leaves a door of harbor's
    /// alone. True when the door is harbor's and loaded. Only the installed copy
    /// does this (LaunchAgent.mayManage), never a debug run.
    @discardableResult
    static func ensureInstalled() -> Bool {
        guard LaunchAgent.mayManage, let exe = Bundle.main.executablePath else { return false }
        return install(label: label, plist: plistURL, program: [exe, "--door"], port: 80)
    }

    /// Loads a door agent for `program`, taking the label over from whoever has it.
    ///
    /// headroom may be installing its own door at the same moment (both apps do at launch),
    /// so a refused bootstrap isn't the end: if the label is loaded with this plist by then,
    /// that is what was wanted (headroom loads harbor's plist when it finds it unloaded); if
    /// it is loaded with another one, that one is taken over on the next try. It never leaves
    /// by its own doing a state with no door: the plist is written before the old one is
    /// booted out. (`run` is launchctl; a test passes its own. `--test-door` runs this with a
    /// throwaway label on a high port.)
    static func install(label: String, plist: URL, program: [String], port: Int, extra: [String: Any] = [:],
                        run: ([String]) -> Bool = { LaunchAgent.launchctl($0) }) -> Bool {
        changing.lock()
        defer { changing.unlock() }
        let service = "\(LaunchAgent.domain)/\(label)"
        func ours() -> Bool { NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String] == program }
        func write() -> Bool {
            let agent: [String: Any] = [
                "Label": label,
                "ProgramArguments": program,
                "Sockets": [
                    "v4": ["SockNodeName": "127.0.0.1", "SockServiceName": "\(port)", "SockFamily": "IPv4"],
                    "v6": ["SockNodeName": "::1", "SockServiceName": "\(port)", "SockFamily": "IPv6"],
                ],
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: agent.merging(extra) { _, new in new }, format: .xml, options: 0) else { return false }
            return (try? data.write(to: plist, options: .atomic)) != nil
        }
        let loaded = run(["print", service])
        if loaded, ours() { return true }
        guard write() else { return false }
        if loaded { _ = run(["bootout", service]) }
        for _ in 0..<15 {
            if run(["bootstrap", LaunchAgent.domain, plist.path]) { return true }
            if run(["print", service]) {
                if ours() { return true }
                // Someone else's door got in between: point the file back at harbor and unload theirs.
                guard write() else { return false }
                _ = run(["bootout", service])
            }
            usleep(200_000)
        }
        return false
    }
}
