import XCTest
@testable import Harbor

/// Names (`<project>.localhost`): who gets which name, what a rename may be,
/// where a Host goes, how a request head is rewritten, and what the port-80
/// door does with a request. All pure functions; nothing here listens.
final class NamesTests: XCTestCase {
    /// A listening port. `folder` nil makes it an app's (`app`), not a project's.
    private func row(_ port: UInt16, folder: String? = "/Users/me/code/storefront", app: String? = nil, pid: pid_t? = nil,
                     category: PortCategory = .dev, started: TimeInterval = 0, scope: AddressScope = .loopback,
                     addresses: [String] = ["127.0.0.1"], system: Bool = false, isSelf: Bool = false, path: String? = nil) -> PortRow {
        PortRow(port: port, addresses: addresses, scope: scope, pid: pid ?? pid_t(port), ppid: 1,
                processName: app ?? "node", path: path, cwd: folder, projectRoot: folder, command: nil,
                started: Date(timeIntervalSince1970: started), footprint: nil, workers: 0, workerPids: [],
                isSystem: system, appBundle: app.map { "/Applications/\($0).app" }, appName: app, framework: nil,
                category: category, isSelf: isSelf)
    }

    /// A site in `web/` and its API at the repo's root are one card, but still two projects for
    /// everything saved by folder: names, passwords and network names don't move.
    func testASiteAndItsApiShareACardNotAKey() {
        var web = row(3737, folder: "/Users/me/code/tips/web")
        web.repo = "/Users/me/code/tips"
        let api = row(7878, folder: "/Users/me/code/tips")
        XCTAssertEqual(web.groupKey, api.groupKey)
        XCTAssertEqual(web.groupTitle, "tips")
        XCTAssertEqual(api.groupTitle, "tips")
        XCTAssertNotEqual(Names.key(web), Names.key(api))
        XCTAssertEqual(Names.key(web), "/Users/me/code/tips/web")
        // A saved rename for the folder still finds its server.
        let table = Names.assign([web, api], saved: ["/Users/me/code/tips/web": "site"])
        XCTAssertEqual(table.byRow[web.id], "site")
        XCTAssertEqual(table.byRow[api.id], "tips")
        // Without a repo above it, a folder is its own card.
        XCTAssertNotEqual(row(3000, folder: "/Users/me/code/shop/web").groupKey, row(4000, folder: "/Users/me/code/shop").groupKey)
    }

    /// A list says what a server is, not "node": a runtime goes by its folder; a program with a name keeps it.
    func testARuntimeGoesByItsFolder() {
        let home = NSHomeDirectory()
        XCTAssertEqual(row(3000, folder: home + "/code/shop/exams-portal").display, "exams-portal")
        XCTAssertEqual(row(8080, folder: home + "/code/shop", app: nil).display, "shop")
        let python = PortRow(port: 8012, addresses: ["127.0.0.1"], scope: .loopback, pid: 8012, ppid: 1, processName: "Python", path: nil,
                             cwd: home + "/code/eticket", projectRoot: home + "/code/eticket", command: nil, started: nil, footprint: nil,
                             workers: 0, workerPids: [], isSystem: false, appBundle: nil, appName: nil, framework: nil, category: .dev, isSelf: false)
        XCTAssertEqual(python.display, "eticket")
        var named = row(7878, folder: home + "/code/tips")
        named = PortRow(port: 7878, addresses: ["127.0.0.1"], scope: .loopback, pid: 7878, ppid: 1, processName: "tips-server", path: nil,
                        cwd: home + "/code/tips", projectRoot: home + "/code/tips", command: nil, started: nil, footprint: nil,
                        workers: 0, workerPids: [], isSystem: false, appBundle: nil, appName: nil, framework: nil, category: .dev, isSelf: false)
        XCTAssertEqual(named.display, "tips-server")
        // No folder to name it by: the process, as before.
        let none = PortRow(port: 9000, addresses: ["127.0.0.1"], scope: .loopback, pid: 9, ppid: 1, processName: "node", path: nil,
                           cwd: nil, projectRoot: nil, command: nil, started: nil, footprint: nil, workers: 0, workerPids: [],
                           isSystem: false, appBundle: nil, appName: nil, framework: nil, category: .dev, isSelf: false)
        XCTAssertEqual(none.display, "node")
        // A site and its API in one folder: the framework says which is which.
        func run(_ process: String, _ framework: String?) -> PortRow {
            PortRow(port: 3001, addresses: ["127.0.0.1"], scope: .loopback, pid: 1, ppid: 1, processName: process, path: nil,
                    cwd: home + "/code/cbm", projectRoot: home + "/code/cbm", command: nil, started: nil, footprint: nil, workers: 0,
                    workerPids: [], isSystem: false, appBundle: nil, appName: nil, framework: framework, category: .dev, isSelf: false)
        }
        XCTAssertEqual(run("node", "Vite").display, "cbm frontend")
        // A server framework is "backend" only once "/" has been seen to answer without a page...
        XCTAssertEqual(run("Python", "Uvicorn").display(served: "404"), "cbm backend")
        XCTAssertEqual(run("Python", "Flask").display(served: "200"), "cbm backend")
        // ...a title or a redirect means it renders its own pages (Jinja, Django templates): no word.
        XCTAssertEqual(run("Python", "Flask").display(served: "200 · Storefront"), "cbm")
        XCTAssertEqual(run("Python", "Django").display(served: "302 → /login"), "cbm")
        // Not asked yet, or not answering: no guess.
        XCTAssertEqual(run("Python", "Uvicorn").display, "cbm")
        XCTAssertEqual(run("Python", "Flask").display(served: "not answering"), "cbm")
        XCTAssertEqual(run("node", "Node.js").display, "cbm")                      // could be either: no guess
        XCTAssertEqual(run("tips-server", "Flask").display, "tips-server")         // its own name wins
    }

