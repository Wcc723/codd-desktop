# CODD Desktop — Architecture (native Swift, local only)

Source of truth for implementation. Product/UX spec: `design/SPEC.md` (§8–§9 override earlier sections).
Research behind these decisions: `design/research/native-swift/` (synth.md + critique.md).

## Decisions (2026-10-15, updated for M1 2026-10-16, M2 and M3 2026-10-17, M4 2026-10-18, M5 2026-10-19)

- Native Swift, macOS 26.0+, built with Xcode 27 / Swift 6.4. Local only (no remote / tunnel for now).
- UI: AppKit shell (NSOutlineView sidebar, NSSplitView, NSStatusItem + non-activating NSPanel, ⌘K NSPanel).
  SwiftUI only for leaf views (settings forms, sheets) via NSHostingView. `@Observable` models.
- Terminal engine: **libghostty** (decided in M1, see docs/M1-PLAN.md): `Lakr233/libghostty-spm` pinned
  `2.2.2026101301`, its MIT Swift wrapper vendored into `Packages/CoddTerminal/Sources/GhosttyWrapper`
  (CODD patches marked `CODD:`, kept as `Vendor/GhosttyWrapper-CODD.patch`) so replay uses
  `ghostty_surface_write_buffer_replay` without reflection. SwiftTerm is dropped. The app talks to the
  engine only through `CoddTerminal.TerminalEngine` (one per PTY) and the pane's `TerminalSurface` slots.
- Sessions survive app quit / crash / update: every PTY is owned by a tiny **`codd-holder`** process
  (one per PTY: a session's own, and each shell tab). The app spawns holders; holders outlive the app.
  Reboot → `claude --resume <Claude session id>`.
- Hook endpoint: the **app** hosts it (`Packages/CoddHooks`), since M1. **`coddd` is deferred** (M2
  decision D10, revisit with signing in M5): the app already hosts the endpoint and the holders keep
  sessions alive across quits, so a background agent would add little today; an `SMAppService` agent
  needs a real signing identity (CODD is ad-hoc signed, TCC and launchd attribute agents by it); and it
  would duplicate the registry watcher and the state engine the app runs anyway (two writers of the
  same hook records). While CODD is not running, hooks of running sessions go unanswered (Claude
  ignores a failed http hook) and states are caught up from the registry and holder EXIT at the next
  launch. If it comes back it uses the same package, plus cswap polling, auto-switch and note
  indexing, and never owns a PTY.
- One CODD per data root (M2, D9): `<dataRoot>/codd.lock`, see "App: robustness and lifecycle".
- State detection = port of CODD web `configs/hooks/status-writer.js` `applyEvent` (exact semantics, golden tests).
- Real mode is the default (Debug and Release); mock data only with `-codd-mock` (screenshots, self tests).
- Signing: ad-hoc (`-`) for Debug builds. Release (M5 D18, `scripts/release.sh`): ad-hoc by default; an
  Apple Development or Developer ID Application identity only when asked (`--identity "<name>"` or
  `RELEASE_IDENTITY`, matched against `security find-identity -v -p codesigning`), with a warning that
  the certificate's name and Team ID end up in every published copy's signature (a keychain identity is
  never picked up on its own); every Mach-O stripped of its debug map (`strip -S`, no build-machine
  paths), then signed with the hardened runtime (`--options runtime`), `scripts/release.entitlements` on
  CODD.app and codd-holder and the matching purpose strings in Info.plist; the helpers re-signed with
  their own identifiers before the app (never `--deep`). Debug builds keep the runtime off. No
  notarization, no Sparkle. A launchd agent (coddd) would still need
  a real identity.
- Dependency pinning: the app's package graph (libghostty-spm with its prebuilt GhosttyKit, DisplayLink,
  GRDB) is pinned by the tracked `App/Package.resolved` (excluded from the app's sources); release.sh
  copies it into the generated workspace's `swiftpm/Package.resolved` and builds with
  `-onlyUsePackageVersionsFromResolvedFile`, so a moved upstream tag fails the build instead of linking
  another engine. A deliberate dependency change resolves once without the flag and copies the new file
  back. Release output is refused inside the repository except under the ignored `build/`.
- Licenses: CODD is MIT (`LICENSE`). `THIRD-PARTY-NOTICES.md` (a CODD target resource, opened from
  Settings › 關於 › 第三方元件授權) holds the full texts for everything shipped: the Swift packages, what
  GhosttyKit links (Oniguruma, simdutf, Highway, Wuffs, libxev, libvaxis, z2d, zig-objc, zf, uucode and
  its Unicode tables, Zig std, GNU libintl; found with `nm -U` on the Release binary and from the
  `dependencies` of Ghostty's `build.zig.zon` at the pinned commit) and the fonts (JetBrains Mono, Space
  Mono, Symbols Nerd Font); the two OFL texts also ship next to the fonts in `Contents/Resources/Fonts`.
  z2d (MPL-2.0) and libintl (LGPL-2.1) ship as executable code only: every release that publishes the
  zip attaches their source tarballs (the notices' "Source of the MPL-2.0 and LGPL-2.1 parts";
  `scripts/release.sh` prints them with their SHA-256).
- M2 (all reversible; the full list D1–D31 is in docs/M2-PLAN.md §1 and docs/M2-REPORT.md §7):
  - **Composer** = a native AppKit `NSTextView` (TextKit 1) in `Packages/CoddComposer`, IME-safe
    (every key through `interpretKeyEvents`); prompts reach the PTY through the holder's
    `input.paste` capability (bracketed paste + a submit 50 ms later), never through the terminal
    engine's own paste.
  - **Claude's files stay read-only** (registry, transcripts, settings.json, `.claude.json`); the
    one exception is `刪除對話紀錄…`, which moves one conversation's files to the macOS Trash.
  - **External sessions** come from the registry `<claudeDir>/sessions` only (no `claude agents
    --json`), are read-only and are never persisted; a folder CODD does not know gets a transient
    project that is never saved.
  - **Launch profiles** live in `<dataRoot>/profiles.json`; a session records the profile that ran.
  - **No new wire version**: every holder addition is a capability (`input.paste`); `proto` stays 1.
  - **Ring replay from disk** for a session whose holder is gone; **UNREACHABLE** is an overlay
    flag, not a session state.
- M3 (all reversible; the full list D1–D38 is in docs/M3-PLAN.md §2 and docs/M3-REPORT.md §7):
  - **Accounts come from cswap's own state files, read only** (`~/.claude-swap-backup`:
    `sequence.json`, `cache/usage.json` schema 2, `configs/` for the plan, `sessions/<n>-*` for
    pinning) plus `<claudeDir>/../.claude.json`'s identity; CODD runs only `cswap switch <n> --json`,
    `cswap add --slot n --alias a`, `cswap alias`, `cswap --version` and, only on an explicit
    refresh while the state files are unusable, `cswap list --json` (D1). E-mails are matched in
    memory inside the reader and never stored, logged, dumped or shown (D2, D31).
  - **Quota comes from Claude Code's status line, never from the usage API**: every CODD claude
    session gets a `statusLine` in `--settings` that runs `codd-statusline` (no Foundation, like
    codd-hook), which POSTs `rate_limits` to the app's endpoint (`/statusline`) and chains the
    user's own status line (D8, D9); cswap's cache is the second source. `<dataRoot>/quota.json`
    keeps the newest window per account and its source (D7).
  - **Attribution by `CLAUDE_CONFIG_DIR`**: `default` → the active account (with a 90 s grace and a
    weekly-reset fingerprint around switches), `cswap-<n>` → account n, `cfg-<hash>` of a known
    profile → that account (D6).
  - **Direct switching with UNDO** (R3), confirmation only when Settings asks for it (D5); auto-switch
    is CODD's own engine on CoddCore's policy, default OFF, cooldown persisted (D13, D37).
  - **Claude's `settings.json` is written only by the installer**, on an explicit `套用並備份` after
    a diff, with a backup next to the file, refusing a file changed since the preview, keeping key
    order, indentation and number spellings (D10, CoddClaudeSettings). CODD Desktop needs no global
    hooks; the optional global status line is the guarded D11 wrapper.
  - **Pinned sessions** run with `CLAUDE_CONFIG_DIR=<cswap run profile>` and no auth-override
    variables; CODD never runs `cswap run` (it prints the e-mail) (D12).
  - **One design system package** (`Packages/CoddUI`, D30) used by the app and the STATUS,
    Settings and dialogs packages; **preferences** live in `<dataRoot>/preferences.json` (D14).
  - **Isolation of automated runs**: on any data root but the standard one CODD has no cswap, no
    cswap state root, no `claude --version`, no login item and no global hotkey unless DEBUG flags
    name them, and logs every external program it runs (`exec <tool> path=… sub=…`, D3, D21, D22,
    D28, D38).
