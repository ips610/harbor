import CryptoKit
import Darwin
import Foundation
import Security

/// "Update now": harbor replaces itself with the newest release, on the owner's click and
/// never by itself.
///
/// What makes this safe is one check (`meets`): the downloaded app has to satisfy the
/// RUNNING app's own designated requirement, asked of the Security framework in this
/// process. So the new app must be signed by the same key as the one that is asking. That
/// is also why it is only offered to a copy whose requirement names a certificate: an
/// ad-hoc build has nothing to hold a download to. The download's address, its checksum and
/// the shape of the zip are checked too, but those only catch mistakes; none of them is the
/// security check.
///
/// Every step fails closed: the installed app stays exactly as it was, and the reason is
/// said in plain words. Nothing from the release (a name, a version, a note) is ever handed
/// to a shell or shown as markup.
enum Updater {
    struct Problem: Error, Equatable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// A download the network cut off, in plain words. Seen for real: a campus network that lets github.com
    /// through and resets every connection to the server GitHub hands its downloads to. A browser fails there too.
    static func cutOff(_ reason: String) -> Problem {
        let why = reason.isEmpty || ".!?".contains(reason.last!) ? reason : reason + "."
        return Problem("The download did not arrive\(why.isEmpty ? "." : ": " + why) Some networks block GitHub's downloads; if it keeps happening, try on another network. \(AppInfo.name) is as it was.")
    }

    /// No release is anywhere near this size.
    static let maxBytes = 30 << 20
    static let assets = (appleSilicon: "\(AppInfo.fallbackName)-apple-silicon.zip", intel: "\(AppInfo.fallbackName)-intel.zip", sums: "SHA256SUMS")
    /// The folder the zip has to hold, and nothing beside it.
    static var appFolder: String { "\(AppInfo.fallbackName).app" }

    // MARK: Is it offered at all?

    /// The code at a path, as Security sees it (nothing is run).
    static func code(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    /// Is this code signed with a certificate? Asked of Security itself: an ad-hoc signature
    /// (a throwaway one, the hash of that one build) and no signature at all both say no.
    /// The wording of a requirement is never read for this: "anchor" can be part of a name.
    static func hasCertificate(_ code: SecStaticCode) -> Bool {
        var found: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &found) == errSecSuccess, let info = found as? [String: Any],
              let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value, !SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) else { return false }
        return (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.isEmpty == false
    }

    /// Offered only to an app bundle, signed with a certificate, in a folder this user may
    /// write to. And only to the installed copy (the one in Applications that the agents
    /// start): the new one is started the way install.sh starts it, under those agents, and a
    /// copy somewhere else has none.
    static func mayOffer(bundle: URL, certificate: Bool, installed: Bool, writable: (String) -> Bool = { access($0, W_OK) == 0 }) -> Bool {
        bundle.pathExtension == "app" && installed && certificate && writable(bundle.deletingLastPathComponent().path)
    }

