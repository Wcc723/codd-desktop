# CODD Desktop: M1 report

Written 2026-10-16 after integration step 4b, updated the same day after the M1 review fixes (§8).
M1 = real terminals, real Claude sessions, live states (docs/M1-PLAN.md). It covers the four
components (CoddTerminal, HolderStream, CoddHooks, app integration 4a + 4b), how to run them, the
numbers, what is not done, and what you should try by hand.

**Status:**
- **Builds and tests:** Debug and Release build with zero warnings in our code. App tests 124/124,
  CoddCore 191, CoddHolder 132, CoddHooks 90, CoddTerminal 67 — all green.
- **End to end:** `scripts/m1-e2e.sh` 42/42 (real app, real holder, real hook endpoint, real libghostty,
  fake claude); `scripts/m1-smoke.sh` 22/22 (shell holders, tabs, ⌘J panel, relaunch).
- **Review:** 26 confirmed findings; 24 fixed with regression tests, the GPU-memory budget (F2) and
  the churn footprint (E2E-3) are open (§5, §8).
- **Default mode:** CODD now starts in real mode (Debug and Release) on
  `~/Library/Application Support/CODD`. Mock data only with `-codd-mock` (snapshots, self test).
- **Not yet verified with a real `claude`:** automated runs never start one (quota). The manual checks
  in §6 are what is left for you.

---

## 1. What was built

### Terminal engine: `Packages/CoddTerminal` (libghostty)
- `TerminalEngine` (one per PTY) on libghostty-spm `2.2.2026101301`. Its MIT Swift wrapper is vendored
  (`Sources/GhosttyWrapper`, CODD patches in `Vendor/GhosttyWrapper-CODD.patch`) so replay uses
  `ghostty_surface_write_buffer_replay` directly, no reflection. Key / IME / mouse code is upstream's.
- Feed / replay / reset from any thread in call order; replies suppressed during replay; a size gate so
  a new surface never parses at libghostty's default 800×600 grid; reserved CODD shortcuts (⌘K ⌘1–9 ⌘\
  ⌘J ⌘T ⌘L ⌘, ⌘N ⌘W ⌘Q ⌘⇧[ ⌘⇧], plus ⌃Tab ⌘⏎ ⌥⌘F) go to the menu, also under 注音.
- `TerminalPool` tiers: visible, up to 6 hot (occluded, streaming), cold (disposed, replayed on show).
- `codd-term-demo` for checking the engine alone.

### Holder streaming: `Packages/CoddHolder`
- `HolderStream`: non-blocking client, callbacks on its own queue, replay/live phases, pause/resume
  backpressure, keepalive, exactly-once `onClosed` / `onExit`. Protocol v1 frozen with two
  capability-gated additions (`attach.ack` ATTACHED frame, `gap.resync` GAP modes).
- Flow control threshold min(1 MiB, ring/2) (Ctrl+C under flood ≈ 40 ms instead of ≈ 80 ms).
- `HolderBinaryInstaller`: content-addressed copies under `<dataRoot>/bin`, now with a `namePrefix`
  overload used for codd-hook too (4b; one new package test).

### Hooks: `Packages/CoddHooks`
- `HookServer` (NWListener, 127.0.0.1 only, token / Origin / Host checks, 204 before decoding),
  `config.json` (port 47821 or next free, 32-byte token, 0600), `RegistryWatcher` (FSEvents on
  `<claudeDir>/sessions`), actor `SessionStateEngine` (hooks > registry > holder EXIT > title glyph,
  batches ≤ 10 Hz, per-session records in `hooks/`), and `codd-hook` (Foundation-free SessionStart
  command hook, always exit 0, 2 s budget).

### App 4a: real terminals
- One `PtyConnection` per live PTY; `TerminalHub` feeds engines straight from the stream queue (bytes
  never touch the main actor). CLAUDE tab, `$ ZSH` tab (lazy shell holder), ⌘T new tab, ⌘J bottom
  panel with its own shell, ⌘W closes tab/panel (CLAUDE tab asks), tab layout in `panes.json`.
