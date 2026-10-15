import Darwin
import Foundation

// MARK: - Models

struct PortRow: Identifiable, Hashable {
    var id: String { "\(pid)-\(port)" }
    let port: UInt16
    let addresses: [String]
    let scope: AddressScope
    let pid: pid_t
    let ppid: pid_t
    let processName: String
    let path: String?
    let cwd: String?
    let projectRoot: String?
    let command: String?
    let started: Date?
    let footprint: UInt64?
    let workers: Int
    let workerPids: [pid_t]
    let isSystem: Bool
    let appBundle: String?
    let appName: String?
    let framework: String?
    let category: PortCategory
    let isSelf: Bool
    /// The container this port is published for, when the listener is Docker's own process (see Docker).
    var container: Docker.Container? = nil
    /// The folder of the card this row sits on, when that isn't its own project folder: the git
    /// checkout above it (a site in `web/` and its API at the repo's root), or the project a
    /// container belongs to. Only the card: names, passwords and everything saved by folder
    /// still go by `projectFolder`.
    var repo: String? = nil

    /// The same listener, known as the container it forwards to: a database or a dev
    /// server by its image, and tagged with that image.
    func inContainer(_ c: Docker.Container) -> PortRow {
        PortRow(port: port, addresses: addresses, scope: scope, pid: pid, ppid: ppid, processName: processName, path: path, cwd: cwd,
                projectRoot: projectRoot, command: command, started: started, footprint: footprint, workers: workers, workerPids: workerPids,
                isSystem: isSystem, appBundle: appBundle, appName: appName, framework: c.image.isEmpty ? framework : c.image,
                category: c.isDatabase ? .database : .dev, isSelf: isSelf, container: c)
    }

    /// What the row goes by: the container, else the process.
    var label: String { container?.title ?? processName }
    /// Not a project of mine: no project folder was found for it (the page's "other apps").
    var isOtherApp: Bool { projectRoot == nil && repo == nil }

    /// Other devices on the network can open it: it listens on every interface or on a LAN address.
    var isReachable: Bool { scope == .all || scope == .specific }

    /// What a list calls this server. A runtime says nothing ("node", "Python"), so one that runs
    /// from a folder goes by the folder's name; a program with a name of its own keeps it.
    var display: String { display(served: nil) }

    /// `served` is what the server answered on "/" when it was last asked (see Probe), if it was.
    func display(served: String?) -> String {
        guard container == nil, let folder, Self.isUserFolder(folder) else { return label }
        let name = processName.lowercased()
        guard Self.runtimeNames.contains(name) || name.hasPrefix("python") else { return label }
        let leaf = Fmt.lastComponent(folder)
        guard !leaf.isEmpty else { return label }
        // A site and its API often share a folder: say which is which when the framework does.
        return role(served: served).map { "\(leaf) \($0)" } ?? leaf
    }

    /// "frontend" for a tool that only builds pages (Vite, Next, …). "backend" for a framework that
    /// serves either (Flask, Django, FastAPI…) only once it has been seen to answer "/" without a
    /// page: a title or a redirect means it renders pages itself (Jinja, Django templates), and
    /// then it is neither word. Not yet asked: no word.
    func role(served: String?) -> String? {
        guard let framework else { return nil }
        if Self.frontends.contains(framework) { return "frontend" }
        guard Self.backends.contains(framework), let served, served.first?.isNumber == true,
              !served.contains("·"), !served.contains("→") else { return nil }
        return "backend"
    }

    private static let frontends: Set = ["Vite", "Next.js", "Nuxt", "Astro", "Remix", "SvelteKit", "React", "Angular", "webpack", "Expo", "Hugo", "Jekyll"]
    private static let backends: Set = ["Flask", "Uvicorn", "FastAPI", "Gunicorn", "Django", "Rails", "Puma", "Laravel", "Rack"]

    private static let runtimeNames: Set = ["node", "ruby", "php", "java", "bun", "deno", "dotnet", "perl", "beam.smp"]

    /// What its card is called: the compose project (or "Docker"), else its own title.
    var groupTitle: String { repo.map(Fmt.lastComponent) ?? container?.group ?? title }

