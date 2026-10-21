import Darwin
import Foundation
import Testing
@testable import CoddClaudeSettings

@Suite("DesktopStatusLine")
struct DesktopStatusLineTests {
    @Test func commandFormat() {
        let desktop = DesktopStatusLine(binary: "/r/bin/codd-statusline", dataRoot: "/r")
        #expect(desktop.command(chain: nil) == "if [ -x '/r/bin/codd-statusline' ]; then '/r/bin/codd-statusline' --data-root '/r'; fi")
        // base64("printf 'X'") == "cHJpbnRmICdYJw=="
        #expect(desktop.command(chain: "printf 'X'") ==
            "if [ -x '/r/bin/codd-statusline' ]; then '/r/bin/codd-statusline' --data-root '/r' --chain-b64 cHJpbnRmICdYJw==; else /bin/sh -c 'printf '\\''X'\\'''; fi")
        #expect(desktop.command(chain: "") == desktop.command(chain: nil))
        #expect(DesktopStatusLine(dataRoot: "/a b/CODD").binary == "/a b/CODD/bin/codd-statusline")
    }

    @Test func parsesBackWithSpacesAndQuotes() {
        let root = "/Users/u/Library/Application Support/it's/CODD"
        let desktop = DesktopStatusLine(dataRoot: root)
        let chains: [String?] = [nil, "printf 'X'", "~/.hook-tap/statusline.sh", "a && b; fi\nif true; then echo '\\'; fi", "中文 'q' \"d\" $HOME `x`"]
        for chain in chains {
            let parsed = DesktopStatusLine.parse(desktop.command(chain: chain))
            #expect(parsed?.binary == desktop.binary)
            #expect(parsed?.dataRoot == root)
            #expect(parsed?.chain == chain, "\(String(describing: chain))")
        }
    }

    @Test func parseRefusesAnythingElse() {
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let good = desktop.command(chain: "printf 'X'")
        let rejected = [
            "~/.hook-tap/statusline.sh",
            good.replacingOccurrences(of: "else /bin/sh -c 'printf '\\''X'\\'''", with: "else /bin/sh -c 'printf Y'"),
            good.replacingOccurrences(of: "cHJpbnRmICdYJw==", with: "cHJpbnRmICdYJw"),
            good + " ",
            good.replacingOccurrences(of: "then '/r/bin/codd-statusline'", with: "then '/other/bin/codd-statusline'"),
            desktop.command(chain: nil).replacingOccurrences(of: "; fi", with: "; else :; fi"),
            "if [ -x '/r/bin/codd-statusline' ]; then '/r/bin/codd-statusline' --data-root '/r",
            "echo /bin/codd-statusline --data-root",
        ]
        for command in rejected {
            #expect(DesktopStatusLine.parse(command) == nil, "\(command)")
        }
    }

    /// A fake binary that prints its arguments, under a data root with a space and a quote.
    private func fakeRoot(_ tmp: TempDir) throws -> DesktopStatusLine {
        let root = "\(tmp.path)/Application Support/it's/CODD"
        let desktop = DesktopStatusLine(dataRoot: root)
        try tmp.write("Application Support/it's/CODD/bin/codd-statusline",
                      "#!/bin/sh\ncat >/dev/null\nprintf 'BIN'\nfor a in \"$@\"; do printf '|%s' \"$a\"; done\n", mode: 0o755)
        return desktop
    }

    @Test func thenBranchRunsTheBinary() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let desktop = try fakeRoot(tmp)
        let withChain = try runShell(desktop.command(chain: "printf 'X'"), stdin: "{}")
        #expect(withChain.output == "BIN|--data-root|\(desktop.dataRoot)|--chain-b64|cHJpbnRmICdYJw==")
        #expect(withChain.status == 0)
        let bare = try runShell(desktop.command(chain: nil), stdin: "{}")
        #expect(bare.output == "BIN|--data-root|\(desktop.dataRoot)")
    }

    @Test func elseBranchRunsTheChainWhenTheBinaryIsGone() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let desktop = try fakeRoot(tmp)
        try FileManager.default.removeItem(atPath: desktop.binary)
        let result = try runShell(desktop.command(chain: "printf 'X'"), stdin: "{}")
        #expect(result.output == "X")
        #expect(result.status == 0)
        // The chain reads the same stdin Claude sent.
        let cat = try runShell(desktop.command(chain: "cat; exit 3"), stdin: "{\"rate_limits\":null}")
        #expect(cat.output == "{\"rate_limits\":null}")
        #expect(cat.status == 3)
        // No chain and no binary: nothing printed, success.
        let none = try runShell(desktop.command(chain: nil), stdin: "{}")
        #expect(none.output == "")
        #expect(none.status == 0)
    }

    @Test func chainBase64RoundTrip() {
        for chain in ["x", "printf 'X'", "中文", "a\nb"] {
            #expect(ChainBase64.decode(ChainBase64.encode(chain)) == chain)
        }
        #expect(ChainBase64.decode("eA") == nil)
        #expect(ChainBase64.decode("") == nil)
        #expect(ChainBase64.decode("/w==") == nil) // 0xFF is not UTF-8
        #expect(ChainBase64.find(in: "x --chain-b64   eA== y") == .decoded("x"))
        #expect(ChainBase64.find(in: "x --chain-b64") == .absent)
        #expect(ChainBase64.find(in: "x --chain-b64 eA") == .undecodable)
    }
}
