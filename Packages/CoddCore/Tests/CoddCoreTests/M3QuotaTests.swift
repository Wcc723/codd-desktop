import Foundation
import Testing
@testable import CoddCore

private func at(_ seconds: Double) -> Date { referenceNow.addingTimeInterval(seconds) }
private let day: TimeInterval = 86_400

private func window(_ used: Double, resetIn seconds: Double?) -> QuotaWindow {
    QuotaWindow(usedPercent: used, resetsAt: seconds.map(at))
}

private func statusLine(_ ref: QuotaAccountRef, five: QuotaWindow?, week: QuotaWindow?, capturedAt: Date) -> QuotaObservation {
    .fromStatusLine(account: ref, fiveHour: five, weekly: week, capturedAt: capturedAt)
}

@Suite("Quota book (D7)")
struct QuotaBookTests {
    @Test func aNewerCaptureWinsPerWindow() {
        var book = QuotaBook()
        let changed1 = book.ingest(statusLine(.number(3), five: window(9, resetIn: 3600), week: window(85, resetIn: 2 * day), capturedAt: at(0)))
        #expect(changed1)
        let changed2 = book.ingest(statusLine(.number(3), five: window(12, resetIn: 3600), week: nil, capturedAt: at(30)))
        #expect(changed2)
        let e = book.entry(.number(3))
        #expect(e?.fiveHour?.window.usedPercent == 12)
        #expect(e?.fiveHour?.capturedAt == at(30))
        #expect(e?.weekly?.window.usedPercent == 85) // missing in the newer report: kept
        #expect(e?.weekly?.capturedAt == at(0))
    }

    @Test func anOlderCaptureNeverReplaces() {
        var book = QuotaBook()
        book.ingest(statusLine(.number(3), five: window(9, resetIn: 3600), week: window(85, resetIn: 2 * day), capturedAt: at(0)))
        let cswap = QuotaObservation(account: .number(3), fiveHour: window(1, resetIn: 3600), weekly: window(50, resetIn: 2 * day),
                                     source: .cswap, capturedAt: at(-120))
        let changed3 = book.ingest(cswap)
        #expect(!changed3)
        #expect(book.entry(.number(3))?.fiveHour?.source == .statusline)
        #expect(book.entry(.number(3))?.weekly?.window.usedPercent == 85)
        // The same capture again changes nothing either.
        let changed4 = book.ingest(statusLine(.number(3), five: window(9, resetIn: 3600), week: nil, capturedAt: at(0)))
        #expect(!changed4)
    }

    @Test func anEmptyObservationCreatesNothing() {
        var book = QuotaBook()
        let changed5 = book.ingest(statusLine(.number(1), five: nil, week: nil, capturedAt: at(0)))
        #expect(!changed5)
        #expect(book.entries.isEmpty)
        #expect(book.entry(.number(1)) == nil)
    }

    @Test func scopedWindowsComeFromCswapOnly() {
        var book = QuotaBook()
        let fable = [NamedQuotaWindow(name: "Fable", window: window(0, resetIn: 3 * day))]
        book.ingest(QuotaObservation(account: .number(3), fiveHour: window(5, resetIn: 3600), weekly: window(80, resetIn: 3 * day),
                                     scoped: fable, source: .cswap, capturedAt: at(-180)))
        // A newer status-line report replaces 5h and 1w but keeps cswap's scoped windows.
        var sl = statusLine(.number(3), five: window(9, resetIn: 3600), week: window(85, resetIn: 3 * day), capturedAt: at(0))
        sl.scoped = [NamedQuotaWindow(name: "Fable", window: window(99, resetIn: 3 * day))]
        let changed6 = book.ingest(sl)
        #expect(changed6)
        let e = book.entry(.number(3))
        #expect(e?.weekly?.source == .statusline)
        #expect(e?.scoped == fable)
        #expect(e?.scopedCapturedAt == at(-180))
        // A cswap observation without scoped windows keeps them too.
        book.ingest(QuotaObservation(account: .number(3), fiveHour: nil, weekly: nil, source: .cswap, capturedAt: at(60)))
        #expect(book.entry(.number(3))?.scoped == fable)
    }

    @Test func newestSourceAndAge() {
        var book = QuotaBook()
        book.ingest(QuotaObservation(account: .number(2), fiveHour: window(2, resetIn: 3600), weekly: window(54, resetIn: day),
                                     source: .cswap, capturedAt: at(-180)))
        #expect(book.entry(.number(2))?.newest?.source == .cswap)
        #expect(book.entry(.number(2))?.newest?.at == at(-180))
        book.ingest(statusLine(.number(2), five: window(3, resetIn: 3600), week: nil, capturedAt: at(-12)))
        #expect(book.entry(.number(2))?.newest?.source == .statusline)
        #expect(book.entry(.number(2))?.newest?.at == at(-12))
        #expect(QuotaEntry().newest == nil)
        // A tie goes to the status line.
        let tie = QuotaEntry(fiveHour: SourcedWindow(window: window(1, resetIn: 1), source: .cswap, capturedAt: at(0)),
                             weekly: SourcedWindow(window: window(1, resetIn: 1), source: .statusline, capturedAt: at(0)))
        #expect(tie.newest?.source == .statusline)
    }

