# CODD Desktop: M5 report

Written 2026-10-19 after integration step I4 (end to end, docs, this report). M5 = hardening and
release (docs/M5-PLAN.md): CODD Desktop 1.0. A new user gets a first-launch wizard (the frozen
Onboarding artboard: detect the environment, import projects from `~/.claude.json` read only, tidy CODD
web's legacy hooks through the M3 Hook 差異 dialog, the fixed notes location and the M4 MCP
registration, the cswap accounts, the notification permission); existing users are never interrupted
and can reopen it from Settings › 關於 and 說明. The app has its final identity (`app.codd.CODD`, user
decision 2026-10-18) and copies its own window / split / menu bar positions over once. Every JSON file
CODD owns has a version and one launch preflight looks after them (newer files are never overwritten,
corrupt user data is moved aside with a banner, `cache/` is rebuilt on a version change). The
performance budgets have a measuring script, the hot terminal tier resists scans, the current client
has a compatibility script against the M1 and M4 holders, `scripts/release.sh` builds / signs / zips /
installs a Release, VoiceOver and Full Keyboard Access cover the custom views with an automated audit,
a copy audit checks every string, every e2e script fails when a CODD window rises above your windows,
and a stop pressed while a session is STARTING now works. This report covers the nine components, the
four integration steps, how to run everything, the numbers, what is not done and what to try by hand.

**Status (read this first):**
- **Fix round 1 (2026-10-19, §11):** the wrap-up test run's failures (7 package suites, 7 app tests,
  `scripts/m4-sidebar-dnd.sh` D4, `scripts/m5-e2e.sh` D2 / S1 / A1, `scripts/m5-perf.sh` launch and idle
  visible) and the review's findings (onboarding group keys after ↻, panes.json on a new root, the probe
  swallowing the Dock click, `release.sh --output /Applications`, the catalog on test roots, three
  onboarding layout cuts) are fixed; §11 has the table, what ran and what is left. The status lines
  below are I4's.
- **Built, compiled, not yet tested as a whole.** The user asked for each stage to be finished before
  anything is tested or reviewed (「今晚繼續做，但要記得不要過度測試」), so every component and every
  integration step of M5, this one included, only compiled. One test run after this step runs
  everything (every package suite, the app tests, every e2e script once, the fixture self tests,
  `scripts/m5-perf.sh`, `scripts/m5-compat.sh`, the release dry run) and its failures go to a fix agent;
  §3 lists the exact commands. **None of §3's "pending" rows has a result yet, and `scripts/m5-e2e.sh`,
  `scripts/m5-perf.sh` and `scripts/m5-compat.sh` have never run.** About 250 new tests were written
  (80 CoddOnboarding, 43 CoddDataStore, 15 in the store guards, 33 CoddUI, the seven UI packages' audit
  tests, 13 tier policy, 50 app tests in 21 suites); none has run. Treat this report's behaviour statements
  as the design and the step reports, not as verified facts, until §3 is filled in.
- **Builds (this step):** Debug `build-for-testing` (derived data `build/m5`, every target including all
  app test files): `** TEST BUILD SUCCEEDED **`, zero `warning:` and zero `error:` lines. Release through
  `scripts/release.sh --output <scratchpad>/rel`: `** BUILD SUCCEEDED **`, zero warnings, signed, verified
  and zipped in 128 s (§4), then deleted. `scripts/release.sh --dry-run` and `python3 -I
  scripts/tools/copy-audit.py` (`COPY findings=0 failing=0 review=0 allowed=495`) are clean.
- **On your real data root, the first 1.0 launch** (once installed): no wizard (your root is not new);
  the window frame, the split and the menu bar item position are copied once from the old bundle id's
  defaults (log `defaults migrated from=… keys=<n>`); the data preflight checks every file (they are all
  version 1, nothing is moved unless it is unreadable by its own store) and writes `cache/VERSION`
  (`1`; the existing notes index is kept); macOS asks again for the notification permission and for
  folder access; 登入時啟動 must be switched off and on once (D4 hint). Nothing else changes.
- **Not verified with the real thing:** no real claude, cswap, `~/.claude.json` or `settings.json` in the
  wizard; no real VoiceOver or Full Keyboard Access session; `--install` never ran (it refuses inside
  Claude Code by design). §6 is the 繁體中文 checklist for you.
- **Questions for you** (§7, end): the GPU budget change, what ⌘Q in the middle of the wizard should do,
  the new copy (§8), `release.sh --install`, the proposed CLAUDE.md lines (§10).

---

## 1. What was built

### Components (parallel, outside App/; compile only)

