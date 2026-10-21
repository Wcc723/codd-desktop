# CODD Desktop: native UI architecture for responsiveness (macOS, Swift)

**Recommendation:** use an AppKit app shell with SwiftUI only for the low-frequency parts. Build the sidebar with `NSOutlineView`. Put the terminal and the answer bar in AppKit views. Build the menu bar item with `NSStatusItem` and a non-activating `NSPanel`. Use the `@Observable` framework for state. Set the minimum target to macOS 26.0 and build with Xcode 27.

**Environment (checked read-only):** Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1, Apple Silicon.

## 1. SwiftUI vs AppKit vs hybrid

| Part of the UI | Technology | Why |
|---|---|---|
| App lifecycle, main menu, windows | AppKit (`NSApplicationDelegate`, `NSWindowController`) | Full control over activation, window chrome and dynamic submenus. SwiftUI's app menu is reportedly built only once and can't have dynamic submenus. |
| Sidebar (groups, projects, sessions) | View-based `NSOutlineView`, `.plain` style, custom `NSTableRowView`/`NSTableCellView`, fixed row height | See the pitfalls below. |
| Split layout | Plain `NSSplitViewItem(viewController:)` | Avoids the sidebar item type and `NavigationSplitView`, which float a glass sidebar on macOS 26+. |
| Session header, tab strip | SwiftUI inside `NSHostingView` (`sizingOptions` trimmed), or AppKit | Updates rarely. With `@Observable` only the parts that read a changed property redraw. |
| Terminal | The terminal engine's own `NSView`, placed directly in the AppKit view tree | Keep it out of SwiftUI layout and SwiftUI shaders. |
| Answer bar | `NSTextView` subclass | IME correctness (section 7). |
| ⌘K palette | One child `NSPanel` built ahead of time (`NSTextField` + `NSTableView`), shown with `orderFront`/`orderOut` | Appears instantly: no sheet animation, no allocation. |
| Sheets (new session, rename group) | SwiftUI in `NSHostingController` via `beginSheet` | Low frequency. |
| Settings | SwiftUI `Form` in your own `NSWindowController` | Avoids the `openSettings` problems. |

### SwiftUI List / OutlineGroup pitfalls on macOS 15–27

- **Hierarchical lists are slow.** A test with 100k flat items and with 4×25k items in folders took minutes to become responsive, and selection was very slow, with 99% of CPU inside SwiftUI (FB14822105). The author retested on macOS 26 beta 1 and it was still slow. Apple's 6× load / 16× update claim (WWDC25) is for flat lists over 100k items. At about 300 rows raw speed is acceptable; the bigger problems are styling and interaction.
- **Selection changes re-evaluate every visible row** (claim from the FastList author). Byla found that `.contextMenu` doesn't select the right-clicked row. Several developers report SwiftUI `Table` and `LazyVGrid` hitching where `NSTableView` "felt buttery".
- **Drag and drop:**
  - `onMove` only works within one flat `ForEach`, so moving projects between groups isn't covered.
  - The new `reorderable()` / `reorderContainer` API is macOS 27+ only. It already has crash reports: when the view body contains `if #available`, and when a popover is attached.
  - The fixes for `List` accepting drops apply only to apps built with the 27 SDK.
- **Styling fights the framework:**
  - Selection uses the system accent colour.
  - `listRowBackground` can make rows opaque while dragging.
  - On Tahoe the sidebar list style turns into floating glass.
  - Group tint blocks that span several rows need hacks.
- **Menus:** SwiftUI menus can't hold custom swatch views. On macOS 27, SwiftUI and AppKit hide menu-item images by default.
- **Animations:** `.repeatForever` driven by state changes caused CPU to climb until the animation stuttered (Apple forum thread). There is also a macOS 27 report that showing a popover more than once in a view's lifetime crashes the app.

### Where `NSOutlineView` is better

- **Drag and drop:**
  - Moving several items at once (`pasteboardWriterForItem`).
  - Drops between parents, limited in `validateDrop` (sessions only within their project, projects only into groups).
  - An animated gap while dragging (`draggingDestinationFeedbackStyle = .gap`).
  - `moveItem(at:inParent:to:inParent:)` animates the move instead of reloading.
