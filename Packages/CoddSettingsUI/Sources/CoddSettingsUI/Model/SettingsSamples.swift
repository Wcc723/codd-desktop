import AppKit
import CoddUI

/// The SPEC §5 sample as `SettingsInfo` (accounts `#2 藍鵲` / `#3 工作` / `#1 個人` in R7 order,
/// the five groups, the HOOKS state of the user's machine per M3 §1 / D10, three backups; M4: the
/// notes folder in the data root, MCP running on the hook port with 3 clients, Claude Code
/// registered, Codex not, Claude Desktop `FUTURE`, 15 cleanup candidates). Used by the demo, the
/// tests and the app's mock mode.
@MainActor
public enum SettingsSamples {
    public static func info(now: Date = Date()) -> SettingsInfo {
        let saved = Calendar.current.date(bySettingHour: 10, minute: 41, second: 0, of: now) ?? now
        return SettingsInfo(
            preferencesPath: "~/Library/Application Support/CODD/preferences.json",
            dataRootPath: "~/Library/Application Support/CODD",
            logPath: "~/Library/Logs/CODD/main.log",
            savedAt: saved,
            profileNames: [
                SettingsProfileName(id: "claude-default", title: "claude-default · claude"),
                SettingsProfileName(id: "claude-plan", title: "claude-plan · --permission-mode plan"),
                SettingsProfileName(id: "claude-rc", title: "claude-rc · --remote-control"),
                SettingsProfileName(id: "zsh", title: "zsh · shell"),
            ],
            defaultProfileID: "claude-default",
            groups: [
                SettingsGroup(id: "g-lab", name: "藍鵲 · 實驗室", color: NSColor(hex: 0xFF9B4E)),
                SettingsGroup(id: "g-web", name: "藍鵲 · 網站", color: NSColor(hex: 0x5B8DEF)),
                SettingsGroup(id: "g-github", name: "個人 · Github", color: NSColor(hex: 0x4EC9B0)),
                SettingsGroup(id: "g-codd", name: "CODD", color: NSColor(hex: 0xB07CFF)),
                SettingsGroup(id: "ungrouped", name: "未分類", color: nil),
            ],
            cswap: SettingsCswapInfo(pathOK: true, version: "0.26.0", versionOK: true),
            accounts: accounts,
            usageSources: [
                SettingsUsageSource(glyph: "●", accounts: "#3 工作", source: "statusline 的 rate_limits", age: "12s 前"),
                SettingsUsageSource(glyph: "○", accounts: "#2 藍鵲 · #1 個人", source: "cswap 快取", age: "3m 前"),
            ],
            hooks: hooks,
            cleanupPeriodDays: 30,
            rcCount: 1,
            rcTitles: ["修正登入 API 401"],
            versions: [
                SettingsVersion(key: "App", value: "1.0.0"),
                SettingsVersion(key: "macOS", value: "27.0"),
                SettingsVersion(key: "Claude Code", value: "2.1.302"),
                SettingsVersion(key: "cswap", value: "0.26.0"),
                SettingsVersion(key: "libghostty", value: "1.2.0"),
            ],
            appVersion: "1.0.0",
            externalSessionCount: 1,
            waitingCount: 3,
            cleanupCandidateCount: 15,
            notebook: notebook,
            condenseAccounts: condenseAccounts,
            canOpenCleanup: true
        )
    }

