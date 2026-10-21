#if DEBUG
import AppKit
import CoddUI

/// `-codd-shortcut-matrix YES` (D21, M2 I4): presses the app shortcuts with the terminal, the
/// sidebar, the filter field and the composer focused (the composer also while 注音 composes), the
/// way AppKit dispatches them (the key window's views first, then the main menu), and checks each
/// one's effect. A focused terminal or composer must decline every chord (the terminal also as 注音
/// reports it: non-ASCII characters, the ANSI key code decides). Then the ⌘K palette: ⌘⏎ is its
/// own (the menu's 允許 never runs), esc closes it, ⌘K toggles it. Then the ⌘N sheet (I6): ⌘⏎ in the
/// sheet and in its open project list is claimed (允許 never runs; the create is refused because the
/// folder does not exist), esc closes the list, then the sheet. Logs `SHORTCUT …` per press and
/// `SHORTCUTS ok=n fail=m`.
@MainActor
struct ShortcutMatrix {
    let app: AppDelegate

    private struct Chord {
        var name: String
        var characters: String
        /// What 注音 reports for the same key (the terminal decline is checked with it too).
        var zhuyin: String?
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags
    }

    private enum Focus: String, CaseIterable { case terminal, sidebar, filter, composer, composing }

    func run() async {
        guard let main = app.mainWindow, let window = main.window, let menu = NSApp.mainMenu,
              let start = app.shell.currentSessionID else {
            HolderSessionStore.printLog("SHORTCUTS skipped: no window or no shown session")
            return
        }
        window.makeKeyAndOrderFront(nil)
        let composerWasOpen = app.shell.pane(for: start).composerOpen
        var ok = 0
        var fail = 0
        func report(_ focus: String, _ chord: String, _ passed: Bool, _ detail: String) {
            if passed { ok += 1 } else { fail += 1 }
            HolderSessionStore.printLog("SHORTCUT focus=\(focus) \(chord) \(passed ? "ok" : "FAIL") \(detail)")
        }
        let chords = [
            Chord(name: "⌘1", characters: "1", zhuyin: "ㄅ", keyCode: 0x12, modifiers: .command),
            Chord(name: "⌘2", characters: "2", zhuyin: "ㄉ", keyCode: 0x13, modifiers: .command),
            Chord(name: "⌘9", characters: "9", zhuyin: "ㄞ", keyCode: 0x19, modifiers: .command),
            Chord(name: "⌃Tab", characters: "\t", zhuyin: nil, keyCode: 0x30, modifiers: .control),
            Chord(name: "⌘\\", characters: "\\", zhuyin: "、", keyCode: 0x2A, modifiers: .command),
            Chord(name: "⌘⏎", characters: "\r", zhuyin: nil, keyCode: 0x24, modifiers: .command),
            Chord(name: "⌘T", characters: "t", zhuyin: "ㄔ", keyCode: 0x11, modifiers: .command),
            Chord(name: "⌘J", characters: "j", zhuyin: "ㄨ", keyCode: 0x26, modifiers: .command),
            Chord(name: "⌘P", characters: "p", zhuyin: "ㄣ", keyCode: 0x23, modifiers: .command),
            Chord(name: "⌘.", characters: ".", zhuyin: "ㄡ", keyCode: 0x2F, modifiers: .command),
            Chord(name: "⌘L", characters: "l", zhuyin: "ㄠ", keyCode: 0x25, modifiers: .command),
            Chord(name: "⌘K", characters: "k", zhuyin: "ㄜ", keyCode: 0x28, modifiers: .command),
        ]
        for focus in Focus.allCases {
            for chord in chords {
                main.show(start)
                try? await Task.sleep(for: .milliseconds(120))
                let responder = await self.focus(focus, main: main, window: window, session: start)
                let order = main.sidebar.snapshot.sessionOrder
                let session = app.sessionStore.session(start)
                let pinnedBefore = session?.isPinned ?? false
                let tabsBefore = app.shell.pane(for: start).panelTabs.count
                let panelBefore = app.shell.pane(for: start).panelOpen
                let composerBefore = app.shell.pane(for: start).composerOpen
                let composerFocused = main.pane.composer.bar.hasFocus
                let sidebarBefore = main.split.isSidebarCollapsed
                guard let event = key(chord.characters, chord, window) else { report(focus.rawValue, chord.name, false, "no event"); continue }
                let claimedByView = window.performKeyEquivalent(with: event)
                var zhuyinDeclined = true
                if focus == .terminal || focus == .composing, let chars = chord.zhuyin, let ime = key(chars, chord, window) {
                    zhuyinDeclined = !window.performKeyEquivalent(with: ime)
                }
                let taken = !claimedByView && menu.performKeyEquivalent(with: event)
                try? await Task.sleep(for: .milliseconds(150))
                var effect = false
                var note = ""
                switch chord.name {
                case "⌘1": effect = app.shell.currentSessionID == order.first
                case "⌘2": effect = order.count < 2 || app.shell.currentSessionID == order[1]
                case "⌘9":
                    effect = order.count < 9 ? !claimedByView : app.shell.currentSessionID == order[8]
                    if order.count < 9 { note = "(fewer than 9 sessions: beeps)" }
                case "⌃Tab":
                    let index = order.firstIndex(of: start) ?? -1
                    effect = order.isEmpty || app.shell.currentSessionID == order[(index + 1) % order.count]
                case "⌘\\":
                    try? await Task.sleep(for: .milliseconds(300))
                    effect = main.split.isSidebarCollapsed != sidebarBefore
                    // Put it back without animation: the split view autosaves its state into the
                    // app's defaults, which the user's own CODD reads too.
                    main.split.sidebarItem.isCollapsed = sidebarBefore
                    try? await Task.sleep(for: .milliseconds(100))
                case "⌘⏎":
                    // Allow needs a WAITING claude on screen; otherwise the item is disabled and
                    // what counts is that no view swallowed the chord.
                    let canAllow = main.pane.canAllowCurrent
                    effect = canAllow ? taken : !claimedByView
                    note = canAllow ? "" : "(no waiting session: item disabled)"
                case "⌘T":
                    // A new terminal in the bottom panel, focused there; ⌘W then closes that tab.
                    effect = app.shell.pane(for: start).panelTabs.count == tabsBefore + 1 && main.pane.panelSurface.hasFocus
                    let close = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
                        .first { $0.action == #selector(NSWindow.performClose(_:)) }
                    if effect {
                        window.performClose(close)
                        effect = app.shell.pane(for: start).panelTabs.count == tabsBefore
                    }
                    if app.shell.pane(for: start).panelOpen != panelBefore { main.pane.toggleBottomTerminal() }
                case "⌘J":
                    effect = app.shell.pane(for: start).panelOpen != panelBefore
                    main.pane.toggleBottomTerminal()
                case "⌘P":
                    effect = (app.sessionStore.session(start)?.isPinned ?? false) != pinnedBefore
                    app.sessionStore.setPinned(pinnedBefore, sessions: [start])
                case "⌘.":
                    if session?.state.isLive == true {
                        try? await Task.sleep(for: .milliseconds(200))
                        if let sheet = window.attachedSheet {
                            effect = true
                            note = "(confirm sheet shown, cancelled)"
                            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                        }
                    } else {
                        effect = !claimedByView
                        note = "(session not running: item disabled)"
                    }
                case "⌘L":
                    // The ⌘L state machine: hidden → shown + focused; shown, focused → hidden.
                    let open = app.shell.pane(for: start).composerOpen
                    if composerFocused {
                        effect = composerBefore && !open && !main.pane.composer.bar.hasFocus
                    } else {
                        effect = open && main.pane.composer.bar.hasFocus
                    }
                    note = "(composer \(composerBefore ? "open" : "closed")→\(open ? "open" : "closed"))"
                    app.shell.setComposerOpen(composerBefore, in: start)
                case "⌘K":
                    effect = app.palette?.isShown == true
                    app.palette?.close()
                default: break
                }
                // Setting the text drops the composition (as a session switch does): committing it
                // with unmarkText would put the test's ㄅㄚ into the session's saved draft.
                main.pane.composer.bar.field.text = ""
                let passed = !claimedByView && zhuyinDeclined && effect
                report(focus.rawValue, chord.name, passed,
                       "responder=\(responder) declinedByView=\(!claimedByView) zhuyinDeclined=\(zhuyinDeclined) menu=\(taken) effect=\(effect) \(note)")
            }
        }
        await notesChecks(main: main, window: window, menu: menu, start: start, report: report)
        await filesChecks(main: main, window: window, menu: menu, start: start, report: report)
        await zoomChecks(main: main, window: window, menu: menu, start: start, report: report)
        await paletteChecks(main: main, window: window, menu: menu, start: start, report: report)
        await sheetChecks(menu: menu, report: report)
        main.show(start)
        app.shell.setComposerOpen(composerWasOpen, in: start)
        main.pane.surface.focus()
        HolderSessionStore.printLog("SHORTCUTS ok=\(ok) fail=\(fail)")
    }

    /// M4 D13 / D36: in the sessions area ⌘⇧N starts the quick SCRATCH linked to the shown
    /// session (a terminal declines the chord, also as 注音 reports it; nothing while the composer
    /// composes) and ⌘E / ⌘F / ⌘⇧A / ⌘⇧C (NOTES only) never act (no pasteboard write either); on
    /// NOTES 允許 ⌘⏎ never runs while ⌘E toggles the shown note's mode, ⌘F focuses the Notebook
    /// search, ⌘⇧C copies `codd://note/<id>` (the private pasteboard in a background run) and
    /// ⌘⇧A opens ImageAnnotate when the note has an image (I1b).
    private func notesChecks(main: MainWindowController, window: NSWindow, menu: NSMenu, start: SessionID,
                             report: (String, String, Bool, String) -> Void) async {
        let quick = Chord(name: "⌘⇧N", characters: "N", zhuyin: "ㄙ", keyCode: 0x2D, modifiers: [.command, .shift])
        let source = Chord(name: "⌘E", characters: "e", zhuyin: "ㄍ", keyCode: 0x0E, modifiers: .command)
        let search = Chord(name: "⌘F", characters: "f", zhuyin: "ㄑ", keyCode: 0x03, modifiers: .command)
        let annotate = Chord(name: "⌘⇧A", characters: "A", zhuyin: "ㄇ", keyCode: 0x00, modifiers: [.command, .shift])
        let copyRef = Chord(name: "⌘⇧C", characters: "C", zhuyin: "ㄏ", keyCode: 0x08, modifiers: [.command, .shift])
        let commandReturn = Chord(name: "⌘⏎", characters: "\r", zhuyin: nil, keyCode: 0x24, modifiers: .command)
        let isCODD = app.sessionStore.session(start).map { !$0.external } ?? false
        for focus in Focus.allCases {
            for chord in [quick, source, search, annotate, copyRef] {
                main.show(start)
                try? await Task.sleep(for: .milliseconds(150))
                let responder = await self.focus(focus, main: main, window: window, session: start)
                let modeBefore = app.noteEditor.mode
                let runsBefore = app.notesCommandRuns
                let draftsBefore = app.notes.draftsStarted
                let writeBefore = app.pasteboard.lastWrite
                guard let event = key(chord.characters, chord, window) else { report(focus.rawValue, chord.name, false, "no event"); continue }
                let claimedByView = window.performKeyEquivalent(with: event)
                var zhuyinDeclined = true
                if focus == .terminal, let chars = chord.zhuyin, let ime = key(chars, chord, window) {
                    zhuyinDeclined = !window.performKeyEquivalent(with: ime)
                }
                let taken = !claimedByView && menu.performKeyEquivalent(with: event)
                try? await Task.sleep(for: .milliseconds(200))
                var passed: Bool
                var note = ""
                switch chord.name {
                case "⌘⇧N":
                    if focus == .composing {
                        // The disabled item takes the key (AppKit) but never acts; the composition stays.
                        let stillComposing = main.pane.composer.bar.textView.hasMarkedText()
                        passed = app.shell.area == .sessions && app.notes.draftsStarted == draftsBefore && stillComposing
                        note = "(composing: refused, marked=\(stillComposing))"
                    } else {
                        let draft = app.noteEditor.draft
                        let linked = !isCODD || draft?.links.sessions == [start.lowercased()]
                        passed = !claimedByView && zhuyinDeclined && taken && app.shell.area == .notes && draft?.kind == .scratch && linked
                        note = "(area=\(app.shell.area.rawValue) draft=\(draft?.kind.rawValue ?? "-") linked=\(linked))"
                    }
                default:
                    // A disabled item still takes its key (AppKit); what counts is that it never acts.
                    passed = app.notesCommandRuns == runsBefore && app.shell.area == .sessions && app.noteEditor.mode == modeBefore
                        && app.pasteboard.lastWrite == writeBefore && app.notesArea?.mode == .notebook
                    note = "(NOTES only: never acts)"
                }
                main.pane.composer.bar.field.text = ""
                report(focus.rawValue, chord.name, passed, "responder=\(responder) declinedByView=\(!claimedByView) "
                       + "zhuyinDeclined=\(zhuyinDeclined) menu=\(taken) \(note)")
            }
        }
        // On NOTES: ⌘⏎ never runs 允許 (in the editor it is the note's 送出, I2b), ⌘E toggles the shown
        // note (when there is one), ⌘F the search,
        // ⌘⇧C copies the reference, ⌘⇧A opens ImageAnnotate (a note with an image is shown first).
        main.show(start)
        app.shell.area = .notes
        try? await Task.sleep(for: .milliseconds(400))
        if let withImage = app.notes.rows.first(where: { $0.assetCount > 0 }), let area = app.notesArea {
            area.reveal(withImage.id)
            try? await Task.sleep(for: .milliseconds(400))
        }
        for chord in [commandReturn, source, search, copyRef, annotate] {
            // I2b (D14, D36): ⌘⏎ with the note editor focused is the note's 送出, never 允許.
            if chord.name == "⌘⏎", app.noteEditor.hasContent {
                app.noteEditor.focus()
                try? await Task.sleep(for: .milliseconds(100))
            }
            let sendsBefore = app.noteSending.attempts
            let allowsBefore = app.allowInvocations
            let modeBefore = app.noteEditor.mode
            let shown = app.noteEditor.hasContent
            let saved = app.noteEditor.noteID != nil
            let hasImage = saved && !app.noteEditor.imagePaths.isEmpty
            let runsBefore = app.notesCommandRuns
            let writeBefore = app.pasteboard.lastWrite
            guard let event = key(chord.characters, chord, window) else { report("notes", chord.name, false, "no event"); continue }
            let claimedByView = window.performKeyEquivalent(with: event)
            let taken = !claimedByView && menu.performKeyEquivalent(with: event)
            try? await Task.sleep(for: .milliseconds(300))
            var passed: Bool
            var note = ""
            switch chord.name {
            case "⌘⏎":
                let routed = app.noteSending.attempts > sendsBefore
                passed = app.allowInvocations == allowsBefore && (!shown || (claimedByView && routed))
                note = "(send routed=\(routed) outcome=\(app.noteSending.last?.outcome ?? "-"))"
                // The other chords run with the keyboard where the area put it (the note list).
                if let list = app.notesArea?.noteList { window.makeFirstResponder(list) }
            case "⌘E":
                passed = shown ? (taken && app.noteEditor.mode != modeBefore) : !taken
                if app.noteEditor.mode != modeBefore { app.noteEditor.toggleMode() }
            case "⌘⇧C":
                let write = app.pasteboard.lastWrite
                let wrote = write != writeBefore
                let target = write?.target.rawValue ?? "-"
                passed = saved ? (taken && wrote && (!AppActivation.isBackground || write?.target == .private))
                    : (app.notesCommandRuns == runsBefore && !wrote)
                note = "(saved=\(saved) wrote=\(wrote) target=\(target))"
            case "⌘⇧A":
                let opened = app.notesArea?.mode == .annotate
                passed = hasImage ? (taken && opened) : (app.notesCommandRuns == runsBefore && !opened)
                note = "(image=\(hasImage) opened=\(opened))"
                if opened { app.notesArea?.cancelAnnotate() }
            default:
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                passed = taken && responder.contains("TextView")
            }
            report("notes", chord.name, passed, "claimedByView=\(claimedByView) menu=\(taken) shown=\(shown) "
                   + "allows=\(app.allowInvocations - allowsBefore) \(note)")
        }
        main.show(start)
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// M4 interface zoom: ⌘=, ⌘+ (⌘⇧=), ⌘− and ⌘0 with the terminal focused (⌘− and ⌘0 also as
    /// 注音 reports them): the terminal declines each, the menu takes it, and the UI and terminal
    /// sizes move one point together (⌘0: UI back to 13, the terminal by the steps taken) with the windows and every terminal
    /// at the new sizes, so libghostty never stepped its own size next to the menu's. The sizes
    /// the run started with are restored afterwards.
    private func zoomChecks(main: MainWindowController, window: NSWindow, menu: NSMenu, start: SessionID,
                            report: (String, String, Bool, String) -> Void) async {
        let chords = [
            Chord(name: "⌘=", characters: "=", zhuyin: nil, keyCode: 0x18, modifiers: .command),
            Chord(name: "⌘+", characters: "+", zhuyin: nil, keyCode: 0x18, modifiers: [.command, .shift]),
            Chord(name: "⌘−", characters: "-", zhuyin: "ㄦ", keyCode: 0x1B, modifiers: .command),
            Chord(name: "⌘0", characters: "0", zhuyin: "ㄢ", keyCode: 0x1D, modifiers: .command),
        ]
        let original = app.preferences.preferences.appearance
        for chord in chords {
            main.show(start)
            try? await Task.sleep(for: .milliseconds(120))
            let responder = await focus(.terminal, main: main, window: window, session: start)
            let before = app.preferences.preferences.appearance
            let expected = switch chord.name {
            case "⌘−": before.zoomed(by: -1)
            case "⌘0": before.zoomReset()
            default: before.zoomed(by: 1)
            }
            guard let event = key(chord.characters, chord, window) else { report("terminal", chord.name, false, "no event"); continue }
            let claimedByView = window.performKeyEquivalent(with: event)
            var zhuyinDeclined = true
            if let chars = chord.zhuyin, let ime = key(chars, chord, window) { zhuyinDeclined = !window.performKeyEquivalent(with: ime) }
            let taken = !claimedByView && menu.performKeyEquivalent(with: event)
            try? await Task.sleep(for: .milliseconds(400))
            let after = app.preferences.preferences.appearance
            let terminal = app.shell.terminalFontSize
            let engines = app.terminalHub.map { Double($0.fontSize) } ?? terminal
            let effect = after == expected && UIZoom.fontSize == after.uiFontSize
                && terminal == Double(after.terminalFontSize) && engines == terminal
            report("terminal", chord.name, !claimedByView && zhuyinDeclined && taken && effect,
                   "responder=\(responder) declinedByView=\(!claimedByView) zhuyinDeclined=\(zhuyinDeclined) menu=\(taken) "
                   + "ui=\(before.uiFontSize)→\(after.uiFontSize) terminal=\(before.terminalFontSize)→\(after.terminalFontSize) "
                   + "applied=\(UIZoom.fontSize)/\(terminal)/\(engines)")
        }
        app.preferences.update {
            $0.appearance.uiFontSize = original.uiFontSize
            $0.appearance.terminalFontSize = original.terminalFontSize
            $0.appearance.zoomTerminalSteps = original.zoomTerminalSteps
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// M4 I3 (D36): in the Files mode (a scratch file in the run's data root) ⌘P focuses the
    /// filter (never 釘選), ⌘F opens the find widget (never 搜尋筆記), ⌘S writes the typed edit, ⌘W
    /// closes the clean tab (the window stays), and ⌘W on a dirty tab asks first (不儲存 leaves the
    /// file as it was). Back in the sessions area ⌘W belongs to 關閉分頁或視窗 again.
    private func filesChecks(main: MainWindowController, window: NSWindow, menu: NSMenu, start: SessionID,
                             report: (String, String, Bool, String) -> Void) async {
        guard let root = app.holderStore?.root.url, let area = app.notesArea, let mode = app.filesMode else { return }
        let folder = root.appendingPathComponent("shortcut-matrix-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("matrix.txt")
        try? Data("hello\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: folder) }
        let filter = Chord(name: "⌘P", characters: "p", zhuyin: "ㄣ", keyCode: 0x23, modifiers: .command)
        let find = Chord(name: "⌘F", characters: "f", zhuyin: "ㄑ", keyCode: 0x03, modifiers: .command)
        let save = Chord(name: "⌘S", characters: "s", zhuyin: "ㄋ", keyCode: 0x01, modifiers: .command)
        let close = Chord(name: "⌘W", characters: "w", zhuyin: "ㄊ", keyCode: 0x0D, modifiers: .command)
        app.shell.area = .notes
        guard let tab = await app.files.open(file, preview: false, root: folder) else {
            report("files", "open", false, "no tab")
            return
        }
        area.showFilesMode()
        try? await Task.sleep(for: .milliseconds(400))
        let pinnedBefore = app.sessionStore.session(start)?.isPinned ?? false
        for chord in [filter, find, save, close] {
            mode.focusEditor()
            try? await Task.sleep(for: .milliseconds(80))
            if chord.name == "⌘S" {
                tab.editor?.textViewForTesting.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard let event = key(chord.characters, chord, window) else { report("files", chord.name, false, "no event"); continue }
            let claimedByView = window.performKeyEquivalent(with: event)
            let taken = !claimedByView && menu.performKeyEquivalent(with: event)
            try? await Task.sleep(for: .milliseconds(300))
            let responder = window.firstResponder as? NSView
            var passed: Bool
            var note = ""
            switch chord.name {
            case "⌘P":
                let focused = responder?.isDescendant(of: mode.view.tree) ?? false
                let pinned = app.sessionStore.session(start)?.isPinned ?? false
                passed = taken && focused && pinned == pinnedBefore
                note = "(filter=\(focused) pinChanged=\(pinned != pinnedBefore))"
            case "⌘F":
                let inEditor = tab.editor.map { responder?.isDescendant(of: $0) ?? false } ?? false
                let notebookSearch = responder?.isDescendant(of: area.lists) ?? false
                passed = (claimedByView || taken) && inEditor && !notebookSearch
                note = "(find field=\(inEditor))"
            case "⌘S":
                let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                passed = taken && !tab.isDirty && disk.contains("x")
                note = "(written=\(disk.contains("x")))"
            default:
                passed = taken && app.files.tab(tab.id) == nil && app.shell.area == .notes
                note = "(tab closed=\(app.files.tab(tab.id) == nil))"
            }
            report("files", chord.name, passed, "claimedByView=\(claimedByView) menu=\(taken) \(note)")
        }
        // A dirty tab asks first; 不儲存 never writes.
        if let dirty = await app.files.open(file, preview: false, root: folder) {
            let before = try? Data(contentsOf: file)
            mode.focusEditor()
            dirty.editor?.textViewForTesting.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(80))
            if let event = key(close.characters, close, window) {
                let claimedByView = window.performKeyEquivalent(with: event)
                let taken = !claimedByView && menu.performKeyEquivalent(with: event)
                try? await Task.sleep(for: .milliseconds(200))
                let asked = mode.dirtySheet != nil
                await mode.answerDirtyClose(.discard)
                let unchanged = (try? Data(contentsOf: file)) == before
                report("files", "⌘W dirty", taken && asked && unchanged && app.files.tab(dirty.id) == nil,
                       "menu=\(taken) asked=\(asked) unchanged=\(unchanged)")
            }
        }
        // The sessions area: ⌘W is 關閉分頁或視窗 again (validated, not pressed: it would close the window).
        main.show(start)
        try? await Task.sleep(for: .milliseconds(200))
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        if let windowClose = items.first(where: { $0.action == #selector(NSWindow.performClose(_:)) }),
           let tabClose = items.first(where: { $0.action == #selector(AppDelegate.closeFileTab(_:)) }) {
            let windowItem = window.validateMenuItem(windowClose)
            let tabItem = app.validateMenuItem(tabClose)
            report("sessions", "⌘W", windowItem && !tabItem, "closeWindow=\(windowItem) closeTab=\(tabItem)")
        }
    }

    /// In the ⌘K palette: ⌘⏎ is claimed by the panel (the menu's 允許 never runs, also with a
    /// waiting session on screen), esc closes it, ⌘K closes it again.
    private func paletteChecks(main: MainWindowController, window: NSWindow, menu: NSMenu, start: SessionID,
                               report: (String, String, Bool, String) -> Void) async {
        let checks: [(String, Chord)] = [
            ("⌘⏎", Chord(name: "⌘⏎", characters: "\r", zhuyin: nil, keyCode: 0x24, modifiers: .command)),
            ("esc", Chord(name: "esc", characters: "\u{1B}", zhuyin: nil, keyCode: 0x35, modifiers: [])),
            ("⌘K", Chord(name: "⌘K", characters: "k", zhuyin: nil, keyCode: 0x28, modifiers: .command)),
        ]
        for (name, chord) in checks {
            main.show(start)
            app.showQuickSwitch(nil)
            try? await Task.sleep(for: .milliseconds(150))
            guard let palette = app.palette, palette.isShown else { report("palette", name, false, "palette not shown"); continue }
            // A query without results: ⌘⏎ has nothing to open, so only the claim is measured.
            if name == "⌘⏎" { palette.setQuery("zzqqxxjj") }
            let panel = palette.panel
            let allowsBefore = app.allowInvocations
            guard let event = key(chord.characters, chord, panel) else { report("palette", name, false, "no event"); continue }
            let claimedByPanel = panel.performKeyEquivalent(with: event)
            let taken = !claimedByPanel && menu.performKeyEquivalent(with: event)
            try? await Task.sleep(for: .milliseconds(150))
            var passed: Bool
            switch name {
            case "⌘⏎": passed = claimedByPanel && !taken && app.allowInvocations == allowsBefore
            case "esc": passed = claimedByPanel && !palette.isShown
            default: passed = !claimedByPanel && taken && !palette.isShown
            }
            report("palette", name, passed, "claimedByPanel=\(claimedByPanel) menu=\(taken) allows=\(app.allowInvocations - allowsBefore) shown=\(palette.isShown)")
            palette.close()
        }
    }

    /// The ⌘N sheet and its project list claim ⌘⏎ (the folder is missing, so nothing starts);
    /// esc closes the list first and the sheet second.
    private func sheetChecks(menu: NSMenu, report: (String, String, Bool, String) -> Void) async {
        let commandReturn = Chord(name: "⌘⏎", characters: "\r", zhuyin: nil, keyCode: 0x24, modifiers: .command)
        let esc = Chord(name: "esc", characters: "\u{1B}", zhuyin: nil, keyCode: 0x35, modifiers: [])
        var form = NewSessionForm()
        form.path = "/codd-shortcut-matrix-missing-folder"
        app.presentNewSession(form)
        try? await Task.sleep(for: .milliseconds(400))
        guard let sheet = app.newSessionSheet, let window = sheet.window else {
            report("sheet", "⌘⏎", false, "sheet not shown")
            return
        }
        for (place, target) in [("sheet", window as NSWindow), ("sheet-list", sheet.dropdown as NSWindow)] {
            if place == "sheet-list" { sheet.openDropdownList() }
            let allowsBefore = app.allowInvocations
            guard let event = key(commandReturn.characters, commandReturn, target) else { report(place, "⌘⏎", false, "no event"); continue }
            let claimed = target.performKeyEquivalent(with: event)
            let taken = !claimed && menu.performKeyEquivalent(with: event)
            try? await Task.sleep(for: .milliseconds(150))
            let refused = (sheet.dumpObject["error"] as? String) != nil
            report(place, "⌘⏎", claimed && !taken && app.allowInvocations == allowsBefore && app.newSessionSheet === sheet && refused,
                   "claimed=\(claimed) menu=\(taken) allows=\(app.allowInvocations - allowsBefore) refused=\(refused)")
        }
        for (step, expectSheet) in [("esc list", true), ("esc sheet", false)] {
            guard let event = key(esc.characters, esc, window) else { continue }
            let claimed = window.performKeyEquivalent(with: event)
            try? await Task.sleep(for: .milliseconds(150))
            let sheetOpen = app.newSessionSheet != nil
            report("sheet", step, claimed && !sheet.isDropdownOpen && sheetOpen == expectSheet,
                   "claimed=\(claimed) list=\(sheet.isDropdownOpen) sheet=\(sheetOpen)")
        }
        app.newSessionSheet?.close()
    }

    private func key(_ characters: String, _ chord: Chord, _ window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: chord.keyCode)
    }

    private func focus(_ focus: Focus, main: MainWindowController, window: NSWindow, session: SessionID) async -> String {
        switch focus {
        case .terminal: main.pane.surface.focus()
        case .sidebar: window.makeFirstResponder(main.sidebar.outline)
        case .filter: main.sidebar.focusFilter()
        case .composer, .composing:
            if !app.shell.pane(for: session).composerOpen { main.pane.toggleComposer() }
            main.pane.composer.bar.focus()
            if focus == .composing {
                // 注音 in the middle of a syllable: the composition is marked text.
                main.pane.composer.bar.textView.setMarkedText("ㄅㄚ", selectedRange: NSRange(location: 2, length: 0),
                                                             replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        try? await Task.sleep(for: .milliseconds(60))
        let name = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        if focus == .composing { return name + (main.pane.composer.bar.textView.hasMarkedText() ? "+marked" : "") }
        return name
    }
}
#endif