    /// Hidden unless "Show system ports" is on.
    var isHiddenByDefault: Bool { port < 1024 || isSystem || isSelf }

    var addressLabel: String {
        if scope == .all { return "all interfaces" }
        return addresses.joined(separator: ", ")
    }

    var url: URL {
        var host = "localhost"
        if scope == .specific, let a = addresses.first {
            host = a.contains(":") ? "[\(a)]" : a
        }
        return URL(string: "http://\(host):\(port)")!
    }

    /// Folder the server was started from, if it is a real folder.
    var folder: String? {
        guard let cwd, cwd != "/" else { return nil }
        return cwd
    }

    /// Folder used to group rows: a detected project, or the working folder of
    /// a plain command-line server. App-owned servers group under the app.
    var projectFolder: String? {
        if let projectRoot { return projectRoot }
        guard appBundle == nil, let folder, Self.isUserFolder(folder) else { return nil }
        return folder
    }

    /// Where people keep their own work (not /opt/homebrew/var and the like).
    static func isUserFolder(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") || path.hasPrefix("/Volumes/")
    }

    /// Other devices can connect: listening on all interfaces or a LAN IPv4 address.
    var onNetwork: Bool { scope == .all || (scope == .specific && addresses.contains { !$0.contains(":") }) }

    /// The QR for another device. Not offered for harbor itself or macOS services (AirPlay and the like).
    var lanReachable: Bool { !isSelf && !isSystem && onNetwork }

    /// "172.17.131.1:3000": where other devices reach it (nil when only this Mac can).
    func networkAddress(ip: String?) -> String? {
        guard onNetwork else { return nil }
        if scope == .all { return ip.map { "\($0):\(port)" } }
        return addresses.first { !$0.contains(":") }.map { "\($0):\(port)" }
    }

    /// The address a phone on the same network would open.
    func lanURL(ip: String?) -> String? {
        guard lanReachable, let a = networkAddress(ip: ip) else { return nil }
        return "http://\(a)/"
    }

    func bonjourURL(_ name: String?) -> String? {
        guard lanReachable, scope == .all, let name else { return nil }
        return "http://\(name):\(port)/"
    }

    /// The card a row belongs to: its project folder, else its app.
    var groupKey: String {
        if let repo { return "p:" + Fmt.path(repo) }
        return container.map { "d:" + $0.group } ?? projectFolder.map { "p:" + Fmt.path($0) } ?? "a:" + (appName ?? processName)
    }

    /// Project colours, in the page's fixed order.
    static let palette = ["#4f8cf7", "#19a77d", "#9a84f4", "#de5a88", "#cf9214", "#16a6c2", "#e8743f", "#6b8f2a"]

    /// The one place a project gets its colour; the menu and the page both use
    /// it. Same hash the page always used (31·h + UTF-16 unit, 32-bit), so
    /// colours people already know don't move.
    var colorHex: String { Self.colorHex(for: groupKey) }

    static func colorHex(for key: String) -> String {
        var h: Int32 = 0
        for scalar in key.unicodeScalars {
            h = h &* 31 &+ Int32(String(scalar).utf16.first ?? 0)
        }
        return palette[Int(h.magnitude % UInt32(palette.count))]
    }

    /// What to call this server in one word: its project, else its app.
    var title: String { container?.title ?? projectFolder.map(Fmt.lastComponent) ?? appName ?? processName }

    /// A hint for well-known macOS listeners that surprise developers.
    var hint: String? {
        if processName == "ControlCenter" && (port == 5000 || port == 7000) {
            return "AirPlay Receiver. Turn it off in System Settings → General → AirDrop & Handoff."
        }
        return nil
    }
}

/// Manfath-style sections for the port list.
enum PortCategory: String, CaseIterable, Hashable {
    case dev, database, runtime, appHelper, other, system

    var title: String {
        switch self {
        case .dev: return "Dev servers"
        case .database: return "Databases"
        case .runtime: return "Runtimes"
        case .appHelper: return "App helpers"
        case .other: return "Other"
        case .system: return "System services"
        }
    }
}

