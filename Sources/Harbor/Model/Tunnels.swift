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
        UserDefaults.standard.removeObject(forKey: Self.pidsKey)
    }

    /// After a crash, tunnels from the last run would keep a port public.
    func cleanUpOrphans() {
        let pids = UserDefaults.standard.array(forKey: Self.pidsKey) as? [Int] ?? []
        for raw in pids {
            let pid = pid_t(raw)
            guard let path = LibProc.path(pid), path.hasSuffix("/cloudflared") || path.hasSuffix("/ngrok"),
                  let args = LibProc.arguments(pid), args.contains("--url") || args.contains("http") else { continue }
            kill(pid, SIGTERM)
        }
        UserDefaults.standard.removeObject(forKey: Self.pidsKey)
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
        var pids = UserDefaults.standard.array(forKey: Self.pidsKey) as? [Int] ?? []
        pids.append(Int(pid))
        UserDefaults.standard.set(pids, forKey: Self.pidsKey)
    }

    private func forget(_ pid: pid_t) {
        let pids = (UserDefaults.standard.array(forKey: Self.pidsKey) as? [Int] ?? []).filter { $0 != Int(pid) }
        UserDefaults.standard.set(pids, forKey: Self.pidsKey)
    }

    /// When a shared server stops, its tunnel would only serve errors.
    func prune(listening: Set<UInt16>) {
        for port in active.keys where !listening.contains(port) {
            stop(port)
            Monitor.shared.notify("Stopped sharing :\(port) because nothing listens there any more.")
        }
    }

    // MARK: QR codes

    func qr(_ text: String) -> CGImage? {
        if let c = qrCache[text] { return c }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent) else { return nil }
        qrCache[text] = cg
        return cg
    }

    /// The QR code as rows of "0"/"1", for the page to draw on a canvas.
    func qrRows(_ text: String) -> [String]? {
        guard let cg = qr(text) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in String((0..<w).map { pixels[y * w + $0] < 128 ? "1" : "0" }) }
    }
}
