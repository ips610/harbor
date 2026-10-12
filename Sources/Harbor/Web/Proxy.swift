import Foundation

// MARK: - Names

/// Local names: every project gets `<name>.localhost`, served by `Proxy` below.
/// Everything here is pure, so the rules are tested without a socket.
enum Names {
    static let suffix = ".localhost"
    /// The apps' own names (the door redirects those); never given to a project.
    static let reserved = Set(["harbor", "headroom", AppInfo.slug])
    /// Never a target: headroom's page and harbor's page, on the ports they are really on
    /// (see Ports), and the proxy itself.
    static var reservedPorts: Set<UInt16> {
        [UInt16(Ports.reserved(Ports.headroom)), UInt16(Ports.reserved(Ports.harbor)), Proxy.port]
    }
    static let maxLength = 40
    /// Ports browsers refuse to open (the Fetch standard's "bad ports"): mail, IRC, X11, SIP and
    /// the like. Whatever listens there isn't a web page, so it gets no name.
    static let badPorts: Set<UInt16> = [
        1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102, 103, 104, 109, 110,
        111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532,
        540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061,
        6000, 6566, 6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080,
    ]

    /// Is this executable harbor's (this copy, or another one: the door, a second copy)?
    static func isHarbor(_ path: String?) -> Bool {
        guard let path else { return false }
        return path == Bundle.main.executablePath || path.hasSuffix("/Contents/MacOS/Harbor")
    }

    /// May this row have a name? Not macOS services, harbor's own processes, the two apps'
    /// pages, databases, or anything on a port a browser won't open.
    static func named(_ row: PortRow, never: Set<UInt16>) -> Bool {
        !row.isSystem && !row.isSelf && !isHarbor(row.path) && row.category != .database
            && !never.contains(row.port) && !badPorts.contains(row.port)
    }

    /// Where a name goes: a port on this Mac, and the addresses its server listens on.
    struct Target: Equatable {
        let port: UInt16
        let addresses: [String]
    }

    struct Table: Equatable {
        var base: [String: String] = [:]      // key → "storefront"
        var byRow: [String: String] = [:]     // PortRow.id → "storefront" or "storefront-3001"
        var targets: [String: Target] = [:]   // name → where the proxy sends it
    }