    /// SPEC §5: `● 127.0.0.1:47821 · 3 clients`; the notes live in `<dataRoot>/notes` (the
    /// artboards' `~/.codd/notebook` is design-time copy, M4 plan).
    public static let notebook = SettingsNotebookInfo(
        notesPath: "~/Library/Application Support/CODD/notes", mcpRunning: true, mcpClients: 3, port: 47821,
        tokenMasked: "••••••••••••",
        registrations: [
            SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: "已註冊 · user scope", isOn: true, actionTitle: "移除"),
            SettingsMCPRegistration(id: "codex", name: "Codex", hint: "未註冊", actionTitle: "註冊", accent: true),
            SettingsMCPRegistration(id: "claude-desktop", name: "Claude Desktop", hint: "未安裝", actionTitle: "安裝 .mcpb",
                                    actionEnabled: false, accent: true, chip: "FUTURE"),
        ],
        indexLine: "已重建 · 128 則 · 0.4 s")

    /// D32: 跟隨全域登入 first (the active `#3 工作`), then the accounts by number like the artboard.
    public static let condenseAccounts: [SettingsCondenseAccount] = [
        SettingsCondenseAccount(id: SettingsCondenseAccount.followID, title: "跟隨全域登入（#3 工作）"),
        SettingsCondenseAccount(id: "1", title: "#1 個人"),
        SettingsCondenseAccount(id: "2", title: "#2 藍鵲"),
        SettingsCondenseAccount(id: "3", title: "#3 工作"),
    ]

    /// R7 order: soonest weekly reset first; `#3` is the active one.
    public static let accounts: [SettingsAccountRow] = [
        SettingsAccountRow(id: "2", slot: "#2", alias: "藍鵲", plan: "MAX 20x", fiveHour: SettingsQuota(remaining: 98),
                           weekly: SettingsQuota(remaining: 46), resetIn: "1d12h後", resetAt: "10/16 週五 22:59",
                           sessions: "1 session 固定 · cswap run"),
        SettingsAccountRow(id: "3", slot: "#3", alias: "工作", plan: "MAX 20x", fiveHour: SettingsQuota(remaining: 91),
                           weekly: SettingsQuota(remaining: 15), resetIn: "3d01h後", resetAt: "10/18 週日 12:00",
                           sessions: "12 session", isActive: true),
        SettingsAccountRow(id: "1", slot: "#1", alias: "個人", plan: "MAX 20x", fiveHour: SettingsQuota(remaining: 100, tone: .muted, text: "未開始"),
                           weekly: SettingsQuota(remaining: 100), resetIn: "4d09h後", resetAt: "10/19 週一 20:00", sessions: "0 session"),
    ]

    /// D10 on the user's machine (M3 §1): hooks are injected per session, the CODD web status-line
    /// wrapper and `status-writer.js` handlers are still in `~/.claude/settings.json`.
    public static let hooks = SettingsHooksInfo(
        statusDir: "~/Github/codd-web/agent-sandbox/.claude/codd-status",
        statusDirDiffersFromDefault: true,
        components: [
            SettingsHooksComponent(id: "hooks", part: "Hooks", status: "● 14 / 14 · 每個 CODD session 自動注入", statusTone: .ok,
                                   hint: "CODD Desktop 不寫全域 hooks；每個 CODD session 啟動時注入全部 14 個事件。"),
            SettingsHooksComponent(id: "statusline", part: "Statusline", status: "◆ 需要更新", statusTone: .warn,
                                   hint: "目前是 CODD web 的 statusline（串接 hook-tap → statusline.sh）；更新後改由 CODD Desktop 串接，終端機上的顯示不變。",
                                   chip: "最近收到資料 8s 前",
                                   buttons: [SettingsHooksComponent.Button(title: "預覽變更", action: .previewChanges),
                                             SettingsHooksComponent.Button(title: "更新", action: .update, style: .primary)]),
            SettingsHooksComponent(id: "legacy", part: "Legacy", status: "◆ 偵測到 CODD web hooks", statusTone: .warn,
                                   hint: "10 個事件上有 status-writer.js；CODD Desktop 不需要它們。",
                                   buttons: [SettingsHooksComponent.Button(title: "只移除舊版", action: .removeLegacy)]),
        ],
        events: SettingsHooksInfo.eventNames.map { SettingsHookEvent(name: $0, installed: true) },
        foreignSummary: "外部 hooks 保持不動：hook-tap ×11 · osascript 通知 ×2",
        backups: [
            SettingsBackupRow(id: "settings.json.codd-bak-20261012-091503", name: "settings.json.codd-bak-20261012-091503",
                              hint: "10/12 09:15 · 安裝 statusline · 4.1 KB", label: "10/12"),
            SettingsBackupRow(id: "settings.json.codd-bak-20261003-183020", name: "settings.json.codd-bak-20261003-183020",
                              hint: "10/03 18:30 · 更新 hooks · 3.8 KB", label: "10/03"),
            SettingsBackupRow(id: "settings.json.codd-bak-20260921-140812", name: "settings.json.codd-bak-20260921-140812",
                              hint: "09/21 14:08 · 首次安裝 · 2.9 KB", label: "09/21"),
        ],
        navTail: "◆ 更新"
    )
}
