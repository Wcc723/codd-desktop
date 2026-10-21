import CoddCleanupUI
import CoddCore
import CoddNotes
import CoddPreferences
import Foundation
import Testing
@testable import CODD

// M4 I4a: the retention table through `RetentionService` (notes D29, sessions D30 with the
// first-run grace), the D38 trash targets, the Cleanup page's rows, actions and bulk bar (D31),
// the digest's timing and the ADVANCED scrollback mirror reaching the engine. Temp data roots,
// an injected trash folder and clock; no holder, no claude.

@Suite("M4 cleanup · retention")
@MainActor
struct M4CleanupRetentionTests {
    @Test func notesFollowTheRetentionTableWithExemptions() async throws {
        let rig = try await CleanupRig("codd-m4-ret-notes")
        defer { rig.tearDown() }
        // A live CODD claude session: notes linked to it are exempt (豁免).
        let live = try rig.session("live", kind: .claude, state: .idle, since: rig.clock.now)
        let old = try await rig.note("舊筆記")
        let pinned = try await rig.note("釘選筆記")
        _ = try await rig.notes.update(pinned, .pinned(true))
        let linked = try await rig.note("使用中", links: NoteLinks(sessions: [live]))
        let scratch = try await rig.note("隨手記", kind: .scratch)
        let prompt = try await rig.note("送出的 prompt", kind: .prompt)
        _ = try await rig.notes.update(prompt, .markSent(at: rig.clock.now, to: live))
        let staleOnly = try await rig.note("稍舊")
        let gone = try await rig.note("要清除")
        try await rig.notes.trash(gone)

        // 8 days: SCRATCH and the sent PROMPT archive (scratchArchiveDays 7).
        rig.clock.advance(days: 8)
        var report = await rig.retention.run(reason: "test")
        #expect(await rig.status(scratch) == "archived")
        #expect(await rig.status(prompt) == "archived")
        #expect(await rig.status(old) == "active")
        #expect(Set(report.archived) == [scratch.rawValue, prompt.rawValue])

        // 23 more days (31 in all): the old note archives, pinned and linked stay; the trash is purged.
        try await rig.notes.update(staleOnly, .addTag("touch"))
        rig.clock.advance(days: 23)
        report = await rig.retention.run(reason: "test")
        #expect(await rig.status(old) == "archived")
        #expect(await rig.status(pinned) == "active", "pinned notes are exempt")
        #expect(await rig.status(linked) == "active", "notes linked to a live session are exempt")
        #expect(await rig.status(staleOnly) == "active", "a note touched 23 days ago is only stale")
        #expect(report.staleIDs.contains(staleOnly.rawValue))
        #expect(report.purged == [gone.rawValue])
        #expect(rig.trashed.contains { $0.hasSuffix(".md") }, "the purged note went to the injected trash folder (D38)")
        #expect(await rig.library.tombstone(gone) != nil)
        #expect(rig.logs.values.contains { $0.hasPrefix("retention notes ") })
        #expect(!rig.logs.values.contains { $0.contains("trash target=system") })
    }

    @Test func theFirstRunNeverArchivesSessionsAtOnce() async throws {
        let rig = try await CleanupRig("codd-m4-ret-grace")
        defer { rig.tearDown() }
        let stopped = try rig.session("停了十天", since: rig.days(-10))
        let archived = try rig.session("封存很久", since: rig.days(-90), archivedAt: rig.days(-60), ringBytes: 4096)

        var report = await rig.retention.run(reason: "launch")
        #expect(rig.state.state.retention.firstRunAt == rig.clock.now, "the first run records the grace start")
        #expect(report.sessionsArchived.isEmpty, "upgrading never archives existing stopped sessions at once")
        #expect(report.ringsTrashed.isEmpty, "nor trashes rings")
        #expect(rig.store.sessionsByID[stopped] != nil)
        #expect(FileManager.default.fileExists(atPath: rig.root.sessionDirectory(archived) + "/ring"))
        #expect(rig.retention.candidates.sessions.contains { $0.id.uuidString.lowercased() == stopped },
                "the row still shows the real stopped days")

