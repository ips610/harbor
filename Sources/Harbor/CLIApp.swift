import Darwin
import Foundation

/// The commands that go further than `ls`, `kill` and `open`: scanning a range, checking one
/// port, watching, and (through the running app) sharing, tunnels, passwords, groups and names.
///
/// The ones that change something reach the app the way its page does: on its own loopback
/// port, with the owner's private session file (0600, this account only). It is the same trust
/// as the page, and the same code answers, so each call behaves exactly like the click.
/// Passwords are never an argument (they would sit in shell history and in `ps`): they are
/// typed at a hidden prompt, read from stdin, or made by the app with `--random`.
enum CLIApp {
    /// What a command line asks for here.
    enum Call: Equatable {
        case scan(range: ClosedRange<UInt16>, all: Bool, json: Bool)
        case check(String)
        case watch(every: Double)
        case shares
        case share(target: String, seconds: Int?, password: Password)
        case unshare(String)
        case extend(target: String, times: Int, publicLink: Bool)
        case password(target: String, Password)
        case tunnels
        case tunnel(target: String, seconds: Int?)
        case untunnel(String)
        case stopped
        case start(String, yes: Bool)
        case rename(target: String, name: String?)
        case groups
        case group(target: String, title: String?)
        case groupRename(title: String, to: String)
        case groupDelete(String)
    }

    /// Where a password comes from. Never from an argument.
    enum Password: Equatable { case prompt, stdin, random, none }

    static let usage = """
    More commands:

      harbor scan [3000-3999] [--all] [--json]   what is listening in a range of ports
      harbor check <port|name>                   what answers on it: status and page title
      harbor watch [--every N]                   print what starts and stops, until Ctrl-C

    Through the running app (the same as the page, no password in an argument):
      harbor shares                              what is on the network, with time left
      harbor share <port|name> [--minutes 30|60 | --until-stopped] [--open | --random | --password-stdin]
                                                 put it on the network as name.local (asks for a password)
      harbor unshare <port|name>                 take it off the network
      harbor extend <port|name> [30m|1h] [--public]   half an hour more per 30m, for a share or a link
      harbor password <port|name> [--random | --password-stdin | --remove]
      harbor tunnels                             public links, with time left
      harbor tunnel <port|name> [--minutes 30|60 | --until-stopped]   a public link, printed when it is ready
      harbor tunnel stop <port|name>
      harbor stopped                             servers harbor saw stop
      harbor start <port|name> [-y]              start one again (shows what will run, asks first)
      harbor rename <port|name> <name> | --reset  its name in lists
      harbor groups                              groups made by hand
      harbor group <port|name> <title> | --auto  put it in a group (made if new), or back
      harbor group rename <title> <new title>
      harbor group delete <title>
    """

    // MARK: Reading the command line

