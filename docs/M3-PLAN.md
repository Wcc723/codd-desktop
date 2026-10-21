# M3 plan — Menu bar, accounts, status, settings

Goal: CODD knows the user's Claude accounts and their remaining quota without ever asking
Anthropic's usage API. Accounts come from cswap (its own state files, read-only, plus `cswap switch`
for switching); quota comes from Claude Code's status line (a `codd-statusline` CLI injected into every
CODD claude session, chaining the user's own status line) and from cswap's cache. The menu bar extra,
the sidebar footer, the rail chip and Home USAGE show real data; accounts switch directly with UNDO;
auto-switch at ≤ 2 % remaining (default OFF) works; the STATUS page (HOST, ACCOUNTS, HOOKS &
STATUSLINE, MCP / REMOTE placeholders) and every Settings section of the artboard exist and persist
in the data root; the four §7.7 dialogs (switch account, Hook 差異, add account, quit) work; a
configurable global hotkey shows CODD from any app.

Sources (read before working): design/SPEC.md §2, §5, §7.7, §7.11, §7.12, §7.13 with the §8 (v2)
and §9 (v3, R7 / R8) overrides; the APPROVED, frozen artboards
`design/artboards-src/{MenuBar,Status,Settings,StatusDialogs,Main,Home,NewSession}.src.html`
(implement them, do not redesign); `design/helmet.html` (tokens, `.card`, `.qrow`, `.bar10`,
`.meter`, `.sw`, `.seg`, `.modal`, `.thr`); docs/ARCHITECTURE.md; docs/M2-REPORT.md (§5 known issues,
§7 decisions); docs/ROADMAP.md (standing decisions).

Out of scope: notebook, file editor, MCP server (M4: their Settings rows and the STATUS MCP section
are placeholders), cleanup engine (M4: Settings › 清理 values are stored only), onboarding,
performance hardening, release packaging, updates (M5), remote (future).

---

## 0. Starting point (code survey, 2026-10-17)

| Item | Exists after M2 | Gap M3 closes |
|---|---|---|
| Accounts model | CoddCore `Account`, `QuotaWindow` (used %, `status(at:)` with rollover), `AccountOrdering` (R7), `AutoSwitchPolicy` / `AutoSwitchController` (R8, cooldown, "no target" de-dup), `CswapClient` (`list` / `status` / `switch --json`, serialized, env scrubbing), cswap JSON models + fixtures | no reader of cswap's state files, no quota cache, no attribution of status-line numbers to accounts, no `add` / `alias` / `--version`, no pace for status-line data, no e-mail redaction helper |
| App accounts | `AccountStore` protocol (sync `switchTo`), `MockAccountStore` used in real mode too (D29 note `· 示意資料，M3 接上 cswap`), `AccountVM` / app `QuotaWindow` (remaining %, tone), `AccountRowView` (sidebar `.acrow`, menu bar `.mb-ac`), `SidebarFooterView` (R2 expand), `RailAccountChip`, Home USAGE, ⌘N account select disabled (D16) | a real store, async switch with progress / failure / UNDO, pinned sessions, threshold ticks, no sample-data note |
| Status line | `StatusLineWrapper` placeholder in CoddCore `HookSettings.swift` | `codd-statusline` CLI, `/statusline` endpoint, per-session `statusLine` injection, chaining |
| Menu bar | `StatusItemController` (one icon, attention / no-hook variants, right-click menu with 切換帳號 ▸ and a no-op 暫停通知), `MenuBarPanelView` (R4 order: ACCOUNTS · NEEDS YOU · READY · RUNNING · footer) | real accounts, counts mode, pause, account list expander, switch progress |
| STATUS | `StatusPageView` (M1 subset: HOOKS endpoint counters, DATA paths), in the main pane; session sidebar stays | the artboard page with its own sidebar |
| Settings | Separate window (1040 × 720, M2 I6) with the section list; 通知 (one on/off in UserDefaults) and 啟動設定檔 (real); the rest placeholders | every section of the artboard, persisted in the data root |
| Dialogs | none of §7.7 | all four |
| Lifecycle | ⌘Q flushes hooks and quits, holders keep running; close window keeps CODD (D10) | quit confirmation, 結束時 / 關閉視窗 / Dock / login-item preferences, global hotkey |
| Claude settings | read-only (`cleanupPeriodDays`, `model`) | read the user's `statusLine` (read-only, for chaining); the global installer writes `~/.claude/settings.json` only on explicit confirmation with a diff and a backup |
| Launch environment | `HolderLauncher.planClaude` takes **argv** from CoddCore `LaunchBuilder` but builds the child **environment** itself with `App/Real/ShellEnvironment.build` (sanitized login env + `SpawnEnvironmentBuilder` + an `extra` dictionary that wins; `CODD_HOOK_URL` already comes from that `extra`). `LaunchSpec.environment` is not used for holders | every new CODD variable (`CODD_STATUSLINE_CHAIN`, a pinned `CLAUDE_CONFIG_DIR`) must reach the holder through `extra` (C1 exposes them as `LaunchSpec.coddEnvironment`, I1b merges it) |
| Design-system copy set | `App/Controls/FormControls.swift` uses `ClosureMenuItem` (App/Sidebar/SidebarViewController+Menu.swift) and `HomeHeaderView.glow` (App/Session/HomeCards.swift); `DashedRuleView` already exists in App/MenuBar/MenuBarPanelView.swift; App keeps its own `QuotaRowView` / `QuotaRowRenderer` | C5 copies `ClosureMenuItem` and `DashedRuleView` too, adds `Draw.glow`, and names its value-based quota row `QuotaBarRowView` / `QuotaBarRowRenderer` (same names in two modules would be ambiguous in App/Tests) |

## 1. Verified facts (2026-10-17, no session started, nothing sent)

**Claude Code status line input** (installed 2.1.302, read from the bundled JS in the binary): the
command gets one JSON object on stdin with `session_id`, `transcript_path`, `cwd`, `model`,
`workspace`, `version`, `cost`, `context_window`, … and, only when at least one window is known,
```
"rate_limits": {
  "five_hour": { "used_percentage": <0–100, one decimal, clamped to 100>, "resets_at": <epoch SECONDS, number> },
  "seven_day": { "used_percentage": …, "resets_at": … },
  "spend_limit": { … }          // gateway only, ignored by CODD
}
```
(`used_percentage = min(round(utilization × 1000) / 10, 100)`; a window is absent when unknown; the
web CODD script also accepted ms and ISO strings — CODD accepts all three). The settings key is
`statusLine: {type: "command", command, padding?, refreshInterval? (≥ 1 s), hideVimModeIndicator?}`;
it runs on assistant-message and setting changes (debounced 300 ms) plus `refreshInterval`. There is no
plan / subscription field in the status line input.

**cswap 0.26.0** (`~/.local/share/uv/tools/claude-swap/…/claude_swap`, read only):
- `cswap list --json` and `status --json` **fetch `https://api.anthropic.com/api/oauth/usage`** for
  stale accounts (self-throttled to ≥ 180 s per account). CODD therefore never runs them on a timer.
- State root (macOS) `~/.claude-swap-backup/`: `sequence.json` (`activeAccountNumber`, `sequence`
  [numbers], `accounts{"<n>": {email, organizationUuid, organizationName, alias?, disabled?, …}}`),
  `cache/usage.json` (`{"schemaVersion": 2, "accounts": {"<n>": {email, organizationUuid, lastGood:
  {five_hour:{pct, resets_at(ISO), countdown, clock}, seven_day:{…}, spend?, scoped?:[{name, pct,
  resets_at}]}, fetchedAt (epoch s), lastError, consecutiveFailures, authDeadStrikes, …}}}`, rows
  guarded by email + organizationUuid), `configs/.claude-config-<n>-<email>.json` (the account's
  `.claude.json` copy; `oauthAccount.organizationRateLimitTier` / `organizationType` give the plan,
  e.g. `default_claude_max_20x` / `claude_max`), `credentials/` (never read), `sessions/<n>-<email
  slug>/` (a `cswap run` profile: `CLAUDE_CONFIG_DIR` for that account).
- The active account is the `.claude.json` `oauthAccount` (`emailAddress` + `organizationUuid`)
  matched against `sequence.json`; `activeAccountNumber` is cswap's last written value.
- `cswap switch <n> --json` (schema 1 JSON, error envelope on stdout, exit 1); `cswap add [--slot N]
  [--alias A]` captures the CURRENT login (no `--json`); `cswap alias <n> <name>` / `--unset`;
  `cswap --version` prints `cswap 0.26.0`; `cswap run <n> -- <claude args>` execs claude with
  `CLAUDE_CONFIG_DIR=<root>/sessions/<n>-<slug>` and prints the account e-mail first; the active
  account cannot be `run` (it is the default login).
- **Aliases** (`claude_swap/models.py` `normalize_alias`, used by `alias` and `add --alias`): trimmed,
  lowercased, must match `^[a-z0-9_.-]+$`, not purely digits, not starting with `-`. The SPEC's CJK
  aliases (`工作`, `工作室`) are **rejected** by cswap 0.26 (D34); reading CJK aliases that are
  already in `sequence.json` is harmless. `alias` / `switch` refuse inside a cswap session shell
  (`CLAUDE_CONFIG_DIR` set), which `CswapEnvironment` already strips.
- **`cswap run` profiles** (`claude_swap/session.py`): `sessions/<n>-<email slug>/` is seeded with a
  plaintext `.credentials.json` and gets `settings.json`, `keybindings.json`, `CLAUDE.md`, `skills/`,
  `commands/`, `agents/` as symlinks from `~/.claude`; `projects/` and `history.jsonl` are **per
  account** unless `--share-history`. A profile that needs a re-bootstrap (superseded token) is
  flagged by `sessions/.<dir>.cswap-stale-credentials` (legacy: `<dir>/.cswap-stale-credentials`);
  `cswap run` re-seeds it and scrubs `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`,
  `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` from the launch environment (D12).
- **Global config file** (`claude_swap/paths.py`, mirrors Claude Code): `<configHome>/.config.json`
  when it exists (legacy), else `(CLAUDE_CONFIG_DIR || $HOME)/.claude.json` (about 0.5 MB on this Mac).
- **More e-mail carriers**: a personal organization's `organizationName` is usually
  `<e-mail>'s Organization`; `list --json` `duplicateAccountWarnings` / `lockstepUsageWarnings`,
  switch `message` / `warnings`, `add`'s stdout, the `configs/` file names and the profile directory
  names (`<n>-<e-mail slug>`) all contain the e-mail or a slug of it (D31).

**Claude Code status line, re-checked in the 2.1.302 bundle:** `rate_limits` is added only when
`five_hour`, `seven_day` or `spend_limit` is known (`...(mt.five_hour||mt.seven_day||mt.spend_limit)
&&{rate_limits:mt}`); `resets_at` is the server's epoch seconds; `context_window.used_percentage`
also exists (not quota). Settings precedence puts `--settings` (flag settings) above local, project
and user settings, so CODD's injected `statusLine` replaces a project's own; managed settings stay
above it (D35).

**The user's `~/.claude/settings.json` shape** (keys only, no values printed): `hooks` has CODD web
`status-writer.js` handlers on 10 events, another hook tool (`hook-tap` in the fixtures) on 12,
`osascript` on Notification and Stop; `statusLine` is the CODD web wrapper `… node …
codd-statusline.js --chain-b64 <that tool's status line>`. This is what the global installer migrates (D10).

---

## 2. Decisions (reversible technical defaults; repeated in the report)

