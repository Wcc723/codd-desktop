# Research: Apple remote connection options and desktop stack for CODD Desktop

**Short answer:** the "Apple remote connection" the user heard about is most likely **Claude Code Remote Control**, which drives a session on the Mac from the Claude iPhone app. It's Anthropic's, not Apple's, and it needs no Apple Developer account. The Apple features people confuse it with (iPhone Mirroring, Sidecar, Handoff, Live Activities) either run in the wrong direction or need a native iOS app. **Recommended stack: Electron 44 with the CODD Vue 3 + xterm.js + node-pty code reused.**

---

## TASK A: What "Apple's remote connection" probably means

### Ranking of likely meanings
1. **(a) Claude Code Remote Control.** It was widely covered in Feb 2026 and is what people mean by "control Claude Code from my iPhone." Most likely.
2. **(b) Apple Continuity: iPhone Mirroring, Sidecar, Handoff, Universal Control.** These are Apple features with "remote" in the marketing.
3. **(f) Screen Sharing or "Back to My Mac".** Older Apple remote access.
4. **(c), (d), (e), (g)** are ways to *build* a companion app, not things the user would have heard of.

### (a) Claude Code Remote Control: what is confirmed
- **What it is:** the Claude iOS/Android app (Code tab) or claude.ai/code acts as a window into a `claude` process on the Mac. Execution, files and MCP servers stay local. The Mac makes outbound HTTPS calls only and opens no inbound ports. The transcript is stored on Anthropic's servers while connected.
- **How to start it:**
  - `claude --remote-control "Name"` (alias `--rc`) starts an interactive session that is also remote.
  - `/remote-control` (alias `/rc`) inside a session that is already open.
  - `claude remote-control` is server mode. Its flags: `--name`, `--spawn same-dir|worktree|session`, `--capacity <N>` (default 32), `--permission-mode`, `-c`/`--continue`, `--session-id`, `--remote-control-session-name-prefix`. The env var `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX` does the same as the prefix flag. In server mode, pressing spacebar shows a QR code.
- **Settings keys the desktop app can write:**

  | Key | Effect |
  |---|---|
  | `remoteControlAtStartup` | Auto-connect new sessions. A `true` in project settings is ignored; a `false` is honoured. |
  | `disableRemoteControl` | Turns Remote Control off everywhere. |
  | `agentPushNotifEnabled` | "Push when Claude decides" |
  | `inputNeededNotifEnabled` | "Push when actions required" |
  | `dialogExpiry` | How long forwarded dialogs wait for an answer. |

  Env var `CLAUDE_CLIENT_PRESENCE_FILE`: while that marker file exists, phone pushes are skipped. The app can create it while the screen is unlocked or the app is in front.
- **Requirements and limits:**
  - Pro, Max, Team or Enterprise plan, signed in to claude.ai. API keys don't work, nor do Bedrock, Agent Platform, Foundry, or an `ANTHROPIC_BASE_URL` pointing elsewhere.
  - It stops working if `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK` is set.
  - The workspace must be trusted.
  - Outside server mode, each process carries one remote session.
  - The `claude` process must keep running.
  - Some commands work only in the local terminal (`/plugin`, `/resume`).
  - On the phone, Bypass permissions can't be selected.
  - Trusted Devices (beta) can require device enrolment plus Face ID or Touch ID.
- **Feasibility:** high, and no Apple account is needed. The desktop app only spawns `claude` with `--remote-control "<Group>/<Session>"`.
- **Caveat with account switching:** a session shows up only in the claude.ai account that its `CLAUDE_CONFIG_DIR` is logged into. After a cswap-style switch, the phone must be signed into that same account. Getting the session URL out of PTY output to show a QR code is fragile; check it during implementation.
- **Where it shows in the UI:**
  - Session header: a "Remote" chip with a green dot when online, a QR button, and a copy-URL button.
  - Sidebar row: a small phone glyph.
  - Settings → Remote & Mobile:
    - "Connect new sessions to Remote Control" (writes `remoteControlAtStartup`)
    - Two push toggles
    - "Don't push while I'm at this Mac" (presence file)
    - Session-name prefix
  - Menu bar popover footer: "N sessions reachable from phone."

### (b) Apple Continuity features