    /// nil: not one of these commands. `.some(.failure(text))`: it is one, but wrongly written.
    static func parse(_ first: String, _ rest: [String]) -> Result<Call, Failure>? {
        // Words are what is not a flag, and not the value of a flag that takes one (--minutes 30, --every 5).
        var words: [String] = [], skip = false
        for arg in rest {
            if skip { skip = false; continue }
            if arg == "--minutes" || arg == "--every" { skip = true; continue }
            if !arg.hasPrefix("-") { words.append(arg) }
        }
        let flags = Set(rest.filter { $0.hasPrefix("-") })
        func bad(_ line: String) -> Result<Call, Failure> { .failure(Failure(line)) }
        func only(_ allowed: Set<String>) -> Bool { flags.isSubset(of: allowed) }
        switch first {
        case "scan":
            guard only(["--all", "-a", "--json"]), words.count <= 1 else { return bad("harbor scan [3000-3999] [--all] [--json]") }
            guard let range = words.first.map(portRange) ?? (1...65535) else { return bad("A range is two ports, like 3000-3999, or one port.") }
            return .success(.scan(range: range, all: flags.contains("--all") || flags.contains("-a"), json: flags.contains("--json")))
        case "check":
            guard words.count == 1, flags.isEmpty else { return bad("harbor check <port|name>") }
            return .success(.check(words[0]))
        case "watch":
            let every = valueAfter("--every", in: rest).flatMap(Double.init) ?? 5
            guard words.isEmpty, only(["--every"]), every >= 1, every <= 3600 else { return bad("harbor watch [--every N]   (1 to 3600 seconds)") }
            return .success(.watch(every: every))
        case "shares":
            return words.isEmpty && flags.isEmpty ? .success(.shares) : bad("harbor shares")
        case "share":
            guard words.count == 1, let asked = lasts(rest), let pw = password(flags, allowing: ["--open", "--random", "--password-stdin"]),
                  only(["--minutes", "--until-stopped", "--open", "--random", "--password-stdin"]) else {
                return bad("harbor share <port|name> [--minutes 30|60 | --until-stopped] [--open | --random | --password-stdin]")
            }
            return .success(.share(target: words[0], seconds: asked.seconds, password: pw))
        case "unshare":
            return words.count == 1 && flags.isEmpty ? .success(.unshare(words[0])) : bad("harbor unshare <port|name>")
        case "extend":
            // The port or name, and how much: 30m per half hour (the app adds half an hour at a time).
            guard words.count >= 1, words.count <= 2, only(["--public"]) else { return bad("harbor extend <port|name> [30m|1h|2h] [--public]") }
            var times = 1
            if words.count == 2 {
                guard let seconds = Monitor.parseInterval(words[1]), seconds >= 1800, Int(seconds) % 1800 == 0, seconds <= 8 * 3600 else {
                    return bad("How much more: 30m, 1h, 90m… in half hours, up to 8h.")
                }
                times = Int(seconds) / 1800
            }
            return .success(.extend(target: words[0], times: times, publicLink: flags.contains("--public")))
        case "password":
            guard words.count == 1, only(["--random", "--password-stdin", "--remove"]) else {
                return bad("harbor password <port|name> [--random | --password-stdin | --remove]")
            }
            let choice: Password = flags.contains("--remove") ? .none : flags.contains("--random") ? .random : flags.contains("--password-stdin") ? .stdin : .prompt
            return flags.count <= 1 ? .success(.password(target: words[0], choice)) : bad("Choose one of --random, --password-stdin, --remove.")
        case "tunnels":
            return words.isEmpty && flags.isEmpty ? .success(.tunnels) : bad("harbor tunnels")
        case "tunnel":
            if words.first == "stop" {
                return words.count == 2 && flags.isEmpty ? .success(.untunnel(words[1])) : bad("harbor tunnel stop <port|name>")
            }
            guard words.count == 1, let asked = lasts(rest), only(["--minutes", "--until-stopped"]) else {
                return bad("harbor tunnel <port|name> [--minutes 30|60 | --until-stopped]  |  harbor tunnel stop <port|name>")
            }
            return .success(.tunnel(target: words[0], seconds: asked.seconds))
        case "stopped":
            return words.isEmpty && flags.isEmpty ? .success(.stopped) : bad("harbor stopped")
        case "start":
            return words.count == 1 && only(["-y", "--yes"]) ? .success(.start(words[0], yes: !flags.isEmpty)) : bad("harbor start <port|name> [-y]")
        case "rename":
            guard words.count >= 1, only(["--reset"]) else { return bad("harbor rename <port|name> <name>  |  harbor rename <port|name> --reset") }
            if flags.contains("--reset") { return words.count == 1 ? .success(.rename(target: words[0], name: nil)) : bad("harbor rename <port|name> --reset") }
            return words.count >= 2 ? .success(.rename(target: words[0], name: words.dropFirst().joined(separator: " "))) : bad("harbor rename <port|name> <name>")
        case "groups":
            return words.isEmpty && flags.isEmpty ? .success(.groups) : bad("harbor groups")
        case "group":
            if words.first == "rename" {
                return words.count == 3 && flags.isEmpty ? .success(.groupRename(title: words[1], to: words[2]))
                    : bad("harbor group rename <title> <new title>   (quote a title that has spaces)")
            }
            if words.first == "delete" { return words.count == 2 && flags.isEmpty ? .success(.groupDelete(words[1])) : bad("harbor group delete <title>") }
            guard only(["--auto"]) else { return bad("harbor group <port|name> <title>  |  harbor group <port|name> --auto") }
            if flags.contains("--auto") { return words.count == 1 ? .success(.group(target: words[0], title: nil)) : bad("harbor group <port|name> --auto") }
            return words.count >= 2 ? .success(.group(target: words[0], title: words.dropFirst().joined(separator: " "))) : bad("harbor group <port|name> <title>")
        default:
            return nil
        }
    }