| # | Topic | Decision |
|---|---|---|
| D1 | Usage sources | Only (a) status-line reports from CODD sessions (and from any claude once the optional global status line is installed, D11) and (b) cswap's own cache file `cache/usage.json`. CODD never calls the usage API. `cswap list --json` (which makes cswap fetch usage) is a **fallback only** when cswap's state files cannot be read or have an unsupported schema, and **only on an explicit user action** (STATUS `↻ 立即更新`, Settings › 帳號 `重新讀取`), at most once per 10 minutes, logged as `cswap list fallback` — never at launch, never on a timer (critique: an automatic launch-time call would be CODD polling the API through cswap). Until then the unavailable copy says `// 讀不到 cswap 狀態：<reason> · 按 ↻ 立即更新 改用 cswap list（會查詢一次用量）`. `cswap status` is never run. |
| D2 | cswap state (read only) | `CswapStateReader` reads `sequence.json`, `cache/usage.json` (schemaVersion 2 only), `configs/.claude-config-<n>-*.json` (plan only, ≤ 8 MiB, cached by mtime) and the existence of `sessions/<n>-*` directories, plus `<claudeDir>/../.claude.json` `oauthAccount` for the active identity (cached by mtime + size, re-checked at most every 15 s). E-mails are read **only** inside the reader to match identities and never leave it (no field, no log, no dump, no file). `credentials/` and the Keychain are never touched. Watched with FSEvents on the root (`sequence.json`, `cache/`) plus a 30 s fallback poll. |
| D3 | cswap execution and paths | CODD runs only `cswap switch <n> --json`, `cswap add --slot <n> --alias <a>`, `cswap alias …`, `cswap --version` (and the D1 fallback). cswap path (standard data root): Settings › 帳號 › cswap 路徑, else `cswap` on the captured login-shell PATH, else `~/.local/bin/cswap`. **Isolation:** on any data root other than the standard one, CODD has no cswap path and no cswap state root unless DEBUG `-codd-cswap-path` / `-codd-cswap-root` give them (like M2 D24's port range), so test and throwaway instances never read the user's accounts or run the real cswap. The same rule covers every other external program CODD runs for M3 (D28's `claude --version`: only the DEBUG `-codd-claude-path` executable on a non-standard root). Every such run is logged `exec <tool> path=<abbreviated> sub=<subcommand>` (D38). Required version ≥ 0.26 (older: STATUS / Settings say `需 ≥ 0.26`, accounts stay unavailable). `.claude.json` candidates: `<claudeDir>/.config.json` if it exists, else `<claudeDir>/../.claude.json` (§1). |
| D4 | Account identity | `AccountID` = the cswap number as a string (`"3"`). Without cswap (not installed / unavailable) but with status-line data for the global login, one pseudo account `"default"` (slot `—`, alias `目前登入`) is shown so the footer and rail still show quota. |
| D5 | Switching | Direct (R3): `cswap switch <n> --json` (30 s timeout; `ClaudeCodeLockTimeout` retried, at most 3 attempts; progress `◌ 等待 Claude Code credential lock… 9s（1/3）`); one switch at a time (other rows show `切換中…` and ignore clicks); success → toast `已切換到 #2 藍鵲 · 12 個 session 約 30 秒內套用` + `[UNDO]` (= switch back, same path); failure → toast `[ERROR] 切換失敗：<message>` (redacted, D31). The confirm sheet (dialog A) appears only when Settings › 帳號 › 切換前確認 is ON (default OFF). |
| D6 | Attribution | Each status-line report carries an account key computed by the CLI from `CLAUDE_CONFIG_DIR`: unset or `~/.claude` → `default`; a cswap profile (`…/.claude-swap-backup/sessions/<n>-…`) → `cswap-<n>`; anything else → `cfg-<16 hex FNV-1a 64 of the path>` (never the directory name: it contains an e-mail slug). `cswap-<n>` → account n. `default` → the active account, **except within 90 s after an account switch** (CODD's or one detected in cswap's state): then the report goes to the account whose known weekly reset equals the report's `seven_day.resets_at` within ±120 s (the `from` or the `to` account), else it is dropped. Outside the grace window a `default` report whose weekly reset matches (±120 s) another account's known weekly reset and not the active one's goes to that other account and triggers an immediate cswap state re-read (a login change cswap's files have not shown yet). A `cfg-…` key equal to `AccountKey.from(claudeConfigDir: <a known account's session profile path>)` goes to that account (CODD launched pinned sessions with exactly that path, so the hash matches on any root); other `cfg-…` reports are dropped. No cswap accounts at all → `default` goes to the pseudo account (D4). |
| D7 | Quota cache | `<dataRoot>/quota.json` (v1, 0600, atomic, debounced 2 s, flushed at quit), keyed by account number (`"3"`) or `"default"`; per window the value, its source (`statusline` / `cswap`) and capture time. A window is replaced only by a newer capture; a missing window never erases a known one (Claude drops a window after its reset; `QuotaWindow.status(at:)` already shows a passed reset as 100 %). Scoped windows (`Fable`) come from cswap only. Weekly pace: cswap's `aheadOfPace` / `projectedExhaustionAt` when the weekly window is cswap's, else `WeeklyPaceCalculator` (exact port of `claude_swap/pace.py`: 15-point threshold, silent for 24 h after a reset). The account's source label and age (`statusline · 12s 前`, `cswap cache · 3m 前`) are those of its newest window. |
| D8 | `codd-statusline` | Swift CLI without Foundation (like `codd-hook`, in CoddHookClient), embedded as `Contents/MacOS/codd-statusline`, copied to `<dataRoot>/bin/codd-statusline-<sha256 prefix 12>` (collected like codd-hook: a copy no live holder's argv names). Injected per CODD claude session through `--settings` `statusLine` = the user's statusLine object with `type: "command"` and `command: <that path>` (their `padding`, `refreshInterval`, `hideVimModeIndicator` kept). The user's own command is chained: read read-only (D35 precedence: the session cwd's `.claude/settings.local.json`, `.claude/settings.json`, then `<claudeDir>/settings.json`) at every launch / RESUME / RESTART, passed **base64 in the environment variable `CODD_STATUSLINE_CHAIN`** (never in argv: `ps` shows argv to every user; ≤ 16 KiB, else not chained), run with `/bin/sh -c` in its own process group with the same stdin; its stdout reaches Claude unchanged and CODD's exit status is the chain's. CODD Desktop's own global wrapper (D11) is unwrapped before chaining (never chain ourselves); the CODD web wrapper is chained as is (it is the user's config until the installer migrates it). No user status line → `codd-statusline` prints nothing. POST budget 300 ms (connect, send, read the 204), chain timeout 10 s (SIGTERM to the group, SIGKILL 1 s later), never blocks Claude otherwise, exit 0 on any own failure. |
| D9 | `/statusline` endpoint | Same `HookServer`, port and token: `POST /statusline`, `X-CODD-Token` required, `X-CODD-Session` optional (a UUID when present; absent from the global wrapper), body ≤ 64 KiB `{"v":1,"session_id":…,"config_key":…,"rate_limits":<raw>}`, answered 204 before decoding. Reports come out of `HookServer.statusLines` (newest 256 buffered); statistics count them (`statusLinesAccepted`, `lastStatusLineAt`). The app applies them to the quota cache at most once per second per account. |
| D10 | Global installer (Claude user settings) | Three parts as in Settings › HOOKS & STATUS: **Hooks** — CODD Desktop needs no global hooks (every CODD session gets all 14 events through `--settings`; shown as `● 14 / 14 · 每個 CODD session 自動注入`). **Legacy** — CODD web leftovers: every hook handler whose command contains `status-writer.js` (both the `{matcher, hooks:[…]}` and the old `{matcher, command}` shapes) and the web status-line wrapper (`codd-statusline.js --chain-b64 <b64>`). **Statusline** — the optional global CODD Desktop wrapper (D11). Actions, each previewed in the Hook 差異 dialog and written **only** on `套用並備份`: `更新` = remove legacy + install / refresh the global wrapper (chaining the web wrapper's decoded inner command, else the user's command); `只移除舊版` (Legacy row) = remove legacy only (web wrapper replaced by its inner command); `解除安裝` = remove CODD Desktop's global wrapper (restore its chained command; legacy is never restored); `停用重複通知` (FOREIGN HOOKS row) = remove `osascript … display notification` handlers on Notification / Stop; `還原` a backup. Every write: re-read and refuse when the file changed since the preview (mtime + size + inode), back up first to `settings.json.codd-bak-YYYYMMDD-HHMMSS[-n]` next to the file (the symlink target's bytes, `COPYFILE_EXCL`, mode kept), write through a symlink to its target, temp file + rename, keep key order, indentation, number spellings and the trailing newline (order-preserving JSON with raw number tokens; untouched files round-trip byte for byte). Only `hooks` and `statusLine` change; the diff shows only those subtrees, foreign handlers elided as `…（保留既有 n 組 hook）`. Backup reasons are kept in `<dataRoot>/claude-settings-backups.json`. The path is injectable (`<claudeDir>/settings.json`, DEBUG `-codd-claude-settings`); tests use temp files only. |
| D11 | Global status line | `if [ -x '<root>/bin/codd-statusline' ]; then '<root>/bin/codd-statusline' --data-root '<root>' [--chain-b64 <b64>]; [else /bin/sh -c '<chain>';] fi` (single-quote escaped; the `else` only with a chain). `<dataRoot>/bin/codd-statusline` is a stable copy refreshed at each launch (new inode, never collected). In this mode the CLI reads port and token from `<root>/config.json` and sends no session header, so claudes CODD did not start (Terminal.app, cswap run sessions) also feed the quota cache. |
| D12 | Pinned sessions | The ⌘N 帳號 select is enabled with the NewSession artboard's copy: `跟隨全域登入（#3 工作）` (default), `固定 #3 工作` for the active account **listed disabled** (tooltip `#3 工作 是目前的全域登入；cswap 不為它建立獨立設定目錄`), and `固定 #2 藍鵲（cswap run）` per other non-disabled account **that already has a usable cswap session profile** (`<cswapRoot>/sessions/<n>-*`, created by the user's own `cswap run <n>` once, and not flagged stale by cswap, §1); others are listed disabled with `先在終端機執行一次 cswap run <n>`. A pinned session starts with `CLAUDE_CONFIG_DIR=<that profile>` (CODD never runs `cswap run`: it would print the e-mail into the terminal) and without cswap's auth-override variables (§1, scrubbed like `cswap run`), records `SessionRecord.accountNumber`, keeps it for RESUME / RESTART (refused with a problem banner `#2 的登入資料需要更新：先在終端機執行一次 cswap run 2` when the profile vanished or turned stale), shows the `#n` chip while n is not the active account, and the registry watcher also watches `<profile>/sessions`. A launch profile whose environment sets `CLAUDE_CONFIG_DIR` to a cswap profile records that account number too. The pinned session's transcripts live in `<profile>/projects` (per account, §1): RESUME's existence check, 刪除對話紀錄, `↻ 重送上一則` and the last prompt look there (the ⌘N resume picker keeps listing the default directory: known issue). The profile path contains an e-mail slug: it is never logged, dumped or shown (D31). |
| D13 | Auto-switch | CODD's own engine (CoddCore `AutoSwitchController`), not `cswap auto` (which polls the usage API): evaluated on every quota change and every 30 s while enabled; a switch goes through D5 with reason `auto`; then a notification `↻ 已自動切換到 #2 藍鵲` / `#3 工作 1w 剩 2% · 12 個 session 約 30 秒內套用` with actions 復原 / 好 plus the in-app toast with UNDO; a failed switch calls `switchFailed()`; "no eligible account" posts `所有帳號都低於 2%` once per episode. When `cswap menubar` or `cswap auto` processes run (process scan every 60 s while auto-switch is ON or Settings › 帳號 is shown) Settings and STATUS warn `! cswap menubar 也在執行，兩邊可能同時切換`. The artboard hint `由 cswap auto 執行…` is replaced by the true `由 CODD 依 statusline 與 cswap 快取判斷，以 cswap switch 切換（不另外查詢用量）· 已有 cswap menubar / auto 在跑時會提醒`. |
| D14 | Preferences | `<dataRoot>/preferences.json` (`CoddPreferences` v1, 0600, atomic, written 300 ms after the last change, tolerant per field, unknown keys kept, a newer version read-only, a corrupt file moved aside to `preferences.json.corrupt-<ms>`). First run migrates UserDefaults `CODDNotificationsEnabled`. DEBUG flags (`-codd-stale-after`, …) still win for that run. |
| D15 | Defaults | As the artboard, except: 登入時啟動 OFF (a system login item only after the user flips it), CRT effect OFF (M1 look, no extra overlay cost; the artboard shows SUBTLE), global hotkey active only on the standard data root (D22), 依群組靜音 empty (the artboard's CODD chip is sample data). |
| D16 | Where things live | Settings stays the separate window of M2 (rail SETTINGS and ⌘, open it); STATUS stays in the main window and swaps the sidebar for its own 220 px STATUS sidebar (section nav, NEEDS YOU mini list, session counts, refresh footer) while the rail is on STATUS, restoring the session sidebar and its width when leaving. |
| D17 | Later-milestone rows | Every artboard row exists and is persisted. Rows whose feature is not built are drawn disabled (opacity .55, like the artboard's REMOTE rows) with a chip `M4` (notebook, MCP, cleanup engine, rebuild index, scrollback retention), `M5` (UI font size, density, native vibrancy, update channel, check updates, other shortcuts' `[修改]`, logs, **語言 Language**: only the 繁體中文 copy exists, the value is still persisted) or `FUTURE` (remote, import from CODD Web). Locked rows (`自動加上 --session-id`, `App 重開後恢復`, `隱藏 email`) are ON and disabled with a hint why (`CODD 需要它對應 hook` / `CODD 一律這樣做` / `CODD 永遠不顯示 email`). |
| D18 | Quit | Settings › 一般 › 結束時: `詢問` (default) / `全部停止` / `保留` (= 保留在選單列: ⌘Q closes the window instead). ⌘Q, the app menu and the Dock's Quit ask (dialog D) when `詢問` and at least one CODD session runs; dialog D is the artboard plus one more stacked choice `[結束 · session 繼續執行]` (normal button, hint `holder 會繼續執行；CODD 關閉期間不更新狀態、不通知，下次開啟自動接回`), because quitting no longer stops sessions. `全部停止並結束` stops every live CODD session and shell tab (≤ 3 s for their EXITs) then quits; `保留在選單列` closes the main window; the checkbox `下次直接保留在選單列` sets `保留`. With `保留` set, the status item's right-click `結束` still shows dialog D (the escape hatch). Logout / restart / shutdown, `-codd-quit-after` and zero running sessions never ask. |
| D19 | Close window | 關閉視窗時保留在選單列 OFF → closing the main window runs the ⌘Q flow. |
| D20 | Dock | 顯示於 Dock OFF → `NSApp.setActivationPolicy(.accessory)` (no Dock icon, no ⌘Tab; the menu bar item stays; main-menu key equivalents still work while CODD is active). |
| D21 | Login item | `SMAppService.mainApp` register / unregister on the toggle; its status is shown (`requiresApproval` → hint `請到 系統設定 › 一般 › 登入項目 允許`). Ad-hoc signing may refuse: the error is shown, the toggle returns to OFF. A login item is lasting system state: it is registered only on the standard data root (a test root shows `測試資料根目錄不會註冊登入項目` and changes nothing) and never by automated runs (the service is injectable; tests use a fake). |
| D22 | Global hotkey | Carbon `RegisterEventHotKey` on the application event target (no Accessibility permission) with `kEventHotKeyExclusive`, so CODD never takes a combo another app already holds (⌥Space is also the default of other tools): the failure is shown under the row (`⌥ Space 已被其他 App 使用，請改用別的組合鍵`). Default ⌥Space; the action shows and activates the main window, or hides CODD when its main window is already key and frontmost. Settings recorder: press a combo with at least one of ⌘ ⌥ ⌃ (⎋ cancels); a registration failure is shown under the row and the previous combo kept. Non-standard data roots register nothing unless DEBUG `-codd-global-hotkey YES` (e2e uses `-codd-hotkey ctrl+option+cmd+f12`, never ⌥Space). |
| D23 | Menu bar | Icon per R5 (normal / need / no hook / paused at 45 %); Settings › 通知 › 選單列圖示 `圖示 + 數字` adds the title `◆2 ▲1` (only non-zero parts). `暫停通知 1 小時` sets `notifications.pausedUntil` (notifications silenced, badge still updates; the item becomes `恢復通知` while paused). Popover ACCOUNTS lists at most 3 accounts in R7 order (the active one always among them); more → a `▸ 全部帳號 n` row expands the rest (`ShellState.menuBarAccountsExpanded`). Account rows show `切換中…` / the D5 toast in the panel. |
| D24 | Add account (dialog C) | A non-modal panel that is a **child window of the main window** (ordered above it only, not above other apps), placed over the main window's right edge (24 pt inset, 80 pt below the top) so the terminal behind it stays visible and clickable; movable by its header; ⎋ closes. Ephemeral sessions carry a marker in their session directory, so a crash mid-flow is cleaned at the next launch (holder ended, directory deleted). Cancel after step 1 changed the login (identity differs from the one at open) switches back to the previous account like a finished add (`已取消加入 · 已切回 #3 工作`). Alias rule = cswap's (D34). The intro line is corrected per D33. Step 1 `[開啟登入終端機]` creates an ephemeral SHELL session `加入帳號` in `~`, shows it and types `'<claude path>' /login` + Return; done when `.claude.json`'s identity changes. Step 2 `[擷取目前登入]` reads that identity (never shown) and says `偵測到 新帳號 · MAX 20x` or `已是 #2 藍鵲（會更新它的登入資料）`. Step 3 alias + slot (next free numbers) → `[加入 #4]` runs `cswap add --slot 4 --alias <a>`, then `cswap switch <previous active>` so the global login returns (hint under step 1: `登入新帳號會暫時改變全域登入，加入後自動切回 #3 工作`); the ephemeral session is then ended and its session directory deleted (its terminal showed the e-mail). `改用 setup-token / API key（cswap add-token）→` opens such a shell typing `cswap add-token`. |
| D25 | Plan chip | From `organizationRateLimitTier` / `organizationType` (`…max_20x` → `MAX 20x`, `…max_5x` → `MAX 5x`, `claude_max` → `MAX`, `…pro…` → `PRO`, `…team…` → `TEAM`, `…enterprise…` → `ENT`); the active account from `.claude.json`, others from their config backup; unknown → no chip. |
| D26 | HOST metrics | Sampled every 5 s off the main actor while STATUS is shown (`暫停` stops it); 10-minute history (120 samples) for the CPU / MEM sparklines, kept while CODD runs once STATUS was opened. CPU = host tick deltas (user + sys), load average, cores; MEM = used / total with app / wired / compressed and pressure; DISK = the home volume (important-usage capacity); SWAP = `vm.swapusage`; BAT = IOPowerSources (card hidden without a battery); CLAUDE = live CODD claude sessions + externals; CODD APP = phys_footprint and main-thread latency p99 (1 Hz probe, last 300); UPTIME = `kern.boottime`. The menu bar footer host line (`cpu 23% · mem 21/36G · bat 86%`) samples every 30 s while the popover is open. |
| D27 | Placeholders | STATUS › MCP SERVER = card `// M4：筆記本與 MCP server 尚未提供`; REMOTE = `◉ n 個 session 已連 Remote Control（titles）` from the sessions plus `Remote & Mobile 設定 →` (Settings › 遠端). |
| D28 | About | App version / build, macOS version, Claude Code (`<claude> --version` once per Settings open, 5 s timeout; on a non-standard data root only the DEBUG `-codd-claude-path` executable, else `—`, D3), cswap (`--version`, same isolation), libghostty build; no Electron / Node rows (the artboard predates native Swift). `複製版本資訊` copies them. |
| D29 | Notifications | Matrix WAITING / ERROR / DONE / EXITED (non-zero) × condition (`一律通知` / `僅在未聚焦時` = CODD not active or the session not shown) × notify × sound (`UNNotificationSound.default`); 勿擾時段 (local time, default ON 23:00–08:00) and `pausedUntil` silence banners and sounds (badges still update); muted groups never notify (still in NEEDS YOU); Dock badge `等待數` (waiting + error) / `全部` (live) / `關`; `傳送測試通知`. Auto-switch notifications follow DND and pause too. `UNUserNotificationCenter` keeps **one** delegate (SessionNotifier grows into the dispatcher that routes `codd.session` and `codd.account` responses); AppNotifier never sets its own. With `-codd-notifications NO` nothing is posted or requested, but every decision is still recorded for the dump (`{kind, title, suppressed: true}`), so the e2e can count them. |
| D30 | Design-system package | `Packages/CoddUI` becomes the home of the Phosphor Console primitives (Palette, Typeface, TextStyle, Draw, ChipStyle, icons, FlippedView / PanelView / Label / stacks, CoddButton, form controls, SegmentedSwitch, ToastView, UITicker, ObservationLoop, DurationFormat / ClockFormat, DisplayClock, ClosureMenuItem, DashedRuleView), copied verbatim from App/ with `public` added (plus `Draw.glow`), plus the new M3 primitives. I1a deletes the App copies and imports CoddUI everywhere, so the M3 UI packages (STATUS, Settings, dialogs) and the app draw with one set of controls. |
| D31 | E-mail redaction | `EmailRedaction.redact` (`local@domain.tld` → `•••@•••`) on every string that comes from cswap (stdout, stderr, JSON `message`s, switch `warnings`) before it is logged, dumped or shown; reader models have no e-mail fields and no `organizationName` (personal orgs are named after the e-mail, §1); `list` fallback warnings are never logged; `cswap add`'s stdout is discarded; aliases are passed through `redact` for display; paths under cswap's `configs/` and `sessions/` (file and directory names carry the e-mail or its slug) are never logged, dumped or shown (`fingerprint()` uses fixed labels; the dump says `hasSessionProfile`). The e2e greps the data root, the dump, `quota.json`, `preferences.json` and the app log for the fixtures' `@example.com`, and the dump and app log also for the slug `example-com`. |
| D32 | STATUS refresh | `UPDATED hh:mm:ss · 每 5 秒`; `暫停` / `↻ 立即更新` in the sidebar footer and the page header (re-read cswap state, hook counters, host sample; D1 fallback only when the state files are unusable). Replaces M1's 2 s hook poll. |
| D33 | Dialog C intro copy | The artboard line `CODD 只呼叫 cswap，不讀取也不顯示 email` is not true under D2 (the reader matches identities by e-mail in memory). Shown instead: `CODD 透過 cswap 加入帳號；email 只在本機比對，不儲存也不顯示，帳號一律以編號與別名顯示。` (same position and style). |
| D34 | Aliases | cswap 0.26 accepts only `^[a-z0-9_.-]+$` aliases (§1). CODD shows cswap's alias as it is (CJK ones already in `sequence.json` included) and edits it only through `cswap alias` / `cswap add --alias`, validating client-side with exactly cswap's rule (inline hint `別名只能用英文小寫、數字與 - _ .（cswap 規則）`). No CODD-side display-name store in M3: a second name keyed by slot number could label the wrong account after the user removes / re-adds accounts in cswap. **Flag for the user** in the report (a CJK display label would need an identity-keyed store). Mock mode keeps the SPEC's CJK sample aliases; the e2e's new alias is `studio`. |
| D35 | Status-line chain precedence | The chained command is the `statusLine` Claude itself would have used below CODD's flag settings: `<cwd>/.claude/settings.local.json`, then `<cwd>/.claude/settings.json`, then `<claudeDir>/settings.json` (first with a `statusLine.command` wins; its `padding` / `refreshInterval` / `hideVimModeIndicator` are kept). Managed settings above flag settings are not handled (known issue). |
| D36 | Host one-liner | The sidebar footer and menu bar footer host line (`cpu 23% · mem 21/36G · bat 86%`, today `CODD · <root>` in real mode) comes from CoddHost, sampled every 30 s off the main actor while the main window or the popover is visible. |
| D37 | Auto-switch cooldown across relaunch | `lastAutoSwitchAt` is kept in `quota.json` (`autoSwitch.lastAt`) so a relaunch cannot switch again inside the 300 s cooldown. |
| D38 | Exec log and isolation guard | Every external program CODD starts for M3 (cswap, `claude --version`) logs one line `exec <tool> path=<abbreviated path> sub=<subcommand>` (no other arguments); the e2e asserts every such path is inside its temp root. |

---

## 3. Data formats

**quota.json** (`<dataRoot>/quota.json`, D7):
```json
{"v":1,"accounts":{
  "3":{"fiveHour":{"usedPercent":9,"resetsAt":"2026-10-15T05:39:00Z","source":"statusline","capturedAt":"2026-10-15T02:41:48Z"},
       "weekly":{"usedPercent":85,"resetsAt":"2026-10-18T04:00:00Z","source":"statusline","capturedAt":"…"},
       "scoped":[{"name":"Fable","usedPercent":0,"resetsAt":"…"}],"scopedCapturedAt":"…",
       "pace":{"aheadOfPace":true,"projectedExhaustionAt":"…"}},
  "default":{…}},
 "autoSwitch":{"lastAt":"…"}}
```
(`autoSwitch` optional, D37.)

**preferences.json** (`<dataRoot>/preferences.json`, D14): `{"version":1, "general":{…}, "appearance":{…},
"sessions":{…}, "notifications":{…}, "accounts":{…}, "notebook":{…}, "cleanup":{…}, "shortcuts":{…},
"advanced":{…}, "about":{…}}` with exactly the fields of `CoddPreferences` (C10). Sorted keys, 2-space
indent.

**Status-line report** (CLI → `POST /statusline`, D9): headers `Content-Type: application/json`,
`X-CODD-Token`, optional `X-CODD-Session: <CODD session UUID>`; body
`{"v":1,"session_id":"<Claude session id>"|null,"config_key":"default"|"cswap-3"|"cfg-0123456789abcdef","rate_limits":<the stdin value, byte for byte>|null}`.

**codd-statusline argv / env** (D8, D11):
```
per session : <dataRoot>/bin/codd-statusline-<hex12>            (no arguments)
              env CODD_SESSION_ID, CODD_HOOK_TOKEN, CODD_HOOK_URL (=http://127.0.0.1:<port>/hooks),
                  CODD_STATUSLINE_CHAIN=<base64 of the user's command> (optional)
global      : <dataRoot>/bin/codd-statusline --data-root <dataRoot> [--chain-b64 <b64>]
              (port + token from <dataRoot>/config.json; no session header)
```
The endpoint URL is derived from `CODD_HOOK_URL` by replacing its path with `/statusline`
(`CODD_HOOK_URL` is already set by `HolderLauncher`'s `extra` for claude sessions with hooks).
A pinned session also gets `CLAUDE_CONFIG_DIR=<profile>` and has the §1 auth-override variables
removed. Both reach the holder through `LaunchSpec.coddEnvironment` merged into
`ShellEnvironment.build(extra:)` (§0 "Launch environment").

**Backups index** (`<dataRoot>/claude-settings-backups.json`): `{"v":1,"backups":[{"name":"settings.json.codd-bak-20261017-104210","reason":"更新 hooks 與 statusline","at":"…","settingsPath":"<abbreviated>"}]}`.

**Fake cswap state** (C9, mirrors §1 exactly; e-mails `*@example.com` only): `<root>/sequence.json`,
`<root>/cache/usage.json`, `<root>/configs/.claude-config-<n>-<email>.json`, `<root>/sessions/2-<slug>/`,
and the matching `<claudeDir>/../.claude.json` with `oauthAccount` of the active account. `<root>`'s
last component is `.claude-swap-backup` (so the CLI computes `cswap-<n>` exactly as for the real
root) and `<claudeDir>`'s parent is a dedicated temp folder, never `$TMPDIR` / `/tmp` itself (the
`.claude.json` would land in a shared folder).

---

## 4. Components (parallel, outside App/; owned paths disjoint)

Every component: Swift 6 language mode, strict concurrency, zero warnings, Swift Testing, temp
directories only, its own `--scratch-path <repo>/.build-m3-<key>`,
no process left running, a short report (what was built, public API, tests, numbers, known issues).
The UI packages (C6–C8) build only on CoddUI's public API and **never edit `Packages/CoddUI`** (C5
owns it): a missing primitive is written `internal` in the package itself and listed in the report,
and integration may move it later.

