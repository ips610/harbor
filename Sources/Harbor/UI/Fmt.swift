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

/// harbor's mark: the page header's two waves, in a 64-unit square (y down). The
/// favicon SVG (Page.icon) has the same paths; the app icon and menu bar glyph use this.
enum WaveMark {
    static func path(_ map: (CGFloat, CGFloat) -> NSPoint) -> NSBezierPath {
        let p = NSBezierPath()
        for y: CGFloat in [25, 39] {
            p.move(to: map(11, y))
            p.curve(to: map(25, y), controlPoint1: map(16, y - 4.8), controlPoint2: map(20, y - 4.8))
            p.curve(to: map(39, y), controlPoint1: map(30, y + 4.8), controlPoint2: map(34, y + 4.8))
            p.curve(to: map(53, y), controlPoint1: map(44, y - 4.8), controlPoint2: map(48, y - 4.8))
        }
        p.lineCapStyle = .round
        return p
    }

    /// The mark on its ink tile as a PNG. The app icon keeps macOS's 10% margin;
    /// tab icons fill the square (radius as a fraction of the tile; 0 = square).
    static func png(_ px: Int, inset: CGFloat = 0, radius: CGFloat = 14.0 / 64) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let s = CGFloat(px)
        rep.size = NSSize(width: s, height: s)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * inset, dy: s * inset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * radius, yRadius: rect.width * radius)
        NSGradient(starting: NSColor(hex: "#23252e"), ending: NSColor(hex: "#0b0b0c"))?.draw(in: shape, angle: -90)
        let k = rect.width / 64
        let waves = path { x, y in NSPoint(x: rect.minX + x * k, y: rect.maxY - y * k) }
        waves.lineWidth = 6 * k
        NSColor(hex: "#a7b4ff").setStroke()
        waves.stroke()
        NSGraphicsContext.current?.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// Tab icons for browsers that skip SVG favicons (Safari often does), made once.
    static let favicon32 = png(32) ?? Data()
    static let appleTouch = png(180, radius: 0) ?? Data()  // iOS rounds the corners itself
}

enum StatusIcon {
    static func image(for state: IconState) -> NSImage {
        if state != .zombies {
            // The waves: a template image that follows the menu bar, orange or red when memory is tight.
            let color: NSColor? = state == .good ? nil : state == .warn ? .systemOrange : .systemRed
            let img = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { r in
                let k = r.width / 48  // the waves span x 8...56 of the grid, centred on 32
                let path = WaveMark.path { x, y in NSPoint(x: r.midX + (x - 32) * k, y: r.midY - (y - 32) * k) }
                path.lineWidth = 5 * k
                (color ?? .black).setStroke()
                path.stroke()
                return true
            }
            img.isTemplate = color == nil
            img.accessibilityDescription = AppInfo.name
            return img
        }
        let name = "exclamationmark.triangle.fill"
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