    /// "My Shop_v2" → "my-shop-v2": lowercase a-z, 0-9 and hyphens, at most 40 characters.
    static func slug(_ text: String) -> String {
        var out = ""
        for u in text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) { out.unicodeScalars.append(u) }
            else if !out.isEmpty && !out.hasSuffix("-") { out += "-" }
        }
        return trimmed(String(out.prefix(maxLength)))
    }

    private static func trimmed(_ s: String) -> String {
        var s = s
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }

    /// One hostname label in the names' alphabet. A name the user picks is at most 40 long.
    static func isLabel(_ s: String, max: Int = 63) -> Bool {
        (1...max).contains(s.utf8.count) && !s.hasPrefix("-") && !s.hasSuffix("-")
            && s.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    /// What a name belongs to, and what a rename is saved under: the project folder, else the app.
    static func key(_ row: PortRow) -> String { row.projectFolder ?? "app:" + (row.appName ?? row.processName) }

    /// Gives every project a name, and its other ports `<name>-<port>`.
    ///
    /// - The name is the folder's slug ("~/code/storefront" → storefront); an app without a
    ///   folder uses its own name (Ollama → ollama).
    /// - A saved rename wins. A name saved for a project is kept for it while it isn't running.
    /// - Every name stays with its server for as long as that server keeps running (`previous`
    ///   is the table from the last scan): a project's name, and an extra port's name too.
    /// - Two folders with the same name: the one that started first keeps the plain name, the
    ///   later one gets its parent folder in front (shop-web), then a number (web-2).
    /// - Several ports: the name goes to the server its owner chose as the main one (`mains`,
    ///   by project, a port) while that one runs; else to a dev server first, then to the
    ///   lowest port. The choice is kept while its server is away.
    /// - Some rows get no name at all (see `named`).
    static func assign(_ rows: [PortRow], saved: [String: String] = [:], previous: Table = Table(), mains: [String: Int] = [:]) -> Table {
        let never = reservedPorts
        let groups = Dictionary(grouping: rows.filter { named($0, never: never) }, by: key)
        // Names that servers still running go by: nobody else is given one of those.
        let live = Set(rows.map(\.id))
        let held = Set(previous.byRow.filter { live.contains($0.key) }.values)
        func started(_ k: String) -> Date { groups[k]?.compactMap(\.started).min() ?? .distantFuture }
        func rank(_ k: String) -> Int { saved[k] != nil ? 0 : previous.base[k] != nil ? 1 : 2 }
        let order = groups.keys.sorted { (rank($0), started($0), $0) < (rank($1), started($1), $1) }

        var table = Table()
        var used = Set<String>()
        func pick(_ k: String) -> String {
            if let s = saved[k], isLabel(s, max: maxLength), !reserved.contains(s), !used.contains(s) { return s }
            let others = Set(saved.filter { $0.key != k }.values)
            func free(_ n: String) -> Bool { !reserved.contains(n) && !used.contains(n) && !others.contains(n) }
            if let p = previous.base[k], isLabel(p), free(p) { return p }
            // A new name: also not one a running server already has.
            func open(_ n: String) -> Bool { free(n) && !held.contains(n) }
            let folder = k.hasPrefix("app:") ? nil : k
            let own = slug(folder.map(Fmt.lastComponent) ?? String(k.dropFirst(4)))
            let name = own.isEmpty ? "project" : own
            if open(name) { return name }
            if let folder {
                let parent = slug(Fmt.lastComponent((folder as NSString).deletingLastPathComponent))
                let both = trimmed(String("\(parent)-\(name)".prefix(maxLength)))
                if !parent.isEmpty, open(both) { return both }
            }
            for n in 2... {
                let tail = "-\(n)"
                let numbered = trimmed(String(name.prefix(maxLength - tail.count))) + tail
                if open(numbered) { return numbered }
            }
            return name  // not reached: the loop above ends at the first free number
        }

        var kept: [(name: String, row: PortRow)] = [], extra: [(name: String, row: PortRow)] = []
        for k in order {
            let name = pick(k)
            used.insert(name)
            // The chosen main server first; else the server that has the name keeps it; else a
            // dev server first, then the lowest port.
            func chosen(_ r: PortRow) -> Bool { mains[k] == Int(r.port) }
            func place(_ r: PortRow) -> (Int, Int, Int, UInt16, pid_t) { (chosen(r) ? 0 : 1, previous.byRow[r.id] == name ? 0 : 1, r.category == .dev ? 0 : 1, r.port, r.pid) }
            let rs = (groups[k] ?? []).sorted { place($0) < place($1) }
            table.base[k] = name
            table.targets[name] = target(rs[0])
            for (i, r) in rs.enumerated() {
                // A chosen main takes the name outright; the one that had it goes by its port from here on.
                if i == 0, chosen(r) { table.byRow[r.id] = name }
                else if let had = previous.byRow[r.id], had != name { kept.append((had, r)) }
                else if i == 0 { table.byRow[r.id] = name }
                else { extra.append(("\(name)-\(r.port)", r)) }
            }
        }
        // After every project has its name, so a project never loses one to another's extra port.
        // First the extra ports that already had a name, then the new ones.
        let savedNames = Set(saved.values)
        for (name, r) in kept {
            if used.contains(name) { extra.append(("\(table.base[key(r)] ?? name)-\(r.port)", r)); continue }
            used.insert(name)
            table.byRow[r.id] = name
            table.targets[name] = target(r)
        }
        for (name, r) in extra where !used.contains(name) && !held.contains(name) && !savedNames.contains(name) && !reserved.contains(name) {
            used.insert(name)
            table.byRow[r.id] = name
            table.targets[name] = target(r)
        }
        return table
    }

    /// A server on all interfaces answers on loopback; one bound to an address is reached there.
    private static func target(_ row: PortRow) -> Target {
        Target(port: row.port, addresses: row.scope == .all ? ["127.0.0.1", "::1"] : row.addresses)
    }

    /// Why `name` can't be the name saved for `key`, or nil when it can.
    static func problem(with name: String, for key: String, in table: Table, saved: [String: String]) -> String? {
        guard isLabel(name, max: maxLength) else {
            return "Use lowercase letters, numbers and hyphens, 1 to \(maxLength) characters."
        }
        if reserved.contains(name) { return "\(name)\(suffix) belongs to the app itself. Pick another name." }
        let mine = table.base[key] == name
        if saved.contains(where: { $0.key != key && $0.value == name }) || (table.targets[name] != nil && !mine) {
            return "\(name)\(suffix) is already taken by another project."
        }
        return nil
    }

    /// "Storefront.localhost:8490" → "storefront.localhost": lowercased, no port, no trailing dot.
    static func hostName(_ header: String?) -> String? {
        guard var host = header?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return nil }
        // Drop a port, but keep IPv6 brackets intact.
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    enum Route: Equatable {
        case forward(Target)
        /// A well-formed name nothing is running as. The label is safe to show.
        case unknown(String)
        /// Not a `.localhost` name (or one of the apps' own): answered with 404.
        case refuse
    }

    /// Where a request goes, by its Host header. Only `<name>.localhost` is ever forwarded: a
    /// website that points its own name at this Mac (DNS rebinding) still sends its own Host.
    static func route(host: String?, in table: Table) -> Route {
        guard let host = hostName(host), host.hasSuffix(suffix) else { return .refuse }
        let name = String(host.dropLast(suffix.count))
        guard isLabel(name), !reserved.contains(name) else { return .refuse }
        guard let target = table.targets[name] else { return .unknown(name) }
        return reservedPorts.contains(target.port) || badPorts.contains(target.port) ? .refuse : .forward(target)
    }
}

// MARK: - Request head

/// The head of a proxied request: parsed once, then written out again for the dev server.
struct ProxyHead {
    /// How much of what the client sends after the head belongs to this request.
    enum Body: Equatable { case none, length(Int), chunked }

    let method: String
    let target: String
    let version: String
    let headers: [(name: String, value: String)]
    let body: Body

