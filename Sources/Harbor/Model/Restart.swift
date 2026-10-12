import Darwin
import Foundation

/// Is this process in a sandbox? (libsystem's own question; the last argument is "no filter".)
@_silgen_name("sandbox_check")
private func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

/// "Start again" for a server that stopped.
///
/// While a server runs, harbor keeps how it was started: the program, its argv as an array,
/// its working folder and the environment it was given. All of it stays in this process's
/// memory. It is never written to a file, to the settings, to the note for the command line
/// or to a log, and the environment is never sent to the page or shown anywhere. When the
/// server stops it joins a short list (the last 20, for a day, gone when harbor quits) and
/// can be started again: from the remembered array, with `Process`, never through a shell
/// and never from a string that is parsed. The request that asks for it names the list's
/// entry and nothing else.
///
/// Argv, the environment and the path that was exec'd are read from the process's own
/// memory, so the process can have written anything there. Three things answer that: which
/// program runs is the kernel's word, not the process's; a process in a sandbox is never
/// remembered (started again by harbor it would be outside it); and the owner is shown
/// exactly what will run before it does (`question`).
enum Restart {
    /// What a file was when its program ran: enough to say "this changed".
    struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let modified: Int
        let modifiedNanos: Int
        let size: off_t
    }

    /// How a server was started.
    struct Launch: Equatable {
        /// The path that is run: what was exec'd when that is a whole path to the program the
        /// kernel says ran (a virtualenv's python is a link, and has to be run as that link),
        /// else the kernel's own path.
        let executable: String
        /// Where the program really is (links followed), and what was there when it ran.
        let resolved: String
        var stamp: Stamp? = nil
        let arguments: [String]
        let environment: [String: String]
        /// Its working folder, and where that really is.
        let folder: String
        let folderResolved: String
    }

    /// A server that stopped, as harbor remembers it.
    struct Stopped: Identifiable, Equatable {
        /// Made up when it stopped, for this run of harbor only: what a request names.
        let id: String
        let name: String
        let port: UInt16
        let launch: Launch
        let at: Date
        /// Where its output goes once it has been started again.
        var log: URL?
        /// What became of the last try, when it didn't just work.
        var note: String?
        /// The process harbor started for it, until that ends: one at a time.
        var pid: pid_t? = nil
    }

    static let keep = 20
    static let life: TimeInterval = 24 * 3600
    static let maxLog: off_t = 5 << 20
    /// `~/Library/Logs/harbor`. A debug run keeps its own, apart from the installed copy's.
    static var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(AppInfo.name)\(DebugCLI.isDebugRun ? "-debug" : "")") }

    static func isSandboxed(_ pid: pid_t) -> Bool { sandbox_check(pid, nil, 0) != 0 }

    /// May harbor remember how this listener was started? Only a server of this user's own
    /// that harbor would also let them stop, started from a folder: never macOS's own, never
    /// harbor or anything harbor runs for a public link, never Docker's, never an app's
    /// helper (an app is opened, not re-run by a binary inside it), and never a process that
    /// runs in a sandbox (a coding agent's, say): harbor would start it outside.
    static func mayRemember(_ row: PortRow, owner: (pid_t) -> uid_t? = LibProc.owner, sandboxed: (pid_t) -> Bool = isSandboxed, tunnel: Bool) -> Bool {
        owner(row.pid) == getuid() && !tunnel && !row.isSystem && !row.isSelf && !Names.isHarbor(row.path) && row.appBundle == nil && row.container == nil
            && row.path != nil && row.folder != nil && Engine.refusal(pid: row.pid, path: row.path, name: row.processName) == nil && !sandboxed(row.pid)
    }

    private static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Stamp(device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec, size: info.st_size)
    }

    /// Reads how `row`'s process was started. nil when the kernel doesn't say, or says
    /// something harbor couldn't start again.
    static func capture(_ row: PortRow) -> Launch? {
        guard let folder = row.folder, let started = LibProc.launch(row.pid), !started.arguments.isEmpty else { return nil }
        return launch(exec: started.exec, path: row.path, arguments: started.arguments, environment: started.environment, folder: folder)
    }

    /// `path` is the kernel's own word for which program runs. `exec` is what the process
    /// says was exec'd: it is taken only when it is a whole path that leads to that same
    /// file (a virtualenv's python, a link). One that leads anywhere else: not remembered.
    static func launch(exec: String, path: String?, arguments: [String], environment: [String], folder: String) -> Launch? {
        guard let path, path.hasPrefix("/"), let resolved = real(path), let folderResolved = real(folder) else { return nil }
        if exec.hasPrefix("/"), real(exec) != resolved { return nil }
        var values: [String: String] = [:]
        for entry in environment {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            values[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return Launch(executable: exec.hasPrefix("/") ? exec : path, resolved: resolved, stamp: stamp(resolved), arguments: arguments, environment: values,
                      folder: folder, folderResolved: folderResolved)
    }

    // MARK: What is shown

    /// Text from the process, with what can't be seen made visible: control and
    /// direction-changing characters, line breaks and odd white space each become "\u{FFFD}".
    /// Nothing is dropped or joined, so two different texts never look the same by this.
    static func visible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let category = scalar.properties.generalCategory
            let hidden = category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator
                || category == .surrogate || category == .privateUse || category == .unassigned || (scalar.properties.isWhitespace && scalar != " ")
            return hidden ? "\u{FFFD}" : scalar
        }))
    }

    /// One argument as it is shown: a plain word as it is, anything else (empty, a space, a
    /// quote, anything a shell would read) in single quotes, the way a shell needs it. So
    /// where one argument ends and the next begins can't be read two ways.
    static func shown(_ argument: String) -> String {
        let text = visible(argument)
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || "_@%+=:,./-".unicodeScalars.contains($0) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// No longer than `max` code points; what was cut is said, never silently dropped.
    static func cut(_ text: String, max: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > max else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(max))) + "… (\(scalars.count - max) more characters not shown)"
    }

    /// The arguments after the program's own name, as one line. For reading only; nothing is ever started from this text.
    static func arguments(_ launch: Launch, max: Int) -> String {
        cut(launch.arguments.dropFirst().map(shown).joined(separator: " "), max: max)
    }

    /// The row's line: the program by its file's name (never argv[0], which the process
    /// chooses for itself) and its arguments. Never the environment.
    static func command(_ launch: Launch) -> String {
        cut(([shown((launch.executable as NSString).lastPathComponent)] + launch.arguments.dropFirst().map(shown)).joined(separator: " "), max: 300)
    }

    /// Variables that make a program load code: when one is set, the owner is told its name.
    static let loaders: Set<String> = ["NODE_OPTIONS", "PYTHONSTARTUP", "PYTHONPATH", "BASH_ENV", "ENV", "RUBYOPT", "PERL5OPT", "JAVA_TOOL_OPTIONS",
                                       "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD"]

    /// Has the program's file changed since harbor saw it run? (A rebuild does that: it is said, not refused.)
    static func changed(_ launch: Launch) -> Bool { launch.stamp != nil && stamp(launch.resolved) != launch.stamp }

    /// What is asked before a server is started again: the program by where it really is,
    /// its arguments, its folder and port, and what comes back with it. The environment's
    /// values are never part of it; the names of the ones that load code are.
    static func question(_ entry: Stopped) -> String {
        let launch = entry.launch
        var lines = [Fmt.path(visible(launch.resolved))]
        if launch.executable != launch.resolved { lines.append("run as \(Fmt.path(visible(launch.executable)))") }
        lines.append(launch.arguments.count > 1 ? arguments(launch, max: 1000) : "(no arguments)")
        lines.append("")
        lines.append("in \(Fmt.path(visible(launch.folder))), on port \(entry.port) as before. It gets no Terminal: its output goes to a log file.")
        let named = launch.environment.keys.filter(loaders.contains).sorted()
        lines.append("Its environment comes back as it was." + (named.isEmpty ? "" : " Set in it, and able to make it load code: \(named.joined(separator: ", "))."))
        if changed(launch) { lines.append("This program changed since it stopped.") }
        return lines.joined(separator: "\n")
    }

    // MARK: May it be started

    private static func look(_ path: String) -> (owner: uid_t, group: gid_t, mode: mode_t)? {
        var info = stat()
        return lstat(path, &info) == 0 ? (info.st_uid, info.st_gid, info.st_mode) : nil
    }

    /// Could another account change what is at `path`? Walks from it up to "/". Every step
    /// has to be this user's or root's; not writable by everyone (a folder with the sticky
    /// bit, like /tmp, apart); and not writable by a group other than admin or wheel (staff
    /// is every account on the Mac; an admin can become root anyway, and Homebrew's folders
    /// are admin's). Returns the first step that isn't, or nil.
    static func loose(_ path: String, me: uid_t = getuid(), look: (String) -> (owner: uid_t, group: gid_t, mode: mode_t)? = Restart.look) -> String? {
        var step = path
        while true {
            guard let info = look(step), info.owner == me || info.owner == 0 else { return step }
            let kind = info.mode & S_IFMT
            if kind != S_IFLNK {        // a link has no permissions of its own: who may replace it is its folder's business
                if info.mode & S_IWOTH != 0, !(kind == S_IFDIR && info.mode & S_ISVTX != 0) { return step }
                if info.mode & S_IWGRP != 0, info.group != 80, info.group != 0 { return step }
            }
            if step == "/" { return nil }
            step = (step as NSString).deletingLastPathComponent
        }
    }

    /// Why it can't be started again, or nil. What is on disk has to be where it was when
    /// the server ran: the same file, a regular one, reached the same way (a link that now
    /// leads elsewhere, or one that wasn't there, changes where it really is); the same for
    /// its folder. And nobody but this user (or root) may be able to swap either.
    static func problem(_ launch: Launch) -> String? {
        var info = stat()
        guard real(launch.executable) == launch.resolved, stat(launch.resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(launch.executable, X_OK) == 0 else {
            return "The program it ran isn't where it was any more, so it wasn't started."
        }
        guard real(launch.folder) == launch.folderResolved, stat(launch.folderResolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return "Its folder isn't where it was any more, so it wasn't started."
        }
        if let step = [launch.executable, launch.resolved, launch.folder, launch.folderResolved].lazy.compactMap({ loose($0) }).first {
            return "Another account on this Mac could change \(Fmt.path(visible(step))), so it wasn't started from there."
        }
        return nil
    }

    /// The list after a scan: what just stopped is added, and what is listening again, older
    /// than a day or beyond the newest twenty is dropped.
    static func list(_ stopped: [Stopped], adding gone: [Stopped], listening: Set<UInt16>, now: Date) -> [Stopped] {
        let fresh = gone.filter { new in !stopped.contains { $0.port == new.port && $0.launch == new.launch } }
        // The newest first; one entry per port (what ran there last).
        var seen = Set<UInt16>()
        return (fresh + stopped)
            .filter { !listening.contains($0.port) && now.timeIntervalSince($0.at) < life }
            .sorted { $0.at > $1.at }
            .filter { seen.insert($0.port).inserted }
            .prefix(keep).map { $0 }
    }

    // MARK: Starting it

    /// `<name>-<port>.log` in harbor's own log folder. The name is one of harbor's own labels.
    static func logURL(name: String, port: UInt16, in folder: URL = logs) -> URL {
        folder.appendingPathComponent("\(Names.isLabel(name) ? name : "server")-\(port).log")
    }

    /// A new, empty log only this account can read, in a folder that is really a folder of
    /// this user's (a link there is refused, not followed). Whatever was at the log's path
    /// is unlinked, never opened: a link or a second name for another file put there can't
    /// get that file emptied. Opened for appending, so the server's output and harbor's cap
    /// (see `keepSmall`) can't write over each other.
    static func openLog(_ url: URL, owner: uid_t = getuid()) -> Int32? {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == owner else { return nil }
        fchmod(dir, 0o700)      // by the open folder itself, not by its path: one that was there already is narrowed too
        unlinkat(dir, url.lastPathComponent, 0)
        let fd = openat(dir, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW, 0o600)
        return fd >= 0 ? fd : nil
    }

    /// Starts it: the remembered program with the remembered argv, in its folder, with its
    /// environment, and its output in `log`. No shell is involved at any point. Returns the
    /// process and what keeps its log small, or why not.
    static func start(_ launch: Launch, log: URL, limit: off_t = maxLog) -> (process: Process?, problem: String?, keeper: DispatchSourceFileSystemObject?) {
        if let problem = problem(launch) { return (nil, problem, nil) }
        guard let fd = openLog(log) else { return (nil, "Its log couldn't be opened, so it wasn't started.", nil) }
        let watched = dup(fd)
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = Array(launch.arguments.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: launch.folder)
        process.environment = launch.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            close(watched)
            return (nil, "It couldn't be started: \(error.localizedDescription)", nil)
        }
        return (process, nil, watched >= 0 ? keepSmall(watched, limit: limit) : nil)
    }

    /// Keeps a log under 5 MB while harbor runs: when it has grown past that, it is emptied
    /// and says so. The server writes to the file itself (so it doesn't depend on harbor
    /// staying open), which means harbor can't stop it writing; it can only start the file
    /// over. Asked when the file grows, not on a timer. `fd` is the open log (closed when
    /// this is cancelled); the file is never looked up by its path again.
    static func keepSmall(_ fd: Int32, limit: off_t = maxLog) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .delete, .rename], queue: .global(qos: .utility))
        source.setEventHandler {
            if !source.data.isDisjoint(with: [.delete, .rename]) { return source.cancel() }
            trim(fd, limit: limit)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Empties the file behind `fd` when it is over `limit`, leaving one line that says so.
    @discardableResult
    static func trim(_ fd: Int32, limit: off_t) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > limit else { return false }
        ftruncate(fd, 0)
        let line = Array("(\(AppInfo.name) emptied this log when it passed \(limit >> 20) MB)\n".utf8)
        _ = write(fd, line, line.count)
        return true
    }
}
