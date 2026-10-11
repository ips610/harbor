import Foundation

/// The shared "door" on port 80 (also used by headroom): launchd holds
/// 127.0.0.1:80 and [::1]:80 and starts `harbor --door` on a connection, which
/// redirects bare names to the real ports. No NSApplication, no menu bar item;
/// it exits after 10 s without a connection.
enum Door {
    static let label = "local.localhost.door"
    static let routes = ["headroom.localhost": 8460, "harbor.localhost": 8470]
    private static let idleExit: Double = 10

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // MARK: Serving (`--door`)

    private static let queue = DispatchQueue(label: "local.harbor.door")
    private static var sources: [DispatchSourceRead] = []
    private static var lastActivity = Date()

    static func run() -> Never {
        let fds = LaunchAgent.activatedSockets()
        if fds.isEmpty { exit(1) }  // not started by launchd: nothing to serve
        queue.sync {
            for fd in fds {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                src.setEventHandler { acceptAll(fd) }
                src.resume()
                sources.append(src)
            }
            scheduleIdleCheck()
        }
        dispatchMain()
    }

    private static func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + 2) {
            if Date().timeIntervalSince(lastActivity) >= idleExit { exit(0) }
            scheduleIdleCheck()
        }
    }

    private static func acceptAll(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            lastActivity = Date()
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 1, tv_usec: 0)  // short reads, so the 5 s deadline below is enforced
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global().async { answer(fd) }
        }
    }

    /// Reads the request head (blocking, 5 s timeout) and answers by Host.
    private static func answer(_ fd: Int32) {
        defer { close(fd) }
        var head = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // A deadline for the whole request, not per read: a slow client that
        // dribbles one byte per read can't hold the thread past 5 s.
        let deadline = Date().addingTimeInterval(5)
        while head.count < 16_384, head.range(of: Data("\r\n\r\n".utf8)) == nil {
            if Date() >= deadline { return }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if n < 0 && errno == EAGAIN && Date() < deadline { continue }  // read timed out, still time left
                return
            }
            head.append(contentsOf: chunk[0..<n])
        }
        write(fd, response(for: head))
    }

    static func response(for head: Data) -> Data {
        let text = String(decoding: head, as: UTF8.self)
        var host = ""
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        // Drop a port, but keep IPv6 brackets intact.
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        if host.hasSuffix(".") { host.removeLast() }
        // 302, never 301: browsers cache 301 forever.
        if let port = routes[host] {
            return Data(("HTTP/1.1 302 Found\r\nLocation: http://\(host):\(port)/\r\nCache-Control: no-store\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8)
        }
        let body = "Nothing here. Try harbor.localhost or headroom.localhost.\n"
        return Data(("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    private static func write(_ fd: Int32, _ data: Data) {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            sent += n
        }
    }

    // MARK: Installing

    /// Install the door unless someone (headroom) already has it loaded with a
    /// binary that exists. Take it over if it points at a missing binary.
    static func ensureInstalled() {
        guard Bundle.main.bundleURL.pathExtension == "app", let exe = Bundle.main.executablePath else { return }
        let loaded = LaunchAgent.launchctl(["print", "\(LaunchAgent.domain)/\(label)"])
        if loaded {
            let current = (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first
            if let current, FileManager.default.isExecutableFile(atPath: current) { return }
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--door"],
            "Sockets": [
                "v4": ["SockNodeName": "127.0.0.1", "SockServiceName": "80", "SockFamily": "IPv4"],
                "v6": ["SockNodeName": "::1", "SockServiceName": "80", "SockFamily": "IPv6"],
            ],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: plistURL, options: .atomic)) != nil else { return }
        if loaded { LaunchAgent.launchctl(["bootout", "\(LaunchAgent.domain)/\(label)"]) }
        for _ in 0..<15 {
            if LaunchAgent.launchctl(["bootstrap", LaunchAgent.domain, plistURL.path]) { return }
            usleep(200_000)
        }
    }
}