struct AppGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String?
    let mainPid: pid_t
    let mainPath: String?
    let pids: [pid_t]
    let footprint: UInt64
    let cpu: Double?
    let cwd: String?
    let command: String?
    let isSystem: Bool
    let isSelf: Bool

    var canQuit: Bool { !isSystem && !isSelf }
}

struct OtherProcess: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let path: String?
    let uid: uid_t
    var isSystem: Bool { LibProc.isSystemPath(path) }
}

struct ZombieParent: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let path: String?
    let count: Int
    var canQuit: Bool { pid > 1 && !LibProc.isSystemPath(path) && pid != getpid() }
}

struct ZombieReport: Equatable {
    var zombieCount = 0
    var parents: [ZombieParent] = []
    var processCount = 0
    var ownProcessCount = 0
    var maxProc = LibProc.sysctlInt("kern.maxproc") ?? 0
    var maxProcPerUID = LibProc.sysctlInt("kern.maxprocperuid") ?? 0

    static let perParentLimit = 50
    static let totalLimit = 300

    var alarm: Bool {
        zombieCount > Self.totalLimit || (parents.first?.count ?? 0) > Self.perParentLimit
    }
}

struct FullScan {
    var ports: [PortRow]
    var apps: [AppGroup]
    var others: [OtherProcess]
    var zombies: ZombieReport
    var duration: Double
}

// MARK: - Scanner

/// Reads process, port and zombie data. Not thread-safe: use from one queue.
final class Scanner: @unchecked Sendable {
    private struct StaticInfo {
        let comm: String
        let name: String
        let path: String?
        let started: Date?
        let bundle: String?
        let groupKey: String
        let isSystem: Bool
        let cwd: String?
    }

    private struct Proc {
        let pid: pid_t
        let ppid: pid_t
        let info: StaticInfo
        let footprint: UInt64
        let cpu: Double?
    }

    private let myUID = LibProc.myUID
    private let myPid = getpid()
    private var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
    private var staticCache: [pid_t: StaticInfo] = [:]
    private var cpuPrev: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
    private var projectCache: [String: String] = [:]
    private var repoCache: [String: String] = [:]
    private var commandCache: [pid_t: (name: String, command: String)] = [:]
    private var bundleNames: [String: String] = [:]
    private var frameworkCache: [String: String] = [:]
    private var docker = Docker.Book()

    private static let projectMarkers = [
        ".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile",
        "composer.json", "pom.xml", "build.gradle", "Package.swift", "manage.py",
        "requirements.txt", "deno.json", "mix.exs",
    ]

    /// Forget everything cached; used when the UI closes.
    func dropCaches() {
        staticCache = [:]
        cpuPrev = [:]
        projectCache = [:]
        repoCache = [:]
        commandCache = [:]
        fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
    }

    // MARK: Cheap idle pass

    /// One pass of short BSD info over every pid: zombie and process counts.
    func zombiePass() -> ZombieReport {
        var report = ZombieReport()
        var byParent: [pid_t: Int] = [:]
        let zomb = UInt32(SZOMB)
        for pid in LibProc.allPids() where pid > 0 {
            guard let s = LibProc.shortInfo(pid) else {
                countZombieFallback(pid, into: &report, byParent: &byParent)
                continue
            }
            report.processCount += 1
            if s.pbsi_uid == myUID { report.ownProcessCount += 1 }
            if s.pbsi_status == zomb {
                report.zombieCount += 1
                byParent[pid_t(s.pbsi_ppid), default: 0] += 1
            }
        }
        report.parents = Self.parents(byParent)
        return report
    }

    /// proc_pidinfo can't see zombies on current macOS; sysctl can.
    private func countZombieFallback(_ pid: pid_t, into report: inout ZombieReport, byParent: inout [pid_t: Int]) {
        guard let z = LibProc.zombieViaSysctl(pid) else { return } // exited meanwhile
        report.processCount += 1
        if z.uid == myUID { report.ownProcessCount += 1 }
        report.zombieCount += 1
        byParent[z.ppid, default: 0] += 1
    }

