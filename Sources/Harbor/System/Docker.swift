import Darwin
import Foundation

/// What Docker publishes, by container. Docker Desktop forwards every published port from
/// one process of its own, so to the scanner each of them is just "Docker". The Engine API
/// says which container a port belongs to: one read-only question over this user's own
/// Docker socket, asked in-process (the `docker` command is never run), only while one of
/// Docker's processes is among the listeners, and at most every 15 seconds.
///
/// The only thing ever written to the socket is `request`. Everything read from it is
/// somebody else's text: it is stripped of control characters and cut to size here, before
/// it is a row's title, a tag or a name.
enum Docker {
    struct Container: Hashable {
        /// The Engine's id: what tells one container from the next one on the same port.
        let id: String
        let name: String            // "postgres-dev"
        let image: String           // "postgres:16"
        let project: String?        // com.docker.compose.project
        let service: String?        // com.docker.compose.service

        /// What its row is called: its service in a compose project, else the container.
        var title: String { service ?? name }
        /// Its card: the compose project, else everything Docker runs by itself.
        var group: String { project ?? "Docker" }
        /// A database's port isn't a web page: no name, no status line.
        var isDatabase: Bool { Docker.databases.contains(Docker.repository(image)) || image.lowercased().contains("mssql") }
    }

    /// The one request harbor ever sends.
    static let request = Data("GET /containers/json HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n".utf8)
    /// The whole exchange within a second, an answer of at most 1 MB, kept for 15 seconds.
    static let wait: Double = 1, keep: Double = 15, maxAnswer = 1 << 20

    /// Why a row of Docker's has no kill: the process behind it is Docker itself.
    static func noKill(_ container: Container?) -> String {
        // The command is something to copy into a shell: the name is in it only when it is a name Docker itself
        // would give ([a-zA-Z0-9][a-zA-Z0-9_.-]*), never with a space, a semicolon or a dollar sign in it.
        guard let container else {
            return "This port is held by Docker itself, which \(AppInfo.name) leaves running. Stop the container with docker stop, or in Docker's own window."
        }
        let command = isPlainName(container.name) ? "docker stop \(container.name)" : "docker stop"
        return "A container. Stop it with \(command), or in Docker's own window: the process on this port is Docker itself, which \(AppInfo.name) leaves running."
    }

