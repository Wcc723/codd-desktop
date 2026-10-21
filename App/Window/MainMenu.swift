import AppKit

/// Commands the main menu sends (implemented by the app delegate).
@MainActor @objc
protocol CoddCommands: AnyObject {
    func showSettings(_ sender: Any?)
    func showQuickSwitch(_ sender: Any?)
    func toggleSessionSidebar(_ sender: Any?)
    func selectSessionByNumber(_ sender: NSMenuItem)
    func selectNextSession(_ sender: Any?)
    func selectPreviousSession(_ sender: Any?)
    func allowCurrentSession(_ sender: Any?)
    func newShellTab(_ sender: Any?)
    func toggleBottomTerminal(_ sender: Any?)
    func showMainWindow(_ sender: Any?)
    func focusSidebarFilter(_ sender: Any?)
    /// ⌘N: the new-session sheet (real mode; mock mode beeps).
    func newSession(_ sender: Any?)
    /// ⌘Q: ends attached sheets first (AppKit does not quit while one is up), then terminates.
    func quitApp(_ sender: Any?)
    /// ⌘P (D21): pins / unpins the session on screen (never an external).
    func togglePinCurrentSession(_ sender: Any?)
    /// ⌘. (D21): stops the session on screen after the `要停止「…」嗎？` sheet (never an external).
    func stopCurrentSession(_ sender: Any?)
    /// ⌘L: the composer of the session on screen (show + focus, focus, or hide + focus the terminal).
    func toggleComposer(_ sender: Any?)
    /// ⌘⇧N (M4 D13): a NOTE while NOTES shows, else the quick SCRATCH linked to the session on
    /// screen. An in-app key equivalent only (never a system-wide hotkey: it is Finder's 新增檔案夾).
    /// The M4 commands are optional so earlier command targets (test doubles) stay valid.
    @objc optional func quickNote(_ sender: Any?)
    /// ⌘E (D36): the shown note's 原始碼 ⇄ 即時預覽.
    @objc optional func toggleNoteSource(_ sender: Any?)
    /// ⌘F (D36): the Notebook search (NOTES only).
    @objc optional func searchNotes(_ sender: Any?)
    /// ⌘⇧A (D10, D36): ImageAnnotate for the image at the caret, else the note's first (NOTES only).
    @objc optional func annotateImage(_ sender: Any?)
    /// ⌘⇧C (D15): copies `codd://note/<id>` of the shown note (NOTES only; D39 pasteboard).
    @objc optional func copyNoteReference(_ sender: Any?)
    /// ⌘S (M4 I3, D24): saves the Files mode's shown tab (the only way a file is written).
    @objc optional func saveFile(_ sender: Any?)
    /// ⌘W (D36): closes the Files mode's shown tab (a dirty one asks first).
    @objc optional func closeFileTab(_ sender: Any?)
    /// ⌘P (D36): the Files mode's filter field.
    @objc optional func filterFiles(_ sender: Any?)
    /// ⌘F (D36): the find widget in the Files mode's shown file.
    @objc optional func findInFile(_ sender: Any?)
    /// ⌘+ / ⌘= (M4 interface zoom): UI 字級 and 終端機字級 one point larger, together.
    @objc optional func zoomIn(_ sender: Any?)
    /// ⌘− : both one point smaller.
    @objc optional func zoomOut(_ sender: Any?)
    /// ⌘0: both back to their defaults (13 / 13).
    @objc optional func zoomToActualSize(_ sender: Any?)
    /// 說明 › 首次啟動設定… (M5 D5): the onboarding window, from step 1 with live data (brought
    /// forward when it is open already). A menu item only, no key equivalent.
    @objc optional func showOnboarding(_ sender: Any?)

    // M5 D21: every action that was only a click gets a menu item (no new key equivalents), so the
    // keyboard and VoiceOver reach it.