    /// nil for anything that isn't one plain HTTP/1.x request head with exactly one Host and
    /// one clear way to tell where its body ends.
    init?(_ head: Data) {
        // Latin-1 maps every byte to one character, so the head goes out exactly as it came in.
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        // A stray CR, LF or NUL could hide a second header from the checks below.
        guard !lines.contains(where: { $0.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" } }) else { return nil }
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        // Only a path: an absolute URL or CONNECT would name a host of its own.
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines {
            // A header's name is a plain HTTP token (so no space, and no folded line), and has no
            // underscore: some servers read X_Forwarded_For as X-Forwarded-For.
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].unicodeScalars.allSatisfy(Self.isNameCharacter) else { return nil }
            // Only spaces and tabs are trimmed: `.whitespaces` would also eat bytes like 0xA0.
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))))
        }
        func values(_ name: String) -> [String] { headers.filter { $0.name.lowercased() == name }.map(\.value) }
        // One Host, and a port in it is digits.
        let hosts = values("host")
        guard hosts.count == 1 else { return nil }
        if !hosts[0].hasSuffix("]"), let colon = hosts[0].lastIndex(of: ":") {
            let port = hosts[0][hosts[0].index(after: colon)...]
            guard (1...5).contains(port.utf8.count), port.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        }
        // Where the body ends: a length, or chunks, never both, never two lengths that differ.
        let lengths = values("content-length"), codings = values("transfer-encoding")
        if !codings.isEmpty {
            guard lengths.isEmpty, codings.count == 1, codings[0].lowercased() == "chunked" else { return nil }
            body = .chunked
        } else if let first = lengths.first {
            guard Set(lengths).count == 1, (1...18).contains(first.utf8.count), first.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(first) else { return nil }
            body = length == 0 ? .none : .length(length)
        } else {
            body = .none
        }
        method = String(parts[0])
        target = String(parts[1])
        version = String(parts[2])
        self.headers = headers
    }

    /// Letters, digits and the punctuation HTTP allows in a header's name, without "_".
    private static func isNameCharacter(_ u: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || "!#$%&'*+-.^`|~".unicodeScalars.contains(u)
    }

    private func value(_ name: String) -> String? { headers.first { $0.name.lowercased() == name }?.value }

    /// Every value given for a header (a Cookie header may come more than once).
    func values(_ name: String) -> [String] { headers.filter { $0.name.lowercased() == name }.map(\.value) }

    var host: String { value("host") ?? "" }

    /// The Host as it is passed on: the name in lowercase without a trailing dot, and the port
    /// when one was given. Only ever used for a Host that routed, so it is `<name>.localhost`.
    var forwardHost: String {
        var port = ""
        if !host.hasSuffix("]"), let colon = host.lastIndex(of: ":") { port = String(host[colon...]) }
        return (Names.hostName(host) ?? "") + port
    }

    /// Asks for a WebSocket. Whether it becomes one is up to the server: see `Proxy.exchange`.
    var isWebSocket: Bool {
        value("upgrade")?.lowercased() == "websocket"
            && (value("connection") ?? "").lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }
    }

    /// Headers the proxy sets itself, or that would let a client speak for it: taken out of
    /// what the client sent, whatever it put there.
    static let replaced: Set = ["host", "connection", "keep-alive", "proxy-connection", "forwarded", "x-forwarded-for",
                                "x-forwarded-host", "x-forwarded-proto", "x-forwarded-port", "x-forwarded-scheme",
                                "x-real-ip", "x-original-url", "x-rewrite-url"]

    /// The head as the dev server gets it. Host and Origin stay what the browser sent (the
    /// name), so the app sees its real origin: its redirects, cookies and CSRF checks all
    /// agree. Dev servers accept `.localhost` names. The connection is closed after this one
    /// request unless it asks for a WebSocket.
    /// `dropCookie` (for a name shared on the network): harbor's visitor cookie is taken out
    /// of what the project gets.
    func forwarded(client: String, dropCookie: Bool = false) -> Data {
        var out = "\(method) \(target) \(version)\r\nHost: \(forwardHost)\r\n"
        for (name, value) in headers {
            let n = name.lowercased()
            if Self.replaced.contains(n) || (n == "upgrade" && !isWebSocket) { continue }
            if dropCookie, n == "cookie" {
                if let rest = Lan.strip(value) { out += "\(name): \(rest)\r\n" }
                continue
            }
            out += "\(name): \(value)\r\n"
        }
        out += "X-Forwarded-Host: \(forwardHost)\r\nX-Forwarded-Proto: http\r\nX-Forwarded-For: \(client)\r\n"
        out += "Connection: \(isWebSocket ? "Upgrade" : "close")\r\n\r\n"
        return out.data(using: .isoLatin1) ?? Data()
    }
}

/// Follows a request's body as it goes by, so the proxy passes on one request's worth and no more.
struct BodyScanner {
    private enum State { case length(Int), size, data(Int), end(Int), trailer, done }
    private var state: State
    private var line: [UInt8] = []