    /// The code on disk that this process runs from.
    static func ownCode() -> SecStaticCode? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var onDisk: SecStaticCode?
        return SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess ? onDisk : nil
    }

    /// The running app's own designated requirement: what a download is held to.
    static func ownRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard let code = ownCode(), SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Asked once: none of it changes while the app runs.
    static let offered: Bool = !DebugCLI.isDebugRun && mayOffer(bundle: Bundle.main.bundleURL, certificate: ownCode().map(hasCertificate) ?? false, installed: LaunchAgent.mayManage)

    // MARK: 1. Which file, from where

    /// Is this Mac's hardware Apple Silicon? (Asked of the hardware, so an Intel build running under Rosetta moves to the native one.)
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func asset(appleSilicon: Bool) -> String { appleSilicon ? assets.appleSilicon : assets.intel }

    /// Where a release's file is: only ever this address, built from a version made of
    /// digits and dots and one of the three file names harbor knows.
    static func address(version: String, file: String) -> URL? {
        guard !version.isEmpty, version.count <= 20, version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }), !version.hasPrefix("."), !version.hasSuffix("."),
              !version.contains(".."), [assets.appleSilicon, assets.intel, assets.sums].contains(file) else { return nil }
        return URL(string: "https://github.com/ips610/harbor/releases/download/v\(version)/\(file)")
    }

    // MARK: 2. The download

    /// May a download go to (or be sent on to) this address? Only https on its own port, and
    /// only GitHub's own hosts: github.com itself, or a host that ends in ".githubusercontent.com".
    static func mayFollow(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", (url.port ?? 443) == 443, url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    typealias Fetch = (URL) async throws -> Data

    /// Gets what is at `url`, by the rules above: https only, redirects only to GitHub's
    /// hosts, never more than `maxBytes`, with time limits and macOS's own certificate checks.
    /// (`get` is the download itself; a test passes its own, so that no test asks GitHub.)
    static func fetch(_ url: URL, get: Fetch = { try await Fetcher().get($0) }) async throws -> Data {
        guard mayFollow(url), url.host?.lowercased() == "github.com" else { throw Problem("That isn't an address \(AppInfo.name) downloads from.") }
        return try await get(url)
    }

    final class Fetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private var data = Data()
        private(set) var problem: Problem?
        private var waiting: CheckedContinuation<Data, Error>?
        private let limit: Int
        init(limit: Int = Updater.maxBytes) { self.limit = limit }

        func get(_ url: URL) async throws -> Data {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 20
            settings.timeoutIntervalForResource = 180
            settings.httpCookieStorage = nil
            settings.urlCache = nil
            let session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                session.dataTask(with: URLRequest(url: url)).resume()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // Anywhere else: the redirect isn't followed, and its own answer (not a 200) ends the download.
            completionHandler(Updater.mayFollow(request.url) ? request : nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, Updater.mayFollow(http.url) else {
                problem = Problem("GitHub didn't hand the file over.")
                return completionHandler(.cancel)
            }
            guard response.expectedContentLength <= Int64(limit) else {
                problem = Problem("The download is larger than a release ever is, so it was stopped.")
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            data.append(chunk)
            if data.count > limit {
                problem = Problem("The download is larger than a release ever is, so it was stopped.")
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let problem { waiting?.resume(throwing: problem) }
            else if let error { waiting?.resume(throwing: Updater.cutOff(error.localizedDescription)) }
            else { waiting?.resume(returning: data) }
            waiting = nil
        }
    }

    // MARK: 3. The checksum (catches a broken download; it is NOT the security check)

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The sum SHA256SUMS lists for `file` ("<64 hex>  <name>" lines, as shasum writes them).
    static func sum(for file: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1] == file || parts[1] == "*" + file, parts[0].utf8.count == 64,
                  parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            return String(parts[0])
        }
        return nil
    }

    // MARK: 4. The zip

    /// What a zip says it holds, from its own table of contents: each entry's path, and
    /// whether it is a link. nil when that table can't be read.
    static func entries(inZip data: Data) -> [(name: String, isLink: Bool)]? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 22 else { return nil }
        // The end record: "PK\u{5}\u{6}", somewhere in the last 64 KB.
        var end = bytes.count - 22
        while end >= 0, end >= bytes.count - 22 - 65535, !(bytes[end] == 0x50 && bytes[end + 1] == 0x4B && bytes[end + 2] == 5 && bytes[end + 3] == 6) { end -= 1 }
        guard end >= 0, end >= bytes.count - 22 - 65535 else { return nil }
        let count = u16(end + 10)
        var at = u32(end + 16)
        var found: [(String, Bool)] = []
        for _ in 0..<count {
            guard at + 46 <= bytes.count, bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 1, bytes[at + 3] == 2 else { return nil }
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            guard at + 46 + nameLength <= bytes.count, let name = String(bytes: bytes[(at + 46)..<(at + 46 + nameLength)], encoding: .utf8) else { return nil }
            // Unix mode in the high half of the external attributes: 0xA000 is a link.
            found.append((name, (u32(at + 38) >> 16) & 0xF000 == 0xA000))
            at += 46 + nameLength + extra + comment
        }
        return found
    }

    /// Why a zip isn't a release, or nil: everything in it is inside `harbor.app` (macOS's
    /// own `__MACOSX` side entries apart), nothing climbs out with "..", nothing starts at
    /// the root, and `harbor.app` itself is a folder, not a link.
    static func zipProblem(_ entries: [(name: String, isLink: Bool)]) -> String? {
        let no = "The download isn't shaped like a release, so it wasn't unpacked."
        guard entries.contains(where: { $0.name.hasPrefix(appFolder + "/") }) else { return no }
        for entry in entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.name.hasPrefix("/"), !entry.name.contains("\\"), !entry.name.contains("\0"), !parts.contains(".."), !parts.contains("."),
                  let top = parts.first, top == appFolder || top == "__MACOSX" else { return no }
            if (entry.name == appFolder || entry.name == appFolder + "/"), entry.isLink { return no }
        }
        return nil
    }

    private static func spawn(_ tool: String, _ arguments: [String]) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil ? process : nil
    }

    /// How much is in a folder: the sizes of its files, links not followed.
    static func size(of folder: URL) -> Int64 {
        var total: Int64 = 0, info = stat()
        for name in FileManager.default.enumerator(atPath: folder.path) ?? FileManager.DirectoryEnumerator() {
            if let name = name as? String, lstat(folder.path + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFREG { total += Int64(info.st_size) }
        }
        return total
    }

    /// Unpacks with macOS's own ditto, and takes the result only if exactly one thing came
    /// out: a real folder called `harbor.app`. A small zip can hold any amount, and ditto
    /// has no limit of its own: it is ended when what it has written passes `limit`, or
    /// after `seconds`.
    static func unpack(_ zip: URL, into folder: URL, limit: Int64 = 200 << 20, seconds: Double = 60) -> Result<URL, Problem> {
        guard let ditto = spawn("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else { return .failure(Problem("The download couldn't be unpacked.")) }
        let began = Date()
        var stopped = false
        while ditto.isRunning {
            if Date().timeIntervalSince(began) >= seconds || size(of: folder) > limit {
                stopped = true
                kill(ditto.processIdentifier, SIGKILL)
                break
            }
            usleep(100_000)
        }
        ditto.waitUntilExit()
        // Asked once more when it has ended: a fast disk can write a great deal between two looks.
        if stopped || size(of: folder) > limit { return .failure(Problem("The download unpacks to more, or for longer, than a release ever does, so it was stopped.")) }
        let bundle = folder.appendingPathComponent(appFolder)
        var info = stat()
        guard ditto.terminationStatus == 0, (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == [appFolder],
              lstat(bundle.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return .failure(Problem("The download didn't unpack to one \(appFolder), so it wasn't installed."))
        }
        return .success(bundle)
    }

    /// A zip also carries who may write: access lists, permission for a group or for
    /// everyone, set-user-id bits. None of that is part of what is signed, so none of it is
    /// kept: after this only the owner can write anywhere in the app. Done here, item by
    /// item, with the calls that act on a link itself: what a link leads to is never
    /// touched (`chmod -R -N` does follow them). Anything that can't be read or changed:
    /// false, and the app isn't installed.
    static func tame(_ bundle: URL) -> Bool {
        guard let none = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(none)) }
        var roots: [UnsafeMutablePointer<CChar>?] = [strdup(bundle.path), nil]
        defer { free(roots[0]) }
        guard let walk = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(walk) }
        while true {
            errno = 0
            guard let item = fts_read(walk) else { return errno == 0 }      // the end of it, or it couldn't be walked
            switch Int32(item.pointee.fts_info) {
            case FTS_DP, FTS_SL, FTS_SLNONE: continue           // a folder once more on the way out; a link (it carries neither, and is not followed)
            case FTS_DNR, FTS_ERR, FTS_NS: return false
            default: break
            }
            guard let path = item.pointee.fts_path, let seen = item.pointee.fts_statp, acl_set_link_np(path, ACL_TYPE_EXTENDED, none) == 0 else { return false }
            let mode = seen.pointee.st_mode
            if mode & 0o6022 != 0, lchmod(path, mode & 0o7777 & ~0o6022) != 0 { return false }
        }
    }

    // MARK: 5. THE security check

    /// Does the app at `bundle` satisfy `requirement`, all of it (every architecture, the
    /// code nested in it, strictly)? Asked of the Security framework here; nothing is run.
    static func meets(_ bundle: URL, _ requirement: SecRequirement) -> Bool {
        guard let code = code(at: bundle) else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The bundle id and version an unpacked app says it has (read from its Info.plist, never from the release's text).
    static func facts(of bundle: URL) -> (id: String, version: String)? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), let id = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return (id, version)
    }

    /// The same app, the release that was asked for, and strictly newer than the one that is running: no downgrade, no sideways.
    static func factsProblem(id: String, version: String, release: String, runningID: String, running: String) -> String? {
        if id != runningID { return "The download is a different app (\(Docker.clean(id, max: 60))), so it wasn't installed." }
        if version != release { return "The download says it is another version than the release, so it wasn't installed." }
        if !Updates.isNewer(version, than: running) { return "The download isn't newer than this \(AppInfo.name), so it wasn't installed." }
        return nil
    }

    // MARK: 6. The swap

    /// The installed app moves aside, the new one takes its place. If the new one can't be
    /// put there, the old one is put back: at no point is there no app.
    static func swap(installed: String, new: String, aside: String, rename: (String, String) -> Int32 = { Darwin.rename($0, $1) }) -> Problem? {
        guard rename(installed, aside) == 0 else { return Problem("\(AppInfo.name) couldn't be moved out of the way, so nothing was changed.") }
        guard rename(new, installed) == 0 else {
            return rename(aside, installed) == 0 ? Problem("The new \(AppInfo.name) couldn't be put in place, so the old one was put back.")
                : Problem("The new \(AppInfo.name) couldn't be put in place, and the old one is now at \(Fmt.path(aside)). Move it back to where it was.")
        }
        return nil
    }

    // MARK: All of it

    /// What an update needs from outside itself (a test puts its own in).
    struct World {
        var fetch: Fetch = { try await Updater.fetch($0) }
        var appleSilicon = Updater.isAppleSilicon
        var requirement: SecRequirement
        var bundleID: String
        var running: String
        var rename: (String, String) -> Int32 = { Darwin.rename($0, $1) }
        /// The old app, once it has been replaced: to the Trash, not deleted.
        var trash: (URL) -> Bool = { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }
        /// The Trash wouldn't take it: it stays where it is, and the new copy is left a note to say so.
        var leftBehind: (URL) -> Void = { Updater.leaveNote($0) }
        /// The new app is in place: start it and leave. Returns only if that couldn't be done.
        var handOver: (URL) -> Void
    }

    /// Replaces the app at `installed` with release `version`. Returns why not; when it
    /// worked, `world.handOver` has been called (and in the real world never returns).
    static func update(to version: String, installed: URL, world: World) async -> Problem? {
        let file = asset(appleSilicon: world.appleSilicon)
        guard let zipAddress = address(version: version, file: file), let sumsAddress = address(version: version, file: assets.sums) else { return Problem("That isn't a version \(AppInfo.name) knows how to get.") }
        // A fresh folder of this user's own beside the app: the same volume, so the swap is a rename.
        let scratch = installed.deletingLastPathComponent().appendingPathComponent(".\(AppInfo.fallbackName)-update-\(Lan.token(6))")
        guard mkdir(scratch.path, 0o700) == 0 else { return Problem("\(AppInfo.name) can't write beside itself, so it can't update itself here.") }
        let saved = scratch.appendingPathComponent("download.zip"), unpacked = scratch.appendingPathComponent("new"), old = scratch.appendingPathComponent("old")
        // However this ends, the download and what was unpacked from it go. The folder for the old app goes only when it
        // is empty (rmdir does nothing else): an old app still in it, which the Trash wouldn't take or which couldn't be
        // put back, is never deleted.
        func tidy() {
            try? FileManager.default.removeItem(at: saved)
            try? FileManager.default.removeItem(at: unpacked)
            rmdir(old.path)
            rmdir(scratch.path)
        }
        defer { tidy() }
        do {
            let sums = try await world.fetch(sumsAddress)
            let zip = try await world.fetch(zipAddress)
            guard zip.count <= maxBytes else { return Problem("The download is larger than a release ever is, so it was stopped.") }
            // A broken or cut-off download ends here. Not the security check: whoever could change the zip could change this list too.
            guard let listed = sum(for: file, in: String(decoding: sums.prefix(4096), as: UTF8.self)), listed == sha256(zip) else {
                return Problem("The download doesn't match its checksum, so it wasn't installed.")
            }
            guard let entries = entries(inZip: zip) else { return Problem("The download isn't a zip \(AppInfo.name) can read, so it wasn't unpacked.") }
            if let problem = zipProblem(entries) { return Problem(problem) }
            guard FileManager.default.createFile(atPath: saved.path, contents: zip, attributes: [.posixPermissions: 0o600]), mkdir(unpacked.path, 0o700) == 0 else {
                return Problem("The download couldn't be saved.")
            }
            let bundle: URL
            switch unpack(saved, into: unpacked) {
            case .failure(let problem): return problem
            case .success(let found): bundle = found
            }
            guard tame(bundle) else { return Problem("The download's permissions couldn't be set right, so it wasn't installed.") }
            // THE check: signed by the same key as the app that is running.
            guard meets(bundle, world.requirement) else { return Problem("The download isn't signed with the same key as this \(AppInfo.name), so it wasn't installed.") }
            guard let facts = facts(of: bundle) else { return Problem("The download isn't an app \(AppInfo.name) can read, so it wasn't installed.") }
            if let problem = factsProblem(id: facts.id, version: facts.version, release: version, runningID: world.bundleID, running: world.running) { return Problem(problem) }
            guard mkdir(old.path, 0o700) == 0 else { return Problem("The download couldn't be put in place.") }
            let aside = old.appendingPathComponent(installed.lastPathComponent)
            if let problem = swap(installed: installed.path, new: bundle.path, aside: aside.path, rename: world.rename) { return problem }
            // The old one goes to the Trash. If the Trash won't have it, it stays where it is, and the new copy says where.
            if !world.trash(aside) { world.leftBehind(aside) }
            // Here and not only in the defer: the real hand-over ends this process and never comes back, and a real
            // update left its download and two empty folders beside the app because of that.
            tidy()
            world.handOver(installed)
            return nil
        } catch let problem as Problem {
            return problem
        } catch {
            return cutOff(error.localizedDescription)
        }
    }

    /// Where the one line about an old copy that is still on disk waits for the new copy to say it.
    static var noteURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(LaunchAgent.label)\(DebugCLI.isDebugRun ? ".debug" : "")/old-copy")
    }

    /// Leaves that line: where the old app is. A file only this account can read, made new (never written through a link).
    static func leaveNote(_ old: URL, at note: URL = noteURL) {
        try? FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(note.path)
        let fd = open(note.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let line = Array((old.path + "\n").utf8)
        _ = write(fd, line, line.count)
        close(fd)
    }

    /// Takes the line: it is read, removed, and comes back as what to say (once). nil when there is none.
    static func takeNote(at note: URL = noteURL) -> String? {
        let fd = open(note.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 2048)
        let count = read(fd, &bytes, bytes.count)
        close(fd)
        unlink(note.path)
        guard count > 0, let path = String(decoding: bytes[..<count], as: UTF8.self).split(whereSeparator: \.isNewline).first, path.hasPrefix("/") else { return nil }
        return "The old \(AppInfo.name) couldn't be moved to the Trash. It is still at \(Restart.visible(String(path))). Delete it when you like."
    }

    /// The real hand-over, as install.sh does it: everything harbor has open is closed, the
    /// new binary sets up the agents and starts under them, and this process leaves without
    /// marking harbor as "quit on purpose".
    @MainActor
    static func handOver(_ installed: URL) {
        Tunnels.shared.stopAll()
        Shared.clear()
        OnNetwork.shared.stopAll()
        LaunchAgent.clearQuitMarker()
        guard startApart(installed.appendingPathComponent("Contents/MacOS/\(CLI.executable)").path, ["--refresh-agents"]) != nil else { return }
        // Not the usual quit: that would mark harbor as "quit on purpose", and the new one would wait for a visit.
        exit(0)
    }

    /// Starts a program that is to outlive this process: in a session of its own, with
    /// nothing of this process's open in it (not the ports launchd handed over either).
    /// launchd's manual says that when a job ends, what is left in the job's process group
    /// is ended too, and the new harbor's `--refresh-agents` must not go down half-way through
    /// with the harbor that started it. (Tried with a throwaway launchd job: a helper started
    /// like this outlived the job's end and its bootout.)
    static func startApart(_ executable: String, _ arguments: [String]) -> pid_t? {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return nil }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, environ) == 0 ? pid : nil
    }
}