    /// The two page filters read these: a project is anything with a project folder found for it,
    /// and reachable is any listener that isn't loopback-only.
    func testOtherAppsAndReachablePorts() {
        let project = row(3000)
        let app = PortRow(port: 11434, addresses: ["127.0.0.1"], scope: .loopback, pid: 5, ppid: 1, processName: "ollama", path: nil,
                          cwd: nil, projectRoot: nil, command: nil, started: nil, footprint: nil, workers: 0, workerPids: [],
                          isSystem: false, appBundle: nil, appName: "Ollama", framework: nil, category: .other, isSelf: false)
        XCTAssertFalse(project.isOtherApp)
        XCTAssertTrue(app.isOtherApp)
        XCTAssertFalse(project.isReachable)                                       // loopback only
        XCTAssertTrue(row(3000, scope: .all, addresses: ["0.0.0.0"]).isReachable)
        XCTAssertTrue(row(3000, scope: .specific, addresses: ["172.17.134.35"]).isReachable)
    }

    /// Groups and names made by hand sit over the automatic ones, and never change a key.
    func testWhatWasChosenSitsOverTheAutomatic() {
        var r = row(3000, folder: NSHomeDirectory() + "/code/shop")
        let auto = r.groupKey
        XCTAssertEqual(r.autoGroupKey, auto)
        r.chosen.cardTitle = "My shop"                                   // an automatic card, renamed
        XCTAssertEqual(r.groupKey, auto)
        XCTAssertEqual(r.groupTitle, "My shop")
        XCTAssertEqual(r.autoGroupTitle, "shop")
        r.chosen.group = "ab12cd34"                                      // a group of its own
        r.chosen.groupTitle = "Exams"
        XCTAssertEqual(r.groupKey, "c:ab12cd34")
        XCTAssertEqual(r.groupTitle, "Exams")
        XCTAssertEqual(r.autoGroupKey, auto)                             // what a rename of the card is saved under
        r.chosen.rowName = "storefront admin"
        XCTAssertEqual(r.display(served: nil), "storefront admin")
        XCTAssertEqual(Names.key(r), NSHomeDirectory() + "/code/shop")  // names and saved things are by folder, as ever
        // A made-up Route for a stopped server is its own case.
        XCTAssertNotEqual(Names.Route.stopped(name: "shop", id: "a1"), Names.Route.unknown("shop"))
        // And the page for it holds a link that asks first, in harbor's own page.
        let page = String(decoding: Proxy.page(404, "shop isn't running.", action: ("Start it again…", "http://harbor.localhost:8470/?start=a1")), as: UTF8.self)
        XCTAssertTrue(page.contains("<a href=\"http://harbor.localhost:8470/?start=a1\">Start it again…</a>"))
    }

    // MARK: Slugs

    func testSlug() {
        XCTAssertEqual(Names.slug("storefront"), "storefront")
        XCTAssertEqual(Names.slug("My Shop_v2"), "my-shop-v2")
        XCTAssertEqual(Names.slug("--Weird!!  name--"), "weird-name")        // runs collapse, ends are trimmed
        XCTAssertEqual(Names.slug("Café Olé"), "cafe-ole")
        XCTAssertEqual(Names.slug("日本語"), "")                               // nothing usable: the caller falls back
        let long = Names.slug(String(repeating: "a", count: 39) + "-bcdef")
        XCTAssertEqual(long, String(repeating: "a", count: 39))               // cut at 40, never ending in a hyphen
        XCTAssertTrue(Names.isLabel(long, max: Names.maxLength))
    }

    // MARK: Who gets which name

    func testProjectGetsItsFoldersName() {
        let r = row(3000)
        let t = Names.assign([r])
        XCTAssertEqual(t.byRow[r.id], "storefront")
        XCTAssertEqual(t.targets["storefront"], Names.Target(port: 3000, addresses: ["127.0.0.1"]))
        XCTAssertEqual(t.base["/Users/me/code/storefront"], "storefront")
    }

