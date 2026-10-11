import AppKit
import SwiftUI

struct HarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(Monitor.shared)
        } label: {
            MenuBarLabel()
                .environment(Monitor.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let atLogin = launchedAtLogin()
        Tunnels.shared.cleanUpOrphans()
        stopTunnelsOnSignals()
        Monitor.shared.start()
        if DebugCLI.afterLaunch() { return }
        if LaunchAgent.underLaunchd {
            // Started by launchd: a browser may already be waiting on the socket.
            WebServer.shared.start { _ in }
            if LaunchAgent.takePageRequest() { WebServer.shared.openInBrowser() }
            DispatchQueue.global(qos: .utility).async { Door.ensureInstalled() }
            return
        }
        // Opened from Applications or Spotlight: show the page. At login: stay in the menu bar.
        if !atLogin { WebServer.shared.openInBrowser() }
    }

    /// Opening the app again while it runs brings up the page.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WebServer.shared.openInBrowser()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// With a page open, its next poll would make launchd start harbor again.
    /// So answer that poll with "quit" first (at most 3.5 s), then exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Monitor.shared.webActive, !WebAPI.quitting else { return .terminateNow }
        WebAPI.quitting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { WebAPI.finishQuit() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Tunnels.shared.stopAll()
    }

    /// `kill` (e.g. from install.sh) skips applicationWillTerminate, so catch
    /// SIGTERM/SIGINT too: no tunnel may outlive harbor.
    private var signalSources: [DispatchSourceSignal] = []
    private func stopTunnelsOnSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // Quit the normal way: an open page is told first, tunnels are stopped
            // in applicationWillTerminate.
            // Via the run loop, not inside this GCD block: terminateLater runs a
            // nested event loop that must still drain the main queue.
            src.setEventHandler {
                RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func launchedAtLogin() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Fallback: a launch within two minutes of boot is almost certainly login.
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            return Date().timeIntervalSince1970 - Double(boot.tv_sec) < 120
        }
        return false
    }
}