        // 3 days later the grace clock reaches the stale step, 7 days later the archive.
        rig.clock.advance(days: 3)
        report = await rig.retention.run(reason: "daily")
        #expect(rig.store.retentionStaleIDs.contains(stopped))
        #expect(rig.store.sessionsByID[stopped]?.isStale == true, "stopped-stale dims the row")
        rig.clock.advance(days: 4)
        report = await rig.retention.run(reason: "daily")
        #expect(report.sessionsArchived == [stopped])
        #expect(rig.store.archivedByID[stopped] != nil)
        #expect(rig.store.records[stopped]?.archivedAt == rig.clock.now)
    }

    @Test func anOldFirstRunArchivesAndTrashesRingsAndNeverTouchesRunningPinnedOrExternal() async throws {
        let rig = try await CleanupRig("codd-m4-ret-old")
        defer { rig.tearDown() }
        try rig.graceOver()
        let stopped = try rig.session("停了十天", since: rig.days(-10))
        let pinned = try rig.session("釘選", since: rig.days(-10), pinned: true)
        let running = try rig.session("執行中", kind: .claude, state: .idle, since: rig.days(-10))
        let ring = try rig.session("封存很久", since: rig.days(-90), archivedAt: rig.days(-40), ringBytes: 8192)
        let soon = try rig.session("快刪了", since: rig.days(-60), archivedAt: rig.days(-26), ringBytes: 1024)
        let external = SessionVM(id: "ext-1", projectID: rig.projectID, title: "外部", state: .stopped, stateSince: rig.days(-30))
        external.externalInfo = ExternalInfo(pid: 4242)
        rig.store.externalByID["ext-1"] = external

        let report = await rig.retention.run(reason: "launch")
        #expect(report.sessionsArchived == [stopped])
        #expect(rig.store.sessionsByID[pinned] != nil, "pinned sessions are never archived")
        #expect(rig.store.sessionsByID[running] != nil, "running sessions are never archived")
        #expect(rig.store.externalByID["ext-1"] != nil, "externals are never touched")
        #expect(report.ringsTrashed == [ring])
        #expect(!FileManager.default.fileExists(atPath: rig.root.sessionDirectory(ring) + "/ring"))
        #expect(!FileManager.default.fileExists(atPath: rig.root.sessionDirectory(ring) + "/holder.log"))
        #expect(rig.trashed.contains("ring") && rig.trashed.contains("holder.log"))
        #expect(FileManager.default.fileExists(atPath: rig.root.sessionDirectory(soon) + "/ring"))
        let files = rig.retention.candidates.files.map(\.id)
        #expect(files.contains("ring:" + soon), "a ring due within 7 days is a FILES row (deletes in 4d)")
        #expect(rig.logs.values.contains { $0.hasPrefix("retention sessions archived=1 rings=1") })
        #expect(rig.logs.values.contains { $0.hasPrefix("trash target=folder name=ring") })
    }

    @Test func trashTargetsStayOffTheSystemTrashOutsideTheStandardRoot() {
        let root = CoddDataRoot(path: "/tmp/codd-m4-trash-root")
        #expect(AppTrash.target(dataRoot: root, trashDir: nil) == .folder("/tmp/codd-m4-trash-root/trash"))
        #expect(AppTrash.target(dataRoot: root, trashDir: "/tmp/elsewhere") == .folder("/tmp/elsewhere"))
        #expect(AppTrash.target(dataRoot: root, standardRoot: root, trashDir: nil) == .system)
        #expect(AppTrash.target(dataRoot: root, standardRoot: root, trashDir: "/tmp/t") == .folder("/tmp/t"))
    }

    @Test func cleanupStateRoundTripsAndToleratesACorruptFile() throws {
        let folder = try m3TempFolder("codd-m4-cleanup-state")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let url = URL(fileURLWithPath: folder)
        let store = CleanupStateStore(dataRoot: url)
        store.load()
        let at = Date(timeIntervalSince1970: 1_792_288_800)
        store.update {
            $0.retention.firstRunAt = at
            $0.sessions["ABC"] = CleanupState.Keep(keepUntil: at.addingTimeInterval(86_400))
            $0.digest = CleanupState.Digest(lastShownAt: at, lastCount: 15)
        }
        let again = CleanupStateStore(dataRoot: url)
        again.load()
        #expect(again.state.retention.firstRunAt == at)
        #expect(again.state.sessionKept("abc", now: at) != nil, "session keys are lowercase")
        #expect(again.state.digest.lastCount == 15)
        let text = try String(contentsOfFile: folder + "/cleanup.json", encoding: .utf8)
        #expect(text.contains("\"firstRunAt\" : \"2026-10-18T02:00:00Z\""))
        let mode = try FileManager.default.attributesOfItem(atPath: folder + "/cleanup.json")[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try "{not json".write(toFile: folder + "/cleanup.json", atomically: true, encoding: .utf8)
        let broken = CleanupStateStore(dataRoot: url)
        broken.load()
        #expect(broken.state == CleanupState())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).contains { $0.hasPrefix("cleanup.json.corrupt-") })
    }

    @Test func theAdvancedScrollbackMirrorReachesTheEngine() async throws {
        let preferences = PreferencesService.inMemory()
        let rig = try await CleanupRig("codd-m4-ret-mirror", preferences: preferences)
        defer { rig.tearDown() }
        try rig.graceOver()
        let ring = try rig.session("封存 40 天", since: rig.days(-90), archivedAt: rig.days(-40), ringBytes: 2048)
        // 12 進階 › 終端機紀錄保留 writes the cleanup leaf (C9's row: `$0.cleanup.scrollbackDeleteDays = $1`).
        let coordinator = SettingsCoordinator(environment: .init(preferences: preferences))
        coordinator.model.update { $0.cleanup.scrollbackDeleteDays = 90 }
        #expect(preferences.preferences.cleanup.scrollbackDeleteDays == 90)
        #expect(preferences.preferences.advanced.scrollbackRetentionDays == 30, "the M3 leaf stays stored and unused")
        #expect(RetentionService.sessionPolicy(preferences.preferences, cleanupPeriodDays: nil, firstRunAt: nil).scrollbackDeleteDays == 90)
        var report = await rig.retention.run(reason: "settings")
        #expect(report.ringsTrashed.isEmpty, "90 days: a ring archived 40 days ago stays")
        coordinator.model.update { $0.cleanup.scrollbackDeleteDays = 30 }
        report = await rig.retention.run(reason: "settings")
        #expect(report.ringsTrashed == [ring])
        #expect(RetentionService.policyKey(preferences.preferences) != RetentionService.policyKey(CoddPreferences.defaults.with90()))
    }
}

