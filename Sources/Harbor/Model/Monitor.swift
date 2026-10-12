import AppKit
import Foundation
import Observation

/// Sections of the localhost page that a suggestion can point at.
enum PageSection: String {
    case ports, memory, leaks
}

enum IconState: Equatable {
    case good, warn, bad, zombies
}

/// App-wide state. Cheap when nothing is open: one 60 s timer for swap and
/// zombie counts plus the kernel's memory-pressure event. Full scans (ports,
/// apps, CPU) run every 3 s only while the menu is open, or on request while
/// the localhost page is open and polling.
@MainActor
@Observable
final class Monitor {
    static let shared = Monitor()

    enum Surface: Hashable { case menu, panel }

    private(set) var memory = MemorySnapshot()
    private(set) var zombies = ZombieReport()
    private(set) var ports: [PortRow] = []
    private(set) var apps: [AppGroup] = []
    private(set) var others: [OtherProcess] = []
    private(set) var lastFullScan: Date?
    private(set) var lastScanDuration: Double = 0
    private(set) var iconState: IconState = .good
    private(set) var busy: Set<pid_t> = []
    private(set) var notices: [Notice] = []
    // Port filters, shared by the menu and the page (Manfath's visible range).
    var showSystemPorts = DebugCLI.defaults.bool(forKey: "showSystemPorts") {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(showSystemPorts, forKey: "showSystemPorts") }; refreshBadge() }
    }
    var onlyServers = DebugCLI.defaults.bool(forKey: "onlyServers") {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(onlyServers, forKey: "onlyServers") }; refreshBadge() }
    }
    var minPort = (DebugCLI.defaults.object(forKey: "minPort") as? Int) ?? 1024 {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(minPort, forKey: "minPort") }; refreshBadge() }
    }
    var maxPort = (DebugCLI.defaults.object(forKey: "maxPort") as? Int) ?? 65535 {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(maxPort, forKey: "maxPort") }; refreshBadge() }
    }

    /// Show harbor in the Dock (on by default); the menu bar icon stays either way.
    var showInDock = (DebugCLI.defaults.object(forKey: "showInDock") as? Bool) ?? true {
        didSet {
            if !DebugCLI.isDebugRun { DebugCLI.defaults.set(showInDock, forKey: "showInDock") }
            applyDockPolicy()
        }
    }

    func applyDockPolicy() {
        guard !DebugCLI.isDebugRun else { return }
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case project, category, flat
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// How ports are grouped, in the menu and on the page alike.
    var grouping = Grouping(rawValue: DebugCLI.defaults.string(forKey: "grouping") ?? "") ?? .project {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(grouping.rawValue, forKey: "grouping") } }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// For windows harbor draws itself (alerts); nil follows macOS.
        var nsAppearance: NSAppearance? {
            self == .auto ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }
    }

    /// Light or dark for the menu dropdown and its popovers; the menu bar icon always follows macOS.
    var appearance = Appearance(rawValue: DebugCLI.defaults.string(forKey: "appearance") ?? "") ?? .auto {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(appearance.rawValue, forKey: "appearance") } }
    }

    /// Light or dark for the page, set on the page and kept apart from the menu's.
    var pageAppearance: Appearance = {
        if let saved = Appearance(rawValue: DebugCLI.defaults.string(forKey: "pageAppearance") ?? "") { return saved }
        // The first run with two settings: start from the menu's, so nothing visibly changes.
        let start = Appearance(rawValue: DebugCLI.defaults.string(forKey: "appearance") ?? "") ?? .auto
        if !DebugCLI.isDebugRun { DebugCLI.defaults.set(start.rawValue, forKey: "pageAppearance") }
        return start
    }() {
        didSet { if !DebugCLI.isDebugRun { DebugCLI.defaults.set(pageAppearance.rawValue, forKey: "pageAppearance") } }
    }

    /// Manfath's "Refresh": seconds between scans while the menu is open; 0 = manual.
    static let presetIntervals: [Double] = [5, 15, 30, 60, 0]

    /// Whole seconds, 5 to 3600; 0 means manual.
    static func clampInterval(_ v: Double) -> Double {
        v == 0 ? 0 : Double(min(3600, max(5, Int(v.rounded()))))
    }

    var refreshInterval: Double = {
        // Older choices (1, 3, 10 s) become the new default of 15 s.
        guard let saved = DebugCLI.defaults.object(forKey: "refreshInterval") as? Double,
              ![1, 3, 10].contains(saved) else { return 15 }
        return Monitor.clampInterval(saved)
    }() {
        didSet {
            if !DebugCLI.isDebugRun { DebugCLI.defaults.set(refreshInterval, forKey: "refreshInterval") }
            if isFastMode { enterFastMode() }
            updateBadgeTimer()
        }
    }
    /// Manfath's "Menu bar badge": "hidden" (default), "count" or "dot". With a
    /// badge, ports are scanned at the refresh interval even when nothing is open
    /// (manual: on the 60 s tick), so the count stays live.
    var badgeMode = DebugCLI.defaults.string(forKey: "badgeMode") ?? "hidden" {
        didSet {
            DebugCLI.defaults.set(badgeMode, forKey: "badgeMode")
            if badgeMode != "hidden" && !isFastMode { requestFullScan() }
            updateBadgeTimer()
            refreshBadge()
        }
    }

    /// What the menu bar shows next to the icon. Set only when it changes, so a
    /// scan that finds the same ports doesn't redraw the status item.
    private(set) var badgeCount = 0
    @ObservationIgnored private var badgeTimer: Timer?

    func refreshBadge() {
        let c = badgeMode == "hidden" ? 0 : visiblePorts.count
        if c != badgeCount { badgeCount = c }
    }

    /// How often harbor scans with nothing open, or nil for not at all. With something on the
    /// network: every 15 seconds, or sooner when the refresh setting is shorter, whatever that
    /// setting is (a minute, an hour, manual): a share is for one server, and for one container,
    /// and only a scan sees that it has gone. Otherwise only for a badge, at the refresh setting.
    nonisolated static func scanEvery(refresh: Double, sharing: Bool, badge: Bool) -> Double? {
        if sharing { return refresh > 0 ? min(refresh, 15) : 15 }
        return badge && refresh > 0 ? refresh : nil
    }

    private func updateBadgeTimer() {
        badgeTimer?.invalidate()
        badgeTimer = nil
        let sharing = !lanShares.isEmpty
        guard started, let every = Self.scanEvery(refresh: refreshInterval, sharing: sharing, badge: badgeMode != "hidden") else { return }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // For the badge alone, the open menu or the page's polls already scan. For a share that isn't enough:
                // they scan at the refresh setting, which may be a minute or never.
                guard let self, sharing || (!self.isFastMode && !self.webActive) else { return }
                self.requestFullScan()
            }
        }
        t.tolerance = every / 5
        RunLoop.main.add(t, forMode: .common)
        badgeTimer = t
    }
    /// Manfath's "Process blocklist": rows whose process name matches are hidden.
    var blocklist = DebugCLI.defaults.stringArray(forKey: "blocklist") ?? [] {
        didSet { DebugCLI.defaults.set(blocklist, forKey: "blocklist"); refreshBadge() }
    }

    func hideProcess(_ name: String) {
        let n = name.lowercased()
        if !blocklist.contains(n) { blocklist.append(n) }
    }

    func setRange(_ lo: Int, _ hi: Int) {
        let a = min(max(lo, 1), 65535), b = min(max(hi, 1), 65535)
        minPort = min(a, b)
        maxPort = max(a, b)
    }
    var toast: String?

    struct Notice: Identifiable, Equatable {
        let id: Int
        let text: String
        let at: Date
    }

    @ObservationIgnored private let queue = DispatchQueue(label: "local.harbor.scan", qos: .utility)
    @ObservationIgnored private let scanner = Scanner()
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var fastTimer: Timer?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var visible = Set<Surface>()
    @ObservationIgnored private var surfaceWindows: [Surface: WeakWindow] = [:]
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var toastToken = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var noticeCounter = 0
    @ObservationIgnored private var pendingFresh: [() -> Void] = []
    @ObservationIgnored private var webLastSeen: Date?
    @ObservationIgnored private var webIdleWork: DispatchWorkItem?

    private init() {}

    var isFastMode: Bool { fastTimer != nil }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        memory = SystemMemory.read()
        updateIcon()

        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = src.data
                var m = SystemMemory.read()
                if event.contains(.critical) { m.pressure = .critical }
                else if event.contains(.warning) { m.pressure = max(m.pressure, .warning) }
                self.setMemory(m)
                if event.contains(.warning) || event.contains(.critical), !self.isFastMode {
                    self.queue.async { [scanner = self.scanner] in scanner.dropCaches() }
                }
            }
        }
        src.resume()
        pressureSource = src

        idlePass()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idlePass() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
        updateBadgeTimer()
    }

    /// Swap, RAM breakdown and zombie counts. Runs every 60 s, always.
    private func idlePass() {
        guard !isFastMode else { return }
        if badgeMode != "hidden" {
            // The badge needs a port count: one full scan (no CPU sampling).
            requestFullScan()
            return
        }
        DebugCLI.log("idle pass")
        queue.async { [weak self, scanner] in
            let z = scanner.zombiePass()
            let m = SystemMemory.read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setMemory(m)
                    self.setZombies(z)
                }
            }
        }
    }

    // MARK: Visibility → fast mode

    /// Remember which window shows each surface, so every fast tick can check
    /// that it is still on screen even if a notification was missed.
    func register(_ surface: Surface, window: NSWindow?) {
        surfaceWindows[surface] = WeakWindow(window: window)
    }

    private func recheckSurfaces() {
        for s in visible {
            let w = surfaceWindows[s]?.window
            let onScreen = w.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            if !onScreen {
                DebugCLI.log("surface \(s) no longer on screen")
                visible.remove(s)
            }
        }
    }

    func setVisible(_ surface: Surface, _ isVisible: Bool) {
        let wasActive = !visible.isEmpty
        if isVisible { visible.insert(surface) } else { visible.remove(surface) }
        let active = !visible.isEmpty
        if active && !wasActive {
            enterFastMode()
        } else if !active && wasActive {
            leaveFastMode()
        } else if isVisible {
            requestFullScan()
        }
    }

    private func enterFastMode() {
        DebugCLI.log("fast mode on (\(visible))")
        checkDoor()
        requestFullScan()
        // A second sample soon after opening so CPU % shows up quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.requestFullScan() }
        }
        fastTimer?.invalidate()
        fastTimer = nil
        guard refreshInterval > 0 else {
            // Manual: one scan on open, then only the refresh button. Keep a slow
            // timer just to notice that the menu has closed.
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recheckSurfaces()
                    if self.visible.isEmpty { self.leaveFastMode() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            fastTimer = t
            return
        }
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recheckSurfaces()
                if self.visible.isEmpty { self.leaveFastMode() } else { self.requestFullScan() }
            }
        }
        t.tolerance = min(0.5, refreshInterval / 4)
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    private func leaveFastMode() {
        DebugCLI.log("fast mode off")
        fastTimer?.invalidate()
        fastTimer = nil
        // CPU samples go stale while hidden; drop them and the per-pid caches.
        queue.async { [scanner] in scanner.dropCaches() }
        apps = apps.map { g in
            AppGroup(id: g.id, name: g.name, bundlePath: g.bundlePath, mainPid: g.mainPid, mainPath: g.mainPath,
                     pids: g.pids, footprint: g.footprint, cpu: nil, cwd: g.cwd, command: g.command,
                     isSystem: g.isSystem, isSelf: g.isSelf)
        }
    }

    /// Made-up ports for snapshots (`--fixture`): shown instead of this Mac's, and never scanned over.
    @ObservationIgnored private var fixture: [PortRow]?
    /// Is this the made-up Mac? Then nothing real is ever started, asked or opened for a row.
    var isMadeUp: Bool { fixture != nil }

    func useFixture(_ rows: [PortRow], shared key: String?, every: Bool = false) {
        fixture = rows
        requestFullScan()
        // What the made-up servers "answer", so a snapshot shows the line without anything being asked.
        let answers: [UInt16: String] = [3000: "200 · Storefront – Admin", 3001: "404", 8000: "200 · Notes API · Swagger UI", 8080: "301 → /shop/", 8025: "200 · Mailpit"]
        served = Dictionary(uniqueKeysWithValues: rows.compactMap { row in answers[row.port].map { (row.id, Served(line: $0, at: Date())) } })
        guard let key else { return }
        // The project's main server; or, for the look of several, each of its servers under its own name.
        for row in rows where Names.key(row) == key && (every || isMain(row)) {
            guard let name = networkName(row) else { continue }
            lanShares[row.id] = LanShare(name: name, project: key, port: 80, hasPassword: true, pid: row.pid, serverPort: row.port, started: row.started,
                                         container: row.container?.id, announced: true)
        }
        guard lanShares.values.contains(where: { $0.project == key }) else { return }
        // The made-up project has a made-up password, so every row of it says the same.
        if Passwords.inMemory { Passwords.set(key, "k7mqx2hw"); passwordKnown[key] = nil }
        lanNetwork = LAN.Network(interface: "en0", address: "192.168.1.24", router: "192.168.1.1")
    }

    func requestFullScan() {
        if let fixture {
            // A made-up Mac all the way down: its memory line too.
            apply(FullScan(ports: fixture, apps: [], others: [], zombies: ZombieReport(), duration: 0.006),
                  memory: MemorySnapshot(physical: 16 << 30, app: 6 << 30, wired: 2 << 30, compressed: 1 << 30, cached: 4 << 30, free: 3 << 30))
            lanIP = "192.168.1.24"
            lanName = "Sams-MacBook.local"
            return
        }
        guard !scanInFlight else { return }
        scanInFlight = true
        DebugCLI.log("full scan")
        let sampleCPU = isFastMode || !visible.isEmpty || webActive
        // With a container on the network, every scan asks Docker again: nothing kept from a moment ago.
        let freshDocker = lanShares.values.contains { $0.container != nil }
        queue.async { [weak self, scanner] in
            let scan = scanner.fullScan(sampleCPU: sampleCPU, freshDocker: freshDocker)
            let m = SystemMemory.read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanInFlight = false
                    if self.fixture != nil { return }      // a scan begun before the made-up ports were set
                    self.apply(scan, memory: m)
                }
            }
        }
    }

    /// This Mac's LAN address and Bonjour name, read again on every scan so a new Wi-Fi shows up.
    private(set) var lanIP = LAN.ipv4()
    private(set) var lanName = LAN.bonjourName()

    private func apply(_ scan: FullScan, memory m: MemorySnapshot) {
        if ports != scan.ports { ports = scan.ports }
        let table = Names.assign(scan.ports, saved: savedNames, previous: names, mains: savedMains)
        if table != names { names = table }
        moveOldNetworkNames()
        if served.keys.contains(where: { id in !scan.ports.contains { $0.id == id } }) {
            served = served.filter { answer in scan.ports.contains { $0.id == answer.key } }
        }
        // A share is for one server: that process, on that port. When it is gone the project
        // comes off the network, whatever else of it still runs or has started since. And when
        // another program listens on that port too (on one address, say, in front of a server
        // that listens on all of them), a request could land on it instead: off as well.
        for (key, share) in lanShares {
            if !scan.ports.contains(where: { $0.id == share.row && $0.started == share.started }) {
                stopSharing(key, because: "\(share.name)\(Lan.suffix) stopped, so it is off the network.")
            } else if scan.ports.first(where: { $0.id == share.row })?.container?.id != share.container {
                // Docker's process is still there and still has the port, but for another container (or none it can name).
                stopSharing(key, because: "The container behind \(share.name)\(Lan.suffix) stopped or changed, so it is off the network.")
            } else if let other = Self.otherListener(on: share.serverPort, than: share.pid, in: scan.ports) {
                stopSharing(key, because: "\(other.processName) is listening on port \(share.serverPort) too, so \(share.name)\(Lan.suffix) is off the network.")
            }
        }
        if fixture == nil {                       // made-up ports sit on a made-up network
            checkNetwork()
            let ip = LAN.ipv4(), name = LAN.bonjourName()
            if ip != lanIP { lanIP = ip }
            if name != lanName { lanName = name }
        }
        refreshBadge()
        Tunnels.shared.prune(listening: Set(scan.ports.map(\.port)))
        endExpired()
        if apps != scan.apps {
            // Load icons here, not while the list is laying out its rows.
            IconCache.shared.warm(scan.apps.prefix(60).compactMap(\.bundlePath))
            apps = scan.apps
        }
        if others != scan.others { others = scan.others }
        lastScanDuration = scan.duration
        lastFullScan = Date()
        leaveNote()
        setMemory(m)
        setZombies(scan.zombies)
        let waiting = pendingFresh
        pendingFresh = []
        waiting.forEach { $0() }
    }

    // MARK: What a row serves (see Probe)

    struct Served: Equatable {
        let line: String
        let at: Date
    }

    /// What each looked-at row last answered on "/", by row. Forgotten when the row goes.
    private(set) var served: [String: Served] = [:]
    @ObservationIgnored private var asking = Set<String>()
    /// Is an answer still on its way? (The page looks again a moment later.)
    var isAsking: Bool { !asking.isEmpty }

    /// Somebody is looking at these rows right now: their details are open in the menu, or
    /// they are on screen on the page. Only then, and only as often as `Probe.pick` allows,
    /// is a server asked what it serves. Nothing here runs from a timer.
    func look(at ids: [String], now: Date = Date()) {
        guard fixture == nil, !ids.isEmpty else { return }       // made-up rows have made-up answers
        let picked = Probe.pick(ids, rows: ports, named: Set(names.byRow.keys), last: served.mapValues(\.at), asking: asking, now: now)
        for id in picked {
            guard let row = ports.first(where: { $0.id == id }), let name = names.byRow[id], let target = names.targets[name], let host = nameHost(row) else { continue }
            asking.insert(id)
            DispatchQueue.global(qos: .utility).async {
                let line = Probe.ask(target, host: host)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let m = Monitor.shared
                        m.asking.remove(id)
                        if m.ports.contains(where: { $0.id == id }) { m.served[id] = Served(line: line, at: Date()) }
                    }
                }
            }
        }
    }

    // MARK: Ports

    /// The port the page is served on, once it is (WebServer sets it).
    var pagePort: Int?
    /// Port 80 doesn't reach harbor's door: another program holds it on this Mac.
    var port80Taken = false
    @ObservationIgnored private var doorChecked: Date?
    @ObservationIgnored private var doorChecking = false

    /// Is it time to look at the door? Once at launch, and after that only while it isn't
    /// harbor's or isn't reached, at most once a minute. A door that is right costs nothing.
    nonisolated static func doorCheckDue(ours: Bool, last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return !ours && now.timeIntervalSince(last) >= 60
    }

    /// Makes the door harbor's and sees whether port 80 reaches it, off the main thread. Called
    /// at launch and whenever the menu or the page is looked at, so a failed takeover or one
    /// slow answer at launch doesn't stand for the whole run.
    func checkDoor() {
        guard !DebugCLI.isDebugRun, !doorChecking, Self.doorCheckDue(ours: doorIsOurs, last: doorChecked) else { return }
        doorChecking = true
        DispatchQueue.global(qos: .utility).async {
            let door = Door.check()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = Monitor.shared
                    m.doorChecking = false
                    m.doorChecked = Date()
                    if m.doorIsOurs != door.reaches { m.doorIsOurs = door.reaches }
                    if m.port80Taken != (door.ours && !door.reaches) { m.port80Taken = door.ours && !door.reaches }
                }
            }
        }
    }

    /// Quiet lines for the menu's header and the page's: harbor had to move off its usual
    /// port, or the bare name can't work.
    var portNotes: [String] {
        var notes: [String] = []
        if !lanShares.isEmpty {
            // Projects, as long as each has one server there; servers once one has several.
            let projects = Set(lanShares.values.map(\.project)).count, servers = lanShares.count
            notes.append(servers > projects ? "\(servers) servers on your network" : projects == 1 ? "1 project on your network" : "\(projects) projects on your network")
        }
        if !lanShares.isEmpty, lanIPv6Taken, let port = lanShares.values.first?.port { notes.append("Another program has port \(port) on IPv6") }
        guard let port = pagePort else { return notes }
        if port != Ports.harbor.usual, fixture == nil { notes.append("On port \(port): \(Ports.harbor.usual) was in use") }   // a made-up Mac has no such thing to say
        if port80Taken {
            notes.append("\(WebServer.host) needs port 80, which another program is using; use \(WebServer.host):\(port)")
        }
        return notes
    }

    // MARK: On network (<name>.local)

    struct LanShare: Equatable {
        var name: String        // on the network, without ".local"
        var project = ""        // its folder: the password, and the sign-in, are the project's
        var port: UInt16        // 80, or the listener's high port (then it is part of the link)
        var hasPassword: Bool
        /// The server it is shared for: its process, its port, and when that process started.
        let pid: pid_t
        let serverPort: UInt16
        let started: Date?
        /// The container it is shared for, when the process is Docker's own: that process holds
        /// every published port, so only the container's id tells whose port this is.
        var container: String? = nil
        /// When it comes off the network by itself (see Lasting). nil: when it is turned off.
        var until: Date? = nil
        var row: String { "\(pid)-\(serverPort)" }      // PortRow.id
        /// macOS has announced the name: nil until it answers, which it only does once the
        /// user has let harbor use the local network.
        var announced: Bool?
        var since = Date()
        /// Other devices can't find the name: macOS said no, or has said nothing for a while.
        var isUnannounced: Bool { announced == false || (announced == nil && Date().timeIntervalSince(since) > 4) }
    }

    /// The servers that are on the network right now, by row ("pid-port": a share is for one
    /// server and stays with it). Never remembered across launches; names and passwords are.
    private(set) var lanShares: [String: LanShare] = [:] {
        // While something is on the network harbor keeps looking, with everything closed too.
        didSet {
            if oldValue.isEmpty != lanShares.isEmpty { updateBadgeTimer() }
            if oldValue != lanShares { sharesChanged() }
        }
    }

    // MARK: Shares that stop by themselves (see Lasting)

    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var wakeWatch: NSObjectProtocol?

    /// Something was shared, stopped, or given more time: the one timer is set for the
    /// nearest deadline (none while nothing has one), and the command line's note is brought
    /// up to date. The timer alone isn't trusted: it doesn't run while the Mac sleeps, so
    /// the deadlines are also looked at on waking and with every scan.
    func sharesChanged() {
        armExpiry()
        leaveNote()
    }

    /// When the one timer will next look, for a test.
    var expiryArmedFor: Date? { expiryTimer.flatMap { $0.isValid ? $0.fireDate : nil } }
    /// The timer goes off now, whatever the clock says (a test's stand-in for a clock that was set back).
    func fireExpiryTimer() { expiryTimer?.fire() }

    private func armExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let deadlines = lanShares.values.compactMap(\.until) + Tunnels.shared.active.values.compactMap(\.until)
        if let next = deadlines.min() {
            let timer = Timer(fire: next, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { Monitor.shared.endExpired() } }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
            if wakeWatch == nil {
                wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { Monitor.shared.endExpired() }
                }
            }
        }
    }

    /// Stops what has run out of time, exactly as turning it off by hand does, and says so.
    func endExpired(now: Date = Date()) {
        for (id, share) in lanShares where Lasting.isOver(share.until, now: now) {
            stopSharing(id, because: "\(share.name)\(Lan.suffix) is off the network: its time is up.")
        }
        Tunnels.shared.endExpired(now: now)
        // The timer is good for one go. If it went off early (the clock was set back) nothing was over, and
        // without this nothing would look again: set it for whatever deadline is still ahead.
        armExpiry()
    }

    /// Half an hour more for a server that is on the network with a deadline.
    func moreTime(_ row: PortRow, now: Date = Date()) {
        guard let until = lanShares[row.id]?.until else { return }
        lanShares[row.id]?.until = Lasting.extended(until, now: now)
    }

    /// Gives a share a deadline, or takes it away (nil). Made-up shares and tests use it.
    func setDeadline(_ id: String, _ until: Date?) {
        lanShares[id]?.until = until
    }

    /// What the command line is told (see Shared): which rows are on the network or behind a public link.
    private func leaveNote() {
        var links: [String: String] = [:]
        for (port, tunnel) in Tunnels.shared.active {
            if case .ready(let url) = tunnel.phase, let row = ports.first(where: { $0.port == port }) { links[row.id] = url }
        }
        let network = Dictionary(uniqueKeysWithValues: lanShares.map { id, share in (id, "http://\(share.name)\(Lan.suffix)\(share.port == 80 ? "" : ":\(share.port)")/") })
        Shared.leave(names: names.byRow, door: doorIsOurs, proxy: Int(proxyPort), network: network, links: links)
    }
    /// While sharing: harbor couldn't have the port on IPv6 as well, because another program has it.
    private(set) var lanIPv6Taken = false

    /// Why the network listener's port couldn't be had, in the owner's words. Never "another
    /// program" when it is harbor's own door.
    nonisolated static func portProblem(_ port: UInt16, _ opening: Door.Opening, holder: String?, ownDoor: Bool) -> String {
        if ownDoor {
            return "Port \(port) is \(AppInfo.name)'s own door's, and only the \(AppInfo.name) in Applications can move it aside. Open that one to put a project on the network."
        }
        return opening == .taken ? "Port \(port) on this Mac is used by \(holder ?? "another program"), so nothing can go on the network."
            : "Port \(port) on this Mac isn't free yet. Try again in half a minute."
    }

    /// Somebody else listening on a shared server's port: not that process, and not one it started itself (its workers).
    static func otherListener(on port: UInt16, than pid: pid_t, in rows: [PortRow]) -> PortRow? {
        rows.first { $0.port == port && $0.pid != pid && $0.ppid != pid }
    }
    /// Names on the network, saved for one server each: by its project's folder and its port
    /// (`nameKey`), so a name stays with the server it was given to when another becomes the
    /// project's main one.
    @ObservationIgnored private var savedLanNames = (DebugCLI.defaults.dictionary(forKey: "lanNames") as? [String: String]) ?? [:]
    @ObservationIgnored private var lanNetwork: LAN.Network?

    /// Is this the server its project's plain name opens (`storefront.localhost`, `storefront.local`)?
    func isMain(_ row: PortRow) -> Bool {
        guard names.byRow[row.id] != nil, let name = names.base[Names.key(row)] else { return false }
        return names.targets[name]?.port == row.port
    }

    /// Does this row's project have more than one server with a name?
    func hasSiblings(_ row: PortRow) -> Bool {
        let key = Names.key(row)
        return ports.contains { $0.id != row.id && Names.key($0) == key && names.byRow[$0.id] != nil }
    }

    private func nameKey(_ row: PortRow) -> String { "\(Names.key(row))\t\(row.port)" }

    /// Up to 1.4.x a main server's network name was saved by folder alone, so it went with
    /// whichever server was main. Each of those is handed, once, to the server that is main
    /// when its project is first seen running (`mains`: that port, by folder), and is that
    /// server's from then on. A name the server already has of its own wins.
    nonisolated static func handedOver(_ saved: [String: String], mains: [String: UInt16]) -> [String: String] {
        var names = saved
        for (project, name) in saved where !project.contains("\t") {
            guard let port = mains[project] else { continue }
            names[project] = nil
            if names["\(project)\t\(port)"] == nil { names["\(project)\t\(port)"] = name }
        }
        return names
    }

    private func moveOldNetworkNames() {
        guard savedLanNames.keys.contains(where: { !$0.contains("\t") }) else { return }
        let moved = Self.handedOver(savedLanNames, mains: Dictionary(ports.filter(isMain).map { (Names.key($0), $0.port) }, uniquingKeysWith: { first, _ in first }))
        guard moved != savedLanNames else { return }
        savedLanNames = moved
        DebugCLI.defaults.set(moved, forKey: "lanNames")
    }

    /// What going without a password means for this server's project, for the question asked
    /// first. There is one password per project: with more of its servers on the network (this
    /// one counted, on already or about to be) it is all of them, and that is what is said.
    func anyoneCanOpen(_ row: PortRow) -> String {
        let project = Names.key(row)
        let others = lanShares.filter { $0.key != row.id && $0.value.project == project }.count
        return Lan.anyoneCanOpen(name: networkName(row) ?? row.title, project: names.base[project] ?? row.title, servers: others + 1)
    }

    /// What a server is called on the network while it is on it, or would be: the name saved
    /// for it there, else its `.localhost` name (`storefront`, `storefront-8000`). Debug runs
    /// add a suffix, so a test collides with nothing real.
    func networkName(_ row: PortRow) -> String? {
        if let share = lanShares[row.id] { return share.name }
        return (savedLanNames[nameKey(row)] ?? names.byRow[row.id]).map { $0 + DebugCLI.lanSuffix }
    }

    /// Can this row go on the network? Any server with a name can, each with its own switch.
    func isNetworkRow(_ row: PortRow) -> Bool { names.byRow[row.id] != nil }

    /// The codes a row shows, each with what it is and the link it holds (see QR.codes).
    func codes(_ row: PortRow) -> [(code: QR.Code, label: String, link: String)] {
        let name = networkLink(row)
        let lan = row.lanURL(ip: lanIP)
        var share: String?
        if case .ready(let url)? = Tunnels.shared.active[row.port]?.phase { share = url }
        return QR.codes(onNetwork: name != nil, reachable: lan != nil, shared: share != nil).compactMap { code in
            switch code {
            case .name: return name.map { (code, "On your network", $0) }
            case .lan: return lan.map { (code, "On your network", $0) }
            case .share: return share.map { (code, "Public link", $0) }
            }
        }
    }

    /// "http://storefront.local/" while that server is on the network.
    func networkLink(_ row: PortRow) -> String? {
        lanShares[row.id].map { "http://\($0.name)\(Lan.suffix)\($0.port == 80 ? "" : ":\($0.port)")/" }
    }

    /// A project's password (by its folder): one for all of its servers on the network.
    func networkPassword(_ project: String) -> String? {
        if case .password(let saved) = Passwords.read(project) { return saved }
        return nil
    }

    /// What a share may start with: its saved password; none, but only when the owner has
    /// just said so; or nothing at all. A password that can't be read is never "none".
    nonisolated static func gate(_ saved: Passwords.Read, open: Bool, name: String) -> (password: String?, problem: String?) {
        switch saved {
        case .password(let password): return (password, nil)
        case .none: return (nil, open ? nil : "Choose a password first, or share it without one.")
        case .unreadable: return (nil, "The saved password for \(name)\(Lan.suffix) can't be read. Set a new password to put it on the network.")
        }
    }

    /// Does the project have a password saved? Remembered, so the page's polls don't read the file each time.
    func hasNetworkPassword(_ project: String) -> Bool {
        if let known = passwordKnown[project] { return known }
        // One that can't be read is not one harbor can use: the panel offers to set a new one.
        var has = false
        if case .password = Passwords.read(project) { has = true }
        passwordKnown[project] = has
        return has
    }
    @ObservationIgnored private var passwordKnown: [String: Bool] = [:]

    /// Devices signed in to this row's project right now.
    func devices(_ row: PortRow) -> Int { OnNetwork.shared.devices(project: Names.key(row)) }

    /// Saves a project's password (nil: none) and gives it to every server of the project
    /// that is on the network: there is one per project. Everyone signs in again.
    private func keep(_ password: String?, for project: String) -> Bool {
        guard Passwords.set(project, password) else { return false }
        passwordKnown[project] = password != nil
        for (id, share) in lanShares where share.project == project {
            OnNetwork.shared.setPassword(password, for: share.name)
            lanShares[id]?.hasPassword = password != nil
        }
        return true
    }

    /// Puts a server on the network: any of a project's servers, each with its own switch
    /// and its own name there. With `password` that becomes the project's password first;
    /// `open` takes the project's password away; neither uses the one it has. Returns what
    /// is wrong, or nil.
    ///
    /// `lasting` is how long it stays on: one of Lasting's choices, or nil for what it has
    /// (a share that is only moving to a new name keeps its deadline) or was chosen last time.
    func shareOnNetwork(_ row: PortRow, password: String? = nil, open: Bool = false, lasting: Int? = nil) -> String? {
        let project = Names.key(row)
        guard lasting == nil || Lasting.pick(lasting, kind: .network) != nil else { return "On the network for 30 minutes, an hour, or until you turn it off." }
        guard let base = names.base[project], let own = names.byRow[row.id], let target = names.targets[own] else {
            return "\(row.title) has no name, so it can't go on the network."
        }
        // The name it has without having been renamed is checked like a typed one (wpad, this Mac's own).
        let plain = savedLanNames[nameKey(row)] ?? own, name = plain + DebugCLI.lanSuffix
        if let problem = Lan.nameProblem(plain, others: [], machine: lanName) { return problem }
        guard let network = LAN.current() else { return "This Mac isn't on a network right now." }
        checkNetwork()
        if lanShares.contains(where: { $0.key != row.id && $0.value.name == name }) { return "\(name)\(Lan.suffix) is already another server's name." }
        if open {
            guard keep(nil, for: project) else { return "The password file couldn't be written, so nothing was shared." }
        } else if let password {
            if let problem = Lan.passwordProblem(password, names: [base, own, name]) { return problem }
            guard keep(password, for: project) else { return "The password couldn't be saved, so nothing was shared." }
        }
        // Read back, not assumed: a password that can't be read is not "no password".
        let gate = Self.gate(Passwords.read(project), open: open, name: name)
        if let problem = gate.problem { return problem }
        let stored = gate.password
        // It is shared for this very process on this port, so that has to be the only thing there
        // (with another program on the same port a request could land on that one), and there right now.
        if let other = Self.otherListener(on: row.port, than: row.pid, in: ports) {
            return "\(other.processName) is listening on port \(row.port) too, so \(name)\(Lan.suffix) can't go on the network."
        }
        let server = OnNetwork.Server(pid: row.pid, identity: LibProc.identity(row.pid), target: target)
        guard server.isStillThere else { return "\(row.title) on port \(row.port) isn't running any more." }
        connectNetworkEvents()
        let answering = DebugCLI.lanAddress.map { LAN.Network(interface: "lo0", address: $0, router: nil) } ?? network
        let wanted = DebugCLI.isDebugRun ? DebugCLI.lanPort : 80
        // The new name first, then the old one off: the listener stays open through a rename, with no port to win back.
        let old = lanShares[row.id]
        let begun = OnNetwork.shared.begin(name: name, project: project, server: server, password: stored, on: answering, port: wanted)
        if let old, old.name != name || begun.port == nil { OnNetwork.shared.stop(old.name) }
        if !begun.doorBack {
            // The door stepped aside for the listener and couldn't be loaded again. The usual check takes it from here.
            notify("\(AppInfo.name) couldn't put its door on port \(wanted) back. Until it is, a name needs the port: \(base)\(Names.suffix):\(proxyPort).")
            doorIsOurs = false
            doorChecked = nil
        }
        guard let port = begun.port else {
            lanShares[row.id] = nil
            // Nothing is shared on another port instead. Another program on this one is named when harbor can
            // see it; and when it is harbor's own door, in front of a copy that may not move it, that is said.
            let holder = ports.first { $0.port == wanted && !Names.isHarbor($0.path) }?.processName
            let ownDoor = OnNetwork.shared.aside == nil && OnNetwork.hearsEveryInterface(wanted)
                && LaunchAgent.launchctl(["print", "\(LaunchAgent.domain)/\(Door.label)"])
            return Self.portProblem(wanted, begun.opening, holder: holder, ownDoor: ownDoor)
        }
        lanNetwork = network
        lanIPv6Taken = !OnNetwork.shared.holdsIPv6
        // Its deadline: the one just chosen; else the one it had (a rename doesn't buy time); else the usual choice.
        let chosen = lasting != nil || old == nil ? Lasting.pick(lasting, kind: .network) ?? 0 : nil
        let until = Lasting.until(chosen: chosen, moving: old.map(\.until), now: Date())
        if let chosen { Lasting.remember(.network, chosen) }
        lanShares[row.id] = LanShare(name: name, project: project, port: port, hasPassword: stored != nil, pid: row.pid, serverPort: row.port, started: row.started,
                                     container: row.container?.id, until: until)
        _ = LAN.firewallOn  // read it now, so the panel can say what macOS may ask
        return nil
    }

    /// Takes a server off the network (by its row). `because` is said in a notice when harbor did it by itself.
    func stopSharing(_ id: String, because reason: String? = nil) {
        guard let share = lanShares.removeValue(forKey: id) else { return }
        OnNetwork.shared.stop(share.name)
        if let reason { notify(reason) }
    }

    func stopAllSharing(because reason: String? = nil) {
        guard !lanShares.isEmpty else { return }
        lanShares = [:]
        OnNetwork.shared.stopAll()
        if let reason { notify(reason) }
    }

    /// A server's name on the network; empty goes back to its `.localhost` name. If it is
    /// on the network it moves to the new name at once (visitors sign in again).
    func renameOnNetwork(_ row: PortRow, to typed: String) -> String? {
        let key = nameKey(row), project = Names.key(row)
        guard names.byRow[row.id] != nil else { return "\(row.title) has no name to change." }
        var name = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(Lan.suffix) { name.removeLast(Lan.suffix.count) }
        if !name.isEmpty {
            // Names other servers have there: saved ones, and what the running ones would use.
            var others = Set(savedLanNames.filter { $0.key != key }.values)
            others.formUnion(ports.filter { $0.id != row.id && savedLanNames[nameKey($0)] == nil }.compactMap { names.byRow[$0.id] })
            if let problem = Lan.nameProblem(name, others: others, machine: lanName) { return problem }
        }
        savedLanNames[key] = name.isEmpty ? nil : name
        DebugCLI.defaults.set(savedLanNames, forKey: "lanNames")
        guard let share = lanShares[row.id] else { return nil }
        // It moves to the new name with the gate it has. With a password that can't be read
        // any more it comes off the network instead: never on under the new name without one.
        if share.hasPassword, let problem = Self.gate(Passwords.read(project), open: false, name: share.name).problem {
            stopSharing(row.id, because: problem)
            return problem
        }
        return shareOnNetwork(row, open: !share.hasPassword)
    }

    /// A new password for a row's project (nil: none), for all of its servers on the
    /// network. Everyone who was signed in signs in again.
    func setNetworkPassword(_ row: PortRow, _ password: String?) -> String? {
        let project = Names.key(row)
        if let password, let problem = Lan.passwordProblem(password, names: [names.base[project], names.byRow[row.id], networkName(row)].compactMap { $0 }) { return problem }
        return keep(password, for: project) ? nil : "The password couldn't be saved."
    }

    // MARK: The main server

    /// The server each project's owner chose as its main one, by project folder: a port.
    @ObservationIgnored private var savedMains = (DebugCLI.defaults.dictionary(forKey: "mainPorts") as? [String: Int]) ?? [:]

    /// Makes this server the one its project's plain name opens (`storefront.localhost`, and
    /// `storefront.local` the next time it goes on the network). The server that had the name
    /// goes by its port from here on (`storefront-3000`). A page open at the plain name
    /// reaches the new main with its next request; what it has open stays where it is.
    /// The choice is kept while that server isn't running (then the usual rule decides).
    ///
    /// What the project has on the network comes off it, with that said: a name there is
    /// for one server, and must never start opening another one by itself.
    func makeMain(_ row: PortRow) -> String? {
        let project = Names.key(row)
        guard let base = names.base[project], names.byRow[row.id] != nil else { return "\(row.title) has no name, so it can't be a project's main server." }
        guard !isMain(row) else { return nil }
        savedMains[project] = Int(row.port)
        DebugCLI.defaults.set(savedMains, forKey: "mainPorts")
        for (id, share) in lanShares where share.project == project {
            stopSharing(id, because: "The main server of \(base) changed, so \(share.name)\(Lan.suffix) is off the network. Turn it on again.")
        }
        names = Names.assign(ports, saved: savedNames, previous: names, mains: savedMains)
        return nil
    }

    /// Another network than the one the projects were shared on: all of them come off it.
    /// Asked on every scan, and at once when the system reports a change (OnNetwork.watch).
    func checkNetwork(now: LAN.Network? = LAN.current()) {
        guard !lanShares.isEmpty, let now else { return }
        switch Lan.change(from: lanNetwork, to: now) {
        case .same:
            // The router's hardware address, once macOS has it: what a later network is told apart by.
            if lanNetwork?.routerHardware == nil, now.routerHardware != nil { lanNetwork = now }
        case .moved:
            lanNetwork = now
            for key in lanShares.keys { lanShares[key]?.announced = nil; lanShares[key]?.since = Date() }
            if DebugCLI.lanAddress == nil { OnNetwork.shared.move(to: now) }
        case .left:
            stopAllSharing(because: "This Mac joined a different network, so nothing is shared on it any more.")
        }
    }

    @ObservationIgnored private var networkEventsConnected = false
    private func connectNetworkEvents() {
        guard !networkEventsConnected else { return }
        networkEventsConnected = true
        // Port 80 is the door's too: the door steps aside while the listener is bound. Only the
        // copy that manages the agents does that (or a debug run, to a throwaway door of its own).
        if let door = DebugCLI.lanDoor ?? (LaunchAgent.mayManage ? (label: Door.label, plist: Door.plistURL) : nil) {
            OnNetwork.shared.aside = { bind, answers in Door.aside(label: door.label, plist: door.plist, bind: bind, answers: answers) }
        }
        OnNetwork.shared.renamed = { from, to in
            MainActor.assumeIsolated {
                let m = Monitor.shared
                guard let key = m.lanShares.first(where: { $0.value.name == from })?.key else { return }
                m.lanShares[key]?.name = to
                m.lanShares[key]?.announced = nil
                m.notify("Another device on this network is already \(from)\(Lan.suffix), so this one is \(to)\(Lan.suffix).")
            }
        }
        OnNetwork.shared.manyWrong = { name in
            MainActor.assumeIsolated {
                Monitor.shared.notify("Many wrong passwords for \(name)\(Lan.suffix). Someone may be guessing. Turn sharing off or change the password.")
            }
        }
        // A visitor asked for it and its server wasn't there any more: off at once, not at the next scan.
        OnNetwork.shared.gone = { name in
            MainActor.assumeIsolated {
                let m = Monitor.shared
                guard let key = m.lanShares.first(where: { $0.value.name == name })?.key else { return }
                m.stopSharing(key, because: "\(name)\(Lan.suffix) stopped, so it is off the network.")
            }
        }
        OnNetwork.shared.answered = { name, announced in
            MainActor.assumeIsolated {
                let m = Monitor.shared
                guard let key = m.lanShares.first(where: { $0.value.name == name })?.key else { return }
                m.lanShares[key]?.announced = announced
            }
        }
    }

    // MARK: Names (<project>.localhost)

    /// Who goes by which name right now; worked out again after every scan.
    private(set) var names = Names.Table()
    /// Renames, saved by project folder.
    @ObservationIgnored private var savedNames = (DebugCLI.defaults.dictionary(forKey: "names") as? [String: String]) ?? [:]
    /// The proxy's port once it listens. 0 before that, and names are then not shown.
    var proxyPort: UInt16 = 0
    /// The port-80 door is harbor's, so a name works without a port.
    var doorIsOurs = false

    /// "storefront.localhost" for a row that has a name; with the proxy's port
    /// while the door isn't harbor's, so the address works either way.
    func nameHost(_ row: PortRow) -> String? {
        guard proxyPort != 0, let name = names.byRow[row.id] else { return nil }
        return name + Names.suffix + (doorIsOurs ? "" : ":\(proxyPort)")
    }

    /// What open and copy use: the name when the row has one, else localhost:<port>.
    func address(_ row: PortRow) -> URL {
        nameHost(row).flatMap { URL(string: "http://\($0)/") } ?? row.url
    }

    /// Renames a row's project (its other ports follow); an empty name goes back
    /// to the automatic one. Returns what is wrong with the name, or nil.
    func rename(_ row: PortRow, to typed: String) -> String? {
        let key = Names.key(row)
        guard names.base[key] != nil else { return "\(row.title) doesn't have a name to change." }
        var name = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(Names.suffix) { name.removeLast(Names.suffix.count) }
        if !name.isEmpty, let problem = Names.problem(with: name, for: key, in: names, saved: savedNames) { return problem }
        savedNames[key] = name.isEmpty ? nil : name
        DebugCLI.defaults.set(savedNames, forKey: "names")
        // Everyone else keeps the name they have; this project and its ports pick again.
        var others = names
        others.base[key] = nil
        for r in ports where Names.key(r) == key { others.byRow[r.id] = nil }
        names = Names.assign(ports, saved: savedNames, previous: others, mains: savedMains)
        return nil
    }

    /// Where the proxy sends a Host right now. A hit may rest on a scan up to 5 s
    /// old; a miss scans again first, since the server may only just have started.
    func route(host: String, _ done: @escaping (Names.Route) -> Void) {
        // Not a name at all: answered without a scan.
        if Names.route(host: host, in: Names.Table()) == .refuse { return done(.refuse) }
        fresh(maxAge: 5) { [self] in
            let found = Names.route(host: host, in: names)
            guard case .unknown = found, let t = lastFullScan, Date().timeIntervalSince(t) > 1 else { return done(found) }
            fresh(maxAge: 1) { done(Names.route(host: host, in: self.names)) }
        }
    }

    // MARK: Localhost page

    /// How long the page counts as open after a poll: a little over two of its intervals.
    var webWindow: Double { refreshInterval == 0 ? 60 : refreshInterval * 2 + 5 }

    /// True while the page has polled recently.
    var webActive: Bool { webLastSeen.map { Date().timeIntervalSince($0) < webWindow } ?? false }

    /// Called on every page request. When the page stops asking (tab closed or
    /// hidden), a one-shot timer drops the CPU samples; nothing keeps running.
    func webTouch() {
        webLastSeen = Date()
        checkDoor()
        webIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.webActive, !self.isFastMode else { return }
                DebugCLI.log("page idle: dropping caches")
                self.queue.async { [scanner = self.scanner] in scanner.dropCaches() }
            }
        }
        webIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + webWindow, execute: work)
    }

    /// Runs `done` with data no older than `maxAge` seconds, scanning if needed.
    func fresh(maxAge: Double, _ done: @escaping () -> Void) {
        if let t = lastFullScan, Date().timeIntervalSince(t) < maxAge, !scanInFlight {
            done()
            return
        }
        pendingFresh.append(done)
        requestFullScan()
    }

    func notify(_ text: String) {
        noticeCounter += 1
        notices.append(Notice(id: noticeCounter, text: text, at: Date()))
        notices.removeAll { Date().timeIntervalSince($0.at) > 300 }
        if notices.count > 5 { notices.removeFirst(notices.count - 5) }
        flash(text)
    }

    func dismissNotice(_ id: Int) {
        notices.removeAll { $0.id == id }
    }

    private func setMemory(_ m: MemorySnapshot) {
        if memory != m { memory = m }
        updateIcon()
    }

    private func setZombies(_ z: ZombieReport) {
        if zombies != z { zombies = z }
        updateIcon()
    }

    private func updateIcon() {
        let s: IconState
        if zombies.alarm { s = .zombies }
        else if memory.pressure == .critical { s = .bad }
        else if memory.pressure == .warning || memory.swapIsHeavy { s = .warn }
        else { s = .good }
        if s != iconState { iconState = s }
    }

    // MARK: UI helpers

    func flash(_ message: String) {
        toastToken += 1
        let token = toastToken
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.toastToken == token else { return }
                self.toast = nil
            }
        }
    }

    func setBusy(_ pid: pid_t, _ on: Bool) {
        if on { busy.insert(pid) } else { busy.remove(pid) }
    }

    // MARK: Derived

    /// In the visible range, not a macOS service (unless shown), and a real
    /// server when "only servers" is on.
    func isVisible(_ r: PortRow) -> Bool {
        let p = Int(r.port)
        if p < minPort || p > maxPort { return false }
        if (r.isSystem || r.isSelf) && !showSystemPorts { return false }
        if onlyServers && ![.dev, .database, .runtime].contains(r.category) { return false }
        if !blocklist.isEmpty, blocklist.contains(r.processName.lowercased()) { return false }
        if !showSystemPorts && Tunnels.shared.isTunnelPid(r.pid) { return false }
        return true
    }

    var visiblePorts: [PortRow] { ports.filter(isVisible) }

    var hiddenPortCount: Int { ports.count - visiblePorts.count }

    /// Apps worth suggesting the user quit.
    var quittableApps: [AppGroup] { apps.filter(\.canQuit) }
}

struct WeakWindow {
    weak var window: NSWindow?
}

extension Pressure: Comparable {
    static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
}
