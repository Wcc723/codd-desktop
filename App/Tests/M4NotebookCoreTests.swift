import AppKit
import CoddNotebookUI
import CoddNotes
import Foundation
import Testing
@testable import CODD

// M4 I1a: the DEBUG `-codd-show` parser, D38 trash targets, the D39 pasteboard helper, the D36
// menu rules and the Notebook presenter's texts. Temp folders only; nothing here touches `~`.

@Suite("M4 notebook core · options and infrastructure")
@MainActor
struct M4NotebookCoreInfrastructureTests {
    @Test func showKeepsEverythingAfterTheFirstColonAsGiven() {
        func show(_ value: String) -> RealModeOptions {
            RealModeOptions.parse(arguments: ["CODD", "-codd-show", value], environment: [:], home: "/Users/someone")
        }
        #expect(show("STATUS").show == "status")
        #expect(show("Settings-Notebook").show == "settings-notebook")
        let note = show("Note:Rwd-Punch-K7X2")
        #expect(note.show == "note:Rwd-Punch-K7X2")
        #expect(note.showKeyword == "note")
        #expect(note.showArgument == "Rwd-Punch-K7X2")
        let files = show("FILES:/Users/A/Project/src/Punch.vue:12")
        #expect(files.showKeyword == "files")
        #expect(files.showArgument == "/Users/A/Project/src/Punch.vue:12", "only the first colon splits")
        let annotate = show("annotate:rwd-punch-k7x2:9F3A1C.png")
        #expect(annotate.showArgument == "rwd-punch-k7x2:9F3A1C.png")
        #expect(show("notebook").showArgument == nil)
    }

    @Test func notesFlagsParse() throws {
        let options = RealModeOptions.parse(arguments: [
            "CODD", "-codd-notes-select", "rwd-punch-k7x2", "-codd-notes-new", "第一則", "-codd-quick-note", "YES",
            "-codd-notes-type", "a\\nb", "-codd-notes-paste-image", "~/shot.png", "-codd-notes-search", "打卡 #rwd",
            "-codd-notes-rebuild", "-codd-now", "2026-10-15T10:42:00+08:00",
        ], environment: [:], home: "/Users/someone")
        #expect(options.notesSelect == "rwd-punch-k7x2")
        #expect(options.notesNew == "第一則")
        #expect(options.quickNote)
        #expect(options.notesType == "a\nb")
        #expect(options.notesPasteImage == "/Users/someone/shot.png")
        #expect(options.notesSearch == "打卡 #rwd")
        #expect(options.notesRebuild)
        let now = try #require(options.now)
        #expect(abs(now.timeIntervalSince1970 - 1_792_032_120) < 1)
        // Release builds never see them.
        #expect(options.releaseSubset.notesType == nil && options.releaseSubset.now == nil)
    }