| Feature | What it does | Fit | UI impact |
|---|---|---|---|
| iPhone Mirroring (macOS 15+, not in the EU; macOS 27 adds resizable windows) | The Mac controls the iPhone | **Wrong direction.** It does not control the Mac from the phone. | None |
| Live Activities in the Mac menu bar (macOS 26+) | Live Activities from the iPhone appear in the Mac menu bar. No code changes needed; needs the same Apple Account and iPhone Mirroring. | **Wrong direction.** I found no Mac-native ActivityKit. | It would duplicate our own menu bar item, so plan to dedupe. |
| Sidecar direct input (new in macOS 27) | Tap and scroll on an iPad used as a second display | The only built-in way to touch the Mac app from an iPad. Zero work. | Keep hit targets of 28pt or more and don't rely on hover |
| Universal Control | Shares keyboard and mouse between devices at the same desk | Not remote | None |
| Handoff (`NSUserActivity`) | Picks up an activity on another device | Cheap win. Electron has `app.setUserActivity(type, userInfo, webpageURL)`, so the iPhone can open the claude.ai/code URL (or the tunnel URL) in Safari. | Settings toggle "Handoff active session" |

### (c) Native companion over the local network
- **How it works:** the Mac advertises a Bonjour service (e.g. `_codd._tcp`). The iOS app finds it with `NWBrowser` or `NetworkBrowser`, then talks over WebSocket or QUIC.
- **Pairing:** a QR code shown on the Mac carries host, port and a one-time token or public key.
- **iOS needs** `NSLocalNetworkUsageDescription` and `NSBonjourServices` (with `_codd._tcp`).
- **Multipeer Connectivity** is built on Bonjour. It adds peer-to-peer Wi-Fi and Bluetooth, but it's a weaker fit for streaming bytes.
- **Wi-Fi Aware** (`com.apple.developer.wifi-aware`, `WiFiAwareServices`) is documented for **iOS 26 only**, so it can't be used on the Mac.
- **Limits:** works on the same network only, so remote use needs Tailscale or a tunnel. Distributing the iOS app needs the paid Developer Program (free provisioning runs about 7 days, and TestFlight requires the paid program).
- **UI:** Settings → Paired Devices: a list showing name, model, last seen, a revoke button, and "Pair new device." The pairing modal shows a large QR code, a 6-digit code and an expiry countdown.

### (d) Push notifications and CloudKit
- **Accounts:** Personal Team does **not** support Push Notifications or iCloud. Both need the paid Apple Developer Program (US$99/yr).
- **APNs:**
  - The Mac app can send to `api.push.apple.com` itself with token auth (a .p8 key). That's fine for a personal build. A distributed build should send through a small relay such as a Cloudflare Worker, so the key isn't shipped inside the app.
  - Waiting alerts can use the time-sensitive entitlement (`com.apple.developer.usernotifications.time-sensitive`).
  - Approve/Deny buttons in a notification need a way back to the Mac (LAN, Tailscale, or a relay).
- **CloudKit:** a private database plus `CKDatabaseSubscription` works for syncing session state and quota snapshots. It is too slow for terminal streaming.
- **Alternatives with no Apple account:**
  - Remote Control's own pushes (`inputNeededNotifEnabled`). This is the fastest win.
  - Web Push to the CODD web app saved to the iPhone Home Screen (iOS 16.4+, HTTPS, manifest).
  - ntfy, Pushover or Bark.
  - The Telegram, Discord or iMessage Channels plugins. Telegram and Discord are already installed on this machine.

### (e) Live Activities and Dynamic Island
- **Where they live:** only on the iPhone. A companion app adds a widget extension using `ActivityAttributes`, `ActivityConfiguration`, `DynamicIsland` (compactLeading/Trailing, minimal) and `LiveActivityIntent` buttons.
- **Updates:** sent by APNs with `apns-push-type: liveactivity`. Push-to-start and broadcast push exist; check the exact APIs in the ActivityKit push docs.
- **New in iOS 27:** `.supplementalActivityFamilies([.small])` for Apple Watch and CarPlay, and `isDynamicIslandLimitedInWidth`.
- **Requirements:** paid Developer Program and a native Swift widget target.
- **Side effect:** on macOS 26+, the activity also appears in the Mac menu bar automatically, so it can duplicate our own menu bar item. Either suppress it while the Mac app is running or accept the duplicate.
- **Mockup:** compact view = CODD glyph on the left, orange waiting count on the right. Expanded view = the top 3 sessions with state dots and an Approve button.