    private static func parents(_ byParent: [pid_t: Int]) -> [ZombieParent] {
        byParent.map { ppid, count in
            let path = LibProc.path(ppid)
            let name = path.map { ($0 as NSString).lastPathComponent } ?? LibProc.name(ppid) ?? "pid \(ppid)"
            let bundle = path.flatMap(LibProc.appBundle(forExecutable:))
            let display = bundle.map { FileManager.default.displayName(atPath: $0) } ?? name
            return ZombieParent(pid: ppid, name: display, path: path, count: count)
        }
        .sorted { $0.count > $1.count }
    }

    // MARK: Full scan (only while a window or the menu is open)

    func fullScan(sampleCPU: Bool, freshDocker: Bool = false) -> FullScan {
        let t0 = LibProc.monotonicNanos()
        var report = ZombieReport()
        var byParent: [pid_t: Int] = [:]
        var procs: [Proc] = []
        var others: [OtherProcess] = []
        var seen = Set<pid_t>()
        var newCPU: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
        let zomb = UInt32(SZOMB)

        for pid in LibProc.allPids() where pid > 0 {
            guard let s = LibProc.shortInfo(pid) else {
                countZombieFallback(pid, into: &report, byParent: &byParent)
                continue
            }
            report.processCount += 1
            let own = s.pbsi_uid == myUID
            if own { report.ownProcessCount += 1 }
            if s.pbsi_status == zomb {
                report.zombieCount += 1
                byParent[pid_t(s.pbsi_ppid), default: 0] += 1
                continue
            }
            seen.insert(pid)
            let info = staticInfo(pid: pid, short: s, own: own)
            if own, let ru = LibProc.usage(pid) {
                let now = LibProc.monotonicNanos()
                let cpuNs = LibProc.ticksToNanos(ru.ri_user_time &+ ru.ri_system_time)
                var cpu: Double?
                if sampleCPU {
                    if let prev = cpuPrev[pid], now > prev.at, cpuNs >= prev.cpu {
                        cpu = Double(cpuNs - prev.cpu) / Double(now - prev.at) * 100
                    }
                    newCPU[pid] = (cpuNs, now)
                }
                procs.append(Proc(pid: pid, ppid: pid_t(s.pbsi_ppid), info: info,
                                  footprint: ru.ri_phys_footprint, cpu: cpu))
            } else {
                others.append(OtherProcess(pid: pid, name: info.name, path: info.path, uid: s.pbsi_uid))
            }
        }
        staticCache = staticCache.filter { seen.contains($0.key) }
        commandCache = commandCache.filter { seen.contains($0.key) }
        cpuPrev = sampleCPU ? newCPU : [:]
        report.parents = Self.parents(byParent)

        // Docker's published ports, each as its container (asked only while Docker is listening).
        let ports = docker.name(scanPorts(procs), fresh: freshDocker)
        let apps = groupApps(procs, sampleCPU: sampleCPU)
        others.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let dt = Double(LibProc.monotonicNanos() - t0) / 1e9
        return FullScan(ports: ports, apps: apps, others: others, zombies: report, duration: dt)
    }

    private func staticInfo(pid: pid_t, short s: proc_bsdshortinfo, own: Bool) -> StaticInfo {
        let comm = LibProc.cString(s.pbsi_comm)
        if let c = staticCache[pid], c.comm == comm { return c }
        let path = LibProc.path(pid)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? comm
        var bundle = path.flatMap(LibProc.appBundle(forExecutable:))
        if bundle == nil, let path, path.contains(".xpc/"),
           let rp = LibProc.responsiblePid(pid), rp != pid,
           let rpath = LibProc.path(rp) {
            bundle = LibProc.appBundle(forExecutable: rpath)
        }
        let isSystem = LibProc.isSystemPath(path) && (bundle == nil || LibProc.isSystemPath(bundle))
        let info = StaticInfo(
            comm: comm,
            name: name,
            path: path,
            started: own ? LibProc.startDate(pid) : nil,
            bundle: bundle,
            groupKey: bundle ?? "pid:\(pid)",
            isSystem: isSystem,
            cwd: (own && bundle == nil) ? LibProc.cwd(pid) : nil
        )
        staticCache[pid] = info
        return info
    }

