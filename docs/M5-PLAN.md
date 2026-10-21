# M5 plan — Hardening and release

Goal: CODD Desktop 1.0. A new user gets a first-launch wizard (the frozen Onboarding artboard: detect
the environment, import projects from `~/.claude.json` read-only, tidy hooks through the M3 Hook 差異
dialog, see the fixed notes location and register MCP through the M4 button, see cswap accounts, allow
notifications); existing users are never interrupted and can reopen it from Settings › 關於 and the
Help menu. The app gets its final identity (`app.codd.CODD`, user decision 2026-10-18) with CODD's own
UserDefaults copied over once. Every JSON file CODD owns has a version; one preflight pass at launch
migrates older files after a backup, never overwrites a newer CODD's file and moves a corrupt one aside
with one banner naming it; `cache/` is simply rebuilt. The performance budgets are measured by a script
(launch, idle CPU, switch, memory, GPU while animating) and either met or changed with the measured
reason; the hot tier stops thrashing (scan-resistant policy). The current client is proven against
holders built from the M1 and M4 commits. `scripts/release.sh` builds, signs and zips a Release (and
installs it only when the user runs it). VoiceOver labels and keyboard navigation cover the custom
views, with an automated audit; a copy audit checks every user-visible string. Final docs: README,
繁體中文 user guide, ARCHITECTURE / ROADMAP up to date, the M5 report. The post-M4 carried bug (stop
during STARTING) is fixed; every e2e script fails when a CODD window rises above the user's windows.

Sources (read before working): design/SPEC.md §2, §4, §5, §7.14 (Onboarding) with the §8 / §9 / §10
overrides; the APPROVED, frozen artboard `design/artboards-src/Onboarding.src.html` (implement it, do not
redesign; user decisions below override it where stated); `design/artboards-src/StatusDialogs.src.html`
(dialog B / C reused by steps 3 and 5); `design/helmet.html` (tokens, `.input:focus` = the focus style);
docs/ARCHITECTURE.md (source of truth: data root tree, budgets, background launches, wire protocol v1);
docs/ROADMAP.md (standing decisions, M5 scope); docs/M1-REPORT.md §5 (F2 GPU memory, F5 hot tier),
docs/M2-REPORT.md §4, docs/M3-REPORT.md §4 and docs/M4-REPORT.md §4–§5, §12, §13 (numbers, known
issues); scripts/TEST-MAP.md (what to run for what changed). Reference only (read, never copy, never
run): the user's CODD web app at `~/GitHub/codd-web` (its `SetupView` plans and
applies `settings.json` hooks with a backup; nothing else of it is imported).

User decisions for M5 (2026-10-18, orchestrator): bundle id `app.codd.CODD`; onboarding shows the data
location fixed at `~/Library/Application Support/CODD` with notes in `notes/` (no relocation; the
artboard's `~/.codd/notebook` is overridden); every standing decision of docs/ROADMAP.md holds; the
design is frozen. User rule (2026-10-18): lean testing (test what changed, everything once at the end of
M5); 「今晚繼續做，但要記得不要過度測試」.

Out of scope: remote (§7.15 stays the static placeholder), Sparkle, notarization, Developer ID, App
Store, a `coddd` agent, relocating the data root or the notes, importing anything of CODD web beyond
what step 3 removes, new key equivalents (menu items only).

---

## 0. Starting point (code survey, 2026-10-18)

- `project.yml`: `bundleIdPrefix: app.fancycodd`, `PRODUCT_BUNDLE_IDENTIFIER: app.fancycodd.CODD` /
  `app.fancycodd.CODDTests`; the three embed phases sign helpers ad-hoc as `app.fancycodd.codd-holder |
  codd-hook | codd-statusline`; `CFBundleShortVersionString "0.1.0"`, `CFBundleVersion "1"` are literal
  properties (xcodegen writes App/Info.plist from them).
- Old id in code: queue labels (`app.fancycodd.*`, App/Real, App/Session, CoddHooks, CoddHolder
  `HolderStream`), `OSSignposter(subsystem: "app.fancycodd.CODD")` (TerminalHub), private pasteboard
  `app.fancycodd.CODD.private` (App/Support/CoddPasteboard), sidebar drag type `app.fancycodd.sidebar-node`,
  `app.fancycodd.CoddUI.UIZoomDidChange` (CoddUI), the distributed `app.fancycodd.CODD.showMainWindow`
  (App/Real/InstanceLock). BackgroundWindows (App/Window) recognises another CODD by
  `Bundle.main.bundleIdentifier`. Spikes/ and historical docs also mention it.
- UserDefaults keys CODD writes (all in the app's own domain): `NSWindow Frame CODDMainWindow`,
  `NSSplitView Subview Frames <MainSplitViewController.defaultAutosaveName>`, `NSStatusItem Preferred
  Position CODDStatusItem` / `NSStatusItem Visible CODDStatusItem`, the M1/M2 `CODDNotificationsEnabled`
  (already migrated into preferences.json on the standard root). DEBUG-only argument-domain keys
  (`CODDMetrics`, `CODDForceVisibleTimers`, `codd-verbose-log`) are not persistent.
- Notifications: `SessionNotifier` asks for authorization lazily at the first notification due.
  Login item: `LoginItemController` never registers at launch (M3 D21), only when the toggle changes.
- Defaults written by test runs (critique 2026-10-18): every launch on ANY data root saves `NSWindow Frame
  CODDMainWindow` (`MainWindowController`, `savesFrame` is off only for the layout sweep), the split view
  frames and the status item position (`StatusItemController.autosaveName = "CODDStatusItem"`) into the
  app's own domain. Today that domain is shared with the user's `build/user-*` builds; after D1 it is the
  installed Release's `app.codd.CODD`, and the e2e runs of I1–I4 and the wrap-up would write it before
  the user's first Release launch (so a "copy where missing" migration would skip the user's real frame).
  Hosted unit tests create no window controller or status item and write no defaults.
- Newer files: `LayoutStore` throws `unsupportedVersion` and the App shows the sidebar EMPTY (read-only);
  `PaneLayoutStore.decode` returns nil for a newer file (not read, then overwritten). Both are "not read as
  far as possible" gaps besides the four save gaps below.
- Release builds keep only mode, data root and Claude directory (`RealModeOptions.releaseSubset`): on a
  throwaway `-codd-data-root` a Release never finds cswap (M3 D3), never runs the user's claude (M3 D28:
  `claudeExecutable(standardRoot: false)` is nil) and never writes `~/.claude.json` (M4 D22). The init-time
  `VersionProbe` resolves claude without the login PATH (only `~/.local/bin/claude`); condense resolves it
  through `LoginEnvironment.current()["PATH"]` (AppDelegate+Cleanup).
- `-CODDMetrics` implies mock mode unless `-codd-real-holders YES` is passed too, cycles every session in
  sidebar order (with more than 6 terminals every switch is cold: there is no hot / cold split) and calls
  `exit(0)` (holders survive). `codd-term-demo` calls `NSApp.activate()`. There is no `README.md`, no
  `VERSION`, no Help menu, and the Onboarding artboard's dates are `M/dd` (`10/09`, `9/21`).
