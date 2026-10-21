import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

@MainActor
@Suite struct ChromeTests {
    private func make(_ model: NoteEditorChromeModel = NotebookSamples.n1Chrome) -> (Host<NoteEditorChromeView>, RecordingPresenter) {
        let view = NoteEditorChromeView(model: model)
        let presenter = RecordingPresenter()
        view.menuPresenter = presenter
        return (Host(view, size: CGSize(width: 848, height: 876)), presenter)
    }

    @Test func artboardMetrics() {
        let (host, _) = make()
        defer { host.tearDown() }
        let view = host.view
        #expect(NoteEditorChromeView.topBarHeight == 52)
        #expect(view.infoPanel.frame == CGRect(x: 848 - 240, y: 52, width: 240, height: 876 - 52))
        #expect(view.promptFooter.frame.height == 41)
        #expect(view.docStatus.frame.height == 22)
        #expect(view.docStatus.frame.maxY == view.promptFooter.frame.minY)
        #expect(view.documentSlot.frame == CGRect(x: 0, y: 52, width: 608, height: 876 - 52 - 22 - 41))
        #expect(view.copyRef.frame.height == 24)
        #expect(view.aiPill.frame.height == 20)
        #expect(view.scopePill.frame.height == 20)
        #expect(view.moreButton.frame.maxX == 838, "`.nb-top{padding:0 10px 0 20px}`")
        #expect(view.crumb.frame.minX == 20)
    }

