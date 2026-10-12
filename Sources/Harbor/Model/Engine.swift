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

    /// Is `pid` still the process the page showed? `expected` is the identity
    /// captured then; nil means we have nothing to compare, so allow it.
    nonisolated static func identityMatches(_ pid: pid_t, _ expected: String?) -> Bool {
        guard let expected else { return true }
        return LibProc.identity(pid) == expected
    }

    private static func changed(_ name: String) -> ActionReport {
        ActionReport(result: .gone, message: "\(name) changed since the page last saw it. Refresh and try again.")
    }

    /// SIGTERM, then wait up to 3 s. Forked workers that share the listening
    /// socket get SIGTERM once the parent is gone, so the port is really freed.
    static func stop(pid: pid_t, workers: [pid_t] = [], name: String, path: String?, label: String,
                     expect: String? = nil, workerExpect: [pid_t: String] = [:]) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        guard identityMatches(pid, expect) else { return changed(label) }
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
            // Only workers that are still the same process the page saw.
            let left = workers.filter { ProcessControl.isAlive($0) && identityMatches($0, workerExpect[$0]) }
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
    static func force(pid: pid_t, workers: [pid_t] = [], name: String, path: String?, label: String,
                      expect: String? = nil, workerExpect: [pid_t: String] = [:]) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        guard identityMatches(pid, expect) else { return changed(label) }
        let snapshot = restartSnapshot(pid: pid, path: path)
        for w in workers where ProcessControl.isAlive(w) && identityMatches(w, workerExpect[w]) { _ = ProcessControl.send(SIGKILL, to: w) }
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
    static func quit(pid: pid_t, bundlePath: String?, name: String, path: String?, expect: String? = nil) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        guard identityMatches(pid, expect) else { return changed(name) }
        guard let app = runningApp(pid: pid, bundlePath: bundlePath) else {
            return await stop(pid: pid, name: name, path: path, label: name, expect: expect)
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
    static func admin(pid: pid_t, name: String, path: String?, expect: String? = nil) async -> ActionReport {
        if isProtected(pid, path) {
            return ActionReport(result: .system, message: "\(name) is part of macOS, so \(AppInfo.name) leaves it alone.")
        }
        guard identityMatches(pid, expect) else { return changed(name) }
        let snapshot = restartSnapshot(pid: pid, path: path)
        NSApp.activate(ignoringOtherApps: true)
        // Re-check right before the privileged kill: a pid freed since the page
        // was shown must not be killed as root.
        guard identityMatches(pid, expect) else { return changed(name) }
        // A fresh osascript child each time, so the admin authorization is never
        // reused from an earlier kill (it is cached per-process for ~5 minutes).
        // `pid` is an integer, so nothing can be injected into the script.
        switch runOsascript("do shell script \"kill \(pid)\" with administrator privileges") {
        case .cancelled: return ActionReport(result: .cancelled, message: "Cancelled.")
        case .failed(let msg): return ActionReport(result: .failed, message: msg)
        case .ok: break
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

    private enum OsaResult { case ok, cancelled, failed(String) }

    /// Runs one AppleScript line as a fresh `/usr/bin/osascript` child. A new
    /// process means a new authorization, so each admin kill prompts again.
    private static func runOsascript(_ source: String) -> OsaResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return .failed("Couldn't ask for the administrator password.") }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .ok }
        let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript prints "User canceled. (-128)" when the dialog is dismissed.
        if msg.contains("-128") { return .cancelled }
        return .failed(msg.isEmpty ? "macOS refused." : msg)
    }

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

    /// Open and copy use the row's name (storefront.localhost) when it has one.
    static func open(_ row: PortRow) {
        NSWorkspace.shared.open(Monitor.shared.address(row))
    }

    static func copyURL(_ row: PortRow) {
        copy(Monitor.shared.address(row).absoluteString)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        // A click on the page leaves harbor in the background, and macOS won't let a
        // background app bring Finder forward, so the window opened behind the browser.
        // Launch Services may: open Finder with activation, as `open -a Finder` does.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                                           configuration: config)
    }
}