- Startup probes: a new session's terminal exists (pinned) before its holder starts.

### App 4b: sessions and states (this step)
- **Real mode by default.** `RealModeOptions`: `-codd-mock`; `-codd-data-root` / `CODD_DATA_ROOT`;
  `-codd-claude-dir` / `CODD_CLAUDE_DIR` (registry, transcripts, `.claude.json`; never needed by tests).
  DEBUG: `-codd-claude-path` (fake claude), `-codd-new-claude`, `-codd-dump-state`, `-codd-auto-answer`,
  `-codd-resume-stopped`, `-codd-show status|new-session|home`, `-codd-notifications NO`, plus 4a's.
- **Persisted sidebar.** `layout.json` (CoddCore `LayoutStore`) ↔ the view models (`LayoutMapping`):
  groups → projects → sessions, manual order, colors, pins, collapse, archive, titles, kind, current
  Claude session id, launch options, `lastViewedAt`. Every layout intent (drag reorder, rename, color,
  pin, add/delete group, add/rename/remove project, remove session) saves, debounced; quit flushes.
- **⌘N new-session sheet** (`App/NewSession`): folder field + `選擇資料夾…`, 最近 (CODD projects by last
  activity), 建議 · 來自 ~/.claude.json (folders not added yet, by last use of their transcript
  folder), kind CLAUDE / SHELL, permission mode, model, name, color, a one-line command preview, ⌘⏎ /
  esc. Also from `+ NEW ▾`, a project's or group's context menu, the home page and the menu bar.
- **Empty state / home** (`HomePageView`): `// 還沒有任何 session` + `[+ NEW SESSION ⌘N]` on first
  launch; otherwise `// 沒有選取 session`, counts, NEEDS YOU, LAUNCH 最近專案 with `[+ CLAUDE]`
  `[+ SHELL]`, RECENTLY STOPPED with `[⟲ RESUME]`.
- **Claude launch.** CoddCore `LaunchBuilder`: `--session-id` / `--resume`, per-session hooks
  `--settings` (endpoint from `config.json`, SessionStart = `<dataRoot>/bin/codd-hook-<hex12>`),
  `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` / `CODD_HOOK_URL`, login environment minus the deny-list,
  TERM variables; spawned through the holder. `claude` comes from the login-shell PATH (or
  `~/.local/bin`); when missing the session shows `[ERROR] 無法啟動 · 找不到 claude 執行檔…` with
  `[↻ 再試一次]`.
