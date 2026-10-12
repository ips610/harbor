import AppKit
import Foundation
import Security

/// Serves the harbor page from inside the app at http://harbor.localhost:8470
/// (or the next free port up to 8489 when another program holds that one, see
/// Ports; then a random port), on 127.0.0.1 and ::1 only.
/// The page itself is public and holds no secrets. A tab is signed in by two
/// things together: an HttpOnly, SameSite=Strict cookie and an origin key the
/// page keeps in localStorage, both handed out for a one-time code from a link
/// harbor opens itself. A cookie alone isn't tied to a port on localhost;
/// localStorage is, so another program on a different port of this name can be
/// sent the cookie but never the key. /api calls need the cookie and
/// `X-Harbor-Key`, and POSTs also need `X-Harbor: 1`. An idle listener costs nothing.
final class WebServer: @unchecked Sendable {
    static let shared = WebServer()

    /// The two halves of a session: `session` rides in the cookie, `originKey`
    /// in the `X-Harbor-Key` header. Kept in one 0600 file so a signed-in tab
    /// survives a restart (both regenerated when missing or over 30 days old).
    let session: String
    let originKey: String
    /// Per-launch nonce for the page's one inline <script> (CSP).
    let scriptNonce: String
    /// Opens a signed-in tab; a stub in tests.
    private let opener: () -> Void
    private let queue = DispatchQueue(label: "local.harbor.http")
    // Touched only on `queue`.
    private var acceptSources: [DispatchSourceRead] = []
    private var boundPort: UInt16 = 0
    private var starting = false
    private var waiting: [(URL?) -> Void] = []
    private var loginCodes: [String: Date] = [:]
    /// Last time a signed-out page had harbor open a signed-in tab (rate limit).
    private var lastInvite: Date?
    /// Every open connection, oldest first. Browsers open spare sockets that
    /// never send a request; they must not pile up.
    private var open: [(id: ObjectIdentifier, conn: Client)] = []
    private var answering = Set<ObjectIdentifier>()
    private static let requestTimeout: Double = 5
    private static let maxOpen = 16
    /// The port harbor is on first, then the rest of its range.
    private static let ports: [UInt16] = {
        let reserved = UInt16(LaunchAgent.port)
        return [reserved] + Ports.harbor.range.map { UInt16($0) }.filter { $0 != reserved }
    }()
    private static let codeLifetime: Double = 120
    private static let sessionMaxAge: Double = 30 * 86_400
    /// Hard cap on a request: the 16 KB head plus the 64 KB body we already allow.
    private static let maxRequest = 16_384 + 65_536

    static func csp(nonce: String) -> String {
        "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'"
    }

    static let host = AppInfo.slug + ".localhost"
    static let cookie = AppInfo.slug

    private init() {
        // Debug runs get throwaway in-memory secrets and never touch the file.
        let s = DebugCLI.isDebugRun ? (Self.random(24), Self.random(24))
            : Self.readSession(Self.sessionFileURL) ?? Self.makeSession(at: Self.sessionFileURL)
        (session, originKey) = s
        scriptNonce = Self.random(16)
        opener = { DispatchQueue.main.async { MainActor.assumeIsolated { WebServer.shared.openInBrowser() } } }
    }

    /// For tests: a server that never listens, with known secrets and a stub opener.
    init(session: String, originKey: String, port: UInt16, opener: @escaping () -> Void) {
        self.session = session
        self.originKey = originKey
        self.opener = opener
        scriptNonce = Self.random(16)
        boundPort = port
    }

    // MARK: Session file