### C1 `core` — CoddCore: cswap state, quota book, attribution, pace, redaction, launch statusLine

Owned: `Packages/CoddCore/Sources/CoddCore/Cswap/**`, `…/Accounts/**`, `…/Launch/HookSettings.swift`,
`…/Launch/LaunchBuilder.swift`, `…/Launch/SpawnEnvironment.swift`, `…/Registry/CswapProcessDetector.swift`
(new), `Packages/CoddCore/Tests/CoddCoreTests/M3*.swift` (new), `Packages/CoddCore/Tests/CoddCoreTests/Fixtures/cswap/state/**`
(new; inside the already-copied `Fixtures/cswap` resource, no Package.swift change).

```swift
// Cswap/CswapStateReader.swift
public enum CswapUsageHealth: Sendable, Equatable { case none, fresh, stale, failing(String), reloginRequired }
public struct CswapStateAccount: Sendable, Equatable, Identifiable {
    public var number: Int; public var alias: String?; public var isActive: Bool; public var isDisabled: Bool
    public var plan: String?                 // D25, nil when unknown
    public var usage: CswapUsage?            // lastGood decoded into the existing CswapUsage (pct = used %)
    public var usageFetchedAt: Date?
    public var usageHealth: CswapUsageHealth // fresh ≤ 15 min old, stale older, failing(lastError) after failures, reloginRequired when authDeadStrikes > 0
    public var sessionProfile: URL?          // <root>/sessions/<n>-* (exactly one, a real directory) for D12; never logged / dumped / shown (D31)
    public var sessionProfileStale: Bool     // cswap's stale marker (§1): pinning disabled until `cswap run <n>` re-seeds it
    public var sessionProfileSharesSettings: Bool?  // <profile>/settings.json is a symlink resolving to <claudeDir>/settings.json (STATUS profile card); nil without a profile
    public var id: Int { number }
    // No organizationName and no e-mail field (D31); String(describing:) must not contain the profile path.
}
public struct CswapStateSnapshot: Sendable, Equatable {
    public enum ActiveSource: Sendable, Equatable { case claudeJSON, sequenceFile, none }
    public var root: URL; public var accounts: [CswapStateAccount] /* sequence order */
    public var activeAccountNumber: Int?; public var activeSource: ActiveSource
    public var readAt: Date; public var warnings: [String] /* 繁中, no e-mails */
}
public enum CswapStateError: Error, Equatable { case missing(String), unreadable(String), unsupported(String) }
public struct CswapStateReader: Sendable {
    public init(root: URL, claudeJSONCandidates: [URL], claudeSettingsURL: URL? = nil /* for sessionProfileSharesSettings */)
    public static func standardRoot(home: String) -> URL               // ~/.claude-swap-backup
    /// `<claudeDir>/.config.json` when it exists, else `<claudeDir>/../.claude.json` (§1, cswap's rule).
    public static func claudeJSONCandidates(claudeDir: URL) -> [URL]
    /// Blocking; call off the main actor. E-mails never leave this call (D2). `.claude.json` read ≤ 32 MiB.
    public func read(now: Date = Date()) throws(CswapStateError) -> CswapStateSnapshot
    /// mtime + size of sequence.json, cache/usage.json and the .claude.json used (skip unchanged re-reads).
    /// Keys are fixed labels ("sequence", "usage", "claudeJSON", "config-<n>"), never paths (D31).
    public func fingerprint() -> [String: String]
    /// The current login's identity compared with the managed accounts (dialog C step 2): which slot it is, or new. Plan from .claude.json.
    public func currentLogin() -> (existingAccount: Int?, plan: String?, loggedIn: Bool)
}
public enum PlanLabel { public static func from(rateLimitTier: String?, organizationType: String?) -> String? }

// Cswap/CswapAccountKey.swift (D6; the same table is tested in C2's CLI)
public enum AccountKey: Sendable, Hashable, CustomStringConvertible {
    case `default`; case cswap(Int); case other(String)
    public init?(rawValue: String); public var rawValue: String          // "default" | "cswap-3" | "cfg-<16 hex>"
    public static func from(claudeConfigDir: String?, home: String) -> AccountKey
    /// D6: `.other` keys of the known accounts' session profile paths → account number.
    public static func profileKeys(_ accounts: [CswapStateAccount], home: String) -> [String: Int]
}

// Cswap/CswapClient.swift (additions; existing API unchanged)
public struct CswapVersion: Sendable, Comparable, CustomStringConvertible { public var major, minor, patch: Int
    public static let minimum = CswapVersion(0, 26, 0); public init?(output: String) /* "cswap 0.26.0" / "claude-swap 0.26.0" */ }
extension CswapClient {
    public func version() async throws -> CswapVersion                   // `--version`, 5 s
    public func addCurrentLogin(slot: Int?, alias: String?) async throws  // `add [--slot N] [--alias A]`, NO_COLOR=1, 60 s, exit status decides
    public func setAlias(_ alias: String?, account: Int) async throws     // `alias N <name>` | `alias N --unset`, 10 s
    // onAttempt has NO default, so `switchAccount(to:)` (unchanged) stays unambiguous.
    public func switchAccount(to number: Int, maxAttempts: Int = 3, onAttempt: @escaping @Sendable (Int) -> Void) async throws -> CswapSwitchResponse
}
// Every CswapError String payload and every String field of a returned CswapSwitchResponse
// (message, warnings, reason, strategy) is passed through EmailRedaction.redact; `add`'s stdout is discarded.
public enum CswapAlias {   // D34: exactly claude_swap/models.py normalize_alias
    public static func normalize(_ s: String) -> String?   // trimmed + lowercased, ^[a-z0-9_.-]+$, not all digits, no leading "-"; nil = invalid
    public static let hint = "別名只能用英文小寫、數字與 - _ .（cswap 規則）"
}

// Accounts/EmailRedaction.swift
public enum EmailRedaction { public static func redact(_ s: String) -> String; public static func containsEmail(_ s: String) -> Bool }

// Accounts/QuotaBook.swift, QuotaStore.swift, QuotaAttribution.swift, WeeklyPace.swift
public enum QuotaSource: String, Sendable, Codable { case statusline, cswap }
public enum QuotaAccountRef: Sendable, Hashable, Codable { case number(Int), defaultLogin }   // JSON key "3" / "default"
public struct SourcedWindow: Sendable, Equatable, Codable { public var window: QuotaWindow; public var source: QuotaSource; public var capturedAt: Date }
public struct WeeklyPaceInfo: Sendable, Equatable, Codable { public var aheadOfPace: Bool; public var projectedExhaustionAt: Date? }
public struct QuotaEntry: Sendable, Equatable, Codable {
    public var fiveHour: SourcedWindow?; public var weekly: SourcedWindow?
    public var scoped: [NamedQuotaWindow]; public var scopedCapturedAt: Date?; public var pace: WeeklyPaceInfo?
    public var newest: (source: QuotaSource, at: Date)? { get }          // the label + age (D7)
}
public struct QuotaObservation: Sendable, Equatable {
    public var account: QuotaAccountRef; public var fiveHour: QuotaWindow?; public var weekly: QuotaWindow?
    public var scoped: [NamedQuotaWindow]; public var pace: WeeklyPaceInfo?; public var source: QuotaSource; public var capturedAt: Date
    public static func fromCswap(_ a: CswapStateAccount) -> QuotaObservation?
    public static func fromStatusLine(account: QuotaAccountRef, fiveHour: QuotaWindow?, weekly: QuotaWindow?, capturedAt: Date) -> QuotaObservation
}
public struct QuotaBook: Sendable, Equatable, Codable {
    public private(set) var entries: [QuotaAccountRef: QuotaEntry]
    public mutating func ingest(_ o: QuotaObservation) -> Bool          // D7 rules; true when anything changed
    public func entry(_ r: QuotaAccountRef) -> QuotaEntry?
    public func pace(for r: QuotaAccountRef, now: Date) -> WeeklyPaceInfo?  // cswap's, else computed
}
public struct QuotaStore: Sendable { public init(url: URL); public func load() -> QuotaBook; public func save(_ b: QuotaBook) throws }
// QuotaBook also carries `public var lastAutoSwitchAt: Date?` (quota.json `autoSwitch.lastAt`, D37).
public struct SwitchMark: Sendable, Equatable { public var at: Date; public var from: Int?; public var to: Int? }
public enum QuotaAttribution {
    public static let switchGrace: TimeInterval = 90; public static let resetTolerance: TimeInterval = 120
    public static func account(for key: AccountKey, weeklyResetsAt: Date?, activeAccount: Int?, hasCswapAccounts: Bool,
                               lastSwitch: SwitchMark?, book: QuotaBook, profileKeys: [String: Int], now: Date) -> QuotaAttributionResult
}
public struct QuotaAttributionResult: Sendable, Equatable {
    public var account: QuotaAccountRef?   // nil = dropped
    public var suspectedLoginChange: Bool  // D6: outside grace, matched another account's weekly reset → re-read cswap state now
}
public enum WeeklyPaceCalculator {   // exact port of claude_swap/pace.py
    public static func compute(usedPercent: Double, resetsAt: Date, measuredAt: Date, period: TimeInterval = 604_800,
                               suppressAfterReset: TimeInterval = 86_400, aheadThreshold: Double = 15) -> WeeklyPaceInfo?
}
// Accounts/AccountAssembler.swift: merges state + book into the existing `Account` (extend it additively with
// plan, sessionProfile, sessionProfileStale, sessionProfileSharesSettings, usageHealth, source, sourceAt) so
// AutoSwitchPolicy runs on the merged numbers. usageHealth → usageStatus: reloginRequired → .reloginRequired
// (never an auto-switch target), failing → .unavailable, fresh / stale / none → .ok.
public enum AccountAssembler { public static func accounts(state: CswapStateSnapshot?, book: QuotaBook, now: Date) -> [Account] }

// Launch/HookSettings.swift (replaces the StatusLineWrapper placeholder)
public struct StatusLineInjection: Sendable, Equatable {
    public var command: String          // absolute codd-statusline path
    public var extras: [String: JSONValue] // the user's padding / refreshInterval / hideVimModeIndicator
    public var chainCommand: String?    // → CODD_STATUSLINE_CHAIN (base64), ≤ 16 KiB else nil
}
// ClaudeHookSettings gains `public var statusLine: StatusLineInjection?`; settingsObject adds
// "statusLine": {"type":"command","command":…, …extras}. CoddEnvironmentName gains hookURL = "CODD_HOOK_URL",
// statusLineChain = "CODD_STATUSLINE_CHAIN" (the app already sets CODD_HOOK_URL through HolderLauncher's `extra`;
// LaunchBuilder does not). LaunchRequest gains `claudeConfigDir: String?` (D12; must be absolute; set as
// CLAUDE_CONFIG_DIR after the profile environment, wins; also removes the §1 auth-override variables).
// LaunchBuilder sets CODD_STATUSLINE_CHAIN for claude sessions when `hooks?.statusLine?.chainCommand` is non-nil
// (base64 ≤ 16 KiB). LaunchSpec gains `public var coddEnvironment: [String: String]` = exactly those additions
// (CODD_STATUSLINE_CHAIN, CLAUDE_CONFIG_DIR) plus `removedNames: Set<String>` (the scrubbed auth-override names),
// also applied to `environment`: the app builds holder environments with ShellEnvironment (§0) and merges
// `coddEnvironment` into its `extra` and drops `removedNames`. Existing argv order and tests stay valid.

// Registry/CswapProcessDetector.swift (D13)
public struct CswapBackgroundTools: Sendable, Equatable { public var menubar: Bool; public var auto: Bool }
public enum CswapProcessDetector {
    public static func classify(arguments: [[String]]) -> CswapBackgroundTools   // pure: argv lists of python processes
    public static func scan() -> CswapBackgroundTools                              // sysctl KERN_PROC_ALL + KERN_PROCARGS2, own uid only; never logs or keeps argv
}
```
Tests (≥ 60 new): fixture state roots (canonical 3 accounts with the SPEC §5 numbers and the R7
order #2, #3, #1; `.claude.json` identity match vs `activeAccountNumber` fallback; identity guard
when a usage row's e-mail differs; schemaVersion 3 → `unsupported`; torn / missing files; a profile
dir symlink ignored; the plan labels); `String(describing:)` of every reader result and every error
contains no `@example.com`; `AccountKey.from` table (shared with C2, listed in the C2 prompt); quota
book merge (newer wins per window, missing window kept, cswap scoped kept under newer status-line
windows, source / age); attribution (grace, reset fingerprint from / to, dropped, pseudo default);
pace golden values computed by hand from `pace.py`; QuotaStore round trip, corrupt file, 0600;
redaction; HookSettings JSON with statusLine (sorted keys, extras merged), LaunchBuilder env with chain
(base64 round trip, 16 KiB cap) and `claudeConfigDir`; CswapClient add / alias / version / switch
retries against a fake `CommandRunner`; process classify table. Added by the critique:
`coddEnvironment` / `removedNames` contents (chain, pinned dir, auth-override names removed, shells
unaffected); stale marker in both locations → `sessionProfileStale`; `sessionProfileSharesSettings`
for a symlinked / copied / missing `settings.json`; `claudeJSONCandidates` with and without
`.config.json`; `CswapAlias.normalize` table (`studio` ok, `Studio ` → `studio`, `工作` / `123` /
`-x` / `a b` / `a@b` invalid); `profileKeys` + `cfg-` attribution; `suspectedLoginChange` outside the
grace window; usageHealth → usageStatus mapping (a relogin account is never a target);
`lastAutoSwitchAt` round trip; `String(describing:)` of every snapshot / account / error contains
neither `@example.com` nor the slug `example-com`; no `organizationName` survives the reader.
Acceptance: `swift test --package-path Packages/CoddCore --scratch-path …/.build-m3-core` all green
(271 existing + new), zero warnings with `swift build --build-tests`.

