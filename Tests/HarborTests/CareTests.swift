import Darwin
import Security
import XCTest
@testable import Harbor

private func row(_ port: UInt16, _ process: String = "node", pid: pid_t = 4101, folder: String? = "/Users/sam/code/storefront", path: String? = "/opt/homebrew/bin/node",
                 category: PortCategory = .dev, system: Bool = false, isSelf: Bool = false, bundle: String? = nil, started: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> PortRow {
    PortRow(port: port, addresses: ["127.0.0.1"], scope: .loopback, pid: pid, ppid: 1, processName: process, path: path, cwd: folder, projectRoot: folder,
            command: nil, started: started, footprint: nil, workers: 0, workerPids: [], isSystem: system,
            appBundle: bundle, appName: bundle.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }, framework: nil, category: category, isSelf: isSelf)
}

/// A folder of its own under the temporary folder, gone after the test.
private func scratch(_ test: XCTestCase, _ name: String) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-\(name)-\(Lan.token(4))")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    // Where it really is: the temporary folder is behind a link (/var → /private/var).
    return URL(fileURLWithPath: realpath(folder.path, nil).map { String(cString: $0) } ?? folder.path)
}

private func mode(_ path: String) -> Int {
    var info = stat()
    return stat(path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
}

/// Has what is at `path` (a link itself, not what it leads to) an access list?
private func hasACL(_ path: String) -> Bool {
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
}

@discardableResult
private func tool(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - A. Tell me when it stops

final class WatchTests: XCTestCase {
    func testWhatIsSaidAndWhen() {
        XCTAssertEqual(Monitor.stoppedText(name: "storefront", port: 3000), "storefront (:3000) stopped.")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let front = row(3000), api = row(3001, pid: 4102)
        let watched = [front.id: Monitor.Watch(pid: 4101, port: 3000, started: t0, name: "storefront"), api.id: Monitor.Watch(pid: 4102, port: 3001, started: t0, name: "storefront-3001")]
        // Still that process, started then, on that port: nothing to say.
        var over = Monitor.over(watched, in: [front, api], stopping: [])
        XCTAssertTrue(over.tell.isEmpty && over.quiet.isEmpty)
        // Gone: said. Its port taken by another process, or its pid given to a server started later: gone all the same.
        XCTAssertEqual(Monitor.over(watched, in: [api], stopping: []).tell, [front.id])
        XCTAssertEqual(Monitor.over(watched, in: [row(3000, pid: 5000), api], stopping: []).tell, [front.id])
        XCTAssertEqual(Monitor.over(watched, in: [row(3000, started: t0.addingTimeInterval(60)), api], stopping: []).tell, [front.id])
        XCTAssertEqual(Monitor.over(watched, in: [], stopping: []).tell, [front.id, api.id].sorted())
        // Harbor is stopping it itself, on the owner's click: the watch is over, and nothing is said.
        over = Monitor.over(watched, in: [api], stopping: [4101])
        XCTAssertEqual(over.quiet, [front.id])
        XCTAssertTrue(over.tell.isEmpty)
        XCTAssertTrue(Monitor.over([:], in: [], stopping: []).tell.isEmpty)
    }

    @MainActor
    func testOneServersBell() {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared
        m.stopAllSharing()
        let rows = m.ports, front = rows.first { $0.port == 3000 }!, api = rows.first { $0.port == 3001 }!, database = rows.first { $0.port == 5432 }!
        var said: [String] = []
        let post = Notifier.post
        Notifier.post = { said.append($0) }
        defer { Notifier.post = post; m.setWatch(front, false); m.setWatch(api, false); m.setWatch(database, false); m.useFixture(rows, shared: nil) }

        // Off by default, and with nothing watched (or shared) harbor scans as it always has: not at all without a badge.
        XCTAssertFalse(m.isWatched(front))
        let idle = Monitor.scanEvery(refresh: m.refreshInterval, sharing: false, badge: m.badgeMode != "hidden")
        XCTAssertNil(Monitor.scanEvery(refresh: m.refreshInterval, sharing: false, badge: false))
        XCTAssertEqual(m.scansEvery, idle)
        // The bell on one server: that one only, and now there is a scan at least every 15 seconds to see it go.
        m.setWatch(front, true)
        XCTAssertTrue(m.isWatched(front))
        XCTAssertFalse(m.isWatched(api))
        XCTAssertEqual(m.scansEvery, min(m.refreshInterval > 0 ? m.refreshInterval : 15, 15))
        var state: [String: Any] = [:]
        WebAPI.state { state = ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }
        let told = (state["ports"] as? [[String: Any]]) ?? []
        XCTAssertEqual(told.first { ($0["port"] as? Int) == 3000 }?["watched"] as? Bool, true)
        XCTAssertEqual(told.first { ($0["port"] as? Int) == 3001 }?["watched"] as? Bool, false)
        // Another server stops: nothing is said. Scans in which it still runs: nothing either.
        m.useFixture(rows.filter { $0.port != 3001 }, shared: nil)
        m.useFixture(rows.filter { $0.port != 3001 }, shared: nil)
        XCTAssertTrue(said.isEmpty)
        // It stops: said once, in harbor's own words, and the watch is over (so is the scanning).
        let before = m.notices.last?.id
        m.useFixture(rows.filter { $0.port != 3000 }, shared: nil)
        XCTAssertEqual(said, ["storefront (:3000) stopped."])
        XCTAssertEqual(m.notices.last?.text, "storefront (:3000) stopped.")
        XCTAssertNotEqual(m.notices.last?.id, before)
        XCTAssertFalse(m.isWatched(front))
        XCTAssertEqual(m.scansEvery, idle)
        m.useFixture(rows.filter { $0.port != 3000 }, shared: nil)
        m.useFixture(rows, shared: nil)                                                    // and it coming back is not a watch again
        m.useFixture(rows.filter { $0.port != 3000 }, shared: nil)
        XCTAssertEqual(said.count, 1)

        // The owner stops it through harbor: nothing to tell them. While the stop is under way…
        m.useFixture(rows, shared: nil)
        m.setWatch(front, true)
        m.setBusy(front.pid, true)
        m.useFixture(rows.filter { $0.port != 3000 }, shared: nil)
        m.setBusy(front.pid, false)
        XCTAssertFalse(m.isWatched(front))
        XCTAssertEqual(said.count, 1)
        // …and once it has gone (what Engine does when its stop worked).
        m.useFixture(rows, shared: nil)
        m.setWatch(front, true)
        m.setWatch(api, true)
        m.unwatch(pid: front.pid)
        XCTAssertFalse(m.isWatched(front))
        XCTAssertTrue(m.isWatched(api))
        m.useFixture(rows.filter { $0.port != 3000 }, shared: nil)
        XCTAssertEqual(said.count, 1)
        // A server with no name of its own (a database) is said by its cleaned title; macOS's own can't be watched at all.
        m.setWatch(database, true)
        m.useFixture(rows.filter { $0.port != 5432 }, shared: nil)
        XCTAssertEqual(said.last, "Postgres (:5432) stopped.")
        let system = row(5000, "ControlCenter", pid: 488, folder: nil, category: .system, system: true)
        m.useFixture(rows + [system], shared: nil)
        m.setWatch(system, true)
        XCTAssertFalse(m.isWatched(system))
        m.setWatch(row(9999, pid: 9999), true)                                             // and so can't something that isn't in the list
        XCTAssertFalse(m.isWatched(row(9999, pid: 9999)))
    }
}

extension WatchTests {
    /// Force stop (and the administrator's stop) are harbor ending it on the owner's click,
    /// like stop: whichever scan sees it go while harbor waits, nothing is said.
    @MainActor
    func testAForcedStopKeepsTheBellQuiet() async throws {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared, rows = m.ports
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { kill(child.processIdentifier, SIGKILL) }
        let mine = row(43990, pid: child.processIdentifier)
        var said: [String] = []
        let post = Notifier.post
        Notifier.post = { said.append($0) }
        defer { Notifier.post = post; m.setWatch(mine, false); m.useFixture(rows, shared: nil) }
        m.useFixture(rows + [mine], shared: nil)
        m.setWatch(mine, true)
        XCTAssertTrue(m.isWatched(mine))
        var busyThen = false
        let report = await Engine.force(pid: mine.pid, name: "node", path: "/Users/sam/code/storefront/server", label: "node on :43990", wait: { pid, _ in
            // While harbor waits for it to go, a scan sees that it has gone.
            await MainActor.run {
                busyThen = m.busy.contains(pid)
                m.useFixture(rows, shared: nil)
            }
            return true
        })
        XCTAssertEqual(report.result, .stopped)
        XCTAssertTrue(busyThen)
        XCTAssertEqual(said, [])
        XCTAssertFalse(m.isWatched(mine))
        XCTAssertFalse(m.busy.contains(mine.pid), "and it isn't left marked once the stop is over")
    }
}

// MARK: - B. Start again

final class RestartTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func launch(_ executable: String = "/opt/homebrew/bin/node", folder: String = "/Users/sam/code/storefront", arguments: [String] = ["node", "server.js"],
                        environment: [String: String] = ["PATH": "/usr/bin:/bin"]) -> Restart.Launch {
        Restart.Launch(executable: executable, resolved: executable, arguments: arguments, environment: environment, folder: folder, folderResolved: folder)
    }

    private func entry(_ port: UInt16, at: Date? = nil, id: String? = nil, name: String = "storefront", launch given: Restart.Launch? = nil) -> Restart.Stopped {
        Restart.Stopped(id: id ?? "id-\(port)", name: name, port: port, launch: given ?? launch(), at: at ?? t0)
    }

    func testHowAProcessWasStarted() {
        // What the kernel hands out: argc, the path that was exec'd, padding, argv, then the environment.
        var bytes: [UInt8] = [2, 0, 0, 0]
        for part in ["/opt/homebrew/bin/node"] { bytes += Array(part.utf8) + [0] }
        bytes += [0, 0, 0]
        for part in ["node", "server.js --port=3000", "HOME=/Users/sam", "API_KEY=s3cr3t=with=equals", "EMPTY="] { bytes += Array(part.utf8) + [0] }
        bytes += [0, 0]
        let found = LibProc.launch(in: bytes)
        XCTAssertEqual(found?.exec, "/opt/homebrew/bin/node")
        XCTAssertEqual(found?.arguments ?? [], ["node", "server.js --port=3000"])
        XCTAssertEqual(found?.environment ?? [], ["HOME=/Users/sam", "API_KEY=s3cr3t=with=equals", "EMPTY="])
        // Cut short, or nonsense: nothing, rather than half a command.
        XCTAssertNil(LibProc.launch(in: []))
        XCTAssertNil(LibProc.launch(in: [2, 0, 0, 0]))
        XCTAssertNil(LibProc.launch(in: [3, 0, 0, 0] + Array("/bin/x".utf8) + [0] + Array("x".utf8) + [0]))
        XCTAssertNil(LibProc.launch(in: [255, 255, 255, 255] + Array("/bin/x".utf8) + [0]))
        // And of a real process (this one): its own argv, as an array.
        let mine = LibProc.launch(getpid())
        XCTAssertEqual(mine?.arguments ?? [], ProcessInfo.processInfo.arguments)
        XCTAssertEqual(mine?.exec.hasPrefix("/"), true)
        XCTAssertEqual(mine?.environment.contains { $0.hasPrefix("HOME=") }, true)
        // "NAME=value" becomes a name and a value; the first "=" is where they part.
        let started = Restart.launch(exec: "/bin/sh", path: "/bin/sh", arguments: ["sh"], environment: ["A=1", "B=x=y", "=odd", "plain", "C="], folder: "/tmp")
        XCTAssertEqual(started?.environment, ["A": "1", "B": "x=y", "C": ""])
        // No whole path to what was exec'd, and none to the binary either: nothing harbor could start again.
        XCTAssertNil(Restart.launch(exec: "node", path: nil, arguments: ["node"], environment: [], folder: "/tmp"))
        XCTAssertNil(Restart.launch(exec: "node", path: ".", arguments: ["node"], environment: [], folder: "/tmp"))      // a path that isn't whole is no path
        XCTAssertEqual(Restart.launch(exec: "node", path: "/bin/sh", arguments: ["node"], environment: [], folder: "/tmp")?.executable, "/bin/sh")
        XCTAssertNil(Restart.launch(exec: "/bin/sh", path: "/bin/sh", arguments: ["sh"], environment: [], folder: "/no/such/folder"))
        // Which program runs is the kernel's word. What the process says was exec'd is taken only when it leads to that
        // same file; when it is a whole path that leads anywhere else, nothing is remembered at all.
        XCTAssertNil(Restart.launch(exec: "/bin/sh", path: nil, arguments: ["sh"], environment: [], folder: "/tmp"))
        XCTAssertNil(Restart.launch(exec: "/bin/sh", path: "/bin/ls", arguments: ["sh"], environment: [], folder: "/tmp"))
        XCTAssertNil(Restart.launch(exec: "/no/such/program", path: "/bin/ls", arguments: ["x"], environment: [], folder: "/tmp"))
        XCTAssertEqual(Restart.launch(exec: "./ls", path: "/bin/ls", arguments: ["ls"], environment: [], folder: "/tmp")?.executable, "/bin/ls")
        XCTAssertEqual(Restart.launch(exec: "/bin/../bin/ls", path: "/bin/ls", arguments: ["ls"], environment: [], folder: "/tmp")?.resolved, "/bin/ls")
    }

    func testWhatMayBeRemembered() {
        let me = getuid()
        // Whose a process is comes from the kernel: this test's own runner is mine, and macOS's first processes are root's.
        XCTAssertEqual(LibProc.owner(getpid()), me)
        XCTAssertEqual(LibProc.owner(1), 0)
        XCTAssertNil(LibProc.owner(999_999_999))
        let roots = (2...2000).first { LibProc.owner(pid_t($0)) == 0 }.map { pid_t($0) }
        XCTAssertTrue(Restart.mayRemember(row(3000, pid: getppid()), sandboxed: { _ in false }, tunnel: false))
        if let roots, me != 0 {
            XCTAssertFalse(Restart.mayRemember(row(3000, pid: roots), sandboxed: { _ in false }, tunnel: false))
            XCTAssertTrue(Restart.mayRemember(row(3000, pid: roots), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        }
        // A process in a sandbox is never remembered: started again by harbor it would be outside it. No answer counts as "in one".
        XCTAssertFalse(Restart.mayRemember(row(3000), owner: { _ in me }, sandboxed: { _ in true }, tunnel: false))
        XCTAssertTrue(Restart.isSandboxed(999_999))
        XCTAssertFalse(Restart.isSandboxed(1))
        let boxed = Process()
        boxed.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        boxed.arguments = ["-p", "(version 1)(allow default)", "/bin/sleep", "20"]
        boxed.standardError = FileHandle.nullDevice
        if (try? boxed.run()) != nil {
            defer { kill(boxed.processIdentifier, SIGKILL) }
            // sandbox-exec puts itself in the sandbox and then becomes the program: a moment, longer on a busy Mac.
            let patience = Date().addingTimeInterval(10)
            while boxed.isRunning, !Restart.isSandboxed(boxed.processIdentifier), Date() < patience { usleep(50_000) }
            if boxed.isRunning {
                XCTAssertTrue(Restart.isSandboxed(boxed.processIdentifier))
                XCTAssertFalse(Restart.mayRemember(row(3000, pid: boxed.processIdentifier), owner: { _ in me }, tunnel: false))
                XCTAssertTrue(Restart.mayRemember(row(3000, pid: boxed.processIdentifier), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
            } else {
                XCTAssertTrue(Restart.isSandboxed(getpid()), "only inside a sandbox can sandbox-exec not start one")
            }
        }
        // A server of mine, started from a folder, that harbor would also let me stop.
        XCTAssertTrue(Restart.mayRemember(row(3000), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertTrue(Restart.mayRemember(row(3000, "python3", category: .runtime), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        // Never: another user's, macOS's own, harbor in any form, what harbor runs for a public link, Docker's or a
        // container, an app's helper, and anything with no path or no folder to start it from.
        XCTAssertFalse(Restart.mayRemember(row(3000), owner: { _ in 0 }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000), owner: { _ in me &+ 1 }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000), owner: { _ in nil }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(5000, "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", category: .system, system: true), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, path: "/usr/sbin/httpd"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, system: true), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, isSelf: true), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(8470, "Harbor", path: "/Applications/harbor.app/Contents/MacOS/Harbor"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(20241, "cloudflared", path: "/opt/homebrew/bin/cloudflared"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: true))
        XCTAssertFalse(Restart.mayRemember(row(8080, "Docker", folder: nil, path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", bundle: "/Applications/Docker.app"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(8080, path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        var inContainer = row(8080)
        XCTAssertTrue(Restart.mayRemember(inContainer, owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        inContainer.container = Docker.Container(id: "ab", name: "web", image: "nginx", project: nil, service: nil)
        XCTAssertFalse(Restart.mayRemember(inContainer, owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(11434, "ollama", path: "/Applications/Ollama.app/Contents/MacOS/ollama", bundle: "/Applications/Ollama.app"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, path: nil), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, folder: nil), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, folder: "/"), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
        XCTAssertFalse(Restart.mayRemember(row(3000, pid: 1), owner: { _ in me }, sandboxed: { _ in false }, tunnel: false))
    }

    func testTheListOfWhatStopped() {
        // What just stopped goes in front; what is listening again, a day old, or beyond the newest twenty goes.
        var list = Restart.list([], adding: [entry(3000)], listening: [], now: t0)
        XCTAssertEqual(list.map(\.port), [3000])
        list = Restart.list(list, adding: [entry(3001, at: t0.addingTimeInterval(60))], listening: [], now: t0.addingTimeInterval(60))
        XCTAssertEqual(list.map(\.port), [3001, 3000])
        // Something listens on a port again, however it was started: that row leaves.
        XCTAssertEqual(Restart.list(list, adding: [], listening: [3000], now: t0.addingTimeInterval(61)).map(\.port), [3001])
        XCTAssertEqual(Restart.list(list, adding: [entry(4000, at: t0.addingTimeInterval(61))], listening: [4000, 3001], now: t0.addingTimeInterval(61)).map(\.port), [3000])
        // A day, and not a second more.
        XCTAssertEqual(Restart.life, 24 * 3600)
        XCTAssertEqual(Restart.list(list, adding: [], listening: [], now: t0.addingTimeInterval(24 * 3600 - 1)).map(\.port), [3001, 3000])
        XCTAssertEqual(Restart.list(list, adding: [], listening: [], now: t0.addingTimeInterval(24 * 3600)).map(\.port), [3001])
        XCTAssertEqual(Restart.list(list, adding: [], listening: [], now: t0.addingTimeInterval(24 * 3600 + 60)).map(\.port), [])
        // Twenty, the newest ones. One row per port: what ran there last.
        XCTAssertEqual(Restart.keep, 20)
        let many = (0..<30).map { entry(UInt16(5000 + $0), at: t0.addingTimeInterval(Double($0))) }
        let kept = Restart.list([], adding: many, listening: [], now: t0.addingTimeInterval(40))
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept.first?.port, 5029)
        XCTAssertEqual(kept.last?.port, 5010)
        let again = Restart.list(kept, adding: [entry(5029, at: t0.addingTimeInterval(50), id: "newer", launch: launch(arguments: ["node", "other.js"]))], listening: [], now: t0.addingTimeInterval(50))
        XCTAssertEqual(again.filter { $0.port == 5029 }.map(\.id), ["newer"])
        XCTAssertEqual(again.count, 20)
    }

    func testWhatTheOwnerIsShown() throws {
        let secret = "s3cr3t-\(Lan.token(6))"
        // The row's line: the program by its file's name, never by what it calls itself (argv[0] is the process's to choose).
        XCTAssertEqual(Restart.command(launch("/tmp/hb16srv", arguments: ["node", "server.js"])), "hb16srv server.js")
        XCTAssertEqual(Restart.command(launch(arguments: ["node", "server.js", "--port", "3000"], environment: ["API_KEY": secret])), "node server.js --port 3000")
        // Each argument can be told from the next: one that is empty, or has a space, a quote or anything a shell reads, is in single quotes.
        XCTAssertEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "a\" \"b"])), "echo 'a\" \"b'")
        XCTAssertEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "", " ", "x"])), "echo '' ' ' x")
        XCTAssertEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "hi", "&&", "rm", "-rf", "~"])), "echo hi '&&' rm -rf '~'")
        XCTAssertEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "it's", "$(id)", "a;b", "two words", "--name=x_1.2,3:4/5@6%7+8"])), "echo 'it'\\''s' '$(id)' 'a;b' 'two words' --name=x_1.2,3:4/5@6%7+8")
        XCTAssertNotEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "a b"])), Restart.command(launch("/bin/echo", arguments: ["echo", "a", "b"])))
        XCTAssertNotEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "a", ""])), Restart.command(launch("/bin/echo", arguments: ["echo", "a"])))
        // What can't be seen is shown as a mark, never dropped and never turned into a space: an escape, a line break, a tab, a change of direction, a zero.
        XCTAssertEqual(Restart.command(launch("/bin/echo", arguments: ["echo", "esc\u{1B}[2J", "new\nline", "tab\there", "safe\u{202E}gnp.exe", "a\u{0}b", "nb\u{A0}sp"])),
                       "echo 'esc\u{FFFD}[2J' 'new\u{FFFD}line' 'tab\u{FFFD}here' 'safe\u{FFFD}gnp.exe' 'a\u{FFFD}b' 'nb\u{FFFD}sp'")
        XCTAssertEqual(Restart.command(launch("/tmp/od\u{202E}d\nname", arguments: ["x"])), "'od\u{FFFD}d\u{FFFD}name'")
        // A long one is cut, and says by how much: what runs past the cut is at least counted.
        let long = Restart.command(launch(arguments: ["node", "server.js", "--label=" + String(repeating: "a", count: 280), "--require", "/tmp/evil.js"]))
        XCTAssertTrue(long.hasPrefix("node server.js --label=aaa"))
        XCTAssertTrue(long.hasSuffix("aaa… (26 more characters not shown)"), long)
        XCTAssertFalse(long.contains("evil"))
        XCTAssertFalse(Restart.command(launch(arguments: ["node", String(repeating: "a", count: 295)])).contains("not shown"))        // 300 exactly: all of it
        XCTAssertTrue(Restart.command(launch(arguments: ["node", String(repeating: "a", count: 296)])).hasSuffix("… (1 more characters not shown)"))
        XCTAssertEqual(Restart.cut(String(repeating: "e\u{301}", count: 10), max: 4), "e\u{301}e\u{301}… (16 more characters not shown)")   // counted in code points, so marks piled on a letter count too

        // What is asked before it is started. First the program, by where it really is, on a line of its own; then its arguments.
        let loud = ["API_KEY": secret, "NODE_OPTIONS": "--require /tmp/\(secret).js", "PYTHONPATH": secret, "PATH": "/usr/bin"]
        var asked = Restart.question(Restart.Stopped(id: "x", name: "shop", port: 4321, launch: launch("/tmp/hb16srv", folder: "/tmp", arguments: ["node", "server.js", "two words"], environment: loud), at: t0))
        var lines = asked.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(3)), ["/tmp/hb16srv", "server.js 'two words'", ""])
        XCTAssertTrue(lines.contains("in /tmp, on port 4321 as before. It gets no Terminal: its output goes to a log file."))
        // The environment comes back, and that is said. Its values are never shown; the names of the ones that make a program load code are.
        XCTAssertTrue(lines.contains("Its environment comes back as it was. Set in it, and able to make it load code: NODE_OPTIONS, PYTHONPATH."), asked)
        XCTAssertFalse(asked.contains(secret) || asked.contains("API_KEY") || asked.contains("/usr/bin"))
        XCTAssertFalse(asked.contains("changed"))
        XCTAssertEqual(Restart.loaders, ["NODE_OPTIONS", "PYTHONSTARTUP", "PYTHONPATH", "BASH_ENV", "ENV", "RUBYOPT", "PERL5OPT", "JAVA_TOOL_OPTIONS", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD"])
        for name in Restart.loaders {
            XCTAssertTrue(Restart.question(entry(4321, launch: launch(environment: [name: secret, "HOME": "/Users/sam"]))).contains("able to make it load code: \(name)."), name)
        }
        XCTAssertTrue(Restart.question(entry(4321, launch: launch(environment: ["HOME": "/Users/sam", "NODE_ENV": "x"]))).components(separatedBy: "\n").contains("Its environment comes back as it was."))
        // Run through a link (a virtualenv's python): both are shown, the real one first. No arguments: said.
        let linked = Restart.Launch(executable: "/Users/sam/code/app/.venv/bin/python", resolved: "/opt/homebrew/bin/python3.12", arguments: ["python"], environment: [:], folder: "/Users/sam/code/app", folderResolved: "/Users/sam/code/app")
        lines = Restart.question(entry(4321, launch: linked)).components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), ["/opt/homebrew/bin/python3.12", "run as /Users/sam/code/app/.venv/bin/python", "(no arguments)", ""])
        // A long list of arguments is cut here too, further on, and says so.
        asked = Restart.question(entry(4321, launch: launch(arguments: ["python3"] + (0..<400).map { "-W\($0)" } + ["-c", "import os"])))
        XCTAssertTrue(asked.components(separatedBy: "\n")[1].hasSuffix(" more characters not shown)"))
        XCTAssertFalse(asked.contains("import os"))

        // A program that was changed since it ran (a rebuild does that) is said, not refused.
        let folder = scratch(self, "changed"), program = folder.appendingPathComponent("server").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: program))
        chmod(program, 0o755)
        let real = try XCTUnwrap(Restart.launch(exec: program, path: program, arguments: ["server"], environment: [], folder: folder.path))
        XCTAssertNotNil(real.stamp)
        XCTAssertFalse(Restart.changed(real))
        XCTAssertFalse(Restart.question(entry(4321, launch: real)).contains("This program changed"))
        try FileManager.default.removeItem(atPath: program)                                 // a new file under the old name, with other contents
        try Data("#!/bin/sh\necho replaced\nexit 0\n".utf8).write(to: URL(fileURLWithPath: program))
        chmod(program, 0o755)
        XCTAssertTrue(Restart.changed(real))
        XCTAssertEqual(Restart.question(entry(4321, launch: real)).components(separatedBy: "\n").last, "This program changed since it stopped.")
        XCTAssertNil(Restart.problem(real))
        // Each of the four things that are kept says so on its own.
        let was = try XCTUnwrap(real.stamp), now = try XCTUnwrap(Restart.stamp(program))
        for other in [Restart.Stamp(device: now.device + 1, inode: now.inode, modified: now.modified, modifiedNanos: now.modifiedNanos, size: now.size),
                      Restart.Stamp(device: now.device, inode: now.inode + 1, modified: now.modified, modifiedNanos: now.modifiedNanos, size: now.size),
                      Restart.Stamp(device: now.device, inode: now.inode, modified: now.modified + 1, modifiedNanos: now.modifiedNanos, size: now.size),
                      Restart.Stamp(device: now.device, inode: now.inode, modified: now.modified, modifiedNanos: now.modifiedNanos + 1, size: now.size),
                      Restart.Stamp(device: now.device, inode: now.inode, modified: now.modified, modifiedNanos: now.modifiedNanos, size: now.size + 1)] {
            var same = real
            same.stamp = other
            XCTAssertTrue(Restart.changed(same))
        }
        var same = real
        same.stamp = now
        XCTAssertFalse(Restart.changed(same))
        XCTAssertNotEqual(was, now)
    }

    /// The environment a server ran with is in harbor's memory and nowhere else: not in what
    /// the page is told, not in the note for the command line, not in the settings.
    @MainActor
    func testNothingOfItIsWrittenAnywhere() throws {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared
        let secret = "s3cr3t-\(Lan.token(8))", folder = scratch(self, "note")
        let stopped = entry(4321, at: Date(), id: "the-id", name: "shop", launch: launch(arguments: ["node", "server.js"], environment: ["API_KEY": secret, "TOKEN_\(secret)": "1", "PATH": "/usr/bin", "NODE_OPTIONS": "--require \(secret)"]))
        m.useStopped([stopped])
        defer { m.useStopped([]) }
        // What the page is told: the entry's id, its name, port, folder and command as text.
        var raw = Data()
        WebAPI.state { raw = $0 }
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("API_KEY"))
        let told = (((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["stopped"] as? [[String: Any]])?.first
        XCTAssertEqual(Set((told ?? [:]).keys), ["id", "name", "port", "folder", "command", "question", "ago", "note", "log"])
        XCTAssertEqual((told?["question"] as? String)?.contains("able to make it load code: NODE_OPTIONS."), true)      // a name, never its value
        XCTAssertEqual(told?["id"] as? String, "the-id")
        XCTAssertEqual(told?["command"] as? String, "node server.js")
        XCTAssertEqual(told?["folder"] as? String, "/Users/sam/code/storefront")
        // The note the command line reads, and harbor's settings.
        setenv("HARBOR_SHARED_FILE", folder.appendingPathComponent("shared").path, 1)
        defer { unsetenv("HARBOR_SHARED_FILE") }
        m.sharesChanged()
        let note = try String(contentsOf: folder.appendingPathComponent("shared"), encoding: .utf8)
        XCTAssertFalse(note.contains(secret) || note.contains("API_KEY") || note.contains("server.js") || note.contains("the-id"))
        DebugCLI.defaults.synchronize()
        XCTAssertFalse("\(DebugCLI.defaults.dictionaryRepresentation())".contains(secret))
        XCTAssertFalse("\(UserDefaults.standard.dictionaryRepresentation())".contains(secret))
        // And the only file in the folder is the note: nothing was put beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["shared"])
    }

    /// A request names an entry, and that is all it can say: no command, path or argument
    /// is ever read from it.
    @MainActor
    func testARequestNamesAnEntryAndNothingElse() throws {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared, logs = scratch(self, "logs")
        m.useStopped([entry(4321, at: Date(), id: "real-id", name: "shop")])
        defer { m.useStopped([]) }
        func ask(_ json: String) -> (Int, [String: Any]) {
            var answer: (Int, [String: Any]) = (0, [:])
            WebAPI.action(Data(json.utf8)) { answer = ($0, $1) }
            return answer
        }
        // A made-up id, no id, an id that isn't text, and one from before harbor was started again (the list is new then).
        for body in ["{\"op\":\"start-again\",\"id\":\"made-up\"}", "{\"op\":\"start-again\"}", "{\"op\":\"start-again\",\"id\":4321}", "{\"op\":\"start-again\",\"id\":\"\"}",
                     "{\"op\":\"start-again\",\"id\":\"../real-id\"}", "{\"op\":\"start-again\",\"port\":4321,\"command\":\"/bin/sh -c id\",\"executable\":\"/bin/sh\",\"arguments\":[\"-c\",\"id\"]}"] {
            let answer = ask(body)
            XCTAssertEqual(answer.0, 400, body)
            XCTAssertNotNil(answer.1["error"], body)
        }
        XCTAssertEqual(m.startAgain("made-up", logs: logs).message, "That server isn't in the list any more.")
        m.useStopped([])
        XCTAssertFalse(m.startAgain("real-id", logs: logs).started)
        XCTAssertEqual(ask("{\"op\":\"start-again\",\"id\":\"real-id\"}").0, 400)
        // A log is shown for an entry that has one, by its id; on the made-up Mac nothing is opened at all.
        XCTAssertEqual(ask("{\"op\":\"show-log\",\"id\":\"made-up\"}").0, 400)
        XCTAssertEqual(ask("{\"op\":\"show-log\",\"path\":\"/etc/hosts\"}").0, 400)
        m.useStopped([Restart.Stopped(id: "with-log", name: "shop", port: 4321, launch: launch(), at: Date(), log: URL(fileURLWithPath: "/Users/sam/Library/Logs/harbor/shop-4321.log"))])
        XCTAssertEqual(ask("{\"op\":\"show-log\",\"id\":\"with-log\"}").0, 400)
        m.useStopped([])
        // Nothing was started by any of it: no log was even opened.
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? [], [])

        // And the request has to be the owner's own page's: a session (both halves), a POST, and harbor's own header.
        let token = "tok-5f1d9c7a02", key = "key-a81e3b64d9"
        let server = WebServer(session: token, originKey: key, port: 8470) {}
        func routed(_ method: String, _ headers: [String: String], host: String = "harbor.localhost:8470") -> WebServer.Routed {
            let body = "{\"op\":\"start-again\",\"id\":\"real-id\"}"
            var all = headers
            all["Content-Type"] = "application/json"
            all["Content-Length"] = String(body.utf8.count)
            let head = ["\(method) /api/action HTTP/1.1", "Host: \(host)"] + all.map { "\($0): \($1)" }
            guard case .complete(let request) = HTTPRequest.parse(Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)) else { fatalError() }
            return server.route(request)
        }
        func isAction(_ routed: WebServer.Routed) -> Bool { if case .action = routed { return true } else { return false } }
        let session = ["Cookie": "\(WebServer.cookie)=\(token)", "X-Harbor-Key": key], own = ["X-Harbor": "1", "Sec-Fetch-Site": "same-origin", "Origin": "http://harbor.localhost:8470"]
        XCTAssertTrue(isAction(routed("POST", session.merging(own) { a, _ in a })))
        XCTAssertFalse(isAction(routed("GET", session.merging(own) { a, _ in a })))                               // not a POST
        XCTAssertFalse(isAction(routed("POST", session)))                                                         // without harbor's own header
        XCTAssertFalse(isAction(routed("POST", own)))                                                             // no session at all
        XCTAssertFalse(isAction(routed("POST", ["Cookie": "\(WebServer.cookie)=\(token)"].merging(own) { a, _ in a })))    // half a session
        XCTAssertFalse(isAction(routed("POST", ["X-Harbor-Key": key].merging(own) { a, _ in a })))
        XCTAssertFalse(isAction(routed("POST", ["Cookie": "\(Lan.cookie)=\(token)", "X-Harbor-Key": key].merging(own) { a, _ in a })))   // a network visitor's cookie is no session here
        XCTAssertFalse(isAction(routed("POST", session.merging(["X-Harbor": "1", "Origin": "http://storefront.local"]) { a, _ in a })))   // from another page
        XCTAssertFalse(isAction(routed("POST", session.merging(own) { a, _ in a }, host: "storefront.local")))    // and never under a shared name
        // The network listener has nothing of harbor's own behind it: this path, there, is just a path of the project's.
        XCTAssertEqual(Gate.step(method: "POST", target: "/api/action", protected: true, session: false), .signIn)
        XCTAssertEqual(Gate.step(method: "POST", target: "/api/action", protected: false, session: false), .forward)
    }

    /// The day is up whether or not harbor happens to scan: a timer is set for the oldest
    /// entry's moment, and an entry past its day can't be started in the meantime either.
    @MainActor
    func testTheDayIsUpWithoutAScan() {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared, now = Date()
        defer { m.useStopped([]) }
        XCTAssertNil(m.forgetsAt)
        let old = now.addingTimeInterval(-Restart.life + 600), newer = now.addingTimeInterval(-60)
        m.useStopped([entry(4322, at: newer, id: "newer"), entry(4321, at: old, id: "old")])
        XCTAssertEqual(m.forgetsAt?.timeIntervalSince(now) ?? 0, 600, accuracy: 1)
        m.forgetOld(now: now.addingTimeInterval(599))
        XCTAssertEqual(m.stopped.map(\.id), ["newer", "old"])
        m.forgetOld(now: now.addingTimeInterval(600))
        XCTAssertEqual(m.stopped.map(\.id), ["newer"])
        XCTAssertEqual(m.forgetsAt?.timeIntervalSince(now) ?? 0, Restart.life - 60, accuracy: 1)   // and now for the next one
        // Past its day and still there (the timer hasn't fired yet): not started, and nothing is opened for it.
        let logs = scratch(self, "late")
        m.useStopped([entry(4321, at: now.addingTimeInterval(-Restart.life - 1), id: "late")])
        XCTAssertEqual(m.startAgain("late", logs: logs, portAnswers: { _ in false }).message, "That server isn't in the list any more.")
        m.useStopped([])
        XCTAssertNil(m.forgetsAt)
    }

    @MainActor
    func testAPortThatIsTakenIsNotStartedOn() {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared, logs = scratch(self, "taken")
        defer { m.useStopped([]) }
        // Something harbor lists is on that port (the made-up :3000)…
        m.useStopped([entry(3000, at: Date(), id: "a"), entry(4321, at: Date(), id: "b")])
        var done = m.startAgain("a", logs: logs, portAnswers: { _ in false })
        XCTAssertFalse(done.started)
        XCTAssertEqual(done.message, "Something is already listening on :3000, so nothing was started.")
        // …or something harbor can't list answers there (another user's server).
        done = m.startAgain("b", logs: logs, portAnswers: { $0 == 4321 })
        XCTAssertFalse(done.started)
        XCTAssertEqual(done.message, "Something is already listening on :4321, so nothing was started.")
        // And on the made-up Mac nothing is started at all, free port or not.
        XCTAssertEqual(m.startAgain("b", logs: logs, portAnswers: { _ in false }).message, "These ports are made up, so nothing was started.")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? [], [])
        // What "answers" means: a real listener on loopback does, a port nobody has doesn't.
        let listener = OnNetwork.bind(0, on: "127.0.0.1")
        defer { if let listener { close(listener.fd) } }
        XCTAssertEqual(listener.map { Monitor.answers($0.port) }, true)
        XCTAssertFalse(Monitor.answers(1))
    }

    func testWhatIsOnDiskHasToBeWhatWasThere() throws {
        let folder = scratch(self, "disk")
        let program = folder.appendingPathComponent("server").path, work = folder.appendingPathComponent("work").path, other = folder.appendingPathComponent("other").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: program))
        try Data("#!/bin/sh\necho other\n".utf8).write(to: URL(fileURLWithPath: other))
        chmod(program, 0o755)
        chmod(other, 0o755)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let started = try XCTUnwrap(Restart.launch(exec: program, path: program, arguments: ["server"], environment: [], folder: work))
        XCTAssertNil(Restart.problem(started))
        let gone = "The program it ran isn't where it was any more, so it wasn't started."
        let moved = "Its folder isn't where it was any more, so it wasn't started."
        func put(_ change: () throws -> Void, expect: String?, _ what: String) rethrows {
            try change()
            XCTAssertEqual(Restart.problem(started), expect, what)
        }
        // The program: gone; a folder in its place; not runnable; a link in its place, to another file or to the very same one.
        try put({ try FileManager.default.moveItem(atPath: program, toPath: program + ".kept") }, expect: gone, "gone")
        try put({ try FileManager.default.createDirectory(atPath: program, withIntermediateDirectories: false) }, expect: gone, "a folder")
        try put({ try FileManager.default.removeItem(atPath: program); _ = symlink(other, program) }, expect: gone, "a link to another file")
        try put({ try FileManager.default.removeItem(atPath: program); _ = symlink(program + ".kept", program) }, expect: gone, "a link that wasn't there before")
        try put({ try FileManager.default.removeItem(atPath: program); try FileManager.default.moveItem(atPath: program + ".kept", toPath: program); chmod(program, 0o644) }, expect: gone, "not runnable")
        try put({ chmod(program, 0o755) }, expect: nil, "as it was")
        // Its folder: gone; a file in its place; a link in its place.
        try put({ try FileManager.default.moveItem(atPath: work, toPath: work + ".kept") }, expect: moved, "folder gone")
        try put({ try Data().write(to: URL(fileURLWithPath: work)) }, expect: moved, "a file")
        try put({ try FileManager.default.removeItem(atPath: work); _ = symlink(work + ".kept", work) }, expect: moved, "a link that wasn't there before")
        try put({ try FileManager.default.removeItem(atPath: work); try FileManager.default.moveItem(atPath: work + ".kept", toPath: work) }, expect: nil, "as it was")
        // The folder above them swapped for a link to another one that looks the same: neither is itself a link, and both now are somewhere else.
        let above = folder.appendingPathComponent("site").path, twin = folder.appendingPathComponent("twin").path
        for base in [above, twin] {
            try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: program, toPath: base + "/server")
        }
        let inside = try XCTUnwrap(Restart.launch(exec: above + "/server", path: above + "/server", arguments: ["server"], environment: [], folder: above + "/work"))
        XCTAssertNil(Restart.problem(inside))
        try FileManager.default.moveItem(atPath: above, toPath: above + ".kept")
        XCTAssertEqual(symlink(twin, above), 0)
        XCTAssertEqual(Restart.problem(inside), gone)
        let onlyFolder = Restart.Launch(executable: program, resolved: program, arguments: ["server"], environment: [:], folder: inside.folder, folderResolved: inside.folderResolved)
        XCTAssertEqual(Restart.problem(onlyFolder), moved)
        // A link that was there when it ran (a virtualenv's python) is fine for as long as it leads where it led.
        let link = folder.appendingPathComponent("python").path
        XCTAssertEqual(symlink(program, link), 0)
        let through = try XCTUnwrap(Restart.launch(exec: link, path: program, arguments: ["python"], environment: [], folder: work))
        XCTAssertEqual(through.executable, link)                                        // run as the link it was run as
        XCTAssertEqual(through.resolved, program)
        XCTAssertNil(Restart.problem(through))
        try FileManager.default.removeItem(atPath: link)
        XCTAssertEqual(symlink(other, link), 0)
        XCTAssertEqual(Restart.problem(through), gone)
        // And nothing is started when it isn't: no process, no log.
        let log = folder.appendingPathComponent("logs/x.log")
        XCTAssertNil(Restart.start(through, log: log).process)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    /// One real start: a small script of this test's own, run from the remembered array.
    func testStartingAgainForReal() throws {
        let folder = scratch(self, "start"), work = folder.appendingPathComponent("work dir").path, script = folder.appendingPathComponent("server.sh").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        // It says what it was given, each on a line of its own, and stays for a moment.
        try Data("#!/bin/sh\necho \"count:$#\"\necho \"one:$1\"\necho \"two:$2\"\necho \"three:$3\"\necho \"cwd:$(pwd)\"\necho \"kept:$HARBOR_TEST_VALUE\"\necho \"path:$PATH\"\necho \"home:${HOME:-none}\"\necho oops >&2\n".utf8)
            .write(to: URL(fileURLWithPath: script))
        chmod(script, 0o755)
        let secret = "s3cr3t-\(Lan.token(6))"
        let arguments = [script, "--port", "two words; $(id) `id` $HOME", "*"]
        let started = try XCTUnwrap(Restart.launch(exec: script, path: script, arguments: arguments, environment: ["HARBOR_TEST_VALUE=kept 'as' it \"was\"", "PATH=/usr/bin:/bin", "QUIET_\(secret)=1"], folder: work))
        let logs = folder.appendingPathComponent("Logs/harbor"), log = Restart.logURL(name: "shop", port: 4321, in: logs)
        XCTAssertEqual(log.lastPathComponent, "shop-4321.log")
        XCTAssertEqual(Restart.logURL(name: "../../etc/x y", port: 80, in: logs).lastPathComponent, "server-80.log")   // only one of harbor's own labels is ever part of a file's name
        func run() throws -> String {
            let done = Restart.start(started, log: log)
            XCTAssertNil(done.problem)
            let process = try XCTUnwrap(done.process)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try String(contentsOf: log, encoding: .utf8)
        }
        let said = try run().components(separatedBy: "\n")
        // argv arrived as the array it was: nothing was split, expanded or run on the way (no shell had it).
        XCTAssertEqual(said.first { $0.hasPrefix("count:") }, "count:3")
        XCTAssertEqual(said.first { $0.hasPrefix("one:") }, "one:--port")
        XCTAssertEqual(said.first { $0.hasPrefix("two:") }, "two:two words; $(id) `id` $HOME")
        XCTAssertEqual(said.first { $0.hasPrefix("three:") }, "three:*")
        // Its folder, and its environment: what it had, and nothing of harbor's own added to it.
        XCTAssertEqual(said.first { $0.hasPrefix("cwd:") }, "cwd:\(work)")
        XCTAssertEqual(said.first { $0.hasPrefix("kept:") }, "kept:kept 'as' it \"was\"")
        XCTAssertEqual(said.first { $0.hasPrefix("path:") }, "path:/usr/bin:/bin")
        XCTAssertEqual(said.first { $0.hasPrefix("home:") }, "home:none")
        XCTAssertTrue(said.contains("oops"), "what it says on stderr is in the log too")
        // The log: this account's alone, in a folder that is this account's alone, and it holds what the server
        // said, not what harbor knows about it.
        XCTAssertEqual(mode(log.path), 0o600)
        XCTAssertEqual(mode(logs.path), 0o700)
        XCTAssertFalse(said.joined().contains(secret))
        // Started afresh each time, and a log that was left wider is narrowed.
        chmod(log.path, 0o644)
        let second = try run()
        XCTAssertEqual(second.components(separatedBy: "count:3").count, 2)
        XCTAssertEqual(mode(log.path), 0o600)
        // A link put where the log goes isn't followed: it is taken away, and the log is a new file of its own.
        try FileManager.default.removeItem(at: log)
        let elsewhere = folder.appendingPathComponent("elsewhere")
        try Data("untouched".utf8).write(to: elsewhere)
        XCTAssertEqual(symlink(elsewhere.path, log.path), 0)
        XCTAssertTrue(try run().contains("count:3"))
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "untouched")
        var info = stat()
        XCTAssertEqual(lstat(log.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
    }

    /// Where the log goes can't be pointed at something else of this user's.
    func testTheLogCantBePointedElsewhere() throws {
        let folder = scratch(self, "loglink"), victim = folder.appendingPathComponent("victim"), logs = folder.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        chmod(victim.path, 0o755)
        // The log folder is a link to another folder: refused, and that folder is as it was (not narrowed, nothing put in it).
        XCTAssertEqual(symlink(victim.path, logs.appendingPathComponent("harbor").path), 0)
        XCTAssertNil(Restart.openLog(Restart.logURL(name: "shop", port: 4321, in: logs.appendingPathComponent("harbor"))))
        XCTAssertEqual(mode(victim.path), 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: victim.path), [])
        // A folder that is somebody else's: refused, and nothing is put in it.
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("theirs"), withIntermediateDirectories: true)
        XCTAssertNil(Restart.openLog(logs.appendingPathComponent("theirs/shop-1.log"), owner: getuid() &+ 1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: logs.appendingPathComponent("theirs").path), [])
        // Where the log folder should be there is a file: refused.
        try Data().write(to: logs.appendingPathComponent("afile"))
        XCTAssertNil(Restart.openLog(logs.appendingPathComponent("afile/shop-1.log")))
        // A second name for another file of this user's, put where the log goes: the log is a new file, and the other one keeps what it had.
        let real = logs.appendingPathComponent("harbor2"), precious = folder.appendingPathComponent("precious"), log = real.appendingPathComponent("shop-4322.log")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        chmod(real.path, 0o755)
        try Data("precious contents".utf8).write(to: precious)
        XCTAssertEqual(link(precious.path, log.path), 0)
        let fd = try XCTUnwrap(Restart.openLog(log))
        _ = write(fd, "x", 1)
        close(fd)
        XCTAssertEqual(try String(contentsOf: precious, encoding: .utf8), "precious contents")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "x")
        XCTAssertEqual(mode(log.path), 0o600)
        XCTAssertEqual(mode(real.path), 0o700)          // a folder that was there already is narrowed, by the open folder itself
    }

    /// Who else could change the program or its folder: every step from it up to "/" is looked at.
    func testWhoElseCouldChangeIt() throws {
        typealias Step = (owner: uid_t, group: gid_t, mode: mode_t)
        let me: uid_t = 501, other: uid_t = 502, admin: gid_t = 80, wheel: gid_t = 0, staff: gid_t = 20
        let dir = S_IFDIR, file = S_IFREG, link = S_IFLNK
        func walk(_ path: String, _ steps: [String: Step]) -> String? { Restart.loose(path, me: me, look: { steps[$0] }) }
        let root: [String: Step] = ["/": (0, wheel, dir | 0o755), "/opt": (0, wheel, dir | 0o755), "/usr": (0, wheel, dir | 0o755), "/Users": (0, admin, dir | 0o755),
                                    "/Users/sam": (me, staff, dir | 0o750), "/Users/sam/code": (me, staff, dir | 0o755), "/private": (0, wheel, dir | 0o755), "/private/tmp": (0, wheel, dir | 0o1777)]
        // Homebrew on Apple Silicon: this user's, with admin as its group (some of it writable by admin).
        let silicon = root.merging(["/opt/homebrew": (me, admin, dir | 0o755), "/opt/homebrew/bin": (me, admin, dir | 0o775), "/opt/homebrew/bin/node": (me, admin, link | 0o755),
                                    "/opt/homebrew/Cellar": (me, admin, dir | 0o775), "/opt/homebrew/Cellar/node": (me, admin, dir | 0o755), "/opt/homebrew/Cellar/node/22.9.0": (me, admin, dir | 0o755),
                                    "/opt/homebrew/Cellar/node/22.9.0/bin": (me, admin, dir | 0o755), "/opt/homebrew/Cellar/node/22.9.0/bin/node": (me, admin, file | 0o555)]) { a, _ in a }
        XCTAssertNil(walk("/opt/homebrew/bin/node", silicon))
        XCTAssertNil(walk("/opt/homebrew/Cellar/node/22.9.0/bin/node", silicon))
        // Homebrew on Intel: root's /usr/local, with this user's folders in it.
        let intel = root.merging(["/usr/local": (0, wheel, dir | 0o755), "/usr/local/bin": (me, admin, dir | 0o775), "/usr/local/bin/node": (me, admin, link | 0o755),
                                  "/usr/local/Cellar": (me, admin, dir | 0o775), "/usr/local/Cellar/node": (me, admin, dir | 0o755), "/usr/local/Cellar/node/22.9.0": (me, admin, dir | 0o755),
                                  "/usr/local/Cellar/node/22.9.0/bin": (me, admin, dir | 0o755), "/usr/local/Cellar/node/22.9.0/bin/node": (me, admin, file | 0o555)]) { a, _ in a }
        XCTAssertNil(walk("/usr/local/bin/node", intel))
        XCTAssertNil(walk("/usr/local/Cellar/node/22.9.0/bin/node", intel))
        // A project in the home folder; a file of root's; under a folder everyone writes to that keeps each one's files their own (/tmp).
        func project(_ folder: Step, _ program: Step, under: String = "/Users/sam/code") -> String? {
            walk(under + "/app/server", root.merging([under + "/app": folder, under + "/app/server": program]) { a, _ in a })
        }
        XCTAssertNil(project((me, staff, dir | 0o755), (me, staff, file | 0o755)))
        XCTAssertNil(project((0, wheel, dir | 0o755), (0, wheel, file | 0o755)))
        XCTAssertNil(project((me, wheel, dir | 0o700), (me, wheel, file | 0o700), under: "/private/tmp"))
        XCTAssertNil(project((me, admin, dir | 0o775), (me, admin, file | 0o775)))                  // admin may write: an admin can become root anyway
        XCTAssertNil(project((me, wheel, dir | 0o775), (me, wheel, file | 0o775)))
        XCTAssertNil(project((me, wheel, dir | 0o1777), (me, staff, file | 0o755)))                 // everyone may write, each one's files their own
        XCTAssertEqual(project((me, staff, dir | 0o1777), (me, staff, file | 0o755)), "/Users/sam/code/app")     // the rule for a group has no such excuse
        // Another account's: the program, or a folder above it. Root's is fine, anyone else's isn't.
        XCTAssertEqual(project((me, staff, dir | 0o755), (other, staff, file | 0o755)), "/Users/sam/code/app/server")
        XCTAssertEqual(project((other, staff, dir | 0o755), (me, staff, file | 0o755)), "/Users/sam/code/app")
        // Everyone may write: the folder (a file in it can be swapped), or the program itself. The sticky bit excuses a folder, never a file.
        XCTAssertEqual(project((me, staff, dir | 0o777), (me, staff, file | 0o755)), "/Users/sam/code/app")
        XCTAssertEqual(project((me, staff, dir | 0o757), (me, staff, file | 0o755)), "/Users/sam/code/app")
        XCTAssertEqual(project((me, staff, dir | 0o755), (me, staff, file | 0o757)), "/Users/sam/code/app/server")
        XCTAssertEqual(project((me, staff, dir | 0o755), (me, staff, file | 0o1757)), "/Users/sam/code/app/server")
        // staff may write: staff is every account on this Mac. So may any group that isn't admin or wheel.
        XCTAssertEqual(project((me, staff, dir | 0o775), (me, staff, file | 0o755)), "/Users/sam/code/app")
        XCTAssertEqual(project((me, staff, dir | 0o755), (me, staff, file | 0o775)), "/Users/sam/code/app/server")
        XCTAssertEqual(project((me, 12, dir | 0o770), (me, staff, file | 0o755)), "/Users/sam/code/app")
        // A folder further up, and a step that can't be looked at.
        XCTAssertEqual(walk("/Users/sam/code/app/server", root.merging(["/Users/sam/code": (me, staff, dir | 0o777), "/Users/sam/code/app": (me, staff, dir | 0o755), "/Users/sam/code/app/server": (me, staff, file | 0o755)]) { _, b in b }), "/Users/sam/code")
        XCTAssertEqual(walk("/Users/sam/code/app/server", root.merging(["/Users/sam/code/app/server": (me, staff, file | 0o755)]) { a, _ in a }), "/Users/sam/code/app")
        // A link: its own permissions mean nothing (they are often wide open); whose it is still counts.
        XCTAssertNil(project((me, staff, dir | 0o755), (me, staff, link | 0o777)))
        XCTAssertEqual(project((me, staff, dir | 0o755), (other, staff, link | 0o755)), "/Users/sam/code/app/server")

        // For real, the way it was shown: a folder everyone may write to. The program in it is where it was, and still isn't started.
        let folder = scratch(self, "loose"), open = folder.appendingPathComponent("open"), shut = folder.appendingPathComponent("shut")
        for place in [open, shut] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: place.appendingPathComponent("server"))
            chmod(place.appendingPathComponent("server").path, 0o755)
        }
        chmod(open.path, 0o777)
        chmod(shut.path, 0o755)
        func started(_ program: URL, in work: URL) throws -> Restart.Launch {
            try XCTUnwrap(Restart.launch(exec: program.path, path: program.path, arguments: ["server"], environment: [], folder: work.path))
        }
        XCTAssertNil(Restart.problem(try started(shut.appendingPathComponent("server"), in: shut)))
        let inOpen = try started(open.appendingPathComponent("server"), in: shut)
        XCTAssertEqual(Restart.problem(inOpen), "Another account on this Mac could change \(Fmt.path(open.path)), so it wasn't started from there.")
        let done = Restart.start(inOpen, log: folder.appendingPathComponent("logs/x.log"))
        XCTAssertNil(done.process)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("logs/x.log").path))
        // The same for the folder it runs in, and for a program everyone may write to.
        XCTAssertEqual(Restart.problem(try started(shut.appendingPathComponent("server"), in: open)), "Another account on this Mac could change \(Fmt.path(open.path)), so it wasn't started from there.")
        chmod(shut.appendingPathComponent("server").path, 0o757)
        XCTAssertEqual(Restart.problem(try started(shut.appendingPathComponent("server"), in: shut))?.contains("/shut/server"), true)
    }

    /// One start at a time: while the process harbor started for an entry is alive, a second
    /// request (a second click, three at once from a page) starts nothing.
    @MainActor
    func testOneStartAtATime() throws {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared, folder = scratch(self, "once"), script = folder.appendingPathComponent("server.sh").path, logs = folder.appendingPathComponent("logs")
        try Data("#!/bin/sh\necho started >> \"$PWD/starts\"\nsleep 20\n".utf8).write(to: URL(fileURLWithPath: script))
        chmod(script, 0o755)
        let real = try XCTUnwrap(Restart.launch(exec: script, path: script, arguments: [script], environment: ["PATH=/usr/bin:/bin"], folder: folder.path))
        m.useStopped([entry(43991, at: Date(), id: "one", name: "shop", launch: real)])
        defer { m.stopped.compactMap(\.pid).forEach { kill($0, SIGKILL) }; m.useStopped([]) }
        func ask() -> (started: Bool, message: String) { m.startAgain("one", logs: logs, portAnswers: { _ in false }, madeUp: false) }
        let first = ask()
        XCTAssertTrue(first.started, first.message)
        let pid = try XCTUnwrap(m.stopped.first?.pid)
        let second = ask(), third = ask()
        XCTAssertFalse(second.started || third.started)
        XCTAssertEqual(second.message, "shop was just started (pid \(pid)). Give it a moment to listen.")
        // It says so once it runs (a moment, longer on a busy Mac); and once is how often it was started.
        let starts = folder.appendingPathComponent("starts").path, patience = Date().addingTimeInterval(10)
        while (try? String(contentsOfFile: starts, encoding: .utf8)) == nil, Date() < patience { usleep(50_000) }
        usleep(400_000)
        XCTAssertEqual(try? String(contentsOfFile: starts, encoding: .utf8), "started\n")
        // When that process has ended (it never listened), the entry can be tried again.
        kill(pid, SIGKILL)
        let until = Date().addingTimeInterval(5)
        while m.stopped.first?.pid != nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNil(m.stopped.first?.pid)
        XCTAssertTrue(ask().started)
        // An entry whose process is long gone (a pid that is nobody's) isn't held back by it.
        m.stopped.compactMap(\.pid).forEach { kill($0, SIGKILL) }
        var stale = entry(43992, at: Date(), id: "stale", name: "shop", launch: real)
        stale.pid = 999_999
        m.useStopped([stale])
        XCTAssertEqual(m.startAgain("stale", logs: logs, portAnswers: { _ in false }).message, "These ports are made up, so nothing was started.")
    }

    /// How a server was started is kept for that process: the same pid on the same port,
    /// started at another time, is another server and is read again.
    @MainActor
    func testAPidAndPortThatComeRoundAgain() {
        let m = Monitor.shared
        m.remember([], may: { _ in true }, capture: { _ in nil })
        m.useStopped([])
        defer { m.remember([], may: { _ in true }, capture: { _ in nil }); m.useStopped([]) }
        let a = launch(arguments: ["node", "a.js"]), b = launch(arguments: ["node", "b.js"])
        let first = row(4555, pid: 4999, started: t0), second = row(4555, pid: 4999, started: t0.addingTimeInterval(60))
        XCTAssertEqual(first.id, second.id)
        var read: [Date?] = []
        m.remember([first], may: { _ in true }, capture: { read.append($0.started); return a })
        m.remember([first], may: { _ in true }, capture: { read.append($0.started); return a })
        XCTAssertEqual(read, [t0])                                                          // once per server
        m.remember([second], may: { _ in true }, capture: { read.append($0.started); return b })
        XCTAssertEqual(read, [t0, t0.addingTimeInterval(60)])                               // another server: read again
        XCTAssertEqual(m.stopped.map(\.port), [])                                           // its port is listening
        m.remember([], may: { _ in true }, capture: { _ in nil })
        XCTAssertEqual(m.stopped.map(\.launch), [b])                                        // what stopped is the second one, as the second one was started
        // What may not be remembered is never read, and never listed.
        m.useStopped([])
        m.remember([row(4556, pid: 5000)], may: { _ in false }, capture: { _ in XCTFail("read though it may not be remembered"); return a })
        m.remember([], may: { _ in true }, capture: { _ in nil })
        XCTAssertEqual(m.stopped.map(\.port), [])
    }

    func testALogIsKeptSmall() throws {
        let folder = scratch(self, "log"), log = folder.appendingPathComponent("x.log")
        let fd = try XCTUnwrap(Restart.openLog(log))
        defer { close(fd) }
        XCTAssertEqual(Restart.maxLog, 5 << 20)
        let line = [UInt8](repeating: 120, count: 1000)
        _ = write(fd, line, line.count)
        XCTAssertFalse(Restart.trim(fd, limit: 1000))                                       // at the limit: left alone
        XCTAssertEqual(try Data(contentsOf: log).count, 1000)
        _ = write(fd, line, 1)
        XCTAssertTrue(Restart.trim(fd, limit: 1000))                                        // past it: emptied, and it says so
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "(harbor emptied this log when it passed 0 MB)\n")
        // The server goes on writing at the end of what is there (it never writes over the note, or leaves a hole).
        _ = write(fd, line, 10)
        XCTAssertEqual(try Data(contentsOf: log).count, 46 + 10)
        // And harbor does this by itself when the file grows.
        let keeper = Restart.keepSmall(dup(fd), limit: 2000)
        defer { keeper.cancel() }
        for _ in 0..<5 { _ = write(fd, line, line.count) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (try? Data(contentsOf: log).count) ?? 0 > 2000 { usleep(20_000) }
        XCTAssertLessThanOrEqual(try Data(contentsOf: log).count, 2000)
    }
}

