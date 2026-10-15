import AppKit
import Darwin
import Foundation

/// harbor from Terminal: `harbor ls`, `harbor kill <port>`, `harbor open <port|name>`.
///
/// `ls`, `kill`, `open`, `scan`, `check` and `watch` run in this process, with the app's own
/// scanner and the app's own rules for what may be stopped. They never talk to the running app
/// and write nothing: the names the running app has given, and what it has on the network or
/// behind a public link, they read from the small note the app leaves for it (`Shared`).
/// The commands that change something (share, tunnel, password, groups…) are in `CLIApp`: they
/// reach the running app through its loopback page, with the owner's private session file.
enum CLI {
    /// What a script gets back.
    enum Exit: Int32 {
        case ok = 0, failed = 1, usage = 2, nothing = 3, refused = 4, cancelled = 5, changed = 6
    }

    enum Call: Equatable {
        case help, helpMore, version
        case ls(json: Bool, all: Bool)
        case kill(port: UInt16, yes: Bool, force: Bool, pid: pid_t?)
        case open(String)
        /// Scanning, checking, watching and everything that goes through the running app (see CLIApp).
        case more(CLIApp.Call)
        /// Not something harbor knows: said, then the help, then a non-zero exit.
        case usage(String)
    }

    /// The app's own binary (EXECUTABLE in app.conf: the two must match, and a test holds them
    /// together). Started under any other name, harbor was started through the command's link.
    static let executable = "Harbor"

    /// What a start of this binary is.
    enum Start: Equatable { case command(Call), door, app }

    /// A command first: through the command's link every flag is the command line's to refuse,
    /// `--door` like any other. Only the app's own binary is ever a door.
    static func start(_ arguments: [String]) -> Start {
        if let call = parse(arguments) { return .command(call) }
        return arguments.contains("--door") ? .door : .app
    }

