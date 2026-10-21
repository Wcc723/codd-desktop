/// A screenful that exercises what a Claude Code session draws: palette and
/// truecolour, SGR attributes, box drawing and block elements, Claude's glyphs,
/// CJK width alignment and hyperlinks. Fed straight into an engine (not through
/// the PTY) so both engines render identical bytes side by side.
public enum RenderTestPattern {
    public static var bytes: [UInt8] { Array(text.utf8) }

    static let esc = "\u{1B}"

    public static var text: String {
        var lines: [String] = []
        lines.append("\(esc)[0m\(esc)[1mTERMSPIKE RENDER PATTERN\(esc)[0m  (JetBrains Mono 13 · PingFang TC)")
        lines.append(palette())
        lines.append(cube())
        lines.append(gradient())
        lines.append("\(esc)[1mbold\(esc)[0m \(esc)[2mdim\(esc)[0m \(esc)[3mitalic\(esc)[0m \(esc)[4munderline\(esc)[0m \(esc)[4:3mcurly\(esc)[0m \(esc)[9mstrike\(esc)[0m \(esc)[7minverse\(esc)[0m \(esc)[53moverline\(esc)[0m")
        lines.append("┌─────┬─────┐ ╭─────╮ ┏━━━━━┓ ╔═════╗  ▀▄█▌▐ ░▒▓  ⠋⠙⠹⠸⠼⠴⠦⠧")
        lines.append("│ box │ ok  │ │ rnd │ ┃ hvy ┃ ║ dbl ║  ◐ ◑ ✳ ✻ ● ⎿ ❯ ↓ · …")
        lines.append("├─────┼─────┤ ╰─────╯ ┗━━━━━┛ ╚═════╝  ▁▂▃▄▅▆▇█  ═══ ━━━ ───")
        lines.append("└─────┴─────┘")
        lines.append("CJK width (each row must line up at the bars):")
        lines.append("|0123456789|0123456789|")
        lines.append("|修正登入AB|注音輸入法|")
        lines.append("|ab修正登入|全形，。、|")
        lines.append("|ㄓㄨ ㄧㄣ |「引號」  |")
        lines.append("\(esc)[38;2;255;184;74m●\(esc)[0m 已切換到 #2 藍鵲 · 12 個 session 約 30 秒內套用")
        lines.append("  ⎿  Updated \(esc)[1mpunch.vue\(esc)[0m with 3 additions and 1 removal")
        lines.append("\(esc)[48;2;20;48;28m\(esc)[38;2;184;245;198m 12 + position: sticky; bottom: env(safe-area-inset-bottom);\(esc)[K\(esc)[0m")
        lines.append("\(esc)[48;2;56;20;16m\(esc)[38;2;255;177;163m 13 - position: fixed;\(esc)[K\(esc)[0m")
        lines.append("OSC 8: \(esc)]8;;https://ghostty.org/docs\(esc)\\ghostty docs (Cmd+click)\(esc)]8;;\(esc)\\   plain URL: https://github.com/migueldeicaza/SwiftTerm")
        lines.append("\(esc)[38;2;255;184;74m✻\(esc)[0m Editing… (34s · ↓ 1.2k tokens · esc to interrupt)")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func palette() -> String {
        var row = ""
        for index in 0 ..< 16 {
            row += "\(esc)[48;5;\(index)m \(String(index).count == 1 ? " " : "")\(index) "
        }
        return row + "\(esc)[0m"
    }

    private static func cube() -> String {
        var row = ""
        for index in stride(from: 16, to: 232, by: 3) {
            row += "\(esc)[48;5;\(index)m "
        }
        return row + "\(esc)[0m"
    }

    private static func gradient() -> String {
        var row = ""
        for step in 0 ..< 72 {
            let red = 255 * step / 71
            let blue = 255 - red
            row += "\(esc)[48;2;\(red);96;\(blue)m "
        }
        return row + "\(esc)[0m"
    }
}
