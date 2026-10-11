import AppKit
import Foundation
import SwiftUI

/// Command-line helpers for testing and building. None of them are used by
/// the app in normal operation.
///
///   --dump                 print what the app sees (memory, zombies, ports, apps)
///   --bench N              time N full scans and N idle passes
///   --test-stop PORT [--force]
///                          stop the server on PORT (only if it runs from a temp
///                          folder), escalating to SIGKILL with --force
///   --make-icon DIR        write an .iconset into DIR (used by build.sh)
///   --serve                start the page server, print its URL, open nothing
///   --no-open              normal launch, but log the page URL instead of opening it
///   --menubar-icons DIR    write the menu bar glyph for each state as PNGs
///   --demo-menu            launch with the menu content in a plain panel
///       --appearance light|dark   force the look for snapshots (as if macOS were set so)
///       --theme auto|light|dark      harbor's Appearance, for the menu and the page, not saved
///       --show-system                list macOS services too, not saved
///   --snapshot PATH        with --demo-menu: save the panel as PNG
///       --snapshot-delay S, --snapshot-layer (render via CALayer instead)
///
/// HARBOR_DEBUG=1 logs scan-mode changes to stdout.
enum DebugCLI {
    private static var args: [String] = []

    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func handle(_ arguments: [String]) -> Bool {
        args = arguments
        if args.contains("--dump") { dump(); return true }
        if args.contains("--bench") { bench(Int(value(after: "--bench") ?? "") ?? 20); return true }
        if let p = value(after: "--test-stop") { testStop(port: UInt16(p) ?? 0, force: args.contains("--force")); return true }
        if let dir = value(after: "--make-icon") { makeIcon(dir); return true }
        if let dir = value(after: "--menubar-icons") { menubarIcons(dir); return true }
        if args.contains("--check-update") { checkUpdate(); return true }
        return false
    }

    // MARK: Updates

