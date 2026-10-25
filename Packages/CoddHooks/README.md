# CoddHooks

Live session state for CODD. This package receives Claude Code hooks over loopback HTTP, watches Claude's session registry, and combines both with holder events into the `SessionState` the sidebar, the menu bar and the Dock badge show. Since M3 the same endpoint also receives status-line reports (5-hour and weekly quota) from `codd-statusline`. Since M4 it also carries CODD's MCP server (`POST /mcp`), the prompt-expansion hook (`POST /hooks/prompt`) and note URLs (`GET /n/<id>.md`); the MCP and notes logic itself lives in the app (handlers), this package only routes, authenticates and frames.

In M1 the app hosts all of this (degraded mode). Later, `coddd` takes it over with the same types.

| Part | Role |
|---|---|
| `HookConfigStore` | `<dataRoot>/config.json`: `{port, token, mcpToken, v}`, mode 0600, data root 0700 when CODD creates it; `rotateMCPToken()` (M4) |
| `HookServer` | `NWListener` on 127.0.0.1: `POST /hooks`, `POST /statusline`, `GET /health`, and (M4) `POST /mcp`, `POST /hooks/prompt`, `GET /n/<id>.md`. `start()` / `stop()` / `restart(port:token:)` / `finish()`, plus `state`, `port`, `events`, `statusLines` and `statistics()`; M4: `setMCPHandler`, `setPromptHandler`, `setNoteURLHandler`, `setMCPToken` |
| `MCPAuth` | M4: the per-session MCP token, note URL tokens, `makeToken()` |
| `codd-hook` | The SessionStart `command` hook: stdin to `POST`, no stdout, always exit 0 |
| `codd-statusline` | The status-line `command`: forwards `rate_limits` to `POST /statusline`, runs the user's own status line with the same stdin (see below) |
| `StatusLineReport` | Decodes a `/statusline` body: account key, 5-hour and weekly window |
| `RegistryWatcher` | FSEvents on `~/.claude/sessions` (plus any extra `CLAUDE_CONFIG_DIR`s) |
| `SessionStateEngine` | An actor: hook reducer, merger and resolver, persisted per session, batched at 10 Hz or less |
| `HookRuntime` | Wires the four parts above together for the app |
| `HookHealthProbe` | Tells whether another CODD already owns a busy port |

Build and test (the scratch path avoids lock clashes). `swift test` also builds `codd-hook` and `codd-statusline`, which the end-to-end tests run:

```sh
swift test --package-path Packages/CoddHooks --scratch-path .build-hooks
```

## Wire contract

This matches `ClaudeHookSettings` in CoddCore (`Launch/HookSettings.swift`).

- **http hooks.** Every event except SessionStart is delivered as `POST http://127.0.0.1:<port>/hooks`. The body is the hook JSON.
  - `X-CODD-Token: $CODD_HOOK_TOKEN` is the per-install token from config.json.
  - `X-CODD-Session: $CODD_SESSION_ID` is the CODD session UUID, which is also the hook record's terminal id.
  - Claude expands both from the session environment (`allowedEnvVars`), so the token never appears in argv.
- **SessionStart.** It cannot use `http`, so Claude runs `codd-hook session-start --url <url>` with the hook JSON on stdin and the same two variables in the environment.
  - `codd-hook` accepts any subcommand name, used only as a hint in debug output.
  - `--url=<u>` works too, and `CODD_HOOK_URL` is the fallback.
  - Only `http://127.0.0.1[:port]` and `http://localhost[:port]` URLs are accepted. `localhost` is connected as 127.0.0.1 without a DNS lookup.
- **Status-line reports.** `codd-statusline` sends `POST http://127.0.0.1:<port>/statusline` (M3 D9).
  - `X-CODD-Token` is required, checked like on `/hooks`.
  - `X-CODD-Session` is optional: per-session runs send it, the global status line (claudes CODD did not start) does not. When present it must appear once and be a canonical UUID.
  - The body is at most 64 KiB (`HookRequestPolicy.statusLineMaxBodyBytes`; a `Content-Length` above is refused before the body, a chunked body is cut off at the limit): `{"v":1,"session_id":<Claude's session id>|null,"config_key":"default"|"cswap-<n>"|"cfg-<16 hex>","rate_limits":<Claude's value verbatim>|null}`.
