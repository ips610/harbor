import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        // Manfath-style badge: the port count or a dot next to the icon.
        let count = monitor.badgeMode == "hidden" ? 0 : monitor.visiblePorts.count
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.image(for: monitor.iconState))
            if monitor.badgeMode == "count", count > 0 {
                Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
            } else if monitor.badgeMode == "dot", count > 0 {
                Text("•")
            }
        }
        .accessibilityLabel("\(AppInfo.name), \(count) ports")
    }
}

/// Manfath's "visible range": ports outside it are hidden.
struct PortRange: Identifiable {
    let lo: Int
    let hi: Int
    let title: String
    var id: String { "\(lo)-\(hi)" }

    static let presets = [
        PortRange(lo: 1024, hi: 65535, title: "1024–65535 (hide system ports)"),
        PortRange(lo: 1, hi: 65535, title: "All ports"),
        PortRange(lo: 3000, hi: 9999, title: "3000–9999 (typical dev servers)"),
        PortRange(lo: 1024, hi: 49151, title: "1024–49151 (skip ephemeral ports)"),
    ]
}

/// The menu bar dropdown, modelled on Manfath: what is listening on
/// localhost, in compact rows with open and kill. Memory and stuck-process
/// notes sit apart, below the list, and only take space when they matter.
struct MenuContent: View {
    @Environment(Monitor.self) private var monitor
    @State private var query = ""
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    private var grouping: Monitor.Grouping { monitor.grouping }