    /// Where the per-user secrets live (0600), beside the quit marker.
    static var sessionFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(LaunchAgent.label)/session")
    }

    /// The stored token and origin key if the file is readable and under 30 days old.
    static func readSession(_ url: URL) -> (token: String, key: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n").map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let made = Double(parts[2]), Date().timeIntervalSince1970 - made < sessionMaxAge else { return nil }
        return (parts[0], parts[1])
    }

    /// Writes a fresh token and origin key (0600 from creation) and returns them.
    @discardableResult
    static func makeSession(at url: URL) -> (token: String, key: String) {
        let s = (token: random(24), key: random(24))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // open(2) with O_EXCL sets the mode as the file appears, so it is never
        // readable by anyone else. If it can't be written, the secrets still
        // work for this run; the next launch makes new ones.
        try? FileManager.default.removeItem(at: url)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 {
            let bytes = Array("\(s.token)\n\(s.key)\n\(Date().timeIntervalSince1970)".utf8)
            _ = Darwin.write(fd, bytes, bytes.count)
            close(fd)
        }
        return s
    }

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            bytes = (0..<n).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Start / open

    /// Starts listening if needed; `done` runs on the main thread with a fresh
    /// login link (valid for two minutes).
    func start(_ done: @escaping @MainActor (URL?) -> Void) {
        let deliver: (URL?) -> Void = { url in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(url) } }
        }
        queue.async {
            if self.boundPort != 0 { deliver(self.loginURL()); return }
            self.waiting.append(deliver)
            guard !self.starting else { return }
            self.starting = true
            // Started by launchd: serve on the sockets it hands over.
            if LaunchAgent.underLaunchd {
                let fds = LaunchAgent.gatedSockets ?? LaunchAgent.activatedSockets()
                // A socket whose address another program already held comes back unbound.
                let live = fds.filter { Sock.port(of: $0) != 0 }
                if Sock.allBound(fds.map(Sock.port)) {
                    self.adopt(live, port: Sock.port(of: live[0]))
                } else {
                    // launchd doesn't hold harbor's port (or only half of it): move to the next
                    // free one. What it does hold still gets an answer, a refusal, not silence.
                    DebugCLI.log(fds.isEmpty ? "launch_activate_socket gave nothing; binding ourselves"
                        : "another program holds harbor's port; binding the next free one")
                    self.watch(live)
                    self.tryPort(0)
                }
                // The connection the gate already accepted (its request is still unread).
                if let fd = LaunchAgent.pendingClient {
                    LaunchAgent.pendingClient = nil
                    var one: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    var tv = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    self.start(Client(fd: fd))
                }
                return
            }
            self.tryPort(0)
        }
    }

    @MainActor
    func openInBrowser() {
        start { url in
            guard let url else {
                Monitor.shared.flash("Couldn't start the \(AppInfo.name) page.")
                return
            }
            DebugCLI.log("page: \(url.absoluteString)")
            if DebugCLI.noOpen { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// A link carrying a fresh one-time code; the page trades it at /api/login.
    func loginURL() -> URL? {
        guard boundPort != 0 else { return nil }
        let now = Date()
        loginCodes = loginCodes.filter { now.timeIntervalSince($0.value) < Self.codeLifetime }
        let code = Self.random(16)
        loginCodes[code] = now
        return URL(string: "http://\(Self.host):\(boundPort)/?k=\(code)")
    }

    /// Port `i` of the fixed list, then random ports. 127.0.0.1 and ::1 must
    /// both bind on the same port, or the next port is tried.
    private func tryPort(_ i: Int) {
        guard i < Self.ports.count + 3 else {
            starting = false
            return flush(nil)
        }
        let wanted: UInt16 = i < Self.ports.count ? Self.ports[i] : 0
        guard let (fds, port) = Self.bindLoopback(wanted) else { return tryPort(i + 1) }
        adopt(fds, port: port)
    }

    /// Serve on these listening sockets (ours, or launchd's). `port` is harbor's port from
    /// now on: it goes into the port file, so the door and the next agent follow it.
    private func adopt(_ fds: [Int32], port: UInt16) {
        watch(fds)
        boundPort = port
        starting = false
        DebugCLI.log("serving on 127.0.0.1 and [::1] port \(port)\(LaunchAgent.underLaunchd ? " (launchd)" : "")")
        // Not every copy may say so: a debug run, or a stray copy opened beside the installed
        // one, is on another port and must not move harbor's (Ports.mayRecord).
        if !DebugCLI.isDebugRun || Ports.isTest,
           Ports.mayRecord(underLaunchd: LaunchAgent.underLaunchd, installed: LaunchAgent.mayManage,
                           agentLoaded: LaunchAgent.launchctl(["print", "\(LaunchAgent.domain)/\(LaunchAgent.label)"])) {
            Ports.record(Int(port), Ports.harbor)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { Monitor.shared.pagePort = Int(port) } }
        flush(loginURL())
    }

    private func watch(_ fds: [Int32]) {
        for fd in fds {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptAll(fd) }
            src.setCancelHandler { close(fd) }
            src.resume()
            acceptSources.append(src)
        }
    }

    /// Plain BSD sockets: Network.framework can't set IPV6_V6ONLY, and without
    /// it ::1 and 127.0.0.1 can't share a port. SO_REUSEADDR only lets a restart
    /// rebind 8470 while old connections sit in TIME_WAIT; without SO_REUSEPORT
    /// no other socket can listen on the same address and port. Shared with the
    /// proxy for names, which listens the same way on its own port.
    static func bindLoopback(_ port: UInt16) -> ([Int32], UInt16)? {
        var one: Int32 = 1
        let fd4 = socket(AF_INET, SOCK_STREAM, 0)
        guard fd4 >= 0 else { return nil }
        setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a4 = sockaddr_in()
        a4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a4.sin_family = sa_family_t(AF_INET)
        a4.sin_port = port.bigEndian
        a4.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let ok4 = withUnsafePointer(to: &a4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        guard ok4 else { close(fd4); return nil }
        var actual = port
        if actual == 0 {
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd4, $0, &len) } }
            actual = UInt16(bigEndian: a4.sin_port)
        }
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd6 >= 0 else { close(fd4); return nil }
        setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        var a6 = sockaddr_in6()
        a6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a6.sin6_family = sa_family_t(AF_INET6)
        a6.sin6_port = actual.bigEndian
        a6.sin6_addr = in6addr_loopback
        let ok6 = withUnsafePointer(to: &a6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
        guard ok6, listen(fd4, 64) == 0, listen(fd6, 64) == 0 else { close(fd4); close(fd6); return nil }
        for fd in [fd4, fd6] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        return ([fd4, fd6], actual)
    }

    private func flush(_ url: URL?) {
        let w = waiting
        waiting = []
        w.forEach { $0(url) }
    }

    // MARK: Connections

    /// One browser connection: read one request, answer, close.
    final class Client {
        let fd: Int32
        var buffer = Data()
        var reader: DispatchSourceRead?
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    private func acceptAll(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }  // EAGAIN: nothing more to accept
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            start(Client(fd: fd))
        }
    }

    private func start(_ c: Client) {
        let id = ObjectIdentifier(c)
        open.append((id, c))
        // Over the cap: drop the oldest sockets that aren't mid-answer.
        if open.count > Self.maxOpen {
            for (oid, old) in open.prefix(open.count - Self.maxOpen) where !answering.contains(oid) { finish(old) }
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: c.fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readable(c) }
        c.reader = src
        src.resume()
        // A socket that hasn't delivered a whole request in 5 s is a spare.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self, !c.closed, !self.answering.contains(id) else { return }
            self.finish(c)
        }
    }

    private func readable(_ c: Client) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c.fd, &chunk, chunk.count)
            if n > 0 {
                c.buffer.append(contentsOf: chunk[0..<n])
                // Stop reading a request that's already past the head + body cap.
                if c.buffer.count > Self.maxRequest {
                    c.reader?.cancel(); c.reader = nil
                    answering.insert(ObjectIdentifier(c))
                    return send(c, .json(413, ["error": "too large"]))
                }
                continue
            }
            if n == 0 || errno != EAGAIN { return finish(c) }  // EOF or error
            break
        }
        switch HTTPRequest.parse(c.buffer) {
        case .complete(let req):
            c.reader?.cancel()
            c.reader = nil
            answering.insert(ObjectIdentifier(c))
            handle(req, c)
        case .incomplete:
            break
        case .invalid:
            send(c, .json(400, ["error": "bad request"]))
        }
    }

    /// Close and forget a connection. Safe to call twice.
    private func finish(_ c: Client) {
        guard !c.closed else { return }
        c.closed = true
        c.reader?.cancel()
        c.reader = nil
        close(c.fd)
        let id = ObjectIdentifier(c)
        open.removeAll { $0.id == id }
        answering.remove(id)
    }

    /// For tests: how many sockets are open right now.
    var openCount: Int { queue.sync { open.count } }

    /// What a request gets. Deciding is separate from sending, so the tests can
    /// drive the real handler logic without a socket.
    enum Routed {
        case reply(HTTPResponse)
        /// The page shell: public, no secrets. `crossNav` marks a visit that came
        /// from another website, which must not make harbor open anything.
        case page(look: Bool, crossNav: Bool)
        // Signed-in calls, answered by WebAPI on the main actor.
        case state(see: [String]), qr(port: Int, kind: String), action(Data)
    }

    /// Runs on `queue` (it uses the login codes and the invite clock).
    func route(_ req: HTTPRequest, now: Date = Date()) -> Routed {
        // DNS rebinding: a page on another site pointing its name at loopback
        // still sends its own Host, so only our names are accepted.
        guard Self.hostAllowed(req.headers["host"], port: boundPort) else {
            return .reply(.json(403, ["error": "forbidden"]))
        }
        let parts = req.path.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "")
        let query = parts.count > 1 ? String(parts[1]) : ""
        if req.method == "GET" && path == "/" {
            // Always the shell; its script signs in with /api/login or asks for
            // a signed-in tab with /api/invite. ?look=a|b|c previews the
            // candidate designs; the default page stays.
            return .page(look: ["a", "b", "c"].contains(Self.param("look", in: query) ?? ""),
                         crossNav: req.headers["sec-fetch-site"] == "cross-site")
        }
        // Tab icons. Unlike everything else they're cacheable and allowed for loads the
        // browser makes itself: Safari keeps tab icons in its own store, and a no-store
        // or same-origin-only icon left it showing a letter instead. A cross-site load
        // is refused, so the icon can't be used as a cross-site probe.
        let iconPaths = ["/favicon.svg", "/favicon-32.png", "/favicon.ico", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"]
        if req.method == "GET" && iconPaths.contains(path) && req.headers["sec-fetch-site"] == "cross-site" {
            return .reply(.json(404, ["error": "not found"]))
        }
        let iconHeaders = [("Cache-Control", "public, max-age=604800"), ("Cross-Origin-Resource-Policy", "cross-origin")]
        if req.method == "GET" && path == "/favicon.svg" {
            return .reply(HTTPResponse(status: 200, contentType: "image/svg+xml", body: Data(Page.icon.utf8), headers: iconHeaders))
        }
        if req.method == "GET" && ["/favicon-32.png", "/favicon.ico"].contains(path) {
            return .reply(HTTPResponse(status: 200, contentType: "image/png", body: WaveMark.favicon32, headers: iconHeaders))
        }
        if req.method == "GET" && ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"].contains(path) {
            return .reply(HTTPResponse(status: 200, contentType: "image/png", body: WaveMark.appleTouch, headers: iconHeaders))
        }
        guard path.hasPrefix("/api/") else { return .reply(.json(404, ["error": "not found"])) }
        if let origin = req.headers["origin"], !Self.hosts(port: boundPort).contains(where: { origin == "http://" + $0 }) {
            return .reply(.json(403, ["error": "forbidden"]))
        }
        if req.method == "POST" {
            // A header no cross-site form can send, and JSON only.
            guard req.headers["x-harbor"] == "1" else { return .reply(.json(403, ["error": "forbidden"])) }
            guard req.headers["content-type"]?.hasPrefix("application/json") == true else {
                return .reply(.json(415, ["error": "send JSON"]))
            }
        }
        // Signing in: there is no session yet, so these two rely on the guards
        // above and refuse anything a browser marks as coming from another site.
        if req.method == "POST" && ["/api/login", "/api/invite"].contains(path) {
            guard req.headers["sec-fetch-site"] != "cross-site" else { return .reply(.json(403, ["error": "forbidden"])) }
            return .reply(path == "/api/login" ? login(req.body, now) : invite(now))
        }
        // Everything else needs both halves. Compare both before deciding, so
        // the answer doesn't show which half was wrong.
        let cookieOK = Self.constantEquals(Self.cookieValue(Self.cookie, in: req.headers["cookie"]), session)
        let keyOK = Self.constantEquals(req.headers["x-harbor-key"], originKey)
        guard cookieOK, keyOK else { return .reply(.json(403, ["error": "session"])) }
        switch (req.method, path) {
        case ("GET", "/api/state"):
            // The rows the page has on screen right now ("pid-port", a few of them): only those are looked at (see Probe).
            return .state(see: Probe.rows(in: Self.param("see", in: query) ?? ""))
        case ("GET", "/api/qr"):
            return .qr(port: Int(Self.param("port", in: query) ?? "") ?? 0, kind: Self.param("kind", in: query) ?? "")
        case ("POST", "/api/action"):
            return .action(req.body)
        default:
            return .reply(.json(404, ["error": "not found"]))
        }
    }

    /// Trades a one-time code (used once, 120 s) for the cookie and the origin key.
    private func login(_ body: Data, _ now: Date) -> HTTPResponse {
        guard let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["code"] as? String,
              let issued = loginCodes.removeValue(forKey: code), now.timeIntervalSince(issued) < Self.codeLifetime else {
            return .json(403, ["error": "code"])
        }
        var reply = HTTPResponse.json(200, ["key": originKey])
        reply.headers = [("Set-Cookie", "\(Self.cookie)=\(session); Path=/; Max-Age=\(Int(Self.sessionMaxAge)); HttpOnly; SameSite=Strict")]
        return reply
    }

    /// A signed-out page asks for a signed-in tab. harbor opens it itself through
    /// LaunchServices, so the link only reaches this user's own browser; at most
    /// once every 15 s, so a reload can't spawn tabs.
    private func invite(_ now: Date) -> HTTPResponse {
        if let last = lastInvite, now.timeIntervalSince(last) < 15 { return .json(200, ["result": "wait"]) }
        lastInvite = now
        opener()
        return .json(200, ["result": "opening"])
    }

    private func handle(_ req: HTTPRequest, _ c: Client) {
        switch route(req) {
        case .reply(let r):
            send(c, r)
        case .page(let look, let crossNav):
            let base = look ? PageLooks.html : Page.html
            let nonce = scriptNonce
            // The page's Appearance setting lives on the main actor; the page is sent from there.
            DispatchQueue.main.async {
                let page = Page.themed(base, MainActor.assumeIsolated { Monitor.shared.pageAppearance.rawValue },
                                       nonce: nonce, crossNav: crossNav)
                self.send(c, HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8)))
            }
        case .state(let see):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WebAPI.state(see: see) { data in self.send(c, HTTPResponse(status: 200, contentType: "application/json", body: data)) }
                }
            }
        case .qr(let port, let kind):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WebAPI.qr(port: port, lan: kind == "lan", name: kind == "name") { status, json in self.send(c, .json(status, json)) }
                }
            }
        case .action(let body):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WebAPI.action(body) { status, json in self.send(c, .json(status, json)) }
                }
            }
        }
    }

    /// The Host header values we answer to (DNS-rebinding guard).
    static func hosts(port: UInt16) -> [String] {
        ["\(host):\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"]
    }

    static func hostAllowed(_ host: String?, port: UInt16) -> Bool {
        guard let host else { return false }
        return hosts(port: port).contains(host)
    }

    private static func param(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    private static func cookieValue(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    /// Constant-time, so a wrong secret can't be guessed a character at a time.
    static func constantEquals(_ given: String?, _ secret: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(secret.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Answers from any thread; the write happens on the server queue.
    private func send(_ c: Client, _ r: HTTPResponse) {
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        let custom = Set(r.headers.map { $0.0.lowercased() })
        if !custom.contains("cache-control") { head += "Cache-Control: no-store\r\n" }
        head += "Connection: close\r\n"
        head += "Content-Security-Policy: \(Self.csp(nonce: scriptNonce))\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        if !custom.contains("cross-origin-resource-policy") { head += "Cross-Origin-Resource-Policy: same-origin\r\n" }
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(r.body)
        queue.async { self.write(c, data) }
    }

    private func write(_ c: Client, _ data: Data) {
        guard !c.closed else { return }
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.write(c.fd, $0.baseAddress, $0.count) }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EAGAIN {
                // Socket buffer full (rare on loopback): wait until writable.
                let rest = Data(bytes[sent...])
                let w = DispatchSource.makeWriteSource(fileDescriptor: c.fd, queue: queue)
                w.setEventHandler { [weak self] in w.cancel(); self?.write(c, rest) }
                w.resume()
                return
            }
            break
        }
        finish(c)
    }
}

// MARK: - Minimal HTTP/1.1

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum Parse { case complete(HTTPRequest), incomplete, invalid }

    static func parse(_ data: Data) -> Parse {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: sep) else { return data.count > 16_384 ? .invalid : .incomplete }
        // Cap the head whether or not it arrived in one piece.
        guard end.lowerBound - data.startIndex <= 16_384 else { return .invalid }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...65_536).contains(length) else { return .invalid }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return .complete(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body))
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    var headers: [(String, String)] = []

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 303: return "See Other"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 429: return "Too Many Requests"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
