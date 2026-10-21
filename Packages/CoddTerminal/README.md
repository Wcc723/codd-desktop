# CoddTerminal

CODD's terminal engine on libghostty (component 1 of `docs/M1-PLAN.md`). One `TerminalEngine` per PTY
(a session tab), a shared libghostty app for every surface, CODD's look and key policy, and a
visible / hot / cold pool.

```sh
# from the repository root
swift build --package-path Packages/CoddTerminal --scratch-path .build-terminal
swift test  --package-path Packages/CoddTerminal --scratch-path .build-terminal
swift run   --package-path Packages/CoddTerminal --scratch-path .build-terminal codd-term-demo [--login | --smoke | -- /bin/cat]
# automated runs and measurements: never activates, window behind every other window
… codd-term-demo --background [--force-render --measure <s> --size <w>x<h> --config "<key = value>"] [-- <argv>]
```

- **Products:** `CoddTerminal` (library) and `codd-term-demo` (manual test app).
- **Dependencies:** libghostty-spm `2.2.2026101301` (only its `GhosttyKit` product: the prebuilt
  XCFramework and C header) and DisplayLink `3.0.1`, both pinned `exact`. Nothing from CoddHolder or
  CoddCore.
- **xcodebuild:** `xcodebuild -scheme CoddTerminal-Package -destination 'platform=macOS' build|test`
  works as is. The package has no plugins and no macros, so it needs neither
  `-skipPackagePluginValidation` nor `-skipMacroValidation`. For XcodeGen, add
  `packages: CoddTerminal: { path: Packages/CoddTerminal }` and `- package: CoddTerminal` with
  `product: CoddTerminal` on the app target.

## Public API

| Type | What it is |
|---|---|
| `TerminalEngine` | One terminal (one PTY). `view`, `feed`, `replay`, `reset` (these three from any thread, in order), `onWrite`, `onResize`, `onTitle`, `onWorkingDirectory`, `onBell`, `onFirstDeviceAttributesReply`, `onFontSizeChange`, `onOpenURL` (nil: only http, https and mailto open), `onHoverLink` / `hoveredLink` (the link under the pointer, an OSC 8 target included), `onDesktopNotification`, `fontSize`, `setOccluded`, `focus`, `paste`, `childExited(status:)`, `rebuildForNewProcess()`, `dispose()`, `setOutputBacklogHandler`, `pendingOutputByteCount`, `waitUntilParsed()` / `parsed()`, `readViewportText()` / `readScreenText()`, `rendersWhileWindowOccluded` and the static `rendersWhileWindowOccludedByDefault` (M5 D17, DEBUG `-codd-force-render`: keep drawing in a covered window). |
| `TerminalConfiguration` | Font, fallback fonts, size, colors, cursor, padding, scrollback, reserved key equivalents, image-paste shim, raw extra lines. Renders to a libghostty config (`ghosttyConfigLines`). |
| `TerminalColorTheme` | `#rrggbb` colors; `.phosphorConsole` is the default. |
| `KeyEquivalentPolicy`, `KeyChord`, `KeyModifiers` | Which Cmd shortcuts the terminal leaves to the app. |
| `TerminalRuntime` | The one shared libghostty app: `apply(_:)` a new configuration, `diagnostics(for:)`, `lastConfigurationIssue`, `libghosttyVersion`, `childEnvironment`. |
| `TerminalPool<Key>` | Visible / hot (at most 6 occluded) / cold (disposed) engines. |
| `TerminalTierPolicy<Key>` | The pool's pure policy, a segmented LRU (below): unit-tested without AppKit, with an injected clock. |
| `DeviceAttributesReplyDetector` | Finds the DA1 reply `ESC [ ? … c` across chunk boundaries. |
| `TerminalResize` | Columns, rows and device-pixel size for `TIOCSWINSZ` / holder RESIZE. |

## Why the wrapper is vendored

