# M5 fixtures

Made-up data for the onboarding import (docs/M5-PLAN.md D8, §2.5; `scripts/m5-e2e.sh` O1). Nothing here
starts claude or cswap, and nothing touches the real `~/.claude`, `~/.claude.json` or CODD's data root.

## make-import-fixture.sh

```sh
scripts/m5-fixtures/make-import-fixture.sh <claudeDir> <workDir>
```

Writes, for a throwaway home such as `$T/home`:

- project folders under `<workDir>` (each with a `README.md`): `clients/alpha-web`, `clients/alpha-api`,
  `clients/legacy-site`, `labs/mcp`, `labs/x`, `solo-tool`, `solo-tool/.claude-worktrees/solo-tool-wt1`,
  `sdk-runner`; `gone-project` is listed in `.claude.json` but never created;
- `<claudeDir>/../.claude.json` (0600) with those `projects` keys (`labs/x` spelled with a trailing slash)
  and unrelated keys: `numStartups`, `installMethod`, `autoUpdates`, `theme` and an `oauthAccount` whose
  `emailAddress` is `fixture-user@example.com` (CODD must never show it);
- `<claudeDir>/projects/<sanitized cwd>/<uuid>.jsonl`: 1 to 14 transcripts per project (none for
  `legacy-site`), two lines each, the first carrying `cwd` and `entrypoint` (`cli`; `sdk-cli` for every
  `sdk-runner` transcript, so it is SDK-only). Modification times are set with `touch -t` relative to
  now (newest: 30 min, 1 h, 3 h, 5 h, 26 h, 50 h, 74 h ago), so the last-used order is fixed and every
  dated project is inside the 14-day pre-check window.

It prints what `ProjectCatalogReader.read(claudeDirectory:home:existingProjectPaths:)` must return with no
projects in CODD:

```
SOURCE <claudeDir>/../.claude.json
EXPECT 1 <workDir>/solo-tool/.claude-worktrees/solo-tool-wt1 transcripts=1 hidden=worktree
EXPECT 2 <workDir>/clients/alpha-web transcripts=14 hidden=none
EXPECT 3 <workDir>/labs/mcp transcripts=3 hidden=none
EXPECT 4 <workDir>/sdk-runner transcripts=4 hidden=sdk
EXPECT 5 <workDir>/clients/alpha-api transcripts=5 hidden=none
EXPECT 6 <workDir>/solo-tool transcripts=2 hidden=none
EXPECT 7 <workDir>/labs/x transcripts=1 hidden=none
EXPECT 8 <workDir>/clients/legacy-site transcripts=0 hidden=none
ABSENT <workDir>/gone-project
```

Ranks follow the catalog order (hidden candidates included). With the default selection: alpha-web,
labs/mcp, alpha-api, solo-tool and labs/x are pre-checked; `依父資料夾建議分組` suggests the new groups
`clients` (alpha-web, alpha-api; legacy-site keeps it as its suggestion) and `labs` (mcp, x), solo-tool
stays 未分類; `labs/mcp` and `labs/x` show the `labs/` prefix (D10).

Paths are resolved with realpath first. Both folders must be inside `$TMPDIR`, `/tmp` or `/private/tmp`
(agent scratchpads are under `/private/tmp`) and never inside `$HOME`; `<claudeDir>`'s parent receives
`.claude.json`, so it must not be the temp folder itself, and an existing `.claude.json` there is never
overwritten. Paths must be printable ASCII without quotes or backslashes. Refusals exit 1, bad arguments
exit 2. `CoddOnboardingTests/FixtureTests.swift` runs it into a temp folder and reads it back.
