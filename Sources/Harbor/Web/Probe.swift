import Foundation

/// What a web server answers on "/": its status and its page's title, shown beside its row
/// ("200 · Storefront – Admin", "301 → /login", "500", "not answering").
///
/// Asked only while somebody is looking at that row (its details open in the menu, or the
/// row on screen on the page), never from a timer. One plain request, sent the way a browser
/// coming through the row's `.localhost` name would send it, with no cookie and nothing else
/// that identifies anyone. No redirect is followed. What comes back is somebody else's text:
/// it is cut to size, stripped of anything but text, and only ever shown as text. Neither
/// the title nor a redirect's target is logged.
enum Probe {
    /// At most this many at once, and each row at most once in this many seconds.
    static let atOnce = 6
    static let every: Double = 60
    /// 2 s to connect, 3 s for all of it, and no more than 64 KB read.
    static let connectWithin: Double = 2, allWithin: Double = 3, maxAnswer = 64 * 1024
    static let maxTitle = 80
    static let notAnswering = "not answering"

    /// May this row be asked at all? Only something harbor would give a name to (so never a
    /// macOS service, harbor itself, the two apps' own ports, a database, or a port browsers
    /// refuse), and of those only what is a server in its own right: a project's dev server,
    /// a runtime, a container. An app's private helper port is left alone.
    static func allowed(_ row: PortRow, never: Set<UInt16> = Names.reservedPorts) -> Bool {
        Names.named(row, never: never) && (row.container != nil || [.dev, .runtime, .other].contains(row.category))
    }

    /// The row ids in a page's `see=` ("4101-3000,4102-3001"): only ones shaped like a row's, and no more than 40.
    static func rows(in list: String) -> [String] {
        list.split(separator: ",").prefix(40).map(String.init).filter { id in
            let parts = id.split(separator: "-", omittingEmptySubsequences: false)
            return parts.count == 2 && (1...10).contains(parts[0].count) && (1...5).contains(parts[1].count) && id.utf8.allSatisfy { (48...57).contains($0) || $0 == 45 }
        }
    }

    /// Which of the rows somebody is looking at are asked now: ones that are in harbor's
    /// list at this moment, that may be asked at all (`allowed`) and have a name to be asked
    /// under, not asked in the last minute and not being asked; and never more than six at once.
    static func pick(_ ids: [String], rows: [PortRow], named: Set<String>, last: [String: Date], asking: Set<String>, now: Date) -> [String] {
        var picked: [String] = []
        for id in ids where !picked.contains(id) {
            guard asking.count + picked.count < atOnce else { break }
            guard !asking.contains(id), last[id].map({ now.timeIntervalSince($0) >= every }) ?? true, named.contains(id),
                  let row = rows.first(where: { $0.id == id }), allowed(row) else { continue }
            picked.append(id)
        }
        return picked
    }

    /// The request: `GET /` as the `.localhost` proxy would pass it on for this Host, and
    /// nothing a browser would add about its user.
    static func request(host: String) -> Data? {
        // A name harbor made, with the proxy's port when it has one: letters, digits, hyphens, dots, a colon. Nothing else goes on the wire.
        guard !host.isEmpty, host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 58 }) else { return nil }
        return ProxyHead(Data("GET / HTTP/1.1\r\nHost: \(host)\r\nAccept: text/html,*/*;q=0.8\r\nUser-Agent: \(AppInfo.name)\r\n\r\n".utf8))?.forwarded(client: "127.0.0.1")
    }

    /// One line for what came back. `answer` is whatever arrived, cut off or not.
    static func line(for answer: Data) -> String {
        let text = String(decoding: answer.prefix(maxAnswer), as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts[0].components(separatedBy: "\r\n")
        let status = head[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0", status[1].utf8.count == 3, let code = Int(status[1]), (100...599).contains(code) else {
            return notAnswering
        }
        func header(_ name: String) -> String? {
            head.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        if (300...399).contains(code), let to = header("location").map({ Docker.clean($0, max: maxTitle) }), !to.isEmpty { return "\(code) → \(to)" }
        let html = header("content-type").map { $0.lowercased().contains("html") } ?? true
        guard html, parts.count > 1, let title = title(in: parts.dropFirst().joined(separator: "\r\n\r\n")) else { return String(code) }
        return "\(code) · \(title)"
    }

    /// The text of the first `<title>`, as one line of plain text of at most 80 characters.
    // ponytail: a title that a chunked answer happens to split in two keeps the chunk's size
    // line in its middle. Put the chunks back together first if that is ever seen.
    static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive), let start = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: .caseInsensitive, range: start.upperBound..<html.endIndex) else { return nil }
        // Only "<title>" or "<title attr…>": not "<titles>".
        if let next = html[open.upperBound...].first, next != ">", !next.isWhitespace { return nil }
        let title = Docker.clean(decoded(String(html[start.upperBound..<close.lowerBound])), max: maxTitle)
        return title.isEmpty ? nil : title
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "copy": "©", "reg": "®", "trade": "™", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "times": "×", "rarr": "→", "larr": "←",
    ]

    /// Character references, read once from left to right: `&amp;lt;` is "&lt;", never "<".
    /// The common names and every numeric one; anything else stays exactly as it was written.
    static func decoded(_ text: String) -> String {
        var out = "", rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let end = after.prefix(12).firstIndex(of: ";") else {
                out += "&"
                rest = after
                continue
            }
            let name = after[..<end]
            var character: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                character = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                character = entities[String(name)]
            }
            if let character {
                out += character
                rest = after[after.index(after: end)...]
            } else {
                out += "&"
                rest = after
            }
        }
        return out + rest
    }

    /// Asks the server at `target` and says what it answered. Blocks for at most `allWithin`.
    static func ask(_ target: Names.Target, host: String) -> String {
        let deadline = Date().addingTimeInterval(allWithin)
        // Only this Mac's own addresses, as the proxy does.
        guard let request = request(host: host), let fd = Sock.connect(target.addresses.filter(Sock.isOwn), port: target.port, within: connectWithin) else { return notAnswering }
        defer { close(fd) }
        Sock.send(fd, request, within: max(0.1, deadline.timeIntervalSinceNow))
        var answer = Data(), chunk = [UInt8](repeating: 0, count: 16384)
        while answer.count < maxAnswer, deadline.timeIntervalSinceNow > 0 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000)) > 0 else { break }
            let n = read(fd, &chunk, min(chunk.count, maxAnswer - answer.count))
            if n > 0 { answer.append(contentsOf: chunk[0..<n]) } else if n == 0 || (errno != EAGAIN && errno != EINTR) { break }
            // The title is in: no need for the rest of the page.
            if answer.range(of: Data("</title".utf8)) != nil || answer.range(of: Data("</TITLE".utf8)) != nil { break }
        }
        return line(for: answer)
    }
}