    func testAppWithoutAFolderUsesItsOwnName() {
        let ollama = row(11434, folder: nil, app: "Ollama", category: .appHelper)
        XCTAssertEqual(Names.assign([ollama]).byRow[ollama.id], "ollama")
    }

    func testSeveralPortsMainFirstThenNamePort() {
        // The dev server keeps the name even though the other process has the lower port.
        let tool = row(2000, category: .runtime), web = row(3000), hmr = row(3001)
        let t = Names.assign([tool, web, hmr])
        XCTAssertEqual(t.byRow[web.id], "storefront")
        XCTAssertEqual(t.byRow[hmr.id], "storefront-3001")
        XCTAssertEqual(t.byRow[tool.id], "storefront-2000")
        XCTAssertEqual(t.targets["storefront-2000"]?.port, 2000)
        // No dev server among them: the lowest port.
        let a = row(5433, category: .other), b = row(5432, category: .other)
        XCTAssertEqual(Names.assign([a, b]).byRow[b.id], "storefront")
    }

    func testNoNameForWhatIsntAWebPage() {
        // A database in the project's folder, and ports a browser refuses to open (X11, IRC, SIP…).
        let web = row(3000), db = row(5432, category: .database), x11 = row(6000), irc = row(6667), sip = row(5060)
        let redis = row(6379, folder: nil, app: "Redis", category: .database)
        let t = Names.assign([web, db, x11, irc, sip, redis])
        XCTAssertEqual(t.byRow, [web.id: "storefront"])                        // only the dev server
        XCTAssertEqual(Array(t.targets.keys), ["storefront"])
        // A project that is only a database has no name at all, and nothing answers as one.
        XCTAssertTrue(Names.assign([db]).targets.isEmpty)
        XCTAssertEqual(Names.route(host: "storefront-5432.localhost", in: t), .unknown("storefront-5432"))
        // And a table that somehow named a bad port is not followed either.
        var odd = Names.Table()
        odd.targets["chat"] = Names.Target(port: 6667, addresses: ["127.0.0.1"])
        XCTAssertEqual(Names.route(host: "chat.localhost", in: odd), .refuse)
    }

    func testHarborsOwnProcessesGetNoName() {
        // The door, or a second copy of harbor: not this process, but harbor all the same.
        let door = row(8080, folder: nil, app: "harbor", category: .appHelper, path: "/Applications/harbor.app/Contents/MacOS/Harbor")
        let copy = row(8471, folder: "/Users/me/GitHub/harbor", path: "/Users/me/GitHub/harbor/build/harbor.app/Contents/MacOS/Harbor")
        let web = row(3000)
        XCTAssertEqual(Names.assign([door, copy, web]).byRow, [web.id: "storefront"])
        XCTAssertTrue(Names.isHarbor(Bundle.main.executablePath))
        XCTAssertFalse(Names.isHarbor("/usr/local/bin/node"))
        XCTAssertFalse(Names.isHarbor(nil))
    }

    func testSameFolderNameDoesNotCollide() {
        let first = row(3000, folder: "/Users/me/shop/web", started: 100)
        let later = row(4000, folder: "/Users/me/blog/web", started: 200)
        let third = row(5000, folder: "/Volumes/x/blog/web", started: 300)
        for rows in [[first, later, third], [third, later, first]] {             // the order they are listed in doesn't matter
            let t = Names.assign(rows)
            XCTAssertEqual(t.byRow[first.id], "web")                             // started first: the plain name
            XCTAssertEqual(t.byRow[later.id], "blog-web")                        // then the parent folder in front
            XCTAssertEqual(t.byRow[third.id], "web-2")                           // then a number
            XCTAssertEqual(Set(t.targets.keys).count, 3)
        }
    }

    func testANameStaysWhileTheProjectRuns() {
        let first = row(3000, folder: "/Users/me/shop/web", started: 100)
        let later = row(4000, folder: "/Users/me/blog/web", started: 200)
        let both = Names.assign([first, later])
        // The first one stops: the later one keeps blog-web instead of jumping to web.
        let after = Names.assign([later], previous: both)
        XCTAssertEqual(after.byRow[later.id], "blog-web")
        // And a newcomer can't take a name that is in use.
        let newcomer = row(5000, folder: "/Users/me/x/blog-web", started: 50)
        XCTAssertEqual(Names.assign([later, newcomer], previous: after).byRow[later.id], "blog-web")
    }

