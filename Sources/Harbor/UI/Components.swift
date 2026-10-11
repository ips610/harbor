import AppKit
import SwiftUI

/// Tells the Monitor when the hosting window is actually on screen, so full
/// scans run only while someone can see them.
struct WindowVisibilityReporter: NSViewRepresentable {
    let surface: Monitor.Surface

    func makeNSView(context: Context) -> ReporterView {
        let v = ReporterView()
        v.surface = surface
        return v
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {}

    final class ReporterView: NSView {
        var surface: Monitor.Surface = .menu
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            Monitor.shared.register(surface, window: window)
            guard let w = window else {
                Monitor.shared.setVisible(surface, false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        self?.report(closing: note.name == NSWindow.willCloseNotification)
                    }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let w = window else { return }
            let visible = !closing && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
            Monitor.shared.setVisible(surface, visible)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

struct AppIconView: View {
    let bundlePath: String?
    var size: CGFloat = 20

    var body: some View {
        if let bundlePath {
            Image(nsImage: IconCache.shared.icon(bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

struct ToastView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        if let text = monitor.toast {
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 10)
                .padding(.horizontal, 12)
                .transition(.opacity)
        }
    }
}

/// Opaque light/dark pairs, checked for at least 4.5:1 text contrast.
enum Tone {
    static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    static let neutralBg = dynamic("#e3e3e5", "#3d3d40")
    static let neutralHover = dynamic("#d6d6d9", "#4a4a4e")
    static let neutralInk = dynamic("#2c2c2e", "#e8e8ea")
    static let openBg = dynamic("#dbe7fb", "#1f3352")
    static let openInk = dynamic("#0a4fb0", "#a9c8ff")
    static let shareBg = dynamic("#d4f0e4", "#173b2e")
    static let shareInk = dynamic("#0b6b4b", "#86e3bb")
    static let killBg = dynamic("#f9dedb", "#4a201c")
    static let killInk = dynamic("#b3261e", "#ff9a90")
    static let red = Color(nsColor: NSColor(hex: "#c5221f"))
    static let admin = Color(nsColor: NSColor(hex: "#0a5bd3"))
    /// The "shared" green, the same as the page's.
    static let shared = dynamic("#0f7f5f", "#46d39a")
    static let sharedInk = dynamic("#ffffff", "#0e0e10")
}

extension NSColor {
    convenience init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Manfath-style lowercase text action. Colour means something: open is
/// accent, share is green, kill is neutral until hovered and red only then.
struct Pill: View {
    enum Style { case plain, open, share, danger, dangerFilled, go, accentFilled }
    let title: String
    var style: Style = .plain
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .foregroundStyle(foreground)
                .background(Capsule().fill(background).brightness(hovering && tinted ? -0.04 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }

    private var tinted: Bool { [.open, .share, .dangerFilled, .go, .accentFilled].contains(style) }

    private var foreground: Color {
        switch style {
        case .plain: return Tone.neutralInk
        case .open: return Tone.openInk
        case .share: return Tone.shareInk
        case .danger: return hovering ? Tone.killInk : Tone.neutralInk
        case .dangerFilled, .accentFilled: return .white
        case .go: return Tone.sharedInk
        }
    }

    private var background: Color {
        switch style {
        case .plain: return hovering ? Tone.neutralHover : Tone.neutralBg
        case .open: return Tone.openBg
        case .share: return Tone.shareBg
        case .danger: return hovering ? Tone.killBg : Tone.neutralBg
        case .dangerFilled: return Tone.red
        case .go: return Tone.shared
        case .accentFilled: return Tone.admin
        }
    }
}

/// Inline stop flow, like Manfath's kill button: "kill" → "confirm?" →
/// working → done, with force and administrator follow-ups when needed.
/// The question (naming the process, port and folder) shows in `caption`.
struct StopControl: View {
    enum Phase: Equatable { case idle, confirming, working, force, admin }

    let verb: String
    let question: String
    let primary: () async -> ActionReport
    let force: () async -> ActionReport
    let admin: () async -> ActionReport
    @Binding var caption: String?
    @State private var phase: Phase = .idle
    @State private var armed = 0

    var body: some View {
        HStack(spacing: 4) {
            switch phase {
            case .idle:
                Pill(title: verb, style: .danger, help: question) {
                    phase = .confirming
                    caption = question
                    disarm(after: 6)
                }
            case .confirming:
                Pill(title: "confirm?", style: .dangerFilled, help: question) { run(primary) }
                Pill(title: "cancel") { reset() }
            case .working:
                ProgressView().controlSize(.mini).frame(width: 40)
            case .force:
                Pill(title: "force \(verb)", style: .dangerFilled) { run(force) }
                Pill(title: "cancel") { reset() }
            case .admin:
                Pill(title: "admin password…", style: .accentFilled,
                     help: "macOS asks for the password in its own window; \(AppInfo.name) never sees it.") { run(admin) }
                Pill(title: "cancel") { reset() }
            }
        }
    }

    private func reset() {
        phase = .idle
        caption = nil
    }

    /// Like Manfath's debounce: an unanswered "confirm?" goes back to "kill".
    private func disarm(after seconds: Double) {
        armed += 1
        let token = armed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if armed == token, phase == .confirming { reset() }
        }
    }

    private func run(_ action: @escaping () async -> ActionReport) {
        armed += 1
        phase = .working
        Task { @MainActor in
            let report = await action()
            switch report.result {
            case .stillRunning:
                phase = .force
                caption = report.message
            case .notPermitted:
                phase = .admin
                caption = report.message
            case .stopped, .gone:
                reset()
                Monitor.shared.flash(report.message)
            case .cancelled:
                reset()
            case .system, .failed:
                phase = .idle
                caption = report.message
            }
        }
    }
}
