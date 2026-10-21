# Test map: what to run for what changed

User rule (2026-10-18): test what changed; run everything only at the overall wrap-up.
Pick the rows that match `git status`, take the union per script, and run just that.

- Package suite: `swift test --package-path Packages/<Name> --scratch-path .build-<short>` (one scratch path per package, see CLAUDE.md).
- App unit suite (about 2 min): `xcodegen generate && xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test`.
  One app suite only: add `-only-testing:CODDTests/<SuiteStruct>` (for example `M5OnboardingGateTests`).
- E2E sections: `ONLY=<ids> scripts/mN-e2e.sh` (unset = every section). An unknown id exits 64 with the valid ids.
  Ids: m2 `R1..R13`, m3 `A1..A15`, m4 `B1..B13 U1 U2` (B12 = isolation scan, for the full run),
  m5 `O1 O2 O3 D1 D2 D3 K1 S1 A1 C1 I1` (I1 = isolation scan, for the full run).
- Performance: `ONLY=launch,idle,switch,memory,gpu scripts/m5-perf.sh` (sections; run it with nothing else building).
- Every script that launches CODD runs the window-stack watcher (`scripts/lib/zorder-guard.sh`) and fails on a violation.

| Changed paths | Package suite | App unit suite | E2E sections |
|---|---|---|---|
| `App/Sidebar` | none | yes | m2 `R1,R11`; m4 `U1`; `scripts/m4-sidebar-dnd.sh` |
| `App/Session`, `App/Terminal`, `Packages/CoddComposer`, `Packages/CoddTerminal` | the package touched | yes | m2 `R5,R7,R8,R9`; `scripts/m1-smoke.sh` |
| `Packages/CoddTerminal` tier policy (`TerminalTierPolicy`, `TerminalPool`), `App/Terminal/TerminalHub.swift` (force-render, tiers) | `CoddTerminal` | yes | the row above, plus `ONLY=switch scripts/m5-perf.sh` (and `ONLY=gpu` for force-render) |
| `App/Palette` | none | yes | m2 `R6` |
| `App/NewSession` | none | yes | m2 `R4`; m3 `A3,A14` |
| `App/MenuBar`, `App/Controls`, `Packages/CoddStatusUI`, `Packages/CoddHost`, `Tools/codd-statusline` | the package touched | yes | m3 `A1,A2,A10,A12,A15` |
| `App/Settings`, `Packages/CoddSettingsUI`, `Packages/CoddPreferences`, `Packages/CoddClaudeSettings` | the package touched | yes | m3 `A6,A8,A13`; m4 `U2`; `scripts/m4-ui-zoom.sh` |
| `App/Lifecycle`, `Packages/CoddDialogsUI` | `CoddDialogsUI` (with `--skip PresenterTests`) | yes | m3 `A7,A8,A9,A11` |
| `App/Notes`, `Packages/CoddNotes`, `Packages/CoddNotebookUI`, `Packages/CoddAnnotateUI`, `Packages/CoddTextKit` | the package touched | yes | m4 `B1,B2,B6` |
| `App/MCP`, `Packages/CoddMCP` | `CoddMCP` | yes | m4 `B3,B4,B5,B8` |
| `App/Files`, `Packages/CoddFiles`, `Packages/CoddCodeEditor` | the package touched | yes | m4 `B7,B13` |
| `App/Cleanup`, `Packages/CoddCleanupUI` | the package touched | yes | m4 `B9,B10,B11` |
| `App/Theme`, `App/Window`, `App/Mock`, `App/Fonts`, `Packages/CoddUI` | `CoddUI` and the UI package whose view changed | yes | m4 `U2`; `scripts/m4-ui-zoom.sh`; `scripts/m4-layout-sweep.sh` (looks only) |
| `App/Support`, `App/AppNotifier.swift`, `App/SessionNotifier.swift`, `App/AttentionMonitor.swift` | none | yes | m2 `R2`; m3 `A5,A8` |
| `App/Debug` | none | yes | the sections that use the flag changed |
| Shared app core: `App/AppDelegate*`, `App/Real`, `App/Model`, `HolderSessionStore*`, `Tools/codd-holder`, `Packages/CoddHolder`, `Packages/CoddHooks`, `Tools/codd-hook`, `Packages/CoddCore` | the package touched | yes | `scripts/m1-smoke.sh` always; plus m2 `R1,R2,R3,R8,R9,R10,R13` and the sections of the feature touched |
| M5 onboarding: `App/Onboarding`, `App/AppDelegate+Onboarding.swift`, `Packages/CoddOnboarding`, `scripts/m5-fixtures` | `CoddOnboarding` (its `FixtureTests` run the import fixture) | `M5Onboarding*` suites (or the whole suite) | m5 `O1,O2,O3`; one mock snapshot launch `-codd-show onboarding:all -codd-snapshot <png>` for a look |
| M5 data files: `Packages/CoddDataStore`, `App/Real/DataFilesMonitor.swift`, `App/AppDelegate+Data.swift`, `App/Real/HolderSessionStore+Data.swift`, the version guards (`App/Real/PaneLayoutStore.swift`, `App/Session/ComposerStates.swift`, the backups index in `App/Real/ClaudeSettingsService.swift`, `LayoutStore.loadNewerReadOnly`), a store's load code anywhere | `CoddDataStore` (+ `CoddComposer`, `CoddClaudeSettings`, `CoddHooks` when their stores changed) | `M5DataPreflightTests`, `M5NeverStricterTests`, `M5PaneLayoutGuardTests` | m5 `D1,D2,D3`; `scripts/m1-smoke.sh` (shared core) |
| M5 identity and defaults: `project.yml`, `App/Info.plist`, `App/Support/CoddIdentity.swift`, `App/Support/DefaultsIsolation.swift`, `App/Real/InstanceLock.swift`, `App/Window/BackgroundWindows.swift`, `App/Window/MainWindowController.swift` (frame autosave), `App/MenuBar/StatusItemController.swift` (autosave name), `App/Lifecycle/LoginItems.swift` | none | `M5IdentityTests`, `M5DefaultsTests`, `M5LoginItemTests`, `AppActivationTests`, `BackgroundWindowsTests` | m5 `K1,I1` (the full run for I1); `scripts/m1-smoke.sh` |
| M5 stop while STARTING: `HolderSessionStore.stop`, `HolderSessionStore+Launch.swift`, `App/Real/HolderLauncher.swift` | none | `M5StopWhileStartingTests` | m5 `S1`; the shared core row |
| M5 accessibility: `App/Debug/AccessibilityAuditPass.swift`, `App/AppDelegate+Accessibility.swift`, `App/Controls/KeyFocusControls.swift`, `App/Theme/StateSpeech.swift`, `Packages/CoddUI/Sources/CoddUI/Accessibility`, any `KeyFocus.swift` or accessibility code in a UI package | `CoddUI` and the UI package touched (their `AccessibilityAuditTests`) | `M5SpokenStateTests`, `M5SidebarAccessibilityTests`, `M5MainWindowAuditTests`, `M5MenuItemTests`, `M5AuditFlagTests` | m5 `A1` |
| UI strings anywhere (`App/**`, `Packages/*/Sources/**`), docs, `scripts/tools/copy-audit.py`, `scripts/tools/copy-audit-allow.txt` | none | no | `python3 -I scripts/tools/copy-audit.py` (= m5 `C1`'s first half) |
| `scripts/release.sh`, `VERSION` | none | no | `scripts/release.sh --dry-run` (= m5 `C1`'s second half); a Release build `scripts/release.sh --output <temp dir>` when `project.yml` or `#if DEBUG` / Release-only code changed (delete the output afterwards) |
| Licenses and pins: `THIRD-PARTY-NOTICES.md`, `LICENSE`, `App/Fonts/OFL-*.txt`, `App/Package.resolved`, a dependency version in a `Package.swift` | none | `ReleaseNoticesTests` | `python3 -I scripts/tools/copy-audit.py`; a Release build `scripts/release.sh --output <temp dir>` (the pinned graph resolves; recheck the notices with the `nm` commands at their end) |
| `Packages/CoddHolder` (any change to the protocol, the holder or the client), `Packages/CoddHolder/Sources/codd-holder-compat`, `scripts/m5-compat.sh` | `CoddHolder` | no (yes for the shared core row) | `scripts/m5-compat.sh` (the current client against the holder of the repository's first commit, or the commits given; `git worktree list` unchanged afterwards) |
| Perf hooks: `App/Support/LaunchTiming.swift`, `App/Debug/DebugMetrics.swift`, `scripts/m5-perf.sh` | none | `M5FlagTests` | `scripts/m5-perf.sh` (the sections touched: `ONLY=launch`, `switch`, …) |
| `scripts/tools/zorder*`, `scripts/lib/` | none | no | `LIVE=1 scripts/tools/zorder-selftest.sh`; `bash -n` and `zsh -n` of the scripts touched; then any one e2e script (`scripts/m1-smoke.sh` is the shortest) |
| `scripts/m2-fixtures` | `scripts/m2-fixtures/selftest.sh` | no | m2 `R1,R2` (m3 and m4 also reuse `make-root.sh`: m3 `A1`, m4 `B1`; m5 every section with a launch) |
| `scripts/m3-fixtures` | `scripts/m3-fixtures/selftest.sh` | no | m3 `A1,A4`; m4 `B11` (fake cswap); m5 `O1` |
| `scripts/m4-fixtures` | `scripts/m4-fixtures/selftest.sh` | no | m4 `B1,B3,B7,B8,B9`; m5 `O1,S1` (fake claude m4) |
| `scripts/m*-e2e.sh` | `bash -n`, `zsh -n` | no | the sections edited |

Rules

1. Shared app core (`AppDelegate*`, `App/Real/`, `App/Model/`, `HolderSessionStore*`, `Tools/codd-holder`, `Packages/CoddHolder`, `Packages/CoddHooks`) also runs `scripts/m1-smoke.sh` (about 1 min); `scripts/m1-e2e.sh` only when claude session handling changed.
2. A package change also runs the suites of the packages that depend on it (`CoddUI`: every UI package, `CoddOnboarding` too; `CoddCore`: `CoddHooks`; `CoddPreferences`: `CoddSettingsUI`).
3. Some sections share a launch or a fixture: m4 `B3,B4,B5` share one launch, m4 `B10` re-runs `B9`'s first launches, m3 `A3` re-runs `A1,A2`'s launch; m5 `O1` has three launches (step 2, the full flow, the relaunch), `D1` three, `D3` three. `ONLY` already does this; the extra launches run silently.
4. The overall wrap-up (end of M5, before release) runs everything once, in full: the 9 earlier scripts (`m1-smoke`, `m1-e2e`, `m2-e2e`, `m3-e2e`, `m4-e2e`, `m4-sidebar-dnd`, `m4-ui-zoom`; `m4-layout-sweep` for a look), the M5 scripts `scripts/m5-e2e.sh`, `scripts/m5-perf.sh` (nothing else building), `scripts/m5-compat.sh` and `scripts/release.sh --dry-run`, the three fixture selftests (`scripts/m2-fixtures/selftest.sh --with-app <binary>`, `m3-fixtures`, `m4-fixtures`), `LIVE=1 scripts/tools/zorder-selftest.sh`, `python3 -I scripts/tools/copy-audit.py`, every package suite (CoddDialogsUI with `--skip PresenterTests`) and the app unit suite.
