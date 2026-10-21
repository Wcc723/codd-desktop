import CoddPreferences
import CoddSettingsUI
import Foundation
import Observation

/// The global hotkey (D22): Settings › 一般 › 全域快捷鍵 registered exclusively through
/// CoddSettingsUI's `GlobalHotkey` (Carbon, no Accessibility permission), so a combo another app
/// holds is refused with `⌥ Space 已被其他 App 使用，請改用別的組合鍵` and the previous one stays.
///
/// Only the standard data root registers anything: a test or throwaway root never takes a
/// system-wide combo unless DEBUG `-codd-global-hotkey YES` says so (`-codd-hotkey <combo>` then
/// replaces the stored one for the run, so e2e runs use `ctrl+option+cmd+f12`, never ⌥Space).
@MainActor @Observable
final class HotkeyService {
    @ObservationIgnored let hotkey: GlobalHotkey
    /// This instance may register a global hotkey at all.
    let isAllowed: Bool
    /// DEBUG `-codd-hotkey`: registered instead of the stored combo (never saved).
    @ObservationIgnored let override: KeyCombo?
    /// The last refusal (the text under the row), nil after a success.
    private(set) var error: String?
    /// What is registered now.
    private(set) var registered: KeyCombo?
    /// The Settings recorder is listening (the registration is released so its combo can be pressed).
    private(set) var isSuspended = false
    /// What a press does (show / hide the main window).
    @ObservationIgnored var action: @MainActor () -> Void = {}
    @ObservationIgnored private var wanted: KeyCombo?
    @ObservationIgnored private let log: @MainActor (String) -> Void

    init(isAllowed: Bool, override: KeyCombo? = nil, hotkey: GlobalHotkey = GlobalHotkey(),
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.isAllowed = isAllowed
        self.override = override
        self.hotkey = hotkey
        self.log = log
    }

    static let testRootMessage = "測試資料根目錄不會註冊全域快捷鍵"

    /// The text under the row: the last refusal, or why this instance registers nothing.
    var statusText: String? { error ?? (isAllowed ? nil : Self.testRootMessage) }

    /// Whether this run may register: the standard data root, unless DEBUG `-codd-global-hotkey`
    /// decided (YES on any root, NO everywhere).
    static func isAllowed(standardRoot: Bool, debugFlag: Bool?) -> Bool { debugFlag ?? standardRoot }

    /// The combo the preferences ask for (nil: switched off).
    func wantedCombo(_ general: CoddPreferences.General) -> KeyCombo? {
        guard general.hotkey.enabled else { return nil }
        return override ?? KeyCombo(general.hotkey)
    }

    /// The preferences changed (also at launch): registers the wanted combo, or releases it.
    func apply(_ general: CoddPreferences.General) {
        wanted = wantedCombo(general)
        guard !isSuspended else { return }
        register(wanted)
    }

    private func register(_ combo: KeyCombo?) {
        guard isAllowed, let combo else {
            if hotkey.registered != nil { hotkey.unregister() }
            registered = nil
            if error != nil { error = nil }
            return
        }
        do {
            try hotkey.register(combo) { [weak self] in self?.action() }
            registered = combo
            if error != nil { error = nil }
            log("hotkey registered combo=\(combo.spec)")
        } catch let failure as GlobalHotkeyError {
            registered = hotkey.registered
            error = failure.message
            log("hotkey refused combo=\(combo.spec) (\(failure.message))")
        } catch {
            registered = hotkey.registered
            self.error = "無法註冊 \(combo)"
        }
    }

    /// The recorder started: the combo is free to be pressed again.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if hotkey.registered != nil { hotkey.unregister() }
        registered = nil
    }

    /// The recorder finished: whatever the preferences say now is registered again.
    func resume(_ general: CoddPreferences.General) {
        isSuspended = false
        apply(general)
    }

    /// Settings asks before storing a combo (recorder, `還原預設`): nil accepts it, else the refusal
    /// to show. Only an instance that registers tries it (exclusively); elsewhere every combo with
    /// a modifier is accepted and nothing is registered.
    func tryCombo(_ combo: KeyCombo) -> String? {
        guard combo.hasRequiredModifier else { return GlobalHotkeyError.needsModifier(combo).message }
        guard isAllowed else { return nil }
        // With an override the stored combo is not what runs: accept it without registering.
        guard override == nil else { return nil }
        do {
            try hotkey.register(combo) { [weak self] in self?.action() }
            registered = combo
            error = nil
            log("hotkey registered combo=\(combo.spec)")
            return nil
        } catch let failure as GlobalHotkeyError {
            log("hotkey refused combo=\(combo.spec) (\(failure.message))")
            return failure.message
        } catch {
            return "無法註冊 \(combo)"
        }
    }

    /// `hotkey {registered, combo, error, allowed}` (§6).
    var dumpObject: [String: Any] {
        ["registered": registered != nil, "combo": registered.map { $0.spec as Any } ?? NSNull(),
         "wanted": wanted.map { $0.spec as Any } ?? NSNull(), "error": error.map { $0 as Any } ?? NSNull(),
         "allowed": isAllowed, "suspended": isSuspended]
    }
}
