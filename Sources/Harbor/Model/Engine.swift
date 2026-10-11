import AppKit
import Darwin
import Foundation

/// Signals and checks with no UI. Shared by the app, the page and the debug CLI.
enum ProcessControl {
    enum SignalResult: Equatable { case sent, notPermitted, gone, failed(Int32) }

    static func send(_ sig: Int32, to pid: pid_t) -> SignalResult {
        if kill(pid, sig) == 0 { return .sent }
        switch errno {
        case EPERM: return .notPermitted
        case ESRCH: return .gone
        default: return .failed(errno)
        }
    }

    /// Alive means present and not a zombie.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard let s = LibProc.shortInfo(pid) else { return false }
        return s.pbsi_status != UInt32(SZOMB)
    }

    static func waitForExit(_ pid: pid_t, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !isAlive(pid)
    }

    /// Live processes running the same executable, with their parent pid.
    static func siblings(path: String) -> [pid_t: pid_t] {
        var out: [pid_t: pid_t] = [:]
        for pid in LibProc.allPids() where pid > 0 {
            guard LibProc.path(pid) == path, let s = LibProc.shortInfo(pid),
                  s.pbsi_status != UInt32(SZOMB) else { continue }
            out[pid] = pid_t(s.pbsi_ppid)
        }
        return out
    }

    /// Did something bring the process back? A new process with the same
    /// executable whose parent is launchd (KeepAlive) or the old parent.
    static func findRestart(path: String, oldParent: pid_t, before: Set<pid_t>, within seconds: Double) async -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (pid, ppid) in siblings(path: path) where !before.contains(pid) {
                if ppid == 1 || ppid == oldParent { return pid }
            }
        }
        return nil
    }
}

enum ActionResult: String {
    case stopped
    case stillRunning = "still_running"
    case notPermitted = "not_permitted"
    case gone, failed, system, cancelled
}

struct ActionReport {
    let result: ActionResult
    let message: String
}

/// Stops and quits processes for the menu and the page. Neither confirmation
/// nor wording of the question lives here: callers must ask the user first.
@MainActor
enum Engine {
    private static func isProtected(_ pid: pid_t, _ path: String?) -> Bool {
        pid <= 1 || pid == getpid() || LibProc.isSystemPath(path)
    }

