import Foundation

/// The 13 sections of the Settings artboard, in nav order (`01`–`13`).
public enum SettingsSection: String, CaseIterable, Sendable {
    case general, appearance, sessions, profiles, notifications, accounts, hooks, notebook, cleanup, shortcuts, remote, advanced, about

    /// 1-based position in the nav.
    public var index: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The nav number (`01`).
    public var number: String { index < 10 ? "0\(index)" : "\(index)" }

    /// Nav label (`.sx-zh`): `一般`, `Hooks & Status`, `筆記本 & MCP`.
    public var navTitle: String {
        switch self {
        case .general: "一般"
        case .appearance: "外觀"
        case .sessions: "工作階段"
        case .profiles: "啟動設定檔"
        case .notifications: "通知"
        case .accounts: "帳號"
        case .hooks: "Hooks & Status"
        case .notebook: "筆記本 & MCP"
        case .cleanup: "清理"
        case .shortcuts: "快捷鍵"
        case .remote: "遠端"
        case .advanced: "進階"
        case .about: "關於"
        }
    }

    /// Nav English label (`.sx-en`, drawn in caps); empty for HOOKS (its zh label is English).
    public var navEnglish: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .sessions: "Sessions"
        case .profiles: "Profiles"
        case .notifications: "Notifications"
        case .accounts: "Accounts"
        case .hooks: ""
        case .notebook: "Notebook"
        case .cleanup: "Cleanup"
        case .shortcuts: "Shortcuts"
        case .remote: "Remote"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// The nav group that starts at this item (`App`, `Workflow`, `Integrations`, `System`).
    public var navGroupHead: String? {
        switch self {
        case .general: "App"
        case .sessions: "Workflow"
        case .accounts: "Integrations"
        case .cleanup: "System"
        default: nil
        }
    }

    /// The page title (`.h-page`).
    public var pageTitle: String {
        switch self {
        case .hooks: "HOOKS & STATUS"
        case .notebook: "NOTEBOOK & MCP"
        default: rawValue.uppercased()
        }
    }

    /// The page's CJK name next to the title (`.sx-ph .zh`).
    public var pageZh: String {
        switch self {
        case .hooks: "Hook 與狀態列"
        case .notebook: "筆記本"
        default: navTitle
        }
    }
}
