# CoddUI

The Phosphor Console design system (M3 D30): the primitives CODD.app and the M3 UI packages
(CoddStatusUI, CoddSettingsUI, CoddDialogsUI) draw with, so the app and the packages share one set
of controls. AppKit only; no CoddCore, no App types. Everything is `@MainActor` except the value types.

| Part | What it is |
|---|---|
| `Theme/` | `Palette`, `Metrics`, `Typeface` (JetBrains Mono / Space Mono, `registerFonts(in:)`), `TextStyle`, `Draw` (text, dashed lines, gradients, `glow`), `ChipStyle`, icons (`Icon`, `IconRenderer`, `SVGPath`). Copied verbatim from App/ in M3 I1a with `public` added. |
| `Controls/` | `FlippedView`, `PanelView`, `WindowDragView`, `FieldBoxView` (open classes), labels and stacks, `ChipView`, `CoddButton`, `InputField`, `SelectButton` (per-item enabled entries and tooltips), `RadioRowView`, `SwitchToggle`, `TextAreaField`, `SegmentedSwitch`, `ToastView` (`performUndo`), `ClosureMenuItem`, `DashedRuleView`. |
| `Support/`, `Model/` | `UITicker` (1 Hz, `motionOverride` / `pulsesAllowed` for Reduce Motion), `ObservationLoop`, `DurationFormat`, `ClockFormat`, `PathFormat`, `DisplayClock`, `ViewSnapshot` (offscreen PNG rendering for demos and tests). |
| `Accessibility/` (new in M5) | `KeyboardFocus` (Full Keyboard Access with a test / DEBUG override, focus origin, the keys the controls handle, the helmet focus ring and glow), `KeyboardFocusTracker` (keyboard-only focus drawing for any custom control), `KeyboardFocusTracking` / `KeyboardFocusRefusing`, `AccessibilityAudit` (unlabeled interactive elements and the ones outside the key-view loop, Codable reports). |
| `Primitives/` (new in M3) | `Tone`, `QuotaBarRow` / `QuotaBarRowRenderer` / `QuotaBarRowView` (the value-based `.qrow` with the R8 threshold tick), `MeterView`, `SparklineView`, `CardView` (ASCII corners), `CheckboxButton`, `StepperControl`, `KbdView`, `ModalFrameView`, `DiffLinesView`, `SectionHeaderView`, `FormRowView`, `TextStyle` presets, `ChipStyle.chip` kinds. |

`Sources/CoddUI/MIGRATION.md` lists every declaration that moved out of App/, its edits and the
non-verbatim fixes (the `InputField` observer fix, the I1b additions).

```sh
swift test --package-path Packages/CoddUI --scratch-path .build-ui
swift run  --package-path Packages/CoddUI --scratch-path .build-ui codd-ui-gallery --fonts App/Fonts --snapshot <dir>
```

The gallery renders 9 boards (tokens, buttons, forms, quota and meters, cards and headers, form
rows, modals and diff, toast, focus) at 2x into `<dir>`; without `--snapshot` it opens a window.
`09-focus` shows every focusable control unfocused, after a click and keyboard-focused (the glow
is a layer shadow, which snapshots do not draw).

Keyboard and VoiceOver (M5 D21): every custom control takes focus only while Full Keyboard Access
is on (`KeyboardFocus.isFullKeyboardAccessOn`; text inputs always), presses on Space (buttons and
the select also on ⏎), steps with the arrows (segmented switch ← →, radio rows ↑ ↓ ← →, stepper
↑ ↓ ← →), and draws the helmet focus style only for keyboard focus in the key window. Labels default
to what the view shows; a label set by the caller always wins.