    @Test func cswapPaceBelongsToCswapsWeeklyWindow() {
        var book = QuotaBook()
        let pace = WeeklyPaceInfo(aheadOfPace: true, projectedExhaustionAt: at(day))
        book.ingest(QuotaObservation(account: .number(3), fiveHour: nil, weekly: window(85, resetIn: 3 * day), pace: pace,
                                     source: .cswap, capturedAt: at(-60)))
        #expect(book.entry(.number(3))?.pace == pace)
        #expect(book.pace(for: .number(3), now: referenceNow) == pace)
        // A newer status-line weekly window drops it; the pace is then computed from that window.
        book.ingest(statusLine(.number(3), five: nil, week: window(60, resetIn: 5 * day), capturedAt: at(0)))
        #expect(book.entry(.number(3))?.pace == nil)
        let computed = book.pace(for: .number(3), now: referenceNow)
        #expect(computed == WeeklyPaceCalculator.compute(usedPercent: 60, resetsAt: at(5 * day), measuredAt: at(0)))
        #expect(computed?.aheadOfPace == true)
        // Past the weekly reset the window rolled over: no pace.
        #expect(book.pace(for: .number(3), now: at(6 * day)) == nil)
        #expect(book.pace(for: .number(9), now: referenceNow) == nil)
    }

    @Test func fromCswapUsesLastGoodAndFetchedAt() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let s = try f.read()
        let account3 = try #require(s.account(3))
        let o = try #require(QuotaObservation.fromCswap(account3))
        #expect(o.account == .number(3))
        #expect(o.source == .cswap)
        #expect(o.capturedAt == Date(timeIntervalSince1970: 1_792_032_108))
        #expect(o.fiveHour == QuotaWindow(usedPercent: 9, resetsAt: JSDate.date(fromISO: "2026-10-15T05:39:00Z")))
        #expect(o.weekly?.usedPercent == 85)
        #expect(o.scoped.map(\.name) == ["Fable"])
        #expect(o.pace == nil) // the cache file has no pace fields; the book computes it
        #expect(QuotaObservation.fromCswap(CswapStateAccount(number: 4)) == nil)
        // `--json` windows carry cswap's own pace fields.
        let w = CswapWindow(pct: 85, resetsAt: at(3 * day), expectedPct: 52.1, aheadOfPace: true, projectedExhaustionAt: at(day))
        let withPace = CswapStateAccount(number: 3, usage: CswapUsage(sevenDay: w), usageFetchedAt: at(0))
        #expect(QuotaObservation.fromCswap(withPace)?.pace == WeeklyPaceInfo(aheadOfPace: true, projectedExhaustionAt: at(day), expectedPercent: 52.1))
    }

    @Test func removeAnAccount() {
        var book = QuotaBook()
        book.ingest(statusLine(.defaultLogin, five: window(1, resetIn: 60), week: nil, capturedAt: at(0)))
        let changed7 = book.remove(.defaultLogin)
        #expect(changed7)
        let changed8 = book.remove(.defaultLogin)
        #expect(!changed8)
        #expect(book.entries.isEmpty)
    }

    @Test func accountRefKeys() throws {
        #expect(QuotaAccountRef.number(3).key == "3")
        #expect(QuotaAccountRef.defaultLogin.key == "default")
        #expect(QuotaAccountRef(key: "3") == .number(3))
        #expect(QuotaAccountRef(key: "default") == .defaultLogin)
        #expect(QuotaAccountRef(key: "x") == nil)
        #expect(QuotaAccountRef(key: "-1") == nil)
        let data = try JSONEncoder().encode([QuotaAccountRef.number(2), .defaultLogin])
        #expect(String(decoding: data, as: UTF8.self) == #"["2","default"]"#)
        #expect(try JSONDecoder().decode([QuotaAccountRef].self, from: data) == [.number(2), .defaultLogin])
    }
}

@Suite("Quota store (quota.json)")
struct QuotaStoreTests {
    func sampleBook() -> QuotaBook {
        var book = QuotaBook(lastAutoSwitchAt: at(-100))
        book.ingest(QuotaObservation(
            account: .number(3), fiveHour: window(9, resetIn: 10_620), weekly: window(85, resetIn: 263_880),
            scoped: [NamedQuotaWindow(name: "Fable", window: window(0, resetIn: 263_880))],
            pace: WeeklyPaceInfo(aheadOfPace: true, projectedExhaustionAt: at(day)), source: .cswap, capturedAt: at(-12)))
        book.ingest(statusLine(.number(3), five: window(10.5, resetIn: 10_620), week: nil, capturedAt: at(0)))
        book.ingest(statusLine(.defaultLogin, five: window(1, resetIn: nil), week: window(2, resetIn: 5 * day), capturedAt: at(-5)))
        return book
    }