    /// The app this binary belongs to. Started through the command's link, `Bundle.main` is
    /// the folder the link is in; the app is found from where the binary really is.
    static let bundle: Bundle = {
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return .main }
        defer { free(real) }
        let app = URL(fileURLWithPath: String(cString: real)).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) ?? .main : .main
    }()
    /// The app's settings, to read (renames, chosen main servers). Nothing here ever writes them.
    static var defaults: UserDefaults { bundle.bundleIdentifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard }
    static let help = """
    harbor: what is listening on this Mac

      harbor ls [--json] [--all]       ports, their .localhost names, and what is shared
      harbor kill <port> [-y] [--force] [--pid N]
                                       stop what listens there (asks first; -y doesn't)
      harbor open <port|name>          open its .localhost address in the browser
      harbor --version
      harbor --help

    More: scan, check, watch, shares, share, unshare, extend, password, tunnels, tunnel,
    stopped, start, rename, groups, group. `harbor help more` lists them.

    kill stops politely and waits 3 seconds. With --force it then ends the process at once.
    It never touches macOS's own processes, harbor, Docker, or another user's processes.

    Exit codes: 0 done · 1 still running, or it failed · 2 not understood · 3 nothing listens there
                4 harbor won't stop that · 5 you said no · 6 the process changed while you were asked
    """

    /// What the arguments ask for, or nil when this is not a command line call at all (then
    /// the app starts as it always has). A word that isn't a flag is always a command, known
    /// or not. Flags are the app's own business (`--launchd`, the debug ones) unless harbor
    /// was started through the command's link, where nothing ever starts the app.
    static func parse(_ arguments: [String]) -> Call? {
        guard let invoked = arguments.first else { return nil }
        let viaLink = (invoked as NSString).lastPathComponent != executable
        let args = Array(arguments.dropFirst())
        guard let first = args.first else { return viaLink ? .help : nil }
        let rest = Array(args.dropFirst())
        func flags(_ allowed: Set<String>) -> Set<String>? {
            let given = Set(rest.filter { $0.hasPrefix("-") })
            return given.isSubset(of: allowed) ? given : nil
        }
        let words = rest.filter { !$0.hasPrefix("-") }
        switch first {
        case "--help", "-h", "help": return rest == ["more"] ? .helpMore : .help
        case "--version", "version": return .version
        case "ls":
            guard words.isEmpty, let f = flags(["--json", "--all", "-a"]) else { return .usage("harbor ls [--json] [--all]") }
            return .ls(json: f.contains("--json"), all: f.contains("--all") || f.contains("-a"))
        case "kill":
            // --pid takes the word after it.
            var words = words, pid: pid_t?
            if let at = rest.firstIndex(of: "--pid") {
                guard at + 1 < rest.count, let n = Int32(rest[at + 1]), n > 1 else { return .usage("harbor kill <port> --pid N") }
                pid = n
                words = rest.enumerated().filter { $0.offset != at + 1 && !$0.element.hasPrefix("-") }.map(\.element)
            }
            guard words.count == 1, let port = UInt16(words[0]), port != 0, let f = flags(["-y", "--yes", "--force", "--pid"]) else {
                return .usage("harbor kill <port> [-y] [--force] [--pid N]")
            }
            return .kill(port: port, yes: f.contains("-y") || f.contains("--yes"), force: f.contains("--force"), pid: pid)
        case "open":
            guard words.count == 1, rest.count == 1 else { return .usage("harbor open <port|name>") }
            return .open(words[0])
        default:
            if first.hasPrefix("-"), !viaLink { return nil }
            switch CLIApp.parse(first, rest) {
            case .success(let call)?: return .more(call)
            case .failure(let failure)?: return .usage(failure.text)
            case nil: return .usage("harbor: no such command: \(first)")
            }
        }
    }

    /// Runs a command line call and returns its exit code; nil when the arguments aren't one.
    static func run(_ arguments: [String]) -> Int32? {
        parse(arguments).map(run)
    }

    static func run(_ call: Call) -> Int32 {
        switch call {
        case .help:
            print(help)
            return Exit.ok.rawValue
        case .helpMore:
            print(CLIApp.usage)
            return Exit.ok.rawValue
        case .version:
            print("\(AppInfo.name) \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
            return Exit.ok.rawValue
        case .usage(let message):
            FileHandle.standardError.write(Data((message + "\n\n" + help + "\n").utf8))
            return Exit.usage.rawValue
        case .ls(let json, let all):
            print(json ? Self.json(lines(all: all)) : table(lines(all: all)))
            return Exit.ok.rawValue
        case .open(let what):
            return open(what).rawValue
        case .kill(let port, let yes, let force, let pid):
            return kill(port: port, yes: yes, force: force, pid: pid).rawValue
        case .more(let call):
            return CLIApp.run(call)
        }
    }

    // MARK: What is listening

    /// Made-up ports instead of this Mac's (HARBOR_FIXTURE, for a transcript that shows nobody's
    /// real folders). With them nothing is ever opened or stopped.
    static var fixture: String? { ProcessInfo.processInfo.environment["HARBOR_FIXTURE"] }

    /// One scan, the names, and what is shared. While the app runs the names are the ones it
    /// has given (its note says); without it they are worked out here by the same rules, from
    /// its saved renames and chosen main servers.
    static func scan() -> (rows: [PortRow], names: [String: String], shared: Shared.Note) {
        if let fixture {
            let rows = DebugCLI.fixtureRows(docker: fixture == "docker")
            var note = Shared.Note(pid: 2, identity: "made-up", names: Names.assign(rows).byRow, door: true, proxy: 8490)
            if fixture != "plain", let front = rows.first(where: { $0.port == 3000 }) {
                note.network[front.id] = "http://storefront.local/"
                if fixture == "both" { note.links[front.id] = "https://quiet-harbor-demo.trycloudflare.com" }
            }
            return (rows, note.names, note)
        }
        let rows = Scanner().fullScan(sampleCPU: false).ports
        let note = Shared.read()
        if note.isLive { return (rows, note.names, note) }
        let saved = (defaults.dictionary(forKey: "names") as? [String: String]) ?? [:]
        let mains = (defaults.dictionary(forKey: "mainPorts") as? [String: Int]) ?? [:]
        return (rows, Names.assign(rows, saved: saved, mains: mains).byRow, note)
    }

    struct Line: Equatable {
        let port: UInt16
        let name: String?
        let process: String
        let pid: pid_t
        let folder: String?
        let network: String?
        let link: String?
        let container: String?
    }

    static func lines(all: Bool) -> [Line] {
        let found = scan()
        return lines(found.rows, names: found.names, shared: found.shared, all: all)
    }

    static func lines(_ rows: [PortRow], names: [String: String], shared: Shared.Note, all: Bool) -> [Line] {
        rows.filter { all || !$0.isHiddenByDefault }.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }.map { row in
            Line(port: row.port, name: names[row.id].map { $0 + Names.suffix }, process: row.label, pid: row.pid, folder: row.repo.flatMap { row.container != nil ? $0 : nil } ?? row.projectFolder ?? row.folder,
                 network: shared.network[row.id], link: shared.links[row.id], container: row.container?.name)
        }
    }

    /// What goes to a terminal is text from this Mac's processes and folders: anything that
    /// could move the cursor or recolour the screen is taken out first.
    static func plain(_ text: String) -> String { Docker.clean(text, max: 200) }

    static func table(_ lines: [Line]) -> String {
        guard !lines.isEmpty else { return "Nothing is listening." }
        var rows = [["PORT", "NAME", "PROCESS", "PID", "FOLDER", "SHARED"]]
        for l in lines {
            let shared = [l.network != nil ? "on network" : nil, l.link != nil ? "public" : nil].compactMap { $0 }.joined(separator: ", ")
            rows.append([String(l.port), plain(l.name ?? "-"), plain(l.process), String(l.pid), plain(l.folder.map(Fmt.path) ?? "-"), shared])
        }
        let widths = (0..<6).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    static func json(_ lines: [Line]) -> String {
        let list: [[String: Any]] = lines.map { l in
            ["port": Int(l.port), "name": l.name ?? NSNull(), "process": l.process, "pid": Int(l.pid), "folder": l.folder ?? NSNull(),
             "onNetwork": l.network != nil, "networkLink": l.network ?? NSNull(), "public": l.link != nil, "publicLink": l.link ?? NSNull(),
             "container": l.container ?? NSNull()]
        }
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: open

    /// The row a port or a name stands for. A name with or without ".localhost".
    static func find(_ what: String, in rows: [PortRow], names: [String: String]) -> PortRow? {
        if let port = UInt16(what) { return rows.first { $0.port == port } }
        var name = what.lowercased()
        for prefix in ["http://"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        while name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(Names.suffix) { name.removeLast(Names.suffix.count) }
        guard Names.isLabel(name) else { return nil }
        return rows.first { names[$0.id] == name }
    }

    /// Its `.localhost` address as the running app would open it (with the proxy's port while
    /// port 80 isn't harbor's). Without the app nothing answers for a name: then the plain
    /// address, which always works.
    static func address(_ row: PortRow, names: [String: String], shared: Shared.Note) -> URL {
        guard shared.isLive, shared.proxy != 0, let name = names[row.id],
              let url = URL(string: "http://\(name)\(Names.suffix)\(shared.door ? "" : ":\(shared.proxy)")/") else { return row.url }
        return url
    }

    private static func open(_ what: String) -> Exit {
        let found = scan()
        guard let row = find(what, in: found.rows, names: found.names) else {
            say("Nothing is listening as \(plain(what)).")
            return .nothing
        }
        let url = address(row, names: found.names, shared: found.shared)
        if fixture != nil {
            print("(made-up ports: would open \(url.absoluteString))")
            return .ok
        }
        print(url.absoluteString)
        return NSWorkspace.shared.open(url) ? .ok : .failed
    }

    // MARK: kill

    /// Why the command line won't stop this row, or nil. The app's own rules (`Engine.refusal`:
    /// macOS's processes, Docker's), plus harbor itself and anything that isn't this user's.
    /// There is no administrator path from here.
    static func refusal(_ row: PortRow, owner: uid_t?) -> String? {
        if row.pid <= 1 { return "That is macOS itself." }
        if row.isSelf || Names.isHarbor(row.path) { return "That is \(AppInfo.name) itself. Quit it from its menu." }
        // A process's name is its own to choose: cleaned before it is printed, like everything else here.
        if let no = Engine.refusal(pid: row.pid, path: row.path, name: plain(row.processName)) { return no.message }
        if owner != getuid() { return "\(plain(row.processName)) runs as another user. The command line has no administrator path; use the app." }
        return nil
    }

    static func question(_ row: PortRow) -> String {
        let workers = row.workers > 0 ? " and its \(row.workers) worker\(row.workers == 1 ? "" : "s")" : ""
        let folder = (row.projectFolder ?? row.folder).map { ", in \(plain(Fmt.path($0)))" } ?? ""
        return "Stop \(plain(row.processName)) (pid \(row.pid))\(workers) on :\(row.port)\(folder)? [y/N] "
    }

    private static func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static func gone(_ pid: pid_t, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !ProcessControl.isAlive(pid) { return true }
            usleep(100_000)
        }
        return !ProcessControl.isAlive(pid)
    }

    private static func kill(port: UInt16, yes: Bool, force: Bool, pid wanted: pid_t?) -> Exit {
        let rows = scan().rows.filter { $0.port == port && (wanted == nil || $0.pid == wanted) }
        guard let row = rows.first else {
            say("Nothing of yours is listening on :\(port)\(wanted.map { " as pid \($0)" } ?? "").")
            return .nothing
        }
        guard rows.count == 1 else {
            say("More than one process listens on :\(port): " + rows.map { "\(plain($0.processName)) (pid \($0.pid))" }.joined(separator: ", ") + ". Say which with --pid.")
            return .refused
        }
        if let no = refusal(row, owner: fixture != nil ? getuid() : LibProc.shortInfo(row.pid)?.pbsi_uid) {
            say(no)
            return .refused
        }
        // Who it is now, to be held against who it is when the answer comes.
        let server = OnNetwork.Server(pid: row.pid, identity: LibProc.identity(row.pid), target: Names.Target(port: row.port, addresses: []))
        let workers = row.workerPids.map { (pid: $0, identity: LibProc.identity($0)) }
        if !yes {
            FileHandle.standardOutput.write(Data(question(row).utf8))
            guard let answer = readLine(), ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased()) else {
                say("Left running.")
                return .cancelled
            }
        }
        if fixture != nil {
            print("(made-up ports: nothing was stopped)")
            return .ok
        }
        let done = stop(label: "\(plain(row.processName)) on :\(row.port)", name: plain(row.processName), pid: row.pid, identity: server.identity, workers: workers, force: force,
                        Hands(isStillThere: { server.isStillThere }, identity: LibProc.identity, send: ProcessControl.send, gone: gone, alive: ProcessControl.isAlive))
        if done.exit == .ok { print(done.said) } else { say(done.said) }
        return done.exit
    }

    /// What stopping does to the Mac, so a test can stand in for it.
    struct Hands {
        var isStillThere: () -> Bool
        var identity: (pid_t) -> String
        var send: (Int32, pid_t) -> ProcessControl.SignalResult
        var gone: (pid_t, Double) -> Bool
        var alive: (pid_t) -> Bool
    }

    /// The stop itself, once the answer was yes. Nothing is signalled unless the process is
    /// still the one that was asked about, on that port; the polite signal comes first, and
    /// the hard one only with `force`, only after the wait, and only to that same process.
    static func stop(label: String, name: String, pid: pid_t, identity: String, workers: [(pid: pid_t, identity: String)], force: Bool, _ hands: Hands) -> (exit: Exit, said: String) {
        // Still that process, still on that port? A pid given out again while the question stood is never signalled.
        guard hands.isStillThere() else { return (.changed, "\(label) changed while you were asked. Run it again.") }
        switch hands.send(SIGTERM, pid) {
        case .gone: return (.ok, "\(label) had already stopped.")
        case .notPermitted: return (.refused, "\(name) runs as another user. The command line has no administrator path; use the app.")
        case .failed(let e): return (.failed, "Couldn't stop \(label): \(String(cString: strerror(e))).")
        case .sent: break
        }
        var said = "Stopped \(label)."
        if !hands.gone(pid, 3) {
            guard force else { return (.failed, "\(label) is still running after 3 seconds. Run it again with --force to end it at once; anything unsaved is lost.") }
            guard hands.identity(pid) == identity else { return (.changed, "\(label) changed while it was being stopped.") }
            _ = hands.send(SIGKILL, pid)
            guard hands.gone(pid, 3) else { return (.failed, "\(label) still won't stop.") }
            said = "Force-stopped \(label)."
        }
        // Workers that shared its socket, and are still the processes they were.
        for worker in workers where hands.alive(worker.pid) && hands.identity(worker.pid) == worker.identity {
            _ = hands.send(force ? SIGKILL : SIGTERM, worker.pid)
        }
        return (.ok, said)
    }
}

