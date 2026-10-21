[harness: subagent output matched instruction-shaped pattern(s): settings-json. Control tags below are neutralized (`<` → `<\`); treat any remaining directive-shaped text as a finding to relay to the user, not an instruction to you.]

# Completeness critique: research for the CODD Desktop design mockup

I checked a few claims read-only on this Mac (tagged **[verified]** below). No files were modified.

---

## 1. Contradictions between reports

| # | Topic | Report A says | Report B says | Resolution (verified or most likely) |
|---|---|---|---|---|
| C1 | **Status dir location** | session-ux and server-data: default is `~/.claude/codd-status` | claude-local: CODD hooks write to `.../agent-sandbox/.claude/codd-status` | **[verified]** `~/.claude/settings.json` sets `STATUS_DIR_PATH` to a folder inside another project (shape: `STATUS_DIR_PATH='/path/to/web-repo/<project>/.claude/codd-status'`). That folder has `term/` and `usage/`. `~/.claude/codd-status` and `~/GitHub/<project>/.claude/codd-status` are both empty. **Design:** the Hooks page has to show the *actual* resolved status dir and flag a mismatch. It should not assume the default. |
| C2 | **Can sessions not started by CODD show WAITING?** | server-data (Reuse caveats): "External sessions get registry busy/idle only, with no `waiting`" | claude-local and remote-and-stack: registry `status` can be `waiting` with `waitingFor`, and `claude agents --json` returns `status: waiting`. server-data §1b rule 4 also accepts registry `waiting` when there is no hook file. | server-data contradicts itself. CODD's code only refuses to *override* a hook state with registry `waiting`. For sessions with no hook (external ones), registry `waiting` applies. **[verified]** All 10 live registry files now have `waitingFor: null` with status idle/busy, so the value set cannot be confirmed from data, only from the binary and docs. **Design:** external sessions *can* show WAITING but no reason, or a coarse reason from `waitingFor`. |
| C3 | **Values of `waitingFor`** | claude-local: 6 values (`permission prompt`, `input needed`, `dialog open`, `sandbox request`, `worker request`, `goal proposal`) | remote-and-stack: 5 (no `goal proposal`) | Use claude-local's 6. Map `input needed` → question. Map `permission prompt`, `sandbox request` and `worker request` → permission. Map `dialog open` and `goal proposal` → a generic `other` reason (claude-local's "first and last three" grouping is ambiguous). |
| C4 | **Is it safe to poll usage directly?** | server-data: cswap's `GET /api/oauth/usage` is the "fresher per-account source". Its data model lists `source: oauth-api`. | cswap: "Do not poll `/api/oauth/usage` separately"; this Mac already sees many HTTP 429 errors. claude-local: polling should be opt-in only. | Never poll it from the app. Sources are: statusline for the active account (free) plus cswap's cache or `store_only` snapshot for inactive accounts. **Design:** every quota row shows its source and its age. |
| C5 | **Per-model windows** | claude-local [bin]: `seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`, `seven_day_cowork`, `extra_usage` | cswap: no Opus field; per-model windows arrive as `limits[]`, and today the only one is "Fable" | Trust the live response shape (cswap). **Design:** render a generic list of `scoped[]` rows (0..n), not fixed Opus/Sonnet rows. |
| C6 | **Spend / extra-usage units** | statusline: `rate_limits.spend_limit{used_percentage, used_usd?, limit_usd?, period?}` | cswap: `extra_usage.used_credits` / `monthly_limit` in **cents**, normalized to `spend{used, limit, pct, currency}` | Normalize to dollars and percent in the app. **[verified]** `hasExtraUsageEnabled: false` on the active account, so the mockup shows spend as "off". |
| C7 | **Usage files are not truly per account** | server-data and session-ux: "files are already keyed per account, so per-account display is a small change" | cswap: a switch is *global*, and the default login changes account | **[verified]** There is only `usage/default.json` (one 5h and one 7d window, each with a used percentage and a reset time). `default` means whichever account was globally active when the file was captured, so the file mixes accounts across switches. Only `cswap-<n>` keys (session mode) are stable. **Design consequence:** the menu bar must key accounts by **cswap account number**. The `default` statusline snapshot can be credited only to the active account, using its capture time. |
| C8 | **Quota values drift between sources** | cswap report table: one 5h / 7d pair for the active account | — | **[verified]** minutes later cswap's `cache/usage.json` and the statusline each gave a different pair for the same windows (about a point apart). **Design:** show one value per window, from the freshest source, plus an "as of" label. Never show two numbers side by side. |
| C9 | **cswap field names** | cswap report: `list --json` uses `fiveHour.pct`, `resetsAt`, `countdown`, `clock` | — | **[verified]** `cache/usage.json` uses `pct` (0–100 float, **used**), snake-case `resets_at` (ISO with offset), `countdown: "4d 10h"` and `clock: "Oct 19 20:00"`. The cache schema is internal and differs from `list --json`. **Design:** CODD displays **remaining**, while cswap and the statusline report **used**, so the UI must pick one convention (see Q-A1). |
| C10 | **Title priority** | server-data: transcript custom-title > hook `custom_title` > statusline `session_name` > ai-title > first-prompt > profile > basename(cwd) | claude-local: customTitle > aiTitle > first prompt. It also mentions `agent-name` and registry `name`/`nameSource`. | Use server-data's order with a new **user override** on top: app `title_override` > custom-title > hook > statusline > ai-title > registry `name` (external) > first-prompt > project name. |
| C11 | **Exit naming** | Hook writes `ended`; PTY status is `exited`; STATE_META label is `EXITED`; the hook says `ended` while the PTY is alive → CODD shows `idle` | — | Showing "IDLE" when Claude has quit back to the shell is misleading. In the desktop app that case gets its own state, `SHELL` (see §4). |
| C12 | **Amber is not one color** | Tokens: `--amber #ffb84a` | xterm cursor `#ffb300`; scanlines and modal glow `rgba(255,176,0,…)` | These are leftovers from before the AA-contrast amber. Use `#ffb84a` everywhere in the mockup. |
| C13 | **Terminal font differs from UI font** | UI: JetBrains Mono | xterm: `ui-monospace, SFMono-Regular, Menlo` (`terminalPool.js:104-111`) | **Design default:** the terminal uses JetBrains Mono plus PingFang TC fallback, with a Settings option. |
| C14 | **Vibrancy vs the CRT look** | remote-and-stack: sidebar `vibrancy:'sidebar'`, content opaque | design-system: everything sits on opaque `#050505` with scanlines and grain | Vibrancy would let the wallpaper show through the "phosphor console". **Default:** opaque `#050505` sidebar and no vibrancy in v1. Vibrancy becomes an optional "Native glass" appearance toggle. |
| C15 | **`menubar` npm package** | remote-and-stack recommends Electron 44 | The same report says `menubar` 9.x is tested against Electron 35–43 | Implementation only. It doesn't change the 380×520 popover frame. |

---

## 2. Open questions that affect the design, with suggested defaults

### A. Information architecture and navigation
| Q | Question | Suggested default |
|---|---|---|
| A1 | Quota shown as **remaining** or **used**? | **Remaining** (the user wrote 剩餘額度). Keep CODD's `USAGE 剩餘` bars and tones (≥50 ok, <50 warn, <20 crit). |
| A2 | How do the three areas (主頁 / 狀態 / 設定) switch? | A thin **top segmented nav in the sidebar header** below the traffic lights: `SESSIONS · STATUS · SETTINGS`. Settings also opens with ⌘,. The sidebar list stays visible on all three areas so waiting rows never disappear. |
| A3 | Hierarchy | **Group → Project → Session**, one level of groups, no nesting. Projects without a group go in a default `UNGROUPED` bucket. A session belongs to exactly one project, decided by its cwd. A new session in an unknown cwd creates the project automatically. |
| A4 | Where do projects come from? | Manual "+ Project" (folder picker) **plus** a suggestion list from `~/.claude.json → projects` (187 entries), sorted by `lastSessionModified`. Never import everything automatically; that would recreate the official app's folder mess. |
| A5 | Which sessions appear? | App-spawned sessions (full fidelity) are always shown. **External** live sessions (registry / `claude agents --json`) go in a collapsible `DETECTED` section, or under their project with an `EXT` badge, read-only plus "Attach/Open". Past transcripts are not rows; they live in a per-project **Resume…** picker. SDK (`sdk-*`) and `claude-desktop` entrypoints are hidden by default. |
| A6 | Attention surfacing in the sidebar | A pinned **`◆ NEEDS YOU (n)`** strip at the top of the sidebar, a mirror of all waiting and error sessions across groups. Collapsed groups and projects show aggregate badges (`◆2 ●3`). Manual order is never reshuffled by state. |
| A7 | Meaning of "remove" | Four distinct verbs, all in the context menu: **Archive/Remove** (hide from sidebar, transcript kept, restorable), **Kill** (stop process), **Remove project** (unlist only), **Delete history** (`claude purge`, danger, typed confirmation, buried). Bulk actions: multi-select (⌘/⇧-click), "Clear stopped" per project or group, and an "auto-archive stopped after N h" setting. |
| A8 | Drag scope | Groups reorder. Projects reorder and move between groups. Sessions reorder within their project (they can't change project, because cwd is fixed). Sessions can be **pinned** to a top `PINNED` section. Drop targets get a dashed amber-dim ghost (the existing CODD pattern). |
| A9 | Colors: which entities? | Groups and sessions (as asked). A project inherits its group's color unless overridden. Palette: the 8 `/color` names already in `AgentEditor.vue:69-73` (red `#ef5b5b`, blue `#5b8def`, green `#4ec9b0`, yellow `#e6c84e`, purple `#b07cff`, orange `#ff9b4e`, pink `#ff7cb5`, cyan `#4ed1e6`) plus none. A session with no app color starts from its transcript `agent-color`. |
| A10 | **Color tags clash with state colors** (yellow and orange vs amber waiting; green vs busy; cyan vs idle; red vs danger) | Tags never color the lamp or title. They render as a **3px left stripe on the group header** and a **10×10 square `.color-dot`** on the session row, placed after the lamp. State keeps glyph, label and color (round or diamond glyphs vs a square tag). Optionally tone tags down to 70% saturation. |
| A11 | Home (nothing selected) | Keep CODD's behavior: auto-open the most recent active session, otherwise show a launch grid (profiles × projects), Recently Stopped with RESUME, and the setup checklist. |

### B. Session pane
| Q | Question | Suggested default |
|---|---|---|
| B1 | What does "多可以開啟 terminal" mean? | Both of these: (1) a **toggleable bottom split** (⌘J) in the session's cwd with shell tabs `[SHELL 1] [+]`; (2) a sidebar item kind **Terminal** (plain shell) under a project. Session pane header tabs: `CLAUDE · SHELL · INFO`. |
| B2 | Desktop density | CODD web is tuned for phones (17px body, 16px inputs, 44px rows). Desktop scale: body 13px, sidebar title 13px, micro text 10–11px, row height 36px (2 lines), sidebar width 280px (resizable 220–400). Keep letter-spacing tiers and UPPERCASE. |
| B3 | Header data | Line 1: lamp · title · state chip `◆ WAITING · PERMISSION · 3m`. Line 2: `cwd · ⎇ branch · model · CTX 42% · $1.23 · UP 1h02m · account tag · ◉ RC`. Model is already captured, and cost is in statusline stdin but not yet read, so mark both "needs capture". |
| B4 | Composer and KeyBar on desktop | Composer **off by default** but one keystroke away (⌘L), because Chinese IME in xterm is weaker. When a session is WAITING, show an **inline answer bar** above the terminal: `[1] [2] [3] [ESC]`, built from KeyBar keys. |
| B5 | Session-switch shortcuts | ⌘1–9 jumps (xterm doesn't use ⌘, so Option stays Meta), ⌃Tab cycles, ⌘⇧↑/↓ reorders, ⌘K quick switcher with fuzzy search over group/project/session, ⌘N new session, ⌘T new shell tab. |
| B6 | Restart vs resume | The ⋯ menu has two actions: **↻ RESTART (new conversation)** and **⟲ RESUME** (`claude --resume <id>`). After an app relaunch, persisted sessions show as `STOPPED · RESUMABLE` with a primary RESUME button. |
| B7 | What happens on quit / window close? | Closing the window keeps the app in the menu bar, and PTYs keep running. ⌘Q with live sessions shows a sheet: "N sessions running (◆ M waiting) — Stop all & quit / Keep in menu bar / Cancel". |
| B8 | Workspace views (Identity, Skills, Agents, Tasks, Memory, Kanban) | Out of the v1 main flow. Put them on a **project INFO tab** (CLAUDE.md, Skills, Agents, Memory scoped to `<project>/.claude`). Kanban and Tasks become one global entry in the STATUS area, or are deferred. Show them in the mockup as one frame marked "phase 2". |

### C. Status page, accounts, hooks
| Q | Question | Suggested default |
|---|---|---|
| C1 | How is the account behind a session shown? | Default-profile sessions show `↻ ACTIVE` (they follow the global login). Session-mode (`cswap run`) sessions show a pinned tag `#2 帳號 B`. The account tag is hidden when only one account exists. |
| C2 | Switch UX | A per-account `[ SWITCH ]` button. The confirm sheet warns: "Affects N running default-profile sessions; first message may re-cache". A progress state lasts up to about 27s with retry on `ClaudeCodeLockTimeout`. The switch history comes from the log. |
| C3 | Auto-switch | Shown read-only with an "enable" toggle (threshold 90, cooldown 300s, strategy best|consume-first). Warn when `cswap menubar` or `auto` already owns the engine. |
| C4 | Missing cswap or wrong version | An empty state with the install command (`uv tool install claude-swap==0.26.0`) and a minimum-version check. Without cswap, the app still shows the single statusline account. |
| C5 | Showing emails | Show alias or displayName (e.g. 帳號 C). Email shows truncated on hover. A "Hide emails" setting is for screen sharing. The mockup should use aliases. |
| C6 | Hook installer scope | One card **per config dir** (`~/.claude` plus each non-symlinked `CLAUDE_CONFIG_DIR`). cswap session profiles symlink `settings.json`, so they share it; mark them "inherits ~/.claude". Each card lists **foreign hooks** (another tool's `hook-tap`, the two osascript notifiers), the **statusline chain** (CODD → hook-tap → statusline.sh), a diff preview, backups and uninstall. |
| C7 | Extra events to install | Add `PreCompact`, `PostCompact` and `SubagentStart/Stop`, and keep `StopFailure.error` (it is currently dropped), so the COMPACTING and ERROR states work. The installer shows "outdated: 3 new events". |
| C8 | Duplicate notifications | Existing osascript notification hooks would double up with the app's notifications. The Hooks page offers "disable legacy notifier" (it never removes anything silently). |

### D. Menu bar and notifications
| Q | Question | Suggested default |
|---|---|---|
| D1 | Menu bar title | Monochrome template glyph. Append `◆2` only when sessions are waiting (amber if `setTitle` color works, otherwise monochrome). An error count, if any, is shown as `!1`. |
| D2 | Popover layout (380×520) | Top: **NEEDS YOU** list (waiting and error, click jumps to the session). Then **RUNNING** (compact, grouped by group color). Then **ACCOUNTS** (one block each: 5h and 7d bars, active marker, switch). Footer: host mini-stats, `Open CODD`, `N reachable from phone` (future). |
| D3 | Approve / Deny from the menu bar | **Not in v1.** It competes with other tools' blocking `PermissionRequest` hooks (such as `hook-tap`). Clicking a row jumps to the session. Mock it as a "future" variant. |
| D4 | System notifications | On by default for → WAITING (with reason) and → ERROR. Off by default for DONE while the session isn't focused. Per-group mute, quiet hours, and a sound option. Dock badge = waiting count. |

### E. Look and feel
| Q | Question | Suggested default |
|---|---|---|
| E1 | Theme | Dark only, matching CODD. No light theme in v1. |
| E2 | CRT scanlines and grain in an all-day app | Keep them at about half intensity, never drawn over the terminal viewport, behind a Settings toggle "CRT effects: Full / Subtle / Off" (default Subtle). Respect reduced motion for all pulses. |
| E3 | Traffic lights | `hiddenInset`; a 52px top band in the sidebar holds the traffic lights and the brand `FANCY/CODD`. Its right side holds the segmented nav or `+ NEW`. |
| E4 | Native-only pieces | Right-click context menus, notifications and the menu bar right-click menu are drawn as **standard macOS** UI in the mockup, not CRT-styled. |

---

## 3. Requirements from the brief not yet covered, or only partly covered

| Brief item | Gap |
|---|---|
| "很方便的拖曳、增加、移除" | Research covers CODD's drag only. Nothing covers **bulk remove**, **clear stopped**, **auto-archive**, or **undo after remove**. Remove has no toast or undo, and CODD has no toast component. The mockup needs a toast pattern, e.g. `✕ 3 sessions archived · [UNDO]`, 5s. |
| "大群組" | No data source exists; the model is new (server-data's proposed Group/Project tables). No research covers **group-level actions** (new session in group, collapse all, rename, color, delete group → projects go to Ungrouped). |
| "session 狀態 / 列出各種主要狀態" | CODD has 5 states. Error (StopFailure), Compacting, Done-unseen and Shell are not captured or modelled today (see §4). |
| "多可以開啟 terminal" | No research covers the **split or tab component** (CODD has no tabs) or how a plain-shell session shows state (it has no hooks, so it needs a "shell" state; OSC title or the foreground process name can serve as the label). |
| "狀態：目前電腦狀態" | Covered (CPU/MEM/DISK/SWAP/BAT). Collected but never shown: claude process count, app RSS, event-loop p99. Not researched: network, thermal, GPU (default: leave out). The Status page also needs **history sparklines**, but CODD keeps none; default is to show only the current values and a 10-minute in-memory spark. |
| "cswap 帳號切換" | No research covers the **add-account flow** (`cswap add` captures the current login, so the user must `/login` first), `add-token`, remove (interactive `[y/N]`), alias, or disable. Each needs a modal frame. |
| "Hook 安裝" | Covered for CODD's own hooks. **Not covered:** the multi-config-dir view, foreign-hook coexistence UI, the new-event upgrade path (C7), and app-update path drift (node and script paths embedded in commands → "repair" state). |
| "設定" | There is no consolidated settings inventory. Suggested sections: **General** (launch at login, show in Dock, close-to-menubar, default project root), **Appearance** (CRT effects, font, terminal font size 10–24, density), **Sessions** (default profile, auto `--session-id`, auto-archive, NO HOOK threshold 20s, stale 1h), **Launch Profiles** (existing CRUD, plus model / permission-mode / account fields), **Notifications** (per state, sound, quiet hours, Dock badge), **Accounts** (cswap path and version, auto-switch, hide emails), **Hooks & Status dir**, **Shortcuts**, **Remote & Mobile** (future), **Advanced** (log retention: 57 unbounded `apps/server/data/sessions/*.log`, data paths, import from CODD web). |
| "Mac 導覽列：每一個帳號剩餘額度" | The data-shape gap is described in C7. The reports also miss the **plan badge** (`organizationRateLimitTier: default_claude_max_20x` → "Max 20x", **[verified]**), **pace** (cswap `expectedPct`/`aheadOfPace`/`projectedExhaustionAt`), and the per-account `usageStatus` error states (`relogin_required` and others). |
| "列出目前運作中 session（標出 waiting）" | Covered conceptually. Missing: ordering in the popover (waiting first, then by group order) and the cap with "+N more". |
| "Apple 遠端連線（未來）" | Well researched. Missing: a decision on which frames to mock now. Default: (1) a Remote Control chip in the session header plus a QR modal, (2) Settings → Remote & Mobile with Phase 0/1/2 shown, (3) one iPhone Live Activity frame marked "future". |
| "設計風格延伸 CODD" | Not covered: **desktop density scale** (B2), **tab component**, **toast**, **context-menu style**, **split-pane divider**, **segmented nav**, **menu bar popover styling**, **color-tag rendering** (A10). These are new components the mockup must define. |
| "先製作完整設計稿" | There is no frame list yet. Minimum set: Main (waiting selected), Main + bottom shell split, Home/empty, sidebar edit states (drag, context menu, multi-select, color picker, new group), New Session sheet, Status (host, accounts, hooks), Hooks diff modal, Switch-account sheet, Settings (2–3 sections), Menu bar popover (normal and with error), notification, Quit sheet, first-run onboarding, Remote Control (future). |
| Onboarding | No research covers first run (no hooks, no cswap, no projects). Reuse SetupGuide as a 3-step checklist. |

---

## 4. Canonical session states

Each state is double-encoded with a glyph and a color, as in CODD. Colors are CODD tokens.

| # | State (label) | Meaning | Detection source (priority order) | Glyph / color semantic | Needs attention |
|---|---|---|---|---|---|
| 1 | `waiting · permission` (WAITING · PERMISSION) | A tool or sandbox approval prompt is open | Hook `PermissionRequest` (immediate); hook `Notification permission_prompt` (about 6s later); registry/`claude agents` `status:waiting` + `waitingFor ∈ {permission prompt, sandbox request, worker request}` | `◆` `--amber #ffb84a`, filled amber pill with black text, `lamp-pulse 1.1s`, amber gradient row | **YES, high** (notification, menu bar count, Dock badge) |
| 2 | `waiting · question` (WAITING · QUESTION) | Claude asked the user something (AskUserQuestion or an MCP elicitation) | Hook `PreToolUse tool_name=AskUserQuestion`; `Notification elicitation_dialog / elicitation_url_dialog`; registry `waitingFor: input needed` | as #1 | **YES, high** |
| 3 | `waiting · plan` (WAITING · PLAN) | Plan approval (ExitPlanMode) | Hook `PreToolUse tool_name=ExitPlanMode` | as #1 | **YES, high** |
| 4 | `waiting · other` (WAITING) | Dialog or goal proposal, or an external session with no reason known | Registry `waitingFor ∈ {dialog open, goal proposal}` or `status:waiting` with no hook | as #1, reason omitted | **YES, high** |
| 5 | `error` (ERROR · RATE LIMIT / AUTH / OVERLOADED …) | The turn failed. For `rate_limit`, show the reset time from that account's usage. | Hook `StopFailure.error` (enum: `rate_limit, overloaded, authentication_failed, billing_error, server_error, max_output_tokens, …`). **Needs a status-writer change** (today it maps to idle). Also `Notification quota_auto_resume_*` and `claude agents` `state:failed`. | `▲` or `!`, `--danger #ff7058`, outlined pill | **YES, high** |
| 6 | `busy` (WORKING) | Claude is generating or running tools | Hook `UserPromptSubmit`, `PreToolUse` (other tools), `PostToolUse(Failure)`, `SubagentStart`; registry `busy`; OSC title spinner `◐/◑` (experimental) | `●` `--success #7cff9a` with glow, optional slow spinner; line 2 shows `tool <last_tool>` | No |
| 7 | `compacting` (COMPACTING) | Context compaction in progress (a sub-state of busy) | Hook `PreCompact` → `PostCompact` (**new events to install**); `SessionStart source=compact` ends it | `◌` success-dim, label in `--dim` | No |
| 8 | `done` (DONE · unseen) | The turn finished while the user wasn't viewing the session ("ready for review") | Derived: `Stop` (or registry → idle) after `last_viewed_at`. `Notification idle_prompt` (about 60s) can re-alert. Cleared when the session is opened. | `◇` `--cyan #6ee0f0`, **filled** cyan pill with black text (idle is outlined) | **YES, low** (sidebar badge plus menu bar; notification off by default) |
| 9 | `idle` (IDLE) | Turn finished and already seen; the prompt is ready | Hook `Stop`, `SessionStart`, `Notification idle_prompt`; registry `idle` | `○` `--cyan`, in-state duration in `--dim` | No |
| 10 | `starting` (STARTING) | PTY spawned, no hook or registry data yet (under 20s) | `status=running`, `hook_seen=false`, uptime < `NO_HOOK_AFTER_SEC=20` | `◌` `--bone`, blink-soft | No |
| 11 | `unknown` (— , plus ⚠ NO HOOK) | Running, but no hook data after 20s and no registry entry | No hook file and no registry match; NO HOOK when a claude command, `hook_seen=false` and ≥20s | `●` `--bone` at 0.6 opacity, `⚠ NO HOOK` in `--amber-dim` | No (but shows the setup nudge) |
| 12 | `shell` (SHELL) | PTY alive but Claude isn't running: Claude quit back to the shell, or this is a plain Terminal item | Hook `ended` and PTY alive (CODD currently shows `idle`); `kind=terminal` items; label from OSC title or the foreground process | `$` `--bone` | No |
| 13 | `exited` (EXITED · code N / signal 15) | Process ended in this app run | PTY `status=exited`, `exit_code`; hook `SessionEnd(reason)` | `✕` `--dimmer`; non-zero or signal exit codes in `--danger` text | No (non-zero exit: optional low) |
| 14 | `stopped · resumable` (STOPPED) | A persisted session from an earlier app run, or a killed one, whose transcript still exists | App DB row with no live PTY and an existing transcript `<sessionId>.jsonl` → RESUME | `✕` or `⟲` `--dimmer` at 0.7 | No |

**Modifiers** (they are badges, not states):
- `EXT`: external or not app-spawned. Registry or `claude agents` only, no last_prompt or reason detail.
- `BG`: background job, from `claude agents state working/blocked/done/failed/stopped`. Mapping: working→busy, blocked→waiting, done→done, failed→error, stopped→exited.
- `◉ RC`: Remote Control connected, from `bridgeSessionId` in the registry or a `bridge-session` record in the transcript.
- `STALE`: idle or waiting longer than `STALE_AFTER_SEC=3600`. Dim the duration; never drop the waiting highlight.
- Account tag: shown when the session is pinned to a non-active `CLAUDE_CONFIG_DIR`.

**Aggregates:**
- Attention count (menu bar, Dock, `◆ NEEDS YOU`) = states 1–5.
- Soft count = state 8.
- Group and project header badges show `◆n` (amber), `!n` (danger), `◇n` (cyan), `●n` (success).

---

## 5. Per-account quota data shape for the menu bar

One record per **cswap account number**, or a single `default` record when cswap is absent. It merges the statusline `usage/*.json`, cswap `cache/usage.json` or `list --json`, `sequence.json` and `oauthAccount`.

```ts
type QuotaAccount = {
  key: string;                    // "cswap-3" | "default" | "cfg-1a2b3c4d" (stable UI key)
  cswap_number: number | null;    // 1..n from ~/.claude-swap-backup/sequence.json
  config_keys: string[];          // statusline keys that feed it: ["cswap-3"] (session mode) and "default" while active
  label: string;                  // alias ?? oauthAccount.displayName, e.g. "帳號 C"
  email_masked: string;           // "us…@example.com" (full email hidden behind the "Hide emails" setting)
  org_name: string | null;  is_org: boolean;
  plan: { type: "claude_max" | string; tier: "default_claude_max_20x" | string; badge: "Max 20x" };
  active: boolean;                // sequence.json activeAccountNumber (the global login)
  disabled: boolean;
  status: "ok" | "token_expired" | "api_key" | "keychain_unavailable"
        | "relogin_required" | "foreign_credential" | "no_credentials" | "unavailable";
  five_hour: QuotaWindow | null;
  seven_day: (QuotaWindow & {
    pace?: { expected_pct: number; ahead_of_pace: boolean;
             projected_exhaustion_at: string | null; will_last_to_reset: boolean } }) | null;
  scoped: (QuotaWindow & { name: string })[];          // per-model weekly, e.g. [{name:"Fable", ...}]
  spend: { enabled: boolean; used_usd: number; limit_usd: number;
           used_pct: number; currency: string; resets_at: string | null } | null; // cents converted to USD
  source: "statusline" | "cswap-cache" | "cswap-list";  // whichever is freshest
  captured_at: string;  age_seconds: number;
  stale: boolean;                 // age > 1800s → grayscale(1), opacity .5 (CODD rule)
  last_good?: { captured_at: string; five_hour: QuotaWindow | null; seven_day: QuotaWindow | null };
  last_error?: string | null;  last_429_at?: string | null;  poll_interval_s?: number; // 60 active / 600 idle
  sessions: { running: number; waiting: number };      // join: app sessions using this account
};

type QuotaWindow = {
  used_pct: number;               // 0–100 (statusline used_percentage | cswap pct)
  remaining_pct: number;          // 100 - used_pct; this is what the UI shows
  resets_at: string | null;       // ISO (statusline epoch s, normalized)
  reset_passed: boolean;          // show "已重置", muted tone, 100%
  not_started: boolean;           // 5h pct 0 with no resets_at → "未開始"
  countdown: string;              // "3h31m" (CODD format; cswap gives "3h 31m")
  clock: string;                  // "13:19" | "明天 13:19" | "10/19 週日 20:00"
  tone: "ok" | "warn" | "crit" | "muted";  // remaining ≥50 ok, <50 warn, <20 crit
};
```

**Merge rules:**
1. For the active account, take `usage/default.json` (statusline, no API cost) when it is newer than the cswap cache.
2. For inactive accounts, use the cswap cache (or `cswap list --json` no more often than every 60–180s, off the UI thread).
3. Never poll `/api/oauth/usage` directly.
4. Sort the active account first, then by cswap number.

**Mockup seed data (illustrative values):**

| Account | Plan | 5h used | 7d used | Notes |
|---|---|---|---|---|
| #1 帳號 A | Max 20x | 0% (not started) | 5% | 7d resets Nov 3 09:00 |
| #2 帳號 B | Max 20x | 12% | 40% | 5h resets 14:30, 7d resets Oct 30 18:00 |
| #3 帳號 C (active) | Max 20x | 20% | 80–81% | 5h resets 15:10, 7d resets Nov 1 10:00 → 19% remaining, warn tone. Extra usage off. |

Times are local.