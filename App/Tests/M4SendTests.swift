import AppKit
import CoddComposer
import CoddNotebookUI
import CoddNotes
import Foundation
import Testing
@testable import CODD

// M4 I2b: notes to sessions (D14) — the draft path, the PTY path, the refusals, `sent` on a
// PROMPT, ⌘⏎ in the note editor, the drawer's cards and the composer's reference chips. The mock
// store's SPEC §5 sessions are the targets (s9 busy, s1 waiting, s12 exited, s8 a shell, s14 an
// external); nothing reaches a real PTY (sends are recorded). Temp folders only.

/// `NoteSending` over the NOTES area rig with a recording PTY and a composer without folders.
@MainActor
final class SendRig {
    let notes: NotesAreaRig
    let composer = PaneComposer(states: ComposerStates(directory: { _ in nil }))
    let sending: NoteSending
    private(set) var sent: [(input: TerminalInput, target: TerminalTarget)] = []
    /// What the recording PTY answers (false: nothing took the input).
    var accepts = true
    private(set) var revealed: [SessionID] = []

    init(_ prefix: String) async throws {
        notes = try await NotesAreaRig(prefix, mock: true)
        sending = NoteSending(notes: notes.service, store: notes.store, shell: notes.shell)
        sending.editor = notes.editor
        sending.composer = { [unowned self] in self.composer }
        sending.send = { [unowned self] input, target in
            self.sent.append((input, target))
            return self.accepts
        }
        sending.revealComposer = { [unowned self] id in self.revealed.append(id) }
        notes.area.sending = sending
    }

    var n1: NoteID { notes.n1 }

    /// The text a payload carries (CR line ends inside a paste, as the PTY gets it).
    static func text(_ input: TerminalInput) -> String { String(decoding: input.bytes, as: UTF8.self) }

    func tearDown() async { await notes.tearDown() }
}

@Suite("M4 send to session", .serialized)
@MainActor
struct M4SendTests {
    @Test func insertRefAppendsToTheDraftAndOpensTheComposer() async throws {
        let rig = try await SendRig("codd-m4s-ref")
        let outcome = await rig.sending.perform(.ref, note: rig.n1, to: "s6")
        #expect(outcome == .inserted("s6"))
        await m3Eventually("draft") { rig.composer.states.state("s6")?.draft == "codd://note/rwd-punch-k7x2" }
        #expect(rig.notes.shell.pane(for: "s6").composerOpen, "the composer opens for that session")
        #expect(rig.sent.isEmpty, "a reference is never sent by itself")
        #expect(rig.composer.draftReferences("s6") == ["rwd-punch-k7x2"])
        // A second insert goes after what is there, a space between.
        rig.composer.states.setDraft("看一下", for: "s6")
        _ = await rig.sending.perform(.ref, note: rig.n1, to: "s6")
        #expect(rig.composer.states.state("s6")?.draft == "看一下 codd://note/rwd-punch-k7x2")
        #expect(rig.sending.toast(for: outcome) == "已放進「產生程式碼審查清單」的訊息草稿 · ⌘L")
        await rig.tearDown()
    }

    @Test func insertWhileTheBarShowsTheSessionGoesIntoTheField() async throws {
        let rig = try await SendRig("codd-m4s-bar")
        rig.composer.bind(session: "s9", target: TerminalTarget(sessionID: "s9", tab: .claude), shell: false, live: true, busy: true)
        await rig.composer.states.load("s9")
        rig.composer.bar.field.text = "iPhone SE 寬度下的打卡按鈕改成固定在底部，參考"
        rig.notes.shell.currentSessionID = "s9"
        rig.notes.shell.area = .sessions
        _ = await rig.sending.perform(.ref, note: rig.n1, to: "s9")
        #expect(rig.composer.bar.field.text == "iPhone SE 寬度下的打卡按鈕改成固定在底部，參考 codd://note/rwd-punch-k7x2")
        #expect(rig.composer.states.state("s9")?.draft == rig.composer.bar.field.text, "the draft follows the field")
        #expect(rig.revealed == ["s9"], "on screen: the composer takes the keyboard")
        await rig.tearDown()
    }

    @Test func insertFullPutsTheAITextInTheDraft() async throws {
        let rig = try await SendRig("codd-m4s-full")
        let outcome = await rig.sending.perform(.full, note: rig.n1, to: "s6")
        #expect(outcome == .inserted("s6"))
        await m3Eventually("draft") { rig.composer.states.state("s6")?.draft.hasPrefix("# 打卡頁 RWD 跑版紀錄\ncodd://note/rwd-punch-k7x2") == true }
        let draft = rig.composer.states.state("s6")?.draft ?? ""
        #expect(draft.contains("[image] ") && draft.contains("annotations（原圖像素，左上為原點）"), "§3.7: images and the list")
        #expect(!draft.contains("\nid: "), "the frontmatter is replaced by the header lines")
        await rig.tearDown()
    }

