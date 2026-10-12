import AppKit
import CoreImage
import Foundation
import Observation

/// Public links for local ports, like Manfath's tunnels: a Cloudflare quick
/// tunnel (or ngrok, when installed and logged in). Always started by the
/// user after a confirmation; every tunnel is a child process harbor stops.
@MainActor
@Observable
final class Tunnels {
    static let shared = Tunnels()

    enum Phase: Equatable { case starting, ready(String), failed(String) }

    struct Tunnel: Equatable {
        let port: UInt16
        let title: String
        let provider: String
        var phase: Phase
    }

    struct Tool {
        let name: String
        let path: String
        let isNgrok: Bool
    }

    private(set) var active: [UInt16: Tunnel] = [:]

    /// A made-up public link that is "ready", for snapshots (`--fixture both`). Nothing is started.
    func useFixture(port: UInt16, title: String, url: String) {
        active[port] = Tunnel(port: port, title: title, provider: "cloudflared", phase: .ready(url))
    }
    @ObservationIgnored private var processes: [UInt16: Process] = [:]
    @ObservationIgnored private var qrCache: [String: CGImage] = [:]

    private static let pidsKey = "tunnelPids"

    // MARK: Tools (never installed by harbor)

    static var cloudflared: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ngrok: String? {
        ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// ngrok works only after `ngrok config add-authtoken`.
    static var ngrokConfigured: Bool {
        let home = NSHomeDirectory()
        return ["\(home)/Library/Application Support/ngrok/ngrok.yml", "\(home)/.config/ngrok/ngrok.yml", "\(home)/.ngrok2/ngrok.yml"]
            .contains { (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("authtoken") == true }
    }

    static var tool: Tool? {
        if let c = cloudflared { return Tool(name: "Cloudflare", path: c, isNgrok: false) }
        if let n = ngrok, ngrokConfigured { return Tool(name: "ngrok", path: n, isNgrok: true) }
        return nil
    }

    /// Manfath's hint when nothing can make a tunnel.
    static var hint: (text: String, command: String) {
        if ngrok != nil && !ngrokConfigured {
            return ("ngrok needs an authtoken once. Add it, or install cloudflared instead.", "ngrok config add-authtoken <your-token>")
        }
        return ("cloudflared isn't installed. Install it, then share again.", "brew install cloudflared")
    }

    func isTunnelPid(_ pid: pid_t) -> Bool {
        processes.values.contains { $0.processIdentifier == pid }
    }

    // MARK: Start / stop

    /// Returns a message when sharing can't start.
    @discardableResult
    func start(_ row: PortRow) -> String? {
        if active[row.port] != nil { return nil }
        guard let tool = Self.tool else { return Self.hint.text }
        // Point the tunnel at an address the server really listens on.
        let host = row.addresses == ["::1"] ? "[::1]" : "127.0.0.1"
        let target = "http://\(host):\(row.port)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool.path)
        p.arguments = tool.isNgrok
            ? ["http", target, "--log", "stdout"]
            : ["tunnel", "--no-autoupdate", "--url", target]
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = tool.isNgrok ? pipe : FileHandle.nullDevice
        p.standardError = tool.isNgrok ? FileHandle.nullDevice : pipe
        let port = row.port
        let pattern = tool.isNgrok ? #"https://[a-z0-9-]+\.ngrok(-free)?\.(app|dev|io)"# : #"https://[a-z0-9-]+\.trycloudflare\.com"#
        // Keep draining the pipe so the tool never blocks on a full buffer.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8),
                  let range = text.range(of: pattern, options: .regularExpression) else { return }
            let url = String(text[range])
            DispatchQueue.main.async { MainActor.assumeIsolated { Tunnels.shared.ready(port, url) } }
        }
        p.terminationHandler = { proc in
            let pid = proc.processIdentifier
            DispatchQueue.main.async { MainActor.assumeIsolated { Tunnels.shared.exited(port, pid) } }
        }
        do {
            try p.run()
        } catch {
            return "Couldn't start \(tool.name): \(error.localizedDescription)"
        }
        processes[port] = p
        remember(p.processIdentifier)
        active[port] = Tunnel(port: port, title: row.title, provider: tool.name, phase: .starting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active[port]?.phase == .starting else { return }
                self.stop(port)
                Monitor.shared.notify("Couldn't get a public link for :\(port) within 45 seconds. Check your internet connection.")
            }
        }
        return nil
    }