    /// 顯示方式 › SESSIONS / NOTES / STATUS: the rail's destinations (SETTINGS is `showSettings`).
    @objc optional func showSessionsArea(_ sender: Any?)
    @objc optional func showNotesArea(_ sender: Any?)
    @objc optional func showStatusArea(_ sender: Any?)
    /// 筆記 › 筆記本 / 檔案 / 清理建議: the NOTES area's modes (Files: the shown session's project).
    @objc optional func showNotebookMode(_ sender: Any?)
    @objc optional func showFilesMode(_ sender: Any?)
    @objc optional func showCleanupMode(_ sender: Any?)
    /// Session › 筆記抽屜: the pane's `✎ NOTES` pill.
    @objc optional func toggleNotesDrawer(_ sender: Any?)
    /// Session › 新增群組…: the sidebar's `+ 新增群組` row.
    @objc optional func newGroup(_ sender: Any?)
    /// CODD › 暫停通知 1 小時 / 恢復通知: the status item's menu entry (D23).
    @objc optional func togglePauseNotifications(_ sender: Any?)
    /// Session › 切換帳號 ▸: fills the submenu when it opens (the sidebar footer's and the menu bar
    /// panel's account rows, R7 order, ✓ on the active one).
    @objc optional func fillAccountsMenu(_ menu: NSMenu)
}

/// Fills Session › 切換帳號 each time it opens (the accounts change while CODD runs).
@MainActor
final class AccountsMenuFiller: NSObject, NSMenuDelegate {
    weak var commands: CoddCommands?

    init(commands: CoddCommands) {
        self.commands = commands
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        commands?.fillAccountsMenu?(menu)
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "沒有帳號資料", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }
}

/// Builds the main menu. Shortcuts per SPEC §2: ⌘1–9 jump · ⌃Tab cycle · ⌘K quick switch · ⌘N new
/// session · ⌘\ focus mode · ⌘, settings · ⌘⏎ allow · ⌘T new shell tab · ⌘J bottom terminal · ⌘L
/// composer · ⌘P pin · ⌘. stop (D21) · ⌘+ / ⌘− / ⌘0 interface zoom (M4; ⌥⌘0 opens the main window), plus the
/// standard ⌘W / ⌘M / ⌘Q. They are menu key equivalents (no event monitors), so they never pre-empt
/// the input method; terminals leave them to the menu (`CoddTerminalSetup.keyEquivalents`). ⌘W
/// closes the pane's shell tab first (`CoddMainWindow`). Closing the main window keeps CODD in the
/// menu bar (sessions never stop on close).
@MainActor
enum MainMenuBuilder {
    /// Keeps Session › 切換帳號's delegate alive (a menu holds its delegate weakly).
    private static var accountsFiller: AccountsMenuFiller?

