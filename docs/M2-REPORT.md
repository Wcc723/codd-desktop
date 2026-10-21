# CODD Desktop: M2 report

Written 2026-10-17 after integration step I7 (end to end, report). M2 = sessions complete
(docs/M2-PLAN.md): the sidebar of the approved artboards on real data, read-only external claude
sessions, ⌘K, an IME-safe ⌘L composer, ⌘J panel tabs, the ⌘N sheet with the resume picker and
launch profiles, ring replay for sessions whose holder is gone, and a CODD that copes with a second
instance, an unanswered holder and its own errors. This report covers the four components (C1–C4),
the seven integration steps (I1–I7), how to run everything, the numbers, what is not done, and what
you should try by hand.

**Status:**
- **Review round 1 (§9):** 26 confirmed problems (25 distinct) fixed, each with a regression test
  unless noted. After the fixes: Debug and Release build with zero warnings (`build/fix1`,
  `build/fix1-rel`); app tests 299/299; CoddCore 271, CoddHolder 161 (34 + 127), CoddHooks 90
  (83 + 7), CoddTerminal 68, CoddComposer 85; `scripts/m2-e2e.sh` 110/110, `scripts/m1-e2e.sh`
  42/42, `scripts/m1-smoke.sh` 22/22, `scripts/m2-fixtures/selftest.sh --with-app` 268/268,
  `-CODDSelfTest YES` → `SELFTEST OK`, `-codd-shortcut-matrix` 67/67. Visible idle CPU is still
  over budget while durations count seconds (§4, §5). The bullets below are the I7 state.
- **Builds and tests:** Debug and Release build with zero warnings (fresh derived data
  `build/m2i7`, so every target was compiled). App tests 282/282; CoddCore 266, CoddHolder 161
  (34 + 127), CoddHooks 90 (83 + 7), CoddTerminal 67, CoddComposer 78: all green.
- **End to end:** `scripts/m2-e2e.sh` 110/110 (13 scenarios, 21 app launches, fake claudes only),
  green on two consecutive runs; `scripts/m1-e2e.sh` 42/42, `scripts/m1-smoke.sh` 22/22,
  `scripts/m2-fixtures/selftest.sh` 245/245 (268/268 with `--with-app`), `-CODDSelfTest YES` →
  `SELFTEST OK`.
- **Fixes in this step:** none needed in App/ or the packages: no suite and no e2e run exposed a
  product bug. The step adds the e2e script and the docs (§8).
- **Default mode:** real mode on `~/Library/Application Support/CODD`, as in M1. New files there:
  `codd.lock`, `profiles.json` (written with the 4 built-ins the first time this build starts on
  your root), `sessions/<id>/composer.json`, `sessions/<id>/attachments/`.
- **Not yet verified with a real `claude`:** automated runs never start one (quota). The 繁體中文
  checklist in §6 is what is left for you; the M1 checklist's first real-claude run (hooks accepted
  by the endpoint) is part of it.

---

## 1. What was built

### Components (parallel, outside App/)

**C1 core — `Packages/CoddCore`**
- `Transcripts/TranscriptCatalog.swift`: read-only catalog of `<claudeDir>/projects`. Finds a
  folder by Claude's exact folder name (also the hashed form over 200 characters, checked against
  the installed Claude Code bundle), reads only head (256 KiB) and tail (128 KiB), caches by path +
  mtime + size, lists newest first with `customTitle` > `aiTitle` > first prompt, drops `sdk-*` and
  other-cwd files, gives `lastPrompt` and the D23 `files(sessionId:cwd:)` (never a symlink, never
  outside the projects folder). `TranscriptRetention` (days left), `ClaudeUserSettings`
  (`cleanupPeriodDays`, `model`; read only, ≤ 1 MiB).
- `Search/FuzzyMatcher.swift`: case-, width- and diacritic-folded matcher with tiers (prefix, word
  start incl. CJK↔Latin boundaries, substring, subsequence) and UTF-16 spans for highlighting.
- `Registry/ExternalSessions.swift`: `ExternalSessionDetector` + `ProcessAncestry` (sysctl parent
  chain ≤ 8): the registry minus CODD's own claudes, with `hostHolderPid` for claudes inside a CODD
  shell.
- `Launch/LaunchProfileStore.swift`, `LaunchProfile.swift`: `profiles.json` document (versioned,
  tolerant per entry, normalized), store (atomic, 0600, never over a newer version), editing rules
  (`validate`, argument / environment parsing and formatting, `commandPreview`, `profileCommand`).
  Built-in names are the artboard names (`claude-default`, `claude-plan`, `claude-rc`, `zsh`).

**C2 holder — `Packages/CoddHolder`**
- Capability `input.paste` (INPUT flag bit1, always in WELCOME caps; `proto` stays 1): bracketed
  paste when the child has `?2004` on, markers stripped (`CoddProtocol/BracketedPaste.swift`), the
  submit Return 50 ms after the paste. Client fallback brackets by the newest known modes.
- `CoddProtocol/RingResync.swift`: one shared replay-point choice for WELCOME `resync`, ATTACH,
  GAP and the reader. `CoddHolderClient/RingFileReader.swift`: reads a ring from disk with `pread`
  (never mmap, never flock), safe against a writing holder. `codd-holderctl ring` and
  `send --paste`; testhelper modes `chunks` and `flood`.

**C3 composer — `Packages/CoddComposer` (new)**
- `ComposerTextView` (TextKit 1 NSTextView; every key through `interpretKeyEvents`, Return submits,
  ⇧/⌥Return newline, Return while composing commits the composition and never sends, ↑/↓ history
  on the first / last visual line, Esc), `ComposerField` (grows 1…8 lines, overlay scrollers),
  `ComposerHistory` (100 entries), `ComposerStateFile` (`composer.json`), `ComposerEncoding` (D2),
  `ComposerPaths.escaped` (D31). `codd-composer-demo` for the manual 注音 check.

**C4 fixtures — `scripts/m2-fixtures`**
- `make-root.sh` (a data root with its own hook port 43000–43999), `fake-claude-m2.sh` (Python 3.9
  fake claude: DA1, SessionStart through `codd-hook`, `FAKE-LINE` / `FAKE-PASTE` / `FAKE-SUBMIT`,
  hooks, optional registry file, `FAKE_LOG_DIR`), `fake-external-claude.sh start|host|set-status|stop`,
  `make-transcripts.sh` (six transcripts + manifest), `seed-layout.sh` (layout.json + manifest),
  `selftest.sh`, `README.md`. `scripts/m1-smoke.sh` writes its own config.json (D24).

### Integration steps (sequential, App/)

**I1 robustness and lifecycle**
- Test-root hook port (D24, `HookPipeline.portRange`); single-instance lock and show-window request
  (`App/Real/InstanceLock.swift`, D9, D28); problem banner (`App/Session/ProblemBannerView.swift`,
  `HolderSessionStore.problem`, replaces `lastError`); UNREACHABLE overlay (D8, `PtyConnection`
  outage clock, `retryNow`); dead-session ring replay (D7, `TerminalHub`); window occlusion while
  closed (D10, `MainWindowController.onVisibilityChange`); ARCHITECTURE.md (coddd deferred).

**I2 sessions data**
- External sessions (`App/Real/HolderSessionStore+External.swift`): registry fan-out from
  `HookPipeline`, `externalByID`, transient projects + promotion, read-only pane, menu subsets, no
  `[1 允許]` for them, no notifications. Stale flag (D15). Launch profiles service
  (`App/Real/LaunchProfiles.swift`) and the launch plumbing (profile, `--resume`, Remote Control,
  pre-chosen session id). Transcripts, Claude settings and last prompt on `AppServices`.
  `unarchive`, `archivedSessions`. 刪除對話紀錄 to the Trash (D23).

**I3 sidebar**
- STATE view details, filter over every section, hover card (`App/Sidebar/HoverCard.swift`), inline
  new-group row + color popover (`NewGroupEditor.swift`), group header hover actions and
  `清理已停止`, countdown toast, amber drop line, archive restore menu, external rows, ⌘P / ⌘. menu
  items declined by terminals, the `sidebar` dump (`SidebarDump.swift`), `-codd-shortcut-matrix`
  (`App/Debug/ShortcutMatrix.swift`).

**I4 Home, quick switch, composer**
- Home per artboard (`App/Session/HomeModel.swift`, `HomeCards.swift`, `HomePageView.swift`; D17,
  D29). ⌘K (`App/Palette/QuickSwitchModel.swift`, `CommandPalette.swift`; D14). Composer bar
  (`App/Session/ComposerBarView.swift`, `PaneComposer.swift`, `ComposerStates.swift`) with drafts,
  history, image paste, the `input.paste` send path, ⌘L. Error-banner actions
  (`AutoRetryScheduler.swift`, D26). `project.yml` gains the CoddComposer package.

**I5 bottom panel**
- Panel tabs, `+`, maximize, bells, OSC titles and the running lamp (`App/Model/ShellState.swift`,
  `App/Session/PaneBars.swift`, `TerminalAreaView.swift`, `App/Terminal/ForegroundJob.swift`,
  `TerminalHub`; D11–D13, D25); `panes.json` additive keys (`App/Real/PaneLayoutStore.swift`).

