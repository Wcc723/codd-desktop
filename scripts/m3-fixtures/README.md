# M3 fixtures

Helper scripts for the M3 end-to-end run (`scripts/m3-e2e.sh`, step I4) and for every agent that
launches CODD.app with accounts, quota and the status line (docs/M3-PLAN.md C9, §1, §3, §6). They
replace the real `cswap`, a real `claude` login and the user's Claude settings. Bash and
`python3 -I` only, Python 3.9 compatible (the system `/usr/bin/python3`). No network: the only
sockets in the self test are a hook sink on 127.0.0.1 and refused connections to 127.0.0.1:9. No
Anthropic API, no Keychain, no credentials. E-mails are `*@example.com` only.

`PYTHON3=<python>` picks the interpreter of the generator scripts and the self test. The default is
`/usr/bin/python3` when it exists, else `python3` from PATH. `fake-cswap.py` and `fake-claude-m3.sh`
always run with `/usr/bin/python3 -I` (their shebang).

| Script | What it is |
|---|---|
| `make-cswap-state.sh` | A fake cswap 0.26 state root in cswap's exact file formats, plus the matching `.claude.json`. |
| `fake-cswap.py` | A fake `cswap` CLI working on that state (`--version`, `list` / `status --json`, `switch`, `add`, `alias`). |
| `fake-claude-m3.sh` | `scripts/m2-fixtures/fake-claude-m2.sh` plus Claude Code's status line runner, `FAKE_REGISTRY_DIR=auto`, masked env lines and a fake `/login`. |
| `make-claude-settings.sh` | A temp `settings.json` shaped like a real one (another hook tool `hook-tap`, osascript, CODD web leftovers). |
| `rate-limits.sh` | The `rate_limits` object the fake claude puts into its status line input. |
| `selftest.sh` | Runs everything in a mktemp folder and prints `M3FIXTURES pass=<n> fail=0`. |
| `_m3fix.py`, `_selftest.py` | The Python behind the generators and the self test. |

## Safety rules

- **Refused targets (exit 1).** Every writing script refuses a target inside `~` (unless it is also
  under `$TMPDIR`), `~/Library`, `~/.claude`, `~/.claude.json` or `~/.claude-swap-backup`. Both
  `$HOME` and the account's home from the password database count as `~`.
- **The fakes are stricter.** `fake-cswap.py` (`FAKE_CSWAP_ROOT`, `FAKE_CLAUDE_JSON`,
  `FAKE_CSWAP_LOG`) and the fake claude's `/login` (`FAKE_CLAUDE_JSON`, and reading
  `FAKE_CSWAP_ROOT`) refuse any path outside `$TMPDIR`. Without `TMPDIR` they use the per-user temp
  folder launchd normally exports (`getconf DARWIN_USER_TEMP_DIR`), else `/tmp`. A refusal happens
  before anything is read or written.
- **No real tools.** Nothing here runs the real cswap or claude, opens `~/.claude-swap-backup`,
  `~/.claude` or `~/.claude.json`, or executes the generated hook commands. The osascript handlers
  in a generated settings file would show a notification if something ran them, so never point a
  claude at that file except a fake claude (which only runs `--settings` hooks).
- **Starts no process.** `make-*.sh` and `rate-limits.sh` start no process.

## Cleanup rule

Every process the fixtures start carries the caller's root path in its argv:

- **The fake claude.** Copy it into the root. Its `--settings` names `<dataRoot>/bin/...`.
- **Status line runs.** They are `/bin/sh -c <statusLine.command>`, where the command is CODD's
  `<dataRoot>/bin/codd-statusline-*` or your stub path. Each run has its own process group, and the
  fake claude kills that group when it exits or a run times out.
- **The fake cswap.** It is short-lived. Copy it into the root.

Clean up with `pkill -TERM -f "<root>/"`, wait, then `pkill -KILL -f "<root>/"`. Never kill anything
else. CODD holders outlive the app (see scripts/m2-fixtures/README.md).

## Naming rules

These follow cswap 0.26.0's real naming. Read from `claude_swap/session.py`, `switcher.py` and
`paths.py`; never run.

