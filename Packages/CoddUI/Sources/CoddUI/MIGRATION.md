# CoddUI migration notes (for I1a `ui-switch`)

CoddUI is a verbatim copy of the app's design system (M3-PLAN D30, §4 C5) plus the M3 primitives.
The copies differ from App/ only by access modifiers and the edits listed under "Non-verbatim edits".
I1a deletes every App declaration in "Copied" below, keeps everything in "Left in App", adds
`import CoddUI` where needed (App and App/Tests) and turns `HomeHeaderView.glow` into a forwarder.

How the copy was checked (2026-10-17): each CoddUI file was diffed against its App source with the
added `public` / `open` stripped; the only remaining differences are the ones listed here. Every type
name App declares that appears in the copied code resolves inside CoddUI (no App type is referenced),
and `swift build` of the package compiles them without App.

## Copied (delete from App)

| CoddUI file | App source | Declarations |
|---|---|---|
| `Theme/Theme.swift` | `App/Theme/Theme.swift` | `Palette`, `Metrics`, `extension NSColor { init(hex:alpha:), mixed(with:fraction:) }` |
| `Theme/Typeface.swift` | `App/Theme/Typeface.swift` | `Typeface` (`Weight`, `mono`, `display`, `registerBundledFontsIfNeeded`, `lineHeight`) |
| `Theme/Drawing.swift` | `App/Theme/Drawing.swift` | `TextStyle`, `Draw`, `ChipStyle` (`size(for:)`, `draw`, `smallChip`, `ext`, `badge`) |
| `Theme/Icons.swift` | `App/Theme/Icons.swift` | `Icon`, `IconRenderer`, `SVGPath` (+ `SVGPath.Token`) |
| `Controls/BasicViews.swift` | `App/Controls/BasicViews.swift` | `FlippedView`, `PanelView` (+ `Edges`), `WindowDragView`, `Label`, `WrappingLabel`, `NSView.descendant(ofType:)`, `NSView.pinEdges(to:insets:)`, `hStack`, `vStack`, `columnStack`, `NSStackView.addFullWidth`, `spacer` |
| `Controls/ChipView.swift` | `App/Controls/ChipView.swift` | `ChipView` (+ `kbd`) |
| `Controls/CoddButton.swift` | `App/Controls/CoddButton.swift` | `CoddButton` (+ `Variant`, `Style`, `TabMark`, `markWidth`, `drawSmallBracket`) |
| `Controls/FormControls.swift` | `App/Controls/FormControls.swift` | `FieldBoxView`, `InputField`, `SelectButton`, `RadioRowView`, `SwitchToggle`, `TextAreaField`, `ColorSquareView` |
| `Controls/SegmentedSwitch.swift` | `App/Controls/QuotaViews.swift` (last declaration) | `SegmentedSwitch` |
| `Controls/ToastView.swift` | `App/Controls/ToastView.swift` | `ToastView` |
| `Controls/ClosureMenuItem.swift` | `App/Sidebar/SidebarViewController+Menu.swift` | `ClosureMenuItem` |
| `Controls/DashedRuleView.swift` | `App/MenuBar/MenuBarPanelView.swift` (last declaration) | `DashedRuleView` |
| `Support/UITicker.swift` | `App/Support/UITicker.swift` | `SecondTicking`, `PulseSubscriber`, `UITicker` (keeps `var clock = DisplayClock()`) |
| `Support/ObservationLoop.swift` | `App/Support/ObservationLoop.swift` | `ObservationLoop` |
| `Model/DurationFormat.swift` | `App/Model/DurationFormat.swift` (whole file) | `DurationFormat`, `ClockFormat`, `PathFormat` |
| `Model/DisplayClock.swift` | `App/Model/Stores.swift` (first declaration) | `DisplayClock` |

Whole App files that become empty and can be deleted: `Theme/Theme.swift` (after moving the two
extensions, below), `Theme/Typeface.swift`, `Theme/Drawing.swift` (after moving `statePill`),
`Theme/Icons.swift`, `Controls/BasicViews.swift`, `Controls/ChipView.swift`, `Controls/CoddButton.swift`,
`Controls/FormControls.swift`, `Controls/ToastView.swift`, `Support/UITicker.swift`,
`Support/ObservationLoop.swift`, `Model/DurationFormat.swift`.