    private func bundleName(_ bundle: String) -> String {
        if let n = bundleNames[bundle] { return n }
        let n = FileManager.default.displayName(atPath: bundle)
        let clean = n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        bundleNames[bundle] = clean
        return clean
    }

    // MARK: Ports

    private func scanPorts(_ procs: [Proc]) -> [PortRow] {
        var raw: [LibProc.RawListener] = []
        for p in procs {
            raw.append(contentsOf: LibProc.listeners(pid: p.pid, fds: &fdBuffer))
        }
        guard !raw.isEmpty else { return [] }
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // One kernel socket can be shared by forked workers: credit the parent.
        var primaryFor: [UInt64: pid_t] = [:]
        var workersFor: [UInt64: [pid_t]] = [:]
        for (sock, ls) in Dictionary(grouping: raw, by: { $0.socketID }) {
            let pids = Set(ls.map(\.pid))
            let roots = pids.filter { pid in
                guard let pp = byPid[pid]?.ppid else { return true }
                return !pids.contains(pp)
            }
            let primary = (roots.isEmpty ? pids : roots).min()!
            primaryFor[sock] = primary
            workersFor[sock] = pids.subtracting([primary]).sorted()
        }

        struct Key: Hashable { let pid: pid_t; let port: UInt16 }
        var merged: [Key: (addrs: [String], scopes: Set<AddressScope>, workers: Set<pid_t>)] = [:]
        var seenSockets = Set<UInt64>()
        for l in raw where !seenSockets.contains(l.socketID) {
            seenSockets.insert(l.socketID)
            let pid = primaryFor[l.socketID] ?? l.pid
            let key = Key(pid: pid, port: l.port)
            var entry = merged[key] ?? ([], [], [])
            if !entry.addrs.contains(l.address) { entry.addrs.append(l.address) }
            entry.scopes.insert(l.scope)
            entry.workers.formUnion(workersFor[l.socketID] ?? [])
            merged[key] = entry
        }

        var rows: [PortRow] = []
        for (key, entry) in merged {
            guard let p = byPid[key.pid] else { continue }
            let cwd = LibProc.cwd(key.pid)
            let root = cwd.flatMap(projectRoot(for:))
            let cmd = command(for: key.pid)
            let name = p.info.bundle.map(bundleName) ?? p.info.name
            let framework = Self.framework(command: cmd?.command ?? "", name: p.info.name, root: root,
                                           projectCache: &frameworkCache)
            let userFolder = cwd.map(PortRow.isUserFolder) ?? false
            let category = Self.category(name: p.info.name, framework: framework, isSystem: p.info.isSystem,
                                         bundle: p.info.bundle, hasFolder: root != nil || (p.info.bundle == nil && userFolder))
            let scope: AddressScope = entry.scopes.contains(.all) ? .all
                : entry.scopes.contains(.specific) ? .specific : .loopback
            let addrs = entry.addrs.sorted { a, b in
                // IPv4 first, then IPv6
                (a.contains(":") ? 1 : 0, a) < (b.contains(":") ? 1 : 0, b)
            }
            rows.append(PortRow(
                port: key.port,
                addresses: addrs,
                scope: scope,
                pid: key.pid,
                ppid: p.ppid,
                processName: name,
                path: p.info.path,
                cwd: cwd,
                projectRoot: root,
                command: cmd?.command,
                started: p.info.started,
                footprint: p.footprint,
                workers: entry.workers.count,
                workerPids: entry.workers.sorted(),
                isSystem: p.info.isSystem,
                appBundle: p.info.bundle,
                appName: p.info.bundle.map(bundleName),
                framework: framework,
                category: category,
                isSelf: key.pid == myPid,
                repo: root.flatMap(repoRoot(above:))
            ))
        }
        return rows.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Short name (argv[0], which tools like node set to a useful title) and
    /// the full command line. Read once per process and cached.
    private func command(for pid: pid_t) -> (name: String, command: String)? {
        if let c = commandCache[pid] { return c.command.isEmpty ? nil : c }
        var entry = (name: "", command: "")
        if let args = LibProc.arguments(pid), let first = args.first {
            var argv0 = first.trimmingCharacters(in: .whitespaces)
            if argv0.hasPrefix("/") { argv0 = (argv0 as NSString).lastPathComponent }
            var parts = args.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !parts.isEmpty { parts[0] = argv0 }
            var text = parts.joined(separator: " ")
            if text.count > 300 { text = String(text.prefix(300)) + "…" }
            if argv0.count > 40 { argv0 = String(argv0.prefix(40)) + "…" }
            entry = (argv0, text)
        }
        commandCache[pid] = entry
        return entry.command.isEmpty ? nil : entry
    }

    private func projectRoot(for cwd: String) -> String? {
        if let c = projectCache[cwd] { return c.isEmpty ? nil : c }
        let home = NSHomeDirectory()
        var dir = cwd
        var found = ""
        // Only look for projects where people keep them; /opt/homebrew is a git
        // checkout too, but redis running from it isn't "your project".
        let roots = [home + "/", "/private/tmp/", "/tmp/", "/Volumes/"]
        guard roots.contains(where: { cwd.hasPrefix($0) }) else {
            projectCache[cwd] = ""
            return nil
        }
        for _ in 0..<8 {
            if dir == "/" || dir == home || dir.isEmpty { break }
            if Self.projectMarkers.contains(where: { access(dir + "/" + $0, F_OK) == 0 }) {
                found = dir
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        projectCache[cwd] = found
        return found.isEmpty ? nil : found
    }

    /// The git checkout a project folder sits inside, when it isn't that checkout's own top
    /// (`web/` has its package.json, the repo above it the .git). Looked for below the home
    /// folder only, so a dotfiles repo in ~ doesn't gather everything into one card.
    private func repoRoot(above root: String) -> String? {
        if let c = repoCache[root] { return c.isEmpty ? nil : c }
        let home = NSHomeDirectory()
        var found = ""
        if access(root + "/.git", F_OK) != 0 {
            var dir = (root as NSString).deletingLastPathComponent
            for _ in 0..<6 {
                if dir == "/" || dir == home || dir.isEmpty { break }
                if access(dir + "/.git", F_OK) == 0 { found = dir; break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        repoCache[root] = found
        return found.isEmpty ? nil : found
    }

    // MARK: Framework and category

    private static let databases: [String: String] = [
        "mysqld": "MySQL", "mariadbd": "MariaDB", "postgres": "PostgreSQL", "redis-server": "Redis",
        "valkey-server": "Valkey", "mongod": "MongoDB", "memcached": "Memcached", "clickhouse": "ClickHouse",
        "clickhouse-server": "ClickHouse", "influxd": "InfluxDB", "etcd": "etcd", "minio": "MinIO",
        "couchdb": "CouchDB", "neo4j": "Neo4j", "cockroach": "CockroachDB", "surreal": "SurrealDB",
    ]

    private static let runtimes: [String: String] = [
        "node": "Node.js", "python": "Python", "python3": "Python", "ruby": "Ruby", "php": "PHP",
        "php-fpm": "PHP", "java": "Java", "bun": "Bun", "deno": "Deno", "dotnet": ".NET", "beam.smp": "Erlang",
    ]

    /// Ordered: the first match in the command line wins.
    private static let commandHints: [(String, String)] = [
        ("next-server", "Next.js"), ("next dev", "Next.js"), ("next start", "Next.js"), ("/next ", "Next.js"),
        ("nuxt", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"), ("svelte-kit", "SvelteKit"), ("vite", "Vite"),
        ("react-scripts", "React"), ("ng serve", "Angular"), ("webpack", "webpack"), ("expo", "Expo"),
        ("flask", "Flask"), ("uvicorn", "Uvicorn"), ("fastapi", "FastAPI"), ("gunicorn", "Gunicorn"),
        ("runserver", "Django"), ("streamlit", "Streamlit"), ("jupyter", "Jupyter"), ("http.server", "http.server"),
        ("rails", "Rails"), ("puma", "Puma"), ("artisan serve", "Laravel"), ("php-fpm", "PHP-FPM"),
        ("ollama", "Ollama"), ("com.docker", "Docker"), ("wrangler", "Wrangler"), ("hugo", "Hugo"), ("jekyll", "Jekyll"),
    ]

    private static let configHints: [(String, String)] = [
        ("next.config.js", "Next.js"), ("next.config.mjs", "Next.js"), ("next.config.ts", "Next.js"),
        ("nuxt.config.ts", "Nuxt"), ("nuxt.config.js", "Nuxt"), ("astro.config.mjs", "Astro"),
        ("astro.config.ts", "Astro"), ("svelte.config.js", "SvelteKit"), ("remix.config.js", "Remix"),
        ("vite.config.ts", "Vite"), ("vite.config.js", "Vite"), ("vite.config.mjs", "Vite"),
        ("manage.py", "Django"), ("artisan", "Laravel"), ("config.ru", "Rack"),
    ]

    private static func framework(command: String, name: String, root: String?,
                                  projectCache: inout [String: String]) -> String? {
        if let db = databases[name] { return db }
        let cmd = command.lowercased()
        if let hit = commandHints.first(where: { cmd.contains($0.0) }) { return hit.1 }
        if let root {
            if let cached = projectCache[root] { if !cached.isEmpty { return cached } }
            else {
                let found = configHints.first { access(root + "/" + $0.0, F_OK) == 0 }?.1 ?? ""
                projectCache[root] = found
                if !found.isEmpty { return found }
            }
        }
        return runtimes[name] ?? runtimes[name.lowercased()]
    }

    private static func category(name: String, framework: String?, isSystem: Bool, bundle: String?,
                                 hasFolder: Bool) -> PortCategory {
        if isSystem { return .system }
        if databases[name] != nil || databases.values.contains(framework ?? "") { return .database }
        if bundle != nil { return .appHelper }
        if hasFolder { return .dev }
        if runtimes[name] != nil || runtimes[name.lowercased()] != nil { return .runtime }
        return .other
    }

    // MARK: Apps

    private func groupApps(_ procs: [Proc], sampleCPU: Bool) -> [AppGroup] {
        var groups: [AppGroup] = []
        for (key, ps) in Dictionary(grouping: procs, by: { $0.info.groupKey }) {
            let pidSet = Set(ps.map(\.pid))
            let bundle = ps[0].info.bundle
            var main: Proc
            if let bundle {
                let macos = bundle + "/Contents/MacOS/"
                let mains = ps.filter { p in
                    guard let path = p.info.path, path.hasPrefix(macos) else { return false }
                    return !path.dropFirst(macos.count).contains("/")
                }
                main = mains.min(by: { $0.pid < $1.pid })
                    ?? ps.filter { !pidSet.contains($0.ppid) }.min(by: { $0.pid < $1.pid })
                    ?? ps.min(by: { $0.pid < $1.pid })!
            } else {
                main = ps[0]
            }
            let cmd = bundle == nil ? command(for: main.pid) : nil
            let footprint = ps.reduce(UInt64(0)) { $0 + $1.footprint }
            var cpu: Double?
            if sampleCPU {
                let known = ps.compactMap(\.cpu)
                cpu = known.isEmpty ? nil : known.reduce(0, +)
            }
            groups.append(AppGroup(
                id: key,
                name: bundle.map(bundleName) ?? cmd.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? main.info.name,
                bundlePath: bundle,
                mainPid: main.pid,
                mainPath: main.info.path,
                pids: ps.map(\.pid).sorted(),
                footprint: footprint,
                cpu: cpu,
                cwd: main.info.cwd,
                command: cmd?.command,
                isSystem: main.info.isSystem,
                isSelf: pidSet.contains(myPid)
            ))
        }
        // Sort in 16 MB steps (ties by name) so rows don't swap places every
        // refresh when two apps use about the same memory.
        return groups.sorted { a, b in
            let qa = a.footprint >> 24, qb = b.footprint >> 24
            if qa != qb { return qa > qb }
            return (a.name, a.id) < (b.name, b.id)
        }
    }
}