// MARK: - C. Update now

final class UpdaterTests: XCTestCase {
    /// Three small apps, signed ad-hoc once for the whole class: `a` (the release), `b` (the
    /// same app from another build, so another signature) and `other` (another app).
    private struct Apps {
        let root: URL
        let a: URL, b: URL, other: URL, nested: URL, named: URL
        let requirementA: SecRequirement, requirementOther: SecRequirement, requirementNested: SecRequirement
    }

    private static func make(_ folder: URL, id: String = "local.harbor", version: String, salt: String) throws -> URL {
        let app = folder.appendingPathComponent("harbor.app"), macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Harbor", "CFBundleShortVersionString": version, "CFBundleName": "harbor", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\n# \(salt)\nexit 0\n".utf8).write(to: macos.appendingPathComponent("Harbor"))
        chmod(macos.appendingPathComponent("Harbor").path, 0o755)
        return app
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func requirement(of app: URL) -> SecRequirement? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static let apps: Apps? = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-apps-\(Lan.token(4))")
        guard let a = try? make(root.appendingPathComponent("a"), version: "9.9.9", salt: "a"), let b = try? make(root.appendingPathComponent("b"), version: "9.9.9", salt: "b"),
              let other = try? make(root.appendingPathComponent("other"), id: "local.other", version: "9.9.9", salt: "other") else { return nil }
        // One more with a helper app inside it (code nested in code): the helper is signed first, then the app around it.
        guard let nested = try? make(root.appendingPathComponent("nested"), version: "9.9.9", salt: "nested") else { return nil }
        let helper = nested.appendingPathComponent("Contents/Helpers/helper.app"), helperBinary = helper.appendingPathComponent("Contents/MacOS/Helper")
        let helperInfo: [String: Any] = ["CFBundleIdentifier": "local.harbor.helper", "CFBundleExecutable": "Helper", "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL"]
        guard (try? FileManager.default.createDirectory(at: helperBinary.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              (try? PropertyListSerialization.data(fromPropertyList: helperInfo, format: .xml, options: 0).write(to: helper.appendingPathComponent("Contents/Info.plist"))) != nil,
              (try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperBinary)) != nil else { return nil }
        chmod(helperBinary.path, 0o755)
        // Ad-hoc, once each: never with a real identity.
        for app in [a, b, other, helper, nested] where run("/usr/bin/codesign", ["--force", "-s", "-", app.path]) != 0 { return nil }
        // And one whose requirement was written by hand to be nothing but a name, with "anchor" and "certificate" in it.
        guard let named = try? make(root.appendingPathComponent("named"), id: "local.anchor.certificate", version: "9.9.9", salt: "named"),
              run("/usr/bin/codesign", ["--force", "-s", "-", "-r=designated => identifier \"local.anchor.certificate\"", named.path]) == 0 else { return nil }
        guard let requirementA = requirement(of: a), let requirementOther = requirement(of: other), let requirementNested = requirement(of: nested) else { return nil }
        return Apps(root: root, a: a, b: b, other: other, nested: nested, named: named, requirementA: requirementA, requirementOther: requirementOther, requirementNested: requirementNested)
    }()