    /// A container name as Docker allows them: a letter or digit, then letters, digits, "_", "." and "-".
    static func isPlainName(_ name: String) -> Bool {
        guard let first = name.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 46 || $0 == 45 }
    }

    /// Said before Docker Desktop is quit on purpose (from the list of apps): what goes with it.
    static let quitNote = "Every container stops with it."

    /// Why a quit asked for through the page won't go ahead, or nil. Quitting is for apps. Docker
    /// Desktop may be quit on purpose, from the list of apps it is in (`fromApps`, and only while
    /// it is listed there); never through one of the port rows its process holds, where a
    /// "quit" would be a kill of every container by another name.
    static func quitRefusal(path: String?, isListedApp: Bool, fromApps: Bool) -> String? {
        guard owns(path: path), !(isListedApp && fromApps) else { return nil }
        return noKill(nil)
    }

    private static let databases: Set = ["postgres", "postgresql", "pgvector", "postgis", "timescaledb", "mysql", "mysql-server", "mariadb", "redis", "redis-stack",
                                         "redis-stack-server", "valkey", "mongo",
                                         "mongodb-community-server", "memcached", "clickhouse-server", "influxdb", "etcd", "couchdb", "neo4j", "cockroach",
                                         "surrealdb", "cassandra", "elasticsearch", "opensearch"]

    /// "ghcr.io/acme/postgres:16@sha256:…" → "postgres".
    static func repository(_ image: String) -> String {
        var last = Substring(image.lowercased()).split(separator: "/").last ?? ""
        if let at = last.firstIndex(of: "@") { last = last[..<at] }
        if let colon = last.firstIndex(of: ":") { last = last[..<colon] }
        return String(last)
    }

    /// Is this listener one of Docker's own processes? Docker Desktop's backend, OrbStack's
    /// helper, or Lima's own process (Colima).
    // ponytail: only Docker Desktop was there to try. Colima forwards most ports through a plain
    // ssh process, which is nobody's in particular: those rows stay as they are. Match them by
    // the published port once there is a Colima to test against.
    static func owns(path: String?, home: String = NSHomeDirectory()) -> Bool {
        guard let path else { return false }
        // Only where the real ones are installed: a folder that merely has "Docker.app" in its path is not Docker.
        let apps = ["/Applications/", home + "/Applications/"]
        if apps.contains(where: { path.hasPrefix($0 + "Docker.app/") || path.hasPrefix($0 + "OrbStack.app/") }) { return true }
        return path.hasSuffix("/bin/limactl") && (path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/"))
    }

    /// Where this user's Docker listens, as far as harbor looks: what DOCKER_HOST names (a
    /// unix socket only), then Docker Desktop's, Colima's and OrbStack's own, then the usual
    /// link. Only a socket, and only this user's own.
    static func sockets(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") { paths.append(String(host.dropFirst(7))) }
        paths += ["\(home)/.docker/run/docker.sock", "\(home)/.colima/default/docker.sock", "\(home)/.orbstack/run/docker.sock", "/var/run/docker.sock"]
        var seen = Set<String>()
        return paths.filter { path in
            var info = stat()
            // A sockaddr_un holds 103 bytes of path.
            return path.utf8.count < 104 && stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid() && seen.insert(path).inserted
        }
    }

    /// Host port → container, from the first socket that answers. nil when none does.
    static func containers() -> [UInt16: Container]? {
        for path in sockets() {
            if let answer = ask(path), let found = parse(answer) { return found }
        }
        return nil
    }

    /// Sends `request` to the socket at `path` and reads the answer to its end, all within
    /// `wait`. Nothing else is ever sent.
    static func ask(_ path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let deadline = Date().addingTimeInterval(wait)
        func ready(_ events: Int32) -> Bool {
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            return poll(&p, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000)) > 0
        }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 || (errno == EINPROGRESS && ready(POLLOUT)) else { return nil }
        var sent = 0
        while sent < request.count {
            guard ready(POLLOUT) else { return nil }
            let n = request.withUnsafeBytes { write(fd, $0.baseAddress! + sent, request.count - sent) }
            if n > 0 { sent += n } else if errno != EAGAIN && errno != EINTR { return nil }
        }
        var answer = Data(), chunk = [UInt8](repeating: 0, count: 16384)
        while answer.count <= maxAnswer {
            guard ready(POLLIN) else { return nil }           // too slow: no answer at all, rather than half of one
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { answer.append(contentsOf: chunk[0..<n]) } else if n == 0 { return answer } else if errno != EAGAIN && errno != EINTR { return nil }
        }
        return nil                                             // more than anything real would be
    }

    /// The Engine's answer as host port → container. nil unless it is a 200 holding a list.
    /// A container with nothing published, or published over UDP, isn't in it.
    static func parse(_ answer: Data) -> [UInt16: Container]? {
        guard let end = answer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: answer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = head.first, status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200") else { return nil }
        var body = Data(answer[end.upperBound...])
        if head.dropFirst().contains(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == "transfer-encoding:chunked" }) {
            guard let whole = unchunked(body) else { return nil }
            body = whole
        }
        guard let list = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else { return nil }
        var found: [UInt16: Container] = [:]
        for item in list {
            guard let id = item["Id"] as? String, (1...64).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let name = ((item["Names"] as? [String])?.first).map({ clean(String($0.drop { $0 == "/" }), max: 60) }), !name.isEmpty else { continue }
            let labels = item["Labels"] as? [String: String] ?? [:]
            func label(_ key: String) -> String? { labels[key].map { clean($0, max: 60) }.flatMap { $0.isEmpty ? nil : $0 } }
            let container = Container(id: id, name: name, image: clean(item["Image"] as? String ?? "", max: 80),
                                      project: label("com.docker.compose.project"), service: label("com.docker.compose.service"))
            for port in item["Ports"] as? [[String: Any]] ?? [] where (port["Type"] as? String) == "tcp" {
                guard let number = port["PublicPort"] as? Int, let host = UInt16(exactly: number), host != 0, found[host] == nil else { continue }
                found[host] = container
            }
        }
        return found
    }

    /// A chunked body put back together; nil when it isn't one, or isn't whole.
    private static func unchunked(_ body: Data) -> Data? {
        var out = Data(), rest = body[...]
        let line = Data("\r\n".utf8)
        while let end = rest.range(of: line) {
            let text = String(decoding: rest[..<end.lowerBound], as: UTF8.self)
            guard let size = Int(text.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return nil }
            rest = rest[end.upperBound...]
            if size == 0 { return out }
            guard rest.count >= size + 2 else { return nil }
            out.append(rest.prefix(size))
            rest = rest.dropFirst(size + 2)
        }
        return nil
    }

    /// Text from outside, made fit to show: no control or direction-changing characters,
    /// runs of white space as one space, and no longer than `max`.
    static func clean(_ text: String, max: Int) -> String {
        let kept = text.unicodeScalars.map { scalar -> Character in
            let hidden = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator
            return hidden || scalar.properties.isWhitespace ? " " : Character(scalar)
        }
        let short = String(String(kept).split(separator: " ").joined(separator: " ").prefix(max))
        // A character can carry any number of combining marks: no more than twice `max` code points either.
        return short.unicodeScalars.count <= max * 2 ? short : String(String.UnicodeScalarView(short.unicodeScalars.prefix(max * 2)))
    }

    /// The scanner's side: which of the rows are containers, asked for no more often than
    /// every `keep` seconds, and not at all while none of Docker's processes is listening.
    struct Book {
        private var at = Date.distantPast
        private var found: [UInt16: Container] = [:]
        /// Who answers (a test puts its own here).
        var ask: () -> [UInt16: Container]? = Docker.containers
        private(set) var asked = 0

        /// `fresh` asks again whatever was kept: while a container is on the network, a
        /// scan has to see at once that another one has taken its port.
        mutating func name(_ rows: [PortRow], now: Date = Date(), fresh: Bool = false) -> [PortRow] {
            guard rows.contains(where: { Docker.owns(path: $0.path) }) else {
                (at, found) = (.distantPast, [:])
                return rows
            }
            if fresh || now.timeIntervalSince(at) >= Docker.keep {
                asked += 1
                // No answer is remembered too: a socket that hangs costs its second once per `keep`, not on every scan.
                (at, found) = (now, ask() ?? [:])
            }
            return rows.map { row in
                guard Docker.owns(path: row.path), let container = found[row.port] else { return row }
                return row.inContainer(container)
            }
        }
    }
}