    @Test func protectedDebugPathsAreRefusedLexicallyAndThroughLinks() throws {
        let root = try m3TempFolder("codd-m4-guard")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/home"
        let manager = FileManager.default
        try manager.createDirectory(atPath: home + "/.claude/projects", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: home + "/Library/Application Support/CODD", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/work", withIntermediateDirectories: true)
        for path in [home + "/.claude/x.png", home + "/.claude.json", home + "/.claude-swap-backup/a", home + "/.codex/config.toml",
                     home + "/Library/Application Support/CODD/notes/a.png", home + "/work/../.claude/y.png"] {
            #expect(RealModeOptions.protectedPathReason(path, home: home) != nil, "\(path) must be refused")
        }
        for path in [root + "/work/shot.png", home + "/Pictures/shot.png", home + "/Library/Application Support/CODDX/a.png"] {
            #expect(RealModeOptions.protectedPathReason(path, home: home) == nil, "\(path) is fine")
        }
        // A link (also a dangling one) pointing into ~/.claude is seen through.
        try manager.createSymbolicLink(atPath: root + "/work/link", withDestinationPath: home + "/.claude/projects")
        try manager.createSymbolicLink(atPath: root + "/work/dangling.png", withDestinationPath: home + "/.claude/missing.png")
        #expect(RealModeOptions.protectedPathReason(root + "/work/link/shot.png", home: home) != nil)
        #expect(RealModeOptions.protectedPathReason(root + "/work/dangling.png", home: home) != nil)
    }

    @Test func trashTargetsFollowTheRootKind() throws {
        let standard = CoddDataRoot(path: "/Users/someone/Library/Application Support/CODD")
        #expect(AppTrash.target(dataRoot: standard, standardRoot: standard, trashDir: nil) == .system)
        #expect(AppTrash.target(dataRoot: standard, standardRoot: standard, trashDir: "/tmp/t") == .folder("/tmp/t"))
        let test = CoddDataRoot(path: "/tmp/codd-test/data")
        #expect(AppTrash.target(dataRoot: test, standardRoot: standard, trashDir: nil) == .folder("/tmp/codd-test/data/trash"))
        #expect(AppTrash.target(dataRoot: test, standardRoot: standard, trashDir: "/tmp/elsewhere") == .folder("/tmp/elsewhere"))

        let root = try m3TempFolder("codd-m4-trash")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let lines = LockedLines()
        let systemCalls = LockedLines()
        let trash = AppTrash(target: AppTrash.target(dataRoot: CoddDataRoot(path: root), standardRoot: standard, trashDir: nil),
                             log: { lines.append($0) }, systemTrash: { url in systemCalls.append(url.path) })
        for name in ["note.md", "note.md"] {
            FileManager.default.createFile(atPath: root + "/" + name, contents: Data("x".utf8))
            try trash.move(URL(fileURLWithPath: root + "/" + name))
        }
        #expect(FileManager.default.fileExists(atPath: root + "/trash/note.md"))
        #expect(FileManager.default.fileExists(atPath: root + "/trash/note.md 2"), "a taken name gets a number like the Trash")
        #expect(systemCalls.values.isEmpty, "a non-standard root never reaches the macOS Trash")
        #expect(lines.values == ["trash target=folder name=note.md", "trash target=folder name=note.md"])
        let system = AppTrash(target: .system, log: { lines.append($0) }, systemTrash: { url in systemCalls.append(url.path) })
        try system.move(URL(fileURLWithPath: "/nowhere/ring"))
        #expect(systemCalls.values == ["/nowhere/ring"] && lines.values.last == "trash target=system name=ring")
    }

    @Test func backgroundPasteboardWritesNeverTouchTheGeneralPasteboard() {
        let general = NSPasteboard.general.changeCount
        var logged: [String] = []
        let background = CoddPasteboard(isBackground: true, log: { logged.append($0) })
        #expect(background.write("codd://note/rwd-punch-k7x2", userAction: true) == .private)
        #expect(background.write("secret-ish", userAction: false) == .private)
        #expect(NSPasteboard.general.changeCount == general, "the user's pasteboard stays as it was")
        #expect(CoddPasteboard.privateString() == "secret-ish")
        #expect(logged == ["pasteboard target=private chars=26", "pasteboard target=private chars=10"])
        #expect(!logged.joined().contains("codd://"), "the log never carries the content")
        // A token (the Codex snippet, a note URL's ?t=) is marked concealed for clipboard history apps.
        #expect(background.write("http://127.0.0.1:1/n/x.md?t=abc", userAction: true, concealed: true) == .private)
        let item = NSPasteboard(name: CoddPasteboard.privateName).pasteboardItems?.first
        #expect(item?.types.contains(CoddPasteboard.concealedType) == true)
        #expect(logged.last == "pasteboard target=private chars=31 concealed=true")
        #expect(background.write("plain", userAction: true) == .private)
        #expect(NSPasteboard(name: CoddPasteboard.privateName).pasteboardItems?.first?.types.contains(CoddPasteboard.concealedType) == false)
        // A foreground run writes the general pasteboard only for a user action (not exercised here).
        let foreground = CoddPasteboard(isBackground: false, log: { _ in })
        #expect(foreground.target(userAction: true) == .general)
        #expect(foreground.target(userAction: false) == .private)
    }

    @Test func menuRulesKeepSessionKeysInTheSessionsArea() {
        let allow = #selector(AppDelegate.allowCurrentSession(_:))
        let quick = #selector(AppDelegate.quickNote(_:))
        let source = #selector(AppDelegate.toggleNoteSource(_:))
        let search = #selector(AppDelegate.searchNotes(_:))
        let sessions = MenuAreaRules(area: .sessions, noteShown: true, notesReady: true, canAllow: true)
        #expect(sessions.isEnabled(allow) == true)
        #expect(sessions.isEnabled(source) == false && sessions.isEnabled(search) == false)
        #expect(sessions.isEnabled(quick) == true)
        let notes = MenuAreaRules(area: .notes, noteShown: true, notesReady: true, canAllow: true)
        #expect(notes.isEnabled(allow) == false, "⌘⏎ is the notebook's on NOTES")
        #expect(notes.isEnabled(source) == true && notes.isEnabled(search) == true && notes.isEnabled(quick) == true)
        var composing = notes
        composing.hasMarkedText = true
        #expect(composing.isEnabled(quick) == false && composing.isEnabled(source) == false && composing.isEnabled(search) == false)
        var editorComposing = notes
        editorComposing.noteComposing = true
        #expect(editorComposing.isEnabled(source) == false)
        #expect(MenuAreaRules(area: .notes, noteShown: false).isEnabled(source) == false)
        #expect(MenuAreaRules(area: .status, canAllow: true).isEnabled(allow) == false)
        #expect(sessions.isEnabled(#selector(AppDelegate.togglePinCurrentSession(_:))) == nil, "other items keep their own rules")
    }

    /// No two items share a key, except the Files mode's three D36 pairs (I3), which validation
    /// keeps mutually exclusive: ⌘W 關閉分頁 / 關閉分頁或視窗, ⌘P 篩選檔案 / 釘選 (the sessions area
    /// only), ⌘F 尋找 / 搜尋筆記.
    @Test func mainMenuKeyEquivalentsNeverCollide() {
        let commands = StubCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        var seen: [String: String] = [:]
        var shared: Set<[String]> = []
        var notes: NSMenu?
        let d36: Set<[String]> = [["關閉分頁", "關閉分頁或視窗"], ["篩選檔案", "釘選"], ["尋找", "搜尋筆記"]]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu {
                    if item.title == "筆記" { notes = sub }
                    walk(sub)
                }
                guard !item.keyEquivalent.isEmpty else { continue }
                let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent.lowercased())"
                if let other = seen[key] {
                    let pair = [other, item.title].sorted()
                    #expect(d36.contains(pair), "\(item.title) shares its key with \(other)")
                    shared.insert(pair)
                }
                seen[key] = item.title
            }
        }
        walk(menu)
        #expect(shared == d36, "the three D36 pairs, nothing else")
        // The pairs never act together: the Files mode owns ⌘W / ⌘F / ⌘P, the other areas the rest.
        let files = MenuAreaRules(area: .notes, notesReady: true, notesMode: .files, fileTabShown: true, fileTabHasEditor: true)
        #expect(files.closeTabOwnsCommandW && files.isEnabled(#selector(AppDelegate.closeFileTab(_:))) == true)
        #expect(files.isEnabled(#selector(AppDelegate.findInFile(_:))) == true && files.isEnabled(#selector(AppDelegate.searchNotes(_:))) == false)
        #expect(files.isEnabled(#selector(AppDelegate.filterFiles(_:))) == true)
        let notebook = MenuAreaRules(area: .notes, notesReady: true, notesMode: .notebook, fileTabShown: true, fileTabHasEditor: true)
        #expect(!notebook.closeTabOwnsCommandW && notebook.isEnabled(#selector(AppDelegate.closeFileTab(_:))) == false)
        #expect(notebook.isEnabled(#selector(AppDelegate.findInFile(_:))) == false && notebook.isEnabled(#selector(AppDelegate.searchNotes(_:))) == true)
        let sessions = MenuAreaRules(area: .sessions, fileTabShown: true, fileTabHasEditor: true)
        #expect(sessions.isEnabled(#selector(AppDelegate.filterFiles(_:))) == false && !sessions.closeTabOwnsCommandW)
        let titles = notes?.items.filter { !$0.isSeparatorItem }.map(\.title)
        // I1b added 標註模式 ⌘⇧A and 複製引用 ⌘⇧C (D36); M5 D21 the NOTES modes (no key equivalents).
        #expect(titles == ["快速筆記", "筆記本", "檔案", "清理建議", "原始碼", "標註模式", "複製引用", "搜尋筆記"])
        let quick = notes?.items.first
        #expect(quick?.keyEquivalent == "N" && quick?.keyEquivalentModifierMask == [.command, .shift])
        // A real ⌘⇧N (charactersIgnoringModifiers `N`) reaches it through the menu.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "N", charactersIgnoringModifiers: "N", isARepeat: false, keyCode: 0x2D)
        #expect(event.map { menu.performKeyEquivalent(with: $0) } == true)
        #expect(commands.quickNotes == 1)
    }

    @Test func terminalsDeclineTheQuickNoteChord() {
        let policy = CoddTerminalSetup.keyEquivalents
        #expect(policy.isReserved(characters: "N", keyCode: 0x2D, modifiers: [.command, .shift]))
        #expect(policy.isReserved(characters: "ㄙ", keyCode: 0x2D, modifiers: [.command, .shift]), "注音 reports the key as ㄙ")
        #expect(!policy.isReserved(characters: "e", keyCode: 0x0E, modifiers: [.command]), "⌘E is NOTES-only: never taken from a terminal")
    }
}