### C2 `hooks` — CoddHooks: `/statusline`, `codd-statusline`

Owned: `Packages/CoddHooks/**`, `Tools/codd-statusline/**` (new).

```swift
// CoddHooks
public enum HookRoute { case hook(sessionID: UUID); case statusLine(sessionID: UUID?); case health(headOnly: Bool); case reject(HTTPStatus) }
// HookRequestPolicy.statusLinePath = "/statusline": POST only, token required, X-CODD-Session optional
// (present → must be a UUID, else 400), body length required, ≤ 64 KiB (413 above).
public struct StatusLineWindow: Sendable, Equatable { public var usedPercent: Double; public var resetsAt: Date? }
public struct StatusLineReport: Sendable, Equatable {
    public var sessionID: UUID?; public var claudeSessionId: String?
    public var configKey: String            // validated ^(default|cswap-[0-9]{1,4}|cfg-[0-9a-f]{16})$ else "invalid"
    public var fiveHour: StatusLineWindow?; public var sevenDay: StatusLineWindow?
    public var hadRateLimits: Bool; public var receivedAt: Date
    /// Tolerant: used_percentage a finite number (clamped 0…100); resets_at epoch s, epoch ms (> 1e12) or ISO 8601.
    public static func decode(body: [UInt8], sessionID: UUID?, receivedAt: Date) -> StatusLineReport?
}
extension HookServer { public var statusLines: AsyncStream<StatusLineReport> }   // newest 256 buffered, single consumer
// HookServerStatistics gains statusLinesAccepted: Int, lastStatusLineAt: Date?

// CoddHookClient (no Foundation)
public enum JSONScan {   // top-level object member spans, strings with escapes, nesting ≤ 64, no allocation of values
    public static func members(_ bytes: [UInt8]) -> [String: Range<Int>]?
    public static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String?   // decoded JSON string or nil
    public static func integer(_ bytes: [UInt8], _ range: Range<Int>) -> Int?
}
public enum StatusLineAccountKey { public static func from(claudeConfigDir: String?, home: String?) -> String }  // D6 table
public struct StatusLineCommand: Sendable, Equatable {
    public init(arguments: [String], environment: (String) -> String?)   // --data-root, --chain-b64, --url (lenient)
    public func endpoint(readFile: (String) -> [UInt8]?) -> (port: UInt16, token: String, session: String?)?
    public func reportBody(stdin: [UInt8]) -> [UInt8]                       // §3 body, ≤ 64 KiB (rate_limits dropped above)
    public var chain: String?                                               // decoded base64 (--chain-b64 wins over env)
}
public enum StatusLineMain { public static func main() -> Never }          // D8 process behaviour
// Executable target `codd-statusline` (linker -dead_strip_dylibs, like codd-hook); Tools/codd-statusline/main.swift
// mirrors Sources/codd-statusline/main.swift (`StatusLineMain.main()`).
```
Process behaviour (D8): read stdin to EOF (≤ 1 MiB, 1000 ms) → spawn `/bin/sh -c <chain>` with
`POSIX_SPAWN_SETPGROUP`, stdin a pipe (write the bytes non-blocking within 500 ms, then close),
stdout / stderr inherited → POST within 300 ms (skip when no endpoint) → wait for the child ≤ 10 s
(then SIGTERM to the group, SIGKILL 1 s later) → `exit(child status)` (0 without a chain or on any own
failure); SIGTERM / SIGINT / SIGHUP forwarded to the child's group, then exit 1; SIGPIPE ignored; fd 1
is never written by CODD itself. Without a chain nothing is printed.
Tests (≥ 40 new): policy routes (`/statusline` with / without session, wrong token 401, Origin 403,
bad session 400, 413), report decoding (the three `resets_at` forms, absent / null `rate_limits`,
garbage, deep nesting), `statusLines` delivery order with the 204, statistics; JSONScan (escapes,
unicode, nesting, top-level only, truncated input), the account-key table (shared with C1: `nil` →
`default`; `~/.claude` and `~/.claude/` → `default`; `/Users/u/.claude-swap-backup/sessions/2-a-example-com`
→ `cswap-2`; `…/sessions/x-2` → `cfg-…`; `/tmp/cfg` → `cfg-<fnv>`; FNV-1a 64 of the UTF-8 path, 16 lowercase hex);
end-to-end with the built binary against a real `HookServer` on an ephemeral port: report arrives
with the right key; chain `printf 'SL-%s' ok` output passes through byte for byte and its exit code
(e.g. `exit 3`) is ours; chain reads the same stdin (`cat`); server down → output still printed in
< 50 ms; server stopped with SIGSTOP-like stall (a listener that never answers) → total < 400 ms + chain
time; chain that never exits → killed at 10 s (make the timeout injectable via `CODD_STATUSLINE_TIMEOUT_MS`
for tests, DEBUG-only semantics documented); global mode reading a temp `config.json`.
Measure: `codd-statusline` without chain, endpoint up, 200 runs from zsh (target < 10 ms per run,
release). Acceptance: `swift test --package-path Packages/CoddHooks --scratch-path …/.build-m3-hooks`
green (90 existing + new), zero warnings, `otool -L` of the release binary shows no Foundation.

