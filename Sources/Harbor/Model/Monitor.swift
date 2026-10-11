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

    private func updateBadgeTimer() {
        badgeTimer?.invalidate()
        badgeTimer = nil
        guard started, badgeMode != "hidden", refreshInterval > 0 else { return }
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // The open menu, or the page's polls, already scan and refresh the badge.
                guard let self, !self.isFastMode, !self.webActive else { return }
                self.requestFullScan()
            }
        }
        t.tolerance = refreshInterval / 5
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

    func requestFullScan() {
        guard !scanInFlight else { return }
        scanInFlight = true
        DebugCLI.log("full scan")
        let sampleCPU = isFastMode || !visible.isEmpty || webActive
        queue.async { [weak self, scanner] in
            let scan = scanner.fullScan(sampleCPU: sampleCPU)
            let m = SystemMemory.read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanInFlight = false
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
        let ip = LAN.ipv4(), name = LAN.bonjourName()
        if ip != lanIP { lanIP = ip }
        if name != lanName { lanName = name }
        refreshBadge()
        Tunnels.shared.prune(listening: Set(scan.ports.map(\.port)))
        if apps != scan.apps {
            // Load icons here, not while the list is laying out its rows.
            IconCache.shared.warm(scan.apps.prefix(60).compactMap(\.bundlePath))
            apps = scan.apps
        }
        if others != scan.others { others = scan.others }
        lastScanDuration = scan.duration
        lastFullScan = Date()
        setMemory(m)
        setZombies(scan.zombies)
        let waiting = pendingFresh
        pendingFresh = []
        waiting.forEach { $0() }
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
