# M2 fixtures

Helper scripts for the M2 end-to-end run (`scripts/m2-e2e.sh`, step I7) and for every agent that
launches a real CODD.app without a real `claude` (docs/M2-PLAN.md C4, §8). Bash and `python3 -I`
only. No network: the only sockets are on 127.0.0.1. Nothing is written under `~`. Every path comes in
as an argument, and callers pass temp folders.

Each writing script refuses a target inside `~`, `~/Library` or `~/.claude` (exit 1).

`PYTHON3=<python>` picks the interpreter. The default is `python3` from PATH. All Python here also
runs on the system `/usr/bin/python3` (3.9), which is what CODD's sessions find on their default PATH.

## Cleanup rule

Every process a script starts carries the caller's marker or root path in its argv. Clean up with
`pkill -TERM -f "<root>/"`, wait, then `pkill -KILL -f "<root>/"`. Never kill anything else.

- **CODD holders** run from `<dataRoot>/bin/codd-holder-*`. They outlive the app, so kill them
  explicitly. A holder hangs up its child on SIGTERM, and the fake claude then removes its registry
  file.
- **The fake claude** carries the root through its `--settings` (the `codd-hook` path under
  `<dataRoot>/bin`). It also carries the root through its own path when you copy it into the root.
- **External dummies** carry `<claudeDir>/sessions` and the marker.
- **`host` processes** are renamed `fake-external-host <marker>`.

## make-root.sh

`make-root.sh <root>` creates `<root>` with mode 0700, creating parents as needed. It then writes
`<root>/config.json` with mode 0600, in exactly the format `HookConfigStore` reads and
`scripts/m1-e2e.sh` writes:

```json
{"port":<n>,"token":"<64 hex>","v":1}
```

The port is random, in 43000–43999, and free right now: `bind` without `SO_REUSEADDR`, like
`PortProbe`. The token is fresh (32 bytes).

- **Output:** prints `<port> <token>`.
- **Exit codes:** 1 when `config.json` already exists; 2 for bad arguments or no free port.

Every manual CODD launch starts from such a root, so a test instance never takes the user's hook
port (47821–47899):

```sh
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codd-x.XXXXXX")"   # keep it short: holder sockets < 104 bytes
read -r PORT TOKEN < <(scripts/m2-fixtures/make-root.sh "$ROOT/root")
"$APP" -codd-data-root "$ROOT/root" -codd-claude-dir "$ROOT/claude" -codd-login-env NO -codd-notifications NO \
       -codd-claude-path "$ROOT/fake-claude" -codd-shell-argv "/bin/zsh -f" …
```

## fake-claude-m2.sh

A CODD-compatible fake `claude`. It is a Python 3.9 script with the shebang `#!/usr/bin/python3 -I`,
so the pid is the one the holder spawned. It never contacts Anthropic. CODD starts it through
`-codd-claude-path` with `--session-id` / `--resume`, the per-session `--settings` and
`CODD_SESSION_ID` / `CODD_HOOK_TOKEN` / `CODD_HOOK_URL`.

### Configuration

**Copy the script into your temp root and put a sidecar next to the copy.** With
`-codd-login-env NO`, CODD passes sessions only an allow-list of its own environment (HOME, USER,
TMPDIR, …), so `FAKE_*` variables set on the app never arrive.

- The sidecar is named `<script path>.env`. `FAKE_CONFIG=<file>` names another file.
- It holds `KEY=VALUE` lines; `#` starts a comment.
- Environment variables win over the file.
- A launch profile's environment (D5) also reaches it, because `FAKE_*` is not a blocked name.

```sh
cp scripts/m2-fixtures/fake-claude-m2.sh "$ROOT/fake-claude"
printf 'FAKE_REGISTRY_DIR=%s\nFAKE_LOG_DIR=%s\nFAKE_PRINT_ENV=CODD_SESSION_ID\n' \
    "$ROOT/claude/sessions" "$ROOT/fakelog" > "$ROOT/fake-claude.env"
```

| Setting | Effect |
|---|---|
| `FAKE_REGISTRY_DIR=<dir>` | Keeps `<dir>/<own pid>.json` like a real claude (see below). Use `<claudeDir>/sessions` to prove that CODD's own claude is never listed as external. |
| `FAKE_PRINT_ENV=A,B` | Prints a `FAKE-ENV` line for each name (profile env checks). |
| `FAKE_LOG_DIR=<dir>` | Writes `<dir>/fake-<pid>.json` with `{pid, argv (exact, including the full --settings), cwd, session, resume, config, startedAt}`, and appends every printed `FAKE-…` line to `<dir>/fake-<pid>.log`. Grep this file instead of a terminal dump (see Timings). |
| `FAKE_STOP_DELAY_MS=<ms>` | Delay between UserPromptSubmit and Stop (default 300). |

