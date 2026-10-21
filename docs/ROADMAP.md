# CODD Desktop — roadmap (M2–M5, and later)

Each milestone runs as one orchestrated workflow (plan → critique → parallel package builds → sequential App
integration → five-lens review → triage → fix → verify) and is committed locally when green. Per-milestone plans and
reports: `docs/M<n>-PLAN.md`, `docs/M<n>-REPORT.md`.

Standing decisions (2026-10-16): design frozen (implement `design/artboards-src` v3 faithfully); local only; libghostty;
no separate `coddd` agent for now (the app hosts hooks and keeps running in the menu bar when its window closes; the
CoddHooks package can move into an agent later); anything that edits files outside the data root
(`~/.claude/settings.json`, cswap state) runs only on an explicit user action, with a diff and a backup; never poll
`/api/oauth/usage`.
Decided 2026-10-17 (M3 D34): no CODD-side Chinese display names for accounts for now; CODD shows cswap's own
(ASCII) aliases. Every automated CODD launch stays in the background and passes `-codd-data-root` as its own
argument (DEBUG builds refuse an agent launch without one). Notes live in `<dataRoot>/notes/` (user decision 2026-10-17;
not in projects; M5 onboarding may offer another location).
Decided 2026-10-18: the product name is CODD (FANCY dropped from every visible string; SPEC §10). The bundle id
became `app.codd.CODD` in M5 (user decision 2026-10-18; CODD's own defaults are copied over once). User feedback on the M3 build (drag reorder that works with
a mouse, folders dragged from Finder become projects, ⌘+ / ⌘− / ⌘0 interface zoom, window-resize layout fixes) is part of M4.

## M2 — Sessions complete (done, commit 1b64934; see docs/M2-REPORT.md)
Sidebar on real data (drag and drop, reorder, menus, swatches, PINNED, filter, TREE|STATE, archive, aggregates, stale),
external (EXT) sessions from the registry, ⌘K quick switch, ⌘1–9, ⌃Tab, ⌘\ focus mode, ⌘⏎ allow, ⌘L composer
(IME-safe NSTextView), bottom panel tabs + maximize, tab bells and titles, complete ⌘N sheet (resume picker from
Claude transcripts, launch profiles), Home on real data, dead-session screen from the ring file, single-instance lock,
error banners, UNREACHABLE state, window-close keeps the app in the menu bar.

## M3 — Menu bar, accounts, status, settings (done, commit a0526d1; see docs/M3-REPORT.md)
- Accounts via cswap at runtime (list/status/switch; fixtures and a fake cswap in tests): order by weekly reset
  soonest-first, direct switch with UNDO toast, sessions follow the global login unless pinned (`#2` chip).
- Quota from Claude Code's status line: a `codd-statusline` CLI (embedded, copied to `<dataRoot>/bin` like codd-hook),
  injected per session via `--settings` `statusLine`, forwards `rate_limits` (5h / 7d used %, resets) to the app's
  loopback endpoint with the token, and chains the user's own status line command read from their settings
  (read-only) so their status line still renders. Per-account cache, source label + age. Never call the usage API.
- Auto-switch (≤ 2 %, default OFF, CoddCore `AutoSwitchPolicy`, cooldown 300 s, notify when no target).
- Menu bar extra per SPEC §7.13 with v2/v3 overrides: one monochrome icon + counts; popover 380 px with ACCOUNTS first
  (remaining quota, direct switch with UNDO, expandable list), NEEDS YOU, RUNNING (waiting first), footer.