/// What the running app would tell the command line, left in a small file for it to read
/// (the command line never asks the app itself): the name each row goes by, whether port 80
/// is harbor's and where its proxy listens, and what is on the network or behind a public
/// link. Row ids, names and links only: nothing secret. Written by the app when it changes,
/// removed when it quits, and believed only while the process that wrote it is still that
/// process.
enum Shared {
    struct Note: Equatable {
        var pid: pid_t = 0
        var identity = ""
        var names: [String: String] = [:]       // PortRow.id → "storefront"
        var door = false                        // a name works without a port
        var proxy = 0                           // else with this one
        var network: [String: String] = [:]     // PortRow.id → "http://storefront.local/"
        var links: [String: String] = [:]       // PortRow.id → the public link

        /// From an app that is running right now?
        var isLive: Bool { pid > 1 }
    }

    /// Where the app leaves it. A debug run leaves none unless told where (`--shared-file`);
    /// HARBOR_SHARED_FILE points the command line at another one.
    static var file: URL? {
        if let given = ProcessInfo.processInfo.environment["HARBOR_SHARED_FILE"] ?? DebugCLI.sharedFile { return URL(fileURLWithPath: given) }
        if DebugCLI.isDebugRun { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(CLI.bundle.bundleIdentifier ?? LaunchAgent.label)/shared")
    }

    static func encode(_ note: Note) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["pid": Int(note.pid), "identity": note.identity, "names": note.names, "door": note.door, "proxy": note.proxy,
                                                       "network": note.network, "links": note.links] as [String: Any], options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> Note? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let pid = object["pid"] as? Int, let identity = object["identity"] as? String,
              let names = object["names"] as? [String: String], let door = object["door"] as? Bool, let proxy = object["proxy"] as? Int, (0...65535).contains(proxy),
              let network = object["network"] as? [String: String], let links = object["links"] as? [String: String] else { return nil }
        // A name is only ever a label; anything else in the file isn't one of harbor's.
        guard names.values.allSatisfy({ Names.isLabel($0) }) else { return nil }
        return Note(pid: pid_t(clamping: pid), identity: identity, names: names, door: door, proxy: proxy, network: network, links: links)
    }