private extension CoddPreferences {
    func with90() -> CoddPreferences {
        var copy = self
        copy.cleanup.scrollbackDeleteDays = 90
        return copy
    }
}

@Suite("M4 cleanup · page")
@MainActor
struct M4CleanupPageTests {
    private func controller(_ rig: CleanupRig) -> CleanupController {
        let notes = rig.notes
        let store = rig.store
        let controller = CleanupController(retention: rig.retention, condense: nil, notes: notes, preferences: rig.preferences, store: store,
                                           presenter: { NotebookPresenter(now: notes.clock(), timeZone: notes.timeZone, store: store, projects: [:]) })
        controller.session = { store.session($0) ?? store.archivedSession($0) }
        controller.project = { store.project($0) }
        controller.setActive(true)
        return controller
    }

    @Test func rowsActionsAndTheBulkBarPerTab() async throws {
        let rig = try await CleanupRig("codd-m4-page")
        defer { rig.tearDown() }
        let stale = try await rig.note("Gear3D 載入效能想法", body: "# Gear3D 載入效能想法\n\n場景切塊、材質壓縮與 LOD 的實驗紀錄。\n")
        let other = try await rig.note("舊審查清單草稿", body: "# 舊審查清單草稿\n\nv1 的審查項目：程式碼風格、測試、文件。\n")
        rig.clock.advance(days: 21)
        try rig.graceOver()
        let session = try rig.session("選單列額度顯示", since: rig.days(-5))
        _ = try rig.session("快刪了", since: rig.days(-60), archivedAt: rig.days(-26), ringBytes: 1024)
        await rig.retention.run(reason: "test")
        let page = controller(rig)
        await m3Eventually("rows") { page.page.model.rows.count >= 2 }

        // The chips come from the notebook's active notes, refreshed 40 ms after each create: on a
        // busy main actor the candidates can be in first (the row then has no chips yet).
        await rig.notes.refreshNow()
        await m3Eventually("rows with their chips") { page.model().rows.filter { !$0.chips.isEmpty }.count >= 2 }
        var model = page.model()
        #expect(model.counts[.notes] == 2)
        let row = try #require(model.rows.first { $0.id == stale.rawValue })
        #expect(row.badge == "stale 21d")
        #expect(row.chips.first == .kind("NOTE"))
        #expect(row.actions == [CleanupRowAction.keep, CleanupRowAction.archive])
        #expect(model.isBulkEnabled(CleanupBulkAction.condense))
        #expect(rig.store.cleanupSuggestions == rig.retention.candidates.total)

        // 保留 30 天: the row goes and stays gone.
        await page.act(CleanupRowAction.keep, ids: [stale.rawValue], tab: .notes)
        #expect(!rig.retention.candidates.notes.contains { $0.id == stale })
        // 封存 (bulk): archived by the user.
        await page.bulk(CleanupBulkAction.archive, [other.rawValue])
        #expect(await rig.status(other) == "archived")
        #expect(rig.retention.candidates.notes.isEmpty)

        // SESSIONS: no 移到垃圾桶, no condense; 封存 archives through the store.
        page.select(tab: .sessions)
        model = page.model()
        #expect(model.rows.map(\.id) == [session])
        #expect(!model.isBulkEnabled(CleanupBulkAction.trash) && !model.isBulkEnabled(CleanupBulkAction.condense))
        #expect(model.isBulkEnabled(CleanupBulkAction.archive))
        await page.act(CleanupRowAction.archive, ids: [session], tab: .sessions)
        #expect(rig.store.archivedByID[session] != nil)

        // FILES: the ring row, 保留 30 天 / 移到垃圾桶; no condense.
        page.select(tab: .files)
        model = page.model()
        let files = model.rows.map(\.id)
        #expect(files.count == 1 && files[0].hasPrefix("ring:"))
        #expect(model.rows[0].actions == [CleanupRowAction.keep, CleanupRowAction.trash])
        #expect(!model.isBulkEnabled(CleanupBulkAction.condense))
        await page.act(CleanupRowAction.trash, ids: files, tab: .files)
        #expect(rig.trashed.contains("ring"))
        #expect(rig.retention.candidates.files.isEmpty)
        #expect(page.dumpObject["tab"] as? String == "files")
    }

