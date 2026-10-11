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
// A normal launch (Finder, Spotlight, login item). The instance that runs is
// the one launchd starts with `--launchd`, because launchd owns port 8470.
// Started by launchd after a Quit: only a visit to the page brings harbor back.
if LaunchAgent.underLaunchd && LaunchAgent.quitMarkerSet {
    LaunchAgent.gate()
}
if !DebugCLI.isDebugRun && !LaunchAgent.underLaunchd {
    LaunchAgent.clearQuitMarker()  // opened on purpose
    if LaunchAgent.pointsAtMissingApp { LaunchAgent.ensureInstalled() }  // the app moved or was deleted
    Door.ensureInstalled()  // harbor.localhost without a port
    // One harbor at a time: a running one is asked to show its page.
    if handOffToRunningCopy() { exit(0) }
    if LaunchAgent.ensureInstalled() {
        if !LaunchAgent.soonAfterBoot { LaunchAgent.requestPage() }
        if LaunchAgent.kickstart() { exit(0) }
    }
    // No agent (e.g. launchctl refused): run here and bind the port ourselves.
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
