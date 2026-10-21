# CoddNotebookUI

The Notebook chrome of M4 (C7): the Notebook artboard (`design/artboards-src/Notebook.src.html`,
SPEC §7.8) without the document text, which C4's `MarkdownEditorView` draws in a slot, and the
Split artboard's notes drawer (`.sp-pad`, SPEC §7.2), plus the history compare sheet, the link and
tag pickers and the popover menus. AppKit only, built on CoddUI's public API; no CoddCore,
CoddNotes or App types. Every type name carries a `Notebook` / `Note…View` prefix that CoddNotes
does not use, so App code importing both never qualifies a name.

## Contract

- **Value models in, closures out.** Models are plain `Equatable` (and `Sendable`) values with
  already formatted strings (`10:05`, `已送出 10:02`, `37m 前`, `2 張 · 1.4 MB`); the app formats
  times, sizes and paths. Every view has `init(model:)` and `update(_:)`; an equal model is a no-op,
  and views keep their own transient state across updates (the text being typed in a field, an
  open menu, a section collapsed by a click, scroll positions).
- **Everything is `@MainActor`** (NSView subclasses). No timers, no observation, no file access.
- **Disabled controls carry their reason** as a tooltip: every actionable control can be disabled
  from the model with a `…DisabledReason` string, so integration can wire features step by step
  (I1a / I1b / I2b) without hiding the artboard's controls.
- **IME (D11)**: every text field is edited by the system field editor; while it has marked text
  nothing is reported (`onSearch`, the tag fields' ⏎, the pickers' ⏎ / ↑ ↓ / ⎋ all decline and
  the keys go to the input method). The committed text is reported once the composition ends.