/// Lines appended from @Sendable closures.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var values: [String] { lock.withLock { lines } }
}

@MainActor
final class StubCommands: NSObject, CoddCommands {
    @objc func showSettings(_ sender: Any?) {}
    @objc func showQuickSwitch(_ sender: Any?) {}
    @objc func toggleSessionSidebar(_ sender: Any?) {}
    @objc func selectSessionByNumber(_ sender: NSMenuItem) {}
    @objc func selectNextSession(_ sender: Any?) {}
    @objc func selectPreviousSession(_ sender: Any?) {}
    @objc func allowCurrentSession(_ sender: Any?) {}
    @objc func newShellTab(_ sender: Any?) {}
    @objc func toggleBottomTerminal(_ sender: Any?) {}
    @objc func showMainWindow(_ sender: Any?) {}
    @objc func focusSidebarFilter(_ sender: Any?) {}
    @objc func newSession(_ sender: Any?) {}
    @objc func quitApp(_ sender: Any?) {}
    @objc func togglePinCurrentSession(_ sender: Any?) {}
    @objc func stopCurrentSession(_ sender: Any?) {}
    @objc func toggleComposer(_ sender: Any?) {}
    var quickNotes = 0
    @objc func quickNote(_ sender: Any?) { quickNotes += 1 }
    @objc func toggleNoteSource(_ sender: Any?) {}
    @objc func searchNotes(_ sender: Any?) {}
}