    func stop(_ port: UInt16) {
        active[port] = nil
        guard let p = processes.removeValue(forKey: port) else { return }
        let pid = p.processIdentifier
        if p.isRunning { p.terminate() }
        // Check the Process, not the pid: a reaped pid can be reused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
        forget(pid)
    }

    /// Stops every tunnel; called when harbor quits.
    func stopAll() {
        let all = Array(processes.values)
        processes = [:]
        active = [:]
        for p in all where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(1.5)
        while all.contains(where: { $0.isRunning }) && Date() < deadline { usleep(50_000) }
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        DebugCLI.defaults.removeObject(forKey: Self.pidsKey)
    }

    /// After a crash, tunnels from the last run would keep a port public.
    func cleanUpOrphans() {
        let pids = DebugCLI.defaults.array(forKey: Self.pidsKey) as? [Int] ?? []
        for raw in pids {
            let pid = pid_t(raw)
            guard let path = LibProc.path(pid), path.hasSuffix("/cloudflared") || path.hasSuffix("/ngrok"),
                  let args = LibProc.arguments(pid), args.contains("--url") || args.contains("http") else { continue }
            kill(pid, SIGTERM)
        }
        DebugCLI.defaults.removeObject(forKey: Self.pidsKey)
    }

    private func ready(_ port: UInt16, _ url: String) {
        guard var t = active[port], t.phase == .starting else { return }
        t.phase = .ready(url)
        active[port] = t
        Monitor.shared.flash("Sharing :\(port) at \(url)")
    }

    private func exited(_ port: UInt16, _ pid: pid_t) {
        forget(pid)
        guard processes[port]?.processIdentifier == pid else { return }  // stopped on purpose
        processes[port] = nil
        active[port] = nil
        Monitor.shared.notify("Sharing :\(port) stopped: the tunnel tool exited.")
    }

    private func remember(_ pid: pid_t) {
        var pids = DebugCLI.defaults.array(forKey: Self.pidsKey) as? [Int] ?? []
        pids.append(Int(pid))
        DebugCLI.defaults.set(pids, forKey: Self.pidsKey)
    }

    private func forget(_ pid: pid_t) {
        let pids = (DebugCLI.defaults.array(forKey: Self.pidsKey) as? [Int] ?? []).filter { $0 != Int(pid) }
        DebugCLI.defaults.set(pids, forKey: Self.pidsKey)
    }

    /// When a shared server stops, its tunnel would only serve errors.
    func prune(listening: Set<UInt16>) {
        for port in active.keys where !listening.contains(port) {
            stop(port)
            Monitor.shared.notify("Stopped sharing :\(port) because nothing listens there any more.")
        }
    }

    // MARK: QR codes

    /// A QR code drawn exactly `pixels` wide, in harbor's style (see QR). Kept per text and size.
    func qr(_ text: String, pixels: Int) -> CGImage? {
        let key = "\(pixels) \(text)"
        if let c = qrCache[key] { return c }
        guard let cg = QR.image(text, pixels: pixels) else { return nil }
        qrCache[key] = cg
        return cg
    }

    /// The QR code as rows of "0"/"1", without a quiet zone, for the page to draw the same way.
    func qrRows(_ text: String) -> [String]? {
        QR.matrix(text)?.map { String($0.map { $0 ? "1" : "0" }) }
    }
}

/// harbor's QR codes: soft squares, round corner eyes and the wave mark in the middle, on a
/// white card. Always dark on white, in dark mode too: inverted codes fail on some phones.
/// The page draws the same thing from `matrix` (Page.qrScript); keep the two alike.
enum QR {
    /// A code a row can show: its name on the network, its plain network address, its public link.
    enum Code: String { case name, lan, share }

    /// Which codes a row shows. On the network under its name: that one, and it stands in
    /// for the plain address. Otherwise the plain address, when other devices can reach it.
    /// And the public link when there is one. So one or two, never three.
    static func codes(onNetwork: Bool, reachable: Bool, shared: Bool) -> [Code] {
        (onNetwork ? [.name] : reachable ? [.lan] : []) + (shared ? [.share] : [])
    }

    /// Modules of white around the code, inside the card (the standard quiet zone).
    static let quiet = 4
    static let ink = "#0b0b0c"

