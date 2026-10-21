import AppKit

/// FB 「引導安裝 cswap」 in 設定 › 帳號: how to get cswap (the PyPI package `claude-swap`,
/// github.com/realiti4/claude-swap) when it is missing, or update it when it is older than 0.26.
/// STATUS and onboarding step 5 show the same commands (the App's tests compare them).
public struct SettingsCswapGuide: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case install
        case upgrade
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    /// The guide the cswap facts call for: install when the executable is missing, upgrade when its
    /// version is known and too old, none otherwise, and none while CODD is still looking for it
    /// (STATUS shows its loading line then, never a guide).
    public static func make(_ cswap: SettingsCswapInfo) -> SettingsCswapGuide? {
        if cswap.locating { return nil }
        if !cswap.pathOK { return SettingsCswapGuide(kind: .install) }
        if cswap.version != nil, !cswap.versionOK { return SettingsCswapGuide(kind: .upgrade) }
        return nil
    }

    public static let installCommand = "uv tool install claude-swap"
    public static let upgradeCommand = "uv tool upgrade claude-swap"
    public static let uvCommands = ["brew install uv", "curl -LsSf https://astral.sh/uv/install.sh | sh"]
    public static let projectURL = "https://github.com/realiti4/claude-swap"

    public var lead: String {
        switch kind {
        case .install: "cswap（PyPI 套件 claude-swap）負責切換帳號與讀取用量快取。用 uv 安裝："
        case .upgrade: "這個 cswap 太舊，CODD 需要 0.26 以上。用 uv 更新（用 pipx 裝的改用 pipx upgrade claude-swap）："
        }
    }
    /// The command `在終端機執行` types (not run).
    public var command: String { kind == .install ? Self.installCommand : Self.upgradeCommand }
    public var uvCommands: [String] { kind == .install ? Self.uvCommands : [] }
    public var commands: [String] { [command] + uvCommands }
    public static let uvHint = "還沒有 uv？先用其中一行安裝："
    public static let note = "在終端機執行 只會打好指令，按 Return 才會執行 · 裝好後按 重新偵測，再用 + 加入帳號 登入各個帳號"
}

/// FB 「自動切換帳號加上警語」: the amber line under 剩餘不足時自動切換 and the confirmation asked
/// each time it is turned ON.
@MainActor
public enum SettingsAutoSwitchRisk {
    public static let warning = "Claude 官方不建議用多個帳號自動輪替來延長用量，可能違反 Anthropic 的使用條款；開啟前請自行評估風險。"
    public static let title = "開啟自動切換帳號？"
    public static let confirmTitle = "仍要開啟"
    public static let cancelTitle = "取消"

    /// An alert sheet over `window` (application-modal without one); `done(true)` on 仍要開啟.
    public static func ask(on window: NSWindow?, done: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        guard let window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { done(response == .alertFirstButtonReturn) }
        }
    }
}
