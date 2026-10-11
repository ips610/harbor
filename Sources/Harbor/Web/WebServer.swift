import AppKit
import Foundation
import Network
import Security

/// Serves the harbor page from inside the app: 127.0.0.1 only, a random
/// port, and a per-launch token that every /api call must send as X-Token.
/// An idle listener costs nothing; work happens only when the page asks.
final class WebServer: @unchecked Sendable {
    static let shared = WebServer()

    let token: String
    private let queue = DispatchQueue(label: "local.harbor.http")
    // Touched only on `queue`.
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var waiting: [(URL?) -> Void] = []

    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"

    private init() {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Start / open

    /// Starts the listener if needed; `done` runs on the main thread with the page URL.
    func start(_ done: @escaping @MainActor (URL?) -> Void) {
        let deliver: (URL?) -> Void = { url in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(url) } }
        }
        queue.async {
            if self.boundPort != 0 { deliver(self.pageURL()); return }
            self.waiting.append(deliver)
            guard self.listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.requiredInterfaceType = .loopback
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                let l = try NWListener(using: params)
                l.stateUpdateHandler = { state in self.listenerChanged(state) }
                l.newConnectionHandler = { c in self.accept(c) }
                self.listener = l
                l.start(queue: self.queue)
            } catch {
                DebugCLI.log("listener failed: \(error)")
                self.flush(nil)
            }
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

    private func pageURL() -> URL? {
        boundPort == 0 ? nil : URL(string: "http://127.0.0.1:\(boundPort)/#\(token)")
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            boundPort = listener?.port?.rawValue ?? 0
            flush(pageURL())
        case .failed(let error):
            DebugCLI.log("listener failed: \(error)")
            listener?.cancel()
            listener = nil
            boundPort = 0
            flush(nil)
        default:
            break
        }
    }

    private func flush(_ url: URL?) {
        let w = waiting
        waiting = []
        w.forEach { $0(url) }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
        // Nothing legitimate takes this long; don't let a stuck socket linger.
        queue.asyncAfter(deadline: .now() + 60) { [weak c] in c?.cancel() }
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .complete(let req):
                self.handle(req, c)
            case .incomplete:
                if complete || error != nil { c.cancel() } else { self.read(c, buf) }
            case .invalid:
                self.send(c, .json(400, ["error": "bad request"]))
            }
        }
    }

    private func handle(_ req: HTTPRequest, _ c: NWConnection) {
        // DNS rebinding: a page on another site pointing its name at 127.0.0.1
        // still sends its own Host, so require ours exactly.
        guard req.headers["host"] == "127.0.0.1:\(boundPort)" else {
            return send(c, .json(403, ["error": "forbidden"]))
        }
        let path = String(req.path.split(separator: "?", maxSplits: 1).first ?? "")
        if req.method == "GET" && path == "/" {
            return send(c, HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(Page.html.utf8)))
        }
        guard path.hasPrefix("/api/") else { return send(c, .json(404, ["error": "not found"])) }
        guard tokenMatches(req.headers["x-token"]) else { return send(c, .json(403, ["error": "forbidden"])) }
        if let origin = req.headers["origin"], origin != "http://127.0.0.1:\(boundPort)" {
            return send(c, .json(403, ["error": "forbidden"]))
        }
        switch (req.method, path) {
        case ("GET", "/api/state"):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WebAPI.state { data in self.send(c, HTTPResponse(status: 200, contentType: "application/json", body: data)) }
                }
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

    private func tokenMatches(_ given: String?) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "Content-Security-Policy: \(Self.csp)\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Cross-Origin-Resource-Policy: same-origin\r\n\r\n"
        var data = Data(head.utf8)
        data.append(r.body)
        c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
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

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
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