    @Test func roundTripAndShape() throws {
        let temp = try TempDir("codd-m3-quota")
        defer { temp.remove() }
        let store = QuotaStore(dataRoot: temp.url)
        #expect(store.url.lastPathComponent == "quota.json")
        let book = sampleBook()
        try store.save(book)
        #expect(store.load() == book)
        let json = try #require(JSONValue.parse(try Data(contentsOf: store.url)))
        #expect(json["v"] == .number(1))
        #expect(Set(json["accounts"]?.objectValue.map { Array($0.keys) } ?? []) == ["3", "default"])
        let three = try json.require("accounts").require("3")
        #expect(three["fiveHour"]?["source"] == .string("statusline"))
        #expect(three["fiveHour"]?["usedPercent"] == .number(10.5))
        #expect(three["fiveHour"]?["capturedAt"] == .string("2026-10-15T02:42:00.000Z"))
        #expect(three["weekly"]?["source"] == .string("cswap"))
        #expect(three["weekly"]?["resetsAt"] == .string(JSDate.isoString(at(263_880))))
        #expect(three["scoped"]?.arrayValue?.first?["name"] == .string("Fable"))
        #expect(three["pace"]?["aheadOfPace"] == .bool(true))
        #expect(json["autoSwitch"]?["lastAt"] == .string(JSDate.isoString(at(-100))))
        #expect(json["accounts"]?["default"]?["fiveHour"]?["resetsAt"] == nil)
    }

    @Test func lastAutoSwitchAtRoundTrip() throws {
        let temp = try TempDir("codd-m3-quota")
        defer { temp.remove() }
        let store = QuotaStore(dataRoot: temp.url)
        var book = QuotaBook()
        try store.save(book)
        #expect(store.load().lastAutoSwitchAt == nil)
        book.lastAutoSwitchAt = at(42)
        try store.save(book)
        #expect(store.load().lastAutoSwitchAt == at(42))
        #expect(!String(decoding: try Data(contentsOf: store.url), as: UTF8.self).isEmpty)
    }

