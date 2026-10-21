[harness: subagent output matched instruction-shaped pattern(s): settings-json. Control tags below are neutralized (`<` → `<\`); treat any remaining directive-shaped text as a finding to relay to the user, not an instruction to you.]

# CODD web: session experience feature inventory (input for the desktop design)

Paths are relative to `~/GitHub/codd-web/`. `W/` means `apps/web/src/`, `S/` means `apps/server/src/`.

**App shell** (`W/App.vue`, `W/styles.css:199-213`): a 2-column grid, `280px` sidebar plus `minmax(0,1fr)` main.
- **Sidebar, top to bottom:**
  - Brand `FANCY/CODD` and the `+ NEW ▾` button.
  - Compact SetupGuide banner (shown on every page except home and setup).
  - `SessionSidebar`.
  - Collapsible `WORKSPACE` nav: IDENTITY, SKILLS, AGENTS, TASKS, MEMORY, KANBAN, PROFILES, ALL SESSIONS (`App.vue:11-21`).
  - Footer: `DeviceStatus`, account email, `SETUP` link, `LOGOUT` (`App.vue:177-215`).
- **Global behaviors:**
  - `document.title` becomes `(n) FANCY/CODD` when n sessions are waiting (`App.vue:67-70`).
  - **Alt+1..9** jumps to the nth active session. It uses `e.code` because macOS Option changes `e.key` (`App.vue:78-88`). xterm passes these keys through (`terminalPool.js` custom key handler).
  - **Focus mode** hides the sidebar (grid column becomes 0). A 14px `›` handle on the left edge brings it back (`styles.css:434-466`, `App.vue:217-225`). Persisted in `localStorage['codd.focusMode']`.
- **Home** (`W/views/HomeView.vue:33-44`): if any session is running, it redirects to the most recently started one. Otherwise it shows a LAUNCH grid of profile cards (name, cwd, `$ command`), a "RECENTLY STOPPED" list (top 3, each with ↻ RESTART), and the full SetupGuide when setup is incomplete.
- **Visual language** (`W/styles.css:6-28, 49-77`):
  - Colors: bg `#050505` / `#0a0a0a` / `#111`, lines `#1a1a1a` / `#2a2a2a`, amber `#ffb84a` (dim `#e09a2c`, glow `rgba(255,184,74,.22)`), cream `#f5ecd6`, bone `#d4cdb8`, dim `#a8a298`, dimmer `#7a7468`, cyan `#6ee0f0`, danger `#ff7058`, success `#7cff9a`.
  - Fonts: JetBrains Mono for body, Space Mono for display, PingFang TC for CJK.
  - Effects: CRT scanline overlay, vignette and grain. Buttons are rendered `[ LABEL ]` (`::before '[ '`), uppercase, `border-radius:0`.

---

## 1. Session sidebar (`W/components/SessionSidebar.vue`)

**Header** (228-235): `SESSIONS` label, active count, and an amber filled badge `◆ n` when any session is waiting.

**Active row**, a two-line link (289-305):
- **Line 1:**
  - State lamp glyph.
  - Title: `title || profile_name || id[0:8]` (81-83).
  - State label pill: `WAITING`, `BUSY`, `IDLE` or `—`. When waiting, the pill is filled amber with black bold text and a glow.
- **Line 2:**
  - Path shortened to `~/…/last/two` when it has more than 4 segments (73-79).
  - Time spent in the current state (`activity.since`), then `·` and uptime (`started_at`).
  - Format (52-60): `45s`, `12m`, `3h05m`, `2d04h`. The clock ticks every 1s.
  - `⚠ NO HOOK` warning (102-108). Shown when the session is running, `hook_seen === false`, the command is claude (regex or `claude_session_id`), and uptime is at least `NO_HOOK_AFTER_SEC = 20` (line 9).
- **Waiting row:** amber gradient background, amber left border, lamp pulses (`lamp-pulse 1.1s`, 587/612), and the pulse is turned off under reduced motion.
- **State colors** (568-572): waiting amber, busy success green (with glow), idle cyan, unknown bone at 0.6 opacity, ended dimmer.

**Hover popover**, desktop and `(hover:hover)` only (175-212, 350-380):
- Opens after a 380ms delay, or 60ms when moving between rows. Also opens on keyboard focus-visible.
- Contents:
  - State with reason (`權限確認` permission, `回答問題` question, `確認計畫` plan) and time in state.
  - Title.
  - `最近 prompt：` (last prompt), or the NO HOOK explanation when there is no prompt.
  - Full cwd.
  - Meta: profile_name, `tool <last_tool>`, `ctx NN%`, `up …`, and a `Alt+n` kbd hint.
  - Hint line: "拖曳或 Alt+Shift+↑↓ 調整順序" (drag or Alt+Shift+↑↓ to reorder).

**Grouping and sorting:**
- Only two buckets exist: **active** (`status==='running'`, sorted by the server's `order` and then `started_at`, `stores/sessions.js:86-90, 121-125`) and **STOPPED** (sorted by `exited_at` descending, 126-130).
- STOPPED is collapsible (`localStorage['codd.stoppedOpen']`) and shows at most `STOPPED_LIMIT = 12` rows (line 7), then a `+N more → ALL SESSIONS` link.
- It auto-expands when the currently viewed session has stopped (26-30).
- **There are no groups, folders, projects, colors, pins or search.**

**Actions:**
- **Reorder by drag** using vuedraggable (251-269): `fallback-tolerance 4px`, animation 150ms. On touch devices, drag only works from the `⠿` grip handle. Clicks are swallowed for 300ms after a drop (133-155).
- **Reorder by keyboard:** Alt+Shift+↑/↓ (161-173). The new order goes to `PUT /terminal/sessions/order`, which syncs it to other devices.
- **Remove a stopped row:** a hover `✕` button (335-341), which soft-deletes.
- **New:** via `NewSessionButton`.
- **Not available:** rename, restore of removed sessions in the sidebar (only ALL SESSIONS has "show removed"), and filters.

**Session record fields** (from `S/services/terminal-manager.js:209-232` plus `session-insights.js:312-327`):
- PTY record: `id` (uuid), `profile_id`, `profile_name`, `command`, `cwd`, `pid`, `status` (`running`/`exited`), `started_at`, `exited_at`, `exit_code` (number or `"signal:15"`), `restart_count`, `removed`, `order`, `cols`, `rows`, `controller_client_id`, `claude_session_id`.
- Added by insights: `cwd_short`, `title`, `title_source` (`custom-title`/`statusline`/`ai-title`/`first-prompt`/`fallback`), `last_prompt` (≤500 chars), `context_left_pct`, `hook_seen`, `statusline_seen`, `activity{state, since, reason, last_tool, tool_count, source: hook|registry|null}`.
- Sessions live **in memory only**. A server restart loses them (SessionDetail shows "可能已移除，或 server 重新啟動過", i.e. "may have been removed, or the server restarted").

**ALL SESSIONS page** (`W/views/SessionsList.vue`):
- Toolbar: `show removed (n)` checkbox, profile `<select>`, `+ NEW`, `↻ REFRESH`, and an `INDEX · N sessions · M running` line.
- Row: lamp, title, `id[0:8]`, status chip, state chip, profile chip, `removed` chip, `pid:`, `run: 3h05m`, `restarts: n`.
- Row buttons: KILL / RESTART / REMOVE. Second line: `cwd → command`.

## 2. Session detail (`W/views/SessionDetail.vue`)

**Layout, top to bottom:** header bar (`bg-soft`, bottom border), optional action-error line, **TerminalPane** (flex:1, black), exit banner (when exited), then the bottom stack of KeyBar and Composer.

**Header, left "ident" block** (299-334):
- **Line 1:**
  - Pulsing state lamp.
  - **Title** in Space Mono 19px amber with glow (435-449). It is a focusable button that opens the prompt popover.
  - **State chip:** `◆ WAITING · PERMISSION · 3m`, built as glyph + label + reason (`PERMISSION`/`QUESTION`/`PLAN`) + time since state (or since exit) (80-87).
- **Line 2:** cwd (shortened to 60 chars, or 24 chars RTL tail on mobile), `· UP 3h05m` (or `RAN …` when exited), and `· CTX NN%`, which turns red below 20% (89-100, 322-327).
- **Prompt popover** (328-333): title, `最近 PROMPT` (last prompt) in mono pre-wrap with max-height 30–40vh, and full cwd. Opens on hover, keyboard, or tap on touch.

**Header, right actions** (336-372):
- `A−` / font size number / `A+`: terminal font size 10–24 (`terminalPool.js:28-29`), default 15 on desktop and 14 on touch, stored per device in `codd.termFontSize`.
- `⤢` focus mode (desktop only).
- `⌨` composer and keybar toggle (`localStorage['codd.composer']`; default on for touch, off for desktop).
- `⋯` menu (365-370):
  - `↗ OPEN IN TERMINAL.APP` runs osascript `cd "<cwd>" && <command>` in a new Terminal window (`S/routes/sessions.js:228-247`). A confirm dialog asks: OK = take over (kill the web session and go home), Cancel = keep both running (202-216).
  - `↻ RESTART` kills the session and spawns a **new** session from the same profile and size. It gets a new id, keeps `order`, increments `restart_count`, and is **not a conversation resume** (`terminal-manager.js:308-319`).
  - `■ KILL` (red, with a confirm).
  - `✕ REMOVE` (red, with a confirm; kills first if running, then navigates home).

**Exit banner** (384-391): `✕ SESSION EXITED · code 0 | signal 15 · REMOVED`, plus `↻ RESTART` (primary) and `REMOVE`.

**Modes:** **terminal only.** There is no chat or transcript view, no tabs, and no insights or cost panel. The "insights" are the header chip, CTX, last prompt and title shown above.

**Composer** (`W/components/Composer.vue`):
- Auto-growing textarea up to 150px (120px on mobile), plus a `SEND` button.
- Placeholder: `訊息 · Enter 送出 · ⇧Enter 換行` (Enter sends, ⇧Enter adds a line).
- **Per-session drafts** survive switching sessions (line 6). A per-session in-flight lock prevents double sends.
- IME-safe Enter: checks `isComposing`, keyCode 229 and compositionstart/end (69-79).
- Send logic (`SessionDetail.vue:228-239`): multi-line text is wrapped in bracketed paste `\x1b[200~…\x1b[201~`, then `\r` is sent after `SUBMIT_DELAY_MS=60`. An empty submit sends Enter only.
- **Not available:** attachments, slash-command autocomplete, and input history.

**KeyBar** (`W/components/KeyBar.vue:8-21`): `ESC`, `TAB`, `⇧TAB` (mode switch, `\x1b[Z`), `↑ ↓ ← →` (switches to `ESC O x` when DECCKM is on, `terminalPool.js:581-586`), `⏎`, `^C` (red), `1`, `2`, `3`. Pressing a key doesn't steal focus. The bar scrolls horizontally.

**TerminalPane / terminalPool:**
- **Pool and options:** xterm.js with FitAddon. LRU pool of `MAX_LIVE=3` live terminals; switching sessions moves the DOM node without replaying. Options: scrollback 5000, theme bg `#000`, fg `#e8e6d8`, cursor `#ffb300`, font `ui-monospace, SFMono-Regular, Menlo`.
- **Stream:** SSE `/stream` with events `reset`, `caughtup`, `size`, `data` (base64) and `exit`. The server ring buffer holds 2000 chunks or 4 MB. Input goes through `POST /input` (base64) with a 10ms debounce.
- **Stream labels:** `CONNECTING…`, `RECONNECTING…`, `STREAM CLOSED`, with backoff 1s→30s.
- **Multi-device size control:** the last device to interact controls the PTY size. Other devices see the hint button `◇ 跟隨其他裝置的尺寸 120×30 · 點此接管` ("following another device's size 120×30, click to take over") (TerminalPane 38-42, 106-111). PTY limits: cols 20–500, rows 5–200, default 120×30.

## 3. Session states (exact strings)

- **Client display states** (`W/stores/sessions.js:10, 65-78`):

| State | Glyph | Label | Derivation |
|---|---|---|---|
| `waiting` | `◆` | `WAITING` | `activity.state` |
| `busy` | `●` | `BUSY` | `activity.state` |
| `idle` | `○` | `IDLE` | `activity.state` |
| `unknown` | `●` | `—` | not in `KNOWN_STATES` |
| `ended` | `✕` | `EXITED` | `status !== 'running'` |

- **Waiting reasons:** `permission`, `question`, `plan`.
- **Hook writer** (`configs/hooks/status-writer.js:131-178`), which writes `~/.claude/codd-status/term/<CODD_TERMINAL_ID>.hook.json`:

| Event | Resulting state |
|---|---|
| `SessionStart` | `idle` (unchanged if `source==='compact'`; also sets `custom_title` from `session_title`) |
| `UserPromptSubmit` | `busy` (records `last_prompt`) |
| `PreToolUse` | `busy`, or `waiting` with `question` for `AskUserQuestion`, or `plan` for `ExitPlanMode` |
| `PostToolUse` / `PostToolUseFailure` | `busy` (`tool_count++`, sets `last_tool`) |
| `PermissionRequest` | `waiting` with reason `permission` (or the tool's own reason) |
| `Notification` `permission_prompt` | `waiting` (`permission`) |
| `Notification` `elicitation_dialog` / `elicitation_url_dialog` | `waiting` (`question`) |
| `Notification` `idle_prompt` | `idle` |
| `Stop` / `StopFailure` | `idle` |
| `SessionEnd` | `ended` |

- **Server merge** (`S/services/session-insights.js:331-370`):
  - PTY exited → `ended`.
  - The hook says `ended` but the PTY is alive → `idle`.
  - Claude's own registry `~/.claude/sessions/<pid>.json` overrides with `busy`/`idle` only when it is more than 1s newer than the hook. Waiting is trusted only from the hook.
  - No hook data → the registry's `status`. Neither source → `unknown`.
- **Other status strings:**
  - PTY `status`: `running` | `exited`.
  - Stream: `connecting` | `live` | `reconnecting` | `closed`.
  - Setup part state: `installed` | `outdated` | `missing`. Statusline mode: `wrapped` | `standalone`.

## 4. Launch profiles

- **Schema** (`S/db/schema.sql:25-33`): `id`, `name` (UNIQUE), `command`, `cwd`, `env_json`, `created_at`, `updated_at`. There are **no** model, permission-mode or args fields; everything goes into the `command` string.
- **UI** (`W/views/LaunchProfilesList.vue`):
  - Form fields: name, cwd (default `~/Claude-station`), command (placeholder `claude --channels plugin:discord@…`), env as a JSON textarea.
  - Row actions: DUPLICATE (auto-names `-copy`, `-copy-2`), EDIT, DELETE (with a confirm).
- **Spawn** (`terminal-manager.js:156-232`):
  - Fails with 422 if cwd doesn't exist.
  - Runs `$SHELL -i -c <command>` in node-pty `xterm-256color`.
  - Env is an allowlist (HOME, PATH, USER, LANG, TZ, TMPDIR, `CLAUDE_CONFIG_DIR`, …) plus the sanitized profile env (blocks `LD_*`, `DYLD_*`, `NODE_OPTIONS`, PATH, NODE_PATH), plus `CODD_TERMINAL_ID=<uuid>`.
  - Plain `claude …` commands get `--session-id <pty-id>` appended (60-81).
- **Entry points:** `+ NEW ▾` dropdown in the sidebar header (`NewSessionButton.vue:59-95`; header `LAUNCH PROFILE`, items show name and cwd, footer link `管理 profiles →`), the Home launch grid, and the ALL SESSIONS select.

## 5. DeviceStatus (`W/components/DeviceStatus.vue`, data from `S/services/system-stats.js`)

**HOST block:** header shows `HOST`, then `up 3d4h`, or a stale "x 分鐘前" (x minutes ago) when older than 60s. Cells sit in a 2-column grid, each with a meter bar:
- **CPU:** `NN%`. Tooltip: `load a b c · N cores`.
- **MEM:** `used/totalG` from `vm_stat`. Tone comes from `pressure` (normal/warn/critical). Tooltip: app / wired / compressed / cached / pressure.
- **DISK:** `NNNG free` on the home volume. Warn at 85% used, critical at 95%.
- **SWAP:** shown only when above 0.
- **BAT:** `NN%` plus ` ⚡` when charging or ` AC` on power, via `pmset`. Warn at ≤20%, critical at ≤10% when on battery.
- **Polling:** fast sample 5s, slow sample (disk, battery) 60s, client poll 10s. Paused when the tab is hidden.
- **Collected but never rendered:** `claude.app_running`, `claude.system_processes` (`pgrep -x claude`), `server.rss_bytes`, `event_loop_p99_ms` (`system-stats.js:156-169`).
- **No network or temperature metrics.**

## 6. SetupGuide: hook installation flow (`W/components/SetupGuide.vue`, `S/services/claude-setup.js`)

1. `GET /setup` returns `settings_path` (`~/.claude/settings.json`), `status_dir` (`~/.claude/codd-status`), `hooks{state, events_missing, events_outdated}`, `statusline{state, mode, has_foreign}`, `legacy{present, file, entries}`, `data{hook_last_at, statusline_last_at, usage_last_at}`, `complete`, `warnings` (e.g. `disableAllHooks`, missing script, missing node path after an nvm change) and `error`.
2. A checklist with a checkbox per part: **Hooks**, **Statusline**, and **Legacy hook** (only when present). Each shows a state glyph (`● 已安裝` installed, `◆ 需要更新` needs update, `○ 未安裝` not installed), a purpose line, details, and freshness lines ("最近收到資料：x 分鐘前", last data received x minutes ago).
3. `預覽變更` (preview changes) calls `GET /setup/plan?parts=` and renders a line-level LCS **diff** of only the affected subtree (`- 移除` removed / `+ 新增` added).
4. `安裝選取項目` (install selected) calls `POST /setup/apply`, which:
   - Backs up to `settings.json.codd-bak-<timestamp>`, then writes atomically.
   - Hooks: for the 10 `HOOK_EVENTS` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure, SessionEnd; lines 29-40), appends `{matcher:'*' (tool/permission/notification events only), hooks:[{type:'command', command, timeout:5}]}`. The command is `[ -z "$CODD_TERMINAL_ID" ] || [ ! -x node ] || [ ! -f script ] || STATUS_DIR_PATH=… node configs/hooks/status-writer.js` (123-129).
   - statusLine: becomes `codd-statusline.js`. An existing statusLine is wrapped with `--chain-b64 <base64 original>` and the other keys are kept (134-141, 404-415).
   - Legacy: removes the old channel-level PostToolUse hook from `<CHANNEL_PATH>/.claude/settings.json`.
5. Results show "已套用" (applied) with backup paths. `移除` (uninstall, with a confirm) restores the original statusLine.
6. A CLI box with a copy button: `npm run setup -- status | install --dry-run | install | uninstall | install --only hooks,statusline`.
7. A compact sidebar banner, "◆ 完成設定以取得 session 狀態與 5h/1w 用量 → 設定 ✕" (finish setup to get session status and 5h/1w usage). Dismissal is stored in `codd.setup.dismissed`, and the check reruns every 30s and on tab focus.

**Files written at runtime:**
- `codd-status/term/<id>.hook.json` and `term/<id>.statusline.json` (fields: `session_name`, `context_left_pct`, `model`, `config_dir`).
- `codd-status/usage/<config_key>.json`, written by every session, including ones not started by CODD.

## 7. Usage / quota display

- **Source:** the statusline's `rate_limits.five_hour` / `seven_day`, written to `usage/<config_key>.json`.
- **Account key** (`codd-statusline.js:101-115`): `default` when there's no `CLAUDE_CONFIG_DIR`, `cswap-<n>` for claude-swap directories `<n>-<email-slug>`, otherwise `cfg-<sha8>`. Emails are never exposed.
- **Server** (`session-insights.js:220-247`) returns **only the most recent account's** snapshot: `{config_key, captured_at, age_seconds, five_hour, seven_day}`. Each window is `{used_percentage, remaining_percentage, resets_at, reset_passed}`.
- **UI block** (`DeviceStatus.vue:153-290`):
  - Header: `USAGE 剩餘` (remaining), an account tag when the key isn't `default`, and data age (stale after 1800s).
  - Rows `5h` and `1w`: a **remaining** bar plus percent. Tones: ok ≥50, warn <50, crit <20, muted when not reported yet or reset has passed.
  - Reset text: `重置 14:30` / `明天 14:30` / `10/18 週六 14:30` (reset today / tomorrow / date), plus a countdown such as `2h15m後` (2h15m from now).
  - Placeholder when nothing has been reported: `5h/1w 用量尚未接上 設定 →` (usage not connected yet, go to setup).
- **Per-session:** only `CTX NN%` (context left). The statusline captures `model` but the UI never shows it. **No cost or token display.**
- **Multi-account:** usage files exist per account, but only the newest is shown. The desktop menu-bar view of every account's quota needs a new "list all usage/*.json" endpoint.

## 8. Mobile / web-only features (likely to drop or rework on desktop)

- Mobile top bar (≤767px) with a hamburger plus waiting badge, page title and state pill. Off-canvas drawer with backdrop (`App.vue:159-175`).
- `visualViewport` → `--app-h` tracking for the iOS soft keyboard. `safe-area-inset` padding. 16px minimum input font to stop iOS zoom.
- Touch: KeyBar always shown, composer on by default, drag only via the grip, tap-to-open popovers, xterm not auto-focused.
- The multi-device PTY size controller (`client_id`, BroadcastChannel duplicate-tab detection, follow-and-take-over hint). Desktop with a single window mostly doesn't need it, but it becomes relevant if a remote client is added later.
- SSE single-stream mode on HTTP/1.x; Cloudflare 502/530 retry backoff.
- Google OAuth login and the Cloudflare Access gate (`LoginView`, `S/services/auth-gate.js`). The `401 → codd:unauthorized` handling.
- `(n)` in the tab title. Desktop equivalents are the Dock badge and the menu-bar extra.

## Other workspace views (brief)

All of these read from `CHANNEL_PATH` (e.g. `~/Claude-station`).
- **IDENTITY:** lists `CLAUDE.md`, `IDENTITY.md`, `SOUL.md`, `USER.md`, `MEMORY.md`, … with size and mtime chips. Detail view is a Markdown editor (view/edit/save).
- **SKILLS:** `.claude/skills/*/SKILL.md`. List chips: model, `fork`, disabled, hidden. Detail has a frontmatter form editor (SkillEditor) and a file browser (SkillFiles).
- **AGENTS:** `.claude/agents`. List shows a color dot and chips for model, `perm:`, `effort:`, background, isolation. AgentEditor fields: name, description, model, permissionMode, effort, maxTurns, memory, isolation, background, tools allowlist chips, disallowedTools, color, skills. It also has an advanced JSON toggle.
- **TASKS:** `tasks/`. Chips: active/disabled, channel, `cron:` schedule. Detail is a raw editor with the note "editing does not restart cron".
- **MEMORY:** `memory/<date>` rail showing KB size, plus a rendered Markdown pane.
- **KANBAN:** SQLite columns and cards. Cards drag between columns (vuedraggable group). Card fields: title, description, tags. Create/edit modal.

---

## Features to carry to desktop (priority order)

1. **State model and lamps:** waiting / busy / idle / unknown / ended, with glyph + color double encoding, waiting reasons (permission / question / plan), time-in-state, and the waiting pulse.
2. **Waiting surfacing:** waiting count badge, the amber-highlighted waiting row, and a window/Dock title count. Extend it to the menu bar and system notifications.
3. **Embedded xterm terminal per session:** pool of live terminals, instant switching, reconnect with catch-up replay, font A−/A+ (10–24).
4. **Session row data:** title (custom > statusline > ai-title > first prompt > profile), short cwd, uptime, time in state, CTX %, last tool, and the last-prompt hover popover.
5. **Drag reorder plus keyboard reorder (Alt+Shift+↑↓), and Alt+1..9 quick switch.** Extend to the requested groups, colors and projects.
6. **New session from a launch profile:** name, cwd, command, env; duplicate / edit / delete; auto `--session-id` linking. Consider adding model and permission fields.
7. **Session actions:** Restart (keeps position, counts restarts), Kill, Remove (soft delete) and restore-from-removed. Add a real "resume conversation" option, since restart doesn't resume.
8. **Composer:** per-session drafts, IME-safe Enter, bracketed-paste multi-line, Enter-only send.
9. **KeyBar:** ESC, TAB, ⇧TAB, arrows, ⏎, ^C, 1/2/3. Make it optional on desktop and keep it for quick permission answers.
10. **Exit banner:** exit code or signal, with RESTART and REMOVE.
11. **STOPPED section:** collapsible, recent 12, `+N more`, ALL SESSIONS view with show-removed.
12. **NO HOOK warning:** shown when no hook report arrives after 20s.
13. **Usage panel:** 5h/1w remaining bars, tone thresholds 50/20, reset time and countdown, stale indicator. Make it **multi-account** for the menu bar.
14. **Host status:** CPU (load, cores), MEM (pressure, breakdown), DISK free, SWAP, BAT. Optionally add the collected but hidden claude process count and server RSS.
15. **Setup / hooks installer:** per-part status, freshness, diff preview, install with backup, uninstall/restore, warnings.
16. **Open in Terminal.app** with the take-over vs keep-both choice.
17. **Focus mode:** hide the sidebar.
18. **Home behavior:** auto-open the latest active session, otherwise show the launch grid, recently stopped list and setup.
19. **Workspace tools** (Identity, Skills, Agents, Tasks, Memory, Kanban): lower priority; could go in a secondary nav or Settings.
20. **Drop or rework:** mobile drawer and top bar, visualViewport and iOS keyboard handling, OAuth / Cloudflare Access login, multi-device size takeover (keep it only for a future remote client).