    func testAnExtraPortsNameStaysToo() {
        // alpha has two ports; then a project whose folder is called alpha-39003 starts.
        let main = row(39001, folder: "/Users/me/alpha", started: 100), extra = row(39003, folder: "/Users/me/alpha", started: 100)
        let before = Names.assign([main, extra])
        XCTAssertEqual(before.byRow[extra.id], "alpha-39003")
        let later = row(4000, folder: "/Users/me/x/alpha-39003", started: 50)      // an earlier start doesn't help it
        let after = Names.assign([main, extra, later], previous: before)
        XCTAssertEqual(after.byRow[main.id], "alpha")
        XCTAssertEqual(after.byRow[extra.id], "alpha-39003")                        // the running server keeps its name
        XCTAssertEqual(after.targets["alpha-39003"]?.port, 39003)
        XCTAssertEqual(after.byRow[later.id], "x-alpha-39003")                      // the newcomer gets another
        // The main server stops: the extra one keeps its own name, and the project's name still opens it.
        let alone = Names.assign([extra, later], previous: after)
        XCTAssertEqual(alone.byRow[extra.id], "alpha-39003")
        XCTAssertEqual(alone.targets["alpha"]?.port, 39003)
        XCTAssertEqual(alone.targets["alpha-39003"]?.port, 39003)
        // It comes back on a new port: the name is its again; nothing else moves.
        let back = row(39005, folder: "/Users/me/alpha", started: 400)
        let again = Names.assign([extra, later, back], previous: alone)
        XCTAssertEqual(again.byRow[extra.id], "alpha-39003")
        XCTAssertEqual(again.byRow[later.id], "x-alpha-39003")
        XCTAssertEqual(again.byRow[back.id], "alpha-39005")
    }

    func testReservedNamesAndPortsNeverGetAName() {
        // A project folder that happens to be called harbor can't have harbor.localhost.
        let mine = row(3000, folder: "/Users/me/GitHub/harbor")
        XCTAssertEqual(Names.assign([mine]).byRow[mine.id], "github-harbor")
        let app = row(9000, folder: nil, app: "headroom", category: .appHelper)
        XCTAssertEqual(Names.assign([app]).byRow[app.id], "headroom-2")
        // harbor's page, headroom's page, the proxy, macOS services and harbor itself: no name at all.
        let never = Names.reservedPorts.map { row($0) } + [row(5000, system: true), row(7000, isSelf: true)]
        XCTAssertEqual(Names.reservedPorts.count, 3)
        let t = Names.assign(never)
        XCTAssertTrue(t.byRow.isEmpty)
        XCTAssertTrue(t.targets.isEmpty)
    }

    func testSavedRenameWins() {
        let shop = row(3000, folder: "/Users/me/shop/web", started: 100), blog = row(4000, folder: "/Users/me/blog/web", started: 200)
        let t = Names.assign([shop, blog], saved: ["/Users/me/blog/web": "web"])
        XCTAssertEqual(t.byRow[blog.id], "web")                                  // the saved name, though it started later
        XCTAssertEqual(t.byRow[shop.id], "shop-web")
        // A name saved for a project is kept for it while it isn't running.
        XCTAssertEqual(Names.assign([shop], saved: ["/Users/me/blog/web": "web"]).byRow[shop.id], "shop-web")
        // A saved name that isn't allowed is ignored.
        XCTAssertEqual(Names.assign([shop], saved: ["/Users/me/shop/web": "harbor"]).byRow[shop.id], "web")
        XCTAssertEqual(Names.assign([shop], saved: ["/Users/me/shop/web": "Not A Name"]).byRow[shop.id], "web")
    }

    // MARK: Rename validation

    func testRenameValidation() {
        let shop = row(3000, folder: "/Users/me/shop"), api = row(4000, folder: "/Users/me/api"), extra = row(4001, folder: "/Users/me/api")
        let saved = ["/Users/me/old": "kept"]
        let t = Names.assign([shop, api, extra], saved: saved)
        func problem(_ name: String) -> String? { Names.problem(with: name, for: "/Users/me/shop", in: t, saved: saved) }
        XCTAssertNil(problem("store"))
        XCTAssertNil(problem("a"))
        XCTAssertNil(problem("shop"))                                            // its own name
        XCTAssertNil(problem(String(repeating: "a", count: 40)))
        for bad in ["", String(repeating: "a", count: 41), "Shop", "my shop", "my_shop", "shop.dev", "-shop", "shop-", "sh/op", "café", "a\nb"] {
            XCTAssertNotNil(problem(bad), bad)
        }
        XCTAssertNotNil(problem("harbor"))                                       // reserved
        XCTAssertNotNil(problem("headroom"))
        XCTAssertNotNil(problem("api"))                                          // another running project's
        XCTAssertNotNil(problem("api-4001"))                                     // and its other port's
        XCTAssertNotNil(problem("kept"))                                         // saved for a project that isn't running
    }

    // MARK: Host → target

    func testRouteByHost() {
        let t = Names.assign([row(3000), row(3001)])
        let web = Names.Route.forward(Names.Target(port: 3000, addresses: ["127.0.0.1"]))
        XCTAssertEqual(Names.route(host: "storefront.localhost", in: t), web)
        XCTAssertEqual(Names.route(host: "Storefront.LOCALHOST:8490", in: t), web)   // case, and a port
        XCTAssertEqual(Names.route(host: "storefront.localhost.", in: t), web)       // a trailing dot
        XCTAssertEqual(Names.route(host: "storefront-3001.localhost", in: t), .forward(Names.Target(port: 3001, addresses: ["127.0.0.1"])))
        XCTAssertEqual(Names.route(host: "nothing.localhost", in: t), .unknown("nothing"))
    }

