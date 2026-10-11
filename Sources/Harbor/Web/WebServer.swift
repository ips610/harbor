import AppKit
import Foundation
import Security

/// Serves the harbor page from inside the app at http://harbor.localhost:8470
/// (falling back to 8471–8489, then a random port), on 127.0.0.1 and ::1 only.
/// The browser gets in through a short-lived login link that sets an HttpOnly,
/// SameSite=Strict session cookie; /api calls need that cookie, and POSTs also
/// need an `X-Harbor: 1` header. An idle listener costs nothing.
final class WebServer: @unchecked Sendable {
    static let shared = WebServer()

    /// Per-launch session secret, carried by the cookie.
    let session: String
    private let queue = DispatchQueue(label: "local.harbor.http")
    // Touched only on `queue`.
    private var acceptSources: [DispatchSourceRead] = []
    private var boundPort: UInt16 = 0
    private var starting = false
    private var waiting: [(URL?) -> Void] = []
    private var loginCodes: [String: Date] = [:]
    /// Every open connection, oldest first. Browsers open spare sockets that
    /// never send a request; they must not pile up.
    private var open: [(id: ObjectIdentifier, conn: Client)] = []
    private var answering = Set<ObjectIdentifier>()
    private static let requestTimeout: Double = 5
    private static let maxOpen = 16
    private static let ports: [UInt16] = Array(8470...8489)
    private static let codeLifetime: Double = 120

    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
    static let host = AppInfo.slug + ".localhost"
    static let cookie = AppInfo.slug

    private init() {
        session = Self.random(24)
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

    private func loginURL() -> URL? {
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
        for fd in fds {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptAll(fd) }
            src.setCancelHandler { close(fd) }
            src.resume()
            acceptSources.append(src)
        }
        boundPort = port
        starting = false
        DebugCLI.log("listening on 127.0.0.1 and [::1] port \(port)")
        flush(loginURL())
    }

    /// Plain BSD sockets: Network.framework can't set IPV6_V6ONLY, and without
    /// it ::1 and 127.0.0.1 can't share a port. No SO_REUSE*: nobody else may
    /// bind next to us.
    private static func bindLoopback(_ port: UInt16) -> ([Int32], UInt16)? {
        let fd4 = socket(AF_INET, SOCK_STREAM, 0)
        guard fd4 >= 0 else { return nil }
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
        var one: Int32 = 1
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
            if n > 0 { c.buffer.append(contentsOf: chunk[0..<n]); continue }
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

    private func handle(_ req: HTTPRequest, _ c: Client) {
        // DNS rebinding: a page on another site pointing its name at loopback
        // still sends its own Host, so only our names are accepted.
        let hosts = ["\(Self.host):\(boundPort)", "127.0.0.1:\(boundPort)", "[::1]:\(boundPort)"]
        guard let host = req.headers["host"], hosts.contains(host) else {
            return send(c, .json(403, ["error": "forbidden"]))
        }
        let parts = req.path.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "")
        let query = parts.count > 1 ? String(parts[1]) : ""
        if req.method == "GET" && path == "/" {
            guard let code = Self.param("k", in: query) else {
                return send(c, HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(Page.html.utf8)))
            }
            // Login link: trade the code for the session cookie, then a clean URL.
            guard let issued = loginCodes[code], Date().timeIntervalSince(issued) < Self.codeLifetime else {
                return send(c, HTTPResponse(status: 403, contentType: "text/plain; charset=utf-8",
                                            body: Data("This link has expired. Open \(AppInfo.name) again from the menu bar.".utf8)))
            }
            let cookie = "\(Self.cookie)=\(session); Path=/; HttpOnly; SameSite=Strict"
            return send(c, HTTPResponse(status: 303, contentType: "text/plain", body: Data(),
                                        headers: [("Location", "/"), ("Set-Cookie", cookie)]))
        }
        guard path.hasPrefix("/api/") else { return send(c, .json(404, ["error": "not found"])) }
        guard sessionMatches(Self.cookieValue(Self.cookie, in: req.headers["cookie"])) else {
            // Also what a tab from an earlier run gets: cookies ignore ports.
            return send(c, .json(403, ["error": "session"]))
        }
        if let origin = req.headers["origin"], !hosts.contains(where: { origin == "http://" + $0 }) {
            return send(c, .json(403, ["error": "forbidden"]))
        }
        if req.method == "POST" && req.headers["x-harbor"] != "1" {
            return send(c, .json(403, ["error": "forbidden"]))
        }
        switch (req.method, path) {
        case ("GET", "/api/state"):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WebAPI.state { data in self.send(c, HTTPResponse(status: 200, contentType: "application/json", body: data)) }
                }
            }
        case ("GET", "/api/qr"):
            let port = Int(Self.param("port", in: query) ?? "") ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WebAPI.qr(port: port) { status, json in self.send(c, .json(status, json)) } }
            }
        case ("POST", "/api/action"):
            guard req.headers["content-type"]?.hasPrefix("application/json") == true else {
                return send(c, .json(415, ["error": "send JSON"]))
            }
            let body = req.body
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WebAPI.action(body) { status, json in self.send(c, .json(status, json)) }
                }
            }
        default:
            send(c, .json(404, ["error": "not found"]))
        }
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

    private func sessionMatches(_ given: String?) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(session.utf8)
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
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "Content-Security-Policy: \(Self.csp)\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Cross-Origin-Resource-Policy: same-origin\r\n"
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
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        default: return "Error"
        }
    }
}
