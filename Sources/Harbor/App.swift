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
        if !DebugCLI.isDebugRun {
            Monitor.shared.applyDockPolicy()
            NSApp.mainMenu = mainMenu()
            Passwords.moveOutOfKeychain()   // once, and never with a prompt
        }
        let atLogin = launchedAtLogin()
        // Debug runs share no state with the installed copy, so they must not
        // reap its tunnel processes.
        if !DebugCLI.isDebugRun { Tunnels.shared.cleanUpOrphans() }
        _ = LAN.firewallOn  // warm the cached firewall state in the background
        stopTunnelsOnSignals()
        Monitor.shared.start()
        // Names: the proxy, and the port-80 door that lets them work without a port.
        Proxy.shared.start()
        Monitor.shared.checkDoor()
        if DebugCLI.afterLaunch() { return }
        if LaunchAgent.underLaunchd {
            // Started by launchd: a browser may already be waiting on the socket.
            WebServer.shared.start { _ in }
            if LaunchAgent.takePageRequest() { WebServer.shared.openInBrowser() }
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

    // MARK: Dock

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open \(AppInfo.name)", action: #selector(openPage), keyEquivalent: "").target = self
        return menu
    }

    @MainActor @objc private func openPage() { WebServer.shared.openInBrowser() }

    /// The app menu while harbor is in the Dock: open the page, or quit (⌘Q).
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: AppInfo.name)
        app.addItem(withTitle: "Open \(AppInfo.name)", action: #selector(openPage), keyEquivalent: "o").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        return main
    }

    func applicationWillTerminate(_ notification: Notification) {
        Tunnels.shared.stopAll()
        Shared.clear()              // nothing is shared any more: the command line's note goes with it
        OnNetwork.shared.stopAll()  // off the network (the system withdraws the names anyway when harbor is gone)
        // Remember the quit: a tab's later poll must not bring harbor back.
        if LaunchAgent.underLaunchd { LaunchAgent.setQuitMarker() }
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
