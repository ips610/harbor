import CommonCrypto
import CryptoKit
import Foundation
import Network
import OSLog
import Security
import dnssd

// MARK: - Rules

/// On network: a project the user switched on is served to other devices on the same network
/// as `http://<name>.local/`, optionally behind a password. This file is all of it: the rules
/// (pure, tested without a socket), the password gate, the Bonjour record and the listener.
///
/// It is plain http on a local network. The password keeps out people browsing the Wi-Fi.
/// Someone capturing traffic can read the pages and reuse a signed-in visitor's session, and
/// someone who can change traffic can show a fake sign-in page and learn the password.
enum Lan {
    static let suffix = ".local"
    /// Harbor's cookie on a shared name, and its own paths there. Neither ever reaches the project.
    static let cookie = "__harbor_visitor"
    static let paths = "/__harbor/"
    /// What the panel says about it, in the menu and on the page.
    static let plainHttp = "Plain http on this network. A password keeps out people browsing the Wi-Fi. It doesn't stop someone who can capture or change the Wi-Fi's traffic. For anything private, use share."
    /// PBKDF2 rounds for the sign-in. The page does them in plain JavaScript (there is no
    /// crypto.subtle on http), so this is what a phone does in well under a second: measured
    /// in Chrome, about 40 ms on an M-series Mac and 240 ms with the CPU slowed six times.
    static let iterations = 50_000
    static let minPassword = 8

