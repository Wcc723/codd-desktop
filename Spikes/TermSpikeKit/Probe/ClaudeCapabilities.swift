/// What Claude Code 2.1.300 turns on for a terminal, decided from the
/// terminal's probe replies with the rules in Claude's own bundle (its
/// startup probe function and the kitty graphics allow-list).
///
/// Only the reply-driven capabilities are modelled. Behaviour Claude gates on
/// environment variables alone (`TERM_PROGRAM=ghostty` for the Cmd+click
/// workaround, notifications and hyperlinks) is listed in `environmentGates`.
public enum ClaudeCapabilities {
    /// One capability, named as in Claude's capability log line.
    public struct Verdict: Sendable, Codable, Equatable {
        public var capability: String
        public var enabled: Bool
        public var reason: String

        public init(capability: String, enabled: Bool, reason: String) {
            self.capability = capability
            self.enabled = enabled
            self.reason = reason
        }
    }

    /// The child environment variables that change Claude's decisions.
    public struct Environment: Sendable, Equatable {
        public var termProgram: String?
        /// `CLAUDE_CODE_FORCE_TERMINAL_IMAGES` set: inline images regardless of XTVERSION.
        public var forceTerminalImages: Bool
        /// `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` set: Claude never asks for OSC 7501.
        public var disableTerminalTitle: Bool

        public init(termProgram: String? = nil, forceTerminalImages: Bool = false, disableTerminalTitle: Bool = false) {
            self.termProgram = termProgram
            self.forceTerminalImages = forceTerminalImages
            self.disableTerminalTitle = disableTerminalTitle
        }
    }

    /// XTVERSION names Claude draws kitty graphics for: exactly the name or the
    /// name followed by a space (`ghostty 1.3.2`), plus `kitty(x.y.z)` >= 0.28.0.
    public static let kittyGraphicsTerminals = ["kitty", "ghostty"]
    static let minimumKittyVersion = [0, 28, 0]

    /// Facts read from the 2.1.300 bundle that do not depend on probe replies.
    public static let environmentGates: [String] = [
        "Cmd+click workaround (`macCmdClickArrivesWithoutSgrModifierBit`): only when `TERM_PROGRAM` is `ghostty` or `WarpTerminal` on macOS, never from XTVERSION.",
        "`isGhostty()`: `TERM=xterm-ghostty` or `TERM_PROGRAM=ghostty`.",
        "Desktop notification method and OSC 8 hyperlink support: chosen from `TERM_PROGRAM` (`ghostty` is on both lists).",
        "`CLAUDE_CODE_FORCE_TERMINAL_IMAGES` set (e.g. `=1`; how Claude parses the value was not checked): inline kitty graphics on without the XTVERSION allow-list, so a SwiftTerm host can enable images without spoofing XTVERSION.",
        "`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`: Claude neither sets titles nor probes OSC 7501.",
    ]

    public static func evaluate(tokens: [ReplyToken], environment: Environment = Environment()) -> [Verdict] {
        let name = xtversionName(tokens)
        let sentinel = tokens.contains { ProbeInterpreter.matches($0, ClaudeProbes.da1) }
        // The second burst is only sent after an XTVERSION answer.
        let secondBurst = name != nil && environment.termProgram != "Apple_Terminal"
        var verdicts: [Verdict] = []

        let flags = tokens.first { ProbeInterpreter.matches($0, ClaudeProbes.kittyKeyboard) }
        let flagsText = flags.map { "CSI ? u answered (\($0.display))" } ?? (sentinel ? "no reply to CSI ? u" : "no DA1 sentinel either")
        verdicts.append(Verdict(capability: "kittyKeyboard", enabled: flags != nil, reason: flagsText))
        verdicts.append(Verdict(capability: "extendedKeys", enabled: flags != nil, reason: flagsText))

        if environment.disableTerminalTitle {
            verdicts.append(Verdict(capability: "programStatus", enabled: false, reason: "CLAUDE_CODE_DISABLE_TERMINAL_TITLE set: not asked"))
        } else {
            let status = tokens.contains { ProbeInterpreter.matches($0, ClaudeProbes.programStatus) }
            verdicts.append(Verdict(
                capability: "programStatus", enabled: status,
                reason: status ? "OSC 7501 reply with data starting `?`" : "no OSC 7501 ; ? reply"
            ))
        }

        let notAsked = name == nil ? "not asked: no XTVERSION reply" : "not asked: TERM_PROGRAM=Apple_Terminal"
        verdicts.append(decrpm(
            "synchronizedOutput", probe: ClaudeProbes.decrqm2026, tokens: tokens,
            asked: secondBurst, notAsked: notAsked
        ))

        if environment.forceTerminalImages {
            verdicts.append(Verdict(capability: "kittyGraphics", enabled: true, reason: "forced by CLAUDE_CODE_FORCE_TERMINAL_IMAGES"))
        } else if !secondBurst {
            verdicts.append(Verdict(capability: "kittyGraphics", enabled: false, reason: notAsked))
        } else {
            let replied = tokens.contains { ProbeInterpreter.matches($0, ClaudeProbes.kittyGraphics) }
            let allowed = name.map(isKittyGraphicsTerminal) ?? false
            let reason = switch (replied, allowed) {
            case (true, true): "graphics reply and XTVERSION \"\(name ?? "")\" is on the allow-list"
            case (true, false): "graphics reply, but XTVERSION \"\(name ?? "")\" is not kitty / ghostty"
            case (false, _): "no reply to the graphics query"
            }
            verdicts.append(Verdict(capability: "kittyGraphics", enabled: replied && allowed, reason: reason))
        }

        verdicts.append(decrpm(
            "mousePixels", probe: ClaudeProbes.decrqm1016, tokens: tokens,
            asked: secondBurst, notAsked: notAsked
        ))
        return verdicts
    }

    /// The name from `DCS > | name ST`, as Claude stores it.
    static func xtversionName(_ tokens: [ReplyToken]) -> String? {
        for token in tokens {
            if case let .dcs(payload) = token, ProbeInterpreter.matches(token, ClaudeProbes.xtversion) {
                return String(payload.dropFirst(2))
            }
        }
        return nil
    }

    /// Claude's allow-list check (`nYo` in the 2.1.300 bundle).
    public static func isKittyGraphicsTerminal(_ name: String) -> Bool {
        if name.hasPrefix("kitty(") {
            let digits = name.dropFirst(6).prefix { $0 != ")" }.split(separator: ".").map { Int($0) ?? 0 }
            let version = (digits + [0, 0, 0]).prefix(3)
            return version.lexicographicallyPrecedes(minimumKittyVersion) == false
        }
        return kittyGraphicsTerminals.contains { name == $0 || name.hasPrefix("\($0) ") }
    }

    /// DECRPM status 1, 2 or 3 means "the terminal knows this mode", which is
    /// all Claude asks (a reset 2026 still counts as supported).
    private static func decrpm(
        _ capability: String, probe: ProbeSpec, tokens: [ReplyToken], asked: Bool, notAsked: String
    ) -> Verdict {
        guard asked else { return Verdict(capability: capability, enabled: false, reason: notAsked) }
        guard let reply = tokens.first(where: { ProbeInterpreter.matches($0, probe) }),
              case let .csi(params, _, _) = reply,
              let status = params.split(separator: ";").last.flatMap({ Int($0) })
        else {
            return Verdict(capability: capability, enabled: false, reason: "no DECRPM reply")
        }
        return Verdict(capability: capability, enabled: (1 ... 3).contains(status), reason: "DECRPM status \(status)")
    }
}