`PathFormat` is not in the plan's list but lives in the same file and has no App dependency; it was
copied so `Model/DurationFormat.swift` moves whole (decision, reversible: delete it from CoddUI and
keep App's if preferred).

## Left in App (do not delete)

- `extension TagColor { var color }` and `extension QuotaTone { var color }` (were in `Theme/Theme.swift`;
  move them to another App file, e.g. `Theme/StateStyle.swift`).
- `ChipStyle.statePill(_:size:height:)` (was in `Theme/Drawing.swift`; needs `StateStyle`). Re-declare it
  in App as `extension ChipStyle { static func statePill(...) }`; it compiles unchanged against the
  public `ChipStyle(text:border:fill:dashed:height:padding:)` and `TextStyle.caps`.
- `Theme/StateStyle.swift`, `Controls/LampView.swift`, `Controls/AccountRowView.swift`, `Support/TermMarkup.swift`.
- From `Controls/QuotaViews.swift`: `QuotaBar`, `QuotaRowRenderer`, `QuotaRowView` (CoddUI's value-based
  row is `QuotaBarRowRenderer` / `QuotaBarRowView`, named apart so App/Tests stay unambiguous).
- From `Model/Stores.swift`: everything except `DisplayClock` (`HostSummary`, `AutoSwitchConfig`,
  `StoreProblem`, `SessionStore`, `AccountStore`, `SampleAccountNote`).
- `HomeHeaderView` (`Session/HomeCards.swift`): keep `glow(_:radius:)` as a forwarder,
  `static func glow(_ color: NSColor, radius: CGFloat) -> NSShadow { Draw.glow(color, radius: radius) }`
  (seven App call sites use it).
- The rest of `MenuBar/MenuBarPanelView.swift` and `Sidebar/SidebarViewController+Menu.swift`.

## Non-verbatim edits

1. `Draw.glow(_ color: NSColor, radius: CGFloat) -> NSShadow` added (`extension Draw` at the end of
   `Theme/Drawing.swift`), the body of `HomeHeaderView.glow`. The copied `FormControls.swift` calls it
   instead of `HomeHeaderView.glow` (one call, in `RadioRowView.draw`; the plan said two, there is one).
2. `Typeface.registerFonts(in:) -> Bool` added (`extension Typeface` at the end of `Theme/Typeface.swift`;
   CTFontManagerRegisterFontsForURL per `.ttf` / `.otf`, `.process` scope, already-registered errors
   ignored, clears the font cache). For demos and tests only; the app keeps `ATSApplicationFontsPath`
   and `registerBundledFontsIfNeeded()`. Nothing registers fonts implicitly.
3. `DashedRuleView`, additive only: `public var color` (default `Palette.line`, what the app drew),
   `public var minimumWidth` (default 0), `public convenience init(color:minimumWidth:)`; `draw` uses
   `color`. Existing `DashedRuleView()` calls draw exactly as before.
4. `import AppKit` / `import Foundation` headers on the four files cut out of larger App files.
5. (I1a, bug fix) `InputField.viewDidMoveToWindow` removes only its `NSWindow.didUpdateNotification`
   observation. The copied `NotificationCenter.default.removeObserver(self)` also dropped the
   NSControl delegate registration behind `controlTextDidChange`, so `onChange` never fired once the
   field was in a window (found by C8). App's `ProjectComboBox` had the same line and got the
   same fix.

## Access-level changes

- `public` on every top-level type, free function, extension member, member, initializer, static
  member and nested type (protocol requirements take the protocol's access).
- `open` (the app subclasses them; check with `grep -rn "class .*: *\(FlippedView\|PanelView\|WindowDragView\|FieldBoxView\)" App`):
  - `FlippedView`: `open override var isFlipped`.
  - `PanelView`: `open var fill`, `edges`, `edgeColor`, `dashedEdges`; `open override var wantsUpdateLayer`;
    `open override func draw(_:)`.
  - `WindowDragView`: `open override var mouseDownCanMoveWindow`; `open override func mouseDown(with:)`.
  - `FieldBoxView`: `open var isFocused`, `isDimmed`, `fill`; `open override func draw(_:)`.
  - Their initializers are `public` (`PanelView.init(fill:edges:edgeColor:dashed:)`,
    `FieldBoxView.init(frame:)`, `public required init?(coder:)` unavailable) and stay overridable.
  App subclasses (`SidebarHeaderView`, `SessionHeaderView`, `ProjectComboBox`, the PanelView /
  FlippedView subclasses in Session/, Sidebar/, MenuBar/, NewSession/, Palette/, Settings/) keep
  their plain `override`s.
- Explicit `public` memberwise initializers (Swift's synthesized ones are internal):
  `TextStyle.init(font:color:tracking:uppercase:shadow:)`, `ChipStyle.init(text:border:fill:dashed:height:padding:)`
  (same labels and defaults as the synthesized ones), `PanelView.Edges.init(rawValue:)`,
  `DisplayClock.init(offset:)`.
- `PanelView.Edges` is now `Sendable` (public structs get no implicit `Sendable`, and its `static let`s
  need it under Swift 6).
- `public private(set)`: `CoddButton.isHovered`, `SelectButton.titles` / `selectedIndex`,
  `SegmentedSwitch.titles`, `ToastView.remainingSeconds`, `ObservationLoop.isCancelled`.
- Delegate witnesses are `public` (required for a public class): `InputField.controlTextDidChange`,
  `controlTextDidBeginEditing`, `control(_:textView:doCommandBy:)`; `TextAreaField.textDidChange`,
  `textDidBeginEditing`, `textDidEndEditing`.
- Unchanged: every `private` / `fileprivate` member (`Icon.shape`, `CoddButton` text styles, …).

## Notes for I1a

- App/Tests use `@testable import CODD`; they also need `import CoddUI` for the moved types.
- `UITicker.forceVisible` stays `#if DEBUG`; SwiftPM compiles packages with `DEBUG` in Debug builds.
- New public names App must not redeclare: `Tone`, `ChipKind`, `QuotaBarRow`, `QuotaBarRowRenderer`,
  `QuotaBarRowView`, `MeterView`, `SparklineView`, `CardView`, `CheckboxButton`, `StepperControl`,
  `KbdView`, `ModalFrameView`, `DiffLinesView`, `SectionHeaderView`, `FormRowView`, `ViewSnapshot`, and the
  `TextStyle` / `ChipStyle` presets in `Primitives/StylePresets.swift` (none clash today).
- Pixel parity: the copies draw identically; the snapshot before / after check of I1a still applies.

## Done (I1a, 2026-10-17)

Every declaration under "Copied" is deleted from App (the twelve whole files above, plus
`SegmentedSwitch`, `DisplayClock`, `ClosureMenuItem` and `DashedRuleView` cut out of their files);
the TagColor / QuotaTone extensions and `ChipStyle.statePill` moved to `App/Theme/StateStyle.swift`;
`HomeHeaderView.glow` forwards to `Draw.glow`; 69 App and App/Tests files `import CoddUI`. No access
level had to change: the app and its tests build against the public API as published. Pixel parity
was checked with mock-mode snapshots before / after (identical except time-dependent text).


## Additions (I1b, 2026-10-17)

Additive only (the copied look and every existing call are unchanged):

- `SelectButton.setItems(_:selected:enabled:toolTips:)`, `itemEnabled`, `itemToolTips`,
  `isItemEnabled(_:)`: per-item disabled entries with a tooltip (the ⌘N account select lists the
  active account and accounts without a cswap profile disabled, D12). `setItems(_:selected:)`
  keeps every item enabled as before.
- `ToastView.performUndo()` and `hasUndo`: `[UNDO]` pressed from code (DEBUG `-codd-undo-switch`,
  tests); the button runs the same method.

## Additions (I3, 2026-10-17)

- `UITicker.motionOverride: Bool?`: Settings › 外觀 › 減少動態 (`系統` nil, `開` true, `關` false)
  wins over the system "Reduce motion" in `pulsesAllowed`; pulsing views are told when it changes.
  nil (the default) keeps the old behaviour.

## Additions (M5 ui-core-a11y, 2026-10-18)

Additive API (every existing call compiles; nothing changes size or layout, and nothing is drawn
differently while no control has keyboard focus):

- `KeyboardFocus`: `fullKeyboardAccessOverride`, `isFullKeyboardAccessOn`, `keyWindowOverride`,
  `isKey(_:)`, `acceptsFocus(enabled:refuses:textInput:)`, `refresh()`, `observeSystemSetting()`,
  `didChangeNotification`, `Origin` / `focusOriginOverride` / `origin(of:for:)` /
  `currentOrigin(for:)`, `focusAsKeyboardNavigation(_:)`, `Key` / `key(of:)`, `drawRing(in:)`,
  `ringGlow`. `KeyboardFocusTracker`, `KeyboardFocusTracking`, `KeyboardFocusRefusing` (NSControl
  conforms).
- `AccessibilityAudit` (`Finding`, `Report`, `Summary`, `interactiveRoles`, `audit(window:screen:checkKeyLoop:)`,
  `audit(view:screen:)`, `auditIncludingAttachedWindows(_:screen:checkKeyLoop:)`).
- `ViewSnapshot.render(_:size:width:scale:background:prepare:)`.
- `SegmentedSwitch.select(_:)` and `segmentRect(_:)`; `RadioRowView.siblingRows`,
  `moveToSibling(by:)`, `refusesFirstResponder`; `SelectButton.refusesFirstResponder`;
  `QuotaBarRowView.spokenText`; `focusTracker` on CoddButton, CheckboxButton, SegmentedSwitch,
  SwitchToggle, StepperControl, SelectButton and RadioRowView.

Behaviour changes a dependent's test may notice:

- `acceptsFirstResponder` / `canBecomeKeyView` of CoddButton, CheckboxButton, SegmentedSwitch,
  SwitchToggle, StepperControl, SelectButton and RadioRowView are false while Full Keyboard Access is
  off (CheckboxButton and StepperControl accepted always before; SelectButton and RadioRowView
  never did); `canBecomeKeyView` is also false while hidden.
- StepperControl no longer turns its border amber-dim for any focus; CheckboxButton `.plain` draws
  its `.sd-check` outline and `.boxed` its amber title only for keyboard focus.
- VoiceOver: QuotaBarRowView is static text labelled `5h 剩 91% · 2h57m後` (was a level indicator
  `5h 剩餘` with the value); SectionHeaderView is a heading (was a group); ChipView is static text
  (was not an element); SwitchToggle has subrole switch and the value description 開 / 關;
  SegmentedSwitch has one radio-button child per segment. Labels of CheckboxButton, KbdView,
  ChipView, QuotaBarRowView, SectionHeaderView, CardView, ModalFrameView, FormRowView, MeterView and
  RadioRowView are computed from what they show unless the caller set one (it now survives title
  changes).
- FormRowView's disabled rows also refuse focus for SelectButton and RadioRowView
  (`KeyboardFocusRefusing`).
