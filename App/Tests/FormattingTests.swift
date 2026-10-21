import AppKit
import Foundation
import Testing
@testable import CODD
import CoddUI

@Suite("Formatting")
struct FormattingTests {
    @Test("compact durations follow CODD's voice", arguments: [
        (0.0, "0s"), (45, "45s"), (60, "1m"), (72, "1m12s"), (180, "3m"), (185, "3m"), (720, "12m"),
        (3720, "1h02m"), (7200, "2h"), (11400, "3h10m"), (86400, "1d"), (93600, "1d02h"), (183600, "2d03h"),
    ])
    func compact(seconds: Double, expected: String) {
        #expect(DurationFormat.compact(seconds) == expected)
    }

    @Test func negativeDurationsClampToZero() {
        #expect(DurationFormat.compact(-5) == "0s")
    }

    @Test func countdownUsesMinuteResolution() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DurationFormat.countdown(to: now.addingTimeInterval(2 * 3600 + 57 * 60 + 30), now: now) == "2h57m後")
        #expect(DurationFormat.countdown(to: now.addingTimeInterval(3 * 86400 + 3600 + 18 * 60), now: now) == "3d01h後")
        #expect(DurationFormat.countdown(to: now.addingTimeInterval(20), now: now) == "1m後")
        #expect(DurationFormat.countdown(to: now.addingTimeInterval(-1), now: now) == "已重置")
    }

    @Test func agoDropsSecondsAfterAMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DurationFormat.ago(now.addingTimeInterval(-12), now: now) == "12s 前")
        #expect(DurationFormat.ago(now.addingTimeInterval(-185), now: now) == "3m 前")
    }

    @Test func shortPathKeepsLastTwoLevels() {
        #expect(PathFormat.short("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend")
            == "~/…/orb-toolkit-suite/orb-toolkit-backend")
        #expect(PathFormat.short("~/Github/Gear3D") == "~/Github/Gear3D")
        #expect(PathFormat.lastComponent("~/Github/UsageBar") == "UsageBar")
    }

    @Test func resetLabelShowsWeekdayForOtherDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 10, minute: 42)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 13, minute: 39)))
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12, minute: 0)))
        #expect(ClockFormat.resetLabel(today, now: now, calendar: calendar) == "13:39")
        #expect(ClockFormat.resetLabel(sunday, now: now, calendar: calendar) == "10/18 週日 12:00")
    }

    @Test func termMarkupParsesSpansAndKeepsUnknownTags() {
        let runs = TermMarkup.parse("<d>></d> hi <cc>●</cc> <div class=\"x\"><w>Read</w>")
        #expect(runs.map(\.text) == [">", " hi ", "●", " <div class=\"x\">", "Read"])
        #expect(runs[0].spans == [.d])
        #expect(runs[2].spans == [.cc])
        #expect(runs[3].spans.isEmpty)
        #expect(runs[4].spans == [.w])
    }

    @Test func termMarkupNests() {
        let runs = TermMarkup.parse("<cc>a<w>b</w>c</cc>")
        #expect(runs.map(\.spans) == [[.cc], [.cc, .w], [.cc]])
    }

    @Test func svgTokenizerSplitsSignedNumbers() {
        let tokens = SVGPath.tokenize("M2 11h3.5l2-5.5 4 10")
        #expect(tokens == [.command("M"), .number(2), .number(11), .command("h"), .number(3.5), .command("l"),
                           .number(2), .number(-5.5), .number(4), .number(10)])
    }
}

@Suite("State styles")
struct StateStyleTests {
    /// SPEC §1 glyph allow-list (no emoji-presentation characters).
    static let allowList: Set<String> = ["▸", "▾", "◆", "◇", "●", "○", "◌", "◉", "▲", "✕", "⟲", "↻", "↗", "→", "←", "↑", "↓",
                                         "⋯", "⠿", "■", "□", "▮", "▯", "$", "⌘", "⌥", "⌃", "⇧", "⏎", "⎋", "✓", "✎", "★"]

    @Test func glyphsComeFromTheAllowList() {
        for state in SessionState.allCases {
            #expect(Self.allowList.contains(StateStyle.of(state).glyph), "\(state)")
        }
    }

    @Test func onlyWaitingPulses() {
        for state in SessionState.allCases {
            #expect(StateStyle.of(state).pulses == (state == .waiting), "\(state)")
        }
    }

    @Test func attentionIsWaitingPlusError() {
        #expect(SessionState.allCases.filter(\.needsAttention) == [.waiting, .error])
        #expect(!SessionState.exited.isLive && !SessionState.stopped.isLive && SessionState.shell.isLive)
    }

    @Test func quotaTones() {
        #expect(QuotaWindow(remainingPercent: 91).tone == .ok)
        #expect(QuotaWindow(remainingPercent: 46).tone == .warn)
        #expect(QuotaWindow(remainingPercent: 15).tone == .crit)
        #expect(QuotaWindow(remainingPercent: 100, started: false).tone == .muted)
    }
}