    func testOnlyLocalhostNamesAreRouted() {
        let t = Names.assign([row(3000)])
        // DNS rebinding: another site's name pointed at this Mac still sends its own Host.
        for host in ["evil.com", "evil.com:8490", "storefront.localhost.evil.com", "storefront", "localhost", "localhost:3000",
                     "127.0.0.1:8490", "[::1]:8490", "127.0.0.1", ".localhost", "a.b.localhost", "<script>.localhost", "", "   "] {
            XCTAssertEqual(Names.route(host: host, in: t), .refuse, host)
        }
        XCTAssertEqual(Names.route(host: nil, in: t), .refuse)
        // A name that is only as long as a real one plus ".localhost" is not one.
        for host in ["storefront0123456789", "storefrontxlocalhost", "storefront.localhosx", "storefront.localhost0", "storefront-localhost"] {
            XCTAssertEqual(Names.route(host: host, in: t), .refuse, host)
        }
        // The apps' own names are the door's to redirect, never the proxy's.
        XCTAssertEqual(Names.route(host: "harbor.localhost", in: t), .refuse)
        XCTAssertEqual(Names.route(host: "headroom.localhost:8490", in: t), .refuse)
    }

    func testReservedPortsAreNeverATarget() {
        // Even a table that somehow named one of them (it can't: see assign) is not followed.
        for port in Names.reservedPorts {
            var t = Names.Table()
            t.targets["sneaky"] = Names.Target(port: port, addresses: ["127.0.0.1"])
            XCTAssertEqual(Names.route(host: "sneaky.localhost", in: t), .refuse, "\(port)")
        }
    }

    func testTargetAddresses() {
        let all = row(3000, scope: .all, addresses: ["all interfaces"])
        XCTAssertEqual(Names.assign([all]).targets["storefront"]?.addresses, ["127.0.0.1", "::1"])
        let v6 = row(5173, addresses: ["::1"])                                   // Vite on "localhost" listens on ::1 only
        XCTAssertEqual(Names.assign([v6]).targets["storefront"]?.addresses, ["::1"])
    }

    // MARK: Request head