- **No activation, no stolen focus (D39 spirit).** Menus are `NotebookMenuView`s presented through a
  `NotebookMenuPresenting`. The default `PopoverMenuPresenter` hosts them in a `PopoverPanel`
  (borderless, `.nonactivatingPanel`, `hidesOnDeactivate`) added as a **child window** of the
  anchor's window; it never calls `NSApp.activate` or `orderFrontRegardless`, becomes key only when
  the app is already active and the parent is key (a click in CODD opened it), and does nothing at
  all when the anchor's window is not visible (offscreen tests, snapshots). `InlineMenuPresenter`
  draws the menu as a subview instead (the demo's snapshots). Row context menus in the note list are
  native `NSMenu`s (right click).

## Views

| View | Artboard part | Size | Model | Callbacks |
|---|---|---|---|---|
| `NotebookListsView` | `.nb-lists` | 220 wide | `NotebookListsModel` | `onNew`, `onSearch(String)`, `onSelect(NotebookListID)`, `onToggleSection(section, open)`, `onOpenFile(id)`, `onOpenFolder`, `onOpenCleanup`; `focusSearch()` (⌘F is the app's menu item) |
| `NoteListView` | `.nb-notes` | 300 wide; rows 101 pt with a 2-line snippet (84 / 61 with 1 / 0 lines), day separator 26 | `NoteListModel` (sections with day labels, `NoteListRow`s, end comment, empty text, default row actions) | `onSelect(id)`, `onOpen(id)` (double click, ⏎), `onSort(NoteListSort)`, `onRowAction(row, action)`; ↑ ↓ ⏎ while first responder |
| `NoteEditorChromeView` | `.main` minus the status bar | flexible; top bar 52, info panel 240, doc status 22, footer 41 | `NoteEditorChromeModel` (+ `info`, `status`, `footer`) | `onCrumb`, `onAIAccess`, `onScope(id)`, `onCopyRef(NotebookRefForm)`, `onSend(session, NotebookSendAction)`, `onMore(NotebookMoreAction)`; `documentView` slot; `openMenu(_:)` / `closeMenu()` / `presentedMenu`; `menuModel(for:)` |
| `NoteChipsRowView` | `.nb-meta` (C4 `titleAccessory`) | wraps; `height(for:)` | `NoteChipsRowModel` | `onAddTag`, `onRemoveTag` (tag chip's right-click menu), `onTagClick`, `onOpenSession`, `onOpenProject`; `beginTagEditing()` |
| `ImageAnnotationSummaryView` | `.nb-annp` (C4 image accessory) | `height(for:)` | `ImageAnnotationSummaryModel` | `onEdit` (`[編輯標註]`), `onSelectItem(n)` |
| `NoteInfoPanelView` | `.nb-info` | 240 wide | `NoteInfoPanelModel` | `onOpenLink`, `onAddLink`, `onSelectHistory(id)`, `onCompare`, `onOpenAsset(id)`, `onTogglePin` |
| `NoteDocStatusView` | `.nb-docstat` | 22 high | `NoteDocStatusModel` | `onToggleMode` |
| `PromptFooterView` | `.nb-send` | 41 high | `PromptFooterModel` | `onTarget(id)`, `onInsertRef`, `onInsertFull`, `onSend` |
| `NotesDrawerView` | Split `.sp-pad` | 300 wide; head 36, foot 28; editing bar 32, action row 40 | `NotesDrawerModel` (cards, optional files section, optional `editing`) | `onClose`, `onEditNote` (a card's title; nil: `onOpenNote`), `onOpenNote`, `onBack`, `onOpenInNotebook` (nil: `onOpenNote`), `onInsertRef`, `onSendFull`, `onNewNote`, `onOpenFile`, `onDiff`, `onQuickNote`; `documentView` slot |
| `HistoryCompareView` | sheet content (D8, D34) | 680 wide; `preferredSize` | `HistoryCompareModel` (versions, from / to, `DiffLinesView.Line`s) | `onSelectFrom`, `onSelectTo`, `onRestore`, `onClose` (also ⎋) |
| `LinkPickerView` | popover content | 340 wide; `preferredSize` | `LinkPickerModel` | `onPick(NotebookLink)`, `onCancel` |
| `TagEditorView` | popover content | 300 wide; `preferredSize` | `TagEditorModel` | `onAdd`, `onRemove`, `onDone` |
| `NotebookMenuView` | helmet `.menu`, `.nb-refmenu` | `preferredSize` | `NotebookMenuModel` | `onActivate(item)`, `onDismiss`, `onSizeChange`; `handleKey`, `activate(id:)`, `moveHighlight(by:)` |
| `PopoverPanel` | — | content size | any view (`NotebookPopoverContent` sizes itself) | `onClose`; `show(at:in:)`, `resize(to:)`, `dismiss()` |

### Editor chrome rules

- **COPY REF (D15, §3.6)**: the split button's left part calls `onCopyRef(.uri)`; the right part
  opens the 404 pt menu: header `COPY REFERENCE · 複製引用` + the id, then the five forms in the
  artboard's order with their hints (`NotebookRefForm.hint`), the first highlighted with the `推薦`
  chip and `⌘⇧C`, a separator before the URL. An OFF note's URL item is disabled with the hint and
  tooltip `AI 存取為 OFF，不提供網址`. A note that is not on disk yet (`noteID == nil` or
  `refs == nil`) shows `id —`, and COPY REF and SEND TO SESSION are disabled with
  `NotebookCopy.unsavedReason`; the footer should get the same `disabledReason`.
- **AI menu**: OFF / READ / APPEND with the D34 hints, the current one checked. **Scope menu**:
  `Global` + `scopeOptions`. **SEND TO SESSION**: one row per live session (lamp, title, detail);
  →, ⏎ or a click opens its three actions in place (`插入引用` / `插入全文` / `送出全文`, disabled
  together with `sendActionsDisabledReason`); ← / ⎋ go back. **⋯**: 釘選 / 取消釘選, 類型 ▸,
  封存 (取消封存 when archived, 還原 when trashed), 移到垃圾桶, 在 Finder 顯示, 原始碼 / 即時預覽 ⌘E,
  複製 ID; the file actions are disabled for an unsaved note.
- An open menu follows `update(_:)` and closes when its button becomes disabled.
- Menu item ids (stable, for DEBUG paths): `ai.<off|read|append>`, `scope.<id>`, `ref.<1…5>`,
  `session.<uuid>` → `send.<insertRef|insertFull|send>.<uuid>`, `more.<pin|kind|kind.<kind>|archive|unarchive|trash|restore|reveal|source|copyID>`.

### Drawer editing in place

While `NotesDrawerModel.editing` is set the drawer edits that note: the cards' scroll view hides,
the editing bar shows `‹ LINKED NOTES n` (`onBack`) and `[筆記本 ↗]` (`onOpenInNotebook`, tooltip
`在筆記本開啟`), the `documentView` slot (the app's note editor) fills the column, and the action row
above the footer has `[插入引用] [送出全文]` (`onInsertRef` / `onSendFull` with the note's id,
disabled with `actionsDisabledReason`) and the doc status bar's save state (`● 已儲存 10:05`; a
narrow drawer drops the time, then the state, never cutting it). A model that differs only in
`editing` updates those parts without rebuilding the cards; leaving editing takes the keyboard
away from a focused editor (a hidden view never keeps it).

### C4 accessories

`NoteChipsRowView` is the editor's `titleAccessory` and `ImageAnnotationSummaryView` its image
accessory: give them a width and use `height(for:)` (both also report an intrinsic height for
the width they were last laid out at). The chips row's `+ #` chip shows while the pointer is over
the row (always when the note has no tags) and opens an inline tag field.

## Samples and demo

`NotebookSamples` holds the SPEC §5 data (made-up design data): the lists (INBOX 6 · PINNED 2 ·
PROMPTS 3 · STALE 4 · ARCHIVE 34 · TRASH 3, BY PROJECT, LOCAL FILES 4), rows n1–n6, the n1 chrome
(also OFF and unsaved variants), its info panel, chips row and annotations, the s9 drawer (with and
without files, empty, editing n1), a history compare and the pickers. The notes path is the real
`~/Library/Application Support/CODD/notes`, not the artboards' design-time `~/.codd/notebook`.

```sh
swift build --package-path Packages/CoddNotebookUI --scratch-path .build-m4-notebook --build-tests
swift test  --package-path Packages/CoddNotebookUI --scratch-path .build-m4-notebook
CODD_BACKGROUND=1 swift run --package-path Packages/CoddNotebookUI --scratch-path .build-m4-notebook \
  codd-notebook-demo --fonts App/Fonts --snapshot <dir>
```

The demo renders offscreen (activation policy `.prohibited`, nothing ordered in) and writes
`notebook.png` (1440 × 900: rail placeholder + lists + list + chrome with the COPY REF menu open +
a status bar placeholder), `notebook-unsaved.png`, `drawer.png`, `drawer-nofiles.png`,
`drawer-empty.png`, `drawer-editing.png`, `history.png`, `menus.png`, `pickers.png`, `list-search.png`, `list-empty.png`.
Without `--snapshot` it opens a window (a manual tool; it activates, never run it from automation).

## Copy not on the artboards (D34)

AI menu hints (`AI 看不到這則筆記（MCP 與引用展開都不提供）`, `AI 可透過 MCP 讀取`,
`AI 可讀取，也可以在最後附加內容`) and its header `AI 存取 · AI ACCESS`; scope menu header
`範圍 · SCOPE`; `送到 SESSION` (target menu header); the unsaved tooltip
`筆記尚未建立：輸入內容後才會存成檔案`; `沒有執行中的 Claude session` / `沒有 session`; empty states
`// 還沒有筆記 · ⌘⇧N 新增`, `// 找不到符合的筆記`, `// 還沒有連結這個 session 的筆記`; the compare sheet
`HISTORY · 比較版本`, `還原這一版`, `關閉`, `還原前會先儲存目前的內容`; the pickers' placeholders
(`搜尋 session 或專案…`, `新增標籤…`, `新標籤`), headers `SESSIONS` / `PROJECTS` / `TAGS · 標籤`, the
tag chip's `移除 #<tag>`; ⋯ items `取消封存` / `還原`; AI activity kinds `改寫` / `展開` / `網址`.

## Internal primitives (candidates for CoddUI)

`NotebookSVG` (a complete SVG path parser: C / S / Q / T / A arcs, compact numbers and flags; CoddUI's
`SVGPath` only knows M L H V Z), `NotebookChip` (a chip with a leading lamp / tag / icon),
`InlinePiece` / `InlineLayout` (flex-like one-line layout with shrink priorities), `HoverControl`,
`InlineLabel`, `WrapLabel` (fixed CSS line height, line clamp), `PlainSmallButton` (`.btn.sm.plain`),
`NotebookPillButton` (`.pillbtn.nb-sm` with icon, caps and `.nm` parts, cyan / dim tones),
`CopyRefSplitButton`, `DashedAddButton` (`.nb-addl`), `NotebookTextField` (an IME-safe `.input` with a
prefix and a key cap; CoddUI's `InputField` reports changes during a composition and pins a 30 pt
height), `NotebookMenuView` + `PopoverPanel` (custom popover menus).

## Accessibility (M5 D21)

Custom controls follow CoddUI's `KeyboardFocus` (`Internal/KeyFocus.swift`): every `HoverControl`
is a key view while Full Keyboard Access is on, presses on space / ⏎ and shows the focus style
for keyboard focus only (`KeyboardFocusTracker`, drawn on the layer). The lists column steps with
↑ ↓ (smart lists, BY PROJECT, LOCAL FILES rows; the section heads are disclosure triangles); note
list rows and menu rows stay out of the key loop (the list and the menu keep the focus and their
↑ ↓ ⏎). A note row reads as one element: title, time, kind, link, extra, warnings and AI access,
the snippet as its value, its selection exposed. Tag chips carry a `移除 #tag` action and pop their
menu on VoiceOver's show-menu; plain chips are text. `AccessibilityAuditTests` audits every view.
