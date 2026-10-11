import AppKit
import Foundation
import ServiceManagement

/// JSON for the page, built from the same in-process collectors as the menu.
/// Actions only touch pids the page was actually shown.
@MainActor
enum WebAPI {
    private static var shown = Set<pid_t>()
    private static var shownBefore = Set<pid_t>()
    private static var mayForce = Set<pid_t>()
    private static var mayAdmin = Set<pid_t>()
    private static var shownPorts = Set<UInt16>()

    // MARK: State

    static func state(_ done: @escaping (Data) -> Void) {
        let m = Monitor.shared
        m.webTouch()
        m.fresh(maxAge: 2.0) {
            let object = build()
            done((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }
    }

    private static func n(_ v: Any?) -> Any { v ?? NSNull() }

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
        let lanIP = LAN.ipv4()
        let bonjour = LAN.bonjourName()
        var portsShown = Set<UInt16>()
        let ports: [[String: Any]] = m.ports.map { r in
            pids.insert(r.pid)
            pids.formUnion(r.workerPids)
            portsShown.insert(r.port)
            var tunnel: Any = NSNull()
            if let t = tunnels[r.port] {
                switch t.phase {
                case .starting: tunnel = ["state": "starting", "provider": t.provider]
                case .ready(let url): tunnel = ["state": "ready", "provider": t.provider, "url": url]
                case .failed(let msg): tunnel = ["state": "failed", "provider": t.provider, "message": msg]
                }
            }
            return [
                "tunnel": tunnel,
                "lan": n(r.lanURL(ip: lanIP)),
                "lanBonjour": n(r.bonjourURL(bonjour)),
                "lanReachable": r.lanReachable,
                "loopbackOnly": r.scope == .loopback,
                "id": r.id,
                "port": Int(r.port),
                "pid": Int(r.pid),
                "name": r.processName,
                "title": r.title,
                "app": n(r.appName),
                "framework": n(r.framework),
                "category": r.category.rawValue,
                "color": r.colorHex,
                "categoryTitle": r.category.title,
                "project": n(r.projectFolder.map(Fmt.lastComponent)),
                "projectPath": n(r.projectFolder.map(Fmt.path)),
                "isProject": r.projectRoot != nil,
                "folder": n(r.folder.map(Fmt.path)),
                "command": n(r.command),
                "address": r.addressLabel,
                "exposed": r.scope == .all || r.scope == .specific,
                "url": r.url.absoluteString,
                "uptime": n(r.started.map { max(0, now.timeIntervalSince($0)) }),
                "memory": n(r.footprint.map { Double($0) }),
                "workers": r.workers,
                "hidden": !m.isVisible(r),
                "system": r.isSystem || r.isSelf,
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
        shownPorts = portsShown
        let hint = Tunnels.hint
        let tool = Tunnels.tool

        return [
            "scannedAgo": m.lastFullScan.map { now.timeIntervalSince($0) } ?? 0,
            "scanMs": m.lastScanDuration * 1000,
            "ports": ports,
            "notices": m.notices.map { ["id": $0.id, "text": $0.text] },
            "share": ["available": tool != nil, "provider": n(tool?.name), "hint": hint.text, "command": hint.command],
            "loginItem": loginItemOn,
            "network": ["ip": n(lanIP), "firewall": LAN.firewallOn],
            "settings": [
                "minPort": m.minPort, "maxPort": m.maxPort,
                "showSystem": m.showSystemPorts, "onlyServers": m.onlyServers, "grouping": m.grouping.rawValue,
                "interval": m.refreshInterval,
                "showInDock": m.showInDock,
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
    static func qr(port: Int, lan: Bool, _ done: @escaping (Int, [String: Any]) -> Void) {
        guard let p = UInt16(exactly: port), shownPorts.contains(p) else {
            return done(404, ["error": "That port isn't on the page any more."])
        }
        let url: String?
        if lan {
            url = Monitor.shared.ports.first { $0.port == p && $0.lanReachable }?.lanURL(ip: LAN.ipv4())
        } else if case .ready(let u)? = Tunnels.shared.active[p]?.phase {
            url = u
        } else {
            url = nil
        }
        guard let url, let rows = Tunnels.shared.qrRows(url) else {
            return done(404, ["error": lan ? "No network address for that port." : "That port isn't shared."])
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
            if let v = obj["showInDock"] as? Bool { m.showInDock = v }
            if let g = obj["grouping"] as? String, let v = Monitor.Grouping(rawValue: g) { m.grouping = v }
            return done(200, ["result": "ok"])
        case "unshare":
            guard let port = obj["port"] as? Int, let p = UInt16(exactly: port), Tunnels.shared.active[p] != nil else {
                return done(400, ["error": "That port isn't shared."])
            }
            Tunnels.shared.stop(p)
            return done(200, ["result": "ok", "message": "Stopped sharing :\(port)."])
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
            if let problem = Tunnels.shared.start(shareRow) {
                return done(200, ["result": "unavailable", "message": problem])
            }
            return done(200, ["result": "starting", "message": "Opening a public link for :\(port)…"])
        case "copy":
            guard let row else { return done(400, ["error": "Not a port."]) }
            Engine.copyURL(row)
            return done(200, ["result": "ok", "message": "Copied \(row.url.absoluteString)"])
        case "stop", "quit", "force", "admin":
            break
        default:
            return done(400, ["error": "Unknown action."])
        }

        if op == "force" && !mayForce.contains(pid) { return done(409, ["error": "Stop it first."]) }
        if op == "admin" && !mayAdmin.contains(pid) { return done(409, ["error": "Stop it first."]) }

        Task { @MainActor in
            let report: ActionReport
            switch op {
            case "stop":
                report = await Engine.stop(pid: pid, workers: workers, name: name, path: path, label: label)
            case "quit":
                report = await Engine.quit(pid: pid, bundlePath: group?.bundlePath ?? path.flatMap(LibProc.appBundle(forExecutable:)),
                                           name: name, path: path)
            case "force":
                report = await Engine.force(pid: pid, workers: workers, name: name, path: path, label: label)
            default:
                report = await Engine.admin(pid: pid, name: name, path: path)
            }
            mayForce.remove(pid)
            mayAdmin.remove(pid)
            if report.result == .stillRunning { mayForce.insert(pid) }
            if report.result == .notPermitted { mayAdmin.insert(pid) }
            done(200, ["result": report.result.rawValue, "message": report.message])
        }
    }
}