    struct Failure: Error, Equatable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// "3000-3999" or "3000". nil when it isn't a range of ports.
    static func portRange(_ text: String) -> ClosedRange<UInt16>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let lo = UInt16(parts[0]), lo > 0 else { return nil }
        guard parts.count == 2 else { return lo...lo }
        guard let hi = UInt16(parts[1]), hi >= lo else { return nil }
        return lo...hi
    }

    /// The word after a flag, when there is one.
    private static func valueAfter(_ flag: String, in args: [String]) -> String? {
        guard let at = args.firstIndex(of: flag), at + 1 < args.count else { return nil }
        return args[at + 1]
    }

    /// How long a share lasts, as asked.
    struct Asked: Equatable { let seconds: Int? }      // nil: the app's last choice

    /// `--minutes 30|60` (the app offers 30 minutes, an hour, or until it is stopped), `--until-stopped`, or neither.
    /// nil: asked for something the app doesn't offer, or two things.
    static func lasts(_ args: [String]) -> Asked? {
        let forever = args.contains("--until-stopped")
        if forever { return args.contains("--minutes") ? nil : Asked(seconds: 0) }
        guard args.contains("--minutes") else { return Asked(seconds: nil) }
        guard let minutes = valueAfter("--minutes", in: args).flatMap(Int.init), [30, 60].contains(minutes) else { return nil }
        return Asked(seconds: minutes * 60)
    }

    /// Which way a password is given. The default is a prompt; at most one of the choices.
    private static func password(_ flags: Set<String>, allowing: Set<String>) -> Password? {
        let given = flags.intersection(allowing)
        guard given.count <= 1 else { return nil }
        switch given.first {
        case "--open": return Password.none
        case "--random": return .random
        case "--password-stdin": return .stdin
        default: return .prompt
        }
    }

    // MARK: Finding what a word means

    /// The row a word names, among the app's rows: a port, or a name (with or without .localhost / .local).
    /// A port with two processes is the first; the commands that stop things never use this.
    static func target(_ word: String, in ports: [[String: Any]]) -> [String: Any]? {
        if let port = Int(word) { return ports.first { ($0["port"] as? Int) == port } }
        var name = word.lowercased()
        for suffix in [".localhost", ".local"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return ports.first { ($0["hostName"] as? String) == name }
            ?? ports.first { (($0["local"] as? [String: Any])?["name"] as? String) == name }
            ?? ports.first { ($0["display"] as? String)?.lowercased() == name }
    }

    // MARK: The running app

    struct Problem: Error { let text: String }

    /// How to reach the app: its port and the owner's two halves of a session.
    struct Link {
        let port: Int
        let token: String
        let key: String

        static func open() throws -> Link {
            let env = ProcessInfo.processInfo.environment["HARBOR_APP"]?.split(separator: ",").map(String.init)
            if let env, env.count == 3, let port = Int(env[0]) { return Link(port: port, token: env[1], key: env[2]) }
            guard let session = WebServer.readSession(WebServer.sessionFileURL) else {
                throw Problem(text: "\(AppInfo.name) isn't running (or hasn't made its session yet). Open it from Applications or the menu bar and try again.")
            }
            return Link(port: Ports.reserved(Ports.harbor), token: session.token, key: session.key)
        }

        private func send(_ path: String, body: [String: Any]?) throws -> [String: Any] {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw Problem(text: "That isn't an address.") }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("\(WebServer.cookie)=\(token)", forHTTPHeaderField: "Cookie")
            request.setValue(key, forHTTPHeaderField: "X-Harbor-Key")
            if let body {
                request.httpMethod = "POST"
                request.setValue("1", forHTTPHeaderField: "X-Harbor")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            var out: (Int, Data)?
            let done = DispatchSemaphore(value: 0)
            URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
                if let data, let http = response as? HTTPURLResponse { out = (http.statusCode, data) }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 20)
            guard let (status, data) = out else {
                throw Problem(text: "\(AppInfo.name) isn't answering on port \(port). Is it running?")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 403, (json["error"] as? String) == "session" {
                throw Problem(text: "\(AppInfo.name) didn't accept this session. Open its page once and try again.")
            }
            guard (200..<300).contains(status) else { throw Problem(text: (json["error"] as? String) ?? "\(AppInfo.name) said no (\(status)).") }
            return json
        }

        func state() throws -> [String: Any] { try send("/api/state", body: nil) }

        @discardableResult
        func act(_ body: [String: Any]) throws -> [String: Any] { try send("/api/action", body: body) }
    }

    // MARK: Hidden input

    /// A password: typed at a prompt that doesn't echo, or one line from stdin. Never longer than 200.
    static func readPassword(_ how: Password, prompt: String) -> String? {
        switch how {
        case .stdin:
            return readLine(strippingNewline: true).map { String($0.prefix(200)) }
        case .prompt:
            guard isatty(STDIN_FILENO) == 1 else { return nil }
            FileHandle.standardError.write(Data(prompt.utf8))
            var old = termios()
            tcgetattr(STDIN_FILENO, &old)
            var quiet = old
            quiet.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
            defer {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &old)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            return readLine(strippingNewline: true).map { String($0.prefix(200)) }
        default:
            return nil
        }
    }

    // MARK: Showing

    /// A short line for a row: ":3000 storefront (node)".
    static func label(_ p: [String: Any]) -> String {
        let port = p["port"] as? Int ?? 0
        let name = (p["rowName"] as? String) ?? (p["display"] as? String) ?? (p["name"] as? String) ?? "?"
        return ":\(port) \(CLI.plain(name))"
    }

    /// "30 min left" etc. as the app says it, or "until stopped".
    static func left(_ text: Any?) -> String { (text as? String) ?? "until stopped" }

    /// A table with a header, columns as wide as their widest cell.
    static func table(_ rows: [[String]]) -> String {
        guard let width = rows.first?.count else { return "" }
        let widths = (0..<width).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
}
