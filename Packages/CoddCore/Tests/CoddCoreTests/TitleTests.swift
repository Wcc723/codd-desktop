import Testing
@testable import CoddCore

@Suite("Terminal title glyphs")
struct TitleTests {
    @Test(arguments: [
        ("◐ 修正登入 API 401", TitleActivity?.some(.busy), "修正登入 API 401"),
        ("◑ 修正登入 API 401", .busy, "修正登入 API 401"),
        ("✳ 修正登入 API 401", .idle, "修正登入 API 401"),
        ("✳\u{FE0F} emoji form", .idle, "emoji form"),
        ("  ◐   spaced  ", .busy, "spaced"),
        ("◐", .busy, ""),
        ("✳Claude Code", .idle, "Claude Code"),
        ("zsh: ~/Project", nil, "zsh: ~/Project"),
        ("◒ other spinner", nil, "◒ other spinner"),
        ("", nil, ""),
    ] as [(String, TitleActivity?, String)])
    func parse(raw: String, activity: TitleActivity?, text: String) {
        let t = TerminalTitle.parse(raw)
        #expect(t.activity == activity)
        #expect(t.text == text)
    }

    @Test func trackerDedupesSpinnerFlips() {
        var tracker = TerminalTitleTracker()
        #expect(tracker.ingest("◐ Task") == TerminalTitle(activity: .busy, text: "Task"))
        #expect(tracker.ingest("◑ Task") == nil)
        #expect(tracker.ingest("◐ Task") == nil)
        #expect(tracker.ingest("◐ Task renamed") == TerminalTitle(activity: .busy, text: "Task renamed"))
        #expect(tracker.ingest("✳ Task renamed") == TerminalTitle(activity: .idle, text: "Task renamed"))
        #expect(tracker.ingest("✳ Task renamed") == nil)
        #expect(tracker.current == TerminalTitle(activity: .idle, text: "Task renamed"))
    }
}