    @Test func submitPastesTheAITextAndSubmitsToClaudesOwnPTY() async throws {
        let rig = try await SendRig("codd-m4s-submit")
        let outcome = await rig.sending.perform(.submit, note: rig.n1, to: "s9")
        #expect(outcome == .sent("s9"))
        let last = try #require(rig.sent.last)
        #expect(last.target == TerminalTarget(sessionID: "s9", tab: .claude))
        guard case .payload(let bytes, let submit, let paste) = last.input else {
            Issue.record("not a payload")
            return
        }
        #expect(submit && paste, "one paste plus Return (the composer path)")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("# 打卡頁 RWD 跑版紀錄\rcodd://note/rwd-punch-k7x2"), "LF → CR inside a paste")
        #expect(!text.contains("\n"))
        #expect(rig.sending.toast(for: outcome) == "已送到「打卡頁 RWD 調整」")
        #expect(rig.sending.last?.outcome == "sent" && rig.sending.last?.paste == true)
        await rig.tearDown()
    }

    @Test func submitReachesTheShownFakeSurfaceLikeTheComposer() async throws {
        let rig = try await SendRig("codd-m4s-fake")
        let factory = FakeTerminalSurfaceFactory { _ in "" }
        let surface = try #require(factory.makeSurface(slot: .main) as? FakeTerminalSurface)
        surface.attach(TerminalTarget(sessionID: "s9", tab: .claude))
        rig.sending.send = { input, target in factory.send(input, to: target) }
        #expect(await rig.sending.perform(.submit, note: rig.n1, to: "s9") == .sent("s9"))
        guard case .payload(let bytes, true, true)? = surface.sentInputs.last else {
            Issue.record("no paste + submit reached the surface")
            return
        }
        #expect(String(decoding: bytes, as: UTF8.self).contains("codd://note/rwd-punch-k7x2 · NOTE"))
        await rig.tearDown()
    }

    @Test func refusalsFollowTheComposersRules() async throws {
        let rig = try await SendRig("codd-m4s-refuse")
        #expect(await rig.sending.perform(.submit, note: rig.n1, to: "s1") == .refused("Claude 在等你確認 · 先用下方按鍵回答"))
        #expect(await rig.sending.perform(.submit, note: rig.n1, to: "s12") == .refused("session 沒有在執行"))
        #expect(await rig.sending.perform(.ref, note: rig.n1, to: "s14") == .refused(NoteSending.notTargetText), "externals are never targets")
        #expect(await rig.sending.perform(.ref, note: rig.n1, to: "s8") == .refused(NoteSending.notTargetText), "a shell session neither")
        #expect(rig.sent.isEmpty)
        // The PTY that takes nothing (the holder went away between the check and the send).
        rig.accepts = false
        #expect(await rig.sending.perform(.submit, note: rig.n1, to: "s9") == .refused("session 沒有在執行"))
        // Over the 256 KiB INPUT budget: refused for both the draft and the PTY.
        rig.accepts = true
        let big = try await rig.notes.create("很長的筆記", body: "# 很長的筆記\n\n" + String(repeating: "長文字段落。", count: 50_000))
        let id = big.metadata.id
        #expect(await rig.sending.perform(.submit, note: id, to: "s9") == .refused("筆記太長，改用插入引用"))
        #expect(await rig.sending.perform(.full, note: id, to: "s6") == .refused("筆記太長，改用插入引用"))
        #expect(await rig.sending.perform(.ref, note: id, to: "s6") == .inserted("s6"), "its reference still fits")
        #expect(rig.sent.count == 1, "only the refused-by-the-PTY attempt reached it")
        await rig.tearDown()
    }

    @Test func aPromptRecordsWhereItWasSent() async throws {
        let rig = try await SendRig("codd-m4s-prompt")
        let prompt = try #require(NoteID(rawValue: "prompt-401-b3m9"))
        let before = await rig.notes.fileText(prompt)
        #expect(before.contains("sentTo: s1"))
        #expect(await rig.sending.perform(.submit, note: prompt, to: "s9") == .sent("s9"))
        let after = await rig.notes.fileText(prompt)
        #expect(after.contains("sentTo: s9"), "D14: sent / sentTo of the PROMPT")
        // A NOTE records nothing.
        let n1Before = await rig.notes.fileText(rig.n1)
        _ = await rig.sending.perform(.submit, note: rig.n1, to: "s9")
        #expect(await rig.notes.fileText(rig.n1) == n1Before)
        await rig.tearDown()
    }

