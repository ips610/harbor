import Darwin
import XCTest
@testable import Harbor

/// A made-up listener, as the scanner would report it.
private func row(_ port: UInt16, _ process: String = "node", pid: pid_t = 4101, folder: String? = "/Users/sam/code/storefront", path: String? = "/opt/homebrew/bin/node",
                 category: PortCategory = .dev, system: Bool = false, isSelf: Bool = false, bundle: String? = nil, workers: [pid_t] = []) -> PortRow {
    PortRow(port: port, addresses: ["127.0.0.1"], scope: .loopback, pid: pid, ppid: 1, processName: process, path: path, cwd: folder, projectRoot: folder,
            command: nil, started: Date(timeIntervalSince1970: 1_800_000_000), footprint: nil, workers: workers.count, workerPids: workers, isSystem: system,
            appBundle: bundle, appName: bundle.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }, framework: nil, category: category, isSelf: isSelf)
}

/// One of Docker's listeners, before anybody knows which container it is for.
private func dockers(_ port: UInt16, pid: pid_t = 2201) -> PortRow {
    row(port, "Docker", pid: pid, folder: nil, path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", category: .appHelper, bundle: "/Applications/Docker.app")
}

private func container(_ name: String, image: String = "nginx:1.27", project: String? = nil, service: String? = nil, id: String = "abc123") -> Docker.Container {
    Docker.Container(id: id, name: name, image: image, project: project, service: service)
}

/// A stand-in server on loopback: answers every connection with `reply`, then closes (or holds it open).
private final class Stand: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var heads: [String] = []
    private var open = true
    var seen: [String] { lock.withLock { heads } }

    init?(reply: Data, hold: Bool = false) {
        guard let bound = OnNetwork.bind(0, on: "127.0.0.1") else { return nil }
        (fd, port) = bound
        Thread.detachNewThread { [self] in
            var held: [Int32] = []
            while lock.withLock({ open }) {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 100) > 0 else { continue }
                let c = accept(fd, nil, nil)
                guard c >= 0 else { continue }
                if case .ok(let head, _) = Sock.readHead(c, max: 65536, within: 2) { lock.withLock { heads.append(String(decoding: head, as: UTF8.self)) } }
                Sock.send(c, reply, within: 2)
                if hold { held.append(c) } else { close(c) }
            }
            held.forEach { close($0) }
            close(fd)
        }
    }

    func stop() { lock.withLock { open = false } }
}

final class ProbeTests: XCTestCase {
    private func answer(_ status: String, _ headers: String = "Content-Type: text/html\r\n", _ body: String = "") -> Data {
        Data("HTTP/1.1 \(status)\r\n\(headers)\r\n\(body)".utf8)
    }

    func testWhichRowsMayBeAsked() {
        // A project's dev server, a runtime, a plain server, a container: yes.
        XCTAssertTrue(Probe.allowed(row(3000)))
        XCTAssertTrue(Probe.allowed(row(3000, category: .runtime)))
        XCTAssertTrue(Probe.allowed(row(3000, category: .other)))
        XCTAssertTrue(Probe.allowed(dockers(8080).inContainer(container("web"))))
        // Never: a database, an app's own helper port, macOS's, harbor itself in any form, the two apps' own ports,
        // a port browsers refuse, and a container that is a database.
        XCTAssertFalse(Probe.allowed(row(5432, "postgres", category: .database)))
        XCTAssertFalse(Probe.allowed(row(11434, "ollama", category: .appHelper, bundle: "/Applications/Ollama.app")))
        XCTAssertFalse(Probe.allowed(dockers(8080)))                                       // Docker's port, nobody knows whose
        XCTAssertFalse(Probe.allowed(row(5000, "ControlCenter", category: .system, system: true)))
        XCTAssertFalse(Probe.allowed(row(3000, isSelf: true)))
        XCTAssertFalse(Probe.allowed(row(3000, path: "/Applications/harbor.app/Contents/MacOS/Harbor")))
        for port in Names.reservedPorts { XCTAssertFalse(Probe.allowed(row(port)), "\(port)") }
        XCTAssertFalse(Probe.allowed(row(8470), never: [8470]))
        for port: UInt16 in [22, 25, 6000, 6667, 5060, 10080] { XCTAssertFalse(Probe.allowed(row(port)), "\(port)") }
        XCTAssertFalse(Probe.allowed(dockers(5433).inContainer(container("db", image: "postgres:16"))))
    }

