import Foundation

/// Launch options. Real mode (`HolderSessionStore`: real `codd-holder` processes, claude sessions
/// with hooks, libghostty terminals) is the default in Debug and Release; the mock store with the
/// SPEC §5 data is used only with `-codd-mock` (screenshots, self tests).
///
/// Every build:
/// - `-codd-mock` (optionally `YES` / `NO`): mock data instead of real sessions. The DEBUG tools
///   `-CODDSelfTest`, `-CODDSnapshotDir` and `-CODDMetrics` imply it unless `-codd-real-holders` is
///   given too, so they never touch the real data root.
/// - `-codd-real-holders` (optionally `YES` / `NO`): real mode, explicitly (the M0 / 4a spelling).
/// - `-codd-data-root <dir>` or `CODD_DATA_ROOT`: data root instead of
///   `~/Library/Application Support/CODD`. Keep it short: socket paths must stay under 104 bytes.
/// - `-codd-background [YES|NO]` or `CODD_BACKGROUND=1|0`: never activate, no Dock icon, windows
///   behind every other app's windows (`AppActivation`, `BackgroundWindows`). DEBUG builds default to it when launched from a
///   Claude Code shell or with `-codd-data-root` / `CODD_DATA_ROOT`, so automated runs never take
///   the user's keyboard focus; `-codd-background NO` brings the old behaviour back.
/// - `-codd-claude-dir <dir>` or `CODD_CLAUDE_DIR`: the Claude config directory CODD reads (the
///   registry `<dir>/sessions`, the transcripts `<dir>/projects`, and `<dir>/../.claude.json` for
///   recent projects) instead of `~/.claude`. It does not change what the started claude uses.
///
/// DEBUG builds only (Release ignores them):
/// - A real-mode run from a Claude Code shell needs a data root (`standardRootRefusal`; exit 64),
///   unless `CODD_ALLOW_STANDARD_ROOT=1`.
/// - `-codd-spawn-shell <cwd>`: start one shell session right after launch (`YES` = home folder).
/// - `-codd-new-claude <cwd>`: start one claude session there right after launch.
/// - `-codd-claude-path <file>`: run this executable instead of the `claude` found on the login
///   PATH (tests use a fake claude script; never the real one).
/// - `-codd-shell-argv "<argv>"`: child argv for new shell sessions instead of `$SHELL -l`, split
///   on spaces (smoke runs use it so the user's rc files are never read).
/// - `-codd-quit-after <seconds>`: quit through `NSApp.terminate` after that delay (smoke runs).
/// - `-codd-snapshot <file.png>`: with `-codd-quit-after`, render the main window to a PNG just
///   before quitting (works with a locked screen; same renderer as `-CODDSnapshotDir`).
/// - `-codd-dump-terminal <file>`: with `-codd-quit-after`, write the viewport text of the visible
///   terminals (tab strip and ⌘J panel) to the file just before quitting.
/// - `-codd-dump-state <file>`: write the sessions' states, the hook endpoint status and the
///   attention count as JSON whenever they change, and at quit (e2e runs poll it).
/// - `-codd-auto-answer <key>`: when the shown claude session starts WAITING, press that answer-bar
///   key (`1`…`9`, `esc`) once, through the same path as a click.
/// - `-codd-resume-stopped YES`: RESUME every STOPPED claude session after launch.
/// - `-codd-send-input "<text>"` / `-codd-send-panel-input "<text>"`: once the shown session's
///   terminal (or its panel) streams, type the text plus Return through the holder stream.
/// - `-codd-open-zsh-tab YES`: open a new terminal in the shown session's bottom panel, as ⌘T.
/// - `-codd-open-panel YES`: open the ⌘J panel of the shown session.
/// - `-codd-spawn-count <n>`: with `-codd-spawn-shell`, start that many shells (measurements).
/// - `-codd-login-env NO`: do not capture the login-shell environment (sessions get defaults).
/// - `-codd-notifications NO`: never post (or ask permission for) user notifications.
/// - `-codd-show <status|home|new-session|settings-profiles>`: open the STATUS page, Home, the ⌘N
///   sheet or Settings › 啟動設定檔 after launch (with `-codd-snapshot`, an open sheet is written
///   next to the window as `<name>-sheet.png`, its open project list as `<name>-dropdown.png`, the
///   settings window as `<name>-settings.png` and its editor as `<name>-settings-sheet.png`).
///   `new-session` and `settings-profiles` also work with `-codd-mock` (SPEC §5 data).
/// - `-codd-unreachable-after <seconds>`: a live holder that does not answer for this long is
///   UNREACHABLE (default 5 s).
/// - `-codd-keepalive <idleMs>,<timeoutMs>`: PING after `idleMs` without a byte from a holder, close
///   after `timeoutMs` more (defaults 10000,30000), for every holder connection (shell tabs too).
/// - `-codd-close-main-window YES`: close the main window right after launch (lifecycle checks).
/// - `-codd-select-session <id>`: show that session once the sessions are discovered (an external
///   `ext-…` id is waited for up to 3 s: it comes with the first registry snapshot).
/// - `-codd-new-profile <id>`: with `-codd-new-claude`, start it with that launch profile.
/// - `-codd-resume-transcript <claude session id>`: with `-codd-new-claude`, resume that
///   conversation (`claude --resume <id>`) instead of starting a new one.
/// - `-codd-stale-after <seconds>`: IDLE sessions turn stale after this long (default: Settings ›
///   工作階段 › STALE 判定, 3600); the stale recheck then runs every min(60, that) seconds. It wins
///   over the preference for the run.
/// - `-codd-set-pref <path>=<value>` (repeatable): sets a preference for this run after
///   `preferences.json` is read (`sessions.staleAfterSeconds=1800`, `notifications.waiting.notify=NO`;
///   paths and values as `CoddPreferences.value(atPath:)` / `set(_:atPath:)`). It is not written to
///   the file unless a later edit changes that value; a refused assignment is logged
///   (`preferences set-pref … refused …`) and listed in the state dump (`preferences.setPrefs`).
/// - `-codd-trash-dir <dir>`: 刪除對話紀錄 moves the transcript files into this folder instead of
///   the Trash (D23; automated runs never touch `~/.Trash`).
/// - `-codd-delete-history <session id>`: run 刪除對話紀錄 for that session after launch, without
///   the alert (with `-codd-trash-dir`).
/// - `-codd-list-transcripts <cwd>`: list that folder's transcripts twice after launch and log the
///   cold and cached timings (`transcripts cwd=… count=… ms=… cache=miss|hit`).
/// - `-codd-sidebar-mode tree|state`: the sidebar's TREE | STATE toggle at launch (also with `-codd-mock`).
/// - `-codd-sidebar-filter "<text>"`: the sidebar filter at launch (also with `-codd-mock`).
/// - `-codd-hover-card <session id>|current`: show that row's hover card once the sessions are in
///   (with `-codd-snapshot` it is drawn into the PNG over the main pane).
/// - `-codd-new-group "<name>"`: open the inline new-group editor with that name typed and its color
///   popover up (`-codd-snapshot` draws the popover too).
/// - `-codd-group-hover <group id>`: draw that group header in its hover state (snapshots).
/// - `-codd-drag-preview <project id>,<group id>`: draw a project drag over that group (ghost, `移入`,
///   the amber drop line) without a mouse (snapshots; nothing moves).
/// - `-codd-sidebar-drag-test YES` (M4): drive every kind of sidebar drag (sessions, projects within /
///   between groups and 未分類, groups, folders from Finder) through the real drop path with
///   synthetic dragging infos (no posted events); logs `DRAGTEST …` and `DRAGTESTS ok=n fail=m`. It
///   changes the layout: test data roots only (needs `-codd-data-root`).
/// - `-codd-drop-folders <path>` (repeatable), `-codd-drop-folders-group <id | name | ungrouped>`,
///   `-codd-drop-folders-index <n>` (M4): drop those folders on the sidebar as Finder would (on the
///   group's head, or before its n-th project; without a group, below the groups). Paths inside the
///   real `~/.claude*` or CODD data root are refused.
/// - `-codd-shortcut-matrix YES`: press ⌘1 ⌘2 ⌘9 ⌃Tab ⌘\ ⌘⏎ ⌘T ⌘J ⌘P ⌘. ⌘L ⌘K with the terminal, the
///   sidebar, the filter field and the composer (also while 注音 composes) focused, then ⌘⏎ esc ⌘K in
///   the ⌘K palette; logs `SHORTCUT …` lines and a summary (needs a shown session).
/// - `-codd-palette-query "<q>"`: open ⌘K with that query typed once the sessions are in (also with
///   `-codd-mock`; `-codd-snapshot` draws the palette).
/// - `-codd-composer-open YES`: open the shown session's composer after launch.
/// - `-codd-composer-send "<text>"` (repeatable): once the shown terminal streams, send the text
///   through the composer as if typed there and Entered (`\n`, `\t`, `\\` decoded).
/// - `-codd-panel-tabs <n>`: with `-codd-open-panel`, add panel tabs until the panel has n (1–8);
///   the last one is shown (and gets `-codd-send-panel-input`). Also with `-codd-mock`.
/// - `-codd-maximize-panel YES`: with `-codd-open-panel`, maximize the panel (also with `-codd-mock`).
/// - `-codd-panel-select <n>`: after the panel input was sent, show the n-th panel tab (1-based),
///   so a tab running a job is drawn unselected, as in the Split artboard.
/// - `-codd-new-session-path <cwd>`: with `-codd-show new-session`, the sheet's folder.
/// - `-codd-new-session-start new|resume|rc`: with `-codd-show new-session`, the sheet's start
///   (`resume` lists that folder's transcripts in the picker).
/// - `-codd-new-session-kind claude|shell`: with `-codd-show new-session`, the sheet's kind.
/// - `-codd-open-project-dropdown YES`: with `-codd-show new-session`, open the project list.
/// - `-codd-new-session-advanced YES`: with `-codd-show new-session`, open `▸ 進階 Advanced`.
/// - `-codd-edit-profile <id>|new`: with `-codd-show settings-profiles`, open the profile editor.
/// - `-codd-new-session-create YES`: with `-codd-show new-session`, press 建立 ⌘⏎ once the picker
///   has loaded (e2e: a resume from the picker reaches the fake claude as `--resume <id>`).
///
/// M3 (accounts, quota, status line; docs/M3-PLAN.md §6):
/// - `-codd-cswap-path <file>`: the cswap executable (tests use `scripts/m3-fixtures/fake-cswap.py`).
///   On any data root but the standard one this is the only way CODD gets a cswap (D3).
/// - `-codd-cswap-root <dir>`: cswap's state root instead of `~/.claude-swap-backup` (D3; a fake
///   state from `scripts/m3-fixtures/make-cswap-state.sh`).
/// - `-codd-claude-settings <file>`: the Claude user settings the status-line chain is read from
///   (D35) instead of `<claudeDir>/settings.json`. Read only.
/// - `-codd-switch-account <n>`: after the first account read, switch to account n through the same
///   path as a click on the sidebar footer row (toast included).
/// - `-codd-undo-switch YES`: with `-codd-switch-account`, press the toast's UNDO once the switch
///   succeeded.
/// - `-codd-new-claude-account <n>`: with `-codd-new-claude`, pin the new session to account n
///   through the same path as the ⌘N account select (D12).
/// - `-codd-refresh-accounts YES`: one explicit `↻ 立即更新` after the first account read (the D1
///   `cswap list` fallback runs when cswap's state files are unusable).
///
/// M3 I2 (STATUS, installer, dialogs, auto-switch):
/// - `-codd-show status|dialog-switch|dialog-hooks|dialog-add`: the STATUS area, or dialog A (a switch
///   to the first switchable account, not run), B (the `update` plan) or C (step 1) after launch; with
///   `-codd-snapshot` a sheet is written as `<name>-sheet.png`, the add-account panel as
///   `<name>-panel.png`. Also with `-codd-mock` (SPEC §5 data through the same code).
/// - `-codd-status-section host|accounts|hooks|mcp|remote`: with `-codd-show status`, scroll the page
///   to that section (snapshots of the lower sections).
/// - `-codd-status-details YES`: with `-codd-show status`, open the HOOKS card's `▸ 詳細`.
/// - `-codd-auto-switch-tick <s>`: auto-switch evaluates every s seconds (default 30) while ON.
/// - `-codd-hooks-plan update|remove-legacy|uninstall|disable-notifications`: build that installer
///   plan after launch (the dump's `installer.plan`); nothing is written.
/// - `-codd-hooks-apply YES`: apply that plan without the dialog, but only when `-codd-claude-dir` or
///   `-codd-claude-settings` was given and the target, symlinks resolved, is not inside the real
///   `~/.claude` (else `installer apply refused` is logged and nothing is read or written: the guard
///   runs before the plan reads the file).
/// - `-codd-hooks-apply-delay <ms>`: with `-codd-hooks-apply`, wait this long between the plan and
///   the write (`debug hooks-apply waiting ms=…`), so the e2e can change the file meanwhile and see
///   the write refused (`changedSinceRead`).
/// - `-codd-add-account <alias>`: dialog C's three steps without clicks (the ephemeral shell types
///   `<claude> /login`, the login change is awaited ≤ 15 s, the next free slot, `cswap add`, the
///   switch back, the shell discarded).
///
/// M3 I3 (Settings, lifecycle, hotkey):
/// - `-codd-show settings-<section>`: the Settings window on that section after launch (`general`,
///   `appearance`, `sessions`, `profiles`, `notifications`, `accounts`, `hooks`, `notebook`,
///   `cleanup`, `shortcuts`, `remote`, `advanced`, `about`); with `-codd-snapshot` it is written as
///   `<name>-settings.png`. `-codd-show dialog-quit`: dialog D as ⌘Q would show it. Both also with
///   `-codd-mock`.
/// - `-codd-quit-request <s>`: calls the ⌘Q command after s seconds (dialog D may show; unlike
///   `-codd-quit-after`, which never asks).
/// - `-codd-quit-choice stop-all|keep-running|menubar|cancel`: answers dialog D once it shows.
/// - `-codd-global-hotkey YES|NO`: register the global hotkey on any data root (YES) or nowhere
///   (NO); without it only the standard data root registers (D22).
/// - `-codd-hotkey <combo>`: register this combo instead of the stored one (`ctrl+option+cmd+f12`;
///   never saved). Automated runs never use ⌥Space.
///
/// M4 I1a (notebook core; docs/M4-PLAN.md §6):
/// - `-codd-show notebook|note:<id>`: the NOTES area's Notebook (with that note selected). Only the
///   keyword before the first `:` is case-insensitive; the rest (ids, paths, asset names) is kept
///   exactly as given (every `-codd-show` value).
/// - `-codd-notes-select <id>`: select that note once the notebook is open.
/// - `-codd-notes-new "<title>"`: a new NOTE draft titled so (D3: nothing on disk until typed).
/// - `-codd-quick-note YES`: the D13 quick note path (the menu bar's QUICK NOTE).
/// - `-codd-notes-type "<text>"`: typed into the shown note editor through `insertText` (`\n`,
///   `\t`, `\\` decoded), as if from the keyboard.
/// - `-codd-notes-paste-image <png>`: the editor's image paste path with that file (D9); refused
///   for a path inside the real home's `.claude*`, `.codex`, `.claude-swap-backup` or
///   `Library/Application Support/CODD` (lexical and resolved).
/// - `-codd-notes-search "<query>"`: typed into the Notebook search (the dump's `notes.search`).
/// - `-codd-notes-rebuild YES`: rebuild the notes index after it opened.
/// - `-codd-now <ISO8601>`: the notes' clock starts at that instant (lists, retention, digest).
///
/// M4 I1b (notebook features):
/// - `-codd-show annotate:<id>:<asset>`: ImageAnnotate for that note's image (`9f3a1c.png` or the
///   path as written in the note). With `-codd-mock` item 1 is selected (the artboard's state).
/// - `-codd-notes-annotate <id>:<asset>:<json file>`: the ImageAnnotate `完成` path with the §3.3
///   block JSON of that file (refused inside the real home's protected folders, like a paste).
/// - `-codd-notes-set <id>:<key>=<value>` (repeatable): `ai=off|read|append`,
///   `scope=global|<project path>`, `kind=note|prompt|scratch`, `pinned=yes|no`, `tags=a,b`.
/// - `-codd-notes-archive <id>` / `-codd-notes-trash <id>`: the ⋯ menu's 封存 / 移到垃圾桶.
/// - `-codd-notes-copy-ref <id>:<1…5>`: the COPY REF form's text into the dump's `notes.copyRef`
///   (the URL token masked); never a pasteboard.
/// - `-codd-notes-menu copy-ref|ai|scope|send|more`: that chrome menu drawn open in place (snapshots).
///
/// M4 I3 (file editor):
/// - `-codd-show files:<path>`: the NOTES area's Files mode at that folder, or with that file open
///   (mock mode: a path relative to the mock projects folder, e.g.
///   `orb-toolkit-frontend/src/pages/punch.vue`, draws the FileEditor artboard).
/// - `-codd-open-file <path>`: that file in a pinned tab (the Files mode at its folder, or at the
///   workspace that holds it). Refused inside the real home's protected folders (like a paste).
/// - `-codd-file-type "<text>"`: typed into the shown code view through `insertText` (escapes as
///   `-codd-notes-type`).
/// - `-codd-file-show-ai-changes YES|NO`, `-codd-file-baseline head|saved|ai`,
///   `-codd-file-hunk <index>:revert|accept`, `-codd-file-save YES` (the ⌘S path),
///   `-codd-file-find "<query>"`: the toolbar switch, the baseline select, a hunk bar's buttons,
///   ⌘S and the find widget on the shown tab, in that order.
///
/// M4 I4a (cleanup):
/// - `-codd-show cleanup`: the NOTES area's Cleanup page (mock mode: the Cleanup artboard).
/// - `-codd-retention-run YES`: one more retention run once the launch run finished (the dump's
///   `retention` adds up every run of this launch); with `-codd-now` and `-codd-trash-dir`.
/// - `-codd-cleanup-action <notes|sessions|files>:<id,id…>:keep|archive|trash`: the Cleanup row
///   actions on those rows (FILES ids as the page has them: `image:<path>`, `ring:<id>`, `recent:<path>`).
/// - `-codd-condense <id,id…>` (+ `-codd-condense-account <n|follow>`, `-codd-condense-apply YES`):
///   `交給 Claude 濃縮…` with those notes, `[✻ 產生摘要]` (the claude is `-codd-claude-path` on any
///   non-standard root), then `[建立摘要並封存原稿]`.
///
/// M4 ui-zoom (interface zoom):
/// - `-codd-zoom in|out|reset` (repeatable, in order, once the preferences were read): 顯示方式 ›
///   放大 ⌘+ / 縮小 ⌘− / 實際大小 ⌘0, through the menu commands. The values are written to
///   `preferences.json` like the keys' (set a level without writing with `-codd-set-pref
///   appearance.uiFontSize=16`); the state dump has `zoom` and `preferences.effective.uiFontSize`.
///   With `-codd-window-size` (mock mode too) the steps run once the window has that size, as a
///   live zoom, and are applied without being written.
///
/// M4 layout sweep (window sizes; `scripts/m4-layout-sweep.sh`):
/// - `-codd-window-size <W>x<H>|min`: the main window's content size at launch (`min`: its
///   minimum at the launch zoom; an explicit size is used as given, also below the minimum or
///   wider than the screen). The window's frame and the split's divider positions are then
///   neither restored nor saved, so a sweep never changes the size CODD opens at.
/// - `-codd-sidebar-width <pt>|min|max|collapsed`: the session sidebar at that width (clamped to
///   its limits at the launch zoom) or collapsed to the rail (no saved split either).
/// - `-codd-settings-size <W>x<H>|min`: the Settings window's content size when it opens.
/// - `-codd-settings-all YES`: with `-codd-snapshot` and a Settings window open, every section
///   is written as `<name>-settings-<section>.png`.
/// - `-codd-show menubar`: with `-codd-snapshot`, the menu bar panel is laid out and drawn into
///   `<name>-menubar.png` without being ordered in (it never shows on the menu bar).
///
/// M5 I1 (docs/M5-PLAN.md §5; measurements and the D20 check):
/// - `-codd-force-render YES` (D17): terminals keep drawing in a covered, hidden or minimized
///   window (TerminalHub never occludes them and the engines ignore the window's occlusion), and
///   the 1 Hz UI clock keeps running as with `-CODDForceVisibleTimers` (mock mode's lamps keep
///   their pulse: nothing removes it when the window is covered). For GPU measurements only.
/// - `-codd-stop-after-create YES` (D20): stop the session `-codd-new-claude` / `-codd-spawn-shell`
///   just created in the same main-actor turn, before its holder can exist (logs `stop deferred`,
///   then `stop applied-after-spawn`).
/// - `-CODDMetricsSessions <n>` (a defaults key like `-CODDMetricsPasses`, read by `DebugMetrics`):
///   the switch metric cycles only the first n sessions of the sidebar order.
///
/// M5 I2 (docs/M5-PLAN.md §5; the onboarding window, D5):
/// - `-codd-onboarding auto|show|never`: whether the wizard opens at launch. `auto` asks
///   `OnboardingGate` (a new data root: no layout.json, panes.json, onboarding.json or session);
///   `show` always opens it; `never` never does. Without the flag the standard data root is
///   `auto` and every other root `never` (so no earlier e2e script sees it).
/// - `-codd-onboarding-step <1-6>`: the wizard opens on that step (the earlier ones done).
/// - `-codd-onboarding-actions <a,b,…>`: run in order once the wizard shows: `redetect`, `next`,
///   `skip`, `back`, `goto:<n>`, `filter:<text>`, `check:<path>`, `uncheck:<path>`, `check-visible`,
///   `suggest`, `group:<path>=<key>`, `new-group:<path>=<name>`, `show-hidden`, `more`,
///   `hooks-preview` (the update plan only), `hooks-apply` (guarded like `-codd-hooks-apply`),
///   `reveal-notes`, `mcp-preview` (the registration plan only), `notify`, `finish`, `close`; each
///   logs `onboarding action=<a> step=<n> ok=<bool>`.
/// - `-codd-show onboarding[:<n>|:all]` (mock and real mode): the wizard at launch on step n
///   (mock mode: `OnboardingSamples`, never writing onboarding.json); with `-codd-snapshot` it is
///   written as `<name>-onboarding.png`, and `:all` writes `<name>-onboarding-<n>.png` for steps 1–6.
///
/// M5 I3 (D21):
/// - `-codd-a11y-audit <file>` (mock mode; the flag alone selects it): `AccessibilityAudit` over every
///   main screen (`AccessibilityAuditPass.screenNames`), each window, sheet and panel laid out but
///   kept behind other apps (the menu bar panel never ordered in). Writes
///   `{"screens":[…],"unlabeled":n,"outsideKeyLoop":n}`, prints `A11Y screens=<n> unlabeled=<n>
///   outsideKeyLoop=<n>` and exits (3 when anything is unlabeled, 0 otherwise).
/// - `-codd-a11y-screens <a,b,…>`: only those screens (a name, or a prefix such as `settings`).
/// - `-codd-full-keyboard-access YES|NO`: `KeyboardFocus.fullKeyboardAccessOverride` for the run.
struct RealModeOptions: Equatable, Sendable {
    var enabled = true
    var dataRoot: String?
    var claudeDir: String?
    var claudePath: String?
    var spawnShellCwd: String?
    var newClaudeCwd: String?
    var shellArgv: [String]?
    var quitAfterSeconds: Double?
    var snapshotPath: String?
    var dumpTerminalPath: String?
    var dumpStatePath: String?
    var autoAnswer: String?
    var resumeStopped = false
    var sendInput: String?
    var sendPanelInput: String?
    var openZshTab = false
    var openPanel = false
    var spawnCount = 1
    var captureLoginEnvironment = true
    var notifications = true
    var show: String?
    var unreachableAfterSeconds: Double?
    var keepaliveIdleMilliseconds: Int?
    var keepaliveTimeoutMilliseconds: Int?
    var closeMainWindow = false
    var selectSession: String?
    var newProfile: String?
    var resumeTranscript: String?
    var staleAfterSeconds: Double?
    var trashDir: String?
    var deleteHistory: String?
    var listTranscripts: String?
    var sidebarMode: SidebarMode?
    var sidebarFilter: String?
    var hoverCard: String?
    var newGroupName: String?
    var groupHover: String?
    var dragPreview: String?
    var sidebarDragTest = false
    var dropFolders: [String] = []
    var dropFoldersGroup: String?
    var dropFoldersIndex: Int?
    var shortcutMatrix = false
    var paletteQuery: String?
    var composerOpen = false
    var composerSend: [String] = []
    var panelTabs: Int?
    var maximizePanel = false
    var panelSelect: Int?
    var newSessionPath: String?
    var newSessionStart: String?
    var newSessionKind: String?
    var openProjectDropdown = false
    var newSessionAdvanced = false
    var editProfile: String?
    var newSessionCreate = false
    var setPrefs: [String] = []
    var cswapPath: String?
    var cswapRoot: String?
    var claudeSettings: String?
    var switchAccount: Int?
    var undoSwitch = false
    var newClaudeAccount: Int?
    var refreshAccounts = false
    var autoSwitchTickSeconds: Double?
    var hooksPlan: String?
    var hooksApply = false
    var hooksApplyDelayMilliseconds: Int?
    var addAccount: String?
    var statusSection: String?
    var statusDetails = false
    var quitRequestSeconds: Double?
    var quitChoice: String?
    var globalHotkey: Bool?
    var hotkeyCombo: String?
    var notesSelect: String?
    var notesNew: String?
    var quickNote = false
    var notesType: String?
    var notesPasteImage: String?
    var notesSearch: String?
    var notesRebuild = false
    var now: Date?
    var notesAnnotate: String?
    var notesSet: [String] = []
    var notesArchive: String?
    var notesTrash: String?
    var notesCopyRef: String?
    var notesMenu: String?
    var notesSend: String?
    var mcpRotate = false
    var claudeJSON: String?
    var mcpRegisterPlan: String?
    var mcpRegisterApply = false
    var mcpRegisterApplyDelayMilliseconds: Int?
    var openFile: String?
    var fileType: String?
    var fileShowAIChanges: Bool?
    var fileBaseline: String?
    var fileHunk: String?
    var fileSave = false
    var fileFind: String?
    var retentionRun = false
    var cleanupAction: String?
    var condense: String?
    var condenseAccount: String?
    var condenseApply = false
    /// `-codd-zoom` steps (`in`, `out`, `reset`), in order.
    var zoomSteps: [String] = []
    /// `-codd-window-size` (layout sweep): `WxH` or `min`.
    var windowSize: String?
    /// `-codd-sidebar-width`: points, `min`, `max` or `collapsed`.
    var sidebarWidth: String?
    /// `-codd-settings-size`: `WxH` or `min`.
    var settingsSize: String?
    /// `-codd-settings-all`: every Settings section into the snapshot.
    var settingsAll = false
    /// `-codd-force-render` (M5 D17).
    var forceRender = false
    /// `-codd-stop-after-create` (M5 D20).
    var stopAfterCreate = false
    /// `-codd-onboarding` (M5 D5): `auto`, `show` or `never`; nil = the root's default.
    var onboarding: String?
    /// `-codd-onboarding-step` (1–6).
    var onboardingStep: Int?
    /// `-codd-onboarding-actions`, split at commas.
    var onboardingActions: [String] = []
    /// `-codd-a11y-audit <file>` (M5 D21, mock mode): the accessibility pass over every main screen,
    /// written as JSON to that file; the run then exits (3 when an element is unlabeled).
    var a11yAuditPath: String?
    /// `-codd-a11y-screens <list>`: only these screens (names or prefixes: `settings`, `onboarding`).
    var a11yScreens: [String] = []
    /// `-codd-full-keyboard-access YES|NO`: `KeyboardFocus.fullKeyboardAccessOverride` for the run.
    var fullKeyboardAccess: Bool?