    @Test func fileModeIs0600() throws {
        let temp = try TempDir("codd-m3-quota")
        defer { temp.remove() }
        let store = QuotaStore(dataRoot: temp.url.appendingPathComponent("nested"))
        try store.save(sampleBook())
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func missingAndCorruptFilesLoadEmptyAndAreReplaced() throws {
        let temp = try TempDir("codd-m3-quota")
        defer { temp.remove() }
        let store = QuotaStore(dataRoot: temp.url)
        #expect(store.load() == QuotaBook())
        for corrupt in ["{\"v\":1,\"accounts\":{\"3\":", "[]", "{\"accounts\":{}}", "{\"v\":0}", "\u{0}\u{1}"] {
            try Data(corrupt.utf8).write(to: store.url)
            #expect(store.load() == QuotaBook(), "\(corrupt)")
        }
        try store.save(sampleBook())
        #expect(store.load() == sampleBook())
    }

    @Test func aNewerVersionLoadsEmptyAndIsNeverOverwritten() throws {
        let temp = try TempDir("codd-m3-quota")
        defer { temp.remove() }
        let store = QuotaStore(dataRoot: temp.url)
        let newer = Data(#"{"v":2,"accounts":{"3":{"fiveHour":{"usedPercent":1,"source":"statusline","capturedAt":"2026-10-15T02:42:00.000Z"}}}}"#.utf8)
        try newer.write(to: store.url)
        #expect(store.load() == QuotaBook())
        #expect(throws: QuotaStoreError.newerVersion(2)) { try store.save(sampleBook()) }
        #expect(try Data(contentsOf: store.url) == newer)
    }

    @Test func badEntriesAndWindowsAreSkipped() {
        let json = JSONValue.parse(Data("""
        {"v":1,"accounts":{
          "3":{"fiveHour":{"usedPercent":"x","source":"statusline","capturedAt":"2026-10-15T02:42:00Z"},
               "weekly":{"usedPercent":85,"source":"statusline","capturedAt":"2026-10-15T02:42:00Z"},
               "scoped":[{"name":"","usedPercent":1},{"name":"Fable","usedPercent":2}]},
          "4":{"weekly":{"usedPercent":1,"source":"elsewhere","capturedAt":"2026-10-15T02:42:00Z"}},
          "nope":{"weekly":{"usedPercent":1,"source":"cswap","capturedAt":"2026-10-15T02:42:00Z"}},
          "5":"string"},
         "autoSwitch":{"lastAt":12}}
        """.utf8))
        let book = QuotaBook(json: json ?? .null)
        #expect(Set(book.entries.keys) == [.number(3)])
        #expect(book.entry(.number(3))?.fiveHour == nil)
        #expect(book.entry(.number(3))?.weekly?.window.usedPercent == 85)
        #expect(book.entry(.number(3))?.scoped.map(\.name) == ["Fable"])
        #expect(book.lastAutoSwitchAt == Date(timeIntervalSince1970: 12))
    }

    @Test func codableMatchesTheFileFormat() throws {
        let book = sampleBook()
        let decoded = try JSONDecoder().decode(QuotaBook.self, from: try JSONEncoder().encode(book))
        #expect(decoded == book)
        let entry = try #require(book.entry(.number(3)))
        #expect(try JSONDecoder().decode(QuotaEntry.self, from: try JSONEncoder().encode(entry)) == entry)
        let w = try #require(entry.weekly)
        #expect(try JSONDecoder().decode(SourcedWindow.self, from: try JSONEncoder().encode(w)) == w)
    }
}

@Suite("Quota attribution (D6)")
struct QuotaAttributionTests {
    /// #2 resets 10/16 14:59, #3 resets 10/18 04:00 (SPEC §5).
    var book: QuotaBook {
        var b = QuotaBook()
        b.ingest(QuotaObservation(account: .number(2), fiveHour: nil, weekly: QuotaWindow(usedPercent: 54, resetsAt: reset2),
                                  source: .cswap, capturedAt: at(-180)))
        b.ingest(QuotaObservation(account: .number(3), fiveHour: nil, weekly: QuotaWindow(usedPercent: 85, resetsAt: reset3),
                                  source: .cswap, capturedAt: at(-12)))
        b.ingest(QuotaObservation(account: .number(1), fiveHour: nil, weekly: QuotaWindow(usedPercent: 0, resetsAt: nil),
                                  source: .cswap, capturedAt: at(-180)))
        return b
    }
    let reset2 = JSDate.date(fromISO: "2026-10-16T14:59:00Z") ?? Date()
    let reset3 = JSDate.date(fromISO: "2026-10-18T04:00:00Z") ?? Date()

    func attribute(_ key: AccountKey, weekly: Date?, active: Int? = 3, hasCswap: Bool = true, lastSwitch: SwitchMark? = nil,
                   profileKeys: [String: Int] = [:], now: Date = referenceNow) -> QuotaAttributionResult {
        QuotaAttribution.account(for: key, weeklyResetsAt: weekly, activeAccount: active, hasCswapAccounts: hasCswap,
                                 lastSwitch: lastSwitch, book: book, profileKeys: profileKeys, now: now)
    }

    @Test func constants() {
        #expect(QuotaAttribution.switchGrace == 90)
        #expect(QuotaAttribution.resetTolerance == 120)
    }

    @Test func cswapKeysNameTheirAccount() {
        #expect(attribute(.cswap(2), weekly: nil) == QuotaAttributionResult(account: .number(2)))
        #expect(attribute(.cswap(2), weekly: reset3, lastSwitch: SwitchMark(at: at(-10), from: 3, to: 1)).account == .number(2))
    }

    @Test func defaultWithoutASwitchIsTheActiveAccount() {
        #expect(attribute(.default, weekly: reset3) == QuotaAttributionResult(account: .number(3)))
        #expect(attribute(.default, weekly: nil) == QuotaAttributionResult(account: .number(3)))
        #expect(attribute(.default, weekly: reset3.addingTimeInterval(119)).account == .number(3))
        // A switch long ago does not matter.
        #expect(attribute(.default, weekly: reset3, lastSwitch: SwitchMark(at: at(-600), from: 2, to: 3)).account == .number(3))
        // Cswap accounts exist but none is active: nobody to give it to.
        #expect(attribute(.default, weekly: reset3, active: nil) == .dropped)
    }

    @Test func insideTheGraceAReportMatchingFromGoesToFrom() {
        let mark = SwitchMark(at: at(-30), from: 3, to: 2)
        #expect(attribute(.default, weekly: reset3.addingTimeInterval(-100), active: 2, lastSwitch: mark) == QuotaAttributionResult(account: .number(3)))
    }

    @Test func insideTheGraceAReportMatchingToGoesToTo() {
        let mark = SwitchMark(at: at(-89), from: 3, to: 2)
        #expect(attribute(.default, weekly: reset2, active: 2, lastSwitch: mark) == QuotaAttributionResult(account: .number(2)))
    }

    @Test func insideTheGraceAnythingElseIsDropped() {
        let mark = SwitchMark(at: at(-30), from: 3, to: 2)
        #expect(attribute(.default, weekly: reset2.addingTimeInterval(500), active: 2, lastSwitch: mark) == .dropped)
        #expect(attribute(.default, weekly: nil, active: 2, lastSwitch: mark) == .dropped)
        // To an account without a known weekly reset (#1): the report cannot be told apart.
        #expect(attribute(.default, weekly: reset3.addingTimeInterval(9999), active: 1, lastSwitch: SwitchMark(at: at(-5), from: 3, to: 1)) == .dropped)
    }

    @Test func outsideTheGraceTheActiveAccountWins() {
        let mark = SwitchMark(at: at(-90), from: 3, to: 2)
        #expect(attribute(.default, weekly: reset2, active: 2, lastSwitch: mark) == QuotaAttributionResult(account: .number(2)))
        #expect(attribute(.default, weekly: reset2.addingTimeInterval(9999), active: 2, lastSwitch: mark).account == .number(2))
    }

    @Test func outsideTheGraceAnotherAccountsResetMeansALoginChange() {
        // Active is #3, but the report carries #2's weekly reset: the login moved to #2.
        let r = attribute(.default, weekly: reset2.addingTimeInterval(60))
        #expect(r == QuotaAttributionResult(account: .number(2), suspectedLoginChange: true))
        // Two other accounts with the same reset: suspected, but dropped.
        var b = book
        b.ingest(QuotaObservation(account: .number(4), fiveHour: nil, weekly: QuotaWindow(usedPercent: 1, resetsAt: reset2),
                                  source: .cswap, capturedAt: at(0)))
        let ambiguous = QuotaAttribution.account(for: .default, weeklyResetsAt: reset2, activeAccount: 3, hasCswapAccounts: true,
                                                 lastSwitch: nil, book: b, profileKeys: [:], now: referenceNow)
        #expect(ambiguous == QuotaAttributionResult(account: nil, suspectedLoginChange: true))
    }

    @Test func cfgKeysOfKnownProfiles() {
        let key = AccountKey.from(claudeConfigDir: "/tmp/codd-test/cswap/sessions/2-x", home: "/Users/u")
        guard case .other(let raw) = key else {
            Issue.record("expected a cfg key")
            return
        }
        #expect(attribute(key, weekly: reset2, profileKeys: [raw: 2]) == QuotaAttributionResult(account: .number(2)))
        #expect(attribute(.other("cfg-0123456789abcdef"), weekly: reset3, profileKeys: [raw: 2]) == .dropped)
        #expect(attribute(.other("cfg-0123456789abcdef"), weekly: reset3, hasCswap: false) == .dropped)
    }

    @Test func noCswapAccountsMeansTheDefaultLogin() {
        #expect(attribute(.default, weekly: reset3, active: nil, hasCswap: false) == QuotaAttributionResult(account: .defaultLogin))
        #expect(attribute(.default, weekly: nil, active: nil, hasCswap: false, lastSwitch: SwitchMark(at: at(-1), from: nil, to: nil)).account == .defaultLogin)
    }
}

@Suite("Weekly pace (pace.py port)")
struct WeeklyPaceTests {
    /// 40 % used two days into the week: expected 2/7 = 28.57 %, 11.4 points over: not ahead.
    @Test func fortyPercentAfterTwoDays() throws {
        let measured = at(0)
        let p = try #require(WeeklyPaceCalculator.compute(usedPercent: 40, resetsAt: at(5 * day), measuredAt: measured))
        #expect(abs((p.expectedPercent ?? 0) - 28.571428571428573) < 1e-9)
        #expect(!p.aheadOfPace)
        // 60 % to go at 40 % per 2 days = 3 days.
        #expect(p.projectedExhaustionAt == measured.addingTimeInterval(60 / (40 / 172_800)))
        #expect(abs((p.projectedExhaustionAt?.timeIntervalSince(measured) ?? 0) - 3 * day) < 1e-6)
        #expect(p.willLastToReset == false) // 40 + 40/2d × 5d = 140 > 100
    }

    @Test func sixtyPercentAfterTwoDaysIsAhead() throws {
        let measured = at(0)
        let p = try #require(WeeklyPaceCalculator.compute(usedPercent: 60, resetsAt: at(5 * day), measuredAt: measured))
        #expect(p.aheadOfPace) // 31.4 points over expected
        #expect(p.projectedExhaustionAt == measured.addingTimeInterval(40 / (60 / 172_800)))
        #expect(p.willLastToReset == false)
    }

    @Test func thresholdIsFifteenPointsInclusive() throws {
        // 3.5 days in: expected exactly 50.
        let p = try #require(WeeklyPaceCalculator.compute(usedPercent: 65, resetsAt: at(3.5 * day), measuredAt: at(0)))
        #expect(p.expectedPercent == 50)
        #expect(p.aheadOfPace)
        let q = try #require(WeeklyPaceCalculator.compute(usedPercent: 64.9, resetsAt: at(3.5 * day), measuredAt: at(0)))
        #expect(!q.aheadOfPace)
        let slow = try #require(WeeklyPaceCalculator.compute(usedPercent: 20, resetsAt: at(3.5 * day), measuredAt: at(0)))
        #expect(slow.willLastToReset == true) // 20 + 20 = 40
    }

    @Test func silentForADayAfterTheReset() {
        // 12 h into the week: suppressed; exactly 24 h: computed.
        #expect(WeeklyPaceCalculator.compute(usedPercent: 50, resetsAt: at(6.5 * day), measuredAt: at(0)) == nil)
        #expect(WeeklyPaceCalculator.compute(usedPercent: 50, resetsAt: at(6 * day), measuredAt: at(0)) != nil)
        // Right at a reset boundary elapsed is 0.
        #expect(WeeklyPaceCalculator.compute(usedPercent: 50, resetsAt: at(7 * day), measuredAt: at(0)) == nil)
        #expect(WeeklyPaceCalculator.compute(usedPercent: .nan, resetsAt: at(3 * day), measuredAt: at(0)) == nil)
    }

    @Test func resetsAreRolledByWholePeriods() throws {
        let future = try #require(WeeklyPaceCalculator.compute(usedPercent: 40, resetsAt: at(12 * day), measuredAt: at(0)))
        let now = try #require(WeeklyPaceCalculator.compute(usedPercent: 40, resetsAt: at(5 * day), measuredAt: at(0)))
        #expect(future == now)
        // A stale reset one day in the past: the current window started then (1 day elapsed).
        let stale = try #require(WeeklyPaceCalculator.compute(usedPercent: 10, resetsAt: at(-1 * day), measuredAt: at(0)))
        #expect(abs((stale.expectedPercent ?? 0) - 100.0 / 7) < 1e-9)
        // Six days in the past: six days elapsed.
        let older = try #require(WeeklyPaceCalculator.compute(usedPercent: 10, resetsAt: at(-6 * day), measuredAt: at(0)))
        #expect(abs((older.expectedPercent ?? 0) - 600.0 / 7) < 1e-9)
    }

    @Test func edgeUsages() throws {
        let zero = try #require(WeeklyPaceCalculator.compute(usedPercent: 0, resetsAt: at(3 * day), measuredAt: at(0)))
        #expect(zero.projectedExhaustionAt == nil)
        #expect(zero.willLastToReset == true)
        #expect(!zero.aheadOfPace)
        let full = try #require(WeeklyPaceCalculator.compute(usedPercent: 100, resetsAt: at(3 * day), measuredAt: at(0)))
        #expect(full.projectedExhaustionAt == at(0))
        #expect(full.aheadOfPace)
        #expect(WeeklyPaceCalculator.period == 604_800)
        #expect(WeeklyPaceCalculator.suppressAfterReset == 86_400)
        #expect(WeeklyPaceCalculator.aheadThreshold == 15)
    }
}

@Suite("Account assembler")
struct AccountAssemblerTests {
    @Test func usageHealthToStatus() {
        #expect(AccountAssembler.usageStatus(.reloginRequired) == .reloginRequired)
        #expect(AccountAssembler.usageStatus(.failing("x")) == .unavailable)
        #expect(AccountAssembler.usageStatus(.fresh) == .ok)
        #expect(AccountAssembler.usageStatus(.stale) == .ok)
        #expect(AccountAssembler.usageStatus(.none) == .ok)
    }

    /// The health fixture: #3 active at 99 % used, #1 disabled, #2 needs a re-login → no target.
    @Test func aReloginAccountIsNeverATarget() throws {
        let f = try StateFixture("health")
        defer { f.temp.remove() }
        let accounts = AccountAssembler.accounts(state: try f.read(), book: QuotaBook(), now: referenceNow)
        let a2 = try #require(accounts.first { $0.number == 2 })
        #expect(a2.usageStatus == .reloginRequired)
        #expect(a2.usageHealth == .reloginRequired)
        #expect(accounts.first { $0.number == 3 }?.usageStatus == .unavailable)
        #expect(accounts.first { $0.number == 3 }?.usageIsLastGood == true)
        #expect(AutoSwitchPolicy.nextTarget(accounts: accounts, threshold: 2, now: referenceNow) == nil)
        let settings = AutoSwitchSettings(isEnabled: true)
        guard case .noEligibleTarget(let trigger) = AutoSwitchPolicy.evaluate(accounts: accounts, settings: settings, now: referenceNow,
                                                                                lastAutoSwitchAt: nil) else {
            Issue.record("expected noEligibleTarget")
            return
        }
        #expect(trigger.accountNumber == 3)
        // Re-enable #1: it becomes the target; #2 still never is.
        var enabled = accounts
        if let i = enabled.firstIndex(where: { $0.number == 1 }) { enabled[i].isDisabled = false }
        #expect(AutoSwitchPolicy.nextTarget(accounts: enabled, threshold: 2, now: referenceNow)?.number == 1)
    }

    @Test func theBookWinsOverTheSnapshotPerWindow() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let state = try f.read()
        var book = QuotaBook()
        for a in state.accounts { if let o = QuotaObservation.fromCswap(a) { book.ingest(o) } }
        book.ingest(.fromStatusLine(account: .number(3), fiveHour: nil, weekly: QuotaWindow(usedPercent: 88, resetsAt: JSDate.date(fromISO: "2026-10-18T04:00:00Z")),
                                    capturedAt: at(0)))
        let accounts = AccountAssembler.accounts(state: state, book: book, now: referenceNow)
        let a3 = try #require(accounts.first { $0.number == 3 })
        #expect(a3.weekly?.usedPercent == 88)
        #expect(a3.fiveHour?.usedPercent == 9) // cswap's, still the newest 5h
        #expect(a3.source == .statusline)
        #expect(a3.sourceAt == at(0))
        #expect(a3.usageAsOf == at(0))
        #expect(a3.plan == "MAX 20x")
        #expect(a3.usageHealth == .fresh)
        #expect(a3.scoped.map(\.name) == ["Fable"])
        let a2 = try #require(accounts.first { $0.number == 2 })
        #expect(a2.source == .cswap)
        #expect(a2.weekly?.status(at: referenceNow).remainingPercent == 46)
        #expect(accounts.map(\.number) == [1, 2, 3])
    }

    @Test func snapshotUsageFillsWhatTheBookLacks() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("2-north-example-com", settings: .symlinkToUser)
        try f.write("sessions/.2-north-example-com.cswap-stale-credentials", "")
        let state = try f.read()
        var book = QuotaBook()
        book.ingest(.fromStatusLine(account: .number(2), fiveHour: QuotaWindow(usedPercent: 4, resetsAt: nil), weekly: nil, capturedAt: at(-1)))
        let a2 = try #require(AccountAssembler.accounts(state: state, book: book, now: referenceNow).first { $0.number == 2 })
        #expect(a2.fiveHour?.usedPercent == 4)
        #expect(a2.weekly?.usedPercent == 54)
        #expect(a2.source == .statusline)
        #expect(a2.sessionProfile != nil)
        #expect(a2.sessionProfileStale)
        #expect(a2.sessionProfileSharesSettings == true)
        #expect(a2.displayName == "#2 藍鵲")
        expectNoAccountLeak(a2)
    }

