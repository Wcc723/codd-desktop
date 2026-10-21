/// Deterministic generator of an ANSI-heavy byte stream that resembles what a
/// CODD terminal sees: shell output with SGR colours (256 and truecolour), CJK
/// text, Claude-style tool boxes and diffs, and fullscreen alt-screen frames
/// wrapped in synchronized output (mode 2026) with cursor positioning, plus the
/// occasional OSC 0 title and OSC 8 hyperlink. It contains no queries, so an
/// engine produces no replies while parsing it.
///
/// The same seed always yields the same bytes. Output is valid UTF-8 and is
/// exactly `byteCount` long (segments are never cut; the tail is ASCII padding).
public struct AnsiStreamGenerator: Sendable {
    public let columns: Int
    public let rows: Int
    /// OSC 0 titles per 1000 segments. 1 is realistic for Claude (a retitle every
    /// 960 ms); 100 is a stress case for engines that hop titles to the main thread.
    public let titlePerMille: Int
    private var random: SplitMix64

    public init(seed: UInt64 = 0xC0DD_2026, columns: Int = 120, rows: Int = 40, titlePerMille: Int = 1) {
        random = SplitMix64(seed: seed)
        self.columns = max(20, columns)
        self.rows = max(10, rows)
        self.titlePerMille = max(0, min(1000, titlePerMille))
    }

    public mutating func generate(byteCount: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(byteCount + 64 * 1024)
        var segment: [UInt8] = []
        segment.reserveCapacity(128 * 1024)
        while true {
            segment.removeAll(keepingCapacity: true)
            appendSegment(into: &segment)
            if out.count + segment.count > byteCount { break }
            out.append(contentsOf: segment)
        }
        while out.count < byteCount {
            let lineLength = min(byteCount - out.count, columns)
            if lineLength >= 2 {
                for index in 0 ..< lineLength - 2 {
                    out.append(UInt8(ascii: "a") + UInt8(index % 26))
                }
                out.append(0x0D)
                out.append(0x0A)
            } else {
                out.append(UInt8(ascii: " "))
            }
        }
        return out
    }

    // MARK: - Segments

    private mutating func appendSegment(into out: inout [UInt8]) {
        let roll = random.next(below: 1000)
        if roll < titlePerMille {
            appendTitle(into: &out)
            return
        }
        switch roll {
        case 0 ..< 500: appendLogLine(into: &out)
        case 500 ..< 650: appendCJKLine(into: &out)
        case 650 ..< 800: appendToolBlock(into: &out)
        case 800 ..< 820: appendAltScreenSession(into: &out)
        case 820 ..< 900: appendLink(into: &out)
        default: appendLogLine(into: &out)
        }
    }

    /// `ls --color` / compiler-log style line with 256-colour and truecolour SGR.
    private mutating func appendLogLine(into out: inout [UInt8]) {
        var width = 0
        // Between ~half and the full width; grids narrower than 41 columns
        // must not reach next(below: 0), which traps.
        let shortest = min(40, columns / 2)
        let target = shortest + random.next(below: max(1, columns - shortest))
        while width < target {
            let word = Vocabulary.ascii[random.next(below: Vocabulary.ascii.count)]
            switch random.next(below: 6) {
            case 0:
                out.append(contentsOf: Vocabulary.csi)
                out.append(contentsOf: "38;5;".utf8)
                appendNumber(16 + random.next(below: 216), into: &out)
                out.append(UInt8(ascii: "m"))
            case 1:
                appendTruecolor(foreground: true, into: &out)
            case 2:
                out.append(contentsOf: "\u{1B}[1m".utf8)
            default:
                break
            }
            out.append(contentsOf: word)
            out.append(contentsOf: Vocabulary.reset)
            out.append(UInt8(ascii: " "))
            width += word.count + 1
        }
        out.append(contentsOf: Vocabulary.crlf)
    }