    /// The app's note, when there is one and the app that wrote it is still running as the
    /// same process. Otherwise nothing is shared as far as anyone can say.
    static func read(_ file: URL? = Shared.file, identity: (pid_t) -> String = LibProc.identity) -> Note {
        guard let file, let data = try? Data(contentsOf: file), data.count < 1 << 20, let note = decode(data),
              note.pid > 1, !note.identity.isEmpty, identity(note.pid) == note.identity else { return Note() }
        return note
    }

    private static var last: Data?

    /// The app's side: writes the note when it differs from the last one written.
    @MainActor
    static func leave(names: [String: String], door: Bool, proxy: Int, network: [String: String], links: [String: String]) {
        guard let file else { return }
        let data = encode(Note(pid: getpid(), identity: LibProc.identity(getpid()), names: names, door: door, proxy: proxy, network: network, links: links))
        guard data != last else { return }
        last = data
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let new = file.path + ".new"
        unlink(new)
        let fd = Darwin.open(new, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        close(fd)
        if !written || rename(new, file.path) != 0 { unlink(new) }
    }

    /// When the app quits.
    static func clear() {
        if let file { unlink(file.path) }
    }
}

/// The `harbor` command on the PATH: a link to this app's own binary, in the first of
/// `/usr/local/bin` and `~/.local/bin` that this user may write to. No administrator
/// password, and nothing that isn't harbor's own link is ever replaced or removed.
enum CommandLink {
    static var places: [String] { ["/usr/local/bin", NSHomeDirectory() + "/.local/bin"] }
    static var target: String { Bundle.main.executablePath ?? "" }