    @Test func withoutCswapStateThereAreNoAccounts() {
        var book = QuotaBook()
        book.ingest(.fromStatusLine(account: .defaultLogin, fiveHour: QuotaWindow(usedPercent: 3, resetsAt: nil), weekly: nil, capturedAt: at(0)))
        #expect(AccountAssembler.accounts(state: nil, book: book, now: referenceNow).isEmpty)
        let empty = CswapStateSnapshot(root: URL(fileURLWithPath: "/tmp/x"), accounts: [], activeAccountNumber: nil, activeSource: .none, readAt: referenceNow)
        #expect(AccountAssembler.accounts(state: empty, book: book, now: referenceNow).isEmpty)
    }

    @Test func existingAccountInitializersStillCompile() {
        let a = Account(number: 5, alias: "x", isActive: true)
        #expect(a.plan == nil && a.sessionProfile == nil && !a.sessionProfileStale && a.usageHealth == .none && a.source == nil)
        #expect(Account(cswap: CswapAccount(number: 6)).usageHealth == .none)
    }
}

@Suite("E-mail redaction (D31)")
struct EmailRedactionTests {
    @Test func table() {
        let rows: [(String, String)] = [
            ("north@example.com", "•••@•••"),
            ("Switched to work@example.com (Account-3)", "Switched to •••@••• (Account-3)"),
            ("NORTH.Name+tag@Example.COM", "•••@•••"),
            ("a%b@x.io", "•••@•••"),
            ("north%40example.com", "•••@•••"),
            ("north@example.com's Organization", "•••@•••'s Organization"),
            ("a@b.co, c@d.org", "•••@•••, •••@•••"),
            ("mail a@b.com.", "mail •••@•••."),
            ("使用者 north@example.com 已切換", "使用者 •••@••• 已切換"),
            ("<x@sub.domain.example>", "<•••@•••>"),
            ("no email here", "no email here"),
            ("user@localhost", "user@localhost"),
            ("@example.com", "@example.com"),
            ("x@y.c", "x@y.c"),
            ("a@@b.com", "a@@b.com"),
            ("100% sure", "100% sure"),
            ("", ""),
        ]
        for (input, expected) in rows {
            #expect(EmailRedaction.redact(input) == expected, "\(input)")
        }
    }