    /// Claude-style bullet line mixing CJK (double width) and ASCII.
    private mutating func appendCJKLine(into out: inout [UInt8]) {
        appendTruecolor(foreground: true, into: &out)
        out.append(contentsOf: "● ".utf8)
        out.append(contentsOf: Vocabulary.reset)
        let phrases = 2 + random.next(below: 5)
        for _ in 0 ..< phrases {
            out.append(contentsOf: Vocabulary.cjk[random.next(below: Vocabulary.cjk.count)])
            out.append(UInt8(ascii: " "))
            if random.next(below: 3) == 0 {
                out.append(contentsOf: Vocabulary.ascii[random.next(below: Vocabulary.ascii.count)])
                out.append(UInt8(ascii: " "))
            }
        }
        out.append(contentsOf: Vocabulary.crlf)
    }

    /// Box-drawn tool call header, `⎿` result lines and a coloured diff.
    private mutating func appendToolBlock(into out: inout [UInt8]) {
        let inner = min(columns - 4, 60 + random.next(below: 40))
        out.append(contentsOf: "\u{1B}[38;2;122;116;104m╭".utf8)
        for _ in 0 ..< inner { out.append(contentsOf: Vocabulary.horizontal) }
        out.append(contentsOf: "╮\u{1B}[0m\r\n".utf8)
        out.append(contentsOf: "\u{1B}[38;2;122;116;104m│\u{1B}[0m \u{1B}[1mEdit\u{1B}[0m(".utf8)
        out.append(contentsOf: Vocabulary.paths[random.next(below: Vocabulary.paths.count)])
        out.append(contentsOf: ")\r\n".utf8)
        out.append(contentsOf: "\u{1B}[38;2;122;116;104m╰".utf8)
        for _ in 0 ..< inner { out.append(contentsOf: Vocabulary.horizontal) }
        out.append(contentsOf: "╯\u{1B}[0m\r\n".utf8)
        out.append(contentsOf: "  ⎿  Updated with 3 additions and 1 removal\r\n".utf8)
        let lines = 3 + random.next(below: 8)
        for line in 0 ..< lines {
            let added = random.next(below: 2) == 0
            out.append(contentsOf: (added ? "\u{1B}[48;2;20;48;28m\u{1B}[38;2;184;245;198m" : "\u{1B}[48;2;56;20;16m\u{1B}[38;2;255;177;163m").utf8)
            appendNumber(100 + line, into: &out)
            out.append(contentsOf: (added ? " + " : " - ").utf8)
            out.append(contentsOf: Vocabulary.code[random.next(below: Vocabulary.code.count)])
            out.append(contentsOf: "\u{1B}[K\u{1B}[0m\r\n".utf8)
        }
    }

    /// A fullscreen TUI session: enter the alt screen, draw several synchronized
    /// frames with absolute positioning (only changed rows), leave it again.
    private mutating func appendAltScreenSession(into out: inout [UInt8]) {
        out.append(contentsOf: "\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J".utf8)
        let frames = 6 + random.next(below: 10)
        for frame in 0 ..< frames {
            out.append(contentsOf: "\u{1B}[?2026h".utf8)
            let changed = 4 + random.next(below: rows / 2)
            for _ in 0 ..< changed {
                let row = 1 + random.next(below: rows - 3)
                out.append(contentsOf: Vocabulary.csi)
                appendNumber(row, into: &out)
                out.append(contentsOf: ";1H\u{1B}[2K".utf8)
                if random.next(below: 3) == 0 {
                    out.append(contentsOf: Vocabulary.cjk[random.next(below: Vocabulary.cjk.count)])
                } else {
                    appendTruecolor(foreground: true, into: &out)
                    out.append(contentsOf: Vocabulary.code[random.next(below: Vocabulary.code.count)])
                    out.append(contentsOf: Vocabulary.reset)
                }
            }
            out.append(contentsOf: Vocabulary.csi)
            appendNumber(rows - 1, into: &out)
            out.append(contentsOf: ";1H\u{1B}[2K\u{1B}[38;2;255;184;74m✻\u{1B}[0m Editing… (".utf8)
            appendNumber(frame + 1, into: &out)
            out.append(contentsOf: "s · ↓ ".utf8)
            appendNumber(1 + random.next(below: 9), into: &out)
            out.append(contentsOf: ".2k tokens · esc to interrupt)".utf8)
            out.append(contentsOf: "\u{1B}[?2026l".utf8)
        }
        out.append(contentsOf: "\u{1B}[?25h\u{1B}[?1049l".utf8)
    }