- **States.** `HookPipeline` hosts HookServer + RegistryWatcher + SessionStateEngine in the app; batches
  drive lamps, NEEDS YOU, the header chip, the answer bar (tool + command / question options from the
  hook's `tool_input`), the rail badge, the Dock badge and the menu bar icon. A session the user is
  looking at never turns DONE (finished in front of them); `lastViewedAt` is persisted so a relaunch
  shows IDLE, not a stale DONE.
- **Degraded mode.** Port taken or listener failed → status bar `hooks ▲ :47821 被其他程式佔用 · 只用
  registry`, hollow menu bar icon, STATUS page `▲ DEGRADED`; never a crash.
- **STATUS page** (rail STATUS): HOOKS (state, endpoint, accepted, rejected by HTTP status, last
  rejection, last event, config / registry / codd-hook paths, polled every 2 s) and DATA.
- **Relaunch.** Live holders reattach; a claude session whose holder is gone is `STOPPED · 可接續` with
  RESUME (`claude --resume <latest hook session_id>`), a shell is `EXITED` with RESTART. RESTART of a
  live session ends it first. Holder EXIT while running → EXITED with the code.
- **Notifications.** `SessionNotifier`: → WAITING / → ERROR of a session the user is not looking at
  (`◆ <title> 需要授權`, `▲ <title> 失敗 · …`, actions 前往 / 稍後). Authorization is asked the first time
  one is due; failure degrades silently. Settings › 通知 NOTIFICATIONS on/off.
- **Answer bar** keys (`1` `2` `3` `ESC`, ⌘⏎ = 1) go to the session's PTY through the store (one path
  for the pane and the menu bar's `[1 允許]`).
- **Remove.** `✕ 移除 session…` / `✕ 移除專案…` confirm; a running session's holder is ended, its
  directory, tabs and hook record go; Claude's transcripts stay.
- **Quit.** Hook records flushed and the port released before the app exits (bounded 2 s); ⌘Q ends an
  open sheet first (AppKit ignores `terminate:` while one is attached).
- `project.yml`: CoddHooks package, `codd-hook` tool target (`Tools/codd-hook`), embedded into
  `Contents/MacOS` and ad-hoc signed as `app.fancycodd.codd-hook`.

## 2. How to run

```bash
# Packages (separate scratch paths avoid lock clashes)
swift test --package-path Packages/CoddCore   --scratch-path .build-core
swift test --package-path Packages/CoddHolder --scratch-path .build-holder
swift test --package-path Packages/CoddHooks  --scratch-path .build-hooks
swift test --package-path Packages/CoddTerminal --scratch-path .build-terminal

# App + tests
xcodegen generate
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test

# End to end (temp data root + temp Claude dir + fake claude; kills its holders at the end)
scripts/m1-e2e.sh            # KEEP=1 keeps the temp root for inspection
scripts/m1-smoke.sh          # shell holders, tabs, ⌘J panel, relaunch

# The app on your real data (what you use day to day): just open it.
open build/dd/Build/Products/Debug/CODD.app
# A throwaway try-out instead (temp data root, your real ~/.claude is still read for recent projects
# and the registry; add -codd-claude-dir to avoid that):
APP=build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
"$APP" -codd-data-root "$(mktemp -d ${TMPDIR}codd.XXXXXX)"
# Mock data (screenshots, self test): "$APP" -codd-mock   /   "$APP" -CODDSelfTest YES
```

Log lines on stdout start with `REALHOLDERS` (`spawned`, `attached`, `state session=… a->b`,
`hook-applied … latencyMs=`, `hooks listening port=`, `error …`).

## 3. Test results (2026-10-16)

| Suite | Result |
|---|---|
| App (`xcodebuild test`) | 124 tests in 28 suites passed (4a's 96 + 18 of 4b: new-session form, `.claude.json` reader, layout mapping round trip, codd-hook references, notification rule and text, hook tool detail, store: hook batches / DONE-while-viewing / persisted layout intents / remove running session / missing claude / state dump, real-mode options; + 10 review regressions, §8) |
| CoddCore | 191 passed (+2 review: nesting bound, top-level key skipping) |
| CoddHolder | 29 + 103 passed (+9 review: straddle pause, takeover ERROR, alternate-screen resync, frame-aligned outbuf, GC in-use mark, chdir message, attach during a full-screen program, allowance) |
| CoddHooks | 83 + 7 passed (+3 review: deep bodies, proven `/health`, queued connections / bursts; the connection-limit test now expects waiting, not a reset) |
| CoddTerminal | 67 passed (+8 review: ordered backlog delivery, replay clipboard filter ×6, deferred disposal) |
| Mock `-CODDSelfTest YES` | `SELFTEST OK` (outline fuzz, ⌘T ⌘W ⌘J, shortcuts, timers) |
| `scripts/m1-smoke.sh` | `SMOKE pass=22 fail=0` |
| `scripts/m1-e2e.sh` | `E2E pass=42 fail=0` (output below; +3 review checks: this run's own port, the bind retried once the port is free, and listening at the end) |

```
E2E states seen by polling: starting idle busy waiting done
E2E ok   the endpoint uses this run's port
E2E ok   session is IDLE/DONE after the turn
E2E ok   Dock badge showed 1 while WAITING
E2E wrong token -> 401
E2E ok   wrong token is rejected with 401
E2E ok   /health answers as CODD
E2E ok   wrong token changed nothing
E2E ok   first-run transitions busy -> waiting -> busy
E2E ok   turn ended IDLE or DONE
E2E ok   answer key went to the PTY
E2E ok   codd-hook installed under bin/
E2E ok   holder installed under bin/
E2E ok   startup probe (DA1) answered
E2E ok   SessionStart ran the installed codd-hook
E2E ok   hooks posted 204
E2E ok   fake claude received key 1 (0x31)
E2E ok   --settings names the installed codd-hook
E2E ok   endpoint counted the 401
E2E ok   endpoint accepted the session's hooks
E2E ok   no attention left
E2E ok   layout.json lists the session
E2E ok   holder survived the quit
E2E ok   holder adopted by launchd (ppid 1)
E2E ok   relaunch discovered the live session
E2E ok   reattached to the same holder
E2E ok   no new holder spawned
E2E ok   replay shows the first run's output
E2E ok   input round-trips after reattach
E2E ok   relaunch shows IDLE, not a stale DONE
E2E ok   same holder still running
E2E ok   dead holder discovered as not live
E2E ok   claude session is STOPPED (可接續)
E2E ok   its Claude session id is kept for RESUME
E2E ok   RESUME spawned claude --resume <id>
E2E ok   fake claude saw --resume
E2E ok   resumed session reached IDLE
E2E ok   resumed claude ran SessionStart through codd-hook
E2E ok   port in use is reported, the app keeps running
E2E ok   session still listed while degraded
E2E ok   the endpoint binds once the port is free again
E2E ok   and reports listening
E2E ok   holder EXIT reached the store
E2E ok   session is EXITED with code 3
E2E pass=42 fail=0
```

The first turn ends DONE rather than IDLE in unattended runs: the app is not the active app there, so
the session counts as unseen. The relaunch then shows IDLE because quitting while it was on screen
recorded `lastViewedAt`.

## 4. Measured numbers (Debug build, this Mac)

| What | Measured | Budget |
|---|---|---|
| Hook received → view model updated (engine batching included) | 0.4–1.5 ms per transition (`hook-applied … latencyMs`) | — |
| `codd-hook` per SessionStart (release, CoddHooks report) | 4.75 ms incl. process start; binary 144 KB release / 197 KB debug | — |
| App footprint, 1 claude session terminal, hook server running | 76 MB (`footprint`) | app base < 80 MB |
| Holder footprint (debug holder) | 1.9 MB; release ≈ 1.55 MB (holder report) | ≤ 2.5 MB |
| Hot session switch (4a) | terminal part 0.12–0.57 ms, whole UI p50 1.19 ms | < 16 ms |
| Quit (hooks flushed, port released) | ≈ 0.6 s from `terminate` to exit | — |

## 5. Known issues

- **No real claude run yet.** Claude's own http hook client was never seen by the endpoint. If it sends
  an `Origin` header or a different `Host`, every hook is refused with 403; the STATUS page's
  REJECTED / LAST REJECTION line shows it. Registry and holder EXIT still drive states then.
- **Notifications** under ad-hoc signing: not tried on screen. `UNUserNotificationCenter` may refuse;
  the code degrades silently (Dock badge and menu bar icon still work).
- **DONE vs IDLE** depends on "looking at it" = shown in the visible main window of the active app.
  A finished turn on a second monitor while another app is active counts as unseen (DONE).
- **New-session sheet subset:** no resume picker (接續先前對話), no account (cswap) or Remote Control
  choice, no launch-profile editor; the profile is always `claude-default` plus the chosen permission
  mode and model.
- **Accounts / usage** in the sidebar footer and menu bar are still the mock `MockAccountStore` (M3).
- `HolderSessionStore.lastError` (e.g. "taken over by another CODD") is only logged, except spawn
  failures, which the pane shows.
- A session whose holder is gone shows a note instead of replaying the ring file from disk.
- Two CODD instances on one data root: the one that connects last takes each holder over at launch;
  the other now ends that connection as taken over (STOPPED · 另一個 CODD 接管) instead of taking it
  back (review fix, §8). There is still no single-instance lock, so which instance shows a session as
  live depends on launch order.
- Recent projects come from `.claude.json` keys plus the modification time of their transcript folder;
  `lastSessionId`-style per-project timestamps are not parsed.
- STATUS shows HOOKS and DATA only; HOST, ACCOUNTS, MCP, REMOTE are later milestones. Settings has only
  通知 implemented.
- The ⌘J panel has one shell (no panel tabs / maximize); tab bells are not drawn (from 4a).
- 注音 / IME, clipboard and the visual answer-bar flow are only covered by unit tests of the engine and
  the e2e input path; they need your hands (§6).

Still open after the M1 review (2026-10-16; what was fixed is in §8):
- **GPU memory while anything animates (review F2, budget broken).** A visible terminal that redraws
  every frame (a busy claude's spinner, a blinking cursor a program asked for) keeps about 230 MB of
  Metal memory resident (`owned unmapped (graphics)`), so CODD sits at about 305–370 MB while a busy
  session is on screen (budget: total < 300 MB). It is allocated inside libghostty's renderer (CODD
  only hosts its IOSurface layer); the steady-cursor default only helps while nothing moves. Needs
  Instruments (Metal allocations) against Ghostty.app with the same spinner, then a renderer setting
  or patch, or a revised budget. To measure: a shell session whose `-codd-shell-argv` prints a spinner
  at 10 Hz, visible, then `footprint <pid>`.
- **Footprint under large-ring churn (review E2E-3) not reproduced.** 9 shells with 3.9 MB of history
  each, cycled cold by `-CODDMetrics` for 12–24 passes, plateau at 305–425 MB on this Mac both before
  and after the fixes (no growth after the first passes; the review saw up to 690 MB). The level is
  still over budget for the same reason as above; the root cause of the review's climb is unconfirmed.
- **Switch thrash with 8 or more terminals in rotation (review F5).** The hot tier is still strict LRU
  of 6 + visible, so cycling more terminals in order makes every switch cold. Freeing the evicted
  surface no longer happens inside the switch (it is deferred, §8); a scan-resistant policy or a
  memory-sized hot tier is a product decision for later. The `-CODDMetrics` switch figure is
  bimodal on this Mac (about 5 ms or 30–45 ms per switch, before and after the fixes alike).
- **Hook endpoint DoS by local accounts (review SEC-4, residual).** Connections past the 64 slots now
  wait instead of being reset and idle sockets lose their slot after about a second, so a burst of
  hooks is served in full. A process that keeps renewing hundreds of idle connections can still delay
  hooks (loopback TCP is open to every local account).
- **Sessions started while the endpoint was ours keep their port.** Their `--settings` name the port;
  if CODD is not running and another program takes it, their hooks (with the token) go there. New
  sessions started while the port is not CODD's run without hooks (§8).
- **Takeover ERROR for a client that stopped reading.** The holder now finishes the partly written frame
  and writes ERROR with up to 500 ms of blocking; a client whose socket buffers are full and that is
  not reading still sees only EOF. PtyConnection handles that (a reconnect without takeover, then
  `busy`), so it only costs one extra connection attempt.
- **No UNREACHABLE state.** A live holder that does not answer (stopped, socket being re-bound) is now
  retried every 10 s instead of being shown STOPPED, but the row keeps its last state meanwhile.
- **Input the holder does not take.** Keys typed while reconnecting are held (64 KiB) and sent after
  the reconnect; keys refused because the child stopped reading its input (16 MiB queued) are still
  dropped silently.
- **Replay clipboard filter covers `ESC ] 52`.** The 8-bit C1 form (`0x9D 52 ;`) is not filtered;
  libghostty decodes UTF-8 first, so a raw 0x9D is not an OSC introducer there.
- **Main screen during a full-screen program (review E2E-4, bounded).** A reattach while vim or less
  runs now also replays the main screen before it, but only when that costs at most 2 MiB more than
  replaying from the program's newest point; a TUI that has drawn more than that since it started
  still comes back with a blank main screen when it exits.
- **Backlog pause (review F1): no extra watchdog.** The race is closed by construction (ordered,
  level-based delivery, applied under one lock); no timer re-checks a paused stream.

## 6. Manual test checklist (for you)

Use a real project. Everything below runs on your real data root unless you pass `-codd-data-root`.

1. **Open & first launch.** Open `build/dd/Build/Products/Debug/CODD.app`. With no data you see
   `// 還沒有任何 session` and `[+ NEW SESSION ⌘N]`, plus your recent `.claude.json` projects.
2. **New session.** ⌘N → pick a project from 最近 / 建議 or `+ 選擇資料夾…`, kind CLAUDE, optionally a
   name and color → `建立 ⌘⏎`. The session appears under its project (未分類), lamp STARTING, then IDLE
   after Claude's SessionStart. STATUS → HOOKS: ACCEPTED > 0, REJECTED 0. If REJECTED shows 403,
   send me the LAST REJECTION text.
3. **注音.** Type Chinese with Zhuyin into Claude's prompt; composition and candidate window should
   behave like Terminal.app. Also ⌘K, ⌘1–9, ⌃Tab, ⌘T, ⌘J, ⌘W while the terminal has focus.
4. **Permission from the answer bar.** Ask Claude to run a shell command. The row goes ◆ WAITING, the
   NEEDS YOU strip, the rail badge and the Dock badge show 1, the menu bar icon's inner square turns
   amber. Press `[1] Yes` (or ⌘⏎) in the answer bar: Claude proceeds, the state goes BUSY, then IDLE.
5. **Notification.** Start another long turn, switch to another app, wait for a permission prompt: a
   macOS banner `◆ <title> 需要授權` with 前往 / 稍後 (first time macOS asks for permission). 前往 opens
   the session. Settings (⌘,) › 通知 turns it off.
6. **Sidebar.** Add a group (`+ NEW ▾` › 新增群組), drag the project into it, rename, color, pin; quit
   (⌘Q) and relaunch: the tree is the same.
7. **Quit / relaunch.** Quit while Claude is working, relaunch: the session is still there, reattached
   (same output, still running). `pgrep -lf codd-holder` shows the holder surviving the quit.
8. **STOPPED · 可接續.** Kill the holder (`kill <holderPid>`, the pid is in STATUS/DATA or `pgrep`),
   relaunch: the session shows ⟲ STOPPED · 可接續; `⟲ 接續對話` resumes the same conversation.
9. **Remove.** Right-click a running session › `✕ 移除 session…`: it asks first, then the holder ends.

## 7. Decisions taken in 4b (reversible)

- codd-hook is copied to `<dataRoot>/bin/codd-hook-<sha12>` and that path (not the bundle's) goes into
  `--settings`; copies are collected only when no live holder's argv names them.
- Group ids are lowercase UUIDs (layout.json `ProjectGroup.id`); the ungrouped bucket is implicit.
- A takeover by another CODD marks a session STOPPED (both kinds; the process still runs elsewhere).
- RESTART of a running session ends it first; RESUME only for sessions that are not running.
- "Looking at it" (no DONE, no notification) = current session in the sessions area of the visible,
  non-minimized main window while CODD is the active app.
- Restored states during the first 5 s after launch never notify.

Taken in the review pass (all reversible):
- A reconnect asks without takeover; `busy` (after one retry 500 ms later) ends the connection as taken
  over. The backoff resets only after a connection held 5 s; after the backoff a live holder is
  retried every 10 s, never shown STOPPED for being unreachable.
- The holder blocks up to 500 ms to deliver ERROR to the client it rejects (single thread; only on
  takeover or a refused connection).
- While the hook endpoint is not this app's, new claude sessions start without hooks and without the
  token; the bind is retried after 2, 3, 5 s, then every 10 s. "Another CODD" needs a correct HMAC
  proof on `/health`.
- Hook connections past 64 wait in the listen backlog; the request head must arrive within 1 s.
- Hook bodies: nesting deeper than 64 becomes `null`; `tool_response` is skipped undecoded.
- Replayed history loses every OSC 52 sequence (writes and queries); live output keeps them.
- The pending prompt detail is stored in `sessions/<id>/answer.json` (0600) while a claude session
  waits; an unknown question shows only `ESC` and `選項沒有收到 · 請在終端機裡選擇`.
- On the alternate screen the resync point is the last main-screen point within 2 MiB (ATTACHED
  carries the current modes, capability `attach.modes`, so REPAINT still happens).
- Evicted terminals are freed 150 ms later, one per main-queue turn.
- A running app holds a shared `flock` on its holder and codd-hook copies; GC skips copies it cannot
  lock exclusively, and a reused copy's mtime is refreshed.
- The notifications setting lives in `UserDefaults` (`CODDNotificationsEnabled`, default on).

## 8. M1 review fixes (2026-10-16)

The review (lenses concurrency/performance, holder stream, security/data, e2e acceptance) confirmed 26
findings. Fixed, most severe first, each with a regression test that fails on the old code where a
test could reproduce it:

| Finding | Fix | Regression test |
|---|---|---|
| SEC-1 (high) a ~2 KB hook body nested 300 deep crashed CODD (stack overflow on the hook queue) | `JSONValue.parse` cuts nesting deeper than 64 to `null` in a non-recursive byte pass before decoding; `tool_response` is skipped without being decoded | CoddCore `deepNestingIsCutBeforeDecodingOffTheMainThread` (SIGBUS without the fix), `nestingPassLeavesShallowDocumentsAlone`; CoddHooks `deeplyNestedBodiesDoNotCrashTheServer` |
| F1 / backlog inversion: pause and resume applied out of order froze a terminal for good | the wrapper delivers backlog crossings one at a time with the state current when they run (vendored `InMemoryTerminalSurfaceAccess`, patch regenerated); `PtySink` applies them under its lock and only from the attached engine; a disposed engine drops its handler | CoddTerminal `backlogTransitionsReachTheHostInOrder` (freezes 3/3 on the old delivery) |
| F3 a title loop saturated the main thread | TITLE / CWD hop to main latest-wins, one hop at a time; per-title / per-cwd log lines only with DEBUG `-codd-verbose-log YES` | app `titleFloodReachesTheMainActorCoalesced`, `relayDeliversTheLatestValueOncePerHop` |
| straddle: a pause in the replay half of a boundary frame dropped its live half without GAP | the live half is always delivered (a pause takes effect after the whole frame) | CoddHolder `pauseInStraddlingFrame` (holes without the fix) |
| takeover ERROR lost while output streamed; two clients fought forever | holder: drop unsent frames, finish the partial one, write ERROR with up to 500 ms of blocking (outbuf kept frame-aligned); client: reconnect without takeover, `busy` → taken over, backoff reset only after 5 s up | CoddHolder `takeoverOfReadingClientDeliversError`, `outbufStaysFrameAligned`; app `reconnectAfterAnUnexplainedCloseDoesNotTakeOver` |
| resync table evicted by alternate-screen clears | a new alternate-screen point replaces the previous one | CoddHolder `alternateScreenClearsKeepMainScreenHistory`, `alternateScreenPointsDoNotEvictMainScreenPoints` |
| SEC-2 replayed OSC 52 overwrote the clipboard | `ReplayClipboardFilter` removes OSC 52 from replays (stateful across chunks and the replay/live boundary; `memchr` fast path, no copy unless one is present) | CoddTerminal `ReplayClipboardFilterTests` (every split point) |
| SEC-3 token and hook bodies sent to a port CODD did not hold; fake `/health` | no hook settings or token unless the endpoint is listening; `/health` challenge with an HMAC proof | app `hookSettingsOnlyWhileListeningAndTheBindIsRetried`; CoddHooks `healthProbeProvesTheTokenAndUnmasksAnImpostor` |
| E2E-1 the bind was never retried | retried after 2, 3, 5 s, then every 10 s | same app test; e2e run 5 frees the port while the app runs |
| E2E-2 pending prompt detail lost on relaunch, `1 Yes 2 No` for unknown options | `sessions/<id>/answer.json` while waiting, restored at discovery; unknown options show only `ESC` and a note; no dangling `·` | app `pendingQuestionKeepsItsOptionsAcrossARelaunch`, `answerBarShowsNoGuessedOptionsAndNoDanglingSeparator` |
| F4 closed tabs / removed sessions leaked their engine, view and sink | detach the engine before the runtime is forgotten | app `shellTabSpawnsLazilyAndClosesWithItsHolder` (engines released) |
| F5 the switch paid for freeing the evicted surface | freed 150 ms later, one per main-queue turn (policy unchanged, §5) | CoddTerminal `evictedEnginesAreFreedAfterTheSwitch` |
| input dropped during a reconnect | held (64 KiB) and sent behind the next HELLO | app `inputHeldWhileReconnectingGoesOutOnTheNextStream` |
| a live holder that missed 6 reconnects was STOPPED (and RESUME killed it) | retried every 10 s while meta.json says it runs | covered by the reconnect test's policy; no deterministic repro |
| GC grace counted from the first install | `markInUse` shared `flock` + mtime refresh on reuse | CoddHolder `garbageCollectionHonoursCopiesInUse` |
| SEC-4 / E2E-5 64 idle sockets blocked hooks; bursts over 64 were reset | listener connection limit (extra connections wait), 1 s head timeout | CoddHooks `connectionsPastTheLimitWaitInsteadOfBeingReset`, `aBurstLargerThanTheLimitIsServedInFull` |
| SEC-5 the e2e ran on CODD's real port range | the e2e writes its own config.json (random 43000–43999, fresh token) | `scripts/m1-e2e.sh` check "the endpoint uses this run's port" |
| SEC-6 profile environment dropped for claude | passed through with the blocked-name rules | app `profileEnvironmentReachesClaudeWithTheBlockedNamesRules` |
| E2E-4 main screen lost when reattaching during a full-screen program | last main-screen point within 2 MiB; ATTACHED carries the current modes (`attach.modes`) | CoddHolder `attachDuringAlternateScreenKeepsTheMainScreen`, `mainScreenPointBeyondTheAllowance` |
| E2E-6 RESUME into a deleted folder: `claude: chdir failed`, code 126 | the holder names the folder; RESUME / RESTART check the folder first (`找不到資料夾：…`) | CoddHolder `chdirFailureNamesTheFolder`; app `resumeIntoAMissingFolderSaysSoAndSpawnsNothing` |
| E2E-7 English errors in the ⌘N sheet | 繁體中文 for what the sheet shows, English kept in the log line | app `sheetErrorsAreInChinese` |

Not fixed: F2 and E2E-3 (measurements inside libghostty's renderer, §5), F5's LRU policy (product
decision), and the residuals listed at the end of §5. Protocol v1 stays frozen: the one wire change is
additive (`attach.modes`, trailing bytes in ATTACHED that v1 receivers ignore), and ARCHITECTURE.md
documents it together with the new resync rule, the ERROR delivery and the hook endpoint changes.