- M4 (all reversible; the full list D1–D41 is in docs/M4-PLAN.md §2 and docs/M4-REPORT.md §7):
  - **Notes are Markdown files in `<dataRoot>/notes/`** (never inside a project), pasted images in
    `assets/<note-id>/`, CODD's own state in `notes/.codd/`; a YAML-subset frontmatter patched line by
    line (unknown keys and comments kept), ids that never change, file names never renamed (D1–D4).
    The index `<dataRoot>/cache/notes-index.sqlite` (GRDB 7.11.1, FTS5 `trigram`, `LIKE` for 1–2
    character CJK terms) is derived and rebuilt when missing, corrupt or of another version (D5, D6); an
    FSEvents watcher picks up other programs' edits (D7). Since post-M4 every rebuildable file lives in
    `<dataRoot>/cache/` (the index, burned-in annotated images), user data stays where it is ("Data root").
  - **Editors are TextKit 1** (`NSTextView` forced off TextKit 2): the Notebook's live-preview
    Markdown editor (CoddTextKit) and the file editor's code view (CoddCodeEditor), both IME-safe by
    the M2 composer's rules; highlighting is native lexers, no WebView, no tree-sitter (D11, D28).
  - **The MCP server is in the app, on the hook port** (`POST /mcp`, Streamable HTTP, stateless,
    JSON replies), with `/hooks/prompt` (codd:// expansion as UserPromptSubmit `additionalContext` +
    `systemMessage`) and `/n/<id>.md` (a per-note token URL) on the same listener (D16, D19, D15).
    CODD sessions get a per-session `<sessionDir>/mcp.json` (0600, a literal HMAC token) through
    `--mcp-config` placed right before `--settings`; it only adds `codd` (or `codd-desktop` when the
    user's config has another `codd`) to the user's own servers (D18). AI OFF notes are invisible to
    every AI path; project notes are visible to sessions in that project (advisory: a Bash tool can
    read any file) (D17).
  - **Registration into Claude Code** writes `~/.claude.json`'s `mcpServers.codd` only on the user's
    `套用並備份`, under Claude's own lock, rebasing onto bytes Claude rewrote meanwhile, with a backup
    next to the file (D22); Codex gets a snippet to copy (CODD never writes `~/.codex`).
  - **The file editor writes only on ⌘S**; git is read only (`--no-optional-locks`, no fsmonitor);
    PostToolUse paths mark AI-touched files; SHOW AI CHANGES diffs against git HEAD (D24–D27).
  - **Retention moves things automatically, only reversibly**: notes ACTIVE → STALE → ARCHIVE, stopped
    sessions archived, old rings of archived sessions to the trash, the user's trashed notes purged
    after 30 days, each with a first-run grace for sessions (D29, D30); one app trash function: the
    macOS Trash only on the standard data root, a folder on every other root (D38).
    交給 Claude 濃縮 runs a one-shot `claude -p` with no tools but `notes_read` (D32).
  - **Automation never touches the user's desktop state**: pasteboard writes go to a private
    pasteboard in background runs, nothing is revealed or opened (D39), and a background run's
    windows always stay behind every other app's windows (post-M4, "Background launches" below).
  - **User feedback (2026-10-18)**: sidebar drops are planned from the pointer (sessions, projects,
    groups, and Finder folders becoming projects); an interface zoom (UI 字級 10–20, ⌘+ / ⌘− / ⌘0)
    scales Typeface fonts and design lengths and refreshes every window in place (terminals keep their
    own size); layouts fold or hide pieces by priority at the minimum window and at zoom 20.
- M5 (reversible; the full list D1–D25 is in docs/M5-PLAN.md §1):
  - **Bundle id `app.codd.CODD`** (user decision 2026-10-18; supersedes design/SPEC.md §10's "internal
    identifiers unchanged for now"): every configuration, tests `app.codd.CODDTests`, helpers signed
    `app.codd.codd-holder` / `codd-hook` / `codd-statusline`; queue labels, the signposter subsystem, the
    private pasteboard (`app.codd.CODD.private`), the sidebar drag type (`app.codd.sidebar-node`) and the
    zoom notification (`app.codd.CoddUI.UIZoomDidChange`) take the new prefix through
    `App/Support/CoddIdentity.swift`. The legacy id stays only where an older build must still be
    recognised: the show-window request (posted and observed under both names), `BackgroundWindows`
    (either id is CODD) and the one-time defaults copy (D2: on the standard data root only, before any
    window, CODD's own keys of the legacy domain replace the new domain's until the marker
    `CODDDefaultsMigratedFrom` is set; the legacy domain is only read). Versions: `MARKETING_VERSION`
    (= the repo's `VERSION`) and `CURRENT_PROJECT_VERSION` feed `CFBundleShortVersionString` /
    `CFBundleVersion`.
  - **Test runs never write CODD's defaults** (D25): on any data root but the standard one and in mock
    mode the main window frame (`CODDMainWindow`), the split view frames and the status item position
    (`CODDStatusItem`) are neither restored nor saved (`DefaultsIsolation.autosavesLayout`), so e2e,
    perf and agent runs never move the installed CODD's window, split or menu bar position.
  - **Every data file has a version and one preflight checks them** (D14, "Data root" below).
  - **A stop asked for while a session is STARTING is kept** (D20): `HolderSessionStore.pendingStops`
    applies it through the normal stop path once the holder is up and connected.
  - **A first-launch wizard, only on a new standard data root** (D5–D13, "App: onboarding" below): it
    reads, never writes, until the user presses 下一步 on step 2 (the sidebar), 套用並備份 (dialog B) or
    註冊 (the M4 dialog); it ends with `onboarding.json` and reopens from Settings › 關於 and 說明.
  - **The hot tier resists scans** (D15): `TerminalTierPolicy` is a segmented LRU (probation 2 + protected
    4 = the same 6 hot surfaces); a terminal shown ≥ 5 s or revealed from hot again is protected, a quick
    flip (⌃Tab, ⌘K) only churns probation (injected monotonic clock; the pool and the App are unchanged).
  - **Budgets are measured by a script** (D16, `scripts/m5-perf.sh`, "Performance budgets" below); a
    miss is fixed or the budget changed here with the measured reason (the GPU total while animating was).
  - **Release packaging** (D18): `VERSION` → `MARKETING_VERSION`, `git rev-list --count HEAD` →
    `CURRENT_PROJECT_VERSION`; `scripts/release.sh` builds (packages pinned by `App/Package.resolved`),
    signs inside-out (ad-hoc unless `--identity`), verifies, zips and installs to `/Applications` only
    when the user runs `--install` outside Claude Code (the old app goes to the Trash through
    `/usr/bin/trash`).
  - **Holder compatibility is proven by a script** (D19): `scripts/m5-compat.sh` builds `codd-holder` from
    the M1 and M4 commits in temporary git worktrees and runs the current client (`codd-holder-compat`)
    against each; wire protocol v1 and the ring layout are unchanged.
  - **Accessibility** (D21): every interactive element has a VoiceOver label; custom controls take
    keyboard focus only with Full Keyboard Access (like AppKit buttons) and draw the helmet focus ring only
    for keyboard focus; every click-only action and rail destination has a menu item (no new key
    equivalents); CoddUI's `AccessibilityAudit` and the App's DEBUG `-codd-a11y-audit` check it.
  - **Copy audit** (D22, `scripts/tools/copy-audit.py`): no emoji (test data uses `\u{…}` escapes), no old
    product name or bundle id outside the allow list, no e-mail addresses, simplified-only characters or
    glossary variants in UI strings; English sentences are reported for review.
  - **Automated runs are watched** (D23): every script that launches CODD runs the window-stack watcher
    (`scripts/lib/zorder-guard.sh`, only this build's windows count) and fails on a violation.

## Repository layout

```
App/                      CODD.app sources (AppKit). Generated project: CODD.xcodeproj (from project.yml)
  Real/                   real-mode store (HolderSessionStore + External / Launch / Layout / Accounts /
                          Ephemeral), launcher, hook pipeline, layout and pane persistence, launch
                          profiles, instance lock; M3: CswapAccountStore, AutoSwitchRunner,
                          ClaudeSettingsService, PreferencesService, StatusPageData, HostLineService,
                          AccountDialogs (A, C), HookDiffDialog (B), FileEventWatcher
  Lifecycle/              M3: QuitPolicy, QuitDialogController (D), LoginItems, HotkeyService, VersionProbe
  Terminal/               PtyConnection (one holder stream per PTY), TerminalHub (engine pool, shell tabs,
                          ring replay, running lamp poll)
  Session/                pane, tab strip, ⌘J panel, composer bar, Home, STATUS area (StatusArea), banners
  Sidebar/                outline, snapshot, hover card, new-group editor, drag & drop, menus
  Palette/                ⌘K quick switch; NewSession/ ⌘N sheet + resume picker; Settings/ window
                          (SettingsCoordinator, SettingsInfoBuilder, 啟動設定檔)
  MenuBar/ Window/ Controls/ Theme/ (StateStyle) Model/ Mock/ Debug/ (DEBUG tools) Tests/ (app tests)
  AppNotifier.swift, SessionNotifier.swift   notifications (one UNUserNotificationCenter delegate, D29)
  Notes/                  M4: NotesService (the notes library, lists, search, selection), NotesAreaViewController
                          (+Features / +Annotate / +Files / +Cleanup: the NOTES area's four modes),
                          NoteEditorController (editor binding, autosave, conflicts, paste), NotebookPresenter,
                          NoteImages, NoteAnnotateMapping, NoteSending (D14), NotesDrawerController, NotesDump
  MCP/                    M4: MCPService (server on the hook port, clients, registrations), NotesMCPBackend
                          (D17 visibility), PromptExpansion + NoteURLResponder, MCPSessionInjection (D18),
                          MCPRegistrationService (D22, D23)
  Files/                  M4: FileEditorService (+Diff / +Models / +Drawer), FileTab, FilesModeView, FilesDump
  Cleanup/                M4: RetentionService (D29, D30), CleanupState (cleanup.json), CleanupDigest, CleanupController
                          + CleanupPresenter (the Cleanup page), CondenseRunner + CondenseProcess (D32)
  Support/                M4: AppTrash (D38), CoddPasteboard (D39); M5: CoddIdentity (D1), DefaultsIsolation
                          (D2, D25), LaunchTiming (D16)
  Onboarding/             M5: OnboardingLaunch (the D5 gate), OnboardingFacts (probes → package facts),
                          OnboardingController, OnboardingPresenter, OnboardingWindowController; wiring in
                          AppDelegate+Onboarding.swift
  Real/DataFilesMonitor   M5: the launch preflight and the post-load aside sweep (D14; AppDelegate+Data,
                          HolderSessionStore+Data for the banners)
  AppDelegate+Accessibility.swift, Controls/KeyFocusControls.swift, Theme/StateSpeech.swift,
  Debug/AccessibilityAuditPass.swift   M5: menu items, keyboard focus, spoken state, the -codd-a11y-audit pass
  AppDelegate+Notes / +Send / +Files / +Cleanup / +Zoom.swift   M4 wiring and DEBUG actions per area
  AppIcon.icon            the app icon (Icon Composer document; actool writes AppIcon.icns)
Tools/codd-holder/        Xcode tool target wrapper (main.swift → HolderMain.run())
Tools/codd-hook/          Xcode tool target wrapper (main.swift → HookCommandMain.main())
Tools/codd-statusline/    Xcode tool target wrapper (main.swift → StatusLineMain.main()), M3
Packages/CoddHolder/      SwiftPM: CoddProtocol (wire protocol), CoddHolderCore (holder), CoddHolderClient
                          (HolderStream, spawner, discovery, binary installer, ring file reader), codd-holder,
                          codd-holderctl
Packages/CoddCore/        SwiftPM: CoddCore (models, layout store, hook state machine, registry, launch builder,
                          cswap client; M2: transcript catalog, fuzzy matcher, external session detector,
                          launch profile store; M3: cswap state reader, account keys, aliases, quota book /
                          store / attribution, weekly pace, account assembler, e-mail redaction, status-line
                          injection, cswap process detector) + golden tests
Packages/CoddTerminal/    SwiftPM: CoddTerminal (libghostty engine, pool, config) + vendored GhosttyWrapper,
                          codd-term-demo. See Packages/CoddTerminal/README.md
Packages/CoddHooks/       SwiftPM: CoddHooks (hook server incl. M3 `/statusline`, config.json, registry watcher,
                          state engine), CoddHookClient + codd-hook + codd-statusline (M3). See its README.md
Packages/CoddComposer/    SwiftPM (M2): CoddComposer (⌘L text view, field, history, composer.json, payload
                          encoding, path escaping) + codd-composer-demo (manual 注音 check)
Packages/CoddUI/          SwiftPM (M3, D30): the Phosphor Console design system (theme, controls, M3
                          primitives) + codd-ui-gallery
Packages/CoddPreferences/ SwiftPM (M3): preferences model + preferences.json store
Packages/CoddClaudeSettings/ SwiftPM (M3): order-preserving JSON, Claude settings inspection, the installer
                          (plans, diffs, backups), the user's status-line chain (D35)
Packages/CoddHost/        SwiftPM (M3): host metrics (CPU, memory, disk, swap, battery), history, main-thread
                          latency probe
Packages/CoddStatusUI/    SwiftPM (M3): the STATUS sidebar and page + codd-status-demo
Packages/CoddSettingsUI/  SwiftPM (M3): every Settings section, hotkey recorder and Carbon global hotkey +
                          codd-settings-demo
Packages/CoddDialogsUI/   SwiftPM (M3): dialogs A–D and their presenter + codd-dialogs-demo; M4: the
                          registration diff (dialog B's title / footer) and SnippetDialogView (Codex)
Packages/CoddNotes/       SwiftPM (M4): the notes library (actor NotesLibrary: storage, frontmatter, ids,
                          GRDB index + CJK search, FSEvents watcher, history, assets, annotations + burn-in
                          renderer, retention, cleanup candidates, references, AI text). Depends on GRDB 7.11.1
Packages/CoddMCP/         SwiftPM (M4): transport-free MCP JSON-RPC server (tools, resources, prompts,
                          negotiation, caps) over an MCPNotesBackend protocol; golden fixtures
Packages/CoddTextKit/     SwiftPM (M4): the TextKit 1 live-preview Markdown editor, block parser, read-only
                          renderer, code highlighter + codd-markdown-demo
Packages/CoddCodeEditor/  SwiftPM (M4): the code view (gutter, lexers, find / replace, inline diff hunks,
                          overview ruler) + codd-code-demo
Packages/CoddFiles/       SwiftPM (M4): CoddFiles (read-only git, tree, text codec, watchers, saver, line diff,
                          recent / AI-touch stores) and CoddFileEditorUI (tree, tabs, toolbar, banner, status
                          items, dirty-close sheet) + codd-files-demo
Packages/CoddNotebookUI/  SwiftPM (M4): the Notebook chrome (lists, note list, top bar and menus, chips, info
                          panel, doc status, prompt footer, drawer, history compare, pickers) + codd-notebook-demo
Packages/CoddAnnotateUI/  SwiftPM (M4): the ImageAnnotate screen + codd-annotate-demo
Packages/CoddCleanupUI/   SwiftPM (M4): the Cleanup page (tabs, table, bulk bar, CONDENSE and POLICY cards)
                          + codd-cleanup-demo
                          (M4 changes to older packages: CoddCore launch MCP config + session retention +
                          tool file paths; CoddHooks `/mcp`, `/hooks/prompt`, `/n/<id>.md`, MCPAuth, mcpToken;
                          CoddComposer reference chips; CoddClaudeSettings the `~/.claude.json` MCP installer and
                          the Codex snippet; CoddUI UIZoom, RowFit; CoddSettingsUI 08 / 09 / 12 rows;
                          CoddStatusUI the MCP SERVER card; CoddPreferences the zoom ranges)
Packages/CoddOnboarding/  SwiftPM (M5): CoddOnboarding (flow, environment report, project catalog read from
                          `.claude.json`, group suggester, import plan, onboarding.json store, samples; Foundation
                          only) and CoddOnboardingUI (the frozen Onboarding artboard) + codd-onboarding-demo
Packages/CoddDataStore/  SwiftPM (M5): the data file inventory, DataPreflight (versions, migrations, aside,
                          cache/VERSION), VersionGuard, DefaultsDomainMigration (Foundation only)
                          (M5 changes to older packages: CoddUI KeyboardFocus + AccessibilityAudit; every UI
                          package's labels and keys; CoddTerminal the segmented-LRU tier policy and the
                          occlusion override; CoddHolder the codd-holder-compat executable; CoddComposer,
                          CoddClaudeSettings and CoddHooks never overwrite a newer file; CoddCore
                          LayoutStore.loadNewerReadOnly; CoddSettingsUI the 關於 onboarding row)
Spikes/TermSpike/         Terminal engine spike app (separate Spikes/project.yml → Spikes/TermSpike.xcodeproj)
design/                   Design spec, artboard sources, research
docs/                     This file, the roadmap, the M0–M5 plans and reports, USER-GUIDE.zh-TW.md (the user guide)
scripts/                  m1-smoke.sh (shell holders), m1-e2e.sh (claude pipeline with fake-claude.sh),
                          m2-e2e.sh (M2 end to end: 13 runs, fake claudes only), m3-e2e.sh (M3 end to end:
                          A1–A14, fake claudes and a fake cswap only), m4-e2e.sh (M4 end to end: B1–B13 +
                          U1 / U2, the C11 fakes only), m4-sidebar-dnd.sh, m4-ui-zoom.sh, m4-layout-sweep.sh
                          (user-feedback checks; the sweep renders PNGs of every screen at several sizes),
                          M5: m5-e2e.sh (O1–O3, D1–D3, K1, S1, A1, C1, I1), m5-perf.sh (the budgets),
                          m5-compat.sh (M1 / M4 holders), release.sh (Release, signing, zip, --install),
                          TEST-MAP.md (what to run for a change)
scripts/m5-fixtures/      make-import-fixture.sh (made-up projects, .claude.json, transcripts), README.md
scripts/lib/, scripts/tools/   zorder-guard.sh (sourced by every script that launches CODD), zorder.sh +
                          zorder-watch.swift + zorder-selftest.sh (window-stack watcher), copy-audit.py +
                          copy-audit-allow.txt
README.md, VERSION        developer overview (build, test, release); the marketing version (1.0.0)
scripts/m4-fixtures/      make-notes.sh, make-png.py, make-git-project.sh, make-claude-json.sh, age-layout.py,
                          mcp-client.py, mcp-script-session.jsonl, fake-claude-m4.sh (MCP, prompt hooks, tool
                          edits, print mode), mock-codd.py, selftest.sh, README.md
scripts/m2-fixtures/      make-root.sh (a data root with its own hook port), fake-claude-m2.sh,
                          fake-external-claude.sh, make-transcripts.sh, seed-layout.sh, selftest.sh, README.md
scripts/m3-fixtures/      make-cswap-state.sh (cswap 0.26 state in its exact formats), fake-cswap.py,
                          fake-claude-m3.sh (status line runner, fake /login), make-claude-settings.sh,
                          rate-limits.sh, selftest.sh, README.md
```

Build commands:
- Packages: `swift build --package-path Packages/CoddHolder` / `swift test --package-path Packages/CoddHolder`
  (also CoddCore, CoddHooks, CoddTerminal, CoddComposer, the M3 packages CoddUI, CoddPreferences,
  CoddClaudeSettings, CoddHost, CoddStatusUI, CoddSettingsUI, CoddDialogsUI (`--skip PresenterTests`)
  and the M4 packages CoddNotes, CoddMCP, CoddTextKit, CoddCodeEditor, CoddFiles, CoddNotebookUI,
  CoddAnnotateUI, CoddCleanupUI, and the M5 packages CoddOnboarding, CoddDataStore; use `--scratch-path` per
  agent when building concurrently).
- App: `xcodegen generate && xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build`
- End to end: `scripts/m1-e2e.sh`, `scripts/m1-smoke.sh`, `scripts/m2-e2e.sh`, `scripts/m3-e2e.sh`,
  `scripts/m4-e2e.sh`, `scripts/m5-e2e.sh` (`CODD_APP=<binary>`, `KEEP=1`, `ONLY=<ids>`), `scripts/m5-perf.sh`,
  `scripts/m5-compat.sh`; release: `scripts/release.sh [--dry-run] [--output <dir>] [--identity <name>] [--install]`; fixtures: `scripts/m2-fixtures/selftest.sh
  [--with-app <binary>]`, `scripts/m3-fixtures/selftest.sh`, `scripts/m4-fixtures/selftest.sh`. Manual runs on a
  throwaway root: `scripts/m2-fixtures/make-root.sh <dir>`, then `-codd-data-root <dir>
  -codd-claude-dir <temp>`.
- Spike: `cd Spikes && xcodegen generate && xcodebuild -project TermSpike.xcodeproj -scheme TermSpike -derivedDataPath ../build/spike build`

## Process model

```
CODD.app ──posix_spawn(SETSID, CLOEXEC_DEFAULT)──▶ codd-holder (1 per PTY) ──forkpty──▶ claude … | $SHELL -l
   │  AF_UNIX stream ⇄ holder socket <dataRoot>/run/<8hex>.sock      (HolderStream, one per PTY)
   │  hosts the hook endpoint 127.0.0.1:<port from config.json> ◀── http hooks (claude, per-session --settings)
   │                                                            ◀── codd-hook (SessionStart command hook)
   │                                         POST /statusline ◀── codd-statusline (claude's statusLine command,
   │                                                                per session; or the optional global wrapper)
   │  watches <claudeDir>/sessions/<pid>.json (registry, read only), also each cswap profile's sessions/
   │  reads ~/.claude-swap-backup (FSEvents + 15 s poll, read only) and <claudeDir>/../.claude.json
   │  runs cswap switch / add / alias / --version (short-lived, logged `exec cswap path=… sub=…`)
   │  M4, same listener and port:      POST /mcp ◀── claude (per-session --mcp-config <sessionDir>/mcp.json,
   │                                                 X-CODD-Session + HMAC token) and registered external
   │                                                 clients (X-CODD-Token / Bearer = config.json mcpToken)
   │                              POST /hooks/prompt ◀── claude's UserPromptSubmit (codd:// expansion)
   │                                 GET /n/<id>.md?t ◀── a browser / curl (per-note token, AI OFF → 404)
   │  M4: runs git read only in folders the user opened (`-C <root> --no-optional-locks -c core.fsmonitor=false`,
   │      5 s timeout, logged `exec git path=… sub=…`) and, for 交給 Claude 濃縮 only, one
   │      `claude -p … --strict-mcp-config --mcp-config <dataRoot>/run/condense-<id>/mcp.json` child in its own
   │      process group (stdin / stdout files in that folder, removed when it ends; logged `exec claude … sub=-p`)
   │  M4: watches <dataRoot>/notes (FSEvents, 200 ms) and each open file (DispatchSource)
   │  holds <dataRoot>/codd.lock (flock) for its whole life: one CODD per data root
   │  (deferred) NSXPC ⇄ coddd (SMAppService agent) taking the endpoint over
```

Since M4 the MCP server, the prompt expansion and the note URL live inside the app (CoddMCP's
`MCPServer` behind `MCPService`, CoddHooks routes them): while CODD is not running, sessions keep
working but Claude marks `codd` failed until `/mcp` reconnects (no stdio bridge in M4).

Closing the main window does not stop anything: CODD keeps running with its menu bar item and Dock
icon, the hook endpoint stays up, holders and their connections stay, terminals keep parsing but stop
rendering (occluded) until the window is shown again (Dock click, menu bar `開啟 CODD`, ⌥⌘0 (⌘0 since
M4 is 實際大小), ⌘K, ⌘N, or a second instance's show-window request). ⌘Q flushes the hook records, releases the port
and the lock, closes the connections and exits; holders keep running and the next launch reattaches.

The app spawns holders from `<dataRoot>/bin/codd-holder-<sha256 prefix 12>` (copied out of the bundle at
launch, unused copies collected) and bakes `<dataRoot>/bin/codd-hook-<sha256 prefix 12>` into every
claude session's `--settings`, so app moves, rebuilds and updates never touch a running session's files.
Since M3 the same holds for `<dataRoot>/bin/codd-statusline-<sha256 prefix 12>`, the status line command
in every claude session's `--settings`, POSIX single-quoted (`'<path>'`, a `'` written `'\''`: Claude's
statusLine has no `args`, so there is no exec form, and the standard data root has a space): claude
runs it as `/bin/sh -c <command>` with the session's
environment (`CODD_HOOK_URL`, `CODD_HOOK_TOKEN`, `CODD_SESSION_ID`, `CODD_STATUSLINE_CHAIN`); it reads
stdin, starts the chained user command in its own process group with the same stdin (its stdout goes to
claude unchanged and its exit status is codd-statusline's), POSTs `{v, session_id, config_key,
rate_limits}` to `/statusline` within 300 ms (skipped when there is no endpoint), waits for the chain
(≤ 10 s) and exits. Nothing CODD prints reaches claude.

### Data root

Default `~/Library/Application Support/CODD` (Debug and Release); `-codd-data-root <dir>` /
`CODD_DATA_ROOT` override (tests always use a temp root; keep it short, socket paths must fit 104 bytes).

**USER DATA or DERIVED** (user decision 2026-10-18). USER DATA (what CODD cannot rebuild) survives every
update; a format change migrates it in place after a backup. DERIVED data (rebuildable) lives in `cache/`
(0700, never in Time Machine): any update may delete `cache/` and CODD rebuilds what it needs. A DERIVED
entry outside `cache/` is either *runtime* (a running holder, session or the user's status-line wrapper
names its path) or not moved yet; an update leaves those where they are.

**Versions and the launch preflight** (M5 D14, docs/M5-PLAN.md §2.2). Every JSON file CODD owns
carries an integer version (`version` or `v`, 1 at M5; a `composer.json` without `v` counts as 1) and is
listed with its store's own load rules in CoddDataStore's `DataInventory`. Real mode runs one
`DataPreflight` off the main actor first thing in its start task, before preferences, panes, layout,
profiles, notes or accounts read anything: an older file with a registered migration is backed up
(`<name>.v<from>-backup-<yyyyMMdd-HHmmss>`, 0600, never overwritten) and migrated (none is registered at
M5); a newer file is left untouched and reported, and its store reads it as far as it can without ever
saving over it (layout.json is shown read-only through the v1 decoder, panes.json decodes leniently and is
never replaced (`VersionGuard` right before each write), composer.json keeps its draft in memory, the
backups index and config.json are not rewritten); corrupt USER DATA is moved to `<name>.corrupt-<epoch ms>`
(never deleted) and defaults are used; corrupt DERIVED data (`quota.json`, `hooks/*.json`,
`sessions/*/answer.json`) is removed; `config.json` and `notes/.codd/notebook.json` are only reported
(their stores repair or never parse them). Symlinks, non-regular files, files over 16 MiB and I/O errors
are skipped, never "corrupt". Safety rule: the preflight is never stricter than a file's store (a file
its store would load without moving it aside is never moved; App test `M5NeverStricterTests` saves
through every real store on a temp root and expects `scan()` to read each file as current and `run()` to
change no byte). Each issue becomes one queued problem banner (`▲ <file> …` with `[知道了]`, which shows
the next one; a moved file adds `[在 Finder 中顯示]`, which reveals it on a user click only and is logged
and skipped in background runs). After the stores loaded, `DataPreflight.asideFiles(createdSince:)`
finds the `.corrupt-<ms>` files the stores themselves made during this launch (a schema error the
preflight cannot see) and banners each one not reported yet. `cache/VERSION` (text, `1`): another number or
an unreadable file wipes the cache's contents (rebuilt on use); a missing one is just written (the
post-M4 cache layout is version 1). `onboarding.json` (USER DATA, `v`, M5 I2) is inventoried already.
Logs: `data preflight files=<n> current=<n> migrated=<n> newer=<n> corrupt=<n> removed=<n> ms=<x>` and one
`data <status> file=<relative> …` line per file that is not current (names only, never contents).

```
<dataRoot>/
  bin/codd-holder-<hex12>       DERIVED (runtime). Holder copies (GC: unused by any running process, not
                                marked in use by a running app, ≥ 5 min since the last install)
  bin/codd-hook-<hex12>         DERIVED (runtime). SessionStart hook copies (GC: not named in any live
                                holder's argv, not marked in use by a running app)
  bin/codd-statusline-<hex12>   DERIVED (runtime). Status line command copies (M3, D8; GC like codd-hook)
  bin/codd-statusline           DERIVED (runtime). The stable copy the optional global wrapper (D11) names;
                                replaced through a rename when the bundle's bytes differ, never collected
  run/<8hex>.sock               DERIVED (runtime). Holder sockets
  sessions/<session-uuid>/      USER DATA. A session's own holder: meta.json, ring, holder.log (the whole
                                sessions/ folder is excluded from Time Machine, M1)
  sessions/<session-uuid>/answer.json        DERIVED (runtime). A waiting claude session's prompt detail
                                (app, 0600), restored on relaunch; goes with the session directory
  sessions/<session-uuid>/spawn.env          DERIVED (runtime). The child's environment for the holder's
                                --env-file (0600, holds the hook token); removed as soon as the holder started
  sessions/<session-uuid>/composer.json      USER DATA. The ⌘L composer's draft + history (M2, D3;
                                CoddComposer ComposerStateFile: ≤ 100 entries, 0600, atomic, written 500 ms
                                after the last change and at quit; goes with the session directory)
  sessions/<session-uuid>/attachments/       USER DATA, temporary. Pasted images (M2, D4): <yyyyMMdd-HHmmss>-
                                <6 hex>.png, dir 0700, files 0600; the composer inserts the escaped path (D31).
                                Post-M4 (user decision 2026-10-18): a file goes once no unsent draft (of any
                                session) names it and 24 h have passed since its last send (since it was
                                written, when never sent); the clock is the file's mtime, set again at every
                                send, right before its bytes go out. Swept at launch (every session folder)
                                and after each send of that session, off the main actor; only regular files
                                with CODD's names, no links followed. Goes with the session directory as
                                before; Cleanup does not count it
  sessions/<session-uuid>/tabs/<tab-uuid>/   USER DATA. Its shell tabs: main-strip tabs and ⌘J panel tabs
                                (not listed as sessions; which strip a tab belongs to is panes.json's business)
  sessions/<session-uuid>/codd-ephemeral     USER DATA. M3, D24: marks dialog C's temporary login shell;
                                such a session is never in layout.json, and a leftover one (crash) is ended
                                and its directory deleted at the next launch
  sessions/<session-uuid>/mcp.json           DERIVED (runtime). M4, D18: the claude session's MCP config
                                {"mcpServers":{"codd"|"codd-desktop":{"type":"http","url":"http://127.0.0.1:
                                <port>/mcp","headers":{"X-CODD-Token":<HMAC-SHA256(hook token, "codd-mcp-v1:"
                                +uuid)>,"X-CODD-Session":<uuid>}}}}, 0600, atomic, rewritten at every launch /
                                RESUME / RESTART, removed when 自動掛載 MCP is OFF; goes with the session directory
  layout.json                   USER DATA. Groups → projects → sessions, order, colors, pins, collapse,
                                archive, kind, current Claude session id (RESUME), launch profile, launch
                                options, lastViewedAt (CoddCore LayoutStore; written atomically, debounced,
                                never over a newer version; UUIDs are written upper case, read in either
                                case). Never holds external sessions or transient projects (M2)
  panes.json                    USER DATA. Tab strip and ⌘J panel per session (tab ids = tab holder ids).
                                Version 1; M2 adds `panelTabs`, `panelSelected`, `panelMaximized`,
                                `composerOpen` and still writes `panel` (= the shown panel tab) for an M1
                                build (D13); decoding is tolerant per field and per tab entry
  config.json                   USER DATA. Hook endpoint port + 32-byte hex token (0600; CoddHooks
                                HookConfigStore). Created on first use: 47821 or the next free port up to
                                47899 for the standard data root; any other root (-codd-data-root /
                                CODD_DATA_ROOT) gets a free port of 43000-43999 (searched from a random
                                point), so test and throwaway instances never take the port the user's
                                sessions post to (D24, log `hooks port-range=test`). An existing file is used
                                as is. M4 adds "mcpToken": 64 hex, the external MCP token (registered clients,
                                note URL tokens); added at the first M4 start, replaced by 輪替 (D23)
  codd.lock                     DERIVED (runtime). Single-instance lock (M2, D9): flock(LOCK_EX|LOCK_NB)
                                held for the app's life, content {"pid":…,"app":"<bundle path>","startedAt":ms},
                                0600
  profiles.json                 USER DATA. Launch profiles (M2, D5; CoddCore LaunchProfileStore):
                                {"defaultProfileId","profiles":[{id,name,kind,defaultModel?,
                                defaultPermissionMode?,extraArguments,shellPath?,environment}],"version":1},
                                sorted keys, 0600, atomic. Written with the 4 built-ins on first read; an
                                unreadable file is moved aside to profiles.json.corrupt-<ms>; a newer version is
                                read-only (never replaced)
  hooks/<session-uuid>.json     DERIVED (not moved yet). Last hook record per session (state engine cache,
                                restored on relaunch)
  quota.json                    DERIVED (not moved yet). M3, D7: {"v":1,"accounts":{"<n>"|"default":
                                {fiveHour,weekly:{usedPercent,resetsAt,source statusline|cswap,capturedAt},
                                scoped,scopedCapturedAt,pace,identity}},"autoSwitch":{"lastAt"}} (D37);
                                identity = 16 hex of a domain-separated FNV-1a 64 of the slot's e-mail +
                                organization (tells logins apart, never the e-mail); 0600, atomic, written 2 s
                                after a change (at most 15 s while changes keep coming), at once for
                                autoSwitch.lastAt, and at quit
  preferences.json              USER DATA. M3, D14 (CoddPreferences v1): every Settings value, sorted keys,
                                2-space, 0600, atomic, written 300 ms after the last change and at quit;
                                unknown keys kept, a newer version read-only, a corrupt file moved to
                                preferences.json.corrupt-<ms>. Not written until something changes
  claude-settings-backups.json  USER DATA. M3, D10: {"v":1,"backups":[{name,reason,at,settingsPath}]} (newest
                                200), one entry per installer write; the backups themselves sit next to
                                Claude's settings.json as settings.json.codd-bak-YYYYMMDD-HHMMSS[-n]
  notes/                        USER DATA. M4, D1 (0700): the notebook, never excluded from backups.
                                `<yyyy-MM-dd>-<slug>.md` notes (sub-folders allowed),
                                `assets/<note-id>/<hash6>.<ext>` pasted images (+ `.orig.<ext>`). Files 0600
  notes/.codd/                  USER DATA. notebook.json (marker), state.json (opened / open count /
                                keepUntil, written 1 s after a change), activity.jsonl (AI reads / appends /
                                expansions / URL reads), history/<id>/ (snapshots, D8), trash/ (the user's
                                TRASH, restorable), tombstones.json
  notes/.codd/tmp/              DERIVED (runtime). Temp files of atomic note writes, emptied at open
  cache/                        DERIVED (post-M4, user decision 2026-10-18): 0700, excluded from Time Machine,
                                created at launch off the main actor; may be deleted by any update
  cache/VERSION                 DERIVED. M5 D14: the cache layout's version as text (`1`); another number wipes
                                the folder's contents at launch, a missing file is written (no wipe)
  cache/notes-index.sqlite (+ -wal, -shm)    DERIVED. M4, D5: the notes index (GRDB, FTS5 trigram),
                                rebuilt when missing / corrupt / another version. An M4 build kept it next to
                                notes/; that copy is removed at launch (log `notes legacy-index removed …`)
  cache/annotated/<hash12>-<stem>.annotated.png   DERIVED. D10: the burned-in copy of an annotated image;
                                <hash12> = SHA-256 of the image's standardized path. Never written beside an
                                image or in notes/; xattrs: the block's SHA-256, the source path, the note id.
                                Collected at launch when the source image is gone or the note is no longer
                                indexed, rendered again when a note needs it (also before a composer send
                                whose draft names a missing copy, post-M4)
  files/recent.json             USER DATA. M4: recent local files (≤ 20, 30 days)
  files/ai-touches.json         USER DATA. M4, D26: AI-touched paths from PostToolUse (7 days, ≤ 2,000)
  files/unsaved/<stamp>/        USER DATA. M4 fix: unsaved file-tab buffers a quit that could not ask kept (0600)
  cleanup.json                  USER DATA. M4, D30 / D31: {"v":1,"sessions":{<uuid>:{keepUntil}},"files":
                                {<path>:{keepUntil}},"digest":{"lastShownAt","lastCount"},"retention":
                                {"firstRunAt","lastRunAt"}}; 0600, atomic, a corrupt file moved aside, a newer
                                `v` read only
  run/condense-<uuid>/          DERIVED (runtime). M4, D32: one condense run's mcp.json (0600), stdin /
                                stdout / stderr; removed when the run ends (and at quit)
  onboarding.json               USER DATA. M5 §2.3, D7: written when the wizard ends (開始使用, 略過 on step 6,
                                its window closed; never on ⌘Q in the middle, never in mock mode): {"v":1,
                                "completedAt","appVersion","build","steps":{"detect":"done|skipped|todo",…},
                                "imported":{"projects","groups"},"notifications":"granted|denied|notAsked|
                                suppressed"}, 0600, atomic, sorted keys; a newer `v` is never replaced. Its
                                presence (like layout.json, panes.json or a session) makes the root "not new" (D5)
  trash/                        USER DATA. M4, D38: the app trash on any non-standard data root without
                                -codd-trash-dir (purged notes, rings, holder.log, unused images); the standard
                                root uses the macOS Trash; every move logs `trash target=system|folder name=…`
```

Claude's own files are read, never written, with two exceptions: `<claudeDir>/sessions` (registry),
`<claudeDir>/projects` (transcript folders, "last used", and since M2 the transcripts themselves:
titles, branches, last prompts), `<claudeDir>/settings.json` (`cleanupPeriodDays` and `model`, M2;
since M3 also `statusLine` and `hooks`: the status-line chain is read at every launch, RESUME and
RESTART in D35 precedence: `<cwd>/.claude/settings.local.json`, `<cwd>/.claude/settings.json`, then
the user file; the installer inspects the hooks) and `<claudeDir>/../.claude.json` (`projects` keys =
recent folders; since M3 `oauthAccount` for the active cswap account, matched in memory, and the plan).
The exceptions: `刪除對話紀錄…` (D23) moves one conversation's files to the macOS Trash (since M4 through
the app trash, D38: a folder on any non-standard data root) on the
user's typed confirmation (see "App: sessions data"), and the M3 installer (D10) writes
`<claudeDir>/settings.json` only on the user's `套用並備份` in the Hook 差異 dialog, after a backup next
to the file (see "App: STATUS and the installer"). M4 reads `<claudeDir>/../.claude.json`
(`<CLAUDE_CONFIG_DIR>/.claude.json` for a pinned session) and `<cwd>/.mcp.json` for MCP server names
only (D18, names never logged), and adds a third exception: the MCP registration (D22) writes
`mcpServers.codd` of `~/.claude.json` only on the user's `套用並備份` in its dialog, under Claude's lock,
after a backup next to the file (`.claude.json.codd-bak-…`), on the standard data root only (any other
root: only a DEBUG `-codd-claude-json` file, refused when it resolves into the real home). `~/.codex` is
never written (the Codex snippet is copied by the user). cswap's state root (`~/.claude-swap-backup`) is read
only; `credentials/` and the Keychain are never touched. `<claudeDir>` is `~/.claude`;
`-codd-claude-dir` / `CODD_CLAUDE_DIR` override it for tests (it does not change what a started
claude uses); `-codd-claude-settings` overrides the settings file, `-codd-cswap-root` /
`-codd-cswap-path` cswap's (DEBUG).

Session directory: `<dataRoot>/sessions/<session-uuid>/`
- `meta.json` — written by the holder (atomic rename). Discovery is via meta.json, never by scanning sockets.
- `ring` — mmap ring buffer of PTY output (8 MiB for claude sessions and shells in M1).
- The sessions folder is excluded from Time Machine (`NSURLIsExcludedFromBackupKey`).

### App: terminals, sessions, states (M1)

- **PtyConnection** (`App/Terminal`): one `HolderStream` (HELLO with takeover) per live PTY for its whole
  life. Without an engine it is a control connection (title, cwd, bell, exit still arrive, so cold tabs
  keep the sidebar current); attaching an engine replays from the latest resync point, detaching sends
  DETACH. OUTPUT goes from the stream's queue straight into `TerminalEngine.feed/replay` (`PtySink`);
  keys and query replies go from libghostty's IO thread straight to `sendInput`. Terminal bytes never
  touch the main actor. Drops reconnect with backoff while meta.json says the holder runs (after the
  backoff, every 10 s, never giving up on a live holder); a reconnect asks **without** takeover and a
  `busy` answer (after one retry 500 ms later) ends the connection as taken over, so two clients never
  fight over a holder; the backoff resets only after a connection held for 5 s. Keys typed while
  reconnecting are held (320 KiB since M2, so one composer send fits) and sent behind the next
  HELLO. TITLE / CWD reach the main actor latest-wins, one hop at a time (a title loop cannot
  saturate it). The engine's backlog crossings
  (pause at 4 MiB unparsed, resume at 1 MiB) are delivered one at a time with the state current when
  they run, and applied under the sink's lock, so the stream's pause flag always ends at the engine's
  state.
- **TerminalHub**: `TerminalPool` of engines — visible, up to 6 hot (occluded, still streaming), the rest
  cold (surface disposed, replayed when shown). M5 D15: the hot set is a segmented LRU (probation 2 +
  protected 4; a terminal shown for ≥ 5 s or revealed from hot again is protected, a quick flip stays in
  probation and is evicted first), so a ⌃Tab / ⌘K scan never evicts the session the user worked in. An evicted engine is detached and hidden at once and its
  surface freed 150 ms later, one per main-queue turn (freeing costs 5–16 ms; the switch does not pay
  it). Owns the shell-tab holders. A new session's terminal is created and pinned before its holder
  starts and released at the first DA1 reply (startup probes). Replayed history passes through a
  filter that removes OSC 52 (clipboard) sequences: history is shown, never executed.
- **HolderSessionStore** (`App/Real`): the real `SessionStore`. Launch = CoddCore `LaunchBuilder` argv
  (`--session-id` / `--resume`, per-session hooks `--settings`) + the login environment minus a
  deny-list + `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` / `CODD_HOOK_URL` + TERM variables, spawned through
  the holder. Relaunch: discovered holders are reattached; a claude session whose holder is gone is
  `STOPPED · 可接續` (RESUME = `claude --resume <latest hook session_id>`), a shell is `EXITED` (RESTART).
- **HookPipeline**: `config.json` → `HookServer` (127.0.0.1 only) and `RegistryWatcher` → actor
  `SessionStateEngine` → batches (≤ 10 Hz) applied to the view models on the main actor. A busy port or a
  failed listener is a visible degraded state (status bar, STATUS page, hollow menu bar icon); states
  then come from the registry and holder EXIT only, the bind is retried (2, 3, 5, then every 10 s), and
  claude sessions started meanwhile get **no** hook settings and no token (they would go to whoever
  holds the port). "Another CODD" is reported only when `/health` proves the token (HMAC challenge).
  Wire contract: `Packages/CoddHooks/README.md`.
- Attention (waiting + error) drives the rail badge, the Dock badge, the Dock tile (below), the menu
  bar icon and macOS notifications (→ WAITING / → ERROR of a session the user is not looking at;
  Settings › 通知).
- **Dock tile (post-M4, user decision 2026-10-18).** Normally `NSApp.dockTile.contentView = nil`: the
  Dock shows the system-rendered bundle icon (`App/AppIcon.icon`, the user's icon style respected;
  CODD never sets `applicationIconImage`). `AttentionMonitor` (which also writes the badge) owns a
  `DockTileController` (`App/MenuBar/DockTile.swift`) on the menu bar's attention condition
  (`sessions.contains { $0.state.needsAttention }`; the count is what matters): entering attention,
  and again whenever the count grows, the tile shows the d1 icon drawn by CODD with the amber cell
  blinking 3 times (`DockTileMachine`: dim, lit, dim, lit, dim at 0.6 s steps, then lit), then lit
  (full #FFB84A plus a soft amber glow) until no session needs the user, then `contentView = nil`
  again. A drop in the count lets a blink finish and keeps the tile lit. 暫停通知 (D23): neither
  blink nor lit tile (one wake-up at `pausedUntil` while it hides attention; entering attention
  after it blinks). Reduced motion as the lamps see it (`UITicker.pulsesAllowed`: Settings › 外觀 ›
  減少動態, else the system setting): no blink, straight to lit. No Dock icon
  (`NSApp.activationPolicy() != .regular`: 顯示於 Dock OFF or a background launch): nothing;
  `applyDockPolicy` calls `refresh()` after a policy change. Cost: no timer or display link outside
  a blink (a one-shot task per 0.6 s step), the frames are two pre-rendered 8-bit sRGB bitmaps
  (`DockTileArt`, 512 px at 256 pt, about 1 MB each, made when the tile first needs them and released
  when it is normal again) in one `NSImageView`, and `dockTile.display()` runs only when the frame
  changes. `DockTileArt` reproduces the system rendering on the macOS grid: the 1024 art in an 824
  px continuous-corner square (radius 210, fitted to the system shape) centered in the 1024 canvas,
  with its drop shadow and edge light approximated (comparison: `build/post-m4-dock/compare.png`).

### App: robustness and lifecycle (M2)

- **Single instance (D9, D28).** Real mode opens `<dataRoot>/codd.lock` (`O_CREAT | O_CLOEXEC |
  O_NOFOLLOW`, 0600; the data root is created 0700 when missing) and takes `flock(LOCK_EX | LOCK_NB)`
  in `applicationWillFinishLaunching`, before the store starts, the hook pipeline reads config.json,
  binaries are installed or collected, or any holder is contacted (the app delegate's, store's, hub's
  and services' initializers touch nothing on disk). The fd stays open for the app's life; the
  kernel releases the lock when the process ends, so the file of a crashed CODD is simply locked
  again. A second instance on the same data root reads the owner pid from the file (waiting up to
  300 ms for a starting owner to write it): when `NSRunningApplication(processIdentifier:)` finds
  it, it activates it, posts the distributed notification `app.codd.CODD.showMainWindow` (and, M5 D1,
  the same request under the legacy bundle id's name, `CoddIdentity.showMainWindowNames`) with
  `object` = the canonical (realpath) data root, logs `another-instance pid=<n> root=<root>` and
  exits 0 without a window; otherwise it shows `另一個 CODD 正在使用這個資料夾` and exits. The lock
  holder observes both names for its own root only and shows its main window (log
  `show-window requested`), so a new build launched while an older one holds the lock brings that one
  forward, and the other way round. A lock that cannot be created at all is an alert and an exit too (never
  run unlocked). Mock mode takes no lock; different data roots run side by side.
- **Problem banner.** `HolderSessionStore.problem: StoreProblem?` (message, time, optional session)
  is set by `report(_:detail:surface:sessionID:)` (every report is also logged as `error …`):
  discovery failures, a session taken over by another CODD, a shell tab that cannot start. The pane
  shows `▲ <message> · 12s 前` `[知道了]` above the session banner when the problem is about no
  session in particular or about the one shown, and on the home page. What another view already shows
  passes `surface: false`: the ⌘N sheet's refusals (returned through `lastRefusal`) and a session's
  own launch-error banner.
- **UNREACHABLE (D8).** An overlay, not a state: hook and registry states keep flowing while the
  socket does not. `PtyConnection` starts an outage clock at a drop or a connect attempt and stops it
  at WELCOME; when it has run for `unreachableAfter` (5 s) and meta.json says the holder runs, it
  reports `.unreachable(true)` once, and `.unreachable(false)` right before the next WELCOME. A
  stopped holder is noticed by the stream's keepalive (PING after 10 s idle, closed after 30 s
  more), a handshake that never completes by the 5 s handshake timeout. The store sets
  `SessionVM.unreachableSince` (archived sessions too): row pill `Unreach` and line 2
  `holder 無回應 · 30s`, header chip `◌ UNREACHABLE · 30s` in the danger color, pane banner
  `▲ holder 沒有回應 · 每 10 秒重試一次，畫面與狀態可能不是最新的` `[↻ 立即重試]` (`retryNow()`:
  skips the backoff or a pending handshake). Reconnects never take over: after a SIGCONT the
  holder may still count a stale client for a moment; the `busy` answer is retried once 500 ms later
  before a session counts as taken over. DEBUG `-codd-unreachable-after <s>`,
  `-codd-keepalive <idleMs>,<timeoutMs>` (every connection, shell tabs too).
- **Dead-session replay (D7).** When a session's own terminal is created and its PTY has no
  connection, or its connection ended because the holder is gone (killed, or an exited session's
  holder that quit), and the session is neither starting nor external, `TerminalHub` reads
  `<sessionDir>/ring` with `RingFileReader` off the main actor (the same start a live holder's
  WELCOME `resync` would pick). Back on the main actor, if the same engine is still bound to the key
  and no live connection appeared: `reset()`, the modes' restore sequence, the bytes through
  `replay` (OSC 52 removed, no replies), the dim footer `// holder 已結束 · 以上是最後的畫面（唯讀）`,
  then `childExited` so keys go nowhere. No usable ring: the M1 note. A replayed engine that a new
  process attaches to (RESUME, RESTART, discovery) gets `rebuildForNewProcess()` first, so nothing
  of the old screen is mixed in. A taken-over session (the holder still runs elsewhere) keeps the M1
  note. Log `replay session=… bytes=… ms=…`.
- **Window lifecycle (D10).** `MainWindowController.onVisibilityChange` reports close, miniaturize,
  app hide (false) and show (true); `TerminalHub.setWindowOccluded` then occludes every shown
  terminal without changing the tiers (they stay hot and resume rendering on show; a terminal shown
  while the window is away is occluded too). Measured (Debug build, this Mac, a shell printing a line
  every 100 ms, CPU time over 10 s): app 0.2 % with the window closed, 2.6 % with it visible.

### App: sessions data (M2)

- **External sessions (D6, D27).** `HookPipeline`'s registry pump hands every `RegistryWatcher`
  snapshot (live entries only; the watcher's stream has one consumer) to the state engine and then
  to the main actor (`onRegistry`). `HolderSessionStore.applyRegistry` runs CoddCore's
  `ExternalSessionDetector` with what this CODD owns (`ownedProcesses()`):
  - the child pids of its claude holders (live ones), the current and initial Claude session ids
    of its claude sessions (the CODD id is the initial `--session-id`), and the pids of its claude
    holders: a registry entry matching any of them is CODD's own claude, also before WELCOME told
    the pid (a claude registers early) and whatever `/clear` did to its id. A stopped session counts
    only while its holder may still run: its conversation resumed by hand elsewhere is another
    process and shows as EXT;
  - the pids of its shell holders (shell sessions, and every shell tab via the hub's
    `shellTabHolders` provider): a claude with one of them among its ancestors (sysctl parent chain,
    ≤ 8) is EXT with `在 CODD shell 中` and `[前往 shell]`;
  - `sdk-*` and `claude-desktop` entrypoints are hidden.
  Ownership changes (WELCOME, a spawn, a tab started or ended) re-run the detector on the latest
  entries in the next main-actor turn. Externals live in `externalByID` (id `ext-<pid>-<startedAt ms>`,
  stable across `/clear`), never in `sessionsByID`: `session(_:)` and `allSessions` include them (live,
  NEEDS YOU, Dock badge, menu bar icon count them), but persistence, hook-engine registration,
  spawning, archive, stop, answer, rename, tag, pin, layout intents and `SessionNotifier` see CODD
  sessions only, and the menu bar panel never offers `[1 允許]` for them. View model: kind claude,
  title = registry `name` (else `claude`), state from the registry status (busy / idle / waiting with
  reason, `unknown` without one), `stateSince` = `statusUpdatedAt`, `externalInfo` (pid, kind,
  entrypoint, Claude session id, version, host session / tab). The pane is read-only: header, banner
  `EXT 外部啟動的 session，唯讀狀態偵測 · 偵測自 <claudeDir>/sessions`, no tabs, no terminal (a
  comment with the pid and entrypoint, and `最近 prompt：…` from the transcript, read off the main
  actor), no answer bar; ⌘J / ⌘T / ⌘W beep. Its row menu offers only `複製 session ID`,
  `$  複製 resume 指令`, `↗  在 Terminal.app 開啟`; rows are never dragged and drops are clamped to
  the CODD rows above them.
- **Transient projects.** An external whose folder (symlinks resolved on both sides, realpaths
  cached; a subfolder is another folder) is no project gets a `ProjectVM` with `isTransient` at the
  end of 未分類; it is removed when its last external goes and is never written (`LayoutMapping.layout`
  skips it, and every session id without a record). `promoteTransient` makes it a saved project
  (keeping its externals) before a CODD session is created in, adopted into or added as that folder
  (`createSession`, `adopt`, `addProject(path:)`) and on `加入為專案`; `project(forPath:)` falls back
  to the realpath match for that. Transient projects are not ⌘N choices, do not count for the empty
  state, cannot be dragged or removed, and saved projects always sort before them.
- **Stale (D15).** IDLE for more than `staleAfter` (3600 s; DEBUG `-codd-stale-after`) sets
  `SessionVM.isStale`, recomputed on every transition and every 60 s (CODD and external sessions).
- **Launch profiles (D5).** `LaunchProfiles` (`@MainActor @Observable`, App/Real) reads
  `profiles.json` off the main actor during `start()` (before `isLoaded`), exposes the document,
  claude / shell profiles and the default, validates edits with `LaunchProfileEditing`
  (upsert, delete, duplicate, set default; saves in call order off the main actor) and pushes every
  change into `HolderLauncher.profiles` / `defaultProfileID`. A claude launch uses the named claude
  profile, else the default when it is a claude profile, else the first claude profile; shell
  sessions and shell tabs use the first shell profile (its `shellPath` and environment, blocked names
  dropped as for claude), else the built-in `zsh`; `-codd-shell-argv` still wins. A new session's
  layout row records the profile that actually ran. Mock mode uses an in-memory instance.
- **Launch requests.** `NewSessionRequest` carries `claude.profileID` (nil = default),
  `claude.remoteControl` (D22: `--remote-control` appended once unless the profile passes it; not
  remembered for RESUME), `claude.mode = .resume(<Claude session id>)` from the resume picker
  (`--resume <id>`, the row's `claudeSessionId` = that id, title from the transcript unless named;
  `.restart` is refused) and `sessionID` (the id the ⌘N preview showed: used as the CODD and, for a
  new conversation, Claude session id when no session, layout row, session directory or live claude
  has it, else a fresh one).
- **Transcripts (D18, D20, read only).** One `TranscriptCatalog` per store over
  `<claudeDir>/projects` (head / tail reads, mtime + size cache). `AppServices.transcripts(for:)`
  lists a folder's conversations off the main actor and reuses the list for 10 s unless a session
  was created or resumed since (`transcriptsGeneration`); `inUseClaudeSessionIds` = running CODD
  claude sessions' current ids + live registry entries; `claudeSettings` is
  `ClaudeUserSettings.read(<claudeDir>/settings.json)`, read once; `lastPrompt(for:)` = the latest
  `UserPromptSubmit` hook's prompt (`HookPipeline.onPrompt`, one line, ≤ 200 characters, memory only,
  `SessionVM.lastPrompt`), else the transcript's `last-prompt` record. That is a display form only:
  `resendPrompt(for:)` (D26) is the same hook's prompt whole (`SessionVM.resendPrompt`, ≤ 256 KiB),
  else `TranscriptCatalog.resendablePrompt` (the newest user prompt, uncut, from the last 1 MiB;
  nil for an image or several text blocks). `TranscriptCatalog.list(cwd:limit:)` counts only listed
  conversations (`sdk-*` and other-cwd files do not use up `limit`), reading at most
  `limit * 4 + 64` files; `transcript(sessionId:cwd:)` looks one conversation up by id.
- **One conversation, one claude.** RESUME, a picked transcript and 刪除對話紀錄 refuse a Claude
  session id another claude runs (`isConversationRunning`: a live CODD claude session other than the
  one asked for, or any live registry entry) and wait for the registry's first snapshot (at most
  2 s, `waitForRegistry`). A picked transcript a stopped CODD session already has resumes that
  session instead of creating a second one (an archived one is refused: restore it first).
- **Archive (D19).** `unarchive(_:)` puts archived sessions back after their project's CODD sessions
  (pins kept) and saves; `archivedSessions(inProject:)` lists them, most recently active first.
- **刪除對話紀錄 (D23).** Only for a claude session that is not running (no live holder) and whose
  Claude session id (and CODD id when different) no live claude uses. `TranscriptCatalog.files`
  gives `<claudeDir>/projects/<folder>/<id>.jsonl` (only when its lines carry the session's folder)
  and its sibling `<id>/` folder; never a symlink, never a path outside `<claudeDir>/projects`. They
  are moved off the main actor through the store's `trash` closure (default
  `FileManager.trashItem`; tests and DEBUG `-codd-trash-dir <dir>` move into a folder instead, so
  automated runs never touch `~/.Trash`), then the session leaves CODD (log
  `delete-history session=… files=n`). A file that cannot be moved is a problem banner and the
  session stays. A shell session has no transcript and just leaves. The alert asks for the typed
  session name; the done toast says `✕ 對話紀錄已移到垃圾桶`.

### App: sidebar, Home, quick switch (M2)

- **Sidebar** (`App/Sidebar`). `SidebarSnapshotBuilder` turns the store into a pure
  `SidebarSnapshot` (TREE: NEEDS YOU + `◇ n 個待看`, PINNED, tinted group blocks, projects,
  未分類, `[+ 新增群組]`; STATE: Needs you, Working, Ready, Idle (`n stale`), Shell, Stopped with
  glyph heads and line 2 `lead · ■ project`); the outline applies diffs, so state changes never
  reorder the tree. The filter (case-, width- and diacritic-insensitive substring of the title,
  project or group name) narrows every section, NEEDS YOU and PINNED included. The inline new-group
  row has its own color popover (1–8, 0 = none; digits are never taken from a composing input
  method); group headers show `清理已停止 (n)` · `+` · `⋯` on hover. The drawn amber drop line
  replaces NSOutlineView's gap feedback and follows its drop when rows move; externals are never
  dragged and drops clamp to the CODD rows (since M4 the drop is planned from the pointer, see
  "App: sidebar drag and drop, interface zoom, layout"). The hover card is a borderless, non-activating child
  panel that ignores the mouse: 380 ms after the pointer rests on a session row, 10 px right of the
  sidebar, hidden while a menu tracks, during a drag, after a click and when the window resigns
  key; it follows its session through observation. Archive shows a 5 s countdown toast with Undo;
  `封存 n ▸` restores. ⌘P (pin) and ⌘. (stop, always confirmed) are main-menu items that
  `CoddTerminalSetup.keyEquivalents` makes a focused terminal decline (also under 注音), like ⌘L.
- **Home** (`App/Session/HomeModel.swift`, `HomeCards.swift`). A pure `HomeModel` (counts, NEEDS
  YOU cards with `[1 允許]` only for CODD permission waits, the DONE line, LAUNCH cards by latest
  activity then `.claude.json` suggestions, RECENTLY STOPPED = stopped CODD claude sessions plus
  transcripts no CODD session or live registry entry uses, 3 newest of each of the 6 most recent
  projects, USAGE) is rebuilt when the store changes; views are rebuilt only when the model
  changes, durations tick at 1 Hz. USAGE and the sidebar footer read the `AccountStore`, still the
  mock until M3: in real mode both say `· 示意資料，M3 接上 cswap` (D29).
- **Quick switch ⌘K** (`App/Palette`). `QuickSwitchModel` is pure: CoddCore `FuzzyMatcher` over
  session titles (the location counts half), project names (the path counts half) and actions;
  limits 8 / 5 / 6; an empty query lists NEEDS YOU, then recently viewed, then sidebar order. The
  palette panel is built once, stays live while open (re-ranks when sessions change) and claims
  ⌘⏎ (open with the ⌘J panel) and esc in `performKeyEquivalent`, before the main menu's 允許 can
  see ⌘⏎. Ranking waits while the field has marked text.

### App: composer (M2)

- **Bar.** `ComposerBarView` (CoddComposer `ComposerField` + hint row + `[SEND]`) sits in
  `TerminalAreaView` under the top terminal; ⌘L opens / focuses / closes it (`panes.json`
  `composerOpen`), Esc focuses the terminal. `PaneComposer` binds it to what the tab strip shows
  (claude's own PTY or a shell tab) and to that session's `ComposerStates` entry: draft and
  history from `composer.json`, read lazily off the main actor (edits made before the read are
  applied on top), saved 500 ms after the last change on one queue, flushed at quit. Externals
  have no composer; a PTY that is not live makes it read-only (`session 沒有在執行`).
- **Send path (D1, D2).** Enter → `ComposerEncoding.payload` (line endings → CR, controls removed,
  trailing whitespace trimmed, paste when the text has a newline or TAB, ≤ 256 KiB) →
  `TerminalInput.payload` → `TerminalSurfaceFactory.send(_:to:)` bound to the target the bar was
  pointed at → `TerminalHub` → `PtyConnection.send(_:submit:paste:)` → `HolderStream.sendInput
  (paste:)`. The holder brackets a paste when the child has `?2004` on and writes the Return 50 ms
  later. Input held while reconnecting keeps its paste flag (`PtySink.heldInputLimit` 320 KiB, so
  one full send fits). A sent text is recorded in the history and the field cleared; a refused one
  stays.
- **WAITING.** While the target is claude's own PTY and the session is WAITING (permission, plan,
  question), Enter and SEND send nothing (`Claude 在等你確認 · 先用下方按鍵回答`, checked again at
  the send): the prompt would read the text as its answer. The draft stays editable.
- **Images (D4, D31).** An image-only pasteboard becomes `<sessionDir>/attachments/<stamp>.png`
  (TIFF re-encoded and the file written off the main actor; the path goes in once the file exists,
  at the caret, or at the end of that session's draft when the field moved on; a missing session
  folder is never created) and the composer inserts the path escaped like a Terminal.app drop. A
  dropped file whose name has a line break or another control character is refused (beep).
- **Image expiry (post-M4, user decision 2026-10-18).** CoddComposer `ComposerAttachments`: a send
  (Enter / SEND, the error banner's resend, a note's 送出) first sets the mtime of every image the
  prompt names (`utimensat`, `AT_SYMLINK_NOFOLLOW`, on the main actor right before the PTY write): by
  name in the sending session's folder, and where an absolute path points when that is another
  session's `attachments/` under the same `sessions/` folder (a prompt copied between sessions). Only
  then is the text checked for gone images and sent; afterwards the session's folder is swept off the
  main actor: a regular file with CODD's name goes when its mtime is ≥ 24 h old and no unsent draft
  names it. The drafts are every session's (the draft and the text a ↑ walk stashed: the in-memory
  state, else the saved `composer.json` draft; names are unique, so one draft keeps an image in any
  folder). The launch sweep does the same for `HolderSessionStore.sessionDirectories` once the
  sessions are discovered and remembers the saved drafts it read for later send sweeps. A mark and
  each file's check-and-unlink of a sweep hold one lock, so a sweep running at the moment of a send
  either removed a file first (the send then sees it gone and never sends its path) or keeps it. One
  log line per sweep (`composer attachments sweep reason=launch sessions=… folders=… removed=…
  draft=… recent=… failed=…`, ` redated=…` when non-zero; `reason=send` only when the session has the
  folder). A path is found by its `attachments/<CODD name>` tail; it starts at its first `/` when
  words touch it (`看這張/Users/…`, the composer inserts a pasted path at the caret and Chinese has no
  spaces): everything up to the last character before that `/` that a relative path would not hold
  (anything but ASCII letters, digits, `._-~+@%=$` and backslash escapes) is the user's text. ↑ / ↓
  show an image whose file is gone as `[圖已過期]` (a muted chip, plain text like the note chips), and
  a send whose text still names a gone image is refused once with the field showing `[圖已過期]` in
  its place: a missing path is never sent (the resend and a note's 送出 send `[圖已過期]` in its place).
  The clock is the wall clock: a file dated more than 5 min after a sweep's now (a clock set ahead,
  then corrected) is dated back to now, so it stays at most 24 h after the clock is right again; a
  clock jumped forward cannot be told from the dates, and a sweep then removes images that are less
  than 24 h old in real time. Images pasted straight into the terminal are libghostty's own temp
  files and are not touched.
- **Annotated copies in drafts (post-M4).** 插入全文 puts a note's AI text, which names the
  burned-in copy `cache/annotated/<hash12>-<stem>.annotated.png` (DERIVED), into a draft and later
  into the history (user data). Before a composer send or a resend whose text names a copy that is
  gone (an update emptied `cache/`, the notebook's open dropped it), `PaneComposer.annotatedCopies`
  has the notes the text references (`codd://note/<id>`, the AI text's header line) render theirs
  again (`NotesService.restoreAnnotatedCopies`, inside the notes actor, the notebook opened when
  needed); the send then goes while the field still shows that text (a second Enter meanwhile sends
  nothing). A copy that does not come back (its note or image is gone, the reference was edited
  away) goes as `[圖已過期]`, refused once like a composer image.
- **Error banner actions (D26).** `↻ 重送上一則` resends the whole last prompt
  (`AppServices.resendPrompt(for:)`, never the one-line display form; nothing when only that is
  known) through the same path as paste + submit; `⟲ 稍後自動重試` arms one resend
  60 s later (`AutoRetryScheduler`, tied to the failure's `stateSince`; leaving ERROR or a new
  failure drops it). Nothing persisted.

### App: ⌘J panel tabs (M2)

- `PaneLayout` holds `panelTabs`, `panelSelected` and `panelMaximized` (D11, D13); panel tabs are
  shell-tab holders under `sessions/<id>/tabs/<tab>/` like main-strip tabs, and discovery never
  moves them into the main strip. Closing the panel keeps its tabs running; ⌘W with the panel
  focused (or maximized) closes its shown tab; the last one closes the panel. Maximize hides the top
  terminal (occluded, still hot, its restore size kept), the composer and the splitter.
- Tab labels are the shell's OSC title (one line, controls removed, ≤ 24 characters), else
  `zsh n`. A BEL from a PTY that is not on screen marks its tab `◆` until it is shown (D12, memory
  only). Titles and folders are observed per tab (`ShellTabFacts`), so a title another session's
  shell animates never re-renders the shown pane. The running lamp `●` (D25,
  `App/Terminal/ForegroundJob.swift`): a 1 Hz main-actor timer, only while the window is visible and
  some shell exists, reads the shown session's shells' `kinfo_proc` (again at once when another
  session is shown)
  (`sysctl KERN_PROC_PID`): running = `e_tpgid > 0 && e_tpgid != e_pgid`, and only while the
  shell's parent is still its holder (a reused pid never lights a lamp). About 35–41 µs per shell
  per poll (Debug). Shells without job control (`sh -c`, `cat`) never light it.

### App: new session and launch profiles UI (M2)

- **⌘N sheet** (`App/NewSession`). `NewSessionForm` is a pure model: a lowercase UUID chosen per
  sheet (the preview shows the id that will run and the request carries it), start new / resume /
  Remote Control, profile, model (`預設 (<x>)` names the profile's default, else Claude's
  settings.json `model`, D30), permission, name, color, group, and the command preview through
  `LaunchProfileEditing.commandPreview` (abbreviated on screen, full ids on copy). The project
  combobox's list is a borderless child window of the sheet (closes with it): Recent (5), then
  `.claude.json` suggestions with `+ 加入` (3; 20 + 10 with a query, scrolling), then
  `+ 選擇資料夾… ⌘O` pinned under the scrolling rows. A typed model claude would refuse (whitespace,
  a control character, a leading `-`) keeps `建立` from running. The resume picker lists
  `AppServices.transcripts(for:)` with the expiry warning; ids a running CODD session or a live
  registry entry uses are disabled `執行中`. The sheet window claims ⌘⏎, esc, ⌘O and ⌘W itself
  (checked against marked text first). Still a native titled sheet on the main window.
- **Settings › 啟動設定檔** (`App/Settings`). The profile list, the editor sheet (every field of
  a profile, a live preview line, one 繁體中文 message per `LaunchProfileIssue`) and the preview
  box go through `LaunchProfiles`, so profiles.json and the launcher update together. A copy is
  named `<name> 複本`; the last claude profile cannot be deleted; a newer profiles.json, one that
  could not be read, and any profiles.json before it was read are read-only (an edit then would
  save the built-ins over it). A hand-edited claude profile `LaunchBuilder` would refuse (a
  reserved flag, an invalid model or mode) stays listed but is skipped when a launch picks its
  profile (`LaunchProfileDocument.claudeProfile(id:)`), with a problem line saying which one.

### App: accounts, quota and the status line (M3)

- **Accounts (D1–D5, D25, D31).** `CswapAccountStore` (`App/Real`, `@MainActor @Observable`) is the
  real `AccountStore`. `CswapLocation.resolve` finds cswap (standard data root: Settings › 帳號 ›
  cswap 路徑, else `cswap` on the captured login PATH, else `~/.local/bin/cswap`; any other root:
  only DEBUG `-codd-cswap-path` / `-codd-cswap-root`, else no cswap at all, D3; the two DEBUG flags
  count only together, so a fake state never meets the real cswap). `cswap --version`
  must say ≥ 0.26. CoddCore's `CswapStateReader` runs off the main actor at start, on FSEvents of the
  state root (coalesced 300 ms), on a 15 s fingerprint poll (skipped when nothing changed) and as a
  full read every 5 min; the reader matches `.claude.json`'s identity against `sequence.json` in
  memory and its results carry no e-mail and no profile path. cswap's cache rows and status-line
  reports go into one `QuotaBook` (`quota.json`, D7). Each entry carries its slot's login identity:
  every read lines the book up with the slots (`QuotaBook.reconcile`: an entry follows its login
  after `cswap swap` / `move`, goes when no slot holds it, an identity-less entry of an older file
  goes where the slot's login is known, the D4 entry goes once cswap has accounts). Reports that
  arrive before the first read wait for it (newest per key). No `sequence.json` yet is `ready` with
  no accounts (dialog C adds the first). `AccountAssembler` merges the book with the state into
  `AccountVM`s in R7 order (plan chip, source and age, pace, usage health, `hasSessionProfile`,
  `profileStale`). `availability` is `loading` / `ready` / `noCswap` / `unsupported(version)` /
  `unreadable(reason)` / `pseudo` (D4: no cswap but status-line data for the global login gives one
  `— 目前登入` row); its note is the D1 / D3 copy. The D1 `cswap list --json` fallback runs only from
  `refresh(userInitiated: true)` (STATUS `↻ 立即更新`, Settings `重新讀取`) while the state files are
  unusable, at most once per 10 minutes. Every external program logs `exec <tool> path=… sub=…`
  (D38); every cswap string is passed through `EmailRedaction` before it is logged, dumped or shown.
- **Switching (D5, R3).** `switchTo(_:reason:)` runs `cswap switch <n> --json` through the serialized
  `CswapClient` (credential-lock timeouts retried, at most 3 attempts, progress in `switchState`),
  re-reads the state and records a switch mark for attribution. `AccountSwitching.run` is the one
  path for the sidebar footer, the menu bar, STATUS and ⌘K: toast `已切換到 #2 藍鵲 · …` with UNDO
  (= the same path back, reason `undo`), `[ERROR] 切換失敗：…` (redacted) on failure; with Settings ›
  帳號 › 切換前確認 ON it goes through dialog A (`AccountSwitching.confirmation`).
- **Status line pipeline (D8, D9, D11, D35).** `CoddStatusLineBinary.install` copies the bundled
  `codd-statusline` to `<dataRoot>/bin/codd-statusline-<hex12>` (GC like codd-hook) and refreshes the
  stable `bin/codd-statusline`. For every claude launch, RESUME and RESTART, `HolderLauncher` reads
  the user's status line (`UserStatusLine.chain` over the D35 files, CODD Desktop's own wrapper
  unwrapped) and builds a `StatusLineInjection`: `--settings` gets `statusLine {type: command,
  command: <that copy>, …the user's padding / refreshInterval / hideVimModeIndicator}` next to the
  hooks (only together with hooks), and the user's command travels base64 in
  `CODD_STATUSLINE_CHAIN` (≤ 16 KiB, never in argv). The holder environment is not
  `LaunchSpec.environment`: `planClaude` builds it with `ShellEnvironment.build(extra:)` (sanitized
  login environment + `SpawnEnvironmentBuilder` + `extra`, which wins); `CODD_HOOK_URL`,
  `CODD_HOOK_TOKEN` and `CODD_SESSION_ID` are in `extra`, `LaunchSpec.coddEnvironment`
  (`CODD_STATUSLINE_CHAIN`, a pinned `CLAUDE_CONFIG_DIR`) is merged into it, and
  `LaunchSpec.removedNames` (cswap's five auth-override variables, for pinned sessions) are dropped
  from the result. `HookPipeline` is the single consumer of `HookServer.statusLines`;
  `StatusLineThrottle` (an actor, off the main actor) passes at most one report per second per account
  key to `CswapAccountStore.ingest`, which runs `QuotaAttribution` (D6: `default` → the active account,
  inside 90 s after a switch only the account whose weekly reset matches within ±120 s; `cswap-<n>` →
  n; `cfg-<hash>` of a known profile → that account; a `default` report matching another account's
  reset outside the grace re-reads the state, at most every 15 s and logged at most once a minute per
  key; the reset fingerprint only counts entries of slots cswap has now, held by the same login) and
  ingests the observation (newer capture per window wins, a missing window never erases one, an
  observation of another login starts the entry over). Dropped reports are counted and logged once a
  minute per key. A card's health follows the numbers it shows: status-line numbers are fresh for
  15 min after their capture whatever cswap's cache age.
- **Pinned sessions (D12).** The ⌘N 帳號 select lists `跟隨全域登入（#3 工作）`, the active account
  disabled, and `固定 #n alias（cswap run）` for accounts with a usable cswap profile
  (`<cswapRoot>/sessions/<n>-*`, not marked stale), the others disabled with `先在終端機執行一次 cswap
  run <n>`. `createSession` resolves the profile (`pinResolution`), records
  `SessionRecord.accountNumber`, sets `ClaudeLaunchOptions.claudeConfigDir` (never logged, never in
  `hooks/*.json`); a launch profile whose environment sets `CLAUDE_CONFIG_DIR` to a profile records
  that account too. RESUME / RESTART keep the pin and are refused with the problem banner `#2
  的登入資料需要更新：先在終端機執行一次 cswap run 2` when the profile vanished or turned stale.
  Pinned transcripts live in `<profile>/projects`; the registry watcher also watches every profile's
  `sessions/`.
- **Auto-switch (D13, D37).** `AutoSwitchRunner` wraps CoddCore's `AutoSwitchController` on the
  assembled accounts: evaluated on every quota or account change and every 30 s while ON (default
  OFF), a switch goes through D5 with reason `auto`, the 300 s cooldown is kept in `quota.json`
  (`autoSwitch.lastAt`) so a relaunch cannot switch again, a failed switch does not start the
  cooldown: it is retried on the next tick once, then after the cooldown (≥ 60 s) doubled per further
  failure (≤ 1 h), and the first failure of an episode is toasted and notified; UNDO / 復原 of an
  automatic switch holds that account until the triggering window resets (or the user switches, or
  the rule changes); "no eligible account" is notified once per episode. While ON (or STATUS /
  Settings shown) a 60 s process scan warns when `cswap menubar` / `cswap auto` also run.
- **Surfaces.** Sidebar footer (switch rows with `切換中…`, R8 threshold ticks while auto-switch is
  ON, the availability note), rail chip, Home USAGE, menu bar popover (D23: at most 3 accounts in R7
  order with the active one always among them, `▸ 全部帳號 n`), status item (`◆2 ▲1` title in counts
  mode, `暫停通知 1 小時` / `恢復通知`, the 45 % paused icon, `切換帳號 ▸`), ⌘K `切換帳號到 #n`.
  Host one-liner (D36): `HostLineService` samples CoddHost every 30 s while the main window or the
  popover is visible.
- **Notifications (D29).** `SessionNotifier` owns the one `UNUserNotificationCenter` delegate and
  routes `codd.session` and `codd.account` responses (`AppNotifier` posts through it: 復原 / 好).
  `NotificationRules.decide` applies the WAITING / ERROR / DONE / EXITED matrix (condition, notify,
  sound), 勿擾時段 (local time, across midnight), `pausedUntil` and muted groups; every decision is
  recorded for the dump, also with `-codd-notifications NO` (then nothing is posted or requested).

### App: STATUS, the installer and the account dialogs (M3)

- **STATUS area (D16, D26, D27, D32).** Rail STATUS swaps the views inside the split's sidebar column
  (`SidebarContainerViewController`) for CoddStatusUI's `StatusSidebarView` at 220 px (divider
  autosave off meanwhile, the session sidebar's width and collapse come back) and shows
  `StatusPageView` in the pane. `StatusController` (`App/Session/StatusArea.swift`) refreshes every
  5 s while STATUS is shown and not paused: a CoddHost sample off the main actor (10-minute history),
  the main-thread latency probe, the accounts, the installer inspection; discrete changes (session
  states, the active account, switches, the rule, the inspection) rebuild at once, values that change
  every second wait for the refresh. `StatusPageData` maps the stores into the page model. M1's
  endpoint counters live under the HOOKS card's `▸ 詳細`.
- **Installer (D10, D11).** `ClaudeSettingsService` inspects `<claudeDir>/settings.json` off the main
  actor (re-parsed only when size, mtime or inode changed), plans each action with CoddClaudeSettings
  (`update`, `removeLegacy`, `uninstall`, `disableDuplicateNotifications`, `restore`) and applies a
  plan: re-read, refuse when the file changed since the plan, back up next to the file
  (`settings.json.codd-bak-…`, `COPYFILE_EXCL`, mode kept), write through a symlink to its target
  (temp file + F_FULLFSYNC + rename), record the reason in `claude-settings-backups.json`. Only `hooks`
  and `statusLine` change; key order, indentation and number spellings are kept. Dialog B
  (`HookDiffDialog`) is the only way to apply in the product: 預覽變更 and 更新 open it, only
  `套用並備份` writes.
- **Dialog A** (`SwitchDialogController`, sheet): attempt progress, the redacted error, `同時暫停自動切換`.
- **Dialog C (D24, D33, D34)** (`AddAccountFlow`): a child panel of the main window at its right edge.
  Step 1 creates an ephemeral SHELL session (`createEphemeralShell`: a `codd-ephemeral` marker in its
  session directory, never in layout.json, leftovers ended and deleted at the next launch) and types
  `'<claude>' /login`; the login change is seen through `CswapStateReader.currentLoginToken()` (a
  digest, memory only, checked every second). Step 3 checks the alias with cswap's rule
  (`CswapAlias`) before cswap runs, then `cswap add --slot n --alias a`, re-reads the state to confirm
  the slot, `cswap switch <previous>`, and discards the shell (holder ended, directory deleted).
  Cancel after the login changed switches back too.

### App: Settings, preferences and lifecycle (M3)

- **Preferences (D14).** `PreferencesService` loads `<dataRoot>/preferences.json` off the main actor
  before the holders start, migrates M1/M2's `CODDNotificationsEnabled` (standard root only, first
  run only), saves 300 ms after the last change and flushes at quit; DEBUG `-codd-set-pref` values
  apply for the run and are never written unless a later edit changes that leaf.
- **Settings window.** Hosts CoddSettingsUI's `SettingsRootView` (1040 × 720, minimum 860 × 560) with
  M2's `ProfilesSettingsView` as section 04. `SettingsCoordinator` binds `SettingsModel` to the
  service (an edit writes only the sections it changed, so a pause set from the menu bar meanwhile is
  kept) and rebuilds `SettingsInfo` (`SettingsInfoBuilder`) on an observation loop plus a 5 s tick
  while the window shows; `VersionProbe` runs `claude --version` once per opening (D28: on a
  non-standard root only the DEBUG `-codd-claude-path` executable).
- **Consumers.** Dock policy (D20; background launches always stay `.accessory`), login item (D21,
  `SMAppService.mainApp` through an injectable `LoginItemService`, only on the standard root, a failed
  registration turns the toggle back OFF), keep in menu bar on close (D19), quit (D18, below), global
  hotkey (D22, below), project root, CRT overlay off / subtle / full, terminal font and size (one
  libghostty configuration per process, so every terminal follows), reduce motion (lamp pulse, dialog
  blink, Dock tile blink), NO HOOK grace (`SessionStateEngine.setStartingGrace`, for sessions registered after the
  change), stale threshold, externals display, the notification matrix, Dock badge, menu bar icon,
  cswap path, confirm before switch, auto-switch, resume expiry warning.
- **Quit (D18).** `QuitPolicy.decide(behavior:trigger:running:)` over 結束時 (`詢問` / `全部停止` /
  `保留`) and the trigger (`user` ⌘Q / menu / Dock, `statusItem` right-click 結束, `system` logout /
  restart / shutdown from the Apple event's quit reason, `automation` `-codd-quit-after`,
  `confirmed`): ask with dialog D when at least one CODD session runs (never for system or
  automation), stop all (every live CODD session and shell tab, ≤ 3 s for their EXITs, then the hook
  flush), close the window, or terminate. Holders keep running on a plain quit, as before.
- **Global hotkey (D22).** `HotkeyService` registers the stored combo (default ⌥Space) with
  CoddSettingsUI's `GlobalHotkey` (Carbon `RegisterEventHotKey`, `kEventHotKeyExclusive`, no
  Accessibility permission), only on the standard data root unless DEBUG `-codd-global-hotkey YES`;
  a combo another app holds is refused and shown under the row; the recorder suspends the current one
  while recording. The action shows and activates the main window, or hides CODD when its window is
  already key and frontmost.

### App: the NOTES area and the notebook (M4)

- **NOTES area (D12).** Rail NOTES collapses the session sidebar (its width and collapse come back on
  leave) and shows `NotesAreaViewController` in the pane with four modes: Notebook (lists 220 · note
  list 300 · editor with info panel 240 · doc status · prompt footer, its own status bar under the
  editor), Files, Cleanup and Annotate (full width). The mode and selection are kept for the run.
- **NotesService** (`App/Notes`, `@MainActor @Observable`) owns CoddNotes' `NotesLibrary` (an actor:
  file I/O, the GRDB index and the watcher never touch the main actor), opens it after the
  preferences load, is the only consumer of its change stream and publishes availability, counts,
  lists, a 150 ms debounced search, the selected note's facts (history, activity, assets), the last
  paste, the quick note and linked-note counts per session (`SessionVM.notesCount`, the `✎ NOTES n`
  pill). It hands the library the live sessions and titles (D29 exemptions, D20 activity titles).
- **Editor binding.** `NoteEditorController` binds CoddTextKit's `MarkdownEditorView`: a new note
  goes to disk only at its first real change or first pasted image (D3); autosave 1 s after the last
  change, never while text is being composed; pending text saved on note switch, area leave, window
  close and quit; save conflicts and other programs' edits over unsaved text show the
  `磁碟上的筆記已變更` banner (`重新載入` / `保留我的` (snapshot first) / `比較`), a clean editor reloads
  in place. Leaving a note with text the flush could not write (the banner or a composition holds it
  back, the save failed: file moved or removed outside CODD, note in TRASH, I/O error) first stores that
  text as a HISTORY version (`未儲存的編輯`); when even that fails, as a new note with the same links
  (toast `無法寫入原筆記，未儲存的編輯已另存為新筆記「…」`); when nothing can take it, the editor refuses the
  leave and keeps the note and text on screen. The session drawer's editor sends its toasts to the main
  window while its document is off screen (`NotesDrawerController.onToastElsewhere`, after any UNDO
  toast there, `PoliteToast`). An AI append / write (CODD's own write, no watcher event)
  reaches the open editor through `OpenNoteCoordinator.didWriteFromAI`: a clean editor takes the new
  body in place. Pasted images go through `NotesLibrary.saveAsset` (2576 px long edge, D9); figures draw
  their `codd-annotations` overlays; ImageAnnotate's `完成` rewrites the block as one undoable edit.
- **Metadata, COPY REF, history, ⌘K.** The AI / scope / kind / ⋯ menus patch the frontmatter through
  the library (refused for an unparsable frontmatter); archive / trash show UNDO toasts; COPY REF's five
  forms come from `NoteReferences.forms` with the hook port and `MCPAuth.noteURLToken` (D15; through
  `CoddPasteboard`, D39); HISTORY compares a snapshot with the current text (CoddFiles `LineDiff`)
  and restores it (snapshot first); ⌘K gains a NOTES section (≤ 5 rows).
- **Send to session (D14).** `NoteSending`: 插入引用 / 插入全文 into the session's composer draft
  (`ComposerStates.appendToDraft`, or the bar's field as one undoable insertion), 送出 through
  `ComposerEncoding.payload` → `TerminalInput.payload` (paste + submit) to claude's PTY, refused while
  WAITING, for a non-running session and over 256 KiB; a PROMPT records `sent` / `sentTo`. The session
  pill opens the notes drawer (`NotesDrawerController`, 300 pt, linked notes and the AI-touched files).
  Composer chips draw `codd://note/<id>` (CoddComposer `referenceChips`).
- **Mock mode (D35).** `-codd-mock` seeds a temporary notes folder (`$TMPDIR/codd-mock-notes-<pid>`,
  removed at quit) with SPEC §5's notes, a mock project for Files (a `StaticGitReader`, never git) and
  a mock MCP state; the MCP routes are never installed.

### App: the MCP server, prompt expansion and registration (M4)

- **Server (D16, D17, D21).** `MCPService` wraps CoddMCP's `MCPServer` (name `codd`, version = app
  version) over `NotesMCPBackend` and installs the `/mcp`, `/hooks/prompt` and `/n/<id>.md` handlers on
  the hook server (`HookPipeline.setRoutes`, kept across rebinds) together with the MCP token. The
  request path reads one lock-protected `NotesMCPContext` (library, sessions, AI 可寫入, client names)
  and never waits on the main actor. Visibility: AI OFF notes answer exactly like unknown ones; a
  project-scope note is visible to a session whose cwd (real path) is inside one of its projects or that
  it links, and to external callers; the tools' `scope` only narrows; `notes_write` is listed only while
  AI 可寫入 is ON. Pages of 12,000 characters, ≤ 4 image blocks (≤ 1568 px, ≤ 900 KB). Clients: a CODD
  session from its first request, an external token + client name for 30 minutes; the status bar, the
  rail, the Notebook footer, STATUS › MCP SERVER and Settings › 筆記本 & MCP show them live.
- **notes_create (user feedback 2026-10-19).** Tools in `tools/list` order: `notes_search`, `notes_list`,
  `notes_read`, `notes_append`, `notes_create`, `notes_write` (the last only while AI 可寫入 is ON).
  `notes_create {title, body, tags?, kind?: note | prompt}` lets a session put a document (report, plan,
  summary) into the Notebook instead of a Markdown file in the project: CoddMCP validates (title one line,
  a leading `# ` dropped, ≤ 200 characters; body non-blank, ≤ 100,000 characters; tags cleaned like the tag
  editor, ≤ 20; `scratch` refused) and `NotesMCPBackend.create` calls `NotesLibrary.create` for a NEW
  note only (a fresh id and file; no existing note is read or written, a repeated H1 and CRLF are
  normalized, the AI's text always follows CODD's `# <title>`, so it can never open a frontmatter):
  INBOX, `createdBy: ai`, AI access APPEND (so the same session can `notes_append` to it), linked to the
  calling session and its project (`NotesMCPContext.Session.project`, the non-transient
  `ProjectVM.cwd`, so scope `project`); an external caller's note is unlinked (`global`); a condense run
  is refused. The creation is recorded as `create` AI activity (via `mcp`). The server emits
  `MCPEvent.created`; `MCPService` counts it (dump `mcp.notesCreated`) and calls `onNoteCreated`, and
  `MCPNoteToast` shows `Claude 建立了筆記：<title>` with `[開啟]` (on NOTES at the document's bottom edge,
  elsewhere over the visible sidebar; adding the toast never activates CODD; `[開啟]` opens the note like
  ⌘K NOTES). `notes_create` is **not** in the per-session `permissions.allow` (still only the three read
  tools) and has no `requiresUserInteraction`, so Claude Code asks before each create and the user may
  choose always-allow. The body limit sits well under the hook server's 1 MiB `POST /mcp` cap (even as
  `\uXXXX` escapes with the envelope), so an over-long body gets the tool's own refusal with the
  notes_append hint, never a bare HTTP 413. The toast never replaces a toast that carries `[UNDO]` or a
  countdown (the Notebook's archive / trash, the sidebar's archive): it waits until that one is gone.
- **Per-session injection (D18).** For every claude launch, RESUME and RESTART while 自動掛載 MCP is ON
  and the routes are up, `MCPSessionInjection` reads the session's global config (names only, off the
  main actor, cached 10 s by size and mtime; on a test data root a path into the real home is skipped)
  and `<cwd>/.mcp.json`, chooses `codd` / `codd-desktop` / none (the user registered this endpoint
  themselves), and `HolderLauncher` writes `mcp.json` and puts `--mcp-config <file>` right before
  `--settings` (with `/hooks/prompt` for UserPromptSubmit, timeout 3, and `permissions.allow` for the
  three read tools only: `notes_append`, `notes_create` and `notes_write` keep Claude's prompt). OFF: the
  M3 argv and a stale `mcp.json` removed.
- **Prompt expansion (D19).** `PromptExpansion` answers `/hooks/prompt` (after the event was yielded like
  `/hooks`) within 1.3 s (the server cuts at 1.5 s): ≤ 5 refs, ≤ 9,500 characters of §3.7 text as
  `additionalContext`, `systemMessage` `codd：已展開 …` / `… 無法展開（<reason>）` (an OFF note's title is
  never named), 204 without a ref; `expand` activity recorded. `NoteURLResponder`: 200 Markdown, 410
  trashed / purged, 404 unknown / OFF.
- **Registration (D22, D23).** `MCPRegistrationService`: the target is `~/.claude.json` on the standard
  root only (else DEBUG `-codd-claude-json`, refused before reading when it resolves into the real home);
  plan → dialog B (masked diff of `mcpServers` only) → `套用並備份` through CoddClaudeSettings'
  `ClaudeUserConfigMCPInstaller` (Claude's `<file>.lock` mkdir protocol, re-read under the lock, the edit
  rebased onto a file changed outside `mcpServers`, refused when `mcpServers` changed, backup, atomic
  write); 移除 the same way. Codex: a snippet sheet with `[複製]`. 輪替 rewrites `mcpToken` (config.json
  first, then the running server), after which a registered Claude Code shows `需要重新註冊`.
- **What reaches an AI (pre-publication audit 2026-10-20: CODE-3, CODE-4, CODE-6).** A note can link any
  path (`/…`, `~/…`, `../…`) and an AI may have written that text, so the AI paths (`notes_read` image
  blocks, resources and the `note` prompt, the annotated copies they need, the `[image]` lines of prompt
  expansion) pass `NoteAIText.ImageScope.ai(folders:)`: an image counts only when its real path (every
  symlink followed and `..` applied component by component, a dangling link included) is a regular file
  inside the notes root or, for a CODD session, inside that session's folder (cwd real path); external
  clients and a condense run's own `notes_read` calls get the notes root only. Any other image keeps its
  `[image] <path>` line with `（未附上：圖片不在筆記本或專案資料夾內）` instead of its size, and is not
  measured, attached or burned into
  `cache/annotated` (`annotatedImage(for:image:scope:)` checks the image the block resolved to, not the
  name asked for). The user's own paths (the Notebook editor, 插入全文 / 送出, condense input) stay
  `.unrestricted`. Prompt expansion runs each body through `NotesLibrary.wrapperSafe`, which turns the
  `<` of every `<codd-note` / `</codd-note` lookalike (matched on Unicode scalars after NFKC: any case,
  fullwidth forms, blanks and invisible format characters such as U+200B anywhere after the `<`, any dash or
  none between `codd` and `note`) into `＜`, so a note can neither close its wrapper nor fake another
  (`notes_read` has no wrapper). Registration writes
  `~/.claude.json` 0600 when its mode lets the group or others in (`mode & 0o077 != 0`) and the new bytes
  hold a CODD token (the one registered or any `X-CODD-Token` header), and the new backup 0600 when either
  version holds one (created with that mode, `SettingsFS.copyExclusive(from:to:mode:)`, never chmodded
  afterwards); dialog B then adds one summary line (`檔案權限 0644 → 0600：…`). Each write also makes CODD's
  older `.codd-bak-*` backups that hold a token 0600. A file registered before that (the current token in a
  file or backup the group or others may read) shows `◆ 權限過寬` / `收緊` (`MCPService.claudeCodeExposed`):
  its register plan is `modeOnly` (no diff, no backup, not a byte changed; `收緊權限` only makes them 0600).
  The Codex sheet says to `chmod 600 ~/.codex/config.toml`. None of this guards
  against code running inside a session: it runs as the user and can read `config.json` (hook token,
  external `mcpToken`), so it can read every AI-visible note and create notes without a prompt. Secrets
  belong in AI OFF notes (USER-GUIDE §7).

### App: the file editor (M4)

- **FileEditorService** (`App/Files`): workspaces (a project's cwd, a chosen folder, or a single file's
  deepest known project), VS Code-like preview / pinned tabs, note tabs (a notebook `.md` opens in the
  note editor), one `OpenFileState` + CoddCodeEditor `CodeEditorView` per file tab. Reads off the main
  actor; binary → `// 二進位檔案，無法以文字開啟`, > 5 MiB read-only plain mode, > 50 MiB refused.
  ⌘S through CoddFiles' `FileSaver` (atomic, mode / xattrs / ACL kept, hard links written in place,
  refused when the disk changed since the load unless 保留我的); nothing else ever writes (D24). One
  write at a time per tab (a second ⌘S starts from the first one's fingerprint; text typed during a
  write stays unsaved); the disk watcher reads after CODD's own write. Quitting with unsaved tabs: ⌘Q /
  結束 asks first (one sheet: 不儲存 / 取消 / 儲存全部); a quit that cannot ask (logout, restart,
  `-codd-quit-after`, dialog D's answer) keeps each buffer as a copy under
  `<dataRoot>/files/unsaved/<yyyyMMdd-HHmmss>/` (0600), never over the file.
- **Disk changes (D25).** A `FileWatch` per tab: a clean buffer reloads in place, a dirty one shows the
  banner, attributed to an AI session when that session's PostToolUse named the path within ±10 s.
- **git (D24).** `GitReader` (read only, `--no-optional-locks -c core.fsmonitor=false`,
  `GIT_OPTIONAL_LOCKS=0`, 5 s timeout) for status, ignored files, `ls-files` (⌘P) and `cat-file blob
  HEAD:<path>`; refreshed at open, on folder changes (500 ms, only while Files shows) and after saves.
  On the standard data root it uses the user's own git config; on any other root it runs with
  `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` (tests, fixtures, try-outs).
- **AI touches and SHOW AI CHANGES (D26, D27).** `HookPipeline` records PostToolUse file paths into
  `files/ai-touches.json`; tree / Recent / tab rows get the session-colored AI chip. SHOW AI CHANGES diffs
  the buffer against git HEAD, the last save, the text before the AI started, or the disk (while 比較),
  300 ms after edits, off the main actor; 還原此段 edits the buffer (undoable), 接受 only hides the hunk.
- **Menu.** A `檔案` menu (儲存 ⌘S, 關閉分頁 ⌘W, 篩選檔案 ⌘P, 尋找 ⌘F), every shared key mutually exclusive
  with the sessions' and the notebook's items in `validateMenuItem` (the shortcut matrix checks it).

### App: retention, Cleanup and condense (M4)

- **RetentionService** (`App/Cleanup`, real mode only) runs at launch (after the sessions are discovered
  and the notebook is open), every 24 h and 1 s after a retention setting changes: notes through
  `NotesLibrary.runRetention(liveSessions:)` (archive due notes, purge trash older than 30 days through
  the app trash, tombstones); CODD sessions through CoddCore's `SessionRetention` (stopped → stale dim,
  → archived, archived → `ring` + `holder.log` to the app trash), never running, pinned, external or
  holder-alive sessions. The first run on a data root records `retention.firstRunAt` in `cleanup.json`
  and the session clocks count from it (D30 grace: the first M4 launch archives nothing).
- **Cleanup page (D31).** `CleanupController` + `CleanupPresenter` feed CoddCleanupUI's page: NOTES (the
  library's candidates), SESSIONS (SessionRetention's rows), FILES (unused images, rings due within 7
  days, Recent entries whose file is gone); row actions 保留 30 天 (`keepUntil` in state.json /
  cleanup.json), 封存, 移到垃圾桶; counts on the Notebook footer, the menu bar footer and Settings › 清理.
  `CleanupDigest`: weekly Monday 09:00 local (biweekly, monthly, off), once per period, only with ≥ 5
  candidates, through `AppNotifier` (`cleanup-digest`, action 查看).
