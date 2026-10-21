# CODD Desktop: M3 report

Written 2026-10-17 after integration step I4 (end to end, numbers, docs). M3 = menu bar, accounts,
status, settings (docs/M3-PLAN.md): CODD knows the Claude accounts cswap manages and their remaining
quota without ever asking Anthropic's usage API. Accounts come from cswap's own state files (read
only) and `cswap switch`; quota comes from Claude Code's status line (a `codd-statusline` CLI injected
into every CODD claude session, chaining your own status line) and from cswap's cache. The menu bar,
the sidebar footer, the rail chip and Home USAGE show real data; accounts switch directly with UNDO;
auto-switch at ≤ 2 % (default OFF) works; the STATUS page and every Settings section of the artboard
exist and persist; the four §7.7 dialogs work; a configurable global hotkey shows CODD from any app.
This report covers the ten components (C1–C10), the five integration steps (I1a, I1b, I2, I3, I4),
how to run everything, the numbers, what is not done, and what you should try by hand.

**Status:**
- **Review round 1 (§9, 2026-10-17):** every confirmed review problem fixed (two high: the unquoted
  status-line command that broke every CODD session's status line on the standard data root, and
  quota.json keyed by slot number only), with regression tests. After it: Debug and Release build
  with zero warnings from fresh derived data (`build/m3fix1-clean`, `build/m3fix1-rel`); app tests
  428/428; CoddCore 390, CoddClaudeSettings 78, CoddSettingsUI 55, CoddStatusUI 28, CoddDialogsUI 42
  (presenter tests skipped), the other packages unchanged and green, every package zero warnings on
  clean `--build-tests` builds; `scripts/m3-e2e.sh` 166/166 (new A5d, A12 Home run, A13d, A15),
  `scripts/m2-e2e.sh` 110/110, `scripts/m1-e2e.sh` 42/42, `scripts/m1-smoke.sh` 22/22,
  `scripts/m2-fixtures/selftest.sh --with-app` 268/268, `scripts/m3-fixtures/selftest.sh` 333/333,
  `-CODDSelfTest YES` → `SELFTEST OK`, `-codd-shortcut-matrix` 67/67. The bullets below are the I4
  state unless they say otherwise.
- **Builds and tests:** Debug and Release build with zero warnings from fresh derived data
  (`build/m3i4`, `build/m3i4-rel`). App tests 412/412 (103 suites). Every package suite green with
  zero warnings on clean `--build-tests` builds: CoddCore 379, CoddHolder 34 + 127, CoddHooks 125 + 42,
  CoddTerminal 68, CoddComposer 85, CoddUI 32, CoddPreferences 30, CoddClaudeSettings 77, CoddHost 32,
  CoddStatusUI 27, CoddSettingsUI 52, CoddDialogsUI 41 (its 7 presenter tests skipped, see §3).
- **End to end:** `scripts/m3-e2e.sh` 148/148 (A1–A14, 29 app launches, fake claudes and a fake
  cswap only), green on two consecutive runs of the final binary (and on the two runs before the last
  instrumentation edits); `scripts/m2-e2e.sh` 110/110, `scripts/m1-e2e.sh` 42/42,
  `scripts/m1-smoke.sh` 22/22, `scripts/m2-fixtures/selftest.sh --with-app` 268/268,
  `scripts/m3-fixtures/selftest.sh` 333/333, `-CODDSelfTest YES` → `SELFTEST OK`,
  `-codd-shortcut-matrix` 67/67.
- **Isolation held:** every automated launch ran in the background on a temp data root with a temp
  Claude directory, a fake cswap and fake claudes; no `@example.com` and no profile slug in any data
  root file, dump or log; every `exec` log line named a path inside the temp folder; no login item and
  no global hotkey other than `ctrl+option+cmd+f12` was registered; no process of any run was left.
- **Fixes in this step:** four small DEBUG-path fixes and additions (§8), no product bug found by the
  e2e. Measurement log lines were added (`STATUS shown ms=`, `SETTINGS shown ms=`, the dump's
  `accounts.readMs`).
- **Default mode:** real mode on `~/Library/Application Support/CODD`, as before. New files there:
  `bin/codd-statusline-<hex12>`, `bin/codd-statusline`, `quota.json`, and (once something changes)
  `preferences.json` and `claude-settings-backups.json`.
- **Not verified with the real thing:** automated runs never start a real `claude`, never run the
  real cswap, never touch your Keychain, never post a real notification, never register a login item
  or ⌥Space, never write your `~/.claude/settings.json`. The 繁體中文 checklist in §6 is what is left
  for you. **One question for you:** D34 (cswap aliases are ASCII only), §7.

---

## 1. What was built

### Components (parallel, outside App/)

**C1 core — `Packages/CoddCore`**
- `Cswap/CswapStateReader.swift`: read-only reader of cswap 0.26's state (`sequence.json`,
  `cache/usage.json` schema 2 with cswap's identity guard, `configs/` for the plan, `sessions/<n>-*`
  profiles with stale markers and the settings symlink check, `.claude.json` / legacy `.config.json`
  identity), `fingerprint()` with fixed labels, `currentLogin()`, `currentLoginToken()` (I2). Results
  carry no e-mail, no organizationName and no profile path (descriptions and mirrors redacted).
- `Cswap/CswapAccountKey.swift` (D6 table, FNV-1a `cfg-` keys, `profileKeys`), `CswapAlias` (exact
  `normalize_alias` port), `CswapClient` additions (`version`, `addCurrentLogin`, `setAlias`,
  `switchAccount(to:maxAttempts:onAttempt:)`, every string redacted).
- `Accounts/`: `EmailRedaction`, `QuotaBook` / `QuotaStore` (quota.json v1), `QuotaAttribution`
  (D6 incl. grace, reset fingerprint, suspected login change), `WeeklyPaceCalculator` (exact
  `pace.py` port), `AccountAssembler`; `Account` extended additively.
- `Launch/`: `StatusLineInjection` (replaces the placeholder), `LaunchRequest.claudeConfigDir`,
  `LaunchSpec.coddEnvironment` / `removedNames`, `CODD_STATUSLINE_CHAIN` ≤ 16 KiB.
  `Registry/CswapProcessDetector.swift` (cswap menubar / auto). 107 new tests.

**C2 hooks — `Packages/CoddHooks`**
- `POST /statusline` on the same server, port and token (Origin / Host / token / session header /
  body length rules, 64 KiB cap), 204 before decoding, `HookServer.statusLines` (newest 256),
  statistics. `StatusLineReport.decode` (tolerant `resets_at`: epoch s, ms, ISO).
- `CoddHookClient`: Foundation-free `JSONScan`, `StatusLineAccountKey`, base64, `StatusLineCommand`,
  `StatusLineMain` (D8 process behaviour: chain in its own process group with the same stdin, POST
  ≤ 300 ms, chain timeout 10 s, signals forwarded). Executable `codd-statusline` (no Foundation).
  A real fork race in signal forwarding was found and fixed. 77 new test functions.

**C3 claude-settings — `Packages/CoddClaudeSettings` (new)**
- Lossless `OrderedJSON` (key order, raw number tokens, JSON.stringify-compatible serializer),
  `ClaudeSettingsFile` (indent, trailing newline, fingerprint), inspection (CODD web leftovers in both
  hook shapes, foreign tools with blocking timeouts, status-line states, duplicate notifications),
  `DesktopStatusLine` (D11 guard form, parses back), `ClaudeSettingsInstaller` (plan / diff / apply
  with backup / backups / restore), `UserStatusLine` (D35). 77 tests; byte-reference fixtures.

**C4 host — `Packages/CoddHost` (new)**
- `HostSampler` (CPU from `host_processor_info`, memory, disk with cached important-usage capacity,
  swap, battery, boot time, host name), `HostHistory`, `ByteText`, `MainThreadLatencyProbe`. 32 tests.

**C5 ui-kit — `Packages/CoddUI` (new)**
- The design system moved out of App/ verbatim (theme, controls, ticker, formats) plus the M3
  primitives (`QuotaBarRow*`, `MeterView`, `SparklineView`, `CardView`, `CheckboxButton`,
  `StepperControl`, `KbdView`, `ModalFrameView`, `DiffLinesView`, `SectionHeaderView`, `FormRowView`)
  and `codd-ui-gallery`. `MIGRATION.md` lists every move and edit. 32 tests.

**C6 status-ui — `Packages/CoddStatusUI` (new)**: `StatusSidebarView` + `StatusPageView` of the
Status artboard, value models with absolute dates ticking at 1 Hz, per-section diffing, samples for
11 states, `codd-status-demo`. 26 tests (27 after I2).

**C7 settings-ui — `Packages/CoddSettingsUI` (new)**: all 13 sections bound to `CoddPreferences`,
search, per-section reset, D17 disabled rows, `KeyCombo` / `HotkeyRecorderView` / exclusive Carbon
`GlobalHotkey`, `codd-settings-demo`. 52 tests.

**C8 dialogs-ui — `Packages/CoddDialogsUI` (new)**: dialogs A (switch), B (Hook 差異), C (add
account), D (quit) and `DialogPresenter` (sheets, the child panel for C), samples,
`codd-dialogs-demo`. 49 tests (42 plus 7 presenter tests that order windows front).