| Key | What | Main paths |
|---|---|---|
| onboarding | Package CoddOnboarding: `CoddOnboarding` (Foundation only: the six-step flow, the boot block report, `ProjectCatalogReader` over `.claude.json` read only (≤ 64 MiB, ≤ 2,000 keys, worktree / SDK hidden, last use from transcript mtimes), the D9 group suggester, the import selection and plan, `OnboardingGate`, `OnboardingStateStore` for `onboarding.json`, samples of the artboard) and `CoddOnboardingUI` (`OnboardingView` drawing the frozen artboard by hand, every length through UI zoom), `codd-onboarding-demo` (offscreen PNGs of each step at 1440 × 900 and 1011 × 640); 80 tests; `scripts/m5-fixtures/make-import-fixture.sh` (made-up projects, `.claude.json`, transcripts) | `Packages/CoddOnboarding`, `scripts/m5-fixtures` |
| datastore | Package CoddDataStore: the inventory of every JSON file with its store's own load rules, `DataPreflight` (`run` / `scan`, backups before migrations, aside / remove / report / wipe, `asideFiles(createdSince:)`), `VersionGuard`, `DefaultsDomainMigration`; 43 tests. Store guards: `ComposerStateFile` writes `"v":1` and refuses to overwrite a newer file, `BackupsIndex` keeps a newer index, `HookConfigStore` uses a newer `config.json` as it is and refuses to rotate / repair it | `Packages/CoddDataStore`, CoddComposer, CoddClaudeSettings, CoddHooks |
| ui-core-a11y | CoddUI: `KeyboardFocus` (Full Keyboard Access rule, overrides for tests), `KeyboardFocusTracker` (the helmet focus ring only for keyboard focus), space / ⏎ / arrows on every control, VoiceOver roles and labels computed from what a view shows, `AccessibilityAudit` (unlabeled interactive elements, elements outside the key loop, Codable reports), a FOCUS board in `codd-ui-gallery`; 33 tests | `Packages/CoddUI` |
| ui-packages-a11y | The seven UI packages (Notebook, Cleanup, Status, Settings, Dialogs, Annotate, FileEditorUI): labels, roles, keyboard focus and keys (lists step with ↑ ↓, tabs ← →, the annotate canvas without a mouse), one `AccessibilityAuditTests` per package; Settings › 13 關於 › `首次啟動設定 [重新執行]` (`SettingsActions.openOnboarding`) | `Packages/Codd*UI`, `Packages/CoddFiles/Sources/CoddFileEditorUI` |
| test-tools | The window-stack watcher (`--exe-prefix`: only the build under test counts; the user's own CODD is another app; other agents' builds ignored; `--watch-pid`), `scripts/tools/zorder.sh`, `scripts/lib/zorder-guard.sh` wired into the nine scripts that launch CODD, `scripts/tools/zorder-selftest.sh`, `scripts/tools/copy-audit.py` + its allow list | `scripts/tools`, `scripts/lib`, the m1–m4 scripts |
| perf | `TerminalTierPolicy` as a segmented LRU (D15) with an injected clock (13 tests); the F2 investigation (§4: the extra memory of an animating terminal is the Metal driver's per-process pool, not libghostty); `TerminalEngine.rendersWhileWindowOccluded` for D17; measurement flags in `codd-term-demo`; `scripts/m5-perf.sh` | `Packages/CoddTerminal`, `scripts/m5-perf.sh` |
| holder-compat | `codd-holder-compat` (the current client only: spawn, meta, welcome, stream, input, resize, reattach, paste, ring, stop) and `scripts/m5-compat.sh` (temporary worktrees of 37a9388 and db62f17, release builds of their `codd-holder`, removed afterwards) | `Packages/CoddHolder/Sources/codd-holder-compat`, `scripts/m5-compat.sh` |
| release | `VERSION` (`1.0.0`) and `scripts/release.sh` (`--dry-run`, `--output <dir>`, `--install`) | `VERSION`, `scripts/release.sh` |
| docs | Drafts of `README.md` (developers) and `docs/USER-GUIDE.zh-TW.md` (users), finished in I4 | `README.md`, `docs/USER-GUIDE.zh-TW.md` |

### Integration steps (sequential, App/; compile only)

| Step | What |
|---|---|
| I1 core-identity-data | `App/Support/CoddIdentity.swift` and every label, the pasteboard, the drag type, the signposter, the zoom notification on `app.codd`; project.yml versions; the show-window request under both names; `DefaultsIsolation` (the D2 copy on the standard root only, D25 no autosave on other roots and in mock mode); the D4 login-item hint; `DataFilesMonitor` (the preflight first in real mode, queued banners with `[在 Finder 中顯示]`, the post-load aside sweep); newer files read as far as possible (`LayoutStore.loadNewerReadOnly`, `PaneLayoutStore`, `ComposerStates`, the backups index, the hook config log); D20 `pendingStops`; `-codd-force-render`, `-CODDMetricsSessions`, the `perf launch-to-sidebar` line; dump keys `bundle`, `dataFiles`; `M5CoreTests` (8 suites) |
| I2 onboarding | The D5 gate in `applicationWillFinishLaunching`, `OnboardingWindowController` (1240 × 820, min 1011 × 640, CRT), the probes (only while it shows), the import into the sidebar, steps 3–6 through dialog B, the M4 registration dialog, the notes folder, dialog C and `SessionNotifier.requestAuthorizationNow`, `onboarding.json`, the 說明 menu and the Settings row, DEBUG `-codd-onboarding`, `-codd-onboarding-step`, `-codd-onboarding-actions`, `-codd-show onboarding[:n|:all]`, dump key `onboarding`; `M5OnboardingTests` (8 suites) |
| I3 a11y-copy | `StateSpeech` (states, reasons, colors, durations in words), `KeyFocusControl` / `KeyFocusView`, one VoiceOver element per sidebar row, lamps, rail radio buttons, status bar, menu bar panel, header, drawn lists (⌘K, ⌘N, resume picker, swatches); menu items for click-only actions (顯示方式 › SESSIONS / NOTES / STATUS / SETTINGS, 筆記 › 筆記本 / 檔案 / 清理建議, Session › 筆記抽屜 / 新增群組… / 切換帳號 ▸, CODD › 暫停通知 1 小時); DEBUG `-codd-a11y-audit <file>` over 37 screens (onboarding 1–6 included); the copy audit green (test-data emoji as `\u{…}` escapes, 加入帳號 / 儲存 as the one term); `M5AccessibilityTests` (5 suites) |
| I4 e2e-docs-report | `scripts/m5-e2e.sh` (§3), the M5 rows of `scripts/TEST-MAP.md`, the dump key `dataFiles.bannersQueued` (so the e2e sees one banner per issue), the GPU budget change (§4), README and the user guide final (every draft marker checked against the code), ARCHITECTURE (M5 decisions, layout, budgets, onboarding note), ROADMAP, this report; the Debug and Release builds and the static checks |

## 2. How to run

```bash
# Packages (separate scratch paths avoid lock clashes)
for p in CoddCore CoddHolder CoddHooks CoddTerminal CoddComposer CoddUI CoddPreferences CoddClaudeSettings \
         CoddHost CoddStatusUI CoddSettingsUI CoddNotes CoddMCP CoddTextKit CoddCodeEditor CoddFiles \
         CoddNotebookUI CoddAnnotateUI CoddCleanupUI CoddOnboarding CoddDataStore; do
  swift test --package-path Packages/$p --scratch-path .build-$p
done
swift test --package-path Packages/CoddDialogsUI --scratch-path .build-CoddDialogsUI --skip PresenterTests

# UI demos (offscreen PNGs)
swift run --package-path Packages/CoddOnboarding --scratch-path .build-CoddOnboarding codd-onboarding-demo --fonts App/Fonts --snapshot /tmp/onb
swift run --package-path Packages/CoddUI --scratch-path .build-CoddUI codd-ui-gallery --fonts App/Fonts --snapshot /tmp/gallery   # 09-focus board
swift run --package-path Packages/CoddSettingsUI --scratch-path .build-CoddSettingsUI codd-settings-demo --fonts App/Fonts --snapshot /tmp/settings

# App + tests
xcodegen generate
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build
CODD_BACKGROUND=1 xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test

# End to end (temp roots, temp Claude dirs, the fakes only; every launch in the background; the
# window-stack watcher over each run; they end every process they started)
scripts/m5-e2e.sh            # O1–O3, D1–D3, K1, S1, A1, C1, I1; ONLY=<ids>, KEEP=1, CODD_APP=<binary>
scripts/m5-perf.sh           # the budgets; ONLY=launch,idle,switch,memory,gpu; PERF_JSON=<file>; nothing else building
scripts/m5-compat.sh         # the current client against holders built from 37a9388 and db62f17
scripts/m1-smoke.sh; scripts/m1-e2e.sh; scripts/m2-e2e.sh; scripts/m3-e2e.sh; scripts/m4-e2e.sh
scripts/m4-sidebar-dnd.sh; scripts/m4-ui-zoom.sh; scripts/m4-layout-sweep.sh /tmp/sweep
LIVE=1 scripts/tools/zorder-selftest.sh       # the watcher itself (no CODD launch)
python3 -I scripts/tools/copy-audit.py

# Release
scripts/release.sh --dry-run                  # the plan, nothing built
scripts/release.sh --output /tmp/codd-rel     # a Release into a temp folder (delete it afterwards)
scripts/release.sh --install                  # only you, in your own Terminal, with no CODD running from /Applications
```

**A throwaway try-out of the wizard with the fakes** (a Debug build; nothing of `~/.claude`,
`~/.claude.json`, your cswap or your accounts is read; no Anthropic call):

```bash
APP=build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
T="$(mktemp -d "${TMPDIR%/}/codd-onb.XXXXXX")"; T="$(cd "$T" && pwd -P)"
scripts/m2-fixtures/make-root.sh "$T/d" >/dev/null
mkdir -p "$T/bin" "$T/home/.claude/sessions" "$T/cs/.claude" "$T/fakelog"
bash scripts/m5-fixtures/make-import-fixture.sh "$T/home/.claude" "$T/work"     # projects + home/.claude.json
scripts/m3-fixtures/make-claude-settings.sh "$T/home/.claude" --legacy >/dev/null # CODD web's old hooks
scripts/m3-fixtures/make-cswap-state.sh "$T/cs/.claude-swap-backup" "$T/cs/.claude" >/dev/null
cp scripts/m3-fixtures/fake-cswap.py "$T/bin/cswap"; printf 'FAKE_CSWAP_ROOT=%s\n' "$T/cs/.claude-swap-backup" >"$T/bin/cswap.env"
cp scripts/m4-fixtures/fake-claude-m4.sh "$T/bin/fake-claude"
printf 'FAKE_REGISTRY_DIR=auto\nFAKE_DEFAULT_CLAUDE_DIR=%s\nFAKE_LOG_DIR=%s\n' "$T/home/.claude" "$T/fakelog" >"$T/bin/fake-claude.env"
"$APP" -codd-data-root "$T/d" -codd-claude-dir "$T/home/.claude" -codd-claude-path "$T/bin/fake-claude" \
  -codd-cswap-path "$T/bin/cswap" -codd-cswap-root "$T/cs/.claude-swap-backup" \
  -codd-login-env NO -codd-notifications NO -codd-shell-argv "/bin/zsh -f" -codd-onboarding auto
# The wizard opens behind your windows (a Debug build on another root starts in the background): click it.
# Step 1 shows the fake claude 2.1.302, cswap 0.26.0 · 3 個帳號, hooks 需要更新, the root writable, MCP.
# Step 2 lists 6 projects (+ 2 hidden); 依父資料夾建議分組 makes clients and labs; 下一步 adds them.
# Clean up: pkill -TERM -f "$T/"; sleep 1; pkill -KILL -f "$T/"; rm -rf "$T"
```

Mock data (screenshots): `"$APP" -codd-mock -codd-show onboarding:all -codd-snapshot /tmp/m5.png
-codd-quit-after 8` writes `m5-onboarding-1.png` … `-6.png`; `-codd-a11y-audit /tmp/a11y.json
-codd-full-keyboard-access YES` runs the audit and exits. DEBUG flags: `App/Real/RealModeOptions.swift`
and ARCHITECTURE "Testing hooks".

## 3. Test results (2026-10-19)

What ran in M5 (all of it builds and static checks; the step reports have the details):

| What | Result |
|---|---|
| Debug `build-for-testing` (I4, `build/m5`) | `** TEST BUILD SUCCEEDED **`, zero `warning:` / `error:` lines (also after each of I1, I2, I3) |
| Release (`scripts/release.sh --output <scratchpad>/rel`, I4) | `** BUILD SUCCEEDED **`, zero warning lines in the xcodebuild log, xcodegen skipped (project current), signature verified, helpers `app.codd.codd-holder` / `codd-hook` / `codd-statusline`, `bundle=app.codd.CODD version=1.0.0 build=6 identity=adhoc`, zip 33 MB; the output deleted |
| `scripts/release.sh --dry-run` (I4) | exit 0; `RELEASE dry-run … version=1.0.0 build=6 identity=adhoc bundle=app.codd.CODD (nothing was built)` |
| `python3 -I scripts/tools/copy-audit.py` (I4, after the docs) | exit 0, `COPY findings=0 failing=0 review=0 allowed=495`, no unused allow entry. Before I3: `findings=365 failing=42 review=323` |
| `git grep` / working-tree grep for the old bundle id | only `App/Support/CoddIdentity.swift`, `App/Tests/M5CoreTests.swift`, CoddDataStore's migration and its test, and the history (M0–M4 docs, the M5 plan, Spikes/, design/) |
| `swift build --build-tests` of every package changed in M5 (components, I1, I3) | build complete, zero warnings (CoddOnboarding, CoddDataStore, CoddComposer, CoddClaudeSettings, CoddHooks, CoddUI, the seven UI packages, CoddTerminal, CoddHolder, CoddCore, CoddCodeEditor, CoddNotebookUI) |
| `bash -n`, `zsh -n` | clean on every edited script (`m5-e2e.sh`, `m5-perf.sh`, `m5-compat.sh`, `release.sh`, the nine wired scripts, `zorder-guard.sh`, `zorder.sh`) |
| Measurements | perf component: the F2 Metal investigation and a window-stack watcher over it (`zorder samples=2787 withOwner=1142 violations=0`) (§4) |
| Everything else | **pending** (the wrap-up run below) |

**The wrap-up test run (run once, in this order; failures go to a fix agent, who re-runs only what it
touched and the failing sections with `ONLY=<ids>`, scripts/TEST-MAP.md):**

1. `xcodegen generate && xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build`
2. Every package suite (the loop in §2; CoddDialogsUI with `--skip PresenterTests`). New or changed in M5:
   CoddOnboarding (80; `LayoutTests.pathElision` needs `App/Fonts`), CoddDataStore (43; prints
   `data preflight 200 sessions: ms=…`, budget < 30 ms), CoddUI (75), the seven UI packages (their
   `AccessibilityAuditTests` print `A11Y <screen>: interactive n, unlabeled n, outsideKeyLoop n`),
   CoddTerminal (81), CoddComposer, CoddClaudeSettings, CoddHooks, CoddCore, CoddHolder, CoddCodeEditor.
3. `CODD_BACKGROUND=1 xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test`
   (new: `M5IdentityTests`, `M5FlagTests`, `M5DefaultsTests`, `M5LoginItemTests`, `M5DataPreflightTests`,
   `M5NeverStricterTests`, `M5PaneLayoutGuardTests`, `M5StopWhileStartingTests`, the eight `M5Onboarding*`
   suites, `M5SpokenStateTests`, `M5SidebarAccessibilityTests`, `M5MainWindowAuditTests`, `M5MenuItemTests`,
   `M5AuditFlagTests`).
4. `LIVE=1 scripts/tools/zorder-selftest.sh` (a few seconds, no app) before the first guarded script.
5. `scripts/m1-smoke.sh`, `scripts/m1-e2e.sh`, `scripts/m2-e2e.sh`, `scripts/m3-e2e.sh`, `scripts/m4-e2e.sh`,
   `scripts/m4-sidebar-dnd.sh`, `scripts/m4-ui-zoom.sh`, `scripts/m5-e2e.sh` (each prints its `zorder
   samples=… violations=0` line), `scripts/m4-layout-sweep.sh <dir>` for a look.
6. `scripts/m2-fixtures/selftest.sh --with-app build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD`,
   `bash scripts/m3-fixtures/selftest.sh`, `bash scripts/m4-fixtures/selftest.sh`.
7. `scripts/m5-perf.sh` alone (nothing else building; `PERF_JSON=<file>`); for every FAIL: a small fix and
   `ONLY=<section>` again, or the budget changed in ARCHITECTURE "Performance budgets" AND the script's
   table, each with the measured number and the reason (§4 has the expectations).
8. `scripts/m5-compat.sh` (then `git worktree list` must show only the main tree and `build/wt-m4`).
9. `scripts/release.sh --dry-run`; `python3 -I scripts/tools/copy-audit.py`.
10. A look at the snapshots: `-codd-mock -codd-show onboarding:all -codd-snapshot <png>` against
    `design/artboards-src/Onboarding.src.html` and `codd-onboarding-demo`; the 09-focus gallery board; the
    Settings 關於 section.

`scripts/m5-e2e.sh` (about 125 checks in 15 CODD launches plus one mock audit launch; written, `bash -n`
and `zsh -n` clean, never run). One mktemp folder `codd-m5e.XXXXXX`, a group folder per scenario with its
own data root (make-root.sh), Claude directory and fakes; every launch with each flag as its own
argument, `-codd-quit-after`, `-codd-dump-state`, `-codd-login-env NO`, `-codd-notifications NO`, in the
background; the zorder guard over the whole run; cleanup by `pkill -f "<folder>/"` only.

| Id | What it checks |
|---|---|
| O1 (oa, ob) | a new root with `-codd-onboarding auto`, the import fixture, the fake claude, the fake cswap (3 accounts), CODD web's legacy hooks: gate `new-root`; the wizard shown, the main window not; boot rows (claude 2.1.302 and its path, `0.26.0 · 3 個帳號`, hooks `需要更新（n 個事件）` with `舊版 CODD web：`, the root `可寫入` with `MCP 127.0.0.1:<port> 可用`, `6 個專案` read only), header `4 OK · 1 待處理`; rows in the fixture's last-use order with transcripts and hidden kinds, the missing folder absent, `labs/` prefixes on mcp and x only, the 5 pre-checked rows; `suggest` → clients / labs / 未分類 (legacy-site keeps clients as its suggestion); ⌘Q mid-way writes no `onboarding.json`; the full flow: 10 actions ok, `onboarding import projects=5 groups=2`, layout.json with exactly those 5 projects in the suggested groups and colors, hooks-preview a plan with no backup written, notebook path `<root>/notes`, reveal skipped (background), accounts as 3 alias rows, `notify` → `suppressed`, `onboarding.json` v1 (0600, every step done, 5 / 2, this version), the main window shown; `.claude.json`, the transcripts and settings.json unchanged (size, mtime, sha256); a relaunch: `existing-root`, no probe |
| O2 (o2) | a seeded root plus one fixture project in it: `existing-root`, no probe, the main window; `-codd-show onboarding` (`show-flag`) leaves that project out (`already` 1); six skips import nothing (layout.json's groups and projects the same) and write an all-skipped `onboarding.json` |
| O3 (o3) | no cswap, a claude path that does not exist: `[FAIL] claude 找不到` (log `onboarding claude missing`), `[ .. ] cswap 沒有安裝`, the step 5 note, the flow finishes, no `exec claude` |
| D1 (dn) | a run writes v1 files (a shell with two panel tabs, a composer send, a zoom step), then layout.json, preferences.json, panes.json, the composer.json and config.json become v99 with that content; two later runs (the same shell with a third tab, another composer send and zoom step; a new session) change no byte; five `newer` issues at v99, `bannersShown + bannersQueued ≥ 5` with the newer wording; the sidebar shows the v99 layout's groups and sessions, the pane the v99 panes.json's tabs; preferences origin `newerReadOnly(99)`; the read-only log lines; `data preflight … newer=5` |
| D2 (dc, ds) | garbage layout.json, preferences.json, profiles.json, cleanup.json, files/recent.json and a composer.json: each moved to `<name>.corrupt-<ms>` with the planted bytes and a corrupt issue naming it, defaults used, a banner each; quota.json and a hooks record removed with no banner and no aside; config.json with a bad token repaired in place with its port (`config.json.invalid-*` copy, never `.corrupt-`); `corrupt=6 removed=2`; a layout.json with a `1e999` member (current for the preflight) moved aside by LayoutStore and bannered by the sweep (`by=store`); a preferences.json with `"version":"1"` not moved |
| D3 (dk, dv) | `cache/VERSION` 0 + a planted file → wiped, `VERSION` 1, the notes index rebuilt; the next launch keeps a new planted file; a cache without VERSION keeps its file and gains `VERSION` 1 (log `written`) |
| K1 | the built bundle: `CFBundleIdentifier` app.codd.CODD, `CFBundleShortVersionString` = VERSION, `CFBundleVersion` a number, the three helpers signed `app.codd.<name>`, the binaries contain the legacy id only as the bare constant (and its `.showMainWindow` form) |
| S1 (st) | `-codd-new-claude` + `-codd-stop-after-create YES`: `stop deferred` before `stop applied-after-spawn` for the same session, the session ends as for any stop (EXITED with RESUME, or STOPPED when the holder left no EXIT; fix round 1, was "STOPPED"), no holder left within 5 s |
| A1 | `-codd-mock -codd-a11y-audit <file> -codd-full-keyboard-access YES`: exit 0, 0 unlabeled over ≥ 30 screens including onboarding 1–6, the outsideKeyLoop total printed (report only) |
| C1 | `copy-audit.py` exit 0 with `failing=0`; `release.sh --dry-run` exit 0 naming `version=<VERSION>` and `bundle=app.codd.CODD`, nothing built |
| I1 | every `exec` line inside the temp folder; no `defaults migrat…` line (other roots never migrate); every dump: `bundle` app.codd.CODD at VERSION, `autosavesLayout` false, `legacyDefaults` `notApplicable` (D25); no `example.com` (the fixtures' e-mails) and no `anthropic.com` in any dump or log; no new `~/.claude.json.codd-bak-*` / `~/.claude/settings.json.codd-bak-*` (names only) |

Assumptions in `scripts/m5-e2e.sh` most likely to need a fix in the first run: the cswap identity in
O1 (CODD reads the active login from `<claudeDir>/../.claude.json`, here the import fixture's made-up
account, which matches no cswap account: rows still come from cswap, but the availability could differ);
the exact counts (10 actions ok, `newer=5`, `corrupt=6 removed=2`, 3 account rows); the composer send on
the reattached shell in D1's second run; the timing of the post-load sweep in D2 (14 s runs); a session
folder without `meta.json` holding the corrupt composer.json in D2; A1 finishing within its 240 s.

## 4. Measured numbers (this Mac: M4 Max, 64 GB, macOS 27.0.1, Debug)

**Performance (`scripts/m5-perf.sh`), measured in the wrap-up run (2026-10-19, Debug, load1 about 2.2):**
launch_to_sidebar 453 ms before fix round 1, 411–421 ms after (Debug budget < 450 ms; the Release target
< 400 ms has no script); idle_cpu_visible 0.95–1.0 % before, 0.15–0.16 % after (now measured from 125 s);
idle_cpu_hidden 0.044–0.063 %; idle_cpu_holders 0.010–0.014 %; switch_cold_max 4.86 ms; switch_hot_p50
1.86 ms; switch_hot_max 1.89 ms; memory_app_base 51.0 MB; memory_holder_max 2.0 MB; memory_total_15
188.5 MB; gpu_lamps_growth −0.4 MB; gpu_animating_total 419.1 MB (< 550 MB). Measured before the run, and
the budget decision taken on it:

| What | Measured (perf component, `codd-term-demo --background --measure`, phys_footprint) |
|---|---|
| A quiet zsh terminal, 900 × 560 pt | 44 MB at 5 s, 38 MB at 35 s (0 frames/s) |
| A 10 Hz spinner | 267–272 MB (9–10 frames/s); the same in a 450 × 280 window: 262–265 MB |
| A blinking cursor / a 60 Hz flood / `window-vsync=false` | 267–270 MB (1–2 frames/s) / 278–280 MB (88–95 frames/s) / 269–272 MB |
| The extra while drawing | "owned unmapped (graphics)": 27 regions of exactly 8 MB, independent of window size and frame rate |
| A 60-line Metal program, no window, no libghostty (clear an IOSurface texture at 10 Hz) | 225 MB in 28 × 8 MB regions (261 MB footprint) while `MTLDevice.currentAllocatedSize` is 24 MB; the same with 1 / 2 command buffers, a private target, a pipeline draw, two queues, 1 Hz; gone about 1 s after the last command buffer (261 → 37 MB) |

**Budget change (I4, 2026-10-19): `gpu_animating_total` < 300 MB → < 550 MB** (ARCHITECTURE
"Performance budgets" and the script's table). Reason: the extra of an animating visible terminal is the
Metal driver's per-process pool (about 225 MB), paid once per process while anything draws at ≥ 1 Hz;
libghostty's renderer settings do not change it (the CAMetalLayer knobs are moot: libghostty uses its own
IOSurface layer), and avoiding it means not drawing a visible terminal. The quiet total budget stays
< 300 MB. Question 1 in §7 asks whether you accept this or want terminals CODD is not focused on to stop
animating.

(Written before the wrap-up run; the numbers above supersede it.) Expected from the M1–M4 numbers (not measured by the script yet; the fix agent decides on the wrap-up's
quiet run): `memory_app_base` < 80 MB is likely to fail on Debug (M2: Debug with sessions 113–115 MB,
Release Home-only 80 MB); `idle_cpu_visible` < 0.5 % may fail in the first minutes (M2: 0.5–0.7 % while
durations count seconds, 0.1–0.2 % after 2 min); `idle_cpu_hidden` < 0.1 % and `switch_cold_max` < 50 ms
(M1: 30–45 ms cold) are borderline; `gpu_lamps_growth` may measure nothing in a covered window (D17 keeps
the timers, not the window server's compositing).

**Compatibility (`scripts/m5-compat.sh`): passed in the wrap-up run (M1 and M4 holders plus head).** As predicted from the code: the M1 holder advertises
`attach.ack`, `attach.modes` and `gap.resync` but not `input.paste`, so the current client brackets
pastes itself from ATTACHED's modes; the ring layout is still version 1 and the CLI flags are unchanged.

**Release (I4):** xcodebuild Release 126 s with zero warnings, the whole script 128 s (2:08 wall, 693 s
user); the output folder 2.2 GB (derived data included, deleted afterwards); `CODD-1.0.0-6.zip` 33 MB;
ad-hoc signature, the app without entitlements (Xcode's ad-hoc `get-task-allow` is not kept).

**Copy audit:** before I3 `findings=365 failing=42 review=323`; now `findings=0 failing=0 review=0
allowed=495` (the review-only English strings are log lines, protocol text, configuration and sample
data, allow-listed per file or folder with a reason).

**Accessibility:** the A1 run audits 37 screens: 22 unlabeled elements in the wrap-up run, 0 after fix
round 1 (outsideKeyLoop 478, informational).

## 5. Known issues

**Nothing was executed.** See §3: every new test, `scripts/m5-e2e.sh`, `scripts/m5-perf.sh`,
`scripts/m5-compat.sh`, the zorder self test, the onboarding snapshots, the FOCUS board, the a11y audit
and the fixture run (CoddOnboarding's `FixtureTests`) have their first run in the wrap-up.

**Onboarding**
- ⌘Q in the middle of the wizard writes no `onboarding.json` and (fix round 1) no empty `panes.json`, so
  the wizard comes back at the next launch; only after step 2's 下一步 imported projects is the root no
  longer new (`layout.json`), and then it is reopened from 說明 › 首次啟動設定….
- The window appears only after the first probe (it waits up to 10 s for the sessions to load, and
  `claude --version` may take up to 5 s); there is no loading state and no overall probe deadline (a
  project on an unreachable network mount can stall its `stat`). Since fix round 1 a Dock click, 開啟
  CODD, the hotkey or a second instance during the probe show the main window instead of nothing; the
  wizard still appears when the probe ends (both windows are then open).
- Suggested new groups are keyed by their parent folder (`new:<path>`), named groups `user:<n>` (fix
  round 1): a re-detect keeps every row in its group, but a suggested group's color and collision name
  can change when the new catalog lists the parents in another order.
- The registration and Codex refusal toasts go to the main window's toast area, which is hidden while
  the wizard is open (rare: the 註冊 button is hidden when registration is disabled).
- `-codd-onboarding-actions` splits at commas (no commas in `filter:` or path arguments).
- On temp roots under `/private/var/folders`, `standardizedFileURL` may drop `/private` for project cwds;
  catalog matching uses realpath (fine), but D9's existing-group suggestion after an import may not match
  there. Real home paths are not affected.
- Step 5 is redrawn on every account change the observation sees (status-line quota reports included);
  cheap, not throttled.
- Drawing compromises (from the component, not seen on screen yet): layer-shadow glows do not appear in
  offscreen snapshots; the `_` cursor blinks 1 s on / 1 s off (the CSS has a 1 s period); checkboxes are
  13 px squares and the header box shows `−` when partly checked; at 1011 × 640 (fix round 1) the
  toolbar hint and the footer's faint tail are dropped whole, the header labels stay whole (the PROJECT
  and GROUP columns give way to 132 / 126 px, so names and group selects are cut sooner), but long boot
  details (hooks, the data root's path) are still cut at the window edge and the stepper drops its foot
  hint; the PATH column keeps one more component than the artboard's hand-written text for three rows
  (it fits).

**Data files**
- The aside sweep runs once (after the notes, the first retention run and the accounts read): a store
  that loads lazily later in the run (NOTES › Files' recent and AI-touch stores) and moves a file aside
  gets no banner.
- While a newer `layout.json` / `panes.json` is shown read-only, the user's changes stay in memory only;
  the newer-version banner is the only hint.
- `"v": true` in `claude-settings-backups.json` reads as v1 for the stores but as non-integer for the
  preflight (it would be moved aside); CODD never writes it.
- `HookConfigStore` still tightens a newer `config.json` to 0600 (metadata only).
- The preflight validates every composer.json fully; very large histories cost proportionally.
- `notes/.codd/notebook.json` is report-only (never moved), unlike the plan's table, because its store
  never parses it (D14 safety rule).

**Identity and defaults**
- On test roots the status item has no autosave name, so AppKit may still write `NSStatusItem … Item-0`
  keys into the app's domain; they are not CODD's keys, never migrated, and never touch the installed
  CODD's `CODDStatusItem` position.
- With 登入時啟動 ON, the D4 hint also replaces the old 「系統找不到這個 App」 text for `.notFound`.
- Ad-hoc signing: TCC knows the app by each build's signature, so folder access may be asked again after
  every update.

**Performance**
- `scripts/m5-perf.sh` measures a Debug build (its DEBUG flags have no Release counterpart). Fix round 1
  gave `launch_to_sidebar` a Debug row (< 450 ms; the < 400 ms product target is for Release and has not
  been measured by a script) and measures `idle_cpu_visible` from 125 s after launch (the first 2 minutes
  count seconds in every row); the idle section now takes about 3 minutes.
- A window covered from its first ordering never gets an occlusion notification, so libghostty keeps
  drawing it (the demo drew 9–10 frames/s covered). CODD's background test windows probably behave the
  same, so background CPU numbers may include drawing (M3 §4's "covered, libghostty did not draw" may be
  wrong for them). Not changed: reading `occlusionState` at window move would leave never-shown windows
  without a first frame and could break snapshot checks.
- F2 was measured on one Mac; the driver pool may differ on other GPUs and macOS versions.

**Compatibility, release, tooling**
- `m5-compat.sh`: untested assumptions (macOS `/bin/sh` runs the WINCH trap during `wait`; the old commits
  build with Swift 6.4 in release); a stale, prunable worktree path makes its `git worktree add` fail
  (reported, never pruned).
- `release.sh`: the zip from `ditto -c -k --keepParent` carries AppleDouble entries for the files'
  provenance attributes (Archive Utility and `ditto -x -k` restore them; a plain `unzip` would put `._`
  files into the bundle and break its seal); `--install` itself never ran; the running-CODD check matches
  the command line by path prefix.
- The zorder watcher counts only layer-0 windows; any process under `<repo>/build/` or `<repo>/.build*`
  other than the build under test (and `build/user-*`) is ignored; the first guarded run compiles the
  watcher (several seconds).

**Accessibility**
- The audit (CoddUI `AccessibilityAudit`) skips a scroller's own parts and the field editor (fix round 1):
  AppKit's unlabeled arrow / page elements and the editor of a text field being edited are not CODD's to
  label; a label missing on a real control inside a scroll view is still found.
- No real VoiceOver or Full Keyboard Access session; the counts are unmeasured. In a focused terminal Tab
  goes to the shell (leave with ⌥⌘F or the menus); the menu bar panel's ↑ ↓ stays within one list; focus
  glows are cut by superviews that clip; the file tree, crumbs and status items draw their own cursor
  (a click shows it under Full Keyboard Access); a focused CoddButton takes ⏎ before a dialog's own ⏎
  mapping (only with Full Keyboard Access on); radio rows are each a Tab stop (not one stop per group).

**Docs**
- The user guide's login-items pane name on macOS 26 / 27 in 繁體中文 is not checked; CODD writes its log
  to stdout only (Settings › 進階 › 紀錄檔 shows `—`).

## 6. 手動測試清單（請用真的 claude、cswap、~/.claude/settings.json 與 ~/.claude.json）

先用 `scripts/release.sh --install` 安裝（第 E 項），之後的項目都用 `/Applications/CODD.app`。有問題時請附上
在「終端機」執行 `/Applications/CODD.app/Contents/MacOS/CODD` 時印出的 `REALHOLDERS` 開頭的紀錄行，與畫面截圖。

**A. VoiceOver（⌘F5 打開）**
1. 側欄：等待中的 session 應念出像 `修正登入 API 401，等待中 · 權限 · 3 分鐘，標籤：紅` 這樣的文字（不靠顏色）；
   群組列念出 `<名稱> 群組，展開，n 個 session：等待中 1、工作中 1`。
2. rail：`SESSIONS，3 個需要你`（選取中）、`NOTES`、`STATUS`、`SETTINGS` 是單選按鈕。
3. 標題列的燈號是一張有說明的圖；下方狀態列念出 MCP 與 hooks 的狀態；側欄底部的 5h / 1w 用量。
4. 選單列面板：每一列念出標題、狀態、時間與位置；`前往 …`、`允許 …（回答 1）` 按鈕名稱正確。
5. NOTES（筆記本、檔案、清理、標註）、STATUS、設定的各頁、各對話框，以及首次啟動設定（步驟列念出 `已完成 /
   目前步驟 / 尚未開始`，匯入表格的每一列、勾選框、群組選單）。

**B. 鍵盤導覽（系統設定 › 鍵盤 › 鍵盤導覽 打開）**
6. 在主視窗、設定、各對話框與首次啟動設定按 Tab：每個按鈕、開關、清單都走得到；有焦點的元件外圍出現琥珀色的框，
   用滑鼠點的時候不出現。空白鍵按下、⏎ 按下按鈕；方向鍵切換分段選項、數值與清單。
7. 選單：`顯示方式 › SESSIONS / NOTES / STATUS / SETTINGS`、`筆記 › 筆記本 / 檔案 / 清理建議`、
   `Session › 筆記抽屜 / 新增群組… / 切換帳號`、`CODD › 暫停通知 1 小時` 都能用（沒有快捷鍵）。

**C. 你真的資料夾上的 1.0（`~/Library/Application Support/CODD`）**
8. 第一次打開 1.0：**不應**出現首次啟動設定；主視窗的大小與位置、側欄寬度、選單列圖示的位置跟舊版一樣；
   session 都接回來；設定 › 關於 的 App 一列是 `1.0.0 (<建置編號>)`。紀錄裡有一行 `defaults migrated
   from=… keys=<n>`。
9. 資料夾裡多了 `cache/VERSION`（內容 `1`），筆記搜尋照常（索引沒有被重建）。不應出現任何 `▲ … 無法讀取` 的提示；
   如果出現，請把提示全文告訴我（檔案已移到旁邊的 `.corrupt-<數字>`，沒有遺失）。
10. 登入時啟動：如果你開過 設定 › 一般 › `登入時啟動`，那一列下方應提示「CODD 換了識別碼：請把「登入時啟動」
    關掉再打開一次」。照做之後到 系統設定 › 一般 › 登入項目 把舊的 CODD 刪掉；登出再登入，應只啟動新的 CODD。

**D. 用 `說明 › 首次啟動設定…` 在真的資料夾上走一次（會讀你真的 claude、cswap、settings.json 與 ~/.claude.json）**
11. 開始前記下時間戳記：`stat -f '%m %z' ~/.claude/settings.json ~/.claude.json`。
12. 第 1 步：claude 的版本與路徑（從登入 shell 的 PATH 找到的那個）、cswap 的版本與帳號數、hooks 的狀態（有 CODD
    web 的舊 hooks 時是 `需要更新`）、資料夾可寫入、MCP 位址都正確。
13. 第 2 步：列出的是你 `~/.claude.json` 裡、還不在 CODD 側欄的專案，依最近使用排序；worktree 與 SDK 專案隱藏；
    `[依父資料夾建議分組]` 的分組合理。勾選少數幾個按 `[下一步]`：側欄只多出勾選的專案（之後可以在側欄用右鍵
    移除專案拿掉）。
14. 第 3 步 `[預覽變更]`：Hook 差異 對話框只移除 CODD web 的舊 hooks（其他工具的 hooks 保留）；
    **不按** `套用並備份` 就關掉，`~/.claude/settings.json` 的時間戳記不變。要套用時按 `套用並備份`，旁邊多一個
    `settings.json.codd-bak-<時間>`。
15. 第 4 步：`[在 Finder 中顯示]` 打開筆記資料夾；Claude Code `[註冊…]` 打開 M4 的註冊對話框，不按 `套用並備份`
    就不會改 `~/.claude.json`（時間戳記不變）。
16. 第 5 步：帳號只顯示別名（例如 `#3 工作`），依每週重置時間排序；`[+ 加入帳號]` 會叫出主視窗與加入帳號面板。
17. 第 6 步 `[允許通知]`：macOS 應跳出通知權限的詢問（新的識別碼要重新允許）。按 `[開始使用 →]`：視窗關掉、
    主視窗出現；`~/Library/Application Support/CODD/onboarding.json` 更新。
18. 再走一次並在第 3 步按 ⌘Q：下次打開 CODD 不會自動出現首次啟動設定（見 §7 問題 2）。

**E. 安裝、臨時資料夾與通知**
19. 在一般的「終端機」（不是 Claude Code 裡）先在舊的 CODD 按 ⌘Q 選 `結束 · session 繼續執行`，再執行
    `scripts/release.sh --install`：最後一行 `RELEASE app=… version=1.0.0 build=<n> identity=adhoc
    bundle=app.codd.CODD`，舊的 `/Applications/CODD.app` 在垃圾桶裡，session 沒有中斷。
20. （選用）臨時資料夾試用：`T="$(mktemp -d)"; mkdir -p "$T/root" "$T/claude/sessions";
    /Applications/CODD.app/Contents/MacOS/CODD -codd-data-root "$T/root" -codd-claude-dir "$T/claude"`，用
    `說明 › 首次啟動設定…` 打開：claude 與 cswap 會顯示找不到、Claude Code 註冊是停用的，這是設計如此
    （臨時資料夾不碰你真的帳號與設定）。結束後刪掉 `$T`。
21. 第一則通知（或第 6 步）時 macOS 會再問一次通知權限；允許後 設定 › 通知 › `[傳送測試通知]` 應出現。

## 7. Decisions taken (all reversible)

### The plan's decisions as implemented

| # | As implemented |
|---|---|
| D1 | `app.codd.CODD` everywhere (tests `app.codd.CODDTests`, helpers `app.codd.codd-*`); every name through `CoddIdentity`; the show-window request posted and observed under both ids; BackgroundWindows treats either id as CODD. Supersedes design/SPEC.md §10's "internal identifiers unchanged for now" |
| D2 | `DefaultsIsolation.migrateLegacyDefaults` right after the instance lock, standard root only: CODD's own keys (window frame, split frames, status item position / visibility, `CODD*` minus the DEBUG tool keys) from the legacy domain replace the new domain's until the marker `CODDDefaultsMigratedFrom`; the legacy domain is only read; logs `defaults migrated from=… keys=<n>` / `skipped reason=alreadyDone|sourceMissing|sameDomain` |
| D3 | Onboarding step 6 asks (`requestAuthorizationNow`, suppressed in background runs and with `-codd-notifications NO`); everyone else at the first notification, as before |
| D4 | 「CODD 換了識別碼：請把「登入時啟動」關掉再打開一次」 under 登入時啟動 when it is ON but the service is not enabled / awaiting approval; never registered at launch |
| D5 | The gate once in `applicationWillFinishLaunching` (standard root: `OnboardingGate`; other roots only with DEBUG `-codd-onboarding auto|show`; mock with `-codd-show onboarding`); logged on every real-mode launch; Dock / show-window / status item / global hotkey bring the open wizard forward; probes only while it shows |
| D6 | Its own window, 1240 × 820 (min 1011 × 640), hidden-inset title bar, CRT overlay, no frame autosave; the main window built but shown only when it ends |
| D7 | `onboarding.json` (0600, atomic) when it ends; closing the window = ended (the step skipped); ⌘Q mid-way writes nothing (but see §5: the root is no longer new afterwards); mock never writes it |
| D8 | `<claudeDir>/../.claude.json` (else `<claudeDir>/.claude.json`), read only through a symlink, ≤ 64 MiB, ≤ 2,000 keys (sorted before the cap), existing folders only; worktree and SDK-only hidden; ≤ 12 pre-checked from the last 14 days; 12 rows + 24 per `載入更多`; applied at step 2's 下一步 |
| D9 | Existing group with a sibling project, else a shared parent of ≥ 2 checked rows → a new group in SPEC tag-color order, else 未分類; every candidate has a suggestion; collisions `<grandparent> · <parent>`, then a number |
| D10 | `parent/` prefixes, front elision of PATH by whole components measured with the real font, `今天 / 昨天 HH:mm`, else `M/dd` |
| D11 | Boot rows claude, cswap, hooks, the data root, then the import source (`[ OK ] ~/.claude.json 187 個專案`) on steps 1–2 and `projects 已匯入 n 個` later; the node row dropped; the hooks wording for CODD web's legacy events |
| D12 | `已在用 CODD Web？匯入它的設定 →` only with web leftovers; jumps to step 3 |
| D13 | Step 5's `+ 加入帳號` is dialog C on the main window; the wizard stays and follows the accounts |
| D14 | `DataPreflight` first in real mode; backups `<name>.v<from>-backup-<yyyyMMdd-HHmmss>`; newer files untouched and read as far as possible (layout read-only through the v1 decoder, panes leniently, composer drafts in memory, the backups index and config.json not rewritten); corrupt USER DATA aside, corrupt DERIVED removed, `config.json` and `notebook.json` report-only; `cache/VERSION` wipe / write; never stricter than the store (`M5NeverStricterTests`); one queued banner per issue; the post-load aside sweep |
| D15 | Segmented LRU, probation 2 + protected 4, protection after ≥ 5 s shown or a reveal from hot; eviction from probation first; injected clock |
| D16 | `scripts/m5-perf.sh` with the budget table mirroring ARCHITECTURE; `gpu_animating_total` changed to < 550 MB (§4); the other budgets wait for the wrap-up's quiet run |
| D17 | `-codd-force-render YES`: TerminalHub never occludes, engines ignore window occlusion, the 1 Hz clock forced; mock lamps keep their animation anyway (nothing removes it) |
| D18 | `scripts/release.sh` as planned; re-signs without `--preserve-metadata` (no entitlements), refuses `build/user-*`, `build/wt-*`, the repo root and `build` as outputs; `--install` only from `build/release` |
| D19 | `codd-holder-compat` + `scripts/m5-compat.sh` (worktrees under `build/m5-compat/`, removed with `git worktree remove --force`, never `prune`) |
| D20 | `pendingStops` + `launchesInFlight`: a stop during an in-flight launch is applied through `stop` after the connect (`stop deferred` → `stop applied-after-spawn`); failure, relaunch, removal and archive clear it; `-codd-stop-after-create YES` |
| D21 | Labels everywhere, focus only with Full Keyboard Access, the ring only for keyboard focus, space / ⏎ / arrows, menu items without key equivalents, `AccessibilityAudit` + `-codd-a11y-audit` |
| D22 | `copy-audit.py` rules E F M S G (failing) and L (review); test-data emoji as escapes |
| D23 | `--exe-prefix` watcher in every script that launches CODD; a violation or a missing summary fails the run |
| D24 | Every component and integration step compiled only (user rule); one wrap-up run runs everything |
| D25 | `DefaultsIsolation.autosavesLayout`: false on every non-standard root and in mock mode (no frame, split or status item autosave) |

### Added by the components and steps (selection; the step reports have the full lists)

- Onboarding: the boot block's fifth row is the import source; new-group keys are stable (`new:<n>` by the
  parent's position); the artboard sample's selection is set by hand; ⏎ presses the primary except while
  composing or with the group menu open, ⌘[ goes back; `-codd-show onboarding[:n]` in real mode writes
  `onboarding.json` like `-codd-onboarding show`; the first probe waits for the sessions; leaving step 1 by a
  jump counts as done; imported rows leave the table; a failed `claude --version` reads `--version 沒有回報版本`.
- Data: `notebook.json` report-only; `belowOneVersion` for stores that read a version < 1 as theirs; a
  corrupt banner only when a file was really moved; a newer `config.json` without a usable port / token
  throws instead of being repaired; no new `HookConfigOrigin` case; backups written with `O_EXCL`; a
  missing data root makes the preflight do nothing.
- Accessibility: ⏎ presses buttons, toggles take space; the ring follows `:focus-visible`; a caller's
  label always wins; sidebar rows are one AXRow; drawn lists expose static-text rows with a press action;
  no explicit `nextKeyView` links (AppKit's automatic loop already follows the view order); every radio
  row is a Tab stop; SegmentedSwitch arrows do not wrap.
- Copy: one term each: 加入帳號 (Settings, STATUS and dialog C on the frozen artboards use it; onboarding
  step 5's `+ 新增帳號` became `+ 加入帳號`), 儲存 (not 保存), 資料夾 (目錄 only where the artboards use it).
- Tools: `--watch-pid` so an orphaned watcher ends; the guard keeps a copy of the log on a violation; the S
  list omits characters that are also valid traditional ones.
- Perf: probation borrows unused protected slots (a scan never shrinks the hot set below 6); the
  wrapper's "a new window starts visible" assumption left unchanged (reported in §5).
- Release: the identity's SHA-1 is used when an Apple Development certificate exists; the bundle id is
  checked right after the copy and again in verify.
- I4: the dump's `dataFiles.bannersQueued`; the GPU budget change; the e2e gives the fake cswap its own
  home so its `.claude.json` never meets the import fixture's; the docs tell users that ⌘Q in the
  middle of the wizard does not bring it back.

### Questions for you

1. **GPU memory while a terminal animates.** The Metal driver keeps about 225 MB per process while any
   visible terminal draws (claude's spinner, a progress bar). I changed the budget to < 550 MB total while
   animating (quiet stays < 300 MB). The alternative is to stop animating terminals CODD is not focused on
   (they would freeze until you look at them). Keep the budget change?
2. **⌘Q in the middle of the wizard.** (Fix round 1: it now comes back by itself unless step 2 already
   imported projects; the rest of this question is I4's.) Today it writes no `onboarding.json`, but the wizard does not come
   back by itself next time (the root is no longer "new"); you reopen it from 說明 › 首次啟動設定…. Should
   it come back until it was finished or closed?
3. **The new copy** in §8 (onboarding lines not on the artboard, VoiceOver phrases, the new menu titles,
   `+ 加入帳號` in step 5).
4. **`scripts/release.sh --install`** is yours to run (it refuses inside Claude Code); please quit the old
   CODD from `build/user-m4` first.
5. **CLAUDE.md** (§10): applied by the orchestrator after the run (2026-10-19).

## 8. New copy not on the artboards (please review)

Onboarding (component; the artboard draws steps 1 and 2 only):
- Boot block: claude `找不到` / `先安裝 Claude Code`, `無法執行`; cswap `沒有安裝` /
  `選用：要切換多個帳號再安裝（0.26 以上）`, `<v> 太舊` / `需要 0.26 以上`, `讀不到狀態`, `讀取中…`; hooks
  `已是最新`, `需要更新（狀態列）` / `<file> · 全域狀態列是舊版`, `讀不到設定`, `尚未檢查`; data root `無法寫入`,
  `MCP <ep> 未啟動`, `MCP 未啟動`; import source `<n> 個專案` / `只讀取，不會改動`, `找不到` /
  `還沒用過 Claude Code？`, `讀不到`; later `已匯入 <n> 個`, `未匯入`; last lines `<step> waiting for
  operator_`, `[ OK ] ready`; counts `· <n> 失敗`, `<n> 項失敗`.
- Step 1: `claude 無法執行（<r>）：修好後按 ↻ 重新偵測。`, `找不到 claude：先安裝 Claude Code，裝好後按 ↻ 重新偵測。`,
  `cswap <v> 太舊：要切換多個帳號請更新到 0.26 以上。`, `讀不到 cswap 狀態：<r>`,
  `<file> 的全域狀態列是舊版：第 3 步可以預覽並更新。`, `讀不到 hooks 設定：<r>`, `資料夾無法寫入：<path>`,
  `MCP 未啟動：hooks 連接埠被占用，claude 暫時讀不到筆記。` with `[第 4 步 →]`.
- Stepper details: `◆ 需要更新 · 舊版 <n> 個事件`, `◆ 需要更新 · 狀態列`, `● 已是最新`, `▲ 讀不到設定`, `尚未檢查`,
  `cswap 太舊`, `讀不到 cswap 狀態`, `讀取中…`, `~/…/CODD/notes · :<port>`, `已略過 · 可在 SETTINGS 調整` (fix round 1: shortened to fit its 177 px column);
  the version line `1.0.0 (build 1) · macOS 27.0`.
- Step 2: `找不到 ~/.claude.json，沒有可以匯入的專案。之後可以用 ⌘N 或側欄的 + 加入專案。`,
  `// 沒有符合「<f>」的專案`, `// ~/.claude.json 裡沒有可以匯入的專案`, `~/.claude.json 太大（超過 64 MB），沒有讀取`,
  `讀不到 ~/.claude.json：<r>`, `~/.claude.json 無法解析`, `· <n> 個未分類`, `· 另有 <n> 個已在側欄`, `群組名稱`,
  `新群組`; footers `● MCP 運作中` / `○ MCP 未啟動`, `<n> 個帳號`.
- Step 3: `● 沒有舊版設定`, `▲ 讀不到設定`, `◆ 需要更新`, `● 已套用 · 備份 <name>` (I2: `（新檔案，無備份）`).
- Step 4: `○ 未註冊 · 這個資料夾不能註冊` (I2: `○ 未註冊 · <reason>`); CODEX `—` when unavailable.
- Step 5: `+ 加入帳號`, `更新 cswap 後按 ↻ 重新偵測；在那之前 session 用目前登入的帳號。`,
  `沒有 cswap 也能使用 CODD：session 用目前登入的帳號。要管理多個帳號，安裝 cswap（0.26 以上）後按 ↻ 重新偵測。`,
  `讀取 cswap 狀態中…`.
- Step 6: `允許通知：session 需要你回覆或出錯，而你不在 CODD 畫面前時，CODD 會發通知提醒你。`, `已套用`, `已是最新`,
  `未套用 · 之後可在 SETTINGS 調整`, `沒有 cswap`, `○ 這次執行不發通知`.
- VoiceOver: `已完成 / 已略過 / 目前步驟 / 尚未開始`, `CODD · 首次啟動設定`, `Return 鍵`, `重新偵測環境`,
  `預覽 settings.json 的變更`, `在 Finder 中顯示筆記資料夾`, `向 Claude Code 註冊 CODD 的 MCP`,
  `複製 Codex 的 MCP 設定`, `載入更多專案`, `可匯入的專案`, `選擇群組`, `路徑`, `新群組名稱`, `已選 <n> 個專案`,
  `（建議）`, `，目前的群組`, `允許 CODD 發通知`, `設定摘要`, `隱藏 worktree 與 SDK 專案`, account rows
  `帳號 #3 工作，使用中，5 小時剩 91%，1 週剩 15%，1w 重置 3d01h後`.

App and packages:
- Window title `首次啟動設定`; menu `說明 › 首次啟動設定…`; Settings › 關於 row `首次啟動設定` (EN `Onboarding`),
  hint 「重新看一次環境偵測、匯入專案、hooks、筆記本、帳號與通知；不會自動改動任何檔案。」, button `[重新執行]`
  (VoiceOver `重新執行首次啟動設定`).
- Data banners (plan §2.2): `<file> 是較新版本的 CODD 寫的（v<n>）：能讀的部分照用，這次的變更不會存進這個檔案`,
  `<file> 無法讀取，已移到 <aside>，改用預設值`, `<file> 無法轉換成這個版本的格式（<reason>）：原檔與備份都保留，這次改用預設值`,
  `<file> 是舊格式（v<n>），這個版本不認得：原檔保持不動`; buttons `[在 Finder 中顯示]`, `[知道了]`;
  `config.json 是較新版本的 CODD 寫的（v<n>），這個版本不會改寫它` (the rotate refusal).
- D4: 「CODD 換了識別碼：請把「登入時啟動」關掉再打開一次」.
- Menus (I3): `顯示方式 › SESSIONS / NOTES / STATUS / SETTINGS`, `筆記 › 筆記本 / 檔案 / 清理建議`,
  `Session › 筆記抽屜 / 新增群組… / 切換帳號 ▸` (entries `#3 工作 · 5h 剩 91% · 1w 剩 15%`, `自動切換設定…`,
  `沒有帳號資料`), `CODD › 暫停通知 1 小時 / 恢復通知`.
- VoiceOver (I3): states 等待中 / 錯誤 / 完成 / 工作中 / 壓縮中 / 閒置 / 啟動中 / 執行中 / Shell / 已結束 /
  已停止 / 無法連線, reasons 權限 / 提問 / 計畫 / 等待輸入, durations `n 秒 / n 分鐘 / n 小時 m 分鐘 / n 天 m 小時`,
  rows `修正登入 API 401，等待中 · 權限 · 3 分鐘，標籤：紅，Remote Control 已連線`, `EXT 外部 session`, `帳號 #2`,
  `stale，閒置超過 1 小時`, groups `<name> 群組，展開，n 個 session：等待中 1、工作中 1`, `NEEDS YOU，展開，3 個 session`,
  rail `SESSIONS，3 個需要你`, `筆記抽屜，n 則筆記`, `終端機字級 13`, `MCP <endpoint> 執行中|未啟動，n 個 client`,
  `hooks 正常|需要更新|未安裝|錯誤|注意`, `5h 剩 91% · …，自動切換門檻 n%`, `目前帳號 <名稱>，共 n 個帳號`,
  `前往 <title>`, `允許 <title>（回答 1）`, `最近使用` / `建議，未加入` / `已選` / `其他資料夾`, swatches
  `紅色 … 青色 / 無顏色`; packages: `移除 #tag`, `開啟 session：…` / `開啟專案：…`, `關閉 <title>`,
  `標註 n · 類型：說明，座標`, QuotaBarRow `5h 剩 91%`, switches 開 / 關.
- Changed copy: `+ 新增帳號` → `+ 加入帳號` (onboarding step 5), `還原前會先保存目前的內容` → `還原前會先儲存目前的內容`
  (notebook history), rail MCP `…未執行` → `…未啟動`.
- `release.sh --install`'s closing text (接下來：…四點).

## 9. Visible deviations from the Onboarding artboard

Nothing has been rendered yet (no snapshot pass in M5 so far); these come from reading the code against
`design/artboards-src/Onboarding.src.html`:

1. Asked for by the plan or the user: the brand reads CODD (SPEC §10); the node row is dropped; the data
   root is `~/Library/Application Support/CODD` (fix round 1: `~/…/CODD` in the name column, the full path
   leading the detail column, the grid kept) with notes in `notes/`
   (not `~/.codd/notebook`); step 3's detail is `◆ 需要更新 · 舊版 4 個事件` and the hooks detail
   `舊版 CODD web：…`; step 4's detail `~/…/CODD/notes · :47821`; the version line `1.0.0 (build 1) · macOS 27.0`.
2. A fifth boot row (the import source) keeps the header at `4 OK · 1 待處理`.
3. PATH elision is measured: three rows keep one more component than the artboard's text.
4. The `_` cursor blinks 1 s on / 1 s off.
5. Checkboxes are drawn 13 px squares; the header box shows `−` when partly checked.
6. Glows and the menu's drop shadow are layer shadows (absent from offscreen snapshots); the menu has no second
   amber glow.
7. At 1011 × 640: the toolbar hint and the footer's faint tail are dropped whole, columns shrink so PATH
   keeps 160 px and the header labels stay whole, rows scroll, the stepper drops its foot hint.
8. Stepper details are one line, cut at the end (the skipped step's now reads `已略過 · 可在 SETTINGS 調整`
   and fits).
9. Not on the artboard: hidden rows dimmed with `WORKTREE` / `SDK` marks, `[依父資料夾建議分組]` disabled when
   nothing is checked, `· 另有 n 個已在側欄`, the group menu opening below its select when there is no room.
10. The window's default size is 1240 × 820 (the artboard's 1440 × 900 is the design size); the traffic lights
    sit over the stepper's 52 px drag area.

## 10. Changes made in this step, and the CLAUDE.md lines

| What | Why |
|---|---|
| `scripts/m5-e2e.sh` (new) | the M5 end to end (§3) |
| `scripts/TEST-MAP.md` | M5 rows (onboarding, data files, identity and D25, stop while STARTING, tier policy, holder compat, accessibility, copy, release, zorder), the m5 ids, rule 4's wrap-up set |
| `App/Real/DataFilesMonitor.swift`, `App/AppDelegate+Data.swift` | dump `dataFiles.bannersQueued` (the e2e's one-banner-per-issue check without pressing 知道了) |
| `scripts/m5-perf.sh` (budget table) | `gpu_animating_total` < 550 MB with the reason |
| docs/ARCHITECTURE.md | M5 decisions (D15, D16, D18, D19, D21–D23 added to I1 / I2's), signing, repository layout, build commands, the budgets paragraph, the onboarding ⌘Q note, the dump key |
| README.md, docs/USER-GUIDE.zh-TW.md | final: every draft marker checked against the code (fixed: `+ 加入帳號`, the worktree wording, ⌘Q mid-way, the install staging, About's `1.0.0 (6)`, the keyboard / VoiceOver paragraph) |
| docs/ROADMAP.md, this report | M5 done, what remains; the stale ROADMAP allow entry removed from `scripts/tools/copy-audit-allow.txt` |

**CLAUDE.md (applied by the orchestrator after the run).** The build lines would gain, after the M3 packages:
`M4 packages CoddNotes, CoddMCP, CoddTextKit, CoddCodeEditor, CoddFiles, CoddNotebookUI, CoddAnnotateUI,
CoddCleanupUI and M5 packages CoddOnboarding, CoddDataStore (swift test --package-path Packages/<Name>
--scratch-path .build-<Name>); demos codd-markdown-demo, codd-code-demo, codd-files-demo,
codd-notebook-demo, codd-annotate-demo, codd-cleanup-demo, codd-onboarding-demo`; the end-to-end line would
add `scripts/m4-e2e.sh`, `scripts/m5-e2e.sh`, `scripts/m5-perf.sh` (alone, nothing else building),
`scripts/m5-compat.sh`, `LIVE=1 scripts/tools/zorder-selftest.sh` and `python3 -I scripts/tools/copy-audit.py`;
a release line `scripts/release.sh --dry-run | --output <temp dir>` (`--install` only by the user, outside
Claude Code); and the rules would add: the bundle id is `app.codd.CODD` (names through
`App/Support/CoddIdentity.swift`); every script that launches CODD sources `scripts/lib/zorder-guard.sh`;
never read or write the real defaults domains, `/Applications` or `~/.Trash`; test runs never write CODD's
defaults (D25); `~/.claude.json` and `~/.codex` join the files tests never touch.

## 11. Fix round 1 (2026-10-19)

The wrap-up test run's failures and the review's confirmed findings, most severe first. Lean testing
(「今晚繼續做，但要記得不要過度測試」): the suites of what changed, the app suite, and only the failing e2e
sections / scripts were run again; everything else waits for verify.

| Id | Cause | Fix | Regression test |
|---|---|---|---|
| test-1 CoddCore | The test compared against a second `sample()` (fresh UUIDs every call) and saved over the v99 file it had planted (refused, as designed) | Test only: one `layout` value; the current bytes written back directly | the test itself |
| test-2 CoddDataStore | `DataPreflight` reported `missing` for every session folder without `composer.json` / `answer.json` (a wildcard row's literal last part) | `missing` only for literal rows (`DataPreflight.candidates`) | `missingFile` (17 cases) |
| test-3/4/5 CleanupUI, StatusUI, SettingsUI | The audit flagged AppKit's legacy scroller parts (`NSAccessibilityScrollerPart`, unlabeled AXButton) | CoddUI `AccessibilityAudit` skips a scroller's children and the field editor | `scrollerPartsAreNotFindings` (fails without the fix) |
| test-6 CoddOnboarding | (a) the a11y test counted only views that are elements (CoddButton is exposed through its cell); the group menu's field editor counted as unlabeled; (b) `FixtureTests` looked rows up under `/var/…` while the script writes `realpath()`s (`/private/var/…`) | (a) counts and labels through CoddUI's audit, the field editor skipped; (b) the fixture's spelling | the tests themselves |
| test-7 CoddUI | (a) `makeFirstResponder` never asks `acceptsFirstResponder`: code could focus (and ring) the 7 custom controls without Full Keyboard Access; (b) NSButton's `accessibilityPerformPress` clicked a CoddButton but returned false | (a) their `becomeFirstResponder` refuses when not accepting; the test checks who holds focus; (b) `CoddButton.accessibilityPerformPress` | `focusFollowsFullKeyboardAccess`, `buttonIsLabelledByItsTitle` |
| test-8 app suite | Stale M4 menu lists (I3 added 筆記本 / 檔案 / 清理建議); a sidebar label test that needed today = 2026-10-15; the main-window audit (scroller parts); a removed defaults domain reads back as `[:]`, not nil (the migration wrote the marker for a new user); the sweep test's `\ud800` plant is repaired by `JSONValue.parse`; the Settings coordinator was released before its weak action ran | Tests updated; the audit fix; `DefaultsDomainMigration` treats an empty domain as missing; the plant is a `1e999` member (no Swift number holds it: the preflight's top-level scan skips it, LayoutStore cannot parse it); the test keeps the coordinator | `removedOldDomainWritesNothing` (CoddDataStore) and the 7 tests |
| test-9 m4-sidebar-dnd D4 | The launch's first session is revealed by an observation callback on a later turn, after the DEBUG drop hook selected the project | The hook waits 150 ms first (a user's drop always comes later) | D4 |
| test-10 m5-e2e | D2: the same `\ud800` plant; S1: expected STOPPED, but D20 applies the stop "as for any stop" and a stopped running claude is EXITED (the holder's SIGHUP, an EXIT frame); A1: the scroller parts (22) | D2 plants `1e999`; S1 accepts EXITED or STOPPED (not live); the audit fix | D2, S1, A1 |
| test-11 m5-perf | launch: logged after the claude registrations and the hook endpoint (about 40 ms after the rows were installed) on a Debug build whose main window takes 175 ms; idle visible: measured 12–22 s after launch, while every row's durations count seconds | The line is logged when the store installed the layout (`HolderSessionStore.onLoaded`); a `launch_to_sidebar.debug` row (< 450 ms; Release target < 400 ms unchanged); idle visible measured from 125 s (ARCHITECTURE and the script's table changed together) | `ONLY=launch,idle` |
| correctness-1 | Suggested group keys were the parent's position in the sorted catalog and user groups continued that count, so ↻ 重新偵測 could swap groups | Keys `new:<parent folder>` and `user:<n>` | `keysSurviveARedetect` (fails on the old keys) |
| correctness-2 | `PaneLayoutStore` wrote an empty `panes.json` 0.5 s into every first launch, so the gate never saw a new root again | No write while there is no file and nothing to keep | `aNewRootGetsNoEmptyFile`; two interrupted `-codd-onboarding auto` runs both logged `gate show=true reason=new-root` |
| correctness-3 | `bringForward` returned true while the first probe ran (no window yet), so the Dock click / 開啟 CODD / hotkey / a second instance showed nothing | False until the window exists (the caller shows the main window); logged `bring-forward skipped … probing=true` | `reopenRequestsGoToTheWizardWhileItIsOpen` |
| correctness-4, security-data-1 | `release.sh --output /Applications` `rm -rf`'d the installed app around --install's guards | Refuses `/Applications`, `~/Applications` (and below) and a folder whose `CODD.app` has no `.codd-release-output` marker (written into every output); build/release keeps working | dry runs: the three Applications paths and a foreign CODD.app exit 3, a marked folder and the default exit 0 |
| security-data-2 | `onboardingProbe` read the real `~/.claude.json` and transcripts on a test root without `-codd-claude-dir` | Skipped there (`OnboardingFacts.catalogIsProtected`), step 2 says `測試資料夾不會讀取 ~/.claude.json` | `theCatalogIsSkippedOnTestRootsWithTheUsersClaudeDirectory` |
| spec-fidelity-1 | The data-root name overflowed its 158 px column | `~/…/CODD` in the column (front elision), the full path leads the detail | TextTests, the demo PNGs looked at |
| spec-fidelity-2 | `已略過 · 之後可在 SETTINGS 調整` (191 px) cut in 177 px | `已略過 · 可在 SETTINGS 調整` | TextTests |
| spec-fidelity-3 | Cuts at 1011 × 640 | The sort hint and the footer's faint tail are dropped whole; LAST USED ↓ and TRANSCRIPTS keep their labels (PROJECT / GROUP minimums 132 / 126 px; PATH keeps 160) | LayoutTests, `step2-min.png` |
| test-0 | The parallel first run (4 at a time) | CoddHooks and CoddNotes passed alone (load flakiness); not changed | - |

**What ran in this round** (Debug, derived data `build/m5`, the window-stack watcher over the whole
session: `zorder samples=11293 withOwner=3131 violations=0 ignored=0 stopped=signal`):
- Package suites: CoddDataStore 44 passed; CoddUI 77; CoddOnboarding 23 + 58; CoddStatusUI 41,
  CoddSettingsUI 87, CoddCleanupUI 45, CoddDialogsUI 51 (`--skip PresenterTests`), CoddNotebookUI 65,
  CoddAnnotateUI 50, CoddFiles 63 + 23 (the UI packages for the CoddUI change); CoddCore: the fixed test
  only (`--filter`, a test-file change). Zero compiler warnings.
- App unit suite: `675 tests in 160 suites passed`.
- `scripts/m4-sidebar-dnd.sh`: `pass=25 fail=0`. `ONLY=D2,S1,A1 scripts/m5-e2e.sh` (D2, A1 ok; S1's old
  check) then `ONLY=S1,A1`: `pass=8 fail=0`, `A11Y screens=37 unlabeled=0 outsideKeyLoop=478`.
- `ONLY=launch,idle scripts/m5-perf.sh` (load1 1.52): `launch_to_sidebar 411 ms` (835 / 411 / 411, the
  first right after a rebuild) PASS < 450 (Debug); `idle_cpu_visible 0.161 %` PASS; `idle_cpu_hidden
  0.056 %`; `idle_cpu_holders 0.011 %`. Before the change (same build, this round): idle visible at 12 s
  0.74–1.02 %, the sample showing `SessionLine2View.draw` as the only work.
- `python3 -I scripts/tools/copy-audit.py`: `findings=0 failing=0 review=0`. `scripts/release.sh --dry-run`
  (default output): exit 0.
- `codd-onboarding-demo` PNGs (step 2 at 1011 × 640, step 4) looked at.

**Decisions taken in this round (reversible):** the Debug launch allowance and the steady-state idle
window (budgets, see test-11); the launch line at the store's load; S1 follows D20's "as for any stop"
(no product change: a stop of a STARTING claude ends EXITED with RESUME, like any stopped claude); group
keys `new:<path>` / `user:<n>`; the probe-time fallback to the main window (both windows open when the
wizard then appears); `release.sh`'s output refusals and its `.codd-release-output` marker; test roots
never read the user's catalog (new copy `測試資料夾不會讀取 ~/.claude.json`); the custom controls refuse
programmatic focus without Full Keyboard Access; the audit skips scroller parts and the field editor; the
preflight's `missing` only for literal rows; an empty legacy defaults domain counts as missing; the
shortened stepper text and the narrow-window drops.

**Not done / still open after this round:**
- Not re-run (they passed in the wrap-up run or were not touched): m5 `O1 O2 O3 D1 D3 K1 C1 I1`, the other
  e2e scripts, `scripts/m5-compat.sh`, the rest of `m5-perf.sh` (switch, memory, gpu), the fixture self
  tests, CoddHooks / CoddNotes. O1–O3 read the onboarding model through the dump; the key format change
  (`new:<path>`) and the boot line's drawing are not in what they check, but they have not run on this
  build.
- The < 400 ms launch target of a Release build is not measured by any script.
- The first probe still has no overall deadline (correctness-3 only stops it from swallowing the
  window requests).
- The DEBUG drop hook's 150 ms wait is a timing assumption (DEBUG only; D4 passed).