### Output contract

The e2e greps these strings. Each one is its own line, in this order:

| Line | When |
|---|---|
| `FAKE-ARGV <args joined by single spaces>` | Always first. The `--settings` value is replaced by `<settings:NB>` (N = its UTF-8 byte length). Arguments that contain spaces are not quoted. |
| `FAKE-ENV <NAME>=<value>` / `FAKE-ENV-UNSET <NAME>` | One for each `FAKE_PRINT_ENV` name. The value comes from the real process environment. |
| `FAKE-REGISTRY <dir>/<pid>.json` | Registry mode, written before the DA1 probe (claude registers early, so CODD may see the file before the holder's WELCOME). |
| `FAKE-DA1-OK` / `FAKE-DA1-MISSING` | Stdin is a tty: it sends `ESC[c` and waits up to 3 s for `ESC[?…c`. Bytes that arrive after the reply are kept as input. |
| `FAKE-CLAUDE session=<id> resume=<id or none> url=<hook url>` | Same as `scripts/fake-claude.sh`. |
| `FAKE-SESSIONSTART hook=<command> status=<rc>` / `FAKE-SESSIONSTART-MISSING hook=<command or empty>` | SessionStart through the `command` hook in `--settings`: `[command] + args`, event JSON on stdin (`source` is `startup` or `resume`). The `hook=` prefix matches the m1 greps. |
| (no line) | OSC 0 title `fake claude m2`, `ESC[?2004h`, then raw mode with no echo. |
| `FAKE-READY` | Input is read from here on. |

Per input byte stream:

- **`FAKE-PASTE <text>`** for an `ESC[200~ … ESC[201~` block. CR is shown as `⏎` (U+23CE), LF as
  `↵` (U+21B5), TAB as `⇥` (U+21E5), other control characters as `^X`. Markers split across reads
  are handled.
- **`FAKE-LINE <typed text>`** at CR, only when something was typed. Typed text is printable UTF-8
  (a character split across reads survives). LF adds a newline (shown `↵`), DEL / BS delete one
  character, and Ctrl-C clears the line (`FAKE-KEY 03`).
- **`FAKE-SUBMIT`** at every CR, printed after `FAKE-LINE`. When the prompt is non-empty, the
  registry is already `busy` when this line appears. The prompt is the pasted and typed text in
  order, with CR / CRLF converted to LF.
- **Hooks after a non-empty submit:**
  - UserPromptSubmit `{hook_event_name, session_id, cwd, prompt, permission_mode}`.
  - About 300 ms later, Stop `{…, stop_hook_active:false}`.
  - Then the registry goes back to `idle`.
  - An empty CR prints `FAKE-SUBMIT` and posts nothing.
- **`FAKE-HOOK <event> <http status>`** after each post (`000` = failed). Only printed when a hook URL
  is known.
  - The URL is `CODD_HOOK_URL`, else the `http` UserPromptSubmit handler in `--settings`.
  - Posts go only to `http://127.0.0.1|localhost:<port>`, with 1 s timeouts.
  - Headers: `X-CODD-Token: $CODD_HOOK_TOKEN`, `X-CODD-Session: $CODD_SESSION_ID`,
    `Content-Type: application/json`, `Host: 127.0.0.1:<port>`; no `Origin`.
  - With no URL, nothing is posted or printed.
- **`FAKE-KEY <hex>`** for other control bytes, CSI / SS3 keys, or a lone ESC (an escape sequence
  not finished within 100 ms).
- **Typed line `FAKE-EXIT`:** prints `FAKE-LINE FAKE-EXIT` and `FAKE-CLAUDE-EXITING`, then exits
  with status 3. No `FAKE-SUBMIT`, no hooks.
- **Typed line `FAKE-CLEAR`** (like `/clear`):
  - prints `FAKE-LINE FAKE-CLEAR`;
  - posts SessionEnd `{reason:"clear"}`;
  - picks a new Claude session id and prints `FAKE-CLEARED session=<new id>`;
  - updates the registry `sessionId`;
  - runs the SessionStart command hook with `source: "clear"`.

On exit (FAKE-EXIT, end of input, hangup, SIGTERM / SIGHUP / SIGINT) it removes the registry file,
sends `ESC[?2004l` and restores the tty. The exit status is 3, 0, 129, 143 or 130. A second signal
during cleanup is ignored.

### Registry file

`<FAKE_REGISTRY_DIR>/<pid>.json`, compact JSON, written atomically (temp file `.<pid>.json.tmp` +
rename):

```json
{"pid":…,"sessionId":"<--resume or --session-id value>","cwd":"<os.getcwd()>","startedAt":<ms>,
 "procStart":"Fri Oct 16 14:45:04 2026","version":"2.1.300","kind":"interactive","entrypoint":"cli",
 "name":"<-n value, when given>","nameSource":"user","bridgeSessionId":"cse_…(with --remote-control)",
 "status":"idle|busy","statusUpdatedAt":<ms>,"updatedAt":<ms>}
```

`procStart` is `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`, whitespace-normalized. The C locale
matters: with `LANG=zh_TW.UTF-8`, `ps` prints `五 10月/16 …`, which CODD cannot parse.

## fake-external-claude.sh

A claude "started outside CODD". It runs a long-lived dummy whose argv is
`perl -e <code> <claudeDir>/sessions <marker>`, and writes the registry file a real claude keeps,
`<claudeDir>/sessions/<pid>.json`. The file has the same fields as above; `name` defaults to
`external test` and `status` to `busy`. `waitingFor` is present only when given. Every write is
atomic.

| Command | Effect | Output |
|---|---|---|
| `start <claudeDir> <cwd> <marker> [status] [name] [waitingFor]` | Detached dummy (`setsid`, parent launchd), like a claude in another terminal. | `<pid> <sessionId>` |
| `host <claudeDir> <cwd> <marker> [status] [name]` | The dummy is a child of this script's process. The line also goes to `<claudeDir>/host-<basename of marker>.txt`. Then the script runs `exec -a "fake-external-host <marker>" /bin/cat`, keeping its pid, so the dummy's parent stays alive. | `<pid> <sessionId>` (on the terminal and in the host file) |
| `set-status <claudeDir> <pid> <status> [waitingFor]` | Rewrites the file with a strictly newer `statusUpdatedAt` (= `updatedAt`). `waitingFor` is dropped unless given. `waiting` + `permission prompt` is a permission wait; `input needed` is a question. | nothing; exit 1 when the file is missing |
| `stop <claudeDir> <pid>` | Removes the file. Then it TERMs (and after 2 s KILLs) the pid, but only when its argv names `<claudeDir>/sessions`; otherwise exit 1, nothing killed. A zombie counts as stopped. | nothing |

Optional environment for `start` / `host`: `FAKE_EXT_SESSION_ID` (instead of a fresh uuid),
`FAKE_EXT_ENTRYPOINT` (for example `sdk-cli` or `claude-desktop`, to test hiding) and
`FAKE_EXT_KIND`.

How the dummy ends:

- On SIGTERM / SIGHUP / SIGINT it removes its own file, like a clean claude exit.
- `kill -KILL <pid>` leaves a stale file behind, like a crash. CODD's liveness re-check drops that
  file within 5 s.
- It ends by itself after an hour.

**Using `host` as a CODD shell.** Pass it as the shell argv:

```sh
-codd-shell-argv "<abs path>/fake-external-claude.sh host <claudeDir> <cwd> <marker>"
```

- The argv is split on spaces, so none of these paths may contain one.
- The shell's holder is then an ancestor of the dummy: holder → host (cat) → dummy.
- Read `<claudeDir>/host-<marker basename>.txt` to learn the dummy's pid.
- The flag applies to every shell and shell tab of that app run.
- When the holder hangs up, cat and the dummy get SIGHUP, and the file disappears.

## make-transcripts.sh

`make-transcripts.sh <claudeDir> <cwd>` writes six JSONL transcripts into
`<claudeDir>/projects/<folder>/`. `<folder>` is Claude's name for `<cwd>`: every UTF-16 unit outside
`[A-Za-z0-9]` becomes `-`, so a CJK character outside the BMP gives two dashes. It prints the manifest
path.

Each transcript has realistic records: user and assistant lines with `sessionId`, `cwd`,
`gitBranch`, `timestamp`, `entrypoint`, `version`, `uuid` / `parentUuid` and `message`; a tool_use /
tool_result pair; `custom-title`, `ai-title` and `last-prompt` records.

| | Title (source) | Branch | Age | Notes |
|---|---|---|---|---|
| a | `refresh token 流程改寫` (custom-title; its ai-title loses) | fix/refresh | 2 d | first line `file-history-snapshot` (no cwd), `last-prompt` = `順便補上過期 token 的測試`, sibling `<id>/subagents/agent-1.jsonl` |
| b | `auth middleware 單元測試` (ai-title) | main | 5 d | |
| c | `登入頁錯誤訊息 i18n` (first prompt) | feat/i18n | 12 d | starts like a `/clear` session: meta caveat line (`isMeta`), `<command-name>/clear</command-name>` line, empty `<local-command-stdout>` line; none of them is a prompt |
| d | `CI 設定` (first prompt, content as a text-block array) | main | 26 d | `! resume 4 天後過期` with the default cleanupPeriodDays 30 |
| e | (hidden) | main | 1 d | entrypoint `sdk-cli` |
| f | (hidden) | main | 3 d | same folder, but its lines carry another cwd, `<parent>-<basename>`, which has the same folder name |

The manifest is `<claudeDir>/projects/manifest-<folder>.json` (0600):

```text
{cwd, folder, projectsDir, cleanupPeriodDays: 30, warnWithinDays: 5, generatedAtMs,
 expected: [{id, title, titleSource (custom|ai|firstPrompt), branch, ageDays, expiresInDays|null,
             sizeBytes, mtimeMs, createdAt (first timestamp), path}]   newest first (a, b, c, d),
 hidden: [e, f], hiddenReasons: {<id>: "sdk-cli" | "other-cwd"}, otherCwd,
 siblingFolder: {id, path}, lastPrompt: {id, text}}
```

- **Ages and expiry.** The mtime is "N days + 2 hours ago", so the floor and the rounding of the age
  both give N during the whole run. `expiresInDays` = 30 − ageDays when ≤ 5 (only d: 4).
- **Ids** are fresh lowercase uuids.
- **The cwd.** Pass it the way a real claude records it, `getcwd()` with symlinks resolved
  (`cd "$dir" && pwd -P`, for example `/private/var/folders/…`). The lines carry the cwd exactly as
  given.
- **Errors.** It refuses a second run for the same folder (manifest exists, exit 1). It refuses a
  folder name over 200 characters (Claude shortens those with a hash; exit 2).

## seed-layout.sh

`seed-layout.sh <dataRoot> <workDir>` creates the project folders under `<workDir>` and writes
`<dataRoot>/layout.json` in CoddCore's exact format:

- `LayoutStore` / `JSONEncoder` pretty-printed with sorted keys and `"key" : value`;
- version 1;
- dates as `JSDate.isoString` writes them (`2026-10-15T02:42:00.000Z`);
- ColorTag raw values;
- lowercase UUIDs (CoddCore reads either case; once the app saves the layout, `layout.json` has
  them upper case, while the state dump keeps lower case: compare ids case-insensitively);
- an ungrouped project has no `groupId` key.

It prints the path of `<dataRoot>/manifest-layout.json`.

| Group (color) | Project | Sessions |
|---|---|---|
| `藍鵲 · 網站` (blue) | `northstar-site` | claude `修正登入 API 401` (titleOverride, pinned, color orange, claudeSessionId = its own id); archived claude `舊的部署腳本` |
| | `整合範例` (collapsed) | claude `refresh token 流程改寫` (title; claudeSessionId differs, as after /clear) |
| `個人 · Github` (green) | `codd-desktop` | none |
| 未分類 | `scratch` | shell `zsh` |

No session has a holder. CODD therefore shows the claude sessions STOPPED and the shell EXITED, and
the state dump lists `groups` = `["藍鵲 · 網站", "個人 · Github", "未分類"]` and the three non-archived
sessions.

The manifest has these keys:

```text
{dataRoot, workDir, layout, groups [{id,name,color,order}], groupOrder (with 未分類 last),
 projects [{id,name,path,groupId,group,order,collapsed,sessions,archived}],
 sessions [{id,kind,title,projectId,claudeSessionId,pinned,archived,order,color}],
 pinned, archived, collapsedProject, ungroupedProject, cjkProject, visibleSessions}
```

Directories are 0700 and files 0600. `<dataRoot>` is created when missing, and a `make-root.sh` root
works (its `config.json` is left alone). It refuses an existing `layout.json` (exit 1).

## selftest.sh

```sh
scripts/m2-fixtures/selftest.sh
scripts/m2-fixtures/selftest.sh --with-app build/m2fixtures/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
```

It runs everything in one fresh `mktemp` folder and checks:

- **make-root.sh:** the format, the modes, the port range, and that it refuses an existing config,
  `~/.claude` and `~/Library` (tested with `HOME` pointing into the temp folder).
- **fake-external-claude.sh start / set-status / stop:**
  - the JSON fields and types;
  - `procStart` against the kernel's `kinfo_proc` start time in UTC, within 1.5 s;
  - that a SIGTERM removes the file;
  - that `stop` refuses a pid that is not a dummy.
- **`host` under a pty:** the dummy's parent is the host process, which exec'd cat; the host file;
  hangup cleanup.
- **make-transcripts.sh** for a CJK + space + non-BMP path and a space path:
  - the folder names, from an independent per-code-point implementation;
  - the manifest against the files: order, titles derived from the lines, branches, sizes, mtimes,
    line JSON, the cwds;
  - the sdk and other-cwd files, the sibling folder, the last-prompt record.
- **seed-layout.sh:** the structure and the exact encoder form.
- **fake-claude-m2.sh under a pty**, with no hook URL and registry mode:
  - the `FAKE-ARGV` / `FAKE-ENV` / DA1 / title / `?2004h` lines;
  - the registry file (pid = the spawned pid, procStart);
  - `hello 世界` split inside a UTF-8 character, giving `FAKE-LINE`;
  - registry busy, then idle;
  - `第一行⏎第二行` (CR inside a paste) and `甲↵乙` (LF inside a paste);
  - split paste markers, lone ESC, backspace;
  - FAKE-EXIT exit 3, with the file removed.
- **A copy with a sidecar `.env` and a local HTTP sink:**
  - SessionStart command hook argv and stdin;
  - UserPromptSubmit / Stop bodies, headers and the 300 ms gap;
  - FAKE-CLEAR;
  - `FAKE_LOG_DIR`;
  - SIGTERM giving exit 143 with the file removed.
- **`--with-app`:**
  - CODD on a seeded `make-root.sh` root: the dump's groups, the non-archived sessions, and hooks on
    the root's own port;
  - a second run where CODD starts `fake-claude-m2` as its claude, giving DA1, SessionStart through
    the installed `codd-hook`, `FAKE-LINE hello 世界`, both hooks 204, `idle->busy->done`, and a
    registry file that is removed when the holder is terminated.

It prints `FIXTURES pass=N fail=M` and exits 1 on any failure. At the end, no process carrying the
temp folder may still be running. It kills only what carries the temp folder, and removes the folder
unless `KEEP=1`.

## Timings and flakiness guards (for the e2e author)

- **Startup.** The fake claude reaches `FAKE-READY` well under 1 s once the terminal answers DA1.
  Without an answer it waits the full 3 s, then prints `FAKE-DA1-MISSING`.
- **Turn timing.** Stop follows UserPromptSubmit after about 300 ms (`FAKE_STOP_DELAY_MS`). CODD
  batches state at 10 Hz or less, so a 300 ms busy phase can be missed by a poller. Assert on the
  app log transitions (`idle->busy`, `busy->done`) or on `FAKE-HOOK … 204`, not on catching `busy` in
  a dump.
- **Terminal dumps wrap.** `-codd-dump-terminal` writes the viewport, so long lines wrap at the
  terminal width and early lines can scroll away. `FAKE-SESSIONSTART hook=<long path> status=0`
  wrapped in a 130-column dump. Use `FAKE_LOG_DIR` (`fake-<pid>.log` has one exact line per event)
  or prefix greps.
- **Registry timing.** CODD's registry watcher coalesces for 100 ms and re-checks liveness every 5 s.
  Allow about 1 s for a new or changed file to show, and up to about 6 s for a SIGKILLed dummy's stale
  file to be dropped.
- **Port races.** `make-root.sh` checks that the port is free when it runs. Another program could
  take it before CODD binds; the chance is about 1/1000 per concurrent root.
- **Holders outlive the app.** The holder hangs up its child on SIGTERM (SIGHUP, then SIGKILL after
  3 s); the fake claude cleans up on that hangup.
- **Socket paths.** Keep roots short (`$TMPDIR` is fine, deep scratch folders are not): holder
  socket paths must stay under 104 bytes.
