import Foundation

enum Level: Int, Comparable {
    case good, warn, bad
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct Verdict {
    let level: Level
    let headline: String
    let detail: String
    let symbol: String
}

enum SuggestionAction {
    case quitApp(AppGroup)
    case quitProcess(pid: pid_t, name: String, path: String?)
    case show(PageSection)
    case openActivityMonitor
}

struct Suggestion: Identifiable {
    let id: String
    let symbol: String
    let level: Level
    let title: String
    let detail: String
    let actionTitle: String?
    let action: SuggestionAction?
}

/// Plain-English verdict and the few concrete things worth doing.
extension Monitor {
    var verdict: Verdict {
        let m = memory
        let swap = Fmt.bytes(m.swapUsed)
        if zombies.alarm {
            let top = zombies.parents.first
            let detail = top.map { "\(Fmt.count(zombies.zombieCount)) stuck processes; \($0.name) holds \(Fmt.count($0.count))." }
                ?? "\(Fmt.count(zombies.zombieCount)) stuck processes."
            return Verdict(level: .bad, headline: "Too many stuck processes. New apps may fail to open.",
                           detail: detail, symbol: "exclamationmark.triangle.fill")
        }
        switch m.pressure {
        case .critical:
            return Verdict(level: .bad, headline: "Your Mac is out of memory, so everything is slow.",
                           detail: "Memory pressure is critical · \(swap) of swap in use.",
                           symbol: "exclamationmark.octagon.fill")
        case .warning:
            return Verdict(level: .warn, headline: "Your Mac is short on memory, so it may feel slow.",
                           detail: "Memory pressure is elevated · \(swap) of swap in use.",
                           symbol: "exclamationmark.circle.fill")
        case .normal:
            if m.swapIsHeavy {
                return Verdict(level: .warn, headline: "Your Mac is leaning on swap, so switching apps may lag.",
                               detail: "\(swap) of swap in use on \(Fmt.bytes(m.physical)) of RAM. Pressure is normal right now.",
                               symbol: "exclamationmark.circle.fill")
            }
            return Verdict(level: .good, headline: "Your Mac has enough memory.",
                           detail: "Memory pressure is normal · \(swap) of swap in use.",
                           symbol: "checkmark.circle.fill")
        }
    }

    func suggestions(limit: Int = 3) -> [Suggestion] {
        var out: [Suggestion] = []

        // 1. Zombies: the one that stopped this Mac launching anything.
        if zombies.alarm {
            if let p = zombies.parents.first, p.count > ZombieReport.perParentLimit {
                out.append(Suggestion(
                    id: "zombie-\(p.pid)", symbol: "arrow.triangle.branch", level: .bad,
                    title: "Quit \(p.name)",
                    detail: "It has \(Fmt.count(p.count)) stuck child processes. Quitting it lets macOS clear them.",
                    actionTitle: p.canQuit ? "Quit…" : nil,
                    action: p.canQuit ? .quitProcess(pid: p.pid, name: p.name, path: p.path) : nil))
            } else {
                out.append(Suggestion(
                    id: "zombie-total", symbol: "arrow.triangle.branch", level: .bad,
                    title: "\(Fmt.count(zombies.zombieCount)) stuck processes",
                    detail: "They're spread across many apps. If apps start failing to open, restart your Mac.",
                    actionTitle: "Show", action: .show(.leaks)))
            }
        }

        // 2. Memory: name the biggest apps.
        let memoryTight = memory.pressure != .normal || memory.swapIsHeavy
        let big = quittableApps.filter { $0.footprint >= 500 << 20 }
        if memoryTight {
            for (i, g) in big.prefix(2).enumerated() {
                let detail = i == 0
                    ? "\(g.name) is using \(Fmt.bytes(g.footprint)); quitting it would help most."
                    : "\(g.name) is using \(Fmt.bytes(g.footprint))."
                out.append(Suggestion(
                    id: "mem-\(g.id)", symbol: "memorychip", level: memory.pressure == .critical ? .bad : .warn,
                    title: "Quit \(g.name)", detail: detail,
                    actionTitle: "Quit…", action: .quitApp(g)))
            }
            if memory.pressure == .normal, memory.swapIsHeavy, big.isEmpty, lastFullScan != nil {
                out.append(Suggestion(
                    id: "swap-restart", symbol: "arrow.clockwise", level: .warn,
                    title: "Restart when it suits you",
                    detail: "\(Fmt.bytes(memory.swapUsed)) of swap is left over from earlier. No single app is to blame; a restart clears it.",
                    actionTitle: nil, action: nil))
            }
        }

        // 3. Runaway CPU.
        if let hot = quittableApps.filter({ ($0.cpu ?? 0) >= 80 }).max(by: { ($0.cpu ?? 0) < ($1.cpu ?? 0) }) {
            out.append(Suggestion(
                id: "cpu-\(hot.id)", symbol: "flame", level: .warn,
                title: "\(hot.name) is busy (\(Fmt.cpu(hot.cpu)) CPU)",
                detail: "That keeps the fans going and slows everything else. Quit it if you're not using it.",
                actionTitle: "Quit…", action: .quitApp(hot)))
        }

        // 4. Forgotten dev servers.
        let servers = visiblePorts
        if servers.count >= 5 {
            out.append(Suggestion(
                id: "ports", symbol: "network", level: .good,
                title: "\(servers.count) servers are listening",
                detail: "Stop the ones you're not using; each holds memory.",
                actionTitle: "Show", action: .show(.ports)))
        }

        return Array(out.prefix(limit))
    }
}