    init(_ body: ProxyHead.Body) {
        switch body {
        case .none: state = .done
        case .length(let n): state = .length(n)
        case .chunked: state = .size
        }
    }

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    /// How many of `bytes` belong to the body (the rest, if any, is not this request's). nil
    /// when the body isn't framed the way its head said.
    mutating func take(_ bytes: ArraySlice<UInt8>) -> Int? {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            switch state {
            case .done:
                return i - bytes.startIndex
            case .length(let n):
                let k = min(n, bytes.endIndex - i)
                i += k
                state = n == k ? .done : .length(n - k)
            case .data(let n):
                let k = min(n, bytes.endIndex - i)
                i += k
                state = n == k ? .end(2) : .data(n - k)
            case .end(let left):  // the CR LF after a chunk's data
                guard bytes[i] == (left == 2 ? 13 : 10) else { return nil }
                i += 1
                state = left == 2 ? .end(1) : .size
            case .size, .trailer:
                let byte = bytes[i]
                i += 1
                line.append(byte)
                guard line.count <= 1024 else { return nil }
                guard byte == 10 else { continue }
                guard line.count >= 2, line[line.count - 2] == 13 else { return nil }
                let text = line.dropLast(2)
                line = []
                if case .trailer = state {
                    if text.isEmpty { state = .done }  // the blank line after the last chunk (and any trailers)
                    continue
                }
                // A chunk's size in hex; anything after ";" is an extension.
                let hex = text.prefix { $0 != 59 }
                guard (1...15).contains(hex.count), hex.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(String(decoding: hex, as: UTF8.self), radix: 16) else { return nil }
                state = size == 0 ? .trailer : .data(size)
            }
        }
        return bytes.count
    }
}

/// The head of the dev server's answer.
enum ResponseHead {
    /// The status of "HTTP/1.1 200 OK…", or nil when this isn't a response head.
    static func status(_ head: Data) -> Int? {
        let line = String(decoding: head.prefix(64), as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
        guard line.count >= 2, line[0].hasPrefix("HTTP/1."), line[1].count == 3 else { return nil }
        return Int(line[1])
    }

    /// The same head saying `Connection: close`, whatever the server said. The proxy carries
    /// one request per connection; a browser told to keep the connection would send its next
    /// request into one the proxy has finished with.
    static func closing(_ head: Data) -> Data {
        guard let text = String(data: head, encoding: .isoLatin1) else { return head }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return head }
        let dropped: Set = ["connection", "keep-alive", "proxy-connection"]
        let kept = lines.dropFirst().filter { line in
            !dropped.contains(line.prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return (([lines[0]] + kept + ["Connection: close"]).joined(separator: "\r\n") + "\r\n\r\n").data(using: .isoLatin1) ?? head
    }
}

// MARK: - Sockets

/// Socket calls for the proxy and the door. They block, with deadlines, on the connection's own thread.
enum Sock {
    /// Non-blocking, no SIGPIPE, and keepalive so a peer that vanished is noticed.
    static func prepare(_ fd: Int32) {
        var one: Int32 = 1, idle: Int32 = 60
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, size)
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    private static func wait(_ fd: Int32, _ events: Int32, until deadline: Date) -> Bool {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            let n = poll(&p, 1, Int32(left * 1000) + 1)
            if n > 0 { return true }
            if n == 0 || errno != EINTR { return false }
        }
    }

    enum Head { case ok(head: Data, rest: Data), tooLarge, timedOut, closed }

    /// Reads up to the blank line that ends a request head. The cap and the deadline are for the
    /// whole head, so a client that sends a byte at a time can't hold the thread.
    static func readHead(_ fd: Int32, max: Int, within seconds: Double) -> Head {
        let deadline = Date().addingTimeInterval(seconds)
        let end = Data("\r\n\r\n".utf8)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var searched = 0
        while true {
            if let r = data.range(of: end, in: searched..<data.count) {
                return r.lowerBound > max ? .tooLarge : .ok(head: data.subdata(in: 0..<r.upperBound), rest: data.subdata(in: r.upperBound..<data.count))
            }
            if data.count > max { return .tooLarge }
            searched = Swift.max(0, data.count - 3)
            guard wait(fd, POLLIN, until: deadline) else { return .timedOut }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { data.append(contentsOf: chunk[0..<n]) }
            else if n == 0 || (errno != EAGAIN && errno != EINTR) { return .closed }
        }
    }

    /// Writes all of `data`, waiting while the socket is full. For harbor's own small replies.
    @discardableResult
    static func send(_ fd: Int32, _ data: Data, within seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { sent += n; continue }
            guard n < 0, errno == EAGAIN || errno == EINTR, wait(fd, POLLOUT, until: deadline) else { return false }
        }
        return true
    }

    /// Sends a reply and ends the connection without cutting it off: closing with the request
    /// still unread would reset the connection under the reply.
    static func reply(_ fd: Int32, _ data: Data) {
        guard send(fd, data) else { return }
        shutdown(fd, SHUT_WR)
        let deadline = Date().addingTimeInterval(1)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while wait(fd, POLLIN, until: deadline), read(fd, &chunk, chunk.count) > 0 {}
    }

