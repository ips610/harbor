import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        // Manfath-style badge: the port count or a dot next to the icon.
        let count = monitor.badgeCount  // changes only when the number does
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
    // With keyboard navigation on, the window's first control opens highlighted;
    // start in the search field instead, so typing filters straight away.
    @FocusState private var searchFocused: Bool
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    private var grouping: Monitor.Grouping { monitor.grouping }

    /// Solid near-black in dark mode, like the page's panels: the see-through menu material let
    /// the wallpaper tint the list. Light mode keeps the normal window colour.
    private static let backdrop = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: "#121215") : .windowBackgroundColor
    })
    private var updates: Updates { .shared }

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
            if updates.newer, let latest = updates.latest {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("\(AppInfo.name) \(latest) is out").font(.system(size: 12))
                    Spacer()
                    Button("Get it") { updates.download() }.controlSize(.small)
                    // Beside the link, where harbor can hold a download to its own signing key (see Updater).
                    if updates.canUpdateNow {
                        Button(updates.updating ? "Updating…" : "Update now") { askUpdate(latest) }.controlSize(.small).disabled(updates.updating)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, updates.updateProblem == nil ? 8 : 2)
                if let problem = updates.updateProblem {
                    Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
            Divider()
            if rows.isEmpty {
                emptyState
                stoppedRows       // nothing is listening: all the more reason to show what stopped
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
                    stoppedRows
                }
                .defaultScrollAnchor(.top)
                .frame(maxHeight: DebugCLI.menuHeight ?? 430)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HealthFooter()
            footer
        }
        .frame(width: 400)
        .background(Self.backdrop)
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
            updates.check()  // at most once a day
        }
        .overlay(alignment: .bottom) { ToastView() }
        .background(WindowVisibilityReporter(surface: .menu))
        .background(WindowAppearance(appearance: monitor.appearance.nsAppearance))
    }

    // MARK: Pieces

    private func header(count: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Listening on localhost").font(.system(size: 13, weight: .semibold))
                Text(meta(count)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Text(networkLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                // Only when harbor had to move off its usual port, or port 80 isn't its door's.
                ForEach(monitor.portNotes, id: \.self) { note in
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
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

    /// "On your network: 172.17.131.1 · Name.local", like Manfath's network address.
    private var networkLine: String {
        guard let ip = monitor.lanIP else { return "Not on a network" }
        return "On your network: " + ([ip] + [monitor.lanName].compactMap { $0 }).joined(separator: " · ")
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
                Text("Every 5 seconds").tag(5.0)
                Text("Every 15 seconds").tag(15.0)
                Text("Every 30 seconds").tag(30.0)
                Text("Every minute").tag(60.0)
                if !Monitor.presetIntervals.contains(monitor.refreshInterval) {
                    Text("Every \(Int(monitor.refreshInterval)) seconds (custom)").tag(monitor.refreshInterval)
                }
                Text("Manual only").tag(0.0)
            }
            Button("Custom interval…") { askCustomInterval() }
            Picker("Menu bar badge", selection: $monitor.badgeMode) {
                Text("Count").tag("count")
                Text("Dot").tag("dot")
                Text("Hidden").tag("hidden")
            }
            Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { setLoginItem($0) }))
            Toggle("Show in Dock", isOn: $monitor.showInDock)
            // For this dropdown only; the page has its own. The menu bar icon always follows macOS.
            Picker("Appearance", selection: $monitor.appearance) {
                ForEach(Monitor.Appearance.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button(updates.checking ? "Checking for Updates…" : "Check for Updates…") {
                updates.check(force: true) { monitor.flash(updates.summary) }
            }
            .disabled(updates.checking)
            Text("\(AppInfo.name) \(updates.current)")
            Button("\(AppInfo.name) on GitHub") { NSWorkspace.shared.open(Updates.home) }
            // harbor ls, kill and open in Terminal: a link to this app on the PATH, put there or taken away again.
            Button(CommandLink.installed() == nil ? "Install the harbor command…" : "Remove the harbor command…") { askCommand() }
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
                .focused($searchFocused)
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("o")
            Spacer()
            Text(scanLabel)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scanLabel: String {
        switch monitor.refreshInterval {
        case 0: return "Manual scan only"
        case 60: return "Scanning every minute"
        default: return "Scanning every \(Int(monitor.refreshInterval))s"
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
                || (monitor.nameHost(r)?.contains(q) ?? false)
        }
    }

    private struct MenuSection {
        let title: String
        let rows: [PortRow]
        var id: String { (rows.first?.groupKey ?? "") + title }
    }

    /// Servers that stopped, each with a way to start it again as it was.
    @ViewBuilder
    private var stoppedRows: some View {
        if !monitor.stopped.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Stopped", count: monitor.stopped.count, color: nil)
                ForEach(monitor.stopped) { entry in
                    HStack(spacing: 8) {
                        Text(verbatim: ":\(entry.port)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                            .padding(.leading, 12)      // in line with the ports above, which have a coloured bar before them
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: entry.name).font(.system(size: 13)).lineLimit(1)
                            Text(verbatim: entry.note ?? Restart.command(entry.launch)).font(.system(size: 11)).foregroundStyle(entry.note == nil ? Color.secondary : Color.orange)
                                .lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if let log = entry.log { Pill(title: "log", help: "Show what it printed") { NSWorkspace.shared.open(log) } }
                        Pill(title: "start again", style: .open, help: "Run it again, as it was started") { askStartAgain(entry) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Shows the command and the folder, and starts it on a yes.
    private func askStartAgain(_ entry: Restart.Stopped) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        alert.messageText = "Start \(entry.name) again?"
        alert.informativeText = Restart.question(entry)
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitor.flash(monitor.startAgain(entry.id).message)
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
            func rank(_ r: PortRow) -> Int { r.projectRoot != nil ? 0 : r.projectFolder != nil || r.container?.project != nil ? 1 : 2 }
            return groups.values
                .map { rs in MenuSection(title: rs[0].groupTitle, rows: rs.sorted { $0.port < $1.port }) }
                .sorted { a, b in
                    let ra = rank(a.rows[0]), rb = rank(b.rows[0])
                    if ra != rb { return ra < rb }
                    let t = a.title.localizedCaseInsensitiveCompare(b.title)
                    // Two folders can share a name ("web"): the lower port first, so the order holds.
                    return t == .orderedSame ? a.rows[0].port < b.rows[0].port : t == .orderedAscending
                }
        }
    }

    /// Whole seconds, 5 to 3600. Lower is raised to 5, higher capped at 3600.
    private func askCustomInterval() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        alert.messageText = "Scan every how many seconds?"
        alert.informativeText = "While the menu or the page is open. Whole seconds, from 5 to 3600."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = monitor.refreshInterval > 0 ? String(Int(monitor.refreshInterval)) : "15"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let typed = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), typed > 0 else { return }
        let value = Monitor.clampInterval(typed)
        monitor.refreshInterval = value
        if typed < 5 { monitor.flash("Raised to 5 seconds, the shortest interval.") }
        else if typed > 3600 { monitor.flash("Capped at 3600 seconds (one hour).") }
    }

    /// Says what an update does (and what ends with it), and starts it on a yes.
    private func askUpdate(_ latest: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        alert.messageText = "Update \(AppInfo.name) to \(latest)?"
        alert.informativeText = Updates.updateQuestion(version: latest, sharing: !monitor.lanShares.isEmpty || !Tunnels.shared.active.isEmpty)
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let why = updates.updateNow() { monitor.flash(why) }
    }

    /// Says exactly what will be done, does it on a yes, and says what was done.
    private func askCommand() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        let installed = CommandLink.installed()
        if let installed {
            alert.messageText = "Remove the harbor command?"
            alert.informativeText = "\(Fmt.path(installed)) is a link to this app. Without it Terminal no longer has harbor ls, kill and open; the app itself stays as it is."
        } else {
            alert.messageText = "Install the harbor command?"
            alert.informativeText = "A link to this app goes into /usr/local/bin, or into ~/.local/bin when that one can't be written to. No administrator password. After that Terminal has harbor ls, harbor kill <port> and harbor open <port or name>."
        }
        alert.addButton(withTitle: installed == nil ? "Install" : "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitor.notify(installed == nil ? CommandLink.install().note : CommandLink.remove())
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            monitor.flash(error.localizedDescription)
        }
        loginItem = SMAppService.mainApp.status == .enabled
        WebAPI.loginItemCache = nil
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
    @State private var showLAN = false
    @State private var showPassword = false
    /// "For how long?" is being asked: for a public link, or for the network.
    @State private var choosingShare = false
    @State private var choosingNetwork = false

    var body: some View {
        let tunnel = Tunnels.shared.active[row.port]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The project's colour, the same as on the page. Text stays in normal colours.
                // Square-ish ends: a full capsule this thin reads soft, like a glow, on the menu's glass.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(hex: row.colorHex))
                    .frame(width: 3, height: 26)
                Text(verbatim: ":\(row.port)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        let name = Text(verbatim: showTitle ? row.title : row.label).font(.system(size: 13)).lineLimit(1)
                        // The framework tag only when it fits whole; otherwise just the name.
                        if let fw = row.framework, fw != row.title {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 5) { name; FrameworkTag(text: fw).fixedSize() }
                                name
                            }
                        } else {
                            name
                        }
                        if row.isSystem {
                            FrameworkTag(text: "macOS", filled: true, symbol: "desktopcomputer").fixedSize().help("A macOS service")
                        }
                        if tunnel != nil {
                            Text("shared")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .foregroundStyle(Tone.sharedInk)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Tone.shared))
                                .fixedSize()
                        }
                        if row.scope == .all {
                            Image(systemName: "dot.radiowaves.up.forward")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Listening on all interfaces: other devices on your network can reach it.")
                        }
                    }
                    HStack(spacing: 0) {
                        // Where other devices reach it (click to copy), or "this Mac only". On the
                        // network under its name: a tag in orange, like every other sign that the
                        // network can reach something. It sits here because the line above has no room.
                        if let link = monitor.networkLink(row) {
                            Button { Engine.copy(link); monitor.flash("Copied \(link)") } label: {
                                Text("on network")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .foregroundStyle(.orange)
                                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .help("Copy \(link)")
                            .fixedSize()
                        } else if let net = row.networkAddress(ip: monitor.lanIP) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("http://\(net)", forType: .string)
                                monitor.flash("Copied http://\(net)")
                            } label: { Text(net).foregroundStyle(Tone.openInk) }
                            .buttonStyle(.plain)
                            .help("Copy http://\(net)")
                            .fixedSize()
                        } else {
                            Text(row.onNetwork ? "not on a network" : "this Mac only").fixedSize()
                        }
                        Text(" · " + subtitle).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Pill(title: "open", style: .open, help: "Open \(monitor.address(row).absoluteString)") { Engine.open(row) }
                if !(row.isSystem || row.isSelf) {
                    Button { showLAN.toggle() } label: { Image(systemName: "qrcode") }
                        .buttonStyle(.borderless)
                        .help(row.lanReachable ? "Open it on another device on this network" : "Open it on your phone")
                        .popover(isPresented: $showLAN, arrowEdge: .bottom) { LANCard(row: row) }
                }
                if !(row.isSystem || row.isSelf) {
                    ShareControl(row: row, note: $shareNote, choosing: $choosingShare)
                }
                // Not for a container either: the process on its port is Docker itself (the details say so).
                if !(row.isSystem || row.isSelf || Docker.owns(path: row.path)) {
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
            // Its name, storefront.localhost (click to copy), on a line of its own under the row,
            // where a long one fits; :port on the left stays the plain address.
            if let host = monitor.nameHost(row) {
                let name = Button {
                    Engine.copyURL(row)
                    monitor.flash("Copied http://\(host)/")
                } label: { Text(host).foregroundStyle(Tone.openInk).lineLimit(1).truncationMode(.middle) }
                .buttonStyle(.plain)
                .help("Copy http://\(host)/")
                // The plain address beside it when both fit; otherwise just the name.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        name
                        Text(" · " + row.url.absoluteString.replacingOccurrences(of: "http://", with: "")).foregroundStyle(.secondary).fixedSize()
                    }
                    name
                }
                .font(.system(size: 11))
                .padding(.leading, 77)
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
            if choosingShare {
                // How long the public link lasts: one click on a choice starts it. The one made last time is marked.
                HStack(spacing: 6) {
                    ForEach(Lasting.choices, id: \.self) { seconds in
                        Pill(title: Lasting.title(seconds), style: seconds == Lasting.remembered(.link) ? .go : .plain) {
                            choosingShare = false
                            shareNote = Tunnels.shared.start(row, for: seconds)
                        }
                    }
                }
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
        .onAppear {
            guard DebugCLI.expandPort == row.port else { return }
            expanded = true
            // For a snapshot of the "for how long?" choices.
            choosingShare = DebugCLI.choosing == "share"
            choosingNetwork = DebugCLI.choosing == "network"
            if choosingShare { shareNote = "Anyone with the link can open \(row.title) on port \(row.port). For how long?" }
        }
        // Its details are open: now, and only now, is its server asked what it serves.
        .onChange(of: expanded, initial: true) { _, open in if open { monitor.look(at: [row.id]) } }
        .contextMenu {
            Button("Open \(monitor.address(row).absoluteString)") { Engine.open(row) }
            Button("Copy URL") { Engine.copyURL(row); monitor.flash("Copied \(monitor.address(row).absoluteString)") }
            if monitor.nameHost(row) != nil {
                Button("Copy \(row.url.absoluteString)") {
                    Engine.copy(row.url.absoluteString)
                    monitor.flash("Copied \(row.url.absoluteString)")
                }
                Button("Rename…") { askRename() }
            }
            if monitor.isNetworkRow(row), let name = monitor.networkName(row) {
                Divider()
                if let link = monitor.networkLink(row) {
                    Button("Copy \(link)") { Engine.copy(link); monitor.flash("Copied \(link)") }
                    Button("Network Password…") { askNetworkPassword() }
                    Button("Turn Off \(name)\(Lan.suffix)") { monitor.stopSharing(row.id) }
                } else {
                    // The same way in as "turn on": its details open, asking for how long first.
                    Button("Put on Network as \(name)\(Lan.suffix)…") { expanded = true; choosingNetwork = true }
                }
                Button("Rename on Network…") { askNetworkName() }
                if monitor.hasSiblings(row), !monitor.isMain(row) { Button("Make This the Main Server") { makeMain() } }
                Divider()
            }
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

    /// On network: the project as `<name>.local` for other devices on this Wi-Fi. Off: the
    /// switch and the name it would have. On: its link, its password, and a QR for a phone.
    @ViewBuilder
    private func network(_ name: String) -> some View {
        let key = Names.key(row)
        if let link = monitor.networkLink(row) {
            DetailLine(label: Lan.suffix, value: link) {
                Pill(title: "copy") { Engine.copy(link); monitor.flash("Copied \(link)") }
            }
            HStack(spacing: 6) {
                Pill(title: "rename") { askNetworkName() }
                Pill(title: "turn off", style: .danger) { monitor.stopSharing(row.id); showPassword = false }
            }
            .padding(.leading, 58)
            if let left = Lasting.left(monitor.lanShares[row.id]?.until, now: Date()) {
                DetailLine(label: "Stays on", value: left) {
                    Pill(title: "+30 min", help: "Half an hour more") { monitor.moreTime(row) }
                }
            }
            DetailLine(label: "Password", value: monitor.lanShares[row.id]?.hasPassword == true
                       ? (showPassword ? monitor.networkPassword(key) ?? "" : "••••••••") : "none: anyone on this Wi-Fi can open it") {
                if monitor.lanShares[row.id]?.hasPassword == true { Pill(title: showPassword ? "hide" : "show") { showPassword.toggle() } }
                Pill(title: "change") { askNetworkPassword() }
            }
            if let share = monitor.lanShares[row.id] {
                // Whose password it is and who is in; and, with another of the project's servers on the network, how a page reaches this one.
                if share.hasPassword, let note = Lan.passwordNote(project: monitor.names.base[key] ?? row.title, several: monitor.hasSiblings(row), devices: monitor.devices(row)) {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if monitor.lanShares.contains(where: { $0.key != row.id && $0.value.project == key }) {
                    Text(Lan.callByName).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let share = monitor.lanShares[row.id], share.isUnannounced {
                Text(Lan.notAnnounced(share.name)).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            codeStack
            Text(Lan.plainHttp)
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(Lan.systemAsks(firewall: LAN.firewallOn))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            // Its name for other devices on this network, and the switch. The pills get their own
            // line: beside a name they would squeeze it into two.
            DetailLine(label: Lan.suffix, value: "\(name)\(Lan.suffix)  ·  off") { EmptyView() }
            HStack(spacing: 6) {
                if choosingNetwork {
                    // How long it stays on the network, then (when the project has none yet) its password.
                    ForEach(Lasting.choices, id: \.self) { seconds in
                        Pill(title: Lasting.title(seconds), style: seconds == Lasting.remembered(.network) ? .go : .plain) {
                            choosingNetwork = false
                            askShare(lasting: seconds)
                        }
                    }
                    Pill(title: "cancel") { choosingNetwork = false }
                } else {
                    Pill(title: "turn on", style: .open, help: "Other devices on this Wi-Fi open it at http://\(name)\(Lan.suffix)/") { choosingNetwork = true }
                    Pill(title: "rename", help: "Change its name on the network") { askNetworkName() }
                }
            }
            .padding(.leading, 58)
        }
    }

    /// One question with a text field, in harbor's look. nil when cancelled.
    private func ask(_ title: String, _ text: String, value: String, yes: String, other: String? = nil) -> (answer: String, other: Bool)? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: "Cancel")
        if let other { alert.addButton(withTitle: other) }
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (field.stringValue, false)
        case .alertThirdButtonReturn: return (field.stringValue, true)
        default: return nil
        }
    }

    private func confirm(_ title: String, _ text: String, yes: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Turning it on: with the password it has, or one suggested here to keep, change or do without.
    private func askShare(lasting: Int? = nil) {
        let key = Names.key(row)
        guard let name = monitor.networkName(row) else { return }
        var problem: String?
        if monitor.hasNetworkPassword(key) {
            problem = monitor.shareOnNetwork(row, lasting: lasting)
        } else if let choice = ask("Put \(name)\(Lan.suffix) on your network?",
                                   "Other devices on this Wi-Fi open it with this password. Keep it, or type your own (at least \(Lan.minPassword) characters).",
                                   value: Lan.randomPassword(), yes: "Share", other: "No Password…") {
            if !choice.other {
                problem = monitor.shareOnNetwork(row, password: choice.answer, lasting: lasting)
            } else if confirm("Share without a password?", monitor.anyoneCanOpen(row), yes: "Share") {
                problem = monitor.shareOnNetwork(row, open: true, lasting: lasting)
            } else {
                return
            }
        } else {
            return
        }
        monitor.flash(problem ?? "\(monitor.networkLink(row) ?? name) is on your network.")
    }

    private func askNetworkName() {
        guard let name = monitor.networkName(row),
              let typed = ask("Rename \(name)\(Lan.suffix)", "Its name for other devices on this network. Lowercase letters, numbers and hyphens, up to \(Names.maxLength). Leave it empty to use its .localhost name.",
                              value: name, yes: "Rename") else { return }
        if let problem = monitor.renameOnNetwork(row, to: typed.answer) { monitor.flash(problem) }
    }

    /// A new password, typed or random as offered; or none at all, after being asked.
    private func askNetworkPassword() {
        guard let name = monitor.networkName(row),
              let choice = ask("Password for \(name)\(Lan.suffix)", "At least \(Lan.minPassword) characters. Everyone who is signed in signs in again.",
                               value: Lan.randomPassword(), yes: "Change", other: "No Password…") else { return }
        if choice.other, !confirm("Remove the password?", monitor.anyoneCanOpen(row), yes: "Remove") { return }
        if let problem = monitor.setNetworkPassword(row, choice.other ? nil : choice.answer) { monitor.flash(problem) }
    }

    /// This server becomes the one its project's plain name opens. What the project has on the network comes off it (said in a notice).
    private func makeMain() {
        if let problem = monitor.makeMain(row) { monitor.flash(problem) }
        else { monitor.flash("\(monitor.names.base[Names.key(row)] ?? row.title)\(Names.suffix) opens port \(row.port) now.") }
    }

    /// A new name for the row's project, the part before .localhost. Empty goes back to the automatic one.
    private func askRename() {
        guard let current = monitor.names.base[Names.key(row)] else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.window.appearance = monitor.appearance.nsAppearance
        alert.messageText = "Rename \(current)\(Names.suffix)"
        alert.informativeText = "Lowercase letters, numbers and hyphens, up to \(Names.maxLength). Leave it empty to go back to the automatic name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = monitor.rename(row, to: field.stringValue) { monitor.flash(problem) }
        else if let host = monitor.nameHost(row) { monitor.flash("It's \(host) now.") }
    }

    @ViewBuilder
    private func tunnelLine(_ t: Tunnels.Tunnel) -> some View {
        let both = expanded && monitor.codes(row).count == 2
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
                    // With the details open and another code in them, this one is there too, beside it: both at once.
                    if !both { Pill(title: showQR ? "hide qr" : "qr") { showQR.toggle() } }
                }
                if let left = Lasting.left(t.until, now: Date()) {
                    HStack(spacing: 6) {
                        Text(verbatim: "Public link · \(left)").font(.system(size: 11)).foregroundStyle(.secondary)
                        Pill(title: "+30 min", help: "Half an hour more") { Tunnels.shared.more(row.port) }
                    }
                }
                if showQR, !both { QRCode(text: url).frame(maxWidth: .infinity) }
            }
        }
    }

    /// The row's codes, together in the middle of its details: one under the other on one
    /// centre line, each named above when there are two. One alone sits on the same line.
    private var codeStack: some View {
        let codes = monitor.codes(row)
        return VStack(spacing: 6) {
            ForEach(codes, id: \.link) { code in
                if codes.count > 1 { Text(code.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                QRCode(text: code.link)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var question: String {
        let folder = row.folder.map(Fmt.path) ?? "no project folder"
        let workers = row.workers > 0 ? " and its \(row.workers) worker\(row.workers == 1 ? "" : "s")" : ""
        return "Stop \(row.processName) (pid \(row.pid))\(workers) on :\(row.port), in \(folder)?"
    }

    private var subtitle: String {
        var parts: [String] = []
        if showTitle && row.title != row.label { parts.append(row.label) }
        parts.append("pid \(row.pid)")
        if row.workers > 0 { parts[parts.count - 1] += " +\(row.workers)" }
        if row.started != nil { parts.append("up \(Fmt.uptime(since: row.started))") }
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = row.container {
                DetailLine(label: "Container", value: c.name) { EmptyView() }
                if !c.image.isEmpty { DetailLine(label: "Image", value: c.image) { EmptyView() } }
                if let project = c.project { DetailLine(label: "Compose", value: project + (c.service.map { " / " + $0 } ?? "")) { EmptyView() } }
            }
            if Docker.owns(path: row.path) {
                Text(verbatim: Docker.noKill(row.container)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                    Engine.copy(row.url.absoluteString)
                    monitor.flash("Copied \(row.url.absoluteString)")
                }
            }
            if let answer = monitor.served[row.id] {
                DetailLine(label: "Serves", value: answer.line) { EmptyView() }
            }
            if !(row.isSystem || row.isSelf) {
                // The bell: tell me when this one server stops.
                let watching = monitor.isWatched(row)
                HStack(spacing: 6) {
                    Image(systemName: watching ? "bell.fill" : "bell").font(.system(size: 10)).foregroundStyle(watching ? Tone.openInk : .secondary)
                    Text(verbatim: watching ? "A notification when it stops" : "Tell me when it stops").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Pill(title: watching ? "watching" : "tell me", style: watching ? .open : .plain, help: watching ? "Stop watching this server" : "A notification when this server stops") {
                        monitor.setWatch(row, !watching)
                    }
                }
            }
            if let log = monitor.log(for: row) {
                DetailLine(label: "Output", value: Fmt.path(log.path)) {
                    Pill(title: "show log", help: "\(AppInfo.name) started it, so it has no Terminal") { NSWorkspace.shared.open(log) }
                }
            }
            let canShare = monitor.isNetworkRow(row), shared = monitor.lanShares[row.id] != nil
            // Its two names, one above the other, each with its own rename: on this Mac, and on the network.
            if let host = monitor.nameHost(row) {
                DetailLine(label: Names.suffix, value: host) {
                    Pill(title: "rename", help: "Change its .localhost name") { askRename() }
                }
                // Another of the project's servers can be made the one its plain name opens. On its
                // own line: two pills beside a name squeeze it into two.
                if monitor.hasSiblings(row), !monitor.isMain(row) {
                    Pill(title: "make main", help: "\(monitor.names.base[Names.key(row)] ?? "The project's name")\(Names.suffix) would open this server. What the project has on the network comes off it.") { makeMain() }
                        .padding(.leading, 58)
                }
            }
            if canShare, let name = monitor.networkName(row) { network(name) }
            // The QR the row's button shows, here too: another device on this network scans it.
            // Once the project is on the network under its name, that link and QR stand in for this one.
            if !shared, let lan = row.lanURL(ip: monitor.lanIP) {
                DetailLine(label: "Network", value: lan) {
                    Pill(title: "copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lan, forType: .string)
                        monitor.flash("Copied \(lan)")
                    }
                }
                codeStack
            }
            if let hint = row.hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if row.scope == .loopback, !shared {
                Text(canShare ? "Only this Mac can reach it. Turn on network to open it from your phone, or use share for a public link."
                     : "Only this Mac can reach it. Start it on 0.0.0.0 to open it from your phone, or use share for a public link.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Manfath's tunnel pill: "share" → confirm with plain words → public link.
private struct ShareControl: View {
    let row: PortRow
    @Binding var note: String?
    /// "For how long?": the row shows the choices under itself while this is on.
    @Binding var confirming: Bool
    @State private var armed = 0

    init(row: PortRow, note: Binding<String?>, choosing: Binding<Bool>) {
        self.row = row
        _note = note
        _confirming = choosing
    }

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
            Pill(title: "cancel") { confirming = false; note = nil }
        } else {
            Pill(title: "share", style: .share, help: "Get a public link for :\(row.port)") {
                guard Tunnels.tool != nil else {
                    note = "\(Tunnels.hint.text) \(Tunnels.hint.command)"
                    return
                }
                confirming = true
                note = "Anyone with the link can open \(row.title) on port \(row.port). For how long?"
                armed += 1
                let token = armed
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if armed == token, confirming { confirming = false; note = nil }
                }
            }
        }
    }
}

/// "Open it on your phone". Reachable servers get their network address as a QR code,
/// like Manfath's. Loopback-only ones say why a phone can't reach them and offer share;
/// once shared, the QR opens the public link instead.
struct LANCard: View {
    @Environment(Monitor.self) private var monitor
    let row: PortRow
    @State private var confirming = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open on another device").font(.system(size: 12, weight: .semibold))
            let codes = monitor.codes(row)
            if codes.isEmpty {
                if row.lanReachable { network } else { loopback }
            } else {
                // Every code the row has, one under the other, each with what it is and its link.
                if codes.count == 1, codes[0].code == .share { small("Phones can't reach 127.0.0.1, so this opens the public link.") }
                ForEach(codes, id: \.link) { code in
                    if codes.count > 1 { Text(code.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                    QRCode(text: code.link, size: 150).frame(maxWidth: .infinity)
                    link(code.link)
                }
                if codes.contains(where: { $0.code == .lan }) { network }
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(WindowAppearance(appearance: monitor.appearance.nsAppearance))  // the popover's own window
    }

    @ViewBuilder private var network: some View {
        if row.lanURL(ip: monitor.lanIP) != nil {
            if let bonjour = row.bonjourURL(monitor.lanName) {
                Text("Or \(bonjour)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if LAN.firewallOn {
                small("The macOS firewall is on, so macOS may ask to allow incoming connections for this server.")
            }
        } else {
            small("This Mac isn't on a network right now, so other devices can't reach it.")
        }
    }

    @ViewBuilder private var loopback: some View {
        switch Tunnels.shared.active[row.port]?.phase {
        case .ready?:
            EmptyView()     // its code is drawn with the others
        case .starting?:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); small("Opening a public link…") }
        default:
            small("Phones can't reach 127.0.0.1. Share it to get a link and QR that work anywhere.")
            if confirming {
                Text("Anyone with the link can open \(row.title) on port \(row.port) until you stop sharing.")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Pill(title: "share", style: .go) { confirming = false; note = Tunnels.shared.start(row) }
                    Pill(title: "cancel") { confirming = false }
                }
            } else {
                Pill(title: "share", style: .share, help: "Get a public link for :\(row.port)") {
                    if Tunnels.tool == nil { note = "\(Tunnels.hint.text) \(Tunnels.hint.command)" } else { confirming = true }
                }
            }
            if let note { small(note).textSelection(.enabled) }
        }
    }

    private func link(_ url: String) -> some View {
        HStack(spacing: 6) {
            Text(url).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            Pill(title: "copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                monitor.flash("Copied \(url)")
            }
        }
    }

    private func small(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    var filled = false  // the neutral grey "macOS" tag
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)) }
            Text(text)
        }
            .font(.system(size: 10, weight: filled ? .semibold : .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(filled ? Tone.neutralInk : Color.secondary)
            .background {
                if filled { RoundedRectangle(cornerRadius: 4).fill(Tone.neutralBg) }
                else { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)) }
            }
            .lineLimit(1)
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
                            question: "Quit \(p.name) (pid \(p.pid))? macOS then clears its stuck processes." + (Docker.owns(path: p.path) ? " " + Docker.quitNote : ""),
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