    @Test func liveTargetsNeverListExternalsOrShells() async throws {
        let rig = try await SendRig("codd-m4s-targets")
        let p = NotebookPresenter(now: MockData.referenceDate, timeZone: MockNotes.timeZone, store: rig.notes.store, projects: [:])
        let ids = Set(p.liveTargets.map(\.id))
        #expect(ids.contains("s9") && ids.contains("s1"))
        #expect(!ids.contains("s14") && !ids.contains("s8") && !ids.contains("s12"))
        await rig.tearDown()
    }

    @Test func footerAndCommandReturnSendTheShownNoteToItsTarget() async throws {
        let rig = try await SendRig("codd-m4s-footer")
        await rig.notes.show(rig.n1)
        rig.notes.area.refreshChrome()
        let footer = try #require(rig.notes.area.chrome.model.footer)
        #expect(footer.target?.id == "s9" && footer.disabledReason == nil, "D14 default: the first live linked session")
        #expect(rig.notes.area.chrome.model.sendActionsDisabledReason == nil)
        // ⌘⏎ in the editor is the footer's 送出 (the menu's 允許 is disabled outside the sessions area).
        rig.notes.editor.onCommandReturn?()
        await m3Eventually("sent") { rig.sent.count == 1 }
        #expect(rig.sent.first?.target.sessionID == "s9")
        #expect(rig.notes.editor.documentView.toast != nil, "the outcome is the note's toast")
        // The footer's 插入引用, and SEND TO SESSION's action on another session.
        rig.notes.area.chrome.promptFooter.onInsertRef?()
        await m3Eventually("ref draft") { rig.composer.states.state("s9")?.draft.contains("codd://note/rwd-punch-k7x2") == true }
        rig.notes.area.chrome.onSend?("s6", .insertRef)
        await m3Eventually("s6 draft") { rig.composer.states.state("s6")?.draft == "codd://note/rwd-punch-k7x2" }
        await rig.tearDown()
    }

    @Test func aDraftNoteHasNothingToSend() async throws {
        let rig = try await SendRig("codd-m4s-draft")
        rig.notes.area.newNote()
        await m3Eventually("draft") { rig.notes.editor.draft != nil && !rig.notes.area.hasPendingRequests }
        let outcome = await rig.notes.area.sendShown(.submit)
        #expect(outcome == .refused(NotebookCopy.unsavedReason))
        #expect(rig.sent.isEmpty && rig.sending.attempts == 1)
        rig.notes.area.refreshChrome()
        #expect(rig.notes.area.chrome.model.footer?.disabledReason == NotebookCopy.unsavedReason)
        await rig.tearDown()
    }

    @Test func commandReturnBelongsToTheSessionsAreaOnlyThere() {
        let allow = #selector(AppDelegate.allowCurrentSession(_:))
        #expect(MenuAreaRules(area: .sessions, canAllow: true).isEnabled(allow) == true)
        #expect(MenuAreaRules(area: .notes, canAllow: true).isEnabled(allow) == false, "the note editor gets ⌘⏎ on NOTES")
        #expect(MenuAreaRules(area: .status, canAllow: true).isEnabled(allow) == false)
    }

    @Test func composerDrawsNoteReferencesAsChips() {
        #expect(ComposerBarView.style.referenceChips, "C4's chips are on (Split artboard `.sp-ref`)")
        let bar = ComposerBarView()
        bar.field.text = "參考 codd://note/rwd-punch-k7x2 再改"
        #expect(bar.field.text == "參考 codd://note/rwd-punch-k7x2 再改", "the text stays plain")
    }
}

@Suite("M4 notes drawer", .serialized)
@MainActor
struct M4DrawerTests {
    @Test func tasksAreReadOutsideCodeFences() {
        let body = """
        # t

        - [x] 先重現（Chrome DevTools 375 寬）
        - [ ] 按鈕改 `position: sticky`
          * [X] 巢狀的也算
        1. [ ] 有序的也算
        - [] 不是待辦
        ```md
        - [ ] 程式碼裡的不算
        ```
        """
        let tasks = NotesDrawerController.tasks(in: body)
        #expect(tasks.map(\.text) == ["先重現（Chrome DevTools 375 寬）", "按鈕改 `position: sticky`", "巢狀的也算", "有序的也算"])
        #expect(tasks.map(\.done) == [true, false, true, false])
    }

