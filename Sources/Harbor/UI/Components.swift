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

/// Manfath-style lowercase text action ("open", "kill", "confirm?").
struct Pill: View {
    enum Style { case plain, danger, dangerFilled, accentFilled }
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
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }

    private var foreground: Color {
        switch style {
        case .plain: return hovering ? .primary : .secondary
        case .danger: return hovering ? .red : .secondary
        case .dangerFilled, .accentFilled: return .white
        }
    }

    private var background: Color {
        switch style {
        case .plain: return Color.primary.opacity(hovering ? 0.12 : 0.07)
        case .danger: return hovering ? Color.red.opacity(0.14) : Color.primary.opacity(0.07)
        case .dangerFilled: return Color.red.opacity(hovering ? 1 : 0.88)
        case .accentFilled: return Color.accentColor.opacity(hovering ? 1 : 0.88)
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