    static let mockFlag = "-codd-mock"
    static let realHoldersFlag = "-codd-real-holders"
    static let dataRootFlag = "-codd-data-root"
    static let dataRootVariable = "CODD_DATA_ROOT"
    static let claudeDirFlag = "-codd-claude-dir"
    static let claudeDirVariable = "CODD_CLAUDE_DIR"
    static let claudePathFlag = "-codd-claude-path"
    static let spawnShellFlag = "-codd-spawn-shell"
    static let newClaudeFlag = "-codd-new-claude"
    static let shellArgvFlag = "-codd-shell-argv"
    static let quitAfterFlag = "-codd-quit-after"
    static let snapshotFlag = "-codd-snapshot"
    static let dumpTerminalFlag = "-codd-dump-terminal"
    static let dumpStateFlag = "-codd-dump-state"
    static let autoAnswerFlag = "-codd-auto-answer"
    static let resumeStoppedFlag = "-codd-resume-stopped"
    static let sendInputFlag = "-codd-send-input"
    static let sendPanelInputFlag = "-codd-send-panel-input"
    static let openZshTabFlag = "-codd-open-zsh-tab"
    static let openPanelFlag = "-codd-open-panel"
    static let spawnCountFlag = "-codd-spawn-count"
    static let loginEnvironmentFlag = "-codd-login-env"
    static let notificationsFlag = "-codd-notifications"
    static let showFlag = "-codd-show"
    static let unreachableAfterFlag = "-codd-unreachable-after"
    static let keepaliveFlag = "-codd-keepalive"
    static let closeMainWindowFlag = "-codd-close-main-window"
    static let selectSessionFlag = "-codd-select-session"
    static let newProfileFlag = "-codd-new-profile"
    static let resumeTranscriptFlag = "-codd-resume-transcript"
    static let staleAfterFlag = "-codd-stale-after"
    static let trashDirFlag = "-codd-trash-dir"
    static let deleteHistoryFlag = "-codd-delete-history"
    static let listTranscriptsFlag = "-codd-list-transcripts"
    static let sidebarModeFlag = "-codd-sidebar-mode"
    static let sidebarFilterFlag = "-codd-sidebar-filter"
    static let hoverCardFlag = "-codd-hover-card"
    static let newGroupFlag = "-codd-new-group"
    static let groupHoverFlag = "-codd-group-hover"
    static let dragPreviewFlag = "-codd-drag-preview"
    static let sidebarDragTestFlag = "-codd-sidebar-drag-test"
    static let dropFoldersFlag = "-codd-drop-folders"
    static let dropFoldersGroupFlag = "-codd-drop-folders-group"
    static let dropFoldersIndexFlag = "-codd-drop-folders-index"
    static let shortcutMatrixFlag = "-codd-shortcut-matrix"
    static let paletteQueryFlag = "-codd-palette-query"
    static let composerOpenFlag = "-codd-composer-open"
    static let composerSendFlag = "-codd-composer-send"
    static let panelTabsFlag = "-codd-panel-tabs"
    static let maximizePanelFlag = "-codd-maximize-panel"
    static let panelSelectFlag = "-codd-panel-select"
    static let newSessionPathFlag = "-codd-new-session-path"
    static let newSessionStartFlag = "-codd-new-session-start"
    static let newSessionKindFlag = "-codd-new-session-kind"
    static let openProjectDropdownFlag = "-codd-open-project-dropdown"
    static let newSessionAdvancedFlag = "-codd-new-session-advanced"
    static let editProfileFlag = "-codd-edit-profile"
    static let newSessionCreateFlag = "-codd-new-session-create"
    static let setPrefFlag = "-codd-set-pref"
    static let cswapPathFlag = "-codd-cswap-path"
    static let cswapRootFlag = "-codd-cswap-root"
    static let claudeSettingsFlag = "-codd-claude-settings"
    static let switchAccountFlag = "-codd-switch-account"
    static let undoSwitchFlag = "-codd-undo-switch"
    static let newClaudeAccountFlag = "-codd-new-claude-account"
    static let refreshAccountsFlag = "-codd-refresh-accounts"
    static let autoSwitchTickFlag = "-codd-auto-switch-tick"
    static let hooksPlanFlag = "-codd-hooks-plan"
    static let hooksApplyFlag = "-codd-hooks-apply"
    static let hooksApplyDelayFlag = "-codd-hooks-apply-delay"
    static let addAccountFlag = "-codd-add-account"
    static let statusSectionFlag = "-codd-status-section"
    static let statusDetailsFlag = "-codd-status-details"
    static let quitRequestFlag = "-codd-quit-request"
    static let quitChoiceFlag = "-codd-quit-choice"
    static let globalHotkeyFlag = "-codd-global-hotkey"
    static let hotkeyFlag = "-codd-hotkey"
    static let notesSelectFlag = "-codd-notes-select"
    static let notesNewFlag = "-codd-notes-new"
    static let quickNoteFlag = "-codd-quick-note"
    static let notesTypeFlag = "-codd-notes-type"
    static let notesPasteImageFlag = "-codd-notes-paste-image"
    static let notesSearchFlag = "-codd-notes-search"
    static let notesRebuildFlag = "-codd-notes-rebuild"
    static let nowFlag = "-codd-now"
    static let notesAnnotateFlag = "-codd-notes-annotate"
    static let notesSetFlag = "-codd-notes-set"
    static let notesArchiveFlag = "-codd-notes-archive"
    static let notesTrashFlag = "-codd-notes-trash"
    static let notesCopyRefFlag = "-codd-notes-copy-ref"
    static let notesMenuFlag = "-codd-notes-menu"
    static let notesSendFlag = "-codd-notes-send"
    static let mcpRotateFlag = "-codd-mcp-rotate"
    static let claudeJSONFlag = "-codd-claude-json"
    static let mcpRegisterPlanFlag = "-codd-mcp-register-plan"
    static let mcpRegisterApplyFlag = "-codd-mcp-register-apply"
    static let mcpRegisterApplyDelayFlag = "-codd-mcp-register-apply-delay"
    static let openFileFlag = "-codd-open-file"
    static let fileTypeFlag = "-codd-file-type"
    static let fileShowAIChangesFlag = "-codd-file-show-ai-changes"
    static let fileBaselineFlag = "-codd-file-baseline"
    static let fileHunkFlag = "-codd-file-hunk"
    static let fileSaveFlag = "-codd-file-save"
    static let fileFindFlag = "-codd-file-find"
    static let retentionRunFlag = "-codd-retention-run"
    static let cleanupActionFlag = "-codd-cleanup-action"
    static let condenseFlag = "-codd-condense"
    static let condenseAccountFlag = "-codd-condense-account"
    static let condenseApplyFlag = "-codd-condense-apply"
    static let zoomFlag = "-codd-zoom"
    static let windowSizeFlag = "-codd-window-size"
    static let sidebarWidthFlag = "-codd-sidebar-width"
    static let settingsSizeFlag = "-codd-settings-size"
    static let settingsAllFlag = "-codd-settings-all"
    static let forceRenderFlag = "-codd-force-render"
    static let stopAfterCreateFlag = "-codd-stop-after-create"
    static let onboardingFlag = "-codd-onboarding"
    static let onboardingStepFlag = "-codd-onboarding-step"
    static let onboardingActionsFlag = "-codd-onboarding-actions"
    static let a11yAuditFlag = "-codd-a11y-audit"
    static let a11yScreensFlag = "-codd-a11y-screens"
    static let fullKeyboardAccessFlag = "-codd-full-keyboard-access"
    /// DEBUG tools that draw or fuzz the SPEC §5 mock data.
    static let mockToolFlags: Set<String> = ["-CODDSelfTest", "-CODDSnapshotDir", "-CODDMetrics"]