    /// Eight characters a person can read out: no i, l, o, 0 or 1.
    static func randomPassword() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // 31 letters: a byte under 248 maps evenly; the few above are drawn again.
        return String(bytes.map { byte -> Character in
            var b = byte
            while b >= 248 { b = UInt8.random(in: 0...255) }
            return letters[Int(b) % letters.count]
        })
    }

    static func token(_ bytes: Int = 24) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &raw) != errSecSuccess { raw = raw.map { _ in UInt8.random(in: 0...255) } }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    /// The passwords everybody tries first. Short on purpose: length is what a password is
    /// asked for, and these are the ones that have it and are still no password at all.
    static let obvious: Set = ["password", "password1", "passw0rd", "qwertyui", "qwertyuiop", "iloveyou"]

    /// Why this can't be the password, or nil when it can. `names` are what the project goes by.
    static func passwordProblem(_ password: String, names: [String] = []) -> String? {
        guard password.count >= minPassword, password.utf8.count <= 128 else { return "A password needs at least \(minPassword) characters." }
        let lower = password.lowercased(), codes = lower.unicodeScalars.map { Int($0.value) }
        let steps = Set(zip(codes, codes.dropFirst()).map { $1 - $0 })
        // One character over and over (step 0), or a run up or down (12345678, hgfedcba).
        let easy = obvious.contains(lower) || steps == [0] || steps == [1] || steps == [-1]
            || names.contains { lower == $0 || lower == $0 + suffix }
        return easy ? "That one is too easy to guess. Type another, or use a new random one." : nil
    }

    /// Why `name` can't be a project's name on the network, or nil when it can. `others` are
    /// the names other projects have there; `machine` is this Mac's own Bonjour name.
    static func nameProblem(_ name: String, others: Set<String>, machine: String?) -> String? {
        guard Names.isLabel(name, max: Names.maxLength) else {
            return "Use lowercase letters, numbers and hyphens, 1 to \(Names.maxLength) characters."
        }
        let own = machine.map { $0.lowercased().replacingOccurrences(of: suffix, with: "") }
        if Names.reserved.contains(name) || name == "localhost" || name == own { return "\(name)\(suffix) is taken on this Mac. Pick another name." }
        // Names other devices look up by themselves, to find a proxy or a tunnel.
        if ["wpad", "isatap"].contains(name) { return "\(name)\(suffix) is a name devices look up by themselves. Pick another name." }
        if others.contains(name) { return "\(name)\(suffix) is already another project's name." }
        return nil
    }

    /// The shared name a request is for, by its Host: exactly `<name>.local`, with the
    /// listener's port when that isn't 80. Anything else is nobody's: a `.localhost` name,
    /// harbor's own page, an address, an unshared project.
    static func name(forHost host: String, port: UInt16, isShared: (String) -> Bool) -> String? {
        var host = host.lowercased()
        if port != 80 {
            guard host.hasSuffix(":\(port)") else { return nil }
            host.removeLast(String(port).count + 1)
        }
        guard host.hasSuffix(suffix) else { return nil }
        let name = String(host.dropLast(suffix.count))
        return Names.isLabel(name) && isShared(name) ? name : nil
    }

    /// A shared name's own origin, as a browser writes it: "http://storefront.local", with the port when it isn't 80.
    static func origin(_ name: String, port: UInt16) -> String {
        "http://\(name)\(suffix)" + (port == 80 ? "" : ":\(port)")
    }

    /// Is this one of the sign-in page's own calls? Its Origin is exactly the name's, it isn't
    /// marked as coming from another site, and it is JSON, which a page on another site can't
    /// send without asking first. A script on the network can forge all three; then its
    /// tries count against its own address.
    static func isOwnPage(_ request: ProxyHead, name: String, port: UInt16) -> Bool {
        let type = request.values("content-type")
        return request.values("origin") == [origin(name, port: port)]
            && !request.values("sec-fetch-site").contains { $0.lowercased() == "cross-site" }
            && type.count == 1 && type[0].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// Another device on the network already has `name`: the next one that is free here.
    static func nextName(after name: String, taken: (String) -> Bool) -> String {
        var n = 2
        while true {
            let end = "-\(n)", next = String(name.prefix(Names.maxLength - end.count)) + end
            if !taken(next) { return next }
            n += 1
        }
    }

    /// On port 80 the listener hears every interface (a low port can only be bound on all of
    /// them). A connection is answered only when it came in on the address harbor announced.
    static func accepts(local: String, announced: String?) -> Bool {
        announced != nil && local == announced
    }

    enum Change { case same, moved, left }

    /// What became of the network a project was shared on. Another interface, another router,
    /// or a router with the same address but other hardware: a different network, which ends
    /// the sharing. The same router handing this Mac a new address: moved, and the name is
    /// announced again there. No network at the moment is not yet a different one. A new
    /// address counts as the same network only when the router is provably the same one.
    static func change(from announced: LAN.Network?, to now: LAN.Network?) -> Change {
        guard let announced, let now else { return .same }
        if announced.interface != now.interface || announced.router != now.router { return .left }
        let known = announced.routerHardware != nil && now.routerHardware != nil
        if known, announced.routerHardware != now.routerHardware { return .left }
        if announced.address == now.address { return .same }
        return known ? .moved : .left
    }

    /// A Cookie header's value without harbor's cookie; nil when nothing else was in it.
    static func strip(_ cookies: String) -> String? {
        let kept = cookies.split(separator: ";").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(cookie + "=") }
        let value = kept.joined(separator: ";").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The visitor's token from a request's Cookie headers.
    static func visitor(in cookies: [String]) -> String? {
        for header in cookies {
            for part in header.split(separator: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces)
                if pair.hasPrefix(cookie + "=") { return String(pair.dropFirst(cookie.count + 1)) }
            }
        }
        return nil
    }

    // MARK: The sign-in's arithmetic (the page does the same in JavaScript, see `crypto`)

    /// PBKDF2-HMAC-SHA256 of the password, 32 bytes.
    static func key(password: String, salt: String, iterations: Int = iterations) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let s = Array(salt.utf8)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, s, s.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        return Data(out)
    }

    /// What a visitor who knows the password answers to a challenge: HMAC-SHA256 under the
    /// derived key of the name and the one-time nonce, in hex. The password itself never travels.
    static func proof(key: Data, name: String, nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("\(name):\(nonce)".utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Under a password in the panel: whose it is when the project has several servers, and
    /// how many devices are signed in. nil when there is nothing to say.
    static func passwordNote(project: String, several: Bool, devices: Int) -> String? {
        let whose = several ? "One password for all of \(project)'s servers on the network: a visitor signs in once." : nil
        let who = devices > 0 ? "\(devices) device\(devices == 1 ? "" : "s") signed in. A new password signs \(devices == 1 ? "it" : "them") out." : nil
        let both = [whose, who].compactMap { $0 }
        return both.isEmpty ? nil : both.joined(separator: " ")
    }

    /// When a second server of a project is on the network: how a page reaches it.
    static let callByName = "A page can only call this one by its .local name, not localhost."

    /// What macOS itself asks the first time something goes on the network, and where to put
    /// a No right. Harbor can't answer for the user, and can't see the firewall's answer.
    static func systemAsks(firewall: Bool) -> String {
        firewall
            ? "The first time, macOS asks two things: whether \(AppInfo.name) may find devices on local networks (when you turn this on) and, because the firewall is on, whether it may accept incoming connections (when the first device connects). Choose Allow for both. To put a No right: System Settings → Privacy & Security → Local Network, and Network → Firewall → Options."
            : "The first time, macOS asks whether \(AppInfo.name) may find devices on local networks: choose Allow. To put a No right: System Settings → Privacy & Security → Local Network."
    }

    /// Said while macOS hasn't announced a shared name (it is waiting for that Allow, or got a No).
    static func notAnnounced(_ name: String) -> String {
        "macOS hasn't announced \(name)\(suffix) yet, so other devices can't find it. Allow \(AppInfo.name) under System Settings → Privacy & Security → Local Network, then turn this off and on."
    }

    /// A reply with nothing in it: what everything that isn't a shared name gets.
    static func bare(_ status: Int) -> Data {
        Data("HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
    }

    static func json(_ status: Int, _ object: [String: Any], cookie: String? = nil) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        if let cookie { head += "Set-Cookie: \(cookie)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

// MARK: - The gate

/// What a request to a shared name gets, decided before anything is sent to the project.
enum Gate {
    enum Step: Equatable {
        /// On to the project.
        case forward
        /// Harbor's sign-in page; nothing reaches the project.
        case signIn
        /// The sign-in's two calls, answered by harbor.
        case challenge, enter
        /// One of harbor's paths that isn't there: never forwarded either.
        case notFound
    }

    /// `session` is whether the request carries a valid visitor cookie for this name. A
    /// WebSocket upgrade is a request like any other here.
    static func step(method: String, target: String, protected: Bool, session: Bool) -> Step {
        let path = String(target.prefix { $0 != "?" && $0 != "#" })
        if path.hasPrefix(Lan.paths) || path + "/" == Lan.paths {
            guard protected, method == "POST" else { return .notFound }
            switch path.dropFirst(Lan.paths.count) {
            case "challenge": return .challenge
            case "enter": return .enter
            default: return .notFound
            }
        }
        return !protected || session ? .forward : .signIn
    }
}

/// Who is signed in to which shared name, the one-time challenges, and the wrong tries.
/// Everything here is bounded, and nothing is kept for a challenge that was only asked for,
/// so a visitor can neither grow harbor's memory nor push another visitor's sign-in out.
/// Not thread-safe: OnNetwork uses it under its lock. The clock is passed in.
struct Visitors {
    static let nonceLife: TimeInterval = 120
    static let sessionLife: TimeInterval = 12 * 3600
    static let maxUsed = 1024, maxSessions = 1024, maxAddresses = 512
    /// Per address: this many wrong tries lock it, for 5 minutes, then 10, 20, 40, an hour.
    static let triesPerAddress = 5
    /// Across everyone: more than this many wrong tries in 10 minutes and the owner is told,
    /// and every answer for that name is held back `slowBy` seconds for 10 minutes. There is
    /// no lock for the whole name.
    static let manyTries = 30
    static let slowBy: TimeInterval = 2

    /// Made when harbor starts and never stored: what it marks its challenges with.
    private let key = SymmetricKey(size: .bits256)
    private var used: [String: Date] = [:]            // challenges that let someone in, until they'd end anyway
    /// A session is for one name, and remembers the project that name belongs to and the
    /// address it was signed in from: from that address the project's other names open too
    /// (see `sibling`). There is no second table to fall out of step with this one.
    private var sessions: [String: (name: String, project: String, address: String, until: Date)] = [:]
    private struct Tries {
        var wrong = 0
        var locks = 0
        var lockedUntil = Date.distantPast
        var last: Date
    }
    private var addresses: [String: Tries] = [:]      // "name address"
    private var recent: [String: [Date]] = [:]        // wrong tries per name in the last 10 minutes
    private var slowUntil: [String: Date] = [:]

    var counts: (used: Int, sessions: Int, addresses: Int, recent: Int) {
        (used.count, sessions.count, addresses.count, recent.values.reduce(0) { $0 + $1.count })
    }

    // Challenges: for one name, two minutes, and good for one sign-in.

    private func mark(_ name: String, _ body: Substring) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("\(name)|\(body)".utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// A challenge: when it ends, something random, and harbor's mark over the name and both.
    /// Nothing is kept for it, so asking for a thousand costs nothing and pushes nobody's out.
    func challenge(for name: String, now: Date) -> String {
        let body = "\(Int(now.timeIntervalSince1970 + Self.nonceLife)).\(Lan.token(16))"
        return body + "." + mark(name, body[...])
    }

    /// When a challenge ends, if it is one harbor made for `name`, still in time, and not
    /// yet used to sign in. nil for anything else: made up, changed, made for another name
    /// or by another launch, too old, used.
    func end(of nonce: String, for name: String, now: Date) -> Date? {
        guard nonce.utf8.count <= 160, let dot = nonce.lastIndex(of: "."), let until = Int(nonce.prefix { $0 != "." }),
              WebServer.constantEquals(String(nonce[nonce.index(after: dot)...]), mark(name, nonce[..<dot])),
              Double(until) > now.timeIntervalSince1970, used[nonce] == nil else { return nil }
        return Date(timeIntervalSince1970: Double(until))
    }

    /// Uses a challenge up: it has just let someone in, and is remembered until it would end
    /// anyway. False when so many are remembered at once that there is no room for one more
    /// (then nobody gets in on it).
    mutating func use(_ nonce: String, until: Date, now: Date) -> Bool {
        used = used.filter { $0.value > now }
        guard used.count < Self.maxUsed else { return false }
        used[nonce] = until
        return true
    }

    // Sessions: twelve hours, for one name.

    mutating func signIn(to name: String, project: String = "", from address: String = "", now: Date) -> String {
        sessions = sessions.filter { $0.value.until > now }
        if sessions.count >= Self.maxSessions, let oldest = sessions.min(by: { $0.value.until < $1.value.until }) { sessions[oldest.key] = nil }
        let token = Lan.token()
        sessions[token] = (name, project, address, now.addingTimeInterval(Self.sessionLife))
        return token
    }

    /// A page on one of a project's names calls another of its servers by that server's
    /// name. To the browser that is another site: it sends no cookie, and the question it
    /// asks first (the preflight) never carries one. So a device that has signed in to a
    /// project is known by its address for that project's other names, for as long as its
    /// session lasts. This is that session's name, when `address` has one on another name of
    /// `project`; nil otherwise.
    ///
    /// - `address` is the connection's own other end, never a header.
    /// - Only within one project. The name that was signed in on still wants its cookie.
    /// - It ends with the session it rests on, every way a session ends.
    /// - Devices behind one address (a hotspot, a router doing NAT) count as one here.
    func sibling(of name: String, project: String, address: String, now: Date) -> String? {
        guard !project.isEmpty, !address.isEmpty else { return nil }
        return sessions.values.first { $0.project == project && $0.address == address && $0.name != name && now < $0.until }?.name
    }

    /// How many devices (addresses) are signed in to a project right now.
    func devices(project: String, now: Date) -> Int {
        Set(sessions.values.filter { $0.project == project && now < $0.until }.map(\.address)).count
    }

    func isSignedIn(_ token: String?, to name: String, now: Date) -> Bool {
        guard let token, let found = sessions[token] else { return false }
        return found.name == name && now < found.until
    }

    /// Sharing stopped, or the password changed: everyone signs in again.
    mutating func forget(_ name: String) {
        sessions = sessions.filter { $0.value.name != name }
        recent[name] = nil
        slowUntil[name] = nil
    }

    // Wrong tries.

    /// Seconds this address must still wait before trying `name` again, or nil.
    func wait(address: String, name: String, now: Date) -> Int? {
        func seconds(_ until: Date) -> Int? { until > now ? Int(until.timeIntervalSince(now).rounded(.up)) : nil }
        if let tries = addresses["\(name) \(address)"] { return seconds(tries.lockedUntil) }
        // The table is full and every address in it is waiting: a new one waits for the first
        // of them, rather than pushing one out and letting it try again early.
        guard addresses.count >= Self.maxAddresses else { return nil }
        return addresses.values.map(\.lockedUntil).min().flatMap(seconds)
    }

    /// Counts a wrong try. True when it took the name over "many" (the owner is told, once).
    mutating func wrong(address: String, name: String, now: Date) -> Bool {
        let id = "\(name) \(address)"
        // Forget addresses that have been quiet for two hours. If the table is still full, the
        // quietest one that isn't waiting makes room.
        addresses = addresses.filter { now.timeIntervalSince($0.value.last) < 7200 || $0.value.lockedUntil > now }
        let full = addresses[id] == nil && addresses.count >= Self.maxAddresses
        if full {
            guard let quietest = addresses.filter({ $0.value.lockedUntil <= now }).min(by: { $0.value.last < $1.value.last }) else { return false }
            addresses[quietest.key] = nil
        }
        // Under that pressure a newcomer's first lock is the long one, so a crowd of
        // addresses taking turns gets no more tries than the table has room for.
        var tries = addresses[id] ?? Tries(locks: full ? 4 : 0, last: now)
        tries.wrong += 1
        tries.last = now
        if tries.wrong >= Self.triesPerAddress {
            tries.lockedUntil = now.addingTimeInterval(min(300 * pow(2, Double(tries.locks)), 3600))
            tries.locks += 1
            tries.wrong = 0
        }
        addresses[id] = tries

        var window = (recent[name] ?? []).filter { now.timeIntervalSince($0) < 600 }
        window.append(now)
        guard window.count > Self.manyTries else {
            recent[name] = window
            return false
        }
        recent[name] = nil
        let already = (slowUntil[name] ?? .distantPast) > now
        slowUntil[name] = now.addingTimeInterval(600)
        return !already
    }

    /// How long every answer for `name` is held back right now: someone may be guessing.
    func delay(for name: String, now: Date) -> TimeInterval {
        (slowUntil[name] ?? .distantPast) > now ? Self.slowBy : 0
    }

    /// A right answer clears that address's count.
    mutating func right(address: String, name: String) {
        addresses["\(name) \(address)"] = nil
    }
}

// MARK: - Passwords

/// A project's network password, by project folder. Kept in a file only this account can
/// read, beside the sign-in session. The owner has to be able to read it out to a friend,
/// and the Keychain would ask for the login password after every update: harbor isn't
/// signed with an Apple Developer ID, so to the Keychain each build is a different app.
/// Never in defaults or a log. Debug runs and tests keep them in memory.
///
/// A password that can't be read is never "no password": `read` says `.unreadable`, and a
/// project that had one isn't shared until its owner sets a new one.
enum Passwords {
    enum Read: Equatable { case none, password(String), unreadable }

    private static let lock = NSLock()
    private static var memory: [String: String] = [:]
    static var inMemory = DebugCLI.isDebugRun || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    /// Where they are kept (a test points this at a file of its own).
    static var file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(LaunchAgent.label)/network-passwords")

    static func read(_ key: String) -> Read {
        lock.lock()
        defer { lock.unlock() }
        if inMemory { return memory[key].map(Read.password) ?? .none }
        return read(key, in: file)
    }

    static func read(_ key: String, in file: URL) -> Read {
        guard let all = load(file) else { return .unreadable }
        return all[key].map(Read.password) ?? .none
    }

    /// Saves the password, or removes it (nil). False when it couldn't be written.
    @discardableResult
    static func set(_ key: String, _ password: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inMemory {
            memory[key] = password
            return true
        }
        return store(key, password, in: file)
    }

    /// What the file holds: nothing when there is no file, nil when there is one and it
    /// can't be read as what it should be (then nobody's password is known, which is not
    /// the same as nobody having one).
    static func load(_ file: URL) -> [String: String]? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return errno == ENOENT ? [:] : nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 1 << 20 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: String]
    }

    /// One project's password into the file (nil: out of it). A file that can't be read is
    /// not carried over: whoever is writing is setting a password anew.
    static func store(_ key: String, _ password: String?, in file: URL) -> Bool {
        var all = load(file) ?? [:]
        all[key] = password
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A new file, 0600 from the moment it exists (O_EXCL, and no following of a link put
        // in its place), then put where the old one was in one step.
        let new = file.path + ".new"
        unlink(new)
        let fd = open(new, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        close(fd)
        guard written, rename(new, file.path) == 0 else {
            unlink(new)
            return false
        }
        return true
    }

    // MARK: Out of the Keychain, once

    /// The Keychain as the move needs it. `read` is nil for an item that can't be read
    /// without asking the owner.
    struct Keychain {
        var accounts: () -> [String]
        var read: (String) -> String?
        var delete: (String) -> Void
    }

    /// Moves what 1.4.0 kept in the Keychain into the file. Never with a prompt: an item
    /// that would need one stays where it is, and its project has no saved password until
    /// the owner sets one. A password already in the file wins, and an item is deleted only
    /// once its password is safely in the file.
    @discardableResult
    static func move(from keychain: Keychain, into file: URL) -> Int {
        var moved = 0
        for account in keychain.accounts() {
            guard let password = keychain.read(account), let all = load(file) else { continue }
            guard all[account] != nil || store(account, password, in: file) else { continue }
            keychain.delete(account)
            moved += 1
        }
        return moved
    }

    /// The one place harbor still calls into the Keychain: once, at the first launch of a
    /// build that keeps passwords in the file, and with every kind of asking forbidden.
    static func moveOutOfKeychain() {
        guard !inMemory, !DebugCLI.defaults.bool(forKey: "lanPasswordsMoved") else { return }
        DebugCLI.defaults.set(true, forKey: "lanPasswordsMoved")
        let service = LaunchAgent.label + ".on-network"
        func query(_ account: String?) -> [CFString: Any] {
            var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
            if let account { q[kSecAttrAccount] = account }
            return q
        }
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        lock.lock()
        defer { lock.unlock() }
        move(from: Keychain(
            accounts: {
                var found: CFTypeRef?
                var q = query(nil)
                q[kSecMatchLimit] = kSecMatchLimitAll
                q[kSecReturnAttributes] = true
                guard SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess else { return [] }
                return ((found as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
            },
            read: { account in
                var found: CFTypeRef?
                var q = query(account)
                q[kSecReturnData] = true
                q[kSecMatchLimit] = kSecMatchLimitOne
                guard SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            },
            delete: { _ = SecItemDelete(query($0) as CFDictionary) }), into: file)
    }
}

// MARK: - Bonjour

/// Announces `<name>.local` as this Mac's address on one interface, through the system's
/// own responder (dnssd; nothing is shelled out). All records hang on one connection: when
/// it closes (sharing stops, harbor quits, or it crashes) the system withdraws them.
final class Bonjour {
    private final class Record {
        let name: String
        weak var owner: Bonjour?
        var ref: DNSRecordRef?
        init(name: String, owner: Bonjour) { self.name = name; self.owner = owner }
    }

    private var connection: DNSServiceRef?
    private var records: [String: Record] = [:]
    private let queue: DispatchQueue
    /// Runs on `queue` when the responder has answered: nil for announced, or the error
    /// (kDNSServiceErr_NameConflict when another device already has the name).
    var result: ((_ name: String, _ error: DNSServiceErrorType) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// False when the record couldn't even be handed to the responder.
    func announce(_ name: String, address: String, interface: String) -> Bool {
        withdraw(name)
        var ip = in_addr()
        guard inet_pton(AF_INET, address, &ip) == 1 else { return false }
        if connection == nil {
            var ref: DNSServiceRef?
            guard DNSServiceCreateConnection(&ref) == kDNSServiceErr_NoError, let ref else { return false }
            DNSServiceSetDispatchQueue(ref, queue)
            connection = ref
        }
        let record = Record(name: name, owner: self)
        var ref: DNSRecordRef?
        // Unique: the responder first asks the network whether anyone has the name.
        let error = withUnsafeBytes(of: &ip) { bytes in
            DNSServiceRegisterRecord(connection, &ref, kDNSServiceFlagsUnique, if_nametoindex(interface), name + Lan.suffix + ".",
                                     UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, bytes.baseAddress, 120,
                                     { _, _, _, error, context in
                                         guard let context else { return }
                                         let record = Unmanaged<Record>.fromOpaque(context).takeUnretainedValue()
                                         record.owner?.result?(record.name, error)
                                     }, Unmanaged.passUnretained(record).toOpaque())
        }
        guard error == kDNSServiceErr_NoError else { return false }
        record.ref = ref
        records[name] = record
        return true
    }

    func withdraw(_ name: String) {
        guard let record = records.removeValue(forKey: name), let ref = record.ref, let connection else { return }
        DNSServiceRemoveRecord(connection, ref, 0)
        if records.isEmpty { withdrawAll() }
    }

    func withdrawAll() {
        records = [:]
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
    }

    deinit { withdrawAll() }
}

// MARK: - The listener

/// Serves the shared names to the network. One listener, open only while something is
/// shared. It answers only connections that arrived on the announced address, only for a
/// Host that is exactly a shared name, and only after the gate. It knows nothing of harbor's
/// page or the `.localhost` names.
final class OnNetwork: @unchecked Sendable {
    static let shared = OnNetwork(announces: DebugCLI.lanAddress == nil)

    /// The one server a name was shared for: its process (its pid, and when it started) and
    /// its port. A share is pinned to it. When it goes away the sharing stops; it never moves
    /// on to whatever else the project runs, or to whatever listens on that port next.
    struct Server: Equatable {
        let pid: pid_t
        let identity: String                 // LibProc.identity(pid) when it was shared
        let target: Names.Target

        /// Still that process, and still listening on that port? Asked before every request.
        var isStillThere: Bool {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
            return LibProc.identity(pid) == identity && LibProc.listeners(pid: pid, fds: &fds).contains { $0.port == target.port }
        }
    }

    struct Share {
        var project = ""                     // its folder: the password and the sign-in are the project's
        let server: Server
        var salt = Lan.token(16)             // new with every password, so it also tells one sharing from the next
        var secret: Data?                    // the derived key; nil when there is no password
    }

    /// Told on the main thread: a name another device already had was replaced; a name is
    /// getting many wrong passwords; macOS answered about announcing a name (it only answers
    /// once it is allowed to); a name's server is gone.
    var renamed: ((_ from: String, _ to: String) -> Void)?
    var manyWrong: ((_ name: String) -> Void)?
    var answered: ((_ name: String, _ announced: Bool) -> Void)?
    var gone: ((_ name: String) -> Void)?
    /// On port 80 harbor's own door has to step aside while the listener is bound (see
    /// Door.aside). Set for the copy that manages the agents, and for a debug run pointed at
    /// a throwaway door; nil: the port is simply bound.
    var aside: ((_ bind: () -> Bool, _ answers: () -> Bool) -> (opening: Door.Opening, doorBack: Bool))?

    private static let log = Logger(subsystem: "local.harbor", category: "network")
    /// Connections at once: from everyone (as many as the `.localhost` proxy takes), and
    /// from any one address. A browser holds six for a page, one more for every WebSocket,
    /// and keeps the WebSockets of pages it has left for a while, so one visitor needs room.
    static let maxOpen = 128, maxPerAddress = 24
    /// A whole request head within this many seconds, or the connection is dropped.
    static let headWithin: Double = 5
    /// A WebSocket with nothing passing either way for this long is closed: ten minutes.
    let quietSocket: Double
    /// False only for tests and `--lan-address`: the listener without the Bonjour record.
    private let announces: Bool
    private let queue = DispatchQueue(label: "local.harbor.network")
    private let lock = NSLock()
    // Under `lock`.
    private var shares: [String: Share] = [:]       // by name on the network
    private var visitors = Visitors()
    private var announced: LAN.Network?
    private var boundPort: UInt16 = 0
    private var held6 = false
    // Per name, what is being passed on right now: the visitor's socket, the server's, and
    // the name whose session let it in when it came without a cookie of its own (`sibling`).
    private var live: [String: [Int32: (server: Int32, via: String?)]] = [:]
    // On `queue`.
    private var source: DispatchSourceRead?
    private var source6: DispatchSourceRead?
    private var open = 0
    private var openFrom: [String: Int] = [:]       // per visitor address
    private lazy var bonjour: Bonjour = {
        let b = Bonjour(queue: queue)
        b.result = { [weak self] name, error in self?.announcedResult(name, error) }
        return b
    }()
    private var watcher: NWPathMonitor?
    private var wrongTries: [String: Int] = [:]     // per name, for the log

    init(announces: Bool = true, quietSocket: Double = 600) {
        self.announces = announces
        self.quietSocket = quietSocket
    }

    /// The visitors' book, under the lock. For tests, which have only one address to come from.
    func withVisitors<T>(_ body: (inout Visitors) -> T) -> T { locked { body(&visitors) } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var port: UInt16 { locked { boundPort } }
    /// While listening: does harbor have the same port on IPv6 as well? When not, another
    /// program has it, and could answer there in a shared name's place.
    var holdsIPv6: Bool { locked { held6 } }
    var names: [String] { locked { Array(shares.keys) } }

    /// How starting went: the port it is served on (nil: nothing is shared), why not, and
    /// whether the door is where it was (it steps aside while port 80 is bound).
    struct Begun {
        var port: UInt16?
        var opening = Door.Opening.open
        var doorBack = true
    }

    func start(name: String, project: String = "", server: Server, password: String?, on network: LAN.Network, port wanted: UInt16) -> UInt16? {
        begin(name: name, project: project, server: server, password: password, on: network, port: wanted).port
    }

    /// Devices signed in to a project right now, for its owner's panel.
    func devices(project: String) -> Int { locked { visitors.devices(project: project, now: Date()) } }

    /// Starts serving `name` from `server` on `network`, opening the listener if this is the
    /// first one; later names use the listener that is there. One at a time: two started at
    /// once take their turns on `queue`, and only the first opens anything.
    func begin(name: String, project: String = "", server: Server, password: String?, on network: LAN.Network, port wanted: UInt16) -> Begun {
        queue.sync { () -> Begun in
            var begun = Begun()
            if source == nil {
                let every = Self.hearsEveryInterface(wanted)
                var listener: (fd: Int32, port: UInt16)?
                var hold: Int32?
                // The listener, and the same port on IPv6 in the same breath: once the door is back, neither could be bound.
                let bind = { () -> Bool in
                    listener = Self.bind(wanted, on: every ? nil : network.address)
                    if let listener { hold = Self.hold6(listener.port) }
                    return listener != nil
                }
                // Is another program on that port? (Asked only when it couldn't be bound.)
                let answers = { () -> Bool in
                    guard let fd = Sock.connect(["127.0.0.1", network.address], port: wanted, within: 0.5) else { return false }
                    close(fd)
                    return true
                }
                if every, let aside {
                    (begun.opening, begun.doorBack) = aside(bind, answers)
                } else if !bind() {
                    begun.opening = answers() ? .taken : .busy
                }
                guard let bound = listener else {
                    Self.log.notice("port \(wanted, privacy: .public) couldn't be had: \(String(describing: begun.opening), privacy: .public) door back=\(begun.doorBack, privacy: .public)")
                    return begun
                }
                locked { boundPort = bound.port }
                let src = DispatchSource.makeReadSource(fileDescriptor: bound.fd, queue: queue)
                src.setEventHandler { [weak self] in self?.acceptAll(bound.fd) }
                src.setCancelHandler { close(bound.fd) }
                src.resume()
                source = src
                // The same port on IPv6, only so that nobody else has it. Nothing is served
                // there: whatever arrives is closed. Without it sharing works all the same.
                if let fd6 = hold {
                    let src6 = DispatchSource.makeReadSource(fileDescriptor: fd6, queue: queue)
                    src6.setEventHandler { while case let c = accept(fd6, nil, nil), c >= 0 { close(c) } }
                    src6.setCancelHandler { close(fd6) }
                    src6.resume()
                    source6 = src6
                } else {
                    Self.log.notice("port \(bound.port, privacy: .public) on IPv6 is another program's: not held")
                }
                locked { held6 = source6 != nil }
                watch()
            }
            var share = Share(project: project, server: server)
            if let password { share.secret = Lan.key(password: password, salt: share.salt) }
            locked {
                cut(name)                           // the same name shared again: nothing of before stays open
                visitors.forget(name)
                shares[name] = share
                announced = network
            }
            if announces, !bonjour.announce(name, address: network.address, interface: network.interface) { announcedResult(name, DNSServiceErrorType(kDNSServiceErr_Unknown)) }
            Self.log.notice("on network: \(name, privacy: .public) password=\(password != nil, privacy: .public) port=\(self.port, privacy: .public)")
            begun.port = port
            return begun
        }
    }

    /// Stops serving `name`: its visitors are signed out, what was open for them is cut, and
    /// its record is withdrawn. The listener closes with the last one.
    func stop(_ name: String) {
        queue.sync {
            let left = locked { () -> Int in
                shares[name] = nil
                visitors.forget(name)
                cut(name)
                return shares.count
            }
            bonjour.withdraw(name)
            Self.log.notice("off network: \(name, privacy: .public) wrong tries while on: \(self.wrongTries[name] ?? 0, privacy: .public)")
            wrongTries[name] = nil
            if left == 0 { closeAll() }
        }
    }

    func stopAll() {
        queue.sync {
            locked {
                shares.keys.forEach { visitors.forget($0) }
                shares = [:]
                live.keys.forEach(cut)
            }
            closeAll()
        }
    }

    private func closeAll() {
        bonjour.withdrawAll()
        source?.cancel()
        source = nil
        source6?.cancel()
        source6 = nil
        watcher?.cancel()
        watcher = nil
        locked {
            boundPort = 0
            held6 = false
            announced = nil
        }
    }

    /// Ends everything that is being passed on for `name`, both ends of each, and whatever
    /// its sessions let in on the project's other names. Under `lock`, and always beside
    /// `visitors.forget(name)`. The sockets are only shut down here; each connection's own
    /// thread closes them.
    private func cut(_ name: String) {
        for (other, open) in live {
            for (visitor, end) in open where other == name || end.via == name {
                shutdown(visitor, SHUT_RDWR)
                shutdown(end.server, SHUT_RDWR)
            }
        }
    }

    /// The same network gave this Mac another address: answer there, and announce the names
    /// again. What was open came in on the old address and is cut.
    // ponytail: a debug run on a high port stays bound to the old address (port 80 hears
    // every interface, so the real thing has nothing to rebind); reopen here if that matters.
    func move(to network: LAN.Network) {
        queue.sync {
            let names = locked { () -> [String] in
                announced = network
                // Everyone signs in again: a device is known by its address here, and addresses have just been dealt anew.
                shares.keys.forEach { visitors.forget($0) }
                live.keys.forEach(cut)
                return Array(shares.keys)
            }
            guard announces else { return }
            for name in names where !bonjour.announce(name, address: network.address, interface: network.interface) {
                announcedResult(name, DNSServiceErrorType(kDNSServiceErr_Unknown))
            }
            if !names.isEmpty { Self.log.notice("a new address on the same network: \(names.count, privacy: .public) announced again") }
        }
    }

    /// A new password (or none) for a name that is on: everyone signs in again, and what
    /// they had open is cut.
    func setPassword(_ password: String?, for name: String) {
        locked {
            guard var share = shares[name] else { return }
            share.salt = Lan.token(16)
            share.secret = password.map { Lan.key(password: $0, salt: share.salt) }
            shares[name] = share
            visitors.forget(name)
            cut(name)
        }
    }

    // MARK: Bonjour answers

    private func announcedResult(_ name: String, _ error: DNSServiceErrorType) {
        guard error == kDNSServiceErr_NameConflict else {
            if error != kDNSServiceErr_NoError { Self.log.notice("bonjour: \(name, privacy: .public) error \(error, privacy: .public)") }
            DispatchQueue.main.async { self.answered?(name, error == kDNSServiceErr_NoError) }
            return
        }
        // Another device on this network already goes by that name: take the next free one.
        let moved = locked { () -> (to: String, network: LAN.Network)? in
            guard let share = shares[name], let network = announced else { return nil }
            let next = Lan.nextName(after: name) { shares[$0] != nil }
            shares[name] = nil
            shares[next] = share
            visitors.forget(name)
            cut(name)
            return (next, network)
        }
        guard let moved else { return }
        bonjour.withdraw(name)
        Self.log.notice("bonjour: \(name, privacy: .public) is taken on this network, now \(moved.to, privacy: .public)")
        DispatchQueue.main.async { self.renamed?(name, moved.to) }
        if !bonjour.announce(moved.to, address: moved.network.address, interface: moved.network.interface) { announcedResult(moved.to, DNSServiceErrorType(kDNSServiceErr_Unknown)) }
    }

    /// While something is shared, a change of network is noticed at once, menu open or not.
    private func watch() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Monitor.shared.checkNetwork() } }
        }
        monitor.start(queue: queue)
        watcher = monitor
    }

    // MARK: Connections

    /// A port under 1024 can only be had on every interface: without root, one address is
    /// refused there. That is why the announced-address check exists.
    static func hearsEveryInterface(_ port: UInt16) -> Bool { port != 0 && port < 1024 }

    /// A listening socket on `port` (0: any), on one address or on every interface (nil).
    ///
    /// Both set SO_REUSEADDR, and neither can have the announced address taken from under it
    /// (each of these was tried on this macOS):
    /// - Every interface is for port 80. Harbor's own door already holds 127.0.0.1:80, and
    ///   without the option this bind is refused for as long as the door is there. Nothing
    ///   is given away by it: on a port under 1024 a process without root can't bind one
    ///   address at all, with any option, and a second socket on every interface is refused.
    /// - One address is for the high ports of debug runs and tests. A second socket on
    ///   exactly that address and port is refused whatever options it sets, because this one
    ///   never sets SO_REUSEPORT. Here the option only spares the 30 s a quick off and on
    ///   would otherwise wait for the old connections to clear.
    static func bind(_ port: UInt16, on only: String?) -> (fd: Int32, port: UInt16)? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        if let only, inet_pton(AF_INET, only, &address.sin_addr) != 1 { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        guard bound, listen(fd, 64) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (fd, Sock.port(of: fd))
    }

    /// `port` on IPv6, every interface, IPv6 only (so it sits beside the IPv4 listener).
    /// Harbor announces no IPv6 address and serves nothing here. It holds the port because a
    /// program that could bind it beside harbor, and announce an IPv6 address for a shared
    /// name, would get the visitors whose devices prefer IPv6, with a sign-in page of its own.
    /// SO_REUSEADDR for the same reason as on IPv4 (the door has [::1]:80); a second socket
    /// on [::] is refused all the same, and one address on a low port needs root.
    static func hold6(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
        guard bound, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let from = Sock.peer(fd)
            // Only what arrived on the announced address: everything else (loopback, a VPN,
            // another interface) is closed without a word. And only so many at once, from
            // everyone and from any one address, so a few silent connections keep nobody out.
            guard Lan.accepts(local: Sock.local(fd), announced: locked { announced?.address }),
                  open < Self.maxOpen, openFrom[from, default: 0] < Self.maxPerAddress else {
                close(fd)
                continue
            }
            Sock.prepare(fd)
            open += 1
            openFrom[from, default: 0] += 1
            Thread.detachNewThread {
                self.serve(fd, from: from)
                close(fd)
                self.queue.async {
                    self.open -= 1
                    self.openFrom[from] = self.openFrom[from].flatMap { $0 > 1 ? $0 - 1 : nil }
                }
            }
        }
    }

    private func serve(_ fd: Int32, from address: String) {
        guard case .ok(let head, let rest) = Sock.readHead(fd, max: Proxy.maxHead, within: Self.headWithin) else { return }
        guard let request = ProxyHead(head) else { return Sock.reply(fd, Lan.bare(400)) }
        let now = Date()
        // By Host, and only for a name that is shared right now. No hint of what else exists.
        let found = locked { () -> (name: String, share: Share, session: Bool, via: String?, port: UInt16)? in
            guard let name = Lan.name(forHost: request.host, port: boundPort, isShared: { shares[$0] != nil }), let share = shares[name] else { return nil }
            // Its own cookie; or, without one, a session this address has on another name of the same project.
            let own = visitors.isSignedIn(Lan.visitor(in: request.values("cookie")), to: name, now: now)
            let via = own || share.secret == nil ? nil : visitors.sibling(of: name, project: share.project, address: address, now: now)
            return (name, share, own || via != nil, via, boundPort)
        }
        guard let found else { return Sock.reply(fd, Lan.bare(404)) }
        let name = found.name
        let step = Gate.step(method: request.method, target: request.target, protected: found.share.secret != nil, session: found.session)
        // The sign-in's two calls are for harbor's own page only. From anywhere else they are
        // refused, and no try is counted: another site can't use up a visitor's tries.
        if step == .challenge || step == .enter, !Lan.isOwnPage(request, name: name, port: found.port) { return Sock.reply(fd, Lan.bare(403)) }
        switch step {
        case .notFound:
            Sock.reply(fd, Lan.bare(404))
        case .signIn:
            Sock.reply(fd, SignIn.page(name: name))
        case .challenge:
            let answer = locked { () -> Data in
                if let wait = visitors.wait(address: address, name: name, now: now) { return Lan.json(429, ["wait": wait]) }
                return Lan.json(200, ["salt": found.share.salt, "nonce": visitors.challenge(for: name, now: now), "iterations": Lan.iterations])
            }
            Sock.reply(fd, answer)
        case .enter:
            Sock.reply(fd, enter(fd, request: request, rest: rest, name: name, address: address))
        case .forward:
            // Only ever to the server it was shared for. Gone: say so, and the sharing ends.
            let server = found.share.server
            guard server.isStillThere else {
                DispatchQueue.main.async { self.gone?(name) }
                return Sock.reply(fd, Lan.bare(502))
            }
            guard let up = Sock.connect(server.target.addresses.filter(Sock.isOwn), port: server.target.port) else { return Sock.reply(fd, Lan.bare(502)) }
            // From here both ends can be cut the moment sharing stops or the password changes.
            // If that has just happened, nothing is passed on at all.
            let current = locked { () -> Bool in
                guard shares[name]?.salt == found.share.salt else { return false }
                live[name, default: [:]][fd] = (up, found.via)
                return true
            }
            defer {
                // Out of the list before the sockets close, so a cut never reaches a number that has been given out again.
                locked {
                    live[name]?[fd] = nil
                    if live[name]?.isEmpty == true { live[name] = nil }
                }
                close(up)
            }
            guard current else { return }
            Proxy.exchange(client: fd, server: up, request: request, rest: rest, clientAddress: address, quietSocket: quietSocket, dropCookie: true)
        }
    }

    enum Entry: Equatable {
        case signedIn(token: String)
        /// A wrong password: how long this address now has to wait, and whether the name just went over "many".
        case wrong(wait: Int?, many: Bool)
        /// Not looked at: this address is still waiting out a lock.
        case locked(wait: Int)
        /// Not looked at either: the challenge isn't one of harbor's, is too old, or has
        /// already let someone in. Start again with a new one. It is not a wrong try.
        case again
    }

    /// Checks a visitor's answer to a challenge. A wrong try is counted only when the
    /// challenge was good and the proof didn't match it; the proof is compared in constant
    /// time, and a challenge lets one visitor in, once.
    static func check(proof: String?, nonce: String, name: String, project: String = "", secret: Data, address: String, visitors: inout Visitors, now: Date) -> Entry {
        if let wait = visitors.wait(address: address, name: name, now: now) { return .locked(wait: wait) }
        guard let end = visitors.end(of: nonce, for: name, now: now) else { return .again }
        guard WebServer.constantEquals(proof, Lan.proof(key: secret, name: name, nonce: nonce)) else {
            let many = visitors.wrong(address: address, name: name, now: now)
            return .wrong(wait: visitors.wait(address: address, name: name, now: now), many: many)
        }
        guard visitors.use(nonce, until: end, now: now) else { return .again }
        visitors.right(address: address, name: name)
        return .signedIn(token: visitors.signIn(to: name, project: project, from: address, now: now))
    }

    /// The answer to a challenge: `{nonce, proof}`. A right one gets the visitor's cookie.
    private func enter(_ fd: Int32, request: ProxyHead, rest: Data, name: String, address: String) -> Data {
        // A small JSON body, all of it within 5 s.
        guard case .length(let length) = request.body, length <= 1024 else { return Lan.bare(400) }
        var body = [UInt8](rest.prefix(length))
        var chunk = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(5)
        while body.count < length, deadline.timeIntervalSinceNow > 0 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 500) > 0 else { continue }
            let n = read(fd, &chunk, min(chunk.count, length - body.count))
            if n > 0 { body += chunk[0..<n] } else if n == 0 { break }
        }
        let sent = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
        let nonce = (sent?["nonce"] as? String) ?? ""
        // Someone may be guessing at this name: every answer takes a little longer for a while.
        let hold = locked { visitors.delay(for: name, now: Date()) }
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        let now = Date()
        let (answer, wrong, many) = locked { () -> (Data, Bool, Bool) in
            guard let share = shares[name], let secret = share.secret else { return (Lan.bare(404), false, false) }
            switch Self.check(proof: sent?["proof"] as? String, nonce: nonce, name: name, project: share.project, secret: secret, address: address, visitors: &visitors, now: now) {
            case .locked(let wait):
                return (Lan.json(429, ["wait": wait]), false, false)
            case .again:
                return (Lan.json(409, ["again": true]), false, false)
            case .signedIn(let token):
                return (Lan.json(200, ["ok": true], cookie: "\(Lan.cookie)=\(token); Path=/; Max-Age=\(Int(Visitors.sessionLife)); HttpOnly; SameSite=Lax"), false, false)
            case .wrong(let wait, let many):
                var reply: [String: Any] = ["error": "wrong"]
                if let wait { reply["wait"] = wait }
                return (Lan.json(403, reply), true, many)
            }
        }
        if wrong {
            queue.async { self.wrongTries[name, default: 0] += 1 }
            // Whose turn it is to wait, and for how long; never what was typed.
            if let wait = locked({ visitors.wait(address: address, name: name, now: now) }) {
                Self.log.notice("wrong password for \(name, privacy: .public) from \(address, privacy: .public): locked out for \(wait, privacy: .public) s")
            }
        }
        if many {
            Self.log.notice("many wrong passwords for \(name, privacy: .public): its answers are held back for 10 minutes")
            DispatchQueue.main.async { self.manyWrong?(name) }
        }
        return answer
    }
}

// MARK: - The sign-in page

/// Harbor's own page for a visitor without a session. It holds nothing about the project
/// but its name, loads nothing from anywhere, and its one script and one style run under a
/// nonce. The password is never sent: the script answers a challenge with it.
enum SignIn {
    static func page(name: String) -> Data {
        let nonce = Lan.token(16)
        let body = html.replacingOccurrences(of: "__NONCE__", with: nonce)
            .replacingOccurrences(of: "__NAME__", with: name + Lan.suffix)      // a checked label: letters, digits, hyphens
            .replacingOccurrences(of: "__APP__", with: AppInfo.name)
        let csp = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
        let head = "HTTP/1.1 401 Unauthorized\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: \(csp)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n"
            + "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }

    /// SHA-256, HMAC and PBKDF2 in plain JavaScript, because `crypto.subtle` doesn't exist on
    /// an http page. `harborProof(password, salt, name, nonce, iterations)` gives the same
    /// hex as `Lan.proof(key: Lan.key(…), …)`; a unit test holds the two against each other.
    static let crypto = #"""
const K = new Int32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
const W = new Int32Array(64);
// One block: h is the running state (8 words), W[0..15] holds the block.
function compress(h) {
  for (let i = 16; i < 64; i++) {
    const a = W[i - 15], b = W[i - 2];
    W[i] = (W[i - 16] + ((a >>> 7 | a << 25) ^ (a >>> 18 | a << 14) ^ (a >>> 3)) + W[i - 7] + ((b >>> 17 | b << 15) ^ (b >>> 19 | b << 13) ^ (b >>> 10))) | 0;
  }
  let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
  for (let i = 0; i < 64; i++) {
    const t1 = (k + ((e >>> 6 | e << 26) ^ (e >>> 11 | e << 21) ^ (e >>> 25 | e << 7)) + ((e & f) ^ (~e & g)) + K[i] + W[i]) | 0;
    const t2 = (((a >>> 2 | a << 30) ^ (a >>> 13 | a << 19) ^ (a >>> 22 | a << 10)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
    k = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
  }
  h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0;
  h[4] = (h[4] + e) | 0; h[5] = (h[5] + f) | 0; h[6] = (h[6] + g) | 0; h[7] = (h[7] + k) | 0;
}
function fresh() { return new Int32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]); }
// Hashes `bytes` on from state `h`, which has already taken `before` bytes. Returns h.
function absorb(h, bytes, before) {
  const total = before + bytes.length, padded = new Uint8Array(((bytes.length + 9 + 63) >> 6) << 6);
  padded.set(bytes); padded[bytes.length] = 0x80;
  const bits = total * 8;
  padded[padded.length - 4] = bits >>> 24; padded[padded.length - 3] = bits >>> 16; padded[padded.length - 2] = bits >>> 8; padded[padded.length - 1] = bits;
  padded[padded.length - 5] = Math.floor(total / 0x20000000);
  for (let o = 0; o < padded.length; o += 64) {
    for (let i = 0; i < 16; i++) W[i] = padded[o + 4 * i] << 24 | padded[o + 4 * i + 1] << 16 | padded[o + 4 * i + 2] << 8 | padded[o + 4 * i + 3];
    compress(h);
  }
  return h;
}
function bytesOf(h) { const out = new Uint8Array(32); for (let i = 0; i < 8; i++) { out[4 * i] = h[i] >>> 24; out[4 * i + 1] = h[i] >>> 16; out[4 * i + 2] = h[i] >>> 8; out[4 * i + 3] = h[i]; } return out; }
function sha256(bytes) { return bytesOf(absorb(fresh(), bytes, 0)); }
function utf8(text) { const s = unescape(encodeURIComponent(text)), out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out; }
function hex(bytes) { let s = ''; for (const b of bytes) s += (b < 16 ? '0' : '') + b.toString(16); return s; }
// The two half-done hashes HMAC starts from for a key: (key ^ ipad) and (key ^ opad) already taken in.
function keyed(key) {
  if (key.length > 64) key = sha256(key);
  const i = new Uint8Array(64).fill(0x36), o = new Uint8Array(64).fill(0x5c);
  for (let n = 0; n < key.length; n++) { i[n] ^= key[n]; o[n] ^= key[n]; }
  const inner = fresh(), outer = fresh();
  for (const [h, pad] of [[inner, i], [outer, o]]) {
    for (let n = 0; n < 16; n++) W[n] = pad[4 * n] << 24 | pad[4 * n + 1] << 16 | pad[4 * n + 2] << 8 | pad[4 * n + 3];
    compress(h);
  }
  return { inner, outer };
}
function hmacWith(k, message) { return bytesOf(absorb(new Int32Array(k.outer), bytesOf(absorb(new Int32Array(k.inner), message, 64)), 64)); }
function hmac(key, message) { return hmacWith(keyed(key), message); }
// PBKDF2-HMAC-SHA256, 32 bytes out. After the first round every message is one 32-byte
// hash, so each round is two blocks, built straight into W.
function pbkdf2(password, salt, rounds) {
  const k = keyed(password), first = new Uint8Array(salt.length + 4);
  first.set(salt); first[first.length - 1] = 1;
  const u = absorb(new Int32Array(k.outer), bytesOf(absorb(new Int32Array(k.inner), first, 64)), 64);
  const t = new Int32Array(u), h = new Int32Array(8);
  for (let r = 1; r < rounds; r++) {
    for (const start of [k.inner, k.outer]) {
      h.set(start);
      W.set(u); W[8] = 0x80000000 | 0; W[9] = 0; W[10] = 0; W[11] = 0; W[12] = 0; W[13] = 0; W[14] = 0; W[15] = 768;
      compress(h);
      u.set(h);
    }
    for (let j = 0; j < 8; j++) t[j] ^= u[j];
  }
  return bytesOf(t);
}
function harborProof(password, salt, name, nonce, rounds) {
  return hex(hmac(pbkdf2(utf8(password), utf8(salt), rounds), utf8(name + ':' + nonce)));
}
"""#

    private static let html = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark"><title>__NAME__</title>
<style nonce="__NONCE__">
  :root { color-scheme: light dark; --bg: #fff; --panel: #f6f6f4; --line: #e5e5e1; --text: #0b0b0c; --muted: #65686f; --signal: #3d4bd1; --danger: #c3301f; }
  @media (prefers-color-scheme: dark) { :root { --bg: #0e0e10; --panel: #16161a; --line: #27272d; --text: #f2f2f0; --muted: #8d9099; --signal: #a7b4ff; --danger: #ff5d4d; } }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 20px; background: var(--bg); color: var(--text);
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  main { width: min(380px, 100%); background: var(--panel); border-radius: 14px; padding: 24px; }
  .logo { display: flex; align-items: center; gap: 8px; color: var(--muted); font-weight: 700; font-size: 14px; letter-spacing: -.02em; }
  .logo svg { width: 22px; height: 15px; color: var(--signal); }
  h1 { font-size: 22px; line-height: 1.2; letter-spacing: -.025em; margin: 14px 0 6px; overflow-wrap: anywhere; }
  p { margin: 0; color: var(--muted); font-size: 14px; }
  form { display: grid; gap: 10px; margin-top: 18px; }
  input { font: inherit; padding: 11px 12px; border-radius: 10px; border: 1px solid var(--line); background: var(--bg); color: var(--text); width: 100%; }
  input:focus { outline: 2px solid var(--signal); outline-offset: 1px; }
  button { font: 600 15px/1 inherit; padding: 13px; border: 0; border-radius: 999px; background: var(--text); color: var(--bg); cursor: pointer; }
  button[disabled] { opacity: .5; cursor: default; }
  #note { min-height: 21px; color: var(--danger); }
</style></head>
<body><main>
  <div class="logo"><svg viewBox="0 0 26 18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M1 6c2.5-2.4 4.5-2.4 7 0s4.5 2.4 7 0 4.5-2.4 7 0"/><path d="M1 13c2.5-2.4 4.5-2.4 7 0s4.5 2.4 7 0 4.5-2.4 7 0"/></svg>__APP__</div>
  <h1>__NAME__</h1>
  <p>Shared from a Mac on this network. Enter the password its owner gave you.</p>
  <form id="form">
    <input id="password" type="password" autocomplete="current-password" autocapitalize="off" autocorrect="off" spellcheck="false" aria-label="Password" required autofocus>
    <button id="go">Open</button>
    <p id="note" role="status"></p>
  </form>
</main>
<script nonce="__NONCE__">
'use strict';
__CRYPTO__
const NAME = location.hostname.replace(/\.local$/, '');
const note = (text) => { document.getElementById('note').textContent = text; };
const wait = (seconds) => 'Too many tries. Wait ' + (seconds > 90 ? Math.ceil(seconds / 60) + ' minutes.' : Math.ceil(seconds) + ' seconds.');
async function call(path, body) {
  const reply = await fetch('/__harbor/' + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}), cache: 'no-store', credentials: 'same-origin' });
  return { status: reply.status, data: await reply.json().catch(() => ({})) };
}
// One try: a fresh challenge, and the answer that proves the password without sending it.
async function attempt(password) {
  const c = await call('challenge');
  if (c.status === 429) return { wait: c.data.wait };
  if (c.status === 403) return { refused: true };
  if (c.status !== 200) return { gone: true };
  await new Promise((r) => setTimeout(r, 0));
  const r = await call('enter', { nonce: c.data.nonce, proof: harborProof(password, c.data.salt, NAME, c.data.nonce, c.data.iterations) });
  // A wrong password is a 403 that says so. A bare one means harbor didn't take the call as this page's own.
  return { status: r.status, wait: r.data.wait, again: r.status === 409, refused: r.status === 403 && r.data.error !== 'wrong', gone: r.status === 404 };
}
document.getElementById('form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const field = document.getElementById('password'), button = document.getElementById('go');
  button.disabled = true; note('');
  try {
    let r = await attempt(field.value);
    if (r.again) r = await attempt(field.value);     // the challenge had gone stale: once more, without a word
    if (r.status === 200) { location.reload(); return; }
    note(r.wait ? wait(r.wait) : r.refused ? "Couldn't sign in from this page. Reload and try again." : r.gone ? 'This project is not shared any more.'
      : r.again ? "That didn't go through. Try again." : "That isn't the password.");
    field.select();
  } catch (e) {
    note("Couldn't reach it. Is the Mac still on this network?");
  } finally {
    button.disabled = false;
  }
});
</script></body></html>
"""#.replacingOccurrences(of: "__CRYPTO__", with: crypto)
}
