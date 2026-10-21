import Foundation
import Testing
@testable import CoddTerminal

@Suite("Terminal configuration rendering")
struct TerminalConfigurationTests {
    private let lines = TerminalConfiguration.default.ghosttyConfigLines

    @Test func defaultsMatchTheDesign() {
        let configuration = TerminalConfiguration.default
        #expect(configuration.fontFamily == "JetBrains Mono")
        #expect(configuration.fallbackFontFamilies == ["PingFang TC"])
        #expect(configuration.fontSize == 13)
        #expect(configuration.cursorStyle == .block)
        #expect(!configuration.cursorBlinks)
        #expect(configuration.scrollbackLimitBytes == 10_000_000)
        #expect(configuration.colors == .phosphorConsole)
    }

    @Test func rendersFontChainSizeAndCursor() {
        #expect(lines.prefix(2) == ["font-family = JetBrains Mono", "font-family = PingFang TC"])
        #expect(lines.contains("font-size = 13"))
        #expect(lines.contains("font-thicken = false"))
        #expect(lines.contains("cursor-style = block"))
        #expect(lines.contains("cursor-style-blink = false"))
        #expect(lines.contains("window-padding-x = 16"))
        #expect(lines.contains("window-padding-y = 10"))
        #expect(lines.contains("scrollback-limit = 10000000"))
        #expect(lines.contains("confirm-close-surface = false"))
    }

    @Test func rendersPhosphorConsoleColors() {
        #expect(lines.contains("background = #000000"))
        #expect(lines.contains("foreground = #e8e6d8"))
        #expect(lines.contains("cursor-color = #ffb84a"))
        #expect(lines.contains("cursor-text = #000000"))
        #expect(lines.contains("selection-background = #5a4420"))
        #expect(lines.contains("selection-foreground = #f5ecd6"))
        let palette = lines.filter { $0.hasPrefix("palette = ") }
        #expect(palette.count == 16)
        #expect(palette.first == "palette = 0=#2a2a2a")
        #expect(palette.last == "palette = 15=#f5ecd6")
        #expect(palette[11] == "palette = 11=#ffb84a")
        let theme = TerminalColorTheme.phosphorConsole
        #expect(([theme.background, theme.foreground, theme.cursor, theme.cursorText,
                  theme.selectionBackground, theme.selectionForeground] + theme.palette)
            .allSatisfy(TerminalColorTheme.isValidHex))
    }

    @Test func unbindsEveryReservedChordAndNothingElse() {
        let unbinds = lines.filter { $0.hasPrefix("keybind = ") }
        #expect(unbinds.allSatisfy { $0.hasSuffix("=unbind") })
        #expect(unbinds.contains("keybind = super+k=unbind"))
        #expect(unbinds.contains("keybind = super+key_k=unbind"))
        #expect(unbinds.contains("keybind = super+backslash=unbind"))
        #expect(unbinds.contains("keybind = super+comma=unbind"))
        #expect(unbinds.contains("keybind = super+9=unbind"))
        #expect(unbinds.contains("keybind = shift+super+bracket_right=unbind"))
        #expect(!unbinds.contains { $0.contains("super+c=") || $0.contains("super+v=") || $0.contains("super+0=") })
    }

    @Test(arguments: [(CGFloat(13), "13"), (12.5, "12.5"), (14.25, "14.25"), (1, "6"), (500, "72"), (.nan, "13")])
    func fontSizeIsPosixAndClamped(size: CGFloat, rendered: String) {
        var configuration = TerminalConfiguration()
        configuration.fontSize = size
        #expect(configuration.ghosttyConfigLines.contains("font-size = \(rendered)"))
    }

    @Test func customValuesAndEscapeHatch() {
        var configuration = TerminalConfiguration()
        configuration.fallbackFontFamilies = []
        configuration.cursorBlinks = true
        configuration.cursorStyle = .bar
        configuration.paddingX = -3
        configuration.keyEquivalents = KeyEquivalentPolicy(reserved: [])
        configuration.additionalGhosttyConfig = ["mouse-hide-while-typing = true"]
        let lines = configuration.ghosttyConfigLines
        #expect(lines.filter { $0.hasPrefix("font-family") } == ["font-family = JetBrains Mono"])
        #expect(lines.contains("cursor-style = bar"))
        #expect(lines.contains("cursor-style-blink = true"))
        #expect(lines.contains("window-padding-x = 0"))
        #expect(!lines.contains { $0.hasPrefix("keybind") })
        #expect(lines.last == "mouse-hide-while-typing = true")
        #expect(configuration.renderedGhosttyConfig.hasSuffix("mouse-hide-while-typing = true\n"))
    }

    /// libghostty rejects the whole config on any bad line (and falls back to its defaults), so
    /// every line CODD renders must parse.
    @Test @MainActor func libghosttyAcceptsTheDefaultConfig() {
        let diagnostics = TerminalRuntime.diagnostics(for: .default)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
    }

    @Test @MainActor func libghosttyReportsABadLine() {
        var configuration = TerminalConfiguration()
        configuration.additionalGhosttyConfig = ["no-such-option = 1"]
        #expect(!TerminalRuntime.diagnostics(for: configuration).isEmpty)
    }

    @Test func childEnvironmentFollowsTheM1Decision() {
        let environment = TerminalRuntime.childEnvironment
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "ghostty")
        #expect(environment["TERM_PROGRAM_VERSION"] == TerminalRuntime.libghosttyVersion)
        #expect(TerminalRuntime.libghosttyVersion.contains("1e9e14af5"), "\(TerminalRuntime.libghosttyVersion)")
    }
}