- **Condense (D32).** `CondenseRunner`: OFF notes left out; account `follow` or a cswap account (M3 D12
  pin rules, `CLAUDE_CONFIG_DIR`); the claude is the login PATH's on the standard root, else only
  DEBUG `-codd-claude-path`; argv `-p --model <m> --output-format text --tools "" --permission-prompts
  none --strict-mcp-config --mcp-config <run>/mcp.json --allowedTools mcp__codd__notes_read
  --no-session-persistence`, no `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` / `CODD_HOOK_URL`, the run's UUID a
  transient read-only MCP caller, 180 s timeout, cancel = SIGTERM then SIGKILL of its process group.
  Nothing changes before `[建立摘要並封存原稿]`: a summary NOTE with `condensedFrom`, whole-note sources
  snapshotted and archived with `condensedInto`, a long-note source (only its dated sections older than
  30 days were sent) unchanged with `keepUntil` +30 d; UNDO unarchives and trashes the summary.
- **App trash (D38).** `AppTrash`: the macOS Trash only on the standard data root; any other root
  `-codd-trash-dir` or `<dataRoot>/trash/`; every move logs `trash target=system|folder name=<last>`
  (also M2's 刪除對話紀錄 now).

### App: sidebar drag and drop, interface zoom, layout (M4, user feedback 2026-10-18)

- **Drops from the pointer.** AppKit proposes "on the row" for the middle of every row; the drop
  planner (`DropPlanner.plan(dragged:pointer:…)`) instead takes the dragged level's block under the
  pointer (a session row, a project with its visible sessions, a group with everything in it): the
  upper half means before it, the lower half after. validateDrop and acceptDrop plan identically, the
  amber line is drawn above the rows. Finder folders (`.fileURL`) on a group head go to its end, over a
  project before / after it, elsewhere where 新增專案 puts them; a folder that already is a project is
  revealed and selected instead (`addProjects(paths:toGroup:atIndex:)`, shared with ⌘O). Rows never
  leave the app. DEBUG: `-codd-sidebar-drag-test`, `-codd-drop-folders`.
- **Interface zoom.** CoddUI `UIZoom.scale` = UI 字級 / 13 (10–20): every `Typeface` font and every
  design length (`UIZoom.pt`, rounded to whole points at a non-default zoom; exactly the old values at
  13) follows; `UIZoom.apply` refreshes every window in place (labels, buttons, text views, tagged
  constraints `.zoomed(design)`, row heights, `ZoomRefreshing` views). 顯示方式 › 放大 ⌘+ / 縮小 ⌘− /
  實際大小 ⌘0 step UI 字級 and 終端機字級 (8–28) together through the preferences (CODD 主視窗 moved to
  ⌥⌘0); `appearance.zoomTerminalSteps` counts the terminal's net ⌘+ / ⌘− move, and ⌘0 takes exactly
  that back (UI to 13), so a 終端機字級 chosen in Settings or with A− / A+ survives it; terminals keep
  their own size and leave the keys to the menu. A launch peeks at
  `preferences.json` for the UI size before the first window.
- **Layout at the minimum and at zoom 20.** Optional pieces resist compression and hide by
  `RowFit` rules, columns fold in order (Notebook: info panel, then the list narrows, then the lists),
  Settings rows stack their controls under the labels; zooming in grows a window that is smaller than
  the new minimum. `scripts/m4-layout-sweep.sh` renders every screen at the sizes it checks.

### App: onboarding (M5)

- **Gate (D5).** `applicationWillFinishLaunching` decides once, right after the instance lock and the D2
  defaults line, before anything writes the root (`OnboardingLaunch.decide`): the standard data root
  shows the wizard when `OnboardingGate.isNewDataRoot` (no layout.json, panes.json, onboarding.json and
  no `sessions/*/meta.json`); any other root only with DEBUG `-codd-onboarding auto|show` (default
  `never`, so no earlier e2e script sees it); a Release build never parses the flag, so a throwaway
  `-codd-data-root` is never automatic. Mock mode shows it only with `-codd-show onboarding[:<n>|:all]`
  (`OnboardingSamples`, the frozen artboard's data). Logged `onboarding gate show=… reason=…`.
- **Window (D6).** `OnboardingWindowController`: its own window (hidden-inset title bar, traffic
  lights over the stepper's drag area, title 首次啟動設定, content 1240 × 820, minimum 1011 × 640), the
  package's `OnboardingView` inside the App's scanline container (Settings › 外觀 › CRT 效果, live), no
  frame autosave. When the wizard opens at launch the main window is built but not shown; real mode
  starts as usual behind it (hook server, cswap, MCP), so the facts are live. While it is open a
  show-window request, a Dock click, the status item's 開啟 CODD and the global hotkey bring it forward
  instead of the main window (`OnboardingPresenter.bringForward`); a background run orders it through
  `BackgroundWindows` and never activates.
- **Probes (only while it shows).** `AppDelegate.onboardingProbe` waits for the sessions to load, then:
  claude resolved like condense does (`claudeExecutable(override: -codd-claude-path, standardRoot:,
  loginPATH:)`, the login shell's PATH on the standard root only; any other root runs only the DEBUG
  claude) and run once through `VersionProbe` (absolute path, 5 s, `exec claude path=… sub=--version`);
  `CswapAccountStore` (its own availability, version, path, accounts; `start()` joins the read real mode
  began); `ClaudeSettingsService.refreshInspection` (legacy CODD web hooks, the status line, other
  tools' hooks: D11 wording); a create-and-remove of a temp file in the root (`可寫入`); the hook port and
  `MCPService.running`; the registration state; and `ProjectCatalogReader` over `<claudeDir>/../.claude.json`
  (read only, off the main actor, projects already in CODD left out). `↻ 重新偵測` runs it again. Logged
  `onboarding probe ms=… claude=… cswap=… hooks=… writable=… mcp=… candidates=… already=…`.
- **What it writes, and when.** Nothing until the user acts. Step 2's 下一步 applies the `ImportPlan`
  (`OnboardingImport.apply`): `addGroup` for each new group in first-use order with its color, then
  `addProjects` per group in table order (未分類 = no group), logged `onboarding import projects=<n>
  groups=<n>`; 略過 imports nothing; imported rows leave the table, so back-and-on never imports twice.
  Step 3 `預覽變更` is dialog B (`update`) on the wizard's window (it writes only on 套用並備份, with its
  backup; the step then shows `● 已套用 · 備份 <name>`); step 4 reveals the notes folder (logged and
  skipped in background runs), opens the M4 registration dialog (disabled with its reason on a test root
  without `-codd-claude-json`) and the Codex snippet sheet; step 5's `+ 加入帳號` is dialog C (it brings
  the main window, D13; the accounts follow through an observation loop); step 6's `允許通知` is
  `SessionNotifier.requestAuthorizationNow()` (`.suppressed`, without touching
  `UNUserNotificationCenter`, when `-codd-notifications NO` or a background run; recorded in the
  notification log as `permission`). Ending writes `onboarding.json` (`OnboardingStateStore`, D7), closes
  the window, shows the main window and selects the first imported project.
- **Reopen.** Settings › 關於 `首次啟動設定 [重新執行]` (`SettingsActions.openOnboarding`) and 說明 ›
  首次啟動設定… (`NSApp.helpMenu`, no key equivalent) open it from step 1 with live data; projects already
  in CODD are left out of step 2 and finishing rewrites `onboarding.json`. ⌘Q in the middle writes no
  `onboarding.json`, and `panes.json` is written only once a session has a layout to keep (fix round 1:
  it used to be written empty half a second into every first launch), so the wizard comes back at the
  next launch; after step 2's 下一步 imported projects, `layout.json` exists and the root is no longer
  new (reopen it from 說明).

### App: accessibility and copy (M5)

- **VoiceOver (D21).** State is spoken as text, never only as glyph and color (`StateSpeech.swift`:
  `StateStyle.spokenName`, `SessionSpeech`, `SpokenDuration`, all 繁體中文 with Claude Code's own names kept):
  a sidebar row is one AXRow whose label says the cell (`SidebarCellView.spokenLabel`; the cell itself is
  no element, so only its real buttons are children): sessions `title，等待中 · 權限 · 3 分鐘，標籤：紅，…`,
  groups with their tally, projects with their count; a lamp with a description is an image
  (`LampView.spokenDescription`, the pane header's), inside rows it is decoration; the rail items are
  radio buttons (`SESSIONS，3 個需要你`, value 1 while their area shows); status bar items, the header's
  meta line and the footer's quota rows are static texts; the menu bar panel's account and session rows
  are buttons; lists the App draws itself (⌘K results, the ⌘N project list) and the color swatches expose
  one element per row (`DrawnRowElement`).
- **Keyboard (D21).** The App's own custom controls (`KeyFocusControl`, `KeyFocusView`: rail items and
  account chip, the footer's usage toggle, account rows, the panel's session rows, Home's done line) follow
  CoddUI's rules: a key view only with Full Keyboard Access, space / ⏎ press, ↑ ↓ step through rows of one
  list, the helmet focus ring (layer border + `KeyboardFocus.ringGlow`) only for keyboard focus. Tab order
  is AppKit's automatic loop, which follows the view hierarchy (rail, then sidebar, then pane, each top to
  bottom), so no explicit `nextKeyView` links. Every action that was only a click has a main-menu item
  without a key equivalent: 顯示方式 › SESSIONS / NOTES / STATUS / SETTINGS, 筆記 › 筆記本 / 檔案 / 清理建議,
  Session › 筆記抽屜 / 新增群組… / 切換帳號 ▸, CODD › 暫停通知 1 小時 (恢復通知 while paused).
- **Copy (D22).** `scripts/tools/copy-audit.py` exits 0: test data with emoji uses `\u{…}` escapes (raw
  strings `\#u{…}`); English that is not UI copy (logs, protocol text, configuration, sample data) is
  allow-listed per file with its reason. One term per concept: 帳號 (`+ 加入帳號` everywhere), 設定, 資料夾 for
  folders (目錄 only where the frozen artboards say it: 資料根目錄, 專案根目錄, 專案目錄, 狀態目錄, 設定目錄), 登入, 筆記, 封存,
  垃圾桶, 儲存.

### Testing hooks (DEBUG only)

`RealModeOptions` lists every DEBUG flag (`-codd-…`: spawn, select, send, composer, palette,
sidebar, panel, sheet, keepalive, trash folder, …; M3: cswap path / root, Claude settings, switch /
undo / refresh / pin, auto-switch tick, installer plan / apply / apply delay, add account, quit
request / choice, global hotkey / combo, `-codd-set-pref`, `-codd-show status|settings-<section>|
dialog-switch|dialog-hooks|dialog-add|dialog-quit`); `-codd-dump-state <file>` writes the state the
e2e scripts check (`StateDump`: sessions with their states and M2 / M3 flags, projects, groups, pins,
archive, profiles, `sidebar`, `palette`, `home`, `pane`, `newSession`, `resumePicker`, `problem`,
`windowVisible`, `instance`; M3: `accounts`, `quota`, `statusline`, `menuBar`, `autoSwitch`,
`installer`, `notifications`, `dialogs`, `status`, `preferences` (with `effective`), `quitDialog`,
`hotkey`, `dock`, `loginItem`, `settings`, `hostLine`; never an e-mail or a cswap profile path).
M4 adds (docs/M4-PLAN.md §6): `-codd-show notebook|note:<id>|annotate:<id>:<asset>|files:<path>|
cleanup|split|settings-notebook|settings-cleanup|menubar` (only the keyword before the first `:` is
case-insensitive), `-codd-notes-select|new|type|paste-image|annotate|search|set|archive|trash|send|
copy-ref|rebuild|menu`, `-codd-quick-note`, `-codd-now <ISO8601>` (the notes' clock: lists,
retention, digest), `-codd-retention-run`, `-codd-cleanup-action`, `-codd-condense` (+ `-account`,
`-apply`), `-codd-mcp-rotate`, `-codd-claude-json` + `-codd-mcp-register-plan|apply|apply-delay`,
`-codd-open-file`, `-codd-file-type|show-ai-changes|baseline|hunk|save|find`, `-codd-sidebar-drag-test`,
`-codd-drop-folders` (+ `-group`, `-index`), `-codd-zoom in|out|reset`, `-codd-window-size`,
`-codd-sidebar-width`, `-codd-settings-size`, `-codd-settings-all`; M5 I1 (docs/M5-PLAN.md §5) adds
`-codd-force-render YES` (D17: TerminalHub never occludes and the engines ignore AppKit's occlusion, the
1 Hz UI clock keeps running as with `-CODDForceVisibleTimers`; measurements only), `-codd-stop-after-create
YES` (D20: the session `-codd-new-claude` / `-codd-spawn-shell` just created is stopped in the same
main-actor turn, before its holder exists: `stop deferred session=…`, then `stop applied-after-spawn
session=… holderPid=…`) and the defaults key `-CODDMetricsSessions <n>` (the switch metric cycles the
first n sessions; its summary gains `sessions=<n> hot=<n> cold=<n>`, and `-CODDMetricsVerbose` switch lines
end in `tier=hot|cold`, read from the hub before the switch); every build logs `perf launch-to-sidebar
ms=<n> rows=<n>` once, when the sidebar first shows the loaded layout (from the kernel's process start);
M5 I2 adds `-codd-onboarding auto|show|never`, `-codd-onboarding-step <1-6>`, `-codd-onboarding-actions
<a,b,…>` (run in order once the wizard shows: `redetect`, `next`, `skip`, `back`, `goto:<n>`,
`filter:<text>`, `check:<path>`, `uncheck:<path>`, `check-visible`, `suggest`, `group:<path>=<key>`,
`new-group:<path>=<name>`, `show-hidden`, `more`, `hooks-preview` (the plan only), `hooks-apply` (guarded
like `-codd-hooks-apply`), `reveal-notes`, `mcp-preview` (the plan only), `notify`, `finish`, `close`;
each logs `onboarding action=<a> step=<n> ok=<bool>`) and `-codd-show onboarding[:<n>|:all]` (with
`-codd-snapshot`: `<stem>-onboarding.png`, and for `:all` `<stem>-onboarding-<n>.png` for steps 1–6);
M5 I3 adds `-codd-a11y-audit <file>` (D21; a mock-mode tool, the flag alone selects mock mode:
`AccessibilityAuditPass` visits every main screen, runs CoddUI's `AccessibilityAudit` on each window, sheet
and panel, writes `{"screens":[…],"unlabeled":n,"outsideKeyLoop":n}`, prints `A11Y screen=…` lines and
`A11Y screens=<n> unlabeled=<n> outsideKeyLoop=<n>`, then exits 3 when anything is unlabeled, else 0; the
menu bar panel is only laid out offscreen, every other window stays behind other apps),
`-codd-a11y-screens <a,b,…>` (names or prefixes: `settings`, `onboarding`) and
`-codd-full-keyboard-access YES|NO` (`KeyboardFocus.fullKeyboardAccessOverride` for the run);
every flag that takes a path refuses
one inside the real home's `.claude*`, `.codex`, `.claude-swap-backup` or `Library/Application
Support/CODD` (lexical and resolved, dangling links included). Dump keys: `notes` (index, counts,
lists, search, selected, history, activity, copyRef (token masked), annotate, lastPaste, lastSend,
externalEvents / Reloads, banner, saves, openMs), `mcp` (running, endpoint, clients, requests, lastTool,
rejections, sessionConfigs, claudeCode), `promptExpansion`, `registration` (plan with its masked diff,
applied, error, tokenRotatedAt), `files` (workspace, git facts, aiTouched, tabs with encoding / EOL /
hunks, banner), `retention`, `cleanup` (counts, digest, condense), `zoom`, `sidebar.lastDrop`; M5 I1 adds `bundle` (id, version,
build, legacyDefaultsMigrated, legacyDefaults, autosavesLayout) and `dataFiles` (preflight {ms,
cacheWiped, files [{file, status, version?, from?, aside?, backup?, reason?}]}, issues [{file, kind,
version?, aside?, message}], bannersShown, bannersQueued); M5 I2 adds `onboarding` (shown, reason, source, step, steps
[{id, state, detail}], boot [{tag, name, value, detail}], import {source, total, hidden, already, checked,
visible, filter, rows [{path, name, prefix, lastUsed, transcripts, hidden, checked, group, suggestion}],
options [{key, name, color, kind}]}, applied {projects, groups}, hooks {pending, applied, backup},
notebook {path, mcp, claudeCode}, accounts {availability, rows [{slot, alias, active}]}, notifications,
completedAt, file); never a token, never note text, never an e-mail.
Release builds ignore them all.

**Background launches (every build; `AppActivation`, `BackgroundWindows`).** `-codd-background [YES|NO]`
/ `CODD_BACKGROUND=1|0` (a DEBUG build defaults to it from a Claude Code shell or on another data root)
makes a run leave the user alone: `CoddApplication` swallows every activation request, the policy stays
`.accessory`, and every CODD window (main window, Settings, dialogs, sheets, `NSAlert` including
`runModal`, the ⌘K palette, notes and quick note, file editor, annotate, Cleanup, hover card, menu bar
panel, dropdowns, child windows) stays behind every other app's normal windows, at launch, on relaunch
and on every later ordering. Not activating alone left a window directly behind the active app's key
window, above all other apps (user, 2026-10-18: 「不要跳到幕前干擾我」). main.swift installs one hook on
`NSWindow`, only in background mode and before any window exists: `orderWindow(_:relativeTo:)` (behind
`orderFront`, `makeKeyAndOrderFront`, `showWindow`, `isVisible`) and `orderFrontRegardless` turn an
ordering to the front, or relative to another app's window, into one just above CODD's frontmost window
(a sheet or child window: above its parent; no CODD window shown: the back of the level); orderings
relative to CODD's own windows, to the back and out pass, so CODD's windows keep their order as one block
behind the other apps. `level` above `.normal` (the floating menu bar panel, a modal alert) is held at
`.normal`; AppKit's own status-item, menu and tool-tip windows are left alone. AppKit's private modal
ordering (`_orderFrontModalWindow:relativeToWindow:`, hooked only when present) is put back in the same
call. A safety net sinks every CODD window when the window server shows one above another app's
normal window (on resign active and unhide; on key, main and occlusion changes at most once a second;
other background CODD runs do not count, so two of them never chase each other; the user's own CODD
has the same bundle identifier (or, M5 D1, the legacy one: `CoddIdentity.isCODD`) and counts as another
app: a CODD process is a background run when
its launch arguments and environment, read with `KERN_PROCARGS2`, resolve to background mode as
`AppActivation.resolve` does, else, or when unreadable, it is another app). The user still
decides: a click on a CODD window activates it as for any app, and while CODD is active or while a real
mouse click is dispatched (the status item, a non-activating panel) orderings run unchanged; leaving CODD
sinks its windows again. Drawing, `cacheDisplay` snapshots, key / main window, modal loops and terminal
state are unchanged; a covered window reports itself occluded (libghostty pauses drawing, text still
updates; `isViewing` counts a background window as seen). Foreground launches install nothing. The
hosted unit-test process (`.prohibited`, CODD as the test host) installs the same hook: tests order
windows front too (the hover card, sheets, panels), and they stay behind every other app.

### codd-holder

Code: `Packages/CoddHolder` (`CoddHolderCore`; the `codd-holder` executable is `HolderMain.run()`).

- Darwin only, no Foundation (`-dead_strip_dylibs` drops the load command the toolchain adds),
  single kqueue loop, no threads. Budget measured as `footprint` (phys_footprint), not RSS: idle
  release holder with a `/bin/sh` child ≈ 1.55 MB footprint, ≈ 2.5 MB RSS (RSS also counts shared
  pages and resident ring pages).
- **Binary location.** The app bundles `Contents/MacOS/codd-holder` but never spawns it from there.
  `HolderBinaryInstaller.install(bundledHolder:dataRoot:)` copies it to
  `<dataRoot>/bin/codd-holder-<first 12 hex digits of its SHA-256>` (`bin/` 0700, file 0755): bytes
  written to `.codd-holder-<digest>.<pid>.<random>.tmp`, fsync, rename. An existing file of that
  name is reused only when its bytes equal the bundle's. Copying the bytes keeps the ad-hoc signature
  (it is inside the Mach-O; `codesign -v` passes) and carries no extended attributes. Holders are
  spawned from the copy, so app updates and rebuilds never touch a running holder's file (overwriting
  a running signed executable in place gets it killed). At launch, after installing,
  `collectGarbage(dataRoot:keeping:)` removes every other `codd-holder-<12 hex>` file and stale
  `.codd-holder-*.tmp` that is at least 5 minutes old (a reused copy's mtime is refreshed at install),
  that no running process executes (all pids via `proc_listpids`, their executables via
  `proc_pidpath`, compared by device + inode) and that no running app marked in use
  (`markInUse`: a shared `flock` held for the app's lifetime; GC skips a copy it cannot lock
  exclusively). Other files in `bin/` are never touched. Discovery (`SessionDirectory.isHolderProcess`) accepts executables
  named `codd-holder`, `codd-holder-<12 hex>` and `holder-*`.
- CLI: `codd-holder --session <id> --dir <sessionDir> --socket <path> --cols <n> --rows <n> --cwd <dir>
  [--ring-size <bytes|K|M|G>] [--env-file <path>] [--exit-linger-ms <ms>] [--log <path>]
  [--flow-limit <bytes|K|M>] -- <argv…>`
  - `--session`: 1–64 characters of `[A-Za-z0-9_-]`. `--ring-size`: default 8 MiB, 128 KiB … 1 GiB,
    rounded up to 4 KiB. `--exit-linger-ms`: default 10000, at most one day. `--log`: append-only
    diagnostic log (default stderr, which the spawner points at /dev/null). `--flow-limit`: default
    1 MiB, 64 KiB … 64 MiB (measurements only).
  - `--env-file`: NUL-separated `KEY=VALUE` list (entries without `=` or with an empty key are
    skipped); the child gets EXACTLY this environment (the spawner builds it: login-shell PATH,
    LANG/LC_CTYPE UTF-8, TERM, COLORTERM=truecolor, TERM_PROGRAM, …). `argv[0]` is resolved against
    the file's PATH.
  - Exit codes: 0 normal, 64 usage error, 71 startup failure (socket in use by a live holder, ring
    locked by another holder, …). A failed start leaves the previous holder's ring header intact.
- Spawning (`HolderSpawner`): `posix_spawn` with SETSID, CLOEXEC_DEFAULT, default signal
  dispositions, empty mask, /dev/null stdio. The holder raises its soft RLIMIT_NOFILE to
  min(hard, OPEN_MAX) (inherited by the child), ignores SIGPIPE/SIGHUP, takes SIGTERM/SIGINT through
  EVFILT_SIGNAL, forces SIGCHLD to SIG_DFL.
- The child: `forkpty`-style setup in C (CCoddShim): new session, the PTY slave as controlling
  terminal and fds 0/1/2, IUTF8, every other fd closed, signal dispositions and mask reset, chdir,
  execve. A failed exec is reported in the stream as `codd-holder: <argv0>: …` and as exit status
  126/127.
- Master fd is `O_NONBLOCK`; output is read straight into the ring (≤ 64 KiB per read) and is never
  blocked by a client except through flow control below. Input is queued and drained with
  `EVFILT_WRITE` (PTY input capacity is ~1 KB). Input backpressure: while more than 4 MiB of input
  wait for the PTY, the holder stops reading the client's socket; it resumes below 1 MiB. Queued
  input is discarded when the child exits. A paste (INPUT flag `paste`, capability `input.paste`,
  M2) is queued as one unit, bracketed when the child's current modes have `?2004` on (see INPUT).
- Every listening/accepted socket has `FD_CLOEXEC` and `SO_NOSIGPIPE`; accepted sockets get
  SO_SNDBUF 1 MiB / SO_RCVBUF 256 KiB. Socket file 0600 in a 0700 directory; the socket accepts only
  after meta.json exists; peer uid checked (`getpeereid`); at most 8 connections waiting for HELLO.
- Single client at a time; a HELLO with `takeover:true` disconnects the previous client (ERROR
  `taken-over`), otherwise the newcomer gets ERROR `busy`.
- **Flow control.** High-water mark = min(`--flow-limit` (1 MiB), ring / 2), low-water = half of
  it. A client's pending bytes = unsent frame bytes + ring bytes past its cursor. While a client is
  attached and not in drop mode, the holder stops reading the PTY above the high-water mark (the
  child blocks in `write`) and resumes below the low-water mark; the ring / 2 bound guarantees such a
  client is never lapped. A watchdog (every 100 ms while paused) switches the client to drop mode
  after 500 ms without write progress: the PTY is read freely again, bytes stay in the ring, and
  once the ring overwrites the client's cursor it gets `GAP` and continues from the ring's latest
  resync point. Drop mode ends when a write brings it below the low-water mark. Against a client that
  reads nothing the child stops after ≈ 2 MiB (1 MiB pending + ≈ 1 MiB of socket buffers; 4 MiB
  stopped it at ≈ 5 MiB). Ctrl+C during a `yes` flood with a 50 MB/s consumer: output stops after
  p50 36–41 ms at 1 MiB versus 75–91 ms at 4 MiB (`MeasurementTests.interruptLatency`).
- **Ring** (`ring` in the session directory, layout in `CoddProtocol.RingLayout`): mmap'd file,
  continued across holder restarts when the capacity matches (offsets keep increasing; WELCOME
  `spawnOffset` / header `spawnOffset` mark where this holder's child started). flock'd exclusively.
- **Reading a ring from disk** (M2: `CoddHolderClient.RingFileReader.read(path:limit:)` →
  `RingSnapshot`; the last screen of a session whose holder is gone, also `codd-holderctl ring`).
  Blocking, `O_RDONLY`, never `flock`, never writes: it works while a holder owns the ring. Magic,
  version, header size and capacity (= file size − 4096) are validated (else `notARing`; no file:
  `missing`; failed calls: `io`). Data and header are copied with `pread`, never mapped (a new holder
  that truncates the file to another capacity must not SIGBUS the app).
  - Start = the point a live holder's WELCOME `resync` would name for the same ring:
    `CoddProtocol.RingResync.replayPoint` of the header's valid slots (oldest first). The holder
    calls the same function for WELCOME `resync`, ATTACH `UINT64_MAX` and the GAP resume point, so
    the two cannot drift. No surviving point: the oldest byte, `modes` nil.
  - More than `limit` bytes (default 8 MiB) from there to the end: the newest resync point within
    the limit, else the newest `limit` bytes with `modes` nil.
  - Concurrent writer (RingLayout rule): `writeOffset` read first (acquire fence), the resync table
    copied until two consecutive copies agree (points past `writeOffset`, and a table whose offsets
    go backwards, are not used), the data copied, then the header read again. Unless the header is
    unchanged and its holder finished (flag bit2) or no longer runs (holder pid not a holder
    process), every byte below `writeOffsetAfter − capacity + RingLayout.maxWriteChunk` (64 KiB) is
    dropped: start moves to the next resync point at or after it, else to that offset with `modes`
    nil. A holder that started over on the ring (write offset went backwards) means a retry.
  - Exit fields from the header flags (`childExited`, `signaled`, `exitStatus` only after an exit,
    `holderExitedCleanly` = bit2, never set after a crash or SIGKILL), `spawnOffset`, `cols` / `rows`.
  - Measured: a full 8 MiB ring in ≈ 0.25 ms (warm page cache, debug build); during a 24 MiB
    flood into a 256 KiB ring, ≈ 250 reads per run, each a contiguous slice of what an attached
    client received (without the drop rule the same test sees torn bytes).
- **Output scanner** (no emulator): OSC 0/2 title, OSC 7 cwd (`file://` and `kitty-shell-cwd://`,
  host dropped, percent-decoded), BEL outside strings, OSC 9;4 progress, DEC private modes (1049/1047/47
  alt screen, 2004 bracketed paste, 1000/1002/1003/1006 mouse, 1004 focus, 2026 sync, 25 cursor,
  1 app cursor keys) and kitty keyboard flags (`CSI > n u` push, `CSI < n u` pop, `CSI = n ; m u`,
  one stack per screen). OSC strings over 4096 bytes are ignored. Title and cwd are reported only when
  they change.
- **Resync points** (offsets a reset terminal can replay from), at most 16 kept in the ring header,
  each with the modes in effect at it:
  - the spawn offset of every holder start, the offset right after `CSI 2 J`, after `ESC c` (RIS),
    and after a switch from the main to the alternate screen (`?1049h` / `?1047h` / `?47h`; modes set
    in the same CSI belong to the point);
  - `CSI 3 J` is NOT a point (it erases only the scrollback; `clear` sends 2J then 3J, so its 2J point
    replays the 3J harmlessly);
  - on the alternate screen only the newest point is kept (a new one replaces the previous
    alternate-screen point in place), so a program that redraws often never pushes main-screen
    points out of the 16 slots;
  - leaving the alternate screen drops the points recorded on it, so the last main-screen point is
    the latest again (replaying from it re-runs the full-screen program and its exit); only when no
    main-screen point survives in the ring does the exit offset itself become a point. The header's
    `resyncCount` therefore can decrease (the slots are rewritten from slot 0);
  - WELCOME `resync` (and ATTACH `UINT64_MAX`, and the GAP resume point) is the latest point still in
    the ring, except while the alternate screen is on: then it is the last main-screen point, if it
    is still in the ring and at most 2 MiB before the newest point, so a reattach also restores the
    main screen the program returns to (otherwise the newest alternate-screen point). When no point
    survived, `resync` falls back to `ringStart` and its modes are unknown (`resyncModes` absent).
    The selection is `CoddProtocol.RingResync.replayPoint` (M2), shared with `RingFileReader`.
- On child exit: drain what the PTY still holds, record the exit (ring header + meta.json), send
  `EXIT`, then keep serving; with no client attached the holder exits after the linger period
  (default 10 s; re-armed when the last client leaves). Ring and meta.json stay; meta.json gets
  `holderExited: true`.
- SIGTERM/SIGINT: drain, close the master (the child gets SIGHUP like a closed terminal window, plus
  SIGCONT), SIGKILL to its process group after 3 s, exit once it is gone. On the way out the holder
  gives the client up to 200 ms to receive the last frames.
- If the socket path disappears (directory vnode watch, plus a check every 30 s) the holder
  re-binds it; a path that still accepts connections belongs to a live holder and is never stolen.
- `meta.json` (atomic temp + rename, 0600; title / cwd / progress / size changes debounced 500 ms):
  `{"v":1,"session","holder":"0.1","proto":1,"holderPid","childPid","argv":[…],"cwd","socket","ring",
  "ringSize","cols","rows","startedAt":ms,"boot":kern.bootsessionuuid?,"title"?,"oscCwd"?,
  "progress":{"state","value"}?,"exited","exitStatus"?,"signaled"?,"exitedAt":ms?,"holderExited"}`.
  A record with `exited:false` can describe a dead holder (crash, reboot): readers check `holderPid`
  (and that it runs a holder executable) and compare `boot` with the current boot session.
- `codd-holderctl` (debug and scripts): `spawn`, `attach`, `send [--submit] [--paste] [--escapes]
  [--takeover] <text>` (`--paste`, M2: one paste through `HolderConnection.sendInput(paste:)`, so a
  holder without `input.paste` gets it bracketed by ctl from the WELCOME modes), `tail`, `list`,
  `kill`, and `ring <sessionDir> [--raw] [--limit <bytes>]` (M2: `RingFileReader` on
  `<sessionDir>/ring`, no holder needed; one `key=value` line each for `start`, `end`, `size`, `modes`
  (WELCOME-style JSON or `unknown`), `spawnOffset`, `childExited`, `exitStatus` (`none` before an
  exit), `signaled`, `holderExitedCleanly`, `cols`, `rows`; `--raw` writes only the bytes
  `[start, end)`; exit status 2 when there is no ring file, 1 when it is not a ring).

### Holder wire protocol v1 (frozen in M1; extend only via capability flags)

Code: `Packages/CoddHolder/Sources/CoddProtocol` (framing, messages, payload layouts),
`CoddHolderClient.HolderStream` (the app's client), `HolderConnection` (blocking; ctl and tests).

**Frozen.** v1 below is final. Anything new is additive and announced by a capability string:
new frame types (receivers ignore types they do not know), trailing bytes after a fixed layout
(receivers ignore them), new JSON keys (decoders ignore unknown keys), or behaviour a client opts into
by listing the capability in HELLO `caps`. `proto` stays 1.

Frame: `u32 BE length` (bytes of type + payload, 2 … 1 MiB = 1,048,576) | `u16 BE type` | payload.
All integers are big-endian. A length outside that range is a framing error: the holder answers
ERROR `bad-frame` and closes; a client closes. OUTPUT frames carry at most 64 KiB of data.

| Type | Dir | Payload |
|---|---|---|
| 0x0001 HELLO | c→h | JSON `{"proto":1,"client":str,"takeover":bool,"caps":[str]}`; only `proto` is required. `client` is cut to 128 bytes (control characters → `?`) |
| 0x0002 WELCOME | h→c | JSON, see below |
| 0x0003 ATTACH | c→h | `u64 fromOffset` (`UINT64_MAX` = latest resync point) |
| 0x0004 DETACH | c→h | — stop OUTPUT; the connection stays open for control frames |
| 0x0010 OUTPUT | h→c | `u64 offset` (stream offset of the first byte) + bytes |
| 0x0011 GAP | h→c | `u64 from`, `u64 to` [+ `gap.resync`: `u64 replayEnd`, mode snapshot] — bytes `[from, to)` were lost |
| 0x0012 ATTACHED | h→c | `attach.ack` only: `u64 start`, `u64 replayEnd`, mode snapshot (25 bytes) [+ `attach.modes`: mode snapshot of the current modes] |
| 0x0020 INPUT | c→h | `u8 flags` (bit0 = submit, bit1 = paste with `input.paste`) + bytes |
| 0x0021 RESIZE | c→h | `u16 cols, u16 rows, u16 pxW, u16 pxH` (TIOCSWINSZ) |
| 0x0022 SIGNAL | c→h | `u8 signo` |
| 0x0023 REPAINT | c→h | — |
| 0x0030 EXIT | h→c | `i32 status`, `u8 signaled` (status = exit code, or the signal number) |
| 0x0040 PING / 0x0041 PONG | both | `u64 token` |
| 0x0050 TITLE | h→c | UTF-8 title (OSC 0/2), sent only when it changed |
| 0x0051 CWD | h→c | UTF-8 path (OSC 7, decoded), sent only when it changed |
| 0x0052 BELL | h→c | — (consecutive unsent BELLs coalesce) |
| 0x00FF ERROR | h→c | JSON `{"code":str,"message":str}`; the holder closes the connection after every ERROR. Before it, frames not started on the wire are dropped and a partly written one is finished; the rest is written with at most 500 ms of blocking (a client that is reading always gets it) |

Mode snapshot (9 bytes): `u32 TerminalModes.bits`, `u32 kitty flags`, `u8 flags` (bit0 = known).
Bits in the order 1, 25, 1000, 1002, 1003, 1004, 1006, 1049, 2004, 2026 (bit 0 = `?1`). A position
whose modes are known is a resync point: reset the terminal, apply
`TerminalModes.restoreSequence()` (never restores `?2026`), replay from it.

**Capabilities** (WELCOME `caps` = what the holder supports; HELLO `caps` = what the client opts
into): `input.submit`, `repaint`, `flow`, `osc.title`, `osc.cwd`, `bell`, `gap.resync` (always on:
GAP carries the extension), `attach.ack` (opt-in: ATTACHED is sent only to a client whose HELLO
`caps` lists it), `attach.modes` (always on: ATTACHED carries the current modes after its v1 fields),
`input.paste` (M2, always on: INPUT flag bit1 = one paste, see INPUT; no HELLO opt-in, a client sets
the bit only for a holder that lists the capability).

**Handshake.** The client's first frame must be HELLO (anything else: ERROR `hello-required`).
HELLO must arrive within 5 s of connecting (checked each second; ERROR `hello-timeout`). `proto` ≠ 1:
ERROR `unsupported-proto`. Another client attached and no `takeover`: ERROR `busy`; with `takeover`
the old client gets ERROR `taken-over`. Otherwise WELCOME:
`{"proto":1,"holder":"0.1","session","childPid","cols","rows","ringStart","ringEnd","resync","modes":{…},
"title"?,"cwd"?,"exited","exitStatus"?,"signaled"?,"caps":[…],"holderPid","ringSize","spawnOffset",
"progress":{"state","value"}?,"resyncModes":{…}?}`.
- `ringStart` oldest offset in the ring, `ringEnd` next offset the child will write, `resync` the
  latest resync point in the ring (`ringStart` if none survived), `resyncModes` the modes at
  `resync` (absent in that fallback), `modes` the modes after `ringEnd` (for a client continuing
  live). Use `resyncModes`, not `modes`, before a replay: kitty push/pop are not idempotent.
- `modes` JSON: `{"1":bool,"25":bool,"1000":…,"1002":…,"1003":…,"1004":…,"1006":…,"1049":…,"2004":…,
  "2026":…,"kitty":n}` (47/1047 fold into 1049).
- ERROR codes: `bad-frame` (framing or payload error), `hello-required`, `unsupported-proto`,
  `busy`, `taken-over`, `hello-timeout`. `message` is at most 1024 bytes, control characters → `?`.

**ATTACH.** `UINT64_MAX`: stream from the latest resync point. An offset below `ringStart`: GAP
`from = offset, to = latest resync point`, then stream from there (replay never starts inside an
escape sequence). An offset above `ringEnd` is clamped to `ringEnd`. Ring bytes are streamed, then
live output. A new ATTACH on an attached connection restarts at the new position; frames already
queued for the old position are still sent first. With `attach.ack`, ATTACHED is written into the
outbound stream when the ATTACH is processed, so everything after it belongs to this attach:
`start` = the resolved position (the requested offset when it was below `ringStart`, a GAP follows),
`replayEnd` = `ringEnd` at that moment (bytes below it are history; a terminal must not answer queries
in them), mode snapshot = modes at `start` if it is a resync point, then (`attach.modes`) the modes at
`replayEnd`: a replay can start on the main screen before a full-screen program that is still running,
and a client decides on REPAINT by what the replay ends in. Clients should send HELLO and
the first ATTACH in one write: the holder handles every frame of one read in one pass, so WELCOME and
the attach describe the same ring state.

**GAP.** Sent when a client in drop mode was lapped (its cursor fell out of the ring), and for an
ATTACH below `ringStart`. OUTPUT continues at `to`, the ring's latest resync point (or its oldest
byte when no point survived; modes unknown then). With `gap.resync`, `replayEnd` = the holder's write
offset when the GAP was generated (bytes in `[to, replayEnd)` are history) and the snapshot = the
modes at `to`. The client resets its terminal, applies the modes and keeps feeding: no re-ATTACH needed.

**Ordering.** OUTPUT offsets are contiguous per attach except across a GAP. TITLE / CWD / BELL / EXIT
sent to an attached client are released only once its OUTPUT cursor passed the stream position where
they happened, so they never overtake the output that produced them. To a client that has not
attached (or detached) they go out immediately. Consequences a client must handle:
- EXIT can precede the replay of an ATTACH the holder processed after the exit (client not attached
  at exit time);
- a child that exited before HELLO produces no EXIT frame on that connection (WELCOME `exited`,
  `exitStatus`, `signaled`, and `ringEnd` is the final offset);
- EXIT goes to the client attached at the time of the exit, once.
`HolderStream` turns this into one sequence: `onExit` at most once, held back while an attach is
pending until that attach's replay reached its `replayEnd` (the final offset when the child had
already exited), immediately when no attach is requested (also for WELCOME `exited`).

**INPUT.** At most 1 MiB − 3 bytes per frame; a larger paste is split and only the last frame
carries submit. Submit: the holder writes `\r` 10 ms after the last payload byte reached the PTY;
input arriving meanwhile waits behind it. Input after the child exited is discarded.

**Paste** (`input.paste`, M2; the composer's multi-line prompts). An INPUT frame with flag bit1 is
one paste. When the child's current modes (the scanner's state after everything read from the PTY
so far) have `?2004` on, the holder queues `ESC [ 200 ~` + payload + `ESC [ 201 ~` as one unit,
after removing every `ESC [ 200 ~` and `ESC [ 201 ~` from the payload (`CoddProtocol.BracketedPaste`:
a removal that uncovers another marker removes that too, so pasted text can never end the bracket
early; a payload with nothing left queues nothing). With `?2004` off the payload is queued
unchanged. With submit as well (flags `0x03`), the `\r` is written 50 ms (`Holder.pasteSubmitDelayNanoseconds`) after
the last byte of the unit reached the PTY instead of 10 ms; input arriving meanwhile waits behind it
like after a plain submit. Example: `00 00 00 05 | 00 20 | 03 | 68 69` = paste "hi", then Enter;
a child with `?2004` on reads `1B 5B 32 30 30 7E 68 69 1B 5B 32 30 31 7E`, and 50 ms later `0D`. Input
backpressure, the frame limit and the discard after exit are unchanged; frames without bit1 behave
exactly as before. A paste larger than one frame reaches the holder as consecutive pastes (every
frame carries bit1, only the last submit). Holders without the capability ignore the bit, so a
client that does not find `input.paste` in WELCOME `caps` brackets itself (same stripping) when the
newest modes it knows (WELCOME `modes`, replaced by each ATTACHED's current modes) have `?2004` on,
and sends plain INPUT with the normal submit; those modes can be stale.

**RESIZE** ignores zero cols/rows and ends a REPAINT in progress. **SIGNAL** accepts 1…31, goes to the
PTY's foreground process group (`tcgetpgrp`, else the child), ignored after exit. **REPAINT** narrows
the PTY by one column (widens when cols = 1) so the child redraws, and restores the size once its
output was quiet for 30 ms after it started writing, or at `?2026l`, at the latest after 150 ms.

**Keepalive.** Either side may PING; the holder answers PONG with the same token (queued as a
droppable control frame, released before OUTPUT that is not materialized yet) and never sends PING itself. The control
queue holds 256 frames; when full, the oldest TITLE / CWD / BELL / PONG is dropped (WELCOME and EXIT
never are). `HolderStream` sends PING after 10 s without a byte from the holder and closes with
`keepaliveTimeout` when 30 s pass without any byte after it (not while its reading is paused); its
keepalive tokens have bit 63 set.

**Stream offsets** are monotonically increasing u64 over the session's whole output, continued
across holder restarts on the same ring (the ring keeps the last `ringSize` bytes).

**Client (`HolderStream`, M1).** Non-blocking AF_UNIX socket (SO_RCVBUF 1 MiB), read/write dispatch
sources on a private serial queue, callbacks only on that queue. Frames that arrive whole in one read
are handed to `onOutput` in place (no copy); only a frame split across reads is assembled. Unsent
client data is bounded (16 MiB): `sendInput` throws `outboundQueueFull` rather than dropping input.
`sendInput(_:submit:paste:)` (M2) sets the paste flag when `supportsPaste` (WELCOME `caps` lists
`input.paste`; false before WELCOME), else brackets as described under INPUT; a paste sent before
WELCOME waits for it, and input sent after it waits too, so the order holds.
`pauseReading()` stops delivery after the current frame (both halves of a frame that straddles
`replayEnd` count as one) and stops reading the socket; the holder's flow control then pauses the
child and, after 500 ms, switches to drop mode (GAP on resume).
`attach(from:)` / `detach()` suppress OUTPUT of the previous attach from the moment they return.
`onClosed` fires exactly once (peer closed, ERROR, protocol or I/O error, timeouts, `close()`).

## State model (from design/SPEC.md §3)

States: waiting(permission|question|plan|other) · error(reason) · done (unseen) · busy · compacting · idle ·
starting · unknown(no hook) · shell · exited · stopped(resumable). Attention = waiting + error.
Primary source = hooks (ported `applyEvent`), then `~/.claude/sessions/<pid>.json` registry (busy/idle/waiting),
then holder EXIT, then OSC title glyph (◐/◑ busy, ✳ idle). `claude agents --json` is not used (M2 D6).
External sessions (claude processes CODD did not start) get their state from the registry only.
Overlays that are not states: UNREACHABLE (`SessionVM.unreachableSince`, D8) and stale (IDLE for
more than 1 h, `SessionVM.isStale`, D15).

## Performance budgets (targets, verify with os_signpost + Instruments)

Host input path < 1 ms p99 · zsh keystroke-to-glyph < 10 ms p95 · 120 fps streaming, frame p99 ≤ 8.3 ms ·
idle CPU: app < 0.5 % (visible) / < 0.1 % (hidden), holders ≈ 0 · memory: holder ≤ 2.5 MB, app base < 80 MB,
total with 15 sessions < 300 MB · session switch hot < 16 ms · launch to interactive sidebar < 400 ms.
M4 (debug builds, component tests): notes index build of 1,000 notes < 2 s · notes search p95 < 20 ms (CJK 1–3
characters) · a 1 MiB note loads < 300 ms and restyles a keystroke < 30 ms · a 1 MB code file's first highlighted
screen < 150 ms and a keystroke < 16 ms · git status of 5,000 files < 300 ms (measured numbers: docs/M4-REPORT.md §4).
M5 (`scripts/m5-perf.sh`, D16; one `PERF <name> value=… budget=… PASS|FAIL|SKIP` line per budget, its table
mirrors this paragraph and changes with it): session switch cold < 50 ms (max, through 15 sessions in order) ·
GPU: footprint growth while waiting lamps pulse < 5 MB over 30 s · **while a visible terminal animates: total
< 550 MB** (changed 2026-10-19 from "< 300 MB like the quiet total": the extra is the Metal driver's
per-process pool, measured by the perf component as 27–28 regions of 8 MB, about 225 MB, independent of window
size and frame rate, the same with a 60-line Metal program that has no window and no libghostty
(`MTLDevice.currentAllocatedSize` 24 MB); it is paid once per process while anything draws at ≥ 1 Hz and leaves
about 1 s after the last frame; removing it would mean not drawing a visible terminal, a visible change; see
docs/M5-REPORT.md §4). The hot tier is a segmented LRU (D15: probation 2 + protected 4 = 6 hot surfaces).
Measured on a Debug build (what the script runs; fix round 1, 2026-10-19): **launch to interactive sidebar
< 450 ms** (the product target, a Release build, stays < 400 ms; Debug measured 410 ms median at load1 2.1:
its unoptimized Swift builds and shows the main window in about 175 ms), counted until the store installed
the loaded layout (not until the hook endpoint is up); **idle CPU visible** is measured once every row is past
the 2 minutes in which its durations count seconds (from 125 s after launch: 0.16 %; in the first 2 minutes
15 rows redraw every second, 0.7–1.0 % on Debug, a running clock rather than idle).
Measured M5 numbers and any further budget change with its reason: docs/M5-REPORT.md §4.

## Coding rules

- Swift 6 language mode, strict concurrency. Terminal bytes never go through the main actor or Observation.
- No emoji in UI; glyph allow-list and colors from design/SPEC.md + design/helmet.html (Phosphor Console tokens).
- UI copy: 繁體中文 for explanatory text, English UPPERCASE for structural labels.
- Never write to `~/.claude/settings.json` from tests. Never run the real cswap in tests (use
  `scripts/m3-fixtures` and CoddCore's fixtures); never call the Anthropic usage API.
- M4: never touch `~/.claude.json` or `~/.codex` from tests (a `make-claude-json.sh` file and
  `-codd-claude-json`); git in tests and fixtures runs with an isolated config (`GIT_CONFIG_GLOBAL=<empty
  temp file>`, `GIT_CONFIG_NOSYSTEM=1`, `-c core.fsmonitor=false`) and only in temp repos; automatic trash
  moves never reach `~/.Trash` from a test root (D38); background runs never write the general pasteboard
  (D39); a change to an existing package keeps the App compiling (D40).
