import AppKit
import Foundation
import OSLog
import ServiceManagement

/// JSON for the page, built from the same in-process collectors as the menu.
/// Actions only touch pids the page was actually shown.
@MainActor
enum WebAPI {
    private static var shown = Set<pid_t>()
    private static var shownBefore = Set<pid_t>()
    /// Follow-up kills are allowed for 60 s after the first attempt, keyed by pid.
    private static var mayForce: [pid_t: Date] = [:]
    private static var mayAdmin: [pid_t: Date] = [:]
    /// Identity of each shown pid, to refuse a kill if the pid was reused.
    private static var shownStart: [pid_t: String] = [:]
    private static var shownPorts = Set<UInt16>()

    private static let log = Logger(subsystem: "local.harbor", category: "action")
    private static func fresh(_ at: Date?) -> Bool { at.map { Date().timeIntervalSince($0) < 60 } ?? false }

    /// One line per destructive action. Process name and port are readable;
    /// the pid and anything else stay private.
    private static func logAction(_ op: String, pid: Int, name: String, port: Int) {
        log.notice("op=\(op, privacy: .public) pid=\(pid) name=\(name, privacy: .public) port=\(port, privacy: .public)")
    }

    // MARK: State

    /// `see`: the rows the page has on screen. Those, and only those, are asked what they serve.
    static func state(see: [String] = [], _ done: @escaping (Data) -> Void) {
        let m = Monitor.shared
        m.webTouch()
        Updates.shared.check()  // at most once a day
        m.fresh(maxAge: 2.0) {
            m.look(at: see)
            let object = build()
            done((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }
    }

    private static func n(_ v: Any?) -> Any { v ?? NSNull() }

    /// A project's state on the network, for its main row: the name it has there, whether it
    /// is on, its link, and whether it has a password. Never the password itself.
    private static func lan(_ r: PortRow) -> [String: Any]? {
        let m = Monitor.shared, project = Names.key(r)
        guard m.isNetworkRow(r), let name = m.networkName(r) else { return nil }
        let share = m.lanShares[r.id]
        return ["name": name, "on": share != nil, "link": n(m.networkLink(r)),
                "password": share?.hasPassword ?? m.hasNetworkPassword(project),
                "trouble": n(share?.isUnannounced == true ? Lan.notAnnounced(name) : nil),
                // Its project: is this the server the plain name opens, has the project other servers, how
                // many of those are on the network too, and how many devices are signed in to it.
                "main": m.isMain(r), "several": m.hasSiblings(r),
                "note": n(share?.hasPassword == true
                    ? Lan.passwordNote(project: m.names.base[project] ?? r.title, several: m.hasSiblings(r), devices: m.devices(r)) : nil),
                "help": n(share != nil && m.lanShares.contains { $0.key != r.id && $0.value.project == project } ? Lan.callByName : nil),
                // What the page asks before the project goes without a password.
                "anyone": m.anyoneCanOpen(r),
                // The time it has left on the network, when it has a deadline.
                "left": n(Lasting.left(share?.until, now: Date()))]
    }

    /// SMAppService.status is a blocking XPC call to the system: read it at most
    /// once a minute, and again right after either surface toggles it.
    static var loginItemCache: (on: Bool, at: Date)?
    private static var loginItemOn: Bool {
        if let c = loginItemCache, Date().timeIntervalSince(c.at) < 60 { return c.on }
        let on = SMAppService.mainApp.status == .enabled
        loginItemCache = (on, Date())
        return on
    }

    private static func build() -> [String: Any] {
        let m = Monitor.shared
        let now = Date()
        var pids = Set<pid_t>()

        let tunnels = Tunnels.shared.active
        let lanIP = m.lanIP
        let bonjour = m.lanName
        var portsShown = Set<UInt16>()
        let ports: [[String: Any]] = m.ports.map { r in
            pids.insert(r.pid)
            pids.formUnion(r.workerPids)
            portsShown.insert(r.port)
            var tunnel: Any = NSNull()
            if let t = tunnels[r.port] {
                switch t.phase {
                case .starting: tunnel = ["state": "starting", "provider": t.provider]
                case .ready(let url): tunnel = ["state": "ready", "provider": t.provider, "url": url, "left": n(Lasting.left(t.until, now: now))]
                case .failed(let msg): tunnel = ["state": "failed", "provider": t.provider, "message": msg]
                }
            }
            return [
                "tunnel": tunnel,
                "qrs": m.codes(r).map { ["kind": $0.code.rawValue, "label": $0.label, "link": $0.link] },
                "lan": n(r.lanURL(ip: lanIP)),
                "lanBonjour": n(r.bonjourURL(bonjour)),
                "lanReachable": r.lanReachable,
                "net": n(r.networkAddress(ip: lanIP)),
                "loopbackOnly": r.scope == .loopback,
                "id": r.id,
                "port": Int(r.port),
                "pid": Int(r.pid),
                "name": r.label,
                "display": r.display(served: m.served[r.id]?.line),
                "title": r.title,
                // A container: what it is, the card it belongs on, and why it has no kill.
                "container": n(r.container.map { ["name": $0.name, "image": $0.image, "project": n($0.project), "service": n($0.service)] as [String: Any] }),
                "group": n(r.container != nil || r.repo != nil ? r.groupKey : nil),
                "groupTitle": n(r.container?.group ?? r.repo.map(Fmt.lastComponent)),
                "nokill": n(Docker.owns(path: r.path) ? Docker.noKill(r.container) : nil),
                // What it answered on "/" when it was last looked at: plain text, or nothing yet.
                "served": n(m.served[r.id]?.line),
                // The bell is set on this one; and harbor started it itself, so its output is in a log.
                "watched": m.isWatched(r),
                "log": m.log(for: r) != nil,
                "app": n(r.appName),
                "framework": n(r.framework),
                "category": r.category.rawValue,
                "color": r.colorHex,
                "categoryTitle": r.category.title,
                "project": n(r.projectFolder.map(Fmt.lastComponent)),
                "projectPath": n((r.repo ?? r.projectFolder).map(Fmt.path)),
                "isProject": r.projectRoot != nil,
                "folder": n(r.folder.map(Fmt.path)),
                "command": n(r.command),
                "address": r.addressLabel,
                "exposed": r.scope == .all || r.scope == .specific,
                "url": r.url.absoluteString,
                // The row's name: its address, what open and copy use, and the project's part of it.
                "host": n(m.nameHost(r)),
                "hostUrl": n(m.nameHost(r).map { "http://\($0)/" }),
                "hostName": n(m.names.base[Names.key(r)]),
                // On network: only on the row a project is shared through (its main server).
                "local": n(lan(r)),
                "uptime": n(r.started.map { max(0, now.timeIntervalSince($0)) }),
                "memory": n(r.footprint.map { Double($0) }),
                "workers": r.workers,
                "hidden": !m.isVisible(r),
                "system": r.isSystem || r.isSelf,
                "macos": r.isSystem,
                "hint": n(r.hint),
                "busy": m.busy.contains(r.pid),
            ]
        }

        // Extras, kept small: the biggest apps and memory at a glance.
        let apps: [[String: Any]] = m.apps.prefix(8).map { g in
            pids.insert(g.mainPid)
            return [
                "id": g.id, "name": g.name, "pid": Int(g.mainPid), "count": g.pids.count,
                "memory": Double(g.footprint), "cpu": n(g.cpu), "canQuit": g.canQuit,
                // Said before it is quit: with Docker Desktop, every container goes too.
                "quitNote": n(Docker.owns(path: g.mainPath) ? Docker.quitNote : nil),
                "folder": n(g.cwd.flatMap { $0 == "/" ? nil : Fmt.path($0) }),
            ]
        }
        let z = m.zombies
        let parents: [[String: Any]] = z.parents.prefix(5).map { p in
            pids.insert(p.pid)
            return ["pid": Int(p.pid), "name": p.name, "count": p.count, "canQuit": p.canQuit]
        }
        let mem = m.memory
        let v = m.verdict

        shownBefore = shown
        shown = pids
        shownStart = Dictionary(uniqueKeysWithValues: pids.map { ($0, LibProc.identity($0)) })
        shownPorts = portsShown
        let hint = Tunnels.hint
        let tool = Tunnels.tool
        let up = Updates.shared

        return [
            "scannedAgo": m.lastFullScan.map { now.timeIntervalSince($0) } ?? 0,
            "scanMs": m.lastScanDuration * 1000,
            "badgeCount": m.badgeCount,  // equals the visible rows (0 with the badge hidden)
            "ports": ports,
            "notices": m.notices.map { ["id": $0.id, "text": $0.text] },
            // A looked-at row's answer is still on its way: the page asks again in a moment.
            "asking": m.isAsking,
            // Servers that stopped and can be started again: what they were called, where, and their command as
            // text. Never the environment they ran with, and nothing a request could be built from but the id.
            "stopped": m.stopped.map { s in
                ["id": s.id, "name": s.name, "port": Int(s.port), "folder": Fmt.path(Restart.visible(s.launch.folder)), "command": Restart.command(s.launch),
                 "question": Restart.question(s), "ago": max(0, now.timeIntervalSince(s.at)), "note": n(s.note), "log": s.log != nil] as [String: Any]
            },
            "share": ["available": tool != nil, "provider": n(tool?.name), "hint": hint.text, "command": hint.command],
            // How long a share lasts: the choices, and the one made last time for each kind.
            "lasts": ["public": Lasting.remembered(.link), "network": Lasting.remembered(.network),
                      "choices": Lasting.choices.map { ["seconds": $0, "title": Lasting.title($0)] as [String: Any] }],
            "loginItem": loginItemOn,
            "update": [
                "current": up.current, "latest": n(up.latest), "newer": up.newer, "url": up.url.absoluteString,
                "checking": up.checking, "failed": up.failed,
                // "Update now": whether it is offered here, whether one is under way, why the last one stopped, and what is asked first.
                "canUpdate": up.canUpdateNow, "updating": up.updating, "problem": n(up.updateProblem),
                "question": n(up.latest.map { Updates.updateQuestion(version: $0, sharing: !m.lanShares.isEmpty || !tunnels.isEmpty) }),
            ],
            "network": ["ip": n(lanIP), "name": n(bonjour), "firewall": LAN.firewallOn, "asks": Lan.systemAsks(firewall: LAN.firewallOn), "plain": Lan.plainHttp],
            "portNotes": m.portNotes,
            "settings": [
                "minPort": m.minPort, "maxPort": m.maxPort,
                "showSystem": m.showSystemPorts, "onlyServers": m.onlyServers,
                "showOtherApps": m.showOtherApps, "onlyReachable": m.onlyReachable, "grouping": m.grouping.rawValue,
                "interval": m.refreshInterval,
                "showInDock": m.showInDock,
                "appearance": m.pageAppearance.rawValue,  // the page's own; the menu has its own
            ],
            "memory": [
                "physical": Double(mem.physical), "used": Double(mem.used), "app": Double(mem.app),
                "wired": Double(mem.wired), "compressed": Double(mem.compressed), "cached": Double(mem.cached),
                "free": Double(mem.free), "swapUsed": Double(mem.swapUsed), "swapTotal": Double(mem.swapTotal),
                "pressure": mem.pressure.label.lowercased(), "swapHeavy": mem.swapIsHeavy,
            ],
            "verdict": ["level": ["good", "warn", "bad"][v.level.rawValue], "headline": v.headline, "detail": v.detail],
            "apps": apps,
            "zombies": [
                "count": z.zombieCount, "alarm": z.alarm, "parents": parents,
                "own": z.ownProcessCount, "perUser": z.maxProcPerUID,
            ],
        ]
    }

    /// The QR code of a shared port's public link, as rows of 0/1.
    /// QR codes only for ports the page was shown: the public link, or (lan)
    /// the address other devices on this network would open.
    static func qr(port: Int, lan: Bool, name: Bool = false, _ done: @escaping (Int, [String: Any]) -> Void) {
        guard let p = UInt16(exactly: port), shownPorts.contains(p) else {
            return done(404, ["error": "That port isn't on the page any more."])
        }
        let url: String?
        if name {
            url = Monitor.shared.ports.lazy.compactMap { $0.port == p ? Monitor.shared.networkLink($0) : nil }.first
        } else if lan {
            url = Monitor.shared.ports.first { $0.port == p && $0.lanReachable }?.lanURL(ip: Monitor.shared.lanIP)
        } else if case .ready(let u)? = Tunnels.shared.active[p]?.phase {
            url = u
        } else {
            url = nil
        }
        guard let url, let rows = Tunnels.shared.qrRows(url) else {
            return done(404, ["error": name ? "That project isn't on the network." : lan ? "No network address for that port." : "That port isn't shared."])
        }
        done(200, ["url": url, "rows": rows])
    }

    // MARK: Actions

    static func action(_ body: Data, _ done: @escaping (Int, [String: Any]) -> Void) {
        Monitor.shared.webTouch()
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let op = obj["op"] as? String else {
            return done(400, ["error": "Send {op, pid}."])
        }
        switch op {
        case "login-item":
            let on = (obj["enabled"] as? Bool) ?? false
            logAction("login-item", pid: 0, name: AppInfo.name, port: 0)
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                return done(200, ["result": "failed", "message": error.localizedDescription])
            }
            let status = SMAppService.mainApp.status
            loginItemCache = nil
            let msg = status == .requiresApproval
                ? "Approve \(AppInfo.name) in System Settings → General → Login Items."
                : (status == .enabled ? "\(AppInfo.name) will open at login." : "\(AppInfo.name) won't open at login.")
            return done(200, ["result": status == .enabled ? "on" : "off", "message": msg])
        case "settings":
            let m = Monitor.shared
            if let lo = obj["minPort"] as? Int, let hi = obj["maxPort"] as? Int { m.setRange(lo, hi) }
            if let v = obj["showSystem"] as? Bool { m.showSystemPorts = v }
            if let v = obj["onlyServers"] as? Bool { m.onlyServers = v }
            if let v = obj["showOtherApps"] as? Bool { m.showOtherApps = v }
            if let v = obj["onlyReachable"] as? Bool { m.onlyReachable = v }
            if let v = obj["showInDock"] as? Bool { m.showInDock = v }
            if let a = obj["appearance"] as? String, let v = Monitor.Appearance(rawValue: a) { m.pageAppearance = v }
            if let g = obj["grouping"] as? String, let v = Monitor.Grouping(rawValue: g) { m.grouping = v }
            return done(200, ["result": "ok"])
        case "unshare":
            guard let port = obj["port"] as? Int, let p = UInt16(exactly: port), Tunnels.shared.active[p] != nil else {
                return done(400, ["error": "That port isn't shared."])
            }
            logAction("unshare", pid: 0, name: "", port: port)
            Tunnels.shared.stop(p)
            return done(200, ["result": "ok", "message": "Stopped sharing :\(port)."])
        case "start-again":
            // The entry's id and nothing else: what is run is what harbor itself remembers of that server.
            guard let id = obj["id"] as? String else { return done(400, ["error": "Send the server's id."]) }
            let m = Monitor.shared
            let entry = m.stopped.first { $0.id == id }
            logAction("start-again", pid: 0, name: entry?.name ?? "", port: Int(entry?.port ?? 0))
            let result = m.startAgain(id)
            return done(result.started ? 200 : 400, result.started ? ["result": "ok", "message": result.message] : ["error": result.message])
        case "show-log":
            // The log of a server harbor started: by the stopped entry's id, or by the pid of one that is running.
            let m = Monitor.shared
            let log = (obj["id"] as? String).flatMap { id in m.stopped.first { $0.id == id }?.log }
                ?? (obj["pid"] as? Int).flatMap { pid in m.ports.first { Int($0.pid) == pid }.flatMap(m.log(for:)) }
            guard let log, !m.isMadeUp else { return done(400, ["error": "There is no log for that."]) }
            guard NSWorkspace.shared.open(log) else { return done(400, ["error": "The log isn't there any more."]) }
            return done(200, ["result": "ok", "message": "Opened \(Fmt.path(log.path))."])
        case "update-now":
            // Only ever from here, on the owner's click on the signed-in page. What is downloaded and from where is harbor's own business (see Updater).
            logAction("update-now", pid: 0, name: AppInfo.name, port: 0)
            // The answer is what was really done: "Updating…" only when an update is under way.
            if let why = Updates.shared.updateNow() { return done(400, ["error": why]) }
            return done(200, ["result": "ok", "message": "Updating…"])
        case "check-update":
            // The page polls quickly while "checking" is true.
            Updates.shared.check(force: true)
            return done(200, ["result": "ok"])
        case "dismiss-notice":
            if let id = obj["id"] as? Int { Monitor.shared.dismissNotice(id) }
            return done(200, ["result": "ok"])
        default:
            break
        }

        guard let raw = obj["pid"] as? Int, raw > 0, raw <= Int(Int32.max) else {
            return done(400, ["error": "Send {op, pid}."])
        }
        let pid = pid_t(raw)
        guard shown.contains(pid) || shownBefore.contains(pid) else {
            return done(403, ["error": "That process isn't on the page any more. Refresh and try again."])
        }
        let m = Monitor.shared
        let row = m.ports.first { $0.pid == pid }
        // One process can listen on several ports, and each of its servers has its own switch on the network: those actions name the port too.
        let lanRow = (obj["port"] as? Int).flatMap { port in m.ports.first { $0.pid == pid && Int($0.port) == port } } ?? row
        let group = m.apps.first { $0.mainPid == pid }
        let parent = m.zombies.parents.first { $0.pid == pid }
        let path = row?.path ?? group?.mainPath ?? parent?.path ?? LibProc.path(pid)
        let name = row?.processName ?? group?.name ?? parent?.name ?? LibProc.name(pid) ?? "pid \(pid)"
        let label = row.map { "\($0.processName) on :\($0.port)" } ?? name
        let workers = row?.workerPids ?? []

        switch op {
        case "reveal":
            guard let folder = row?.folder else { return done(400, ["error": "No folder for that process."]) }
            Engine.reveal(folder)
            return done(200, ["result": "ok", "message": "Shown in Finder."])
        case "share":
            // Only a port the page showed, served by the pid the page showed.
            guard let port = obj["port"] as? Int, let p = UInt16(exactly: port), shownPorts.contains(p),
                  let shareRow = m.ports.first(where: { $0.port == p && $0.pid == pid }) else {
                return done(400, ["error": "That port isn't on the page any more."])
            }
            if shareRow.isSystem || shareRow.isSelf { return done(400, ["error": "harbor doesn't share macOS services or itself."]) }
            if let asked = obj["for"], Lasting.pick(asked as? Int ?? -1, kind: .link) == nil { return done(400, ["error": "A public link lasts 30 minutes, an hour, or until you stop it."]) }
            logAction("share", pid: Int(pid), name: shareRow.processName, port: port)
            if let problem = Tunnels.shared.start(shareRow, for: obj["for"] as? Int) {
                return done(200, ["result": "unavailable", "message": problem])
            }
            return done(200, ["result": "starting", "message": "Opening a public link for :\(port)…"])
        case "copy":
            guard let row else { return done(400, ["error": "Not a port."]) }
            Engine.copyURL(row)
            return done(200, ["result": "ok", "message": "Copied \(m.address(row).absoluteString)"])
        case "rename":
            // The project is the shown row's own; only the name comes from the page, and it is checked here.
            guard let row else { return done(400, ["error": "Not a port."]) }
            if let problem = m.rename(row, to: (obj["name"] as? String) ?? "") { return done(400, ["error": problem]) }
            logAction("rename", pid: Int(pid), name: row.processName, port: Int(row.port))
            return done(200, ["result": "ok", "message": m.nameHost(row).map { "It's \($0) now." } ?? "Renamed."])
        case "lan-suggest":
            return done(200, ["result": "ok", "password": Lan.randomPassword()])
        case "lan-on":
            // On the network as <name>.local: with the password sent, with none (open), or with the one it has.
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            if let asked = obj["for"], Lasting.pick(asked as? Int ?? -1, kind: .network) == nil { return done(400, ["error": "On the network for 30 minutes, an hour, or until you turn it off."]) }
            if let problem = m.shareOnNetwork(row, password: obj["password"] as? String, open: (obj["open"] as? Bool) ?? false, lasting: obj["for"] as? Int) {
                return done(400, ["error": problem])
            }
            logAction("lan-on", pid: Int(pid), name: row.processName, port: Int(row.port))
            return done(200, ["result": "ok", "message": (m.networkLink(row) ?? "It") + " is on your network."])
        case "lan-off":
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            let name = m.networkName(row) ?? row.title
            m.stopSharing(row.id)
            logAction("lan-off", pid: Int(pid), name: row.processName, port: Int(row.port))
            return done(200, ["result": "ok", "message": "\(name)\(Lan.suffix) is off the network."])
        case "lan-rename":
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            if let problem = m.renameOnNetwork(row, to: (obj["name"] as? String) ?? "") { return done(400, ["error": problem]) }
            return done(200, ["result": "ok", "message": "On the network it is \(m.networkName(row) ?? "")\(Lan.suffix)."])
        case "main":
            // The server its project's plain name opens. What the project has on the network comes off it.
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            if let problem = m.makeMain(row) { return done(400, ["error": problem]) }
            logAction("main", pid: Int(pid), name: row.processName, port: Int(row.port))
            return done(200, ["result": "ok", "message": "\(m.names.base[Names.key(row)] ?? row.title)\(Names.suffix) opens port \(row.port) now."])
        case "watch":
            // The bell on one server: tell me when it stops.
            guard let row = lanRow, !row.isSystem, !row.isSelf else { return done(400, ["error": "Not a port."]) }
            let on = (obj["on"] as? Bool) ?? false
            m.setWatch(row, on)
            return done(200, ["result": "ok", "message": on ? "You'll be told when \(m.names.byRow[row.id] ?? row.title) stops." : "The bell is off."])
        case "more":
            // Half an hour more for a public link or a server on the network that has a deadline. Only ever asked for by its owner, here.
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            if (obj["kind"] as? String) == "public", Tunnels.shared.active[row.port]?.until != nil {
                Tunnels.shared.more(row.port)
            } else if (obj["kind"] as? String) == "network", m.lanShares[row.id]?.until != nil {
                m.moreTime(row)
            } else {
                return done(400, ["error": "That has no time limit to add to."])
            }
            return done(200, ["result": "ok", "message": "30 minutes more."])
        case "lan-password":
            // A new one typed, a new random one, or none: for the project, all its servers. Whoever was signed in signs in again.
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            let random = (obj["random"] as? Bool) == true, off = (obj["off"] as? Bool) == true
            let password = random ? Lan.randomPassword() : off ? nil : (obj["password"] as? String) ?? ""
            if let problem = m.setNetworkPassword(row, password) { return done(400, ["error": problem]) }
            logAction(off ? "lan-password-off" : "lan-password", pid: Int(pid), name: row.processName, port: Int(row.port))
            return done(200, ["result": "ok", "message": off ? "No password any more." : "New password set.", "password": n(random ? password : nil)])
        case "lan-show":
            // The owner reads it out to a friend: only ever to the signed-in page, on this Mac.
            guard let row = lanRow else { return done(400, ["error": "Not a port."]) }
            return done(200, ["result": "ok", "password": n(m.networkPassword(Names.key(row)))])
        case "stop", "quit", "force", "admin":
            break
        default:
            return done(400, ["error": "Unknown action."])
        }

        // Docker Desktop is quit on purpose from the list of apps, or not at all: never through a port row's pid.
        if op == "quit", let no = Docker.quitRefusal(path: path, isListedApp: group != nil, fromApps: (obj["from"] as? String) == "apps") {
            return done(200, ["result": ActionResult.system.rawValue, "message": no])
        }
        if op == "force" && !fresh(mayForce[pid]) { return done(409, ["error": "Stop it first."]) }
        if op == "admin" && !fresh(mayAdmin[pid]) { return done(409, ["error": "Stop it first."]) }

        let expect = shownStart[pid]
        let workerExpect = Dictionary(uniqueKeysWithValues: workers.compactMap { w in shownStart[w].map { (w, $0) } })
        logAction(op, pid: Int(pid), name: name, port: Int(row?.port ?? 0))

        Task { @MainActor in
            let report: ActionReport
            switch op {
            case "stop":
                report = await Engine.stop(pid: pid, workers: workers, name: name, path: path, label: label,
                                           expect: expect, workerExpect: workerExpect)
            case "quit":
                report = await Engine.quit(pid: pid, bundlePath: group?.bundlePath ?? path.flatMap(LibProc.appBundle(forExecutable:)),
                                           name: name, path: path, expect: expect)
            case "force":
                report = await Engine.force(pid: pid, workers: workers, name: name, path: path, label: label,
                                            expect: expect, workerExpect: workerExpect)
            default:
                report = await Engine.admin(pid: pid, name: name, path: path, expect: expect)
            }
            mayForce[pid] = nil
            mayAdmin[pid] = nil
            if report.result == .stillRunning { mayForce[pid] = Date() }
            if report.result == .notPermitted { mayAdmin[pid] = Date() }
            done(200, ["result": report.result.rawValue, "message": report.message])
        }
    }
}
