import AppKit
import CoddOnboarding

/// What the wizard asks the App to do. Every closure defaults to doing nothing and runs on the main
/// actor. The view never changes the flow itself (the App moves it and calls `update(_:)`); step 2's
/// selection is the exception: the view applies a check, filter, group, page or hidden change at
/// once (so typing and clicking feel immediate) and reports the result through `importChanged`.
/// `suggestGroups` and `newGroup` say what the operator asked for (logs, `onboarding action=…`) and
/// come right before the `importChanged` that carries their result.
@MainActor
public struct OnboardingActions {
    /// The primary button (`下一步：… →`; ⏎). On step 6 it is `finish` instead.
    public var next: @MainActor () -> Void
    /// `略過` (on step 6: finish without asking for notifications).
    public var skip: @MainActor () -> Void
    /// `← 上一步` (⌘[).
    public var back: @MainActor () -> Void
    /// `↻ 重新偵測`.
    public var redetect: @MainActor () -> Void
    /// D12 `已在用 CODD Web？匯入它的設定 →` (jump to step 3).
    public var importWeb: @MainActor () -> Void
    /// `依父資料夾建議分組`.
    public var suggestGroups: @MainActor () -> Void
    /// Step 3 `預覽變更` (dialog B).
    public var previewHooks: @MainActor () -> Void
    /// Step 4 `在 Finder 中顯示`.
    public var revealNotes: @MainActor () -> Void
    /// Step 4 `註冊…` (the M4 registration dialog).
    public var registerClaudeCode: @MainActor () -> Void
    /// Step 4 `複製設定…` (the M4 Codex snippet sheet).
    public var copyCodexSnippet: @MainActor () -> Void
    /// Step 5 `+ 加入帳號` (dialog C, D13).
    public var addAccount: @MainActor () -> Void
    /// Step 6 `允許通知`.
    public var requestNotifications: @MainActor () -> Void
    /// Step 6 `開始使用 →`.
    public var finish: @MainActor () -> Void
    /// A done or skipped step in the stepper, or a `第 n 步 →` button of step 1.
    public var goTo: @MainActor (OnboardingStep) -> Void
    /// Step 2's selection after a change the view made (see the type's note).
    public var importChanged: @MainActor (ImportSelection) -> Void
    /// `+ 新群組…` named for a row (`path`, `name`).
    public var newGroup: @MainActor (_ path: String, _ name: String) -> Void
    /// FB: step 5's cswap guide `複製` (the command as shown).
    public var copyCommand: @MainActor (String) -> Void
    /// FB: step 5's cswap guide `在終端機執行`: a terminal with the command typed, not run. (Its
    /// `↻ 重新偵測` is `redetect`.)
    public var runInTerminal: @MainActor (String) -> Void

    public init(next: @escaping @MainActor () -> Void = {}, skip: @escaping @MainActor () -> Void = {},
                back: @escaping @MainActor () -> Void = {}, redetect: @escaping @MainActor () -> Void = {},
                importWeb: @escaping @MainActor () -> Void = {}, suggestGroups: @escaping @MainActor () -> Void = {},
                previewHooks: @escaping @MainActor () -> Void = {}, revealNotes: @escaping @MainActor () -> Void = {},
                registerClaudeCode: @escaping @MainActor () -> Void = {}, copyCodexSnippet: @escaping @MainActor () -> Void = {},
                addAccount: @escaping @MainActor () -> Void = {}, requestNotifications: @escaping @MainActor () -> Void = {},
                finish: @escaping @MainActor () -> Void = {}, goTo: @escaping @MainActor (OnboardingStep) -> Void = { _ in },
                importChanged: @escaping @MainActor (ImportSelection) -> Void = { _ in },
                newGroup: @escaping @MainActor (_ path: String, _ name: String) -> Void = { _, _ in },
                copyCommand: @escaping @MainActor (String) -> Void = { _ in },
                runInTerminal: @escaping @MainActor (String) -> Void = { _ in }) {
        self.next = next
        self.skip = skip
        self.back = back
        self.redetect = redetect
        self.importWeb = importWeb
        self.suggestGroups = suggestGroups
        self.previewHooks = previewHooks
        self.revealNotes = revealNotes
        self.registerClaudeCode = registerClaudeCode
        self.copyCodexSnippet = copyCodexSnippet
        self.addAccount = addAccount
        self.requestNotifications = requestNotifications
        self.finish = finish
        self.goTo = goTo
        self.importChanged = importChanged
        self.newGroup = newGroup
        self.copyCommand = copyCommand
        self.runInTerminal = runInTerminal
    }
}