**I6 new session and profiles UI**
- The ⌘N sheet per the NewSession artboard (`App/NewSession/NewSessionForm.swift`,
  `NewSessionSheet.swift`, `NewSessionModels.swift`, `ProjectCombobox.swift`,
  `App/Controls/FormControls.swift`) with the resume picker (D16, D18, D22, D30). Settings ›
  啟動設定檔 (`App/Settings/ProfilesSettingsView.swift`, `ProfileEditorSheet.swift`,
  `ProfileEditorForm.swift`).

**I7 end to end, report (this step)**
- `scripts/m2-e2e.sh`, the full verification pass (§3), the numbers (§4), this report, the final
  docs/ARCHITECTURE.md pass (decisions, repository layout, data root tree, the M2 app sections:
  sidebar / Home / ⌘K, composer, panel tabs, new session and profiles, testing hooks) and the
  CLAUDE.md build lines.

## 2. How to run

```bash
# Packages (separate scratch paths avoid lock clashes)
swift test --package-path Packages/CoddCore     --scratch-path .build-core
swift test --package-path Packages/CoddHolder   --scratch-path .build-holder
swift test --package-path Packages/CoddHooks    --scratch-path .build-hooks
swift test --package-path Packages/CoddTerminal --scratch-path .build-terminal
swift test --package-path Packages/CoddComposer --scratch-path .build-composer

# App + tests
xcodegen generate
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test

# End to end (temp roots, temp Claude dirs, fake claudes; they end every process they started)
scripts/m2-e2e.sh            # M2: 13 scenarios; KEEP=1 keeps the temp folder; CODD_APP=<binary>
scripts/m1-e2e.sh            # M1 claude pipeline
scripts/m1-smoke.sh          # M1 shell holders, tabs, ⌘J panel, relaunch
scripts/m2-fixtures/selftest.sh [--with-app build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD]

# Manual 注音 check of the composer alone
swift run --package-path Packages/CoddComposer --scratch-path .build-composer codd-composer-demo

# The app on your real data (what you use day to day): just open it.
open build/dd/Build/Products/Debug/CODD.app

# A throwaway try-out instead: its own data root and hook port, a temp Claude dir (nothing of
# ~/.claude is read), no login-shell capture, no notifications.
APP=build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
T="$(mktemp -d "${TMPDIR:-/tmp}/codd-try.XXXXXX")"
scripts/m2-fixtures/make-root.sh "$T/root"
mkdir -p "$T/claude/sessions"
"$APP" -codd-data-root "$T/root" -codd-claude-dir "$T/claude" -codd-login-env NO -codd-notifications NO
# Optional: a seeded sidebar and transcripts for the resume picker
#   scripts/m2-fixtures/seed-layout.sh "$T/root" "$T/work"   (before the first launch)
#   scripts/m2-fixtures/make-transcripts.sh "$T/claude" "$T/work/northstar-site"
# Mock data (screenshots, self test): "$APP" -codd-mock   /   "$APP" -CODDSelfTest YES
```

The try-out root's shells are your login shell (`-codd-shell-argv "/bin/zsh -f"` avoids your rc
files) and its claude is the real one unless you pass `-codd-claude-path`. DEBUG flags are listed
in `App/Real/RealModeOptions.swift`; `-codd-dump-state <file>` writes what the e2e checks.

## 3. Test results (2026-10-17)

| Suite | Result |
|---|---|
| After review round 1 (§9) | App 299 tests in 68 suites; CoddCore 271; CoddHolder 34 + 127; CoddHooks 83 + 7; CoddTerminal 68; CoddComposer 85; m2-e2e 110/110; m1-e2e 42/42; m1-smoke 22/22; selftest `--with-app` 268/268; `SELFTEST OK`; shortcut matrix 67/67: all green, zero warnings |
| App (`xcodebuild test`, build/m2i7) | 282 tests in 64 suites passed (124 after M1 + 158 in M2: robustness 19, sessions data 25, sidebar 40 + 7 on a seeded real store, Home / palette / composer 28, panel 20, new session / profiles 19) |
| CoddCore | 266 passed (191 + 75: transcripts and settings 27, fuzzy 11, external sessions 13, launch profiles 24) |
| CoddHolder | 34 + 127 passed (132 + 29: paste, resync choice, ring file reader incl. a live-flood torn-read test) |
| CoddHooks | 83 + 7 passed (unchanged) |
| CoddTerminal | 67 passed (unchanged) |
| CoddComposer | 78 passed (new: encoding, history, state file, paths, text view 37, field 13) |
| Builds | Debug and Release `** BUILD SUCCEEDED **`, zero `warning:` lines (fresh derived data); package builds with `--build-tests` zero warnings |
| `scripts/m2-fixtures/selftest.sh` | `FIXTURES pass=245 fail=0`; with `--with-app`: `pass=268 fail=0` |
| `scripts/m1-e2e.sh` | `E2E pass=42 fail=0` |
| `scripts/m1-smoke.sh` | `SMOKE pass=22 fail=0` |
| `-CODDSelfTest YES` | `SELFTEST OK` (outline fuzz, panel tabs + maximize, ⌘T ⌘W ⌘J, shortcuts; timers skipped while the window is not on screen) |
| `scripts/m2-e2e.sh` | `E2E pass=110 fail=0`, two consecutive runs (output below; about 3 min 25 s) |
| Release app on a make-root.sh root | starts, takes the lock, seeds profiles.json, `/health` answers as CODD (80 MB, Home only) |

Warnings left anywhere: none from the compiler. The only `warning:` lines seen were SwiftPM's
"stale file outside of the allowed root paths" notes on the first build into a scratch folder that
was cloned from another one (an artifact of the clone, gone on the next build).

```
E2E root=<tmp> app=build/m2i7/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
E2E r1 exit=0
E2E ok   R1 app quit by itself
E2E ok   R1 groups in order with their colors
E2E ok   R1 projects sit in their groups
E2E ok   R1 non-archived sessions listed (claude STOPPED, shell EXITED)
E2E ok   R1 pinned session in pinned and in the PINNED section
E2E ok   R1 archived session in archived, not in sessions
E2E ok   R1 collapsed project stays collapsed (its session row hidden)
E2E ok   R1 layout.json keeps the archived session after quit
E2E ok   R1 layout.json keeps the project collapsed
E2E ok   R1 hooks on the root's own port
E2E externals known=87989 unknown=88001
E2E ok   R2 both externals listed
E2E ok   R2 known-folder external under northstar-site, busy, with its pid
E2E ok   R2 unknown-folder external in a transient project in 未分類
E2E ok   R2 layout.json never names the transient project or an ext- id (while shown)
E2E ok   R2 external turns WAITING (permission) and counts as attention
E2E ok   R2 waiting external is in NEEDS YOU
E2E ok   R2 stopped externals are gone, and the transient project with them
E2E r2 exit=0
E2E ok   R2 app quit by itself
E2E ok   R2 layout.json never names the transient project or an ext- id (after quit)
E2E host dummy=88375 shell=05f4519e-5701-4d70-8d78-572fce04cd6b claude=ee710d32-f94e-4696-8596-d4133d7cfa1e
E2E ok   R2c claude inside a CODD shell is external with hostSession = that shell
E2E ok   R2b CODD's fake claude keeps a registry file (profile env)
E2E ok   R2b the fake claude saw the profile's FAKE_REGISTRY_DIR
E2E ok   R2b CODD's claude is never external
E2E ok   R2b the log never added it as external (not even before WELCOME)
E2E r2b exit=0
E2E ok   R2b app quit by itself
E2E ok   R2bc holders ended, registry files removed
E2E ok   R11 filter: both waits count as attention, NEEDS YOU shows only the matching one
E2E ok   R11 filter: PINNED keeps the matching pinned session
E2E ok   R11 filter: only northstar-site rows in TREE mode
E2E r11b exit=0
E2E ok   R11b app quit by itself
E2E r4a exit=0
E2E ok   R4a app quit by itself
E2E profile session=8839ef64-0593-4b12-8161-5211d7bad8d1 fake pid=88739
E2E ok   R4a terminal shows FAKE-ARGV with --e2e-flag
E2E ok   R4a terminal shows FAKE-ENV FOO=bar-42
E2E ok   R4a exact argv line has --e2e-flag (FAKE_LOG_DIR)
E2E ok   R4a layout row records the profile that ran
E2E r4b exit=0
E2E ok   R4b app quit by itself
E2E resumed session=17efa14c-0ecc-42f5-9d6b-319ef5418d99 transcript=fa1319bc-4b0c-4fa8-a115-504593b97356 fake pid=88872
E2E ok   R4b FAKE-ARGV has --resume <transcript id>
E2E ok   R4b exact argv: --resume <id> (FAKE_LOG_DIR)
E2E ok   R4b the session's claudeSessionId is the transcript id
E2E r4c exit=0
E2E ok   R4c app quit by itself
E2E ok   R4c picker lists the fixture transcripts, newest first, with their titles and branches
E2E ok   R4c the 26-day transcript expires in 4 days, no other warning
E2E ok   R4c sdk and other-cwd transcripts absent
E2E ok   R4c the running session's transcript is disabled (執行中)
E2E ok   R4c command preview starts with claude --resume
E2E ok   R5a lastPrompt learned from UserPromptSubmit
E2E r5a exit=0
E2E ok   R5a app quit by itself
E2E ok   R5a composer sent the line (log)
E2E ok   R5a fake claude: FAKE-LINE hello 世界 then FAKE-SUBMIT
E2E ok   R5b lastPrompt is the last text (one line, D20)
E2E r5b exit=0
E2E ok   R5b app quit by itself
E2E ok   R5b composer sent a paste (log)
E2E ok   R5b fake claude: FAKE-PASTE 第一行⏎第二行 then FAKE-SUBMIT
E2E ok   R5 composer.json history holds both sends, draft empty
E2E ok   R5 dump: composer open with 2 history entries
E2E r6 exit=0
E2E ok   R6 app quit by itself
E2E palette query=claude title='fake claude m2'
E2E ok   R6 the query is part of the session title
E2E ok   R6 palette: the session in Sessions
E2E ok   R6 palette: its project in Projects
E2E ok   R6 palette: 在 claude-lab 新增 session in Actions
E2E ok   R11 STATE view: the idle fake claude row is stale
E2E ok   R11 STATE view: Idle head counts its rows and says n stale
E2E r11a exit=0
E2E ok   R11a app quit by itself
E2E ok   R12 the resumed session's holder ended (session stopped)
E2E r12 exit=0
E2E ok   R12 app quit by itself
E2E ok   R12 log: two files moved
E2E ok   R12 transcript and sibling folder are in the trash folder
E2E ok   R12 they left the projects folder
E2E ok   R12 the other fixture transcripts are untouched
E2E ok   R12 the trash folder holds nothing else
E2E ok   R12 the session left CODD (dump)
E2E ok   R12 the session left layout.json
E2E c1 exit=0
E2E ok   C1 app quit by itself
E2E shell session=d14df7f8-9948-4bcd-b00b-42dd56d5c99a holder=89788
E2E ok   C1 the shell printed the marker
E2E ok   C1 its holder survived the quit
E2E second instance exit=0 after 0.12s
E2E ok   R3 second instance exits 0 within 5 s
E2E ok   R3 second instance logs another-instance with the first's pid
E2E ok   R3 second instance wrote no state dump
E2E ok   R3 first instance logs show-window requested
E2E ok   R3 first instance keeps running
E2E ok   R3 layout.json, config.json and panes.json unchanged by the second
E2E r3a exit=0
E2E ok   R3 first instance quit by itself
E2E ok   R3 first instance kept its session attached (no close, no takeover)
E2E ok   R3 first instance still shows it live and reachable
E2E ok   R9 stopped holder → unreachable within 15 s
E2E ok   R9 SIGCONT → reachable again within 20 s
E2E unreachable after 5.26s, cleared 0.16s after SIGCONT
E2E ok   R9 the session is not stopped (still a live shell)
E2E r9 exit=0
E2E ok   R9 app quit by itself
E2E ok   R9 no takeover, holder still running
E2E r8 exit=0
E2E ok   R8 app quit by itself
E2E ok   R8 replayed viewport shows the last output
E2E ok   R8 replay footer holder 已結束
E2E ok   R8 session EXITED and marked replayed
E2E ok   R8 log: ring replayed
E2E ok   R7 pane: two panel tabs with holders, maximized
E2E r7 exit=0
E2E ok   R7 app quit by itself
E2E panel session=fc17b2f5-dbbb-4128-8831-fc15b7d18b7e tab holders=90836 90837
E2E ok   R7 panes.json: 2 panelTabs, panelMaximized, and the M1 panel key
E2E ok   R7 both tab holders run after the quit
E2E ok   R7 relaunch: both panel tabs reattached to the same holders
E2E r7b exit=0
E2E ok   R7b app quit by itself
E2E ok   R7 relaunch spawned no tab holder
E2E ok   R7 relaunch kept maximize
E2E ok   R10 windowVisible false after closing the main window
E2E ok   R10 the app keeps running with the window closed
E2E r10 exit=0
E2E r10 ran 8.78s
E2E ok   R10 app quit by itself
E2E ok   R10 it kept running until its quit-after (8 s)
E2E ok   R10 every holder survived the quit
E2E r13 exit=0
E2E ok   R13 app quit by itself
E2E ok   R13 fresh root listens on a port in 43000-43999 (config.json created with it)
E2E ok   R13 log: hooks port-range=test
E2E killing holders: 88738 90835 90836 90837
E2E pass=110 fail=0
```

