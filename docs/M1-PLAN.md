# M1 plan — real terminals, real Claude sessions, live states

Goal: CODD becomes usable for daily work on this Mac. At the end of M1 the user can open folders, start Claude and
shell sessions, type into real terminals (libghostty, Zhuyin OK), quit/relaunch CODD without losing sessions, and see
live WAITING / BUSY / IDLE / ERROR states in the sidebar, menu bar and Dock badge.

## Decisions taken (2026-10-16)

| Topic | Decision |
|---|---|
| Terminal engine | **libghostty** via `Lakr233/libghostty-spm` (pinned `2.2.2026101301`). User verified Zhuyin is more stable than SwiftTerm. SwiftTerm is dropped (no fallback code kept in the app; the spike stays in `Spikes/`). |
| Replay on reattach | Call libghostty's C API directly (`ghostty_surface_write_buffer_replay` or equivalent from `GhosttyKit`), no reflection. If the Swift wrapper hides what we need, vendor the MIT wrapper source into `Packages/CoddTerminal/Sources/GhosttyWrapper*` with attribution. |
| Cursor | Steady by default (blinking costs ~225 MiB resident Metal memory). Setting later. |
| `TERM` / `TERM_PROGRAM` | `TERM=xterm-256color` (no xterm-ghostty terminfo dependency), `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION` = libghostty build. |
| Startup probes | A `claude` process is never started without an attached surface; the surface stays attached (may be occluded) at least until the first DA1 reply was written back. Holders do not answer probes. |
| Flow control | Holder pause threshold = min(1 MiB, ring/2) (was 4 MiB; 4 MiB added ~30 ms to Ctrl+C). |
| Holder binary | Copied out of the bundle to `<dataRoot>/bin/codd-holder-<sha256 prefix 12>` before spawning (atomic copy, keep old copies while any holder uses them; GC unused ones at launch). |
| Holder memory budget | Measured as `footprint` (≈1.6 MB), not RSS. |
| Shell state | Claude ended but PTY alive → `SHELL` (SPEC §3). |
| Auto-switch owner | CODD's own policy (CoddCore), skipping accounts whose usageStatus ≠ ok. (Wired in M3.) |
| Claude session environment | Full captured login-shell environment minus a deny-list (`DYLD_*`, `__CF*`, `XPC_*`, Xcode vars, `CLAUDE_CODE_SSE_PORT`, `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `ANTHROPIC_*` only if set by CODD itself…), plus CODD vars. |
| Hook endpoint | `http://127.0.0.1:<port>/hooks`, port fixed per install (default 47821, stored in `<dataRoot>/config.json`, 0600, with a random 32-byte hex token). Headers `X-CODD-Token`, `X-CODD-Session`. In M1 the **app** hosts it (degraded mode); `coddd` takes it over in a later milestone using the same package. |
| Default mode | Real mode is the default; mock data only with `-codd-mock` (screenshots/tests). Real data root default `~/Library/Application Support/CODD`; `-codd-data-root` / `CODD_DATA_ROOT` override (tests ALWAYS use a temp root). |
| Settings location | Inside the main window via the rail SETTINGS item, as in the approved design. |

## Components and contracts

### 1. `Packages/CoddTerminal` (new) — libghostty engine
Depends on `GhosttyKit`/`GhosttyTerminal` (libghostty-spm) and `CoddProtocol`.

```swift
/// Thread-safety: feed/replay may be called from any thread; everything else on the main actor.
@MainActor public final class GhosttyTerminal {          // one per PTY (session tab)
    public init(configuration: TerminalConfiguration)
    public var view: NSView { get }                          // place in AppKit tree
    public nonisolated func feed(_ bytes: UnsafeRawBufferPointer)        // live PTY output
    public nonisolated func replay(_ bytes: UnsafeRawBufferPointer)      // history: engine replies suppressed
    public func reset()                                      // full reset before a resync replay
    public var onWrite: (@Sendable ([UInt8]) -> Void)?       // keys + query replies → PTY (any thread)
    public var onResize: ((TerminalResize) -> Void)?         // cols, rows, pxW, pxH (after layout / font change)
    public var onTitle: ((String) -> Void)?; public var onWorkingDirectory: ((String) -> Void)?; public var onBell: (() -> Void)?
    public var onFirstDeviceAttributesReply: (() -> Void)?   // fires once when a DA1 reply was written (probe policy)
    public var fontSize: CGFloat { get set }
    public func setOccluded(_ occluded: Bool)
    public func focus()
    public func childExited(status: Int32)                   // keeps the screen, shows exit state, allows rebuild
    public func dispose()
}
public struct TerminalConfiguration: Sendable {              // font family/size, CJK fallback, theme colors, cursor style,
    …                                                        // keybinds cleared for app shortcuts (⌘K ⌘1-9 ⌘\ ⌘J ⌘T ⌘L ⌘, ⌘N ⌘W ⌘Q)
}
public final class TerminalPool { … }                        // tiers: visible / hot (LRU ≤ 6, occluded) / cold (no surface)
```
Plus an executable demo target `codd-term-demo` (AppKit window, spawns `zsh -l` through a holder and streams it)
used for manual testing of the package alone.

### 2. `Packages/CoddHolder` — streaming client
```swift
/// Data-plane client for one holder. All callbacks are delivered on the stream's private serial queue
/// (never the main actor). Non-blocking socket, kqueue/DispatchSource based.
public final class HolderStream: Sendable {
    public init(socketPath: String, clientName: String) throws
    public func start(takeover: Bool, attachFrom: AttachPoint)   // .latestResync | .offset(UInt64) | .noAttach
    public var onWelcome / onOutput(offset, bytes) / onGap(from,to) / onTitle / onCwd / onBell / onExit / onClosed / onError
    public func sendInput(_ bytes: [UInt8], submit: Bool)        // INPUT (+ submit flag)
    public func resize(_ r: TerminalResize); func signal(_ signo: Int32); func repaint(); func detach(); func close()
}
```
GAP → the owner calls `terminal.reset()` and re-attaches from the latest resync point. Also: flow-control threshold
change (min(1 MiB, ring/2)), and update `docs/ARCHITECTURE.md` "Holder wire protocol v1" with everything the code
actually does (extra WELCOME/meta fields, ERROR codes, capability names, resync rules, EXIT-before-ATTACH ordering)
— this freezes protocol v1.

### 3. `Packages/CoddHooks` (new) — hook endpoint, registry watcher, state engine
Depends on `CoddCore`.
- `HookServer`: Network.framework `NWListener` on 127.0.0.1 only, minimal HTTP/1.1 (POST `/hooks`, Content-Length,
  ≤ 1 MiB body, keep-alive off), rejects missing/wrong `X-CODD-Token`, any `Origin` header, wrong `Host`; replies
  `204` immediately, then decodes the hook JSON into CoddCore's hook event type. Exposes an `AsyncStream` of
  `(sessionID, HookEvent)`.
- `codd-hook` executable: for hooks that can't be `http` (SessionStart): reads stdin, POSTs to `CODD_HOOK_URL` with
  `CODD_HOOK_TOKEN` / `CODD_SESSION_ID` from env, 2 s timeout, always exits 0, never prints to stdout.
- `RegistryWatcher`: DispatchSource/FSEvents on `~/.claude/sessions/` (injectable path), debounced 100 ms, uses
  CoddCore's tolerant registry reader off the main thread.
- `SessionStateEngine` (actor): per CODD session, combines hook events (primary, CoddCore state machine incl.
  `relaunchBaseline`), registry status, title glyph, holder EXIT → emits `SessionActivity` changes (batched ≤ 10 Hz).
- `HookConfig`: load/create `<dataRoot>/config.json` (port, token) atomically, 0600.

### 4. App integration (sequential, after 1–3)
- 4a Terminal wiring: `TerminalSurfaceFactory` → CoddTerminal; `HolderStream` per visible/hot tab; CLAUDE tab, ZSH tab
  (lazily spawned shell holder in the session cwd), ⌘J bottom shell panel, ⌘T new shell tab; LRU tiers; answer bar →
  `sendInput`; REPAINT on reattach for alt-screen tabs; holder binary copy-out.
- 4b Sessions & states: real mode default; ⌘N new-session sheet (folder picker + recent projects from `~/.claude.json`
  `projects` keys sorted by last use, kind CLAUDE/SHELL, name, optional color); LaunchBuilder → holder spawn with the
  login environment + hooks `--settings`; in-app HookServer + RegistryWatcher + SessionStateEngine → store → sidebar
  lamps, NEEDS YOU, Dock badge, menu bar icon; LayoutStore persistence of groups/projects/sessions (order, colors,
  pins, titles); relaunch → reattach live holders, dead claude sessions become `STOPPED · 可接續` with RESUME
  (`claude --resume <claudeSessionId>`); user notifications for → WAITING / → ERROR when that session is not the
  focused one (UNUserNotificationCenter, Open action).

## Acceptance (automated)
- Package tests green; app tests green; zero warnings.
- E2E (temp data root): app spawns a shell session, stream delivers output to a real GhosttyTerminal, typed input
  (synthesized via the stream API) round-trips, quit → holder alive → relaunch → reattach + replay shows previous
  output; hook POSTs (curl with token) move a session through BUSY → WAITING → IDLE in the store; wrong token → 401
  and no state change.
## Acceptance (manual, by the user)
- Open a real project, start `claude`, type Chinese with Zhuyin, approve a permission prompt from the answer bar,
  see WAITING in the sidebar/menu bar/Dock, quit CODD, relaunch, session still there.