### (f) Screen Sharing, Back to My Mac, Tailscale
- **Back to My Mac** was removed in macOS Mojave (2018). That is from memory; I didn't re-check it.
- **Screen Sharing** (VNC, port 5900) needs a third-party client on the iPhone, such as Screens or Jump Desktop. High Performance mode is Mac-to-Mac only: Apple silicon on both, macOS 14+, UDP 5900–5902, about 75 Mbps for 4K. It works, but it's clumsy on a phone.
- **Tailscale** (recommended path to remote access):
  - `tailscale serve <port>` publishes the app's embedded server at `https://<device>.<tailnet>.ts.net`, reachable only inside the tailnet. `funnel` would make it public.
  - The sandboxed macOS client can't serve files or folders (port proxying is fine).
  - CODD already ships the other option: a Cloudflare named tunnel (`npm run tunnel` → `configs/cloudflared.yml`, root `package.json`) with Google ID-token auth (README line 3).
- **UI:** Settings → Remote Access: provider [Off | Tailscale | Cloudflare Tunnel], health dot, URL, QR code, auth mode.

### (g) Apple APIs from 2026
- **App Intents in macOS 27:**
  - Entity schemas and intent schemas, the View Annotations API, AppIntentsTesting.
  - `LongRunningIntent`, which runs past the 30-second limit and shows progress as a Live Activity.
  - `CancellableIntent`, `ExecutionTargets`, `SyncableEntity`, `@UnionValue`.
- **Limits:**
  - In a WWDC26 Q&A, Apple said there is no API for one app to call another app's intents; Siri and Shortcuts do that.
  - ExecutionTargets only picks a process on the same device.
  - Nothing says an iPhone can run intents that live in a Mac app.
  - **MCP in App Intents** has only been seen in iOS 26.1 / macOS 26.1 beta code (Sept 2025). WWDC26 didn't confirm it.
- **Foundation Models:** now accepts any model through the Language Model protocol, with Claude and Gemini named as examples. Not needed for this app.
- **Practical uses:**
  - Mac Shortcuts actions: "Waiting sessions," "Send prompt," "Approve." These need Swift. In Electron, use a `codd://` URL scheme or a CLI instead.
  - With no app work at all, the iPhone Shortcuts action "Run Script over SSH" can reach the Mac over Tailscale and call a `codd` CLI.

### Suggested phases for the "Remote & Mobile" area
- **Phase 0 (v1, no Apple account):** Remote Control integration, Handoff `webpageURL`, Remote Control push toggles, the presence file.
- **Phase 1:** embedded CODD server reachable over Tailscale or Cloudflare. The existing CODD web UI becomes the phone client as a Home Screen app with Web Push. Add pairing by QR code.
- **Phase 2 (US$99/yr):** native SwiftUI iOS app with Bonjour discovery, Tailscale as fallback, APNs actionable notifications, and a Live Activity.

### Session state signals for the status indicators
- `claude agents --json --all` is documented as the supported way to read session state from outside Claude Code. The docs say not to parse `~/.claude/jobs/<id>/state.json`.

  | Field | Values |
  |---|---|
  | `state` | `working`, `blocked`, `done`, `failed`, `stopped` |
  | `status` | `busy`, `waiting`, `idle` |
  | `waitingFor` | `permission prompt`, `input needed`, `sandbox request`, `worker request`, `dialog open` |

  Other fields: `kind`, `sessionId`, `pid`, `cwd`, `name`.
- **UI labels and colours from agent view:** Working (animated), Needs input (yellow), Idle (dimmed), Completed (green), Failed (red), Stopped (grey). Its row groups are Pinned, Ready for review, Needs input, Working, Completed.
- **Notification hook matchers for hook install:** `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_*`. Plus the `Stop`, `SessionStart`, `SessionEnd` and `UserPromptSubmit` events.

---

## TASK B: Desktop tech stack

### What CODD code can be reused (from `~/GitHub/codd-web`)
- **Server dependencies** (`apps/server/package.json`): `@homebridge/node-pty-prebuilt-multiarch ^0.12.0`, `better-sqlite3 ^12.10.0`, `express ^4.21.0`. The first two are native Node modules.
- **Web dependencies** (`apps/web/package.json`): `vue ^3.5.10`, `@xterm/xterm ^6.0.0`, `@xterm/addon-fit ^0.11.0`, `pinia`, `vuedraggable ^4.1.0`, `vite ^5.4.8`.
- **PTY:** `apps/server/src/services/terminal-manager.js`. Spawn is at line 196, `subscribe()` at line 347, and the scrollback replay buffer at line 360.
- **Streaming routes:** `apps/server/src/routes/sessions.js`. SSE stream `GET /:id/stream` at line 98, `POST /:id/input` at line 166, `/:id/resize` at line 183.
- **Size of the Node services that would need rewriting** in a non-Node stack: system-stats 316 lines, claude-setup 680, session-insights 498, terminal-manager 401.

### Comparison