    private mutating func appendLink(into out: inout [UInt8]) {
        out.append(contentsOf: "see \u{1B}]8;;https://example.invalid/docs/".utf8)
        appendNumber(random.next(below: 10_000), into: &out)
        out.append(contentsOf: "\u{1B}\\documentation\u{1B}]8;;\u{1B}\\ for details\r\n".utf8)
    }

    private mutating func appendTitle(into out: inout [UInt8]) {
        let glyph = random.next(below: 2) == 0 ? "◐" : "◑"
        out.append(contentsOf: "\u{1B}]0;\(glyph) claude\u{07}".utf8)
    }

    // MARK: - Helpers

    private mutating func appendTruecolor(foreground: Bool, into out: inout [UInt8]) {
        out.append(contentsOf: Vocabulary.csi)
        out.append(contentsOf: (foreground ? "38;2;" : "48;2;").utf8)
        appendNumber(random.next(below: 256), into: &out)
        out.append(UInt8(ascii: ";"))
        appendNumber(random.next(below: 256), into: &out)
        out.append(UInt8(ascii: ";"))
        appendNumber(random.next(below: 256), into: &out)
        out.append(UInt8(ascii: "m"))
    }

    private func appendNumber(_ value: Int, into out: inout [UInt8]) {
        if value >= 10 { appendNumber(value / 10, into: &out) }
        out.append(UInt8(ascii: "0") + UInt8(value % 10))
    }
}

/// SplitMix64: tiny, fast, deterministic PRNG (not for security).
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(below bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }
}

private enum Vocabulary {
    static let csi: [UInt8] = [0x1B, 0x5B]
    static let reset: [UInt8] = Array("\u{1B}[0m".utf8)
    static let crlf: [UInt8] = [0x0D, 0x0A]
    static let horizontal: [UInt8] = Array("─".utf8)

    static let ascii: [[UInt8]] = [
        "build", "Compiling", "SwiftTerm", "ghostty", "warning:", "error:", "note:", "src/main.swift",
        "README.md", "drwxr-xr-x", "-rw-r--r--", "staff", "4096", "Oct", "15", "19:32", "node_modules",
        "package.json", "[OK]", "[..]", "PASS", "FAIL", "✓", "→", "0.42s", "100%", "commit", "a2e4403",
    ].map { Array($0.utf8) }

    static let cjk: [[UInt8]] = [
        "修正登入 API 401", "已切換到 #2 藍鵲", "上班打卡按鈕被底部導覽列蓋住", "時鐘數字在 SE 上太大",
        "打卡紀錄卡片離按鈕太近", "所有帳號都低於 2%", "可以展開看所有帳號的用量", "這邊可以直接切換",
        "注音輸入法測試：ㄓㄨˋ ㄧㄣ", "繁體中文說明文字", "全形標點，。、；：「」",
    ].map { Array($0.utf8) }

    static let paths: [[UInt8]] = [
        "apps/web/src/punch.vue", "Packages/CoddCore/Sources/HookState.swift", "configs/hooks/status-writer.js",
        "design/SPEC.md", "docs/ARCHITECTURE.md",
    ].map { Array($0.utf8) }

    static let code: [[UInt8]] = [
        "let state = applyEvent(previous, event)", "func feed(_ bytes: UnsafeRawBufferPointer) {",
        "  position: sticky; bottom: env(safe-area-inset-bottom);", "return .waiting(.permission)",
        "if (event.hook_event_name === 'Stop') {", "case .busy: return \"●\"", "}",
    ].map { Array($0.utf8) }
}
