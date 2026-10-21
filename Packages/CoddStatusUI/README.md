# CoddStatusUI

The STATUS area of the Status artboard (M3 C6, SPEC §7.11): `StatusSidebarView` (220 px: section
nav, NEEDS YOU, session counts, refresh footer) and `StatusPageView` (HOST cards with meters and
sparklines, ACCOUNTS cards in R7 order with quota rows and R8 threshold ticks, AUTO-SWITCH row,
HOOKS & STATUSLINE card with foreign tools and the `▸ 詳細` endpoint diagnostics, the cswap session
profile cards, MCP SERVER, REMOTE). Built only on CoddUI's public API; no CoddCore and
no App types.

- Value models only (`StatusPageModel` and its parts, all `Sendable` + `Equatable`). Relative times
  are absolute dates (`StatusClock`, `StatusText`) that the views re-render at 1 Hz through
  `UITicker` while they are in a window, so the app sends a new model only when data changes.
- `apply(_:)` diffs per section and per card. `StatusPageActions` carries every button as a closure
  (all default to no-ops). `scroll(to:)` + `onVisibleSectionChange` wire the sidebar nav to the page.
- MCP SERVER (M4, D21–D23): `StatusPageModel.mcp: StatusMCPModel?` (running, endpoint, client
  count, `StatusMCPClient` rows, `StatusMCPRegistration` rows, masked token, notes path, an optional
  note, `canRotateToken`) draws the artboard's `codd` card: `● RUNNING 127.0.0.1:47821 · 3 clients ·
  只接受本機連線` (stopped: `○ STOPPED` dim and the note), the client rows or `// 沒有 client 連線`,
  `REGISTRATIONS 註冊到其他 app` with state and button (a `chip` disables it), `TOKEN •••• … [輪替]`.
  nil (every M3 call site, which keeps compiling, D40) keeps the D27 placeholder. Actions
  `onMCPRegistration(id)` and `onRotateMCPToken`; `StatusNavItem.mcp(_:)` builds the nav item
  (`● … 3 clients`, `○ … 0 clients`, `○ —` without a model).
- `StatusSamples` holds the SPEC §5 sample (M4: MCP running with its three clients) and 14 states
  (accounts missing / too old / unreadable, auto-switch on, switching, hooks clean / legacy, no
  battery, profile not linked, paused, mcp-no-clients, mcp-stopped, mcp-placeholder) for the demo
  and the tests.

```sh
swift test --package-path Packages/CoddStatusUI --scratch-path .build-status
swift run  --package-path Packages/CoddStatusUI --scratch-path .build-status codd-status-demo --fonts App/Fonts --snapshot <dir> [--state <name>]
# ACCOUNTS alone at several window widths; --resize-from also live-resizes from that width and
# writes resize-report.txt (views still on .onSetNeedsDisplay keep their old drawing).
swift run  --package-path Packages/CoddStatusUI --scratch-path .build-status codd-status-demo --fonts App/Fonts --accounts-sweep <dir> \
    [--widths 760,900,1000,1200,1440,1900] [--resize-from 1440] [--state <name>]
```

FB (Status 的 Account 小一點 / 縮放尺寸時版型會跑掉): every drawn STATUS view redraws when its size
changes (`.duringViewResize`; the page and sidebar move the CoddUI views they host to it), the account
cards are compact and the grid takes as many columns as fit cards of their content's width (at most
300 wide), the header hints wrap under the title when they do not fit, and while cswap is missing or
too old the install guide (`uv tool install claude-swap`, `[複製]`, `[在終端機執行]`, `[↻ 重新偵測]`)
follows the unavailable line. Turning AUTO-SWITCH ON asks first (`StatusPageActions.confirmAutoSwitch`)
and the row always shows the policy warning.

The app maps its stores into the model in `App/Real/StatusPageData.swift` and runs it from
`App/Session/StatusArea.swift` (5 s refresh, HOST sampling with CoddHost, latency probe).

## Accessibility (M5 D21)

`HoverControl` (nav items, NEEDS YOU rows, link rows, the add-account card) is a key view while Full
Keyboard Access is on (CoddUI's `KeyboardFocus`), presses on space / ⏎ and shows the focus style for
keyboard focus; the SECTIONS nav and the NEEDS YOU rows step with ↑ ↓. Nav items and NEEDS YOU rows
read as one element (their texts are hidden), the current item is selected, a NEEDS YOU row's
duration and detail are its value. `AccessibilityAuditTests` audits every sample state.
