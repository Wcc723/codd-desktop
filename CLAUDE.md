# CODD Desktop

Native Swift macOS app that manages many Claude Code sessions. Local only.
- Product / UX spec: `design/SPEC.md` (§8 v2 and §9 v3 override earlier sections); visual tokens: `design/helmet.html`.
- Architecture, process model, holder wire protocol v1, budgets: `docs/ARCHITECTURE.md` (source of truth).
- Research behind decisions: `design/research/` (native Swift: `design/research/native-swift/synth.md` + `critique.md`).

## Build & test

- Packages: `swift build --package-path Packages/CoddHolder --scratch-path .build-holder`,
  `swift test --package-path Packages/CoddCore --scratch-path .build-core` (separate scratch paths avoid lock clashes).
  Same for CoddHooks, CoddTerminal and CoddComposer (`swift test --package-path Packages/CoddComposer --scratch-path .build-composer`)
  and the M3 packages CoddUI, CoddPreferences, CoddClaudeSettings, CoddHost, CoddStatusUI, CoddSettingsUI and
  CoddDialogsUI (`swift test --package-path Packages/CoddStatusUI --scratch-path .build-status`; the UI packages
  have demos: `codd-ui-gallery`, `codd-status-demo`, `codd-settings-demo`, `codd-dialogs-demo` with
  `--fonts App/Fonts --snapshot <dir>`; run CoddDialogsUI with `--skip PresenterTests` to keep test windows away).
  M4 packages CoddNotes, CoddMCP, CoddTextKit, CoddCodeEditor, CoddFiles, CoddNotebookUI, CoddAnnotateUI, CoddCleanupUI
  and M5 packages CoddOnboarding, CoddDataStore (`swift test --package-path Packages/<Name> --scratch-path .build-<Name>`);
  demos `codd-markdown-demo`, `codd-code-demo`, `codd-files-demo`, `codd-notebook-demo`, `codd-annotate-demo`,
  `codd-cleanup-demo`, `codd-onboarding-demo`.
- App: `xcodegen generate && xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build`
- End to end (fake claudes, temp roots): `scripts/m1-e2e.sh`, `scripts/m1-smoke.sh`, `scripts/m2-e2e.sh`,
  `scripts/m3-e2e.sh` (fake cswap too; `CODD_APP=<…/CODD.app/Contents/MacOS/CODD>`, `KEEP=1`),
  `scripts/m4-e2e.sh`, `scripts/m5-e2e.sh`, `scripts/m5-perf.sh` (alone, nothing else building), `scripts/m5-compat.sh`,
  `scripts/m2-fixtures/selftest.sh [--with-app <binary>]`, `scripts/m3-fixtures/selftest.sh`,
  `LIVE=1 scripts/tools/zorder-selftest.sh`, `python3 -I scripts/tools/copy-audit.py`.
- Release: `scripts/release.sh --dry-run | --output <temp dir>`; `--install` only by the user, outside Claude Code.
- Manual app runs on a throwaway root: `scripts/m2-fixtures/make-root.sh <dir>` (own hook port), then
  `-codd-data-root <dir> -codd-claude-dir <temp dir> -codd-login-env NO -codd-notifications NO`; with accounts,
  also `-codd-cswap-path <copy of scripts/m3-fixtures/fake-cswap.py> -codd-cswap-root <make-cswap-state.sh root>`
  (recipe in `scripts/m3-fixtures/README.md`). Every automated launch runs in the background (`CODD_BACKGROUND=1`).
- Spike: `cd Spikes && xcodegen generate && xcodebuild -project TermSpike.xcodeproj -scheme TermSpike -configuration Debug -derivedDataPath ../build/spike -skipPackagePluginValidation -skipMacroValidation build`
- Which tests to run for a change (package suites, app unit suite, `ONLY=<ids>` e2e sections): `scripts/TEST-MAP.md`; run everything only at the overall wrap-up.
- Filter xcodebuild output: `… 2>&1 | grep -E "error:|warning:|BUILD"`.
- Signing: `scripts/release.sh` signs ad-hoc (`-`) unless asked for an Apple Development or Developer ID identity
  (`--identity "<name>"` or `RELEASE_IDENTITY=…`), which puts the certificate's name and Team ID into the signature;
  always with the hardened runtime and `scripts/release.entitlements` (CODD.app and codd-holder).
  It builds with the package graph pinned by `App/Package.resolved` (`-onlyUsePackageVersionsFromResolvedFile`);
  after a dependency change, copy the workspace's `swiftpm/Package.resolved` there.
- Licenses: `LICENSE` (MIT); every shipped third-party license is in `THIRD-PARTY-NOTICES.md` (a resource,
  opened from Settings › 關於); recheck it with the `nm` commands at its end when libghostty-spm changes.

## Rules

- Swift 6 language mode, strict concurrency. Terminal bytes never touch the main actor or Observation.
- Tests use temp directories only; never touch `~/.claude/settings.json`, `~/.claude-swap-backup`,
  `~/Library/Application Support/CODD`, or run the real cswap (use the fake); never call the Anthropic usage API.
- Do not start real `claude` sessions in automated tests (they consume quota); use `/bin/sh`, `zsh -f`, `cat`, `yes`.
- UI copy: 繁體中文 for explanatory text, English UPPERCASE for structural labels. No emoji anywhere.
- Ask the user before decisions with lasting product impact (engine choice, signing, data locations).
- The bundle id is `app.codd.CODD`; every name derived from it goes through `App/Support/CoddIdentity.swift`.
- Every script that launches CODD sources `scripts/lib/zorder-guard.sh` (background windows must stay behind other apps;
  it also drops the `CODD_*` session variables a run inherits when started inside a CODD session).
- Never read or write the real defaults domains, `/Applications` or `~/.Trash` in tests; test runs never write CODD's
  defaults (M5 D25); `~/.claude.json` and `~/.codex` join the files tests never touch.
