import Darwin
import Foundation

/// Running the commands of `CLIApp`.
extension CLIApp {
    private static func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    static func run(_ call: Call) -> Int32 {
        do {
            return try execute(call).rawValue
        } catch let problem as Problem {
            say(CLI.plain(problem.text))
            return CLI.Exit.failed.rawValue
        } catch {
            say("\(error)")
            return CLI.Exit.failed.rawValue
        }
    }

    /// y or Y at a terminal; anything else, and anything not at a terminal, is no.
    private static func confirmed(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) == 1 else { return false }
        FileHandle.standardError.write(Data(question.utf8))
        return ["y", "yes"].contains((readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func ports(_ state: [String: Any]) -> [[String: Any]] { state["ports"] as? [[String: Any]] ?? [] }

    /// The row a word names among the app's, or a clear no.
    private static func row(_ word: String, _ state: [String: Any]) throws -> (pid: Int, port: Int, row: [String: Any]) {
        guard let p = target(word, in: ports(state)), let pid = p["pid"] as? Int, let port = p["port"] as? Int else {
            throw Problem(text: "Nothing is listening as \(CLI.plain(word)). `harbor ls` shows what is.")
        }
        return (pid, port, p)
    }

    private static func execute(_ call: Call) throws -> CLI.Exit {
        switch call {
        // MARK: In this process
        case .scan(let range, let all, let json):
            let found = CLI.scan()
            let lines = CLI.lines(found.rows, names: found.names, shared: found.shared, all: all).filter { range.contains($0.port) }
            print(json ? CLI.json(lines) : CLI.table(lines))
            if !json, !lines.isEmpty { say("\(lines.count) listening in \(range.lowerBound)–\(range.upperBound).") }
            return lines.isEmpty ? .nothing : .ok
        case .check(let what):
            let found = CLI.scan()
            guard let row = CLI.find(what, in: found.rows, names: found.names) else {
                say("Nothing is listening as \(CLI.plain(what)).")
                return .nothing
            }
            if CLI.fixture != nil { print("(made-up ports: nothing is asked)"); return .ok }
            let target = Names.Target(port: row.port, addresses: row.scope == .all ? ["127.0.0.1", "::1"] : row.addresses)
            let answer = Probe.ask(target, host: "localhost")
            print("\(CLI.plain(row.processName)) on :\(row.port): \(CLI.plain(answer))")
            return answer == Probe.notAnswering ? .failed : .ok
        case .watch(let every):
            var known: [String: String]?
            while true {
                let found = CLI.scan()
                let now = Dictionary(found.rows.filter { !$0.isHiddenByDefault }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                func text(_ r: PortRow) -> String { ":\(r.port)  \(CLI.plain(r.processName))  \(CLI.plain((r.projectFolder ?? r.folder).map(Fmt.path) ?? "-"))" }
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                if let known {
                    for (id, r) in now.sorted(by: { $0.value.port < $1.value.port }) where known[id] == nil { print("\(stamp)  + \(text(r))") }
                    for (id, line) in known.sorted(by: { $0.value < $1.value }) where now[id] == nil { print("\(stamp)  - \(line)") }
                } else {
                    print("Watching \(now.count) ports, every \(Int(every)) s. Ctrl-C to stop.")
                    for r in now.values.sorted(by: { $0.port < $1.port }) { print("\(stamp)    \(text(r))") }
                }
                fflush(stdout)
                known = now.mapValues(text)
                sleep(UInt32(every))
            }
        // MARK: Through the running app
        case .shares, .tunnels:
            let state = try Link.open().state()
            var rows = [call == .shares ? ["PORT", "NAME", "WHERE", "PASSWORD", "LEFT"] : ["PORT", "NAME", "LINK", "LEFT"]]
            for p in ports(state) {
                if case .shares = call, let l = p["local"] as? [String: Any], (l["on"] as? Bool) == true {
                    rows.append([String(p["port"] as? Int ?? 0), CLI.plain((l["name"] as? String ?? "") + Lan.suffix), CLI.plain(l["link"] as? String ?? "-"),
                                 (l["password"] as? Bool) == true ? "yes" : "none", left(l["left"])])
                }
                if case .tunnels = call, let t = p["tunnel"] as? [String: Any] {
                    let url = (t["url"] as? String) ?? (t["state"] as? String ?? "")
                    rows.append([String(p["port"] as? Int ?? 0), label(p), CLI.plain(url), left(t["left"])])
                }
            }
            guard rows.count > 1 else {
                print(call == .shares ? "Nothing is on the network." : "No public links.")
                return .ok
            }
            print(table(rows))
            return .ok
        case .share(let word, let seconds, let how):
            let link = try Link.open()
            let (pid, port, p) = try row(word, try link.state())
            guard let local = p["local"] as? [String: Any], let name = local["name"] as? String else {
                throw Problem(text: "\(label(p)) has no name to put on the network.")
            }
            var body: [String: Any] = ["op": "lan-on", "pid": pid, "port": port]
            var shown: String?
            switch how {
            case .none:
                body["open"] = true
                say("No password: anyone on this network can open \(name)\(Lan.suffix).")
            case .random:
                shown = try link.act(["op": "lan-suggest", "pid": pid])["password"] as? String
                body["password"] = shown
            case .stdin, .prompt:
                guard let typed = readPassword(how, prompt: "Password for \(name)\(Lan.suffix) (8 or more characters): "), !typed.isEmpty else {
                    throw Problem(text: how == .prompt ? "A password needs a terminal. Use --password-stdin, --random or --open." : "No password was read.")
                }
                body["password"] = typed
            }
            if let seconds { body["for"] = seconds }
            let done = try link.act(body)
            print((done["message"] as? String).map(CLI.plain) ?? "On the network.")
            if let shown { print("Password: \(shown)   (shown once; `harbor password` changes it)") }
            return .ok
        case .unshare(let word):
            let link = try Link.open()
            let (pid, port, _) = try row(word, try link.state())
            try link.act(["op": "lan-off", "pid": pid, "port": port])
            print("Off the network.")
            return .ok
        case .extend(let word, let times, let publicLink):
            let link = try Link.open()
            let (pid, port, p) = try row(word, try link.state())
            let local = p["local"] as? [String: Any], tunnel = p["tunnel"] as? [String: Any]
            let kind = publicLink || ((local?["on"] as? Bool) != true && tunnel != nil) ? "public" : "network"
            var message = ""
            for _ in 0..<times {
                message = (try link.act(["op": "more", "pid": pid, "port": port, "kind": kind])["message"] as? String) ?? ""
            }
            print("\(label(p)): \(times * 30) minutes more on the \(kind == "public" ? "public link" : "network share"). \(message == "" ? "" : "")".trimmingCharacters(in: .whitespaces))
            return .ok
        case .password(let word, let how):
            let link = try Link.open()
            let (pid, port, p) = try row(word, try link.state())
            var body: [String: Any] = ["op": "lan-password", "pid": pid, "port": port]
            switch how {
            case .none: body["off"] = true
            case .random: body["random"] = true
            case .stdin, .prompt:
                let name = ((p["local"] as? [String: Any])?["name"] as? String) ?? word
                guard let typed = readPassword(how, prompt: "New password for \(name)\(Lan.suffix) (8 or more characters): "), !typed.isEmpty else {
                    throw Problem(text: how == .prompt ? "A password needs a terminal. Use --password-stdin, --random or --remove." : "No password was read.")
                }
                body["password"] = typed
            }
            let done = try link.act(body)
            print((done["message"] as? String).map(CLI.plain) ?? "Done.")
            if let made = done["password"] as? String { print("Password: \(made)   (shown once)") }
            return .ok
        case .tunnel(let word, let seconds):
            let link = try Link.open()
            let (pid, port, p) = try row(word, try link.state())
            var body: [String: Any] = ["op": "share", "pid": pid, "port": port]
            if let seconds { body["for"] = seconds }
            let started = try link.act(body)
            if (started["result"] as? String) == "unavailable" { throw Problem(text: (started["message"] as? String) ?? "No tunnel tool is available.") }
            say("Opening a public link for \(label(p))…")
            for _ in 0..<60 {
                sleep(1)
                guard let now = target("\(port)", in: ports(try link.state())), let t = now["tunnel"] as? [String: Any] else { continue }
                switch t["state"] as? String {
                case "ready":
                    print(CLI.plain(t["url"] as? String ?? ""))
                    say("\(left(t["left"])). `harbor tunnel stop \(port)` ends it.")
                    return .ok
                case "failed":
                    throw Problem(text: CLI.plain((t["message"] as? String) ?? "The public link didn't open."))
                default: continue
                }
            }
            throw Problem(text: "The public link didn't open within a minute. `harbor tunnels` shows where it is.")
        case .untunnel(let word):
            let link = try Link.open()
            let (pid, port, _) = try row(word, try link.state())
            _ = pid
            try link.act(["op": "unshare", "port": port])
            print("Public link stopped.")
            return .ok
        case .stopped:
            let state = try Link.open().state()
            let list = state["stopped"] as? [[String: Any]] ?? []
            guard !list.isEmpty else {
                print("Nothing has stopped since harbor started.")
                return .ok
            }
            var rows = [["NAME", "PORT", "FOLDER", "STOPPED"]]
            for s in list {
                let ago = Int(s["ago"] as? Double ?? 0)
                rows.append([CLI.plain(s["name"] as? String ?? ""), String(s["port"] as? Int ?? 0), CLI.plain(s["folder"] as? String ?? "-"),
                             ago < 120 ? "\(ago) s ago" : ago < 7200 ? "\(ago / 60) min ago" : "\(ago / 3600) h ago"])
            }
            print(table(rows))
            return .ok
        case .start(let word, let yes):
            let link = try Link.open()
            let list = try link.state()["stopped"] as? [[String: Any]] ?? []
            let name = word.lowercased().replacingOccurrences(of: ".localhost", with: "")
            guard let s = list.first(where: { ($0["name"] as? String)?.lowercased() == name || String($0["port"] as? Int ?? 0) == word }),
                  let id = s["id"] as? String else {
                say("Nothing stopped as \(CLI.plain(word)). `harbor stopped` lists what harbor saw stop.")
                return .nothing
            }
            say(CLI.plain(s["question"] as? String ?? "Start it again?"))
            if !yes, !confirmed("Start it? [y/N] ") { return .cancelled }
            let done = try link.act(["op": "start-again", "id": id])
            print((done["message"] as? String).map(CLI.plain) ?? "Started.")
            return .ok
        case .rename(let word, let name):
            let link = try Link.open()
            let (pid, port, _) = try row(word, try link.state())
            try link.act(["op": "row-rename", "pid": pid, "port": port, "name": name ?? ""])
            print(name == nil ? "Back to its automatic name." : "Renamed.")
            return .ok
        case .groups:
            let state = try Link.open().state()
            let groups = state["groups"] as? [[String: Any]] ?? []
            guard !groups.isEmpty else {
                print("No groups made by hand. `harbor group <port|name> <title>` makes one.")
                return .ok
            }
            print(table([["GROUP", "SERVERS"]] + groups.map { [CLI.plain($0["title"] as? String ?? ""), String($0["count"] as? Int ?? 0)] }))
            return .ok
        case .group(let word, let title):
            let link = try Link.open()
            let state = try link.state()
            let (pid, port, _) = try row(word, state)
            var body: [String: Any] = ["op": "group-set", "pid": pid, "port": port]
            if let title {
                let groups = state["groups"] as? [[String: Any]] ?? []
                if let mine = groups.first(where: { ($0["title"] as? String)?.caseInsensitiveCompare(title) == .orderedSame }) { body["group"] = mine["id"] }
                else { body["title"] = title }
            } else {
                body["group"] = NSNull()
            }
            try link.act(body)
            print(title == nil ? "Back on its automatic card." : "In \(CLI.plain(title ?? "")).")
            return .ok
        case .groupRename(let title, let new):
            let link = try Link.open()
            let groups = try link.state()["groups"] as? [[String: Any]] ?? []
            guard let key = groups.first(where: { ($0["title"] as? String)?.caseInsensitiveCompare(title) == .orderedSame })?["key"] as? String else {
                say("No group called \(CLI.plain(title)). `harbor groups` lists them.")
                return .nothing
            }
            try link.act(["op": "card-rename", "key": key, "title": new])
            print("Renamed.")
            return .ok
        case .menubar(let set):
            let link = try Link.open()
            if let set {
                try link.act(["op": "settings", "pid": 0, "showMenuBarIcon": set])
                print(set ? "The menu bar icon is on." : "The menu bar icon is off. `harbor menubar on` brings it back.")
                return .ok
            }
            let on = ((try link.state()["settings"] as? [String: Any])?["showMenuBarIcon"] as? Bool) ?? true
            print("The menu bar icon is \(on ? "on" : "off").")
            return .ok
        case .groupDelete(let title):
            let link = try Link.open()
            let groups = try link.state()["groups"] as? [[String: Any]] ?? []
            guard let key = groups.first(where: { ($0["title"] as? String)?.caseInsensitiveCompare(title) == .orderedSame })?["key"] as? String else {
                say("No group called \(CLI.plain(title)). `harbor groups` lists them.")
                return .nothing
            }
            try link.act(["op": "group-delete", "key": key])
            print("Deleted; its servers are back on their own cards.")
            return .ok
        }
    }
}
