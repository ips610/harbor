import AppKit
import SwiftUI

enum Fmt {
    private static let home = NSHomeDirectory()

    /// Binary units, labelled the way Activity Monitor labels them.
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    static func cpu(_ c: Double?) -> String {
        guard let c else { return "–" }
        if c < 0.05 { return "0%" }
        if c < 10 { return String(format: "%.1f%%", c) }
        return String(format: "%.0f%%", c)
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }

    static func uptime(since date: Date?) -> String {
        guard let date else { return "" }
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        let d = s / 86_400
        return d == 1 ? "1 day" : "\(d) days"
    }

    static func path(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    static func lastComponent(_ p: String) -> String {
        (p as NSString).lastPathComponent
    }
}

extension Level {
    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
}

extension Pressure {
    var level: Level {
        switch self {
        case .normal: return .good
        case .warning: return .warn
        case .critical: return .bad
        }
    }
}

/// App icons, cached while the window is open and dropped when it closes.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(_ bundlePath: String) -> NSImage {
        if let i = cache[bundlePath] { return i }
        let i = NSWorkspace.shared.icon(forFile: bundlePath)
        i.size = NSSize(width: 32, height: 32)
        cache[bundlePath] = i
        return i
    }

    func warm(_ paths: [String]) {
        for p in paths where cache[p] == nil { _ = icon(p) }
    }

    func clear() { cache = [:] }
}

enum StatusIcon {
    static func image(for state: IconState) -> NSImage {
        let name = state == .zombies ? "exclamationmark.triangle.fill" : "ferry.fill"
        let color: NSColor
        switch state {
        case .good: color = .systemGreen
        case .warn: color = .systemOrange
        case .bad, .zombies: color = .systemRed
        }
        // The warning triangle gets a white "!" on red; the pulse is one colour.
        let palette: [NSColor] = state == .zombies ? [.white, color] : [color]
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "\(AppInfo.name)") ?? NSImage()
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = false
        return img
    }
}