    /// Options of this process. Release builds keep only the every-build options.
    static var current: RealModeOptions {
        let parsed = parse(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment,
                           home: NSHomeDirectory())
        #if DEBUG
        return parsed
        #else
        return parsed.releaseSubset
        #endif
    }

    #if DEBUG
    static let allowStandardRootVariable = "CODD_ALLOW_STANDARD_ROOT"

    /// Why this DEBUG launch must not start, or nil. A real-mode run started from a Claude Code
    /// shell (`CLAUDECODE`, i.e. an agent or a script it runs) without a data root would use the
    /// user's own `~/Library/Application Support/CODD`; on 2026-10-17 an argument list passed as
    /// one zsh word did exactly that. A fake home (`CFFIXED_USER_HOME`) moves the standard root
    /// with it, and `CODD_ALLOW_STANDARD_ROOT=1` runs there on purpose.
    static func standardRootRefusal(options: RealModeOptions, environment: [String: String]) -> String? {
        guard options.enabled, options.dataRoot == nil, environment["CLAUDECODE"] != nil,
              environment["CFFIXED_USER_HOME"] == nil, environment[allowStandardRootVariable] != "1" else { return nil }
        return "CODD (DEBUG) refused to start: launched from Claude Code in real mode without \(dataRootFlag), "
            + "so it would use the user's own data root. Pass \(dataRootFlag) <temp dir> (one argument each; "
            + "zsh does not split \"$VAR\" strings) or set \(allowStandardRootVariable)=1."
    }
    #endif