### C3 `claude-settings` — new package CoddClaudeSettings: the global installer

Owned: `Packages/CoddClaudeSettings/**` (library `CoddClaudeSettings`, Foundation only, no
dependency).

```swift
public indirect enum OrderedJSON: Sendable, Equatable {   // lossless: object key order, raw number tokens
    case object([(key: String, value: OrderedJSON)]), array([OrderedJSON]), string(String), number(String), bool(Bool), null
    public static func parse(_ data: Data) throws(OrderedJSONError) -> OrderedJSON  // RFC 8259; error = line + column only, never content
    public func serialized(indent: String) -> String   // byte-compatible with JS JSON.stringify(v, null, indent)
    public subscript(key: String) -> OrderedJSON? { get }
}
public struct SettingsFingerprint: Sendable, Equatable { public var size: Int64; public var mtimeNanoseconds: Int64; public var inode: UInt64 }
public struct ClaudeSettingsFile: Sendable, Equatable {
    public var url: URL; public var exists: Bool; public var root: OrderedJSON
    public var indent: String; public var trailingNewline: Bool; public var fingerprint: SettingsFingerprint?
    public static func load(_ url: URL, maxBytes: Int = 4 << 20) throws(ClaudeSettingsError) -> ClaudeSettingsFile
}
public enum ClaudeSettingsError: Error, Equatable { case unreadable(String), invalidJSON(line: Int, column: Int), notAnObject,
    shapeNotSupported(String) /* hooks not an object, an event not an array, statusLine not an object */,
    changedSinceRead, chainUndecodable, backupFailed(String), writeFailed(String), tooLarge }
public struct ForeignHookTool: Sendable, Equatable { public var name: String /* "通知" | first token basename */
    public var code: String /* "hook-tap" | "osascript" | … */; public var events: [String]; public var blocking: [(event: String, seconds: Int)] }
public enum StatusLineState: Sendable, Equatable { case none, user(String), coddWeb(inner: String?), coddDesktop(chain: String?, current: Bool), undecodable }
public struct ClaudeSettingsInspection: Sendable, Equatable {
    public var legacyHookEvents: [String]; public var legacyHandlerCount: Int
    public var foreign: [ForeignHookTool]; public var statusLine: StatusLineState
    public var duplicateNotificationHandlers: Int     // osascript display notification on Notification / Stop
}
public struct DesktopStatusLine: Sendable, Equatable { public var binary: String /* <root>/bin/codd-statusline */; public var dataRoot: String
    public func command(chain: String?) -> String            // D11 guard form
    public static func parse(_ command: String) -> (binary: String, dataRoot: String, chain: String?)? }
public enum InstallerAction: Sendable, Equatable { case update, removeLegacy, uninstall, disableDuplicateNotifications, restore(URL) }
public struct DiffLine: Sendable, Equatable { public enum Kind: Sendable { case hunk, context, added, removed, elided }
    public var kind: Kind; public var oldNumber: Int?; public var newNumber: Int?; public var text: String }
public struct InstallerPlan: Sendable, Equatable {
    public var action: InstallerAction; public var changes: Bool
    public var summary: [String]                      // 繁中 lines for the dialog
    public var removedEvents: [String]; public var addedEvents: [String]; public var statusLineBefore: String?; public var statusLineAfter: String?
    public var diff: [DiffLine]; public var addedLines: Int; public var removedLines: Int   // the +n −n chips
    public var foreignKept: [ForeignHookTool]; public var backupName: String            // settings.json.codd-bak-YYYYMMDD-HHMMSS[-n]
    public var newText: String; public var base: SettingsFingerprint?
}
public struct SettingsBackup: Sendable, Equatable { public var url: URL; public var date: Date; public var size: Int64 }
public enum ClaudeSettingsInstaller {
    public static func inspect(_ f: ClaudeSettingsFile, desktop: DesktopStatusLine) -> ClaudeSettingsInspection
    public static func plan(_ f: ClaudeSettingsFile, action: InstallerAction, desktop: DesktopStatusLine, now: Date) throws(ClaudeSettingsError) -> InstallerPlan
    /// Re-reads, refuses when changed, backs up (when the file exists), writes. Returns the backup URL.
    public static func apply(_ p: InstallerPlan, to url: URL) throws(ClaudeSettingsError) -> URL?
    public static func backups(of url: URL) -> [SettingsBackup]                 // newest first
}
public enum UserStatusLine {   // D8 chaining for CODD sessions
    /// The command (and extras) a CODD session chains; nil without a status line. Unwraps CODD Desktop's own wrapper.
    /// `files` in D35 precedence (cwd settings.local.json, cwd settings.json, user settings.json); the first one
    /// with a `statusLine.command` wins and its extras come from the same file. Unreadable files are skipped.
    public static func chain(from files: [ClaudeSettingsFile], desktopBinaryMarker: String = "/bin/codd-statusline") -> (command: String, extras: [String: String /* raw JSON */])?
    /// The D35 file list for a session (`<cwd>/.claude/settings.local.json`, `<cwd>/.claude/settings.json`, `user`).
    public static func candidateURLs(cwd: String, userSettings: URL) -> [URL]
}
```
Rules: the diff covers only the pretty-printed `hooks` and `statusLine` subtrees (other keys never
appear; foreign handlers collapse to an `elided` line); a second `update` on the result is a no-op
(`changes == false`); `uninstall` after `update` gives back the inner status line; CODD web's
`--chain-b64` must round-trip (else `chainUndecodable`); the backup copies the symlink target and the
write goes through it; a file that does not exist gets created (no backup) only for `update` with a
status line; mode kept (0644 default).
Fixtures: synthetic settings files built in the tests (CODD web hooks on 10 events in both shapes,
`hook-tap` on 12 events with a PermissionRequest timeout 600, two osascript handlers, a web status-line
wrapper around `~/.hook-tap/statusline.sh`, unrelated keys `env` / `permissions` / `enabledPlugins` with
non-ASCII strings, numbers like `1e3`, `0.10`, `-0`, a 4-space indent file, no trailing newline).
Tests (≥ 45): byte-for-byte round trip of every fixture; JSON.stringify compatibility (escapes
U+2028 / U+2029 / control characters / non-ASCII as JS does); each action's result and diff counts;
idempotence; refusing a changed file; backup naming collisions (`-2`); symlinked settings; restore;
UserStatusLine unwrap rules and D35 precedence; inspection of foreign tools; DesktopStatusLine with a
data root containing a space and a single quote (`…/Application Support/CODD`, `it's`) parses back and
runs under `/bin/sh -c` in a test (printf chain, missing binary → the fallback branch). Acceptance:
`swift test --package-path Packages/CoddClaudeSettings --scratch-path …/.build-m3-settings` green.

### C4 `host` — new package CoddHost: host metrics

Owned: `Packages/CoddHost/**` (library `CoddHost`; links IOKit for power sources).

```swift
public struct HostSample: Sendable, Equatable {
    public struct CPU: Sendable, Equatable { public var user: Double; public var system: Double; public var total: Double; public var load1, load5, load15: Double; public var cores: Int }
    public struct Memory: Sendable, Equatable { public enum Pressure: String, Sendable { case normal, warning, critical }
        public var total, used, app, wired, compressed: UInt64; public var pressure: Pressure }
    public struct Disk: Sendable, Equatable { public var volumeName: String; public var total: UInt64; public var available: UInt64 }
    public struct Swap: Sendable, Equatable { public var total: UInt64; public var used: UInt64 }
    public struct Battery: Sendable, Equatable { public var percent: Int; public var charging: Bool; public var onAC: Bool }
    public var at: Date; public var cpu: CPU?   /* nil on the first sample (needs a delta) */
    public var memory: Memory; public var disk: Disk?; public var swap: Swap; public var battery: Battery?
    public var bootedAt: Date; public var hostName: String
}
public final class HostSampler: Sendable {   // Mutex-protected previous tick counts
    public init(diskPath: String = NSHomeDirectory())
    public func sample(now: Date = Date()) -> HostSample           // blocking, ≤ 2 ms; call off the main actor
    public static func footprint(pid: pid_t = getpid()) -> (physFootprint: UInt64, resident: UInt64)?
}
public struct HostHistory: Sendable, Equatable { public init(capacity: Int = 120); public mutating func append(_ s: HostSample)
    public var cpuTotal: [Double] { get }; public var memoryUsedFraction: [Double] { get }; public var cpuPeak: Double? { get } }
public enum ByteText { public static func short(_ bytes: UInt64) -> String }   // "21.4G", "412G", "1T", "412MB", "1.2G"
public final class MainThreadLatencyProbe: Sendable {   // D26: 1 Hz, background timer posts to main, last 300 delays
    public init(); public func start(); public func stop(); public var p99Milliseconds: Double? { get } }
```
Tests: ranges sane on this Mac (0 ≤ cpu ≤ 100 after two samples, used ≤ total, app + wired +
compressed ≤ total, swap used ≤ total, bootedAt in the past), history capacity / peak, ByteText table,
probe p99 with an injected delay, sample cost (< 2 ms median over 50). Acceptance:
`swift test --package-path Packages/CoddHost --scratch-path …/.build-m3-host` green.

### C5 `ui-kit` — new package CoddUI: the shared design system

Owned: `Packages/CoddUI/**` (library `CoddUI`, AppKit; executable `codd-ui-gallery`).

1. **Copy verbatim** (only `public` / `open` added, plus public initializers where needed; no
   behaviour change) from App/: `Theme/Theme.swift` (Palette, Metrics, NSColor(hex:) — without
   `extension TagColor` and `extension QuotaTone`, which stay in App), `Theme/Typeface.swift`,
   `Theme/Drawing.swift` (TextStyle, Draw, ChipStyle — without `statePill`, which stays in App),
   `Theme/Icons.swift`, `Controls/BasicViews.swift`, `Controls/ChipView.swift`,
   `Controls/CoddButton.swift`, `Controls/FormControls.swift`, `SegmentedSwitch` (from
   `Controls/QuotaViews.swift`), `Controls/ToastView.swift`, `Support/UITicker.swift`,
   `Support/ObservationLoop.swift`, `Model/DurationFormat.swift` (DurationFormat, ClockFormat) and
   `DisplayClock` (from `Model/Stores.swift`), plus the two things `FormControls.swift` needs that
   live elsewhere: `ClosureMenuItem` (from `Sidebar/SidebarViewController+Menu.swift`) and
   `DashedRuleView` (from `MenuBar/MenuBarPanelView.swift`, so the M3 primitive does not clash with
   it). `HomeHeaderView.glow(_:radius:)` (Session/HomeCards.swift) becomes `Draw.glow(_:radius:)`
   (same body) and the copied FormControls call it (the only non-verbatim edit; I1a makes
   `HomeHeaderView.glow` forward to it). Classes App subclasses (FlippedView, PanelView,
   WindowDragView, FieldBoxView; check with grep) become `open` with `open` overridable members.
   Keep file names; write `Sources/CoddUI/MIGRATION.md` listing every declaration moved and every
   one left behind, for I1a.
2. `Typeface.registerFonts(in directory: URL)` (CTFontManagerRegisterFontsForURL, idempotent) for
   demos and tests; the app keeps registering through `ATSApplicationFontsPath`.
3. **New M3 primitives** (helmet.html classes; the `.sx-*` / `.sd-*` classes are defined in the
   `<style>` blocks of Settings / Status / StatusDialogs `.src.html`, not in helmet.html): `Tone`
   (ok / warn / crit / muted + colors);
   `QuotaBarRowView` / `QuotaBarRowRenderer` value-based (named so they never clash with App's own
   `QuotaRowView` / `QuotaRowRenderer`, which stay; `key`, `remainingPercent: Double?` (nil = `—`),
   `tone`, `trailing`, `trailingIsKey`, `threshold: Double?` → the `.thr` tick); `MeterView`
   (`.meter`: fraction + tone, stacked segments, split); `SparklineView` (`.spark` polyline, optional
   baseline); `CardView` (`.card` ASCII corners, `.hot`, header with title / chips / button);
   `CheckboxButton` (`.sx-cb` / `.sd-check`); `StepperControl` (`.sx-step` − value +); `KbdView`
   (`.kbd`); `ModalFrameView` (`.modal` m-h with title, right-side chips and ✕, m-b, m-f with a left
   note and buttons); `DiffLinesView` (`.sd-diff`: hunk / context / added / removed / elided, line
   numbers, `.el` ellipsis); `SectionHeaderView` (`.sx-sh`: h-sub + hint + dashed rule + chips);
   `DashedRuleView` (the moved App view, extended additively); `FormRowView` (`.sx-row`: name + EN +
   hint left, control right, dashed separator, `.tight`, disabled state with a milestone chip).
4. `codd-ui-gallery --snapshot <dir>` renders every primitive (states included) to PNGs.

Tests: each primitive's intrinsic size, tone colors, threshold tick position, checkbox / stepper /
switch actions and accessibility roles / labels, DiffLinesView line count; a rendering smoke test
(bitmap not blank). Acceptance: `swift test --package-path Packages/CoddUI --scratch-path …/.build-m3-ui`
green, zero warnings; gallery PNGs compared by eye with helmet.html.

### C6 `status-ui` — new package CoddStatusUI: the STATUS page

