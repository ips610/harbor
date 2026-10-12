import AppKit

// The port-80 door (started by launchd): redirect and exit, no app, no menu bar.
if CommandLine.arguments.contains("--door") {
    Door.run()
}

// Debug/test commands (`--dump`, `--bench`, `--test-stop`, `--make-icon`) run
// without any UI and exit. Everything else starts the menu bar app.
if DebugCLI.handle(CommandLine.arguments) {
    exit(0)
}
// `--refresh-agents`: what install.sh runs after putting a new copy in place. It makes the
// agents this version's (a new version may hold more sockets than the old agent did) and
// starts harbor under them, without opening the page. Safe to run again: with the agents
// already right it only makes sure harbor is started. It leaves the "was quit" marker alone.
if CommandLine.arguments.contains("--refresh-agents") {
    let agent = LaunchAgent.refresh(quitOld: quitOtherCopies)
    let door = Door.ensureInstalled()
    let started = agent != .failed && LaunchAgent.kickstart()
    print("agent: \(agent), door: \(door ? "harbor's" : "not harbor's"), started: \(started)")
    exit(agent == .failed ? 1 : 0)
}
// A normal launch (Finder, Spotlight, login item). The instance that runs is
// the one launchd starts with `--launchd`, because launchd owns harbor's port.
// Started by launchd after a Quit: only a visit to the page brings harbor back.
if LaunchAgent.underLaunchd && LaunchAgent.quitMarkerSet {
    LaunchAgent.gate()
}
if !DebugCLI.isDebugRun && !LaunchAgent.underLaunchd {
    LaunchAgent.clearQuitMarker()  // opened on purpose
    // The agents first, before anything is handed to a running copy: after an update (the
    // new app dragged over the old one, or install.sh) the copy that runs is the old one,
    // under the old agent. If the agents had to be replaced, that copy is gone by now.
    let agent = LaunchAgent.refresh(quitOld: quitOtherCopies)
    Door.ensureInstalled()  // harbor.localhost without a port, and the projects' names
    // One harbor at a time: a running one (this version, the agents were already right, or
    // this copy may not manage them) is asked to show its page.
    if agent != .replaced, handOffToRunningCopy() { exit(0) }
    if agent != .failed {
        if !LaunchAgent.soonAfterBoot { LaunchAgent.requestPage() }
        LaunchAgent.clearQuitMarker()  // a copy that was just replaced set it on its way out
        if LaunchAgent.kickstart() { exit(0) }
    }
    // No agent (a copy outside Applications, or launchctl refused): run here and bind the port ourselves.
}
if DebugCLI.isDebugRun {
    // Test runs: no SwiftUI scene, so no second icon in the real menu bar.
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    HarborApp.main()
}

/// Asks every other running harbor to quit and waits up to 5 s for it to go. After an update
/// that copy is the old version; it must let go of the port before the new agent is loaded.
func quitOtherCopies() {
    guard let id = Bundle.main.bundleIdentifier else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
    others.forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, others.contains(where: { kill($0.processIdentifier, 0) == 0 }) { usleep(100_000) }
}

/// If another harbor (same bundle id) runs, reopen it (it opens its page) and return true.
func handOffToRunningCopy() -> Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let me = ProcessInfo.processInfo.processIdentifier
    guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .first(where: { $0.processIdentifier != me }), let url = other.bundleURL else { return false }
    let done = DispatchSemaphore(value: 0)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 3)
    return true
}