    /// Drops a connection outright: nothing of it stays behind on the local port. (An
    /// ordinary close keeps the address for half a minute when this side closed first.)
    static func drop(_ fd: Int32) {
        var now = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &now, socklen_t(MemoryLayout<linger>.size))
        close(fd)
    }

    /// Ends a connection politely and still leaves nothing behind on the local port: says it
    /// is done, gives the other side `seconds` to close too, then drops what is left. The
    /// door closes this way, because what a closed connection leaves on port 80 is launchd's,
    /// and for half a minute it would keep harbor from binding that port (see Door.aside).
    static func closeLeavingNothing(_ fd: Int32, within seconds: Double = 1) {
        // The option first: once both sides have said goodbye it can't be set any more, and
        // the close would keep the address after all.
        var now = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &now, socklen_t(MemoryLayout<linger>.size))
        shutdown(fd, SHUT_WR)
        let deadline = Date().addingTimeInterval(seconds)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while wait(fd, POLLIN, until: deadline) {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { break }
        }
        close(fd)
    }

    /// Connects to the first of `addresses` (numeric, this Mac's own) that answers on `port`.
    static func connect(_ addresses: [String], port: UInt16, within seconds: Double = 5) -> Int32? {
        for address in addresses {
            var v4 = sockaddr_in(), v6 = sockaddr_in6()
            let fd: Int32, result: Int32
            if inet_pton(AF_INET, address, &v4.sin_addr) == 1 {
                v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                v4.sin_family = sa_family_t(AF_INET)
                v4.sin_port = port.bigEndian
                fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                prepare(fd)
                result = withUnsafePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else if inet_pton(AF_INET6, address, &v6.sin6_addr) == 1 {
                v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                v6.sin6_family = sa_family_t(AF_INET6)
                v6.sin6_port = port.bigEndian
                fd = socket(AF_INET6, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                prepare(fd)
                result = withUnsafePointer(to: &v6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            } else {
                continue
            }
            if result == 0 { return fd }
            if errno == EINPROGRESS, wait(fd, POLLOUT, until: Date().addingTimeInterval(seconds)) {
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 { return fd }
            }
            close(fd)
        }
        return nil
    }

    /// The other end's address ("127.0.0.1", "::1"), for X-Forwarded-For.
    static func peer(_ fd: Int32) -> String { address(fd, getpeername) }

    /// The address on this Mac a connection arrived on.
    static func local(_ fd: Int32) -> String { address(fd, getsockname) }

    private static func address(_ fd: Int32, _ which: (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32) -> String {
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = withUnsafeMutablePointer(to: &storage) { p -> Bool in
            guard p.withMemoryRebound(to: sockaddr.self, capacity: 1, { which(fd, $0, &size) }) == 0 else { return false }
            if p.pointee.ss_family == sa_family_t(AF_INET6) {
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet_ntop(AF_INET6, &$0.pointee.sin6_addr, &text, socklen_t(text.count)) != nil }
            }
            return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet_ntop(AF_INET, &$0.pointee.sin_addr, &text, socklen_t(text.count)) != nil }
        }
        return ok ? text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "127.0.0.1"
    }

    /// Is this address one of this Mac's own right now? Loopback always is. Any other has to
    /// be on one of its interfaces at this moment: a server seen on an address the Mac has
    /// since given up (a Wi-Fi it left) could by now be somebody else's machine.
    static func isOwn(_ address: String) -> Bool {
        if address == "::1" || address.hasPrefix("127.") { return true }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var next = list
        while let interface = next {
            next = interface.pointee.ifa_next
            guard let raw = interface.pointee.ifa_addr else { continue }
            let family = Int32(raw.pointee.sa_family)
            let read = family == AF_INET
                ? raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet_ntop(AF_INET, &$0.pointee.sin_addr, &text, socklen_t(text.count)) != nil }
                : family == AF_INET6
                ? raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet_ntop(AF_INET6, &$0.pointee.sin6_addr, &text, socklen_t(text.count)) != nil }
                : false
            if read, text.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == address { return true }
        }
        return false
    }

    /// Did launchd really bind every socket it handed over? `ports` are their bound ports; one
    /// whose address another program already held comes back as 0. Half a pair is no use: the
    /// other half's connections go to that other program.
    static func allBound(_ ports: [UInt16]) -> Bool {
        !ports.isEmpty && !ports.contains(0)
    }

    /// The port a listening socket is bound to.
    static func port(of fd: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        return withUnsafeMutablePointer(to: &storage) { p -> UInt16 in
            guard p.withMemoryRebound(to: sockaddr.self, capacity: 1, { getsockname(fd, $0, &size) }) == 0 else { return 0 }
            // sin_port and sin6_port sit at the same offset.
            return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    /// Copies bytes both ways between two non-blocking sockets, `first` going to `b` before
    /// anything else. It ends when either side closes (what was already read is still
    /// delivered), on an error, or when nothing has moved for `idle` seconds (nil: no limit).
    /// At most 64 KB waits in each direction: a slow reader slows its sender down instead of
    /// filling memory, and nothing is ever buffered whole.
    // ponytail: a client that half-closes and then waits for the answer gets none (browsers and
    // curl don't do that); pass the FIN on with shutdown(SHUT_WR) if such a client ever matters.
    static func relay(_ a: Int32, _ b: Int32, first: Data = Data(), idle: Double?) {
        var toA: [UInt8] = [], toB = [UInt8](first)
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var ending = false  // one side has closed: deliver what's waiting, then stop
        var moved = false

        /// Writes what it can from `buffer`. False when the socket is broken.
        func drain(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
            while !buffer.isEmpty {
                let n = buffer.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                if n > 0 { buffer.removeFirst(n); moved = true; continue }
                return n < 0 && (errno == EAGAIN || errno == EINTR)
            }
            return true
        }
        /// Reads once from `fd` into the empty `buffer` and passes it straight on to `out`.
        func pump(_ fd: Int32, _ out: Int32, _ buffer: inout [UInt8]) -> Bool {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer = Array(chunk[0..<n])
                moved = true
                return drain(out, &buffer)
            }
            if n == 0 { ending = true; moved = true; return true }
            return errno == EAGAIN || errno == EINTR
        }
        func events(read: Bool, write: Bool) -> Int16 { Int16((read ? POLLIN : 0) | (write ? POLLOUT : 0)) }

        guard drain(b, &toB) else { return }
        while !(ending && toA.isEmpty && toB.isEmpty) {
            // Read a side only when the last thing read from it has been written out.
            var p = [pollfd(fd: a, events: events(read: !ending && toB.isEmpty, write: !toA.isEmpty), revents: 0),
                     pollfd(fd: b, events: events(read: !ending && toA.isEmpty, write: !toB.isEmpty), revents: 0)]
            let limit = ending ? 5 : idle
            let n = poll(&p, 2, limit.map { Int32(Swift.min($0, 86_400) * 1000) } ?? -1)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }  // nothing moved in time
            moved = false
            let ra = Int32(p[0].revents), rb = Int32(p[1].revents)
            if (ra | rb) & (POLLERR | POLLNVAL) != 0 { return }
            if ra & POLLOUT != 0, !drain(a, &toA) { return }
            if rb & POLLOUT != 0, !drain(b, &toB) { return }
            if !ending, toB.isEmpty, ra & (POLLIN | POLLHUP) != 0, !pump(a, b, &toB) { return }
            if !ending, toA.isEmpty, rb & (POLLIN | POLLHUP) != 0, !pump(b, a, &toA) { return }
            // poll said ready but nothing could be done: a broken socket, not a reason to spin.
            guard moved else { return }
        }
    }
}