    /// Version comparison checks, then one real look at the Releases page.
    private static func checkUpdate() {
        precondition(Updates.isNewer("1.10", than: "1.9") && Updates.isNewer("1.1", than: "1.0.9") && Updates.isNewer("2", than: "1.9.9"))
        precondition(!Updates.isNewer("1.1.0", than: "1.1") && !Updates.isNewer("1.0", than: "1.1"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            print("version checks ok; newest release on GitHub:", await Updates.newestRelease() ?? "none")
            done.signal()
        }
        done.wait()
    }

    // MARK: Dump

    private static func dump() {
        let scanner = Scanner()
        _ = scanner.fullScan(sampleCPU: true)
        Thread.sleep(forTimeInterval: 1.5)
        let s = scanner.fullScan(sampleCPU: true)
        let m = SystemMemory.read()
        out("MEMORY physical=\(Fmt.bytes(m.physical)) app=\(Fmt.bytes(m.app)) wired=\(Fmt.bytes(m.wired)) compressed=\(Fmt.bytes(m.compressed)) cached=\(Fmt.bytes(m.cached)) free=\(Fmt.bytes(m.free))")
        out("SWAP used=\(Fmt.bytes(m.swapUsed)) total=\(Fmt.bytes(m.swapTotal)) pressure=\(m.pressure.label)")
        let z = s.zombies
        out("PROCS total=\(z.processCount) own=\(z.ownProcessCount) maxproc=\(z.maxProc) maxprocperuid=\(z.maxProcPerUID)")
        out("ZOMBIES total=\(z.zombieCount) alarm=\(z.alarm)")
        for p in z.parents.prefix(10) { out("  zombie-parent pid=\(p.pid) name=\(p.name) count=\(p.count)") }
        out("PORTS \(s.ports.count) (scan \(String(format: "%.1f", s.duration * 1000)) ms)")
        for r in s.ports {
            out("  port=\(r.port) pid=\(r.pid) name=\(r.processName) addr=\(r.addresses.joined(separator: ",")) scope=\(r.scope) hidden=\(r.isHiddenByDefault) workers=\(r.workers) mem=\(r.footprint.map(Fmt.bytes) ?? "-") up=\(Fmt.uptime(since: r.started)) cwd=\(r.cwd ?? "-") project=\(r.projectRoot ?? "-") cmd=\(r.command ?? "-")")
        }
        out("APPS \(s.apps.count) groups; \(s.others.count) other-user processes")
        for g in s.apps.prefix(15) {
            out("  \(g.name) mem=\(Fmt.bytes(g.footprint)) cpu=\(Fmt.cpu(g.cpu)) procs=\(g.pids.count) main=\(g.mainPid) system=\(g.isSystem)")
        }
    }

    // MARK: Bench

    private static func bench(_ n: Int) {
        let scanner = Scanner()
        var full: [Double] = []
        for _ in 0..<n {
            full.append(scanner.fullScan(sampleCPU: true).duration * 1000)
        }
        var idle: [Double] = []
        for _ in 0..<n {
            let t0 = LibProc.monotonicNanos()
            _ = scanner.zombiePass()
            _ = SystemMemory.read()
            idle.append(Double(LibProc.monotonicNanos() - t0) / 1e6)
        }
        func stats(_ v: [Double]) -> String {
            String(format: "avg %.1f ms, min %.1f, max %.1f", v.reduce(0, +) / Double(v.count), v.min() ?? 0, v.max() ?? 0)
        }
        out("full scan (\(n)x): \(stats(full))")
        out("idle pass (\(n)x): \(stats(idle))")
    }

    // MARK: Stop test (temp-folder servers only)

    private static func testStop(port: UInt16, force: Bool) {
        let scan = Scanner().fullScan(sampleCPU: false)
        guard let row = scan.ports.first(where: { $0.port == port }) else {
            out("no listener on port \(port)"); return
        }
        let cwd = row.cwd ?? ""
        let tempPrefixes = ["/private/tmp/", "/tmp/", "/private/var/folders/"]
        guard tempPrefixes.contains(where: { cwd.hasPrefix($0) }) else {
            out("refusing: pid \(row.pid) runs in \(cwd), not a temp folder"); return
        }
        out("found port=\(port) pid=\(row.pid) name=\(row.processName) cwd=\(cwd)")
        let path = row.path ?? ""
        let before = Set(ProcessControl.siblings(path: path).keys).union([row.pid])
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let r = ProcessControl.send(SIGTERM, to: row.pid)
            out("SIGTERM -> \(r)")
            var exited = await ProcessControl.waitForExit(row.pid, timeout: 3)
            out("exited within 3 s: \(exited)")
            if !exited && force {
                out("SIGKILL -> \(ProcessControl.send(SIGKILL, to: row.pid))")
                exited = await ProcessControl.waitForExit(row.pid, timeout: 2)
                out("exited after SIGKILL: \(exited)")
            }
            if exited {
                let again = await ProcessControl.findRestart(path: path, oldParent: row.ppid, before: before, within: 12)
                out(again.map { "restarted as pid \($0): It restarts itself. Use the app's own Quit or uninstall it." } ?? "did not restart")
            }
            sem.signal()
        }
        sem.wait()
    }

    // MARK: Icon

