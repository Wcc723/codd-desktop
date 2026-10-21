# CoddSettingsUI

Every section of the Settings artboard (M3 C7, SPEC §7.12), bound to `CoddPreferences`, plus the
global hotkey pieces. Depends on CoddUI and CoddPreferences; links Carbon for the hotkey.

- `SettingsModel` (`@MainActor @Observable`): `preferences`, `info` (`SettingsInfo`: the facts the
  page shows but does not own, built by the app: accounts, auto-switch preview, hooks components and
  backups, versions, login item status, hotkey error, …), `update(_:)` (one `onChange` per real
  change), `resetSection(_:)`.
- `SettingsRootView(model:actions:profilesView:)`: sidebar with search (case-, width- and
  diacritic-folded; Enter jumps to the first match), 13 sections, footer with the saved path. The
  M2 `ProfilesSettingsView` is injected as section 04. Rows of later milestones are drawn disabled
  with an `M5` / `FUTURE` chip (D17); locked rows explain why.
- `SettingsActions`: every button as a closure (`tryHotkey` returns nil or the refusal text,
  `setAlias`, `restoreBackup`, `rereadAccounts`, `resetAll`, …; M4: `openNotesFolder`,
  `rotateMCPToken`, `mcpRegistration(id)`, `rebuildNotesIndex`, `openCleanup`; M5: `openOnboarding`,
  the 13 關於 row 首次啟動設定 `[重新執行]`; `openThirdPartyNotices`, 關於 › Legal's 第三方元件授權
  `[開啟]`, above the line that CODD is unofficial and not Anthropic's). Every closure and
  every new `SettingsInfo` member has a default, so M3 call sites compile unchanged (D40).
- M4 (D30, D33): 08 筆記本 & MCP, 09 清理 and 12 進階 are live. `SettingsInfo.notebook`
  (`SettingsNotebookInfo`: notes path, MCP running / clients, the hook port shown read-only, the
  masked token, the 註冊 rows as `SettingsMCPRegistration`, the index line, `rebuilding`, and
  `canOpenFolder` / `canRotateToken` / `canRebuildIndex`) defaults to `.unavailable` (`—` values,
  `○ 未執行`, buttons disabled). 位置 offers only LOCAL; `iCloud Drive` / `自訂…` are disabled
  segments with an `M5` chip (`SxSegmented.segmentChips`). `SettingsInfo.condenseAccounts`
  (`SettingsCondenseAccount`, ids `follow` / `<n>`) fills 交給 Claude 濃縮's account select, which
  stores the id in `cleanup.condenseAccount` (nil shows the first entry; empty list: `—`,
  disabled). `SettingsInfo.canOpenCleanup` (default false) enables `查看清理建議 · n →`.
  ADVANCED › 終端機紀錄保留 edits `cleanup.scrollbackDeleteDays` (the engine's value) with the
  artboard's three options; `永不` chosen in 清理 shows as its title, not as a fourth option.
- Hotkey: `KeyCombo` (spec strings like `ctrl+option+cmd+f12`, `⌃⌥⌘ F12` display, Codable),
  `HotkeyRecorderView` (needs one of ⌘ ⌥ ⌃, ⎋ cancels), `GlobalHotkey` (Carbon
  `RegisterEventHotKey` with `kEventHotKeyExclusive`, so a combo another app holds is refused with
  `<combo> 已被其他 App 使用，請改用別的組合鍵`).
- `AliasRule` is cswap 0.26's `normalize_alias`, kept identical to CoddCore's `CswapAlias` (D34).

```sh
swift test --package-path Packages/CoddSettingsUI --scratch-path .build-settingsui
swift run  --package-path Packages/CoddSettingsUI --scratch-path .build-settingsui codd-settings-demo --fonts App/Fonts --snapshot <dir>
```

The snapshot run renders offscreen (no window is ordered in); it adds the M4 states
`state-08/09/12-*-neutral.png` (an M3 caller), `state-08-notebook-stopped.png`,
`state-09-cleanup-account-1*.png` (the artboard's `#1 個人`) and
`state-12-advanced-never-rebuilding.png`.

Tests register only `ctrl+option+cmd+f12`, never ⌥Space. The app side is
`App/Settings/SettingsCoordinator.swift` and `SettingsInfoBuilder.swift`.

## Accessibility (M5 D21)

The custom controls (`SxSegmented`, `SxCheckbox`, `SxStepper`, `SxLinkButton`, `GroupChipView`,
the nav items) derive from `SxKeyView`: key views while Full Keyboard Access is on (CoddUI's
`KeyboardFocus`), the focus style for keyboard focus only, space / ⏎ press, arrows step a segmented
control or a stepper; ↑ ↓ on a nav item select the neighbouring shown section and keep the focus
in the nav. `SxSegmented` exposes one radio button per segment. `AccessibilityAuditTests` audits the
sidebar and all 13 sections.
