import AppKit
import CoddPreferences
import CoddUI

/// 01 GENERAL 一般: login item, Dock, keep in menu bar, 結束時 (D18), the global hotkey (D22),
/// the project root and the language (persisted, `M5`).
final class GeneralSectionView: SettingsSectionView {
    private(set) var recorder: HotkeyRecorderView?
    private(set) var projectRoot: SxTextInput?
    private var recorderError: String?
    private var hotkeyRow: SxRow?

    override func build() {
        let reset = button("還原本頁預設") { [weak self] in self?.resetPage() }
        add(pageHead(lead: SxRich("啟動、視窗與結束時的行為。所有變更立即生效。"), actions: [reset]))

        let login = row("general.launchAtLogin", "登入時啟動", en: "Launch at login", hint: "登入 macOS 後在背景啟動，只顯示選單列圖示 [■]。",
                        controls: [toggle("general.launchAtLogin", label: "登入時啟動", get: { $0.general.launchAtLogin },
                                          set: { $0.general.launchAtLogin = $1 })])
        bind { [weak login] _, info in login?.setNote("status", info.loginItemStatus) }
        let dock = row("general.showInDock", "顯示於 Dock", en: "Show in Dock", hint: "關閉後只留選單列圖示，⌘Tab 也不會出現。",
                       controls: [toggle("general.showInDock", label: "顯示於 Dock", get: { $0.general.showInDock },
                                         set: { $0.general.showInDock = $1 })])
        add(sxGroup(groupHead("Startup", cjk: "啟動"), [SxCard([login, dock])]))

        let keep = row("general.keepInMenuBarOnClose", "關閉視窗時保留在選單列", en: "Keep in menu bar",
                       hint: "⌘W 關閉視窗後，session 繼續在背景執行。",
                       controls: [toggle("general.keepInMenuBarOnClose", label: "關閉視窗時保留在選單列",
                                         get: { $0.general.keepInMenuBarOnClose }, set: { $0.general.keepInMenuBarOnClose = $1 })])
        let quitTitles = ["詢問", "全部停止", "保留"]
        let quit = row("general.quitBehavior", "結束時", en: "On quit", hint: "⌘Q 時還有 session 執行中，要怎麼處理。",
                       controls: [segmented("general.quitBehavior", titles: quitTitles,
                                            values: [CoddPreferences.QuitBehavior.ask, .stopAll, .keep], label: "結束時",
                                            get: { $0.general.quitBehavior }, set: { $0.general.quitBehavior = $1 })],
                       keywords: quitTitles)
        let recorder = hotkeyRecorder("general.hotkey", compact: false, kbdHeight: 24, accessibilityLabel: "修改全域快捷鍵") { [weak self] error in
            self?.recorderError = error
            self?.refreshHotkeyNote()
        }
        self.recorder = recorder
        let hotkey = row("general.hotkey", "全域快捷鍵", en: "Global hotkey", hint: "在任何 App 中叫出 CODD 視窗。", controls: [recorder],
                         keywords: ["⌥ Space", "hotkey"])
        hotkeyRow = hotkey
        bind { [weak self] _, _ in self?.refreshHotkeyNote() }
        add(sxGroup(groupHead("Window", cjk: "視窗"), [SxCard([keep, quit, hotkey])]))

        let root = SxTextInput(value: model.preferences.general.projectRoot, width: 240, accessibilityLabel: "預設專案根目錄")
        root.onCommit = { [weak self] typed in
            let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return .revert }
            self?.edit { $0.general.projectRoot = value }
            return .accept(value)
        }
        bind { [weak root] prefs, _ in root?.setValue(prefs.general.projectRoot) }
        registerControl("general.projectRoot", root)
        projectRoot = root
        let choose = button("選擇…", accessibilityLabel: "選擇預設專案根目錄") { [weak self] in self?.actions.chooseProjectRoot() }
        let project = row("general.projectRoot", "預設專案根目錄", en: "Project root", hint: "新增專案、選擇資料夾時從這裡開始。",
                          controls: [root, choose])
        let languages = CoddPreferences.Language.allCases
        let language = row("general.language", "語言", en: "Language", hint: "結構標籤（SESSIONS、NEEDS YOU…）維持英文大寫。",
                           controls: [select("general.language", titles: languages.map(OptionLabels.language), values: languages,
                                             width: 180, label: "語言", get: { $0.general.language }, set: { $0.general.language = $1 })],
                           milestone: "M5", keywords: languages.map(OptionLabels.language))
        add(sxGroup(groupHead("Defaults", cjk: "預設"), [SxCard([project, language])]))
    }

    /// The refusal under the hotkey row: the app's (registration at launch) or the recorder's.
    private func refreshHotkeyNote() {
        hotkeyRow?.setNote("error", model.info.hotkeyError ?? recorderError, color: Palette.danger)
    }

    var hotkeyNote: String? { hotkeyRow?.note("error") }

    /// `還原本頁預設`: GENERAL's defaults in one change; the default ⌥ Space goes through
    /// `tryHotkey` like a recorded combo (a refusal keeps the current one).
    func resetPage() {
        let defaultCombo = KeyCombo(CoddPreferences.defaults.general.hotkey)
        var keepHotkey = false
        if KeyCombo(model.preferences.general.hotkey) != defaultCombo, let refusal = actions.tryHotkey(defaultCombo) {
            keepHotkey = true
            recorderError = refusal
        } else {
            recorderError = nil
        }
        model.resetSection(.general, keepHotkey: keepHotkey)
        actions.resetSection(.general)
        refreshHotkeyNote()
    }
}
