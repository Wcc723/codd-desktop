# CoddDialogsUI

The four dialogs of the StatusDialogs artboard (M3 C8, SPEC §7.7) as content views over value
models with closures, plus a presenter. Depends only on CoddUI.

| Dialog | View | Notes |
|---|---|---|
| A 切換帳號 | `SwitchAccountDialogView` (640 pt) | from / to mini cards, consequences, `同時暫停自動切換`, the D5 lock progress `◌ 等待 Claude Code credential lock… 9s（1/3）`, the redacted error line |
| B Hook 差異 | `HookDiffDialogView` (640 pt) | summary, event chips, `+n` / `−n`, the diff (`DiffLinesView`, foreign handlers elided), foreign tools kept, backup path, `[套用並備份]` (or `還原` for a restore) |
| C 加入帳號 | `AddAccountDialogView` (560 pt) | three steps, detect box (`偵測到 新帳號 · MAX 20x` / `已是 #2 藍鵲`), alias checked with cswap's rule (`DialogAliasRule`, D34), slot select, the D33 intro line |
| D 結束 | `QuitDialogView` (560 pt) | summary, NEEDS YOU rows, four stacked choices incl. D18's `結束 · session 繼續執行`, `下次直接保留在選單列` |

M4 (I2b) additions, both additive: `HookDiffModel` takes `dialogTitle`, `footerNote` and
`noChangesText` (defaults keep dialog B's hook texts), so the `~/.claude.json` MCP registration
reuses dialog B (`MCP 註冊 · 預覽變更`, `預覽 ~/.claude.json 變更`); `SnippetDialogView` (560 pt) shows a
text to copy into another tool's own config (`註冊到 Codex`: one line, the snippet in the code box,
`[關閉]` `[複製]`, `markCopied()` → `已複製`) and writes nothing itself.

⏎ triggers the primary button only when it is enabled and ⎋ cancels; both are left to the input
method while it has marked text. `update(_:)` changes only what changed and keeps what the user
typed or ticked. `DialogPresenter` shows A / B / D as sheets and C as a borderless child panel of
the main window (24 pt inside its right edge, 80 pt below the top, same level, never floating),
or standalone when no window is open. `DialogSamples` holds the SPEC §5 states for mock mode.

```sh
swift test --package-path Packages/CoddDialogsUI --scratch-path .build-dialogs
swift run  --package-path Packages/CoddDialogsUI --scratch-path .build-dialogs codd-dialogs-demo --fonts App/Fonts --snapshot <dir>
```

The presenter tests briefly order test windows front; `--skip PresenterTests` keeps a run fully
in the background. The app side is `App/Real/AccountDialogs.swift` (A, C), `App/Real/HookDiffDialog.swift`
(B), `App/Lifecycle/QuitDialogController.swift` (D) and `App/MCP/MCPRegistrationService.swift` /
`App/AppDelegate+Send.swift` (the M4 registration and the Codex snippet).

## Accessibility (M5 D21)

Dialogs are CoddUI controls, which follow `KeyboardFocus`; the text link of dialog C shows the
focus style for keyboard focus. `AccessibilityAuditTests` audits dialogs A–D in their sample states
and the snippet dialog.