- **Selection and keyboard:** multi-select, type-to-select and keyboard navigation work out of the box. Right-click uses `clickedRow` without changing the selection, and the menu is built lazily in `menuNeedsUpdate`.
- **Inline rename:** `editColumn` uses the system field editor, so IME works correctly.
- **Custom drawing:**
  - Group tint blocks: draw them in `NSTableRowView.drawBackground` with `intercellSpacing = 0`.
  - Square selection: override `drawSelection`.
  - Keep `usesAutomaticRowHeights` off; automatic heights flickered on Sonoma.
- **Per-row updates without `reloadData`:** on macOS 26, AppKit observation tracking is on by default. A cell's `updateLayer()`/`layout()` that reads `session.state` re-runs only for that cell.
- **Status lamps:** a `CALayer` per lamp with a `CABasicAnimation`. The animation is committed once and does no per-frame work on your main thread. Only visible rows exist (cell reuse), so that is about 40 lamp layers.
- **Colour swatches in context menus:** use a custom `NSMenuItem.view`, or colour images with `preferredImageVisibility = .visible` (macOS 27+).
- **`NSCollectionView`** is the better choice for grids or card dashboards (it can draw section backgrounds as decoration items), not for this hierarchy.

## 2. Menu bar item: use `NSStatusItem` + a non-activating `NSPanel` hosting SwiftUI

**Why not `MenuBarExtra(.window)`:**
- There's no first-party way to open or close it from code; the workaround is the MenuBarExtraAccess package (1.3.1, Aug 2026), which reaches into the underlying window.
- The label is rendered as an image, so a coloured inner square is awkward.
- Activation and focus can't be controlled.
- `openSettings` failed on macOS 26 for menu-bar (accessory) apps.
- With the `.menu` style, the run loop is blocked while the menu is open, so timers stop.