- `~/.Trash` cannot be listed from a Claude Code shell (TCC, M4 report §5); `/usr/bin/trash` exists
  (macOS 27.0.1 here). Emoji in tracked files today: Unicode test data only (`😀`, `🚀` in CoddCore,
  CoddCodeEditor, CoddHolder tests); `✻` and `❯` (Claude's own glyphs) are text-presentation symbols.
- Data files: most stores already move a corrupt file aside (`<name>.corrupt-<epoch ms>`) and keep a
  newer version read-only (layout.json, preferences.json, profiles.json, cleanup.json, files/*.json,
  notes/.codd/*.json, quota.json). Gaps: `panes.json` (a newer file decodes to nil and the next save
  rewrites it), `sessions/<id>/composer.json` (no version; corrupt = empty, kept), 
  `claude-settings-backups.json` (`v != 1` reads as empty, the next entry overwrites it), `config.json`
  (a newer `v` is still repaired / gains `mcpToken`). No store reports to the user except preferences.
- `RecentProjectsReader` (App/Real/ClaudeDirectory.swift) already reads `.claude.json` project keys,
  hides `/.claude-worktrees/`, sorts by the transcript folder's mtime (cap 200). `TranscriptCatalog`
  (CoddCore) knows `sdk-*` entrypoints. `HolderSessionStore.addGroup(name:color:)` and
  `addProjects(paths:toGroup:atIndex:)` exist.
- Installer: `ClaudeSettingsService` inspection (`isUpToDate`, `hasLegacy`, `legacyHookEvents`,
  `statusLine` state) → `StatusPageData` maps it for STATUS; dialog B = `presentHookDiff(_:on:readOnly:)`.
  MCP registration: `MCPRegistrationService` + `MCPRegistrationDialog.present(on:)`. Dialog C
  (`presentAddAccount`) shows the main window first (it hosts an ephemeral SHELL session).
- Accessibility: many views already set labels (App 188 calls, CoddUI 167, UI packages 30–150 each);
  CoddUI controls set `focusRingType = .none` and draw no focus state; there is no audit.
- Perf: `-CODDMetrics YES` (DebugMetrics: launch → sidebar drawn, switch p50/max, footprint; exits),
  `-CODDMetricsDelay`, `-codd-spawn-shell <dir> -codd-spawn-count n`, `-CODDForceVisibleTimers YES`,
  `-CODDHideAfterLaunch YES`. Background windows are covered, so libghostty stops drawing in automated
  runs (M3 §4). TerminalTierPolicy = strict LRU of 6 hot (F5). Measured: app 113–140 MB idle with
  sessions, 361–427 MB while a shown terminal animates (F2, ~230 MB of Metal memory in libghostty).
- `scripts/tools/zorder-watch.swift` (untracked, in the repo now) matches windows by owner NAME `CODD`,
  so the user's own CODD counts as the run's. `scripts/m4-layout-sweep.sh` defaults to
  `build/m4-layout-sweep`. No signing identity on this Mac (`0 valid identities found`).
- `HolderSessionStore.stop(_:)` (App/Real/HolderSessionStore.swift) needs a live holder pid; a session
  still STARTING (spawn in flight) is skipped silently.

## 1. Decisions (reversible technical defaults; repeated in the report)

- **D1 Bundle id.** `app.codd.CODD` for every configuration; tests `app.codd.CODDTests`; helper signing
  identifiers `app.codd.codd-holder`, `app.codd.codd-hook`, `app.codd.codd-statusline`; every queue
  label, the signposter subsystem (`app.codd.CODD`), the private pasteboard (`app.codd.CODD.private`), the
  drag type (`app.codd.sidebar-node`) and the zoom notification (`app.codd.CoddUI.UIZoomDidChange`) use
  the new prefix. The show-window distributed notification is POSTED under both
  `app.codd.CODD.showMainWindow` and the legacy `app.fancycodd.CODD.showMainWindow` and OBSERVED under
  both (a new build launched while an old build holds the lock still brings that one forward).
  BackgroundWindows treats both ids as CODD (`CoddIdentity.allBundleIdentifiers`). Spikes/ and the
  M0–M4 plans / reports stay as written (history); `git grep fancycodd` may only hit them,
  `Spikes/`, `design/research/`, the migration constant and this plan.
- **D2 Defaults migration.** Once, on the standard data root only, at launch before any window:
  CoddDataStore `DefaultsDomainMigration` copies CODD's own keys (prefixes `NSWindow Frame CODD`,
  `NSSplitView Subview Frames CODD`, `NSStatusItem Preferred Position CODD`, `NSStatusItem Visible CODD`,
  `CODD`; never the DEBUG tool keys `CODDMetrics*`, `CODDSelfTest`, `CODDSnapshotDir`,
  `CODDForceVisibleTimers`, `CODDHideAfterLaunch`) from the persistent domain `app.fancycodd.CODD` into
  the app's domain, then sets the marker `CODDDefaultsMigratedFrom = "app.fancycodd.CODD"`. While the
  marker is absent the copied keys REPLACE what the new domain has (before the first standard-root launch
  only a test or throwaway run can have written them); once it is set nothing is copied again. The old
  domain is never modified. Any other data root never migrates (automated runs never read or write the
  user's domains). Log `defaults migrated from=app.fancycodd.CODD keys=<n>` / `skipped reason=…`. See D25.
- **D3 Notifications.** The permission belongs to the bundle id, so macOS asks again: new users in
  onboarding step 6 (one line saying why), existing users at the first notification due (unchanged
  lazy path). Documented in the report and the user guide.
- **D4 Login item.** Never registered at launch (M3 D21 stays). When 登入時啟動 is ON on the standard root
  but `SMAppService.mainApp.status` is not `.enabled` / `.requiresApproval`, the row under it says
  「CODD 換了識別碼：請把「登入時啟動」關掉再打開一次」; the user guide says to remove the old CODD
  entry in 系統設定 › 一般 › 登入項目.
- **D5 When onboarding shows.** Decided once in `applicationWillFinishLaunching`, right after the
  instance lock, before anything writes: the standard data root is NEW when it has no `layout.json`, no
  `panes.json`, no `sessions/*/meta.json` and no `onboarding.json` (CoddOnboarding `OnboardingGate`). Any
  other root only with DEBUG `-codd-onboarding auto|show` (default `never`), so no e2e script changes;
  Release with `-codd-data-root`: never automatic. Mock mode: `-codd-show onboarding[:<1-6>]`. Reopen:
  Settings › 關於 `首次啟動設定 [重新執行]` and `說明 › 首次啟動設定…`. While the onboarding window is
  open, a show-window request (second instance), a Dock click (`applicationShouldHandleReopen`) and the
  status item's open action bring the onboarding window forward instead of the main window. The facts
  (claude, cswap, hooks, data root) are probed only while the onboarding window shows, never in ordinary
  runs (no extra `claude --version` in the m1–m4 scripts).
- **D6 The window.** A separate `OnboardingWindowController` window (hiddenInset title bar, traffic
  lights, no rail, no sidebar; title `首次啟動設定`), default content 1240 × 820, minimum 1011 × 640;
  the artboard's 1440 × 900 is the design size (the table's path column flexes). The main window is
  built as usual but shown only when onboarding ends (開始使用, 略過 on step 6, or closing the window).
  Real mode starts as usual behind it (hook server, cswap store, MCP), so detection reads live state.
- **D7 `onboarding.json`** (USER DATA, §2.3): written when onboarding ends; closing the window counts as
  ended (it never nags; Settings / Help reopen it). ⌘Q in the middle writes nothing.
- **D8 Import source and defaults.** `<claudeDir>/../.claude.json`, else `<claudeDir>/.claude.json`,
  read only (bytes and mtime unchanged), ≤ 64 MiB, at most 2,000 project keys; the file may be a symlink
  (dotfile managers) and is read through it (reading is harmless; transcript folders and files are
  `lstat`ed and never followed); a key is a candidate when it is an absolute path to an existing folder;
  paths are compared standardized without a trailing slash (also against the projects already in CODD). 最近使用 = the newest `.jsonl` mtime in its transcript
  folder (`<claudeDir>/projects/<sanitized>`, §2.5), else the folder's mtime, else none (sorted last).
  Transcripts = the number of `.jsonl` files there. Hidden by default (`顯示隱藏項目` shows them dimmed):
  paths containing `/.claude-worktrees/`, and SDK-only projects (each of the newest ≤ 3 transcripts has
  `"entrypoint":"sdk-` in its first 8 KiB). Projects already in CODD are left out (`另有 n 個已在側欄`).
  Pre-checked: used within the last 14 days, at most 12, newest first. Page: 12 rows, `載入更多 ↓` adds
  24; the filter searches every candidate. Applied at step 2's `下一步`; `略過` imports nothing.
- **D9 依父資料夾建議分組.** For the checked rows: (1) an existing CODD group that holds a project whose
  parent folder equals the row's parent → that group; (2) else a parent folder shared by ≥ 2 checked rows
  → a new group named after the parent's last path component (on a name collision `<grandparent> ·
  <parent>`), colors in SPEC §3 tag order (red, blue, green, yellow, purple, orange, pink, cyan) skipping
  colors already used by groups; (3) else 未分類. The button assigns every checked row its suggestion;
  the group menu marks the suggested entry `建議`. Unchecked rows keep their suggestion but their select
  is disabled (artboard). `+ 新群組…` asks for a name inline (`命名後套用`) and takes the next free color.
- **D10 Name prefix (`.pp`).** `parent/` is shown before the folder name when the name is not unique
  among the candidates, or when it is shorter than 7 characters and its parent is neither the home
  folder nor a common root (`Github`, `GitHub`, `github`, `Project`, `Projects`, `Developer`, `Code`,
  `code`, `src`, `repos`, `work`). Path column: `~` for the home folder; when the path is wider than the
  column, the view elides from the front by whole components and keeps as many trailing components as fit
  (`~/…/websites/業主/Northstar invoice system` keeps 3, `~/…/orb-toolkit-suite/orb-toolkit-backend` keeps 2
  on the artboard; at least the last one, then tail-truncated); full path in the tooltip and the
  accessibility value. 最近使用: `今天 HH:mm`, `昨天 HH:mm`, else `M/dd` (`10/09`, `9/21`: month unpadded,
  day padded, as the artboard).
- **D11 Boot log content.** Rows `claude`, `cswap`, `hooks`, the data root, then `projects` (the
  artboard's `node` row is dropped: CODD Desktop needs no Node). Tags `[ OK ]` (success), `[ .. ]`
  (pending, amber), `[FAIL]` (danger), `[ -- ]` (skipped, dim). The data-root row names
  `~/Library/Application Support/CODD` (the fixed location) and `MCP 127.0.0.1:<port> 可用`. The stepper
  foot's version line is `<CFBundleShortVersionString> (build <CFBundleVersion>) · macOS <x.y>`. The hooks
  row keeps the artboard's `需要更新（<n> 個事件）`, but in CODD Desktop the pending events are CODD web's
  legacy hooks to remove (sessions get CODD's hooks per launch): its detail is `<file> · 舊版 CODD web：<events>`
  (not `缺 …`), and step 3's stepper detail is `◆ 需要更新 · 舊版 <n> 個事件` (`◆ 需要更新 · 狀態列` when only
  the global status line is outdated). New copy, listed for review.
- **D12 `已在用 CODD Web？匯入它的設定 →`.** Shown only when the inspection finds CODD web leftovers
  (legacy hook handlers or its `codd-statusline.js` status line); it jumps to step 3, whose dialog B
  removes them (`removeLegacy`). CODD web's projects already come from the same `~/.claude.json`.
- **D13 Step 5 `+ 新增帳號`.** Uses M3 dialog C, which needs the main window (ephemeral SHELL session):
  the main window comes forward with the dialog; the onboarding window stays open and refreshes when the
  accounts change.
- **D14 Data versioning = one preflight** (§2.2): CoddDataStore `DataPreflight` runs off the main actor
  first thing in real mode, before any store loads. Older version with a registered migration →
  backup `<name>.v<from>-backup-<yyyyMMdd-HHmmss>` (0600, never overwritten) then migrate; newer → left
  untouched and reported (stores keep it read-only; the four gaps above are closed); corrupt USER DATA →
  `<name>.corrupt-<epoch ms>` (the existing convention) and defaults; corrupt DERIVED → removed;
  `config.json` is never moved (its store repairs it and keeps the port). No migration is registered at
  M5 (every file is version 1; a composer.json without `"v"` counts as 1); the registry is tested with
  synthetic migrations. `cache/VERSION` (`1`): a different number or an unreadable file → the folder's
  contents are deleted and rebuilt; MISSING → just written (the post-M4 cache layout is version 1, so the
  user's notes index is not rebuilt for nothing). One banner per issue (§2.2), queued.
  Safety rule (critique): the preflight is never stricter than a file's own store: a file its store would
  load without moving it aside is never moved by the preflight (a missing, non-integer or < 1 version is
  `absentVersion` where the store reads it so, e.g. preferences.json, cleanup.json, notes `.codd/` files;
  corrupt only where the store itself rejects it: layout.json, profiles.json, files/*.json). I1 proves it
  with each real store's own output on a temp root (`scan()` reports every file `current`). A file the
  store itself moves aside later (a schema error the preflight cannot see) still gets the corrupt banner:
  after the stores loaded, `DataPreflight.asideFiles(createdSince: launch)` lists `<name>.corrupt-<ms>`
  files made during this launch and each one not reported yet is queued. Newer files are READ as far as
  possible: I1 makes a newer layout.json load read-only through the v1 decoder when it decodes (today the
  sidebar shows empty) and a newer panes.json decode leniently (today nil, then overwritten).
- **D15 Hot tier (F5).** Segmented LRU inside `TerminalTierPolicy`: probation 2 + protected 4 = the same
  6 hot surfaces. A hidden terminal enters PROTECTED when it was revealed from hot again or when this
  showing lasted ≥ 5 s (the user worked in it); a quick flip (< 5 s, e.g. ⌃Tab or ⌘K scanning) enters
  probation. Eviction takes probation's oldest first; a full protected segment demotes its oldest to
  probation's head. A cyclic scan through many terminals churns probation only, and "work in X for a
  while, glance at A, B, C, back to X" keeps X hot (plain "second access" SLRU with probation 2 would
  evict X there: critique). The policy takes an injected monotonic clock (default `ContinuousClock`), so
  `setVisible`, `TerminalPool` and the App stay unchanged; `init(hotCapacity:)` keeps working.
- **D16 Budgets.** `scripts/m5-perf.sh` measures the ARCHITECTURE budgets on the Debug build and adds
  `session switch cold < 50 ms`. A miss is fixed or the budget is changed in ARCHITECTURE with the
  measured reason (I4). The GPU numbers need DEBUG `-codd-force-render YES` (D17). Hot and cold switches
  need I1's `-CODDMetricsSessions <n>` (switch among the first n sessions only: n ≤ 4 is all hot after the
  first pass; all 15 in order is all cold) and `-codd-real-holders YES` next to `-CODDMetrics` (else mock).
  The perf component's own run only proves the script (other agents compile at the same time); the
  numbers that decide budgets come from I4's run (sequential, nothing else building), and the script
  prints `PERF env load1=<x> cpus=<n>` first so a noisy run is visible.
- **D17 `-codd-force-render YES`** (DEBUG): TerminalHub never occludes terminals and the engines ignore
  the window's occlusion, so a covered background window keeps rendering; in mock mode it also keeps the
  lamp animations running in a covered window (for measurements only).
- **D18 Release.** `VERSION` = `1.0.0` → `MARKETING_VERSION`; `CURRENT_PROJECT_VERSION` = `git rev-list
  --count HEAD`; the first Apple Development identity from `security find-identity -v -p codesigning`,
  else ad-hoc; hardened runtime stays off; helpers re-signed before the app (no `--deep`); output
  `build/release/CODD.app` + `build/release/CODD-<version>-<build>.zip`. `--install` refuses inside a
  Claude Code shell (`CLAUDECODE` set) and while any CODD from `/Applications/CODD.app` runs; the replaced
  app goes to the user's Trash through `/usr/bin/trash` (never `mv` into or a listing of `~/.Trash`: TCC).
  `--dry-run` prints the plan; `--output <dir>` builds into a temp folder. `xcodegen generate` runs only
  when `CODD.xcodeproj/project.pbxproj` is missing or older than `project.yml` (components share the
  generated project and never regenerate it). Every nested code item is signed inside-out (helpers, then
  anything under `Contents/Frameworks` or `Contents/PlugIns` if present, then the app).
- **D19 Compat.** `git worktree add --detach build/m5-compat/wt-<short> <commit>` (never `build/wt-*`),
  only the `codd-holder` product built (release config, own scratch path), removed with `git worktree
  remove --force <that path>` (never `prune`); the current client is a new `codd-holder-compat`
  executable in Packages/CoddHolder. The holder CLI is unchanged since M1 (`HolderOptions.known`), so the
  current `HolderSpawner` spawns every target with `--exit-linger-ms 500` (both know it). The paste check
  runs after `reattach` with a child that turned on `?2004` before `compat-ready` (the old holder lacks
  `input.paste`, so the client brackets from the ATTACHED modes; both must give the same bytes).
- **D20 Stop while STARTING.** `HolderSessionStore.pendingStops`: `stop` of a live session without a
  running holder records the id; `launched(.success(pid))` connects as usual and then applies it through
  the normal stop path (`stopRequested`, SIGTERM; the EXIT frame drives STOPPED / EXITED), log
  `stop applied-after-spawn session=… holderPid=…`; a failed spawn, RESUME, RESTART and removal clear it.
- **D21 Accessibility.** Every interactive element has a label (VoiceOver); custom controls take
  keyboard focus whenever Full Keyboard Access is on (like AppKit buttons; text inputs always) and draw
  the helmet focus style (amber border + 1 px inset + 8 px amber glow) while they are the key window's
  first responder; space / ⏎ press, arrows step segmented controls and steppers; every rail destination
  and every action that is only a click today gets a main-menu item (no new key equivalents). The audit
  fails on unlabeled interactive elements and lists the ones outside the key-view loop.
- **D22 Copy audit.** `scripts/tools/copy-audit.py`: E emoji (anywhere in tracked text; Unicode test data
  is written as `\u{…}` escapes, same scalars at run time; `✻` `❯` `★` `☐` are text-presentation symbols and
  never flagged), F `FANCY` /
  `fancycodd` (allow-listed places only), M e-mail addresses in UI strings, S simplified-only characters
  in UI strings, G glossary variants (§2.7), L English sentences in UI strings (reported for review, not
  failing). Allow list `scripts/tools/copy-audit-allow.txt` (`<rule> <path>:<text> # reason`).
- **D23 zorder.** The watcher counts only windows owned by processes whose executable is under
  `--exe-prefix <dir>` (the app under test); the user's own CODD is another app like any other. Every
  script that launches CODD runs it and fails when violations > 0. Other agents' test builds and demos
  (`<repo>/build/`, `<repo>/.build`) are ignored, the user's `<repo>/build/user-*` builds never are; paths
  are compared after `realpath` and Unicode NFC normalization (the repo path contains 桌面版).
- **D24 Lean testing.** Each agent runs only its own package suites (plus TEST-MAP rule 2 dependents)
  and the TEST-MAP rows of what it changed; I4 runs the new M5 scripts once (m5-e2e included: the
  wrap-up run is its second run); every script and suite runs in full once in the wrap-up test run.
  Duplicates removed (critique): ui-core-a11y runs CoddUI plus only the dependents no later agent runs
  (CoddTextKit, CoddCodeEditor), because ui-packages-a11y runs the other UI suites right after it on the
  final CoddUI; I1 only builds the packages whose string constants it renamed (CoddUI, CoddHolder,
  CoddHooks); no Release build before I4's `release.sh --output` (I4 fixes any Release-only error); I2
  writes every onboarding step's snapshot in one launch (`-codd-show onboarding:all`). CLAUDE.md is not
  edited (proposed lines go in the report).
- **D25 Test runs never write CODD's defaults.** On any non-standard data root and in mock mode the main
  window frame, the split view frames and the status item position are neither restored nor saved (no
  frame autosave name, split `autosaveName` nil, status item `autosaveName` nil), so e2e, perf and agent
  runs never change the installed CODD's window, split or menu bar position (critique 2026-10-18).

## 2. Contracts and formats

### 2.1 Identity

`App/Support/CoddIdentity.swift` (I1): `enum CoddIdentity { static let bundleIdentifier = "app.codd.CODD";
static let legacyBundleIdentifier = "app.fancycodd.CODD"; static let allBundleIdentifiers: Set<String>;
static let showMainWindowNames: [Notification.Name] }`. Every other place uses these constants.
`project.yml`: `bundleIdPrefix: app.codd`; base settings `MARKETING_VERSION: "1.0.0"`,
`CURRENT_PROJECT_VERSION: "1"`; info properties `CFBundleShortVersionString: "$(MARKETING_VERSION)"`,
`CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"`; the CoddDataStore (I1) and CoddOnboarding (I2) packages.

### 2.2 Data files, preflight, banners

Inventory (`DataInventory.all`, CoddDataStore). `key` = the version member; `absent` = the version a
file without it has; policy for corrupt files: `aside` (move to `<name>.corrupt-<ms>`), `remove`,
`report` (never touched).

| File (relative to the data root) | key | current | absent | kind | corrupt |
|---|---|---|---|---|---|
| `layout.json` | `version` | 1 | corrupt | USER | aside |
| `panes.json` | `version` | 1 | corrupt | USER | aside |
| `preferences.json` | `version` | 1 | 1 (its store repairs it) | USER | aside |
| `profiles.json` | `version` | 1 | corrupt | USER | aside |
| `cleanup.json` | `v` | 1 | 1 | USER | aside |
| `claude-settings-backups.json` | `v` | 1 | corrupt | USER | aside |
| `files/recent.json`, `files/ai-touches.json` | `v` | 1 | corrupt | USER | aside |
| `onboarding.json` (new) | `v` | 1 | corrupt | USER | aside |
| `sessions/*/composer.json` | `v` | 1 | 1 | USER | aside |
| `notes/.codd/notebook.json`, `notes/.codd/state.json`, `notes/.codd/tombstones.json` | `v` | 1 | 1 | USER | aside |
| `config.json` | `v` | 1 | 1 | USER | report (HookConfigStore repairs it, keeps the port) |
| `quota.json` | `v` | 1 | corrupt | DERIVED | remove |
| `hooks/*.json`, `sessions/*/answer.json` | — | — | — | DERIVED | remove when not a JSON object |
| `cache/` | `cache/VERSION` text | 1 | 1 (written, no wipe) | DERIVED | wipe contents |

The `absent` column covers a missing, non-integer or < 1 version alike (that is what each store does:
preferences.json, cleanup.json and the notes `.codd/` files read such a file as their current version,
layout.json, profiles.json and files/*.json reject it). Each row is checked against its store's load code
by the datastore agent (it lists the store line it mirrored) and by I1's real-store test.

Not inventoried (documented in ARCHITECTURE): holder-owned `sessions/*/meta.json` and
`sessions/*/tabs/*/meta.json` (v1, frozen with the wire protocol), runtime files (`codd.lock`, `bin/`,
`run/`, `sessions/*/mcp.json`, `spawn.env`, `notes/.codd/tmp/`, `run/condense-*`),
`notes/.codd/activity.jsonl` (lines; a bad line is skipped by its reader), history snapshots and notes
themselves (Markdown), `sessions/*/attachments/`, `sessions/*/codd-ephemeral`, `files/unsaved/`, `trash/`.

Rules: the root is resolved with `realpath` first (a symlinked data root is fine); entries inside are
opened with `O_NOFOLLOW`; a symlink, a non-regular file or a file over 16 MiB is reported as `skipped`
and left alone (a symlinked `cache/` is skipped, never wiped through); an I/O error (not a parse error) is
never "corrupt". A parse failure = not UTF-8 JSON or not an object. Version: an integer member
(`exactIntegerValue`); missing, non-integer or < 1 = `absentVersion` when the row has one, else corrupt.
`newer` = version > current. Never stricter than the store (D14). Migration chain: `MigrationRegistry` steps
`from → from+1`; a missing step = report `noMigration` and leave the file (stores decide). Backup
before the first step, then each step's output is checked to carry `to` and written atomically (temp +
`F_FULLFSYNC` + rename, mode kept, 0600 when created). A failed step leaves the original and the backup
in place and reports `migrationFailed`. Off the main actor; budget < 30 ms for a root with 200 sessions.

Swift contract (CoddDataStore, Foundation only, `Sendable` values):

```swift
public enum DataFileKind: String, Sendable, Codable { case userData, derived }
public enum CorruptPolicy: String, Sendable, Codable { case moveAside, remove, report, wipe }
public struct DataFileSpec: Sendable, Hashable {
    public let pattern: String            // "layout.json", "sessions/*/composer.json" (one `*` = one path component)
    public let versionKey: String?        // "version" | "v" | nil (versionless derived files)
    public let currentVersion: Int
    public let absentVersion: Int?        // nil: a missing key is corrupt
    public let kind: DataFileKind
    public let corrupt: CorruptPolicy
}
public enum DataInventory { public static let all: [DataFileSpec]; public static let cacheVersion = 1 }
public struct MigrationStep: Sendable { public let pattern: String; public let from: Int
    public let migrate: @Sendable ([String: Any]) throws -> [String: Any] }   // must set the version key to from+1
public struct MigrationRegistry: Sendable { public init(_ steps: [MigrationStep] = [])
    public static let standard: MigrationRegistry   // empty at M5
    public func chain(pattern: String, from: Int, to: Int) -> [MigrationStep]? }
public enum DataFileStatus: Sendable, Equatable { case missing, current(Int), migrated(from: Int, to: Int, backup: String),
    newer(Int), corrupt(movedTo: String?), removed, skipped(String), noMigration(Int), migrationFailed(String) }
public struct DataIssue: Sendable, Equatable, Codable { public enum Kind: String, Codable, Sendable { case newer, corrupt, migrationFailed, noMigration }
    public let file: String; public let kind: Kind; public let version: Int?; public let aside: String?; public let message: String }
public struct DataFileResult: Sendable, Equatable { public let path: String; public let status: DataFileStatus }  // path relative to the root
public struct DataPreflightReport: Sendable { public let files: [DataFileResult]
    public let issues: [DataIssue]; public let cacheWiped: Bool; public let milliseconds: Double }
public struct DataPreflight: Sendable {
    public init(root: URL, inventory: [DataFileSpec] = DataInventory.all, registry: MigrationRegistry = .standard,
                now: @escaping @Sendable () -> Date = Date.init, log: @escaping @Sendable (String) -> Void = { _ in })
    public func run() -> DataPreflightReport                 // blocking
    public func scan() -> DataPreflightReport                // read-only dry run (the dump, tests)
    /// `<name>.corrupt-<ms>` files next to inventoried files with ms ≥ `date` (stores' own moves this launch).
    public func asideFiles(createdSince date: Date) -> [String]
}
public enum VersionGuard {   // for writers that must never replace a newer file
    public static func existingVersion(of url: URL, key: String) -> Int?
    public static func mayReplace(_ url: URL, key: String, current: Int) -> Bool
}
public enum DefaultsDomainMigration {
    public struct Result: Sendable, Equatable { public var copied: [String]; public var alreadyDone: Bool; public var sourceMissing: Bool }
    public static let keyPrefixes: [String]               // D2
    public static let excludedKeyPrefixes: [String]       // D2: the DEBUG tool keys
    public static let marker = "CODDDefaultsMigratedFrom"
    /// Before the marker: copied keys replace the target's (D2); `oldDomain` is read with `persistentDomain(forName:)`.
    public static func migrate(from oldDomain: String, into newDomain: String, defaults: UserDefaults = .standard) -> Result
}
```

Banner copy (`DataIssue.message`, the problem banner `▲ …` with `[知道了]`, plus `[在 Finder 中顯示]` for
`corrupt`, which reveals the aside file on a user click, never in a background run):
- newer: `<file> 是較新版本的 CODD 寫的（v<n>）：能讀的部分照用，這次的變更不會存進這個檔案`
- corrupt: `<file> 無法讀取，已移到 <aside>，改用預設值`
- migrationFailed: `<file> 無法轉換成這個版本的格式（<reason>）：原檔與備份都保留，這次改用預設值`
- noMigration: `<file> 是舊格式（v<n>），這個版本不認得：原檔保持不動`
Logs: `data preflight files=<n> current=<n> migrated=<n> newer=<n> corrupt=<n> removed=<n> ms=<x>`, one
`data <status> file=<relative> …` line per non-current file (names only, never contents).

Store gaps closed (datastore for packages, I1 for the app and CoddCore): `PaneLayoutStore` (App) reads a
newer `panes.json` leniently and never saves over it (`VersionGuard`); `LayoutStore` (CoddCore, I1 seam)
loads a newer `layout.json` read-only through the v1 decoder when it decodes (the sidebar shows it;
saving still throws); `ComposerStateFile` (CoddComposer) writes `"v":1`, reads a newer file's
draft and history when they decode and refuses to save it (`ComposerStateFileError.newerVersion`);
`BackupsIndex` (CoddClaudeSettings) reads a newer index's entries and never writes it (the backup file
itself is still made by the installer); `HookConfigStore` (CoddHooks) loads a newer `config.json` as it
is (port, token, mcpToken), never repairs or rewrites it, and `rotateMCPToken` / `reassignPort` /
`setPort` throw `HookConfigError.newerVersion(n)`.

### 2.3 `onboarding.json` and the gate

`<dataRoot>/onboarding.json`, 0600, atomic, sorted keys:
`{"v":1,"completedAt":"<ISO 8601>","appVersion":"1.0.0","build":"<n>","steps":{"detect":"done",
"import":"done|skipped","hooks":"…","notebook":"…","accounts":"…","done":"…"},"imported":{"projects":9,
"groups":3},"notifications":"granted|denied|notAsked|suppressed"}`. A newer `v` is never replaced.
`OnboardingGate.isNewDataRoot(_ root: URL) -> Bool` = none of `layout.json`, `panes.json`,
`onboarding.json`, `sessions/*/meta.json` exists.

### 2.4 Onboarding UI (artboard `Onboarding.src.html`, plus the copy for the steps it does not draw)

Layout (all lengths through CoddUI `UIZoom.pt` / `dz`, so ⌘+ / ⌘− work):
- Stepper column 260 px, full height, `--bg`, right border 1 px `--line`; 52 px drag area; brand block
  (padding 4 22 18, dashed bottom border): `Icon.brand` 20 px amber with a soft glow, `CODD` display 17 px
  amber (§10: no FANCY), comment `// first boot · 首次啟動設定`. Steps (padding 14 12 0): row padding 10 10
  15, gap 12; number box 26 × 26 (1 px `--line-bright`, 11 px 600, tabular); text = title 13 px 500
  `--bone`, English 10 px caps .16em `--dim`, detail 11 px `--dimmer`; a dashed connector from each box to
  the next (left 23, top 36). States: done (✓ in `--success`, border rgba(124,255,154,.4), connector
  rgba(82,196,114,.6), detail `--dim`, hover title `--cream`, clickable), skipped (number kept, detail
  `已略過 · 之後可在 SETTINGS 調整`, clickable), current (row gradient `--amber-glow` → transparent 85 %,
  2 px amber inset bar, number box filled amber with black text and glow, title amber with glow and the
  blinking `_`, English `--amber-dim`, detail `--bone`, `aria-current=step`), todo (title `--dim`, not
  clickable). Foot (margin-top auto, dashed top border, padding 14 20 16, gap 9, 11 px `--dim`): hint
  「第 3 步按下套用前，不會改動 `~/.claude/settings.json`。每一步都能之後在 SETTINGS 調整。」, the D12 link
  (bone, dashed underline, amber on hover), the D11 version line (faint).
- Steps (title · English · detail line): 1 偵測環境 · DETECT · `4 項正常 · 1 項待處理`; 2 匯入專案 ·
  IMPORT PROJECTS · `已選 9 / 187`; 3 安裝 hooks · HOOKS & STATUSLINE · `◆ 需要更新 · 舊版 4 個事件` (D11;
  the artboard's sample says `缺 4 個事件`) / `● 已是最新`; 4 筆記本與 MCP · NOTEBOOK & MCP · `~/…/CODD/notes · :47821`; 5 帳號 (cswap) · ACCOUNTS ·
  `偵測到 3 個帳號` / `找不到 cswap`; 6 完成 · DONE · `開第一個 session`.
- Body (padding 28 40 14, gap 20): the boot block on every step (border 1 px `--line-bright`, `#000`):
  header 28 px (`--bg-soft`, bottom border, 10.5 px `--dimmer`): `BOOT · 偵測環境`, `4 OK · 1 待處理`
  (ok part green, pending amber), spacer, `10:41:58 · 0.8s`, `[↻ 重新偵測]` (sm); lines 12 px / 1.5 in a 4
  column grid 64 · 158 · 236 · rest (tag, name, value, dim detail; ellipsis). The last line follows the
  step: `[ .. ] projects waiting for operator_` (step 2, blinking cursor), `[ .. ] hooks waiting for
  operator_` (3), …, `[ OK ] ready` (6). Then the head: kicker 10.5 px caps .18em `--amber-dim` (`STEP 02 /
  06 · IMPORT PROJECTS`), `.h-page` 26 px display, lead 13 px `--bone` (max 820, bold numbers `--cream`).
- Footer bar 60 px (dashed top border `--line-bright`, `--bg-soft`, padding 0 40, gap 10): `[← 上一步]`
  (disabled on step 1), `[略過]`, spacer, the step summary, the primary `[下一步：<next title> →]` (step 6:
  `[開始使用 →]`) and the `⏎` kbd.

Step 2 (exactly the artboard): lead 「從 `~/.claude.json` 找到 **187** 個專案（依最近使用排序）。只勾選你要的，
CODD 不會一次全部匯入。」; toolbar: filter 340 × 30 (`/` prefix, placeholder `篩選名稱或路徑…`), `[依父資料夾建議
分組]` (accent), chip `已選 9` (amber), spacer, hint `依最近使用排序 · 群組可之後在側欄拖曳調整`; table (border
`--line-bright`, `--bg-soft`): header 30 px `--bg-lift`, caps 10 px .16em `--dim` (`PROJECT`, `PATH`, `LAST
USED ↓` in `--amber-dim`, `TRANSCRIPTS` right aligned, `GROUP`), header checkbox = 全選目前顯示的專案; rows 30 px
with dashed `--line` separators, hover `--bg-lift`; widths 42 · 262 · flex · 118 · 112 · 214; unchecked rows
dim with a disabled group select; 最近使用 `今天 10:34` / `昨天 22:47` / `10/13` / `10/09` / `9/21` (local time,
`M/dd`); group select 24 px (tag square, name, caret; open = amber border + inset + glow); its menu opens
above it (248 px; an overlay view inside the window, not a child window or NSMenu, so snapshots and
background runs need nothing special):
header `移到群組 · GROUP`, each group with its square (dashed square for 未分類), `建議` chip on the
suggestion, `✓` on the current one, separator, `+ 新群組… 命名後套用`. Table foot (36 px): `// ~/.claude-worktrees/*
與 SDK 產生的專案預設隱藏` + `[顯示隱藏項目]` (sm plain; toggles to `[隱藏]`), spacer, `顯示 12 / 187`, `[載入更多
↓]`. Footer summary `**9** 個專案 → **3** 個群組 · 之後可用 ⌘N 或側欄加入更多`. Empty: no `.claude.json` →
`// 找不到 ~/.claude.json：還沒用過 Claude Code？之後可以用 ⌘N 或側欄的 + 加入專案`; everything already in CODD →
`// 這些專案都已在側欄`.

Steps 1, 3–6 (not drawn; same voice; new copy listed in the report for review):
- 1 偵測環境 — lead 「CODD 先看看這台 Mac：Claude Code、cswap、hooks 與資料夾。這一步只讀，不會改動任何檔案。」
  Under it one line per item that needs attention, each with its button: claude missing `▲ 找不到 claude：
  先安裝 Claude Code，裝好後按 ↻ 重新偵測。`; cswap missing `○ 沒有 cswap：CODD 仍可使用目前登入的帳號；要切換多個帳號
  再安裝 cswap（0.26 以上）。` `[第 5 步 →]`; hooks pending `◆ ~/.claude/settings.json 有舊版 CODD web 的 hooks：
  第 3 步可以預覽並移除。` `[第 3 步 →]`; data root not writable `▲ 資料夾無法寫入：<path>`; all fine `// 一切正常，按
  下一步 繼續`. Summary `4 項正常 · 1 項待處理`.
- 3 安裝 hooks — lead 「CODD 開的 session 會自動帶上 hooks 與狀態列，不必改全域設定。這一步只整理
  `~/.claude/settings.json`：移除舊版 CODD web 的 hooks，或安裝全域狀態列，讓 CODD 以外的 claude 也回報用量。」 A card
  `~/.CLAUDE · SETTINGS.JSON` with rows `SESSION HOOKS ● 14 / 14 · 每個 CODD session 自動注入`, `LEGACY ◆ 舊版 CODD
  web · <events>` / `● 沒有舊版設定`, `STATUSLINE ○ 未安裝全域版 · 選用` / `● 已安裝` / `◆ 需要更新`, `FOREIGN <code>
  <name> ×n · 保持不動` (one per tool; the name is left out when it equals the code: `FOREIGN hook-tap ×11 · 保持不動`,
  `FOREIGN osascript 通知 ×2 · 保持不動`); `[預覽變更]` (primary while something is pending) opens dialog B with
  the `update` plan; hint 「按下 套用並備份 前不會寫入；寫入前會先備份成 `settings.json.codd-bak-<時間>`。」 After
  an apply `● 已套用 · 備份 <name>`. Summary `◆ 1 項待處理` / `● 已是最新`.
- 4 筆記本與 MCP — lead 「筆記是一般的 Markdown 檔，存在 CODD 的資料夾裡；CODD 開的 claude session 會自動掛上 CODD 的
  MCP，可以搜尋與讀取筆記。」 Rows: `NOTEBOOK ~/Library/Application Support/CODD/notes [在 Finder 中顯示]` + hint
  「位置固定在 CODD 的資料夾，不另外搬動；更新 CODD 時保留。」; `MCP 127.0.0.1:47821 · ● 運作中` (`○ 未啟動 · hooks
  連接埠被占用` when down); `CLAUDE CODE ○ 未註冊 [註冊…]` (`● 已註冊`) + hint 「選用：註冊後，CODD 以外開的 claude
  也能讀筆記。會先顯示 `~/.claude.json` 的差異，按 套用並備份 才寫入。」; `CODEX [複製設定…]` (the M4 snippet sheet).
- 5 帳號 — lead 「CODD 透過 cswap 管理多個 Claude 帳號：只讀 cswap 的狀態檔，只顯示別名，不顯示 email。」 Header
  `ACCOUNTS · 依每週重置排序 · 越快重置越上面`; rows in R7 order (slot + alias, plan chip, 5h / 1w remaining
  bars, `1w 重置 1d12h後`, `✓ ACTIVE` with the amber bar); `[+ 新增帳號]` (D13). Missing: `// 找不到 cswap` +
  「沒有 cswap 也能使用 CODD：session 用目前登入的帳號。要管理多個帳號，安裝 cswap（0.26 以上）後按 ↻ 重新偵測。」; too
  old: `// cswap <v> 太舊，需要 0.26 以上`; unreadable: `// 讀不到 cswap 狀態：<reason>`. Summary `3 個帳號`.
- 6 完成 — lead 「設定好了。每一步都能之後在 SETTINGS 調整，或從 說明 › 首次啟動設定 重來一次。」 A boot-style
  summary (`[ OK ] 匯入 9 個專案 → 3 個群組`, `[ -- ] hooks 略過`, `[ OK ] 筆記本 ~/…/CODD/notes`, `[ OK ] 3 個帳號`), a
  `NOTIFICATIONS` block 「允許通知：session 需要你回覆或出錯，而你不在 CODD 畫面前時，CODD 會發通知提醒你。」 `[允許通知]` →
  `● 已允許` / `○ 未允許 · 可在 系統設定 › 通知 開啟`; hint `按 ⌘N 開第一個 session`; `略過` = finish without
  asking. 開始使用 / 略過 / closing the window: write `onboarding.json`, close, show the main window.
- Reopen points: Settings › 13 關於 row `首次啟動設定` with hint 「重新看一次環境偵測、匯入專案、hooks、筆記本、帳號與通知；
  不會自動改動任何檔案。」 and button `[重新執行]` (CoddSettingsUI `SettingsActions.openOnboarding`); main menu
  `說明 › 首次啟動設定…` (`NSApp.helpMenu`). Reopened, it starts at step 1 with live data; projects already in
  CODD are left out of step 2; finishing rewrites `onboarding.json`.

Keyboard: ⏎ = the primary button (not while the filter or a name field composes text); ⌘[ = 上一步;
Tab order stepper → body controls → footer; in the table ↑ / ↓ move the row focus, space toggles, ⌥↓
opens the row's group menu; the stepper's done / skipped rows are buttons. VoiceOver: the stepper is a
list (`首次啟動設定步驟`), each step a button / static text with `<n>. <title>，<state>` ; table rows are
checkboxes labeled `<name>，<path>，<最近使用>，<n> 個對話` ; group selects `<name> 的群組：<group>`
(`（未勾選）` when disabled), the boot block a group `環境偵測結果` whose lines read `<tag> <name> <value>`.

Motion and look: the blinking `_` (current step title, the boot block's waiting line) uses CoddUI's
`UITicker` and stops while the window is hidden, miniaturized or occluded (idle CPU budget); the
artboard's CRT look is the App's `ScanlineOverlay` following the appearance preference, applied by I2 to
the onboarding window as to the main window (the package draws no scanlines).

### 2.4b Onboarding package API (C1; the App fills the models, the views never read the disk)

Package `Packages/CoddOnboarding`: library `CoddOnboarding` (Foundation only: models, catalog, gate,
state store) and library `CoddOnboardingUI` (AppKit + CoddUI: the views), executable
`codd-onboarding-demo --fonts <dir> --snapshot <dir>` (PNG per step and state), tests for both.

```swift
public enum OnboardingStep: Int, CaseIterable, Sendable, Codable { case detect = 1, importProjects, hooks, notebook, accounts, done
    public var id: String          // detect, import, hooks, notebook, accounts, done (onboarding.json keys)
    public var title: String       // 偵測環境 …  (§2.4)
    public var english: String     // DETECT, IMPORT PROJECTS, HOOKS & STATUSLINE, NOTEBOOK & MCP, ACCOUNTS, DONE
    public var kicker: String }    // "STEP 02 / 06 · IMPORT PROJECTS"
public enum StepProgress: String, Sendable, Codable { case todo, current, done, skipped }
public struct OnboardingFlow: Sendable, Equatable {
    public private(set) var current: OnboardingStep; public private(set) var progress: [OnboardingStep: StepProgress]
    public init(start: OnboardingStep = .detect)
    public mutating func next()                        // current → done, the following step → current
    public mutating func skip()                        // current → skipped (a done step stays done), following → current
    public mutating func back()                        // the previous step → current (states kept)
    @discardableResult public mutating func go(to: OnboardingStep) -> Bool   // only done / skipped / current
    public var isAtLastStep: Bool }
public struct BootLine: Sendable, Equatable { public enum Tag: String, Sendable { case ok, pending, fail, skipped, waiting }
    public let tag: Tag; public let name: String; public let value: String; public let detail: String; public let cursor: Bool }
public struct EnvironmentFacts: Sendable, Equatable {
    public enum Claude: Sendable, Equatable { case found(version: String, path: String), missing, failed(String) }
    public enum Cswap: Sendable, Equatable { case ready(version: String, path: String, accounts: Int), missing,
        unsupported(String), unreadable(String), loading }
    public enum Hooks: Sendable, Equatable { case upToDate(file: String), legacy(events: [String], file: String),
        statuslineOutdated(file: String), unreadable(String), unknown }
    public struct DataRoot: Sendable, Equatable { public let path: String; public let writable: Bool
        public let mcpEndpoint: String?; public let mcpRunning: Bool }
    public var claude: Claude; public var cswap: Cswap; public var hooks: Hooks; public var dataRoot: DataRoot
    public var checkedAt: Date; public var milliseconds: Int }
public struct EnvironmentReport: Sendable, Equatable { public let lines: [BootLine]; public let ok: Int; public let pending: Int
    public let failed: Int; public let header: String   // "4 OK · 1 待處理"; the time and duration from the facts
    public static func make(_ facts: EnvironmentFacts, step: OnboardingStep, imported: Int?, timeZone: TimeZone) -> EnvironmentReport }
public struct DetectItem: Sendable, Equatable { public let glyph: String; public let tone: String; public let text: String
    public let button: String?; public let target: OnboardingStep? }
public struct HooksStepModel: Sendable, Equatable { public struct Row: Sendable, Equatable { public let label: String
    public let state: String; public let tone: String; public let detail: String }
    public var rows: [Row]; public var pending: Int; public var canPreview: Bool; public var appliedBackup: String? }
public struct NotebookStepModel: Sendable, Equatable { public var notesPath: String; public var mcpLine: String; public var mcpRunning: Bool
    public var claudeCodeState: String; public var claudeCodeButton: String?; public var codexAvailable: Bool }
public struct AccountsStepModel: Sendable, Equatable { public struct Row: Sendable, Equatable { public let slot: String
    public let alias: String; public let plan: String?; public let fiveHourRemaining: Double?; public let weeklyRemaining: Double?
    public let weeklyReset: String; public let active: Bool }
    public var availabilityNote: String?; public var rows: [Row]; public var canAdd: Bool }
public struct DoneStepModel: Sendable, Equatable { public var summary: [BootLine]
    public enum Notifications: String, Sendable { case notAsked, asking, granted, denied, suppressed }; public var notifications: Notifications }
public struct ImportStepModel: Sendable, Equatable { public var catalog: ProjectCatalog; public var selection: ImportSelection
    public var options: [GroupOption]; public var suggestion: [String: String]; public var summary: String }   // "9 個專案 → 3 個群組"
public struct OnboardingViewModel: Sendable, Equatable { public var flow: OnboardingFlow; public var boot: EnvironmentReport
    public var versionLine: String; public var showsWebImportLink: Bool; public var stepDetails: [OnboardingStep: String]
    public var detect: [DetectItem]; public var importStep: ImportStepModel; public var hooks: HooksStepModel
    public var notebook: NotebookStepModel; public var accounts: AccountsStepModel; public var done: DoneStepModel }
public enum OnboardingSamples { public static func artboard() -> OnboardingViewModel }   // the artboard's data (demo, mock mode)
public enum OnboardingGate { public static func isNewDataRoot(_ root: URL) -> Bool }
public struct OnboardingState: Sendable, Equatable, Codable { … §2.3 }
public struct OnboardingStateStore: Sendable { public init(url: URL)
    public func load() -> OnboardingState?; public func save(_ state: OnboardingState) throws }   // newer v refused

// CoddOnboardingUI
@MainActor public struct OnboardingActions {   // every closure defaults to doing nothing; all @MainActor
    public var next, skip, back, redetect, importWeb, suggestGroups, previewHooks, revealNotes,
               registerClaudeCode, copyCodexSnippet, addAccount, requestNotifications, finish: @MainActor () -> Void
    public var goTo: @MainActor (OnboardingStep) -> Void
    public var importChanged: @MainActor (ImportSelection) -> Void       // every check, filter, group, page or hidden change
    public var newGroup: @MainActor (_ path: String, _ name: String) -> Void
    public init(…) }
@MainActor public final class OnboardingView: NSView {
    public init(model: OnboardingViewModel, actions: OnboardingActions)
    public func update(_ model: OnboardingViewModel)          // applies only what changed (no flicker, keeps focus)
    public static let defaultContentSize: NSSize               // 1240 × 820
    public static let minimumContentSize: NSSize                // 1011 × 640
    public var initialFirstResponder: NSView? }
```
`GroupOption.key`: `existing:<group id>`, `new:<n>` (in creation order), `ungrouped`.

### 2.5 Import catalog (CoddOnboarding, Foundation only, read only)

Transcript folder = `<claudeDir>/projects/<sanitized>`; sanitized = every UTF-16 unit outside
`[A-Za-z0-9]` becomes `-` (JavaScript `replace(/[^a-zA-Z0-9]/g,'-')`); when the result is longer than
200 characters, Claude cuts it to 200 and appends `-<hash>`: then every folder whose name starts with
the 200-character prefix + `-` counts (stat only). Counting reads directory entries and `stat`s; the SDK
check reads at most 3 files × 8 KiB. Budget: 200 projects < 150 ms on this Mac (debug).

```swift
public struct ImportCandidate: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String; public let name: String; public let prefix: String?   // D10
    public let displayPath: String   // the full path with `~` for home; the VIEW elides it to the column (D10)
    public let lastUsed: Date?; public let transcripts: Int
    public enum Hidden: String, Sendable { case worktree, sdk }; public let hidden: Hidden?
}
public struct ProjectCatalog: Sendable, Equatable { public let source: String?   // "~/.claude.json"
    public let candidates: [ImportCandidate]; public let alreadyInCODD: Int; public let problem: String? }
public enum ProjectCatalogReader {
    public static func read(claudeDirectory: URL, home: String, existingProjectPaths: Set<String>) -> ProjectCatalog   // blocking
}
public struct ExistingGroup: Sendable, Equatable { public let id: String; public let name: String
    public let color: String?; public let projectPaths: [String] }
public struct GroupOption: Sendable, Hashable { public enum Kind: Sendable, Hashable { case existing(String), new, ungrouped }
    public let key: String; public let name: String; public let color: String?; public let kind: Kind }
public enum GroupSuggester {
    public static func suggest(for candidates: [ImportCandidate], checked: Set<String>, existing: [ExistingGroup])
        -> (options: [GroupOption], suggestion: [String: String])   // path → option key (D9)
}
public struct ImportSelection: Sendable, Equatable {   // the step's state, pure mutations
    public var checked: Set<String>; public var group: [String: String]; public var filter: String
    public var showHidden: Bool; public var limit: Int; public var newGroups: [GroupOption]
    public static func initial(_ catalog: ProjectCatalog, existing: [ExistingGroup], now: Date) -> ImportSelection   // D8 pre-check + D9
    public func visible(in catalog: ProjectCatalog) -> [ImportCandidate]     // filter (case / width / diacritic insensitive over name + path), hidden, limit
}
public struct ImportPlan: Sendable, Equatable {
    public struct NewGroup: Sendable, Equatable { public let key: String; public let name: String; public let color: String? }
    public struct Addition: Sendable, Equatable { public let path: String; public let groupKey: String? }  // (a tuple array would not be Equatable)
    public let newGroups: [NewGroup]                          // in first-use order
    public let additions: [Addition]                          // table order; nil = 未分類; `existing:<id>` for an existing group
    public static func make(_ selection: ImportSelection, catalog: ProjectCatalog, options: [GroupOption]) -> ImportPlan
}
```

### 2.6 Accessibility audit (CoddUI)

```swift
@MainActor public enum AccessibilityAudit {
    public struct Finding: Sendable, Equatable, Codable { public let path: String; public let role: String
        public let label: String?; public let frame: CGRect; public let problem: String }   // "unlabeled" | "notInKeyLoop"
    public struct Report: Sendable, Equatable, Codable { public let screen: String; public let interactive: Int
        public let unlabeled: [Finding]; public let outsideKeyLoop: [Finding] }
    public static let interactiveRoles: Set<String>   // AXButton, AXCheckBox, AXRadioButton, AXPopUpButton, AXMenuButton,
                                                      // AXTextField, AXTextArea, AXComboBox, AXSlider, AXIncrementor, AXLink,
                                                      // AXDisclosureTriangle, AXRow (selectable rows), AXCell when pressable
    public static func audit(window: NSWindow, screen: String, checkKeyLoop: Bool = true) -> Report
    public static func audit(view: NSView, screen: String) -> Report
}
public enum KeyboardFocus { @MainActor public static var fullKeyboardAccessOverride: Bool?   // tests, DEBUG
    @MainActor public static var isFullKeyboardAccessOn: Bool }                          // override ?? NSApp.isFullKeyboardAccessEnabled
```
Walk: `accessibilityChildren()` recursively from the window's content view (sheets and child windows are
audited as their own screens); hidden, zero-sized and alpha-0 views are skipped; an element counts as
labeled when `accessibilityLabel` or `accessibilityTitle` (or a text field's placeholder) is non-empty after
trimming. The key loop: `nextValidKeyView` from `initialFirstResponder` (with the override ON) until it
returns to the start (≤ 2,000 steps). The App's `-codd-a11y-audit <file>` (I3) writes
`{"screens":[Report…],"unlabeled":<n>,"outsideKeyLoop":<n>}` and exits 3 when `unlabeled > 0`.

### 2.7 Copy audit (`scripts/tools/copy-audit.py`)

Scope: `App/**/*.swift` and `Packages/*/Sources/**/*.swift` (UI rules: string literals), every tracked
`*.md`, `*.swift`, `*.sh`, `*.py`, `*.yml` (rule E). UI literals exclude: arguments of `log(`, `printLog(`,
`print(`, `Logger`/`os_log`, `fatalError(`, `precondition(`, `assert(`, `#expect(`, `#require(`,
`DispatchQueue(label:`, `Notification.Name(`, `NSPasteboard.*(`, `forKey:`, `UserDefaults`, regex and
format-only literals, identifiers / paths / commands (no space and no CJK), `Tests/`, `App/Debug/`,
`Sources/codd-*` demo targets. Rules: E emoji = scalars in U+1F000–1FAFF, U+FE0F, and the Emoji_Presentation
code points below U+2B56 (list in the tool; SPEC's glyph allow-list ◆ ▲ ◇ ● ◌ ○ $ ✕ ⟲ ✓ ✎ ↻ → ← ↑ ↓ ⏎ ⌘ ⌥ ⇧ ⌃ ⎋
▸ ▾ · … ■ □ ↗ ✳ ◐ ◑ ① – ⑳ is never flagged); F `FANCY` (case-sensitive word) or `fancycodd`; M
`[\w.+-]+@[\w-]+\.[\w.]+` (fixtures' made-up addresses only in tests); S simplified-only characters
(a list of ≥ 150 common ones in the tool, each checked to have a different traditional form, e.g. 设 账 号
会 话 确 删 显 开 关 启 动 时 间 项 档 览 录 认 证 统 网 络 页 码 输 选 择 线 实 现 务 资 讯 应 发 复 贴 帮 这 们 么 为
个 来 对 说 让 还 进 过 从 无 与 万 条 变 处 头 将 车 东 门 问 题; characters that are also valid traditional
ones, such as 后 并 几 制 面 里 只 台, are never on it); G glossary (`帳户/账户/賬號 →
帳號`, `設置 → 設定`, `文件夾 → 資料夾`, `登錄 → 登入`, `屏幕 → 螢幕`, `默認 → 預設`, `信息 → 訊息`, `程序 → 程式`,
`鏈接 → 連結`, `菜單 → 選單`, `窗口 → 視窗`, `用戶 → 使用者`, `視頻 → 影片`, `質量 → 品質`); L a literal with no
CJK and ≥ 4 lowercase English words (report only). Output: `<rule> <path>:<line> <text>` per finding,
then `COPY findings=<n> failing=<n> review=<n>`; exit 1 when failing > 0 (E, F, M, S, G not allow-listed).

### 2.8 Performance (`scripts/m5-perf.sh`)

Budgets (ARCHITECTURE, plus D16): launch to interactive sidebar < 400 ms · idle CPU app visible < 0.5 %,
hidden < 0.1 %, holders ≈ 0 (< 0.05 % total for 15) · hot switch < 16 ms (p50 and max), cold switch < 50
ms (max) · memory: holder ≤ 2.5 MB, app base < 80 MB, total with 15 sessions < 300 MB · GPU: footprint growth
while lamps pulse < 5 MB over 30 s; an animating visible terminal's extra footprint (reported against the
total budget). One line per metric: `PERF <name> value=<v><unit> budget=<op><b><unit> PASS|FAIL|SKIP
(<note>)`, then `PERF summary pass=<n> fail=<n> skip=<n>`; exit 1 on any FAIL. `ONLY=launch,idle,switch,
memory,gpu`; `PERF_JSON=<file>`; `KEEP=1`; `CODD_APP` (default `build/dd/…/Debug/CODD.app/Contents/MacOS/CODD`).
First line `PERF env load1=<x> cpus=<n> build=<Debug|Release>` (D16). Every `-CODDMetrics` launch also passes
`-codd-real-holders YES` (else it runs mock mode) and its holders are ended afterwards (it calls `exit(0)`).
Scenarios (fresh temp roots by `make-root.sh`, `-codd-claude-dir <temp>`, `-codd-login-env NO`,
`-codd-notifications NO`, `CODD_BACKGROUND=1`, zorder guard, every process ended): launch = real mode on
a root seeded with 15 stopped sessions (`seed-layout.sh`), the `perf launch-to-sidebar ms=<n> rows=<n>` log
line (I1), 3 runs, median; idle = 15 sessions (`-codd-spawn-shell <dir> -codd-spawn-count 12` + 3 silent
fake claudes: 3 stopped claude sessions from `seed-layout.sh` with `-codd-resume-stopped YES` and
`-codd-claude-path <fake>`), `ps -o cputime` over 10 s from 12 s after launch with
`-CODDForceVisibleTimers YES` (visible) and `-codd-close-main-window YES` (hidden), holders summed; switch =
`-CODDMetrics YES -codd-real-holders YES -CODDMetricsDelay 6 -CODDMetricsPasses 3 -CODDMetricsVerbose YES`
with 15 shells (hot: `-CODDMetricsSessions 4`, I1; cold: all 15 in order, every switch past the hot
tier; SKIP lines until I1's flag exists); memory = `footprint <pid>` (phys_footprint) 20 s after launch, each holder
too; GPU = mock mode (`-codd-mock -CODDForceVisibleTimers YES`, waiting lamps pulse) footprint at 5 s and
35 s, and a shell printing a 10 Hz spinner shown with `-codd-force-render YES` (I1) versus quiet.

### 2.9 Holder compatibility (`scripts/m5-compat.sh`, `codd-holder-compat`)

`scripts/m5-compat.sh [commit…]` (default `37a9388 db62f17`): for each commit, `git worktree add --detach
build/m5-compat/wt-<short> <commit>`, `swift build -c release --package-path build/m5-compat/wt-<short>/
Packages/CoddHolder --scratch-path build/m5-compat/scratch-<short> --product codd-holder`, then the CURRENT
`codd-holder-compat` (built from the working tree: `swift build --package-path Packages/CoddHolder
--scratch-path .build-holder-compat --product codd-holder-compat`) runs against that binary on a fresh
temp root; finally `git worktree remove --force` of each path it created (also on failure, trap). Output
`COMPAT <short> <check> ok|FAIL <detail>` and `COMPAT summary ok=<n> fail=<n>`; exit 1 on a failure.
Checks (current client code only: `HolderSpawner`, `SessionDirectory`, `HolderStream`, `RingFileReader`):
`spawn` (only CLI flags the M1 holder knows: read `git show 37a9388:Packages/CoddHolder/Sources/
CoddHolderCore/HolderOptions.swift`; the set is unchanged today; `--exit-linger-ms 500`), `meta` (meta.json
v1 read by `SessionDirectory`, holder alive), `welcome` (proto 1, caps listed, ringStart / ringEnd),
`stream` (the child prints `ESC[?2004h` then `compat-ready`; the line arrives in order), `input` (submit:
the child echoes `got:<line>`), `resize` (100 × 30 → the child's WINCH trap prints `30 100`), `reattach`
(close, reconnect, ATTACH from the latest resync point replays the marker; ATTACHED's modes show
`?2004` on), `paste` (after reattach: the echoed line carries `ESC[200~`…`ESC[201~` for every target: the
current holder brackets itself, the M1 holder gets the client's bracketing), `ring` (RingFileReader reads
the old ring), `stop` (SIGTERM → EXIT frame, holder gone within 5 s, meta `holderExited`).

### 2.10 Release (`scripts/release.sh`)

`scripts/release.sh [--dry-run] [--output <dir>] [--install]`. Steps: check `xcodegen`, `xcodebuild`,
clean-tree warning (not fatal); `VERSION` → `MARKETING_VERSION`, `git rev-list --count HEAD` →
`CURRENT_PROJECT_VERSION`; `xcodegen generate` only when the project is missing or older than
`project.yml` (`RELEASE step xcodegen skipped (project current)` otherwise; D18); `xcodebuild -project CODD.xcodeproj -scheme CODD
-configuration Release -derivedDataPath <out>/dd MARKETING_VERSION=… CURRENT_PROJECT_VERSION=… build`;
copy the product to `<out>/CODD.app` (`ditto`); if the built Info.plist does not carry the versions, set
them with PlistBuddy (warning) before signing; identity = first `Apple Development` line of `security
find-identity -v -p codesigning`, else `-`; sign `Contents/MacOS/codd-holder|codd-hook|codd-statusline`
(identifiers `app.codd.<name>`), then any nested code under `Contents/Frameworks` / `Contents/PlugIns` (none
today), then the app (`--force --sign <id> --timestamp=none`); verify `codesign
--verify --strict --deep`, the bundle id, both versions, the three helpers; zip with `ditto -c -k
--keepParent` → `<out>/CODD-<version>-<build>.zip`; print `RELEASE app=<path> zip=<path> version=<v>
build=<n> identity=<adhoc|name> bundle=<id>`. `<out>` = `build/release` (never `build/user-*`), or
`--output <dir>`. `--install` (only after a build to `build/release`): refuse with `CLAUDECODE` set, refuse
while `ps -axo pid=,command=` shows a process running `/Applications/CODD.app/Contents/MacOS/CODD`, then
copy to `/Applications/.CODD.app.installing`, move an existing `/Applications/CODD.app` to the Trash with
`/usr/bin/trash` (never `mv` into or a listing of `~/.Trash`; if it fails, stop and leave both apps as they
are), rename the new one into place, print what to do next (quit an old CODD
started from elsewhere first; sessions survive; notification permission is asked again).

### 2.11 zorder tooling

`scripts/tools/zorder-watch.swift <seconds> [owner] [--exe-prefix <dir>] [--ignore-prefix <dir>]…
[--never-ignore-prefix <dir>]…` (positional form unchanged; with `--exe-prefix` only windows whose owner
pid's `proc_pidpath` starts with `<dir>` count as the owner's; windows of other processes under an
`--ignore-prefix` (other agents' background CODD test builds) are neither owner nor "other", unless they
are under a `--never-ignore-prefix` (the user's `build/user-*` builds, which always count as other apps);
the summary line gains `ignored=<n>`). `zorder.sh` passes `--ignore-prefix <repo>/build/ --ignore-prefix
<repo>/.build --never-ignore-prefix <repo>/build/user-` by default (`.build*` = SwiftPM demos such as the
perf component's `codd-term-demo`, ordered back like a test CODD). Precedence: `--exe-prefix` (owner),
then `--never-ignore-prefix` (other), then `--ignore-prefix` (ignored); every path compared after
`realpath` and NFC normalization. `scripts/tools/zorder.sh build` (swiftc -O into `build/tools/zorder-watch` when missing or older
than the source), `zorder.sh start <log> --exe-prefix <dir> [--seconds <n>]` (prints the pid, default 3600 s),
`zorder.sh stop <log>` (SIGINT, ≤ 5 s, prints the summary, exit 1 when violations > 0 or no summary).
`scripts/lib/zorder-guard.sh` (sourced): `zorder_guard_begin <tmpdir> <app binary>` and
`zorder_guard_end` (returns 1 and prints `E2E zorder violations=<n> (log <path>)` on a violation).
`ZORDER=0` skips it (manual debugging only).

### 2.12 Stop while STARTING (D20)

`HolderSessionStore`: `var pendingStops: Set<SessionID>`; `stop(_:)` for a live CODD session whose
runtime has no running holder (no pid, or not a holder process) and whose spawn is in flight inserts the
id and logs `stop deferred session=<id>`; `launched(.success(pid))` records the pid, connects, then
applies it through `stop(_:)` (so the EXIT frame drives the state as for any stop); `.failure`,
`relaunch`, removal and archive clear it. `-codd-stop-after-create YES` calls `stop` synchronously in
the same main-actor turn as the create (the launch Task cannot have a pid yet: no timing race). Regression test with an injected spawn delay
(`HolderLauncher` start seam): stop before the pid exists → the session ends STOPPED (claude) / EXITED
(shell), `stopRequested` contains it, no holder process remains.

## 3. Components (parallel, outside App/; owned paths disjoint)

| Key | Title | Owned paths | dependsOn |
|---|---|---|---|
| `onboarding` | Onboarding package (models, catalog, views, demo) | `Packages/CoddOnboarding/**`, `scripts/m5-fixtures/**` | — |
| `datastore` | Data versioning package + store guards | `Packages/CoddDataStore/**`; `Packages/CoddComposer/Sources/CoddComposer/ComposerState.swift`, `Packages/CoddComposer/Tests/CoddComposerTests/ComposerStateVersionTests.swift`; `Packages/CoddClaudeSettings/Sources/CoddClaudeSettings/BackupsIndex.swift`, `Packages/CoddClaudeSettings/Tests/CoddClaudeSettingsTests/BackupsIndexVersionTests.swift`; `Packages/CoddHooks/Sources/CoddHooks/HookConfig.swift`, `Packages/CoddHooks/Tests/CoddHooksTests/HookConfigVersionTests.swift` | — |
| `ui-core-a11y` | CoddUI focus, keyboard, accessibility audit | `Packages/CoddUI/**` | — |
| `ui-packages-a11y` | Accessibility of the UI packages + Settings onboarding row | `Packages/CoddNotebookUI/**`, `Packages/CoddCleanupUI/**`, `Packages/CoddStatusUI/**`, `Packages/CoddSettingsUI/**`, `Packages/CoddDialogsUI/**`, `Packages/CoddAnnotateUI/**`, `Packages/CoddFiles/Sources/CoddFileEditorUI/**`, `Packages/CoddFiles/Tests/CoddFileEditorUITests/**`, `Packages/CoddFiles/Package.swift` (test-target dependencies only) | `ui-core-a11y` |
| `test-tools` | zorder tooling in every e2e script, copy audit tool | `scripts/tools/**`, `scripts/lib/**`, `scripts/m1-e2e.sh`, `scripts/m1-smoke.sh`, `scripts/m2-e2e.sh`, `scripts/m3-e2e.sh`, `scripts/m4-e2e.sh`, `scripts/m4-sidebar-dnd.sh`, `scripts/m4-ui-zoom.sh`, `scripts/m4-layout-sweep.sh`, `scripts/m2-fixtures/selftest.sh` | — |
| `perf` | Budgets script, hot tier (F5), GPU memory (F2) | `scripts/m5-perf.sh`, `Packages/CoddTerminal/**` | `test-tools` |
| `holder-compat` | Current client vs M1 / M4 holders | `scripts/m5-compat.sh`, `Packages/CoddHolder/Package.swift`, `Packages/CoddHolder/Sources/codd-holder-compat/**` | — |
| `release` | Release packaging | `scripts/release.sh`, `VERSION` | — |
| `docs` | README and the 繁體中文 user guide (drafts) | `README.md`, `docs/USER-GUIDE.zh-TW.md` | — |

Every component: Swift 6, strict concurrency, zero warnings; tests in temp directories; its own
`--scratch-path .build-<key>` (and `build/<key>` for any xcodebuild); additive API changes only to
existing packages (the App must keep compiling: check with one `xcodebuild -project CODD.xcodeproj
-scheme CODD -configuration Debug -derivedDataPath build/<key> build` when it changed a package the App
uses; components never run `xcodegen generate`, the generated project is current and only integration
steps regenerate it); a report listing what was built, the commands run with results, measured
numbers, decisions and known issues.

Components share one working tree and build concurrently: keep every file you edit compiling between
edits (CoddUI, CoddTerminal, CoddComposer, CoddHooks and CoddClaudeSettings are compiled by other agents'
App builds while you work); a build failure inside a package you do not own is another agent's edit in
progress: wait and retry, never edit it.

Integration steps may edit string literals and small seams in any package (the components are finished
by then), and say which package suites they re-ran.

## 4. Integration (sequential, App/ + project.yml; one agent at a time)

- **I1 `core-identity-data`** — identity (D1), versions in project.yml (§2.1), defaults migration (D2,
  replace-before-marker), no defaults writes on test roots and in mock mode (D25), login-item hint (D4),
  data preflight + banners + the `panes.json` guard + newer `layout.json` / `panes.json` read as far as
  possible + the post-load aside sweep + the real-store "never stricter" test (D14), stop while STARTING
  (D20), perf hooks (`-codd-force-render` incl. mock lamps, `-CODDMetricsSessions`, the `perf
  launch-to-sidebar` line, D16 / D17), dump keys `bundle`, `dataFiles`. Updates the ARCHITECTURE
  paragraphs it changes.
- **I2 `onboarding`** — the window, the gate (D5), the probes, import apply, steps 3–6 wiring (dialog B,
  registration dialog, Finder reveal, dialog C, notification request), onboarding.json, Settings ›
  關於 row + `說明 › 首次啟動設定…`, DEBUG flags and the `onboarding` dump key, mock `-codd-show onboarding`.
- **I3 `a11y-copy`** — labels / roles / keyboard reachability for the App's custom views (sidebar rows,
  lamps, chips, rail, status bar, menu bar panel, session header and tabs, answer bar, composer bar,
  Home cards, palette rows, ⌘N sheet, notes area wiring), menu items for click-only actions, the
  `-codd-a11y-audit` DEBUG pass over every main screen in mock mode (0 unlabeled), the copy audit green
  (fixes in App and in any package's string literals).
- **I4 `e2e-docs-report`** — `scripts/m5-e2e.sh`, `scripts/TEST-MAP.md` M5 rows, one run each of
  m5-e2e (once, green; the wrap-up is its second run), m5-perf (budgets fixed or changed in ARCHITECTURE with the measured reason),
  m5-compat, `release.sh --dry-run` and `--output <tmp>`; ARCHITECTURE / ROADMAP / README / user guide
  final; docs/M5-REPORT.md (built, how to run, numbers, known issues, decisions, new copy, 繁體中文 manual
  checklist, proposed CLAUDE.md lines). Not the full suite (the wrap-up test run does that).

## 5. DEBUG flags and dump keys (RealModeOptions / StateDump; Release ignores them)

- I1: `-codd-force-render YES` (real and mock mode); `-CODDMetricsSessions <n>` (the switch metric cycles
  only the first n sessions of the sidebar order; its METRIC line gains `sessions=<n>`, and with
  `-CODDMetricsVerbose` each switch line names the tier it came from: `hot` / `cold`);
  `-codd-stop-after-create YES` (stops the session `-codd-new-claude` /
  `-codd-spawn-shell` just created, before its holder exists); log `perf launch-to-sidebar ms=<n> rows=<n>`
  (once, when the sidebar first shows the loaded layout, every build); dump `bundle` `{id, version, build,
  legacyDefaultsMigrated}` and `dataFiles` `{preflight:{ms, files:[{file, status, version?, aside?,
  backup?}]}, issues:[DataIssue], bannersShown:n}`.
- I2: `-codd-onboarding auto|show|never`, `-codd-onboarding-step <1-6>`, `-codd-onboarding-actions <list>`
  (comma list run in order once the window shows: `redetect`, `next`, `skip`, `back`, `goto:<n>`,
  `filter:<text>`, `check:<path>`, `uncheck:<path>`, `check-visible`, `suggest`, `group:<path>=<key>`,
  `new-group:<path>=<name>`, `show-hidden`, `more`, `hooks-preview`, `hooks-apply`, `reveal-notes`,
  `mcp-preview`, `notify`, `finish`, `close`; each logs `onboarding action=<a> step=<n> ok=<bool>`),
  `-codd-show onboarding[:<n>|:all]` (mock and real; `all` with `-codd-snapshot` writes
  `<stem>-onboarding-<n>.png` for steps 1–6 in one launch; mock mode never writes `onboarding.json`); dump `onboarding` `{shown, reason, step, steps:[{id,
  state, detail}], boot:[{tag, name, value, detail}], import:{source, total, hidden, already, checked,
  visible, filter, rows:[{path, name, prefix, lastUsed, transcripts, hidden, checked, group}],
  options:[{key, name, color, kind}]}, applied:{projects, groups}, hooks:{pending, applied, backup},
  notebook:{path, mcp, claudeCode}, accounts:{availability, rows:[{slot, alias, active}]},
  notifications, completedAt, file}` (never an e-mail, never a token).
- I3: `-codd-a11y-audit <file>` (mock mode; `-codd-a11y-screens <list>` narrows), `-codd-full-keyboard-access
  YES` (sets `KeyboardFocus.fullKeyboardAccessOverride`).

## 6. Acceptance

Automated (each by the agent that owns it; all once more in the wrap-up run):
1. New package suites green with zero warnings: CoddOnboarding, CoddDataStore; changed suites green:
   CoddUI and every UI package (rule 2), CoddTerminal, CoddComposer, CoddClaudeSettings, CoddHooks (+ its
   dependents per rule 2), CoddHolder (the compat target builds).
2. App builds (Debug `build-for-testing` in each I-step; Release through I4's `release.sh --output`) with
   zero warnings; app unit suite green (I-steps run their TEST-MAP rows; the wrap-up runs it whole),
   including I1's real-store test (every store's own output scans `current`: the preflight is never
   stricter than a store) and the D2 / D25 defaults tests (temp suites only).
3. `scripts/m5-e2e.sh` green in I4 and again in the wrap-up run (onboarding flow on a new root, existing root untouched,
   data files newer / corrupt / cache, bundle id and versions, stop while STARTING, the a11y audit with 0
   unlabeled, the copy audit, the release dry run, isolation scan, zorder violations = 0).
4. `scripts/m5-perf.sh`: every line PASS, or the budget changed in ARCHITECTURE with the measured reason.
5. `scripts/m5-compat.sh`: `COMPAT summary ok=<n> fail=0` for 37a9388 and db62f17; no worktree left.
6. `scripts/release.sh --dry-run` and `--output <tmp>`: `bundle=app.codd.CODD version=1.0.0 build=<count>`,
   `codesign --verify --strict --deep` passes, the zip exists.
7. `python3 scripts/tools/copy-audit.py` exits 0; `git grep -n fancycodd` hits only the D1 allow-list.
8. Every e2e script prints its zorder summary with violations = 0 (the wrap-up run).

`scripts/m5-e2e.sh` (I4; `ONLY=<ids>` like m4, unknown id exits 64; one mktemp folder `codd-m5e.XXXXXX`, a
data root per group from `make-root.sh`, temp Claude dirs, the fakes only, `-codd-quit-after` +
`-codd-dump-state` on every launch, the zorder guard over the whole run, every process ended, `KEEP=1`):
- **O1** new root with `-codd-onboarding auto`, the C1 import fixture (made-up projects under the run's
  `work/`: two parents with ≥ 2 projects, one single, one `.claude-worktrees` path, one SDK-only, one
  missing folder), a fake claude with `--version`, the fake cswap (3 accounts), a settings fixture with
  CODD web legacy hooks: onboarding shown and the main window not; boot rows (claude version, `3 個帳號`,
  hooks pending with the events, data root writable, MCP endpoint); import rows sorted by last use, hidden 2,
  the missing folder absent, prefixes, pre-checked rows, `suggest` → the two parent groups; `next` → layout.json
  has exactly the checked projects in the suggested groups and colors; the fixture `.claude.json` and the
  transcripts unchanged (sha256 + mtime); hooks step → `hooks-preview` plan only, settings.json unchanged;
  notebook path = `<root>/notes`, `reveal-notes` logged as skipped (background); accounts rows = aliases, no
  e-mail anywhere; `notify` → `suppressed` (`-codd-notifications NO`); `finish` → onboarding.json v1 with the
  steps, the main window shown. Relaunch: no onboarding.
- **O2** an existing root (seeded layout): no onboarding without a flag; `-codd-show onboarding` lists only
  projects not yet in CODD (`already` count), skipping every step imports nothing (layout.json bytes unchanged).
- **O3** no cswap, a claude path that does not exist: `[ .. ] cswap` / `[FAIL] claude` rows, the step 5 note,
  the flow still finishes.
- **D1** newer files (`layout.json` v99, `preferences.json` v99, `panes.json` v99, a `composer.json` v99,
  `config.json` v99): every byte unchanged after a run that changes things through existing DEBUG flags
  (a session created and renamed, a `-codd-set-pref` edit made persistent by a Settings edit flag, a panel
  tab, a composer draft); `dataFiles.issues` lists each `newer`; one banner per file in the dump; the
  sidebar (dump) shows the v99 layout's groups and sessions (read as far as possible, the v99 file written
  with v1-compatible content) and the v99 panes.json's tabs
  (`claude-settings-backups.json` and the notes `.codd/` files are covered by package tests).
- **D2** corrupt files (`layout.json`, `preferences.json`, `profiles.json`, `cleanup.json`, `files/recent.json`,
  a `composer.json`): each moved to `<name>.corrupt-<ms>` (bytes equal to the planted ones), defaults used,
  the banner names the file; a corrupt `quota.json` and `hooks/<id>.json` removed without a banner;
  `config.json` garbage → repaired by its store, never moved, port kept when readable; a `layout.json`
  that is a valid v1 object with a wrong shape (moved aside by LayoutStore itself) still gets its banner
  (the post-load aside sweep); a preferences.json with `"version":"1"` is NOT moved (its store repairs it).
- **D3** `cache/VERSION` = `0` with a planted file → cache contents wiped and the notes index rebuilt;
  a second launch keeps the cache; a cache without VERSION (the post-M4 layout) keeps its planted file and
  gains `VERSION`.
- **K1** the built bundle: `CFBundleIdentifier` `app.codd.CODD`, `CFBundleShortVersionString` = VERSION,
  helper signing identifiers `app.codd.codd-*`; `strings` of the binaries contain `fancycodd` only as the
  migration / legacy-notification constants.
- **S1** `-codd-new-claude` (fake claude) + `-codd-stop-after-create YES`: log `stop deferred` then
  `stop applied-after-spawn`, the session ends STOPPED, no holder process left within 5 s.
- **A1** mock mode `-codd-a11y-audit <file>` (every screen of §2.6 incl. onboarding 1–6): `unlabeled == 0`;
  the `outsideKeyLoop` count printed.
- **C1** `python3 scripts/tools/copy-audit.py` exit 0; `scripts/release.sh --dry-run` prints `RELEASE …
  bundle=app.codd.CODD version=<VERSION>`.
- **I1** isolation (B12-like): every `exec` line inside the temp folder; no new `~/.claude/settings.json.codd-bak-*`
  or `~/.claude.json.codd-bak-*` (names only); no `defaults migrated` line (non-standard roots never migrate);
  zorder summary violations = 0.

Manual (for the user, 繁體中文 checklist in the report): VoiceOver over the sidebar, a session, NOTES,
STATUS, Settings, the menu bar panel and onboarding; Full Keyboard Access (Tab through each screen, focus
rings visible, every rail destination from the menu); the installed Release on the REAL data root:
`說明 › 首次啟動設定…` with the real claude, cswap, settings.json and `~/.claude.json` (detection correct,
nothing written until 套用並備份 / 註冊, the import adds only the checked projects, which can be removed
from the sidebar); optionally a throwaway `-codd-data-root` try-out of the automatic first launch, where
by design (M3 D3 / D28, M4 D22) claude and cswap show as missing and MCP registration is disabled; the
notification permission prompt; 登入時啟動 off / on and removing the old entry; `scripts/release.sh
--install`; that the existing real data root shows no onboarding and keeps window frames, the split and
the status item position (defaults migration).

## 7. Testing policy (lean, user rule 2026-10-18)

Components run their own suites plus the rule-2 dependents no later agent runs, and one App build when
they changed a package the App uses (ui-core-a11y: CoddUI + CoddTextKit + CoddCodeEditor, because
ui-packages-a11y runs the other UI suites right after it). Integration steps run the TEST-MAP rows of the
paths they changed: I1 = shared app core → `scripts/m1-smoke.sh` once + the app test suites it added or
touched (`-only-testing:`) + `swift build` (not test) of the packages whose constants it renamed; I2 = its
new app test suites only + one snapshot launch (`-codd-show onboarding:all`) + one real-mode run; I3 = the
audit run, the copy audit and the package suites whose strings it changed; I4 = the M5 scripts once each
(m5-e2e included) and the Release through `release.sh --output`. No agent runs the full m1–m4 e2e scripts
or the whole app suite; the wrap-up test run does, once (it is also m5-e2e's second run).

## 8. Risks

- **Bundle id change**: notification permission, Full Disk / folder permissions (ad-hoc TCC is per build
  anyway) and the login item restart from zero; an old CODD with the old id may still launch at login and
  win the lock. Mitigation: both show-window names, D4 hint, user guide steps.
- **Reading another app's defaults domain**: works for a non-sandboxed app through `persistentDomain(forName:)`;
  if it returns nil the migration logs `sourceMissing` and nothing else happens.
- **Onboarding on test roots**: avoided by D5 (standard root only unless DEBUG); the m1–m4 scripts stay as they are.
- **Preflight false corrupt** (it runs on the user's real data root at the first M5 launch): only parse
  failures count; I/O errors, symlinks and large files are skipped; never stricter than the file's store
  (D14, proved by I1's real-store test); a corrupt file is moved, never deleted (USER DATA), logged and
  bannered, so a mistake is undone by renaming it back; the post-M4 cache (no VERSION) is kept.
- **Test runs writing the installed CODD's defaults** (window frame, split, status item): closed by D25;
  D2 replaces keys before its marker, so keys a test run wrote before the user's first Release launch do
  not block the copy.
- **Bundle id and TCC**: macOS asks again for notifications and for folder access (Desktop / Documents /
  Downloads, network volumes) because the identity changed; the user guide says so.
- **F2 may be inside libghostty's renderer**: the perf component tries renderer settings (drawable count,
  occlusion release, cursor blink, vsync) with a timebox; otherwise the budget changes with numbers.
- **Old commits may not build** with today's toolchain: compat builds only `codd-holder` in release; a build
  failure is a FAIL line with the compiler's first error, reported (not hidden).
- **A11y audit false positives** (labels set on a parent, AppKit-internal views): audit works on the
  accessibility tree, not raw views; allow a per-screen ignore list in the App audit with a reason.
- **Copy audit noise**: rule L is report-only; the allow list carries reasons.
- **Focus rings changing snapshots**: drawn only for the key window's first responder with Full Keyboard
  Access; snapshot tests run without it.
- **Scope / time**: nine components, four steps; lean testing; I4 must not start the full suite.

## 9. Rules for every agent

- Swift 6, strict concurrency complete, zero warnings in touched code; concise doc comments explaining why;
  no emoji anywhere; UI copy 繁體中文 for explanations, English UPPERCASE for structural labels.
- Real mode is the default: every CODD launch passes `-codd-data-root <fresh temp dir>` and
  `-codd-claude-dir <temp dir>` as separate arguments (or `-codd-mock`), `CODD_BACKGROUND=1`, never `open`,
  never `-codd-background NO`, never osascript / AppleScript `activate`; DEBUG builds refuse a real-mode
  launch from Claude Code without a data root: never work around it.
- Never touch `~/.claude/settings.json`, `~/.claude.json`, `~/.claude-swap-backup`, `~/Library/Application
  Support/CODD`, the real `app.codd.CODD` / `app.fancycodd.CODD` defaults domains (tests use unique temp
  suite names and remove them), `/Applications`; never run the real cswap or a real `claude`; never call
  an Anthropic API. Onboarding fixtures use made-up paths under temp folders.
- The user's own CODD may run from `build/user-m3` or `build/user-m4`: never kill it, its holders or its
  sessions; never build into `build/user-*`; never touch `build/wt-*`. End every process you started.
- Own scratch paths: `--scratch-path .build-<label>`, `-derivedDataPath build/<label>`.
- Do not commit; do not edit CLAUDE.md. Report honestly (what does not work goes under known issues).
- Never list or write `~/.Trash` (TCC); never read the real defaults domains with `defaults read` either.

## 10. Critique changes (2026-10-18, applied above)

1. D2: copied keys replace the target's before the marker; DEBUG tool keys excluded (test runs write the
   new domain before the user's first Release launch). New D25: no frame / split / status item autosave on
   non-standard roots and in mock mode (test runs would change the installed CODD's window).
2. D14: never stricter than a store (missing / non-integer / < 1 version follows each store; real-store
   test in I1); missing `cache/VERSION` is written, not wiped; a post-load sweep banners the stores' own
   `.corrupt-<ms>` moves; newer layout.json / panes.json are read as far as possible (gaps not listed before).
3. D15: protection by dwell (≥ 5 s visible) or revisit, with an injected clock; plain second-access SLRU
   with probation 2 would evict the session the user worked in after three quick glances.
4. D16 / §2.8: hot / cold switch needs I1's `-CODDMetricsSessions` and `-codd-real-holders YES`
   (`-CODDMetrics` implies mock); budget decisions use I4's quiet run; `PERF env` line; the 3 fake claudes
   come from `-codd-resume-stopped`.
5. D8 / D10 / D11: `.claude.json` read through a symlink; width-based path elision and `M/dd` dates (as the
   artboard); hooks wording for the Desktop model (legacy events, not `缺`).
6. D18 / §2.10: `/usr/bin/trash`, never `~/.Trash` listings (TCC); xcodegen only when stale (components share
   the project); nested code signed inside-out.
7. D19 / §2.9: `--exit-linger-ms 500`; the paste check after reattach with `?2004` on.
8. D20 / §2.12: the deferred stop goes through the normal stop path after connect.
9. D23 / §2.11: `.build` demos ignored; precedence; realpath + NFC (the repo path has CJK characters).
10. §2.2 / §2.4b contracts: `DataFileResult` and `ImportPlan.Addition` structs (tuple arrays are not
    Equatable); `asideFiles(createdSince:)`; `@MainActor` action closures; displayPath elided by the view.
11. D5: reopen / show-window / Dock while onboarding is open bring the onboarding window; facts probed only
    while it shows. I2 resolves claude through the login PATH (the init-time VersionProbe does not).
12. ui-packages-a11y also owns `Packages/CoddFiles/Package.swift` (test-target dependencies only).
13. Lean testing (D24): m5-e2e once in I4; no duplicate rule-2 suites; package builds instead of suites for
    constant renames; Release only through I4's release.sh; onboarding snapshots in one launch.
14. Manual checklist: the onboarding check with the real tools runs on the real data root (a throwaway
    root shows claude / cswap missing and MCP registration disabled by design).
15. Copy audit: emoji in test data become `\u{…}` escapes (I3) instead of allow-list entries.