@Suite("M4 notebook core · presenter texts")
@MainActor
struct M4NotebookPresenterTests {
    static let taipei = TimeZone(identifier: "Asia/Taipei")!

    func presenter() -> NotebookPresenter {
        NotebookPresenter(now: MockData.referenceDate, timeZone: Self.taipei, store: MockSessionStore(), projects: [:])
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.taipei
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func daySectionsInLocalTime() {
        let p = presenter()
        #expect(p.dayLabel(date(15, 0, 5)) == "Today · 10/15")
        #expect(p.dayLabel(date(14, 23, 59)) == "Yesterday")
        #expect(p.dayLabel(date(12, 9, 0)) == "10/12")
        #expect(p.dayLabel(date(9, 9, 0)) == "10/9")
        #expect(p.dayLabel(date(8, 9, 0)) == "2026-10")
        #expect(p.dayLabel(date(1, 9, 0).addingTimeInterval(-30 * 86_400)) == "2026-09")
        #expect(NotebookPresenter.isDaySection("10/12") && !NotebookPresenter.isDaySection("2026-09"))
        #expect(p.shortStamp(date(14, 18, 20)) == "昨天 18:20")
        #expect(p.shortStamp(date(15, 10, 5)) == "10:05")
        #expect(p.shortStamp(date(12, 9, 41)) == "10/12 09:41")
    }

    func summary(kind: NoteKind = .note, sent: Date? = nil, sessions: [String] = [], projects: [String] = [], updated: Date,
                 archivesAt: Date? = nil, stale: Bool = false, flags: NoteFlags = [], ai: NoteAIAccess = .read) -> NoteSummary {
        let meta = NoteMetadata(id: NoteID(rawValue: "rwd-punch-k7x2")!, title: "打卡頁 RWD 跑版紀錄", kind: kind, tags: ["rwd"],
                                links: NoteLinks(sessions: sessions, projects: projects), ai: ai, created: updated, updated: updated, sentAt: sent)
        return NoteSummary(metadata: meta, snippet: "iPhone SE\n下打卡按鈕", assetCount: 0, assetBytes: 0, lastActivity: updated,
                           staleSince: stale ? updated : nil, archivesAt: archivesAt, purgeAt: nil, exempt: nil, flags: flags,
                           fileURL: URL(fileURLWithPath: "/tmp/n.md"))
    }

    @Test func rowTextsFollowTheArtboard() {
        let p = presenter()
        let note = p.row(summary(sessions: ["s9"], updated: date(15, 10, 5)), daySection: true)
        #expect(note.time == "10:05" && note.kind == .note && note.ai == .read)
        #expect(note.link == .session(title: "打卡頁 RWD 調整", state: .busy))
        #expect(note.snippet == "iPhone SE 下打卡按鈕")
        let sent = p.row(summary(kind: .prompt, sent: date(15, 10, 2), updated: date(15, 10, 2)), daySection: true)
        #expect(sent.time == "已送出 10:02" && sent.kind == .prompt)
        let draft = p.row(summary(kind: .prompt, updated: date(14, 21, 30)), daySection: true)
        #expect(draft.kind == .promptDraft && draft.time == "21:30")
        let scratch = p.row(summary(kind: .scratch, updated: date(15, 8, 47), archivesAt: date(22, 8, 47), ai: .off), daySection: true)
        #expect(scratch.extra == "7d 後封存" && scratch.ai == .off && scratch.kind == .scratch)
        let old = p.row(summary(projects: ["~/Github/Gear3D"], updated: date(1, 9, 0), stale: true, flags: [.duplicateID]), daySection: false)
        #expect(old.time == "10/1" && old.stale && old.warnings == ["ID 重複"])
        #expect(old.link == .project(name: "Gear3D", tag: nil), "an unknown path shows its last component without color")
    }

    @Test func listGroupsRowsByDayAndEndsWithItsComment() {
        let p = presenter()
        let rows = [summary(updated: date(15, 10, 5)), summary(updated: date(15, 9, 40)), summary(updated: date(14, 21, 30)),
                    summary(updated: date(1, 9, 0).addingTimeInterval(-20 * 86_400))]
        let model = p.noteList(rows: rows, list: .inbox, sort: .updated, selected: nil, total: 4, resolve: { $0 })
        #expect(model.sections.map(\.day) == ["Today · 10/15", "Yesterday", "2026-09"])
        #expect(model.sections.map(\.rows.count) == [2, 1, 1])
        #expect(model.endComment == "// INBOX 4 則 · 已全部顯示")
        #expect(model.title == "Inbox" && model.count == "4")
        let titled = p.noteList(rows: rows, list: .inbox, sort: .title, selected: nil, total: 4, resolve: { $0 })
        #expect(titled.sections.count == 1 && titled.sections.first?.day == nil)
        let empty = p.noteList(rows: [], list: .inbox, sort: .updated, selected: nil, total: 0, resolve: { $0 })
        #expect(empty.sections.isEmpty && empty.emptyText == NotebookCopy.noNotesEmpty && empty.endComment == nil)
    }

    @Test func searchTitlesAreHighlighted() {
        #expect(NotebookPresenter.searchTerms("打卡 #rwd \"跑版\"") == ["打卡", "跑版"])
        #expect(NotebookPresenter.ranges(of: ["打卡", "rwd"], in: "打卡頁 RWD 跑版紀錄") == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 3)])
    }

    @Test func figuresMapAnnotationBlocks() throws {
        let body = MockNotes.n1Body(final: true)
        let facts = NoteFigureFacts.parse(body)
        let figure = try #require(facts.figures["assets/rwd-punch-k7x2/9f3a1c.png"])
        #expect(figure.alt == "截圖 2026-10-15 09:32 · iPhone SE")
        let annotations = try #require(figure.annotations)
        let overlay = NoteFigureFacts.overlay(annotations)
        #expect(overlay == [.rect(n: 1, CGRect(x: 20, y: 1150, width: 710, height: 120), color: nil),
                            .point(n: 2, CGPoint(x: 375, y: 330), color: nil),
                            .arrow(n: 3, from: CGPoint(x: 600, y: 760), to: CGPoint(x: 700, y: 1080), color: nil)])
        let summary = NoteFigureFacts.summary(annotations)
        #expect(summary.items.map(\.coordinates) == ["rect · x 20 y 1150 · 710×120", "point · x 375 y 330", "arrow · x 600 y 760 → x 700 y 1080"])
        #expect(summary.hint == "AI 會收到標註後的圖與座標清單")
        #expect(NoteFigureFacts.sendHint(.init(original: true, annotated: true, list: true)) == "AI 會收到原圖、標註後的圖與座標清單")
        #expect(NoteFigureFacts.sendHint(.init(original: false, annotated: false, list: false)) == "AI 不會收到這張圖")
    }

    @Test func draftsLeaveTheirSeedBeforeTheyCount() {
        let note = NoteDraft.note()
        #expect(note.seed == "# \n" && note.caret == 2 && !note.isTouched("# \n") && !note.isTouched("# ") && !note.isTouched("#  \n")
            && note.isTouched("# a\n"))
        let quick = NoteDraft.quick(now: date(17, 9, 0), timeZone: Self.taipei, links: NoteLinks(sessions: ["s9"]))
        #expect(quick.title == "隨手記 10/17" && quick.kind == .scratch && quick.seed == "# 隨手記 10/17\n\n")
        #expect(!quick.isTouched(quick.seed) && quick.isTouched(quick.seed + "x"))
        #expect(NoteDraft.title(of: "\n# 標題一\n內容") == "標題一")
        #expect(NoteDraft.title(of: "內容\n# 不是標題") == nil)
        #expect(NoteDraft.title(of: "# ") == nil)
    }
}