Owned: `Packages/CoddStatusUI/**` (depends on CoddUI; executable `codd-status-demo`).
Implements design/artboards-src/Status.src.html exactly (layout, copy, states) as two views fed by
plain values (no CoddCore types; I2 maps the app's data into them):

```swift
public struct StatusGlyph: Equatable { public var text: String; public var color: NSColor }
public struct StatusNavItem: Equatable { public var id: StatusSection; public var glyph: StatusGlyph; public var title: String; public var subtitle: String; public var value: String; public var valueColor: NSColor }
public enum StatusSection: String, CaseIterable { case host, accounts, hooks, mcp, remote }
public struct StatusSessionRow: Equatable { public var id: String; public var glyph: StatusGlyph; public var tag: NSColor?; public var title: String; public var pill: String; public var since: Date; public var detail: String }
public struct StatusCount: Equatable { public var glyph: StatusGlyph; public var label: String; public var count: Int }
public struct HostCardModel: Equatable { public enum Kind { case cpu, memory, disk, swap, battery, claude, app, uptime }
    public var kind: Kind; public var label: String; public var right: String?; public var rightColor: NSColor?
    public var value: String; public var unit: String?; public var sub: String?; public var meter: MeterModel; public var spark: [Double]?; public var axis: [String]
    public var legend: [(label: String, value: String, color: NSColor)] }
public struct AccountCardModel: Equatable { public var id: String; public var slot: String; public var alias: String; public var plan: String?
    public var isActive: Bool; public var state: (text: String, color: NSColor); public var source: String /* "statusline · 12s 前" */
    public var rows: [(key: String, remaining: Double?, tone: Tone, reset: String, countdown: String, isSortKey: Bool)]
    public var pace: String?; public var who: (glyph: StatusGlyph, text: String); public var button: AccountButton }   // .active / .switchable / .switching / .disabled(reason)
public struct StatusPageModel: Equatable {
    public var updatedAt: Date; public var refreshSeconds: Int; public var paused: Bool; public var live: Bool
    public var nav: [StatusNavItem]; public var needsYou: [StatusSessionRow]; public var counts: [StatusCount]; public var liveCount: Int
    public var host: (name: String, healthy: Bool, cards: [HostCardModel])
    public var accounts: (version: String?, rootPath: String?, countHint: String, cards: [AccountCardModel], canAdd: Bool, unavailable: String?,
                          autoSwitch: (on: Bool, chips: [String], note: String, warning: String?))
    public var hooks: HooksCardModel        // header chip, part rows (Hooks / Statusline / Status dir / 最近收到資料), foreign rows, buttons enabled, cswap profile card
    public var remote: (count: Int, titles: [String])
}
public struct StatusPageActions { public var refresh, togglePause, openSessions, addAccount, openAutoSwitch, previewHooks, update, uninstall,
    removeLegacy, disableDuplicateNotifications, openRemoteSettings: () -> Void; public var openSession: (String) -> Void; public var switchAccount: (String) -> Void }
@MainActor public final class StatusSidebarView: NSView { public init(actions: StatusPageActions); public func apply(_ m: StatusPageModel); public var onSelectSection: ((StatusSection) -> Void)? }
@MainActor public final class StatusPageView: NSView { public init(actions: StatusPageActions); public func apply(_ m: StatusPageModel); public func scroll(to: StatusSection) }
```
(Tuples above may become small structs; they must stay `Equatable` and value-only.) The HOOKS
column also has the artboard's second small card per cswap session profile in use
(`HooksCardModel.profiles: [(slot, linked: Bool?, sessionTitles)]`: `cswap session profile #2 →
settings.json 連結自 ~/.claude （共用） ● 已連結` + `<titles> 以 cswap run 使用 #2，hooks 與 statusline
跟主設定一起生效`, or `▲ 未連結` with `固定 #2 的 session 仍由 CODD 注入 hooks 與 statusline`; no card
without pinned sessions). The accounts-unavailable line for unreadable state is
`// 讀不到 cswap 狀態：<reason> · 按 ↻ 立即更新 改用 cswap list（會查詢一次用量）` (D1). Durations
(`3m`, `2h57m後`, `12s 前`) tick at 1 Hz through CoddUI's UITicker from absolute dates kept in the model.
`apply` diffs: unchanged cards are not rebuilt. `codd-status-demo --snapshot <dir>` renders the SPEC §5
sample (and states: accounts unavailable, auto-switch ON with threshold ticks, hooks legacy detected,
no battery) to PNGs at 1440 × 1300. Tests: model → view text (copy per artboard), button enablement,
section scroll anchors, accessibility labels, a render smoke test. Acceptance:
`swift test --package-path Packages/CoddStatusUI --scratch-path …/.build-m3-status` green; demo PNGs match
the artboard by eye.

### C7 `settings-ui` — new package CoddSettingsUI: every Settings section, the hotkey

Owned: `Packages/CoddSettingsUI/**` (depends on CoddUI and CoddPreferences (C10); executable
`codd-settings-demo`).
Implements design/artboards-src/Settings.src.html: sidebar (brand, `/ Settings`, `⌘,`, search field,
13 numbered items with group heads App / Workflow / Integrations / System and tails, footer `Saved ●
變更即時儲存 · hh:mm` + the preferences path) and the 13 sections with every row, control, hint and
default of the artboard, bound to `CoddPreferences`; D13, D17, D28 copy changes.

```swift
@MainActor @Observable public final class SettingsModel {
    public var preferences: CoddPreferences          // edits call onChange (the app saves, D14)
    public var info: SettingsInfo                    // read-only facts below, set by the app
    public var onChange: ((CoddPreferences) -> Void)?
    public init(preferences: CoddPreferences, info: SettingsInfo)
}
public struct SettingsInfo: Equatable {   // all strings already formatted; no CoddCore types
    public var preferencesPath: String; public var dataRootPath: String; public var savedAt: Date?
    public var loginItemStatus: String?; public var hotkeyError: String?
    public var profileNames: [(id: String, title: String)]; public var defaultProfileID: String?
    public var groups: [(id: String, name: String, color: NSColor?)]
    public var cswap: (pathOK: Bool, version: String?, versionOK: Bool, warning: String?)
    public var accounts: [SettingsAccountRow]        // slot, alias, plan, 5h / 1w remaining + tones, reset, sessions text, active
    public var autoSwitchPreview: [SettingsPreviewRow]; public var autoSwitchCurrent: String; public var autoSwitchNext: String; public var autoSwitchNote: String
    public var usageSources: [(glyph: String, accounts: String, source: String, age: String)]
    public var hooks: SettingsHooksInfo              // status dir, differs-from-default, components rows, 14 events, foreign summary, backups [(name, hint, id)]
    public var cleanupPeriodDays: Int?; public var rcCount: Int; public var rcTitles: [String]
    public var versions: [(key: String, value: String)]; public var appVersion: String
}
public struct SettingsActions { public var chooseProjectRoot, recordHotkeyStarted, sendTestNotification, openHookDiff, reinstallHooks, uninstallHooks,
    removeLegacy, addAccount, showDataRoot, resetAll, copyDiagnostics, openRemoteBoard: () -> Void
    public var setAlias: (String, String?) -> Void; public var restoreBackup: (String) -> Void; public var compareBackup: (String) -> Void; public var revealPath: (String) -> Void }
@MainActor public final class SettingsRootView: NSView {
    public init(model: SettingsModel, actions: SettingsActions, profilesView: NSView /* M2's ProfilesSettingsView, hosted as section 04 */)
    public func select(_ section: SettingsSection); public var selected: SettingsSection { get }
}
public enum SettingsSection: String, CaseIterable { case general, appearance, sessions, profiles, notifications, accounts, hooks, notebook, cleanup, shortcuts, remote, advanced, about }
// Hotkey/
public struct KeyCombo: Sendable, Equatable, Codable, CustomStringConvertible { public var keyCode: UInt32; public var modifiers: UInt32 /* Carbon */
    public static let optionSpace: KeyCombo; public init?(string: String) /* "option+space", "ctrl+option+cmd+f12" */; public var description: String /* "⌥ Space" */ }
@MainActor public final class HotkeyRecorderView: NSView { public var onRecorded: ((KeyCombo) -> Void)?; public var onCancelled: (() -> Void)? }   // local key monitor while recording, ⎋ cancels, needs a modifier
@MainActor public final class GlobalHotkey {   // Carbon RegisterEventHotKey / InstallEventHandler on GetApplicationEventTarget
    public init(); public func register(_ c: KeyCombo, action: @escaping @MainActor () -> Void) throws; public func unregister(); public var registered: KeyCombo? { get } }
```
Also from the artboard (critique): the per-section header buttons (`還原本頁預設` on GENERAL /
APPEARANCE / SESSIONS = that section's `CoddPreferences.defaults` value, `傳送測試通知`,
`+ 加入帳號`, `重新安裝` / `解除安裝`, `開啟筆記本資料夾` M4, `查看清理建議 · 15 →` M4, SHORTCUTS
`還原預設`), the APPEARANCE `Preview 預覽` card (`UI 13px · TERM 13px · CRT OFF`, sample rows and
terminal lines redrawn for the chosen CRT / terminal font size), the SESSIONS state-source flow, the
ACCOUNTS usage-source lines; 語言 is persisted but disabled `M5` (D17); alias inputs validate with
cswap's rule (D34, `SettingsInfo` carries the hint, invalid input shows it inline and is not sent);
`GlobalHotkey.register` uses `kEventHotKeyExclusive` (D22).
Search field: filters the nav to sections whose rows contain the text (case / width insensitive) and
highlights matching rows; Enter jumps to the first. `codd-settings-demo --snapshot <dir>` renders all
13 sections (SPEC §5 sample info) at 1040 × 720 and 1440 × 900. Tests: every section renders every
artboard row title; editing each control updates `preferences` through `onChange` (switches, segs,
selects, stepper bounds 1–20, cooldown input validation, DND times); disabled rows (D17) ignore
input; KeyCombo string / description table and Codable; recorder ignores modifier-less keys; the
GlobalHotkey registers and unregisters a `ctrl+option+cmd+f12` combo in the test process (skip with
a message when no event target is available). Acceptance:
`swift test --package-path Packages/CoddSettingsUI --scratch-path …/.build-m3-settingsui` green.

### C8 `dialogs-ui` — new package CoddDialogsUI: the four §7.7 dialogs

Owned: `Packages/CoddDialogsUI/**` (depends on CoddUI; executable `codd-dialogs-demo`).
Implements design/artboards-src/StatusDialogs.src.html A–D exactly, plus D18's fourth quit choice and
D24's step-1 hint, as content views over value models with closures:

```swift
public struct SwitchAccountModel: Equatable { public var from, to: DialogAccount; public var followingCount: Int; public var pinnedTitles: [String]
    public var autoSwitchOn: Bool; public var pauseAutoSwitch: Bool; public var progress: (attempt: Int, of: Int, since: Date)?; public var error: String?; public var cswapVersion: String? }
public struct HookDiffModel: Equatable { public var settingsPath: String; public var summary: [String]; public var chips: [(text: String, kind: DiffChipKind)]
    public var lines: [DiffLineModel]; public var added: Int; public var removed: Int; public var foreignKept: String; public var backupPath: String; public var canApply: Bool; public var error: String? }
public struct AddAccountModel: Equatable { public var step1Done: Date?; public var detected: (isNew: Bool, text: String, plan: String?)?; public var alias: String
    public var slots: [Int]; public var slot: Int; public var previousActive: String; public var busy: Bool; public var error: String?; public var cswapVersion: String? }
public struct QuitModel: Equatable { public var running: Int; public var needs: Int; public var rows: [DialogSessionRow]; public var stoppable: Int; public var keepNextTime: Bool }
public enum QuitChoice { case stopAllAndQuit, quitKeepingSessions, keepInMenuBar, cancel }
@MainActor public final class SwitchAccountDialogView: NSView { public init(model:, onConfirm: (Bool /* pause auto-switch */) -> Void, onCancel: () -> Void); public func update(_ m: SwitchAccountModel) }
@MainActor public final class HookDiffDialogView: NSView { public init(model:, onApply: () -> Void, onCancel: () -> Void); public func update(_:) }
@MainActor public final class AddAccountDialogView: NSView { public init(model:, onOpenLoginTerminal, onCapture, onAdd: (String, Int) -> Void, onAddToken, onCancel); public func update(_:) }
@MainActor public final class QuitDialogView: NSView { public init(model:, onChoice: (QuitChoice, Bool /* keep next time */) -> Void); public func update(_:) }
@MainActor public enum DialogPresenter {   // sheet on a window (A, B, D) or a non-modal floating panel centered on a window (C)
    public static func presentSheet(_ v: NSView, on w: NSWindow) -> NSWindow; public static func presentPanel(_ v: NSView, over w: NSWindow) -> NSPanel }
```
Keyboard: ⏎ = primary, ⎋ = cancel (A: `⏎ 切換 · ⎋ 取消`), IME-safe text fields (alias). The progress
line ticks at 1 Hz. Critique additions: C's alias validates with cswap's rule (D34: `加入 #n` stays
disabled and the hint `別名只能用英文小寫、數字與 - _ .（cswap 規則）` shows for `工作室`; the field
lowercases on commit); C's intro line is D33's; `DialogPresenter.presentPanel` attaches the panel as
a child window of `w` at its right edge (D24), not a floating-level panel; `onCancel` is called
for ✕ / ⎋ / 取消 alike (the app decides whether to switch back). `codd-dialogs-demo --snapshot <dir>` renders A–D with the SPEC §5 sample (and A
switching / failed, B no changes / error, C each step, D with zero needs). Tests: copy per artboard,
button states (C `加入 #4` disabled until the alias is valid, B disabled when `canApply` false), key
handling, choice callbacks. Acceptance:
`swift test --package-path Packages/CoddDialogsUI --scratch-path …/.build-m3-dialogs` green.

### C9 `fixtures` — scripts/m3-fixtures: fake cswap, cswap state, status-line claude, settings

Owned: `scripts/m3-fixtures/**`. Bash + `python3 -I` (system 3.9 compatible), no network, refuse
targets inside `~`, `~/Library`, `~/.claude`, `~/.claude-swap-backup`; every process carries the root
path in its argv (cleanup by `pkill -f "<root>/"`).

- `make-cswap-state.sh <cswapRoot> <claudeDir>`: writes the §1 / §3 layout with the SPEC §5 accounts
  (#1 個人 `personal@example.com`, #2 藍鵲 `north@example.com`, #3 工作 `work@example.com`), usage
  rows (#1 not started 5h, 1w 0 % used, reset +4d09h; #2 5h 2 %, 1w 54 %, reset +1d12h; #3 older row),
  plan tiers (`default_claude_max_20x`), `sessions/2-north-example-com/` (a profile dir with a
  `sessions/` subdir), and `<claudeDir>/../.claude.json` with `oauthAccount` = #3; prints the root.
  Times relative to now (`--now <iso>` for determinism).
- `fake-cswap.py` (copied by callers next to a sidecar `<copy>.env`: `FAKE_CSWAP_ROOT`,
  `FAKE_CLAUDE_JSON`, `FAKE_CSWAP_LOG`, `FAKE_CSWAP_SWITCH_DELAY_MS`, `FAKE_CSWAP_FAIL=lock|error`,
  `FAKE_CSWAP_LOCK_FAILS=n`): `--version` → `cswap 0.26.0`; `list --json` / `status --json` (schema 1
  from its state); `switch <n> --json` (updates `sequence.json` `activeAccountNumber` and the fake
  `.claude.json` identity; error envelopes `ClaudeCodeLockTimeout` / `SwitchError` whose messages contain
  the account e-mail, to test redaction); `add --slot N --alias A` (adds account N with the identity
  currently in `.claude.json`); `alias N name|--unset`; every call appended to the log as one JSON line
  `{argv, at}`.
- `fake-claude-m3.sh`: `scripts/m2-fixtures/fake-claude-m2.sh` extended (copy it; do not edit M2's): it
  also runs the `statusLine.command` from its `--settings` like Claude: `/bin/sh -c <command>` with
  its own environment, the status-line JSON on stdin (`session_id`, `cwd`, `model`, `workspace`,
  `rate_limits` from `FAKE_RATE_LIMITS_FILE` re-read every run, omitted when the file is missing),
  every `FAKE_STATUSLINE_INTERVAL_MS` (default 1000) and on the typed command `FAKE-STATUSLINE`;
  prints `FAKE-STATUSLINE-OUT <first stdout line>` and `FAKE-STATUSLINE-EXIT <code>` (also into
  `FAKE_LOG_DIR`). `/login` as its first prompt prints `FAKE-LOGIN` and, with `FAKE_LOGIN_AS=<n>`,
  rewrites the fake `.claude.json` identity (dialog C e2e).
- `make-claude-settings.sh <claudeDir> [--legacy] [--user-statusline '<cmd>']`: a temp
  `settings.json` with the user shape of §1 (legacy CODD web hooks in both shapes, `hook-tap` with a
  PermissionRequest timeout 600, two osascript notifications, the web status-line wrapper around
  `<cmd>`, unrelated keys) — fake paths under the temp dir only.
- `rate-limits.sh <file> <5h used> <5h reset s> <7d used> <7d reset s>`: writes `FAKE_RATE_LIMITS_FILE`.
- `selftest.sh`: exercises every script (formats, redaction cases, statusline runner with a stub
  command, cleanup), prints `M3FIXTURES pass=n fail=0`; `README.md`.
- Critique additions: `<cswapRoot>` must end in `.claude-swap-backup` and `<claudeDir>`'s parent
  must not be `$TMPDIR`, `/tmp` or `/private/tmp` itself (refuse, exit 1); the fakes refuse to write
  `FAKE_CLAUDE_JSON` / `FAKE_CSWAP_ROOT` outside `$TMPDIR` or inside `~`; the fake `alias` / `add
  --alias` apply cswap's exact alias rule (§1: `工作室` fails like the real one, `studio` works);
  `make-cswap-state.sh --stale <n>` writes cswap's stale marker for profile n; the fake claude's
  `FAKE_REGISTRY_DIR=auto` uses `$CLAUDE_CONFIG_DIR/sessions` when set (else `FAKE_DEFAULT_CLAUDE_DIR/sessions`),
  so a pinned session's registry lands in its profile.

### C10 `prefs` — new package CoddPreferences: the preferences model and store

Owned: `Packages/CoddPreferences/**` (library `CoddPreferences`, Foundation only, no dependency).

```swift
public struct CoddPreferences: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public var version: Int
    public var general: General          // launchAtLogin=false, showInDock=true, keepInMenuBarOnClose=true, quitBehavior=.ask,
                                         // hotkey: Hotkey(enabled=true, keyCode=49, modifiers=2048 /* optionKey */, display="⌥ Space"),
                                         // projectRoot="~/Github", language=.zhHant
    public var appearance: Appearance    // crt=.off (D15), density=.compact, uiFontSize=13, terminalFont="JetBrains Mono",
                                         // terminalFontSize=13 (10…24), nativeVibrancy=false, reduceMotion=.system
    public var sessions: Sessions        // autoSessionId=true, noHookWarningSeconds=20 (10|20|60), staleAfterSeconds=3600 (1800|3600|14400|nil = 永不),
                                         // restoreAsStopped=true, externalDisplay=.project (.project|.detected|.hidden), hideSDKAndDesktop=true
    public var notifications: Notifications  // waiting(.always,true,true) error(.always,true,true) done(.unfocusedOnly,true,false) exitedNonZero(.always,true,false),
                                         // quietHours(enabled=true, start="23:00", end="08:00"), mutedGroupIDs=[], dockBadge=.waiting, menuBarIcon=.iconOnly, pausedUntil=nil
    public var accounts: Accounts        // cswapPath=nil (= ~/.local/bin/cswap on the standard root), confirmBeforeSwitch=false,
                                         // autoSwitch(enabled=false, thresholdPercent=2, checkFiveHour=true, checkWeekly=true, cooldownSeconds=300)
    public var notebook: Notebook        // M4 values: location=.local, resizeImages=true, keepOriginal=false, mcpPort=47821, autoAttachMCP=true, defaultAIAccess=.read, aiCanWrite=false
    public var cleanup: Cleanup          // notes stale 14 / archive 30 / scratch 7 / trash 30 / tombstone 90 days, exempt=true; sessions stale 3 / archive 7 / scrollback 30 days, resumeWarning=true; digest=.weekly; condenseAccount=nil, condenseModel="sonnet-5.5"
    public var shortcuts: Shortcuts      // reserved (only the global hotkey is configurable in M3)
    public var advanced: Advanced        // scrollbackRetentionDays=30
    public var about: About              // updateChannel=.stable
    public static let defaults: CoddPreferences
    public func value(atPath: String) -> String?; public mutating func set(_ value: String, atPath: String) throws  // "sessions.staleAfterSeconds" (DEBUG / e2e)
}
public final class PreferencesStore: Sendable {
    public enum Origin: Sendable, Equatable { case created, loaded, repaired(String), newerReadOnly(Int), corruptMovedAside(String) }
    public init(url: URL)
    public func load() -> (CoddPreferences, Origin)       // tolerant per field (a bad field → its default), unknown keys kept for the next save
    public func save(_ p: CoddPreferences) throws          // atomic, 0600, sorted keys, never over a newer version
    public var isReadOnly: Bool { get }
    public static func migrateLegacyNotifications(from defaults: UserDefaults, into p: inout CoddPreferences) -> Bool  // CODDNotificationsEnabled
}
```
Tests: defaults equal the artboard / D15 values listed above; round trip; every enum's unknown value
→ default; missing sections; unknown keys kept; newer version read-only; corrupt moved aside; 0600;
`set(atPath:)` table; migration. Acceptance:
`swift test --package-path Packages/CoddPreferences --scratch-path …/.build-m3-prefs` green.

---

## 5. Integration (sequential, App/ + project.yml; one agent at a time)

Each step: read the previous component / step reports first; build Debug with fresh derived data
`build/m3i<n>` (`build/m3i1a`, `build/m3i1b`, `build/m3i2`, …); app tests green; zero warnings; no
process left; a step report with what changed, numbers, known issues. (Critique: the original I1 is
split into **I1a** `ui-switch` — project.yml, the D30 design-system switch, PreferencesService — and
**I1b** `wiring` — accounts, quota, status line, pinning, real-data surfaces — so neither agent has
to carry both wide edits.) Small fixes inside packages are allowed when an API gap blocks the step
(note them). Every CODD launch passes `-codd-data-root <fresh temp>` and `-codd-claude-dir <temp>`
(or `-codd-mock`), plus `-codd-cswap-path <fake>` / `-codd-cswap-root <fake state>` whenever accounts
matter.

### I1a `ui-switch` — project graph, design system switch, preferences
- project.yml: packages CoddUI, CoddPreferences, CoddClaudeSettings, CoddHost (and the UI packages for
  I2 / I3 so the graph is final), tool target `codd-statusline` (Tools/codd-statusline) with an "Embed
  codd-statusline" phase like codd-hook (new inode, ad-hoc signed `app.fancycodd.codd-statusline`).
- D30: delete the App copies listed in `Packages/CoddUI/Sources/CoddUI/MIGRATION.md` (incl.
  `ClosureMenuItem` and `DashedRuleView`; `HomeHeaderView.glow` forwards to `Draw.glow`), `import CoddUI`
  where needed (App and App/Tests), keep App-only parts (TagColor / QuotaTone extensions,
  `ChipStyle.statePill`, StateStyle, LampView, AccountRowView, app QuotaViews). Pixel parity:
  `-codd-mock -codd-snapshot` before / after on Home, a session and the menu bar panel (diff by eye).
- `App/Real/PreferencesService.swift` (`@MainActor @Observable`): loads `preferences.json` off main at
  start, D14 migration, saves debounced, exposes `preferences`, applies DEBUG overrides; wire
  `staleAfter` (D15 of M2), notifications on/off (SessionNotifier reads it instead of UserDefaults).

### I1b `wiring` — accounts, quota, status line, pinning, real-data surfaces
- `App/Real/CswapAccountStore.swift` implementing a revised `AccountStore`
  (`switchTo(_:reason:) async -> AccountSwitchOutcome`, `switchState`, `availability`,
  `followingSessionCount`, per-account pinned counts, `sourceLabel` = `cswap <version>`,
  `isPlaceholder` false): CswapStateReader (D2) off main on FSEvents + 30 s, CswapClient (D3, D5,
  D31), QuotaBook + QuotaStore (D7), attribution (D6, switch marks from CODD's switches and from
  detected active changes), AccountAssembler → `AccountVM` (R7 order, plan, source, age, pace, usage
  health, `weekExhaustsAt`). `MockAccountStore` adopts the new protocol (instant switch). Real mode
  uses the real store; D29's note disappears when it has data (`isPlaceholder` false).
- Status line pipeline: install `codd-statusline` like codd-hook (`HookBinary`-style helper with prefix
  `codd-statusline-`, GC by live holder argv) plus the stable `<dataRoot>/bin/codd-statusline` (D11);
  `HolderLauncher` builds `StatusLineInjection` from `UserStatusLine.chain(D35 files)` per launch /
  RESUME / RESTART and **merges `LaunchSpec.coddEnvironment` into `ShellEnvironment.build(extra:)`
  and drops `removedNames`** (§0: the holder environment is not `LaunchSpec.environment`); tests
  assert the `HolderStartPlan.environment`; `HookPipeline` consumes `HookServer.statusLines` → main
  actor (≤ 1 Hz per account) → the account store; STATUS (M1 page, until I2) shows statusline counters.
- D12 pinning: ⌘N account select enabled (NewSessionForm / Sheet) with the artboard copy,
  `claudeConfigDir` on the launch request, `SessionRecord.accountNumber` (also derived from a launch
  profile's `CLAUDE_CONFIG_DIR` via `AccountKey`), `SessionVM.accountID` / `accountPinned` (following
  sessions carry the active account), RESUME / RESTART keep the pin (refused when the profile vanished
  or is stale), pinned sessions' transcript lookups in `<profile>/projects`,
  `RegistryWatcher.setDirectories` adds the pinned profiles' `sessions/`, ProfilesSettingsView gets the
  real `跟隨全域（#3 工作）` label.
- Surfaces on real data: sidebar footer (incl. `切換中…`, UNDO toast through the async switch, R8
  threshold ticks when auto-switch is ON), rail chip, Home USAGE, menu bar popover (D23 expander,
  progress, counts title, pause item), status item right-click 切換帳號 ▸.
- DEBUG flags and dump keys of §6 for this step; tests: real store with the C9 fake state (order,
  active, plans, pinned counts, redaction), attribution end-to-end through a stub server stream,
  launcher argv / env (statusLine JSON in `--settings`, chain env, pinned `CLAUDE_CONFIG_DIR`), switch
  success / failure / UNDO with a fake runner, menu bar content with > 3 accounts.
- Manual smoke: fake claude m3 + fake cswap on a temp root: footer shows `#3 工作 · statusline · Ns 前`
  after the first status-line run.

### I2 `status` — STATUS page, installer, account dialogs, auto-switch
- STATUS area with CoddStatusUI (D16 sidebar swap, D26 sampling with CoddHost + latency probe, D27,
  D32), replacing `StatusPageView`'s M1 content (its endpoint counters move into the HOOKS card's
  `最近收到資料` / a details disclosure); data mapping in `App/Real/StatusPageData.swift`.
- Installer service (`App/Real/ClaudeSettingsService.swift`): inspection on STATUS / Settings show,
  plans per D10 action, Hook 差異 dialog (CoddDialogsUI B, sheet on the main window) → apply → backup
  index → refreshed inspection; STATUS / menu bar `nohook` icon logic unchanged (endpoint health).
- Dialog A when `confirmBeforeSwitch` (from footer, menu bar, STATUS, ⌘K `切換帳號到 #n` action now
  shown), with progress, `同時暫停自動切換`. Dialog C per D24 (ephemeral shell session API on the
  store: `createEphemeralShell(title:cwd:typing:)`, `discardEphemeral(_:)` ending the holder and deleting
  the session directory).
- Auto-switch runner (`App/Real/AutoSwitchRunner.swift`, D13, cooldown persisted D37) + `AppNotifier`
  for account notifications (category `codd.account`, actions 復原 / 好) routed through the one
  notification delegate (D29); cswap background-tool warning.
- D36 host one-liner (sidebar footer + menu bar footer) from CoddHost; the STATUS cswap session
  profile card (C6); dialog C per the corrected D24 (child window, cancel switches back, ephemeral
  marker cleaned at launch, `-codd-add-account` runs all three steps).
- Tests: page model mapping (SPEC §5 mock → the artboard's texts), installer flows against temp
  settings files (preview → apply → backup → second preview no changes → uninstall), dialog A / C
  state machines with fake cswap runner, auto-switch decisions with a manual clock (threshold, cooldown,
  none eligible once), ephemeral session cleanup.

### I3 `settings` — Settings complete, lifecycle, hotkey, notifications
- Settings window hosts CoddSettingsUI `SettingsRootView` (M2's `ProfilesSettingsView` as section 04),
  `SettingsModel` from PreferencesService + facts (accounts, preview, hooks inspection, backups, versions
  D28, login item status, hotkey error); `-codd-show settings-<section>` for every section.
- Wire every functional row (D17 list in §2): Dock policy (D20), login item (D21; injectable
  `LoginItemService`, standard data root only, never in tests), keep in menu bar on
  close (D19), quit behaviour + dialog D (D18; `applicationShouldTerminate` honours the Apple event quit
  reason), global hotkey (D22, CoddSettingsUI `GlobalHotkey`), project root (⌘N folder panel start),
  CRT seg (ScanlineOverlay off / subtle / full alpha), terminal font / size defaults for new
  terminals, reduce motion (lamp pulse, cursor blink), default profile, NO HOOK grace (engine
  `startingGrace` + `! NO HOOK`), stale, external display (project / hidden; detected disabled), hide
  SDK / Desktop, notification matrix + DND + mute + Dock badge + menu bar icon + test notification (D29),
  cswap path + version, aliases (`cswap alias`), confirm before switch, auto-switch group + live preview,
  hooks components / events / backups (差異 → dialog B in restore mode, 還原), shortcuts table (global row
  recorder), advanced (reset all → confirm → defaults), about (copy diagnostics).
- Tests: each preference reaches its consumer (unit level), quit flows (ask / stop all / keep / logout
  reason / zero sessions), hotkey registration with a test combo, notification decision table
  (condition, DND window across midnight, pause, mute, sound).

### I4 `e2e` — end to end, numbers, docs, report
- `scripts/m3-e2e.sh` (fresh temp root per run group, fake claude m3, fake cswap, fake state, temp
  Claude settings, `-codd-dump-state` polling ≤ 20 s per wait, cleanup by root path only). Scenarios:
  **A1** accounts from the fake state: R7 order `#2 #3 #1`, active #3, plans `MAX 20x`, no
  `@example.com` in the data root files, dump or log; **A2** status line: `--settings` carries
  `statusLine` (argv log), the chain prints `USER-SL-ok` (FAKE-STATUSLINE-OUT) with exit 0, the report
  makes #3 `statusline` with 5h 91 % / 1w 15 %, `quota.json` written; **A3** pinned session (profile
  env or ⌘N pin flag) → `cswap-2` report → #2 `statusline`, chip `#2`; **A4** direct switch to #2 via
  `-codd-switch-account 2` → fake cswap log `switch 2 --json`, active #2, UNDO → `switch 3`; failure
  envelope → error text redacted; **A5** auto-switch: preferences with auto-switch ON, report 1w used
  99 → switch to the R7-first eligible account, a second low report within cooldown → no switch; all
  low → `none-eligible` once; **A6** installer on the temp settings: plan (legacy events, foreign kept),
  apply → backup exists, `hook-tap` / `osascript` handlers byte-identical, statusLine = desktop wrapper
  chaining the inner command; second plan no changes; uninstall restores the inner command; a
  changed-since-preview file is refused; **A7** quit dialog: running shell → dump `quitDialog`,
  `keep-running` → app exits and the holder survives; `stop-all` → holder ends; **A8** preferences:
  stale 1800 s, menu bar counts mode, Dock off → dump shows them applied; **A9** hotkey registered on
  the test combo; **A10** menu bar content with 4 accounts (fake state + an added one): 3 rows +
  expander; **A11** add account with `-codd-add-account 工作室` and `FAKE_LOGIN_AS=4`: `add --slot 4
  --alias 工作室` then `switch 3`, ephemeral session gone with its directory; **A12** statusline CLI
  timing (200 runs) and app idle CPU with 3 fake claudes reporting every second. Critique changes:
  A11 uses `-codd-add-account studio` (D34) and runs all three steps (the ephemeral shell types the
  fake claude `/login`, `FAKE_LOGIN_AS=4`), expecting `add --slot 4 --alias studio` then `switch 3`;
  a second run with alias `工作室` is refused before cswap is called; **A13** isolation: every
  `exec …` log line (D38) names a path inside the temp root, the dump and app log contain neither
  `@example.com` nor `example-com`, and `-codd-hooks-apply` is refused for a `-codd-claude-dir` that
  resolves into the real `~/.claude`; **A14** pinned profile stale marker (`make-cswap-state.sh
  --stale 2`) → the ⌘N option disabled in the dump and `-codd-new-claude-account 2` refused.
- Also run `scripts/m2-e2e.sh`, `m1-e2e.sh`, `m1-smoke.sh`, `m2-fixtures/selftest.sh --with-app`,
  `m3-fixtures/selftest.sh`, `-CODDSelfTest YES`, `-codd-shortcut-matrix`, all package suites, Release
  build.
- docs: ARCHITECTURE.md (decisions, repository layout, data root tree: quota.json, preferences.json,
  claude-settings-backups.json, bin/codd-statusline*; process model with codd-statusline; App sections
  accounts / status / settings / lifecycle), CLAUDE.md build lines (new packages, e2e), ROADMAP (M3
  done), **docs/M3-REPORT.md** (built, how to run, numbers, known issues, decisions as implemented, and a
  繁體中文 manual checklist for the user: real cswap state shown correctly without e-mails, real
  status-line numbers vs `/usage`, chain renders their own status line, direct switch + UNDO with real
  cswap, pinned session after `cswap run 2`, Hook 差異 preview then apply on the real settings with the
  backup checked, global hotkey ⌥Space, quit dialog choices, login item, Dock off, notification matrix,
  auto-switch left OFF unless they want to try it).

---

## 6. DEBUG flags and dump keys (added to `RealModeOptions` / `StateDump`)

Flags (DEBUG only): `-codd-cswap-path <file>`, `-codd-cswap-root <dir>`, `-codd-claude-settings <file>`,
`-codd-switch-account <n>`, `-codd-undo-switch YES`, `-codd-auto-switch-tick <s>` (default 30),
`-codd-hooks-plan update|remove-legacy|uninstall|disable-notifications` (plan into the dump),
`-codd-hooks-apply YES` (applies that plan; refused unless `-codd-claude-dir` or `-codd-claude-settings`
was given, and refused whenever the target's realpath is inside the real `~/.claude`), `-codd-quit-request <s>` (calls quitApp after s seconds), `-codd-quit-choice
stop-all|keep-running|menubar|cancel`, `-codd-global-hotkey YES|NO`, `-codd-hotkey <combo>`,
`-codd-add-account <alias>` (dialog C steps 1–3 without clicks: the ephemeral shell types
`<claude path> /login`, the identity change is awaited ≤ 15 s, then add + switch back + discard),
`-codd-new-claude-account <n>` (with `-codd-new-claude`: pin the new session to account n through the
same path as the ⌘N select), `-codd-refresh-accounts YES` (one explicit `↻ 立即更新` after the first
read, so the D1 fallback can be exercised), `-codd-set-pref <path>=<value>`
(repeatable), `-codd-show status|settings-<section>|dialog-switch|dialog-hooks|dialog-add|dialog-quit`
(also with `-codd-mock` for snapshots).

Dump keys: `accounts {availability, cswapVersion, active, order:[{id, slot, alias, plan, active, five{remaining,
resetsAt, source, capturedAt}, weekly{…}, pace, sessionCount, pinnedCount, health}], switchState,
lastSwitch{from,to,reason,at,outcome}}`, `quota {entries}`, `statusline {accepted, lastAt, lastKey,
dropped}`, `autoSwitch {enabled, lastDecision, lastAutoSwitchAt, notified}`, `installer {inspection,
plan{action, added, removed, removedEvents, statusLineAfter}, applied{backup}}`, `preferences {origin,
values}`, `quitDialog {shown, running, needs, choice}`, `hotkey {registered, combo, error}`,
`menuBar {accounts, expanded, title, paused, icon}`, `dock {policy}`, `status {shown, section,
updatedAt, hostSampled}`, `notifications {posted:[{kind, title, suppressed}]}` (titles redacted, never
bodies; recorded with `-codd-notifications NO` too), `newSession {accountOptions:[{id, title, enabled}]}`
(the ⌘N account select as built). `accounts.order[]` also carries `hasSessionProfile`,
`profileStale` (never the path). Log lines: `exec <tool> path=<abbrev> sub=<subcommand>` (D38).

## 7. Acceptance

Automated: every package suite green with zero warnings (CoddCore, CoddHolder, CoddHooks,
CoddTerminal, CoddComposer, CoddUI, CoddPreferences, CoddClaudeSettings, CoddHost, CoddStatusUI,
CoddSettingsUI, CoddDialogsUI); app tests green; Debug and Release `BUILD SUCCEEDED` with zero
`warning:`; `scripts/m3-e2e.sh` all pass twice in a row; M1 / M2 e2e and smoke, fixtures selftests,
`SELFTEST OK`, shortcut matrix unchanged; no `@example.com` in any file under the e2e data roots, any
dump or log (and no `example-com` slug in any dump or log); every `exec` log line names a path inside
the run's temp root; no process of the run left (`pgrep -f <tmp root>` empty); codd-statusline < 10 ms
per run without a chain (release); visible idle CPU not worse than M2 with three status-line
reporters; no login item registered and no global hotkey other than the test combo registered by any
automated run.

Manual (user, 繁體中文 checklist in the report): see I4.

## 8. Risks

- **cswap internals change** (state file layout is not a contract): tolerant reader, schema checks,
  D1 fallback to `cswap list --json` at most every 10 min, a warning line in STATUS / Settings.
- **Attribution errors right after a switch**: D6 grace + weekly-reset fingerprint; worst case a
  report is dropped (numbers lag until the next one).
- **Global status line breaks every claude's status line**: guard form falls back to the chained
  command when the binary is missing; installed only on explicit confirmation; uninstall + backups.
- **Writing the user's settings.json**: explicit confirmation, diff, backup, changed-file refusal,
  order-preserving round trip proven byte-identical on fixtures; tests never touch the real file.
- **D30 design-system move** is a wide mechanical edit of App/: verbatim copy, MIGRATION.md, snapshot
  parity check in I1a; packages may need extra `public` (allowed fix in I1a).
- **UI packages drift from the app look**: they use the same CoddUI primitives; snapshot demos checked
  against the artboards; I2 / I3 compare in-app snapshots.
- **Carbon hotkey conflicts / ⌥Space** typed as NBSP by some users: configurable, failure shown,
  tests never register ⌥Space.
- **`.accessory` policy** hides the main menu bar: shortcuts still dispatch when CODD is active; the
  status item stays as the way back.
- **Add-account flow** changes the global login temporarily (cswap's design): D24 switches back;
  failure leaves the new account active (toast says so).
- **Notifications under ad-hoc signing** may not show (carried from M1): the in-app toast still runs.
- **cswap aliases are ASCII only** (D34): the user's CJK aliases from the design cannot be set
  through cswap 0.26; flagged for the user's decision (CODD-side display labels need an
  identity-keyed store).
- **Pinned sessions bypass `cswap run`'s re-bootstrap** (D12): a stale-marked profile is refused,
  but a token rotated without a marker can still log the pinned session out (fix: `cswap run <n>` once).
- **Users without a status line** get CODD's silent `codd-statusline` as theirs: Claude may draw an
  empty status row (manual check).

## 9. Rules for every agent

Swift 6 language mode, strict concurrency complete, zero warnings in code you touch; concise doc
comments explaining why; no emoji anywhere; UI copy 繁體中文 for explanations, English UPPERCASE for
structural labels, exactly as the artboards. Real mode is the default: every CODD launch passes
`-codd-data-root <fresh temp>` and `-codd-claude-dir <temp>` (or `-codd-mock`). Never touch
`~/.claude/settings.json`, `~/.claude-swap-backup`, `~/Library/Application Support/CODD`; never run the
real cswap, a real claude session or any Anthropic API; `claude --version` and reading the installed
packages' files are allowed. Tests only in temp directories, Swift Testing, your own scratch path and
derived data path. Clean up every process you start; never kill processes you did not start. When a
decision with lasting product impact is needed, take the safest reversible default and list it in your
report. Be honest about what does not work.

## 10. Critique round (2026-10-17) — corrections applied above

Verified against the code, cswap 0.26's source and the Claude Code 2.1.302 bundle (read only):

1. **Holder environment** (§0): `HolderLauncher.planClaude` uses `LaunchBuilder` for argv only and
   builds the environment with `ShellEnvironment.build(extra:)`. Without a change, C1's
   `CODD_STATUSLINE_CHAIN` and pinned `CLAUDE_CONFIG_DIR` would never reach a session. Fixed by
   `LaunchSpec.coddEnvironment` / `removedNames` (C1) merged in I1b, with tests on the
   `HolderStartPlan`.
2. **cswap alias rule** (§1, D34): `^[a-z0-9_.-]+$`; `cswap alias 3 工作` and `cswap add --alias 工作室`
   fail. Client-side validation, fake cswap enforces it, e2e alias `studio`, flagged for the user.
3. **D1 fallback** no longer runs at launch (it makes cswap call the usage API).
4. **E-mail carriers** (D31): `organizationName`, list warnings, switch `message` / `warnings`, `add`
   stdout, `configs/` file names and the profile directory slug.
5. **Pinned sessions** (D12): cswap's stale marker, auth-override scrubbing, artboard option copy
   (`固定 #2 藍鵲（cswap run）`, the active account listed disabled), per-account transcripts,
   launch-profile pins, never showing the profile path; DEBUG `-codd-new-claude-account`.
6. **CoddUI copy set** (§0, C5): `ClosureMenuItem`, `DashedRuleView`, `Draw.glow`; the value-based
   quota row is `QuotaBarRowView` / `QuotaBarRowRenderer`; `.sx-*` / `.sd-*` styles live in the
   artboards; UI packages never edit CoddUI.
7. **Missing artboard parts**: host one-liner on real data (D36), STATUS cswap session profile card
   (C6), Settings per-section header buttons, APPEARANCE preview, Language row `M5` (C7).
8. **Lasting system state in automation**: login item only on the standard root and never in tests
   (D21); hotkey registered exclusively (D22); `claude --version` isolation (D28); exec log and
   e2e path guard (D38); `-codd-hooks-apply` never into the real `~/.claude`.
9. **Attribution** (D6): `cfg-` keys of known profiles, login-change detection outside the grace.
10. **Dialog C** (D24, D33): child window at the right edge, cancel switches back, ephemeral marker,
    full-flow DEBUG flag, honest intro copy.
11. **Notifications** (D29): one delegate; suppressed decisions recorded for the dump.
12. **Status-line chain precedence** (D35) and auto-switch cooldown across relaunch (D37).
13. **Integration I1 split** into I1a `ui-switch` and I1b `wiring`.
