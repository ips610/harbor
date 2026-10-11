import AppKit

// Debug/test commands (`--dump`, `--bench`, `--test-stop`, `--make-icon`) run
// without any UI and exit. Everything else starts the menu bar app.
if DebugCLI.handle(CommandLine.arguments) {
    exit(0)
}
// One harbor at a time: a second launch asks the running one to show its page.
if !DebugCLI.isDebugRun, handOffToRunningCopy() {
    exit(0)
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