    /// The menu bar glyph in each state, at 2x, for checking by eye.
    private static func menubarIcons(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for state in [IconState.good, .warn, .bad, .zombies] {
            let img = StatusIcon.image(for: state)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width * 2), pixelsHigh: Int(img.size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = img.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(origin: .zero, size: img.size))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar-\(state).png"))
            out("menubar-\(state).png template=\(img.isTemplate)")
        }
    }

    private static func makeIcon(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            if let data = WaveMark.png(px, inset: 0.1, radius: 0.225) {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
    }

    // MARK: UI demo modes

    /// Called once the app has launched. Returns true if a demo mode ran.
    @MainActor
    static func afterLaunch() -> Bool {
        let snapshotPath = value(after: "--snapshot")
        if args.contains("--serve") {
            // Start the page server and print its URL without opening a browser.
            WebServer.shared.start { url in out("PAGE \(url?.absoluteString ?? "failed")") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let bars = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible }
                out("STATUS ITEMS \(bars.count)")
            }
            return true
        }
        if let i = Double(value(after: "--interval") ?? "") { Monitor.shared.refreshInterval = Monitor.clampInterval(i) }
        if let g = value(after: "--grouping"), let v = Monitor.Grouping(rawValue: g) {
            Monitor.shared.grouping = v  // not saved in debug runs
        }
        if let look = value(after: "--appearance") {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        // --theme sets harbor's own Appearance for both the menu and the page (not saved in debug runs).
        if let t = value(after: "--theme"), let v = Monitor.Appearance(rawValue: t) {
            Monitor.shared.appearance = v
            Monitor.shared.pageAppearance = v
        }
        if args.contains("--show-system") { Monitor.shared.showSystemPorts = true }  // not saved either
        if let raw = value(after: "--demo-lan"), let port = UInt16(raw) {
            // The menu's "open on another device" card for one port, in a panel.
            Monitor.shared.requestFullScan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let row = Monitor.shared.ports.first(where: { $0.port == port }) else { out("no row for :\(port)"); return }
                    let panel = DemoPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
                                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.title = "LAN card (demo)"
                    let host = NSHostingView(rootView: LANCard(row: row).environment(Monitor.shared))
                    panel.contentView = host
                    panel.setContentSize(host.fittingSize)
                    panel.center()
                    panel.orderFrontRegardless()
                    demoPanel = panel
                    report(panel, snapshotPath)
                }
            }
            return true
        }
        if args.contains("--demo-menu") {
            let panel = DemoPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "\(AppInfo.name) menu (demo)"
            let host = NSHostingView(rootView: MenuContent().environment(Monitor.shared))
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            panel.center()
            panel.orderFrontRegardless()
            demoPanel = panel
            report(panel, snapshotPath)
            return true
        }
        return false
    }

    @MainActor private static var demoPanel: NSPanel?

    /// Demo windows never take the keyboard, so typing elsewhere can't land in them.
    private final class DemoPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor
    private static func report(_ w: NSWindow, _ snapshotPath: String?) {
        out("WINDOW \(w.windowNumber)")
        guard let snapshotPath else { return }
        let delay = Double(value(after: "--snapshot-delay") ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if let panel = demoPanel { panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size) }
                out("GEOMETRY window=\(w.frame) content=\(w.contentView?.frame ?? .zero) layout=\(w.contentLayoutRect)")
                if args.contains("--snapshot-layer"), let view = w.contentView?.superview ?? w.contentView,
                   let layer = view.layer {
                    let scale = w.backingScaleFactor
                    let size = view.bounds.size
                    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                    if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                           bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: scale, y: scale)
                        layer.render(in: ctx)
                        if let img = ctx.makeImage() {
                            let rep = NSBitmapImageRep(cgImage: img)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: snapshotPath))
                            out("SNAPSHOT(layer) \(snapshotPath)")
                        }
                    }
                    return
                }
                guard let view = w.contentView?.superview ?? w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: snapshotPath))
                    out("SNAPSHOT \(snapshotPath)")
                }
            }
        }
    }

    /// --no-open (or --serve): never open the browser, only log the page URL.
    static var noOpen: Bool { args.contains("--no-open") || args.contains("--serve") }

    /// Any test flag: run without a menu bar icon and alongside an installed copy.
    static var isDebugRun: Bool {
        args.contains { ["--no-open", "--serve", "--demo-menu", "--demo-lan", "--snapshot"].contains($0) }
    }

    /// Settings store. Debug runs use a throwaway suite so they never read or
    /// write the installed app's `local.harbor` defaults. One swap point: all
    /// code reads and writes settings through here.
    static var defaults: UserDefaults {
        isDebugRun ? (UserDefaults(suiteName: "local.harbor.debug") ?? .standard) : .standard
    }

    /// Set HARBOR_DEBUG=1 to log mode changes to stdout.
    static let verbose = ProcessInfo.processInfo.environment["HARBOR_DEBUG"] == "1"

    static func log(_ s: String) {
        if verbose { out("[\(Date().formatted(date: .omitted, time: .standard))] \(s)") }
    }

    static func out(_ s: String) {
        print(s)
        fflush(stdout)
    }
}
