# Developing CODD Desktop

How to build, test, try and package CODD from source. The [README](../README.md) (繁體中文) covers
installing and using it, the [user guide](USER-GUIDE.zh-TW.md) every feature.
[ARCHITECTURE.md](ARCHITECTURE.md) is the source of truth for the process model, the data root, the holder
wire protocol and the performance budgets; [CLAUDE.md](../CLAUDE.md) is the short version of the commands and
rules below for Claude Code sessions working in this repository.

Every terminal is owned by a small `codd-holder` process, not by the app. Quitting, crashing or updating CODD
leaves the sessions running; the next launch reattaches to them. After a reboot a stopped Claude session
resumes with `claude --resume`. Version 1.0.0 (`VERSION`), bundle id `app.codd.CODD`; a Release's build
number is the commit count.

## Requirements

- macOS 26.0 or later (the project's deployment target).
- Xcode 27 (Swift 6.4, Swift 6 language mode with strict concurrency).
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`): the Xcode project is generated
  from `project.yml` and is not checked in.
- `python3` (the fixtures and fakes of the end-to-end scripts).
- Network on the first build: SwiftPM fetches libghostty-spm (with its prebuilt `GhosttyKit.xcframework`),
  DisplayLink and GRDB.swift from GitHub. Each `Package.swift` names an exact version; Release builds also
  pin the revisions (`App/Package.resolved`, see Release).
- To use it for real: Claude Code (`claude` on your login shell's PATH or in `~/.local/bin`), and
  optionally cswap 0.26 or later for several Claude accounts.

## Repository layout

```
App/                 CODD.app sources (AppKit; SwiftUI only for a few leaf views), app tests in App/Tests,
                     App/Package.resolved (the app's pinned package graph), App/Fonts (fonts and their OFL texts)
Tools/               thin Xcode targets for the embedded helpers: codd-holder, codd-hook, codd-statusline
Packages/            SwiftPM packages, each with its own tests:
  CoddHolder           holder process, wire protocol v1, client (HolderStream), ring reader
  CoddCore             models, layout store, hook state machine, launch builder, cswap reader, quota
  CoddHooks            loopback hook / status line / MCP server, config.json, registry watcher
  CoddTerminal         libghostty engine and terminal pool (vendored wrapper, see its NOTICE)
  CoddComposer         the ⌘L composer (TextKit 1, IME-safe)
  CoddUI               the design system (Phosphor Console tokens, controls, zoom)
  CoddPreferences, CoddClaudeSettings, CoddHost, CoddStatusUI, CoddSettingsUI, CoddDialogsUI   (M3)
  CoddNotes, CoddMCP, CoddTextKit, CoddCodeEditor, CoddFiles, CoddNotebookUI, CoddAnnotateUI,
  CoddCleanupUI                                                                                 (M4)
  CoddOnboarding, CoddDataStore   first-launch wizard; data file versions and recovery         (M5)
design/              product / UX spec (SPEC.md), the approved artboards (artboards-src/; earlier rounds in
                     v1/ and v2/), tokens (helmet.html), the research behind the decisions (research/)
docs/                architecture, this file, roadmap, milestone plans and reports, the user guide, README images
scripts/             end-to-end scripts (m1–m5), fixtures and fakes (m2/m3/m4/m5-fixtures), m5-perf.sh,
                     m5-compat.sh, release.sh, lib/ (the window-stack guard), tools/ (zorder, copy audit)
Spikes/              the terminal engine spike (separate project)
VERSION              the marketing version (MARKETING_VERSION; scripts/release.sh)
LICENSE              MIT; THIRD-PARTY-NOTICES.md holds every shipped third-party license
```

The artboards in `design/artboards-src/` are HTML sources for the claude.ai Design canvas: they include that
canvas's `./support.js`, which is not in this repository.

## Build

Each package builds and tests on its own. Use a separate scratch path per package so concurrent
builds do not fight over SwiftPM's lock:

```bash
swift build --package-path Packages/CoddHolder --scratch-path .build-holder
swift test  --package-path Packages/CoddCore     --scratch-path .build-core
swift test  --package-path Packages/CoddComposer --scratch-path .build-composer
swift test  --package-path Packages/CoddStatusUI --scratch-path .build-status
swift test  --package-path Packages/CoddDialogsUI --scratch-path .build-dialogs --skip PresenterTests
```

`--skip PresenterTests` keeps the dialog presenter tests (they order windows to the front) away. The
UI packages have offscreen demos that write PNG snapshots: `codd-ui-gallery`, `codd-status-demo`,
`codd-settings-demo`, `codd-dialogs-demo`, the M4 `codd-markdown-demo`, `codd-code-demo`, `codd-files-demo`,
`codd-notebook-demo`, `codd-annotate-demo` and `codd-cleanup-demo`, and the M5 `codd-onboarding-demo`:

```bash
swift run --package-path Packages/CoddStatusUI --scratch-path .build-status codd-status-demo --fonts App/Fonts --snapshot <dir>
```

The app (Debug, into `build/dd`):

```bash
xcodegen generate && xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build
```

Filter the output with `2>&1 | grep -E "error:|warning:|BUILD"`; keep the build free of warnings (the M5
package and Release builds had none, docs/M5-REPORT.md §3 and §4). Debug builds are signed ad-hoc (`-`).

## Test

**Test what changed.** [scripts/TEST-MAP.md](../scripts/TEST-MAP.md) maps changed paths to the package
suites, the app unit suite and the end-to-end sections to run; every script and suite runs in full only
once, before a release.

- Package suites: `swift test --package-path Packages/<Name> --scratch-path .build-<short>` (a package
  change also runs the suites of the packages that depend on it, see TEST-MAP rule 2).
- App unit suite (about 2 minutes), hosted in CODD itself:
  `CODD_BACKGROUND=1 xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test`
  (one suite: add `-only-testing:CODDTests/<SuiteStruct>`).
- End to end: `scripts/m1-e2e.sh`, `scripts/m1-smoke.sh`, `scripts/m2-e2e.sh`, `scripts/m3-e2e.sh`,
  `scripts/m4-e2e.sh`, plus `scripts/m4-sidebar-dnd.sh`, `scripts/m4-ui-zoom.sh` and
  `scripts/m4-layout-sweep.sh <out dir>` (PNGs only). The m2–m5 e2e scripts take `ONLY=<ids>` to run single
  sections (an unknown id exits 64 and lists the valid ones); `KEEP=1` keeps the temp folder,
  `CODD_APP=<…/CODD.app/Contents/MacOS/CODD>` picks the binary.
- M5: `scripts/m5-e2e.sh` (sections `O1 O2 O3` onboarding, `D1 D2 D3` newer / corrupt data files and
  `cache/VERSION`, `K1` bundle identity, `S1` stop while STARTING, `A1` accessibility audit, `C1` copy audit
  and release dry run, `I1` isolation), `scripts/m5-perf.sh` (the ARCHITECTURE budgets,
  `ONLY=launch,idle,switch,memory,gpu`, `PERF_JSON=<file>`; run it with nothing else building) and
  `scripts/m5-compat.sh [commit…]` (the current client against `codd-holder` built from older commits in
  temporary git worktrees, which it removes again; without arguments it uses the repository's first commit,
  the 1.0 holder).
- Fixture self tests: `scripts/m2-fixtures/selftest.sh [--with-app <binary>]`,
  `scripts/m3-fixtures/selftest.sh`, `scripts/m4-fixtures/selftest.sh`.
- Copy audit: `python3 -I scripts/tools/copy-audit.py` (no emoji anywhere, no old product name or bundle
  id outside its allow list, no e-mail addresses, simplified-only characters or glossary variants in UI
  strings; English sentences in UI strings are listed for review). Exit 0 means clean; the allow list is
  `scripts/tools/copy-audit-allow.txt`, each entry with its reason.
- Window-stack watcher: `LIVE=1 scripts/tools/zorder-selftest.sh` checks the watcher itself.

The end-to-end scripts start CODD with fake claudes (`scripts/fake-claude.sh`, the m2 / m3 / m4
fakes), a fake cswap (`scripts/m3-fixtures/fake-cswap.py`) and fresh temp data roots
(`scripts/m2-fixtures/make-root.sh`), and end every process they started.

### Safety rules for tests and agents

CODD runs in real mode by default, on the user's real data. Every automated run must follow these:

- **Temp roots only.** Every launch passes `-codd-data-root <fresh temp dir>` and
  `-codd-claude-dir <temp dir>` (or `-codd-mock`). Pass every flag as its own argument (`"$APP"
  -codd-data-root "$T/r" …`, or a bash array): zsh does not split an unquoted variable, so flags kept
  in one variable reach CODD as one argument and it runs on the real data root. A DEBUG build started
  from a Claude Code shell without a data root refuses to run (exit 64); never work around that.
- **Never touch the user's files:** `~/.claude/settings.json`, `~/.claude.json`, `~/.codex`,
  `~/.claude-swap-backup`, `~/Library/Application Support/CODD`, `/Applications`, `~/.Trash`. Code that
  edits Claude settings takes an injectable path; tests use temp files.
- **Never run the real cswap or a real `claude`** (they change accounts and use quota); use the
  fakes, `/bin/sh`, `zsh -f`, `cat` or `yes`. Never call the Anthropic usage API or any other
  Anthropic API.
- **Background launches.** Every script that starts CODD exports `CODD_BACKGROUND=1`; a background
  CODD never activates and keeps every window behind the user's windows. Never launch CODD.app with
  `open`, never pass `-codd-background NO`, never run AppleScript `activate` or anything else that
  changes the frontmost app. Every script that starts CODD sources `scripts/lib/zorder-guard.sh`: the
  window-stack watcher (`scripts/tools/zorder.sh`) runs for the whole run, counts only the windows of the
  build under test (the user's own CODD is another app) and fails the run when one rises above another
  app's window. The guard also drops the `CODD_*` variables a run inherits when it starts inside a CODD
  session.
- **Test runs never write CODD's own defaults.** On any data root but the standard one, and in mock
  mode, the main window frame, the split view and the menu bar item position are neither restored nor
  saved, so test runs never change the installed CODD's window or menu bar position (M5 D25). Nothing
  automated reads or writes the real defaults domains.
- **Clean up** every app, holder, shell and fake server you started, and nothing else: the user's own
  CODD and its sessions may be running on the same Mac.

## Trying the app by hand on a throwaway root

```bash
APP=build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
T="$(mktemp -d "${TMPDIR%/}/codd-try.XXXXXX")"
scripts/m2-fixtures/make-root.sh "$T/root"
mkdir -p "$T/claude/sessions"
"$APP" -codd-data-root "$T/root" -codd-claude-dir "$T/claude" -codd-login-env NO -codd-notifications NO
```

`make-root.sh` gives the root its own hook port. On a data root other than the standard one a Debug
build starts in the background (no Dock icon, every window behind the other apps' windows): click a
CODD window or use the menu bar item's `開啟 CODD`. Automated runs add `CODD_BACKGROUND=1` anyway.

- Accounts: also pass `-codd-cswap-path <copy of scripts/m3-fixtures/fake-cswap.py>` and
  `-codd-cswap-root <root from make-cswap-state.sh>`; the full recipes are in `scripts/m3-fixtures/README.md`
  and `scripts/m4-fixtures/README.md`.
- First-launch wizard: it never opens by itself on such a root. Add `-codd-onboarding show` (DEBUG), and for
  projects to import run `scripts/m5-fixtures/make-import-fixture.sh "$T/claude" "$T/work"` first (it writes
  `$T/.claude.json`).
- Mock data for screenshots: `"$APP" -codd-mock`.

The DEBUG flags are listed in `App/Real/RealModeOptions.swift` and in ARCHITECTURE "Testing hooks";
Release builds keep only the mode, the data root and the Claude directory.

## Release

`scripts/release.sh` builds a Release with pinned dependencies, re-signs it, verifies the signature and
zips it.

```bash
scripts/release.sh --dry-run              # print the plan, build nothing
scripts/release.sh                        # Release build into build/release
scripts/release.sh --output <dir>         # build into another folder (tests, CI-like runs)
scripts/release.sh --identity "<name>"    # sign with a certificate instead of ad-hoc
scripts/release.sh --install              # build, then install to /Applications (only you, from a normal Terminal)
```

- Versions: `VERSION` becomes `CFBundleShortVersionString`, `git rev-list --count HEAD` becomes
  `CFBundleVersion` (a dirty working tree only prints a warning). `xcodegen generate` runs only when the
  project is missing or older than `project.yml`.
- Pinned packages: the tracked `App/Package.resolved` is copied into the generated workspace
  (`CODD.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) and xcodebuild runs with
  `-onlyUsePackageVersionsFromResolvedFile`, so a moved upstream tag fails the build instead of linking
  another dependency (libghostty's prebuilt XCFramework included). After changing a dependency on purpose,
  resolve once without the flag (Xcode, or `xcodebuild … -resolvePackageDependencies`), review the new pins
  and copy the workspace's `Package.resolved` to `App/Package.resolved`.
- Signing: ad-hoc (`-`) by default; a keychain identity is never picked up on its own. `--identity <name>`
  (or `RELEASE_IDENTITY`; the option wins) signs with an Apple Development or Developer ID Application
  identity, given as its whole name, a part that matches exactly one name, or its SHA-1, as
  `security find-identity -v -p codesigning` lists it (`-` is ad-hoc). The script then warns that the
  certificate's name and Team ID end up in the signature of the app and the zip, where anyone can read
  them with `codesign -dvv`. The embedded helpers (`codd-holder`, `codd-hook`, `codd-statusline`,
  identifiers `app.codd.<name>`) are signed first, then any nested code in `Contents/Frameworks` and
  `Contents/PlugIns` (none today), then the app, never with `--deep`; the result is checked with
  `codesign --verify --strict --deep`. No notarization and no Sparkle, so a downloaded copy is blocked by
  Gatekeeper on other Macs until the user allows it in System Settings › Privacy & Security (the README's
  download steps); a build from source is not blocked.
- Hardened runtime: every signature the script makes gets `--options runtime`, and the re-sign still drops
  Xcode's entitlements (no `get-task-allow`). `scripts/release.entitlements` holds the seven resource-access
  entitlements Ghostty also ships: `com.apple.security.automation.apple-events`,
  `com.apple.security.device.audio-input`, `com.apple.security.device.camera` and
  `com.apple.security.personal-information.addressbook`, `.calendars`, `.location`, `.photos-library`.
  CODD is a terminal host: while CODD runs, macOS attributes the privacy (TCC) requests of the programs
  run in its sessions (`osascript`, a CLI that wants the camera or the microphone) to the responsible app,
  CODD, and asks in its name. Under the hardened runtime tccd prompts only when that app has both the
  entitlement and the matching purpose string in its `Info.plist`; without either it refuses without a
  prompt (Apple Events alone still prompts without a string). The strings (`NSAppleEventsUsageDescription`,
  `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSContactsUsageDescription`,
  `NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription`,
  `NSRemindersUsageDescription` / `NSRemindersFullAccessUsageDescription`,
  `NSLocationUsageDescription` / `NSLocationWhenInUseUsageDescription`, `NSPhotoLibraryUsageDescription`)
  live in `project.yml` (`targets.CODD.info.properties`, which xcodegen writes to `App/Info.plist`); the
  script's `usage_keys` maps each entitlement to the strings it needs and refuses an entitlement it does
  not know. The file is signed into `CODD.app` and `codd-holder` (holders are spawned with
  `POSIX_SPAWN_SETSID`, without disclaiming responsibility, and outlive the app; for the holder it is a
  precaution, see the comment at `ENTITLEMENTS` in the script), not into `codd-hook` or
  `codd-statusline` (TCC looks at the responsible process, not at intermediate ones such as the
  status line's chained command). None of them is restricted, so ad-hoc signing takes them.
- Strip: after the copy and before signing, `strip -S` removes the debug map from every Mach-O in
  `Contents/MacOS` (and in nested code, none today), so no binary names build-machine paths such as
  `/Users/<name>/<project folder>`; the symbol table stays.
- Verify, besides the bundle id, the versions and the helper identifiers: the runtime flag on the app and
  each helper for every architecture (`codesign -dvv --arch <arch>` shows `flags=0x10002(adhoc,runtime)`
  ad-hoc, the runtime flag with an identity); the entitlements (`codesign -d --entitlements - --xml`) of
  `CODD.app` and `codd-holder` equal to the file and none on the other two helpers; a non-empty purpose
  string in the built `Info.plist` for each of the file's entitlements (PlistBuddy `Print`); no Mach-O
  containing the repository path, the derived-data path or `$HOME/` (`grep -a -c`). A miss fails with
  `RELEASE error: verify: …`.
- Debug builds keep `ENABLE_HARDENED_RUNTIME: NO`, so the e2e scripts never run hardened code. When the
  signing, entitlements, strip or `Info.plist` steps change, also smoke-launch the Release app once
  (`CODD_BACKGROUND=1`, a `make-root.sh` root, `scripts/lib/zorder-guard.sh`; scripts/TEST-MAP.md). A
  Release build honours only the mode, the data root and the Claude directory (no `-codd-spawn-shell`),
  so check that the hook endpoint binds and start a holder from the root's `bin/` copy with
  `codd-holderctl spawn` (`.build-holder/debug/codd-holderctl`).
- Zip: `ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl`, so the zip has no `._`
  AppleDouble entries (checked with `zipinfo -1`); a copy unpacked from the zip must verify and carry the
  app's CDHash.
- Output: `build/release/CODD.app`, `build/release/CODD-<version>-<build>.zip` and `xcodebuild.log`, the
  checksum lines `RELEASE sha256 <hex> CODD-<version>-<build>.zip` (`shasum -a 256`) and
  `RELEASE cdhash arm64=<hex> x86_64=<hex>` (the `CDHash=` line of `codesign -dvvv --arch <arch>`), and the
  line `RELEASE app=<path> zip=<path> version=<v> build=<n> identity=<adhoc|name> bundle=app.codd.CODD`.
  `RELEASE_EXPECT_BUNDLE` (default `app.codd.CODD`) is the bundle id the built app must carry. Put both
  checksums in the release notes: users compare the zip's SHA-256 (`shasum -a 256 <zip>`) or, when Safari
  has already unpacked the zip and moved it to the Trash, the CDHash of `/Applications/CODD.app` for their
  Mac (`codesign -dvvv /Applications/CODD.app 2>&1 | grep '^CDHash='` shows the host architecture's: arm64
  on Apple silicon, x86_64 on Intel).
- `--output <dir>` puts derived data in `<dir>/dd` and the app, zip and log in `<dir>`. It refuses a folder
  inside the repository but outside `build/` (where `git add -A` would pick the zip and log up),
  `build/user-*`, `build/wt-*`, `/Applications`, `~/Applications` and folders inside them, and a folder
  holding a `CODD.app` the script did not make (no `.codd-release-output` marker next to it).
- Publishing: GhosttyKit carries GNU libintl (LGPL-2.1) and z2d (MPL-2.0). After the zip the script prints
  the two source archives (names, URLs and SHA-256) to attach to the same GitHub release, next to the
  zip; list the SHA-256 of every attached file in the release notes. See
  [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) "Source of the MPL-2.0 and LGPL-2.1 parts". When
  libghostty-spm or another package changes, recheck that file with the `nm` commands at its end.
- `--install` is for the user only: it refuses inside a Claude Code shell (`CLAUDECODE` set) and while
  `/Applications/CODD.app` is running, and only installs a build to `build/release`; it copies the new
  app to `/Applications/.CODD.app.installing`, verifies it, moves the old one to the Trash with
  `/usr/bin/trash` and renames the new one into place, then prints the next steps. Sessions keep running
  across the install (holders are separate processes).
- Exit status: 0 done, 1 failed, 2 usage, 3 refused. The script never launches CODD and never reads or
  writes a CODD data root.

## Performance budgets

Launch to an interactive sidebar < 400 ms (Release; the Debug build the script measures: < 450 ms); idle CPU
< 0.5 % with the window visible, < 0.1 % hidden, holders about 0 (< 0.05 % for all 15 together); session
switch < 16 ms hot, < 50 ms cold; memory: holder ≤ 2.5 MB, app base < 80 MB, total with 15 sessions
< 300 MB, and < 550 MB while a visible terminal animates (the Metal driver keeps a pool of about 225 MB per
process while anything draws; docs/ARCHITECTURE.md has the measured reason). `scripts/m5-perf.sh` measures
them on the Debug build and prints `PERF env load1=… cpus=… build=…` first, then one
`PERF <name> value=… budget=… PASS|FAIL|SKIP (note)` line each and `PERF summary pass=… fail=… skip=…`.
Its budget table mirrors docs/ARCHITECTURE.md "Performance budgets" and changes with it; the measured
numbers are in docs/M5-REPORT.md §4.

## Documentation

- [USER-GUIDE.zh-TW.md](USER-GUIDE.zh-TW.md): the user guide (繁體中文): install, first launch, every
  feature, where data lives, updating and uninstalling, troubleshooting.
- [ARCHITECTURE.md](ARCHITECTURE.md): decisions, repository layout, process model, the data root (every
  entry USER DATA or DERIVED), testing hooks, holder wire protocol v1, budgets.
- [design/SPEC.md](../design/SPEC.md) (§8 v2, §9 v3 and §10 override earlier sections), the approved
  artboards in `design/artboards-src/`, the visual tokens in `design/helmet.html`.
- [ROADMAP.md](ROADMAP.md) and `docs/M<n>-PLAN.md` / `docs/M<n>-REPORT.md` for each milestone (what was
  built, numbers, known issues, decisions, manual checklists).
- [scripts/TEST-MAP.md](../scripts/TEST-MAP.md): which tests to run for a change.
- Package READMEs (`Packages/CoddTerminal/README.md`, `Packages/CoddHooks/README.md`, the UI packages,
  `Packages/CoddOnboarding/README.md`) and the fixture READMEs in `scripts/m2-fixtures/`,
  `scripts/m3-fixtures/`, `scripts/m4-fixtures/`, `scripts/m5-fixtures/`.
- [CLAUDE.md](../CLAUDE.md): the short version of the build commands and rules for Claude Code sessions in
  this repository.