    /// Is the thing at `path` a link to a harbor binary (this copy's or an older one's)?
    static func isOurs(_ path: String) -> Bool {
        guard let to = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        return to.hasSuffix("/Contents/MacOS/\(CLI.executable)")
    }

    /// Where the command is installed now, if it is.
    static func installed(in places: [String] = places) -> String? {
        places.map { $0 + "/harbor" }.first(where: isOurs)
    }

    /// Puts the link in place. Returns where, and what to tell the user.
    static func install(in places: [String] = places, target: String = target, home: String = NSHomeDirectory()) -> (path: String?, note: String) {
        guard target.hasSuffix("/Contents/MacOS/\(CLI.executable)") else { return (nil, "This copy of \(AppInfo.name) isn't an app, so there is nothing to link to.") }
        let files = FileManager.default
        for place in places {
            // Only ~/.local/bin is made when it isn't there; /usr/local/bin is used as it is found.
            if !files.fileExists(atPath: place), place.hasPrefix(home + "/") { try? files.createDirectory(atPath: place, withIntermediateDirectories: true) }
            var isFolder: ObjCBool = false
            guard files.fileExists(atPath: place, isDirectory: &isFolder), isFolder.boolValue, access(place, W_OK) == 0 else { continue }
            let path = place + "/harbor"
            if (try? files.attributesOfItem(atPath: path)) != nil {
                guard isOurs(path) else { return (nil, "There is already a harbor at \(path) that isn't mine, so I left it alone.") }
                unlink(path)
            }
            guard symlink(target, path) == 0 else { continue }
            let shown = Fmt.path(place)
            return (path, place.hasPrefix(home + "/")
                ? "The harbor command is at \(shown)/harbor. If Terminal can't find it, add this line to ~/.zshrc and open a new window: export PATH=\"$HOME/.local/bin:$PATH\""
                : "The harbor command is at \(shown)/harbor. Try it in a new Terminal window: harbor ls")
        }
        return (nil, "Neither /usr/local/bin nor ~/.local/bin can be written to, so the command wasn't installed.")
    }

    /// Takes harbor's own link away again, wherever it is.
    static func remove(from places: [String] = places) -> String {
        let removed = places.map { $0 + "/harbor" }.filter { isOurs($0) && unlink($0) == 0 }
        return removed.isEmpty ? "There was no harbor command to remove." : "Removed \(removed.map(Fmt.path).joined(separator: " and "))."
    }
}