| Item | Rule | Fixture value |
|---|---|---|
| State root | `<home>/.claude-swap-backup`; CODD's CLI derives `cswap-<n>` from `…/.claude-swap-backup/sessions/<n>-…` | `make-cswap-state.sh` refuses any other last component |
| Config backup | `configs/.claude-config-<n>-<email>.json` (raw e-mail in the name) | `.claude-config-2-north@example.com.json` |
| `cswap run` profile | `sessions/<n>-<slugify_email(email)>`, where slugify keeps ASCII letters, digits and `._-`, everything else becomes `_` | **`sessions/2-north_example.com`** |
| Stale marker | `sessions/.<profile dir name>.cswap-stale-credentials` (sibling of the profile; the legacy child location `<profile>/.cswap-stale-credentials` is not written) | `sessions/.2-north_example.com.cswap-stale-credentials` |
| Global config | `<claudeDir>/../.claude.json` (cswap's rule without `.config.json`) | `<home>/.claude.json` |

**The profile slug.** The plan writes the slug as `2-north-example-com`, but cswap's real slug is
`north_example.com`. The fixtures follow cswap. Grepping a dump or log for `example-com` therefore
finds nothing even when a profile path leaked. Grep for **`example.com`** instead: it catches the
e-mails, the config file names and the slug.

Recommended layout: one dedicated folder per run group, with the Claude directory and the cswap
root as siblings. Then `.claude.json` is the same file for CODD (`-codd-claude-dir`), the fake cswap
(its default `FAKE_CLAUDE_JSON`) and the fake claude's `/login`:

```text
$ROOT/home/.claude/                  -codd-claude-dir (settings.json, sessions/, projects/)
$ROOT/home/.claude.json              the global login (cswap: oauthAccount)
$ROOT/home/.claude-swap-backup/      -codd-cswap-root, FAKE_CSWAP_ROOT
$ROOT/bin/cswap  + cswap.env         -codd-cswap-path (a copy of fake-cswap.py)
$ROOT/bin/fake-claude + .env         -codd-claude-path (a copy of fake-claude-m3.sh)
```

## Redaction expectations

The fixtures deliberately put e-mails everywhere cswap does (D31), so CODD's redaction is exercised:

- `sequence.json` (`email`), and #1's `organizationName` (`personal@example.com's Organization`);
- `cache/usage.json` row guards (`email`);
- config backup file names and contents (`emailAddress`);
- the profile directory name (`2-north_example.com`);
- `.claude.json` (`oauthAccount.emailAddress`);
- the fake cswap's `list` / `status` / `switch` JSON (`email`, `from` / `to`, `message`) and
  `FAKE_CSWAP_WARN` warnings;
- every fake cswap error message (`ClaudeCodeLockTimeout`, `SwitchError`, …), which names both
  accounts' e-mails;
- `add`'s stdout (`Added Account 4: new@example.com [...]`).

The e2e should then find:

- **No `@example.com`** in any file under CODD's data root (`quota.json`, `preferences.json`,
  `layout.json`, backups index, session folders), in the state dump or in the app log.