**C9 fixtures — `scripts/m3-fixtures`**: `make-cswap-state.sh` (cswap's exact writer formats,
`--accounts 4`, `--stale n`), `fake-cswap.py` (`--version`, `list` / `status --json`, `switch` with
`.claude.json` splice and failure modes, `add`, `alias`, a JSONL call log), `fake-claude-m3.sh`
(status line runner, `FAKE_REGISTRY_DIR=auto`, masked env, fake `/login`), `make-claude-settings.sh`
(your settings' shape), `rate-limits.sh`, `selftest.sh` (333 checks). Finding: cswap's real profile
slug is `north_example.com`, so the e2e greps `example.com`.

**C10 prefs — `Packages/CoddPreferences` (new)**: the preferences model (71 leaf paths, artboard
defaults with D15's exceptions) and `PreferencesStore` (tolerant per field, unknown keys kept,
newer read-only, corrupt moved aside, atomic 0600). 30 tests.

### Integration steps (sequential, App/)

**I1a ui-switch** — project graph (7 local packages, the `codd-statusline` tool target embedded and
signed like codd-hook), the D30 switch (12 App files deleted, 69 files import CoddUI; one real bug in
`InputField` fixed: `onChange` stopped firing once the field was in a window), `PreferencesService`
(load off main, D14 migration on the standard root only, 300 ms debounced save, `-codd-set-pref`),
stale threshold and notifications from preferences; a latent M1/M2 sidebar filter-row squeeze fixed.

**I1b wiring** — `CswapAccountStore` (D1–D7, D31, D38), the status-line pipeline (binary install,
injection per launch / RESUME / RESTART, `coddEnvironment` into `ShellEnvironment.build(extra:)`,
`removedNames` dropped, throttled ingest, attribution), D12 pinning (⌘N select, launch-profile pins,
RESUME / RESTART refusals, per-profile transcripts and registry folders), every surface on real data
(footer, rail, Home USAGE, menu bar D23, status item counts / pause), the M1 fake claude's greedy
settings parse fixed.

**I2 status** — the STATUS area (sidebar swap, 5 s refresh, CoddHost sampling, latency probe,
discrete-change rebuilds that cut STATUS CPU in half), `ClaudeSettingsService` + dialog B, dialog A,
dialog C with ephemeral shells, `AutoSwitchRunner` + `AppNotifier` (one notification delegate), the
D36 host line, ⌘K switch actions.

**I3 settings** — the Settings window on CoddSettingsUI with every functional row wired (Dock D20,
login item D21 through an injectable service, close D19, quit D18 with dialog D and the Apple-event
quit reason, hotkey D22, CRT, terminal font / size, reduce motion, NO HOOK grace, stale, externals,
the D29 notification matrix, Dock badge, menu bar icon, cswap path, aliases, confirm before switch,
auto-switch with live preview, hooks components / backups / restore, reset all, diagnostics), section-
level commits so a menu bar pause is never overwritten.

**I4 e2e (this step)** — `scripts/m3-e2e.sh` (A1–A14), the full verification (§3), the
measurements (§4), the DEBUG fixes and instrumentation of §8, READMEs for the five new packages that
had none (CoddUI, CoddPreferences, CoddStatusUI, CoddSettingsUI, CoddDialogsUI), docs/ARCHITECTURE.md
(M3 decisions, layout, process model with codd-statusline and `/statusline`, data root tree, the App
sections for accounts / quota / status line, STATUS / installer / dialogs, Settings / preferences /
lifecycle / hotkey, Claude's files), CLAUDE.md build lines, docs/ROADMAP.md, this report.

## 2. How to run

```bash
# Packages (separate scratch paths avoid lock clashes)
for p in CoddCore CoddHolder CoddHooks CoddTerminal CoddComposer CoddUI CoddPreferences \
         CoddClaudeSettings CoddHost CoddStatusUI CoddSettingsUI; do
  swift test --package-path Packages/$p --scratch-path .build-$p
done
swift test --package-path Packages/CoddDialogsUI --scratch-path .build-CoddDialogsUI --skip PresenterTests

# UI demos (PNG snapshots, offscreen)
swift run --package-path Packages/CoddStatusUI --scratch-path .build-CoddStatusUI codd-status-demo --fonts App/Fonts --snapshot /tmp/status-demo

# App + tests
xcodegen generate
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build
CODD_BACKGROUND=1 xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test

# End to end (temp roots, temp Claude dirs, fake claudes, fake cswap; they end every process they started)
scripts/m3-e2e.sh            # M3: A1–A14; KEEP=1 keeps the temp folder; CODD_APP=<binary>
scripts/m2-e2e.sh; scripts/m1-e2e.sh; scripts/m1-smoke.sh
scripts/m2-fixtures/selftest.sh --with-app build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
bash scripts/m3-fixtures/selftest.sh
```

**The app on your real data** (what you use day to day): just open it
(`open build/dd/Build/Products/Debug/CODD.app`). On the standard data root CODD finds the real cswap
by itself: Settings › 帳號 › cswap 路徑 if you set one, else `cswap` on your login shell's PATH, else
`~/.local/bin/cswap`; it reads `~/.claude-swap-backup` (read only) and `~/.claude.json`'s identity,
and shows `需 ≥ 0.26` for an older cswap. Your status line is read from `~/.claude/settings.json`
(and a project's `.claude/settings.json` / `.claude/settings.local.json`, D35) at every launch of a
CODD claude session and chained behind `codd-statusline`; the file is written only when you press
`套用並備份` in the Hook 差異 dialog.

**A throwaway try-out with the fakes** (nothing of `~/.claude`, your cswap or your accounts is read):

```bash
APP=build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
ROOT="$(mktemp -d "${TMPDIR%/}/codd-try.XXXXXX")"; ROOT="$(cd "$ROOT" && pwd -P)"
scripts/m2-fixtures/make-root.sh "$ROOT/data"
scripts/m3-fixtures/make-cswap-state.sh "$ROOT/home/.claude-swap-backup" "$ROOT/home/.claude"
scripts/m3-fixtures/make-claude-settings.sh "$ROOT/home/.claude" --legacy   # your settings' shape
mkdir -p "$ROOT/bin" "$ROOT/home/.claude/sessions" "$ROOT/work"
cp scripts/m3-fixtures/fake-cswap.py "$ROOT/bin/cswap"
printf 'FAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n' "$ROOT/home/.claude-swap-backup" "$ROOT/cswap-calls.jsonl" >"$ROOT/bin/cswap.env"
cp scripts/m3-fixtures/fake-claude-m3.sh "$ROOT/bin/fake-claude"
printf 'FAKE_REGISTRY_DIR=auto\nFAKE_DEFAULT_CLAUDE_DIR=%s\nFAKE_RATE_LIMITS_FILE=%s\nFAKE_CSWAP_ROOT=%s\nFAKE_LOGIN_AS=4\n' \
  "$ROOT/home/.claude" "$ROOT/rl.json" "$ROOT/home/.claude-swap-backup" >"$ROOT/bin/fake-claude.env"
scripts/m3-fixtures/rate-limits.sh "$ROOT/rl.json" 9 $(( $(date +%s) + 9000 )) 85 $(( $(date +%s) + 260000 ))
"$APP" -codd-data-root "$ROOT/data" -codd-claude-dir "$ROOT/home/.claude" \
  -codd-cswap-path "$ROOT/bin/cswap" -codd-cswap-root "$ROOT/home/.claude-swap-backup" \
  -codd-claude-path "$ROOT/bin/fake-claude" -codd-login-env NO -codd-notifications NO -codd-shell-argv "/bin/zsh -f"
# ⌘N a claude session in $ROOT/work: the footer shows #3 工作 91 % / 15 % from `statusline`;
# switch accounts (the fake cswap logs every call), try STATUS, Settings, 加入帳號 (FAKE_LOGIN_AS=4).
# Clean up: pkill -TERM -f "$ROOT/"; sleep 1; pkill -KILL -f "$ROOT/"; rm -rf "$ROOT"
```

Mock data (screenshots): `"$APP" -codd-mock -codd-show status|settings-<section>|dialog-switch|dialog-hooks|dialog-add|dialog-quit -codd-snapshot <png> -codd-quit-after 4`.
DEBUG flags are listed in `App/Real/RealModeOptions.swift`; `-codd-dump-state <file>` writes what
the e2e checks.

## 3. Test results (2026-10-17)

| Suite | Result |
|---|---|
| App (`xcodebuild test`) | 429 tests in 106 suites passed after review round 1 and the §10 guard (I4 state: 412 in 103 suites, 299 after M2 + 113 in M3: UI switch 15, background launches 3, wiring 32, status 25, settings and lifecycle 36, I4 2) |
| CoddCore | 390 passed after round 1 (I4: 379 = 271 after M2 + 107 C1 + 1 I2) |
| CoddHolder | 34 + 127 passed (unchanged) |
| CoddHooks | 125 + 42 passed (90 after M2 + C2's 77 test functions, several parameterized) |
| CoddTerminal / CoddComposer | 68 / 85 passed (unchanged) |
| CoddUI / CoddPreferences / CoddClaudeSettings / CoddHost | 32 / 30 / 78 / 32 passed (new; CoddClaudeSettings 77 at I4) |
| CoddStatusUI / CoddSettingsUI | 28 / 55 passed (new; 27 / 52 at I4) |
| CoddDialogsUI | 42 passed (41 at I4) with `--skip PresenterTests` (7 presenter tests not run here: they order test windows front; C8 ran them green) |
| Builds | Debug and Release `** BUILD SUCCEEDED **`, zero `warning:` lines, fresh derived data; every package `swift build --build-tests` from an empty scratch path: zero warnings |
| `scripts/m3-e2e.sh` | `E2E pass=166 fail=0` after round 1 (482 s, about 8 minutes); at I4 `E2E pass=148 fail=0` on two consecutive runs (output below, I4 state; about 6 minutes) |
| `scripts/m2-e2e.sh` | `E2E pass=110 fail=0` |
| `scripts/m1-e2e.sh` / `scripts/m1-smoke.sh` | `E2E pass=42 fail=0` / `SMOKE pass=22 fail=0` |
| `scripts/m2-fixtures/selftest.sh --with-app` | `FIXTURES pass=268 fail=0` |
| `scripts/m3-fixtures/selftest.sh` | `M3FIXTURES pass=333 fail=0` |
| `-CODDSelfTest YES` / `-codd-shortcut-matrix YES` | `SELFTEST OK` (timers skipped: the window is not on screen in background mode, as before) / `SHORTCUTS ok=67 fail=0` |
| Mock snapshots | STATUS (top and HOOKS), every Settings section, dialogs A–D and the menu bar panel rendered from the final binary and compared by eye with the Status, Settings, StatusDialogs and MenuBar artboards (§5 lists the visible deviations) |

How the e2e is laid out: one mktemp folder; one group folder per scenario group, each with its own
data root (make-root.sh), home (`.claude`, `.claude.json`, `.claude-swap-backup` from
make-cswap-state.sh), copies of the fake cswap and the fake claude with sidecars, a rate-limits file
and a work folder: `a` (A1–A3), `b` (A4), `c` and `e` (A5), `f` (A6), `g` (A7), `h` (A8, A9), `i`
(A10), `j` (A11), `k` (A12), `l` (A13, A14). Every wait polls the state dump every 100 ms and is
bounded (≤ 30 s). The fake cswap's JSONL call log is what the switch / add / list checks read.

```
E2E root=<tmp> app=build/m3i4/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
E2E ok   A2 #3 turns statusline 91 % / 15 % within 15 s
E2E ok   A1 accounts ready, cswap 0.26.0, R7 order #2 #3 #1
E2E ok   A1 active #3 (the .claude.json identity), aliases as cswap stores them
E2E ok   A1 plans MAX 20x from the config backups
E2E ok   A1 #2 from the cswap cache (5h 98 %, 1w 46 %, source cswap cache)
E2E a1 exit=0
E2E ok   A1 app quit by itself
E2E a1 claude session=89c0062b-1dee-46e8-aa23-2afba2be081d fake pid=79541
E2E ok   A2 --settings carries statusLine = <dataRoot>/bin/codd-statusline-<hex12> with the user's padding
E2E ok   A2 the hooks are still all there next to it (14 events)
E2E ok   A2 the fake claude saw the statusLine command at startup
E2E ok   A2 CODD_STATUSLINE_CHAIN decodes to the user's own command
E2E ok   A2 the chained status line printed USER-SL-ok and exited 0
E2E ok   A2 the claude is unpinned and follows #3
E2E ok   A2 statusline counters: reports accepted, last key default -> #3, nothing dropped
E2E ok   A2 quota.json written with mode 0600
E2E ok   A2 quota.json keeps #3 from statusline (9 / 85 used) and #2 from cswap
E2E ok   A2 log: statusline first report key=default account=3
E2E ok   A3 pinned session: #2 turns statusline 80 % / 70 % (key cswap-2)
E2E ok   A3 the active account is still #3 and keeps its own numbers
E2E ok   A3 the external whose registry sits in the profile's sessions folder is listed
E2E a2 exit=0
E2E ok   A3 app quit by itself
E2E a2 pinned session=aa9838e3-779b-4b99-bb81-099db42ca1c7 fake pid=79980
E2E ok   A3 dump: the session carries account 2, pinned (the #2 chip)
E2E ok   A3 log: pinned session=… account=#2
E2E ok   A3 the pinned claude saw CLAUDE_CONFIG_DIR (masked) and no API key
E2E ok   A3 its registry file went into the profile's sessions folder (FAKE_REGISTRY_DIR=auto)
E2E ok   A3 the profile path never appears in the dump or the log
E2E ok   A3 launch-profile pin: #2 turns statusline 70 % / 60 % (key cswap-2)
E2E a3 exit=0
E2E ok   A3 launch-profile run quit by itself
E2E ok   A3 launch-profile session records account 2 (pinned)
E2E ok   A3 launch-profile claude saw CLAUDE_CONFIG_DIR
E2E ok   A3 launch-profile: the profile path never appears in the dump or the log
E2E ok   A4 switch: the dump shows #2 active
E2E ok   A4 UNDO: back on #3, lastSwitch is the undo from #2
E2E b1 exit=0
E2E ok   A4 switch run quit by itself
E2E ok   A4 fake cswap: switch 2 --json, then switch 3 --json (UNDO), nothing else switched
E2E ok   A4 log: the toast's UNDO was pressed and #3 is active again
E2E ok   A4 cswap's state says #3 again
E2E ok   A4 failure: switchState failed with a redacted message
E2E b2 exit=0
E2E ok   A4 failure run quit by itself
E2E ok   A4 failure: still on #3, lastSwitch outcome failed
E2E ok   A4 failure: the log names the failure without an e-mail
E2E ok   A4 lock: active #2 after the retries
E2E b3 exit=0
E2E ok   A4 lock run quit by itself
E2E ok   A4 lock: exactly three switch 2 --json calls in this run
E2E ok   A4 lock: log switched to=#2
E2E ok   A5 auto-switch to #2 (the R7-first eligible account)
E2E ok   A5 the notification was recorded (suppressed: notifications off)
E2E ok   A5 fake cswap: exactly one switch 2 --json
E2E #2 weekly reset 2026-10-18T20:36:45.000Z (1792355805)
E2E ok   A5 a low report for #2 inside the cooldown (1w 1 %)
E2E ok   A5 inside the cooldown: no second switch call
E2E ok   A5 the runner says cooling-down
E2E c1 exit=0
E2E ok   A5 run quit by itself
E2E ok   A5 quota.json keeps the cooldown (autoSwitch.lastAt) and #2's low week
E2E ok   A5 log: auto-switch to=#2 from=#3 window=weekly remaining=1
E2E ok   A5 relaunch: #2 active and low, the cooldown read back from quota.json
E2E c2 exit=0
E2E ok   A5 relaunch quit by itself
E2E ok   A5 relaunch: still exactly one switch call in total
E2E ok   A5 all low: none-eligible decided and notified
E2E ok   A5 all low: recorded once (suppressed), no switch
E2E e1 exit=0
E2E ok   A5 all-low run quit by itself
E2E ok   A5 all low: the log says none eligible exactly once
E2E ok   A5 all low: the fake cswap never switched
E2E legacy events: Notification,PermissionRequest,PostToolUse,PostToolUseFailure,PreToolUse,SessionEnd,SessionStart,Stop,StopFailure,UserPromptSubmit
E2E f1 exit=0
E2E ok   A6 plan run quit by itself
E2E ok   A6 plan: removes exactly the 10 CODD web events, adds the desktop status line
E2E ok   A6 plan: hook-tap and osascript kept
E2E ok   A6 plan: inspection saw the web leftovers and both foreign tools
E2E ok   A6 plan: settings.json untouched, no backup
E2E f2 exit=0
E2E ok   A6 apply run quit by itself
E2E backup: settings.json.codd-bak-20261017-163748
E2E ok   A6 apply: log names the backup
E2E ok   A6 apply: the backup holds the original bytes, mode kept
E2E ok   A6 apply: every hook-tap / osascript handler and every other key byte-identical
E2E ok   A6 apply: no status-writer.js and no codd-statusline.js left
E2E ok   A6 apply: statusLine is the desktop guard wrapper chaining the user's command
E2E ok   A6 apply: the wrapper renders the user's status line (app not running)
E2E ok   A6 apply: the backups index records the reason
E2E f3 exit=0
E2E ok   A6 second plan run quit by itself
E2E ok   A6 second plan: no changes
E2E f4 exit=0
E2E ok   A6 touched run quit by itself
E2E ok   A6 touched after the plan: refused (changedSinceRead)
E2E ok   A6 touched after the plan: content unchanged, no new backup
E2E f5 exit=0
E2E ok   A6 uninstall run quit by itself
E2E ok   A6 uninstall: statusLine is the user's command again
E2E ok   A6 uninstall: a second backup holds the applied file
E2E ok   A6 uninstall: foreign handlers still byte-identical
E2E g1 exit=0
E2E g1 ran 5.51s
E2E ok   A7 keep-running: the app quit by itself
E2E ok   A7 keep-running: long before its quit-after (40 s)
E2E quit shell session=ed65b5cc-3deb-42b3-a9b3-6b27361880e0 holder=84302
E2E ok   A7 dialog D was shown for 1 running session and answered keep-running
E2E ok   A7 log: quit trigger=user decision=ask, then quit choice=keep-running
E2E ok   A7 keep-running: the holder survived
E2E g2 exit=0
E2E ok   A7 stop-all run quit by itself
E2E ok   A7 stop-all: every session stopped before the quit
E2E ok   A7 stop-all: the holder is gone
E2E ok   A8 a waiting external counts as attention
E2E ok   A8 menu bar counts mode: title ◆1
E2E h1 exit=0
E2E ok   A8 run quit by itself
E2E ok   A8 the three assignments applied (set-pref)
E2E ok   A8 stale 1800 s reached the store
E2E ok   A8 Dock off wanted (.accessory), background run stays accessory
E2E ok   A8 no login item on a test root
E2E ok   A8 set-pref values are never written (no preferences.json)
E2E ok   A9 hotkey registered on the test combo
E2E ok   A9 log: hotkey registered combo=ctrl+option+cmd+f12
E2E i1 exit=0
E2E ok   A10 run quit by itself
E2E ok   A10 four accounts in R7 order, #4 MAX 5x
E2E ok   A10 menu bar: 3 rows (the active #3 among them) + ▸ 全部帳號 4
E2E ok   A11 add-account ends added within 30 s
E2E ok   A11 dump: #4 studio is managed, #3 active again
E2E j1 exit=0
E2E ok   A11 run quit by itself
E2E ephemeral session=bfae7102-89e6-40e7-896f-45d3e8f672cc
E2E ok   A11 the ephemeral shell typed the login and saw it change
E2E ok   A11 fake cswap: add --slot 4 --alias studio, then switch 3 --json
E2E ok   A11 the ephemeral session ended and its folder is gone
E2E ok   A11 cswap's state: #4 studio, #3 active again
E2E j2 exit=0
E2E ok   A11 工作室 run quit by itself
E2E ok   A11 工作室 refused by cswap's rule before cswap runs, then cancelled
E2E ok   A11 工作室: no add call in the fake cswap log
E2E ok   A11 工作室: the ephemeral session is gone too
E2E ok   A12 three claude holders running
E2E ok   A12 three CODD claudes attached and reporting
E2E number app idle CPU with 3 reporters: 0:00.78 -> 0:01.03 over 10.03 s = 2.49 %
E2E number app footprint with 3 fake claudes: 361 MB
E2E ok   A12 idle CPU with 3 reporters below 5 % (sanity bound; the report has the number)
E2E number codd-statusline (this build, global mode, endpoint up, no chain): 3.47 ms per run
E2E ok   A12 the app received the 200 reports
E2E ok   A12 codd-statusline below 25 ms per run in this build (release target < 10 ms, see the report)
E2E k4 exit=0
E2E ok   A12 measurement run quit by itself
E2E l1 exit=0
E2E ok   A13 guard run quit by itself
E2E ok   A13 -codd-hooks-apply into the real ~/.claude refused
E2E ok   A13 refused before the plan (nothing read): no hooks-plan line, no plan in the dump
E2E ok   A13 nothing was created in the real ~/.claude
E2E l2 exit=0
E2E ok   A13 unsupported state run quit by itself
E2E ok   A13 unsupported state: accounts unavailable with the D1 copy
E2E ok   A13 unsupported state: no cswap list at launch (only --version)
E2E ok   A13 explicit refresh: the cswap list fallback shows the accounts
E2E l3 exit=0
E2E ok   A13 refresh run quit by itself
E2E ok   A13 exactly one cswap list --json in total
E2E ok   A13 log: cswap list fallback
E2E ok   A14 a pinned #2 session first (profile usable, option enabled)
E2E l4 exit=0
E2E ok   A14 pinned run quit by itself
E2E ok   A14 cswap's stale marker written next to the profile
E2E ok   A14 RESUME of the pinned session refused with the problem banner
E2E l5 exit=0
E2E ok   A14 stale run quit by itself
E2E ok   A14 #2 profile stale in the dump (never its path)
E2E ok   A14 ⌘N option for #2 disabled (follow still enabled)
E2E ok   A14 a new pin to #2 refused with the same text, nothing started
E2E ok   A14 the stopped session stays stopped (RESUME refused, logged)
E2E ok   A14 the pinned session is still STOPPED and pinned to #2
E2E exec lines:
E2E      6 exec cswap path=<tmp>/b/bin/cswap sub=switch
E2E      5 exec cswap path=<tmp>/l/bin/cswap sub=--version
E2E      5 exec cswap path=<tmp>/f/bin/cswap sub=--version
E2E      4 exec cswap path=<tmp>/k/bin/cswap sub=--version
E2E      3 exec cswap path=<tmp>/b/bin/cswap sub=--version
E2E      3 exec cswap path=<tmp>/a/bin/cswap sub=--version
E2E      2 exec cswap path=<tmp>/j/bin/cswap sub=switch
E2E      2 exec cswap path=<tmp>/j/bin/cswap sub=--version
E2E      2 exec cswap path=<tmp>/g/bin/cswap sub=--version
E2E      2 exec cswap path=<tmp>/c/bin/cswap sub=--version
E2E      1 exec cswap path=<tmp>/l/bin/cswap sub=list
E2E      1 exec cswap path=<tmp>/j/bin/cswap sub=add
E2E      1 exec cswap path=<tmp>/i/bin/cswap sub=--version
E2E      1 exec cswap path=<tmp>/h/bin/cswap sub=--version
E2E      1 exec cswap path=<tmp>/e/bin/cswap sub=--version
E2E      1 exec cswap path=<tmp>/c/bin/cswap sub=switch
E2E ok   A13 every exec line (D38) names a path inside the temp folder
E2E ok   A13 the only exec tools are cswap (claude --version runs only with Settings open)
E2E ok   A13 no @example.com in any data root file (quota.json, preferences.json, layout, sessions…)
E2E ok   A13 no @example.com in any dump or app log
E2E ok   A13 no example.com (covers the plan's example-com and cswap's real slug) in any dump or app log
E2E ok   A13 the quota caches hold no e-mail
E2E leftover processes before cleanup: 0
E2E pass=148 fail=0
```

## 4. Measured numbers (this Mac)

How measured: the Debug build `build/m3i4` unless stated, launched in the background on temp roots
with the fakes (a scratch script, not in the repo, built like `scripts/m3-e2e.sh`'s groups); CPU = `ps -o cputime` over 10 s starting 12 s
after launch, with `-CODDForceVisibleTimers YES` so the 1 Hz ticker runs as if visible (background
windows sit behind yours and were reported occluded, so libghostty did not draw); footprint =
`footprint <pid>` (phys_footprint) at 22 s; the rest from the log lines and dump keys named in the
table. "3 reporting claudes" = three fake claudes whose status line runs every second (the fixture
also prints two lines into its terminal per run); "silent" = the same with the status line off.

| What | Measured | Budget |
|---|---|---|
| `codd-statusline`, release, no chain, endpoint up (the running app), 200 runs from `zsh -f` | 2.93–4.68 ms per run (3 rounds: 4.68, 2.93, 2.94; `/usr/bin/true` 1.57 ms in the same loop); C2: 4.03 ms | < 10 ms |
| same with a `printf` chain / endpoint down / the app's bundled Debug copy | 5.43 ms / 2.50 ms / 3.53 ms (e2e A12, bundled copy: 3.39–5.29 ms) | — |
| HOST sample cost in the app (`status.sampleMs`, incl. the hop off the main actor) | 0.52 ms (I2: 0.72 ms); standalone median 0.09–0.13 ms, first sample of a sampler about 20 ms (C4) | < 2 ms |
| STATUS open (`STATUS shown ms=`: model build + apply + layout of page and sidebar, 3 claudes) | 20.5 ms | — |
| Main-thread latency p99 with STATUS shown (`status.p99`) | 0.06 ms (I2: 0.8 ms) | — |
| Idle CPU, STATUS shown | 3 reporting claudes 1.2 % (2.3 % with the e2e's state dump on); 3 silent claudes 0.2–0.4 % | visible < 0.5 % (over with reporters, see below and §5) |
| Idle CPU, sessions area, a claude shown | 3 reporting 1.3 % (1.7–2.5 % with the dump: e2e A12); 3 silent 0.3 %; window closed 0.5 % / 0.1 % | visible < 0.5 %, hidden < 0.1 % |
| App-side cost of 3 status-line reports per second (3 silent claudes + 3 global-mode `codd-statusline` runs per second from a shell) | 0.6–0.8 % against 0.4 % without the reports: +0.2–0.4 % for the endpoint, throttle, attribution and UI; the rest of the 1.3 % above is the fixture's terminal output (a shell printing the same two lines per second: 0.5 % against 0.4 %) | — |
| App footprint with 3 fake claudes, one shown | 361–382 MB while the shown terminal receives the fixture's two lines per second; 124–140 MB with silent claudes; a shell printing the same lines: 365 MB vs 122 MB quiet (so it is libghostty's surface under output, M1 F2, not the status-line path); STATUS shown 94–96 MB; window closed 103–105 MB | app base < 80 MB (over, carried) |
| Quota attribution latency: one global-mode report → the dump shows the new number | 134–137 ms (one cold run 171 ms); of that the CLI 4–5 ms and the dump's own 100 ms write delay, so report → quota book ≈ 30 ms | — |
| cswap state read on the fixture (`accounts.readMs`, off the main actor) | 1.14 ms | — |
| Settings window open, first open of a launch (`SETTINGS shown ms=`) | 42.1 ms (一般), 54.8 ms (帳號), 40.2 ms (HOOKS), 33.6 ms (關於) | — |
| e2e idle CPU with 3 reporters (A12, dump on) | 1.70–2.49 % over six runs | — |

Component and step numbers (from their reports): `codd-hook` release grew 144 → 247 KB (startup
unchanged, 2.4–3.5 ms); CoddClaudeSettings load 0.15 s / plan 0.55 s for a 1.5 MB, 60k-line file
(debug); STATUS CPU with one reporter before I2's discrete-change rebuild 0.28–0.59 s per 10 s, after
0.14–0.15 s; latency probe with an injected 50 ms delay p50 52 ms / p99 55 ms.

## 5. Known issues

**Not verified with the real thing** (automated runs never use them):
- **A real `claude`:** the status line input shape and its `rate_limits` come from reading the
  installed 2.1.302 bundle, not from a live session; whether Claude renders your chained status line
  exactly as before (padding, colors, refresh) under CODD's `--settings` `statusLine`; how often a
  real claude runs it (assistant messages and setting changes, debounced 300 ms, plus your
  `refreshInterval`). Managed settings above flag settings would override CODD's injection (D35 known
  issue, not handled).
- **The real cswap 0.26:** its state formats were read from its source and reproduced by the fake;
  `cswap switch` with the real credential lock and Keychain (how long the lock takes, the retry
  path), `cswap add` (an occupied slot makes cswap ask `Overwrite slot N?`; CODD's stdin is
  /dev/null, cswap then says Cancelled and exits 0, so CODD re-reads the state to see whether the slot
  holds the new account), `cswap alias`; the cswap menubar / auto detection was checked only with a
  python process whose argv says `cswap menubar`.
- **Real notifications** (ad-hoc signing may stop them from showing, carried from M1), **the real
  login item** (`SMAppService.mainApp` was never called; ad-hoc signing may refuse it, the toggle then
  returns to OFF with the error), **⌥Space** (never registered by tests; the exclusive-conflict path
  was tested inside one process only), **Dock off on screen** (background launches always stay
  `.accessory`; checked through `dock.wanted`), **the global hotkey's press action** (no synthetic
  Carbon event), **the D19 close button** running the ⌘Q flow end to end.
- **Your real `~/.claude/settings.json`:** the installer was exercised only on generated files of the
  same shape (hook-tap ×12 with PermissionRequest 600, osascript ×2, CODD web leftovers in both
  shapes, the web status-line wrapper).

**Design dependencies and heuristics:**
- **cswap's internal files are not a contract.** A format change makes accounts unavailable with
  `// 讀不到 cswap 狀態：<reason>`; `↻ 立即更新` / `重新讀取` then run `cswap list --json` (which makes
  cswap fetch usage) at most once per 10 minutes, never at launch or on a timer (D1). A schema-3
  `cache/usage.json` gives a warning and no cswap numbers.
- **Attribution heuristics (D6).** For 90 s after a switch a `default` report goes only to the
  account whose weekly reset matches within ±120 s; one matching neither is dropped (numbers lag until
  the next report). With an unmanaged global login (an identity no cswap slot has) `default` reports
  are dropped. `cfg-` reports of unknown directories are dropped. Drops are counted (`statusline
  dropped`) and logged once a minute per key.
- **Adding an account changes the global login for a while** (cswap's design): dialog C switches back
  after `cswap add` and on cancel; a failed switch back leaves the new account active (the toast says
  so); quitting CODD while dialog C is open leaves its login shell until the next launch (ended and
  deleted then) and does not switch back.
- **Pinned sessions bypass `cswap run`'s re-bootstrap (D12).** A profile cswap marked stale is
  refused (`#2 的登入資料需要更新：先在終端機執行一次 cswap run 2`), but a token rotated without a
  marker can still log a pinned session out; `cswap run <n>` once fixes it. While the D1 list fallback
  is shown nothing can be pinned (the list has no profiles).
- **Users without a status line** get CODD's silent `codd-statusline` as theirs: Claude may draw an
  empty status row (manual check §6).
- **`.accessory` (Dock off)** hides CODD's main menu bar; shortcuts still work while CODD is active and
  the status item is the way back.

**Budgets:**
- **Visible idle CPU with status-line reporters is over the 0.5 % budget**: 1.2–1.3 % (Debug, window
  occluded, 3 fake claudes reporting every second). The app-side part is +0.2–0.4 %; most of the rest
  is the fake claude's two terminal lines per run and libghostty's display link waking for them (a
  real claude redraws its status row in place, normally only when the text changes, so the real cost
  is expected to be lower; not measured with a real claude). With silent claudes the app idles at
  0.2–0.4 % on STATUS and in the sessions area. Not measured in Release. After the review fixes (§9,
  same machine, no state dump, 12 s): Home 0.58 % (2.00 % before), a session shown 0.91 % (0.83 %),
  Settings › HOOKS 1.08 % (1.66 %), main window closed on Home or on a session 0.50 % (1.33 % /
  0.58 %); still over the 0.5 % visible and the 0.1 % hidden budget. The hidden cost is the report
  path itself (HTTP endpoint, throttle, attribution, the quota book and the views that stay
  observed: footer, rail, menu bar title); not traced further. A12 now gates Home with 3 reporters
  at 1.8 % and ≤ 2 renders in 10 s (no dump, timers visible; measured 1.10 %): it catches the
  per-report rebuild, not the budget.
- **Footprint** 361–382 MB with a shown terminal that keeps receiving output (M1 F2, carried; the
  status-line path itself does not add memory), 94–140 MB otherwise (over the 80 MB base, carried).

**Accounts, quota, status line (I1b):**
- The ⌘N resume picker still lists only the default `<claudeDir>/projects`; a pinned session's own
  transcripts are used for RESUME, 刪除對話紀錄 and `↻ 重送上一則`.
- `following` counts live CODD claude sessions without a pin only; externals are not counted (their
  config directory is unknown); an external whose registry sits in a cswap profile shows as EXT
  without an account.
- `.claude.json` sits outside cswap's state root, so FSEvents do not see a login change: the 15 s
  fingerprint poll (or an immediate re-read on a suspected login change) does; changes inside a
  profile folder are seen by the 5-minute full read.
- The sidebar footer shows the availability copy on one line, cut to the sidebar width (the tooltip
  has it all); the D5 lock progress line is shown only in dialog A (rows say `切換中…（2/3）`). A switch
  picked from the status item's right-click menu shows its toast in the main window's sidebar.
- A pinned session's `spawn.env` holds `CLAUDE_CONFIG_DIR` (and the hook token, as since M1) for the
  moment between writing it and the holder opening its socket.
- The quota cache is written 2 s after the last change, at most 15 s after the first unsaved one
  while reports keep coming, and the auto-switch cooldown at once (§9): a crash loses at most 15 s of
  numbers (they come back with the next report or cswap read), never the cooldown.
- Quota entries carry an opaque identity of their slot's login (§9, a domain-separated FNV-1a 64 of
  e-mail and organization, 16 hex digits in quota.json). It is not the e-mail and is not a secure
  hash: someone with the 0600 file and a candidate e-mail could confirm the match. A quota.json
  written before the fix has no identities: its number entries are dropped at the first read (cswap's
  cache refills them at once, the status line within a second).
- The projected 1w exhaustion is kept to the minute it is shown at; while an account is ahead of
  pace it still moves with each capture, so Home re-renders about once a minute then.
- cswap without any account yet (no `sequence.json`) is `ready` with no accounts (§9): STATUS shows
  `cswap 還沒有帳號 · 加入第一個帳號` with the add card; the sidebar footer only shows `—`.

**STATUS, installer, dialogs (I2):**
- The STATUS sidebar width swap is checked on snapshots only (a unit test would write the user's
  defaults domain). With legacy (always shown) scroll bars the page is about 15 px narrower than the
  artboard; the profile card's path chip is cut in the middle to fit (§9), down to hidden on a very
  narrow card.
- On a temp root the HOOKS card title and dialog B show long temp paths (the question line keeps the
  last three components). Values that change every second update with the 5 s refresh while STATUS
  shows. The host line's cpu part appears from the second 30 s sample.
- Dialog C: a `/login` into the same account is not seen as step 1 (`擷取目前登入` still works); an
  existing account with a CJK alias starts with an empty alias field and `加入 #n` needs an ASCII one
  (D34); on a non-standard root without DEBUG `-codd-claude-path` its login shell opens but types
  nothing (CODD never starts a real claude there).
- ⌘K with an empty query now lists `切換帳號到 #<first switchable>`, so the sixth common action
  (Composer) drops off that list.
- I2 reset `App/Real/HolderSessionStore.swift` by mistake once and restored it (build, tests and
  every e2e pass); its diff against HEAD should be reviewed before the commit.
- M2's `ResumePickerTests.pickerOverAFixtureCatalogDisablesRunningSessionsAndRegistryEntries` failed
  4 runs in a row once during I2 (holder stop without EXIT in 8 s) and passed every run since,
  including all of I3's and I4's; no root cause found.

**Settings and lifecycle (I3):**
- Terminal font family and size are one libghostty configuration per process: a change applies to
  every terminal, not only new ones.
- Settings › HOOKS & STATUS's page head always reads `~/.claude/settings.json` (artboard copy); the
  status-dir row shows the real path. ADVANCED › 紀錄檔 shows `—` (CODD writes no log file; M5).
- The cswap background-tool scan runs while the Settings window shows on any section. Mute chips list
  the groups at the time the window opens. Dialog D's summary counts externals (`13 個 session
  執行中`) while ask-or-quit and `全部停止並結束` count CODD sessions only.
- Rows of later milestones are drawn disabled with `M4` / `M5` / `FUTURE` (notebook, MCP, cleanup
  engine values stored only, UI font size, density, vibrancy, updates, logs, 語言 stored only,
  remote); Settings has two scrollback rows (CLEANUP 終端機紀錄 and ADVANCED 終端機紀錄保留), M4 decides
  which one the cleanup engine obeys. Discrete select preferences accept only the artboard's options
  (`-codd-set-pref sessions.staleAfterSeconds=5` is refused; `-codd-stale-after` still works).
- A user who had notifications off in M1/M2 keeps DONE / EXITED notifications on after the
  migration (only WAITING / ERROR are migrated); keys added to preferences.json by hand while CODD
  runs are lost on its next save.

**Packages (C1–C10):**
- `codd-hook`'s release binary grew 144 → 247 KB (CoddHookClient is linked as one object); startup is
  unchanged. A chain that does not read its stdin within 500 ms gets it truncated above 64 KiB; stdin
  over 1 MiB or not at EOF within 1 s is passed as read so far. `CLAUDE_CONFIG_DIR` is hashed as
  given (a literal `~/.claude` is a `cfg-` key, not `default`).
- CoddClaudeSettings: CRLF becomes LF on a write; a BOM, invalid UTF-8 or lone surrogates make the
  file `invalidJSON` (CODD refuses to touch it); integer-like keys keep file order (JSON.stringify
  would move them); a non-canonical layout is re-laid out on the first write (the summary says so);
  the diff degrades above 1000 edits per member; no file locking against another writer in the
  microseconds before the rename. A restore shows the other tools' handlers it removes or brings back
  as diff lines and names them (§9); handlers are told apart by event and exact content, so two
  identical handlers on one event count as one change each.
- CoddHost: memory figures can be up to about 1 s old (host_statistics64 rate limit); DISK
  available between important-usage lookups (60 s) is an estimate; the host name is `gethostname`
  without `.local` (not the Sharing name).
- CoddSettingsUI's own Sx primitives overlap CoddUI's FormRowView / CheckboxButton / StepperControl
  (they can be merged later); the APPEARANCE preview clips its last line at 16 pt and up (as the
  artboard); search does not look inside the PROFILES page. CoddDialogsUI: inline `code` in wrapping
  text has no box; sheets are titled (rounded corners on Tahoe) and the modal's outer glow is off; the
  IME was tested with `setMarkedText` only (a manual 注音 check is in §6).
- Fixtures: the fake cswap models no credentials, Keychain, usage fetching, sentinels, `run`,
  `auto`, `menubar`; the fake claude runs its status line only on its interval and prints two lines
  per run into its terminal (which costs CPU and memory in the measurements, above).

**New copy not on the frozen artboards** (written by the steps; please review): status-line hints for
outdated / CODD web / not installed / undecodable, `最近收到資料` variants, `● 正常`, `◆ 注意`,
`○ PAUSED` / `○ OFFLINE`, `· 已暫停`, `[繼續]`, the profile card's not-linked / unknown lines,
`// 沒有其他工具的 hook`, `沒有 session 連著 Remote Control`, `// 正在讀取 cswap 的帳號…`,
`◆ 抓取失敗`, `尚無資料` / `重置時間未知`, `取樣中`, `使用電池` / `充電中`, `壓力偏高` / `壓力過高`, the `▸ 詳細`
lines, dialog B / C error texts, auto-switch toast and notification bodies,
`! cswap menubar 與 cswap auto 也在執行，可能同時切換`, `#n 在 cswap 中已停用`,
`還在讀取 cswap 的帳號，請稍候再試一次。`, `#n 是目前的全域登入；cswap 不為它建立獨立設定目錄`,
`沒有 #n 這個 cswap 帳號。`, `正在切換帳號，請稍候`, `尚無用量`, the switch failure texts,
`▾ 全部帳號 n`, `測試資料根目錄不會註冊全域快捷鍵` / `…登入項目`, the login item errors, the reset-all
alert, `preferences.json 是較新版本的 CODD 寫的，變更不會儲存`, `cswap alias 失敗：…`, the test
notification body, the DONE / EXITED banners, the dialog C placeholder `例如：studio` (D34).

**Visible deviations from the artboards in the mock snapshots:** STATUS › MCP SERVER is the D27
placeholder (`// M4：筆記本與 MCP server 尚未提供`) where the artboard shows a running MCP card; the HOOKS
card shows the SPEC sample's `1 項需要更新` as CODD web leftovers on 10 events (the artboard shows 4
missing events); NEEDS YOU rows are 38 pt (artboard 43.5 pt); the scroll-spy highlights the section
at the top line while scrolling by hand (a nav click keeps its section, the end of the page the last
header on screen, §9); dialog C's alias placeholder is `例如：studio`.

**Test tooling:** every automated CODD launch shows its own status item in the menu bar for its
lifetime (as since M1); the e2e registers `ctrl+option+cmd+f12` for about 10 s (A9); A13 creates a
link `realclaude → ~/.claude` inside its temp folder that is only resolved (never read through) and
removed right after; A13d gives two runs a fake home (`CFFIXED_USER_HOME`, which NSHomeDirectory
honours; `getenv("HOME")` users are not affected and none runs in those launches); CoddDialogsUI's
presenter tests were skipped in this step's runs.

## 6. 手動測試清單（請用真的 cswap、真的 claude 與真的 ~/.claude）

先打開 `build/dd/Build/Products/Debug/CODD.app`（或你自己 build 的版本）。這會用你真的資料夾
`~/Library/Application Support/CODD`：會多出 `bin/codd-statusline-…`、`bin/codd-statusline`、`quota.json`，
改過設定後還有 `preferences.json`。有問題時請附上 STATUS 頁或終端機輸出裡 `REALHOLDERS` 開頭的那幾行
（裡面不會有 email）。

1. **帳號清單（真的 cswap）。** 打開後看側欄底部、選單列圖示的面板、STATUS › ACCOUNTS：應列出 cswap 管理的
   每個帳號，只顯示 `#編號 別名` 與方案（如 `MAX 20x`），**任何地方都不應出現 email**；順序是「週額度越快
   重置的越上面」；目前的帳號標 `ACTIVE`。cswap 版本低於 0.26 時應顯示 `需 ≥ 0.26`。
2. **別名與中文顯示名稱（D34，你已決定：先不做中文顯示名稱）。** cswap 0.26 只接受英文小寫、數字與 `- _ .` 的別名，CODD 會原樣
   顯示 cswap 存的別名（你之前留下的中文別名也會照樣顯示），但在 CODD 裡新設或修改時只能用英文。請告訴我：
   你是否需要 CODD 另外存一份「中文顯示名稱」（例如 `#3 工作`）？要做的話需要以帳號身分為索引另存一份資料，
   之後的里程碑才做。
3. **statusline 的數字對不對。** 開一個 CODD 的 claude session，跟它說一兩句話。側欄底部的 active 帳號應顯示
   `statusline · 幾秒前`，5h / 1w 的剩餘百分比與重置時間，應和你在同一個 claude 裡輸入 `/usage` 看到的一致
   （CODD 顯示的是剩餘，`/usage` 顯示的是已用）。
4. **你原本的 statusline 還在。** 在 CODD 的 claude session 裡，底部的 statusline 應和在 Terminal.app 跑 claude
   時一樣（其他工具的內容、顏色、padding 都在）。
5. **沒有 statusline 的情況。** 如果你有某個專案（或另一台設定）沒有設定 statusLine：在那裡開 CODD 的 claude
   session，看底部是否多出一條空白的 status 列。若有，請截圖給我。
6. **直接切換 + UNDO（真的 cswap）。** 在側欄底部或選單列面板點另一個帳號：應出現 `切換中…`，完成後 toast
   `已切換到 #2 … · n 個 session 約 30 秒內套用` 和 `[UNDO]`；按 UNDO 會切回原本的帳號。請告訴我切換花了幾秒，
   有沒有出現 `等待 Claude Code credential lock…（1/3）`。設定 › 帳號 › `切換前確認` 打開後，點帳號應先出現
   切換確認的對話框。
7. **固定帳號的 session（cswap run）。** 先在終端機執行一次 `cswap run 2`（之後可以結束它），回到 CODD 按
   ⌘N，帳號選單應有 `固定 #2 …（cswap run）` 可選，目前的帳號那一項是灰的。用它開一個 session：側欄那一列
   有 `#2` 標記，那個 session 用 #2 的額度（在它裡面 `/usage` 應是 #2 的）。若 cswap 把那個設定目錄標記為需要
   更新，⌘N 裡那一項應變灰，而對已存在的固定 session 按 RESUME 會出現橫幅
   `#2 的登入資料需要更新：先在終端機執行一次 cswap run 2`。
8. **STATUS 頁（真的資料）。** 點左側 rail 的 STATUS：HOST（CPU、記憶體、磁碟、電池、CODD APP）數字合理、
   每 5 秒更新、`暫停` 可停；ACCOUNTS 與上面一致；HOOKS & STATUSLINE 應顯示你目前的 settings.json 狀態：
   偵測到舊版 CODD web 的 hook（`status-writer.js`）、其他工具的 hook（例如 `hook-tap`）與 osascript 列在 FOREIGN HOOKS。
9. **Hook 差異 → 套用並備份（會寫入你真的 ~/.claude/settings.json）。** 先自己備份一份 settings.json。在 STATUS
   或 設定 › Hooks & Status 按 `預覽變更`：差異只應包含 `hooks` 與 `statusLine` 兩段，其他工具與 osascript
   的部分以 `…（保留既有 n 組 hook）` 帶過。按 `套用並備份` 後：`~/.claude/` 裡多一個
   `settings.json.codd-bak-<日期時間>`（內容與原本相同），`status-writer.js` 的 hook 都不見了，其他工具與
   osascript 的設定一字未改，其他設定（env、permissions、plugins）不變；statusLine 變成 CODD 的外層指令，
   裡面串著你原本的 statusline。然後在 **Terminal.app** 開一個 claude：statusline 應仍正常顯示。
   不滿意可在 設定 › Hooks & Status 的備份清單按 `還原`，或按 `解除安裝`。
10. **選用的全域 statusline。** 套用之後，在 Terminal.app 跑的 claude 也會把用量回報給 CODD（CODD 開著時）：
    看 STATUS › `最近收到資料` 是否更新。CODD 沒開時，Terminal.app 的 claude statusline 也應照常顯示。
11. **全域快捷鍵 ⌥Space。** 切到別的 App，按 ⌥Space：CODD 主視窗應跳到最前面；CODD 已在最前面時再按一次會
    隱藏。若別的 App（例如啟動器）已占用 ⌥Space，設定 › 一般 › 全域快捷鍵 下方應顯示
    `⌥ Space 已被其他 App 使用，請改用別的組合鍵`；在那裡錄一個新組合鍵（需含 ⌘ ⌥ ⌃ 之一，⎋ 取消）應立即生效。
12. **結束對話框。** 有 session 在跑時按 ⌘Q：應出現結束對話框，列出需要你的 session。分別試：
    `全部停止並結束`（session 都停止）、`結束 · session 繼續執行`（`pgrep -lf codd-holder` 仍看得到 holder，
    重開後接回）、`保留在選單列`（只關視窗）、`取消`。勾 `下次直接保留在選單列` 後，⌘Q 只會關視窗；選單列圖示
    右鍵的 `結束` 仍會出現對話框。
13. **Dock 關閉再打開。** 設定 › 一般 › `顯示於 Dock` 關掉：Dock 圖示消失、⌘Tab 也看不到，選單列圖示還在，
    從選單列可以叫回視窗。再打開：Dock 圖示回來。
14. **登入時啟動。** 設定 › 一般 › `登入時啟動` 打開：應出現在 系統設定 › 一般 › 登入項目；若顯示需要允許，
    依提示到系統設定允許。因為是 ad-hoc 簽章，系統可能拒絕，這時開關會自動回到關，並顯示錯誤（請告訴我顯示
    什麼）。
15. **通知矩陣與勿擾。** 設定 › 通知：按 `傳送測試通知` 應跳出 `◆ 測試通知 · FANCY/CODD`。試 WAITING / ERROR /
    DONE / EXITED 各自的條件（一律通知 / 僅在未聚焦時）、通知與聲音開關；勿擾時段內（預設 23:00–08:00）
    不應跳通知但 Dock 數字仍更新；選單列 `暫停通知 1 小時` 後圖示變淡、項目變成 `恢復通知`。
16. **自動切換（預設關閉；想試再開）。** 設定 › 帳號 › 自動切換 打開後，側欄帳號列會出現門檻刻度；當 active
    帳號 5h 或 1w 剩餘 ≤ 2% 時，CODD 會用 `cswap switch` 切到排序第一個額度足夠的帳號，跳 toast（有 UNDO）與
    通知 `↻ 已自動切換到 #n …`，300 秒內不會再切；全部帳號都不夠時只通知一次 `所有帳號都低於 2%`。要觀察可以看
    STATUS › AUTO-SWITCH 列與 REALHOLDERS 的 `auto-switch` 行。若你同時在跑 `cswap menubar` 或 `cswap auto`，
    設定與 STATUS 會提醒兩邊可能同時切換。
17. **加入帳號（會暫時改變全域登入）。** 設定 › 帳號 `+ 加入帳號`：右側出現加入帳號面板。按 `開啟登入終端機`，
    在出現的終端機完成 `claude /login`（登入另一個帳號）；回到面板按 `擷取目前登入`，應顯示 `偵測到 新帳號 ·
    MAX …`；輸入英文別名（例如 `studio`）按 `加入 #n`：cswap 加入後 CODD 自動切回原本的帳號，那個登入終端機
    自動關閉並刪除。輸入中文別名應直接提示 cswap 的別名規則，不會執行 cswap。
18. **注音輸入。** 在加入帳號面板的別名欄、設定的搜尋欄與 cswap 路徑欄用注音打字：組字中按 Enter 只確認選字。

## 7. Decisions taken (all reversible)

### The plan's decisions as implemented

| # | As implemented |
|---|---|
| D1 | As planned: status line + cswap's cache only; `cswap list --json` only from `refresh(userInitiated: true)` while the state is unusable, ≤ once per 10 min, logged `cswap list fallback`; its warnings and organizationName are dropped, never logged; `cswap status` never runs. |
| D2 | As planned; the reader caches only FNV-1a digests; `.claude.json` re-checked on a 15 s fingerprint poll (plus FSEvents on the state root, coalesced 300 ms, and a full read every 5 min instead of the 30 s poll). An unmanaged login gives no active account (cswap's own rule). |
| D3 | As planned: on the standard root DEBUG flag → Settings path → login PATH → `~/.local/bin/cswap`; a set but broken preferred path shows noCswap (no silent replacement); any other root has no cswap unless DEBUG flags; `exec cswap path=… sub=…`. |
| D4 | Pseudo account id `default` (slot `—`, alias `目前登入`), never a switch target. |
| D5 | As planned; lock timeouts retried without a pause (cswap already waited), UNDO's own switch-back toast has no UNDO, a refused switch shows nothing; dialog A only for reason `user` with 切換前確認 ON. |
| D6 | As planned, plus: inside the grace a report matching both `from` and `to` is dropped; outside it a report matching several other accounts is dropped with a re-read. |
| D7 | As planned; equal capture times never replace; scoped windows from cswap only; the quota book is not observed by views (only `hasDefaultLoginEntry`). |
| D8 | As planned; the chain inherits the environment minus `CODD_STATUSLINE_CHAIN` (recursion guard); signals re-sent 20 ms later (fork race); the timeout counts from the chain's spawn; the stable copy is replaced only when its bytes differ (always through a rename). |
| D9 | As planned; `statusLinesUndecodable` added; ≤ 1 report per second per account key reaches the store. |
| D10 | As planned; summaries in 繁中; foreign handlers elided; backups with `COPYFILE_EXCL` and the next free `-n`; the backups index keeps the newest 200; restore backs up the current file first. |
| D11 | As planned (guard form, single-quote escaped, `else` only with a chain). |
| D12 | As planned; option order follow, active (disabled), others in R7 order; a launch profile with its own `CLAUDE_CONFIG_DIR` is never overridden; `SessionRegistration.configDir` stays nil so the profile path never reaches `hooks/*.json`. |
| D13 | As planned; a failed auto-switch does not start the cooldown; the scan runs while auto-switch is ON or STATUS / Settings shows. |
| D14 | As planned; the UserDefaults migration only on the standard data root and only when preferences.json does not exist yet; `-codd-set-pref` never written unless a later edit changes that leaf. |
| D15 | As planned (login item OFF, CRT OFF, hotkey on the standard root only, no muted groups). |
| D16 | The STATUS sidebar swaps views inside the split's sidebar column (saved divider frames stay valid). |
| D17 | As planned; disabled rows at alpha .55 with their chip; 語言 persisted but disabled. |
| D18 | As planned; `下次直接保留在選單列` sets 保留 for any choice but 取消; `-codd-quit-request` is a user quit, `-codd-quit-after` automation. |
| D19–D22 | As planned; login item and hotkey only on the standard root (test roots say why under the row). |
| D23 | As planned; when the active account is not among the first 3 it takes the third place, order stays R7. |
| D24 | As planned; the ephemeral marker is written before the holder spawns; text typed 500 ms after WELCOME; after `cswap add` the state must show the slot. |
| D25–D28 | As planned; ABOUT has five version cells (App, macOS, Claude Code, cswap, libghostty). |
| D29 | As planned; the test notification ignores pause and quiet hours but respects `-codd-notifications NO`. |
| D30 | As planned, plus the non-verbatim `InputField` observer fix (and App's ProjectComboBox). |
| D31 | As planned; the e2e greps `example.com` (cswap's real slug is `north_example.com`, so the plan's `example-com` could never match). |
| D32–D33, D35–D38 | As planned. |
| **D34** | **Question for you:** cswap 0.26 accepts only `^[a-z0-9_.-]+$` aliases, so CODD validates with exactly that rule and suggests `studio`-style aliases; CJK aliases already in cswap's `sequence.json` are shown as they are. There is **no CODD-side CJK display name in M3**: a second name keyed by slot number could label the wrong account after you remove and re-add accounts in cswap; doing it safely needs a store keyed by account identity. Do you want CODD-side 中文顯示名稱 in a later milestone? |

### Added by the components and steps

- **C1:** unmanaged live login → no active account; several `sessions/<n>-*` for one account → cswap's
  exact name or no profile with a warning; the fingerprint has a `sessions` key; usage health priority
  relogin > failing > fresh/stale; `WeeklyPaceInfo` gained `expectedPercent` / `willLastToReset`;
  QuotaStore tolerant (corrupt → empty, newer → not written); `CswapProcessDetector` reads argv only
  for this uid's python / cswap processes.
- **C2:** `StatusLineReport.decode` uses the Foundation-free JSONScan; `CODD_STATUSLINE_TIMEOUT_MS`
  honoured only within 1…10000 ms; a non-UUID `CODD_SESSION_ID` is left out instead of sent;
  `--chain-b64` wins over the environment; global mode reads config.json with O_NOFOLLOW, owner and
  size checks; a report is posted even without `rate_limits` (liveness).
- **C3:** the parser refuses rather than alters (BOM, invalid UTF-8, comments, trailing commas); a blank
  file is `{}`; only `update` creates a missing file; a dangling settings symlink is written to the end
  of its chain; diff hunk format as documented.
- **C4:** CPU ticks from `host_processor_info` (host_statistics is rate limited); the important-usage
  disk lookup cached for 60 s; resident memory for the CODD APP card (its `RSS` label).
- **C5–C8:** CardView's 7 pt outset as alignment insets; CSS-exact chip widths; quota bar minimum
  40 px; CJK-safe alias placeholder; dialog widths 640 / 640 / 560 / 560; dialog A with no following
  sessions has its own line; view-owned inputs survive `update(_:)`.
- **C9:** cswap's real naming (`2-north_example.com`, raw-e-mail config names, sibling stale markers);
  `--legacy` opt-in; `--stale` on an existing root.
- **C10:** all types nested in `CoddPreferences`; raw values are the Swift case names; optionals
  written as explicit null; a missing / bad version reads as 1 with a repair note; `Origin.unreadable`.
- **I1a:** sidebar filter row fixed at 42 pt; preferences loaded before the holders start.
- **I1b:** polling 15 s + full read 5 min; fallback replaces the snapshot until a read succeeds; view
  models updated per field; the M1 fake claude's SessionStart extraction fixed.
- **I2:** STATUS counts STARTING / RUNNING as BUSY and STOPPED as EXITED; every scoped window gets a
  row on every card; CPU sparkline scaled to 1.58 × the peak; HOST health rule; `n 項需要更新` counts
  web leftovers and an outdated wrapper as 1 each; STATUS toasts over the STATUS sidebar; discrete-change
  rebuilds (CPU).
- **I3:** section-level commits; auto-switch preview from `AutoSwitchPolicy.isEligibleTarget`; the 14
  hook events from `ClaudeHookSettings`; login item called only when the toggle changes; NO HOOK grace
  for sessions registered after the change; `preferences.effective` and a pure `StatusItemAppearance`.

### Added in this step (I4)

- `-codd-hooks-apply` checks its isolation guard before the plan reads the target, so a refused path
  is never read (the plan said "refused"; now also "not read").
- `-codd-hooks-plan` refreshes the installer inspection first, so the dump shows the inspection the
  plan was built on (as STATUS would).
- New DEBUG `-codd-hooks-apply-delay <ms>` (0…30000) between the plan and the write, for the e2e's
  changed-since-preview check.
- The DEBUG `-codd-new-claude` path logs a refused pin's text (`debug new-claude refused: …`), because
  there is no ⌘N sheet to show it in.
- Measurement hooks: `STATUS shown ms=…`, `SETTINGS shown ms=… first=… section=…`, dump
  `accounts.readMs` (the last state read off the main actor).
- The e2e greps the stricter `example.com` (covers e-mails, config names and cswap's real slug) over
  every dump and log, and `@example.com` over every data root file.
- `-codd-hooks-apply` refused without `-codd-claude-dir` / `-codd-claude-settings` was covered by unit
  tests only (an e2e launch without `-codd-claude-dir` would read the real `~/.claude`); since §9 the
  e2e covers it (and a `-codd-claude-dir` through a link) with a fake home.

## 8. Fixes made in this step

| What | Why | Regression check |
|---|---|---|
| `runInstallerDebugActions`: the apply guard runs before the plan (`App/AppDelegate.swift`) | the plan used to read the target first, so a `-codd-claude-settings` path into the real `~/.claude` was read before the apply was refused | e2e A13 (no `debug hooks-plan` line, `installer.plan` null, nothing created there); `M3EndToEndHookTests.guardSeesThroughALinkToAMissingPathInTheRealClaudeDirectory` |
| `-codd-hooks-plan` refreshes the inspection | plan-only runs dumped `inspection: unknown`, so `upToDate` and the foreign tools could not be checked | e2e A6 (inspection's legacy events and foreign tools; second plan `upToDate`) |
| `-codd-hooks-apply-delay <ms>` (`App/Real/RealModeOptions.swift`) | the changed-since-preview refusal could not be reached from a script (plan and apply ran back to back) | e2e A6 (`changedSinceRead`, file unchanged, no new backup); `M3EndToEndHookTests.applyDelayParsesWithinItsRangeAndReleaseIgnoresIt` |
| `-codd-new-claude` logs a refused pin | the refusal went to `lastRefusal` only (the ⌘N sheet shows it), invisible to scripts | e2e A14 |
| Timing log lines and `accounts.readMs` (`StatusArea.swift`, `AppDelegate.swift`, `CswapAccountStore.swift`) | the §4 numbers had no in-app measurement point | §4 |

No product bug was found by the e2e; the A14 / A4 / A5 failures in the first runs were wrong
expectations in the new script (an int `lastSwitch.to`, a string at the end of an `and` chain, a log
line read before it was written), fixed in the script.

## 9. Fixes after the M3 review (round 1)

Written 2026-10-17 after the review of the integrated M3 (correctness, security and data, spec
fidelity, concurrency and performance, end to end). Every confirmed problem was fixed except the
ones listed at the end of this section; each fix has a regression test where one was practical.

| Review id | Fix | Where | Regression check |
|---|---|---|---|
| security-data-1, e2e-1 (high) | The per-session `statusLine.command` is the copy's path POSIX single-quoted (`'…'`, `'` as `'\''`). Claude runs a status line through `/bin/sh -c` (no `args`, no exec form), so the standard root `~/Library/Application Support/CODD` split at its space: every CODD session's status line exited 127, no quota report reached CODD and the user's own status line disappeared. GC of the copies sees through the quoting | `StatusLineInjection.shellCommand`, `ShellQuoting` (CoddCore `HookSettings.swift`), `CoddHookBinary.referencedPaths` | CoddCore `generatedCommandRunsThroughShFromARootWithASpaceAndAQuote` (runs the command through `/bin/sh -c` from a root with a space, a `'` and `$(x)`), `quotingRoundTripsAndEscapesSingleQuotes`; app `quotedCommandsStillCountAsReferenced`; e2e A2 (quoted form) and the new A15 (a data root `d m3'e`: USER-SL-ok, exit 0, reports accepted) |
| correctness-1 (high) | Quota entries carry the identity of their slot's login (`CswapStateAccount.identity`, `QuotaEntry.identity` in quota.json). Every read runs `QuotaBook.reconcile`: an entry follows its login after `cswap swap` / `move`, is dropped when no slot holds it (`remove`, a slot reused), an identity-less entry of an older file is dropped where the slot's login is known, the D4 entry goes once cswap has accounts. An observation of another login starts the entry over. D6's reset fingerprint counts only entries of current slots held by the same login | CoddCore `QuotaBook.swift`, `QuotaAttribution.swift`, `CswapStateReader.swift`; `CswapAccountStore.apply` / `attribute` | CoddCore `QuotaIdentityTests` (swap, removed or reused slots, legacy entries, another login's observation, round trip, the reviewer's #5 / #6 probe), `slotIdentitiesAreOpaqueStableAndFollowTheLogin`; app `aSwapKeepsEachLoginsNumbersWithItsLogin`, `aRemovedAccountsLeftoverEntryTakesNothing` |
| concurrency-perf-1 (medium) | Home's model no longer carries the capture time (the usage list reads it at its 1 Hz tick), the projected 1w exhaustion is kept to the minute it is shown at, and Home observes and renders only while the main window is on screen | `HomeModel.UsageRow`, `UsageListView`, `HomePageView`, `SessionPaneViewController.isWindowVisible`, `MainWindowController.reportVisibility`, `CswapAccountStore.minute` | app `homeDoesNotRebuildOnEveryReport`, `homeStopsWhileTheWindowIsAway`; e2e A12 Home run (≤ 2 renders in 10 s, ≤ 1.8 % CPU); measured 2.00 % → 0.58 % (§5) |
| correctness-2 (medium) | Settings text fields commit when editing ends however it ends: `InputField` reports the end of editing at once, `SxTextInput` commits when it leaves its window, the root ends editing before it swaps sections, the Settings window before it closes, the app before it flushes the preferences at quit | CoddUI `InputField.controlTextDidEndEditing`, CoddSettingsUI `SxTextInput.viewWillMove(toWindow:)`, `SettingsRootView.endEditing`, `SettingsWindowController.windowWillClose`, `AppDelegate.applicationWillTerminate` | CoddSettingsUI `typedTextCommitsWhenTheSectionChangesOrEditingEnds` (the real field editor in a window, no Return) |
| security-data-2 (medium) | A restore preview shows other tools' handlers it removes or brings back as removed / added lines (only handlers kept on both sides are elided), its summary names them (`會移除 hook-tap 的 2 個 hook（備份裡沒有）`) and the other top-level keys it reverts (`hooks 與 statusLine 以外也會還原：model`), and dialog B's FOREIGN row says `◆ foreign hooks 會變動：移除 hook-tap ×2` instead of `保持不動` | CoddClaudeSettings `SettingsLineRenderer` (`changedForeign`), `ClaudeSettingsInstaller.plan(.restore)`, `ForeignHookChange`; CoddDialogsUI `HookDiffModel.foreignChanged`; `ClaudeSettingsService.diffModel` | CoddClaudeSettings `restoreShowsTheForeignHandlersItRemoves` (the reviewer's repro), `restoreReportsOtherKeysAndEventChanges`; CoddDialogsUI `aRestoreThatRemovesForeignHooksSaysSo` |
| e2e-3 (medium) | A failing automatic switch is retried once on the next tick (D13), then after the cooldown (at least 60 s), doubled per further failure, at most an hour; the first failure of an episode is toasted (`[ERROR] 自動切換到 #2 藍鵲 失敗：…`, redacted) and notified (`account-auto-switch-failed`); the dump shows `failures`, `retryNotBefore`, `lastDecision: retry-wait` | CoddCore `AutoSwitchController.switchFailed(at:cooldownSeconds:)`, `retryDelay`; `AutoSwitchRunner.perform`; `AppNotifier.Kind.autoSwitchFailed` | CoddCore `aSwitchThatKeepsFailingBacksOff`; app `aFailingSwitchIsNotifiedOnceAndBacksOff`; e2e A5d (two switch calls in 16 s, one notification, the log's `retrying in 300 s`) |
| spec-fidelity-1 (medium) | The ⌘N sheet has the artboard's `.ns-quota` line under the account select: the picked account (follow = the active one) in cyan, 5h / 1w mini meters with the remaining % in their tones, `剩餘`; it follows the pick and the numbers | `NewSessionQuotaLine.swift` (new), `NewSessionSources.accountQuota`, the sheet's observation loop, dump `newSession.accountQuota` | app `newSessionQuotaLineFollowsThePick` |
| spec-fidelity-2 (medium) | A card's health follows the numbers it shows: status-line numbers are `● ok` for 15 min after their capture whatever cswap's cache age; `◌ 舊資料` only for old cswap numbers or an old capture; failing / re-login unchanged | `CswapAccountStore.health(_:source:sourceAt:now:)` | app `cardHealthFollowsTheNumbersItShows` |
| concurrency-perf-2 (low) | quota.json's debounce has a maximum wait (15 s from the first unsaved change); `autoSwitch.lastAt` is written at once (off the main actor); `flush` also waits for a write already queued | `CswapAccountStore.scheduleSave(immediately:)`, `Configuration.maxSaveDelay`, `flush` | app `quotaJSONIsWrittenWhileReportsKeepComingAndTheCooldownAtOnce`; `quotaBookIsSavedPrivatelyAndLoadedAgain` |
| concurrency-perf-3 (low) | The Settings facts loop tracks only discrete inputs: its tracked pass leaves out the capture times and the last report's age (shown at the 5 s tick), the full facts are built outside tracking | `SettingsCoordinator.makeInfo(now:tracked:)`, `SettingsFacts.includesAges`, `SettingsInfoBuilder.usageSources(_:now:ages:)` | app `settingsFactsIgnoreTheReportsAges`; measured infoBuilds 70 → 16–18 per 30 s, CPU 1.66 % → 1.08 % |
| concurrency-perf-4 (low) | Buttons in rows rebuilt from the facts keep their targets per group; a rebuild releases the group's old ones | CoddSettingsUI `SettingsSectionView.makeTarget(_:group:)`, `releaseTargets`, `HooksSectionView` | CoddSettingsUI `rebuiltRowsDoNotPileUpButtonTargets` |
| concurrency-perf-5 (low) | A suspected login change re-reads the state at most every 15 s (and skips an unchanged fingerprint) and logs at most once a minute per key | `CswapAccountStore.suspectLoginChange` | app `aSuspectedLoginChangeIsLoggedAndReadAtMostOnceInAWhile` |
| concurrency-perf-6 (low) | The preference field tables are built once (`static let`); the DEBUG state dump writes at most every 500 ms | CoddPreferences `CoddPreferences+Fields.swift`; `AppDelegate.scheduleStateDump` | CoddPreferences suite; measured with the dump on, Home 0.92 % (§4 had 2.3 % on STATUS with the dump) |
| correctness-3 (low) | Reports that arrive while the accounts are loading wait for the first read (newest per key) instead of landing on the D4 pseudo account; the D4 entry is dropped once cswap has accounts | `CswapAccountStore.ingest` / `replayPendingReports`, `QuotaBook.reconcile` | app `reportsWhileLoadingWaitForTheFirstRead`, `aRemovedAccountsLeftoverEntryTakesNothing` |
| correctness-4 (low) | UNDO / 復原 of an automatic switch holds that account until the triggering window resets, the user switches to another account, or the rule changes (a switch back that never lands stops holding after 2 min); the UNDO toast says `· 在 1w 重置前不再自動切走` | CoddCore `AutoSwitchHold`, `AutoSwitchController.undoAutoSwitch`; `AutoSwitchRunner.undo(to:)` | CoddCore `undoHoldsTheAccountUntilItsWindowResets`; app `undoHoldsTheAccountPastTheCooldown` |
| correctness-5 (low) | Mock mode's Hook 差異 sheet closes on ⎋ / ✕ / 取消 / 套用 and never stacks | `AppDelegate.presentHookDiff` | none automated (mock mode only; checked by reading) |
| correctness-6 (low) | No `sequence.json` yet is `ready` with no accounts: the STATUS add card shows (`cswap 還沒有帳號 · 加入第一個帳號`), dialog C and `addCurrentLogin` work; the add-account refusal toast no longer shows the note's `// ` | `CswapAccountStore.performRead`, `StatusPageData.accountsSection`, `AppDelegate.presentAddAccount` | app `noStateYetIsReadyWithoutAccounts` |
| security-data-3 (low) | DEBUG `-codd-cswap-path` and `-codd-cswap-root` count only together: either one alone gives no cswap (logged), so a fake state never meets the real cswap | `CswapLocation.resolve`, `CswapAccountStore.locateAndRead` | app `d3ResolutionAndIsolation` |
| e2e-2 (low) | A12 gained a Home run with no dump and visible timers, gated at ≤ 2 renders in 10 s and ≤ 1.8 % CPU (measured 1.10 % with the 1 Hz timers running; the render count catches the per-report rebuild); the 0.5 % budget is still missed (§5) | `scripts/m3-e2e.sh` A12 | e2e A12 |
| e2e-5 (low) | The e2e proves both refusals with a fake home (`CFFIXED_USER_HOME`): a `-codd-claude-dir` through a link into "~/.claude" is refused before the plan, a run without `-codd-claude-dir` / `-codd-claude-settings` is refused, the fake home's settings.json stays byte-identical | `scripts/m3-e2e.sh` A13d | e2e A13d |
| spec-fidelity-3 (low) | A Home section head lays out again when an accessory's text changes (the USAGE note kept the width of its first text and ended in `…`) | `HomeTextView.text` | by reading (the head is frame-laid-out; no snapshot test) |
| spec-fidelity-4 (low) | Dialog D lists the NEEDS YOU sessions only, in the sidebar's NEEDS YOU order (artboard D); the box is hidden when nothing needs you | `QuitDialogController.model` | app `dialogDModelRowsAndChoiceNames`, `keepRunningLeavesTheHoldersAndStopAllEndsThem` |
| spec-fidelity-5 (low) | Settings › 帳號's unavailable notice wraps (the band grows) so `會查詢一次用量` always shows | CoddSettingsUI `AccountAliasesView.noticeBandHeight` | CoddSettingsUI `rereadAppearsOnlyWhileCswapStateIsUnavailable` |
| spec-fidelity-6 (low) | STATUS draws the threshold tick only on the 5h / 1w bars the rule checks, never on scoped rows | CoddStatusUI `AccountQuotaRow.window`, `AutoSwitchModel.threshold(for:)`, `checksFiveHour` / `checksWeekly`; `StatusPageData` | CoddStatusUI `autoSwitchOnDrawsThresholdTicks` |
| spec-fidelity-7 (low) | The profile card's path chip is cut in the middle (keeping more of the end) to the room the lead text, `（共用）` and the state leave | CoddStatusUI `ProfileCardView.middleTruncated`, `layout` | CoddStatusUI `aLongClaudeDirStaysInsideTheProfileCard` |
| spec-fidelity-8 (low) | The M4 registrations box draws its client names and buttons in the disabled colors | CoddSettingsUI `SxStaticButton.isDisabledLook`, `RegistrationsBox.isDisabledLook`, `SxRow.disable` | CoddSettingsUI `milestoneRegistrationsDrawDisabled` |
| spec-fidelity-9 (low) | With the D4 pseudo row showing numbers the note reads `// 找不到 cswap（設定 › 帳號）· 只顯示目前登入的用量` | `AccountAvailability.pseudoNote`, `CswapAccountStore.availability` | app `aTestDataRootWithoutFlagsHasNoCswapAndRunsNothing`, `thePseudoNoteNoLongerPromisesNumbers` |
| spec-fidelity-10 (low) | STATUS's scroll spy keeps a nav click's section until the page is scrolled by hand, and at the end of the page highlights the last header on screen (HOOKS, MCP and REMOTE can be highlighted) | CoddStatusUI `StatusPageView.visibleSection` | CoddStatusUI `navClickSelectsAndScrollsToTheAnchor` |

**Decisions taken in this round (all reversible):**
- The quota identity is a domain-separated FNV-1a 64 of the slot's e-mail and `organizationUuid or ""`
  (the pair cswap's usage cache checks), 16 hex digits, persisted in quota.json; quota.json stays v1
  (an older CODD ignores the new key). Entries of an older file without an identity are dropped where
  the slot's login is known (the cache refills them), not adopted.
- The failure backoff: next tick once, then the cooldown (≥ 60 s) doubled per failure, capped at 1 h;
  one toast and one notification per episode (a success, or the trigger clearing, ends it). Lock
  timeouts are treated like other failures (cswap already retries them 3 times).
- UNDO of an automatic switch holds until the triggering window's reset (the cooldown when unknown,
  at most 7 days), the user's own switch to another account, or a rule edit.
- Dialog D follows artboard D (NEEDS YOU only), dropping I4's filler rows of other running sessions.
- A suspected login change re-reads at most every 15 s and only when cswap's files changed.
- quota.json's maximum debounce wait is 15 s; the DEBUG dump's minimum interval is 500 ms.
- The A12 Home gate is 1.8 % CPU (measured 1.10 % with the timers forced, 0.58 % without; the pre-fix code
  measured about 2 %): a regression guard, not the 0.5 % budget.

**Not fixed in this round:** the 0.5 % visible / 0.1 % hidden idle budgets with status-line
reporters (§5: 0.50 % with the window closed, 0.58–1.08 % shown; the report path's remaining cost
was not traced); the other per-report surfaces (footer, rail, menu bar) were not profiled; mock
dialog B's dismissal has no automated test.

## 10. After the workflow (orchestrator, 2026-10-17)

- **Standard-root guard.** On 2026-10-17 05:09 (during the M2 review) a review agent passed a whole
  CODD argument list as one zsh word (`"$APP" $C`, which zsh does not split). CODD saw no
  `-codd-mock` and no `-codd-data-root`, so it ran in real mode for about two minutes and created an
  empty `~/Library/Application Support/CODD` (config.json, panes.json, profiles.json, bin/ with the
  M2 holder and hook copies; no sessions) before the agent ended it. Nothing else of the user's was
  written (`~/.claude/settings.json` has no CODD Desktop entry; M2 had no cswap code). DEBUG builds
  now refuse such a launch: a real-mode run from a Claude Code shell (`CLAUDECODE`) without a data
  root exits 64 with a message (`RealModeOptions.standardRootRefusal`, called from `App/main.swift`),
  unless `CFFIXED_USER_HOME` gives a fake home or `CODD_ALLOW_STANDARD_ROOT=1` is set. Test:
  app `agentLaunchesNeverUseTheStandardRoot`. App tests after it: 429/429. Every script passes
  `-codd-data-root` as its own argument, so their round-1 results stand (they were not re-run after
  this change). The user chose to delete the empty root; it was removed on 2026-10-17.
- **D34 decided:** no CODD-side Chinese display names for now (the user: 先不用); CODD shows cswap's aliases.

