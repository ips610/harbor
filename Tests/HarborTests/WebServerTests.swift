import XCTest
@testable import Harbor

/// The security-relevant logic, driven through the real request handler
/// (`WebServer.route`) without a socket: the two-part session, signing in,
/// the Host guard, the parser, the pid-reuse check and the session file.
/// The server here never listens, and its "open a tab" is a counter.
final class WebServerTests: XCTestCase {
    private let token = "tok-5f1d9c7a02", originKey = "key-a81e3b64d9"
    private var opened = 0
    private var server: WebServer!

    override func setUp() {
        opened = 0
        server = WebServer(session: token, originKey: originKey, port: 8470) { [unowned self] in self.opened += 1 }
    }

    /// A parsed request to harbor's own Host; `json` makes it a JSON body.
    private func request(_ method: String, _ path: String, _ headers: [String: String] = [:],
                         host: String = "harbor.localhost:8470", json: String? = nil) -> HTTPRequest {
        var headers = headers
        if let json {
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
            headers["Content-Length"] = String(json.utf8.count)
        }
        let head = ["\(method) \(path) HTTP/1.1", "Host: \(host)"] + headers.map { "\($0): \($1)" }
        guard case .complete(let req) = HTTPRequest.parse(Data((head.joined(separator: "\r\n") + "\r\n\r\n" + (json ?? "")).utf8)) else {
            fatalError("expected a complete request")
        }
        return req
    }

    private func reply(_ routed: WebServer.Routed) -> HTTPResponse? {
        if case .reply(let r) = routed { return r }
        return nil
    }

    private func json(_ r: HTTPResponse?) -> [String: Any] {
        (r.flatMap { try? JSONSerialization.jsonObject(with: $0.body) } as? [String: Any]) ?? [:]
    }

    /// The headers harbor's own page sends with a POST.
    private let own = ["X-Harbor": "1", "Sec-Fetch-Site": "same-origin", "Origin": "http://harbor.localhost:8470"]