    /// SIGTERM, then wait up to 3 s. Forked workers that share the listening
    /// socket get SIGTERM once the parent is gone, so the port is really freed.
    static func stop(pid: pid_t, workers: [pid_t] = [], name: String, path: String?, label: String) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        let snapshot = restartSnapshot(pid: pid, path: path)
        switch ProcessControl.send(SIGTERM, to: pid) {
        case .notPermitted:
            return ActionReport(result: .notPermitted,
                                message: "\(name) runs as another user, so macOS needs an administrator password to stop it.")
        case .gone:
            Monitor.shared.requestFullScan()
            return ActionReport(result: .gone, message: "\(label) had already stopped.")
        case .failed(let e):
            return ActionReport(result: .failed, message: "Couldn't stop \(label): \(String(cString: strerror(e))).")
        case .sent:
            break
        }
        Monitor.shared.setBusy(pid, true)
        defer { Monitor.shared.setBusy(pid, false) }
        var gone = await ProcessControl.waitForExit(pid, timeout: 3)
        if gone {
            let left = workers.filter(ProcessControl.isAlive)
            for w in left { _ = ProcessControl.send(SIGTERM, to: w) }
            for w in left where !(await ProcessControl.waitForExit(w, timeout: 3)) { gone = false }
        }
        Monitor.shared.requestFullScan()
        if gone {
            watchRestart(name: name, snapshot: snapshot)
            return ActionReport(result: .stopped, message: "Stopped \(label).")
        }
        return ActionReport(result: .stillRunning,
                            message: "\(label) is still running after 3 seconds. Force stop ends it at once; anything unsaved is lost.")
    }

    /// SIGKILL (or Force Quit for a GUI app), for when stop didn't work.
    static func force(pid: pid_t, workers: [pid_t] = [], name: String, path: String?, label: String) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        let snapshot = restartSnapshot(pid: pid, path: path)
        for w in workers where ProcessControl.isAlive(w) { _ = ProcessControl.send(SIGKILL, to: w) }
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil {
            app.forceTerminate()
        } else if ProcessControl.send(SIGKILL, to: pid) == .notPermitted {
            return ActionReport(result: .notPermitted,
                                message: "\(name) runs as another user, so macOS needs an administrator password to stop it.")
        }
        let gone = await ProcessControl.waitForExit(pid, timeout: 3)
        Monitor.shared.requestFullScan()
        if gone {
            watchRestart(name: name, snapshot: snapshot)
            return ActionReport(result: .stopped, message: "Force-stopped \(label).")
        }
        return ActionReport(result: .failed, message: "\(label) still won't stop. Try Activity Monitor.")
    }

    /// Quit an app the normal way (it may ask to save). Non-GUI processes get stop().
    static func quit(pid: pid_t, bundlePath: String?, name: String, path: String?) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        guard let app = runningApp(pid: pid, bundlePath: bundlePath) else {
            return await stop(pid: pid, name: name, path: path, label: name)
        }
        let appPid = app.processIdentifier
        let snapshot = restartSnapshot(pid: appPid, path: path)
        _ = app.terminate()
        Monitor.shared.setBusy(pid, true)
        defer { Monitor.shared.setBusy(pid, false) }
        let gone = await ProcessControl.waitForExit(appPid, timeout: 6)
        Monitor.shared.requestFullScan()
        if gone {
            watchRestart(name: name, snapshot: snapshot)
            return ActionReport(result: .stopped, message: "Quit \(name).")
        }
        return ActionReport(result: .stillRunning,
                            message: "\(name) hasn't quit. It may be asking to save something; check its windows. Force quit closes it at once.")
    }

    /// Root-owned processes: macOS shows its own password dialog. harbor
    /// never sees the password.
    static func admin(pid: pid_t, name: String, path: String?) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        let snapshot = restartSnapshot(pid: pid, path: path)
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        // `pid` is an integer, so nothing can be injected into the script.
        NSAppleScript(source: "do shell script \"kill \(pid)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                return ActionReport(result: .cancelled, message: "Cancelled.")
            }
            return ActionReport(result: .failed, message: (error[NSAppleScript.errorMessage] as? String) ?? "macOS refused.")
        }
        let gone = await ProcessControl.waitForExit(pid, timeout: 3)
        Monitor.shared.requestFullScan()
        if gone {
            watchRestart(name: name, snapshot: snapshot)
            return ActionReport(result: .stopped, message: "Stopped \(name).")
        }
        return ActionReport(result: .failed, message: "\(name) is still running. It may need its own Quit command.")
    }

    // MARK: Helpers

    static func runningApp(pid: pid_t, bundlePath: String?) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil,
           app.activationPolicy != .prohibited {
            return app
        }
        guard let bundlePath else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == bundlePath && $0.activationPolicy != .prohibited
        }
    }

    private struct RestartSnapshot {
        let path: String
        let parent: pid_t
        let before: Set<pid_t>
    }

    private static func restartSnapshot(pid: pid_t, path: String?) -> RestartSnapshot? {
        guard let path else { return nil }
        let parent = LibProc.shortInfo(pid).map { pid_t($0.pbsi_ppid) } ?? 1
        return RestartSnapshot(path: path, parent: parent,
                               before: Set(ProcessControl.siblings(path: path).keys).union([pid]))
    }

    /// Watches ~12 s for the process coming back (launchd KeepAlive etc.).
    private static func watchRestart(name: String, snapshot: RestartSnapshot?) {
        guard let s = snapshot else { return }
        Task { @MainActor in
            if let newPid = await ProcessControl.findRestart(path: s.path, oldParent: s.parent, before: s.before, within: 12) {
                Monitor.shared.requestFullScan()
                Monitor.shared.notify("\(name) came back as process \(newPid). It restarts itself. Use the app's own Quit or uninstall it.")
            }
        }
    }

    // MARK: Small actions

    static func open(_ row: PortRow) {
        NSWorkspace.shared.open(row.url)
    }

    static func copyURL(_ row: PortRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.url.absoluteString, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