// MARK: - Proxy

/// The reverse proxy behind `<name>.localhost`: a second listener, on 127.0.0.1 and ::1 only,
/// that sends each request to the dev server its Host names, and keeps the name in the address
/// bar. One request per connection: the head is read (16 KB at most, within 10 s) and sent on
/// with the proxy's own forwarding headers, then exactly that request's body, and the answer
/// streams back (see `exchange`).
///
/// It is apart from the page's server on purpose: it has no route to /api and never sees the
/// session. `resolve` decides where a Host goes; it only ever names ports harbor lists itself.
final class Proxy: @unchecked Sendable {
    /// Fixed (8490), and held by launchd from login (LaunchAgent), so no other program can take it.
    static let port = Ports.proxy
    static let maxHead = 16_384
    private static let headTimeout: Double = 10
    /// A plain request is dropped when nothing has moved either way for this long.
    static let idleTimeout: Double = 600
    /// Each connection has a thread while it lasts; past this many, new ones are refused.
    static let maxOpen = 128

    typealias Resolver = (_ host: String, _ done: @escaping (Names.Route) -> Void) -> Void

    static let shared = Proxy { host, done in
        DispatchQueue.main.async { MainActor.assumeIsolated { Monitor.shared.route(host: host, done) } }
    }

    private let resolve: Resolver
    private let queue = DispatchQueue(label: "local.harbor.proxy")
    // Touched only on `queue`.
    private var sources: [DispatchSourceRead] = []
    private var open = 0
    /// launchd holds only half of the port (another program has the other address): names are
    /// off, and what does arrive is told so.
    private var unavailable = false

    init(resolve: @escaping Resolver) {
        self.resolve = resolve
    }

    /// Starts listening: on launchd's sockets when it started harbor, else on 127.0.0.1 and ::1
    /// here. Debug runs use `--proxy-port`, or any free port.
    @MainActor
    func start() {
        // launchd hands over a socket even when it couldn't bind it (the port was taken).
        let handed = LaunchAgent.underLaunchd
            ? LaunchAgent.gatedProxySockets ?? LaunchAgent.activatedSockets(LaunchAgent.proxySockets) : []
        var fds = handed.filter { Sock.port(of: $0) != 0 }
        if !handed.isEmpty && !Sock.allBound(handed.map(Sock.port)) {
            // Another program has one of the two addresses on this port. Names are off (none is
            // shown), and a visit on the half launchd does hold is told why.
            DebugCLI.log("names: another program holds port \(Self.port), so they are off")
            queue.sync { unavailable = true }
            listen(on: fds)
            if let fd = LaunchAgent.pendingProxyClient {
                LaunchAgent.pendingProxyClient = nil
                queue.async { self.adopt(fd) }
            }
            return
        }
        if fds.isEmpty {
            // An agent from before names (it is replaced the next time harbor is opened), or no agent.
            guard let bound = WebServer.bindLoopback(DebugCLI.isDebugRun ? DebugCLI.proxyPort : Self.port) else {
                DebugCLI.log("names: port \(Self.port) is taken, so they are off")
                return
            }
            fds = bound.0
        }
        listen(on: fds)
        // The connection the gate already accepted (its request is still unread).
        if let fd = LaunchAgent.pendingProxyClient {
            LaunchAgent.pendingProxyClient = nil
            queue.async { self.adopt(fd) }
        }
        Monitor.shared.proxyPort = Sock.port(of: fds[0])
        DebugCLI.log("names on 127.0.0.1 and [::1] port \(Monitor.shared.proxyPort)")
    }