    func testOnlyWhatIsLookedAtAndNotTooOftenOrTooManyAtOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0..<10).map { row(3000 + UInt16($0), pid: 4100 + pid_t($0)) } + [row(5432, "postgres", pid: 612, category: .database)]
        let ids = rows.map(\.id), named = Set(ids)
        func pick(_ looked: [String], last: [String: Date] = [:], asking: Set<String> = [], rows given: [PortRow]? = nil, named names: Set<String>? = nil) -> [String] {
            Probe.pick(looked, rows: given ?? rows, named: names ?? named, last: last, asking: asking, now: now)
        }
        XCTAssertEqual(Probe.atOnce, 6)
        XCTAssertEqual(Probe.every, 60)
        // Nobody is looking: nothing is asked. Somebody looks at one row: that one.
        XCTAssertEqual(pick([]), [])
        XCTAssertEqual(pick([ids[2]]), [ids[2]])
        XCTAssertEqual(pick([ids[2], ids[2]]), [ids[2]])
        // Ten on screen: six at a time, in the order they came; with four already on their way, two more.
        XCTAssertEqual(pick(Array(ids.prefix(10))), Array(ids.prefix(6)))
        XCTAssertEqual(pick(Array(ids.prefix(10)), asking: Set(ids[0..<4])), [ids[4], ids[5]])
        XCTAssertEqual(pick(Array(ids.prefix(10)), asking: Set(ids[0..<6])), [])
        // Asked less than a minute ago: not again. A minute ago: again.
        XCTAssertEqual(pick([ids[0], ids[1]], last: [ids[0]: now.addingTimeInterval(-59)]), [ids[1]])
        XCTAssertEqual(pick([ids[0]], last: [ids[0]: now.addingTimeInterval(-60)]), [ids[0]])
        // Never: one being asked, a row that isn't in harbor's list now, one with no name, one that may not be asked.
        XCTAssertEqual(pick([ids[0]], asking: [ids[0]]), [])
        XCTAssertEqual(pick(["9999-3000", "4100-9999", ids[0]]), [ids[0]])
        XCTAssertEqual(pick([ids[0]], rows: []), [])
        XCTAssertEqual(pick([ids[0], ids[1]], named: [ids[1]]), [ids[1]])
        XCTAssertEqual(pick([ids[10]]), [])                                                 // the database
        // What a page may send as the rows it sees: row ids and nothing else, and not without end.
        XCTAssertEqual(Probe.rows(in: "4101-3000,4102-3001"), ["4101-3000", "4102-3001"])
        XCTAssertEqual(Probe.rows(in: ""), [])
        XCTAssertEqual(Probe.rows(in: "abc,4101,4101-,-3000,1-2-3,../x,4101-3000x,4101-300000,4101-3000"), ["4101-3000"])
        XCTAssertEqual(Probe.rows(in: (0..<100).map { "1-\($0)" }.joined(separator: ",")).count, 40)
    }

    func testTheRequestSaysNothingAboutAnyone() throws {
        let sent = String(decoding: try XCTUnwrap(Probe.request(host: "storefront.localhost")), as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("GET / HTTP/1.1\r\nHost: storefront.localhost\r\n"))
        XCTAssertTrue(sent.hasSuffix("Connection: close\r\n\r\n"))
        // As the proxy passes a request on, so the server answers what the user would see…
        XCTAssertTrue(sent.contains("\r\nX-Forwarded-Host: storefront.localhost\r\n"))
        // …and with no cookie, no credentials, no body, nothing to come back to.
        for never in ["cookie", "authorization", "content-length", "referer", "origin:", "upgrade", "keep-alive"] { XCTAssertFalse(sent.lowercased().contains(never), never) }
        XCTAssertEqual(sent.components(separatedBy: "\r\n").filter { !$0.isEmpty }.map { String($0.prefix { $0 != ":" && $0 != " " }) },
                       ["GET", "Host", "Accept", "User-Agent", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Forwarded-For", "Connection"])
        // The host is a name harbor made; anything else isn't sent anywhere.
        for odd in ["storefront.localhost\r\nCookie: a=b", "storefront.localhost Cookie", "Storefront.localhost", "a.localhost/x", ""] { XCTAssertNil(Probe.request(host: odd), odd) }
        XCTAssertTrue(String(decoding: try XCTUnwrap(Probe.request(host: "storefront.localhost:8490")), as: UTF8.self).contains("Host: storefront.localhost:8490\r\n"))
    }

    func testWhatIsShownForAnAnswer() {
        XCTAssertEqual(Probe.line(for: answer("200 OK", "Content-Type: text/html; charset=utf-8\r\n", "<!doctype html><html><head><title>Storefront – Admin</title></head>")), "200 · Storefront – Admin")
        XCTAssertEqual(Probe.line(for: answer("500 Internal Server Error", "Content-Type: text/plain\r\n", "boom")), "500")
        XCTAssertEqual(Probe.line(for: answer("404 Not Found", "", "<TITLE lang=en>\n  Not\tFound \r\n</TITLE>")), "404 · Not Found")
        XCTAssertEqual(Probe.line(for: answer("204 No Content", "")), "204")
        // A redirect is shown, never followed.
        XCTAssertEqual(Probe.line(for: answer("301 Moved Permanently", "Location: /login\r\n")), "301 → /login")
        XCTAssertEqual(Probe.line(for: answer("302 Found", "location:   https://example.com/sign-in?next=%2F  \r\nContent-Type: text/html\r\n", "<title>Redirecting</title>")), "302 → https://example.com/sign-in?next=%2F")
        XCTAssertEqual(Probe.line(for: answer("304 Not Modified", "")), "304")
        // Its target is somebody else's text too: one line, nothing but text, cut to size.
        XCTAssertEqual(Probe.line(for: answer("302 Found", "Location: /a\u{1B}[31m\tb\u{202E}" + String(repeating: "x", count: 300) + "\r\n")), "302 → /a [31m b " + String(repeating: "x", count: 70))
        // Not a page: no title is looked for.
        XCTAssertEqual(Probe.line(for: answer("200 OK", "Content-Type: application/json\r\n", "{\"html\":\"<title>no</title>\"}")), "200")
        // Not HTTP at all, half of it, or nothing.
        for garbage in ["", "SSH-2.0-OpenSSH_9.6\r\n", "HTTP/1.1 OK\r\n\r\n", "HTTP/1.1 99 X\r\n\r\n", "HTTP/1.1 2000 X\r\n\r\n", "HTTP/2 200\r\n\r\n", "200 OK\r\n\r\n", "\u{0}\u{1}\u{2}"] {
            XCTAssertEqual(Probe.line(for: Data(garbage.utf8)), "not answering", garbage)
        }
        XCTAssertEqual(Probe.line(for: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<title>cut of".utf8)), "200")
    }

    func testATitleIsOnlyEverText() {
        func title(_ html: String) -> String? { Probe.title(in: html) }
        XCTAssertEqual(title("<title>Tom &amp; Jerry &lt;script&gt;alert(1)&lt;/script&gt;</title>"), "Tom & Jerry <script>alert(1)</script>")
        // Read once: what was written as text stays text.
        XCTAssertEqual(title("<title>&amp;lt;b&amp;gt; &amp;amp;</title>"), "&lt;b&gt; &amp;")
        XCTAssertEqual(title("<title>&#65;&#x42;&#X43; &ndash; &mdash; &copy;&nbsp;2026 &hellip;</title>"), "ABC – — © 2026 …")
        // What isn't a reference stays exactly as it was written.
        XCTAssertEqual(title("<title>R&D &unknown; &; &#; &#xZZ; &#1114112; &#55296; AT&T</title>"), "R&D &unknown; &; &#; &#xZZ; &#1114112; &#55296; AT&T")
        // One line, no control or direction-changing characters, at most 80 characters.
        XCTAssertEqual(title("<title>\n\n  a\r\n\tb \u{0}c\u{7}\u{1B}[31m d&#0;e&#27;f \u{202E}evil\u{2066}\u{200F} </title>"), "a b c [31m d e f evil")
        XCTAssertEqual(title("<title>" + String(repeating: "x", count: 500) + "</title>")?.count, 80)
        // Eighty characters can carry any number of combining marks: no more than 160 code points either.
        let stacked = try? XCTUnwrap(title("<title>" + String(repeating: "a" + String(repeating: "\u{0301}", count: 50), count: 200) + "</title>"))
        XCTAssertLessThanOrEqual(stacked?.count ?? 999, 80)
        XCTAssertLessThanOrEqual(stacked?.unicodeScalars.count ?? 999, 160)
        XCTAssertEqual(title("<title>" + String(repeating: "é", count: 80) + "</title>")?.count, 80)                 // ordinary text is not cut short by it
        XCTAssertEqual(Probe.maxTitle, 80)
        // The first one, whatever its case or attributes; and only a real one.
        XCTAssertEqual(title("<head><TiTlE data-x=\"1\">One</tItLe><title>Two</title>"), "One")
        XCTAssertNil(title("<titles>no</titles>"))
        XCTAssertNil(title("<title></title>"))
        XCTAssertNil(title("<title>   \n </title>"))
        XCTAssertNil(title("<title>never closed"))
        XCTAssertNil(title("no title here"))
    }

    func testAskingAServer() throws {
        // A page: its status and title, from one request that says only what the proxy would say.
        let page = try XCTUnwrap(Stand(reply: answer("200 OK", "Content-Type: text/html\r\nSet-Cookie: sid=1\r\n", "<title>Storefront</title><body>" + String(repeating: "x", count: 4000))))
        defer { page.stop() }
        XCTAssertEqual(Probe.ask(Names.Target(port: page.port, addresses: ["127.0.0.1"]), host: "storefront.localhost"), "200 · Storefront")
        XCTAssertEqual(page.seen.count, 1)
        XCTAssertTrue(page.seen[0].hasPrefix("GET / HTTP/1.1\r\nHost: storefront.localhost\r\n"))
        XCTAssertFalse(page.seen[0].lowercased().contains("cookie"))
        // A redirect: said, and nothing else is asked for.
        let elsewhere = try XCTUnwrap(Stand(reply: answer("301 Moved Permanently", "Location: http://127.0.0.1:\(page.port)/login\r\n")))
        defer { elsewhere.stop() }
        XCTAssertEqual(Probe.ask(Names.Target(port: elsewhere.port, addresses: ["127.0.0.1"]), host: "a.localhost"), "301 → http://127.0.0.1:\(page.port)/login")
        XCTAssertEqual(page.seen.count, 1, "the redirect wasn't followed")
        // Nothing listening, and only this Mac's own addresses are ever tried.
        XCTAssertEqual(Probe.ask(Names.Target(port: 1, addresses: ["127.0.0.1"]), host: "a.localhost"), "not answering")
        XCTAssertEqual(Probe.ask(Names.Target(port: page.port, addresses: ["192.0.2.7"]), host: "a.localhost"), "not answering")
        XCTAssertEqual(page.seen.count, 1)
        // A server that takes the connection and then says nothing, or never stops talking: over in three seconds, and never more than 64 KB read.
        let silent = try XCTUnwrap(Stand(reply: Data(), hold: true))
        defer { silent.stop() }
        var began = Date()
        XCTAssertEqual(Probe.ask(Names.Target(port: silent.port, addresses: ["127.0.0.1"]), host: "a.localhost"), "not answering")
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        let endless = try XCTUnwrap(Stand(reply: answer("200 OK", "Content-Type: text/html\r\n", String(repeating: "<p>no title yet</p>", count: 20_000)), hold: true))
        defer { endless.stop() }
        began = Date()
        XCTAssertEqual(Probe.ask(Names.Target(port: endless.port, addresses: ["127.0.0.1"]), host: "a.localhost"), "200")
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        XCTAssertEqual(Probe.maxAnswer, 65536)
    }
}

final class DockerTests: XCTestCase {
    private let listed = """
    [{"Id":"8f3a1c0de9b2","Names":["/shop-web-1"],"Image":"nginx:1.27","Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"},
      "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"PrivatePort":443,"Type":"tcp"}]},
     {"Id":"77aa00bb11cc","Names":["/postgres-dev"],"Image":"postgres:16","Labels":{},"Ports":[{"PrivatePort":5432,"PublicPort":5432,"Type":"tcp"},{"PrivatePort":53,"PublicPort":5353,"Type":"udp"}]},
     {"Id":"not hex!","Names":["/x"],"Image":"x","Ports":[{"PublicPort":9000,"Type":"tcp"}]},
     {"Id":"0011","Names":[],"Image":"x","Ports":[{"PublicPort":9001,"Type":"tcp"}]},
     {"Id":"0022","Names":["/late"],"Image":"x","Ports":[{"PublicPort":8080,"Type":"tcp"},{"PublicPort":70000,"Type":"tcp"},{"PublicPort":0,"Type":"tcp"}]},
     {"Id":"0033","Names":["/ev\\u001b[31mil\\n\\u202eeman"],"Image":"\(String(repeating: "i", count: 300))","Labels":{"com.docker.compose.project":"  a\\tb  ","com.docker.compose.service":""},"Ports":[{"PublicPort":9002,"Type":"tcp"}]}]
    """

    private func answer(_ body: String, status: String = "200 OK", chunked: Bool = false) -> Data {
        if chunked {
            let half = body.utf8.count / 2, bytes = Array(body.utf8)
            let parts = [bytes[..<half], bytes[half...]].map { String($0.count, radix: 16) + "\r\n" + String(decoding: $0, as: UTF8.self) + "\r\n" }.joined()
            return Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\(parts)0\r\n\r\n".utf8)
        }
        return Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    func testTheOneRequest() {
        // Everything harbor ever writes to Docker's socket: one GET, with no body, that changes nothing.
        XCTAssertEqual(String(decoding: Docker.request, as: UTF8.self), "GET /containers/json HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n")
    }

    func testWhatTheEngineSaysByPort() throws {
        for chunked in [false, true] {
            let found = try XCTUnwrap(Docker.parse(answer(listed, chunked: chunked)))
            XCTAssertEqual(Set(found.keys), [8080, 5432, 9002], "tcp ports that are published, by containers with an id and a name")
            XCTAssertEqual(found[8080], Docker.Container(id: "8f3a1c0de9b2", name: "shop-web-1", image: "nginx:1.27", project: "shop", service: "web"))   // the first to say so
            XCTAssertEqual(found[8080]?.title, "web")
            XCTAssertEqual(found[8080]?.group, "shop")
            XCTAssertEqual(found[5432]?.title, "postgres-dev")
            XCTAssertEqual(found[5432]?.group, "Docker")
            XCTAssertNil(found[5432]?.project)
            // Somebody else's text, made fit to show: no escape or direction characters, one line, cut to size; an empty label is none.
            XCTAssertEqual(found[9002]?.name, "ev [31mil eman")
            XCTAssertEqual(found[9002]?.image.count, 80)
            XCTAssertEqual(found[9002]?.project, "a b")
            XCTAssertNil(found[9002]?.service)
        }
        // Anything but a 200 holding a list is no answer.
        XCTAssertNil(Docker.parse(answer(listed, status: "500 Internal Server Error")))
        XCTAssertNil(Docker.parse(answer("{\"message\":\"no\"}")))
        XCTAssertNil(Docker.parse(answer("[{\"Id\"")))
        XCTAssertNil(Docker.parse(Data("garbage".utf8)))
        XCTAssertNil(Docker.parse(Data()))
        XCTAssertNil(Docker.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n[]\r\n0\r\n\r\n".utf8)))
        XCTAssertEqual(Docker.parse(answer("[]")), [:])
        // Which images are databases (no name, no status line).
        for image in ["postgres:16", "ghcr.io/acme/postgres@sha256:abc", "mysql", "mariadb:11", "redis:7-alpine", "mongo", "mcr.microsoft.com/mssql/server:2022-latest", "valkey/valkey",
                      "bitnami/postgresql:16", "pgvector/pgvector:pg16", "redis/redis-stack:latest", "redis/redis-stack-server", "docker.io/library/POSTGRESQL"] {
            XCTAssertTrue(container("x", image: image).isDatabase, image)
        }
        for image in ["nginx:1.27", "axllent/mailpit", "acme/server", "node:22", "postgres-admin-ui", ""] { XCTAssertFalse(container("x", image: image).isDatabase, image) }
    }

    func testOnlyDockersOwnProcessesAndOnlyThisUsersSocket() throws {
        XCTAssertTrue(Docker.owns(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"))
        XCTAssertTrue(Docker.owns(path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper"))
        XCTAssertTrue(Docker.owns(path: "/opt/homebrew/bin/limactl"))
        for path in ["/opt/homebrew/bin/node", "/usr/bin/ssh", "/Users/sam/Docker.application/x", "/usr/local/bin/docker", nil] { XCTAssertFalse(Docker.owns(path: path), path ?? "nil") }
        // Only where the real ones are installed. A folder that merely has "Docker.app" in its path is anybody's.
        XCTAssertTrue(Docker.owns(path: "/Users/sam/Applications/Docker.app/Contents/MacOS/com.docker.backend", home: "/Users/sam"))
        XCTAssertTrue(Docker.owns(path: "/opt/homebrew/Cellar/lima/1.0.2/bin/limactl"))
        for path in ["/Users/sam/code/Docker.app/Contents/MacOS/com.docker.backend", "/private/tmp/x/Docker.app/Contents/MacOS/server", "/Applications/Evil.app/Contents/Resources/Docker.app/x",
                     "/Users/sam/Downloads/OrbStack.app/Contents/MacOS/OrbStack Helper", "/Users/other/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                     "/Users/sam/bin/limactl", "/private/tmp/limactl", "/opt/homebrew/limactl"] {
            XCTAssertFalse(Docker.owns(path: path, home: "/Users/sam"), path)
        }
        // Sockets: only one that is there, is a socket, and is this user's own. DOCKER_HOST counts when it names a unix socket.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(Lan.token(4))").path
        try FileManager.default.createDirectory(atPath: home + "/.docker/run", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.colima/default", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: home + "/.colima/default/docker.sock"))
        XCTAssertEqual(Docker.sockets(home: home, environment: [:]).filter { $0.hasPrefix(home) }, [])
        let listener = try XCTUnwrap(unixListener(home + "/.docker/run/docker.sock"))
        defer { close(listener) }
        XCTAssertEqual(Docker.sockets(home: home, environment: [:]).filter { $0.hasPrefix(home) }, [home + "/.docker/run/docker.sock"])
        let other = try XCTUnwrap(unixListener(home + "/mine.sock"))
        defer { close(other) }
        XCTAssertEqual(Docker.sockets(home: home, environment: ["DOCKER_HOST": "unix://\(home)/mine.sock"]).first, home + "/mine.sock")
        XCTAssertFalse(Docker.sockets(home: home, environment: ["DOCKER_HOST": "tcp://192.0.2.7:2375"]).contains { $0.contains("192.0.2.7") })
        XCTAssertEqual(Docker.sockets(home: home, environment: ["DOCKER_HOST": "unix://\(home)/.docker/run/docker.sock"]).filter { $0.hasPrefix(home) }.count, 1)   // not twice
    }

    private func unixListener(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        return fd
    }

    func testOnlyTheGetIsEverSent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("d-\(Lan.token(4))").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/docker.sock", listener = try XCTUnwrap(unixListener(path))
        defer { close(listener) }
        let reply = answer(listed)
        var received = Data()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let c = accept(listener, nil, nil)
            var chunk = [UInt8](repeating: 0, count: 4096)
            // Everything the other side writes, until it has been quiet for a moment.
            while true {
                var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 150) > 0 else { break }
                let n = read(c, &chunk, chunk.count)
                if n <= 0 { break }
                received.append(contentsOf: chunk[0..<n])
            }
            _ = reply.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            close(c)
            done.signal()
        }
        let answered = try XCTUnwrap(Docker.ask(path))
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(received, Docker.request, "one GET and not a byte more")
        XCTAssertEqual(Docker.parse(answered)?[8080]?.name, "shop-web-1")
        // A socket nobody answers on, and one that isn't there: no answer, within the second.
        let silent = try XCTUnwrap(unixListener(folder + "/silent.sock"))
        defer { close(silent) }
        let began = Date()
        XCTAssertNil(Docker.ask(folder + "/silent.sock"))
        XCTAssertNil(Docker.ask(folder + "/nothing.sock"))
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        XCTAssertEqual(Docker.wait, 1)
    }

    func testRowsBecomeTheirContainers() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var book = Docker.Book()
        var answers: [UInt16: Docker.Container]? = [8080: container("shop-web-1", project: "shop", service: "web"), 5433: container("shop-db-1", image: "postgres:16", project: "shop", service: "db"),
                                                     8025: container("mailpit", image: "axllent/mailpit"), 3000: container("impostor")]
        book.ask = { answers }
        // Nothing of Docker's is listening: Docker isn't asked at all.
        let plain = [row(3000), row(5432, "postgres", pid: 612, category: .database)]
        XCTAssertEqual(book.name(plain, now: t0), plain)
        XCTAssertEqual(book.asked, 0)
        // Docker is listening: asked once, and its rows are the containers. A row that isn't Docker's keeps its own
        // name whatever Docker says about its port, and a port Docker says nothing about stays "Docker".
        let rows = plain + [dockers(8080), dockers(5433), dockers(8025), dockers(9999)]
        let named = book.name(rows, now: t0)
        XCTAssertEqual(book.asked, 1)
        XCTAssertEqual(named.map(\.title), ["storefront", "storefront", "web", "db", "mailpit", "Docker"])
        XCTAssertEqual(named.map(\.label), ["node", "postgres", "web", "db", "mailpit", "Docker"])
        XCTAssertEqual(named.map(\.groupTitle), ["storefront", "storefront", "shop", "shop", "Docker", "Docker"])
        XCTAssertEqual(named[2].groupKey, named[3].groupKey)
        XCTAssertNotEqual(named[2].groupKey, named[4].groupKey)
        XCTAssertEqual(named.map(\.category), [.dev, .database, .dev, .database, .dev, .appHelper])
        XCTAssertEqual(named[2].framework, "nginx:1.27")
        XCTAssertNil(named[0].container)
        XCTAssertEqual(named[2].id, rows[2].id)                                            // the same listener, only known better
        // Kept for fifteen seconds; asked again after that; and at once when told to (a container is on the network).
        _ = book.name(rows, now: t0.addingTimeInterval(14))
        XCTAssertEqual(book.asked, 1)
        _ = book.name(rows, now: t0.addingTimeInterval(15))
        XCTAssertEqual(book.asked, 2)
        _ = book.name(rows, now: t0.addingTimeInterval(16), fresh: true)
        XCTAssertEqual(book.asked, 3)
        // No answer (no socket, or too slow): the rows stay Docker's, and it isn't asked again on every scan.
        answers = nil
        XCTAssertEqual(book.name(rows, now: t0.addingTimeInterval(40)).map(\.title), ["storefront", "storefront", "Docker", "Docker", "Docker", "Docker"])
        _ = book.name(rows, now: t0.addingTimeInterval(41))
        XCTAssertEqual(book.asked, 4)
        // Docker stops listening: what was kept is dropped.
        _ = book.name(plain, now: t0.addingTimeInterval(42))
        answers = [:]
        _ = book.name(rows, now: t0.addingTimeInterval(43))
        XCTAssertEqual(book.asked, 5)
    }

    func testContainersGetNamesByTheUsualRules() {
        let web = dockers(8080).inContainer(container("shop-web-1", project: "shop", service: "web"))
        let admin = dockers(8443).inContainer(container("shop-web-1", project: "shop", service: "web"))
        let other = dockers(9090, pid: 2202).inContainer(container("blog-web-1", project: "blog", service: "web", id: "def456"))
        let db = dockers(5433).inContainer(container("shop-db-1", image: "postgres:16", project: "shop", service: "db"))
        let alone = dockers(8025).inContainer(container("Mail_Pit 2", image: "axllent/mailpit"))
        let unknown = dockers(9999)
        XCTAssertEqual(Names.key(web), "docker/shop/web")
        XCTAssertEqual(Names.key(alone), "docker/docker/Mail_Pit 2")
        XCTAssertNotEqual(Names.key(web), Names.key(other))
        let table = Names.assign([web, admin, other, db, alone, unknown, row(3000)])
        // Its service. Two projects have a "web": one keeps the plain name, the other gets its project in front, as two folders would.
        XCTAssertEqual(table.byRow[other.id], "web")
        XCTAssertEqual(table.byRow[web.id], "shop-web")
        XCTAssertEqual(table.byRow[admin.id], "shop-web-8443")                              // the same container's other port
        XCTAssertEqual(Names.assign([web, admin]).byRow[web.id], "web")                     // alone it is just "web"
        XCTAssertNil(table.byRow[db.id])                                                    // a database
        XCTAssertEqual(table.byRow[alone.id], "mail-pit-2")
        XCTAssertEqual(table.byRow[unknown.id], "docker")                                   // nobody knows whose: as before
        XCTAssertEqual(table.targets["shop-web"]?.port, 8080)
        // A container's row carries Docker's own start time, days old. A project of mine with the same name, started
        // long after Docker, still gets the plain name; the container gets its project in front.
        let mine = PortRow(port: 5173, addresses: ["127.0.0.1"], scope: .loopback, pid: 4301, ppid: 1, processName: "node", path: "/opt/homebrew/bin/node", cwd: "/Users/sam/code/web",
                           projectRoot: "/Users/sam/code/web", command: nil, started: Date(timeIntervalSince1970: 1_800_500_000), footprint: nil, workers: 0, workerPids: [],
                           isSystem: false, appBundle: nil, appName: nil, framework: nil, category: .dev, isSelf: false)
        XCTAssertLessThan(web.started ?? .distantFuture, mine.started ?? .distantPast)
        let tied = Names.assign([web, mine])
        XCTAssertEqual(tied.byRow[mine.id], "web")
        XCTAssertEqual(tied.byRow[web.id], "shop-web")
        XCTAssertEqual(Names.assign([mine, web]).byRow[mine.id], "web")
        // The same against an app with no folder.
        let app = row(11434, "ollama", pid: 733, folder: nil, path: "/Applications/Ollama.app/Contents/MacOS/ollama", category: .appHelper, bundle: "/Applications/Ollama.app")
        let named = dockers(8090).inContainer(container("ollama", id: "aa11"))
        XCTAssertEqual(Names.assign([named, app]).byRow[app.id], "ollama")
        XCTAssertNotEqual(Names.assign([named, app]).byRow[named.id], "ollama")
        // A container called like one of the apps, or on a port browsers refuse, gets what any row would.
        let reserved = dockers(8081).inContainer(container("harbor"))
        XCTAssertNotEqual(Names.assign([reserved]).byRow[reserved.id], "harbor")
        XCTAssertNil(Names.assign([dockers(6000).inContainer(container("x11"))]).byRow["2201-6000"])
    }

    func testDockerItselfIsNeverStopped() {
        // The process on a container's port is Docker's own: no signal from the app, the page or the command line.
        let backend = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        XCTAssertEqual(Engine.refusal(pid: 2201, path: backend, name: "Docker")?.result, .system)
        XCTAssertEqual(Engine.refusal(pid: 2201, path: backend, name: "Docker")?.message, Docker.noKill(nil))
        XCTAssertTrue(Docker.noKill(container("postgres-dev")).contains("docker stop postgres-dev"))
        // The hint is something to copy into a shell. A name Docker itself wouldn't give is left out of it.
        for name in ["web", "shop-web-1", "a", "A9_b.c-d", "0db"] { XCTAssertTrue(Docker.isPlainName(name), name) }
        for name in ["", "-web", ".web", "_web", "we b", "web;id", "web$(id)", "web`id`", "web|sh", "wéb", "web\nx", "x; rm -rf ~ $(id)", "a&b", "a>b", "a'b", "a\"b", "a/b"] {
            XCTAssertFalse(Docker.isPlainName(name), name)
            let hint = Docker.noKill(container(name))
            XCTAssertTrue(hint.hasPrefix("A container. Stop it with docker stop, or in Docker's own window"), name)
            if !name.isEmpty { XCTAssertFalse(hint.contains(name), name) }
        }
        // Quitting is for apps. Docker Desktop may be quit on purpose from the list of apps it is in, and is told what
        // goes with it; a "quit" for the pid behind one of its port rows is the kill that isn't offered, and is refused the same way.
        let listed = "/Applications/Docker.app/Contents/MacOS/Docker"
        XCTAssertNil(Docker.quitRefusal(path: listed, isListedApp: true, fromApps: true))
        XCTAssertEqual(Docker.quitRefusal(path: backend, isListedApp: false, fromApps: false), Docker.noKill(nil))
        XCTAssertEqual(Docker.quitRefusal(path: backend, isListedApp: true, fromApps: false), Docker.noKill(nil))    // its pid, but asked for through a row
        XCTAssertEqual(Docker.quitRefusal(path: backend, isListedApp: false, fromApps: true), Docker.noKill(nil))    // says "apps", but isn't one that is listed
        XCTAssertNil(Docker.quitRefusal(path: "/Applications/Safari.app/Contents/MacOS/Safari", isListedApp: true, fromApps: false))
        XCTAssertNil(Docker.quitRefusal(path: "/opt/homebrew/bin/node", isListedApp: false, fromApps: false))
        XCTAssertNil(Docker.quitRefusal(path: nil, isListedApp: false, fromApps: false))
        XCTAssertEqual(Docker.quitNote, "Every container stops with it.")
        XCTAssertNil(Engine.refusal(pid: 4101, path: "/opt/homebrew/bin/node", name: "node"))
        // And what was always refused still is.
        XCTAssertEqual(Engine.refusal(pid: 1, path: "/opt/homebrew/bin/node", name: "node")?.result, .system)
        XCTAssertEqual(Engine.refusal(pid: getpid(), path: "/opt/homebrew/bin/node", name: "node")?.result, .system)
        XCTAssertEqual(Engine.refusal(pid: 4101, path: "/usr/sbin/cupsd", name: "cupsd")?.result, .system)
    }

    @MainActor
    func testAShareIsForOneContainer() {
        _ = DebugCLI.handle(["--no-open", "--fixture", "docker"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared
        m.stopAllSharing()
        let rows = m.ports, web = rows.first { $0.port == 8080 }!
        XCTAssertEqual(web.container?.name, "shop-web-1")
        XCTAssertEqual(m.names.byRow[web.id], "web")
        // The page is told what it is, which card it belongs on, and that it has no kill.
        var state: [String: Any] = [:]
        WebAPI.state { state = ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }
        let told = ((state["ports"] as? [[String: Any]]) ?? []).first { ($0["port"] as? Int) == 8080 }
        XCTAssertEqual(told?["name"] as? String, "web")
        XCTAssertEqual(told?["groupTitle"] as? String, "shop")
        XCTAssertEqual((told?["container"] as? [String: Any])?["image"] as? String, "nginx:1.27")
        XCTAssertEqual(told?["nokill"] as? String, Docker.noKill(web.container))
        XCTAssertEqual(told?["served"] as? String, "301 → /shop/")
        XCTAssertTrue(((state["ports"] as? [[String: Any]]) ?? []).first { ($0["port"] as? Int) == 3000 }?["nokill"] is NSNull)
        // On the network for this container. Docker's process stays, the port stays, but another container has it
        // now: the name must not start opening that one. Off, and said.
        m.useFixture(rows, shared: Names.key(web))
        XCTAssertEqual(m.lanShares[web.id]?.container, web.container?.id)
        m.useFixture(rows, shared: nil)
        XCTAssertNotNil(m.lanShares[web.id], "the same container: still on")
        let before = m.notices.last?.id
        let swapped = rows.map { $0.port == 8080 ? $0.inContainer(container("someone-else", id: "ffff0000")) : $0 }
        XCTAssertEqual(swapped.first { $0.port == 8080 }?.id, web.id)                       // the very same pid and port
        m.useFixture(swapped, shared: nil)
        XCTAssertNil(m.lanShares[web.id])
        XCTAssertNotEqual(m.notices.last?.id, before)
        XCTAssertEqual(m.notices.last?.text.hasPrefix("The container behind "), true)
        // And when Docker can't say whose port it is any more: off as well.
        m.useFixture(rows, shared: Names.key(web))
        m.useFixture(rows.map { row -> PortRow in
            var row = row
            if row.port == 8080 { row.container = nil }
            return row
        }, shared: nil)
        XCTAssertNil(m.lanShares[web.id])
        XCTAssertEqual(m.notices.last?.text.hasPrefix("The container behind "), true)
        m.stopAllSharing()
    }

    /// A container goes on the card of its project: by its compose file's folder, else by a folder it
    /// mounts from when a project of mine runs there. Names and keys don't move.
    func testAContainerJoinsItsProjectsCard() throws {
        let home = NSHomeDirectory()
        let json = """
        [{"Id":"aa11","Names":["/ds-mysql"],"Image":"mysql:8.0","Labels":{"com.docker.compose.project":"ds","com.docker.compose.service":"mysql",
           "com.docker.compose.project.working_dir":"\(home)/code/ds"},"Ports":[{"PublicPort":3307,"Type":"tcp"}]},
         {"Id":"bb22","Names":["/ds-redis-local"],"Image":"redis:7.0-alpine","Labels":{},
           "Mounts":[{"Type":"volume","Name":"abc"},{"Type":"bind","Source":"/host_mnt\(home)/code/ds/.claude/worktrees/x/redis.conf"}],
           "Ports":[{"PublicPort":6380,"Type":"tcp"}]},
         {"Id":"cc33","Names":["/other"],"Image":"redis:7","Labels":{},"Mounts":[{"Type":"bind","Source":"/opt/data"}],"Ports":[{"PublicPort":6381,"Type":"tcp"}]}]
        """
        let found = try XCTUnwrap(Docker.parse(answer(json)))
        XCTAssertEqual(found[3307]?.workingDir, home + "/code/ds")
        XCTAssertEqual(found[6380]?.mountedFrom, home + "/code/ds/.claude/worktrees/x/redis.conf")   // /host_mnt is Docker Desktop's
        XCTAssertNil(found[6381]?.workingDir)
        func row(_ port: UInt16, folder: String?, container: Docker.Container? = nil) -> PortRow {
            PortRow(port: port, addresses: ["127.0.0.1"], scope: .loopback, pid: pid_t(port), ppid: 1, processName: "node", path: nil,
                    cwd: folder, projectRoot: folder, command: nil, started: nil, footprint: nil, workers: 0, workerPids: [],
                    isSystem: false, appBundle: nil, appName: nil, framework: nil, category: .dev, isSelf: false, container: container)
        }
        var site = row(3000, folder: home + "/code/ds/exams")
        site.repo = home + "/code/ds"                                  // the git checkout above it
        let rows = Docker.join([site, row(3307, folder: nil, container: found[3307]), row(6380, folder: nil, container: found[6380]),
                                row(6381, folder: nil, container: found[6381])])
        XCTAssertEqual(rows[1].groupKey, rows[0].groupKey)             // compose: by its working folder
        XCTAssertEqual(rows[2].groupKey, rows[0].groupKey)             // plain run: by what it mounts
        XCTAssertEqual(rows[1].groupTitle, "ds")
        XCTAssertNotEqual(rows[3].groupKey, rows[0].groupKey)          // nothing of mine: stays with Docker
        XCTAssertEqual(rows[3].groupTitle, "Docker")
        XCTAssertFalse(rows[1].isOtherApp)
        XCTAssertTrue(rows[3].isOtherApp)
        // Compose with no server of mine running: still its folder's card, not "Docker".
        let alone = Docker.join([row(3307, folder: nil, container: found[3307])])
        XCTAssertEqual(alone[0].groupTitle, "ds")
        // Names are by container, as before.
        XCTAssertEqual(Names.key(rows[1]), "docker/ds/mysql")
    }
}

final class LastingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheChoicesAndTheDeadline() {
        XCTAssertEqual(Lasting.choices, [1800, 3600, 0])
        XCTAssertEqual(Lasting.choices.map(Lasting.title), ["30 min", "1 hour", "until I stop it"])
        // A public link ends after an hour unless told otherwise; the network stays on until it is turned off.
        XCTAssertEqual(Lasting.Kind.link.usual, 3600)
        XCTAssertEqual(Lasting.Kind.network.usual, 0)
        // One of the three, or it is refused: nothing odd is ever read as "for ever".
        for asked in [1800, 3600, 0] { XCTAssertEqual(Lasting.pick(asked, kind: .link), asked) }
        for odd in [-1, 1, 60, 1799, 3601, 86400, Int.max] { XCTAssertNil(Lasting.pick(odd, kind: .link), "\(odd)") }
        XCTAssertEqual(Lasting.deadline(1800, from: t0), t0.addingTimeInterval(1800))
        XCTAssertEqual(Lasting.deadline(3600, from: t0), t0.addingTimeInterval(3600))
        XCTAssertNil(Lasting.deadline(0, from: t0))
        // Over at the deadline, on the wall clock: a Mac that slept through it finds it over when it wakes.
        let until = t0.addingTimeInterval(1800)
        XCTAssertFalse(Lasting.isOver(until, now: t0.addingTimeInterval(1799)))
        XCTAssertTrue(Lasting.isOver(until, now: until))
        XCTAssertTrue(Lasting.isOver(until, now: t0.addingTimeInterval(8 * 3600)))
        XCTAssertFalse(Lasting.isOver(nil, now: .distantFuture))
        // More time is half an hour from where the deadline stands, never less than half an hour from now, and
        // nothing gets a deadline (or loses one) by it.
        XCTAssertEqual(Lasting.extended(until, now: t0), t0.addingTimeInterval(3600))
        XCTAssertEqual(Lasting.extended(until, now: t0.addingTimeInterval(1790)), t0.addingTimeInterval(3600))
        XCTAssertEqual(Lasting.extended(until, now: t0.addingTimeInterval(5000)), t0.addingTimeInterval(6800))
        XCTAssertNil(Lasting.extended(nil, now: t0))
        // A share that starts gets its time from now. One that is only moving to a new name keeps the deadline it
        // has, to the second, or none if it had none: renaming never buys time.
        XCTAssertEqual(Lasting.until(chosen: 1800, moving: nil, now: t0), t0.addingTimeInterval(1800))
        XCTAssertNil(Lasting.until(chosen: 0, moving: nil, now: t0))
        XCTAssertEqual(Lasting.until(chosen: nil, moving: .some(until), now: t0.addingTimeInterval(1700)), until)
        XCTAssertNil(Lasting.until(chosen: nil, moving: .some(nil), now: t0))
        XCTAssertEqual(Lasting.until(chosen: 3600, moving: .some(until), now: t0.addingTimeInterval(1700)), t0.addingTimeInterval(5300))   // chosen anew, by the owner
        // What the row says.
        XCTAssertEqual(Lasting.left(t0.addingTimeInterval(42 * 60 + 30), now: t0), "42 min left")
        XCTAssertEqual(Lasting.left(t0.addingTimeInterval(3600), now: t0), "1 h 0 min left")
        XCTAssertEqual(Lasting.left(t0.addingTimeInterval(65 * 60), now: t0), "1 h 5 min left")
        XCTAssertEqual(Lasting.left(t0.addingTimeInterval(59), now: t0), "under a minute left")
        XCTAssertEqual(Lasting.left(t0.addingTimeInterval(-5), now: t0), "under a minute left")
        XCTAssertNil(Lasting.left(nil, now: t0))
    }

    /// A share is for one server, and for one container: only a scan sees that it has gone. So
    /// while anything is on the network harbor scans at least every 15 seconds, whatever the
    /// refresh setting says.
    func testSomethingSharedIsLookedAtEveryFifteenSeconds() {
        for slow in [15.0, 30, 60, 600, 3600] { XCTAssertEqual(Monitor.scanEvery(refresh: slow, sharing: true, badge: false), 15, "\(slow)") }
        XCTAssertEqual(Monitor.scanEvery(refresh: 0, sharing: true, badge: false), 15)           // manual refresh
        XCTAssertEqual(Monitor.scanEvery(refresh: 5, sharing: true, badge: true), 5)             // sooner when the setting is
        XCTAssertEqual(Monitor.scanEvery(refresh: 3600, sharing: true, badge: true), 15)
        // Nothing shared: only for a badge, and then at the setting. Otherwise nothing is scanned at all.
        XCTAssertEqual(Monitor.scanEvery(refresh: 60, sharing: false, badge: true), 60)
        XCTAssertNil(Monitor.scanEvery(refresh: 0, sharing: false, badge: true))
        XCTAssertNil(Monitor.scanEvery(refresh: 15, sharing: false, badge: false))
    }

    func testTheLastChoiceIsRememberedPerKind() {
        let keep = (Lasting.remembered(.link), Lasting.remembered(.network))
        defer { Lasting.remember(.link, keep.0); Lasting.remember(.network, keep.1) }
        Lasting.remember(.link, 1800)
        Lasting.remember(.network, 3600)
        XCTAssertEqual(Lasting.remembered(.link), 1800)
        XCTAssertEqual(Lasting.remembered(.network), 3600)
        XCTAssertEqual(Lasting.pick(nil, kind: .link), 1800)                                 // nothing said: what was chosen last time
        Lasting.remember(.link, 0)
        XCTAssertEqual(Lasting.remembered(.link), 0)
        XCTAssertEqual(Lasting.remembered(.network), 3600)
        Lasting.remember(.link, 77)                                                         // not a choice: not remembered
        XCTAssertEqual(Lasting.remembered(.link), 0)
    }

    @MainActor
    func testSharesStopWhenTheirTimeIsUp() {
        _ = DebugCLI.handle(["--no-open", "--fixture", "both"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared, front = m.ports.first { $0.port == 3000 }!
        XCTAssertNotNil(m.lanShares[front.id])
        XCTAssertNil(m.lanShares[front.id]?.until)                                          // on the network: until it is turned off, as before
        let now = Date()
        // The made-up public link has about 42 minutes; the page is told so, and what the choices are.
        var state: [String: Any] = [:]
        WebAPI.state { state = ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }
        let told = ((state["ports"] as? [[String: Any]]) ?? []).first { ($0["port"] as? Int) == 3000 }
        XCTAssertEqual((told?["tunnel"] as? [String: Any])?["left"] as? String, "42 min left")
        XCTAssertTrue((told?["local"] as? [String: Any])?["left"] is NSNull)
        XCTAssertEqual(((state["lasts"] as? [String: Any])?["choices"] as? [[String: Any]])?.map { $0["title"] as? String }, ["30 min", "1 hour", "until I stop it"])
        // Nothing is over yet.
        m.endExpired(now: now.addingTimeInterval(41 * 60))
        XCTAssertNotNil(Tunnels.shared.active[3000])
        // Half an hour more, asked for: the deadline moves by exactly that.
        let until = Tunnels.shared.active[3000]?.until
        Tunnels.shared.more(3000, now: now)
        XCTAssertEqual(Tunnels.shared.active[3000]?.until, until?.addingTimeInterval(1800))
        m.endExpired(now: now.addingTimeInterval(60 * 60))
        XCTAssertNotNil(Tunnels.shared.active[3000])
        // Its time is up: stopped, and said.
        var before = m.notices.last?.id
        m.endExpired(now: now.addingTimeInterval(73 * 60))
        XCTAssertNil(Tunnels.shared.active[3000])
        XCTAssertNotEqual(m.notices.last?.id, before)
        XCTAssertEqual(m.notices.last?.text, "The public link for :3000 has ended: its time is up.")
        // The same for a server on the network that was given a deadline. One without is never touched.
        XCTAssertNotNil(m.lanShares[front.id])
        m.moreTime(front, now: now)
        XCTAssertNil(m.lanShares[front.id]?.until, "no deadline: more time gives it none")
        m.setDeadline(front.id, now.addingTimeInterval(1800))
        m.endExpired(now: now.addingTimeInterval(1799))
        XCTAssertNotNil(m.lanShares[front.id])
        m.moreTime(front, now: now.addingTimeInterval(100))
        XCTAssertEqual(m.lanShares[front.id]?.until, now.addingTimeInterval(3600))
        m.endExpired(now: now.addingTimeInterval(3599))
        XCTAssertNotNil(m.lanShares[front.id])
        before = m.notices.last?.id
        m.endExpired(now: now.addingTimeInterval(3600))
        XCTAssertNil(m.lanShares[front.id])
        XCTAssertNotEqual(m.notices.last?.id, before)
        XCTAssertEqual(m.notices.last?.text.hasSuffix(".local is off the network: its time is up."), true)
        // The one timer. It is set for the nearest deadline; and when it goes off early (the clock was set back, so
        // nothing is over yet) it is set again, or nothing would ever look at that deadline again.
        m.useFixture(m.ports, shared: Names.key(front))
        XCTAssertNil(m.expiryArmedFor, "no deadline, no timer")
        let deadline = Date().addingTimeInterval(1800)
        m.setDeadline(front.id, deadline)
        XCTAssertEqual(m.expiryArmedFor?.timeIntervalSince(deadline) ?? 99, 0, accuracy: 0.01)
        m.fireExpiryTimer()
        XCTAssertNotNil(m.lanShares[front.id], "nothing was over")
        XCTAssertEqual(m.expiryArmedFor?.timeIntervalSince(deadline) ?? 99, 0, accuracy: 0.01)
        m.endExpired(now: deadline.addingTimeInterval(-60))
        XCTAssertEqual(m.expiryArmedFor?.timeIntervalSince(deadline) ?? 99, 0, accuracy: 0.01)
        m.endExpired(now: deadline)
        XCTAssertNil(m.lanShares[front.id])
        XCTAssertNil(m.expiryArmedFor, "nothing left with a deadline")
        // A public link, or a share, started for a time that isn't one of the choices is refused.
        XCTAssertEqual(Tunnels.shared.start(front, for: 99), "A public link lasts 30 minutes, an hour, or until you stop it.")
        XCTAssertNil(Tunnels.shared.active[3000])
        // (And these ports are made up: whatever the time, no tunnel tool is ever started for one of them.)
        XCTAssertEqual(Tunnels.shared.start(front, for: 1800), "These ports are made up, so nothing is shared.")
        XCTAssertNil(Tunnels.shared.active[3000])
        XCTAssertEqual(m.shareOnNetwork(front, lasting: 99), "On the network for 30 minutes, an hour, or until you turn it off.")
        XCTAssertNil(m.lanShares[front.id])
    }
}

final class CLITests: XCTestCase {
    private let app = "/Applications/harbor.app/Contents/MacOS/Harbor", link = "/usr/local/bin/harbor"

    func testACommandIsToldFromAnAppLaunch() {
        // The app's own binary: nothing, its own flags and the debug ones start the app as ever.
        for args in [[], ["--launchd"], ["--refresh-agents"], ["--door"], ["--serve", "--no-open"], ["--dump"], ["-psn_0_12345"], ["--frobnicate"]] {
            XCTAssertNil(CLI.parse([app] + args), args.joined(separator: " "))
        }
        XCTAssertNil(CLI.parse([".build/release/Harbor", "--make-icon", "x"]))
        XCTAssertNil(CLI.parse([]))
        // Through the command's link nothing ever starts the app: nothing after it is help, and a flag it doesn't know is an error.
        XCTAssertEqual(CLI.parse([link]), .help)
        XCTAssertEqual(CLI.parse(["harbor"]), .help)
        for args in [["--launchd"], ["--serve", "--no-open"], ["--demo-menu"], ["--frobnicate"], ["-x"]] {
            guard case .usage = CLI.parse([link] + args) else { return XCTFail(args.joined(separator: " ")) }
        }
        // What a start is, decided in one place. The door is a start of the app's own binary; through the link "--door"
        // is one more flag the command line doesn't know.
        XCTAssertEqual(CLI.start([app, "--door"]), .door)
        XCTAssertEqual(CLI.start([app, "--door", "--door-port", "39399"]), .door)
        XCTAssertEqual(CLI.start([app]), .app)
        XCTAssertEqual(CLI.start([app, "--launchd"]), .app)
        XCTAssertEqual(CLI.start([app, "ls"]), .command(.ls(json: false, all: false)))
        for through in [link, "harbor", "./harbor"] {
            guard case .command(.usage) = CLI.start([through, "--door", "--door-port", "39399"]) else { return XCTFail("\(through) --door") }
            guard case .command(.usage) = CLI.start([through, "--door"]) else { return XCTFail("\(through) --door") }
            XCTAssertEqual(CLI.run([through, "--door", "--door-port", "39399"]), 2)
        }
        // The name the command tells the app's binary by is the one app.conf builds it under.
        let conf = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("app.conf"), encoding: .utf8)
        XCTAssertEqual(conf?.components(separatedBy: "\n").first { $0.hasPrefix("EXECUTABLE=") }, "EXECUTABLE=\"\(CLI.executable)\"")
        // A word is a command however harbor was started, known or not.
        for invoked in [app, link, "harbor", "./Harbor"] {
            XCTAssertEqual(CLI.parse([invoked, "ls"]), .ls(json: false, all: false))
            XCTAssertEqual(CLI.parse([invoked, "ls", "--json", "-a"]), .ls(json: true, all: true))
            XCTAssertEqual(CLI.parse([invoked, "kill", "3000"]), .kill(port: 3000, yes: false, force: false, pid: nil))
            XCTAssertEqual(CLI.parse([invoked, "kill", "-y", "3000", "--force"]), .kill(port: 3000, yes: true, force: true, pid: nil))
            XCTAssertEqual(CLI.parse([invoked, "kill", "3000", "--pid", "4101"]), .kill(port: 3000, yes: false, force: false, pid: 4101))
            XCTAssertEqual(CLI.parse([invoked, "kill", "--pid", "3000", "3000", "--yes"]), .kill(port: 3000, yes: true, force: false, pid: 3000))
            XCTAssertEqual(CLI.parse([invoked, "open", "storefront"]), .open("storefront"))
            XCTAssertEqual(CLI.parse([invoked, "open", "3000"]), .open("3000"))
            for help in ["--help", "-h", "help"] { XCTAssertEqual(CLI.parse([invoked, help]), .help) }
            for version in ["--version", "version"] { XCTAssertEqual(CLI.parse([invoked, version]), .version) }
            for bad in [["frobnicate"], ["LS"], ["ls", "extra"], ["ls", "--bogus"], ["kill"], ["kill", "abc"], ["kill", "0"], ["kill", "70000"], ["kill", "3000", "3001"],
                        ["kill", "3000", "--now"], ["kill", "3000", "--pid"], ["kill", "3000", "--pid", "1"], ["kill", "3000", "--pid", "x"], ["open"], ["open", "a", "b"], ["open", "--x"], ["stop", "3000"]] {
                guard case .usage = CLI.parse([invoked] + bad) else { return XCTFail("\(invoked) \(bad.joined(separator: " "))") }
            }
        }
        // Scripts can rely on these.
        XCTAssertEqual([CLI.Exit.ok, .failed, .usage, .nothing, .refused, .cancelled, .changed].map(\.rawValue), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(CLI.run([link, "frobnicate"]), 2)
        XCTAssertEqual(CLI.run([link, "--serve"]), 2)
        XCTAssertNil(CLI.run([app]))
        XCTAssertNil(CLI.run([app, "--launchd"]))
    }

    func testWhatTheCommandLineWontStop() {
        let me = getuid()
        XCTAssertNil(CLI.refusal(row(3000), owner: me))
        // The app's own rules…
        XCTAssertNotNil(CLI.refusal(row(3000, pid: 1), owner: me))
        XCTAssertNotNil(CLI.refusal(row(3000, pid: 0), owner: me))
        XCTAssertEqual(CLI.refusal(row(5000, "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", system: true), owner: me), "ControlCenter is part of macOS, so harbor leaves it alone.")
        XCTAssertEqual(CLI.refusal(row(3000, path: nil), owner: me), "node is part of macOS, so harbor leaves it alone.")   // nothing known about it: left alone
        XCTAssertEqual(CLI.refusal(dockers(8080).inContainer(container("web")), owner: me), Docker.noKill(nil))
        // …harbor itself, in any form…
        XCTAssertEqual(CLI.refusal(row(8470, "Harbor", path: "/Applications/harbor.app/Contents/MacOS/Harbor"), owner: me), "That is harbor itself. Quit it from its menu.")
        XCTAssertNotNil(CLI.refusal(row(3000, isSelf: true), owner: me))
        // …and anything that isn't this user's: there is no administrator path from here.
        XCTAssertEqual(CLI.refusal(row(3000), owner: 0), "node runs as another user. The command line has no administrator path; use the app.")
        XCTAssertNotNil(CLI.refusal(row(3000), owner: me &+ 1))
        XCTAssertNotNil(CLI.refusal(row(3000), owner: nil))
        // A process's name is its own to choose: what is printed about it can't move the cursor or recolour the screen.
        let loud = "no\u{1B}[2J\u{7}de\nx"
        for said in [CLI.refusal(row(3000, loud), owner: 0), CLI.refusal(row(5000, loud, path: "/usr/sbin/cupsd", system: true), owner: me), CLI.refusal(row(3000, loud, path: nil), owner: me)] {
            XCTAssertEqual(said?.hasPrefix("no [2J de x "), true, said ?? "nil")
            XCTAssertFalse(said?.contains("\u{1B}") ?? true)
            XCTAssertFalse(said?.contains("\n") ?? true)
        }
        // What it asks first.
        let home = NSHomeDirectory()
        XCTAssertEqual(CLI.question(row(3000, folder: home + "/code/storefront")), "Stop node (pid 4101) on :3000, in ~/code/storefront? [y/N] ")
        XCTAssertEqual(CLI.question(row(3000, folder: nil, workers: [4102, 4103])), "Stop node (pid 4101) and its 2 workers on :3000? [y/N] ")
        XCTAssertFalse(CLI.question(row(3000, "no\u{1B}[2Jde", folder: home + "/a\nb")).contains("\u{1B}"))
    }

    func testStoppingFromTheCommandLine() {
        var sent: [(Int32, pid_t)] = [], there = true, dies = Set<Int32>([SIGTERM]), identities: [pid_t: String] = [4101: "t1", 4102: "w2", 4103: "w3"], alive = Set<pid_t>([4101, 4102, 4103])
        var answer = ProcessControl.SignalResult.sent
        func stop(force: Bool = false, workers: [(pid: pid_t, identity: String)] = []) -> (exit: CLI.Exit, said: String) {
            sent = []
            alive = [4101, 4102, 4103]
            return CLI.stop(label: "node on :3000", name: "node", pid: 4101, identity: "t1", workers: workers, force: force, CLI.Hands(
                isStillThere: { there }, identity: { identities[$0] ?? "" },
                send: { signal, pid in sent.append((signal, pid)); if dies.contains(signal), answer == .sent { alive.remove(pid) }; return answer },
                gone: { pid, _ in !alive.contains(pid) }, alive: { alive.contains($0) }))
        }
        // The polite stop, and only that; then the workers that shared its socket.
        var done = stop()
        XCTAssertEqual(done.exit, .ok)
        XCTAssertEqual(done.said, "Stopped node on :3000.")
        XCTAssertEqual(sent.map(\.0), [SIGTERM])
        done = stop(workers: [(4102, "w2"), (4103, "someone else now"), (4999, "gone")])
        XCTAssertEqual(sent.map(\.1), [4101, 4102], "a worker that is another process by now is left alone")
        XCTAssertEqual(sent.map(\.0), [SIGTERM, SIGTERM])
        // It changed while the question stood (the pid was given out again, or it no longer has the port): nothing is sent at all.
        there = false
        done = stop(force: true)
        XCTAssertEqual(done.exit, .changed)
        XCTAssertTrue(sent.isEmpty)
        there = true
        // It ignores the polite stop. Without --force it is left running, and that is said; with it, the hard one comes after the wait.
        dies = [SIGKILL]
        done = stop()
        XCTAssertEqual(done.exit, .failed)
        XCTAssertEqual(sent.map(\.0), [SIGTERM])
        XCTAssertTrue(done.said.contains("--force"))
        done = stop(force: true, workers: [(4102, "w2")])
        XCTAssertEqual(done.exit, .ok)
        XCTAssertEqual(done.said, "Force-stopped node on :3000.")
        XCTAssertEqual(sent.map(\.0), [SIGTERM, SIGKILL, SIGKILL])
        XCTAssertEqual(sent.map(\.1), [4101, 4101, 4102])
        // Between the two it became another process: the hard signal is never sent to that one.
        identities[4101] = "t9"
        done = stop(force: true)
        XCTAssertEqual(done.exit, .changed)
        XCTAssertEqual(sent.map(\.0), [SIGTERM])
        identities[4101] = "t1"
        // Nothing stops it.
        dies = []
        XCTAssertEqual(stop(force: true).exit, .failed)
        // Already gone, somebody else's, or the signal failed: said, with the code a script can read.
        dies = [SIGTERM]
        answer = .gone
        XCTAssertEqual(stop().exit, .ok)
        answer = .notPermitted
        done = stop(force: true)
        XCTAssertEqual(done.exit, .refused)
        XCTAssertEqual(sent.map(\.0), [SIGTERM], "no second try, and no administrator path")
        answer = .failed(EINVAL)
        XCTAssertEqual(stop().exit, .failed)
    }

    func testListingAndOpening() {
        let home = NSHomeDirectory()
        let front = row(3000, folder: home + "/code/storefront"), api = row(3001, pid: 4102, folder: home + "/code/storefront")
        let db = row(5432, "postgres", pid: 612, folder: nil, category: .database), low = row(631, "cupsd", pid: 99, folder: nil, category: .system, system: true)
        let web = dockers(8080).inContainer(container("shop-web-1", project: "shop", service: "web"))
        let rows = [web, db, api, low, front], names = Names.assign(rows).byRow
        var shared = Shared.Note(pid: 4242, identity: "t1.2", names: names, door: true, proxy: 8490)
        shared.network[front.id] = "http://storefront.local/"
        shared.links[front.id] = "https://quiet-harbor-demo.trycloudflare.com"
        let lines = CLI.lines(rows, names: names, shared: shared, all: false)
        XCTAssertEqual(lines.map(\.port), [3000, 3001, 5432, 8080], "by port, without what the app hides until asked")
        XCTAssertEqual(CLI.lines(rows, names: names, shared: shared, all: true).map(\.port), [631, 3000, 3001, 5432, 8080])
        XCTAssertEqual(lines[0], CLI.Line(port: 3000, name: "storefront.localhost", process: "node", pid: 4101, folder: home + "/code/storefront",
                                          network: "http://storefront.local/", link: "https://quiet-harbor-demo.trycloudflare.com", container: nil))
        XCTAssertEqual(lines[1].name, "storefront-3001.localhost")
        XCTAssertNil(lines[1].network)
        XCTAssertNil(lines[2].name)
        XCTAssertEqual(lines[3].process, "web")
        XCTAssertEqual(lines[3].container, "shop-web-1")
        let table = CLI.table(lines).components(separatedBy: "\n")
        XCTAssertEqual(table.count, 5)
        XCTAssertEqual(table[0].split(separator: " ").map(String.init), ["PORT", "NAME", "PROCESS", "PID", "FOLDER", "SHARED"])
        XCTAssertEqual(table[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init), ["3000", "storefront.localhost", "node", "4101", "~/code/storefront", "on", "network,", "public"])
        XCTAssertFalse(table.contains { $0.hasSuffix(" ") })
        XCTAssertEqual(CLI.table([]), "Nothing is listening.")
        let json = (try? JSONSerialization.jsonObject(with: Data(CLI.json(lines).utf8))) as? [[String: Any]]
        XCTAssertEqual(json?.count, 4)
        XCTAssertEqual(json?[0]["name"] as? String, "storefront.localhost")
        XCTAssertEqual(json?[0]["onNetwork"] as? Bool, true)
        XCTAssertEqual(json?[0]["public"] as? Bool, true)
        XCTAssertEqual(json?[0]["publicLink"] as? String, "https://quiet-harbor-demo.trycloudflare.com")
        XCTAssertEqual(json?[1]["onNetwork"] as? Bool, false)
        XCTAssertTrue(json?[2]["name"] is NSNull)
        XCTAssertEqual(json?[3]["container"] as? String, "shop-web-1")
        // open: a port, or a name with or without what surrounds it.
        for what in ["3000", "storefront", "storefront.localhost", "http://storefront.localhost/", "STOREFRONT"] { XCTAssertEqual(CLI.find(what, in: rows, names: names)?.id, front.id, what) }
        XCTAssertEqual(CLI.find("storefront-3001", in: rows, names: names)?.id, api.id)
        XCTAssertEqual(CLI.find("web", in: rows, names: names)?.id, web.id)
        for what in ["9999", "nothing", "", "store front", "../x", "storefront.local"] { XCTAssertNil(CLI.find(what, in: rows, names: names), what) }
        // As the running app would open it: the name, with the proxy's port while port 80 isn't harbor's. Without the
        // app nothing answers for a name: the plain address, which always works. And a row with no name has only that.
        XCTAssertEqual(CLI.address(front, names: names, shared: shared).absoluteString, "http://storefront.localhost/")
        shared.door = false
        XCTAssertEqual(CLI.address(front, names: names, shared: shared).absoluteString, "http://storefront.localhost:8490/")
        XCTAssertEqual(CLI.address(db, names: names, shared: shared).absoluteString, "http://localhost:5432")
        XCTAssertEqual(CLI.address(front, names: names, shared: Shared.Note()).absoluteString, "http://localhost:3000")
        // What goes to a terminal can't move the cursor.
        XCTAssertEqual(CLI.plain("a\u{1B}[2J\u{7}b\r\nc"), "a [2J b c")
    }

    func testTheNoteTheAppLeaves() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("n-\(Lan.token(4))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("shared")
        var note = Shared.Note(pid: 4242, identity: "t1.2", names: ["4101-3000": "storefront"], door: true, proxy: 8490,
                               network: ["4101-3000": "http://storefront.local/"], links: ["4101-3000": "https://x.trycloudflare.com"])
        XCTAssertTrue(note.isLive)
        XCTAssertFalse(Shared.Note().isLive)
        XCTAssertEqual(Shared.decode(Shared.encode(note)), note)
        // Believed only while the process that wrote it is still that process.
        try Shared.encode(note).write(to: file)
        XCTAssertEqual(Shared.read(file) { $0 == 4242 ? "t1.2" : "" }, note)
        XCTAssertEqual(Shared.read(file) { _ in "t9.9" }, Shared.Note(), "that pid is another process now")
        XCTAssertEqual(Shared.read(file) { _ in "" }, Shared.Note(), "nobody has that pid")
        // No note, a broken one, one with no writer: nothing is shared as far as anyone can say.
        XCTAssertEqual(Shared.read(folder.appendingPathComponent("none")) { _ in "t1.2" }, Shared.Note())
        XCTAssertEqual(Shared.read(nil) { _ in "t1.2" }, Shared.Note())
        try Data("{\"pid\":".utf8).write(to: file)
        XCTAssertEqual(Shared.read(file) { _ in "t1.2" }, Shared.Note())
        note.pid = 1
        try Shared.encode(note).write(to: file)
        XCTAssertEqual(Shared.read(file) { _ in "t1.2" }, Shared.Note())
        note = Shared.Note(pid: 4242, identity: "")
        try Shared.encode(note).write(to: file)
        XCTAssertEqual(Shared.read(file) { _ in "" }, Shared.Note())
        // A name in it is a label or the note isn't harbor's: nothing from the file is ever opened as anything else.
        note = Shared.Note(pid: 4242, identity: "t1.2", names: ["4101-3000": "evil.example/x?"], door: true, proxy: 80)
        try Shared.encode(note).write(to: file)
        XCTAssertEqual(Shared.read(file) { _ in "t1.2" }, Shared.Note())
    }

    func testTheCommandOnThePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(Lan.token(4))").path
        let first = root + "/usr-local-bin", home = root + "/home", second = home + "/.local/bin", target = root + "/harbor.app/Contents/MacOS/Harbor"
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        addTeardownBlock { chmod(first, 0o755); try? FileManager.default.removeItem(atPath: root) }
        let places = [first, second]
        func to(_ path: String) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: path) }
        XCTAssertNil(CommandLink.installed(in: places))
        // Into the first place that can be written to: a link to this app's own binary.
        var done = CommandLink.install(in: places, target: target, home: home)
        XCTAssertEqual(done.path, first + "/harbor")
        XCTAssertEqual(to(first + "/harbor"), target)
        XCTAssertEqual(CommandLink.installed(in: places), first + "/harbor")
        XCTAssertTrue(done.note.contains("harbor ls"))
        // Again (the app moved): its own link is replaced.
        done = CommandLink.install(in: places, target: root + "/elsewhere/harbor.app/Contents/MacOS/Harbor", home: home)
        XCTAssertEqual(to(first + "/harbor"), root + "/elsewhere/harbor.app/Contents/MacOS/Harbor")
        XCTAssertEqual(CommandLink.remove(from: places), "Removed \(Fmt.path(first + "/harbor")).")
        XCTAssertNil(to(first + "/harbor"))
        XCTAssertEqual(CommandLink.remove(from: places), "There was no harbor command to remove.")
        // The first can't be written to: the second, made if it isn't there, and the note says what to add to the PATH.
        chmod(first, 0o555)
        done = CommandLink.install(in: places, target: target, home: home)
        XCTAssertEqual(done.path, second + "/harbor")
        XCTAssertEqual(to(second + "/harbor"), target)
        XCTAssertTrue(done.note.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
        XCTAssertEqual(CommandLink.remove(from: places), "Removed \(Fmt.path(second + "/harbor")).")
        chmod(first, 0o755)
        // Something else called harbor is there already: left exactly as it is, and nothing is put anywhere else in its place.
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: URL(fileURLWithPath: first + "/harbor"))
        done = CommandLink.install(in: places, target: target, home: home)
        XCTAssertNil(done.path)
        XCTAssertTrue(done.note.contains("isn't mine"))
        XCTAssertEqual(try String(contentsOfFile: first + "/harbor", encoding: .utf8), "#!/bin/sh\necho mine\n")
        XCTAssertNil(to(second + "/harbor"))
        XCTAssertEqual(CommandLink.remove(from: places), "There was no harbor command to remove.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first + "/harbor"))
        try FileManager.default.removeItem(atPath: first + "/harbor")
        // Somebody else's link too.
        XCTAssertEqual(symlink("/usr/bin/true", first + "/harbor"), 0)
        XCTAssertNil(CommandLink.install(in: places, target: target, home: home).path)
        XCTAssertEqual(CommandLink.remove(from: places), "There was no harbor command to remove.")
        XCTAssertEqual(to(first + "/harbor"), "/usr/bin/true")
        try FileManager.default.removeItem(atPath: first + "/harbor")
        // A copy that isn't an app (a bare build) has nothing to link to; and nowhere to write is said.
        XCTAssertNil(CommandLink.install(in: places, target: root + "/.build/release/Harbor", home: home).path)
        XCTAssertNil(CommandLink.install(in: [root + "/missing"], target: target, home: home).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/missing"), "only ~/.local/bin is ever made")
    }

    // MARK: How often to scan

    /// Two hours or a day must be settable: seconds, or a number with s, m, h or d, up to a week.
    func testTheRefreshIntervalTakesHoursAndDays() {
        XCTAssertEqual(Monitor.parseInterval("90"), 90)
        XCTAssertEqual(Monitor.parseInterval("90s"), 90)
        XCTAssertEqual(Monitor.parseInterval("30m"), 1800)
        XCTAssertEqual(Monitor.parseInterval("2h"), 7200)
        XCTAssertEqual(Monitor.parseInterval(" 1.5 hours "), 5400)
        XCTAssertEqual(Monitor.parseInterval("1d"), 86_400)
        XCTAssertEqual(Monitor.parseInterval("2 days"), 172_800)
        for bad in ["", "abc", "0", "-5", "2x", "h", "1e9999", "nan", "5 minutes ago"] { XCTAssertNil(Monitor.parseInterval(bad), bad) }
        // Kept as asked, between 5 seconds and a week; 0 is manual.
        XCTAssertEqual(Monitor.clampInterval(7200), 7200)
        XCTAssertEqual(Monitor.clampInterval(86_400), 86_400)
        XCTAssertEqual(Monitor.clampInterval(2), 5)
        XCTAssertEqual(Monitor.clampInterval(10_000_000), 7 * 86_400)
        XCTAssertEqual(Monitor.clampInterval(0), 0)
        XCTAssertEqual(Monitor.clampInterval(.nan), 15)
        for preset in Monitor.presetIntervals { XCTAssertEqual(Monitor.clampInterval(preset), preset) }
        XCTAssertEqual(Monitor.intervalLabel(30), "30 seconds")
        XCTAssertEqual(Monitor.intervalLabel(60), "1 minute")
        XCTAssertEqual(Monitor.intervalLabel(7200), "2 hours")
        XCTAssertEqual(Monitor.intervalLabel(5400), "1 h 30 min")
        XCTAssertEqual(Monitor.intervalLabel(86_400), "1 day")
    }

    // MARK: The commands that go further

    private func more(_ args: String...) -> CLIApp.Call? {
        if case .more(let call)? = CLI.parse(["/usr/local/bin/harbor"] + args) { return call }
        return nil
    }

    func testTheFurtherCommandsAreRead() {
        XCTAssertEqual(more("scan"), .scan(range: 1...65535, all: false, json: false))
        XCTAssertEqual(more("scan", "3000-3999", "--json"), .scan(range: 3000...3999, all: false, json: true))
        XCTAssertEqual(more("scan", "8080"), .scan(range: 8080...8080, all: false, json: false))
        XCTAssertNil(more("scan", "9000-8000"))                                           // not a range
        XCTAssertEqual(more("check", "3000"), .check("3000"))
        XCTAssertEqual(more("watch", "--every", "2"), .watch(every: 2))
        XCTAssertNil(more("watch", "--every", "0"))
        // Sharing: the word, then how long, then where the password comes from. Never from an argument.
        XCTAssertEqual(more("share", "storefront"), .share(target: "storefront", seconds: nil, password: .prompt))
        XCTAssertEqual(more("share", "3000", "--minutes", "30", "--random"), .share(target: "3000", seconds: 1800, password: .random))
        XCTAssertEqual(more("share", "3000", "--until-stopped", "--open"), .share(target: "3000", seconds: 0, password: .none))
        XCTAssertEqual(more("share", "3000", "--password-stdin"), .share(target: "3000", seconds: nil, password: .stdin))
        XCTAssertNil(more("share", "3000", "--minutes", "45"))                             // the app offers 30, 60 or until stopped
        XCTAssertNil(more("share", "3000", "--random", "--open"))                          // one way only
        XCTAssertNil(more("share", "3000", "--password", "hunter22"))                      // there is no such flag
        XCTAssertEqual(more("unshare", "3000"), .unshare("3000"))
        XCTAssertEqual(more("extend", "3000"), .extend(target: "3000", times: 1, publicLink: false))
        XCTAssertEqual(more("extend", "3000", "2h", "--public"), .extend(target: "3000", times: 4, publicLink: true))
        XCTAssertNil(more("extend", "3000", "20m"))                                        // half hours
        XCTAssertEqual(more("password", "3000", "--remove"), .password(target: "3000", .none))
        XCTAssertEqual(more("password", "3000"), .password(target: "3000", .prompt))
        XCTAssertEqual(more("tunnel", "3000", "--minutes", "60"), .tunnel(target: "3000", seconds: 3600))
        XCTAssertEqual(more("tunnel", "stop", "3000"), .untunnel("3000"))
        XCTAssertEqual(more("tunnels"), .tunnels)
        XCTAssertEqual(more("start", "tips", "-y"), .start("tips", yes: true))
        XCTAssertEqual(more("rename", "3000", "grading", "api"), .rename(target: "3000", name: "grading api"))
        XCTAssertEqual(more("rename", "3000", "--reset"), .rename(target: "3000", name: nil))
        XCTAssertEqual(more("group", "3000", "Exams"), .group(target: "3000", title: "Exams"))
        XCTAssertEqual(more("group", "3000", "--auto"), .group(target: "3000", title: nil))
        XCTAssertEqual(more("group", "rename", "Exams", "Grading"), .groupRename(title: "Exams", to: "Grading"))
        XCTAssertEqual(more("group", "delete", "Exams"), .groupDelete("Exams"))
        // A wrongly written one says how, and is a usage error, not the app's.
        guard case .usage(let text)? = CLI.parse(["/usr/local/bin/harbor", "share"]) else { return XCTFail("share needs a target") }
        XCTAssertTrue(text.hasPrefix("harbor share "))
        XCTAssertEqual(CLI.parse(["/usr/local/bin/harbor", "help", "more"]), .helpMore)
    }

    func testAWordNamesARow() {
        let ports: [[String: Any]] = [
            ["port": 3000, "pid": 10, "hostName": "datesheet-generator", "display": "exams-portal", "local": ["name": "ds"]],
            ["port": 3009, "pid": 11, "hostName": "web", "display": "web frontend"],
        ]
        func port(_ word: String) -> Int? { CLIApp.target(word, in: ports)?["port"] as? Int }
        XCTAssertEqual(port("3009"), 3009)
        XCTAssertEqual(port("web"), 3009)
        XCTAssertEqual(port("Web.localhost"), 3009)
        XCTAssertEqual(port("datesheet-generator.localhost"), 3000)
        XCTAssertEqual(port("ds.local"), 3000)                                             // its name on the network
        XCTAssertEqual(port("exams-portal"), 3000)                                         // what the list calls it
        XCTAssertNil(port("nothing"))
        XCTAssertNil(port("9999"))
        XCTAssertEqual(CLIApp.lasts(["--minutes", "60"]), CLIApp.Asked(seconds: 3600))
        XCTAssertEqual(CLIApp.lasts(["--until-stopped"]), CLIApp.Asked(seconds: 0))
        XCTAssertEqual(CLIApp.lasts([]), CLIApp.Asked(seconds: nil))
        XCTAssertNil(CLIApp.lasts(["--minutes", "61"]))
        XCTAssertEqual(CLIApp.table([["A", "BB"], ["ccc", "d"]]), "A    BB\nccc  d")
    }
}