    static func build(commands: CoddCommands) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("CODD", appMenu(commands)))
        main.addItem(submenu("檔案", fileMenu(commands)))
        main.addItem(submenu("編輯", editMenu()))
        main.addItem(submenu("顯示方式", viewMenu(commands)))
        main.addItem(submenu("Session", sessionMenu(commands)))
        main.addItem(submenu("筆記", notesMenu(commands)))
        let window = windowMenu(commands)
        main.addItem(submenu("視窗", window))
        NSApp.windowsMenu = window
        let help = helpMenu(commands)
        main.addItem(submenu("說明", help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command],
                             target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private static func appMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        m.addItem(item("關於 CODD", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        m.addItem(item("設定…", #selector(CoddCommands.showSettings(_:)), ",", target: c))
        m.addItem(.separator())
        m.addItem(item(pauseNotificationsTitle, #selector(CoddCommands.togglePauseNotifications(_:)), target: c))
        m.addItem(.separator())
        m.addItem(item("隱藏 CODD", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("隱藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("顯示全部", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("結束 CODD", #selector(CoddCommands.quitApp(_:)), "q", target: c))
        return m
    }

    /// M4 I3 (D36): the Files mode's items. Each shares its key with an item of another area
    /// (⌘W 關閉分頁或視窗, ⌘P 釘選, ⌘F 搜尋筆記), and every pair is mutually exclusive in validation
    /// (`MenuAreaRules`): they act only while the NOTES area shows the Files mode, never while an
    /// input method composes.
    private static func fileMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        m.addItem(item("儲存", #selector(CoddCommands.saveFile(_:)), "s", target: c))
        m.addItem(item("關閉分頁", #selector(CoddCommands.closeFileTab(_:)), "w", target: c))
        m.addItem(.separator())
        m.addItem(item("篩選檔案", #selector(CoddCommands.filterFiles(_:)), "p", target: c))
        m.addItem(item("尋找", #selector(CoddCommands.findInFile(_:)), "f", target: c))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("還原", Selector(("undo:")), "z"))
        m.addItem(item("重做", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("剪下", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("拷貝", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("貼上", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("全選", #selector(NSText.selectAll(_:)), "a"))
        return m
    }

    /// `暫停通知 1 小時`; validation turns it into `恢復通知` while paused.
    static let pauseNotificationsTitle = "暫停通知 1 小時"
    static let resumeNotificationsTitle = "恢復通知"

    /// 顯示方式's rail destinations (M5 D21), in rail order.
    static let areaItemTitles = ["SESSIONS", "NOTES", "STATUS", "SETTINGS"]

    private static func viewMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        let areas: [Selector] = [#selector(CoddCommands.showSessionsArea(_:)), #selector(CoddCommands.showNotesArea(_:)),
                                 #selector(CoddCommands.showStatusArea(_:)), #selector(CoddCommands.showSettings(_:))]
        for (title, action) in zip(areaItemTitles, areas) { m.addItem(item(title, action, target: c)) }
        m.addItem(.separator())
        m.addItem(item("隱藏 / 顯示側欄", #selector(CoddCommands.toggleSessionSidebar(_:)), "\\", target: c))
        m.addItem(item("快速切換…", #selector(CoddCommands.showQuickSwitch(_:)), "k", target: c))
        m.addItem(item("篩選 session", #selector(CoddCommands.focusSidebarFilter(_:)), "f", [.command, .option], target: c))
        m.addItem(.separator())
        for zoom in zoomItems(c) { m.addItem(zoom) }
        return m
    }

    /// M4 interface zoom: 放大 ⌘+ (also ⌘= and ⌘⇧=, as hidden items that keep their key, so the
    /// unshifted key and either keypad + reach it whatever AppKit does with Shift), 縮小 ⌘− and
    /// 實際大小 ⌘0. Each step moves UI 字級 and 終端機字級 together (`AppDelegate.zoomIn`); terminals
    /// decline the chords (`CoddTerminalSetup.zoomChords`), so one press is one step.
    static func zoomItems(_ c: CoddCommands) -> [NSMenuItem] {
        let zoomIn = #selector(CoddCommands.zoomIn(_:))
        let larger = item("放大", zoomIn, "+", target: c)
        var items = [larger]
        for (key, modifiers) in [("=", NSEvent.ModifierFlags.command), ("+", [.command, .shift])] {
            let alternate = item("放大", zoomIn, key, modifiers, target: c)
            alternate.isHidden = true
            alternate.allowsKeyEquivalentWhenHidden = true
            items.append(alternate)
        }
        items.append(item("縮小", #selector(CoddCommands.zoomOut(_:)), "-", target: c))
        items.append(item("實際大小", #selector(CoddCommands.zoomToActualSize(_:)), "0", target: c))
        return items
    }

    private static func sessionMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        m.addItem(item("新增 session…", #selector(CoddCommands.newSession(_:)), "n", target: c))
        m.addItem(.separator())
        m.addItem(item("允許（回答 1）", #selector(CoddCommands.allowCurrentSession(_:)), "\r", target: c))
        m.addItem(item("新增終端機", #selector(CoddCommands.newShellTab(_:)), "t", target: c))
        m.addItem(item("下方終端機", #selector(CoddCommands.toggleBottomTerminal(_:)), "j", target: c))
        m.addItem(item("Composer", #selector(CoddCommands.toggleComposer(_:)), "l", target: c))
        m.addItem(.separator())
        m.addItem(item("釘選", #selector(CoddCommands.togglePinCurrentSession(_:)), "p", target: c))
        m.addItem(item("停止 session", #selector(CoddCommands.stopCurrentSession(_:)), ".", target: c))
        m.addItem(item(notesDrawerTitle, #selector(CoddCommands.toggleNotesDrawer(_:)), target: c))
        m.addItem(.separator())
        m.addItem(item("新增群組…", #selector(CoddCommands.newGroup(_:)), target: c))
        let accounts = NSMenuItem(title: accountsMenuTitle, action: nil, keyEquivalent: "")
        let accountsMenu = NSMenu(title: accountsMenuTitle)
        let filler = AccountsMenuFiller(commands: c)
        accountsFiller = filler
        accountsMenu.delegate = filler
        accounts.submenu = accountsMenu
        m.addItem(accounts)
        m.addItem(.separator())
        m.addItem(item("下一個 session", #selector(CoddCommands.selectNextSession(_:)), "\t", [.control], target: c))
        m.addItem(item("上一個 session", #selector(CoddCommands.selectPreviousSession(_:)), "\t", [.control, .shift], target: c))
        m.addItem(.separator())
        for n in 1...9 {
            let jump = item("Session \(n)", #selector(CoddCommands.selectSessionByNumber(_:)), "\(n)", target: c)
            jump.tag = n
            m.addItem(jump)
        }
        return m
    }

    /// D36: the notebook items validate by area (`AppDelegate.validateNotesMenuItem`), so ⌘F and
    /// ⌘E never act in the sessions area and ⌘⏎ / ⌘P / ⌘W stay with it. A disabled item still
    /// takes its key once no view claimed it (AppKit), so a view that wants ⌘E / ⌘F claims it in
    /// its own `performKeyEquivalent`. 標註模式 ⌘⇧A and 複製引用 ⌘⇧C (I1b) act only on NOTES with a
    /// saved note shown, so outside NOTES a terminal or the composer keeps those chords' meaning.
    private static func notesMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        // Upper-case letters: a real ⌘⇧N reports `N` (Shift is never ignored), so "n" + Shift never matches.
        m.addItem(item("快速筆記", #selector(CoddCommands.quickNote(_:)), "N", [.command, .shift], target: c))
        m.addItem(.separator())
        let modes: [Selector] = [#selector(CoddCommands.showNotebookMode(_:)), #selector(CoddCommands.showFilesMode(_:)),
                                 #selector(CoddCommands.showCleanupMode(_:))]
        for (title, action) in zip(notesModeTitles, modes) { m.addItem(item(title, action, target: c)) }
        m.addItem(.separator())
        m.addItem(item("原始碼", #selector(CoddCommands.toggleNoteSource(_:)), "e", target: c))
        m.addItem(item("標註模式", #selector(CoddCommands.annotateImage(_:)), "A", [.command, .shift], target: c))
        m.addItem(item("複製引用", #selector(CoddCommands.copyNoteReference(_:)), "C", [.command, .shift], target: c))
        m.addItem(item("搜尋筆記", #selector(CoddCommands.searchNotes(_:)), "f", target: c))
        return m
    }

    /// Session › 筆記抽屜 (the pane's `✎ NOTES` pill).
    static let notesDrawerTitle = "筆記抽屜"
    /// Session › 切換帳號 ▸.
    static let accountsMenuTitle = "切換帳號"
    /// 筆記 › the NOTES modes (M5 D21).
    static let notesModeTitles = ["筆記本", "檔案", "清理建議"]

    /// M5 D5: the onboarding wizard's reopen point (`NSApp.helpMenu`, so macOS adds its search field).
    static let onboardingItemTitle = "首次啟動設定…"

    private static func helpMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        m.addItem(item(onboardingItemTitle, #selector(CoddCommands.showOnboarding(_:)), target: c))
        return m
    }

    private static func windowMenu(_ c: CoddCommands) -> NSMenu {
        let m = NSMenu()
        m.addItem(item("關閉分頁或視窗", #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("縮放", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        // ⌘0 is 實際大小 since M4 (interface zoom); the main window moved to ⌥⌘0.
        m.addItem(item("CODD 主視窗", #selector(CoddCommands.showMainWindow(_:)), "0", [.command, .option], target: c))
        m.addItem(item("全部移到最上層", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }
}
