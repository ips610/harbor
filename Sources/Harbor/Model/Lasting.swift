import Foundation

/// How long something stays shared: 30 minutes, an hour, or until it is stopped. Chosen
/// when a public link is opened or a server goes on the network, and remembered per kind.
///
/// A deadline is a point on the wall clock, never a count of seconds left to run: a Mac
/// that slept through it stops the share the moment it wakes, and nothing but the owner's
/// own "+30 min" ever moves it.
enum Lasting {
    enum Kind: String {
        case link = "public", network
        /// A public link ends after an hour unless told otherwise; the network keeps today's "until I stop it".
        var usual: Int { self == .link ? 3600 : 0 }
    }

    /// Seconds; 0 is "until I stop it".
    static let choices = [1800, 3600, 0]
    /// What "+30 min" adds.
    static let more: TimeInterval = 1800

    static func title(_ seconds: Int) -> String {
        seconds == 1800 ? "30 min" : seconds == 3600 ? "1 hour" : "until I stop it"
    }

    /// The last choice for this kind, or its usual one.
    static func remembered(_ kind: Kind) -> Int {
        let saved = DebugCLI.defaults.object(forKey: "lasts." + kind.rawValue) as? Int
        return saved.flatMap { choices.contains($0) ? $0 : nil } ?? kind.usual
    }

    static func remember(_ kind: Kind, _ seconds: Int) {
        if choices.contains(seconds) { DebugCLI.defaults.set(seconds, forKey: "lasts." + kind.rawValue) }
    }

    /// The deadline for a share that starts now. nil: until it is stopped. Anything that
    /// isn't one of the three choices is refused (nil from `pick`), never read as "forever".
    static func pick(_ asked: Int?, kind: Kind) -> Int? {
        guard let asked else { return remembered(kind) }
        return choices.contains(asked) ? asked : nil
    }

    static func deadline(_ seconds: Int, from now: Date) -> Date? {
        seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : nil
    }

    /// The deadline of a share as it starts. With a time chosen now: that long from now.
    /// Without one, a share that is only moving (a rename) keeps the deadline it has, to the
    /// second: renaming never buys time.
    static func until(chosen seconds: Int?, moving had: Date??, now: Date) -> Date? {
        if let seconds { return deadline(seconds, from: now) }
        return had ?? nil
    }

    static func isOver(_ until: Date?, now: Date) -> Bool {
        until.map { $0 <= now } ?? false
    }

    /// A deadline moved on by half an hour: from where it stands, never from "now" when
    /// that is earlier, and never for a share that has none.
    static func extended(_ until: Date?, now: Date) -> Date? {
        until.map { max($0, now).addingTimeInterval(more) }
    }

    /// "42 min left", "1 h 5 min left", "under a minute left"; nil without a deadline.
    static func left(_ until: Date?, now: Date) -> String? {
        guard let until else { return nil }
        let seconds = until.timeIntervalSince(now)
        if seconds < 60 { return "under a minute left" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min left" : "\(minutes / 60) h \(minutes % 60) min left"
    }
}
