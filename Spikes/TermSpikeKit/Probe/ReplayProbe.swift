/// Engine side of reattach (acceptance test 5 in
/// design/research/native-swift/terminal.md §7): a session's history replayed
/// into a fresh engine must
/// - answer none of the queries in it (Claude would read the answers as input),
/// - still draw what it drew (proves the bytes were parsed at all, so "no
///   replies" is not vacuous),
/// - restore the modes it set (alt screen, bracketed paste, mouse, kitty keys),
/// - leave live replies working afterwards (the suppression must not stick).
public enum ReplayProbe {
    /// Text drawn by the replayed history; looked for in the viewport.
    public static let marker = "TERMSPIKE-REPLAY-MARKER"

    /// DEC private modes Claude's fullscreen renderer sets.
    public static let modes: [(number: Int, name: String)] = [
        (1049, "alt screen"), (2004, "bracketed paste"), (1000, "mouse"), (1006, "SGR mouse"),
    ]

    /// Kitty keyboard flags the history pushes (`CSI > 1 u`, as Claude does).
    public static let kittyFlags = "1"

    /// Claude's startup probes as it sent them, then its fullscreen setup and
    /// one drawn line.
    public static var history: [UInt8] {
        var setup = "\u{1B}[?1049h\u{1B}[H\u{1B}[2J"
        for mode in modes where mode.number != 1049 {
            setup += "\u{1B}[?\(mode.number)h"
        }
        setup += "\u{1B}[>\(kittyFlags)u\u{1B}[3;1H" + marker
        return ClaudeProbes.burst + Array(setup.utf8)
    }

    /// Live queries sent after the replay: DECRQM per mode, the kitty flags,
    /// DA1 last as the sentinel.
    public static var liveQueries: [UInt8] {
        var text = ""
        for mode in modes {
            text += "\u{1B}[?\(mode.number)$p"
        }
        text += "\u{1B}[?u\u{1B}[c"
        return Array(text.utf8)
    }

    /// What the engine answered to `liveQueries`.
    public struct Verdict: Sendable, Codable, Equatable {
        /// Mode number → DECRPM value (`1` set, `2` reset, `0` unknown). A
        /// missing key means the engine did not answer that query.
        public var modeReports: [String: String]
        /// Flags from `CSI ? flags u`, nil when not answered.
        public var kittyFlags: String?
        /// DA1 answered: live replies work after the replay.
        public var sentinelAnswered: Bool

        public init(modeReports: [String: String], kittyFlags: String?, sentinelAnswered: Bool) {
            self.modeReports = modeReports
            self.kittyFlags = kittyFlags
            self.sentinelAnswered = sentinelAnswered
        }

        /// No mode came back reset or unanswered. Modes the engine cannot
        /// report (DECRPM `0`) do not count; see `unreportedModes`.
        public var allModesRestored: Bool { lostModes.isEmpty }

        public var kittyRestored: Bool { kittyFlags == ReplayProbe.kittyFlags }

        /// Modes answered as anything but set or "not recognized", or not
        /// answered at all, e.g. `["2004 bracketed paste = 2"]`.
        public var lostModes: [String] {
            ReplayProbe.modes.compactMap { mode in
                let value = modeReports[String(mode.number)]
                guard value != "1", value != "0" else { return nil }
                return "\(mode.number) \(mode.name) = \(value ?? "no reply")"
            }
        }

        /// Modes whose state the engine does not report through DECRQM
        /// (DECRPM `0`, "not recognized"), e.g. SwiftTerm and 1049. Their
        /// state has to be confirmed another way.
        public var unreportedModes: [Int] {
            ReplayProbe.modes.compactMap { modeReports[String($0.number)] == "0" ? $0.number : nil }
        }
    }

    /// Sent after the checks: leaving the alt screen must remove the marker
    /// from the viewport, which confirms the replay entered it (engine
    /// independent, for engines that do not report 1049 via DECRQM).
    public static let leaveAltScreen: [UInt8] = Array("\u{1B}[?1049l".utf8)

    public static func evaluate(_ tokens: [ReplyToken]) -> Verdict {
        var reports: [String: String] = [:]
        var flags: String?
        var sentinel = false
        for token in tokens {
            guard case let .csi(params, intermediates, final) = token, params.hasPrefix("?") else { continue }
            let fields = params.dropFirst().split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            switch (final, intermediates) {
            case ("y", "$") where fields.count == 2:
                reports[fields[0]] = fields[1]
            case ("u", ""):
                flags = fields.first
            case ("c", ""):
                sentinel = true
            default:
                break
            }
        }
        return Verdict(modeReports: reports, kittyFlags: flags, sentinelAnswered: sentinel)
    }
}