- Sidebar footer and rail account chip on real data.
- STATUS page (§7.11): HOST, ACCOUNTS, HOOKS & STATUSLINE (stats; global hook installer with the Hook 差異 dialog
  that writes `~/.claude/settings.json` only on confirmation, with backup, and removes the old CODD web
  `status-writer.js` hooks while keeping other tools' hooks), MCP placeholder, REMOTE (future).
- Settings (§7.12) complete; dialogs (§7.7): switch account, hook diff, add account (runs `cswap` login in a new
  SHELL session so the user completes it interactively), quit confirmation listing running sessions.
- Global hotkey (configurable).

## M4 — Notebook, file editor, MCP, cleanup (done 2026-10-18, commit "M4: notebook, file editor, MCP, cleanup"; see docs/M4-REPORT.md)
- Notes as Markdown files under `<dataRoot>/notes/` (assets, `.codd/` state, history, trash, tombstones), a derived
  GRDB index with FTS5 trigram + `LIKE` for short CJK terms, FSEvents watching for other programs' edits.
- NOTES area with the Notebook (smart lists, note list, TextKit 1 live-preview editor safe for 注音, image paste,
  image annotations with ImageAnnotate, info panel with history / assets / retention, tags, links, COPY REF,
  ⌘⇧N quick note, ⌘K NOTES), the session `✎ NOTES` pill + notes drawer, send to session (插入引用 / 插入全文 / 送出).
- Local file editor (Files mode): tree with git `M` badges, tabs, native highlighting, find / replace, disk
  watching with the AI attribution banner, AI-touched badges from PostToolUse, SHOW AI CHANGES with 還原此段 /
  接受; writes only on ⌘S.
- MCP in the app on the hook port (`/mcp`, stateless Streamable HTTP; per-session `--mcp-config`; notes_search /
  read / list / append, notes_write behind AI 可寫入), `codd://` expansion through `/hooks/prompt`, a per-note URL,
  Claude Code registration into `~/.claude.json` (button, diff, backup, Claude's lock), a Codex snippet, token
  rotation; status bar / rail / STATUS / Settings live.
- Retention (notes and sessions, first-run grace, one app trash), the Cleanup page, the Monday digest and
  交給 Claude 濃縮 (a one-shot `claude -p`, previewed, originals archived).
- User feedback on the M3 build: mouse drag reorder of sessions / projects / groups and Finder folders as
  projects, interface zoom (⌘+ / ⌘− / ⌘0, UI 字級 10–20), layout fixes at the minimum window and at zoom 20,
  the app icon, the CODD name.
- Open for the user (docs/M4-REPORT.md §6): the 繁體中文 manual checklist (注音, a real claude session with
  `/mcp`, the real `~/.claude.json` registration, real mouse drags).
- Post-M4 (docs/M4-REPORT.md §13, user decisions 2026-10-18): derived data in `<dataRoot>/cache/` (notes index,
  annotated renders; not backed up, may be rebuilt); ⌘L composer images deleted 24 h after their last send (kept
  while an unsent draft names them; terminal pastes stay in libghostty's temp staging); background launches keep
  every window behind other apps' windows (`BackgroundWindows`, checked with a window-stack watcher); a live Dock
  tile (the amber cell blinks 3 times when a session starts needing you, then stays lit); `ONLY=<ids>` e2e section
  selection and `scripts/TEST-MAP.md`.

## M5 — Hardening and release (built 2026-10-19; see docs/M5-REPORT.md and docs/M5-PLAN.md)
- Onboarding (§7.14, the frozen Onboarding artboard): a first-launch wizard only on a new standard data root
  (detect claude / cswap / hooks / data root / MCP, import projects from `~/.claude.json` read only with
  suggested groups, tidy CODD web's legacy hooks through the Hook 差異 dialog, the fixed notes location and
  the M4 registration, cswap accounts, the notification permission); reopened from 說明 › 首次啟動設定… and
  Settings › 關於. Packages CoddOnboarding (models, catalog, views, demo).
- Identity: bundle id `app.codd.CODD`, `VERSION` 1.0.0, build = commit count; CODD's own defaults copied once on
  the standard root; test runs never write CODD's defaults (D25); a login-item hint after the id change.
- Data versioning: every JSON file has a version; one launch preflight (CoddDataStore) migrates after a backup
  (no migration registered yet), never overwrites a newer CODD's file (read as far as possible), moves corrupt
  user data aside with one banner each, removes corrupt derived data, rebuilds `cache/` on a VERSION change;
  never stricter than a file's own store.
- Performance: `scripts/m5-perf.sh` measures every ARCHITECTURE budget (the GPU total while animating changed to
  < 550 MB with the measured reason: the Metal driver's per-process pool); the hot tier is a segmented LRU (F5).
- Compatibility: `scripts/m5-compat.sh` runs the current client against holders built from the M1 and M4 commits.
- Release: `scripts/release.sh` (Release build, ad-hoc signing unless an Apple Development or Developer ID
  identity is asked for with `--identity` / `RELEASE_IDENTITY`, verify, zip, `--install` to /Applications by the
  user only). No Sparkle / notarization.
- Accessibility (VoiceOver labels and roles, Full Keyboard Access focus rings, menu items for every click-only
  action, an automated audit), the copy audit (`scripts/tools/copy-audit.py`), the window-stack watcher in every
  e2e script, final docs (README, 繁體中文 user guide, ARCHITECTURE, this roadmap).
- The post-M4 carried bug is fixed: a stop pressed while a session is STARTING is applied once its holder is up.
- Testing (user rule 2026-10-18): components and integration steps compiled only; one wrap-up test run runs every
  script, fixture selftest, package suite and the app suite once, and its failures go to a fix agent
  (docs/M5-REPORT.md §3 lists the commands). The milestone is committed after that run is green.
- Open for the user: the 繁體中文 manual checklist in docs/M5-REPORT.md §6 (VoiceOver, Full Keyboard Access, the
  installed Release on the real data root, `--install`, the login item) and the questions in §7.

## Post-M5 feedback (2026-10-19, the user's note "CODD 接下來可以修正的問題")
- Notes editor: the caret stays put after Return and typing (restyle after the edit pass), blank lines keep a full
  body line, a new note opens on the body line under `# `.
- The session drawer edits its note in place (a second NoteEditorController kept in step with the Notebook's);
  text that cannot be saved goes to HISTORY, else a new note, else the editor refuses to leave.
- MCP `notes_create` (new INBOX note linked to the session and project, AI APPEND, at most 100,000 characters,
  not in the allow list so Claude Code asks); toast `Claude 建立了筆記：<title>` that waits for an UNDO toast.
- Sidebar: a hover `+` on project rows starts claude there at once; ⌘N's model defaults to
  `預設（跟隨 Claude Code 設定）` (no `--model`; no profile migration, the built-ins never named a model); a folder
  dropped from Finder (or ⌘O) is revealed, selected and pulsed, new or not.
- Every extra terminal opens in the bottom panel (⌘T, strip `+`); tabs close with ✕, their menu or ⌘W, asking only
  while a program runs; old top-strip tabs move to the panel at discovery.
- STATUS ACCOUNTS: compact cards that reflow at any width (views redraw during live resize); a cswap install /
  upgrade guide on STATUS, Settings › 帳號 and onboarding step 5 (`uv tool install claude-swap`, copy, type into a
  terminal without Return, re-detect); the auto-switch warning plus a confirmation on every OFF→ON.
- Scripts that launch CODD drop the CODD session variables they inherit (`scripts/lib/zorder-guard.sh`).

## Later (not scheduled)
- Remote (§7.15) beyond the static "future" placeholder; a `coddd` launchd agent (needs a real signing identity).
- Developer ID signing, notarization and Sparkle updates (needs a Developer ID and an update host).
- Relocating the data root or the notes folder (onboarding shows the fixed location today).
- Registered data migrations once a file format changes (the M5 registry is empty; every file is version 1).
- Whatever the wrap-up run, the review and the manual checklist of M5 turn up.

### M5 scope as planned (2026-10-16, kept for reference)
- Onboarding (§7.14): claude / cswap detection, hooks, notification permission, data location.
- Performance budgets measured (ARCHITECTURE): GPU memory while animating (M1 review F2), hot-tier policy (F5),
  launch time, idle CPU, switch time; fixes or documented budget changes.
- Data versioning and migration (layout.json, panes.json, config.json, notes index), corrupt-file recovery,
  compatibility test of the current client against holders built from earlier commits.
- Release packaging: `scripts/release.sh` (Release build, ad-hoc signing unless an identity is asked for with
  `--identity` / `RELEASE_IDENTITY`, install to /Applications). No Sparkle / notarization (needs a Developer ID and an update host).
- Accessibility (VoiceOver labels, keyboard navigation), UI copy audit, final docs (README, 繁體中文 user guide).
- Remote (§7.15) stays a static "future" placeholder.
- Carried over from post-M4 review: a stop pressed while a session is still STARTING (no holder yet) is ignored;
  remember it and apply it once the holder spawns.
- Testing (user rule 2026-10-18): each change runs only what `scripts/TEST-MAP.md` maps it to; every script, fixture
  selftest and package suite runs in full once, at the end of M5 before release.