    @Test func keepOfASessionAndAnImageGoesToCleanupJSON() async throws {
        let rig = try await CleanupRig("codd-m4-page-keep")
        defer { rig.tearDown() }
        try rig.graceOver()
        let session = try rig.session("停了五天", since: rig.days(-5))
        await rig.retention.run(reason: "test")
        #expect(rig.retention.candidates.sessions.count == 1)
        await rig.retention.keepSessions([session])
        #expect(rig.retention.candidates.sessions.isEmpty)
        #expect(rig.state.state.sessionKept(session, now: rig.clock.now) != nil)
        let text = try String(contentsOfFile: rig.root.path + "/cleanup.json", encoding: .utf8)
        #expect(text.contains(session))
    }

    @Test func badgeTonesFollowTheArtboard() {
        #expect(CleanupPresenter.tone(badge: "archives in 0d") == .amber)
        #expect(CleanupPresenter.tone(badge: "archives in 1d") == .amber)
        #expect(CleanupPresenter.tone(badge: "archives in 6d") == .plain)
        #expect(CleanupPresenter.tone(badge: "dup 82%") == .cyan)
        #expect(CleanupPresenter.tone(badge: "resume expires 4d") == .amber)
        #expect(CleanupPresenter.tone(badge: "deletes in 4d") == .amber)
        #expect(CleanupPresenter.tone(badge: "stale 21d") == .plain)
        let policy = CleanupPresenter.policy(.defaults)
        #expect(policy.rules.map(\.text) == ["7 天後封存 · 含已送出 prompt", "釘選 · 使用中 session 的筆記", "週一 09:00 · ≥5 項才提醒",
                                             "手動 · 原稿只封存不刪除", "停止 3 天 → stale · 7 天 → 封存", "終端機紀錄封存 30 天後刪除"])
        #expect(policy.lifecycle.map(\.detail) == [nil, "14d", "30d", nil, "30d"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = CleanupRig.taipei
        let last = Date(timeIntervalSince1970: 1_791_424_800)   // 10/08 10:00 Taipei
        #expect(CleanupPresenter.meta(.defaults, total: 15, lastShownAt: last, calendar: calendar) == "每週一 09:00 · 15 項 · 上次 10/08")
    }

    @Test func theKeyboardArchivesTheSelectionOnlyWhereArchiveIsEnabled() async throws {
        let rig = try await CleanupRig("codd-m4-page-keys")
        defer { rig.tearDown() }
        let note = try await rig.note("舊筆記")
        rig.clock.advance(days: 20)
        await rig.retention.run(reason: "test")
        let page = controller(rig)
        await m3Eventually("row") { page.page.model.rows.count == 1 }
        // ⌫ on the page is `onBulk("封存", selection)` (C12); the controller archives.
        page.page.onBulk?(CleanupBulkAction.archive, [note.rawValue])
        await m3Eventually("archived") { rig.retention.candidates.notes.isEmpty }
        #expect(await rig.status(note) == "archived")
        page.select(tab: .files)
        #expect(!page.model().isBulkEnabled(CleanupBulkAction.archive), "⌫ does nothing on FILES (nothing to archive)")
    }
}