The M1 decision was: no reflection. The surface needs `ghostty_surface_write_buffer_replay` (added by
libghostty-spm's patch 0011). The Swift wrapper keeps the raw `ghostty_surface_t` internal and has no
replay entry point. Three options were considered:

1. **A public wrapper API.** Release 2.2.2026101301 has none. Changing the pin is a product decision,
   and no newer release was checked.
2. **CODD's own NSView over the C API.** Rejected. It would mean re-deriving about 5,000 lines of key
   translation, `NSTextInputClient`/IME, mouse, selection, scroll, clipboard, drag-and-drop, Metal-layer
   and display-link code. That is exactly the code the user verified with 注音 in the spike.
3. **Vendor the wrapper (chosen).** `Sources/GhosttyWrapper` is libghostty-spm's
   `Sources/GhosttyTerminal` at commit `d403978c6687`:
   - It is the macOS subset: the UIKit files and the resource bundle are left out.
   - Every file carries an attribution header. The MIT notice is in `NOTICE`.
   - The key, IME, mouse and clipboard paths are byte-for-byte upstream.
   - `Vendor/update-wrapper.sh <checkout>` re-vendors and applies `Vendor/GhosttyWrapper-CODD.patch`.
     `--diff <checkout>` regenerates that patch. The script round-trips: re-vendoring reproduces the
     sources exactly.

### CODD's changes to the vendored wrapper

All changes are marked `CODD:` in the source. They are in 8 upstream files plus `CODD/CoddExtensions.swift`:

| File | Change | Why |
|---|---|---|
| `InMemory/InMemoryTerminalSession.swift` | `replay(_:)` enqueues a `.replay` operation, which runs `ghostty_surface_write_buffer_replay`. | Replay without replies, through the same ordered queue as `receive`, under the same teardown guard: a surface is never freed while an operation uses it. |
| `InMemory/InMemoryTerminalPendingOperations.swift` | A new `.replay` case. It is never coalesced with live writes and never trimmed by the 1 MiB detached cap. It is counted in `pendingByteCount`. | A replay starts at a resync point (a full clear or an alt-screen enter). Dropping its first bytes rebuilds the wrong screen. Backpressure must see it, because a reattach streams up to a whole ring through it. |
| `InMemory/InMemoryTerminalSurfaceAccess.swift` | Replay operation, plus the **size gate** (below). | |
| `Surface/TerminalSurfaceCoordinator.swift` | Tells the session which grid the surface was just sized to (`expectGrid`). | Opens the size gate. |
| `Controller/TerminalController.swift` | `initializeRuntimeIfNeeded` changed from private to internal. | Config diagnostics can run without an app. |
| `Configuration/GhosttyRuntimeResources.swift` | No bundled resources. Unsets an inherited `GHOSTTY_RESOURCES_DIR`. | The resources only serve the exec backend, which CODD never uses. An inherited value (CODD started from Ghostty) would point libghostty at another app's files. |
| `Platform/AppKit/AppTerminalView.swift` | The "Copy" title is a literal instead of `Bundle.module`. | No resource bundle. CODD's subclass overrides the menu anyway (「拷貝」). |
| `Surface/TerminalSurfaceView.swift` | Uses the two-parameter `onChange`. | The one-parameter form is deprecated on macOS 14+, so the build stays at zero warnings. |
| `Surface/TerminalSurfaceCoordinator.swift` | `ignoresWindowOcclusion` (M5): the window's reported occlusion is kept but ignored while it is set. | DEBUG measurements (`-codd-force-render`, D17): a background test window sits behind the user's windows, and once AppKit reports it covered nothing would draw. |

**Size gate.** libghostty creates every surface at a default 800×600 px grid. The view's real size
reaches the terminal only after the IO thread's 25 ms resize coalescing.

- **The problem.** Without the gate, everything fed in that window is parsed for the wrong width:
  - At 100+ MB/s, that is typically a whole reattach replay.
  - Absolute cursor moves clamp, and an alt-screen TUI comes out garbled.
  - The PTY first hears the bogus grid (for example 46×16), then the real one 25 ms later.
- **What the gate does:**
  - After a surface attaches, queued output waits until the IO thread reports the grid the coordinator
    sized the surface to, plus a 4 ms settle.
  - The default grid is never reported to the host.
  - If no matching report arrives within 250 ms, the gate opens anyway and the last held size is
    delivered.
- **Tests:** `firstBytesAreParsedAtTheRealGrid`. A replayed `CSI 1;80 H` lands at column 80, a `CSI 18 t`
  fed right after attaching answers with the real grid, and exactly one resize is reported.

## Threads

| Work | Thread |
|---|---|
| `feed` / `replay` / `reset` | The caller (the holder stream's queue). Copies the bytes into the session queue in call order; never blocks. |
| Parsing (`ghostty_surface_write_buffer[_replay]`) | The session's serial output queue (QoS user-initiated), under libghostty's terminal mutex. Never the main thread. |
| Key encoding | Main: `keyDown` → `interpretKeyEvents` (IME first) → `ghostty_surface_key`. |
| `onWrite` (keys, pastes, query replies) | libghostty's IO thread for the surface. Delivered under the engine's sink lock, in order. |
| DA1 detection | In the write sink (IO thread). `onFirstDeviceAttributesReply` hops to main. |
| `onResize` | The IO thread reports the grid right before it reflows. Coalesced into one main-queue delivery carrying the latest size. |
| Title, cwd, bell, font size, URL, notification | Main: libghostty's app mailbox, drained by `ghostty_app_tick` on main. |
| Rendering | libghostty's renderer thread (Metal), paced by DisplayLink. Stops while occluded or while the window is hidden. |

Terminal bytes never touch the main actor or Observation.

## Rules for the app (M1 4a)

**Wiring a session tab:**

- **One engine per PTY.** `TerminalPool` keyed by session tab: `show([visible keys])` returns each engine.
  `isNew` means attach the stream and replay; `onEvict` means detach the stream.
- **Before attaching the stream:**
  - Set `onWrite` (→ `HolderStream.sendInput`). Bytes produced earlier wait, up to 64 KiB.
  - Call `setOutputBacklogHandler(highWater:lowWater:)` to pause and resume reading the holder.
- **Resize:** `onResize` → `HolderStream.resize`. Pixel sizes are device pixels of the text area, as
  libghostty reports them.

**History, gaps and process lifecycle:**

| Situation | What the app does |
|---|---|
| OUTPUT | `HolderStream.onOutput` runs on the stream's queue: pass `.replay` bytes to `replay(_:)` and `.live` bytes to `feed(_:)`, both straight from that queue. |
| Attach from a resync point | A fresh engine is already clean. Pass the attach's mode-restore bytes to `replay(_:)` before the first OUTPUT. |
| GAP | Call `reset()` from the stream's queue: RIS plus erase scrollback, queued after what was already fed and before the resync bytes that follow. Then the modes, as above. Do not hop to the main queue first: the resync bytes would overtake the reset and be wiped. |
| EXIT | `childExited(status:)`. The screen stays; nothing is sent, keys or replies. libghostty is never told, because once it knows it stops encoding keys and asks to close the surface. |
| RESUME / RESTART in the same tab | `rebuildForNewProcess()`: fresh surface, empty scrollback, default modes, the first DA1 reported again. Then attach the new stream. |
| Startup probes (M1 decision) | Before starting `claude`, make sure the engine's view is in a window and call `pool.setPinned(true, for: key)`. Unpin on `onFirstDeviceAttributesReply`. Pinned keys count toward the 6 hot slots but are never evicted. |

**Hot tier (M5 D15, review F5).** `TerminalTierPolicy` is a segmented LRU over the same 6 hot surfaces:
probation 2 + protected 4 (`init(hotCapacity:)` keeps probation at 2; `protectedCapacity:` overrides).

- A hidden terminal enters **protected** when its showing lasted at least 5 s (the user worked in it)
  or when it was revealed from hot (a revisit). A quick flip (< 5 s: ⌃Tab, ⌘K scanning) enters
  **probation**.
- Eviction takes probation's oldest first, protected's oldest only when probation has only pins left.
  A full protected segment demotes its oldest to probation's head.
- So a scan through many terminals churns probation only, and "work in X, glance at A, B, C, back
  to X" keeps X hot. With a capacity of 2 or less it is a plain LRU.
- `hot` lists protected, then probation (each most recently hidden first); `setVisible`, `Changes`
  and `TerminalPool` are unchanged. The clock is an injected monotonic now (`ContinuousClock`).

**Hot views must stay in a window.** `isHidden` is fine; removing them from the hierarchy is not.
libghostty drains titles, bells and other app messages only while at least one surface is attached. A
full app mailbox blocks parsing.

**Configuration and environment:**

- **One configuration for the process.** `TerminalRuntime.apply(_:)` reconfigures every live surface; the
  last one applied wins. A rejected config leaves libghostty on its defaults, so log
  `TerminalRuntime.lastConfigurationIssue`.
- **Child environment:** `TerminalRuntime.childEnvironment`
  - `TERM=xterm-256color` (no Ghostty terminfo needed)
  - `COLORTERM=truecolor`
  - `TERM_PROGRAM=ghostty`
  - `TERM_PROGRAM_VERSION=<libghostty build>`
- **No OSC 7501.** libghostty does not answer it, so Claude Code's `programStatus` stays off. This is
  expected; ignore it.

## Look and keys

**Look.** `TerminalConfiguration.default`:

- **Font:** JetBrains Mono 13 pt with PingFang TC as the CJK fallback.
  - libghostty embeds JetBrains Mono as its own fallback, so the metrics are the same even when the
    family is not installed.
  - The line height is the font's natural one. It does not copy helmet.html's 1.45.
- **Colors:** Phosphor Console (`TerminalColorTheme.phosphorConsole`). Same values as the spike's
  `CoddTheme`, checked against helmet.html's tokens; the mapping is in the doc comment.
- **Cursor:** a steady block. A blinking cursor kept about 225 MiB of Metal memory resident in the
  spike.
- **Layout and buffers:**
  - Padding 16 / 10 pt (helmet.html `.term`, the same as M0's placeholder view).
  - 10 MB of scrollback.
  - `confirm-close-surface = false`.

**Keys.**

- **Reserved for the app:** ⌘K, ⌘1…⌘9, ⌘\\, ⌘J, ⌘T, ⌘L, ⌘, (comma), ⌘N, ⌘W, ⌘Q, ⌘⇧[ and ⌘⇧].
  - The view's `performKeyEquivalent` declines them, so the main menu gets them.
  - If no menu item takes one, `keyDown` passes it up the responder chain instead of encoding it.
    `keyUp` does the same with its release, so a program that asked for key-release events never gets
    a stray one.
  - libghostty's default bindings for them are also unbound, under both the character and the W3C key
    name.
- **Matching:** by character. When the characters are not ASCII (注音 reports `ㄜ` for ⌘K), by ANSI
  key code.
- **Kept in the terminal:** ⌘C, ⌘V, ⌘A, ⌘+, ⌘- and ⌘0 (libghostty bindings).
- **IME is untouched:** only Cmd chords are looked at, and only in `performKeyEquivalent` and before
  `keyDown` hands the event to the wrapper.
- **Image paste:** a plain ⌘V while the pasteboard holds only an image sends Ctrl+V (0x16), because
  Claude Code reads image pastes on Ctrl+V. It is on by default (`pasteImageAsControlV`).

## Performance

Measured 2026-10-16 on an M4 Max, macOS 27.0.1, load average 6–11 (other agents were building). The
window was never ordered on screen, so libghostty parsed but did not render.

| Measure | Debug | Release |
|---|---|---|
| keyDown → `onWrite` (400 keys, p50 / p99 / max) | 0.12 / 0.64 / 4.3 ms | 0.06–0.12 / 0.12–0.63 / 0.8 ms |
| `feed` parse throughput (32 MiB of colored log lines, 64 KiB chunks) | — | 424–435 MiB/s |
| `replay` parse throughput (same bytes) | — | 423–431 MiB/s |

To reproduce:

```sh
CODD_TERMINAL_MEASURE=1 swift test -c release --package-path Packages/CoddTerminal --scratch-path .build-terminal --filter KeyLatency
```

**What the key number covers.** It runs from `view.keyDown(with:)` to the write sink on the IO thread:
the IME pass, libghostty's encoder and its IO-thread hop.

- **Not included:** AppKit's event dispatch before `keyDown` (`NSApp.sendEvent`, `performKeyEquivalent`)
  and the holder hop. The holder hop's p99 is about 20 µs (M0).
- **Comparison with the spike:** the spike's 2.4–3.6 ms p99 went through `NSApp.sendEvent` and ended at
  the PTY write, so it included the dispatch and the write.

**Other numbers:**

- **End-to-end through a real PTY:** the macOS PTY limits it, not the parser. The spike measured
  108 MiB/s; the PTY alone tops out at 146–165 MiB/s.
- **First parse on a new surface:** waits at least the 25 ms resize coalescing (the size gate).
- **Memory:** about 10.8 MiB per extra hidden surface, and 192 MiB for 15 idle sessions with a steady
  cursor (spike numbers; the engine and the shared app are the same).

**GPU memory while a terminal animates (M5, M1 review F2).** Measured 2026-10-18/19 with
`codd-term-demo --background --force-render --measure <s>` (Debug, 900 × 560 pt, Retina; M4 Max,
64 GB, macOS 27.0.1; other agents were building), the window-stack watcher running throughout (0
violations). Footprint = phys_footprint (`footprint`, `vmmap --summary`).

| Case | Footprint | Frames / s | `owned unmapped (graphics)` |
|---|---|---|---|
| quiet `zsh -f` (steady cursor), at 5 s / 35 s | 44 / 38 MB | 0 | 2 MB (120 MB reclaimable at 5 s) |
| 10 Hz spinner | 267–272 MB | 9–10 | 226 MB (27 regions of 8 MB) |
| the same, 450 × 280 pt window | 262–265 MB | 9–10 | same; IOSurface 1.5 MB instead of 6 MB |
| blinking cursor (DECSCUSR 1) | 267–270 MB | 1–2 | as the spinner |
| 60 Hz full-screen flood | 278–280 MB | 88–95 | as the spinner |
| spinner, `window-vsync = false` | 269–272 MB | 9–10 | as the spinner |
| any case, first second after the surface appears | 272–274 MB | — | — |

- **Not libghostty.** A 60-line Metal program with no window and no libghostty, clearing an
  IOSurface-backed texture 10 times a second, shows the same 225 MB in 28 regions of 8 MB (261 MB
  footprint, from 5 MB). `MTLDevice.currentAllocatedSize` says 24 MB (its three textures), so the
  rest is the Metal driver's own per-process pool, not resources anyone allocated. It is the same
  with `maxCommandBufferCount` 1 or 2, a private target texture, a quad drawn with a pipeline, two
  command queues (as two surfaces would have), and at 1 Hz. About 1 s after the last command
  buffer it leaves the footprint (261 → 37 MB within 1.0 s).
- **What it means for CODD:** the pool belongs to the process, not to a surface. Any visible
  terminal that draws at least about once a second (a busy claude's spinner, a blinking cursor, output)
  adds about 225 MB, once. Nothing that draws less often costs it.
- **Settings tried:** CAMetalLayer `maximumDrawableCount` and `allowsNextDrawableTimeout` do not apply,
  because libghostty replaces the view's CAMetalLayer with its own `IOSurfaceLayer` (`MEASURE layer=`).
  `window-vsync = false` changes nothing, and the blinking cursor is already off by default (a program can still ask
  for it). The window size only changes the 1.5–6 MB of IOSurfaces. No change was kept.
- **A covered background window still draws** when it was covered from its first ordering. AppKit posts
  no occlusion change, and the wrapper assumes a new window is visible. The demo's covered window drew
  9–10 frames / s without `--force-render`. `--force-render` (and `-codd-force-render` in CODD) makes
  this explicit for measurements.

## Tests

`swift test` lists 81 tests in 8 suites. The 2 tests in the `KeyLatency` suite are measurements and
are skipped unless `CODD_TERMINAL_MEASURE` is set.

| Suite | What it covers |
|---|---|
| DA1 reply detector | Splits at every chunk boundary, one byte at a time, look-alikes (DA2, DECRPM, kitty) |
| Replay clipboard filter | OSC 52 removed from replays at every split point, a sequence cut at the replay end finished in the live bytes, reset, plain history without a copy |
| Key-equivalent policy | The reserved list, exact modifiers, 注音 key-code fallback, Dvorak, trigger spellings |
| Image-only paste detection | Uses a private pasteboard; the user's clipboard is never touched |
| Terminal tiers (segmented LRU policy) | Capacity and split, dwell and revisit protection, the critique's "three glances" case, scans, eviction order, demotion, pins in both segments, capacity 0 / 1, several visible keys, remove (injected clock) |
| Terminal configuration rendering | Every line, POSIX number formatting, libghostty accepting the whole config, child environment |
| TerminalEngine on a real surface | Real Metal surfaces in a window that is never ordered on screen; see below |

The real-surface suite:

- **Feed and replay:** fed text shows on screen. A replay of 13 startup queries writes 0 reply bytes,
  and the same queries fed live are answered. Feed and replay stay in order, and bytes queued before
  the surface exists are kept.
- **Replay results:** modes come back through a replay: bracketed paste and kitty keyboard flags.
  Bytes fed right after a surface attaches are parsed at the real grid.
- **Lifecycle:** reset clears screen and scrollback, and a reset called from another thread stays in
  order with feed and replay. Child exit stops input until `rebuildForNewProcess`. DA1 fires once per
  process.
- **Keys:** reserved chords are declined and unbound; ⌘C ⌘V ⌘A ⌘= ⌘- ⌘0 stay libghostty bindings.
- **Size and font:** resize and font size reach `onResize`; a settings change reaches live surfaces.
- **Rest:** title, cwd, bell and notification callbacks; backpressure; dispose; the pool's tiers with
  real engines.

They need a GPU (Metal) and a WindowServer session but no visible screen. Set
`CODD_TERMINAL_SKIP_SURFACE_TESTS=1` to skip them.

`codd-term-demo --background` never activates and has no Dock icon (activation policy `.accessory`),
and orders its window behind every other window (`orderBack`), so automated runs never take the
user's focus. Run it with the window-stack watcher (`scripts/tools/zorder.sh start <log>
--exe-prefix <the demo's folder>`). `--force-render --measure <s>` prints `MEASURE t=… footprint_mb=…
frames=…` once a second and exits. Frames are the frames libghostty presented: changes of its layer's
`contents`.

`codd-term-demo --smoke` checks the real PTY round trip and then quits. It prints `SMOKE OK` and exits
0. It covers:

- typing through `keyDown` into `zsh -f`
- disposing and replaying into a fresh surface, with 0 reply bytes
- live output after the replay
- ⌘K left to the app
- `exit`

## Manual checks in codd-term-demo

`swift run … codd-term-demo` opens one window running `/bin/zsh -f`. `--login` runs `$SHELL -l`
instead. The window title follows the program's title. The subtitle shows the grid and the last event.

1. **注音:** type Chinese. The composition shows inline and the commit inserts the text. Try Ctrl+C
   during a composition.
2. **Reserved shortcuts:** ⌘K, ⌘1…⌘9, ⌘J, ⌘T, ⌘L, ⌘\\, ⌘, (comma), ⌘N, ⌘W, ⌘⇧[ and ⌘⇧]. Each one shows
   `<menu item> → app menu` in the subtitle (Session menu), and the shell receives nothing.
3. **Terminal shortcuts:** ⌘C, ⌘V, ⌘A, ⌘+, ⌘- and ⌘0 work in the terminal.
4. **Selection:** select by drag, double-click a word, and right-click a selection for 「拷貝」.
5. **Scrollback:** run `seq 100000` and scroll back with the trackpad.
6. **Resize and title:** resize the window and check that `stty size` follows. `printf '\e]2;hi\a'`
   sets the window title.
7. **Replay:** Terminal ▸ Replay History Into Fresh Surface (⌘⇧R). The screen comes back and the
   subtitle reads `0 reply bytes`.
8. **Exit and restart:** `exit` shows EXITED and keys do nothing. Terminal ▸ Restart Shell starts a new
   shell in the same view, on a fresh surface (`rebuildForNewProcess`).

## Not covered automatically

- **注音 and other input methods:** synthetic key events bypass the IME. The code path is the
  wrapper's own, unchanged; check it by hand in `codd-term-demo`.
- **Copy from a selection and ⌘V of text:** they would touch the user's real clipboard.
- **On-screen rendering:** frame times and keystroke-to-glyph latency need a visible window and
  Instruments.
