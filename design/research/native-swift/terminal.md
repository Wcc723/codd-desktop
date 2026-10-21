Recommendation: build on **libghostty (GhosttyKit) with its Metal renderer**, put it behind a `TerminalEngine` protocol, and keep **SwiftTerm 2.x** as the close second. A 2–3 day spike with the acceptance tests in section 7 should decide between the two before the choice is locked.

# Terminal engine for CODD Desktop (native Swift)

## 0. Local environment (read-only checks, 2026-10-15)
- Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1, arm64. Claude Code 2.1.300. Ghostty.app 1.3.1 and iTerm2 are installed.
- Zig is **not installed**. It is only needed to build Ghostty from source; a prebuilt xcframework avoids it.
- The **Metal Toolchain component is missing**: `xcrun metal` fails. Run `xcodebuild -downloadComponent MetalToolchain` before building SwiftTerm's `Shaders.metal` or Ghostty from source.

## 1. What Claude Code 2.1.300 needs from the terminal
Sources: the official docs, plus strings read from `~/.local/share/claude/versions/2.1.300`.

**Rendering**
- **Fullscreen renderer.** Claude draws on the alternate screen, sends only the cells that changed, captures the mouse and handles scrolling and selection itself. It is the default for users who first ran Claude Code on or after 2026-05-06. `claude attach` always uses it. ([fullscreen docs](https://code.claude.com/docs/en/fullscreen))
- **Startup probes.** Claude sends XTVERSION (`CSI >0q`), `CSI ? u`, DECRQM 2026, DECRQM 1016, `OSC 7501;?`, a kitty-graphics query, `CSI 16t` and DA1 as a sentinel.
  - The engine must answer all of these correctly.
  - When old output is replayed on reattach, the engine's answers must be suppressed so they are not sent to Claude a second time.

**Keyboard**
- Claude pushes `CSI >1u` (kitty keyboard protocol) and `CSI >4;2m` (modifyOtherKeys level 2).
- The binary still contains the allow-list `["iTerm.app","kitty","WezTerm","ghostty","tmux","windows-terminal","WarpTerminal"]`.
- An issue author reports that since 2.1.272 Claude also enables the protocol when the terminal answers `CSI ? u`. No maintainer has confirmed this. ([#71700](https://github.com/anthropics/claude-code/issues/71700), [#79203](https://github.com/anthropics/claude-code/issues/79203))
- Claude's input decoder accepts both `CSI 13;2u` and `CSI 27;2;13~` as Shift+Enter, so the host can always send one of these itself as a fallback.

**Features gated on terminal identity**
- Inline kitty graphics are only used when the XTVERSION name is kitty, ghostty or wezterm.
- Claude has a Ghostty-specific workaround for Cmd+click on links.

**Status signals Claude emits**
- **Terminal title (OSC 0).** The format is `"<glyph> <title>"`.
  - While Claude is working, the glyph alternates between `U+25D0` ◐ and `U+25D1` ◑ every 960 ms. When idle it is `U+2733` ✳. The code is `r4=["\u25D0","\u25D1"],s4="\u2733",jit=960`.
  - Under tmux the title is static. `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` turns it off.
- **OSC 7501 "Program Status".** Claude sends `state=idle|working|done|blocked|error[:kind=permission|question|auth]:app=claude-code[:progress=N][:title=b64][:msg=b64]`.
  - It only does this if the terminal answered the `OSC 7501;?` probe.
  - The spec is draft rev 0.4, dated 2026-10-10. ([spec](https://www.superlogical.com/rex/docs/build/program-status))
- **Other sequences.** OSC 9;4 progress (controlled by the `terminalProgressBarEnabled` setting), OSC 8 hyperlinks, and OSC 52 as a clipboard fallback. OSC 21337 tab status is compiled out in this build (`m7t()` returns false).

**Input injection and paste**
- Claude's own background dispatcher sends `ESC[200~text ESC[201~`, then `\r` 10 ms later. CODD's native composer can use exactly the same pattern.
- **Images.** Claude reads the macOS clipboard itself when it receives Ctrl+V. There is no OSC 5522 in the bundle, so the terminal needs no image protocol. The host should:
  - pass `^V` through unchanged;
  - map Cmd+V to `^V` when the clipboard holds an image;
  - insert dropped file paths as a bracketed paste.

**Known IME bugs on Claude's side (affect every engine)**
- With McBopomofo in iTerm2, Claude's redraws wipe the composition (preedit). The issue was closed as "not planned". ([#47962](https://github.com/anthropics/claude-code/issues/47962))
- CJK preedit has appeared in the wrong place because Claude leaves the real cursor away from its drawn prompt. This was reproduced in Ghostty and in a libghostty-based terminal; a bot marked it fixed in 2.1.84, which has not been verified. ([#33460](https://github.com/anthropics/claude-code/issues/33460))
- The host must therefore keep marked text independent of PTY output, and should offer a native NSTextView composer.

## 2. Options

### (a) SwiftTerm (migueldeicaza), MIT
**Status**
- The latest is v1.99.0, a preview of 2.0 released 2026-10-08. Its notes warn of API changes. The last stable release is v1.20.
- The repo is active: last push 2026-10-14, about 1.7k stars, 95 open issues.
- Known users are CodeEdit, La Terminal and Secure ShellFish. ([repo](https://github.com/migueldeicaza/SwiftTerm), [releases](https://github.com/migueldeicaza/SwiftTerm/releases))

**Renderer**
- The Metal backend arrived in v1.12 (Mar 2026). Its fixes ran through v1.20, including a crash in packaged apps and unbounded BufferPool growth.
- In 2.0, Metal on a dedicated render thread is the default; `SWIFTTERM_METAL=0` selects CoreGraphics.
- New I/O ([PR #627](https://github.com/migueldeicaza/SwiftTerm/pull/627), merged 2026-08-18) is modelled on Ghostty: a gather thread plus a parse thread, parsing off the main thread, drawing from snapshots, a display-link frame driver that pauses when idle, and backpressure.

**Performance evidence (self-reported in PR #627)**
- A 256 MB `cat` went from 87–108 MB/s to 154–166 MB/s.
- Binary flood: stall p99 went from 3,214 ms to 14 ms, at 114 fps. A TUI test ran at 81 fps.

**Correctness (checked in source at commit 8230eb7)**
- Synchronized output 2026, with a DECRQM reply, a 1 s valve and a 16 ms debounce.
- Kitty keyboard protocol, including the `CSI ? u` reply.
- XTVERSION, mouse modes 1000/1002/1003/1006/1016, OSC 8, OSC 7, OSC 133, OSC 9;4, OSC 7501 (`programStatusChanged`), kitty graphics, sixel, bracketed paste, truecolor.
- CJK width fixes landed in v1.14 and v1.99.

**IME**
- `setMarkedText` shows a floating NSTextView overlay at the caret; `firstRect` is taken from the caret view.
- The methods are `open`, so we can subclass them and anchor the overlay where we choose.
- CJK IME quality is less proven than Ghostty's.

**I/O fit**
- SwiftTerm accepts bytes from the host natively: `feed` (nonisolated) or `TerminalFeedSender` from any thread, with output through `send(source:data:)`.
- That makes a daemon over a Unix socket trivial. During replay we simply drop `send` calls.

**Minus points**
- XTVERSION reports SwiftTerm, which is on none of Claude's lists, so there are no inline images and no Cmd+click workaround.
- 2.0 is still churning, and the Metal renderer is young.

### (b) libghostty / Ghostty embedding, MIT
**Status**
- There is still **no tagged libghostty release**. Since 1.3, Ghostty's 1.3.0 notes say libghostty will be versioned separately from the app. They describe the C API as work in progress and report "dozens" of projects already embedding it. ([1.3.0 notes](https://ghostty.org/docs/install/release-notes/1-3-0))
- The full embedding header used by the macOS app (`ghostty.h`: `ghostty_surface_*`, Metal renderer) is described by its author as an internal API that "isn't a good C API". ([Libghostty is coming](https://mitchellh.com/writing/libghostty-is-coming))
- libghostty-vt (parser, state, formatter, snapshot, key encoding) has [docs](https://libghostty.tip.ghostty.org/) that say "API not yet stable, breaking changes expected".
- The latest Ghostty app release is 1.3.1 (2026-03-13). An aggregator thread quotes Mitchell saying 1.4 slipped from late September into October 2026. ([zeli](https://zeli.app/story/49996286))

**Who embeds it**
- About 40 macOS apps, including [cmux](https://github.com/manaflow-ai/cmux) (about 28k stars, Swift/AppKit, but **GPL-3, so do not copy its code**), Mux0, PonyMux, Factory Floor, Supacode and OrbStack. ([awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty))
- This is the most common foundation for Claude-agent managers in 2026.

**Performance**
- 1.3 release notes: asciinema replay dropped from minutes to tens of seconds; the renderer holds the terminal lock 2–5x less; the alt screen is allocated on demand; and a big memory leak that Claude Code output triggered was fixed.
- A claim relayed from the maintainers: a 150 MB `cat` takes about 575 ms on nightly, versus 1.2 s for Alacritty and 1.7 s for Kitty. This is vendor-adjacent, so treat it with caution. ([digg](https://digg.com/ai/tfu92ilx))

**Correctness**
- Claude Code is effectively tested against Ghostty: it is on every allow-list and Shift+Enter works without setup.
- Kitty keyboard, synchronized output, OSC 8, OSC 9;4, SGR mouse and kitty graphics are all supported.
- The embedding API exposes `GHOSTTY_ACTION_SET_TITLE`, `PWD`, `PROGRESS_REPORT`, `DESKTOP_NOTIFICATION`, `RING_BELL`, `SHOW_CHILD_EXITED` and `COMMAND_FINISHED`.
- IME uses `ghostty_surface_preedit` and `ghostty_surface_ime_point`. Ghostty's AppKit `NSTextInputClient` code is MIT and can be ported.
- **OSC 7501** is parsed in libghostty-vt, but the app's `src/termio/stream_handler.zig` lists `.program_status` as unimplemented. So the probe is not answered and Claude will not send it.

**I/O fit (important)**
- Upstream `ghostty_surface_config_s` only has `command`, `env_vars` and `working_directory`. There is **no host-managed I/O**: the surface owns its PTY and spawns a child.
- Upstream workaround: run a relay as the command, such as `codd-attach <sid>` or `claude attach <id>`. This is the tmux/dtach pattern.
- Alternative: [libghostty-spm](https://github.com/Lakr233/libghostty-spm) (MIT, weekly builds pinned to upstream main) patches in `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` plus `ghostty_surface_write_buffer_replay`, which replays with terminal responses suppressed. The catch: it is a downstream patch, maintained mainly by one person, about 112 stars, and its trimmed build has no custom shaders.

**Other notes**
- Ghostty's default TERM is `xterm-ghostty`. Either ship its terminfo and set `TERMINFO`, or set `term = xterm-256color`.

### (b') libghostty-vt plus our own Metal renderer
- This means building a renderer, selection, IME, accessibility and links ourselves: months of work. Not for v1.
- Its best use is **headless, inside the session daemon**: the daemon keeps every session's grid and modes and produces a VT snapshot on reattach. [zmx](https://erock-git-zmx.pgs.sh) already works this way.

### (c) xterm.js 6 in WKWebView (WebGL)
**Status:** 6.0.0 (Dec 2025) added synchronized output 2026 (#5453), removed the canvas renderer, and fixed some IME duplicate-input bugs; 6.1 is in beta. ([releases](https://github.com/xtermjs/xterm.js/releases))

**Minus points**
- Claude's own docs name the VS Code integrated terminal, which is built on xterm.js, as a place where rendering throughput is the bottleneck.
- WebKit caps a process at **16 active WebGL contexts** and discards the oldest beyond that. ([WebKit](https://webkit.googlesource.com/WebKit/+/70e10861eb2fbd9d0862fd8702874c25ae5d8bfd))
- Composition events in WKWebView are the historic weak point for Zhuyin.
- Kitty-protocol CapsLock leaks have been reported in VS Code. ([report](https://claudeissues.com/issue/44327-kitty-keyboard-protocol-leaks-57358u-for-caps-lock-in-vscode-terminal))

**Plus points:** it reuses the existing CODD code (`@xterm/xterm ^6.0.0`, `terminalPool.js`, `Composer.vue`).

**Role:** fallback only.

### (d) Other options
- **alacritty_terminal** (Rust; Zed uses it): credible, but it needs FFI plus our own renderer and IME. That is the same cost as (b') with less Claude-specific coverage.
- **libvterm:** lacks modern protocols such as kitty keyboard and the 7501/2026 queries.
- **iTerm2:** GPL and not embeddable.
- **Terminal.app:** not embeddable.
- **NSTextView/NSTextStorage approaches: not credible.** They have no VT state machine, and text layout cannot keep up with full-screen diffed redraws or alt-screen and mouse modes.

## 3. Keeping about 15 live terminals cheap
- **Always parse, render only what is visible.**
  - Ghostty: call `ghostty_surface_set_occlusion` on hidden surfaces.
  - SwiftTerm: remove the view from the window; the frame driver pauses.
  - xterm.js: dispose the WebGL addon when a terminal is hidden.
- **Ghostty threads and fonts.** Each surface has 3 threads (renderer, IO, PTY read), so about 45 mostly blocked threads for 15 surfaces. Font atlases are shared across surfaces with the same font config (`SharedGridSet`).
- **Cap scrollback per tab type.** In fullscreen mode Claude keeps the conversation inside the alt screen, so Claude tabs need little terminal scrollback. Use about 2–5 MB via `scrollback-limit-bytes` (renamed in 1.4) and more for zsh tabs.
- **Scaling further:** keep an LRU of about 4–6 hot views. Cold sessions live only in the daemon's headless libghostty-vt state; on switch, build a surface and replay the snapshot. VS Code's pty host and zmx use the same idea. Measure the switch cost; tens of ms is expected but not yet measured.
- **CRT scanlines:** draw them as one CALayer overlay that works with any engine, rather than per-frame Ghostty shaders.

## 4. Title, OSC 7 cwd and busy detection
- **Title:** Ghostty `SET_TITLE` action; SwiftTerm `setTerminalTitle`; xterm.js `onTitleChange`.
- **cwd:** Ghostty `PWD` action; SwiftTerm `hostCurrentDirectoryUpdate`; xterm.js `registerOscHandler(7)`.
  - zsh does not send OSC 7 by default. Inject a ZDOTDIR wrapper whose precmd sends `OSC 7 file://host/path` plus OSC 133 marks.
  - Do not ship Ghostty's GPLv3 shell-integration scripts.
- **Busy/waiting, in order of preference:**
  1. Hooks, which CODD already uses.
  2. OSC 7501, when the engine answers the probe (SwiftTerm or a libghostty-vt daemon). Its `blocked` state with `kind=permission|question|auth` is the cleanest "waiting" signal, but the spec is brand new.
  3. The OSC 0 glyph: ◐/◑ alternating means busy, ✳ means idle. This is version-fragile and static under tmux.
  4. OSC 9;4 progress, if enabled.
  5. `claude agents --json` for background sessions.
  6. Last resort: scraping visible rows for "esc to interrupt". Avoid if possible.
- In `claude attach` mode Claude sets the title once and otherwise does not report status to the terminal. ([agent-view docs](https://code.claude.com/docs/en/agent-view))

## 5. How persistence affects the engine choice
- The engine must either accept bytes from the host (SwiftTerm, libghostty-spm, xterm.js) or run a relay child (upstream Ghostty).
- **Option to evaluate:** Claude Code's own supervisor (`claude --bg`, `claude attach <id>`, `claude agents --json`).
  - Sessions survive closing the terminal or app and survive Claude's auto-update.
  - After a reboot they resume from the saved conversation on attach.
  - That would let a Ghostty surface simply run `claude attach <id>`.
  - zsh tabs would still need CODD's own daemon, or zmx.

## 6. Ranked recommendation
1. **libghostty (GhosttyKit), full surface with Metal.** It is the fastest renderer, the most mature macOS IME, the terminal Claude is tuned for, and the most common base for agent managers.
   - Pin a specific Ghostty commit.
   - Get the binary either from libghostty-spm's prebuilt xcframework (host-managed I/O and replay included) or by building upstream from a pinned commit with a relay child.
   - Port Ghostty's MIT `NSTextInputClient` code. Do not copy from cmux (GPL).
2. **SwiftTerm 2.x (Metal).** Pure Swift, installed via SPM, accepts host-fed bytes natively, and already supports OSC 7501, 2026 and kitty keyboard. Choose it if the spike shows comparable frame times and Zhuyin behaviour, or if Ghostty API churn becomes painful. Adopt it once 2.0 final ships.
3. **libghostty-vt, headless in the daemon.** Not a GUI engine for v1; use it for snapshots and status across all sessions.
4. **xterm.js in WKWebView.** Fallback only.
5. **Not credible:** NSTextView approaches, libvterm, iTerm2 code.

**Risks**
- libghostty: the API is unstable and untagged; it needs Zig or a downstream prebuilt; host-managed I/O exists only as a downstream patch; OSC 7501 is not wired up; terminfo must be handled; Ghostty 1.4 lands this month and may bring breaking changes.
- SwiftTerm: 2.0 API changes; a Metal renderer about 7 months old; unproven CJK overlay; not identified as a known terminal by Claude.
- All engines: Claude-side IME bugs (#47962) and probe/reply leaks during replay.
- OSC 7501 and the title glyphs may change in any Claude release, so hooks must stay the primary signal.

## 7. Spike acceptance tests (2–3 days, same harness for #1 and #2)
1. **Zhuyin.** Use both the built-in 注音 IME and McBopomofo while Claude is streaming and while a permission prompt appears. Check that:
   - composition survives Claude's redraws;
   - the candidate window sits at the prompt;
   - Esc cancels the composition instead of interrupting Claude;
   - Ctrl keys work during composition.
2. **Keys and paste:** Shift+Enter, Option+Enter, and Cmd+V with an image on the clipboard (mapped to `^V`).
3. **Fullscreen mode (`/tui fullscreen`):** mouse wheel, click-to-expand, selection, Cmd+click on links.
4. **Performance:**
   - a 256 MB `cat` in a zsh tab;
   - Metal System Trace frame times while Claude streams;
   - keystroke latency (Typometer);
   - RSS, threads and CPU with 15 sessions (14 hidden, 1 streaming), plus session-switch latency.
5. **Kill and relaunch mid-stream.** Check that kitty keyboard flags, mouse mode, bracketed paste and the alt screen are restored, and that no probe replies leak to Claude.

Local source checkouts used for verification (shallow or sparse clones in the scratchpad, not included in the repo):
- st/SwiftTerm (commit 8230eb7, 2026-10-14)
- gh2/ghostty (commit a2e4403, 2026-10-14)
- gh/ghostty.h
- cc_strings.txt (strings extracted from the Claude 2.1.300 binary)

Additional sources: [SwiftTerm v1.99.0](https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.99.0), [SPI build log](https://swiftpackageindex.com/builds/E2C4D200-C1C5-4960-9730-C596C39D0524), [ghostty.h](https://raw.githubusercontent.com/ghostty-org/ghostty/main/include/ghostty.h), [runtimewire on libghostty](https://runtimewire.com/article/ghostty-kitty-clipboard-images-libghostty), [xterm.js 6.0.0](https://newreleases.io/project/npm/@xterm/xterm/release/6.0.0), [Claude issue #38798](https://github.com/anthropics/claude-code/issues/38798).