| | **Electron 44** (latest stable 44.7.2, Oct 14 2026, Chromium 152, Node 24.21) | **Tauri 2** (tauri 2.12.3, Oct 10 2026) | **Native SwiftUI + SwiftTerm** (SwiftTerm v1.99.0, a preview before 2.0) | **Hybrid: SwiftUI shell + WKWebView + Node helper** |
|---|---|---|---|---|
| Reuse of Vue + xterm.js | Full | Full (but runs in WebKit) | None; rewrite | Session pane only |
| node-pty / better-sqlite3 | Works natively (VS Code uses node-pty). Needs `@electron/rebuild` for Electron's Node version. | No Node runtime. Either rewrite in Rust (`portable-pty`; `tauri-plugin-pty` is early-stage) or ship a Node sidecar, where `pkg` struggles with native `.node` files. | Rewrite using SwiftTerm `LocalProcessTerminalView` | Bundled Node helper; must be signed with hardened runtime and JIT entitlement |
| Menu bar popover | `Tray` + frameless `BrowserWindow` (`type:'panel'`); the `menubar` package (9.x, tested against Electron 35–43) does the positioning | Tray shows a **native menu**. A custom popover needs a separate window + positioner `Position.TrayCenter` or the third-party `tauri-nspopover-plugin` | `MenuBarExtra` + `.menuBarExtraStyle(.window)` hosts any SwiftUI view. Known focus/Settings quirks for Dock-less apps on macOS 26. | `MenuBarExtra(.window)` |
| Vibrancy and Liquid Glass | `vibrancy:'sidebar'`/`'popover'`/`'under-window'`, **one per window**. No built-in Liquid Glass; the `electron-liquid-glass` addon exists. | `window-vibrancy` crate (`NSVisualEffectMaterial::Sidebar`); transparent windows need `macOSPrivateApi:true`, which rules out the Mac App Store | Native Liquid Glass (`NSGlassEffectView`, macOS 26+) | Native |
| Sidebar drag and drop | `vuedraggable`, already used | Same | List `.onMove`/`.draggable`; macOS 27 SwiftUI adds reorder across lists | Native |
| Notifications | `Notification` with `actions`, `hasReply`; **app must be code-signed** | Plugin | `UNUserNotificationCenter`, full support | Native |
| Global hotkey and launch at login | `globalShortcut`; `app.setLoginItemSettings({openAtLogin, type:'mainAppService'})` | `tauri-plugin-global-shortcut`, `tauri-plugin-autostart` | SMAppService plus a hotkey package | Native |
| Apple integrations (App Intents, Handoff, iOS code sharing) | Handoff via `app.setUserActivity`; App Intents not possible without a Swift helper | Tauri can build an iOS app from the same Vue code | Best: share Swift code with the iOS app and Live Activities | Good |
| App size and memory (my estimates, not measured) | About 200 MB, heavier | About 15 MB | About 10 MB | About 60 MB |
| Effort to v1 | **Lowest** | High (Rust rewrite or sidecar workarounds) | Highest | High (two languages, three processes) |

**Electron risk to note:** the macOS 26 WindowServer lag caused by Electron's `_cornerMask` override was fixed in 36.9.2, 37.6.0 and 38.2.0, so any current version (42–44) is fine.

### Recommendation: Electron 44 + Vue 3 + xterm.js 6 + node-pty
**Reasons:**
1. **Almost all of CODD carries over.** `TerminalManager` and the other Express services move into the main process or a `utilityProcess`. The SSE stream can become IPC, or stay as SSE on 127.0.0.1 so the remote access in Phase 1 comes for free.
2. **Full design freedom** for the menu bar popover and sidebar, so the CODD visual language extends directly.
3. **The usual menu bar pattern is mature in Electron**, including `tray.setTitle()` with ANSI colours. That means the menu bar item can show a **coloured waiting count** next to the icon.
4. **The iOS companion is separate either way.** Native SwiftUI is better for Live Activities and APNs, so Tauri's shared-iOS advantage is small.

If native polish (true Liquid Glass, App Intents) later matters more than speed, move to the hybrid. Only the shell would be rewritten; the session pane and Node services carry over.

### Constraints the mockup should respect (Electron)
- **Main window:**
  - `titleBarStyle:'hiddenInset'` with `trafficLightPosition` (e.g. `{x:16,y:18}`). Reserve about 52px at the top of the sidebar for the traffic lights.
  - Sidebar uses `vibrancy:'sidebar'`. The content pane paints its own opaque background, because only one vibrancy is allowed per window.
  - "Glass" effects are CSS `backdrop-filter` layered over the vibrancy, not real refraction.
