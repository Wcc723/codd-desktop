/// One query a program writes to the terminal at startup.
public struct ProbeSpec: Sendable, Equatable, Codable {
    /// Stable key used in result files (`xtversion`, `decrqm-2026`, …).
    public var id: String
    /// Human label, e.g. `XTVERSION  CSI > 0 q`.
    public var label: String
    public var bytes: [UInt8]
    /// What a well-behaved answer looks like.
    public var expected: String
    /// Whether Claude Code 2.1.300 sends this probe (others are extras).
    public var sentByClaude: Bool

    public init(id: String, label: String, sequence: String, expected: String, sentByClaude: Bool = true) {
        self.id = id
        self.label = label
        bytes = Array(sequence.utf8)
        self.expected = expected
        self.sentByClaude = sentByClaude
    }
}

/// Claude Code 2.1.300's startup probes (design/research/native-swift/terminal.md §1).
///
/// Claude sends them in two bursts, each closed by a DA1 sentinel: XTVERSION,
/// `CSI ? u` and `OSC 7501 ; ?` first; then, only if XTVERSION was answered
/// (and `TERM_PROGRAM` is not `Apple_Terminal`), DECRQM 2026, the kitty
/// graphics query, `CSI 16 t` and DECRQM 1016. The spike writes all of them
/// as one burst with DA1 last, which asks the engine the same questions.
public enum ClaudeProbes {
    /// The image id Claude's kitty graphics query uses and expects back.
    public static let kittyGraphicsID = 31

    public static let xtversion = ProbeSpec(
        id: "xtversion", label: "XTVERSION  CSI > 0 q", sequence: "\u{1B}[>0q",
        expected: "DCS > | name version ST")
    public static let kittyKeyboard = ProbeSpec(
        id: "kitty-keyboard", label: "Kitty keyboard query  CSI ? u", sequence: "\u{1B}[?u",
        expected: "CSI ? flags u")
    public static let decrqm2026 = ProbeSpec(
        id: "decrqm-2026", label: "DECRQM 2026 (synchronized output)", sequence: "\u{1B}[?2026$p",
        expected: "CSI ? 2026 ; 1|2 $ y")
    public static let decrqm1016 = ProbeSpec(
        id: "decrqm-1016", label: "DECRQM 1016 (SGR pixel mouse)", sequence: "\u{1B}[?1016$p",
        expected: "CSI ? 1016 ; 1|2 $ y")
    public static let programStatus = ProbeSpec(
        id: "osc-7501", label: "OSC 7501 ; ?  (program status)", sequence: "\u{1B}]7501;?\u{1B}\\",
        expected: "OSC 7501 ; … ST")
    public static let kittyGraphics = ProbeSpec(
        id: "kitty-graphics", label: "Kitty graphics query  APC G a=q", sequence: "\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\",
        expected: "APC G i=31 ; OK ST")
    public static let cellSize = ProbeSpec(
        id: "csi-16t", label: "Cell size in pixels  CSI 16 t", sequence: "\u{1B}[16t",
        expected: "CSI 6 ; height ; width t")
    public static let da1 = ProbeSpec(
        id: "da1", label: "DA1 (sentinel)  CSI c", sequence: "\u{1B}[c",
        expected: "CSI ? attrs c")

    /// In Claude's order. DA1 must stay last.
    public static let all: [ProbeSpec] = [
        xtversion, kittyKeyboard, decrqm2026, decrqm1016, programStatus, kittyGraphics, cellSize, da1,
    ]

    /// All probes concatenated, as Claude writes them in one burst.
    public static var burst: [UInt8] { all.flatMap(\.bytes) }
}