    @Test func cardsFollowTheSplitArtboard() async throws {
        let rig = try await SendRig("codd-m4d-cards")
        let drawer = NotesDrawerController(notes: rig.notes.service, store: rig.notes.store)
        drawer.draftReferences = { [composer = rig.composer] id in composer.draftReferences(id) }
        rig.composer.states.setDraft("參考 codd://note/rwd-punch-k7x2", for: "s9")
        await m3Eventually("draft") { rig.composer.states.state("s9") != nil }
        drawer.show("s9")
        drawer.rebuild()
        await m3Eventually("cards") { drawer.view.model.cards.count == 2 }
        let cards = drawer.view.model.cards
        #expect(cards.map(\.title) == ["打卡頁 RWD 跑版紀錄", "打卡頁 QA 清單"], "newest first")
        let n1 = cards[0]
        #expect(n1.isReferenced, "the draft references it: the amber border")
        #expect(n1.images.count == 2 && n1.images.map(\.caption) == ["直向", "橫向"])
        #expect(n1.imageCaption == "截圖 2026-10-15 09:32 · iPhone SE" && n1.imageSummary?.hasPrefix("2 張 · ") == true)
        #expect(n1.tasks.count == 3 && n1.taskProgress == NotesDrawerTaskProgress(done: 1, total: 3))
        #expect(n1.tags == "#rwd #punch" && n1.updated == "更新 10:05" && n1.aiRead == "AI 讀取 10:12")
        let qa = cards[1]
        #expect(!qa.isReferenced && qa.images.isEmpty && qa.taskProgress?.text == "1/3")
        #expect(qa.metaParts == ["#qa #punch", "1/3", "更新 昨天 17:05"], "the progress shows when the card has no image")
        #expect(drawer.view.model.files == nil, "the files section waits for I3")
        #expect(drawer.view.model.actionsDisabledReason == nil)
        drawer.show(nil)
        await rig.tearDown()
    }

    @Test func emptyAndNonTargetSessions() async throws {
        let rig = try await SendRig("codd-m4d-empty")
        let drawer = NotesDrawerController(notes: rig.notes.service, store: rig.notes.store)
        drawer.show("s13")
        drawer.rebuild()
        await m3Eventually("built") { drawer.builds > 0 }
        #expect(drawer.view.model.cards.isEmpty && drawer.view.model.emptyText == NotebookCopy.drawerEmpty)
        #expect(NotesDrawerController.actionsDisabledReason(rig.notes.store.session("s14")) == NoteSending.notTargetText)
        #expect(NotesDrawerController.actionsDisabledReason(rig.notes.store.session("s8")) == NoteSending.notTargetText)
        #expect(NotesDrawerController.actionsDisabledReason(rig.notes.store.session("s9")) == nil)
        drawer.show(nil)
        await rig.tearDown()
    }

    @Test func aNewLinkedNoteIsADraftUntilTyped() async throws {
        let rig = try await SendRig("codd-m4d-new")
        let links = NoteLinks(sessions: ["s9"], projects: [MockNotes.frontend])
        let before = (try? FileManager.default.contentsOfDirectory(atPath: rig.notes.notesDir))?.count ?? 0
        rig.notes.area.newLinkedNote(links: links)
        await m3Eventually("draft") { rig.notes.editor.draft != nil && !rig.notes.area.hasPendingRequests }
        #expect(rig.notes.editor.draft?.kind == .note && rig.notes.editor.draft?.links == links)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.notes.notesDir))?.count ?? 0) == before, "D3: nothing on disk yet")
        rig.notes.editor.type("RWD 追蹤")
        await m3Eventually("created") { rig.notes.editor.noteID != nil }
        let metadata = try #require(rig.notes.editor.document?.metadata)
        #expect(metadata.links.sessions == ["s9"] && metadata.scope == .project, "D20: linked → project scope")
        await rig.tearDown()
    }

    @Test func thePillTogglesTheDrawerColumnPerSession() {
        let row = PaneBodyRowView(content: NSView())
        row.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        row.drawer = NSView()
        row.layoutSubtreeIfNeeded()
        #expect(row.content.frame.width == 1000 && row.drawer?.isHidden == true)
        row.showsDrawer = true
        #expect(row.content.frame.width == 700 && row.drawer?.frame == NSRect(x: 700, y: 0, width: 300, height: 600))
        row.showsDrawer = false
        #expect(row.content.frame.width == 1000)
    }
}