- **Menu bar:**
  - Monochrome template icon (16×16 and 32×32@2x, filename ends in `Template`).
  - Optional title text next to it (`monospacedDigit`), e.g. a yellow "2".
  - The popover is an HTML panel about 380×520 with no arrow; the `menubar` package defaults to 400×400.
  - Right-click shows a native menu.
- **Native pieces that can't be styled:** context menus (sidebar right-click), notifications, the Settings window chrome. Draw them as standard macOS menus in the mockup.
- **Phone mockups:** design the Remote Control chip and pairing QR modal now. The iPhone companion and Dynamic Island screens can be future frames.

## Sources
- [Remote Control docs](https://code.claude.com/docs/en/remote-control) · [Claude Code on mobile](https://code.claude.com/docs/en/mobile.md) · [Channels](https://code.claude.com/docs/en/channels) · [Agent view](https://code.claude.com/docs/en/agent-view.md) · [Desktop app](https://code.claude.com/docs/en/desktop.md) · [Settings reference](https://code.claude.com/docs/en/settings-reference.md) · [Hooks](https://code.claude.com/docs/en/hooks.md)
- [Help Net Security: Remote Control launch](https://www.helpnetsecurity.com/2026/02/25/anthropic-remote-control-claude-code-feature/)
- [MacRumors: 50 macOS 27 features](https://www.macrumors.com/2026/09/17/new-features-changes-macos-27/) · [Cult of Mac: iPhone Mirroring in macOS 27](https://www.cultofmac.com/news/iphone-mirroring-macos-27-new-features) · [WWDC26 macOS guide](https://developer.apple.com/wwdc26/guides/macos/) · [WWDC26 App Intents (345)](https://developer.apple.com/videos/play/wwdc2026/345/) · [WWDC26 Live Activities (223)](https://developer.apple.com/videos/play/wwdc2026/223/)
- [9to5Mac: Live Activities on Mac](https://9to5mac.com/2025/06/13/live-activities-are-coming-to-ipad-and-mac-heres-how-theyll-work/) · [Apple macOS Tahoe feature PDF](https://www.apple.com/au/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025_AU_Final.pdf)
- [Wi-Fi Aware sample](https://developer.apple.com/documentation/wifiaware/building-peer-to-peer-apps.md) · [Multipeer Connectivity](https://developer.apple.com/tutorials/data/documentation/multipeerconnectivity.md) · [Forum: Personal Team lacks Push and iCloud](https://developer.apple.com/forums/thread/768748) · [OneSignal: iOS Web Push](https://documentation.onesignal.com/docs/web-push-for-ios)
- [Apple: High Performance Screen Sharing](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac) · [Tailscale Serve](https://tailscale.com/kb/1312/serve) · [AlternativeTo: MCP in App Intents beta](https://alternativeto.net/news/2025/9/apple-begins-testing-early-model-context-protocol-mcp-support-in-ios-ipados-and-macos)
- [Electron releases](https://releases.electronjs.org/) · [Electron BaseWindow](https://www.electronjs.org/docs/latest/api/base-window) · [Electron Tray](https://www.electronjs.org/docs/latest/api/tray) · [Electron Notification](https://www.electronjs.org/docs/latest/api/notification) · [Electron app](https://www.electronjs.org/docs/latest/api/app) · [menubar](https://github.com/max-mapper/menubar) · [electron-liquid-glass](https://docsearch.algolia.com/mcp/docs/repo/meridius-labs/electron-liquid-glass) · [The Register: Electron Tahoe lag](https://www.theregister.com/2025/10/02/macos_26_electron_slowdown/) · [Electron PR #48376](https://releases.electronjs.org/pr/48376)
- [Tauri releases](https://v2.tauri.app/release/) · [Tauri system tray](https://v2.tauri.app/learn/system-tray/) · [Tauri positioner](https://v2.tauri.app/plugin/positioner) · [tauri-nspopover-plugin](https://github.com/freethinkel/tauri-nspopover-plugin) · [window-vibrancy](https://github.com/tauri-apps/window-vibrancy) · [Tauri Node sidecar](https://v2.tauri.app/learn/sidecar-nodejs/) · [tauri-plugin-pty](https://docs.rs/tauri-plugin-pty)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · [SwiftTerm releases](https://github.com/migueldeicaza/SwiftTerm/releases) · [MenuBarExtraStyle](https://developer.apple.com/documentation/swiftui/menubarextrastyle) · [steipete: Settings from menu bar apps on Tahoe](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items/) · [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)