    /// The modules, dark = true, with no quiet zone. Correction level H (30%), because the
    /// mark in the middle covers some of them.
    static func matrix(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent) else { return nil }
        // One pixel per module.
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rows = (0..<h).map { y in (0..<w).map { pixels[y * w + $0] < 128 } }
        // Core Image puts a white border of its own around the code; the card has the real one.
        while rows.first?.contains(true) == false { rows.removeFirst() }
        while rows.last?.contains(true) == false { rows.removeLast() }
        while !rows.isEmpty, !rows.contains(where: { $0.first == true }) { rows = rows.map { Array($0.dropFirst()) } }
        while !rows.isEmpty, !rows.contains(where: { $0.last == true }) { rows = rows.map { Array($0.dropLast()) } }
        return rows.isEmpty || rows.count != rows[0].count ? nil : rows
    }

    /// How many modules across the square cleared for the mark is: an odd number, about 24% of
    /// the width, so it never covers more than about 6% of the modules (7 of 29, 11 of 49).
    static func hole(_ modules: Int) -> Int {
        let h = Int(Double(modules) * 0.245)
        return h % 2 == 1 ? h : h - 1
    }

    /// The code drawn `pixels` wide: the white card, soft squares for the modules, the three
    /// corner eyes as shapes, and the mark on its tile, one module smaller than its hole.
    static func image(_ text: String, pixels: Int) -> CGImage? {
        guard pixels > 0, let m = matrix(text), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let n = m.count, total = CGFloat(n + quiet * 2), side = CGFloat(pixels)
        func fill(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat, radius: CGFloat, _ color: String) {
            ctx.setFillColor(NSColor(hex: color).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        // Pixels, y down, from the card's top left corner.
        ctx.translateBy(x: 0, y: side)
        ctx.scaleBy(x: 1, y: -1)
        fill(0, 0, side, radius: side * 0.07, "#ffffff")
        // A module is a whole number of pixels, and the code sits in the middle of the card: at
        // 132 points a long link's modules are only 2 or 3 pixels, and ones that straddle
        // pixels blur until the code stops scanning. The card's margin takes up the slack. It
        // starts on an even pixel, so a reader that halves the picture first still sees whole
        // modules (drawn from an odd pixel, some sizes didn't read).
        let unit = side >= total ? (side / total).rounded(.down) : side / total
        let margin = 2 * ((side - unit * total) / 4).rounded() + unit * CGFloat(quiet)
        // From here on: module units, from the code's top left corner.
        ctx.translateBy(x: margin, y: margin)
        ctx.scaleBy(x: unit, y: unit)

        let hole = Self.hole(n), lo = (n - hole) / 2, cleared = lo..<(lo + hole)
        let eyes = [(0, 0), (n - 7, 0), (0, n - 7)]
        for y in 0..<n {
            for x in 0..<n where m[y][x] {
                if eyes.contains(where: { (ex, ey) in (ex..<ex + 7).contains(x) && (ey..<ey + 7).contains(y) }) { continue }
                if cleared.contains(x) && cleared.contains(y) { continue }
                fill(CGFloat(x) + 0.06, CGFloat(y) + 0.06, 0.88, radius: 0.3, ink)
            }
        }
        for (ex, ey) in eyes {
            let x = CGFloat(ex), y = CGFloat(ey)
            ctx.setStrokeColor(NSColor(hex: ink).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x + 0.5, y: y + 0.5, width: 6, height: 6), cornerWidth: 1.9, cornerHeight: 1.9, transform: nil))
            ctx.strokePath()
            fill(x + 2, y + 2, 3, radius: 1, ink)
        }
        // The app's tile (flat, like the tab icon) with WaveMark's two waves.
        let at = CGFloat(lo) + 0.5, tile = CGFloat(hole - 1), k = tile / 64
        fill(at, at, tile, radius: 14 * k, "#16171c")
        ctx.addPath(WaveMark.path { x, y in NSPoint(x: at + x * k, y: at + y * k) }.cgPath)
        ctx.setStrokeColor(NSColor(hex: "#a7b4ff").cgColor)
        ctx.setLineWidth(6 * k)
        ctx.setLineCap(.round)
        ctx.strokePath()
        return ctx.makeImage()
    }
}