    @Test func containsEmail() {
        #expect(EmailRedaction.containsEmail("token for north@example.com expired"))
        #expect(EmailRedaction.containsEmail("north%40example.com"))
        #expect(!EmailRedaction.containsEmail("Timed out waiting for ~/.claude.lock"))
        #expect(!EmailRedaction.containsEmail("•••@•••"))
        #expect(!EmailRedaction.containsEmail(EmailRedaction.redact("a@b.com and c@d.net")))
    }
}

/// M3 review fix (correctness-1): quota.json was keyed by slot number only, so after `cswap swap`
/// / `move` / `remove` the active login's reports went to another account (or were dropped for
/// good). Entries now carry the slot's login identity and follow it.
@Suite("Quota book identities (M3 review)")
struct QuotaIdentityTests {
    let resetX = JSDate.date(fromISO: "2026-10-16T14:59:00Z") ?? Date()
    let resetY = JSDate.date(fromISO: "2026-10-18T04:00:00Z") ?? Date()

    func observation(_ n: Int, used: Double, reset: Date, identity: String?, at seconds: Double = -60) -> QuotaObservation {
        QuotaObservation(account: .number(n), fiveHour: nil, weekly: QuotaWindow(usedPercent: used, resetsAt: reset),
                         source: .cswap, capturedAt: at(seconds), identity: identity)
    }