    private func head(_ lines: [String]) -> Data { Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) }

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
    }

    func testForwardedHeadForAPlainRequest() throws {
        let request = try XCTUnwrap(ProxyHead(head([
            "GET /cart?x=1 HTTP/1.1", "Host: Storefront.localhost.", "User-Agent: test", "Connection: keep-alive", "Keep-Alive: timeout=5",
            "Cookie: a=b", "Origin: http://storefront.localhost", "Upgrade: h2c",
            // What a client might send to speak for the proxy:
            "X-Forwarded-For: 6.6.6.6", "X-Forwarded-Host: evil.com", "X-Forwarded-Proto: https", "Forwarded: for=6.6.6.6;host=evil.com",
            "X-Real-IP: 6.6.6.6", "X-Forwarded-Port: 443", "X-Forwarded-Scheme: https", "X-Original-URL: /admin", "X-Rewrite-URL: /admin",
        ])))
        XCTAssertFalse(request.isWebSocket)
        let out = lines(request.forwarded(client: "127.0.0.1"))
        XCTAssertEqual(out[0], "GET /cart?x=1 HTTP/1.1")
        // The Host stays the name the browser asked for, in its plain form: the app sees its real origin.
        XCTAssertEqual(out[1], "Host: storefront.localhost")
        XCTAssertEqual(out.filter { $0.lowercased().hasPrefix("host:") }.count, 1)
        XCTAssertTrue(out.contains("Origin: http://storefront.localhost"))        // and so does the Origin
        XCTAssertTrue(out.contains("Connection: close"))
        XCTAssertEqual(out.filter { $0.lowercased().hasPrefix("connection:") }.count, 1)
        XCTAssertFalse(out.contains { $0.lowercased().hasPrefix("keep-alive:") || $0.lowercased().hasPrefix("upgrade:") })
        // What the client claimed is gone; only what the proxy knows is there.
        XCTAssertEqual(out.filter { $0.lowercased().hasPrefix("x-") || $0.lowercased().hasPrefix("forwarded") }.sorted(),
                       ["X-Forwarded-For: 127.0.0.1", "X-Forwarded-Host: storefront.localhost", "X-Forwarded-Proto: http"])
        XCTAssertFalse(out.joined().contains("6.6.6.6") || out.joined().contains("evil.com") || out.joined().contains("/admin"))
        // Everything else goes through as it came, and the head still ends with a blank line.
        XCTAssertTrue(out.contains("User-Agent: test"))
        XCTAssertTrue(out.contains("Cookie: a=b"))
        XCTAssertEqual(Array(out.suffix(2)), ["", ""])
    }

    func testForwardedHeadKeepsAWebSocketUpgrade() throws {
        let request = try XCTUnwrap(ProxyHead(head([
            "GET /hmr HTTP/1.1", "Host: storefront.localhost:8490", "Connection: keep-alive, Upgrade", "Upgrade: WebSocket",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13", "Origin: http://storefront.localhost:8490",
        ])))
        XCTAssertTrue(request.isWebSocket)
        let out = lines(request.forwarded(client: "::1"))
        XCTAssertTrue(out.contains("Connection: Upgrade"))
        XCTAssertFalse(out.contains("Connection: close"))
        XCTAssertTrue(out.contains("Upgrade: WebSocket"))
        XCTAssertTrue(out.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="))
        XCTAssertTrue(out.contains("Host: storefront.localhost:8490"))            // the port it was asked on stays
        XCTAssertTrue(out.contains("X-Forwarded-Host: storefront.localhost:8490"))
        XCTAssertTrue(out.contains("X-Forwarded-For: ::1"))
        XCTAssertTrue(out.contains("Origin: http://storefront.localhost:8490"))   // Host, Origin and X-Forwarded-Host agree
    }

    func testUpgradeDetection() {
        func ws(_ extra: [String]) -> Bool { ProxyHead(head(["GET / HTTP/1.1", "Host: a.localhost"] + extra))?.isWebSocket ?? false }
        XCTAssertTrue(ws(["Connection: Upgrade", "Upgrade: websocket"]))
        XCTAssertTrue(ws(["connection: upgrade", "upgrade: WEBSOCKET"]))
        XCTAssertFalse(ws(["Upgrade: websocket"]))                                // no Connection: upgrade
        XCTAssertFalse(ws(["Connection: Upgrade"]))                               // no Upgrade
        XCTAssertFalse(ws(["Connection: Upgrade", "Upgrade: h2c"]))               // not a WebSocket
        XCTAssertFalse(ws(["Connection: keep-alive"]))
    }

    func testAnotherSitesOriginIsPassedOnUntouched() throws {
        for origin in ["http://evil.com", "http://other.localhost", "https://storefront.localhost", "null"] {
            let request = try XCTUnwrap(ProxyHead(head(["POST /api HTTP/1.1", "Host: storefront.localhost", "Origin: \(origin)", "Content-Length: 2"])))
            XCTAssertTrue(lines(request.forwarded(client: "127.0.0.1")).contains("Origin: \(origin)"), origin)
        }
    }

    func testHeadParserRefusesWhatItCantPassOnSafely() {
        XCTAssertNotNil(ProxyHead(head(["GET / HTTP/1.1", "Host: a.localhost"])))
        XCTAssertNotNil(ProxyHead(head(["POST /x HTTP/1.0", "Host: a.localhost", "Transfer-Encoding: chunked"])))   // bodies are only copied
        for bad in [
            ["GET / HTTP/1.1"],                                                    // no Host
            ["GET / HTTP/1.1", "Host: a.localhost", "Host: evil.com"],             // two Hosts
            ["GET / HTTP/1.1", "Host: a.localhost", "host: evil.com"],
            ["GET http://evil.com/ HTTP/1.1", "Host: a.localhost"],                // an absolute URL names its own host
            ["CONNECT evil.com:443 HTTP/1.1", "Host: a.localhost"],
            ["GET / HTTP/2.0", "Host: a.localhost"],
            ["GET /", "Host: a.localhost"],
            ["GET / HTTP/1.1", "Host : a.localhost"],                              // a space before the colon
            ["GET / HTTP/1.1", "Host: a.localhost", " folded: line"],
            ["GET / HTTP/1.1", "Host: a.localhost", "no colon here"],
            ["GET / HTTP/1.1", "Host: a.localhost", "X: a\nHost: evil.com"],       // a bare LF hiding a second Host
            ["GET / HTTP/1.1", "Host: a.localhost", "X: a\rb"],
            // Header names that aren't plain tokens, or have an underscore (X_Forwarded_For reads as X-Forwarded-For to some servers).
            ["GET / HTTP/1.1", "Host: a.localhost", "X_Forwarded_For: 6.6.6.6"],
            ["GET / HTTP/1.1", "Host: a.localhost", "X(Y): 1"],
            ["GET / HTTP/1.1", "Host: a.localhost", "X@Y: 1"],
            ["GET / HTTP/1.1", "Host: a.localhost", "X\u{e9}: 1"],
            ["GET / HTTP/1.1", "Host: a.localhost", "\"X\": 1"],
            // A Host whose port isn't digits.
            ["GET / HTTP/1.1", "Host: a.localhost:80a"],
            ["GET / HTTP/1.1", "Host: a.localhost:"],
            ["GET / HTTP/1.1", "Host: a.localhost:-80"],
            ["GET / HTTP/1.1", "Host: a.localhost:80:80x"],
            ["GET / HTTP/1.1", "Host: a.localhost:123456"],
            ["GET / HTTP/1.1", "Host: a.localhost:80 evil.com"],
            // A body with no single clear end.
            ["POST / HTTP/1.1", "Host: a.localhost", "Content-Length: 5", "Transfer-Encoding: chunked"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Content-Length: 5", "Content-Length: 6"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Content-Length: 5, 6"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Content-Length: -1"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Content-Length: 0x10"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Transfer-Encoding: gzip, chunked"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Transfer-Encoding: chunked", "Transfer-Encoding: chunked"],
            ["POST / HTTP/1.1", "Host: a.localhost", "Transfer-Encoding: identity"],
        ] {
            XCTAssertNil(ProxyHead(head(bad)), bad.joined(separator: " | "))
        }
        XCTAssertNil(ProxyHead(Data()))
        // Ordinary names with the punctuation HTTP allows are fine, and so is a port in the Host.
        XCTAssertNotNil(ProxyHead(head(["GET / HTTP/1.1", "Host: a.localhost:8490", "Sec-WebSocket-Key: x", "X-Requested-With: y", "Accept-CH: z"])))
        XCTAssertEqual(ProxyHead(head(["POST / HTTP/1.1", "Host: a.localhost", "Content-Length: 5", "Content-Length: 5"]))?.body, .length(5))
        XCTAssertEqual(ProxyHead(head(["POST / HTTP/1.1", "Host: a.localhost", "Transfer-Encoding: Chunked"]))?.body, .chunked)
        XCTAssertEqual(ProxyHead(head(["GET / HTTP/1.1", "Host: a.localhost"]))?.body, ProxyHead.Body.none)
    }

    func testHeadBytesSurviveTheRewrite() throws {
        // A header value that isn't UTF-8 goes out byte for byte.
        var raw = Data("GET / HTTP/1.1\r\nHost: a.localhost\r\nX-Odd: ".utf8)
        raw.append(contentsOf: [0xE9, 0xFF, 0x80])
        raw.append(Data("\r\n\r\n".utf8))
        let out = try XCTUnwrap(ProxyHead(raw)).forwarded(client: "127.0.0.1")
        XCTAssertNotNil(out.range(of: Data([0x58, 0x2D, 0x4F, 0x64, 0x64, 0x3A, 0x20, 0xE9, 0xFF, 0x80, 0x0D, 0x0A])))
    }

    // MARK: The proxy's own pages

    func testOwnPagesCantCarryMarkup() {
        let page = String(decoding: Proxy.page(404, "Nothing is running as <img src=x onerror=alert(1)>&.localhost."), as: UTF8.self)
        XCTAssertFalse(page.contains("<img"))
        XCTAssertTrue(page.contains("&lt;img src=x onerror=alert(1)&gt;&amp;.localhost"))
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(page.contains("Content-Security-Policy: default-src 'none'"))
        XCTAssertTrue(page.contains("Connection: close\r\n"))
        XCTAssertTrue(page.contains("href=\"http://harbor.localhost:\(LaunchAgent.port)/\""))    // the link to harbor
        XCTAssertFalse(String(decoding: Proxy.page(404, "Nothing here.", link: false), as: UTF8.self).contains("href"))
    }

    // MARK: The port-80 door

    func testDoorRoutes() {
        let usual = ["harbor.localhost": 8470, "headroom.localhost": 8460]
        func route(_ host: String) -> Door.Route { Door.route(head(["GET /x HTTP/1.1", "Host: \(host)"]), routes: usual) }
        func text(_ r: Door.Route) -> String { if case .reply(let d) = r { return String(decoding: d, as: UTF8.self) }; return "" }
        // The two apps keep their redirects.
        XCTAssertTrue(text(route("harbor.localhost")).hasPrefix("HTTP/1.1 302 Found\r\nLocation: http://harbor.localhost:8470/\r\n"))
        XCTAssertTrue(text(route("HEADROOM.localhost:80")).contains("Location: http://headroom.localhost:8460/\r\n"))
        // Any other .localhost name goes to harbor's proxy.
        XCTAssertEqual(route("storefront.localhost"), .proxy)
        XCTAssertEqual(route("Storefront.Localhost:80"), .proxy)
        XCTAssertEqual(route("storefront-3001.localhost."), .proxy)
        // Anything else never gets past the door.
        for host in ["evil.com", "localhost", "127.0.0.1", "[::1]", "storefront.localhost.evil.com", ""] {
            XCTAssertTrue(text(route(host)).hasPrefix("HTTP/1.1 404 Not Found\r\n"), host)
        }
        XCTAssertTrue(text(Door.route(Data("GET / HTTP/1.1\r\n\r\n".utf8))).hasPrefix("HTTP/1.1 404"))   // no Host at all
        // Only the head counts: a "Host:" line in the body is not a header.
        let inBody = Data("POST /x HTTP/1.1\r\nContent-Length: 30\r\n\r\nHost: storefront.localhost\r\n\r\n".utf8)
        XCTAssertTrue(text(Door.route(inBody, routes: usual)).hasPrefix("HTTP/1.1 404"))
        let bodyWins = Data("POST /x HTTP/1.1\r\nHost: evil.com\r\nContent-Length: 26\r\n\r\nHost: harbor.localhost\r\n\r\n".utf8)
        XCTAssertTrue(text(Door.route(bodyWins, routes: usual)).hasPrefix("HTTP/1.1 404"))
        // And it reads the head the way the proxy does: two Hosts are nobody's.
        XCTAssertTrue(text(Door.route(head(["GET / HTTP/1.1", "Host: evil.com", "Host: storefront.localhost"]), routes: usual)).hasPrefix("HTTP/1.1 404"))
        XCTAssertTrue(text(Door.route(head(["GET / HTTP/1.1", "Host: storefront.localhost", "Host: harbor.localhost"]), routes: usual)).hasPrefix("HTTP/1.1 404"))
        XCTAssertTrue(text(Door.route(Data("GET / HTTP/1.1\r\nHost: storefront.localhost\r\n".utf8), routes: usual)).hasPrefix("HTTP/1.1 404"))   // a head that never ended
    }

    // MARK: launchd

    func testAgentHoldsTheProxyPortOnLoopbackOnly() throws {
        let agent = LaunchAgent.agent(label: "local.test", program: ["/x/Harbor", "--launchd"], port: 8470)
        let sockets = try XCTUnwrap(agent["Sockets"] as? [String: [String: String]])
        XCTAssertEqual(Set(sockets.keys), ["v4", "v6", "p4", "p6"])
        XCTAssertEqual(sockets["p4"], ["SockNodeName": "127.0.0.1", "SockServiceName": "8490", "SockFamily": "IPv4"])
        XCTAssertEqual(sockets["p6"], ["SockNodeName": "::1", "SockServiceName": "8490", "SockFamily": "IPv6"])
        // Nothing in the agent listens on a network address.
        XCTAssertEqual(Set(sockets.values.compactMap { $0["SockNodeName"] }), ["127.0.0.1", "::1"])
    }

    func testOnlyANavigationToANameWakesAQuitHarbor() {
        let h = "Host: storefront.localhost\r\n"
        XCTAssertTrue(LaunchAgent.isNameVisit("GET / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\nSec-Fetch-Dest: document\r\nSec-Fetch-Site: none\r\n\r\n"))
        XCTAssertTrue(LaunchAgent.isNameVisit("GET /cart/3 HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\nSec-Fetch-Site: same-origin\r\n\r\n"))   // a reload
        for head in [
            "GET /hmr HTTP/1.1\r\n\(h)Connection: Upgrade\r\nUpgrade: websocket\r\nSec-Fetch-Mode: websocket\r\n\r\n",      // a hot-reload retry
            "GET /__ping HTTP/1.1\r\n\(h)Sec-Fetch-Mode: cors\r\nSec-Fetch-Site: same-origin\r\n\r\n",                        // a fetch from an open tab
            "GET /app.js HTTP/1.1\r\n\(h)Sec-Fetch-Mode: no-cors\r\nSec-Fetch-Dest: script\r\n\r\n",
            "GET / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\nSec-Fetch-Dest: iframe\r\n\r\n",                               // embedded in a page
            "GET / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\nSec-Fetch-Dest: document\r\nSec-Fetch-Site: cross-site\r\n\r\n",  // a link on another website
            "POST / HTTP/1.1\r\n\(h)Sec-Fetch-Mode: navigate\r\n\r\n",
            "GET / HTTP/1.1\r\n\(h)\r\n",                                                                                     // curl, a script
        ] {
            XCTAssertFalse(LaunchAgent.isNameVisit(head), head)
        }
        // Only for a Host the proxy would look up. Another website's name pointed at this Mac,
        // an address, or the apps' own names never wake it, navigation or not.
        let nav = "Sec-Fetch-Mode: navigate\r\nSec-Fetch-Dest: document\r\nSec-Fetch-Site: none\r\n\r\n"
        for host in ["evil.com", "evil.com:8490", "127.0.0.1:8490", "[::1]:8490", "localhost", "harbor.localhost", "headroom.localhost",
                     "storefront.localhost.evil.com", "a.b.localhost", ""] {
            XCTAssertFalse(LaunchAgent.isNameVisit("GET / HTTP/1.1\r\nHost: \(host)\r\n\(nav)"), host)
        }
        XCTAssertFalse(LaunchAgent.isNameVisit("GET / HTTP/1.1\r\n\(nav)"))                                                  // no Host
        XCTAssertFalse(LaunchAgent.isNameVisit("GET / HTTP/1.1\r\nHost: evil.com\r\n\(h)\(nav)"))                           // two Hosts
        XCTAssertFalse(LaunchAgent.isNameVisit("GET / HTTP/1.1\r\nSec-Fetch-Mode: navigate\r\n\r\n\(h)"))                     // one in the body only
        XCTAssertTrue(LaunchAgent.isNameVisit("GET / HTTP/1.1\r\nHost: Storefront.localhost:8490\r\n\(nav)"))
    }
}
