# CoddCleanupUI

The Cleanup page of the Cleanup artboard (M4 C12, SPEC §7.10, plan D29–D32, D34, D38, D39):
`CleanupPageView` draws the crumb `← NOTEBOOK / CLEANUP … esc 返回筆記本`, `CLEANUP · 清理建議`
with the meta rule, the NOTES / SESSIONS / FILES tabs with their key hints, the review table
(checkbox · item + chips · why + sub · status chip · AI hint · row actions), the sticky bulk bar,
the CONDENSE · PREVIEW card in its four states and the POLICY · 保留規則 card. AppKit, built only
on CoddUI's public API; no CoddCore, CoddNotes or App types. Everything is `@MainActor`.

## Contract

- **Models** (`CleanupModels.swift`) are plain `Equatable` values with already formatted strings
  (they carry NSColor / NSAttributedString, so they are not `Sendable`):
  `CleanupTab`, `CleanupChip` (`.kind`, `.project`, `.faint`), `CleanupAIHint`, `CleanupRow`,
  `CondenseState`, `CondenseSource`, `CondenseAccountOption`, `CondenseModel`, `CleanupPolicyStep`,
  `CleanupPolicyRule`, `CleanupPolicyModel`, `CleanupPageModel`; action titles in
  `CleanupBulkAction` (`封存`, `移到垃圾桶`, `交給 Claude 濃縮…`) and `CleanupRowAction`.
- **View**: `CleanupPageView(model:)`, `update(_:)`, closures `onBack`, `onOpenSettings`, `onTab`,
  `onSelection`, `onRowAction(rowID, title)`, `onBulk(action, ids)`, `onGenerate`, `onCancelRun`,
  `onApply`, `onRegenerate`, `onDiscard`, `onCondenseAccount(id)`, `onCondenseModel(name)`; plus
  `selection`, `focusedRowID`, `selectAllRows()`, `showToast(_:undo:seconds:)`, `documentHeight`,
  `scroll(toOffset:)`, `scrollOffset`.
- **Samples**: `CleanupSamples.artboard` (8 NOTES rows, 5 selected, the card in preview, the
  policy), `.artboardAsDrawn` (the card idle with the summary, exactly as the artboard draws it),
  `.sessions`, `.files` (made-up rows in the D30 / D31 voice), `.page(condense:withPreview:disabledReason:)`,
  `.condense(_:)`, `.summaryPreview`, `.policy`.

### What the page decides, what the app decides

- **Tabs** are the app's: a click on another tab calls `onTab`; the page shows that tab once the
  app sends its model (`tab`, `rows`).
- **Selection** is the page's transient state, reported through `onSelection` on every user
  change (row click, checkbox, space, ⌘A, the header box, `✕`). `update(_:)` adopts
  `model.selected` only when it differs from the previous model's `selected` (so the app can set or
  clear it, e.g. after 封存), and always drops ids that are no longer rows, without a callback.
- **The condense card** is fully model-driven: the app moves `state` idle → running → preview
  (with `preview`) → closes the card (`condense = nil`) after 建立摘要並封存原稿, or back to idle
  after 捨棄; `failed(text)` shows `[ERROR] text` + `[重新產生]`. `disabledReason` disables
  `[✻ 產生摘要]` and `[重新產生]` and replaces the idle hint (wrapped under the button when long).
  The select pops a native two-section menu (帳號 / 模型, checkmarks from `selectedAccountID` /
  `selectedModel`); popping a menu never activates the app.
- **Bulk bar**: shown while something is selected; actions in `bulkDisabled[tab]` are drawn
  disabled (D31: SESSIONS no 移到垃圾桶 / 濃縮, FILES no 濃縮). It sticks to the visible bottom
  while the table runs below it.
- **Keyboard**, only while the page is the first responder and no field editor in its window has
  marked text: space toggles the focused row (the first row when none), ↑ ↓ move the focus
  (outlined in --amber-dim), ⌘A (also the menu's `selectAll:`) selects every row of the tab,
  ⌫ / ⌦ = `onBulk("封存", selection)` unless 封存 is disabled for the tab, esc = `onBack`.
  A click on a row, its checkbox, a tab or the page background makes the page first responder.
- **Preview**: `CondenseModel.preview` is drawn in a TextKit 1 text view (selectable, scrolls when
  longer than the box; the box is 120 … 264 px at rest and grows with the grid row). A quote bar
  as an `NSTextBlock` needs a width (`setValue(100, type: .percentageValueType, for: .width)`), as
  `CleanupSamples.summaryPreview` shows.

## Layout

The page scrolls (`padding: 18px 36px`). At the artboard's 1368 px page the grid is the 928 px
table + 24 + the 344 px card; the POLICY card spans both, 20 below. Without a condense model the
table takes the full width (extra width goes to ITEM, WHY and AI; STATUS widens for a long badge
like `resume expires 4d`). Below a 640 px table the card moves under the table; below a 1100 px
card body the POLICY lifecycle and rules stack.

## Run

```sh
swift build --package-path Packages/CoddCleanupUI --scratch-path .build-m4-cleanup --build-tests
swift test  --package-path Packages/CoddCleanupUI --scratch-path .build-m4-cleanup
swift run   --package-path Packages/CoddCleanupUI --scratch-path .build-m4-cleanup codd-cleanup-demo \
  --fonts App/Fonts --snapshot <dir> [--only <name>]
```

The demo renders offscreen (activation policy `.prohibited`, no window on screen) at 1368 × 900
(the page plus a status bar placeholder): `artboard`, `artboard-as-drawn`, `artboard-full`,
`artboard-as-drawn-full`, `sessions`, `files`, `condense-idle`, `condense-running`,
`condense-failed`, `condense-disabled`, `empty`, `narrow` (1000 px).

## New copy (D34; not on the artboard)

`// 這一類目前沒有清理建議` (empty table, `CleanupPageModel.emptyText`), `// 尚未產生摘要` (the
preview box without a summary), `◌ 產生中… <elapsed>`, `[取消]`, `[建立摘要並封存原稿]`,
`[重新產生]`, `[捨棄]`, `[ERROR] <text>`, the select's section headers `帳號` / `模型`, and the
SESSIONS / FILES sample rows.

## Accessibility (M5 D21)

A row is one AX row whose label combines item, chips, why (age), status and AI hint, with its
selection exposed; only its checkbox and buttons are separate elements. The tabs, the crumb link and
the condense select are key views under Full Keyboard Access (CoddUI's `KeyboardFocus`, focus style
on the layer); ← → on a focused tab clicks the neighbouring tab; space / ⏎ / ↓ open the select's
menu. `AccessibilityAuditTests` audits the page in every tab and condense state.