    var body: some View {
        @Bindable var monitor = monitor
        let rows = filteredRows
        VStack(spacing: 0) {
            header(count: monitor.visiblePorts.count)
            searchField.padding(.horizontal, 12).padding(.bottom, 8)
            // Same switch as on the page, and the same setting.
            Picker("Group", selection: $monitor.grouping) {
                ForEach(Monitor.Grouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if let notice = monitor.notices.last {
                NoticeStrip(notice: notice)
            }
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                // A plain VStack: ~20 rows don't need laziness, and it keeps the
                // scroll position steady while rows refresh.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections(rows), id: \.id) { section in
                            if grouping != .flat {
                                SectionTitle(title: section.title, count: section.rows.count,
                                             color: grouping == .project ? section.rows.first.map { Color(hex: $0.colorHex) } : nil)
                            }
                            ForEach(section.rows) { row in
                                PortLine(row: row, showTitle: grouping != .project)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.top)
                .frame(maxHeight: 430)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HealthFooter()
            footer
        }
        .frame(width: 400)
        .overlay(alignment: .bottom) { ToastView() }
        .background(WindowVisibilityReporter(surface: .menu))
    }

    // MARK: Pieces

    private func header(count: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Listening on localhost").font(.system(size: 13, weight: .semibold))
                Text(meta(count)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button { monitor.requestFullScan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .focusEffectDisabled()
                .help("Refresh now (⌘R)")
            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private func meta(_ count: Int) -> String {
        var ports = count == 1 ? "1 port" : "\(count) ports"
        if monitor.minPort != 1024 || monitor.maxPort != 65535 { ports += " in \(monitor.minPort)–\(monitor.maxPort)" }
        guard let t = monitor.lastFullScan else { return "\(ports) · scanning…" }
        let ago = max(0, Int(Date().timeIntervalSince(t)))
        return "\(ports) · last scan \(ago)s ago"
    }

    private var settingsMenu: some View {
        @Bindable var monitor = monitor
        return Menu {
            Menu("Visible range: \(monitor.minPort)–\(monitor.maxPort)") {
                ForEach(PortRange.presets) { r in
                    Button {
                        monitor.setRange(r.lo, r.hi)
                    } label: {
                        if monitor.minPort == r.lo && monitor.maxPort == r.hi {
                            Label(r.title, systemImage: "checkmark")
                        } else {
                            Text(r.title)
                        }
                    }
                }
                Divider()
                Button("Custom range on the page…") { WebServer.shared.openInBrowser() }
            }
            Toggle("Only dev servers, databases and runtimes", isOn: $monitor.onlyServers)
            Toggle("Show macOS services", isOn: $monitor.showSystemPorts)
            if !monitor.blocklist.isEmpty {
                Menu("Hidden processes (\(monitor.blocklist.count))") {
                    ForEach(monitor.blocklist, id: \.self) { name in
                        Button("Show \(name) again") { monitor.blocklist.removeAll { $0 == name } }
                    }
                }
            }
            Divider()
            Picker("Refresh while open", selection: $monitor.refreshInterval) {
                Text("Every 1 second").tag(1.0)
                Text("Every 3 seconds").tag(3.0)
                Text("Every 10 seconds").tag(10.0)
                Text("Manual only").tag(0.0)
            }
            Picker("Menu bar badge", selection: $monitor.badgeMode) {
                Text("Count").tag("count")
                Text("Dot").tag("dot")
                Text("Hidden").tag("hidden")
            }
            Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { setLoginItem($0) }))
            Divider()
            Button("Open \(AppInfo.name) page") { WebServer.shared.openInBrowser() }
            Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Search ports, processes, PIDs…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(query.isEmpty ? "No services listening" : "No matches")
                .font(.system(size: 13, weight: .medium))
            Text(query.isEmpty ? "Start a dev server and it'll show up here." : "Try a port number, a process name or a PID.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Button("Open \(AppInfo.name)…") { WebServer.shared.openInBrowser() }
                .buttonStyle(.borderless)
                .keyboardShortcut("o")
            Spacer()
            Text(scanLabel)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scanLabel: String {
        switch monitor.refreshInterval {
        case 0: return "Manual scan only"
        case 1: return "Scanning every 1s"
        case 10: return "Scanning every 10s"
        default: return "Scanning every 3s"
        }
    }

    // MARK: Data

    private var filteredRows: [PortRow] {
        let rows = monitor.visiblePorts
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { r in
            String(r.port).hasPrefix(q) || String(r.pid) == q
                || r.processName.lowercased().contains(q) || r.title.lowercased().contains(q)
                || (r.framework?.lowercased().contains(q) ?? false)
                || (r.command?.lowercased().contains(q) ?? false)
        }
    }

    private struct MenuSection {
        let title: String
        let rows: [PortRow]
        var id: String { (rows.first?.groupKey ?? "") + title }
    }

    private func sections(_ rows: [PortRow]) -> [MenuSection] {
        switch grouping {
        case .flat:
            return [MenuSection(title: "All", rows: rows.sorted { $0.port < $1.port })]
        case .category:
            return PortCategory.allCases.compactMap { c in
                let rs = rows.filter { $0.category == c }.sorted { $0.port < $1.port }
                return rs.isEmpty ? nil : MenuSection(title: c.title, rows: rs)
            }
        case .project:
            // Like the page's cards: projects, then plain folders, then apps.
            let groups = Dictionary(grouping: rows) { $0.groupKey }
            func rank(_ r: PortRow) -> Int { r.projectRoot != nil ? 0 : r.projectFolder != nil ? 1 : 2 }
            return groups.values
                .map { rs in MenuSection(title: rs[0].title, rows: rs.sorted { $0.port < $1.port }) }
                .sorted { a, b in
                    let ra = rank(a.rows[0]), rb = rank(b.rows[0])
                    if ra != rb { return ra < rb }
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            monitor.flash(error.localizedDescription)
        }
        loginItem = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            monitor.flash("Approve \(AppInfo.name) in System Settings → General → Login Items.")
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int
    var color: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

/// One listening port: `:3000  project  [Next.js]  …  open  kill`.
private struct PortLine: View {
    @Environment(Monitor.self) private var monitor
    let row: PortRow
    let showTitle: Bool
    @State private var hovering = false
    @State private var expanded = false
    @State private var caption: String?
    @State private var shareNote: String?
    @State private var showQR = false

    var body: some View {
        let tunnel = Tunnels.shared.active[row.port]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The project's colour, the same as on the page. Text stays in normal colours.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: row.colorHex))
                    .frame(width: 3, height: 26)
                Text(verbatim: ":\(row.port)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(showTitle ? row.title : row.processName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        if let fw = row.framework, fw != row.title {
                            FrameworkTag(text: fw)
                        }
                        if tunnel != nil {
                            Text("shared")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .foregroundStyle(Tone.sharedInk)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Tone.shared))
                        }
                        if row.scope == .all {
                            Image(systemName: "dot.radiowaves.up.forward")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Listening on all interfaces: other devices on your network can reach it.")
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Pill(title: "open", style: .open, help: "Open \(row.url.absoluteString)") { Engine.open(row) }
                if !(row.isSystem || row.isSelf) {
                    ShareControl(row: row, note: $shareNote)
                }
                if !(row.isSystem || row.isSelf) {
                    StopControl(
                        verb: "kill",
                        question: question,
                        primary: { await Engine.stop(pid: row.pid, workers: row.workerPids, name: row.processName, path: row.path, label: label) },
                        force: { await Engine.force(pid: row.pid, workers: row.workerPids, name: row.processName, path: row.path, label: label) },
                        admin: { await Engine.admin(pid: row.pid, name: row.processName, path: row.path) },
                        caption: $caption
                    )
                }
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 77)
            }
            if let shareNote {
                Text(shareNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 77)
            }
            if let tunnel { tunnelLine(tunnel).padding(.leading, 77) }
            if expanded { details.padding(.leading, 77) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering || expanded ? Color.primary.opacity(0.06) : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
        .contextMenu {
            Button("Open \(row.url.absoluteString)") { Engine.open(row) }
            Button("Copy URL") { Engine.copyURL(row); monitor.flash("Copied \(row.url.absoluteString)") }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(row.pid), forType: .string)
            }
            if let folder = row.folder { Button("Reveal in Finder") { Engine.reveal(folder) } }
            Divider()
            Button("Hide processes named \(row.processName)") { monitor.hideProcess(row.processName) }
        }
    }

    private var label: String { "\(row.processName) on :\(row.port)" }

    @ViewBuilder
    private func tunnelLine(_ t: Tunnels.Tunnel) -> some View {
        switch t.phase {
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Opening a public link with \(t.provider)…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red)
        case .ready(let url):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tone.shareInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Pill(title: "copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        monitor.flash("Copied \(url)")
                    }
                    Pill(title: showQR ? "hide qr" : "qr") { showQR.toggle() }
                }
                if showQR, let cg = Tunnels.shared.qr(url) {
                    Image(decorative: cg, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .padding(6)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .help("Scan with your phone camera")
                }
            }
        }
    }

    private var question: String {
        let folder = row.folder.map(Fmt.path) ?? "no project folder"
        let workers = row.workers > 0 ? " and its \(row.workers) worker\(row.workers == 1 ? "" : "s")" : ""
        return "Stop \(row.processName) (pid \(row.pid))\(workers) on :\(row.port), in \(folder)?"
    }

    private var subtitle: String {
        var parts: [String] = []
        if showTitle && row.title != row.processName { parts.append(row.processName) }
        parts.append("pid \(row.pid)")
        if row.workers > 0 { parts[parts.count - 1] += " +\(row.workers)" }
        if row.started != nil { parts.append("up \(Fmt.uptime(since: row.started))") }
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let folder = row.folder {
                DetailLine(label: "Folder", value: Fmt.path(folder)) {
                    Pill(title: "reveal") { Engine.reveal(folder) }
                }
            }
            if let cmd = row.command {
                DetailLine(label: "Command", value: cmd) { EmptyView() }
            }
            DetailLine(label: "Address", value: row.scope == .all ? "all interfaces" : row.addresses.joined(separator: ", ")) {
                EmptyView()
            }
            if let m = row.footprint {
                DetailLine(label: "Memory", value: Fmt.bytes(m)) { EmptyView() }
            }
            DetailLine(label: "URL", value: row.url.absoluteString) {
                Pill(title: "copy") {
                    Engine.copyURL(row)
                    monitor.flash("Copied \(row.url.absoluteString)")
                }
            }
            if let hint = row.hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Manfath's tunnel pill: "share" → confirm with plain words → public link.
private struct ShareControl: View {
    let row: PortRow
    @Binding var note: String?
    @State private var confirming = false
    @State private var armed = 0

    var body: some View {
        if let t = Tunnels.shared.active[row.port] {
            if t.phase == .starting {
                Pill(title: "sharing…") {}
            } else {
                Pill(title: "unshare", style: .danger, help: "Stop sharing :\(row.port)") {
                    Tunnels.shared.stop(row.port)
                    note = nil
                }
            }
        } else if confirming {
            Pill(title: "share", style: .go) {
                confirming = false
                note = Tunnels.shared.start(row)
            }
            Pill(title: "cancel") { confirming = false; note = nil }
        } else {
            Pill(title: "share", style: .share, help: "Get a public link for :\(row.port)") {
                guard Tunnels.tool != nil else {
                    note = "\(Tunnels.hint.text) \(Tunnels.hint.command)"
                    return
                }
                confirming = true
                note = "Anyone with the link can open \(row.title) on port \(row.port) until you stop sharing."
                armed += 1
                let token = armed
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if armed == token, confirming { confirming = false; note = nil }
                }
            }
        }
    }
}

private struct DetailLine<Trailing: View>: View {
    let label: String
    let value: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            trailing
        }
    }
}

private struct FrameworkTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
    }
}

