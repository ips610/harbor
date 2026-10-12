import XCTest
@testable import Harbor

/// Ports that follow reality: an app whose usual port another program holds moves to
/// the next free one, writes it to a file, and the port-80 door reads the files.
/// Everything here uses scratch files and ports the system picks; nothing real.
final class PortsTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-ports-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func app(_ usual: Int = 8470, _ name: String = "port") -> Ports.App {
        Ports.app(usual, folder.appendingPathComponent(name))
    }

    // MARK: The port file

    func testReadingThePortFile() throws {
        let harbor = app()
        XCTAssertEqual(harbor.range, 8470...8489)
        XCTAssertEqual(Ports.reserved(harbor), 8470)                              // no file: the usual port
        for (text, port) in [("8471", 8471), ("8489", 8489), ("8470", 8470), ("8475\n", 8475), ("  8472 ", 8472)] {
            try text.write(to: harbor.file, atomically: true, encoding: .utf8)
            XCTAssertEqual(Ports.reserved(harbor), port, text)
        }
        // Anything that isn't plain digits inside the app's range means the usual port.
        for garbage in ["", "abc", "8471x", "84 71", "-8471", "+8471", "8471.0", "0x2117", "８４７１", "8490", "8469", "80", "22", "65536", "99999999999999999999",
                        "8471\n8472", "8471;rm", "http://evil.com:8471"] {
            try garbage.write(to: harbor.file, atomically: true, encoding: .utf8)
            XCTAssertEqual(Ports.reserved(harbor), 8470, garbage)
        }
        try Data([0xff, 0xfe, 0x00]).write(to: harbor.file)                       // not text at all
        XCTAssertEqual(Ports.reserved(harbor), 8470)
        // The two apps have their own ranges.
        XCTAssertEqual(Ports.parse("8461", app(8460)), 8461)
        XCTAssertEqual(Ports.parse("8485", app(8460)), 8460)
    }

    func testRecordingThePort() throws {
        let harbor = app()
        Ports.record(8470, harbor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harbor.file.path))  // the usual port needs no file
        Ports.record(8471, harbor)
        XCTAssertEqual(try String(contentsOf: harbor.file, encoding: .utf8), "8471")   // plain digits
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: harbor.file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(Ports.reserved(harbor), 8471)
        Ports.record(9999, harbor)                                                // not one of harbor's ports: ignored
        XCTAssertEqual(Ports.reserved(harbor), 8471)
        Ports.record(8470, harbor)                                                // back on the usual one: the file says so
        XCTAssertEqual(try String(contentsOf: harbor.file, encoding: .utf8), "8470")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["port"])   // nothing left behind
    }

    // MARK: Choosing the port

    func testChoosingWithoutASocket() {
        let harbor = app()
        func choose(_ current: Int, ours: Bool = false, taken: Set<Int>) -> Int? {
            Ports.choose(harbor, current: current, ours: ours, taken: taken.contains) { !taken.contains($0) }
        }
        XCTAssertEqual(choose(8470, taken: []), 8470)                              // nobody's: keep it
        XCTAssertEqual(choose(8470, taken: [8470]), 8471)                          // taken: the next one
        XCTAssertEqual(choose(8470, taken: [8470, 8471, 8472, 8473]), 8474)        // the next free one
        XCTAssertEqual(choose(8470, ours: true, taken: Set(8470...8489)), 8470)    // its own agent holds it: keep it
        XCTAssertEqual(choose(8473, taken: []), 8473)                              // moved earlier: no hopping back
        XCTAssertEqual(choose(8473, taken: [8473]), 8470)                          // unless that one is unusable now
        XCTAssertNil(choose(8470, taken: Set(8470...8489)))                        // the whole range is taken
        // Can't be bound for the moment, but nobody answers there: it is still the app's port.
        XCTAssertEqual(Ports.choose(harbor, current: 8470, ours: false, taken: { _ in false }, isFree: { _ in false }), 8470)
    }

    /// Binds 127.0.0.1 on a port the system picks, the way another program would hold it.
    private func foreignSocket() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, size) == 0 && Darwin.listen(fd, 64) == 0 && getsockname(fd, $0, &size) == 0 } }
        try XCTSkipUnless(ok, "couldn't bind a test socket")
        return (fd, Int(UInt16(bigEndian: a.sin_port)))
    }

    func testChoosingWithTheUsualPortTakenByAnotherProgram() throws {
        let other = try foreignSocket()
        defer { close(other.fd) }
        let mine = app(other.port)
        XCTAssertFalse(Ports.isFree(other.port))                                  // 127.0.0.1 is held there
        XCTAssertTrue(Ports.isTaken(other.port))                                   // and something answers on it
        // Another program holds the usual port: the next free one in the range.
        let chosen = try XCTUnwrap(Ports.choose(mine, current: other.port, ours: false))
        XCTAssertTrue(mine.range.contains(chosen) && chosen != other.port, "\(chosen)")
        XCTAssertTrue(Ports.isFree(chosen))
        // The app's own agent holds it (launchd has the socket): it stays.
        XCTAssertEqual(Ports.choose(mine, current: other.port, ours: true), other.port)
        // And once the other program has gone, the port is free again.
        close(other.fd)
        XCTAssertTrue(Ports.isFree(other.port))
        XCTAssertFalse(Ports.isTaken(other.port))
    }

    func testAPortThatOnlyJustClosedIsNotTaken() throws {
        // What an unloaded agent leaves behind: its listener is gone, but a connection it closed
        // lingers for half a minute, and while it does the port can't always be bound from here.
        // That must not read as "another program has it", or harbor would move for no reason.
        let server = try foreignSocket()
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(server.port).bigEndian
        a.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let connected = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        try XCTSkipUnless(connected, "couldn't connect to the test socket")
        let accepted = accept(server.fd, nil, nil)
        close(accepted)          // the server side closes first, so its end is the one that lingers
        usleep(50_000)
        close(client)
        close(server.fd)
        usleep(50_000)
        if !Ports.isFree(server.port) { print("note: port \(server.port) can't be bound right after its listener closed (lingering connection)") }
        XCTAssertFalse(Ports.isTaken(server.port))
        XCTAssertEqual(Ports.choose(Ports.app(server.port, folder.appendingPathComponent("p")), current: server.port, ours: false), server.port)
    }

    // MARK: The door follows the files

    func testDoorRoutesComeFromThePortFiles() throws {
        let harbor = app(8470, "harbor-port"), headroom = app(8460, "headroom-port")
        func location(_ host: String) -> String? {
            guard case .reply(let data) = Door.route(Data("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8), routes: Door.routes(harbor: harbor, headroom: headroom)) else { return nil }
            return String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first { $0.hasPrefix("Location: ") }
        }
        // No files: the usual ports.
        XCTAssertEqual(Door.routes(harbor: harbor, headroom: headroom), ["harbor.localhost": 8470, "headroom.localhost": 8460])
        XCTAssertEqual(location("harbor.localhost"), "Location: http://harbor.localhost:8470/")
        // The apps moved: the door sends the names where they are now.
        try "8471".write(to: harbor.file, atomically: true, encoding: .utf8)
        try "8463".write(to: headroom.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(location("harbor.localhost"), "Location: http://harbor.localhost:8471/")
        XCTAssertEqual(location("headroom.localhost"), "Location: http://headroom.localhost:8463/")
        // A file can't send a name anywhere else: outside the app's range, or not a number, is the usual port.
        try "22".write(to: harbor.file, atomically: true, encoding: .utf8)
        try "8485".write(to: headroom.file, atomically: true, encoding: .utf8)     // one of harbor's ports, not headroom's
        XCTAssertEqual(location("harbor.localhost"), "Location: http://harbor.localhost:8470/")
        XCTAssertEqual(location("headroom.localhost"), "Location: http://headroom.localhost:8460/")
        try "evil.com:80/#".write(to: harbor.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(location("harbor.localhost"), "Location: http://harbor.localhost:8470/")
    }

    // MARK: Everything else follows the port

    func testHostAllowlistFollowsThePort() {
        // harbor on 8471: that is the only port its names are accepted with.
        let moved = WebServer(session: "s", originKey: "k", port: 8471) {}
        func status(_ host: String) -> Int? {
            guard case .complete(let req) = HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)) else { return nil }
            if case .reply(let r) = moved.route(req) { return r.status }
            return 200
        }
        XCTAssertEqual(status("harbor.localhost:8471"), 200)
        XCTAssertEqual(status("127.0.0.1:8471"), 200)
        XCTAssertEqual(status("harbor.localhost:8470"), 403)                      // the old port's name: refused
        XCTAssertEqual(status("harbor.localhost"), 403)
        XCTAssertEqual(moved.loginURL()?.port, 8471)                               // and the sign-in link is for the new one
    }

    func testAgentIsWrittenForTheChosenPort() throws {
        let agent = LaunchAgent.agent(label: "local.test", program: ["/x/Harbor", "--launchd"], port: 8473)
        let sockets = try XCTUnwrap(agent["Sockets"] as? [String: [String: String]])
        XCTAssertEqual(sockets["v4"]?["SockServiceName"], "8473")
        XCTAssertEqual(sockets["v6"]?["SockServiceName"], "8473")
        XCTAssertEqual(sockets["p4"]?["SockServiceName"], "8490")                 // names stay where they are
    }

    // MARK: Who may touch the agents and the port file

    func testOnlyACopyInApplicationsManagesTheAgents() {
        let home = "/Users/me"
        XCTAssertTrue(LaunchAgent.isInstalled("/Applications/harbor.app/Contents/MacOS/Harbor", home: home))
        XCTAssertTrue(LaunchAgent.isInstalled("/Users/me/Applications/harbor.app/Contents/MacOS/Harbor", home: home))
        for stray in [
            "/Users/me/Downloads/harbor.app/Contents/MacOS/Harbor",
            "/Users/me/Desktop/GitHub/harbor/build/harbor.app/Contents/MacOS/Harbor",          // the repo's build folder
            "/Users/me/Desktop/GitHub/harbor/.build/release/Harbor",
            "/private/var/folders/ab/xyz/T/AppTranslocation/1234-5678/d/harbor.app/Contents/MacOS/Harbor",
            "/Volumes/harbor/harbor.app/Contents/MacOS/Harbor",                                 // a disk image
            "/private/tmp/scratch/harbor.app/Contents/MacOS/Harbor",
            "/Applications/../Users/me/Downloads/harbor.app/Contents/MacOS/Harbor",             // not really in Applications
            "/Users/other/Applications/harbor.app/Contents/MacOS/Harbor",                       // someone else's
            "/ApplicationsX/harbor.app/Contents/MacOS/Harbor",
            "/Applications/AppTranslocation/1234/d/harbor.app/Contents/MacOS/Harbor",          // translocated, wherever that lands
        ] {
            XCTAssertFalse(LaunchAgent.isInstalled(stray, home: home), stray)
        }
        // Tests are a debug-less, app-less process: this one may never manage anything.
        XCTAssertFalse(LaunchAgent.mayManage)
        XCTAssertEqual(LaunchAgent.refresh(), .failed)
        XCTAssertFalse(Door.ensureInstalled())
    }

    func testAStrayCopyNeverMovesThePortFile() {
        // The copy launchd runs says where harbor is.
        XCTAssertTrue(Ports.mayRecord(underLaunchd: true, installed: true, agentLoaded: true))
        // An installed copy running by itself because no agent could be loaded: it does too.
        XCTAssertTrue(Ports.mayRecord(underLaunchd: false, installed: true, agentLoaded: false))
        // A second copy opened from Downloads or a build folder lands on 8471 beside the real one: never.
        XCTAssertFalse(Ports.mayRecord(underLaunchd: false, installed: false, agentLoaded: true))
        XCTAssertFalse(Ports.mayRecord(underLaunchd: false, installed: false, agentLoaded: false))
        // Nor an installed one beside a loaded agent (launchd holds the port for the real one).
        XCTAssertFalse(Ports.mayRecord(underLaunchd: false, installed: true, agentLoaded: true))
    }

    // MARK: The door: retries, and another app's door getting in between

    func testOneSlowAnswerIsntAnotherProgramOnPort80() {
        var answers = [false, true]
        var pauses = 0
        let door = Door.settled(installed: true, reach: { answers.removeFirst() }, pause: { pauses += 1 })
        XCTAssertTrue(door.ours && door.reaches)                                   // the second try answered
        XCTAssertEqual(pauses, 1)
        var asked = 0
        let taken = Door.settled(installed: true, reach: { asked += 1; return false }, pause: {})
        XCTAssertTrue(taken.ours && !taken.reaches)                                // three tries, then it is said
        XCTAssertEqual(asked, 3)
        let none = Door.settled(installed: false, reach: { XCTFail("not asked without a door"); return true }, pause: {})
        XCTAssertFalse(none.ours || none.reaches)
    }

    func testTheDoorIsLookedAtAgainWhileItIsntRight() {
        let now = Date()
        XCTAssertTrue(Monitor.doorCheckDue(ours: false, last: nil, now: now))                             // at launch
        XCTAssertFalse(Monitor.doorCheckDue(ours: true, last: now.addingTimeInterval(-3600), now: now))    // all well: never again
        XCTAssertFalse(Monitor.doorCheckDue(ours: false, last: now.addingTimeInterval(-10), now: now))     // not more than once a minute
        XCTAssertTrue(Monitor.doorCheckDue(ours: false, last: now.addingTimeInterval(-61), now: now))      // not given up for the whole run
    }

    /// A stand-in for launchctl with one label: loaded or not, and something that happens at a bootout.
    private final class FakeLaunchd {
        var loaded = false
        var calls: [String] = []
        var atBootout: (() -> Void)?
        func run(_ args: [String]) -> Bool {
            calls.append(args[0])
            switch args[0] {
            case "print": return loaded
            case "bootout":
                let was = loaded
                loaded = false
                let then = atBootout
                atBootout = nil
                then?()
                return was
            case "bootstrap":
                if loaded { return false }   // "service already loaded"
                loaded = true
                return true
            default: return false
            }
        }
    }

    private func program(of plist: URL) -> [String]? { NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String] }

    private func write(_ program: [String], to plist: URL) {
        (["Label": "x", "ProgramArguments": program] as NSDictionary).write(to: plist, atomically: true)
    }

    func testDoorTakeoverWithHeadroomInBetween() {
        let plist = folder.appendingPathComponent("door.plist")
        let harbor = ["/Applications/harbor.app/Contents/MacOS/Harbor", "--door"], headroom = ["/Applications/headroom.app/Contents/MacOS/headroom-app", "--door"]
        func install(_ launchd: FakeLaunchd) -> Bool { Door.install(label: "local.test.door", plist: plist, program: harbor, port: 28080, run: launchd.run) }

        // No door yet: written and loaded.
        let fresh = FakeLaunchd()
        XCTAssertTrue(install(fresh))
        XCTAssertEqual(program(of: plist), harbor)
        XCTAssertTrue(fresh.loaded)
        XCTAssertEqual(fresh.calls, ["print", "bootstrap"])
        // Already harbor's and loaded: left alone.
        fresh.calls = []
        XCTAssertTrue(install(fresh))
        XCTAssertEqual(fresh.calls, ["print"])

        // headroom's door is loaded: harbor's file is in place before theirs is unloaded, then loaded.
        write(headroom, to: plist)
        let theirs = FakeLaunchd()
        theirs.loaded = true
        theirs.atBootout = { XCTAssertEqual(self.program(of: plist), harbor) }     // never a moment with no door's plist to load
        XCTAssertTrue(install(theirs))
        XCTAssertEqual(program(of: plist), harbor)
        XCTAssertEqual(theirs.calls, ["print", "bootout", "bootstrap"])

        // headroom starts at that very moment and, finding harbor's plist unloaded, loads it
        // itself. harbor's bootstrap is refused, but the door is harbor's and loaded: done.
        write(headroom, to: plist)
        let helped = FakeLaunchd()
        helped.loaded = true
        helped.atBootout = { helped.loaded = true }
        let started = Date()
        XCTAssertTrue(install(helped))
        XCTAssertEqual(program(of: plist), harbor)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)                     // without fifteen refused tries first

        // An older headroom puts its own door back in that moment: harbor takes it over again.
        write(headroom, to: plist)
        let raced = FakeLaunchd()
        raced.loaded = true
        raced.atBootout = { self.write(headroom, to: plist); raced.loaded = true }
        XCTAssertTrue(install(raced))
        XCTAssertEqual(program(of: plist), harbor)
        XCTAssertTrue(raced.loaded)
    }

    func testAgentIsReplacedWhenItIsntThisVersions() throws {
        // An agent from the version before names: two sockets, loaded.
        let plist = folder.appendingPathComponent("agent.plist")
        let mine = app(try freePort(), "agent-port")
        let program = ["/Applications/harbor.app/Contents/MacOS/Harbor", "--launchd"]
        var old = LaunchAgent.agent(label: "local.test", program: program, port: mine.usual)
        old["Sockets"] = (old["Sockets"] as? [String: Any])?.filter { ["v4", "v6"].contains($0.key) }
        (old as NSDictionary).write(to: plist, atomically: true)
        let launchd = FakeLaunchd()
        launchd.loaded = true
        var askedOldToQuit = 0
        func refresh() -> LaunchAgent.Refresh {
            LaunchAgent.install(label: "local.test", plist: plist, program: program, app: mine, quitOld: { askedOldToQuit += 1 }, run: launchd.run)
        }
        XCTAssertEqual(refresh(), .replaced)
        XCTAssertEqual(launchd.calls, ["print", "bootout", "bootstrap"])           // the old one out, this version's in
        XCTAssertEqual(askedOldToQuit, 1)                                           // and the copy running under it asked to go first
        XCTAssertEqual(Set(((NSDictionary(contentsOf: plist)?["Sockets"]) as? [String: Any] ?? [:]).keys), ["v4", "v6", "p4", "p6"])
        // Run again (install.sh twice, or the next launch): nothing to do, nobody is asked to quit.
        launchd.calls = []
        XCTAssertEqual(refresh(), .current)
        XCTAssertEqual(launchd.calls, ["print"])
        XCTAssertEqual(askedOldToQuit, 1)
        // The app moved: the program path differs, so it is replaced again.
        let moved = LaunchAgent.install(label: "local.test", plist: plist, program: ["/Users/me/Applications/harbor.app/Contents/MacOS/Harbor", "--launchd"],
                                        app: mine, run: launchd.run)
        XCTAssertEqual(moved, .replaced)
    }

    /// A port nothing is on, from the system.
    private func freePort() throws -> Int {
        let probe = try foreignSocket()
        close(probe.fd)
        return probe.port
    }

    func testNamesNeverTargetTheAppsRealPorts() {
        // Wherever the two apps are on this Mac, plus the proxy's own port.
        XCTAssertEqual(Names.reservedPorts, [UInt16(Ports.reserved(Ports.headroom)), UInt16(Ports.reserved(Ports.harbor)), 8490])
        XCTAssertEqual(Ports.harbor.usual, 8470)
        XCTAssertEqual(Ports.headroom.usual, 8460)
        XCTAssertEqual(Ports.headroom.range, 8460...8479)
        XCTAssertFalse(Ports.harbor.range.contains(Int(Proxy.port)) || Ports.headroom.range.contains(Int(Proxy.port)))
    }
}