**Implementation:**
- **Icon:** `NSImage(size:flipped:drawingHandler:)` with `isTemplate = false`. Draw the outline in `labelColor` for the current menu bar appearance and the inner square in the state colour. Regenerate the image when the button's `effectiveAppearance` changes (observe it with KVO).
- **Text:** quota as `attributedTitle` with monospaced digits so the width doesn't jitter. Set it only when the value changes.
- **Panel setup:**
  - `.nonactivatingPanel` style, so opening it never raises the main CODD window over your editor. Call `makeKey()` when the search field needs typing.
  - `.floating` level; `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
  - `animationBehavior = .utilityWindow` to avoid a flash on recent macOS.
  - A global mouse-down monitor closes it on outside clicks; Esc closes it too.
  - Position it under the status button using `convertToScreen`.
- **Update rhythm:** run the 1 s timer only while the panel is visible. Otherwise update the icon and title only when hook events change something. Poll cswap quota on a slow background interval.

## 3. Custom "Phosphor Console" look

- **Fonts:**
  - Bundle JetBrains Mono v2.304 (OFL-1.1, so bundling is allowed) via the `ATSApplicationFontsPath` Info.plist key. Use the "NL" (no-ligature) variant for the terminal.
  - JetBrains Mono has no Chinese glyphs. Set an explicit CoreText fallback list (PingFang TC) and a fixed line height based on the taller font, so lines don't jump when Chinese appears. Chinese characters take 2 terminal cells.
- **Square corners and controls:** on Tahoe, bordered controls become capsules or rounded rectangles. Use borderless or custom-drawn buttons and plain text fields with your own border. On macOS 27, `textInputBorderShape` is also available.
- **Dashed rules:** `CAShapeLayer` with `lineDashPattern`, or SwiftUI `StrokeStyle(dash:)`. Align to pixel boundaries so lines stay sharp.
- **Amber glow:** a `CALayer` shadow with an explicit `shadowPath` is cheap; use it on lamps, the active tab and the cursor. Avoid shadows on SwiftUI `Text` across many rows (an offscreen render pass each). Don't glow terminal text unless the terminal's GPU renderer does it.
- **CRT scanlines, by cost:**
  - **Cheapest (recommended):** one overlay `CALayer` whose content is a 1-pixel-wide image, one screen tall, stretched horizontally (`contentsGravity = .resize`, `magnificationFilter = .nearest`). Horizontal lines survive horizontal stretching unchanged. The cost is one extra composited layer: about zero CPU and trivial GPU. Make it ignore mouse clicks and leave it off by default.
  - **Avoid animated flicker or rolling bars:** they force the whole window to recomposite every frame, which costs GPU and battery.
  - **Not usable over the terminal: SwiftUI `.layerEffect`/`.colorEffect`/`drawingGroup`.** Apple's documentation says AppKit-backed views render as a placeholder image inside these effects.
  - **Real CRT curvature or bloom** is only possible inside a Metal terminal renderer, at the cost of an extra full-resolution pass per frame. SwiftTerm has an optional Metal renderer. Ghostty supports custom shaders, but its embedding API isn't officially stable. Defer this.
- **Dark only:** set `NSApp.appearance = NSAppearance(named: .darkAqua)` at launch. System menus, alerts and notifications keep the native look; accept that.

**Coexisting with Liquid Glass:**
- **No opt-out:** Apple's documentation says the `UIDesignRequiresCompatibility` key is ignored when you build for macOS 27 or later, so plan around the new chrome.
- **Window:** titlebar-only, with no `NSToolbar`. Windows with a toolbar get a larger corner radius; titlebar-only windows get a smaller one.
  - Use `.fullSizeContentView`, `titlebarAppearsTransparent = true` and `titleVisibility = .hidden`, and draw your own header strip.
  - Leave room for the traffic lights and keep content out of rounded corners via the safe-area layout guide.
  - The window corners stay rounded; only the interior is square. Don't use a borderless window just to get square corners: you lose the traffic lights, tiling and resizing.
- **Sidebar:** avoid the split-view sidebar item type, `NavigationSplitView` and `NSVisualEffectView` materials.
- **Scrolling:** keep scroll views below your header strip, not under the titlebar, so the automatic scroll-edge blur doesn't appear.

## 4. System integration

- **Notifications (`UNUserNotificationCenter`):**
  - Set the delegate in `applicationWillFinishLaunching`. Apple says it must be set before the app finishes launching.
  - A "waiting" category with Open and Reply (`UNTextInputNotificationAction`) actions.
  - One notification ID per session, so a new one replaces the old instead of stacking; remove it when the session is focused. `threadIdentifier` per project.
  - In `willPresent`, suppress it if that session is already visible in the key window.
  - Banners show actions on hover; suggest the user set the "Alerts" style.
  - If you add "Approve" from a notification, check that the session is still waiting on the same prompt before sending keys.
  - Sign with a stable Apple Development identity. Notifications need a signed, bundled app, and ad-hoc signatures change on every build, which resets permissions.
- **Dock badge:** `NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil`, set only when the count changes. Forum reports say it needs notification permission that includes `.badge`.
- **Global hotkey:** KeyboardShortcuts 3.1.0 (2026-09-11, MIT). It uses Carbon `RegisterEventHotKey`, needs no Accessibility permission, and includes a recorder UI.
  - Don't default to ⌃Space or ⌃⌥Space (input-source switching for Zhuyin) or ⌘Space.
  - Option-only shortcuts were blocked in macOS 15.0–15.1 and allowed again in 15.2.
  - ⌘K should be a main-menu key equivalent, not a global hotkey or a key-event monitor.
- **Launch at login:**
  - `SMAppService.mainApp.register()`. If it returns `.requiresApproval`, open System Settings with `openSystemSettingsLoginItems()`.
  - For the process that keeps sessions alive across quits and crashes, use `SMAppService.agent(plistName:)` with the plist in `Contents/Library/LaunchAgents`.
  - After an app update, the old agent binary keeps running. You need versioned communication between app and agent, plus a "restart when idle" path.
- **Single instance:**
  - The `LSMultipleInstancesProhibited` key is about several *users* running the app, not duplicates for one user.
  - The real risks are an Xcode build and an /Applications copy running at the same time, or `open -n`.
  - Fix: take an exclusive `flock` on a file in Application Support. If it's already held, activate the running copy and exit.

## 5. Minimum macOS and state management

**Target macOS 26.0 and build with Xcode 27.** If the app will only ever run on your Macs, 27.0 is also fine: one OS to test, and it adds `reorderContainer`. Reasons for 26:
- `Observations` requires 26.
- AppKit observation tracking is on by default from 26 (on 15 it needs `NSObservationTrackingEnabled`).
- The SwiftUI list and update-scheduling speedups are in the 26 OS itself.
- The safe-area and corner-layout APIs are 26+.
- The new `@State` macro back-deploys anyway.

**Model:**
- One `@MainActor @Observable final class SessionVM` per session. Use Equatable property types so writes that don't change the value don't invalidate views.
- The structure is kept separately: groups → projects → `[SessionID]`. It changes only on add, remove or reorder, so the 1 s ticks never touch the list structure.
- Avoid Combine `ObservableObject`: any change to any property invalidates every view that observes the object. Keep Combine only for existing NotificationCenter and KVO publishers.

**How updates flow:**
- Hook events and registry polls go into an `actor SessionMonitor`, which computes the changes and applies them in one batch, at most one hop to the main thread per ~100 ms.
- Non-UI consumers (Dock badge, menu bar icon) use `Observations`, which batches changes. Caveats: it emits the initial value first, and the SE-0475 review reported stalls when the producer outpaces the consumer.
- Elapsed-time labels: SwiftUI `Text(date, style: .timer)`; in AppKit, one 1 Hz timer that updates only the visible rows. Never store `now` in the model.
- Terminal output never goes through Observation or Combine. Path: PTY or agent socket → parse on a background queue → mark dirty → draw on the view's display link (macOS 14+) at most once per refresh.
- Watch the Swift 6.2+ default: new projects put code on the main thread unless marked otherwise. An unannotated `nonisolated async` function runs on the caller's thread, so heavy parsing can silently land on main. Mark it `@concurrent`; Apple changed `DocumentReader` to `@concurrent` for exactly this reason.
- Keep live terminal views for an LRU set of about 8 sessions and detach the rest.

## 6. IME rules (Zhuyin is critical)

1. Every text-entry surface uses the AppKit text system (`NSTextView`, or `NSTextField` with its field editor).
2. Nothing may intercept Return, Esc, arrows, Space or digits before the input method, because Zhuyin uses them to pick candidates. That means no `.onKeyPress` on parent views (SwiftUI runs it before the text field) and no keyDown event monitors without a `hasMarkedText()` check. Submit in `textView(_:doCommandBy:)` (`insertNewline:`), which runs after the input method.
3. The terminal view implements `NSTextInputClient` fully:
   - `setMarkedText` draws the in-progress text inline at the cursor.
   - `insertText` sends the committed UTF-8 to the PTY.
   - `firstRect(forCharacterRange:)` returns the cursor rectangle in screen coordinates so the candidate window sits in the right place.
   - `keyDown` goes through `interpretKeyEvents` first.
4. Test with Zhuyin (arrow, digit and Space selection, Shift to toggle English, Enter to commit), plus Pinyin, Japanese, the emoji picker and dictation.

## 7. Risks

- **More code:** the AppKit-heavy approach means more boilerplate, such as `NSOutlineView` data source and delegate code.
- **SwiftUI/AppKit boundary bugs:** `NSHostingView` sizing loops, and a Tahoe `NSTableView` bug where rows scroll into the header when the scroll view isn't full height (FB21850950; workaround is 1 pt of inset).
- **macOS 27 SwiftUI regressions:** the popover and `reorderable` crashes. Keep SwiftUI to the leaf views.
- **Mandatory Liquid Glass:** future changes to traffic lights or window corners may clash with the custom header.
- **Profiling:** there are reports of Instruments saying "Trace file had no SwiftUI data" in Xcode 26 and 27; use signposts alongside Instruments.
- **Dependencies:** KeyboardShortcuts depends on Carbon, which Apple hasn't replaced. MenuBarExtraAccess (if you go that way) relies on introspection. libghostty's API isn't stable.
- **Performance targets** (my own budgets, not sourced): under 8 ms of main-thread work per frame at 120 Hz, under 16 ms to switch sessions, and keystroke-to-glyph under 10 ms.

## Sources

- [What's new in SwiftUI, WWDC25](https://developer.apple.com/videos/play/wwdc2025/256/) · [What's new in SwiftUI, WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/) · [Build an AppKit app with the new design, WWDC25](https://developer.apple.com/videos/play/wwdc2025/310/)
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes) · [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) · [UIDesignRequiresCompatibility](https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility)
- [drawingGroup](https://developer.apple.com/documentation/swiftui/view/drawinggroup(opaque:colormode:)) · [layerEffect](https://developer.apple.com/documentation/swiftui/view/layereffect(_:maxsampleoffset:isenabled:)) · [reorderContainer](https://developer.apple.com/documentation/swiftui/view/reordercontainer(for:isenabled:move:)) · [NSMenuItem.preferredImageVisibility](https://developer.apple.com/documentation/appkit/nsmenuitem/preferredimagevisibility)
- [AppKit observation tracking](https://developer.apple.com/documentation/appkit/updating-views-automatically-with-observation-tracking-in-appkit) · [steipete: automatic observation tracking](https://steipete.me/posts/2025/automatic-observation-tracking-uikit-appkit) · [Observations](https://developer.apple.com/documentation/observation/observations) · [SE-0475 review](https://forums.swift.org/t/se-0475-transactional-observation-of-values/79224) · [Use Your Loaf: Observations](https://useyourloaf.com/blog/swift-observations-asyncsequence-for-state-changes/) · [Nil Coalescing: Equatable properties in @Observable](https://nilcoalescing.com/blog/EquatablePropertiesInObservableClasses)
- [UNUserNotificationCenterDelegate](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate) · [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) · [SMAppService.agent](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)) · [LSMultipleInstancesProhibited](https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited) · [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Hierarchical List performance thread](https://developer.apple.com/forums/thread/761829) · [lemonmojo repro repo](https://github.com/lemonmojo/swiftui-hierarchical-list-performance) · [Michael Tsai: NSTableView with SwiftUI](https://mjtsai.com/blog/2024/04/15/nstableview-with-swiftui) · [Michael Tsai: SwiftUI in appleOS 27](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/) · [Michael Tsai: Tahoe window corners](https://mjtsai.com/blog/2025/10/16/tahoe-window-corners/) · [Nil Coalescing: iOS 27 reordering APIs](https://nilcoalescing.com/blog/NewSwiftUIAPIsForReorderingAndDragAndDropOniOS27/) · [Tahoe NSTableView scroll bug](https://troz.net/post/2026/appkit-table-scroll-bug-in-macos-tahoe/) · [repeatForever CPU thread](https://developer.apple.com/forums/thread/767243)
- [steipete: Settings from menu bar items](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items/) · [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) · [Multi: pushing the limits of NSStatusItem](https://multi.app/blog/pushing-the-limits-nsstatusitem) · [Fazm: menu bar floating window pitfalls](https://fazm.ai/blog/swiftui-menu-bar-app-floating-window-best-practices)
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · [Sequoia Option-key hotkey change](https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/) · [Dock badge needs authorization](https://developer.apple.com/forums/thread/696708) · [Notifications need a signed bundle](https://mirror.b10c.me/bitcoin-core-gui/112/)
- [onKeyPress vs IME fix example](https://github.com/uttrflow/uttrflow-swift/pull/1088) · [Zed terminal IME implementation](https://git.secluded.site/zed/commit/c7725e31d953c85daf78eaf1590954ddeaecfd63) · [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (v1.99.0, 2026-10-08) · [Ghostty about](https://ghostty.org/docs/about) · [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (v2.304, OFL-1.1)