private struct NoticeStrip: View {
    @Environment(Monitor.self) private var monitor
    let notice: Monitor.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
            Text(notice.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { monitor.dismissNotice(notice.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(.system(size: 9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }
}

/// The extras, kept apart from the ports: one line about memory, plus a
/// stuck-process warning only when it matters.
private struct HealthFooter: View {
    @Environment(Monitor.self) private var monitor
    @State private var caption: String?

    var body: some View {
        let v = monitor.verdict
        VStack(alignment: .leading, spacing: 4) {
            if monitor.zombies.alarm, let p = monitor.zombies.parents.first {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("\(p.name) holds \(Fmt.count(p.count)) stuck processes")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if p.canQuit {
                        StopControl(
                            verb: "quit",
                            question: "Quit \(p.name) (pid \(p.pid))? macOS then clears its stuck processes.",
                            primary: {
                                await Engine.quit(pid: p.pid, bundlePath: p.path.flatMap(LibProc.appBundle(forExecutable:)),
                                                  name: p.name, path: p.path)
                            },
                            force: { await Engine.force(pid: p.pid, name: p.name, path: p.path, label: p.name) },
                            admin: { await Engine.admin(pid: p.pid, name: p.name, path: p.path) },
                            caption: $caption
                        )
                    }
                }
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(v.level.color).frame(width: 7, height: 7)
                Text(memoryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var memoryLine: String {
        let m = monitor.memory
        var s = "Memory \(Fmt.bytes(m.used)) of \(Fmt.bytes(m.physical)) · swap \(Fmt.bytes(m.swapUsed))"
        if m.pressure != .normal { s += " · pressure \(m.pressure.label.lowercased())" }
        return s
    }
}