@Suite("M4 cleanup · digest")
@MainActor
struct M4CleanupDigestTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = CleanupRig.taipei
        return calendar
    }

    private func at(_ text: String) -> Date { RealModeOptions.isoDate(text)! }

    @Test func weeklyIsMondayNineOClockOncePerPeriodWithFiveCandidates() {
        let monday = at("2026-10-19T09:00:00+08:00")
        #expect(CleanupDigest.periodStart(.weekly, now: at("2026-10-19T09:05:00+08:00"), calendar: calendar) == monday)
        #expect(CleanupDigest.periodStart(.weekly, now: at("2026-10-19T08:59:00+08:00"), calendar: calendar) == at("2026-10-12T09:00:00+08:00"))
        #expect(CleanupDigest.periodStart(.weekly, now: at("2026-10-25T23:00:00+08:00"), calendar: calendar) == monday)
        let now = at("2026-10-19T09:05:00+08:00")
        #expect(CleanupDigest.isDue(.weekly, now: now, lastShownAt: nil, candidates: 5, calendar: calendar))
        #expect(!CleanupDigest.isDue(.weekly, now: now, lastShownAt: nil, candidates: 4, calendar: calendar), "only with ≥ 5")
        #expect(!CleanupDigest.isDue(.weekly, now: now, lastShownAt: at("2026-10-19T09:01:00+08:00"), candidates: 15, calendar: calendar))
        #expect(CleanupDigest.isDue(.weekly, now: now, lastShownAt: at("2026-10-12T09:30:00+08:00"), candidates: 15, calendar: calendar))
        #expect(!CleanupDigest.isDue(.off, now: now, lastShownAt: nil, candidates: 99, calendar: calendar))
    }

    @Test func biweeklyAndMonthlyPeriods() {
        // 2026-10-19 is week 41 after 2026-01-05 (odd): the biweekly period began 10/12.
        #expect(CleanupDigest.periodStart(.biweekly, now: at("2026-10-19T10:00:00+08:00"), calendar: calendar) == at("2026-10-12T09:00:00+08:00"))
        #expect(CleanupDigest.periodStart(.biweekly, now: at("2026-10-26T10:00:00+08:00"), calendar: calendar) == at("2026-10-26T09:00:00+08:00"))
        #expect(CleanupDigest.periodStart(.monthly, now: at("2026-10-19T10:00:00+08:00"), calendar: calendar) == at("2026-10-05T09:00:00+08:00"))
        #expect(CleanupDigest.periodStart(.monthly, now: at("2026-11-01T10:00:00+08:00"), calendar: calendar) == at("2026-10-05T09:00:00+08:00"))
        #expect(CleanupDigest.periodStart(.monthly, now: at("2026-11-02T09:00:00+08:00"), calendar: calendar) == at("2026-11-02T09:00:00+08:00"))
        let text = CleanupDigest.content(notes: 8, sessions: 5, files: 2)
        #expect(text.title == "清理建議 · 15 項" && text.body == "筆記 8 · session 5 · 檔案 2")
    }

    @Test func theDigestIsRecordedOncePerPeriodAndSuppressedWithNotificationsOff() async throws {
        let rig = try await CleanupRig("codd-m4-digest")
        defer { rig.tearDown() }
        // Monday 2026-10-19 09:05 Taipei, five stale notes.
        rig.clock.advance(days: -20)
        for n in 1...5 { try await rig.note("舊筆記 \(n)") }
        rig.clock.advance(days: 20 + (23.0 + 5.0 / 60) / 24)
        let log = NotificationLog()
        let notifier = AppNotifier(dispatcher: nil, allowedThisRun: false, rules: { CoddPreferences.defaults.notifications }, decisions: log,
                                   now: { rig.clock.now })
        rig.retention.postDigest = { title, body in notifier.post(.cleanupDigest, title: title, body: body) }
        await rig.retention.run(reason: "launch")
        #expect(rig.retention.candidates.notes.count == 5)
        #expect(log.entries.map(\.kind) == ["cleanup-digest"])
        #expect(log.entries.first?.suppressed == true, "-codd-notifications NO records it, shows nothing")
        #expect(log.entries.first?.title == "清理建議 · 5 項")
        #expect(rig.state.state.digest.lastShownAt == rig.clock.now)
        // Later the same week: not again.
        rig.clock.advance(days: 1)
        await rig.retention.tick()
        #expect(log.entries.count == 1)
        // The next Monday after 09:00: again.
        rig.clock.advance(days: 6)
        rig.retention.checkDigest()
        #expect(log.entries.count == 2)
    }

    @Test func flagsParse() {
        let o = RealModeOptions.parse(arguments: ["CODD", "-codd-retention-run", "YES", "-codd-cleanup-action", "files:ring:abc,image:assets/x/a.png:trash",
                                                  "-codd-condense", "a,b", "-codd-condense-account", "Follow", "-codd-condense-apply",
                                                  "-codd-show", "Cleanup"], environment: [:], home: "/Users/someone")
        #expect(o.retentionRun && o.condenseApply)
        #expect(o.cleanupAction == "files:ring:abc,image:assets/x/a.png:trash")
        #expect(o.condense == "a,b" && o.condenseAccount == "follow")
        #expect(o.showKeyword == "cleanup")
        #expect(!o.releaseSubset.retentionRun && o.releaseSubset.condense == nil)
    }
}
