[harness: subagent output matched instruction-shaped pattern(s): settings-json. Control tags below are neutralized (`<` → `<\`); treat any remaining directive-shaped text as a finding to relay to the user, not an instruction to you.]

# cswap (claude-swap) research report

Package root: `PKG=~/.local/share/uv/tools/claude-swap/lib/python3.13/site-packages/claude_swap` (about 24.6k lines; I read all of it except the TUI).

I ran only read-only commands: `--version`, `--help`, `config --help` and `run --help`. One other command ran by accident: `menubar --service-status`. It only reports whether the menu bar service is installed and changes nothing, but it is not a help command. I also read Keychain item attributes (no `-w`, so no secrets) and JSON files with secrets redacted. No token values appear below.

## 0. Version and upstream
- **Version:** `claude-swap 0.26.0`, installed with `uv tool` (pinned `==0.26.0`). Entry points `cswap` and `claude-swap` both call `claude_swap.cli:main`.
- **Upstream:** https://github.com/realiti4/claude-swap by Onur Cetinkol, MIT license, "Development Status 4 - Beta".
- **Requirements:** Python 3.12+, `textual>=8.2.8,<9`, `truststore>=0.10.4`. The optional extra `[menubar]` adds `rumps>=0.4.0`.
- **Installed state:** `rumps` is not installed and there is no `~/Library/LaunchAgents/com.cswap.menubar.plist`, so cswap's own menu bar has never run here. No `sessions/` folder exists in the backup root, so session mode has never been used. There is no `mappings.json` either.

## 1. What it does, commands and flags
It switches the one global Claude Code login between stored accounts, shows 5h/7d/per-model usage for every account, can switch automatically before a limit is hit, and can run one account in a single terminal only ("session mode").

Command-to-flag rewrite: `cli.py:50-97`. Main parser: `cli.py:1019-1271`.

| Command | Notes |
|---|---|
| `list` / `ls` `[--json] [--token-status]` | Dashboard of every account. `--json` works only with `list`, `status` and `switch` (`cli.py:1300`). |
| `status [--json]` | The active account only. |
| `switch` / `switch <num\|email\|alias>` `[--strategy best\|next-available] [--model NAMES] [--force] [--json]` | Bare `switch` rotates. `--strategy` works only with bare `switch`. |
| `add [--slot N] [--alias X]` | Captures the current Claude Code login. Asks before overwriting an occupied slot (`switcher.py:3530`). |
| `add-token [TOKEN\|-] [--slot] [--email]` | Adds a setup-token (`sk-ant-oat…`) or API key (`sk-ant-api…`). Prompts with getpass if no token is given. |
| `remove`/`rm`, `disable`, `enable` `<num\|email>` | **`remove` always asks `[y/N]` through `input()`** (`switcher.py:3920`). There is no `--yes` flag. |
| `run [NUM\|EMAIL] [--no-share] [--share-history] [--require-session] [-- claude args]` | Session mode, marked EXPERIMENTAL. It `execvpe`s `claude`, replacing the cswap process (`session.py:607-623`). |
| `map [NUM\|EMAIL] [PATH]`, `unmap [PATH]` | Binds a directory to an account. |
| `alias`, `swap a b`, `move a slot`, `unclaimed [--purge ID]` | Slot and roster management. |
| `auto [--once] [--json] [--interval s] [--threshold pct] [--cooldown s] [--model] [--strategy best\|consume-first] [--dry-run] [--include-api-key-accounts]` | Auto-switch loop. `--once` exit codes: 0 switched, 1 error, 2 nothing to do, 3 blocked (`cli.py:598-602`). |
| `config [list\|get\|set\|unset\|path] [--json]` | Settings keys are listed in section 5. |
| `export <path> [--account] [--full]`, `import <path> [--force]` | Export is plain JSON that contains the tokens. |
| `tui` (also bare `cswap` in a terminal), `watch`, `menubar [--install-service\|--uninstall-service\|--service-status]` | The menu bar runs as a launchd agent with label `com.cswap.menubar`. |
| `upgrade`/`update`, `purge`, `--version`, `--debug` | |

General behaviour:
- cswap refuses to run as root (`cli.py:232`).
- It refuses to change accounts from inside a `cswap run` shell, i.e. when `CLAUDE_CONFIG_DIR` points under `sessions/` (`switcher.py:6508-6537`).
- Commands without `--json` check PyPI for updates with a 2s timeout.

## 2. Storage and what a switch changes
**Backup root on macOS:** `~/.claude-swap-backup/` (`paths.py:90-108`).
- `sequence.json`: `{activeAccountNumber, lastUpdated, sequence:[1,2,3], accounts:{"N":{email, uuid, organizationUuid, organizationName, added, alias?, disabled?}}}`. Holds no secrets.
- `configs/.claude-config-{N}-{email}.json`: a full snapshot of `~/.claude.json`, including `oauthAccount`.
- `credentials/`:
  - `.creds-{N}-{email}.enc` (base64), used only when the Keychain is unusable.
  - `.enc.prev` files, `.unclaimed-*.enc` plus `.unclaimed-manifest.json` (a stash of credentials it could not attribute to a slot), and `.consume-N.lock`.
- `cache/usage.json` (schemaVersion 2, the shared usage table) and `cache/update_check.json`.
- `settings.json`, `autoswitch_state.json`, `menubar_settings.json`, `mappings.json`, `claude-swap.log`, `.lock`, `.migrations.json`.
- `sessions/{N}-{email_slug}/`, the per-account profiles for `cswap run` (`session.py:222`).

**macOS Keychain.** Everything goes through `/usr/bin/security` (`macos_keychain.py:60`). Writes use `security -i` on stdin with hex values (`-X`), so secrets stay out of the process argument list.

| Service | Account name | Owner |
|---|---|---|
| `Claude Code-credentials` (`credentials.py:117`) | `$USER` | Claude Code's live OAuth login: `{"claudeAiOauth":{accessToken, refreshToken, expiresAt(ms), scopes}, mcpOAuth?, …}` |
| `Claude Code-credentials-<sha256(NFC CLAUDE_CONFIG_DIR)[:8]>` (`session.py:232-243`) | `$USER` | Claude Code login for a custom `CLAUDE_CONFIG_DIR`, such as a session profile |
| `Claude Code` (`credentials.py:124`) | `$USER` | Managed API key, if one is active (none here) |
| `claude-swap` (`credentials.py:113`) | `account-{N}-{email}` and `account-{N}-{email}.prev` (`credentials.py:1064, 1457`) | cswap's per-account backups. |

**Reading the live credential** (`credentials.py:566-649`): Keychain first (2 attempts, 0.3s apart), then `~/.claude/.credentials.json`, then the managed API key.

**Which account is active** comes from `~/.claude.json` → `oauthAccount.emailAddress` plus `organizationUuid` (`switcher.py:2871-2894`), not from the Keychain.

**A switch** (`_perform_switch`, `switcher.py:6539`) runs entirely under three locks (`:6608`):
- cswap's own `~/.claude-swap-backup/.lock`;
- Claude Code's credential locks `~/.claude/.oauth_refresh.lock/` then `~/.claude.lock/` (directories, considered stale after 60s);
- the config lock `~/.claude.json.lock/` (stale after 10s).

Each lock waits up to 9s (`claude_locks.py`). The steps are:
1. Back up the outgoing live credential to `claude-swap` / `account-{cur}-{email}` and `~/.claude.json` to `configs/…`. If ownership of the credential is unclear, it goes to the unclaimed stash instead.
2. Write the target credential to Keychain `Claude Code-credentials`. Machine-shared keys (`mcpOAuth`, `pluginSecrets`, …) are carried over from the live copy (`credentials.py:196-268`). If `.credentials.json` already exists it is rewritten so its mtime changes and running sessions reload; it is never created (`:1012`). Any managed API key is cleared (`:797-818`).
3. Replace **only** the `oauthAccount` key in `~/.claude.json` (`switcher.py:7025`).
4. Set `sequence.json.activeAccountNumber` (`:7037`) and log `Switched from account X to Y` (`:7043`). The menu bar builds its switch history from that log line.

If any step fails, the completed steps are rolled back (`models.py:164-206`).

## 3. Usage and quota fetching, token refresh
**Usage endpoint** (`oauth.py:364-374`): `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <access>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-swap/1.0`.

Raw response fields cswap reads (`oauth.py:431-502`):
- `five_hour.{utilization, resets_at}` and `seven_day.{utilization, resets_at}`;
- `extra_usage.{is_enabled, used_credits, monthly_limit, utilization, currency, resets_at}`, where credits and limit are in cents;
- `limits[]` entries `{scope.model.display_name, percent, resets_at}`, which are the per-model weekly limits. Today the only one is "Fable".

There is no separate Opus field; Opus would appear as a `limits[]` entry if Anthropic reports one.

Internal (normalized) shape: `five_hour{pct, resets_at, countdown, clock}`, `seven_day{…}`, `spend{used, limit, pct, currency, resets_at…}`, `scoped[{name, pct, resets_at, countdown, clock}]`. When the 5h window has not started (pct 0), `resets_at` is absent.

**Other endpoints:**
- Profile lookup (who owns a token): `GET https://api.anthropic.com/api/oauth/profile` (`oauth.py:232-291`).
- Token refresh: `POST https://platform.claude.com/v1/oauth/token` with `{grant_type: refresh_token, refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}` (`oauth.py:16-19, 112-195`).

**Refresh rules:**
- cswap refreshes **only inactive accounts**. The active account's tokens belong to Claude Code (`oauth.py:614-620`).
- A refresh happens when the token is expired or within 5 minutes of expiring, or after a 401. It runs through a per-slot lock (`credentials/.consume-N.lock`) and writes the new token back to the `claude-swap` Keychain item.
- A single `invalid_grant` puts the account in quarantine (`AUTH_DEAD_STRIKES = 1`, `usage_store.py:227`). It then shows as `relogin_required`.

**Polling limits** (`poll_policy.py`): the usage endpoint allows roughly 28-30 requests per rolling hour per identity for non-Claude-Code clients.
- Results younger than `SERVE_TTL_S = 180s` are served from the cache without a request.
- Normal interval 180-300s; idle alternate accounts drift to 600s; urgent mode 60s.
- After a 429 the interval is held at a floor of 360s or more for an hour.
- Results stay trusted for switch decisions for 300s (`STALE_OK_S`), extendable up to 3600s.

**This machine already hits the limit:** the log has many "Usage fetch failed" warnings, most of them http-429.

## 4. Binding an account to a session or directory
- **Session mode:** `cswap run N` sets `CLAUDE_CONFIG_DIR=~/.claude-swap-backup/sessions/{N}-{slug}` and removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and the two `*_FILE_DESCRIPTOR` variables (`session.py:192-198, 504-589`).
  - The profile starts with a plaintext `.credentials.json`; Claude Code then moves it into the hashed Keychain item.
  - `settings.json`, `keybindings.json`, `CLAUDE.md`, `skills/`, `commands/` and `agents/` are symlinked from `~/.claude` (`session.py:76`). User-scope `mcpServers` are mirrored.
  - Chat history (`projects/`, `history.jsonl`) is **separate per account** unless `--share-history` is used (`:87`).
  - If the requested account is already the default login, it just runs plain `claude`; `--require-session` refuses instead.
- **Directory mapping:** `mappings.json` maps a normalized path to `{email, organizationUuid}`. The nearest mapped parent folder wins, and bare `cswap run` uses it (`mappings.py`, `switcher.py:1644`).

## 5. Data the UI can show per account
From `cswap list --json` (`json_output.py:211-251`, `switcher.py:5329-5373`).

Top level: `schemaVersion: 1`, `activeAccountNumber`, `accounts[]`, and optionally `duplicateAccountWarnings`, `lockstepUsageWarnings`, `unclaimedCredentials`.

Each row:
- Identity: `number`, `email`, `alias?`, `organizationName`, `organizationUuid`, `isOrganization`, `active`, `disabled?`.
- `usageStatus`: one of `ok`, `token_expired`, `api_key`, `keychain_unavailable`, `relogin_required`, `foreign_credential`, `no_credentials`, `unavailable` (`json_output.py:151-165`).
- `usage`:
  - `fiveHour{pct, resetsAt, countdown, clock}`;
  - `sevenDay{pct, resetsAt, countdown, clock, expectedPct?, aheadOfPace?, projectedExhaustionAt?, willLastToReset?}`;
  - `scoped[{name, pct, resetsAt, …pace}]` and `spend{used, limit, pct, currency, resetsAt}`.
- Freshness: `usageFetchedAt`, `usageAgeSeconds`. When `usage` is null, the last known values are in `lastGoodUsage`, `lastGoodFetchedAt`, `lastGoodAgeSeconds`.

`status --json` returns `{active:{…same fields…, managed}, totalManagedAccounts}`. `switch --json` returns `{switched, from:{number, email}, to, strategy, reason: switched|already-active|…, message, warnings[]}`.

Ready-made status text for each state: `SENTINEL_NOTES` (`switcher.py:198-204`) and `ERROR_NOTES` (`:181-196`).

**Plan type is not in cswap's output.** Read it from `configs/.claude-config-N-*.json` (or `~/.claude.json` for the active account) → `oauthAccount`: `organizationType` ("claude_max"), `organizationRateLimitTier` ("default_claude_max_20x", i.e. Max 20x), `billingType`, `displayName`, `hasExtraUsageEnabled`, `seatTier`, `userRateLimitTier`, `organizationRole`.

**Illustrative data for the mockup** (made-up values; all three accounts on Max 20x, account 3 active):

| # | Email | Display name | 5h | 7d | Fable |
|---|---|---|---|---|---|
| 1 | a@example.com | 帳號 A | 0% (window not started) | 5%, resets 11/03 | 0% |
| 2 | b@example.com | 帳號 B | 12% | 40%, resets 10/30 | 0% |
| 3 (active) | c@example.com | 帳號 C | 20% | 80%, resets 11/01 | 0% |

The cached rows also carry `pollIntervalS` (60s for the active account, 600s for idle ones), `lastError` and `last429At`.

Settings worth exposing (`settings.py:43-57, 105-141`): `autoswitch.threshold` 90 (range 50-99.9), `intervalSeconds` 60, `cooldownSeconds` 300, `hysteresisPct` 10, `strategy` best|consume-first, `includeApiKeyAccounts` false, `unhealthyTicks` 3, `model` (none), `ui.theme` auto.

Waiting/idle status for running sessions is not cswap data. It comes from `~/.claude/sessions/{pid}.json` (`process_detection.py:22-32`), which has `status` (`busy`/`idle`/`waiting`), `name`, `cwd`, `sessionId`, `version`, `statusUpdatedAt` and `kind`/`entrypoint`. Each config directory (including cswap session profiles) has its own `sessions/` folder.

## 6. Risks and limits for a GUI wrapping cswap
1. **A switch is global.** Every running Claude Code session on the default profile moves to the new account once the Keychain cache expires (about 30s on macOS). The first message after a switch may cost extra while the conversation cache rebuilds. Per-session accounts only exist through `cswap run` / `CLAUDE_CONFIG_DIR`, and Claude's session files do not record which account a session uses.
2. **Session mode has side effects.** History is split per account unless `--share-history`, so the app's session list has to scan `<profile>/projects` too (CODD web already handles this via `config_dir` and the `cswap-<n>` folder-name pattern in `codd-statusline.js:100-105`). Running the same account as both the default login and a session can leave one copy with an outdated token (warning at `switcher.py:6566-6582`).
3. **`cswap list --json` is not read-only.** It can refresh inactive tokens and write them to the Keychain and `cache/usage.json`. It also spawns `security` once per account plus Python startup each time. Safer options:
   - call it at most every 60-180s, off the UI thread;
   - or read `cache/usage.json` directly (writes are atomic, but the schema is internal);
   - or use the Python `SnapshotSource.take(store_only=True)` path, which the docs call "the supported read path for dashboards and GUI shells" (`snapshot_source.py:1-12`).
4. **Do not poll `/api/oauth/usage` separately.** The rate limit is shared and this machine already gets 429s. For the active account, the statusline's `rate_limits` costs no API calls (CODD already uses it); cswap's cache covers the inactive accounts.
5. **Keychain prompts.** cswap's items were created by `/usr/bin/security`. A Swift or Electron app reading them through Security.framework would trigger the "wants to use your keychain" prompt. Go through `cswap` or `/usr/bin/security`.
6. **Concurrency and latency.** A switch can wait 9s per lock (about 27s worst case) while Claude Code refreshes tokens, then fail with `ClaudeCodeLockTimeout`. Show progress and allow retry. Running two auto engines (our app plus `cswap menubar`/`auto`) shares `autoswitch_state.json`; it is guarded by locks, but there should be only one owner.
7. **Interactive prompts.** `remove`, `add --slot` (when the slot is occupied), first-run setup and `add-token` without a token all read stdin. Use a PTY, pipe `y\n`, or call the Python API with `assume_yes=True`.
8. **Environment hygiene.** Never pass a session's `CLAUDE_CONFIG_DIR` into cswap management calls; they are refused or act on the wrong store. Also strip `ANTHROPIC_*` / `CLAUDE_CODE_OAUTH_TOKEN` variables from the app's environment.
9. **Errors.** Errors in `--json` mode come back as `{"schemaVersion":1,"error":{"type","message"}}` with exit 1. Types: `CredentialReadError`, `CredentialWriteError`, `SwitchError`, `SessionError`, `LockError`/`ClaudeCodeLockTimeout`, `AccountNotFoundError`, `ValidationError`, `TransferError`, `MigrationError`. The JSON contract only adds fields over time, so ignore unknown keys.
10. **Beta software that changes quickly.** The code pins Claude Code internals as of version 2.1.218-2.1.220 (lock names, hashed Keychain service names), and session mode is EXPERIMENTAL. Pin a minimum cswap version and check `cswap --version`. Exports and `.enc` files contain tokens in plaintext or base64, so never show or log them.