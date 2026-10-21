[harness: subagent output matched instruction-shaped pattern(s): settings-json. Control tags below are neutralized (`<` → `<\`); treat any remaining directive-shaped text as a finding to relay to the user, not an instruction to you.]

# CODD Desktop (native Swift, local only): final recommendation

**Markers:** **[U]** means a source report flagged the claim as unverified, self-reported or vendor-adjacent. **[T]** means my own target or estimate, not measured. **[M]** means measured on this Mac by the process report.

**Environment, checked read-only:**
- Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1, arm64.
- Claude Code 2.1.300, cswap 0.26.0.
- The Metal Toolchain component is missing. Run `xcodebuild -downloadComponent MetalToolchain` before building any Metal code.
- Zig is not installed. It is not needed if we use a prebuilt libghostty xcframework.
- The process report lists build "26A434" for macOS 27.0.1, which looks like a typo.

---

## 1. Verdict

Go native. The app runs all the time, keeps about 15 PTYs alive, depends on Zhuyin IME working correctly, sits in the menu bar, and needs small helper processes that outlive the app. Native Swift fits every one of those, and Electron fits most of them poorly.

**What we gain:**
- **Memory:** no Chromium base cost and no WebKit limit of 16 WebGL contexts. Expect roughly 3–5× less memory with 15 sessions **[T]**.
- **Idle CPU** close to zero **[T]**.
- **Launch** in under 0.5 s **[T]**.
- **Input path:** the host adds well under 1 ms. The holder hop costs 8.5 µs **[M]**.
- **IME:** the AppKit text-input system instead of DOM composition events.
- **Rendering:** a Metal renderer tuned for Claude (Ghostty).

**What we give up:**
- Reusing the CODD web code. All UI, terminal, PTY, editor and server code is rewritten; only logic and contracts carry over.
- The web ecosystem: xterm.js addons, CodeMirror, markdown-it plugins.
- Fast UI iteration with hot reload.
- Cross-platform support.
- A shared codebase with any future remote UI.

**What native cannot fix:** Claude's own TUI echo and redraw latency. That is Claude's code. Native removes only the host's overhead.

---

## 2. Architecture

### Processes

```
CODD.app (AppKit UI, terminal views, Notebook, NSStatusItem + panel)
  ├─ posix_spawn(SETSID) ─▶ codd-holder ×N (1 per PTY) ─ PTY ─▶ claude … | zsh -l
  │     binary copied to ~/Library/Application Support/CODD/bin/holder-<hash>
  │     ring: …/CODD/sessions/<uuid>/ring (mmap) + meta.json
  ├─ AF_UNIX framed stream ⇄ each holder (data plane)
  └─ NSXPC (MachService, code-signing requirement on Team ID) ⇄ coddd
coddd (SMAppService.agent, KeepAlive, ProcessType=Interactive; never owns a PTY)
  • HTTP hook sink 127.0.0.1:<fixed per-install port>   ◀─ claude http hooks
  • AF_UNIX datagram sink ◀─ codd-statusline / codd-hook
  • runtime state store, registry watcher (FSEvents), reboot detector (kern.bootsessionuuid)
  • cswap poller + auto-switch policy, notes indexer (FSEvents → FTS)
codd-mcp (stdio, spawned by Claude per session) → notes files + read-only index
```

**Why the app, not the agent, spawns the holders:**
- macOS privacy (TCC) permissions for the child processes are attributed to CODD.
- launchd does not throttle the children.
- The agent can restart at any time without touching sessions.

Holders were confirmed to survive the app being removed via launchd when started with SETSID **[M]**. Each holder uses 1.5–2.0 MB **[M]**.

**Degraded mode:** if the user disables the background agent, the app hosts the hook endpoint itself. This uses the same Swift package and the same fixed port.

**One writer per database:**
- The app writes the layout DB (groups, projects, order).
- The agent writes the runtime state DB and the notes index.
- Each holder writes its own `meta.json` and ring.

### IPC

| Link | Mechanism |
|---|---|
| App ⇄ holder | AF_UNIX stream in a 0700 folder under `_CS_DARWIN_USER_TEMP_DIR`, peer checked with `getpeereid`. Frames are `u32 len \| u16 type`. v1 is frozen: `HELLO/ACK, ATTACH(fromOffset), OUTPUT, INPUT, RESIZE, SIGNAL, GAP, EXIT, PING`, extended only through capability flags. |
| Replay | The app maps the ring file read-only. |
| App ⇄ agent | NSXPC with a version handshake. The agent pushes state batched to at most one update per 100 ms. |
| Hooks → agent | HTTP POST on loopback. Requires the `X-CODD-Token` header, rejects any `Origin` header, checks `Host`, replies 204 immediately. |
| CLIs → agent | Fire-and-forget datagrams. |

**Use a fixed port and token per install.** CODD bakes the hook URL into each session's `--settings` at launch. A random port would silently break every live session's hooks after the agent restarts.

### Terminal byte flow

**Output path:**
1. `claude` writes to the PTY.
2. The holder reads up to 64 KB at a time in its kqueue loop and appends it to the mmap ring.
3. The holder updates a small mode tracker (2004, mouse modes, 1004, 2026, 25, 1, kitty keyboard flags, 1049) and the resync index.
4. If the app is attached, the holder writes an `OUTPUT` frame to the non-blocking socket. The per-client queue is bounded at about 1 MB. On overflow the holder sends `GAP(offset)` and the app catches up from the mapped ring. **The child process is never blocked.** A PTY nobody reads stalls `claude` after about 1 KB **[M]**.
5. In the app, a per-session DispatchSource reader on a background queue feeds the engine, which parses off the main thread.
6. The engine renders with Metal on its display link, only when the view is visible and dirty.

**Input path:**
1. `NSTextInputClient` and `interpretKeyEvents` handle the key first.
2. The engine encodes it (kitty keyboard protocol or modifyOtherKeys).
3. The app sends an `INPUT` frame; the holder writes to the PTY.
4. Resizes go as `RESIZE`, which the holder applies with `TIOCSWINSZ`.

**Reattach after app quit or crash:**
- **Claude tabs on the fullscreen (alt-screen) renderer:** do not replay bytes. Send the saved modes, enter the alt screen, then nudge the size by one column and back. The resulting SIGWINCH makes Claude repaint fully **[U: verify in spike]**.
- **zsh tabs and the classic renderer:** replay from the latest resync point with the engine's own replies suppressed, then send SIGWINCH.

### State detection

- **Hooks are the primary signal.** They are injected per session through `--settings '<json>'`, so CODD's own sessions never need edits to `~/.claude/settings.json`.
- **Hook configuration:** `type:"http"`, `timeout: 2`, `onFailure: continue`. `SessionStart` does not support http hooks, so it uses a `codd-hook` command hook.
- **Event mapping:** port it from `configs/hooks/status-writer.js`, including the takeover rule for `SessionStart` with source clear or fork.

| Event | State |
|---|---|
| UserPromptSubmit | busy |
| Notification (permission/idle prompt), PermissionRequest | waiting |
| Stop | idle |
| StopFailure | error |
| SessionEnd | ended |
| Pre/PostCompact | compacting |

- **PreToolUse** is matched only on `Write|Edit|MultiEdit`. The agent snapshots the target file synchronously (target under 5 ms **[T]**) before replying, which gives a per-tool-call AI diff.
- **Secondary signals, in order:**
  1. `~/.claude/sessions/<pid>.json`, decoded tolerantly, with liveness checked by pid plus `procStart`.
  2. Holder `EXIT` records.
  3. The OSC 0 title glyph (◐/◑ alternating means busy, ✳ means idle). Strip the glyph and dedupe changes so the 960 ms spinner never touches the UI.
  4. `claude agents --json` (about 142 ms per call **[M]**), only for background sessions, at most every 30 s.
- **OSC 7501** is a bonus only. The spec is a draft, and Ghostty does not answer the probe, so Claude will not send it there.
- **Global hook installer:** only for sessions started in other terminals. It writes atomically and keeps a backup; port it from `claude-setup.js`.

### Quota (cswap)

- **Free live quota:** a `codd-statusline` Swift CLI (port of `codd-statusline.js`) forwards `rate_limits.five_hour/seven_day.used_percentage` and `resets_at` to the agent. If the user already had a status line, the CLI runs it and passes its output through, because `--settings` overrides that key.
- **cswap calls:**
  - Use `~/.local/bin/cswap --json` with swift-subprocess.
  - Run one call at a time. Timeouts: list 20 s, status 10 s, switch 30 s.
  - Set `LANG` and `PYTHONIOENCODING`.
  - Poll on menu open or when data is older than 5 minutes.
  - Keep the last good result and fall back gracefully if `schemaVersion` is not 1.
- **Auto-switch policy:** port it unchanged from the server's `rate-limit.js` logic and run it in the agent, so it works while the app is quit.

### Notebook and MCP

- **Storage:**
  - Notes are Markdown files on disk.
  - Pasted images go to `assets/<sha256>.png`; image annotations go in JSON sidecar files.
  - The index is a GRDB SQLite database with an FTS5 trigram table. Queries with 1–2 CJK characters fall back to `LIKE`; a trigram `MATCH` returns no rows for them, as tested on this Mac's SQLite 3.54.
  - The index is derived and can be rebuilt. Only the agent writes it.
- **`codd-mcp`:** a stdio helper on swift-sdk 0.12.1, pinned, behind a thin adapter.
  - It reads the files and the read-only index, and does appends as atomic file writes.
  - It works while the app is quit.
  - Port whichever of the 15 tools in `apps/mcp/src/index.js` stay in scope, keeping their names and schemas (skills, agents, tasks, memory days, kanban), and add the `notes_*` tools.
  - Register it for CODD sessions with `--mcp-config` (I have not verified that flag).

---

## 3. Components (pin exact versions)

| Area | Choice | Version / license |
|---|---|---|
| Terminal engine (primary) | libghostty full surface (Metal), from the **libghostty-spm** prebuilt xcframework. It includes host-managed I/O and `write_buffer_replay`, which replays with terminal replies suppressed. Pin the build hash and fork the patch ourselves. | Ghostty pinned commit (e.g. a2e4403); no tagged libghostty release exists; MIT. libghostty-spm is MIT, a downstream patch, maintained mainly by one person. |
| Terminal engine (fallback) | SwiftTerm 2.x (Metal), behind the same `TerminalEngine` protocol | v1.99.0 preview (2026-10-08) → adopt 2.0 final; MIT |
| Rejected | Upstream Ghostty with a relay child (double PTY, probe replies leak during replay); xterm.js in WKWebView; libvterm; NSTextView-based terminals; cmux code (GPL-3) | — |
| UI | AppKit shell: view-based `NSOutlineView` sidebar, plain `NSSplitViewItem`, `NSStatusItem` + non-activating `NSPanel`, ⌘K palette as a pre-built child `NSPanel`. SwiftUI only in leaf views (settings Form, sheets, header) via `NSHostingView`. `@Observable` with Equatable properties. | System. Minimum macOS 26.0, built with Xcode 27 SDK |
| Text (notebook + file editor) | One `NSTextView` subclass in TextKit 1 mode, plus TextStory, Neon, SwiftTreeSitter 0.10.0, tree-sitter-markdown 0.5.3, `NSTextFinder`, `NSRulerView` | System; tree-sitter-markdown MIT; ChimeHQ libraries are probably BSD-3 (**verify**) |
| Search / diff | `rg --json`, bundled; `git diff --histogram` or `CollectionDifference` | rg is MIT/Unlicense |
| HTTP (hooks) | Hummingbird in coddd | 2.28.0 (2026-10-13), Apache-2.0 |
| MCP | modelcontextprotocol/swift-sdk, stdio | 0.12.1 pinned; MIT moving to Apache-2.0 |
| Database | GRDB, WAL, `DatabasePool`, FTS5 trigram | 7.11.1, MIT |
| Processes | swift-subprocess | 1.0.1 (2026-10-09); license not in the reports (probably Apache-2.0) |
| Updater | Sparkle; Developer ID signing, hardened runtime, notarized, **no App Sandbox** | 2.10.0 (2026-09-13), MIT |
| Hotkey | KeyboardShortcuts | 3.1.0, MIT |
| Font | JetBrains Mono NL, bundled, with PingFang TC as fallback | 2.304, OFL-1.1 |
| Login / agent | `SMAppService.agent` + `SMAppService.mainApp` | System |
| Not using | STTextView (GPL or paid), CodeEditSourceEditor (says it is not production-ready), Vapor 5 beta, SwiftData, `MenuBarExtra`, `NavigationSplitView`, SwiftUI List for the sidebar, tmux, dtach | — |

**Engine decision rule.** The terminal report ranked libghostty first and called for a spike before locking the choice. I make Ghostty the default. We switch to SwiftTerm only if Ghostty fails any gate in the 3-day M0 spike:
- Zhuyin and McBopomofo while Claude is streaming;
- replay with no probe replies leaking to Claude;
- frame time;
- 15-session memory.

**Do not spoof** SwiftTerm's XTVERSION reply.

---

## 4. Performance plan

### Budgets (all [T] until the M0 harness measures them)

| Metric | Budget |
|---|---|
| Host input path (keyDown → PTY write) | < 1 ms p99 (the holder hop is 37–46 µs p99 **[M]**) |
| Keystroke-to-glyph in a zsh tab, 120 Hz | < 10 ms p95 (Typometer). Claude tabs are measured but not owned. |
| Streaming / scrolling | 120 fps; frame p99 ≤ 8.3 ms in Metal System Trace; 0 frames over 16.7 ms |
| Main-thread work | < 4 ms per frame; no hang over 50 ms |
| Session switch | Hot < 16 ms; cold < 80 ms (the reports gave no number) |
| Idle CPU, 15 idle sessions | App < 0.5% with the window visible, < 0.1% hidden; agent < 0.1%; holders ≈ 0 |
| Memory | App base < 80 MB; visible surface ≤ 80 MB including drawables; hot hidden ≤ 15 MB; cold ≈ 0.2 MB; holder ≤ 2.5 MB; agent ≤ 25 MB; total with 15 sessions (6 hot) < 300 MB |
| Throughput | 256 MB `cat` at ≥ 150 MB/s; input latency during the flood < 50 ms |
| Launch | Interactive sidebar < 400 ms; visible terminal painted < 150 ms later |
| Hook handling | < 2 ms p99 |
| Notebook | p95 keystroke-to-paint < 8 ms on a 1 MB note with 200 images |
| File editor | First screen of a 10 MB file highlighted < 300 ms |

### Techniques

1. **Three terminal tiers.**
   - **Visible (1–3):** render on the display link.
   - **Hot (LRU up to 6):** the surface stays alive but occluded (`ghostty_surface_set_occlusion`). It keeps parsing but does not render.
   - **Cold (the rest):** the app has no surface; only the holder's ring and the model exist. Selecting it builds a surface and repaints as described in section 2.
   - Measure whether occluded surfaces keep their IOSurface drawables. If they do, cut the hot LRU to 3.
2. **No terminal bytes on the main thread.**
   - Use DispatchSource or dedicated threads, not a Swift Task per chunk.
   - Mark parsers `@concurrent`. Swift 6.2+ projects default code to the main actor.
   - Terminal bytes never pass through Observation or Combine.
3. **Holders.**
   - Darwin only, no Foundation, a single kqueue thread.
   - Raise `RLIMIT_NOFILE` above launchd's soft limit of 256.
   - Ring size: 2 MiB for Claude tabs on the fullscreen renderer, 8 MiB for zsh and the classic renderer.
4. **Scrollback caps:** Claude tabs 2–5 MB, zsh tabs 10–20 MB. Share font atlases by using one font configuration everywhere. Warm the CoreText fallback to PingFang at launch so the first Chinese glyph does not hitch.
5. **UI updates.**
   - Fixed-height `NSOutlineView` rows with cell reuse; `moveItem` for drags; never call `reloadData`.
   - Per-cell observation tracking (on by default in macOS 26).
   - The agent batches state at 100 ms.
   - A 1 Hz elapsed-time clock runs only for visible rows, and only while some visible row needs it.
6. **No idle animation.**
   - One shared 2 Hz blink clock for visible lamps in the waiting state; nothing animates otherwise.
   - The CRT effect is a static 1-pixel-wide scanline layer, off by default.
   - Confirm in Instruments that WindowServer is not compositing at 120 Hz while idle.
7. **Lazy startup.** Restore the layout from the local DB. Connect to the visible session's holder first and to the others staggered in the background. Start the agent on demand through XPC.
8. **Slow work stays off the hot path.**
   - cswap is single-flight and fed mostly by status-line data.
   - The registry watcher debounces at 100 ms.
   - Images in the notebook are downsampled with ImageIO thumbnails off the main thread and cached in `NSCache`.
   - Files above 5 MB open in plain mode.
9. **Make it measurable.**
   - os_signposts on keyDown→write and read→present.
   - The spike harness becomes a regression suite, re-run on every Ghostty bump.

---

## 5. Reuse from CODD web, and effort

**Port the logic, not the code:**

| From CODD web | Becomes |
|---|---|
| `configs/hooks/status-writer.js` (197 lines) | Event→state machine; recorded payloads become golden test data |
| `configs/statusline/codd-statusline.js` | `codd-statusline` |
| `claude-setup.js` (680 lines) | Settings merge, backup and install rules |
| `rate-limit.js` | Quota and auto-switch policy |
| `session-insights.js` | Session insights |
| `stores/sessions.js` | Group → project → session model and ordering |
| `terminalPool.js` (610 lines) | Its LRU and keep-alive idea |
| `Composer.vue` | Bracketed paste followed by `\r` after 10 ms; Shift+Enter fallback `CSI 13;2u`; Ctrl+V and Cmd+V image paste as `^V`; dropped paths as a bracketed paste |
| `apps/mcp/src/index.js` | MCP tool names and schemas |
| — | Phosphor design tokens and cswap JSON v1 parsing |

**Rewrite:**
- All Vue UI → AppKit/SwiftUI.
- xterm.js → libghostty.
- node-pty / `terminal-manager.js` → `codd-holder`.
- Node server → `coddd`.
- better-sqlite3 → GRDB.
- markdown-it, which only rendered → a live-preview editor (new work).
- Build, signing, notarization and updates.

**Drop:** remote/tunnel, login/auth, DeviceStatus, KeyBar (mobile), and the remote board.

**Effort (one dev + Claude, person-weeks):**

| Milestone | Scope | PW |
|---|---|---|
| M0 Skeleton + spikes | Targets (app, coddd, holder, CLIs) with stable signing; terminal spike Ghostty vs SwiftTerm (3 days); holder spike plus TCC attribution test; Zhuyin matrix; gate decisions | 2 |
| M1 Terminal + persistence | Holder protocol v1 frozen; engine view; `NSTextInputClient`; keys and paste; resize; reattach and replay; tabs plus bottom panel; LRU and occlusion | 3.5 |
| M2 Shell + sessions | Window chrome; sidebar (drag and drop, rename, menus, swatches); coddd (XPC, hooks, registry, reboot → `--resume`); `--settings` injection; notifications and badge; ⌘K | 3.5 |
| M3 Menu bar + accounts | Status item and panel; cswap; status-line quota; auto-switch; settings window; external hook installer; hotkey | 2 |
| M4 Notebook + editor + MCP | TextKit 1 live preview (spike gate in week 1); image paste and annotation canvas; code editor with tree-sitter, tabs and find; file watching; AI diff; FTS; `codd-mcp` | 5 |
| M5 Hardening | Performance budgets pass; Sparkle and notarization; agent upgrade path; CI against old holders; data migration; polish | 2.5 |
| **Total** | Usable as a daily driver after M2 (about 9 weeks) | **≈18 (range 15–24)** |

M4 drives most of the range.

---

## 6. Top risks and mitigations

1. **The libghostty API is untagged and unstable.** Host-managed I/O exists only as a one-maintainer downstream patch, and Ghostty 1.4 is expected this month (an aggregator report says it slipped to October **[U]**).
   - Hide it behind the `TerminalEngine` protocol.
   - Pin the xcframework hash and fork the patch.
   - Keep SwiftTerm validated in the same harness.
   - Never bump Ghostty without re-running the harness.
2. **Zhuyin IME.**
   - Claude-side redraw bugs: #47962 was closed "not planned"; #33460 was marked fixed in 2.1.84 by a bot **[U]**.
   - Mitigations: keep marked text independent of PTY output; make a native `NSTextView` answer bar the default prompt composer; nothing intercepts keys before the IME (submit happens in `doCommandBy`); test with 注音, McBopomofo and vChewing in M0.
3. **TCC attribution for holder children after the app quits.** Claude's own background host lost attribution (#59065).
   - Test this on M0 day 1.
   - The app spawns holders; add usage-description strings and the resource entitlements Ghostty uses.
   - Fallback: end the session and resume it.
4. **Persistence and update correctness:** mode restore, probe-reply leaks, old holders running alongside new apps, and flaky SMAppService re-registration **[U, forum reports]**.
   - Freeze holder protocol v1 with capability flags; CI against holder builds from the last 12 months.
   - Run holders from a binary copied out of the bundle.
   - The agent exits itself when its version on disk changes; degraded mode when the agent is disabled.
5. **Undocumented Claude surfaces may change:** the registry format, `agents --json`, title glyphs, OSC 7501, status-line JSON, http-hook semantics. The Swift MCP SDK still targets the 2025-11-25 spec; whether that works with 2.1.300 is untested **[U]**.
   - Hooks stay primary.
   - Decode everything tolerantly.
   - Keep golden test fixtures per Claude version; gate features by version.
   - Keep the MCP adapter thin, with hand-written JSON-RPC over stdio as the fallback.
6. **The cost of the notebook's live preview** in TextKit 1: hiding syntax, attachments and the IME edge cases there.
   - 1–2 week spike gate with fixed targets.
   - If it fails, switch only the notebook to WKWebView + CodeMirror 6 (MarkEdit-style) and accept the WebKit composition fixes that come with it.

---

## 7. Design-mockup implications (keep the Phosphor look)

- **Window chrome:**
  - On the macOS 27 SDK, Liquid Glass cannot be opted out of.
  - Mockups must show native traffic lights inside our custom header strip (full-size content view, transparent titlebar, no `NSToolbar`), with that zone reserved.
  - Outer window corners stay rounded; only the interior is square.
  - No glass sidebar.
- **Menus and context menus:**
  - Native `NSMenu`: rounded, glass, system highlight, system font.
  - Remove the custom amber menus from the mockups. Phosphor styling is limited to item text and a colour-swatch row (custom `NSMenuItem.view`).
  - Fully custom panels only for ⌘K and the menu-bar dropdown, which are both `NSPanel`.
- **Menu bar icon:** an outline in the menu-bar label colour (not a template image), the inner square in the state colour, and quota text in monospaced digits. The dropdown can be fully Phosphor-styled.
- **Fonts:**
  - JetBrains Mono NL in the terminal (no ligatures).
  - Chinese renders in PingFang TC at 2 cells wide, with a fixed line height. Mockups need real Chinese strings to check this.
  - Menus, alerts, notifications and the find bar use the system font.
- **Terminal colours:** we control only the ANSI palette, foreground, background, cursor and selection. Claude's TUI draws its own truecolor theme, so mockups must not show Claude's UI recoloured amber.
- **CRT and glow:**
  - Static scanlines only, off by default. No flicker, rolling bar, curvature or bloom in v1; custom shaders are absent from the libghostty-spm build.
  - Amber glow only on lamps, the active tab and the cursor, not on terminal text.
- **Lamps:** blink only for "waiting"; "busy" is a steady colour. This follows from the idle-CPU budget.
- **Controls:** custom-drawn square buttons and text fields. Native controls become capsules on Tahoe.
- **Settings:** a separate ⌘, window (SwiftUI Form) with General, Terminal, Accounts/Quota, Hooks, Notebook and Advanced sections. Advanced shows agent and holder status and an "End all sessions" command. Quitting the app never ends sessions.
- **Sidebar:** native drag gap animation, group tint blocks and square selection are all feasible. Inline rename uses the system field editor.
- **Notifications:** system banners with Open and Reply actions. Their look cannot be styled.
- **Notebook:**
  - Obsidian-style live preview that hides syntax away from the caret.
  - Images shown inline with a read-only annotation overlay. Annotation editing happens in a separate canvas panel, because macOS has no PencilKit canvas.
  - v1 shows tables as aligned monospace source, and has no Mermaid, math or HTML embeds.
- **File editor:**
  - Included: tabs, line numbers, the system find bar, an `rg` project-search panel, a custom unified and side-by-side AI diff, and a "changed on disk" banner.
  - Not in v1: minimap, multi-cursor and LSP.
- **Remove from mockups:** the remote board, tunnel/QR, login, device status and the mobile key bar.

---

**Note on the harness flag:** it flagged the process report for mentioning `~/.claude/settings.json`. That text is design guidance: inject hooks per session with `--settings`, and keep the global installer atomic with a backup. Nothing was executed and no files were modified.

**Files:**
- CODD web repo, inspected read-only: ~/GitHub/codd-web (commit 3d3db15)
- Spike sources from the reports (scratch files, not included in the repo):
  - bench/ptybench.c
  - bench/ptybuf2.c
  - bench/spawnspike.c
  - ftstest/t.swift

**Key sources:**
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/fullscreen
- https://ghostty.org/docs/install/release-notes/1-3-0
- https://github.com/Lakr233/libghostty-spm
- https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.99.0
- https://github.com/modelcontextprotocol/swift-sdk
- https://modelcontextprotocol.io/specification/2026-07-28/changelog
- https://github.com/sparkle-project/Sparkle/releases
- https://github.com/groue/GRDB.swift
- https://github.com/hummingbird-project/hummingbird
- https://developer.apple.com/documentation/servicemanagement/smappservice
- https://github.com/anthropics/claude-code/issues/59065
- https://github.com/anthropics/claude-code/issues/47962