How the e2e is laid out: one mktemp folder with four data roots (`a` seeded by seed-layout.sh for
R1, R2, R2b/c, the R11 filter; `b` with transcripts and a custom profile for R4, R5, R6, the R11
STATE view, R12; `c` for the terminal lifecycle: C1, R3, R9, R8, R7, R10; `d` a plain `mkdir` for
R13), each with its own Claude directory. The fake claude is a copy inside the folder with a
sidecar `.env` (`FAKE_LOG_DIR`); profile environments add `FAKE_REGISTRY_DIR` (R2b) or
`FOO`/`FAKE_PRINT_ENV` (R4a). Every wait polls the state dump every 100 ms and is bounded (≤ 20 s).

## 4. Measured numbers (this Mac)

How measured: the Debug build `build/m2i7` unless stated; footprint = `footprint <pid>`
(phys_footprint) 12 s after launch; CPU = `ps -o cputime` over 10 s; the rest from the DEBUG log
lines named in the table. Measurement roots were made by make-root.sh, with the fake claude.

| What | Measured | Budget |
|---|---|---|
| App footprint, 1 fake claude shown + 2 shells + composer open, window visible | 115 MB; the same without the composer 113–115 MB. The **M1 build** (`build/dd`, commit 37a9388) in the same scenario today: 112–114 MB, so M2 adds ≈ 0–2 MB (the M1 report's 76 MB was not reproduced) | app base < 80 MB (over, see §5) |
| Same, main window closed (`-codd-close-main-window YES`) | 82 MB | — |
| Release build, Home only, no session | 80 MB | — |
| Idle CPU over 10 s, the scenario above, window closed | 0.01 s = 0.1 % (the resolution of `ps`) | hidden < 0.1 % |
| Idle CPU, window visible (review concurrency-perf-1: I7's "visible: the same" was taken with the screen locked, which stops the 1 Hz clock like a hidden window; re-measured with `-CODDForceVisibleTimers YES`, one `zsh -f` SHELL session shown, Debug, cs per 10 s from 10 s after launch) | Before round 1: 8 10 13 13 13 10 12 14 14 12 13 then 3 1 2 1 1 = 0.8–1.4 % while durations count seconds (below 2 min, `12s`, `UP 1m05s`), 0.1–0.3 % after. After (§9, chip and meta line in their own layers): 5 6 7 6 5 7 6 7 6 7 7 then 2 1 1 1 2 = 0.5–0.7 %, then 0.1–0.2 %. Release cannot force visible timers (DEBUG flag) on a locked screen | visible < 0.5 % (still over while seconds count, §5) |
| ⌘K open / rank (`PALETTE shown` / `ranked`, query `claude`, 5 rows) | 4.2–5.2 ms / 0.43–0.46 ms | — |
| ⌘N sheet (`NEWSESSION shown`) | 296–303 ms: building 18.7–19.4 ms, AppKit's sheet slide-in 273–279 ms | — |
| Resume picker load (`NEWSESSION picker`, 6 fixture files, 4 rows, cache miss) | 33–42 ms | — |
| Transcript catalog in the app (`-codd-list-transcripts`, fixtures) | cold 26–64 ms, cached 0.01 ms | — |
| Ring replay of a full 8 MiB ring (12 MB flood, kill -9, relaunch) | 34.1–34.5 ms creation → shown; file read 0.96–1.01 ms off main; apply 0.68–0.69 ms on main | — |
| Session switch (`-CODDMetrics`, 4 shells + 1 claude, real holders) | METRIC p50 1.05–2.06 ms, max 3.5–5.4 ms; `TERMINAL show` hot 0.10–0.22 ms, cold 1.5–21 ms | hot < 16 ms |
| Footprint after that switch cycle (5 terminals hot) | 396–427 MB | total with 15 sessions < 300 MB (over: carried F2) |
| Holder (release, idle `/bin/sh`) | 1536 KB phys_footprint, RSS 2448 KB (C2: 1648 KB) | ≤ 2.5 MB |
| Second instance on the same root: exit | 0.12–0.13 s (e2e R3) | — |
| UNREACHABLE after SIGSTOP (keepalive 1000,2000, unreachable-after 2) / cleared after SIGCONT | 5.3 s / 0.16–0.17 s (e2e R9); with the default timings about 45 s (I1) | — |

Component and step numbers (from their reports): transcript list over 60 × 1.15 MB files cold
34.6 ms / warm 0.47 ms, one 50 MB file 1.2 ms, fuzzy 500 candidates × 6 queries 17.4 ms, external
detection over 50 entries 61 µs (0.67 ms with real sysctl), all release; ring file read of 8 MiB
0.22–0.26 ms; `applyRegistry` with 20 entries 1.0–1.2 ms first, 0.19 ms update; sidebar snapshot
for 100 sessions 0.16 ms (TREE), 0.11 ms (STATE), 0.95 ms (TREE + filter); hover card 4–8 ms after
its 380 ms delay; Home render 1.3–1.8 ms; composer send to the stream 0.010–0.045 ms; running-lamp
poll 34–41 µs per shell; idle CPU with a shell printing every 100 ms 0.2 % (window closed) / 2.6 %
(visible).

## 5. Known issues

**Not verified with a real `claude`** (automated runs never start one):
- Claude's own http hook client against the endpoint (M1 item: an `Origin` header or another
  `Host` would be refused with 403; STATUS › HOOKS shows it).
- Bracketed paste + the 50 ms submit delay: whether Claude Code takes a multi-line paste as one
  prompt and the Return right after it as submit. If it swallows the Return, raise
  `Holder.pasteSubmitDelayNanoseconds`.
- An image path inserted by the composer being accepted as an attachment.
- A real external claude (Terminal.app) and a real claude inside a CODD shell; real transcripts'
  titles, branches and last prompts; 刪除對話紀錄 into the real Trash.
- 注音 in the composer, the ⌘K field, the ⌘N combobox and name fields, the profile editor (tests
  simulate composition with `setMarkedText`).
- Mouse-driven UI: drags, hover cards, header hover buttons, context menus, the combobox list, the
  NSOpenPanel (`選擇資料夾…` / ⌘O), panel strip buttons, Dock click and the menu bar's `開啟
  FANCY/CODD` (they call the verified show-window path). Posting events would move your pointer.
- The second instance bringing the first to the front (`activate`) with an unlocked screen; the
  show-window request itself is verified.

**Budgets**
- **Visible idle CPU over the 0.5 % budget while durations count seconds** (review
  concurrency-perf-1, older than M2): 0.5–0.7 % (Debug, one SHELL session shown) during the first
  2 minutes of a state or an uptime, when the header chip / `UP x` and the sidebar line 2 change
  every second; 0.1–0.2 % afterwards. Round 1 halved it (0.8–1.4 % before) by keeping the glowing
  title out of the per-second redraw; what is left is the 1 Hz timer, the Core Animation commit and
  the small text layers. Not measured in Release (the force-visible flag is DEBUG only and this
  Mac's screen was locked).
- **App footprint over the 80 MB base budget.** One visible terminal: 112–115 MB for both the M1
  and the M2 build on this Mac today (§4), 82 MB with the window closed. The M1 report's 76 MB was
  not reproduced; the difference sits in libghostty's visible Metal surface (see F2 below), not in
  M2 code.
- **GPU memory while terminals animate (M1 F2, carried).** After cycling 5 terminals hot:
  396–427 MB (`-CODDMetrics`). Needs Instruments against Ghostty.app, then a renderer setting or
  patch, or a revised budget.
- **Churn footprint (M1 E2E-3, carried)** and **hot-tier LRU thrash with 8+ terminals (M1 F5,
  carried)**: unchanged.
- The ⌘N sheet takes about 300 ms to appear, 275 ms of it AppKit's synchronous sheet animation
  (terminals do not render meanwhile).

**Accounts and Claude directories**
- Accounts and usage (sidebar footer, Home USAGE, ⌘N account select) are still the mock
  `AccountStore` until M3, labelled `· 示意資料，M3 接上 cswap` in real mode (D29). Its dates are
  the SPEC's and now in the past (`1w 重置 已重置`, a full date for the 5h reset).
- A launch profile with another `CLAUDE_CONFIG_DIR` (and cswap-run sessions) writes its registry
  and transcripts elsewhere: such sessions are not seen as external, their transcripts are not in
  the resume picker, and RESUME / 刪除對話紀錄 look in `<claudeDir>` only (M3 adds those
  directories).
- Claude's settings.json is read once per run (a changed `cleanupPeriodDays` or `model` needs a
  relaunch).

**Sessions, externals, transcripts**
- Folder matching (`project(forPath:)`) resolves project folders off the main actor and caches
  failures for 30 s (review concurrency-perf-5), but a path seen for the first time (a new
  external's cwd, a folder typed into ⌘N) is still resolved on the main actor: a stalled network
  mount there can still stall the UI once.
- The hover card reads an external's transcript prompt again after a state change only when the
  card is shown again (the read-only pane follows it live).
- A non-SDK claude started from a CODD claude session's own Bash tool shows as EXT (the own-holder
  rule looks only at the first ancestor).
- A claude started inside a CODD shell can show `外部啟動` for a moment until the shell's holder
  pid is known.
- External rows carry only what the registry has (state, name, pid, start time): no tool, model or
  context, and an external NEEDS YOU card has no reason line.
- Transcripts started from a symlinked folder are found only from the symlinked spelling; a first
  prompt over 256 KiB gives `（沒有標題）`; the branch is the first one in the head; the prompt
  filter (which lines are not prompts) is a heuristic; symlinked .jsonl files are skipped.
- RECENTLY STOPPED lists 3 conversations per project and the resume picker 50; `sdk-*` and
  other-cwd files no longer use up the limit (review e2e-1), but at most `limit * 4 + 64` files are
  opened per folder (76 for Home, 264 for the picker), so a folder with more newer `claude -p` runs
  than that still shows fewer.
- A resumed conversation's title is replaced by learned titles (hook, registry name, OSC title) as
  in M1; the ⌘N resume passes the transcript title as `-n <title>`, which renames the Claude
  conversation unless the name is cleared.
- `↻ 重送上一則` / `⟲ 稍後自動重試` resend the whole prompt (review correctness-1). After a relaunch
  it comes from the transcript's newest user prompt within its last 1 MiB; a prompt with an image or
  several text blocks, one over 256 KiB, or one whose line starts before that window is not resent
  (both actions disabled, `沒有可重送的 prompt`). Whether Claude Code stores a pasted multi-line
  prompt expanded in the transcript is not verified with a real claude.
- RESUME and a picked transcript wait at most 2 s for the registry's first snapshot (it normally
  comes within milliseconds of the launch); the ⌘N sheet's in-use check uses what is known when
  `建立` is pressed. A picked transcript that a stopped CODD session owns resumes that session with
  its own saved options (the sheet's model, profile and name are not applied).
- A session whose first launch could not be built (for example `claude` not on PATH) still shows
  `STOPPED · 可接續` with the `[ERROR] 無法啟動` banner, although it never ran (review e2e-4: the
  two causes it named, an invalid typed model and an unlaunchable profile, are refused or skipped
  now).
- 刪除對話紀錄: a partial failure leaves the moved files in the Trash and the session in CODD (no
  rollback). `daysLeft` counts whole days from the mtime; Claude deletes at its next start.
- A Remote Control start is not remembered for a later RESUME (D22).
- Taken-over sessions still show the M1 note `這個分頁的 holder 已結束…` (inaccurate: the holder
  runs elsewhere); a killed shell shows `Shell 已結束 · code 0` (no exit was recorded).

**Holder and composer**
- A paste over one frame (1 MiB − 3 bytes) reaches the holder as several bracketed pastes; the
  composer's 256 KiB cap keeps real sends in one.
- Old holders (M1, no `input.paste`): the client brackets by the newest modes it was told about,
  which can be stale. An empty paste with `?2004` on queues nothing; with submit the Return goes out
  at once.
- RingFileReader drops the oldest 64 KiB of a live holder's full ring; a reused holder pid costs
  64 KiB needlessly; its memory ordering rests on fences around `pread` (verified by the flood test
  on this Mac, arm64).
- Marked-text styling (amber underline) is drawn by AppKit only while the composer is first
  responder. The composer's state file does an F_FULLFSYNC per save (debounced 500 ms, off main).
- While a shell tab's holder is still spawning the composer shows `session 沒有在執行` for about a
  second.
- While claude's own PTY is WAITING the composer sends nothing, for every reason (permission, plan,
  AskUserQuestion / elicitation): answer with the answer bar (or in the terminal), then send. A
  state change that has not reached CODD yet (hook in flight) is not caught.
- A pasted image's path appears once the file is written (a few ms for PNG, about 120 ms for a 5K
  TIFF): text typed meanwhile lands before it.

**Sidebar, Home, ⌘K**
- Project pinning and a per-project color override (SPEC §2) are not built (not in the M2 plan).
- Quick color 1–8 in the new-group row works with a Latin layout only (注音 composes digits);
  group header hover buttons are mouse-only (the group menu has the same actions).
- A shell row whose OSC title is a long path hides `up n`; on Home the sidebar filter row sits
  about 12 pt higher than with a session shown (older than M2).
- Palette rows are drawn in one view (VoiceOver gets the list, a count and the highlighted title);
  the DONE line shows only the newest done session.
- Wording not in the plan: `◆ 等待輸入 · n` (hover card) and the stop-sheet explanations.

**Panel**
- "On screen" for bells counts a window covered by others or an inactive app as on screen; a tab
  never shown in this run sees no BEL or title change (label, folder and lamp come from meta.json
  and the 1 Hz poll). The lamp needs a shell with job control; the poll pauses while the window is
  away.
- No shortcut or menu item for maximize, no per-tab close button (none in the SPEC / artboards);
  while maximized the strip's fill shows the hidden top terminal's grid.
- An M1 build reading the new panes.json shows only the selected panel tab and adopts the others
  into its main strip (D13). A SHELL session's header chip can overflow into NOTES with a long cwd
  (older than M2).

**New session and Settings**
- The ⌘N sheet is a native sheet at the top of the window with rounded corners (the artboard modal
  is centered and square; the backdrop is drawn).
- The ⌘N profile menu still lists a profile CODD skips at launch (reserved flag, invalid model or
  mode); picking it previews and runs the fallback profile. The problem banner names it once per
  load.
- Home's meta rule shows LIVE, NEEDS YOU, WORKING and EXITED only (the artboard's four parts):
  STOPPED sessions are counted apart and not drawn.
- The account select is a disabled placeholder (D16); mock mode keeps ⌘N disabled; the Settings
  left nav and every section except 通知 and 啟動設定檔 are placeholders; typing a path reloads the
  picker per keystroke (cached, off main).
- `LaunchProfiles.upsert` reports a refusal on a newer profiles.json only through the problem line.

**Robustness and lifecycle**
- With the default timings a SIGSTOPped holder becomes UNREACHABLE after about 45 s (keepalive
  10 s + 30 s, then 5 s). Shell tabs never show UNREACHABLE. Stale clients left in a stopped
  holder's backlog are covered by the one busy retry (500 ms).
- While the window is closed, ⌘1–9 and ⌃Tab switch sessions in the hidden window without opening it.
- Durations in `-codd-snapshot` PNGs taken with a locked screen keep their first draw.

**Carried from M1, unchanged:** hook endpoint DoS by local accounts (SEC-4 residual); sessions
started while the endpoint was ours keep their port; takeover ERROR to a client that stopped reading;
input refused by a child that stopped reading (16 MiB queued) is dropped silently; the C1 form of
OSC 52 is not filtered; the main screen behind a full-screen program is replayed only within 2 MiB;
no watchdog for a paused backlog; notifications under ad-hoc signing untried on screen; DONE vs IDLE
depends on "looking at it". Closed by M2: the problem banner (was `lastError` only logged), ring
replay (was a note), the single-instance lock, UNREACHABLE, ⌘J panel tabs, the full ⌘N sheet.

**Test tooling**
- Test instances share the app's preferences domain `app.fancycodd.CODD` with your own CODD
  (window frame, split view autosave): automated runs write their window frame there, so your next
  launch may open at the default size. A per-data-root defaults suite is left for M5 hardening.
- `layout.json` ids are UUIDs written upper case by CoddCore, while the dump and the fixtures use
  lower case: compare them case-insensitively (the e2e does; the fixtures README now says so).
- Fixture limits (scripts/m2-fixtures/README.md): `FAKE_*` reach the fake claude only through its
  sidecar or a profile environment; `-codd-dump-terminal` wraps long lines (grep `FAKE_LOG_DIR`);
  a fake turn is busy for only about 300 ms; `-codd-shell-argv` is split on spaces; make-root.sh
  checks the port only when it runs. shellcheck is not installed on this Mac (only `bash -n`).

## 6. 手動測試清單（請用真的 claude 與真的 ~/.claude）

先打開 `build/dd/Build/Products/Debug/CODD.app`（或你自己 build 的版本）。這會用你真的資料夾
`~/Library/Application Support/CODD`：第一次啟動會多出 `codd.lock` 與 `profiles.json`（4 個內建設定檔）。
有問題時請附上 STATUS 頁或終端機輸出裡 `REALHOLDERS` 開頭的那幾行。

1. **Hooks 第一次接上真的 claude。** ⌘N 新增一個 claude session，等它變成 IDLE。到 STATUS › HOOKS：
   ACCEPTED 應大於 0、REJECTED 為 0。若 REJECTED 出現 403，請把 LAST REJECTION 的內容給我。
2. **Composer 的注音。** 在 claude session 按 ⌘L 開 composer，切到注音輸入「測試中文」：選字視窗應正常
   出現在游標旁。在還有組字（底線）時按 Enter：應該只是確認選字，**不會送出**；再按一次 Enter 才送出。
   組字中按 Esc 應只取消組字，不會關掉 composer。⇧Enter 換行、↑ / ↓ 叫出上一則 / 下一則。
3. **多行 prompt 與貼上。** 在 composer 打兩三行（⇧Enter 換行），或貼上一段多行文字，按 Enter：claude
   應把它當成**一則** prompt 收到並開始工作（不是每行各送一次，也不是只貼上沒送出）。若 claude 只顯示
   貼上的文字卻沒送出，請告訴我（要調大 50 ms 的送出延遲）。
4. **貼上圖片。** 截一張圖（⌘⌃⇧4 到剪貼簿），在 composer 按 ⌘V：應插入一個 `…/attachments/….png`
   的路徑（空白前有 `\`）。送出後 claude 應把它當成圖片附件讀取。
5. **外部 claude 顯示為 EXT。** 在 Terminal.app 進入一個 CODD 已有的專案資料夾執行 `claude`：側欄該專案
   下應出現帶 EXT 的一列，第二行 `外部啟動`，狀態會跟著 busy / idle / 等待授權即時變化，算進 NEEDS YOU
   與 Dock 數字，但不會跳通知、沒有 `[1 允許]`。在一個 CODD 不認得的資料夾再開一個：它應出現在
   未分類 底下的暫時專案，右鍵有 `加入為專案`。結束 claude 後，那一列與暫時專案都應消失。右鍵 EXT 列
   只有 `複製 session ID`、`複製 resume 指令`、`在 Terminal.app 開啟`。
6. **CODD shell 裡的 claude。** 開一個 SHELL session（或 ⌘T shell 分頁），在裡面執行 `claude`：側欄應出現
   EXT 列，第二行 `在 CODD shell 中`，點開後的 `[前往 shell]` 會帶你回到那個 shell。
7. **接續先前對話（resume picker）。** ⌘N → 選一個你常用的專案 → 開始方式選 `接續先前對話`：清單應列出
   這個資料夾過去的對話，標題（自訂標題 > AI 標題 > 第一句 prompt）、分支、大小、幾天前都對；快到期的
   顯示 `! resume N 天後過期`；正在 Terminal.app 或 CODD 裡跑的那段顯示 `執行中` 且不能選。按複製圖示
   後貼上，應是完整的 session id。選一段按 `建立 ⌘⏎`：claude 應接續那段對話。
8. **刪除對話紀錄。** 找一段不要的舊對話，先在 CODD 用 resume 開起來再停止，然後右鍵 `刪除對話紀錄…`，
   輸入名稱確認：該 session 從 CODD 消失，`~/.claude/projects/<資料夾>/<id>.jsonl`（和同名資料夾）出現在
   Finder 的垃圾桶，可以「放回原處」。其他對話不受影響。
9. **側欄。** 拖曳專案到另一個群組（琥珀色插入線、目標區塊顯示 `移入`）；在 session 列停約 0.4 秒出現
   hover 卡片（拖曳中或選單開著時不應出現）；`[+ 新增群組]` 的行內輸入列與顏色（英文輸入時 1–8 快速選色，
   注音組字時 Enter 只確認選字）；群組標題 hover 時的 `清理已停止 (n)` · `+` · `⋯`；封存後倒數 5 秒的
   Undo，以及專案右鍵 `封存 n ▸` 還原；TREE | STATE 切換，閒置超過 1 小時的列變淡、Idle 標題顯示 `n stale`；
   篩選框輸入專案名，NEEDS YOU 與 PINNED 也只剩符合的。
10. **⌘K。** 按 ⌘K 輸入 session 標題或專案名的一部分：結果分成 Sessions / Projects / Actions，⏎ 開啟，
    ⌘⏎ 開啟並打開下方終端機（不會變成「允許」），esc 關閉。注音組字時排名不應亂跳。
11. **快捷鍵（注音輸入法開著時也要試）。** 焦點分別在終端機、側欄、composer 時：⌘1–9、⌃Tab、⌘\、⌘L、
    ⌘P（釘選）、⌘.（停止，會先問 `要停止「…」嗎？`）、⌘⏎（有 session 在等授權時才有作用）都應照常運作。
12. **下方終端機分頁。** ⌘J 開下方終端機，按 `+` 再開一個分頁。在其中一個執行 `npm run dev` 或
    `sleep 30`：分頁出現綠色 `●`，回到提示字元後消失。在另一個分頁跑 `sleep 3; printf '\a'` 後切走：
    該分頁出現琥珀色 `◆`，切回去就消失。若你的 zsh 主題會設定終端機標題，分頁名稱應跟著變（最多 24 字）。
    按最大化，再還原；最大化時 ⌘Q 再開 CODD：應恢復最大化，而且是同一批 shell。
13. **啟動設定檔。** 設定（⌘,）› 啟動設定檔：`+ New profile` 新增一個（在額外參數試 `--session-id`，
    應出現錯誤訊息），編輯、複製（名稱 `… 複本`）、刪除（最後一個 claude 設定檔不能刪）。⌘N 的設定檔
    選單與指令預覽應立刻反映。
14. **錯誤橫幅的動作。** 當某個 session 失敗（例如 claude 回報 overloaded）出現錯誤橫幅時：
    `↻ 重送上一則` 應把最後一則 prompt 再送一次；`⟲ 稍後自動重試` 應倒數 60 秒後自動重送，再按一次取消。
    沒有已知 prompt 時兩個按鈕都是灰的（提示 `沒有可重送的 prompt`）。請用一則超過 200 字、有多行、
    最後一句是限制條件的 prompt 試：重送的內容應與原本**完全相同**（多行、最後一句都在）；重開 CODD
    之後再試一次（這時從對話紀錄讀取），內容也應完整。
15. **Home。** 點側欄上方回到 Home：NEEDS YOU 卡片（只有 CODD 的授權等待才有 `[1 允許]`）、完成待看那一行、
    LAUNCH 最近專案卡片（`+ Claude` / `+ Shell`）、RECENTLY STOPPED（含可接續的舊對話）、USAGE（標示
    `示意資料`）。`Profile · … ▾` 可切換預設設定檔。
16. **第二個 CODD。** CODD 開著時（主視窗可以先關掉），在終端機執行
    `open -n build/dd/Build/Products/Debug/CODD.app`（要加 `-n`；從 Finder 點兩下只會切回原本那個）：
    第二個應立刻結束、不出現視窗，原本那個被帶到最前面並顯示主視窗。
17. **關閉視窗與重新打開。** 關掉主視窗：CODD 仍在 Dock 與選單列上，session 繼續跑。點 Dock 圖示、或選單列
    的 `開啟 FANCY/CODD`：主視窗回來，終端機畫面是最新的。
18. **⌘Q 後 session 繼續跑。** 有 claude 正在工作時按 ⌘Q，`pgrep -lf codd-holder` 應仍看得到 holder；
    重新打開 CODD 後同一個 session 自動接回，輸出沒有斷。
19. **UNREACHABLE。** 對某個 session 的 holder 執行 `kill -STOP <holderPid>`（pid 在 STATUS 或
    `pgrep -lf codd-holder`），約 45 秒後該列顯示 `Unreach`、標題列 `◌ UNREACHABLE`、橫幅有 `[↻ 立即重試]`；
    `kill -CONT <holderPid>` 後約 10 秒內（或按立即重試馬上）恢復，session 不會變成已停止。
20. **holder 被砍掉的 session。** 對一個 shell session 的 holder 執行 `kill -9 <holderPid>`，重開 CODD
    再點那個 session：應看到它最後的畫面，最下面一行淡色的 `// holder 已結束 · 以上是最後的畫面（唯讀）`，
    鍵盤輸入不會送到任何地方。
21. **Claude 在等授權時的 composer。** 在 claude 工作中先用 ⌘L 打好一段話，等它跳出授權（WAITING）：
    composer 右下應顯示琥珀色 `Claude 在等你確認 · 先用下方按鍵回答`，SEND 變灰，按 Enter 只會嗶一聲、
    文字保留。用下方 `[1] [2] [3]` 回答後，就能正常送出。
22. **注音組字中切換 session。** 在 composer 用注音打到一半（底線還在）就按 ⌘1 / ⌘2 切到別的 session
    再切回來：草稿裡不應出現沒選字的注音符號。

## 7. Decisions taken (all reversible)

### The plan's decisions as implemented

| # | As implemented |
|---|---|
| D1 | Holder `input.paste` (INPUT bit1, always in WELCOME caps), bracket only when the child has `?2004`, markers stripped, Return 50 ms after the paste (`Holder.pasteSubmitDelayNanoseconds`); client brackets for holders without the cap; a paste sent before WELCOME waits for it, and later input waits behind it. |
| D2 | As planned, plus U+2028 / U+2029 / NEL → newline and C1 controls stripped (U+009B is CSI for 8-bit parsers). |
| D3 | As planned; drafts and history load lazily off main, saves are debounced 500 ms on one queue and flushed at quit; history entries are capped at 16 KiB each. |
| D4 | As planned; the PNG is written synchronously (no fsync) so the path exists before any send; a missing session folder is never created. |
| D5 | As planned; profiles.json is written with the built-ins on the first launch of this build (also on your real root); a corrupt file is moved aside and re-seeded, a newer one is read-only; the layout row records the profile that ran; copies are `<name> 複本`. |
| D6 | As planned; ownership = child pids of live claude holders, current and initial Claude session ids, claude holder pids; a stopped session counts as ours only while its holder may still run. |
| D7 | As planned; the cursor is hidden after the footer; a replayed engine is rebuilt before a new process attaches; RingFileReader skips the overwrite drop for a holder that provably ended. |
| D8 | As planned; the outage clock starts at a drop or the first connect attempt; UNREACHABLE overrides the state style everywhere; `[↻ 立即重試]` skips the backoff or a pending handshake. |
| D9 | As planned; a lock that cannot be created at all is an alert and an exit (never unlocked); a second instance waits up to 300 ms for a starting owner's record. |
| D10 | As planned; occlusion follows `isVisible && !isMiniaturized` (a covered window or a locked screen keeps rendering); coddd stays deferred (ARCHITECTURE.md). |
| D11 | As planned; closing the panel keeps its tabs running; ⌘W in the panel (or while maximized) closes its shown tab; strip actions restore from maximize. |
| D12 | As planned; "on screen" = shown in a slot the pane does not hide while the window is not closed, miniaturized or hidden. |
| D13 | As planned; decoding is tolerant per field and per tab entry. |
| D14 | As planned; ⏎ on a project opens its latest session, ⌘⏎ its shell; `+ 加入` adds a `.claude.json` folder; the palette stays live while open. |
| D15 | As planned; `-codd-stale-after <s>` also sets the recheck to min(60, s). |
| D16 | As planned (disabled `跟隨全域登入`). |
| D17 | As planned; the pace line comes from the account source's forecast (`weekExhaustsAt`). |
| D18 | As planned; five spellings of the folder are tried (typed, standardized, URL-standardized, realpath, realpath standardized); long names use Claude's hashed form. |
| D19 | As planned (`封存 n ▸`, `還原「…」`, `全部還原`). |
| D20 | As planned; the hover card sits 10 px right of the sidebar's edge (the caption) rather than where the artboard draws it. |
| D21 | As planned. |
| D22 | As planned (not remembered for RESUME). |
| D23 | As planned; no rollback after a partial failure. |
| D24 | As planned; the search starts at a random port of 43000–43999. |
| D25 | As planned, also for SHELL sessions' own PTY; only while the shell's parent is still its holder. |
| D26 | As planned; both actions are disabled when no prompt is known. |
| D27 | As planned. |
| D28 | As planned; the notification object is the realpath of the data root. |
| D29 | The sidebar footer note is on a second line (no room at 280 pt); mock mode shows `· cswap 0.26.0`. |
| D30 | Extended: `預設 (<x>)` names the profile's own default model first, then settings.json's `model`. |
| D31 | As planned; file URLs paste before text. |

### Added by the components and steps

- **C1:** Claude's exact folder name for long paths (hash read from the installed bundle); one row
  per session id (newest file wins); `files()` returns the sibling folder only when the .jsonl matched;
  cache of 2048 files (drops the oldest quarter); title / prompt cleaning and caps (200 / 80 / 200);
  `model` ≤ 128 characters; external names cleaned, a repeated pid listed once; lenient profile
  decoding (a wrong-typed entry is skipped whole) and normalization (a claude profile always
  exists; a shell profile may be the default); `save` never normalizes and never overwrites a newer
  file; environment parsing accepts `export` and one pair of quotes; arguments formatted zsh-safe;
  `commandPreview` mirrors `LaunchBuilder` exactly; word starts exclude camelCase.
- **C2:** shared `RingResync.replayPoint` (with an underflow guard for damaged tables); one-pass
  marker stripping; `BracketedPaste.wrap` never sends an empty bracket; `pread`, never mmap; the
  resync table accepted only when two copies agree; up to 4 retries when a new holder restarts the
  ring; unused reserved bytes returned to the outbound budget; lenient ATTACHED peek; `codd-holderctl
  ring` key=value output (exit 2 = no ring).
- **C3:** Return while composing commits instead of calling NSTextView (which would delete the
  composition); TextKit 1; fixed 19 pt line height and amber selection; own UndoManager per text
  view; overlay scrollers only; file URLs before text on paste; ⌘⏎ / ⌃⏎ as insertNewline are
  ignored (a disabled 允許 never becomes a send); CR / CRLF normalized to LF in the view; history
  equality ignores the walk cursor; oversized state files ignored.
- **C4:** a pure-Python fake claude (pid = the spawned one); sidecar `.env` configuration;
  registry file written before the DA1 probe; quiet without a hook URL; `FAKE-CLEAR`; `procStart`
  in the C locale and UTC; writing scripts refuse `~`, `~/Library`, `~/.claude`; detached external
  dummies that remove their own file on TERM / HUP / INT; realistic transcript openings (`/clear`
  caveat lines, a snapshot line without cwd).
- **I1:** random-pivot test port range (also when repairing config.json); the second-instance
  object = realpath; UNREACHABLE clock from the outage start; `retryNow` keeps the attempt counter;
  reconnect delays moved into `PtyConnectionTuning`; ring replay hides the cursor; window occlusion
  as a hub flag apart from pane slots; the confirm sheet's 關閉視窗 calls `close()`; Home's problem
  banner moves the scroll view instead of collapsing; shell-tab spawn failures become problems.
- **I2:** ownership rule above; `project(forPath:)` falls back to a realpath match for every
  project (a symlinked spelling joins the real folder's project); transient projects keep the
  standardized cwd, cannot be removed / renamed / dragged and sort last; first-start seeding of
  profiles.json; profiles read before `isLoaded`; `ClaudeLaunchOptions.profileID` optional; shell
  sessions record the first shell profile; a pre-chosen id counts as taken when any row, session,
  registry entry or session folder has it; resume ids validated; `deleteHistory` async → Bool;
  `SessionVM.external` computed from `externalInfo`; mock store ignores externals in every intent;
  ⌘W on an external beeps.
- **I3:** hover card rules (switch immediately between rows once shown; hidden after a click,
  during menus, drags and key loss); drag hint only where reordering is possible; new-group editor
  details (popover starts closed, digits 1–8 / 0, default color = first unused, blank name =
  `新群組`, focus loss creates a typed name); `清理已停止` counts CODD sessions only; countdown toast
  look for archives only; stop always asks; drawn drop line instead of the native gap; native menu
  badges `執行中` / `需輸入名稱確認`; STATE line 2 rules; filter semantics; sidebar flags in mock mode.
- **I4:** footer note on a second line; send bound to the target the bar was pointed at;
  `heldInputLimit` 320 KiB; composer status rules (busy hint, read-only when not live, too long kept);
  lazy drafts with queued edits; synchronous image writes; resend always paste + submit to the
  session's own PTY; empty-query palette order and contextual actions; live palette; `⌘J 終端機` in
  the strip as plain text (artboard); mock Home transcripts and mock fake-terminal echo.
- **I5:** closing the panel keeps tabs; maximize restore rules and focus moves; the split is laid
  out before hiding the top terminal (keeps its restore size); label rules (`zsh n` in the panel,
  `zsh` for the strip's first tab); title cleaning; panel strip fill = the tab's OSC 7 folder; lamp
  for never-shown tabs from meta.json; accessibility text `，執行中` / `，響鈴`; tolerant panes.json
  decoding; splitter drawn per the Split artboard; tab buttons rebuilt only when the set changes.
- **I6:** the ⌘N sheet stays a native titled sheet with a dim backdrop; D30 extension; permission
  follows the chosen profile (an explicit `default` over a profile mode); name handling for picked
  transcripts; 1–8 color keys when no field has focus; default folder rules; list limits 8 + 5
  (20 + 10 with a query); `+ 加入` vs clicking the suggestion; a changed folder drops the old pick;
  `! resume 即將過期` for 0 days; the Settings preview's sample options; account meta `跟隨全域`;
  editor id slugs, a `Shell 路徑` field, `設為預設` cannot be switched off on the default; copies
  `<name> 複本`; Settings window 1040×720, resizable; InputField restyled to the artboard `.input`.
- **I7 (this step):** the e2e runs on four data roots in one temp folder with per-root Claude
  directories; R6's project folder is named `claude-lab` so that the query `claude` is part of both
  the session's learned title (`fake claude m2`) and its project's name (the palette lists a project
  only when the query matches the project); R5 checks `lastPrompt` against the D20 one-line form
  (`第一行 第二行`); layout.json ids are compared case-insensitively; R3 compares the mtimes of
  layout.json, config.json and panes.json around the second instance; the R10 run proves "keeps
  running" by the window-closed dump while the process is alive plus a quit at its quit-after.

### Added by review round 1 (§9)

- **Resend is whole or nothing:** the hook's prompt as sent, else the transcript's newest prompt
  read uncut; never the display form, never an older prompt, never a part. D26's "disabled when no
  prompt is known" now also covers "known only in short".
- **The composer refuses every WAITING reason** on claude's own PTY, AskUserQuestion included
  (its options take digits too); the plan's optional exception for questions was not taken.
- **One conversation, one CODD session:** a picked transcript a stopped CODD session owns resumes
  that session (its saved options); an archived owner is refused (restore it first).
- **Registry readiness:** RESUME and 刪除對話紀錄 wait at most 2 s for the first registry snapshot;
  刪除對話紀錄 refuses on a timeout, RESUME proceeds with what is known.
- **Unlaunchable profiles are skipped, not repaired:** profiles.json is never rewritten for them;
  the launch takes the first launchable claude profile, else the built-in `claude-default`.
- **profiles.json is read-only until read, and after a failed read** (not only when newer).
- **⌘N list:** 5 + 3 rows without a query (SPEC §7.5); the `+ 選擇資料夾… ⌘O` footer is pinned.
- **Settings preview sample model:** Claude's settings model, else the artboard's `opus-5.5`.
- **Home meta rule:** STOPPED is not part of `✕ n EXITED` and is not drawn (four parts as in the
  artboard).
- **Transcript reads:** the list limit counts listed conversations, with a read bound of
  `limit * 4 + 64` files; resend reads use a 1 MiB tail, uncached.
- **realpath failures** are cached for 30 s; project folders are resolved off the main actor.
- **Running lamps** are polled for the shown session only.
- **Pasted images:** the path is inserted after the file is written (off the main actor); after a
  session switch it goes to the end of that session's draft. A file name with a line break or
  another control character is refused.

## 8. Fixes made in this step

No suite and no e2e run exposed a bug in App/ or the packages, so nothing there changed. What
changed:

| Change | Why |
|---|---|
| `scripts/m2-e2e.sh` (new, executable) | The M2 end-to-end run (§3): 13 scenarios, 110 checks, cleanup by `pkill -CONT/-TERM/-KILL -f "<tmp>/"` only. |
| e2e: layout.json id checks case-insensitive | The first run failed 3 checks (archived row, collapsed project, profile id in layout.json): CoddCore writes UUIDs upper case, the dump and the fixtures lower case. A check bug, not a product bug. |
| `scripts/m2-fixtures/README.md`, `seed-layout.sh` header | Note that the app writes the seeded UUIDs back upper case (compare case-insensitively); no behaviour change, selftest still 245/245. |
| docs/ARCHITECTURE.md | Final M2 pass: decisions, repository layout (CoddComposer, scripts/m2-fixtures, m2-e2e.sh), data root tree (composer.json, attachments/, panes.json keys, layout.json notes), held input 320 KiB, the M2 app sections (sidebar / Home / ⌘K, composer, panel tabs, new session and profiles, testing hooks), the state model (no `claude agents --json`, overlays). The holder sections (C2's) were already consistent. |
| CLAUDE.md | Build / test lines: the CoddComposer test command, the e2e and fixture scripts, make-root.sh for manual runs. |
| docs/M2-REPORT.md | This report. |

## 9. Review round 1 fixes (2026-10-17)

A review of the M2 tree (concurrency / performance, correctness, security / data, end to end, spec
fidelity) confirmed 26 problems (25 distinct: correctness-1 and security-data-2 are one defect).
All were fixed in this round, most severe first; each has a regression test unless noted. Nothing is
committed (the orchestrator commits after the milestone).

| ID | Sev. | Problem | Fix | Regression test |
|---|---|---|---|---|
| correctness-1, security-data-2 | high | `↻ 重送上一則` / `⟲ 稍後自動重試` resent the display form of the prompt: one line, cut at 200 code points (the transcript fallback ending in `…`), so a final constraint such as `不要刪 db/` was lost | Display and resend are separate. `HookPipeline.resendablePrompt` keeps the hook's `prompt` whole (`SessionVM.resendPrompt`, nil above one composer send, 256 KiB); the fallback is `TranscriptCatalog.resendablePrompt`, the newest user prompt read uncut from the last 1 MiB (nil for an image or several text blocks, never an older prompt); when the hook gave only a display form nothing is resent; the pane keys transcript reads by failure (`stateSince`), so an earlier failure's prompt is never reused | `ErrorBannerActionTests.resendNeverSendsTheShortenedDisplayForm`, `resendSendsTheLastPromptAsAPaste` (updated); `TranscriptCatalogReviewFixTests.resendablePromptIsTheWholeNewestPrompt`; `M2ReviewSessionFixTests.resendPromptFallsBackToTheWholeTranscriptPrompt`; `TranscriptServiceTests.userPromptSubmitSetsTheLastPrompt` (whole prompt kept) |
| security-data-1 | high | Composer Enter while claude showed a permission / plan / question prompt wrote the text and a Return into the dialog (`2…` = always allow, Return = the default) | `PaneComposer` refuses every send while the target is claude's own PTY and the session is WAITING, checked at bind time and again at the send; status `Claude 在等你確認 · 先用下方按鍵回答` (amber), SEND disabled, the draft stays editable. A shell tab of the same session still sends | `ComposerTests.composerRefusesToAnswerAWaitingClaude` |
| concurrency-perf-1 | medium | Visible idle CPU about twice the 0.5 % budget; §4's "visible: the same" was measured with the screen locked (the 1 Hz clock stops when occluded) | The header's ticking parts (state chip, meta line with `UP x`) are drawn in their own transparent layers (`HeaderPartView`), so the 1 Hz tick no longer redraws the glowing title; a chip that changes width lays the line out again. §4 re-measured with `-CODDForceVisibleTimers YES`; the remaining miss is listed in §5 | `M2ReviewPaneFixTests.aTickRedrawsOnlyTheTickingParts` (what a tick invalidates) |
| correctness-2 | medium | RESUME (and a picked transcript) never checked whether another claude ran the conversation: two `claude --resume <id>` appended to one transcript | `isConversationRunning` (a live CODD claude session other than the one asked for, or any live registry entry); `resume(_:)` refuses with a problem, waiting for the registry's first snapshot if needed; `createSession(.resume)` refuses a running conversation and turns a transcript a stopped CODD session owns into a RESUME of that session (an archived owner: refused, restore first) | `M2ReviewSessionFixTests.resumeRefusesAConversationAnotherClaudeRunsAndAPickedTranscriptResumesItsSession` |
| e2e-1 | medium | Resume picker empty when the folder's 50 newest files were `sdk-*` / other-cwd runs | `TranscriptCatalog.list` reads newest first until `limit` conversations are listed (at most `limit * 4 + 64` files opened); the resume title lookup uses the new `transcript(sessionId:cwd:)` | `TranscriptCatalogReviewFixTests.newerSDKRunsNeverHideResumableConversations`, `transcriptByIdFindsAnOldConversation`; `newestFirstAndLimit` unchanged (3 reads for 3 rows) |
| e2e-2 | medium | Uncommitted 注音 composition (marked text) was saved into composer.json, and a session switch during a composition leaked it into the newly shown session's draft | `ComposerTextView` reports only committed text (`committedText`): no report from inside AppKit's marked-text calls (the marked range is stale there), one after them, one when a composition is committed (`unmarkText`); `setText` (programmatic) reports nothing | `ComposerMarkedTextDraftTests` (3 tests) |
| spec-fidelity-1 | medium | ⌘N project list hid `+ 選擇資料夾… ⌘O` and suggestions below the 300 pt fold (8 + 5 rows) | 5 recents and 3 suggestions for an empty query (SPEC §7.5); the dashed separator and `+ 選擇資料夾… ⌘O` are a footer pinned outside the scroll view (`ProjectDropdownListView.footer`), so a 20 + 10 filtered list scrolls above it | `M2ReviewNewSessionFixTests.theChooseFolderRowStaysVisibleUnderAnyNumberOfRows` |
| concurrency-perf-2 | low | The hover card read an external's transcript prompt once per run | Cached per (state change, conversation), like the read-only pane; a cancelled read records nothing | `HoverCardTests.transcriptPromptIsReadAgainAfterAStateChange` |
| concurrency-perf-3 | low | Pasting a big TIFF re-encoded it and wrote the file on the main thread (about 120 ms for 5K) | `onPasteImage` hands over `ComposerPastedImage` (PNG / TIFF) unconverted; `ComposerStates.saveAttachment` re-encodes (ImageIO) and writes off the main actor; the path goes in once the file exists (at the caret, or at the end of that session's draft when the field moved on) | `ComposerTextViewTests.tiffIsConvertedOffTheMainActor`; `ComposerTests.pastedTIFFIsConvertedOffTheMainActorAndFollowsItsSession`, `pastedImageIsSavedAsAPrivatePNGAndInsertedEscaped` (updated) |
| concurrency-perf-4 | low | Any shell tab's OSC title change re-ran the shown pane's `render()` | Titles and folders live in one `@Observable` `ShellTabFacts` per tab: the pane tracks only its own tabs (`tabTitles` / `tabCwds` stay as read-only views for the dump and tests) | `TabTitleObservationTests.aTitleChangeInvalidatesOnlyReadersOfThatTab` |
| concurrency-perf-5 | low | `project(forPath:)` called realpath on the main actor for every project on every lookup; failures were never cached | Failures are cached for 30 s (`realpathRetry`); project folders are resolved off the main actor after the load and when a project is added (`prewarmProjectPaths`) | `M2ReviewSessionFixTests.projectLookupCachesFoldersThatDoNotResolve` |
| concurrency-perf-6 | low | The D25 lamp poll read every shell CODD knows | Only the shown session's shells (strip, panel, its own PTY); polled again at once when another session is shown | `PanelTerminalTests.runningLampFollowsForegroundJobs` (extended: another session shown, 0 shells read) |
| concurrency-perf-7 | low | A dead session's ring (up to 8 MiB) was OSC 52 filtered and copied on the main actor | `PreparedReplay` (CoddTerminal) filters and copies off the main actor; the main actor checks the guards and hands the buffer over (`TerminalEngine.replay(_: PreparedReplay)`, O(1)) | `ReplayClipboardFilterTests.preparedReplayIsTheFilteredHistory`; e2e R8 |
| concurrency-perf-8 | low | `ComposerStates.forget` was never called | `TerminalHub.onSessionDeleted` → `PaneComposer.forget` (state, queued edits, pending save; a late read or edit does not bring it back) | `ComposerTests.forgetDropsARemovedSessionsComposerState` |
| correctness-3 | low | An invalid `其他…` model (`opus 4`, `-x`) created a saved session that could never launch | `NewSessionForm.problem` and `createSession` check it with LaunchBuilder's rule (`LaunchProfileEditing.isValidModel`) before anything is written | `M2ReviewSessionFixTests.anInvalidModelIsRefusedBeforeTheSessionIsSaved`; `LaunchProfileReviewFixTests.typedModelsFollowLaunchBuildersRule` |
| correctness-4 | low | A profile edit before profiles.json was read saved the built-ins over the user's profiles; a failed read left them editable | Edits are refused until the file is read (`啟動設定檔還在讀取，請稍候再試一次。`); a failed read (EACCES, EIO) is read-only; Home's Profile pill and Settings follow `canEdit` / `editRefusal` | `M2ReviewNewSessionFixTests.profileEditsWaitForTheFileAndNeverReplaceAnUnreadableOne` |
| security-data-3 | low | A dropped / pasted file whose name has a line break was inserted raw (a shell tab would run the rest as a command) | `ComposerPaths.isInsertable`: a name with LF, CR, NEL, U+2028 / U+2029 or another control character but TAB is refused with a beep (handled, so no fallback to the name as text) | `ComposerPathsTests.controlCharactersAreNotInsertable`, `ordinaryPathsAreInsertable`; `ComposerTextViewTests.aDroppedFileWithALineBreakInItsNameInsertsNothing` |
| e2e-3 | low | The 刪除對話紀錄 in-use guard was empty until the first registry snapshot | `waitForRegistry` (first snapshot, at most 2 s; true at once without a hook pipeline); `deleteHistory` waits and refuses on a timeout; the DEBUG resume request waits too | `M2ReviewSessionFixTests.inUseChecksWaitForTheFirstRegistrySnapshot` |
| e2e-4 | low | A profiles.json default with a reserved argument made every new claude session fail (`STOPPED · 可接續` rows that never ran) | `LaunchProfileDocument.claudeProfile(id:)` skips profiles `LaunchBuilder` would refuse (`LaunchProfileEditing.launchIssues`: reserved flag, invalid model or mode) and falls back to a launchable one, else the built-in default; the profile stays listed for the editor and a problem names it | `LaunchProfileReviewFixTests.unlaunchableProfilesAreSkippedWhenALaunchPicksOne`; `M2ReviewNewSessionFixTests.anUnlaunchableDefaultProfileIsReportedAndSkipped` |
| spec-fidelity-2 | low | Dropdown head read `建議 · 來自 ~/.CLAUDE.JSON` | The path is drawn without the caps transform (`.ns-nt`) | none (drawing); checked in the mock snapshot below |
| spec-fidelity-3 | low | `刪除對話紀錄…` was offered for SHELL sessions (and its toast claimed a transcript went to the Trash) and for a conversation another claude runs | Enabled only for a claude session that is not running and whose conversation no other claude runs (badge `執行中` then); the confirm sheet refuses a shell | `SidebarShortcutTests.sessionMenuFollowsArtboardB` (extended) |
| spec-fidelity-4 | low | Mock ⌘K never showed the PROJECTS `未加入 · 來自 ~/.claude.json [+ 加入]` row | Mock mode passes `MockData.claudeJsonProjects` to the palette, as the ⌘N sheet does | none (AppDelegate wiring); checked in the mock snapshot below |
| spec-fidelity-5 | low | Mock s3's error banner had both D26 actions disabled | Mock s3 has the prompt its terminal shows (`lastPrompt` and `resendPrompt`) | `M2ReviewPaneFixTests.mockErrorBannerOffersBothActions` |
| spec-fidelity-6 | low | Home's `✕ n EXITED` counted STOPPED sessions | `SessionCounts.exited` is EXITED only (`stopped` counted apart, not drawn: the artboard has four parts) | `M2ReviewPaneFixTests.homeMetaRuleCountsOnlyExitedSessions` |
| spec-fidelity-8 | low | Settings › 啟動設定檔 preview lacked the artboard's `--model opus-5.5` | The preview adds Claude's settings model, else the artboard's sample `opus-5.5` (a profile with its own model shows that one) | `ProfileSettingsTests.rowsShowCommandsMetaAndTheDefaultPreview` (updated) |

Also changed: `App/Debug/ShortcutMatrix.swift` (DEBUG): its `composing` step committed its own test
composition with `unmarkText()` before clearing the field, which put `ㄅㄚ` into the session's saved
draft by itself; it now only sets the field's text (which drops the composition, as a session
switch does). ARCHITECTURE.md describes the new rules (transcripts and resend, one conversation one
claude, the composer while WAITING, image saving, tab facts and the lamp poll, the ⌘N list,
profile rules).

**Verification beyond the tests** (fresh temp roots, fake claudes, every process ended):
- e2e-1 repro (6 fixture transcripts, 4 resumable, plus 60 newer `sdk-cli` runs): `NEWSESSION
  picker … count=4`, the dump's `resumePicker` has 4 rows (was `count=0`, `[]`).
- e2e-2 repro (`-codd-shortcut-matrix YES` on a fake claude and a shell): every `composer.json`
  has `"draft":""` (was `"ㄅㄚ"`); `SHORTCUTS ok=67 fail=0`.
- Mock snapshots: the ⌘N list shows 5 recents, 3 suggestions, `建議 · 來自 ~/.claude.json` in lower
  case and the `+ 選擇資料夾… ⌘O` footer; ⌘K `打卡` lists SESSIONS 1, PROJECTS 1 (`未加入 · 來自
  ~/.claude.json [+ 加入]`), ACTIONS 2; s3's banner has both D26 actions enabled; Settings ›
  啟動設定檔 previews `… --model opus-5.5 --permission-mode acceptEdits -n "修正登入 API 4…`.
- Visible idle CPU before / after: §4.

**Not fixed in this round (see §5):** visible idle CPU is still over the 0.5 % budget while
durations count seconds (halved); a session whose first launch could not be built still reads
`STOPPED · 可接續` (its two reported causes are now refused or skipped); the stalled-network-mount
hang (concurrency-perf-5) is reduced, not removed: a path seen for the first time is still resolved
on the main actor; Release visible idle CPU was not measurable on this locked Mac.