    @Test func swapMovesEachEntryToTheSlotThatHoldsItsLogin() {
        var book = QuotaBook()
        book.ingest(observation(2, used: 45, reset: resetX, identity: "x"))
        book.ingest(observation(3, used: 99, reset: resetY, identity: "y"))
        // `cswap swap 2 3`: the old #2 login is #3 now.
        let moved = book.reconcile(slots: [2: "y", 3: "x"])
        #expect(moved)
        #expect(book.entry(.number(3))?.identity == "x")
        #expect(book.entry(.number(3))?.weekly?.window.usedPercent == 45)
        #expect(book.entry(.number(2))?.weekly?.window.usedPercent == 99)
        let again = book.reconcile(slots: [2: "y", 3: "x"])
        #expect(!again, "stable once lined up")
        // The active #3's report (login x's reset) is #3's, not a suspected login change to #2.
        let r = QuotaAttribution.account(for: .default, weeklyResetsAt: resetX, activeAccount: 3, hasCswapAccounts: true,
                                         lastSwitch: nil, book: book, profileKeys: [:], now: referenceNow, slots: [2: "y", 3: "x"])
        #expect(r == QuotaAttributionResult(account: .number(3)))
    }

    @Test func removedOrReusedSlotsLoseTheirEntries() {
        var book = QuotaBook()
        book.ingest(observation(5, used: 10, reset: resetY, identity: "gone"))
        book.ingest(observation(2, used: 20, reset: resetX, identity: "old"))
        book.ingest(observation(3, used: 30, reset: resetY, identity: "three"))
        let dropped = book.reconcile(slots: [2: "new", 3: "three"])
        #expect(dropped)
        #expect(book.entry(.number(5)) == nil, "#5 removed from cswap")
        #expect(book.entry(.number(2)) == nil, "#2 now holds another login")
        #expect(book.entry(.number(3))?.weekly?.window.usedPercent == 30)
    }