    override class func tearDown() {
        if let apps { try? FileManager.default.removeItem(at: apps.root) }
        if let compiled { try? FileManager.default.removeItem(at: compiled.root) }
        super.tearDown()
    }

    private func zip(_ app: URL, in folder: URL, name: String = "release.zip") throws -> Data {
        let file = folder.appendingPathComponent(name)
        XCTAssertEqual(Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, file.path]), 0)
        return try Data(contentsOf: file)
    }

    /// A zip with exactly these entries and nothing in them (stored, no compression): for the names a real tool wouldn't write.
    private func crafted(_ entries: [(name: String, mode: UInt32)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var local: [UInt8] = [], central: [UInt8] = []
        for entry in entries {
            let name = Array(entry.name.utf8), offset = UInt32(local.count)
            local += [0x50, 0x4B, 3, 4] + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + le32(0) + le16(name.count) + le16(0) + name
            central += [0x50, 0x4B, 1, 2] + le16(0x031E) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + le32(0)
                + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(entry.mode << 16) + le32(offset) + name
        }
        let end: [UInt8] = [0x50, 0x4B, 5, 6] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0)
        return Data(local + central + end)
    }

    func testWhenItIsOffered() throws {
        // Signed with a certificate: asked of Security (its flags, its certificates), never read off the wording of a requirement.
        let apps = try XCTUnwrap(Self.apps), folder = scratch(self, "offered")
        XCTAssertFalse(Updater.hasCertificate(try XCTUnwrap(Updater.code(at: apps.a))))                  // ad-hoc
        XCTAssertFalse(Updater.hasCertificate(try XCTUnwrap(Updater.code(at: apps.named))))              // ad-hoc, whatever its requirement says
        var text: CFString?
        var written: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(Updater.code(at: apps.named)), [], &written), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(written), [], &text), errSecSuccess)
        XCTAssertEqual(text as String?, "identifier \"local.anchor.certificate\"")                       // the wording that used to pass
        let plain = try Self.make(folder.appendingPathComponent("plain"), version: "9.9.9", salt: "plain")
        XCTAssertFalse(Updater.code(at: plain).map(Updater.hasCertificate) ?? false)                      // not signed
        XCTAssertTrue(Updater.hasCertificate(try XCTUnwrap(Updater.code(at: URL(fileURLWithPath: "/System/Applications/Calculator.app")))))   // Apple's: certificates, not ad-hoc (only read)
        let app = URL(fileURLWithPath: "/Applications/harbor.app")
        XCTAssertTrue(Updater.mayOffer(bundle: app, certificate: true, installed: true, writable: { $0 == "/Applications" }))
        // Not an app bundle (a bare build); no certificate; a folder this user can't write to; a copy that isn't the
        // installed one (nothing would start the new one for it).
        XCTAssertFalse(Updater.mayOffer(bundle: URL(fileURLWithPath: "/Users/sam/harbor/.build/release"), certificate: true, installed: true, writable: { _ in true }))
        XCTAssertFalse(Updater.mayOffer(bundle: app, certificate: false, installed: true, writable: { _ in true }))
        XCTAssertFalse(Updater.mayOffer(bundle: app, certificate: true, installed: true, writable: { _ in false }))
        XCTAssertFalse(Updater.mayOffer(bundle: app, certificate: true, installed: true, writable: { $0 == "/Applications/harbor.app" }))
        XCTAssertFalse(Updater.mayOffer(bundle: URL(fileURLWithPath: "/Users/sam/Desktop/harbor.app"), certificate: true, installed: false, writable: { _ in true }))
        // "Installed" is the copy in Applications itself. Nothing further in counts: not the old copy an update set aside beside the app.
        for (path, installed) in [("/Applications/harbor.app/Contents/MacOS/Harbor", true), ("/Users/me/Applications/harbor.app/Contents/MacOS/Harbor", true),
                                  ("/Applications/.harbor-update-ab12cd/old/harbor.app/Contents/MacOS/Harbor", false), ("/Applications/Utilities/harbor.app/Contents/MacOS/Harbor", false),
                                  ("/Users/me/Applications/old/harbor.app/Contents/MacOS/Harbor", false), ("/Applications/harbor.app/Contents/Helpers/x.app/Contents/MacOS/x", false),
                                  ("/Applications/Harbor", false), ("/Applications/harbor.app/Contents/Resources/Harbor", false), ("/Applications/harbor/Contents/MacOS/Harbor", false)] {
            XCTAssertEqual(LaunchAgent.isInstalled(path, home: "/Users/me"), installed, path)
        }
        // And a test run is not offered one either.
        XCTAssertFalse(Updater.offered)
        XCTAssertFalse(MainActor.assumeIsolated { Updates.shared.canUpdateNow })
        func asked() -> (Int, String?, String?) {
            var answer: (Int, [String: Any]) = (0, [:])
            MainActor.assumeIsolated { WebAPI.action(Data("{\"op\":\"update-now\"}".utf8)) { answer = ($0, $1) } }
            return (answer.0, answer.1["error"] as? String, answer.1["message"] as? String)
        }
        XCTAssertTrue(asked() == (400, "This copy can't update itself. Use the link.", nil))
        XCTAssertFalse(MainActor.assumeIsolated { Updates.shared.updating })
        // The answer is what was done. Where "Update now" is shown and nothing starts, it says why: never "Updating…".
        MainActor.assumeIsolated {
            Updates.shared.useMadeUp(latest: "99.0")
            defer { Updates.shared.useMadeUp(latest: nil); Monitor.shared.setBusy(4101, false) }
            XCTAssertTrue(Updates.shared.canUpdateNow)
            XCTAssertTrue(asked() == (400, "This release is made up, so nothing is downloaded.", nil))
            XCTAssertFalse(Updates.shared.updating)
            // In the middle of stopping something on the owner's click: the update waits, and says so.
            Monitor.shared.setBusy(4101, true)
            XCTAssertTrue(asked() == (400, "harbor is still stopping something. Try again when that is done.", nil))
            XCTAssertEqual(Updates.shared.updateNow(), "harbor is still stopping something. Try again when that is done.")
            XCTAssertFalse(Updates.shared.updating)
        }
        XCTAssertFalse(MainActor.assumeIsolated { Updates.shared.canUpdateNow })
        // What is asked first says what ends with it.
        XCTAssertFalse(Updates.updateQuestion(version: "1.6.1", sharing: false).contains("ends with the update"))
        XCTAssertTrue(Updates.updateQuestion(version: "1.6.1", sharing: true).hasSuffix("What is on your network, and any public link, ends with the update."))
    }

    /// Made-up ports, a made-up Stopped list and a made-up release are for debug runs. The
    /// real app started with those flags by mistake shows none of them.
    @MainActor
    func testMadeUpThingsOnlyInADebugRun() {
        _ = DebugCLI.handle(["--no-open", "--fixture"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared
        // Whatever this test does, the note for the command line goes to a file of the test's own (never to the installed copy's).
        setenv("HARBOR_SHARED_FILE", scratch(self, "madeup").appendingPathComponent("shared").path, 1)
        m.stopAllSharing()
        m.useStopped([])
        defer { _ = DebugCLI.handle(["--no-open", "--fixture"]); m.stopAllSharing(); m.useStopped([]); Updates.shared.useMadeUp(latest: nil); unsetenv("HARBOR_SHARED_FILE") }
        _ = DebugCLI.handle(["--fixture", "shared", "--stopped", "--update", "99.0"])
        XCTAssertFalse(DebugCLI.isDebugRun)
        for flag in ["--fixture", "--stopped", "--update"] { XCTAssertFalse(DebugCLI.wants(flag), flag) }
        XCTAssertFalse(DebugCLI.afterLaunch())
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertEqual(m.stopped.map(\.id), [])
        XCTAssertFalse(Updates.shared.madeUp)
        // In a debug run they are what they were made for.
        _ = DebugCLI.handle(["--no-open", "--fixture", "shared", "--stopped", "--update", "99.0"])
        for flag in ["--fixture", "--stopped", "--update"] { XCTAssertTrue(DebugCLI.wants(flag), flag) }
        XCTAssertFalse(DebugCLI.wants("--serve"))
        _ = DebugCLI.afterLaunch()
        XCTAssertFalse(m.lanShares.isEmpty)
        XCTAssertEqual(m.stopped.map(\.id), ["demo-docs", "demo-worker"])
        XCTAssertTrue(Updates.shared.madeUp)
    }

    func testADownloadTheNetworkCutsOff() async throws {
        // A campus network resets every connection to GitHub's download server: said in plain words, with what to try.
        let rest = " Some networks block GitHub's downloads; if it keeps happening, try on another network. \(AppInfo.name) is as it was."
        XCTAssertEqual(Updater.cutOff("The network connection was lost.").text, "The download did not arrive: The network connection was lost." + rest)
        XCTAssertEqual(Updater.cutOff("Connection reset by peer").text, "The download did not arrive: Connection reset by peer." + rest)
        XCTAssertEqual(Updater.cutOff("").text, "The download did not arrive." + rest)
        // And that is what an update answers when the download throws, with nothing made beside the app.
        let folder = scratch(self, "cut-off"), installed = folder.appendingPathComponent("harbor.app")
        try? FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        var world = Updater.World(requirement: try XCTUnwrap(requirement), bundleID: "local.harbor", running: "1.6.0", handOver: { _ in XCTFail("nothing to hand over to") })
        world.fetch = { _ in throw URLError(.networkConnectionLost) }
        let problem = await Updater.update(to: "1.6.1", installed: installed, world: world)
        XCTAssertEqual(problem?.text.hasPrefix("The download did not arrive: "), true, problem?.text ?? "nil")
        XCTAssertEqual(problem?.text.hasSuffix(rest), true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], ["harbor.app"], "nothing is left beside the app")
    }

    func testWhatIsDownloadedAndFromWhere() async {
        XCTAssertEqual(Updater.asset(appleSilicon: true), "harbor-apple-silicon.zip")
        XCTAssertEqual(Updater.asset(appleSilicon: false), "harbor-intel.zip")
        XCTAssertEqual(Updater.address(version: "1.6.1", file: "harbor-apple-silicon.zip")?.absoluteString, "https://github.com/ips610/harbor/releases/download/v1.6.1/harbor-apple-silicon.zip")
        XCTAssertEqual(Updater.address(version: "2", file: "SHA256SUMS")?.absoluteString, "https://github.com/ips610/harbor/releases/download/v2/SHA256SUMS")
        // A version is digits and dots; a file is one of the three. Anything else has no address.
        for version in ["", "v1.6", "1.6.0/../../x", "1.6.0?x=1", "1.6.0#", "1.6 .0", "1..6", ".1", "1.", "1.6.0-beta", "١.٦", "1.6.0\n", String(repeating: "1", count: 21), "%2e%2e"] {
            XCTAssertNil(Updater.address(version: version, file: "harbor-intel.zip"), version)
        }
        for file in ["", "harbor.zip", "../SHA256SUMS", "harbor-intel.zip/x", "Harbor-intel.zip", "evil.sh"] { XCTAssertNil(Updater.address(version: "1.6.1", file: file), file) }
        // Only https, and only GitHub's own hosts: for where it starts, and for wherever it is sent on to.
        for good in ["https://github.com/ips610/harbor/releases/download/v1.6.1/harbor-intel.zip", "https://objects.githubusercontent.com/x", "https://release-assets.githubusercontent.com/a/b?c=d", "https://GitHub.com/x", "https://github.com:443/x"] {
            XCTAssertTrue(Updater.mayFollow(URL(string: good)), good)
        }
        for bad in ["http://github.com/ips610/harbor", "http://objects.githubusercontent.com/x", "https://github.com.evil.test/x", "https://evilgithub.com/x", "https://evilgithubusercontent.com/x",
                    "https://githubusercontent.com.evil.test/x", "https://example.com/github.com", "https://user:pw@github.com/x", "https://github.com@evil.test/x", "ftp://github.com/x",
                    "file:///etc/passwd", "https://api.github.com/x", "https://raw.github.io/x", "https:///x", "github.com/x",
                    "https://github.com:8443/x", "https://objects.githubusercontent.com:444/x", "https://github.com:80/x", "https://github.com./x"] {
            XCTAssertFalse(Updater.mayFollow(URL(string: bad)), bad)
        }
        XCTAssertFalse(Updater.mayFollow(nil))
        // The download refuses, before anything is sent, an address that isn't https on github.com. (What would
        // send it is this test's own stand-in: nothing here asks GitHub, whatever the rule says.)
        final class Asked: @unchecked Sendable { var urls: [String] = [] }
        let asked = Asked()
        let standIn: Updater.Fetch = { url in asked.urls.append(url.absoluteString); return Data("ok".utf8) }
        for refused in ["http://github.com/ips610/harbor/releases/download/v1.6.1/harbor-intel.zip", "https://example.com/harbor-intel.zip", "https://objects.githubusercontent.com/harbor-intel.zip",
                        "https://github.com.evil.test/ips610/harbor/releases/download/v1.6.1/harbor-intel.zip", "https://user@github.com/ips610/harbor/releases/download/v1.6.1/harbor-intel.zip"] {
            do {
                _ = try await Updater.fetch(URL(string: refused)!, get: standIn)
                XCTFail(refused)
            } catch {
                XCTAssertEqual(error as? Updater.Problem, Updater.Problem("That isn't an address harbor downloads from."), refused)
            }
        }
        XCTAssertEqual(asked.urls, [])
        let good = Updater.address(version: "1.6.1", file: "harbor-intel.zip")!
        let got = try? await Updater.fetch(good, get: standIn)
        XCTAssertEqual(got, Data("ok".utf8))
        XCTAssertEqual(asked.urls, [good.absoluteString])
        XCTAssertEqual(Updater.maxBytes, 30 << 20)
    }

    /// What the download does with a redirect, an answer and the bytes: asked of the real
    /// download's own handlers, with a task that is never started (nothing is sent anywhere).
    func testARedirectAnAnswerAndTheSize() {
        let from = URL(string: "https://github.com/ips610/harbor/releases/download/v1.6.1/harbor-intel.zip")!
        let task = URLSession.shared.dataTask(with: from)
        defer { task.cancel() }
        func answer(_ status: Int, _ url: URL = from, length: Int? = nil) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: length.map { ["Content-Length": String($0)] })!
        }
        // Sent on to GitHub's own storage over https: followed. Anywhere else, or without https: not.
        func followed(_ to: String) -> Bool {
            var next: URLRequest?
            Updater.Fetcher().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: answer(302), newRequest: URLRequest(url: URL(string: to)!)) { next = $0 }
            return next != nil
        }
        XCTAssertTrue(followed("https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=x"))
        XCTAssertFalse(followed("http://release-assets.githubusercontent.com/github-production-release-asset/1/2"))
        XCTAssertFalse(followed("https://example.com/harbor-intel.zip"))
        XCTAssertFalse(followed("https://github.com.evil.test/harbor-intel.zip"))
        XCTAssertFalse(followed("http://github.com/ips610/harbor/releases/download/v1.6.1/harbor-intel.zip"))
        XCTAssertFalse(followed("https://release-assets.githubusercontent.com:8443/github-production-release-asset/1/2"))       // another port on a host of GitHub's
        // The answer: a 200 from one of those hosts, and no larger than a release.
        func taken(_ response: URLResponse, limit: Int = 1000) -> (Bool, String?) {
            let fetcher = Updater.Fetcher(limit: limit)
            var disposition = URLSession.ResponseDisposition.cancel
            fetcher.urlSession(URLSession.shared, dataTask: task, didReceive: response) { disposition = $0 }
            return (disposition == .allow, fetcher.problem?.text)
        }
        let notHanded = "GitHub didn't hand the file over.", tooLarge = "The download is larger than a release ever is, so it was stopped."
        XCTAssertTrue(taken(answer(200, length: 1000)) == (true, nil))
        XCTAssertTrue(taken(answer(200)) == (true, nil))
        XCTAssertTrue(taken(answer(404)) == (false, notHanded))
        XCTAssertTrue(taken(answer(302)) == (false, notHanded))                            // a redirect that wasn't followed ends here
        XCTAssertTrue(taken(answer(200, URL(string: "https://example.com/x")!)) == (false, notHanded))
        XCTAssertTrue(taken(answer(200, URL(string: "http://github.com/x")!)) == (false, notHanded))
        XCTAssertTrue(taken(URLResponse(url: from, mimeType: nil, expectedContentLength: 10, textEncodingName: nil)) == (false, notHanded))
        XCTAssertTrue(taken(answer(200, length: 1001)) == (false, tooLarge))
        // The bytes: an answer that didn't say how long it is (or lied) is stopped once it is past the limit.
        let fetcher = Updater.Fetcher(limit: 1000)
        fetcher.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 600))
        XCTAssertNil(fetcher.problem)
        fetcher.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 400))
        XCTAssertNil(fetcher.problem)
        fetcher.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 1))
        XCTAssertEqual(fetcher.problem?.text, tooLarge)
    }

    /// The new harbor is started apart from this one: a session and a process group of its
    /// own, so it isn't taken down with the harbor that started it.
    func testWhatIsStartedForTheHandOverStandsApart() throws {
        let pid = try XCTUnwrap(Updater.startApart("/bin/sleep", ["30"]))
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertEqual(getsid(pid), pid)
        XCTAssertNotEqual(getpgid(pid), getpgrp())
        XCTAssertNil(Updater.startApart("/no/such/program", []))
    }

    func testTheChecksumList() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "0123456789abcdef", count: 4)
        let sums = "\(a)  harbor-apple-silicon.zip\n\(b)  harbor-intel.zip\n"
        XCTAssertEqual(Updater.sum(for: "harbor-apple-silicon.zip", in: sums), a)
        XCTAssertEqual(Updater.sum(for: "harbor-intel.zip", in: sums), b)
        XCTAssertEqual(Updater.sum(for: "harbor-intel.zip", in: "\(b) *harbor-intel.zip\r\n"), b)
        XCTAssertNil(Updater.sum(for: "harbor-intel.zip", in: "\(a)  harbor-apple-silicon.zip\n"))
        XCTAssertNil(Updater.sum(for: "harbor-intel.zip", in: "abc  harbor-intel.zip\n"))                          // not a sum
        XCTAssertNil(Updater.sum(for: "harbor-intel.zip", in: "\(a.uppercased())  harbor-intel.zip\n"))
        XCTAssertNil(Updater.sum(for: "harbor-intel.zip", in: "\(b)  x/harbor-intel.zip\n"))
        XCTAssertNil(Updater.sum(for: "harbor-intel.zip", in: ""))
        XCTAssertEqual(Updater.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTheShapeOfTheZip() throws {
        let dir: UInt32 = 0o040755, file: UInt32 = 0o100644, link: UInt32 = 0o120777
        func problem(_ entries: [(name: String, mode: UInt32)]) -> String? {
            guard let read = Updater.entries(inZip: crafted(entries)) else { return "unreadable" }
            XCTAssertEqual(read.map(\.name), entries.map(\.name))
            return Updater.zipProblem(read)
        }
        // A release: everything inside harbor.app (and macOS's own side entries, which ditto puts back where they belong).
        XCTAssertNil(problem([("harbor.app/", dir), ("harbor.app/Contents/Info.plist", file), ("harbor.app/Contents/MacOS/Harbor", file)]))
        XCTAssertNil(problem([("harbor.app/Contents/Info.plist", file), ("__MACOSX/harbor.app/._Contents", file), ("harbor.app/Contents/Frameworks/x.framework/Versions/Current", link)]))
        let no = "The download isn't shaped like a release, so it wasn't unpacked."
        // A second thing beside it; a path that climbs out; a path from the root; the app itself as a link; no app at all.
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("install.sh", file)]), no)
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("other.app/Contents/Info.plist", file)]), no)
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("harbor.app/../../Library/LaunchAgents/evil.plist", file)]), no)
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("../harbor.app/x", file)]), no)
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("__MACOSX/../../x", file)]), no)
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("/Applications/harbor.app/Contents/x", file)]), no)
        XCTAssertEqual(problem([("harbor.app/Contents/Info.plist", file), ("harbor.app\\..\\x", file)]), no)
        XCTAssertEqual(problem([("harbor.app", link), ("harbor.app/Contents/Info.plist", file)]), no)
        XCTAssertEqual(problem([("harbor.app/", link), ("harbor.app/Contents/Info.plist", file)]), no)
        XCTAssertEqual(problem([("Harbor.app/Contents/Info.plist", file)]), no)
        XCTAssertEqual(problem([("harbor.app", file)]), no)
        XCTAssertEqual(problem([]), no)
        // Not a zip, or one cut short.
        XCTAssertNil(Updater.entries(inZip: Data("not a zip at all, just some text that is long enough".utf8)))
        XCTAssertNil(Updater.entries(inZip: Data()))
        let whole = crafted([("harbor.app/Contents/Info.plist", file)])
        XCTAssertNil(Updater.entries(inZip: whole.dropLast(30)))
        // And what a real tool writes reads the same way.
        if let apps = Self.apps {
            let real = try XCTUnwrap(Updater.entries(inZip: try zip(apps.a, in: scratch(self, "zip"))))
            XCTAssertTrue(real.contains { $0.name == "harbor.app/Contents/Info.plist" })
            XCTAssertNil(Updater.zipProblem(real))
        }
    }

    func testUnpackingTakesOneRealApp() throws {
        let apps = try XCTUnwrap(Self.apps), folder = scratch(self, "unpack")
        let good = folder.appendingPathComponent("good.zip"), into = folder.appendingPathComponent("new")
        try zip(apps.a, in: folder).write(to: good)
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        guard case .success(let app) = Updater.unpack(good, into: into) else { return XCTFail("a release unpacks") }
        XCTAssertEqual(app.lastPathComponent, "harbor.app")
        XCTAssertEqual(Updater.facts(of: app)?.version, "9.9.9")
        // Two things come out (the zip was made of a folder holding the app and something beside it): not taken.
        let pair = folder.appendingPathComponent("pair")
        try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apps.a, to: pair.appendingPathComponent("harbor.app"))
        try Data("x".utf8).write(to: pair.appendingPathComponent("also.txt"))
        let two = folder.appendingPathComponent("two.zip"), into2 = folder.appendingPathComponent("new2")
        XCTAssertEqual(Self.run("/usr/bin/ditto", ["-c", "-k", pair.path, two.path]), 0)
        try FileManager.default.createDirectory(at: into2, withIntermediateDirectories: true)
        guard case .failure = Updater.unpack(two, into: into2) else { return XCTFail("two things came out") }
        // The one thing that comes out is called harbor.app and is a link to somewhere: not taken.
        let linked = folder.appendingPathComponent("linked"), into5 = folder.appendingPathComponent("new5")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: into5, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(apps.a.path, linked.appendingPathComponent("harbor.app").path), 0)
        XCTAssertEqual(Self.run("/usr/bin/ditto", ["-c", "-k", linked.path, folder.appendingPathComponent("linked.zip").path]), 0)
        guard case .failure = Updater.unpack(folder.appendingPathComponent("linked.zip"), into: into5) else { return XCTFail("the app is a link") }
        // Something that isn't a zip, and a zip with no app in it.
        let into3 = folder.appendingPathComponent("new3"), into4 = folder.appendingPathComponent("new4")
        try FileManager.default.createDirectory(at: into3, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: into4, withIntermediateDirectories: true)
        try Data("nothing".utf8).write(to: folder.appendingPathComponent("bad.zip"))
        guard case .failure = Updater.unpack(folder.appendingPathComponent("bad.zip"), into: into3) else { return XCTFail("not a zip") }
        let only = folder.appendingPathComponent("only")
        try FileManager.default.createDirectory(at: only, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: only.appendingPathComponent("readme.txt"))
        XCTAssertEqual(Self.run("/usr/bin/ditto", ["-c", "-k", only.path, folder.appendingPathComponent("none.zip").path]), 0)
        guard case .failure = Updater.unpack(folder.appendingPathComponent("none.zip"), into: into4) else { return XCTFail("no app") }
    }

    /// A small zip can unpack to anything, and unpacking has no end of its own.
    func testUnpackingIsStoppedWhenItGoesOn() throws {
        let apps = try XCTUnwrap(Self.apps), folder = scratch(self, "large")
        let app = folder.appendingPathComponent("src/harbor.app")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apps.a, to: app)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data(count: 40 << 20).write(to: app.appendingPathComponent("Contents/Resources/nothing.bin"))            // 40 MB of nothing
        let zip = folder.appendingPathComponent("large.zip")
        XCTAssertEqual(Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]), 0)
        XCTAssertLessThan(try Data(contentsOf: zip).count, 1 << 20)                                                   // and well under a megabyte as a zip
        func unpacked(_ name: String, limit: Int64, seconds: Double) throws -> Result<URL, Updater.Problem> {
            let into = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            return Updater.unpack(zip, into: into, limit: limit, seconds: seconds)
        }
        let stopped = Updater.Problem("The download unpacks to more, or for longer, than a release ever does, so it was stopped.")
        // With room and time enough it is the app. More than it may be: refused. Longer than it may take: ended.
        guard case .success = try unpacked("fits", limit: 200 << 20, seconds: 60) else { return XCTFail("it fits") }
        guard case .failure(let large) = try unpacked("large", limit: 4 << 20, seconds: 60) else { return XCTFail("more than the limit came out") }
        XCTAssertEqual(large, stopped)
        guard case .failure(let slow) = try unpacked("slow", limit: 200 << 20, seconds: 0) else { return XCTFail("it took longer than no time") }
        XCTAssertEqual(slow, stopped)
        // The limit is on what the files hold, links not followed.
        let sized = folder.appendingPathComponent("sized")
        try FileManager.default.createDirectory(at: sized.appendingPathComponent("in"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: sized.appendingPathComponent("a"))
        try Data(count: 20).write(to: sized.appendingPathComponent("in/b"))
        XCTAssertEqual(symlink(app.appendingPathComponent("Contents/Resources/nothing.bin").path, sized.appendingPathComponent("in/link").path), 0)
        XCTAssertEqual(Updater.size(of: sized), 30)
    }

    /// A zip also carries who may write. None of that is part of what is signed, so none of
    /// it may be installed: an app zipped again with everything opened up still passes the
    /// signature check, and has to come out of an update closed.
    func testWhatAZipCarriesBesidesFilesIsNotInstalled() async throws {
        let apps = try XCTUnwrap(Self.apps), folder = scratch(self, "modes")
        let loud = folder.appendingPathComponent("src/harbor.app"), program = loud.appendingPathComponent("Contents/MacOS/Harbor")
        try FileManager.default.createDirectory(at: loud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apps.a, to: loud)
        // Everyone may write everything, the program runs as its owner whoever starts it, and access lists say so once more.
        XCTAssertEqual(tool("/bin/chmod", ["-R", "0777", loud.path]), 0)
        XCTAssertEqual(tool("/bin/chmod", ["6777", program.path]), 0)
        XCTAssertEqual(tool("/bin/chmod", ["+a", "everyone allow write,append,delete,writeattr,writeextattr", program.path]), 0)
        XCTAssertEqual(tool("/bin/chmod", ["+a", "everyone allow add_file,add_subdirectory,delete_child,file_inherit,directory_inherit", loud.appendingPathComponent("Contents").path]), 0)
        let zip = folder.appendingPathComponent("loud.zip")
        XCTAssertEqual(Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", loud.path, zip.path]), 0)
        func everything(in app: URL) -> [String] { [app.path] + (FileManager.default.enumerator(atPath: app.path)?.compactMap { ($0 as? String).map { app.path + "/" + $0 } } ?? []) }
        func open(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT != S_IFLNK && (info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) != 0)
        }
        // As it unpacks, all of that is there (this is what used to be installed), and the signature still passes.
        let raw = folder.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        guard case .success(let unpacked) = Updater.unpack(zip, into: raw) else { return XCTFail("it unpacks") }
        XCTAssertTrue(everything(in: unpacked).contains(where: open))
        XCTAssertTrue(everything(in: unpacked).contains(where: hasACL))
        XCTAssertTrue(Updater.meets(unpacked, apps.requirementA))
        // A link in it to something outside, itself wide open: what the link leads to is never touched.
        let outside = folder.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        XCTAssertEqual(tool("/bin/chmod", ["0666", outside.path]), 0)
        XCTAssertEqual(tool("/bin/chmod", ["+a", "everyone allow write", outside.path]), 0)
        XCTAssertEqual(symlink(outside.path, unpacked.appendingPathComponent("Contents/out").path), 0)
        XCTAssertEqual(symlink(folder.path, unpacked.appendingPathComponent("Contents/outdir").path), 0)
        // ditto itself drops "runs as its owner" on the way out; put back by hand, to see that this takes it away too.
        let unpackedProgram = unpacked.appendingPathComponent("Contents/MacOS/Harbor").path
        XCTAssertEqual(chmod(unpackedProgram, 0o6777), 0)
        var before = stat()
        XCTAssertEqual(lstat(unpackedProgram, &before), 0)
        XCTAssertEqual(before.st_mode & (S_ISUID | S_ISGID), S_ISUID | S_ISGID)
        XCTAssertTrue(Updater.tame(unpacked))
        XCTAssertEqual(everything(in: unpacked).filter(open), [])
        XCTAssertEqual(everything(in: unpacked).filter(hasACL), [])
        XCTAssertEqual(mode(outside.path), 0o666)
        XCTAssertTrue(hasACL(outside.path))
        XCTAssertTrue(hasACL(loud.appendingPathComponent("Contents").path), "nothing was reached through the link to the folder outside")
        XCTAssertEqual(mode(program.path.replacingOccurrences(of: loud.path, with: unpacked.path)), 0o755)      // what the owner may do is as it was
        // Something that isn't there, or a folder in it that can't be read, can't be made right: said, not passed over.
        XCTAssertFalse(Updater.tame(folder.appendingPathComponent("nothing.app")))
        let shut = unpacked.appendingPathComponent("Contents/shut")
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
        chmod(shut.path, 0)
        XCTAssertFalse(Updater.tame(unpacked))
        chmod(shut.path, 0o755)
        XCTAssertTrue(Updater.tame(unpacked))

        // And through a whole update: what is installed is closed, and is still the app that was signed.
        let place = folder.appendingPathComponent("Applications"), installed = place.appendingPathComponent("harbor.app")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        _ = try Self.make(place, version: "1.6.0", salt: "installed")
        let release = try Data(contentsOf: zip)
        var world = Updater.World(requirement: apps.requirementA, bundleID: "local.harbor", running: "1.6.0", handOver: { _ in })
        world.fetch = { url in url.lastPathComponent == "SHA256SUMS" ? Data("\(Updater.sha256(release))  harbor-apple-silicon.zip\n\(Updater.sha256(release))  harbor-intel.zip\n".utf8) : release }
        world.trash = { (try? FileManager.default.removeItem(at: $0)) != nil }
        world.leftBehind = { _ in }
        let problem = await Updater.update(to: "9.9.9", installed: installed, world: world)
        XCTAssertNil(problem?.text)
        XCTAssertEqual(Updater.facts(of: installed)?.version, "9.9.9")
        XCTAssertEqual(everything(in: installed).filter(open), [])
        XCTAssertEqual(everything(in: installed).filter(hasACL), [])
        XCTAssertTrue(Updater.meets(installed, apps.requirementA))
    }

    /// THE check: only an app that meets the running app's own requirement.
    func testOnlyAnAppSignedLikeThisOne() throws {
        let apps = try XCTUnwrap(Self.apps), folder = scratch(self, "meets")
        XCTAssertTrue(Updater.meets(apps.a, apps.requirementA))
        // The same app from another build has another signature; another app has another too. Neither meets it.
        XCTAssertFalse(Updater.meets(apps.b, apps.requirementA))
        XCTAssertFalse(Updater.meets(apps.other, apps.requirementA))
        XCTAssertTrue(Updater.meets(apps.other, apps.requirementOther))
        // A copy of the right one is still the right one; with one byte of its code changed it no longer is.
        let copy = folder.appendingPathComponent("harbor.app")
        try FileManager.default.copyItem(at: apps.a, to: copy)
        XCTAssertTrue(Updater.meets(copy, apps.requirementA))
        let handle = try FileHandle(forWritingTo: copy.appendingPathComponent("Contents/MacOS/Harbor"))
        try handle.seekToEnd()
        handle.write(Data("# changed\n".utf8))
        try handle.close()
        XCTAssertFalse(Updater.meets(copy, apps.requirementA))
        // Something added to it; not signed at all; not there.
        let added = folder.appendingPathComponent("added/harbor.app")
        try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apps.a, to: added)
        try FileManager.default.createDirectory(at: added.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data("extra".utf8).write(to: added.appendingPathComponent("Contents/Resources/extra.txt"))
        XCTAssertFalse(Updater.meets(added, apps.requirementA))
        let plain = try Self.make(folder.appendingPathComponent("plain"), version: "9.9.9", salt: "a")
        XCTAssertFalse(Updater.meets(plain, apps.requirementA))
        XCTAssertFalse(Updater.meets(folder.appendingPathComponent("nothing.app"), apps.requirementA))
        // Code inside the app counts too: with a helper app in it that was changed after signing, the app around it no longer passes.
        let outer = folder.appendingPathComponent("nested/harbor.app")
        try FileManager.default.createDirectory(at: outer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: apps.nested, to: outer)
        XCTAssertTrue(Updater.meets(outer, apps.requirementNested))
        let inner = try FileHandle(forWritingTo: outer.appendingPathComponent("Contents/Helpers/helper.app/Contents/MacOS/Helper"))
        try inner.seekToEnd()
        inner.write(Data("# changed\n".utf8))
        try inner.close()
        XCTAssertFalse(Updater.meets(outer, apps.requirementNested))
        // The same app, the release asked for, and strictly newer.
        XCTAssertNil(Updater.factsProblem(id: "local.harbor", version: "1.6.1", release: "1.6.1", runningID: "local.harbor", running: "1.6.0"))
        XCTAssertEqual(Updater.factsProblem(id: "local.other", version: "1.6.1", release: "1.6.1", runningID: "local.harbor", running: "1.6.0"), "The download is a different app (local.other), so it wasn't installed.")
        XCTAssertEqual(Updater.factsProblem(id: "local.harbor", version: "1.6.2", release: "1.6.1", runningID: "local.harbor", running: "1.6.0"), "The download says it is another version than the release, so it wasn't installed.")
        for running in ["1.6.1", "1.6.2", "1.7", "2", "1.6.1.0", "1.10.0"] {
            XCTAssertEqual(Updater.factsProblem(id: "local.harbor", version: "1.6.1", release: "1.6.1", runningID: "local.harbor", running: running), "The download isn't newer than this harbor, so it wasn't installed.", running)
        }
        XCTAssertFalse(Updater.factsProblem(id: "evil\u{1B}[2J\nid", version: "1", release: "1", runningID: "local.harbor", running: "0")?.contains("\u{1B}") ?? true)
    }

    /// Two more apps, with compiled programs this time: `fat` holds two architectures, and
    /// `withHelper` has a compiled helper app inside it. Built and signed ad-hoc once. nil
    /// where there is no C compiler to build them with.
    private static let compiled: (root: URL, fat: URL, withHelper: URL)? = {
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        let clang = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", sdk = developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        guard FileManager.default.isExecutableFile(atPath: clang), FileManager.default.fileExists(atPath: sdk) else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-compiled-\(Lan.token(4))"), source = root.appendingPathComponent("main.c")
        guard let fat = try? make(root.appendingPathComponent("fat"), version: "9.9.9", salt: "fat"), let outer = try? make(root.appendingPathComponent("outer"), version: "9.9.9", salt: "outer"),
              (try? Data("int main(void) { return 0; }\n".utf8).write(to: source)) != nil else { return nil }
        let helper = outer.appendingPathComponent("Contents/Helpers/helper.app")
        let info: [String: Any] = ["CFBundleIdentifier": "local.harbor.helper", "CFBundleExecutable": "Helper", "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL"]
        guard (try? FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)) != nil,
              (try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: helper.appendingPathComponent("Contents/Info.plist"))) != nil,
              run(clang, ["-isysroot", sdk, "-arch", "arm64", "-arch", "x86_64", "-o", fat.appendingPathComponent("Contents/MacOS/Harbor").path, source.path]) == 0,
              run(clang, ["-isysroot", sdk, "-o", helper.appendingPathComponent("Contents/MacOS/Helper").path, source.path]) == 0 else { return nil }
        // Ad-hoc, once each, the helper before the app around it.
        for app in [fat, helper, outer] where run("/usr/bin/codesign", ["--force", "-s", "-", app.path]) != 0 { return nil }
        return (root, fat, outer)
    }()

    /// The two parts of THE check that a plain app can't show: every architecture in the
    /// program is checked, not only the one this Mac runs, and so is the code inside the app.
    func testEveryArchitectureAndTheCodeInside() throws {
        guard let compiled = Self.compiled else { throw XCTSkip("no C compiler here to build the two apps with") }
        let folder = scratch(self, "compiled")
        // The other architecture's part of the program, changed after signing. This Mac would never run it; it still counts.
        let fat = folder.appendingPathComponent("fat/harbor.app"), requirement = try XCTUnwrap(Self.requirement(of: compiled.fat))
        try FileManager.default.createDirectory(at: fat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: compiled.fat, to: fat)
        XCTAssertTrue(Updater.meets(fat, requirement))
        let program = fat.appendingPathComponent("Contents/MacOS/Harbor")
        var bytes = [UInt8](try Data(contentsOf: program))
        func word(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        XCTAssertEqual(word(0), 0xCAFE_BABE, "a program with more than one architecture")
        #if arch(arm64)
        let mine = 0x0100_000C
        #else
        let mine = 0x0100_0007
        #endif
        let other = try XCTUnwrap((0..<word(4)).map { 8 + $0 * 20 }.first { word($0) != mine })
        bytes[word(other + 8) + 0x600] ^= 0x01
        try Data(bytes).write(to: program)
        XCTAssertFalse(Updater.meets(fat, requirement))
        // A helper app inside, with something added to it after signing. The app around it is untouched, and no longer passes.
        let outer = folder.appendingPathComponent("outer/harbor.app"), outerRequirement = try XCTUnwrap(Self.requirement(of: compiled.withHelper))
        try FileManager.default.createDirectory(at: outer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: compiled.withHelper, to: outer)
        XCTAssertTrue(Updater.meets(outer, outerRequirement))
        let inside = outer.appendingPathComponent("Contents/Helpers/helper.app/Contents/Resources")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("extra".utf8).write(to: inside.appendingPathComponent("extra.txt"))
        XCTAssertFalse(Updater.meets(outer, outerRequirement))
    }

    func testTheSwapIsUndoneWhenItCantBeFinished() throws {
        let folder = scratch(self, "swap")
        func lay() throws -> (installed: String, new: String, aside: String) {
            let installed = folder.appendingPathComponent("harbor.app"), new = folder.appendingPathComponent("new/harbor.app"), old = folder.appendingPathComponent("old")
            for path in [installed, new.deletingLastPathComponent(), old] { try? FileManager.default.removeItem(at: path) }
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: installed.appendingPathComponent("which"))
            try Data("new".utf8).write(to: new.appendingPathComponent("which"))
            return (installed.path, new.path, old.appendingPathComponent("harbor.app").path)
        }
        func which(_ app: String) -> String? { try? String(contentsOfFile: app + "/which", encoding: .utf8) }
        // It works: the new one is where the app was, the old one is aside.
        var at = try lay()
        XCTAssertNil(Updater.swap(installed: at.installed, new: at.new, aside: at.aside))
        XCTAssertEqual(which(at.installed), "new")
        XCTAssertEqual(which(at.aside), "old")
        // The app can't be moved aside: nothing changed.
        at = try lay()
        XCTAssertEqual(Updater.swap(installed: at.installed, new: at.new, aside: at.aside) { _, _ in -1 }, Updater.Problem("harbor couldn't be moved out of the way, so nothing was changed."))
        XCTAssertEqual(which(at.installed), "old")
        XCTAssertEqual(which(at.new), "new")
        // The new one can't be put in place: the old one is put back, and that is said.
        at = try lay()
        var calls = 0
        let problem = Updater.swap(installed: at.installed, new: at.new, aside: at.aside) { from, to in
            calls += 1
            return calls == 2 ? -1 : Darwin.rename(from, to)
        }
        XCTAssertEqual(problem, Updater.Problem("The new harbor couldn't be put in place, so the old one was put back."))
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(which(at.installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: at.aside))
        // And if even that fails, it says where the old one is rather than losing it.
        at = try lay()
        calls = 0
        let worst = Updater.swap(installed: at.installed, new: at.new, aside: at.aside) { from, to in
            calls += 1
            return calls == 1 ? Darwin.rename(from, to) : -1
        }
        XCTAssertEqual(worst?.text.contains("Move it back to where it was."), true)
        XCTAssertEqual(which(at.aside), "old")
    }

    /// The whole update against a stand-in for GitHub: what it takes to go through, and that
    /// every refusal leaves the installed app exactly as it was.
    func testAnUpdateFromStartToFinish() async throws {
        let apps = try XCTUnwrap(Self.apps), folder = scratch(self, "update")
        let release = try zip(apps.a, in: folder), otherBuild = try zip(apps.b, in: folder, name: "b.zip"), otherApp = try zip(apps.other, in: folder, name: "other.zip")
        let place = folder.appendingPathComponent("Applications"), installed = place.appendingPathComponent("harbor.app"), trash = folder.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        struct Run { var asked: [String] = []; var handed: [URL] = []; var trashed: [URL] = []; var modes: [Int] = []; var left: [URL] = []; var besideAtHandOver: [String] = ["not handed over"] }
        /// The folder the update works in, beside the app.
        func working() -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []).filter { $0.hasPrefix(".harbor-update-") }.map { place.appendingPathComponent($0) }
        }
        final class Box: @unchecked Sendable { var run = Run() }
        func world(_ box: Box, zip: Data, sums: String? = nil, requirement: SecRequirement? = nil, bundleID: String = "local.harbor", running: String = "1.6.0",
                   appleSilicon: Bool = true, rename: ((String, String) -> Int32)? = nil) -> Updater.World {
            var world = Updater.World(requirement: requirement ?? apps.requirementA, bundleID: bundleID, running: running, handOver: {
                box.run.handed.append($0)
                // The real hand-over ends the process: what is still beside the app at this moment stays there for good.
                box.run.besideAtHandOver = working().flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }.sorted()
            })
            world.appleSilicon = appleSilicon
            world.fetch = { url in
                box.run.asked.append(url.absoluteString)
                box.run.modes = working().map { mode($0.path) }
                let file = url.lastPathComponent
                if file == "SHA256SUMS" { return Data((sums ?? "\(Updater.sha256(zip))  harbor-apple-silicon.zip\n\(Updater.sha256(zip))  harbor-intel.zip\n").utf8) }
                return zip
            }
            world.trash = { old in
                box.run.trashed.append(old)
                return (try? FileManager.default.moveItem(at: old, to: trash.appendingPathComponent("harbor-\(Lan.token(3)).app"))) != nil
            }
            world.leftBehind = { box.run.left.append($0) }
            if let rename { world.rename = rename }
            return world
        }
        /// The installed app as it was before each try: version 1.6.0, with a mark of its own.
        func install() throws {
            try? FileManager.default.removeItem(at: place)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            _ = try Self.make(place, version: "1.6.0", salt: "installed")
        }
        func untouched() -> Bool {
            Updater.facts(of: installed)?.version == "1.6.0" && (try? String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Harbor"), encoding: .utf8))?.contains("# installed") == true
                && ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []) == ["harbor.app"]
        }

        // It goes through: the release is where the app was, the old one is in the Trash, nothing is left beside it,
        // and the new one was handed over to. The two files came from the release's own address and nowhere else.
        try install()
        var box = Box()
        let done = await Updater.update(to: "9.9.9", installed: installed, world: world(box, zip: release))
        XCTAssertNil(done)
        XCTAssertEqual(Updater.facts(of: installed)?.version, "9.9.9")
        XCTAssertTrue(Updater.meets(installed, apps.requirementA))
        XCTAssertEqual(box.run.handed, [installed])
        XCTAssertEqual(box.run.besideAtHandOver, [], "cleared away before the hand-over, which in the real world never comes back")
        XCTAssertEqual(box.run.trashed.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: place.path), ["harbor.app"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
        XCTAssertEqual(box.run.asked, ["https://github.com/ips610/harbor/releases/download/v9.9.9/SHA256SUMS", "https://github.com/ips610/harbor/releases/download/v9.9.9/harbor-apple-silicon.zip"])
        XCTAssertEqual(box.run.modes, [0o700], "it works in one folder of this user's own, beside the app")
        // On Intel hardware it is the other file.
        try install()
        box = Box()
        _ = await Updater.update(to: "9.9.9", installed: installed, world: world(box, zip: release, appleSilicon: false))
        XCTAssertEqual(box.run.asked.last, "https://github.com/ips610/harbor/releases/download/v9.9.9/harbor-intel.zip")

        /// Every refusal: said in words, nothing handed over, and the installed app exactly as it was.
        func refused(_ what: String, expect: String, _ make: (Box) -> Updater.World, version: String = "9.9.9") async throws {
            try install()
            let box = Box()
            let problem = await Updater.update(to: version, installed: installed, world: make(box))
            XCTAssertEqual(problem?.text, expect, what)
            XCTAssertTrue(box.run.handed.isEmpty, what)
            XCTAssertTrue(box.run.trashed.isEmpty, what)
            XCTAssertTrue(untouched(), what)
        }
        let shape = "The download isn't shaped like a release, so it wasn't unpacked."
        try await refused("a version that isn't one", expect: "That isn't a version harbor knows how to get.", { world($0, zip: release) }, version: "9.9.9/../x")
        try await refused("too large", expect: "The download is larger than a release ever is, so it was stopped.", { world($0, zip: Data(count: Updater.maxBytes + 1)) })
        try await refused("the checksum is another file's", expect: "The download doesn't match its checksum, so it wasn't installed.",
                          { world($0, zip: release, sums: "\(String(repeating: "0", count: 64))  harbor-apple-silicon.zip\n") })
        try await refused("the list doesn't name the file", expect: "The download doesn't match its checksum, so it wasn't installed.", { world($0, zip: release, sums: "\(Updater.sha256(release))  something-else.zip\n") })
        try await refused("not a zip", expect: "The download isn't a zip harbor can read, so it wasn't unpacked.", { world($0, zip: Data("just text, long enough to look for an end record in".utf8)) })
        try await refused("a second thing in the zip", expect: shape, { world($0, zip: self.crafted([("harbor.app/Contents/Info.plist", 0o100644), ("install.sh", 0o100755)])) })
        try await refused("a path that climbs out", expect: shape, { world($0, zip: self.crafted([("harbor.app/Contents/Info.plist", 0o100644), ("harbor.app/../../evil", 0o100644)])) })
        try await refused("the app as a link", expect: shape, { world($0, zip: self.crafted([("harbor.app", 0o120777), ("harbor.app/Contents/Info.plist", 0o100644)])) })
        // Signed, but not with what this app is signed with: the same app from another build, and an unsigned one.
        let unsigned = try zip(try Self.make(folder.appendingPathComponent("unsigned"), version: "9.9.9", salt: "a"), in: folder, name: "unsigned.zip")
        let notOurs = "The download isn't signed with the same key as this harbor, so it wasn't installed."
        try await refused("another build's signature", expect: notOurs, { world($0, zip: otherBuild) })
        try await refused("not signed", expect: notOurs, { world($0, zip: unsigned) })
        try await refused("another app's signature", expect: notOurs, { world($0, zip: otherApp) })
        // It meets the requirement, and is still not taken: another app; another version than asked for; not newer.
        try await refused("another app", expect: "The download is a different app (local.other), so it wasn't installed.", { world($0, zip: otherApp, requirement: apps.requirementOther) })
        try await refused("another version than the release", expect: "The download says it is another version than the release, so it wasn't installed.", { world($0, zip: release) }, version: "9.9.8")
        try await refused("the same version", expect: "The download isn't newer than this harbor, so it wasn't installed.", { world($0, zip: release, running: "9.9.9") })
        try await refused("an older version", expect: "The download isn't newer than this harbor, so it wasn't installed.", { world($0, zip: release, running: "10.0") })
        // The swap can't be finished: the old app is put back.
        var calls = 0
        try await refused("the new app can't be put in place", expect: "The new harbor couldn't be put in place, so the old one was put back.", { box in
            world(box, zip: release, rename: { from, to in
                calls += 1
                return calls == 2 ? -1 : Darwin.rename(from, to)
            })
        })
        XCTAssertEqual(calls, 3)
        // Not even that works: the old app is not where it was, and it is NOT deleted. It stays where it was moved to, and that is said.
        try install()
        box = Box()
        calls = 0
        let stuck = await Updater.update(to: "9.9.9", installed: installed, world: world(box, zip: release, rename: { from, to in
            calls += 1
            return calls == 1 ? Darwin.rename(from, to) : -1
        }))
        XCTAssertEqual(stuck?.text.hasSuffix("Move it back to where it was."), true)
        XCTAssertTrue(box.run.handed.isEmpty)
        let kept = working().map { $0.appendingPathComponent("old/harbor.app/Contents/MacOS/Harbor") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("# installed"), true)
        XCTAssertEqual(working().map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }, [["old"]], "the download and what was unpacked from it are gone all the same")
        // The Trash won't have the old app: the update still goes through, and the old app stays beside the new one.
        try install()
        box = Box()
        var noTrash = world(box, zip: release)
        noTrash.trash = { _ in false }
        let untrashed = await Updater.update(to: "9.9.9", installed: installed, world: noTrash)
        XCTAssertNil(untrashed)
        XCTAssertEqual(box.run.handed, [installed])
        XCTAssertEqual(box.run.besideAtHandOver, ["old"], "only the old app the Trash would not take is left, in its folder")
        XCTAssertEqual(Updater.facts(of: installed)?.version, "9.9.9")
        XCTAssertEqual(working().map { Updater.facts(of: $0.appendingPathComponent("old/harbor.app"))?.version }, ["1.6.0"])
        // Only the old app is left there, nothing of the download; and the new copy is left word of exactly where it is.
        XCTAssertEqual(working().map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }, [["old"]])
        XCTAssertEqual(box.run.left.map(\.path), working().map { $0.path + "/old/harbor.app" })
        // That word: one line in a file of this account's own, said once by the copy that finds it, then gone.
        let note = folder.appendingPathComponent("support/old-copy"), stray = folder.appendingPathComponent("stray.txt")
        XCTAssertNil(Updater.takeNote(at: note))
        Updater.leaveNote(try XCTUnwrap(box.run.left.first), at: note)
        XCTAssertEqual(mode(note.path), 0o600)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), box.run.left[0].path + "\n")
        XCTAssertEqual(Updater.takeNote(at: note), "The old harbor couldn't be moved to the Trash. It is still at \(box.run.left[0].path). Delete it when you like.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertNil(Updater.takeNote(at: note))
        // A link where the note goes is taken away, never written through; one where it is read from is never followed.
        try Data("/somewhere/else/harbor.app\n".utf8).write(to: stray)
        XCTAssertEqual(symlink(stray.path, note.path), 0)
        XCTAssertNil(Updater.takeNote(at: note))                                            // not even when what it leads to reads like a note
        Updater.leaveNote(URL(fileURLWithPath: "/Applications/.harbor-update-ab12cd/old/harbor.app"), at: note)
        XCTAssertEqual(try String(contentsOf: stray, encoding: .utf8), "/somewhere/else/harbor.app\n")
        XCTAssertEqual(Updater.takeNote(at: note)?.contains("/Applications/.harbor-update-ab12cd/old/harbor.app."), true)
        // Words in the note that aren't a path say nothing.
        try Data("see https://example.com\n".utf8).write(to: note)
        XCTAssertNil(Updater.takeNote(at: note))
        // The download itself fails.
        try install()
        box = Box()
        var failing = world(box, zip: release)
        failing.fetch = { _ in throw Updater.Problem("GitHub didn't hand the file over.") }
        let failed = await Updater.update(to: "9.9.9", installed: installed, world: failing)
        XCTAssertEqual(failed?.text, "GitHub didn't hand the file over.")
        XCTAssertTrue(untouched())
        // A folder that can't be written to: said, and nothing else happens (it isn't even offered there).
        try install()
        chmod(place.path, 0o555)
        box = Box()
        let unwritable = await Updater.update(to: "9.9.9", installed: installed, world: world(box, zip: release))
        chmod(place.path, 0o755)
        XCTAssertEqual(unwritable?.text, "harbor can't write beside itself, so it can't update itself here.")
        XCTAssertTrue(box.run.asked.isEmpty)
        XCTAssertTrue(untouched())
    }
}