    private func freshCode() -> String {
        let url = server.loginURL()!
        return URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "k" }!.value!
    }

    // MARK: A session needs both halves

    func testCookieAloneIsRefused() {
        // What another program on a different port of this name could be sent.
        let r = reply(server.route(request("GET", "/api/state", ["Cookie": "\(WebServer.cookie)=\(token)"])))
        XCTAssertEqual(r?.status, 403)
        XCTAssertEqual(json(r)["error"] as? String, "session")
    }

    func testKeyAloneIsRefused() {
        XCTAssertEqual(reply(server.route(request("GET", "/api/state", ["X-Harbor-Key": originKey])))?.status, 403)
    }

    func testCookieAndKeyTogetherAreAccepted() {
        let both = ["Cookie": "\(WebServer.cookie)=\(token)", "X-Harbor-Key": originKey]
        // Passed on to the API (which answers 200); not refused here.
        guard case .state = server.route(request("GET", "/api/state", both)) else { return XCTFail("state should pass with both") }
        guard case .action = server.route(request("POST", "/api/action", both.merging(own) { a, _ in a }, json: "{}")) else {
            return XCTFail("action should pass with both")
        }
        // Either half wrong is still refused.
        XCTAssertEqual(reply(server.route(request("GET", "/api/state", ["Cookie": "\(WebServer.cookie)=\(token)", "X-Harbor-Key": "nope"])))?.status, 403)
        XCTAssertEqual(reply(server.route(request("GET", "/api/state", ["Cookie": "\(WebServer.cookie)=nope", "X-Harbor-Key": originKey])))?.status, 403)
    }

    // MARK: The page is public and holds no secrets

    func testShellIsPublicAndHoldsNoSecrets() {
        // No cookie, no key: still the real page, never a decision made by the server.
        guard case .page(let look, let crossNav) = server.route(request("GET", "/")) else { return XCTFail("GET / should be the page") }
        XCTAssertFalse(look)
        XCTAssertFalse(crossNav)
        for base in [Page.html, PageLooks.html] {
            let shell = Page.themed(base, "auto", nonce: server.scriptNonce)
            XCTAssertFalse(shell.contains(token))
            XCTAssertFalse(shell.contains(originKey))
            XCTAssertTrue(shell.contains("<script nonce=\"\(server.scriptNonce)\">"))
            XCTAssertTrue(shell.contains("/api/login"))                      // both pages sign in the same way
            for left in ["__SESSION__", "__NONCE__", "__theme__", "__QR__", "__WAVES__"] { XCTAssertFalse(shell.contains(left)) }
            XCTAssertTrue(shell.contains("function qrSvg("))                 // both pages draw QR codes the same way
        }
    }

    func testCrossSiteVisitIsMarkedSoThePageWontAskForATab() {
        guard case .page(_, let crossNav) = server.route(request("GET", "/", ["Sec-Fetch-Site": "cross-site"])) else {
            return XCTFail("GET / should be the page")
        }
        XCTAssertTrue(crossNav)
        XCTAssertTrue(Page.themed(Page.html, "auto", nonce: "n", crossNav: true).contains("data-nav=\"cross\""))
        XCTAssertFalse(Page.themed(Page.html, "auto", nonce: "n").contains("data-nav"))
    }

    // MARK: Signing in: /api/login

    func testLoginHandsOutBothHalvesForACode() {
        let r = reply(server.route(request("POST", "/api/login", own, json: "{\"code\":\"\(freshCode())\"}")))
        XCTAssertEqual(r?.status, 200)
        XCTAssertEqual(json(r)["key"] as? String, originKey)
        let cookie = r?.headers.first { $0.0 == "Set-Cookie" }?.1 ?? ""
        XCTAssertTrue(cookie.hasPrefix("\(WebServer.cookie)=\(token);"))
        for part in ["HttpOnly", "SameSite=Strict", "Max-Age=2592000", "Path=/"] { XCTAssertTrue(cookie.contains(part), part) }
    }

    func testLoginCodeIsSingleUse() {
        let body = "{\"code\":\"\(freshCode())\"}"
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", own, json: body)))?.status, 200)
        // The handler removed it: the same code again gets nothing.
        let again = reply(server.route(request("POST", "/api/login", own, json: body)))
        XCTAssertEqual(again?.status, 403)
        XCTAssertNil(json(again)["key"])
        XCTAssertNil(again?.headers.first { $0.0 == "Set-Cookie" })
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", own, json: "{\"code\":\"made-up\"}")))?.status, 403)
    }

    func testLoginCodeExpires() {
        let body = "{\"code\":\"\(freshCode())\"}"
        let late = Date().addingTimeInterval(121)
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", own, json: body), now: late))?.status, 403)
    }

    func testLoginRefusesCrossSiteAndMissingHeader() {
        let body = "{\"code\":\"\(freshCode())\"}"
        var crossSite = own; crossSite["Sec-Fetch-Site"] = "cross-site"
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", crossSite, json: body)))?.status, 403)
        var noHeader = own; noHeader["X-Harbor"] = nil
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", noHeader, json: body)))?.status, 403)
        var otherPort = own; otherPort["Origin"] = "http://harbor.localhost:9999"
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", otherPort, json: body)))?.status, 403)
        var form = own; form["Content-Type"] = "application/x-www-form-urlencoded"
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", form, json: body)))?.status, 415)
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", own, host: "evil.com:8470", json: body)))?.status, 403)
        // None of those used the code up: the page's own request still works.
        XCTAssertEqual(reply(server.route(request("POST", "/api/login", own, json: body)))?.status, 200)
    }

    // MARK: Asking for a signed-in tab: /api/invite

    func testInviteOpensATabWithoutASession() {
        let r = reply(server.route(request("POST", "/api/invite", own, json: "{}")))
        XCTAssertEqual(r?.status, 200)
        XCTAssertEqual(opened, 1)
        // It tells the page nothing secret.
        XCTAssertNil(json(r)["key"])
        XCTAssertNil(r?.headers.first { $0.0 == "Set-Cookie" })
    }

    func testInviteIsRateLimited() {
        let t0 = Date()
        let ask = { (at: Date) in _ = self.server.route(self.request("POST", "/api/invite", self.own, json: "{}"), now: at) }
        ask(t0)
        ask(t0.addingTimeInterval(1))
        ask(t0.addingTimeInterval(14))
        XCTAssertEqual(opened, 1)                 // one tab per 15 s, however often it is asked
        ask(t0.addingTimeInterval(16))
        XCTAssertEqual(opened, 2)
    }

    func testInviteRefusesCrossSiteAndMissingHeader() {
        var crossSite = own; crossSite["Sec-Fetch-Site"] = "cross-site"
        XCTAssertEqual(reply(server.route(request("POST", "/api/invite", crossSite, json: "{}")))?.status, 403)
        var noHeader = own; noHeader["X-Harbor"] = nil
        XCTAssertEqual(reply(server.route(request("POST", "/api/invite", noHeader, json: "{}")))?.status, 403)
        var otherPort = own; otherPort["Origin"] = "http://harbor.localhost:9999"
        XCTAssertEqual(reply(server.route(request("POST", "/api/invite", otherPort, json: "{}")))?.status, 403)
        XCTAssertEqual(reply(server.route(request("GET", "/api/invite")))?.status, 403)   // not a POST: needs a session
        XCTAssertEqual(opened, 0)                 // and nothing was opened
    }

    // MARK: DNS rebinding: only our own Host values are accepted

    func testHostAllowlist() {
        XCTAssertTrue(WebServer.hostAllowed("harbor.localhost:8470", port: 8470))
        XCTAssertTrue(WebServer.hostAllowed("127.0.0.1:8470", port: 8470))
        XCTAssertTrue(WebServer.hostAllowed("[::1]:8470", port: 8470))
        XCTAssertFalse(WebServer.hostAllowed("harbor.localhost:9999", port: 8470))
        XCTAssertFalse(WebServer.hostAllowed(nil, port: 8470))
        // Not even the public page for another name.
        XCTAssertEqual(reply(server.route(request("GET", "/", host: "evil.com:8470")))?.status, 403)
    }

    func testIconsRefuseCrossSiteLoads() {
        XCTAssertEqual(reply(server.route(request("GET", "/favicon.svg", ["Sec-Fetch-Site": "cross-site"])))?.status, 404)
        XCTAssertEqual(reply(server.route(request("GET", "/favicon.svg", ["Sec-Fetch-Site": "same-origin"])))?.status, 200)
        XCTAssertEqual(reply(server.route(request("GET", "/favicon.svg")))?.status, 200)
    }

    // MARK: Parser limits

    private func isInvalid(_ raw: String) -> Bool {
        if case .invalid = HTTPRequest.parse(Data(raw.utf8)) { return true }
        return false
    }

    func testParserRejectsTransferEncoding() {
        // No chunked bodies: closes off request smuggling.
        XCTAssertTrue(isInvalid("POST /api/action HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"))
    }

    func testParserRejectsOversizedHead() {
        XCTAssertTrue(isInvalid("GET / HTTP/1.1\r\nHost: h\r\nX: " + String(repeating: "a", count: 17_000) + "\r\n\r\n"))
    }

    func testParserRejectsOversizedBody() {
        XCTAssertTrue(isInvalid("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 99999\r\n\r\n"))
    }

    // MARK: A kill is refused once a pid's identity changes

    func testIdentityCheck() {
        let me = getpid()
        let mine = LibProc.identity(me)
        XCTAssertFalse(mine.isEmpty)
        XCTAssertTrue(Engine.identityMatches(me, mine))
        XCTAssertFalse(Engine.identityMatches(me, mine + "x"))   // changed start time → refuse
        XCTAssertTrue(Engine.identityMatches(me, nil))           // nothing captured → allow
    }

    // MARK: The session file is private (0600) and holds both halves

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("harbor-test-\(UUID().uuidString)/session")
    }

    func testSessionFileIsPrivate() throws {
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let made = WebServer.makeSession(at: url)
        XCTAssertFalse(made.token.isEmpty)
        XCTAssertFalse(made.key.isEmpty)
        XCTAssertNotEqual(made.token, made.key)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        let read = WebServer.readSession(url)
        XCTAssertEqual(read?.token, made.token)                  // reads back what was written
        XCTAssertEqual(read?.key, made.key)
    }

    func testSessionFileReplacesALooseOne() throws {
        // A file someone left readable is replaced, not reused with its mode.
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        WebServer.makeSession(at: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testSessionFileExpires() throws {
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "tok\nkey\n\(Date().timeIntervalSince1970 - 100)".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(WebServer.readSession(url)?.key, "key")
        try "tok\nkey\n\(Date().timeIntervalSince1970 - 31 * 86_400)".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(WebServer.readSession(url))                 // over 30 days: not reused
        try "tok\n\(Date().timeIntervalSince1970)".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(WebServer.readSession(url))                 // a file with no origin key: not reused
    }

    // MARK: A quit harbor stays quit

    func testOnlyAPageVisitWakesAQuitHarbor() {
        let h = "Host: harbor.localhost:8470\r\n"
        // Typing the address, a bookmark, or the port-80 door's redirect.
        XCTAssertTrue(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\nSec-Fetch-Site: none\r\n\r\n", port: 8470))
        XCTAssertTrue(LaunchAgent.isPageVisit("GET /?look=a HTTP/1.1\r\n\(h)\r\n", port: 8470))
        // What an old tab sends by itself, the public page's own calls included.
        for head in [
            "POST /api/invite HTTP/1.1\r\n\(h)X-Harbor: 1\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n{}",
            "POST /api/login HTTP/1.1\r\n\(h)X-Harbor: 1\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n{}",
            "GET /api/state HTTP/1.1\r\n\(h)Sec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n",
            "GET / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n",       // a script fetching the page
            "GET / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\nSec-Fetch-Site: cross-site\r\n\r\n",    // a link on another website
            "GET /favicon.svg HTTP/1.1\r\n\(h)\r\n",
        ] {
            XCTAssertFalse(LaunchAgent.isPageVisit(head, port: 8470), head)
        }
        // Only for a Host the page's server answers, on the port it came in on: another
        // website's name pointed at this Mac never wakes harbor.
        let nav = "Sec-Fetch-Mode: navigate\r\nSec-Fetch-Site: none\r\n\r\n"
        for host in ["evil.com:8470", "evil.com", "harbor.localhost:9999", "harbor.localhost", "storefront.localhost:8470", "localhost:8470", ""] {
            XCTAssertFalse(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\nHost: \(host)\r\n\(nav)", port: 8470), host)
        }
        XCTAssertFalse(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\n\(nav)", port: 8470))                                    // no Host
        XCTAssertFalse(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\nSec-Fetch-Mode: navigate\r\n\r\n\(h)", port: 8470))        // one in the body only
        XCTAssertFalse(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\n\(h)Host: evil.com:8470\r\n\(nav)", port: 8470))          // two Hosts
        XCTAssertTrue(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\nHost: 127.0.0.1:8470\r\n\(nav)", port: 8470))
        XCTAssertTrue(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\nHost: harbor.localhost:8471\r\n\(nav)", port: 8471))       // harbor on a moved port
        XCTAssertFalse(LaunchAgent.isPageVisit("GET / HTTP/1.1\r\nHost: harbor.localhost:8470\r\n\(nav)", port: 8471))
    }

    // MARK: The menu and the page have separate Light/Dark settings

    @MainActor
    func testPageAndMenuAppearanceAreSeparate() {
        // As a debug run: settings come from the throwaway suite and nothing is saved.
        _ = DebugCLI.handle(["--no-open"])
        XCTAssertTrue(DebugCLI.isDebugRun)
        let m = Monitor.shared
        m.appearance = .dark
        m.pageAppearance = .dark
        // The page's switch goes through the settings action.
        var status = 0
        WebAPI.action(Data(#"{"op":"settings","appearance":"light"}"#.utf8)) { code, _ in status = code }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(m.pageAppearance, .light)
        XCTAssertEqual(m.appearance, .dark)          // the menu's is left alone
        // The gear menu's picker is bound to Monitor.appearance.
        m.appearance = .auto
        XCTAssertEqual(m.pageAppearance, .light)     // and the page's is left alone
    }

    // MARK: Scripts run only with the nonce

    func testCSPScriptSrcUsesNonce() {
        // style-src may still allow inline styles.
        let csp = WebServer.csp(nonce: "abc123")
        XCTAssertTrue(csp.contains("script-src 'nonce-abc123'"))
        XCTAssertFalse(csp.contains("script-src 'unsafe-inline'"))
    }
}