    @Test func legacyEntriesWithoutIdentityAreDroppedWhereTheLoginIsKnown() {
        var book = QuotaBook(json: JSONValue.parse(Data(#"{"v":1,"accounts":{"2":{"weekly":{"usedPercent":45,"source":"statusline","capturedAt":"2026-10-15T02:00:00.000Z"}},"4":{"weekly":{"usedPercent":5,"source":"cswap","capturedAt":"2026-10-15T02:00:00.000Z"}},"default":{"weekly":{"usedPercent":7,"source":"statusline","capturedAt":"2026-10-15T02:00:00.000Z"}}}}"#.utf8)) ?? .null)
        #expect(book.entries.count == 3)
        // #2's login is known: the identity-less numbers could be another login's. #4's is not (D1 list).
        let slots: [Int: String?] = [2: "x", 4: nil]
        let changed = book.reconcile(slots: slots)
        #expect(changed)
        #expect(book.entry(.number(2)) == nil)
        #expect(book.entry(.number(4))?.weekly?.window.usedPercent == 5)
        #expect(book.entry(.defaultLogin) == nil, "the D4 entry goes once cswap has accounts")
        var none = QuotaBook()
        none.ingest(QuotaObservation(account: .defaultLogin, fiveHour: nil, weekly: QuotaWindow(usedPercent: 1, resetsAt: nil),
                                     source: .statusline, capturedAt: at(0)))
        let kept = none.reconcile(slots: [:])
        #expect(!kept, "no cswap account: the D4 entry stays")
    }

    @Test func anObservationOfAnotherLoginStartsTheEntryOver() {
        var book = QuotaBook()
        book.ingest(QuotaObservation(account: .number(2), fiveHour: QuotaWindow(usedPercent: 50, resetsAt: at(3600)),
                                     weekly: QuotaWindow(usedPercent: 45, resetsAt: resetX), source: .statusline,
                                     capturedAt: at(0), identity: "x"))
        // Only a weekly number for the new login: the old 5h window must not survive as its.
        book.ingest(observation(2, used: 3, reset: resetY, identity: "y", at: 10))
        #expect(book.entry(.number(2))?.identity == "y")
        #expect(book.entry(.number(2))?.fiveHour == nil)
        #expect(book.entry(.number(2))?.weekly?.window.usedPercent == 3)
        #expect(book.entry(2, matching: "y") != nil && book.entry(2, matching: "x") == nil)
    }

    @Test func identitiesRoundTripThroughQuotaJSON() throws {
        var book = QuotaBook()
        book.ingest(observation(3, used: 85, reset: resetY, identity: "0123456789abcdef"))
        let back = QuotaBook(json: book.json)
        #expect(back.entry(.number(3))?.identity == "0123456789abcdef")
        #expect(back == book)
    }

    /// The reviewer's probe: a leftover entry #5 sharing the active login's reset used to take
    /// every report (then dropped as an unknown account), so the active #6 never got numbers.
    @Test func aLeftoverSlotNoLongerTakesTheActiveLoginsReports() {
        var book = QuotaBook()
        book.ingest(observation(5, used: 10, reset: resetY, identity: "old"))
        let bare = QuotaAttribution.account(for: .default, weeklyResetsAt: resetY, activeAccount: 6, hasCswapAccounts: true,
                                            lastSwitch: nil, book: book, profileKeys: [:], now: referenceNow)
        #expect(bare == QuotaAttributionResult(account: .number(5), suspectedLoginChange: true), "the old rule")
        let withSlots = QuotaAttribution.account(for: .default, weeklyResetsAt: resetY, activeAccount: 6, hasCswapAccounts: true,
                                                 lastSwitch: nil, book: book, profileKeys: [:], now: referenceNow, slots: [6: "six"])
        #expect(withSlots == QuotaAttributionResult(account: .number(6)))
        // An entry whose slot holds another login now does not count as that slot's fingerprint.
        let otherLogin = QuotaAttribution.account(for: .default, weeklyResetsAt: resetY, activeAccount: 6, hasCswapAccounts: true,
                                                  lastSwitch: nil, book: book, profileKeys: [:], now: referenceNow,
                                                  slots: [5: "new", 6: "six"])
        #expect(otherLogin == QuotaAttributionResult(account: .number(6)))
    }
}