    /// Serves on these listening sockets.
    func listen(on fds: [Int32]) {
        queue.async { [weak self] in
            guard let self else { return }
            for fd in fds {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                src.setEventHandler { [weak self] in
                    while true {
                        let client = accept(fd, nil, nil)
                        guard client >= 0 else { return }  // EAGAIN: nothing more to accept
                        self?.adopt(client)
                    }
                }
                src.setCancelHandler { close(fd) }
                src.resume()
                self.sources.append(src)
            }
        }
    }

    /// One connection, on a thread of its own: it blocks while bytes are copied, and a GCD
    /// pool would run out of threads with a few pages' worth of hot-reload sockets.
    private func adopt(_ fd: Int32) {
        Sock.prepare(fd)
        guard open < Self.maxOpen else {
            close(fd)
            return
        }
        open += 1
        Thread.detachNewThread {
            self.serve(fd)
            close(fd)
            self.queue.async { self.open -= 1 }
        }
    }

    /// For tests: how many connections are open right now.
    var openCount: Int { queue.sync { open } }

    private func serve(_ fd: Int32) {
        let head: Data, rest: Data
        switch Sock.readHead(fd, max: Self.maxHead, within: Self.headTimeout) {
        case .ok(let h, let r): (head, rest) = (h, r)
        case .timedOut: return Sock.reply(fd, Self.page(408, "The request took too long to arrive."))
        case .tooLarge: return Sock.reply(fd, Self.page(431, "The request's headers are too large."))
        case .closed: return
        }
        guard let request = ProxyHead(head) else { return Sock.reply(fd, Self.page(400, "That isn't a request \(AppInfo.name) can pass on.")) }
        if queue.sync(execute: { unavailable }) {
            return Sock.reply(fd, Self.page(503, "Another program is using port \(Self.port), so names are off for now."))
        }
        // `resolve` answers on another thread; wait for it here, for 5 s at most.
        let answer = Answer()
        resolve(request.host) { answer.set($0) }
        guard let route = answer.wait(5) else {
            return Sock.reply(fd, Self.page(503, "\(AppInfo.name) is busy. Reload in a moment."))
        }
        switch route {
        case .refuse:
            Sock.reply(fd, Self.page(404, "Nothing here.", link: false))
        case .unknown(let name):
            Sock.reply(fd, Self.page(404, "Nothing is running as \(name)\(Names.suffix)."))
        case .forward(let target):
            // Only to this Mac's own addresses, as they are now.
            guard let up = Sock.connect(target.addresses.filter(Sock.isOwn), port: target.port) else {
                return Sock.reply(fd, Self.page(502, "The server on port \(target.port) isn't answering."))
            }
            defer { close(up) }
            Self.exchange(client: fd, server: up, request: request, rest: rest, clientAddress: Sock.peer(fd))
        }
    }

    /// A route handed from the resolver's thread to the connection's, which may have stopped waiting.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var route: Names.Route?

        func set(_ value: Names.Route) {
            lock.lock()
            route = value
            lock.unlock()
            ready.signal()
        }