    @Test func topBarTexts() {
        let (host, _) = make()
        defer { host.tearDown() }
        let texts = host.view.topBarTexts
        let expected = ["INBOX", "/", "打卡頁 RWD 跑版紀錄", "AI 可讀 READ ▾", "PROJECT: orb-toolkit-frontend ▾", "id rwd-punch-k7x2", "[ COPY REF",
                        "▾ ]", "SEND TO SESSION ▾", "⋯"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected)) in \(texts)")
        #expect(host.view.aiPill.content.tone == .cyan)
    }

    @Test func documentSlotHostsTheEditor() {
        let (host, _) = make()
        defer { host.tearDown() }
        let editor = NSView()
        host.view.documentView = editor
        host.settle()
        #expect(editor.superview === host.view.documentSlot)
        #expect(editor.frame == host.view.documentSlot.bounds)
        let other = NSView()
        host.view.documentView = other
        #expect(editor.superview == nil)
    }

    // MARK: COPY REF (D15, §3.6)

    @Test func copyRefMenuListsTheFiveFormsInOrder() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        view.copyRef.menuPart.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(view.presentedMenu == .copyRef)
        #expect(view.copyRef.menuPart.isOn)
        #expect(menu.model.width == 404)
        guard case .header(let title, let trailing) = menu.model.entries.first else { Issue.record("no header"); return }
        #expect(title == "Copy reference · 複製引用")
        #expect(trailing == "rwd-punch-k7x2")
        let items = menu.visibleItems
        #expect(items.map(\.title) == ["codd://note/rwd-punch-k7x2", "@codd:codd://note/rwd-punch-k7x2",
                                       "\(NotebookSamples.notesPath)/2026-10-15-打卡頁-rwd-跑版紀錄.md", "複製全文 Markdown",
                                       "http://127.0.0.1:47821/n/rwd-punch-k7x2.md?t=••••"])
        #expect(items.map(\.hint) == NotebookRefForm.allCases.map(\.hint))
        #expect(items[0].hint == "CODD 啟動的 session 會由 UserPromptSubmit hook 自動展開內容")
        #expect(items[4].hint == "瀏覽器 / curl 用；Claude 的 WebFetch 讀不到 localhost")
        #expect(items[0].chip == "推薦")
        #expect(items[0].shortcut == "⌘⇧C")
        #expect(items[0].tone == .amber)
        #expect(items.dropFirst().allSatisfy { $0.chip == nil && $0.shortcut == nil })
        #expect(items.allSatisfy { $0.isEnabled })
        #expect(menu.highlightedID == "ref.1", "the first item is `.hl`")
        // The separator sits right before the URL item.
        let entries = menu.model.entries
        #expect(entries[entries.count - 2] == .separator)
        // `.nb-refmenu{top:46px;right:10px}`.
        #expect(presenter.presented.last?.origin == CGPoint(x: 848 - 10 - 404, y: 46))
    }

    @Test func everyCopyRefFormReachesTheCallback() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        let forms = Recorder<NotebookRefForm>()
        view.onCopyRef = { forms.append($0) }
        view.copyRef.mainPart.performClick(nil)
        #expect(forms.values == [.uri], "the split button's left part copies form 1")
        #expect(presenter.current == nil)
        for form in NotebookRefForm.allCases {
            view.openMenu(.copyRef)
            let menu = try #require(presenter.current)
            #expect(menu.activate(id: "ref.\(form.rawValue)"))
            #expect(presenter.current == nil, "choosing closes the menu")
        }
        #expect(forms.values == [.uri] + NotebookRefForm.allCases)
        // Keyboard: ↓ ↓ ⏎ copies the file path.
        view.openMenu(.copyRef)
        let menu = try #require(presenter.current)
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(forms.last == .path)
    }

    @Test func offNoteDisablesTheURLForm() throws {
        let (host, presenter) = make(NotebookSamples.n1ChromeOff)
        defer { host.tearDown() }
        let view = host.view
        #expect(view.aiPill.content.tone == .dim)
        #expect(view.topBarTexts.contains("AI 關閉 OFF ▾"))
        view.openMenu(.copyRef)
        let menu = try #require(presenter.current)
        let url = try #require(menu.visibleItems.last)
        #expect(!url.isEnabled)
        #expect(url.hint == "AI 存取為 OFF，不提供網址")
        #expect(url.disabledReason == "AI 存取為 OFF，不提供網址")
        #expect(menu.row("ref.5")?.toolTip == "AI 存取為 OFF，不提供網址")
        #expect(menu.visibleItems.dropLast().allSatisfy { $0.isEnabled }, "the other forms stay")
        let forms = Recorder<NotebookRefForm>()
        view.onCopyRef = { forms.append($0) }
        #expect(!menu.activate(id: "ref.5"))
        menu.row("ref.5")?.performClick(nil)
        // ↑ from the first item wraps to the last enabled one (the URL is skipped).
        menu.handleKey(Keys.up)
        #expect(menu.highlightedID == "ref.4")
        #expect(forms.count == 0)
    }

    @Test func unsavedNoteDisablesCopyRefAndSend() throws {
        let (host, presenter) = make(NotebookSamples.unsavedChrome)
        defer { host.tearDown() }
        let view = host.view
        #expect(view.topBarTexts.contains("id —"))
        #expect(!view.copyRef.isEnabled)
        #expect(view.copyRef.mainPart.toolTip == NotebookCopy.unsavedReason)
        #expect(!view.sendButton.isEnabled)
        #expect(view.sendButton.toolTip == NotebookCopy.unsavedReason)
        let forms = Recorder<NotebookRefForm>()
        view.onCopyRef = { forms.append($0) }
        view.copyRef.mainPart.performClick(nil)
        view.copyRef.menuPart.performClick(nil)
        view.openMenu(.copyRef)
        view.openMenu(.send)
        #expect(presenter.presented.isEmpty, "no menu opens from a disabled button")
        #expect(forms.count == 0)
        let refMenu = view.menuModel(for: .copyRef)
        #expect(refMenu.items.count == 5)
        #expect(refMenu.items.allSatisfy { !$0.isEnabled && $0.disabledReason == NotebookCopy.unsavedReason })
        // The footer's three actions are disabled with the same reason.
        for button in [view.promptFooter.insertRefButton, view.promptFooter.insertFullButton, view.promptFooter.sendButton] {
            #expect(!button.isEnabled)
            #expect(button.toolTip == NotebookCopy.unsavedReason)
        }
        // ⋯ keeps pin / kind / source, disables the file actions.
        let more = view.menuModel(for: .more)
        for id in ["more.archive", "more.trash", "more.reveal", "more.copyID"] {
            #expect(more.item(id)?.isEnabled == false, "\(id) disabled")
        }
        for id in ["more.pin", "more.kind", "more.source"] { #expect(more.item(id)?.isEnabled == true) }
        #expect(view.infoPanel.isHidden)
    }

    @Test func savingTheNoteEnablesEverything() {
        let (host, _) = make(NotebookSamples.unsavedChrome)
        defer { host.tearDown() }
        var model = NotebookSamples.unsavedChrome
        model.noteID = "scratch-1016-a1b2"
        model.refs = NotebookRefTexts.standard(id: "scratch-1016-a1b2", path: "~/n.md", port: 47821)
        model.footer = NotebookSamples.n1Footer
        host.view.update(model)
        #expect(host.view.copyRef.isEnabled)
        #expect(host.view.sendButton.isEnabled)
        #expect(host.view.topBarTexts.contains("id scratch-1016-a1b2"))
        #expect(host.view.promptFooter.sendButton.isEnabled)
    }

    // MARK: AI, scope, SEND, ⋯

    @Test func aiMenuOffersTheThreeAccessesWithHints() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        let chosen = Recorder<NotebookAIAccess>()
        view.onAIAccess = { chosen.append($0) }
        view.aiPill.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(view.aiPill.isOn)
        #expect(menu.visibleItems.map(\.title) == ["AI 關閉 OFF", "AI 可讀 READ", "AI 可附加 APPEND"])
        #expect(menu.visibleItems.map(\.hint) == ["AI 看不到這則筆記（MCP 與引用展開都不提供）", "AI 可透過 MCP 讀取",
                                                  "AI 可讀取，也可以在最後附加內容"])
        #expect(menu.visibleItems.map(\.isChecked) == [false, true, false])
        #expect(menu.highlightedID == "ai.read")
        #expect(presenter.presented.last?.origin == CGPoint(x: view.aiPill.frame.minX, y: view.aiPill.frame.maxY + 4))
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(chosen.values == [.append])
        #expect(!view.aiPill.isOn)
        view.aiPill.performClick(nil)
        view.aiPill.performClick(nil)
        #expect(view.presentedMenu == nil, "a second click closes it")
    }

    @Test func scopeMenu() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        let scopes = Recorder<String>()
        view.onScope = { scopes.append($0) }
        view.scopePill.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(menu.visibleItems.map(\.title) == ["Global", "orb-toolkit-frontend", "orb-toolkit-backend", "MCP 整合範例", "Gear3D"])
        #expect(menu.visibleItems.first { $0.isChecked }?.title == "orb-toolkit-frontend")
        #expect(menu.activate(id: "scope.global"))
        #expect(presenter.current == nil)
        for option in NotebookSamples.n1Chrome.scopeOptions.dropFirst() {
            view.openMenu(.scope)
            #expect(try #require(presenter.current).activate(id: "scope.\(option.id)"))
        }
        #expect(scopes.values == NotebookSamples.n1Chrome.scopeOptions.map(\.id))
        var model = NotebookSamples.n1Chrome
        model.scopeID = NotebookScopeOption.globalID
        view.update(model)
        #expect(view.topBarTexts.contains("GLOBAL ▾"))
    }

    @Test func sendMenuListsSessionsWithTheirThreeActions() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        var sends: [String] = []
        view.onSend = { session, action in sends.append("\(session) \(action.rawValue)") }
        view.sendButton.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(menu.visibleItems.map(\.title) == NotebookSamples.liveSessions.map(\.title))
        #expect(menu.visibleItems.first?.glyph == .lamp(.busy))
        #expect(menu.visibleItems.first?.detail == "orb-toolkit-frontend · busy 6m")
        #expect(menu.visibleItems.allSatisfy { $0.submenu != nil })
        // → opens the highlighted session's actions in place; ← goes back.
        menu.handleKey(Keys.right)
        #expect(menu.stack.count == 1)
        #expect(menu.visibleItems.map(\.title) == ["打卡頁 RWD 調整", "插入引用", "插入全文", "送出全文"])
        #expect(menu.visibleItems.first?.id == NotebookMenuView.backRowID)
        #expect(menu.highlightedID == "send.insertRef.\(NotebookSamples.s9.id)")
        menu.handleKey(Keys.left)
        #expect(menu.stack.isEmpty)
        #expect(menu.highlightedID == "session.\(NotebookSamples.s9.id)")
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(menu.stack.count == 1, "⏎ on a session opens its actions")
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(sends == ["\(NotebookSamples.s1.id) send"])
        #expect(presenter.current == nil)
        // Every action of every session.
        for session in NotebookSamples.liveSessions {
            for action in NotebookSendAction.allCases {
                view.openMenu(.send)
                let menu = try #require(presenter.current)
                #expect(menu.activate(id: "session.\(session.id)"))
                #expect(menu.activate(id: "send.\(action.rawValue).\(session.id)"))
            }
        }
        #expect(sends.count == 1 + NotebookSamples.liveSessions.count * 3)
    }

    @Test func sendActionsDisabledWithTheirReason() throws {
        var model = NotebookSamples.n1Chrome
        model.sendActionsDisabledReason = "送到 session 在 I2b 接上"
        let (host, presenter) = make(model)
        defer { host.tearDown() }
        host.view.openMenu(.send)
        let menu = try #require(presenter.current)
        #expect(menu.activate(id: "session.\(NotebookSamples.s9.id)"))
        let actions = menu.visibleItems.dropFirst()
        #expect(actions.allSatisfy { !$0.isEnabled && $0.disabledReason == "送到 session 在 I2b 接上" })
        var sent = 0
        host.view.onSend = { _, _ in sent += 1 }
        #expect(!menu.activate(id: "send.send.\(NotebookSamples.s9.id)"))
        #expect(sent == 0)
        // Without sessions the menu says so.
        var none = NotebookSamples.n1Chrome
        none.sessions = []
        host.view.update(none)
        #expect(host.view.menuModel(for: .send).items.map(\.title) == [NotebookCopy.noTargetReason])
    }

    @Test func moreMenuActions() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        let actions = Recorder<NotebookMoreAction>()
        view.onMore = { actions.append($0) }
        view.moreButton.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(menu.visibleItems.map(\.title) == ["釘選", "類型", "封存", "移到垃圾桶", "在 Finder 顯示", "原始碼", "複製 ID"])
        #expect(menu.visibleItems.first { $0.id == "more.source" }?.shortcut == "⌘E")
        #expect(menu.visibleItems.first { $0.id == "more.trash" }?.tone == .danger)
        for id in ["more.pin", "more.archive", "more.trash", "more.reveal", "more.source", "more.copyID"] {
            view.openMenu(.more)
            #expect(try #require(presenter.current).activate(id: id))
        }
        view.openMenu(.more)
        let kindMenu = try #require(presenter.current)
        #expect(kindMenu.activate(id: "more.kind"))
        #expect(kindMenu.visibleItems.dropFirst().map(\.title) == ["NOTE", "PROMPT", "SCRATCH"])
        #expect(kindMenu.visibleItems.first { $0.isChecked }?.title == "NOTE")
        #expect(kindMenu.activate(id: "more.kind.prompt"))
        #expect(actions.values == [.togglePin, .archive, .trash, .revealInFinder, .toggleSource, .copyID, .kind(.prompt)])
        // Pinned, archived, trashed and source-mode variants.
        var model = NotebookSamples.n1Chrome
        model.pinned = true
        model.location = .archived
        model.sourceMode = true
        view.update(model)
        let archived = view.menuModel(for: .more)
        #expect(archived.item("more.pin")?.title == "取消釘選")
        #expect(archived.item("more.unarchive")?.title == "取消封存")
        #expect(archived.item("more.archive") == nil)
        #expect(archived.item("more.source")?.title == "即時預覽")
        model.location = .trashed
        view.update(model)
        let trashed = view.menuModel(for: .more)
        #expect(trashed.item("more.restore")?.title == "還原")
        #expect(trashed.item("more.trash") == nil)
        view.openMenu(.more)
        #expect(try #require(presenter.current).activate(id: "more.restore"))
        #expect(actions.last == .restore)
    }

    @Test func disabledReasonsFromTheModel() {
        var model = NotebookSamples.n1Chrome
        model.aiDisabledReason = "AI 存取在 I1b 接上"
        model.scopeDisabledReason = "範圍在 I1b 接上"
        model.copyRefDisabledReason = "複製引用在 I1b 接上"
        model.sendDisabledReason = "送到 session 在 I2b 接上"
        model.moreDisabledReason = "更多動作在 I1b 接上"
        let (host, presenter) = make(model)
        defer { host.tearDown() }
        let view = host.view
        #expect(!view.aiPill.isEnabled && view.aiPill.toolTip == "AI 存取在 I1b 接上")
        #expect(!view.scopePill.isEnabled && view.scopePill.toolTip == "範圍在 I1b 接上")
        #expect(!view.copyRef.isEnabled && view.copyRef.menuPart.toolTip == "複製引用在 I1b 接上")
        #expect(!view.sendButton.isEnabled && view.sendButton.toolTip == "送到 session 在 I2b 接上")
        #expect(!view.moreButton.isEnabled && view.moreButton.toolTip == "更多動作在 I1b 接上")
        for menu in NoteChromeMenu.allCases { view.openMenu(menu) }
        #expect(presenter.presented.isEmpty)
    }

    @Test func openMenuClosesWhenItsButtonTurnsDisabled() throws {
        let (host, presenter) = make()
        defer { host.tearDown() }
        let view = host.view
        view.openMenu(.copyRef)
        #expect(presenter.current != nil)
        // The note's AI access changes while the menu is open: the menu follows the model.
        view.update(NotebookSamples.n1ChromeOff)
        #expect(presenter.current?.visibleItems.last?.isEnabled == false)
        var model = NotebookSamples.n1ChromeOff
        model.copyRefDisabledReason = "x"
        view.update(model)
        #expect(presenter.current == nil)
        #expect(view.presentedMenu == nil)
        #expect(!view.copyRef.menuPart.isOn)
    }
}