- **Prompt expansion (M4 D19).** With `ClaudeHookSettings.promptPath = "/hooks/prompt"`, UserPromptSubmit goes to `POST http://127.0.0.1:<port>/hooks/prompt` (timeout 3 s) instead of `/hooks`. The other events stay on `/hooks`.
  - Auth, `Host`, `Origin` (always refused), method, session header, body length and 1 MiB limit are exactly `/hooks`'s.
  - The decoded payload is yielded on `events` first, in the same queue block as any hook, so states and the last prompt update as on `/hooks`. Then the prompt handler (`setPromptHandler`) runs, off the server queue, with a 1.5 s deadline (`Configuration.promptDeadline`).
  - The answer is `200 application/json` `{"hookSpecificOutput":{"additionalContext":"…","hookEventName":"UserPromptSubmit"},"systemMessage":"…"}` (`PromptHookAnswer.jsonBody()`: compact UTF-8, sorted keys, slashes unescaped; `systemMessage`, the line Claude shows the user, only when given). No handler, a `nil` answer, or the deadline passed: `204` (Claude reads an empty body as `{}`). Never plain text: Claude requires a body that starts with `{`.
- **MCP (M4 D16).** `POST http://127.0.0.1:<port>/mcp`, Streamable HTTP, stateless; the MCP handler (`setMCPHandler`) gets the caller and the whole request (`HTTPRouteRequest`: method, path, decoded query, headers, body) and its `HTTPRouteResponse` is sent as is (200 `application/json`, 202 empty, 400, …).
  - `Host` as on `/hooks`. `Origin` absent, or exactly `http://127.0.0.1:<port>` / `http://localhost:<port>` (scheme and host in any case); anything else, or a repeated `Origin`, is 403.
  - A CODD session sends `X-CODD-Session: <uuid>` (exactly once) and `X-CODD-Token: MCPAuth.sessionToken(hookToken:sessionID:)`: lowercase hex HMAC-SHA256 keyed with the hook token's UTF-8 over `codd-mcp-v1:<uuid lowercased>`. It comes literally from the session's 0600 `mcp.json` (`MCPLaunchConfig` in CoddCore), because claude never expands credential-looking variables toward a remote MCP server. Caller `.session(uuid)`.
  - With no session header, the external token (config.json `mcpToken`) as `X-CODD-Token` or `Authorization: Bearer <token>`, each at most once; every copy sent must be right. Caller `.external`.
  - Anything else is 401 **without** `WWW-Authenticate` (no client starts an OAuth flow). A session header is never retried as an external caller.
  - `GET` and `DELETE` (any method but POST) are 405 `Allow: POST`, checked before auth: Claude's transport reads a 405 on GET as "no server stream".
  - Body length required (411), at most 1 MiB (413). No handler: 503 with `{"jsonrpc":"2.0","id":null,"error":{"code":-32603,…}}`. A handler over 10 s (`Configuration.handlerDeadline`): 503 with code -32001.
- **Note URLs (M4 D15).** `GET http://127.0.0.1:<port>/n/<id>.md?t=<token>` (COPY REF form 5, `HookRequestPolicy.noteURL(port:noteID:mcpToken:)`).
  - `Host` as on `/hooks`; any `Origin` is 403; methods other than GET are 405 `Allow: GET`.
  - `<id>` must have the note id shape (`[a-z0-9]+(-[a-z0-9]+)*`, at most 48), else 404 (no route).
  - `t` (exactly once) must be `MCPAuth.noteURLToken(mcpToken:noteID:)`: the first 24 hex of HMAC-SHA256 keyed with the external token over `codd-note-url-v1:<id>`, compared in constant time. Wrong, missing, repeated, or no external token: 404, like an unknown note, and the handler is not called. A rotation kills every URL.
  - The note URL handler (`setNoteURLHandler`) gets the id; its answer is sent as is (200 `text/markdown; charset=utf-8`, 404 for an unknown or AI OFF note, 410 for a trashed or purged one). No handler: 404. Over 10 s: 503.