        func wait(_ seconds: Double) -> Names.Route? {
            guard ready.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return route
        }
    }

    /// One request and its answer, between a client and the dev server it named. Both sockets
    /// are non-blocking; this returns when the exchange is over, and the caller closes them.
    ///
    /// - Client to server: the head as `forwarded`, then exactly this request's body (its
    ///   Content-Length, or its chunks) and nothing after it. A second request sent on the same
    ///   connection never reaches the server.
    /// - Server to client: the answer as it comes, streamed, with `Connection: close` in its
    ///   head so the browser opens a new connection for its next request.
    /// - Only when the server answers 101 to a request for a WebSocket does this become a plain
    ///   pipe both ways (hot reload), with no idle limit unless `quietSocket` gives one.
    ///   Asking for one isn't enough.
    ///
    /// At most 64 KB waits in each direction, so a slow reader slows its sender down.
    static func exchange(client: Int32, server: Int32, request: ProxyHead, rest: Data, clientAddress: String,
                         idle: Double = idleTimeout, quietSocket: Double? = nil, dropCookie: Bool = false) {
        var toServer = [UInt8](request.forwarded(client: clientAddress, dropCookie: dropCookie)), toClient: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var body = BodyScanner(request.body)
        var answer = Data()        // the server's head, until its blank line has arrived
        var headDone = false       // from here on the server's bytes go straight through
        var tunnel = false         // the server said 101: a pipe both ways
        var watching = true        // the body is done; the client is only watched for leaving
        var unread = false         // the client sent more than its request: left unread
        var ending = false         // one side has finished: deliver what's waiting, then stop
        var moved = false

        func drain(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
            while !buffer.isEmpty {
                let n = buffer.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                if n > 0 { buffer.removeFirst(n); moved = true; continue }
                return n < 0 && (errno == EAGAIN || errno == EINTR)
            }
            return true
        }
        /// What the client sent: all of it in a tunnel, else only what belongs to its request.
        func take(_ bytes: ArraySlice<UInt8>) -> Bool {
            if tunnel { toServer += bytes; return true }
            guard let n = body.take(bytes) else { return false }
            toServer += bytes.prefix(n)
            if n < bytes.count { unread = true }
            return true
        }
        /// The server's head (or heads: "100 Continue" comes before the real one).
        func readAnswer() {
            let blank = Data("\r\n\r\n".utf8)
            while !headDone, let end = answer.range(of: blank) {
                let head = answer.subdata(in: 0..<end.upperBound)
                answer = answer.subdata(in: end.upperBound..<answer.count)
                guard let status = ResponseHead.status(head) else {
                    toClient += head  // not HTTP as we know it: pass it on as it is
                    headDone = true
                    break
                }
                if status == 101 && request.isWebSocket {
                    toClient += head
                    tunnel = true
                    headDone = true
                } else if (100..<200).contains(status) && status != 101 {
                    toClient += head
                } else {
                    toClient += ResponseHead.closing(head)
                    headDone = true
                }
            }
            if headDone || answer.count > 65_536 {
                toClient += answer
                answer = Data()
                headDone = true
            }
        }
        func events(read: Bool, write: Bool) -> Int16 { Int16((read ? POLLIN : 0) | (write ? POLLOUT : 0)) }
        /// Ends without cutting the answer off: closing with unread bytes from the client would
        /// reset the connection under what was just sent.
        func finish() {
            guard unread || !body.isDone else { return }
            shutdown(client, SHUT_WR)
            var p = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let until = Date().addingTimeInterval(1)
            while until.timeIntervalSinceNow > 0, poll(&p, 1, 200) > 0, read(client, &chunk, chunk.count) > 0 {}
        }

        guard take(ArraySlice([UInt8](rest))), drain(server, &toServer) else { return }
        while !(ending && toClient.isEmpty && toServer.isEmpty) {
            let fromClient = !ending && toServer.isEmpty && (tunnel || !body.isDone || watching)
            let fromServer = !ending && toClient.isEmpty
            var p = [pollfd(fd: client, events: events(read: fromClient, write: !toClient.isEmpty), revents: 0),
                     pollfd(fd: server, events: events(read: fromServer, write: !toServer.isEmpty), revents: 0)]
            let limit: Double? = ending ? 5 : tunnel ? quietSocket : idle
            let n = poll(&p, 2, limit.map { Int32(Swift.min($0, 86_400) * 1000) } ?? -1)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }  // nothing moved in time
            moved = false
            let rc = Int32(p[0].revents), rs = Int32(p[1].revents)
            if (rc | rs) & (POLLERR | POLLNVAL) != 0 { return }
            if rc & POLLOUT != 0, !drain(client, &toClient) { return }
            if rs & POLLOUT != 0, !drain(server, &toServer) { return }
            if fromClient, rc & (POLLIN | POLLHUP) != 0 {
                if tunnel || !body.isDone {
                    let got = read(client, &chunk, chunk.count)
                    if got > 0 {
                        guard take(chunk[0..<got]), drain(server, &toServer) else { return }
                        moved = true
                    } else if got == 0 {
                        guard tunnel else { return }  // it left in the middle of its own request
                        ending = true
                        moved = true
                    } else if errno != EAGAIN && errno != EINTR {
                        return
                    }
                } else {
                    // Its request is complete, so nothing more is read from it. A look, to tell
                    // "gone" from "sent something else", which stays where it is.
                    var one: UInt8 = 0
                    let got = recv(client, &one, 1, MSG_PEEK)
                    if got == 0 { return }
                    if got > 0 { watching = false; unread = true }
                    moved = true
                }
            }
            if fromServer, rs & (POLLIN | POLLHUP) != 0 {
                let got = read(server, &chunk, chunk.count)
                if got > 0 {
                    if headDone { toClient = Array(chunk[0..<got]) } else { answer.append(contentsOf: chunk[0..<got]); readAnswer() }
                    moved = true
                    guard drain(client, &toClient) else { return }
                } else if got == 0 {
                    // It closed. With nothing sent yet, say so; a partly read head goes as it is.
                    if !headDone { toClient += answer.isEmpty ? [UInt8](page(502, "The server closed the connection without answering.")) : [UInt8](answer) }
                    toServer.removeAll()  // nobody left to send the rest of the request to
                    ending = true
                    moved = true
                    guard drain(client, &toClient) else { return }
                } else if errno != EAGAIN && errno != EINTR {
                    return
                }
            }
            // poll said ready but nothing could be done: a broken socket, not a reason to spin.
            guard moved else { return }
        }
        finish()
    }

    /// One of harbor's own small pages, for when there is nothing to forward to. `text` is
    /// escaped, and the page allows no scripts, so a made-up Host can't put markup into it.
    static func page(_ status: Int, _ text: String, link: Bool = true) -> Data {
        let safe = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let home = "http://\(WebServer.host):\(LaunchAgent.port)/"
        let body = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(AppInfo.name)</title>
        <body style="font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 34em; margin: 18vh auto; padding: 0 20px">
        <p>\(safe)</p>\(link ? "\n<p><a href=\"\(home)\">Open \(AppInfo.name)</a></p>" : "")

        """
        let head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
            + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data((head + body).utf8)
    }
}