    /// The options a Release build honours (mode, data root, Claude directory).
    var releaseSubset: RealModeOptions {
        var options = RealModeOptions()
        options.enabled = enabled
        options.dataRoot = dataRoot
        options.claudeDir = claudeDir
        return options
    }

    /// Pure parser (unit-tested). `arguments[0]` is the executable and is skipped.
    static func parse(arguments: [String], environment: [String: String], home: String) -> RealModeOptions {
        var options = RealModeOptions()
        let args = Array(arguments.dropFirst())
        var explicitMode: Bool?
        var mockTool = false
        var index = 0
        func value(after i: Int) -> String? {
            i + 1 < args.count ? args[i + 1] : nil
        }
        /// A flag with an optional YES / NO value (a following flag is never swallowed).
        func flag(at i: Int) -> Bool {
            if let next = value(after: i), let parsed = boolValue(next) {
                index += 1
                return parsed
            }
            return true
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case mockFlag:
                explicitMode = !flag(at: index)
            case realHoldersFlag:
                explicitMode = flag(at: index)
            case dataRootFlag:
                if let next = value(after: index) { options.dataRoot = expand(next, home: home); index += 1 }
            case claudeDirFlag:
                if let next = value(after: index) { options.claudeDir = expand(next, home: home); index += 1 }
            case claudePathFlag:
                if let next = value(after: index) { options.claudePath = expand(next, home: home); index += 1 }
            case spawnShellFlag, newClaudeFlag:
                if let next = value(after: index) {
                    let cwd: String?
                    switch boolValue(next) {
                    case true?: cwd = home
                    case false?: cwd = nil
                    case nil: cwd = expand(next, home: home)
                    }
                    if arg == spawnShellFlag { options.spawnShellCwd = cwd } else { options.newClaudeCwd = cwd }
                    index += 1
                }
            case shellArgvFlag:
                if let next = value(after: index) {
                    let argv = next.split(separator: " ").map(String.init)
                    options.shellArgv = argv.isEmpty ? nil : argv
                    index += 1
                }
            case quitAfterFlag:
                if let next = value(after: index) {
                    options.quitAfterSeconds = Double(next).flatMap { $0 > 0 ? $0 : nil }
                    index += 1
                }
            case snapshotFlag:
                if let next = value(after: index) { options.snapshotPath = expand(next, home: home); index += 1 }
            case dumpTerminalFlag:
                if let next = value(after: index) { options.dumpTerminalPath = expand(next, home: home); index += 1 }
            case dumpStateFlag:
                if let next = value(after: index) { options.dumpStatePath = expand(next, home: home); index += 1 }
            case autoAnswerFlag:
                if let next = value(after: index) {
                    options.autoAnswer = TerminalInput.isAnswerKey(next.lowercased()) ? next.lowercased() : nil
                    index += 1
                }
            case sendInputFlag:
                if let next = value(after: index) { options.sendInput = next; index += 1 }
            case sendPanelInputFlag:
                if let next = value(after: index) { options.sendPanelInput = next; index += 1 }
            case openZshTabFlag:
                options.openZshTab = flag(at: index)
            case openPanelFlag:
                options.openPanel = flag(at: index)
            case resumeStoppedFlag:
                options.resumeStopped = flag(at: index)
            case loginEnvironmentFlag:
                options.captureLoginEnvironment = flag(at: index)
            case notificationsFlag:
                options.notifications = flag(at: index)
            case showFlag:
                if let next = value(after: index) { options.show = showValue(next); index += 1 }
            case unreachableAfterFlag:
                if let next = value(after: index) {
                    options.unreachableAfterSeconds = Double(next).flatMap { $0 > 0 && $0 <= 3600 ? $0 : nil }
                    index += 1
                }
            case keepaliveFlag:
                if let next = value(after: index) {
                    let parts = next.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2, let idle = parts[0], let timeout = parts[1], idle > 0, timeout > 0 {
                        options.keepaliveIdleMilliseconds = idle
                        options.keepaliveTimeoutMilliseconds = timeout
                    }
                    index += 1
                }
            case closeMainWindowFlag:
                options.closeMainWindow = flag(at: index)
            case selectSessionFlag:
                if let next = value(after: index) { options.selectSession = next.lowercased(); index += 1 }
            case newProfileFlag:
                if let next = value(after: index) { options.newProfile = next; index += 1 }
            case resumeTranscriptFlag:
                if let next = value(after: index) { options.resumeTranscript = next; index += 1 }
            case staleAfterFlag:
                if let next = value(after: index) {
                    options.staleAfterSeconds = Double(next).flatMap { $0 >= 0 && $0 <= 30 * 86_400 ? $0 : nil }
                    index += 1
                }
            case trashDirFlag:
                if let next = value(after: index) { options.trashDir = expand(next, home: home); index += 1 }
            case deleteHistoryFlag:
                if let next = value(after: index) { options.deleteHistory = next.lowercased(); index += 1 }
            case listTranscriptsFlag:
                if let next = value(after: index) { options.listTranscripts = expand(next, home: home); index += 1 }
            case sidebarModeFlag:
                if let next = value(after: index) {
                    switch next.lowercased() {
                    case "tree": options.sidebarMode = .tree
                    case "state": options.sidebarMode = .state
                    default: break
                    }
                    index += 1
                }
            case sidebarFilterFlag:
                if let next = value(after: index) { options.sidebarFilter = next; index += 1 }
            case hoverCardFlag:
                if let next = value(after: index) { options.hoverCard = next.lowercased(); index += 1 }
            case newGroupFlag:
                if let next = value(after: index) { options.newGroupName = next; index += 1 }
            case groupHoverFlag:
                if let next = value(after: index) { options.groupHover = next; index += 1 }
            case dragPreviewFlag:
                if let next = value(after: index) { options.dragPreview = next; index += 1 }
            case sidebarDragTestFlag:
                options.sidebarDragTest = flag(at: index)
            case dropFoldersFlag:
                if let next = value(after: index) { options.dropFolders.append(expand(next, home: home)); index += 1 }
            case dropFoldersGroupFlag:
                if let next = value(after: index) { options.dropFoldersGroup = next; index += 1 }
            case dropFoldersIndexFlag:
                if let next = value(after: index) { options.dropFoldersIndex = Int(next).map { max(0, $0) }; index += 1 }
            case shortcutMatrixFlag:
                options.shortcutMatrix = flag(at: index)
            case paletteQueryFlag:
                if let next = value(after: index) { options.paletteQuery = next; index += 1 }
            case composerOpenFlag:
                options.composerOpen = flag(at: index)
            case composerSendFlag:
                if let next = value(after: index) { options.composerSend.append(decodeEscapes(next)); index += 1 }
            case panelTabsFlag:
                if let next = value(after: index) {
                    options.panelTabs = Int(next).flatMap { (1...8).contains($0) ? $0 : nil }
                    index += 1
                }
            case maximizePanelFlag:
                options.maximizePanel = flag(at: index)
            case panelSelectFlag:
                if let next = value(after: index) {
                    options.panelSelect = Int(next).flatMap { (1...8).contains($0) ? $0 : nil }
                    index += 1
                }
            case newSessionPathFlag:
                if let next = value(after: index) { options.newSessionPath = expand(next, home: home); index += 1 }
            case newSessionStartFlag:
                if let next = value(after: index) {
                    options.newSessionStart = NewSessionForm.Start(mode: next) != nil ? next.lowercased() : nil
                    index += 1
                }
            case newSessionKindFlag:
                if let next = value(after: index) {
                    options.newSessionKind = ["claude", "shell"].contains(next.lowercased()) ? next.lowercased() : nil
                    index += 1
                }
            case openProjectDropdownFlag:
                options.openProjectDropdown = flag(at: index)
            case newSessionAdvancedFlag:
                options.newSessionAdvanced = flag(at: index)
            case editProfileFlag:
                if let next = value(after: index) { options.editProfile = next; index += 1 }
            case newSessionCreateFlag:
                options.newSessionCreate = flag(at: index)
            case setPrefFlag:
                if let next = value(after: index) { options.setPrefs.append(next); index += 1 }
            case cswapPathFlag:
                if let next = value(after: index) { options.cswapPath = expand(next, home: home); index += 1 }
            case cswapRootFlag:
                if let next = value(after: index) { options.cswapRoot = expand(next, home: home); index += 1 }
            case claudeSettingsFlag:
                if let next = value(after: index) { options.claudeSettings = expand(next, home: home); index += 1 }
            case switchAccountFlag:
                if let next = value(after: index) {
                    options.switchAccount = Int(next).flatMap { (1...9999).contains($0) ? $0 : nil }
                    index += 1
                }
            case undoSwitchFlag:
                options.undoSwitch = flag(at: index)
            case newClaudeAccountFlag:
                if let next = value(after: index) {
                    options.newClaudeAccount = Int(next).flatMap { (1...9999).contains($0) ? $0 : nil }
                    index += 1
                }
            case refreshAccountsFlag:
                options.refreshAccounts = flag(at: index)
            case autoSwitchTickFlag:
                if let next = value(after: index) {
                    options.autoSwitchTickSeconds = Double(next).flatMap { $0 >= 0.2 && $0 <= 3600 ? $0 : nil }
                    index += 1
                }
            case hooksPlanFlag:
                if let next = value(after: index) {
                    options.hooksPlan = ClaudeSettingsService.action(named: next) != nil ? next.lowercased() : nil
                    index += 1
                }
            case hooksApplyFlag:
                options.hooksApply = flag(at: index)
            case hooksApplyDelayFlag:
                if let next = value(after: index) {
                    options.hooksApplyDelayMilliseconds = Int(next).flatMap { (0...30_000).contains($0) ? $0 : nil }
                    index += 1
                }
            case addAccountFlag:
                if let next = value(after: index) { options.addAccount = next; index += 1 }
            case statusSectionFlag:
                if let next = value(after: index) { options.statusSection = next.lowercased(); index += 1 }
            case statusDetailsFlag:
                options.statusDetails = flag(at: index)
            case quitRequestFlag:
                if let next = value(after: index) {
                    options.quitRequestSeconds = Double(next).flatMap { $0 > 0 && $0 <= 3600 ? $0 : nil }
                    index += 1
                }
            case quitChoiceFlag:
                if let next = value(after: index) {
                    options.quitChoice = QuitDialogController.choice(named: next) != nil ? next.lowercased() : nil
                    index += 1
                }
            case globalHotkeyFlag:
                options.globalHotkey = flag(at: index)
            case hotkeyFlag:
                if let next = value(after: index) { options.hotkeyCombo = next; index += 1 }
            case notesSelectFlag:
                if let next = value(after: index) { options.notesSelect = next; index += 1 }
            case notesNewFlag:
                if let next = value(after: index) { options.notesNew = next; index += 1 }
            case quickNoteFlag:
                options.quickNote = flag(at: index)
            case notesTypeFlag:
                if let next = value(after: index) { options.notesType = decodeEscapes(next); index += 1 }
            case notesPasteImageFlag:
                if let next = value(after: index) { options.notesPasteImage = expand(next, home: home); index += 1 }
            case notesSearchFlag:
                if let next = value(after: index) { options.notesSearch = next; index += 1 }
            case notesRebuildFlag:
                options.notesRebuild = flag(at: index)
            case nowFlag:
                if let next = value(after: index) { options.now = isoDate(next); index += 1 }
            case notesAnnotateFlag:
                if let next = value(after: index) { options.notesAnnotate = next; index += 1 }
            case notesSetFlag:
                if let next = value(after: index) { options.notesSet.append(next); index += 1 }
            case notesArchiveFlag:
                if let next = value(after: index) { options.notesArchive = next; index += 1 }
            case notesTrashFlag:
                if let next = value(after: index) { options.notesTrash = next; index += 1 }
            case notesCopyRefFlag:
                if let next = value(after: index) { options.notesCopyRef = next; index += 1 }
            case notesMenuFlag:
                if let next = value(after: index) { options.notesMenu = next.lowercased(); index += 1 }
            case notesSendFlag:
                if let next = value(after: index) { options.notesSend = next; index += 1 }
            case mcpRotateFlag:
                options.mcpRotate = flag(at: index)
            case claudeJSONFlag:
                if let next = value(after: index) { options.claudeJSON = expand(next, home: home); index += 1 }
            case mcpRegisterPlanFlag:
                if let next = value(after: index) {
                    let name = next.lowercased()
                    options.mcpRegisterPlan = ["claude-code", "remove"].contains(name) ? name : nil
                    index += 1
                }
            case mcpRegisterApplyFlag:
                options.mcpRegisterApply = flag(at: index)
            case mcpRegisterApplyDelayFlag:
                if let next = value(after: index) {
                    options.mcpRegisterApplyDelayMilliseconds = Int(next).flatMap { (0...30_000).contains($0) ? $0 : nil }
                    index += 1
                }
            case openFileFlag:
                if let next = value(after: index) { options.openFile = expand(next, home: home); index += 1 }
            case fileTypeFlag:
                if let next = value(after: index) { options.fileType = decodeEscapes(next); index += 1 }
            case fileShowAIChangesFlag:
                if let next = value(after: index), let on = boolValue(next) { options.fileShowAIChanges = on; index += 1 }
            case fileBaselineFlag:
                if let next = value(after: index) {
                    let name = next.lowercased()
                    options.fileBaseline = ["head", "saved", "ai"].contains(name) ? name : nil
                    index += 1
                }
            case fileHunkFlag:
                if let next = value(after: index) { options.fileHunk = next.lowercased(); index += 1 }
            case fileSaveFlag:
                options.fileSave = flag(at: index)
            case fileFindFlag:
                if let next = value(after: index) { options.fileFind = next; index += 1 }
            case retentionRunFlag:
                options.retentionRun = flag(at: index)
            case cleanupActionFlag:
                if let next = value(after: index) { options.cleanupAction = next; index += 1 }
            case condenseFlag:
                if let next = value(after: index) { options.condense = next; index += 1 }
            case condenseAccountFlag:
                if let next = value(after: index) { options.condenseAccount = next.lowercased(); index += 1 }
            case condenseApplyFlag:
                options.condenseApply = flag(at: index)
            case zoomFlag:
                if let next = value(after: index) { options.zoomSteps.append(next.lowercased()); index += 1 }
            case windowSizeFlag:
                if let next = value(after: index) { options.windowSize = next.lowercased(); index += 1 }
            case sidebarWidthFlag:
                if let next = value(after: index) { options.sidebarWidth = next.lowercased(); index += 1 }
            case settingsSizeFlag:
                if let next = value(after: index) { options.settingsSize = next.lowercased(); index += 1 }
            case settingsAllFlag:
                options.settingsAll = flag(at: index)
            case forceRenderFlag:
                options.forceRender = flag(at: index)
            case stopAfterCreateFlag:
                options.stopAfterCreate = flag(at: index)
            case onboardingFlag:
                if let next = value(after: index) {
                    let mode = next.lowercased()
                    options.onboarding = ["auto", "show", "never"].contains(mode) ? mode : nil
                    index += 1
                }
            case onboardingStepFlag:
                if let next = value(after: index) {
                    options.onboardingStep = Int(next).flatMap { (1...6).contains($0) ? $0 : nil }
                    index += 1
                }
            case onboardingActionsFlag:
                if let next = value(after: index) {
                    options.onboardingActions += next.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    index += 1
                }
            case spawnCountFlag:
                if let next = value(after: index) {
                    options.spawnCount = Int(next).map { min(max($0, 1), 32) } ?? 1
                    index += 1
                }
            case a11yAuditFlag:
                // A mock-data tool: it never runs on a data root (like -CODDSnapshotDir).
                mockTool = true
                if let next = value(after: index) { options.a11yAuditPath = expand(next, home: home); index += 1 }
            case a11yScreensFlag:
                if let next = value(after: index) {
                    options.a11yScreens += next.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    index += 1
                }
            case fullKeyboardAccessFlag:
                options.fullKeyboardAccess = flag(at: index)
            default:
                if mockToolFlags.contains(arg) { mockTool = true }
            }
            index += 1
        }
        options.enabled = explicitMode ?? !mockTool
        if options.dataRoot == nil, let root = environment[dataRootVariable], !root.isEmpty {
            options.dataRoot = expand(root, home: home)
        }
        if options.claudeDir == nil, let dir = environment[claudeDirVariable], !dir.isEmpty {
            options.claudeDir = expand(dir, home: home)
        }
        return options
    }

    /// Holder connection timings for this run (defaults unless the DEBUG flags changed them).
    var connectionTuning: PtyConnectionTuning {
        var tuning = PtyConnectionTuning()
        if let seconds = unreachableAfterSeconds { tuning.unreachableAfter = .milliseconds(Int(seconds * 1000)) }
        if let idle = keepaliveIdleMilliseconds, let timeout = keepaliveTimeoutMilliseconds {
            tuning.stream.keepaliveIntervalMilliseconds = idle
            tuning.stream.keepaliveTimeoutMilliseconds = timeout
        }
        return tuning
    }

    /// `-codd-window-size` / `-codd-settings-size`: `min` is `minimum`, `WxH` is used as given
    /// (positive, at most 8000 × 8000); anything else is nil.
    static func layoutSize(_ text: String?, minimum: CGSize) -> CGSize? {
        guard let text else { return nil }
        if text == "min" { return minimum }
        let parts = text.split(separator: "x").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let width = parts[0], let height = parts[1], (1...8000).contains(width),
              (1...8000).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// `-codd-show`: the keyword before the first `:` is case-insensitive, everything after it (a
    /// note id, a path, an asset name) is kept exactly as given.
    static func showValue(_ raw: String) -> String {
        guard let colon = raw.firstIndex(of: ":") else { return raw.lowercased() }
        return raw[..<colon].lowercased() + raw[colon...]
    }

    /// The `-codd-show` keyword (`note` of `note:<id>`).
    var showKeyword: String? {
        show.map { value in value.firstIndex(of: ":").map { String(value[..<$0]) } ?? value }
    }

    /// What follows the first `:` of `-codd-show`, as given (`<id>` of `note:<id>`).
    var showArgument: String? {
        guard let show, let colon = show.firstIndex(of: ":") else { return nil }
        return String(show[show.index(after: colon)...])
    }

    /// `2026-10-15T10:42:00+08:00`, with or without fractional seconds.
    static func isoDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Why a DEBUG flag's path must not be read (the M3 A13 guard rule, widened for M4): inside the
    /// real home's `.claude*`, `.codex`, `.claude-swap-backup` or `Library/Application Support/CODD`,
    /// lexically or once symlinks are resolved (a dangling link through its nearest existing
    /// ancestor). Nil when it is fine.
    static func protectedPathReason(_ path: String, home: String = RealModeOptions.realHome) -> String? {
        let lexical = (path as NSString).standardizingPath
        let resolved = guardResolved(path)
        let resolvedHome = ClaudeSettingsService.resolvedPath(home)
        for (candidate, base) in [(lexical, home), (resolved, resolvedHome), (resolved, home)] {
            guard candidate.hasPrefix(base + "/") else { continue }
            let rest = candidate.dropFirst(base.count + 1)
            let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if first.hasPrefix(".claude") { return "inside the real ~/\(first)" }
            if first == ".codex" { return "inside the real ~/.codex" }
            if rest == "Library/Application Support/CODD" || rest.hasPrefix("Library/Application Support/CODD/") {
                return "inside the real ~/Library/Application Support/CODD"
            }
        }
        return nil
    }

    /// The path with symlinks resolved; a dangling link resolves through its destination (so a
    /// link to a file not yet created inside `~/.claude` is still seen as pointing there).
    static func guardResolved(_ path: String, depth: Int = 0) -> String {
        let standardized = (path as NSString).standardizingPath
        if depth < 8, !FileManager.default.fileExists(atPath: standardized),
           let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: standardized) {
            let target = destination.hasPrefix("/") ? destination
                : ((standardized as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
            return guardResolved(target, depth: depth + 1)
        }
        return ClaudeSettingsService.resolvedPath(standardized)
    }

    /// The account's own home (`CFFIXED_USER_HOME` moves `NSHomeDirectory()`, never this one).
    static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// `\n` → LF, `\t` → TAB, `\\` → `\` (anything else after a backslash stays as typed).
    static func decodeEscapes(_ text: String) -> String {
        var out = ""
        var escaping = false
        for ch in text {
            if escaping {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    private static func boolValue(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }

    /// `~` / `~/x` → home-relative absolute path; anything else unchanged.
    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }
}