- **Handler answers.** The server adds `Content-Length`, `Cache-Control: no-store` and `Connection: close`; a handler's own `Content-Length`, `Content-Type`, `Connection`, `Transfer-Encoding` and `Cache-Control` headers, and any header with a control character, are dropped. A status outside 200…599, or a body over 16 MiB (`Configuration.maxResponseBytes`), becomes an empty 500.
- **Queries.** `/hooks`, `/statusline` and `/health` ignore a query exactly as before (`/hooks?x=1` is `/hooks`). Query parsing (`HookRequestPolicy.queryItems`): `+` is a space, `%XX` is decoded, the first value of a repeated name wins in `HTTPRouteRequest.query`.
- **Responses.** The server answers `204` once the body is complete, before decoding it (`/hooks`, `/statusline`). Every response carries `Connection: close`.

  | Status | Cause |
  |---|---|
  | 400 | Malformed request, bad `Content-Length`, or `X-CODD-Session` not a UUID (missing too, on `/hooks` and `/hooks/prompt`) |
  | 401 | Missing, wrong or duplicated token (on `/mcp`: no valid session or external token) |
  | 403 | Any `Origin` header (on `/mcp`: one other than the endpoint's own), or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>` |
  | 404 | Any other path; a note URL with a wrong or missing token |
  | 405 | Wrong method (with `Allow`) |
  | 408 | Request head not complete within 1 s, or the request not within 5 s of its head (never while a handler runs) |
  | 411 | No body length |
  | 413 | Body over 1 MiB (`/hooks`, `/hooks/prompt`, `/mcp`) or 64 KiB (`/statusline`) |
  | 431 | Head over 16 KiB, or more than 100 header fields |
  | 500 | A handler's answer over 16 MiB |
  | 501 | A transfer coding other than chunked |
  | 503 | `/mcp` without a handler; a handler past its deadline (`/mcp`, `/n/`) |
  | 505 | Not HTTP/1.x |

- **Health check.** `GET /health` answers `200 {"ok":true,"app":"codd"}` with no token and no data. With `X-CODD-Challenge: <16–128 hex digits>` the body also carries `"proof"`: lowercase hex HMAC-SHA256 of `codd-health-v1:<challenge>`, keyed with the token. `HookHealthProbe.probe(port:token:)` sends a fresh nonce and reports `.codd` only for a correct proof, so "another CODD on this data root owns the port" is proven, not claimed (any process can answer `{"app":"codd"}`), and the token never leaves the process.
- **Events.** Accepted hooks come out of `HookServer.events` as `HookEvent(sessionID, payload: HookPayload, receivedAt)`.
  - `tool_response` is dropped at the boundary, skipped without being decoded (`HookPayload(body:droppingKeys:)`). It can be megabytes, and no state rule reads it.
  - Arrays and objects nested deeper than 64 levels become `null` before decoding (`JSONValue.maximumNestingDepth`): the decode recurses per level on a dispatch worker thread, and a 2 KB body nested 300 deep used to overflow its stack and kill the app.
  - The stream buffers the newest 1024 events.
- **Reports.** Decoded status-line reports come out of `HookServer.statusLines` as `StatusLineReport(sessionID, claudeSessionId, configKey, fiveHour, sevenDay, hadRateLimits, receivedAt)`, in the order they completed, newest 256 buffered, single consumer. `/hooks` events never appear there and reports never appear on `events`.
  - The body is decoded with `JSONScan` (CoddHookClient): validated without recursion, nested at most 64 levels, else the whole body is dropped. So are bodies that are not one JSON object and a `v` other than `1` (`v` may be omitted).
  - `config_key` must match `^(default|cswap-[0-9]{1,4}|cfg-[0-9a-f]{16})$`, else it becomes `"invalid"`.
  - A window (`rate_limits.five_hour` / `seven_day`) counts only with a finite numeric `used_percentage` (clamped to 0…100; `"50"` is refused). Its `resets_at` may be epoch seconds (what Claude sends), epoch milliseconds (above 1e12) or an ISO 8601 string with a time zone; anything else, zero, negative or past the year 5138 leaves `resetsAt` nil but keeps the window.
  - `rate_limits` absent, `null` or not an object gives `hadRateLimits == false` and no windows. Claude omits it until a window is known.
  - `session_id` becomes `claudeSessionId` when it is a non-empty string of at most 256 bytes.
- **Diagnostics.** `HookServer.statistics()` counts accepted hooks, accepted status-line reports (`statusLinesAccepted`), reports answered 204 that did not decode (`statusLinesUndecodable`), the time of the last report (`lastStatusLineAt`), rejections by status (every route), and refused connections. It also keeps the last rejection with its reason, for example `403 Origin header present ("…")`, `401 wrong token`, `401 wrong MCP session token`, `404 note URL token missing` or `503 MCP handler over 10000 ms`. Token values are never quoted, and neither is a query (it holds note URL tokens). If a Claude version's http client ever sent an `Origin` header or an unexpected `Host`, this is where it would show up.
  - M4: `mcpRequests` (authenticated, body read), `mcpRejected` (refused once routed), `mcpTimedOut`, `lastMCPAt`; `promptHooks` (also in `accepted`), `promptAnswered` (200), `promptLate` (deadline, 204); `noteURLRequests` (valid token). Handler answers are not rejections, whatever their status.

### HTTP subset

The server parses one request per connection (`HTTPRequestParser`):

- **Body framing.** `Content-Length` or `Transfer-Encoding: chunked` (chunk extensions and trailers are ignored). `Expect: 100-continue` gets the interim response; curl sends it for bodies over 1 KiB.
- **Rejected as smuggling shapes.** `Content-Length` together with `Transfer-Encoding`, conflicting duplicate lengths, obsolete line folding, whitespace before a colon, and a bare CR.
- **Tolerated.** Bare LF line ends, empty lines before the request line, and HTTP/1.0.
- **Pipelining.** Bytes after the first request are ignored.

## Security model

The endpoint accepts prompts and tool input from local processes, so:

- **Loopback only.**
  - The listener binds 127.0.0.1, IPv4 only, on the loopback interface, with local-only acceptance.
  - Each peer is checked again to be in 127.0.0.0/8 before the connection is used.
- **No browser can deliver a hook.**
  - Any `Origin` header is refused. Browsers send it on every cross-site POST.
  - `Host` must name the loopback address and the port. This defeats DNS rebinding.
- **Token.**
  - 32 bytes from `SecRandomCopyBytes`, hex encoded, kept in config.json with mode 0600.
  - Compared in constant time.
  - It reaches Claude only through the session environment, never argv.
  - Security-relevant headers must appear exactly once.
- **MCP and note URL tokens (M4).**
  - A session's MCP token is derived from the hook token and the session id, so the literal in its 0600 `mcp.json` opens `/mcp` for that session only and nothing else (not `/hooks`).
  - The external token (`mcpToken`) is a second 32-byte secret in config.json; it opens `/mcp` as `.external` and derives the note URL tokens. It never opens `/hooks`. `HookConfigStore.rotateMCPToken()` + `HookServer.setMCPToken(_:)` replace it without a restart.
  - `/mcp` accepts the endpoint's own `Origin` (MCP clients may send one) but no other, so a web page cannot reach it even with a guessed token; DNS rebinding is stopped by the `Host` rule as everywhere.
  - A note URL token unlocks one note; a wrong token looks exactly like an unknown note (404).
- **Resource bounds.** 64 concurrent connections; more wait in the listen backlog (the listener's `newConnectionLimit`) and are accepted in arrival order as slots free up, instead of being reset. The request head must arrive within 1 s (`headTimeout`), the rest within 5 s of it; a connection that timed out before its head is closed after 100 ms, so idle sockets hold a slot for about a second. A 1 MiB body, and a 16 KiB head. After answering, the server drains unread input for up to 1 s or 2 MiB, so the client reads the status instead of a reset.
- **config.json handling.**
  - A file owned by another user is refused. A symlink is not followed.
  - A loose mode is tightened to 0600.
  - A corrupt file is kept as `config.json.invalid-<time>`, and only the invalid parts are regenerated (a valid port is always kept, and a valid `mcpToken`).
  - M4 (§3.11): a file without a valid `mcpToken` (every M3 file) gains one when it is loaded, rewritten 0600 and atomically with port, token and unknown keys unchanged; the origin stays `.loaded`. If that rewrite fails, the config loads without an MCP token (hooks work as in M3; external MCP callers and note URLs are refused) and the next load tries again. `reassignPort` / `setPort` keep it.
- **Known limit: port squatting.** Any local process could bind the port first, while CODD is not running, and receive the hooks of sessions started earlier, token included. The OS cannot rule this out for TCP on loopback. `HookHealthProbe` at least makes the situation visible: a busy port that does not answer as CODD.
  - It can also answer them. CODD answers `/hooks` with an empty 204 and `/hooks/prompt` only with `additionalContext` and a `systemMessage` (note expansion), but Claude parses a 2xx JSON body of an http hook like a command hook's output, so a squatter can allow, deny or rewrite a tool call (PreToolUse `permissionDecision` / `updatedInput`, PermissionRequest `decision.behavior`), add context to a prompt, block Stop, or replace what Claude sees of a tool's output (PostToolUse `updatedToolOutput`). Only `codd-hook` (SessionStart) and `codd-statusline` ignore the answer.
  - The app starts no session with hooks, status line or MCP while the endpoint is not its own (`HookPipeline.launchSettings`), so only sessions started earlier, the global status line and a user-scope MCP registration (which sends the external MCP token) reach a squatter. Only the MCP token can be rotated (`rotateMCPToken()`); a new hook token takes a new config.json (deleted while CODD is not running, or with an invalid `token`).

## Ports

- **Creation.** The port is chosen once, when config.json is created: 47821, or the first free port up to 47899.
- **Loading never moves a persisted port.** Running sessions have the URL baked into their `--settings`, so a silent move would cut every one of them off.
  - A busy port surfaces as `HookServerError.portInUse(port)` when `start()` is called.
  - Only an explicit `HookConfigStore.reassignPort()` or `setPort(_:)` changes it, after asking the user.
- **Bind retries.** `start()` tries the bind three times over about 200 ms. Under load, Network.framework occasionally reports a just-released port as busy, and a relaunched CODD can race the old instance's shutdown.

## Threading

| Part | Runs on |
|---|---|
| `HookServer` | One private serial queue for the listener, all connections and its state. The answer and the event (or report) yield happen in the same queue block, so a client that waited for its `204` (codd-hook, codd-statusline, Claude's http hooks) cannot have a later event overtake this one. Public methods are async and hop onto the queue; `state` is behind a `Mutex`. |
| Route handlers (M4) | `@Sendable` closures run in a `Task` off the queue. The connection keeps its slot and its read / head timers are replaced by the handler deadline; the answer is written back on the queue. A client that half-closes still gets it; one that disconnects only loses it (the handler is never cancelled, so an MCP append cannot stop half way). Handlers survive `stop()` / `start()`. |
| `RegistryWatcher` | One private serial queue. FSEvents streams deliver there, and file reads use CoddCore's tolerant `ClaudeRegistryReader`. |
| `SessionStateEngine` | An actor. Hook-record files are written on a separate serial queue (`HookStatePersister`). |
| Terminal bytes | Never reach this package. |

The main actor is never used. The UI consumes `SessionStateEngine.updates` and hops to the main actor itself, at most once per batch.

## Registry watcher

- **File events.** FSEvents uses file-level events, because Claude may rewrite `<pid>.json` in place. A kqueue watch on the directory would miss that.
- **Coalescing.** The first change schedules one read 100 ms later, and later changes join it. Latency is bounded, and reads happen at most 10 times a second.
- **Partial writes.**
  - A file that fails to decode keeps its last good entry, and a re-read is scheduled.
  - A file that never decoded is simply absent.
- **Missing directory.**
  - A directory that does not exist yet is polled every 2 s.
  - The root watch notices when a watched directory goes away.
- **Liveness.** Pid plus `procStart` is re-checked every 5 s without reading any file, because a crashed Claude leaves its file behind and no event fires.
- **Output.** `snapshots` yields only when the set of live entries changes. It keeps the newest snapshot.

## State engine

**Sources**, in priority order (docs/ARCHITECTURE.md, "State model"):
- `HookReducer` in the desktop dialect. StopFailure becomes ERROR; PreCompact/PostCompact become COMPACT.
- The live registry through `ActivityMerger`. A registry `busy`/`idle` more than 1 s newer than the last hook corrects it, which covers Esc, approved permissions and compaction mid-turn.
- Holder EXIT.
- The OSC title glyph (`◐`/`◑` busy, `✳` idle). It is used only once a session would otherwise be `unknown`: no hook and no registry entry after the 20 s starting grace.

**API**:
- `register(_:)`, `unregister(_:deletePersistedState:)`
- `claudeProcessStarted(_:pid:startedAt:claudeSessionId:)`, `processExited(_:code:at:)`, `childPidChanged(_:pid:)`
- `setLastViewed(_:at:)`
- `ingest(_:)`, `ingestRegistry(_:)`, `ingestTitle(_:for:)`
- `update(for:)`, `allUpdates()`, `flush()`, `pruneHookStates(keeping:)`, `finish()`

**Fresh vs. reattached processes.**
- `SessionRegistration.freshClaudeProcess = true` means CODD just started claude: a new session, RESTART or RESUME.
  - The restored hook record is hidden; the session shows STARTING until this process's first hook.
  - That first event is applied on top of `HookReducer.relaunchBaseline`. Otherwise the reducer's nested-claude guard would ignore every event of a process running under another Claude session id.
- `false` means CODD relaunched and reattached to a claude that kept running. The restored record shows right away, for example WAITING · PERMISSION.

**Persistence.**
- `<dataRoot>/hooks/<session-id>.json` holds CoddCore's v2 hook record. Mode 0600, directory 0700.
- Writes are debounced (1 s or less) and atomic (rename), but not flushed to disk. The file is a cache, and a torn file decodes as "no state".

**Output.**
- `updates` yields `SessionStateBatch(updates, removed)` at most once per 100 ms.
- The first change after a quiet period goes out immediately. Later ones are coalesced per session, and a change that reverts within the window is not emitted at all.
- Each `SessionStateUpdate` carries:
  - the `SessionState` and the merged `SessionActivity`;
  - the hook record, which includes the current Claude session id for `--resume` after `/clear`;
  - `hookSeen`, which drives SPEC's `! NO HOOK`;
  - the parsed title and the matched registry entry (name, Remote Control).

**Early hooks.** Hooks for a session that is not registered yet are buffered (at most 256 events) and replayed on registration. Register restored sessions before starting the server where possible.

**Clock.** `HookClock` is injectable. `ManualHookClock` drives batching and grace timers in tests.

## codd-statusline

Claude Code's status-line `command` for CODD sessions (M3 D8) and, optionally, for every claude (the global wrapper, D11). Standard library and Darwin only, like `codd-hook`: it runs on every status-line refresh of every session.

```
per session : <dataRoot>/bin/codd-statusline-<hex12>                   (no arguments)
              env CODD_HOOK_URL (=http://127.0.0.1:<port>/hooks), CODD_HOOK_TOKEN, CODD_SESSION_ID,
                  CODD_STATUSLINE_CHAIN=<base64 of the user's own status-line command> (optional)
global      : <dataRoot>/bin/codd-statusline --data-root <dataRoot> [--chain-b64 <b64>]
```

- **Arguments.** `--data-root`, `--chain-b64` and `--url` take `--flag value` or `--flag=value`. Parsing is lenient like `codd-hook`: unknown arguments are ignored, and a flag without a value counts as absent.
- **Endpoint.**
  - Per session: the port of `--url`, else `CODD_HOOK_URL`, with the path replaced by `/statusline`. Loopback only (`LoopbackURL`), plus `CODD_HOOK_TOKEN`. `CODD_SESSION_ID` is sent only when it is a canonical UUID, since the server would refuse anything else.
  - Global (`--data-root`): port and token come from `<root>/config.json`. The file must be a regular file owned by the user, at most 4 KiB, and is not followed if it is a symlink. No session header is sent, whatever the environment holds.
  - No endpoint: no request at all.
- **Report.** `{"v":1,"session_id":…,"config_key":…,"rate_limits":…}`.
  - `rate_limits` is stdin's member, byte for byte, found by `JSONScan` without decoding it. It is `null` when stdin is not a valid JSON object, has no `rate_limits`, or the body would exceed 64 KiB.
  - `session_id` is the raw string token, or `null` when it is not a string of at most 256 bytes.
- **Account key** (`StatusLineAccountKey`, D6). CoddCore's `AccountKey.from(claudeConfigDir:home:)` implements the same table, and both test the same rows. The key never carries the directory name, which for cswap profiles contains an e-mail slug.

  | `CLAUDE_CONFIG_DIR` | `config_key` |
  |---|---|
  | unset or empty | `default` |
  | `$HOME/.claude`, trailing slashes ignored | `default` |
  | last component `^[0-9]{1,4}-`, parent `sessions`, grandparent `.claude-swap-backup` | `cswap-<n>` (no leading zeros) |
  | anything else, as given (no `~` expansion) | `cfg-` + 16 lowercase hex of FNV-1a 64 of its UTF-8 bytes |

- **Chain.** The chain is `--chain-b64`, else `CODD_STATUSLINE_CHAIN`. A given `--chain-b64` wins even when invalid. Both are standard base64, padding optional, and must decode to UTF-8 without NUL. A blank command is no chain.
- **Process behaviour.**
  1. SIGPIPE is ignored, and fds 0–2 are opened on /dev/null if closed.
  2. stdin is read to EOF: at most 1 MiB, within 1000 ms. What arrived is kept if it stops early.
  3. With a chain, `/bin/sh -c <chain>` is started with `posix_spawn`. It gets its own process group (`POSIX_SPAWN_SETPGROUP`) and only fds 0–2 (`POSIX_SPAWN_CLOEXEC_DEFAULT`). stdin is a pipe that receives the same bytes, written non-blocking within 500 ms and then closed. stdout and stderr are inherited.
     - The chain inherits the environment except `CODD_STATUSLINE_CHAIN`, so a chain that runs `codd-statusline` again cannot recurse.
     - SIGPIPE, SIGTERM, SIGINT, SIGHUP and SIGALRM are reset to their defaults, and the signal mask is the inherited one.
     - The chain starts before the report is sent, so the report never delays the user's status line.
  4. The report is POSTed within 300 ms in total (connect, send, read the status), with `LoopbackHTTPClient`. It is never retried.
  5. The chain gets 10 s from its start. Then its group gets SIGTERM (sent again 20 ms later for a member forked meanwhile) and SIGKILL 1 s later if anything of the group is left.
  6. The exit status is the chain's (128 + n for death by signal n), or 0 without a chain and on any failure of our own.
- **Signals.** SIGTERM, SIGINT and SIGHUP are what Claude sends when a newer refresh supersedes a run.
  - The signal is forwarded to the chain's group, and sent again 20 ms later if the group is still there. A process the chain forks while the group is being signalled can miss the first one (seen in tests).
  - The process then waits up to 200 ms for the group to go, without escalating to SIGKILL, and exits 1.
  - A SIGALRM backstop past every budget kills the group and exits 0.
- **Output.** CODD never writes to stdout: without a chain nothing is printed at all. `CODD_HOOK_DEBUG=1` writes one diagnostic line to stderr, for example `codd-statusline: report delivered; chain exited 0`.
- **Test knob.** `CODD_STATUSLINE_TIMEOUT_MS` (1…10000) replaces the 10 s chain timeout. Other values are ignored. It can only shorten the timeout, so an inherited value can never make a status line hold Claude longer. It is meant for tests and is honoured in every build.

## App integration (M1 component 4b)

```swift
let (runtime, load) = try HookRuntime.make(dataRoot: dataRoot)        // config.json; load.origin reports created/repaired
for s in restoredSessions { await runtime.engine.register(s) }       // before start
await runtime.engine.pruneHookStates(keeping: Set(restoredSessions.map(\.sessionID)))
Task { for await batch in runtime.engine.updates { await MainActor.run { store.apply(batch) } } }
do { try await runtime.start() } catch .portInUse(let port) { /* HookHealthProbe.probe(port:) → UI state */ }
// LaunchBuilder(hooks: ClaudeHookSettings(endpoint: runtime.config.endpoint, sessionStartCommand: <codd-hook path>))
// holder WELCOME/EXIT/TITLE → engine.childPidChanged / processExited / ingestTitle
// on quit: await runtime.stop()   (writes pending hook records)

// M4 (I2a): once, after creating the server; survives rebinds and restarts.
await server.setMCPToken(config.mcpToken)                            // also set by Configuration(config:)
await server.setMCPHandler { caller, request in await mcp.handle(caller, request) }
await server.setPromptHandler { sessionID, payload in await expand(sessionID, payload.prompt) }   // PromptHookAnswer?
await server.setNoteURLHandler { id in await notes.urlResponse(id) }  // HTTPRouteResponse
// per session: MCPLaunchConfig(serverName:port:token: MCPAuth.sessionToken(hookToken:sessionID:), sessionID:).write(to:),
// LaunchRequest.mcpConfigPath, ClaudeHookSettings(promptPath: "/hooks/prompt", permissionsAllow: MCPLaunchConfig.allowRules(serverName:))
// rotation: let c = try store.rotateMCPToken(); await server.setMCPToken(c.mcpToken)
```

The app must ship `codd-hook`. Like `codd-holder`, it should be copied out of the bundle to a stable path under the data root, so the SessionStart command baked into running sessions survives app updates and moves. The executable is linked with `-dead_strip_dylibs`: no Foundation load command.

For M3 the app also ships `codd-statusline` (Xcode tool target `Tools/codd-statusline`, the same one-liner as `Tools/codd-hook`, product `CoddHookClient`). It is copied to `<dataRoot>/bin/codd-statusline-<hex12>` for the per-session `--settings` `statusLine`, and to the stable `<dataRoot>/bin/codd-statusline` for the global wrapper (D8, D11). It consumes `HookServer.statusLines` on one task, the stream's single consumer.

Both binaries are 247 KB in release (2026-10-17, SDK 27). `codd-hook` was 144 KB before M3: SwiftPM and Xcode link the `CoddHookClient` library as one pre-linked object, so the linker cannot strip the status-line code out of `codd-hook`. Startup did not change measurably: 2.46 ms against 2.39 ms per run, server down, 300 runs, same session. Splitting the status-line code into its own target would undo the growth, but it changes the product the tool target depends on.

What CODD.app does in M1 (`App/Real/HookPipeline.swift`, `HolderLauncher.swift`): it assembles the server, watcher and engine itself instead of `HookRuntime`, so every event is also read for the answer bar's tool detail before the engine sees it, and it polls `HookServer.statistics()` for the STATUS page. `codd-hook` is embedded as `Contents/MacOS/codd-hook` (Xcode tool target `Tools/codd-hook`, ad-hoc signed as `app.codd.codd-hook`) and copied to `<dataRoot>/bin/codd-hook-<sha256 prefix 12>`; that path goes into `--settings`, and a copy is collected only once no live holder's argv names it.

## Measurements (release, this Mac)

`codd-hook` startup, POST against the real `HookServer`, then exit, measured as a loop of 200 runs from `zsh` (2026-10-16):

| Case | Time per run |
|---|---|
| Delivered | 4.75 ms |
| `/usr/bin/true` (for comparison) | 1.79 ms |
| Server down | 3.05 ms |

Net of process spawn, delivery costs about 3.0 ms.

`codd-statusline` measured the same way (2026-10-17; that run had `codd-hook` delivered at 4.03 ms and `/usr/bin/true` at 1.53 ms):

| Case | Time per run |
|---|---|
| No chain, report delivered | 4.03 ms |
| With a `printf` chain (one extra `/bin/sh`), report delivered | 5.12 ms |
| No chain, server down | 2.24 ms |

The target was under 10 ms per run. The opt-in test that reproduces these numbers is `MeasurementTests` (see its doc comment).