- **No `example.com`** at all (which covers the plan's `example-com` check and the real slug) in
  the dump and the app log. In the data root, only fixture-owned files may have it, so keep fixture
  files such as `FAKE_LOG_DIR` and cswap logs outside `-codd-data-root`.

The fake claude itself never prints an e-mail or the profile path:

- `FAKE-ENV CLAUDE_CONFIG_DIR=set|unset`;
- `FAKE-REGISTRY <CLAUDE_CONFIG_DIR>/sessions/<pid>.json`;
- `FAKE-LOGIN-OK account=<n>`.

`fake-claude-m3.sh --version` (alone) prints `2.1.300 (Claude Code)` and exits 0 at once: Settings
› 關於 runs `<claude> --version` when it opens (D28, M3 I3), and on a test root that is the
`-codd-claude-path` fake.

## make-cswap-state.sh

```sh
scripts/m3-fixtures/make-cswap-state.sh <cswapRoot> <claudeDir> [--now <iso>] [--accounts 3|4] [--stale <n>]
# -> prints <cswapRoot>
```

- **Arguments.** `<cswapRoot>`'s last component must be `.claude-swap-backup`. `<claudeDir>`'s
  parent must be a dedicated folder: not `$TMPDIR`, `/tmp`, `/private/tmp`, the per-user temp folder
  or `/` itself. Otherwise the call refuses (exit 1) before writing anything, because
  `<claudeDir>/../.claude.json` would land in a shared folder.
- **`--now <iso>`** fixes "now" (for example `2026-10-17T02:00:00Z`). The default is the current
  time, whole seconds.
- **`--accounts 4`** adds #4 (no alias), for the menu bar `▸ 全部帳號` expander.
- **`--stale <n>`** writes cswap's stale marker for profile n, creating the profile when it is
  missing. On a root that already has `sequence.json`, only `--stale` is applied (mid-run, against
  the account in that `sequence.json`; `--now` / `--accounts` are ignored). Anything else on an
  existing root is refused (exit 1).
- **Exit codes:** 1 for a refusal, 2 for bad arguments.

### Accounts

| # | e-mail | organizationUuid | organizationName | alias | plan tier |
|---|---|---|---|---|---|
| 1 | `personal@example.com` | `""` | `personal@example.com's Organization` | `個人` | `default_claude_max_20x` |
| 2 | `north@example.com` | `org-2` | `Synthetic North Org` | `藍鵲` | `default_claude_max_20x` |
| 3 | `work@example.com` | `""` | `""` | `工作` | `default_claude_max_20x` |
| 4 (`--accounts 4`) | `new@example.com` | `org-4` | `Synthetic Org 4` | none | `default_claude_max_5x` |

- **Plan type.** `organizationType` is `claude_max` for all of them.
- **Active account.** #3: `sequence.json` `activeAccountNumber` 3, and `.claude.json` carries #3's
  `oauthAccount`.
- **Aliases.** The CJK aliases are what an older cswap or a hand edit left in the file. cswap 0.26
  itself only accepts `^[a-z0-9_.-]+$` (D34). Reading them is fine.
- **#4 and the fake login.** #4 is also the identity `fake-claude-m3.sh` logs in as with
  `FAKE_LOGIN_AS=4`.
- **Expected CODD results.** R7 order `#2 #3 #1`; plan chip `MAX 20x` (#4: `MAX 5x`).

### Usage rows (`cache/usage.json` `lastGood`, offsets from now)

| # | five_hour | seven_day | other | fetchedAt |
|---|---|---|---|---|
| 1 | pct 0, no `resets_at` (not started) | pct 0, reset +4d09h (with microseconds, `….441208+00:00`) | | now − 3 min |
| 2 | pct 2, reset +2h37m | pct 54, reset +1d12h | `scoped: [{name: Fable, pct: 0}]` | now − 3 min |
| 3 | pct 9, reset +2h57m | pct 85, reset +3d01h | | now − 10 min |
| 4 | pct 30, reset +1h10m | pct 20, reset +5d02h | | now − 3 min |

- **Rows** are clean success rows, written in the key order cswap's claim and record steps leave.
  Each row has `email`, `organizationUuid` (the identity guard), `lastAttemptAt`, `claimId: null`,
  `claimUntil: 0.0`, `lastGood`, `fetchedAt`, `nextPollAt` (= fetchedAt + 180 s), `pollIntervalS`
  180, `consecutiveFailures` 0, `lastError` null, `backoffUntil` null and `authDeadStrikes` 0.
- **`fetchedAt`** is epoch seconds as a float.
- **`resets_at`** is ISO 8601 with `+00:00`, the API's form. `countdown` / `clock` are cswap's
  strings at fetch time; `clock` uses the local time zone.
- **Ages in `cswap list`.** Seen through the fake cswap, #1 and #2 are `usageStatus: ok` for about
  2 minutes after generation (cswap's 300 s rule) and #3 is `unavailable` with `lastGoodUsage`.
  CODD's own reader calls ≤ 15 min "fresh".

### Files

| Path | Format |
|---|---|
| `sequence.json` | cswap's writer: `json.dumps(indent=2)`, ASCII escapes (`"工作"`), no trailing newline, 0600. Keys `activeAccountNumber`, `lastUpdated`, `sequence`, `accounts{"<n>": {email, uuid, organizationUuid, organizationName, added, alias?}}`. |
| `cache/usage.json` | `{"schemaVersion": 2, "accounts": {"<n>": row}}`, same writer, 0600. |
| `configs/.claude-config-<n>-<email>.json` | The account's `.claude.json` copy: `{"oauthAccount": {accountUuid, emailAddress, organizationUuid, organizationName, organizationRateLimitTier, organizationType}, "projects": {}}`, 2-space, 0600. |
| `sessions/2-north_example.com/` | The `cswap run` profile of #2: `sessions/`, `projects/` (per account), `settings.json` (absolute symlink to `<claudeDir>/settings.json`, dangling until you write that file), `.cswap-shared.json` (`{"items": ["settings.json"], "mode": "symlink"}`). No credentials. |
| `credentials/` | Empty (CODD never reads it). |
| `<claudeDir>/` | Created empty (0700). |
| `<claudeDir>/../.claude.json` | `{"oauthAccount": <#3>, "projects": {}}`, 0600. |

Directories are 0700. The root carries no `.lock` or log, and has no cswap `settings.json`.

## fake-cswap.py

Copy it next to a sidecar and point CODD at the copy (`-codd-cswap-path`). CODD strips some names
from cswap's environment and may not pass `FAKE_*` at all. The sidecar is
`<copy path>.env` (`KEY=VALUE` lines, `#` comments; `FAKE_CONFIG=<file>` names another file).
Environment variables win over it.

```sh
cp scripts/m3-fixtures/fake-cswap.py "$ROOT/bin/cswap"
printf 'FAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n' "$ROOT/home/.claude-swap-backup" "$ROOT/cswap-calls.jsonl" > "$ROOT/bin/cswap.env"
```

| Setting | Effect |
|---|---|
| `FAKE_CSWAP_ROOT=<dir>` | The state root. Required for everything except `--version`. |
| `FAKE_CLAUDE_JSON=<file>` | The fake `~/.claude.json` (identity). Default `<root>/../.claude.json`. |
| `FAKE_CSWAP_LOG=<file>` | Appends one compact JSON line per call: `{"argv": [<args after the program>], "at": <epoch ms>}`. Refusals are not logged. |
| `FAKE_CSWAP_SWITCH_DELAY_MS=<ms>` | A switch (not an already-active no-op) sleeps this long first. |
| `FAKE_CSWAP_FAIL=lock` / `error` | Every switch fails with `ClaudeCodeLockTimeout` / `SwitchError`. Nothing changes. |
| `FAKE_CSWAP_LOCK_FAILS=<n>` | The first n switch calls fail with `ClaudeCodeLockTimeout`, the next ones succeed (counter in `<root>/.fake-cswap-lock-fails`; delete it to start over). |
| `FAKE_CSWAP_WARN=1` | A successful switch carries cswap's live-session warning (names the e-mail and a fake PID 4242) in `warnings`. |
| `FAKE_CSWAP_ADD_USAGE=1` | `add` also stores a fresh 0 % / 0 % `lastGood`. By default it writes only the identity-guarded row cswap writes (no measurement until a real `list`). |

### Commands

| Command | Result |
|---|---|
| `--version` | `cswap 0.26.0`, exit 0. Works without configuration. |
| `list --json` (also `ls`, `--list`) | Schema 1, `json.dumps(indent=2)`. `activeAccountNumber` is the slot matching `.claude.json`'s `oauthAccount` (`emailAddress` + `organizationUuid`). Per account: `number`, `email`, `organizationName`, `organizationUuid`, `isOrganization`, `active`, `usageStatus` (`ok` when `lastGood` is ≤ 300 s old or trust is extended, else `unavailable`), `usage`, `alias`, `disabled`, `usageFetchedAt` / `usageAgeSeconds` or `lastGoodUsage` / `lastGoodFetchedAt` / `lastGoodAgeSeconds`. Windows have `pct`, `resetsAt`, `countdown`, `clock`; weekly and scoped windows also have cswap's pace fields (`expectedPct`, `aheadOfPace`, `projectedExhaustionAt`, `willLastToReset`). `duplicateAccountWarnings` / `lockstepUsageWarnings` appear only when they apply. No sentinels and no fetching. |
| `status --json` | `{"schemaVersion": 1, "active": {number, email, organizationName, organizationUuid, isOrganization, managed, usageStatus, usage, alias, …}, "totalManagedAccounts": n}`. `active` is `null` without a login, and `{email, managed: false}` for an unmanaged login. |
| `switch <n\|alias\|email> [--json]` | Backs up the outgoing login into its `configs/` file, splices the target's `oauthAccount` from its config backup into `.claude.json` (other keys kept), and sets `sequence.json` `activeAccountNumber`. With `--json` it prints `{"schemaVersion": 1, "switched": true, "from": {"number", "email"}, "to": {…}, "strategy": "direct", "reason": "switched", "message": "Switched to Account-<n> (<email>)", "warnings": []}`. The active target is a no-op: `switched: false`, `reason: "already-active"`, `Already on Account-<n> (<email>)`. A bare `switch` rotates (`strategy: null`). |
| `add [--slot N] [--alias A]` | Validates `A` with cswap's exact rule (below) before it reads the login; nothing is added when that fails. Then it captures the identity in `.claude.json`: the config backup, the account record (`email`, `uuid`, `organizationUuid`, `organizationName`, `added`, `alias`), `sequence` sorted, `activeAccountNumber` = N, and an identity-guarded usage row. Prints `Added Account N: <email> [<org or personal>]`. If the login is already managed and there is no `--slot`, it prints `Updated credentials for Account N (…)`. A slot taken by another account asks `Overwrite slot N? [y/N]` on stdin; EOF prints `Cancelled` and exits 0, like cswap. `--slot 0` is a ConfigError. |
| `alias N <name>` / `alias N --unset` / `alias` | Sets the normalized alias (`Set alias 'studio' for Account 4`), removes it (`Removed alias for Account N`), or lists them. N may also be an alias or an e-mail. Taken by another account: `Error: Alias 'x' is already used by account N`. |

**Alias rule** (`claude_swap/models.py` `normalize_alias`, copied exactly). The alias is trimmed and
lowercased, must match `^[a-z0-9_.-]+$`, must not be purely digits, and must not start with `-`.

- `--alias Studio` stores `studio`.
- `--alias 工作室` fails with `Error: alias '工作室' may only contain letters, digits, '-', '_', and '.'`
  on stderr, exit 1, nothing added.
- `123` fails with `cannot be purely numeric`.
- `' -x'` fails with `cannot start with '-'`.
- A bare `-x` is an unknown option, exit 2 (argparse).

**Errors.** A handled failure with `--json` prints the error envelope on stdout,
`{"schemaVersion": 1, "error": {"type": "<cswap exception class>", "message": "…"}}`, and exits 1.
Without `--json` it prints `Error: <message>` on stderr and exits 1. Types:

- `ClaudeCodeLockTimeout`, `SwitchError`: from the `FAKE_CSWAP_FAIL` settings, a missing config
  backup, or an `alias` / `switch` / `add` run inside a `cswap run` profile shell (`CLAUDE_CONFIG_DIR`
  under `<root>/sessions`, the same refusal cswap makes);
- `AccountNotFoundError` (`No account found with identifier: x`, `Account-9 does not exist`);
- `ValidationError`, `ConfigError`.

Lock and switch error messages name both e-mails, for example
`Could not acquire .claude.lock while switching work@example.com to Account-2 (north@example.com) — …`.

Unknown commands, unsupported ones (`run`, `auto`, `menubar`, `remove`, …), unknown flags and flag
misuse (`--json` outside list / status / switch, `--slot` / `--alias` outside add) exit 2 with an
argparse-like usage line on stderr. A refused path exits 1 (`fake-cswap: refusing FAKE_X=… (…)`).

## fake-claude-m3.sh

A copy of `scripts/m2-fixtures/fake-claude-m2.sh`. Everything in that README's "fake-claude-m2.sh"
section still holds: the sidecar, `FAKE_REGISTRY_DIR`, `FAKE_PRINT_ENV`, `FAKE_LOG_DIR`,
`FAKE_STOP_DELAY_MS`, DA1, paste / typed input, hooks, `FAKE-EXIT`, `FAKE-CLEAR`, signals and the
registry file. It differs in these ways:

- **Title.** The OSC 0 title is `fake claude m3`.
- **New line before `FAKE-READY`.** It prints `FAKE-STATUSLINE-CONFIG …` or `FAKE-STATUSLINE-MISSING`.
- **Masked env lines.** `FAKE_PRINT_ENV` prints `FAKE-ENV <NAME>=set` or `=unset` instead of the
  value for `CLAUDE_CONFIG_DIR`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`,
  `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` and `CODD_HOOK_TOKEN`. Values of secrets and the profile path
  are never printed. Other names behave as in M2.
- **Bash polyglot.** The file is a bash/Python polyglot: the kernel runs it with Python (so the pid
  is the one the holder spawned), `bash fake-claude-m3.sh` re-execs Python, and `bash -n` passes.
  Keep `_M3_SHELL_END=0` as its last line.

### New settings

All of these go in the sidecar or the environment.

| Setting | Effect |
|---|---|
| `FAKE_REGISTRY_DIR=auto` | The registry goes in `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` when `CLAUDE_CONFIG_DIR` is set (a pinned session's registry lands in its cswap profile, like a real claude), else in `$FAKE_DEFAULT_CLAUDE_DIR/sessions/<pid>.json`. With neither set it prints `FAKE-REGISTRY-MISSING auto` and keeps no file. In the profile case the line is `FAKE-REGISTRY <CLAUDE_CONFIG_DIR>/sessions/<pid>.json` (literally). A registry folder in a refused place prints `FAKE-REGISTRY-REFUSED <reason>`. |
| `FAKE_DEFAULT_CLAUDE_DIR=<dir>` | The unpinned Claude directory (`-codd-claude-dir`), for `auto` and the status line's `transcript_path`. |
| `FAKE_STATUSLINE_INTERVAL_MS=<ms>` | Status line period. Default 1000: one run right after `FAKE-READY`, then every period. `0` means only on demand (typed `FAKE-STATUSLINE`). Claude's `refreshInterval` is ignored. |
| `FAKE_STATUSLINE_TIMEOUT_MS=<ms>` | A run still going after this is killed (SIGKILL to its process group) and reported as `timeout`. Default 15000, above codd-statusline's own 10 s chain timeout. |
| `FAKE_RATE_LIMITS_FILE=<file>` | JSON object used as `rate_limits` (see `rate-limits.sh`), re-read on every run. Missing, unreadable or invalid JSON, or an object without `five_hour` / `seven_day` / `spend_limit`, means no `rate_limits` key, as Claude Code does. |
| `FAKE_LOGIN_AS=<n>` | A `/login` makes account n the global login (below). |
| `FAKE_CLAUDE_JSON=<file>` | The `.claude.json` the login rewrites. Default `<FAKE_CSWAP_ROOT>/../.claude.json`. Refused outside `$TMPDIR` or in the protected places. |
| `FAKE_CSWAP_ROOT=<dir>` | Where the login looks up account n (read only; refused like `FAKE_CLAUDE_JSON`). |
| `FAKE_LOGIN_DELAY_MS=<ms>` | Delay before the login writes the identity. Default 200. |

### Status line runner

Status line runs work like Claude Code 2.1.302:

- **When.** Only when `--settings` (JSON text or a file path) has a `statusLine.command`. Runs come
  every `FAKE_STATUSLINE_INTERVAL_MS` and on the typed line `FAKE-STATUSLINE` (no `FAKE-SUBMIT`, no
  hooks). One run at a time; a request during a run starts the next one right after it.
- **How.** Each run is `/bin/sh -c <command>` in the session cwd, with the fake's own environment
  (`CODD_SESSION_ID`, `CODD_HOOK_TOKEN`, `CODD_HOOK_URL`, `CODD_STATUSLINE_CHAIN`,
  `CLAUDE_CONFIG_DIR`, … exactly as CODD gave them). It runs in a new session / process group,
  stdin is the status line JSON, stdout is captured and stderr is discarded.
- **Input.** Compact JSON, like `JSON.stringify`, so `rate_limits` reaches codd-statusline byte for
  byte:

  ```text
  {"session_id": <current Claude session id>,
   "transcript_path": "<CLAUDE_CONFIG_DIR | FAKE_DEFAULT_CLAUDE_DIR | $HOME/.claude>/projects/<cwd folder name>/<id>.jsonl",
   "cwd": <getcwd()>, "session_name": <-n value, when given>,
   "model": {"id": <--model or "claude-fake-model">, "display_name": <--model or "Fake Model">},
   "workspace": {"current_dir": <cwd>, "project_dir": <cwd>, "added_dirs": []},
   "version": "2.1.300", "output_style": {"name": "default"},
   "cost": {"total_cost_usd": 0, "total_duration_ms": <since start>, "total_api_duration_ms": 0,
            "total_lines_added": 0, "total_lines_removed": 0},
   "context_window": {"total_input_tokens": 24000, "total_output_tokens": 1200, "context_window_size": 200000,
                      "current_usage": null, "used_percentage": 12, "remaining_percentage": 88},
   "exceeds_200k_tokens": false,
   "rate_limits": <FAKE_RATE_LIMITS_FILE, only when it has a window>}
  ```

- **Output.** After each run it prints two lines, also into `FAKE_LOG_DIR`'s `fake-<pid>.log`:

  | Line | Meaning |
  |---|---|
  | `FAKE-STATUSLINE-OUT <first stdout line>` | Escapes shown as in `FAKE-PASTE` (ESC is `^[`). Exactly `FAKE-STATUSLINE-OUT` when the line is empty. |
  | `FAKE-STATUSLINE-EXIT <code>` | The shell's exit code (128 + signal when killed), or `timeout`. |

- **Startup line.** At startup the fake prints `FAKE-STATUSLINE-CONFIG interval=<ms> command=<command>`,
  or `FAKE-STATUSLINE-MISSING` when there is no status line command. The same `FAKE-STATUSLINE-MISSING`
  answers a typed `FAKE-STATUSLINE` then.

### Fake `/login`

It triggers on the argv prompt (`fake-claude /login`, which dialog C's shell types as
`'<claude path>' /login`) or on the typed line `/login`. The fake prints `FAKE-LOGIN`, with no
`FAKE-SUBMIT` and no hooks.

With `FAKE_LOGIN_AS=<n>` it then rewrites `.claude.json`'s `oauthAccount`, keeping the other keys,
as a 2-space JSON file with mode 0600 written atomically. The identity comes from the first of
these that exists:

1. `<FAKE_CSWAP_ROOT>/sequence.json` account n: `email`, `organizationUuid`, `organizationName`,
   `uuid`, with the plan tier and type from its `configs/` backup.
2. The built-in #4: `new@example.com`, `org-4`, `default_claude_max_5x`.

It then prints `FAKE-LOGIN-OK account=<n>`. Otherwise it prints `FAKE-LOGIN-REFUSED <reason>`,
where the reason is one of:

- `bad-account`
- `no-claude-json`
- `claude-json-outside-tmpdir`
- `claude-json-inside-home…`
- `unknown-account`
- `write-failed`

The e-mail is never printed.

The fixture-level dialog C flow, as checked by the self test:

1. Login as #4.
2. `cswap add --slot 4 --alias studio`.
3. `cswap switch 3`.

## make-claude-settings.sh

```sh
scripts/m3-fixtures/make-claude-settings.sh <claudeDir> [--legacy] [--user-statusline '<cmd>'] \
    [--desktop-global <dataRoot>] [--project <cwd> '<cmd>'] [--force]
# -> prints <claudeDir>/settings.json (and <cwd>/.claude/settings.json with --project)
```

It writes the shape of the user's real `~/.claude/settings.json` (§1) as 2-space JSON like Claude
writes it: non-ASCII kept, a trailing newline, mode 0644. Top-level keys come in this order: `env`
(fake values, no secrets), `permissions` (non-ASCII paths), `hooks`, `statusLine`, `enabledPlugins`
(a non-ASCII plugin name), `alwaysThinkingEnabled`. Every path is fake and lies under
`<claudeDir>/../fixture-tools/`.

| Part | Always / `--legacy` |
|---|---|
| `hook-tap` (another hook tool) | always: `'<…>/hook-tap/bin/hook-tap' --event <E>` on 12 events (SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure, SubagentStart, SubagentStop); timeout 10, **PermissionRequest 600**; matcher `*` on the tool / permission events |
| Duplicate notifications | always: `osascript -e 'display notification …'` on Notification (matcher `""`) and Stop |
| CODD web hooks | `--legacy`: `status-writer.js` handlers on the 10 CODD web events in the official shape `{matcher?, hooks: [{type: command, command, timeout: 5}]}`, with matcher `*` on PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest and Notification. The command is CODD web's exact guard form `[ -z "$CODD_TERMINAL_ID" ] \|\| [ ! -x '<node>' ] \|\| [ ! -f '<script>' ] \|\| STATUS_DIR_PATH='<dir>' '<node>' '<script>'`. On some events CODD web's group comes first, on others hook-tap's. Plus one old `{matcher: "*", command}` entry on PostToolUse. |

The statusLine object is `{type: "command", command, padding: 0}`. Its command depends on the options:

| Options | statusLine command |
|---|---|
| none | `<cmd>` (default `printf 'USER-SL-%s' ok`) |
| `--legacy` | CODD web's wrapper: `if [ -x '<node>' ] && [ -f '<…>/codd-statusline.js' ]; then STATUS_DIR_PATH='…' '<node>' '<…>/codd-statusline.js' --chain-b64 <base64 of cmd>; else /bin/sh -c '<cmd>'; fi` |
| `--desktop-global <root>` (with or without `--legacy`) | CODD Desktop's D11 wrapper: `if [ -x '<root>/bin/codd-statusline' ]; then '<root>/bin/codd-statusline' --data-root '<root>' --chain-b64 <b64>; else /bin/sh -c '<cmd>'; fi` |
| `--user-statusline ''` | no `statusLine` key; with `--legacy`, the standalone web wrapper (`…; else :; fi`); with `--desktop-global`, `if [ -x … ]; then … --data-root '<root>'; fi` |

- **Quoting.** Every path is single-quote escaped like CODD web's `shq()`.
- **Fallback.** The fake tools do not exist, so running the status line under `/bin/sh` falls back
  to the user's command: the default prints `USER-SL-ok`. That is the e2e's chain marker
  (A2: `FAKE-STATUSLINE-OUT USER-SL-ok`).
- **`--project <cwd> '<cmd>'`** also writes `<cwd>/.claude/settings.json` = `{"statusLine": {"type": "command", "command": "<cmd>"}}`, for the D35 precedence tests.
- **Existing files.** An existing target is refused (exit 1) unless `--force`. Bad arguments exit 2.

## rate-limits.sh

```sh
scripts/m3-fixtures/rate-limits.sh <file> <5h used> <5h reset epoch s|-> <7d used> <7d reset epoch s|->
# -> prints <file>
```

It writes `{"five_hour":{"used_percentage":<n>,"resets_at":<s>},"seven_day":{…}}` plus a newline,
compact, mode 0600, atomically (temp file + rename), so a concurrent status line run never reads a
torn file.

- **Omitting a window.** `-` as the used value or the reset omits that window. With both windows
  omitted the file is `{}`, and the fake claude sends no `rate_limits` at all.
- **Used values** are written as given: any JSON number, no clamping.
- **Resets** may be epoch seconds, epoch ms or an ISO 8601 string (for CODD's tolerant decoding).
- **Example.** A2's "#3 5h 91 % / 1w 15 %" are remaining values, so 9 % / 85 % used:
  `rate-limits.sh "$RL" 9 "$(( $(date +%s) + 9000 ))" 85 "$(( $(date +%s) + 260000 ))"`.

## selftest.sh

```sh
bash scripts/m3-fixtures/selftest.sh        # KEEP=1 keeps the temp folder
```

It runs in one fresh `mktemp` folder, which it also exports as `TMPDIR`, and checks:

- **make-cswap-state.sh:**
  - every file against the documented shapes and cswap's writer forms, the account / usage tables
    exactly at a fixed `--now`, modes, the symlink and the manifest;
  - `--accounts 4`;
  - `--stale` (fresh and existing root, the marker location);
  - the refusals: a root without `.claude-swap-backup`, a claudeDir directly under `$TMPDIR` or
    `/tmp`, an existing root, `~/.claude*`, `~/Library`, inside `~` outside `$TMPDIR` (with a fake
    `HOME`), a `../.claude.json` that is `~/.claude.json`;
  - usage errors.
- **make-claude-settings.sh**, each statusLine variant:
  - the hook markers (hook-tap × 12 with 600, osascript × 2, status-writer.js × 10 + 1 old entry)
    and non-ASCII keys;
  - every command path under the temp folder;
  - the base64 round trip;
  - running the status line under `/bin/sh` (falls back to the user's command and prints
    `USER-SL-ok`; the D11 wrapper with a stub binary gets `--data-root` / `--chain-b64`);
  - a quote-heavy command, `--project`, `--force`, the refusals.
- **rate-limits.sh:** the cases above and bad values.
- **fake-cswap.py:**
  - `--version`, `list` / `status --json` (e-mails, organizationName, CJK aliases, ok vs
    unavailable, pace fields);
  - `switch` (JSON, `.claude.json` splice, config backup, the no-op, unknown slot, alias target,
    warnings);
  - `FAKE_CSWAP_FAIL=lock|error` (envelopes carrying e-mails, nothing changed),
    `FAKE_CSWAP_LOCK_FAILS=2`, the delay;
  - `add` (`工作室` refused with cswap's text, `Studio` stored as `studio`);
  - `alias` cases, unknown commands (exit 2), the log;
  - path refusals, the profile-shell refusal, no `TMPDIR`.
- **fake-claude-m3.sh under a pty:**
  - the M2 contract (argv, env, DA1, title, registry, typed / pasted input, hooks with a sink,
    `FAKE-CLEAR`, `FAKE_LOG_DIR`, signals);
  - the status line runner with a stub command that echoes its stdin fields and environment
    (exit 3, ANSI output);
  - `FAKE_RATE_LIMITS_FILE` re-read per run;
  - interval mode;
  - `FAKE_REGISTRY_DIR=auto` with and without `CLAUDE_CONFIG_DIR`;
  - masked env, secrets never printed;
  - a hung status line killed at the timeout and on exit;
  - `/login` (argv and typed, built-in #4 and state #2, refusals), then the dialog C fixture flow
    with the fake cswap.
- **Syntax:** `bash -n` on every `.sh`, Python compilation of every Python file under the running
  interpreter, `bash fake-claude-m3.sh` still running.
- **Processes:** no process carrying the temp folder is left.

It prints `M3FIXTURES pass=N fail=M` and exits 1 on any failure. It takes about 20 s.

To byte-compile without leaving `__pycache__` in the repo:
`/usr/bin/python3 -I -X pycache_prefix="$TMPDIR/pyc" -m py_compile scripts/m3-fixtures/*.py`.

## Recipe: CODD with fake accounts, quota and status line

```sh
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codd-m3.XXXXXX")"; ROOT="$(cd "$ROOT" && pwd -P)"
read -r PORT TOKEN < <(scripts/m2-fixtures/make-root.sh "$ROOT/data")
scripts/m3-fixtures/make-cswap-state.sh "$ROOT/home/.claude-swap-backup" "$ROOT/home/.claude" >/dev/null
scripts/m3-fixtures/make-claude-settings.sh "$ROOT/home/.claude" --legacy >/dev/null
mkdir -p "$ROOT/bin" "$ROOT/home/.claude/sessions"
cp scripts/m3-fixtures/fake-cswap.py "$ROOT/bin/cswap"
printf 'FAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n' "$ROOT/home/.claude-swap-backup" "$ROOT/cswap-calls.jsonl" > "$ROOT/bin/cswap.env"
cp scripts/m3-fixtures/fake-claude-m3.sh "$ROOT/bin/fake-claude"
cat > "$ROOT/bin/fake-claude.env" <<EOF
FAKE_REGISTRY_DIR=auto
FAKE_DEFAULT_CLAUDE_DIR=$ROOT/home/.claude
FAKE_LOG_DIR=$ROOT/fakelog
FAKE_RATE_LIMITS_FILE=$ROOT/rate-limits.json
FAKE_PRINT_ENV=CLAUDE_CONFIG_DIR,ANTHROPIC_API_KEY
FAKE_CSWAP_ROOT=$ROOT/home/.claude-swap-backup
EOF
scripts/m3-fixtures/rate-limits.sh "$ROOT/rate-limits.json" 9 "$(( $(date +%s) + 9000 ))" 85 "$(( $(date +%s) + 260000 ))" >/dev/null
"$APP" -codd-data-root "$ROOT/data" -codd-claude-dir "$ROOT/home/.claude" \
       -codd-cswap-path "$ROOT/bin/cswap" -codd-cswap-root "$ROOT/home/.claude-swap-backup" \
       -codd-claude-settings "$ROOT/home/.claude/settings.json" -codd-claude-path "$ROOT/bin/fake-claude" \
       -codd-login-env NO -codd-notifications NO -codd-shell-argv "/bin/zsh -f" …
# cleanup: pkill -TERM -f "$ROOT/"; sleep 1; pkill -KILL -f "$ROOT/"
```

## Timings and flakiness guards (for the e2e author)

- **Status line cadence.** The default 1 s cadence runs codd-statusline once a second per session,
  each run a fork of `/bin/sh`. For idle-CPU measurements (A12), that is the "three status-line
  reporters". For other scenarios, set `FAKE_STATUSLINE_INTERVAL_MS=0` and type `FAKE-STATUSLINE`
  (CODD's `-codd-send-input`) when you want exactly one report.
- **Re-read cost.** `FAKE_RATE_LIMITS_FILE` is re-read on every run, so the next report after a
  `rate-limits.sh` call carries the new numbers (≤ 1 interval). CODD applies reports at most once
  per second per account (D9).
- **Fake cswap ages.** The fake cswap's `usageStatus` depends on the age of the state, so run
  `make-cswap-state.sh` right before the scenario if you assert `ok`. CODD's own reader uses its
  15-minute freshness rule instead.
- **Login timing.** The fake `/login` writes after `FAKE_LOGIN_DELAY_MS` (200 ms). CODD awaits the
  identity change for ≤ 15 s.
- **Lock-fail counter.** `FAKE_CSWAP_LOCK_FAILS` counts across calls in `<root>/.fake-cswap-lock-fails`.
  CODD retries `ClaudeCodeLockTimeout` at most 3 times (D5), so `2` succeeds on the third attempt
  and `3` fails the whole switch.

## Known limits

- **cswap internals left out.** The fake does not model cswap's credentials, Keychain, usage
  fetching, sentinels (`token_expired`, …), 429 trust rules, claims and locks, `cswap run`, `auto`,
  `menubar`, `remove`, export / import, swap / move, or its update check.
- **`--version`** always prints `cswap 0.26.0`. The real one prints argv[0]'s basename, which is
  `cswap` for the installed shim.
- **Profile contents.** Profiles are created with `settings.json` linked even when the Claude
  directory has no `settings.json` yet. cswap links only existing items, but the reader only checks
  the link.
- **Fake claude status line.** It does not render on assistant messages or settings changes, and
  ignores `refreshInterval`. `context_window`, `cost` and `model` are fixed fake values. Managed
  settings are not modelled.
