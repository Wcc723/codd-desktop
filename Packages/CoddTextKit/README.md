# CoddTextKit

The notebook's Markdown editor (M4 C4, D11): an `NSTextView` forced into **TextKit 1** with a live
preview of the Notebook artboard's document column, IME-safe editing commands (注音 first), block
decorations (figures with annotation overlays, the title chips row, code blocks), a line-based block
parser with incremental reparse, a read-only renderer for cards and a small fenced-code highlighter.
AppKit + CoddUI only: no CoddNotes, CoddCore or App types; the app maps its data in through
closures and `NSView` slots.

```sh
swift test --package-path Packages/CoddTextKit --scratch-path .build-textkit
swift run  --package-path Packages/CoddTextKit --scratch-path .build-textkit codd-markdown-demo --fonts App/Fonts --snapshot <dir>
```

The demo renders SPEC §5 n1 (generated 750 × 1334 screenshot with the three R6 annotations, a chips
row and an annotation panel) offscreen at 760 × 820 (2x): `notebook-live.png` (caret on the raw
`**Safari 底部工具列展開時**` line), `notebook-source.png`, `notebook-folded.png`, `notebook-empty.png`.
Without `--snapshot` it opens a window for a manual 注音 try (it activates: a manual tool only, never
run by automation).

## API

| Type | What it is |
|---|---|
| `MarkdownEditorView` (`@MainActor`, `NSView`) | the editor in its own scroll view |
| `MarkdownEditorMode` | `.livePreview`, `.source` |
| `MarkdownCaret` | 1-based `line`, `column` (grapheme clusters), `selectionLength` (UTF-16) |
| `MarkdownPastedImage` | `data`, `typeIdentifier` (UTI), `suggestedName`, `fileURL` (file pastes; `data` memory-mapped) |
| `ImageOverlayShape` | `rect` / `point` / `arrow` / `text`, numbered, ORIGINAL image pixels, optional color name |
| `MarkdownImageInfo` | `path`, `image` (nil while decoding), `pixelSize` (original), `caption`, `overlay` |
| `MarkdownAccessorySizing` | an accessory's height for a width (else Auto Layout fitting height, else frame height) |
| `MarkdownEditorStyle` | fonts, colors, metrics; `.notebook` (the artboard via CoddUI), `scaled(by:)` |
| `MarkdownBlockKind`, `MarkdownBlock` | kinds; whole-line UTF-16 ranges; `inlineMarks` hidden off the caret |
| `MarkdownBlockParser` | `blocks(in:)`, `reparse(_:text:edited:delta:)` (both also with `hiddenFenceInfoStrings:`) |
| `MarkdownRender.attributedPreview(_:style:maxLines:)` | the editor's styling with the syntax removed (cards) |
| `MarkdownCodeHighlighter.spans(code:language:)` | `[(NSRange, Token)]` for js / ts, css, swift, python, shell, json, html |
| `MarkdownSamples` | SPEC §5 n1 design data + the generated placeholder screenshot |

`MarkdownEditorView` members:

```swift
init(style: MarkdownEditorStyle = .notebook)
var mode: MarkdownEditorMode                     // the app's ⌘E item sets it; applied after a composition
private(set) var text: String                    // committed text only
var isComposing: Bool                            // marked text exists
func load(_ text: String, selection: NSRange?)   // new document: no undo step, clears undo, folds, image cache
func applyExternalText(_ text: String)           // same document changed on disk: minimal undoable replace, selection/scroll kept
func replace(_ range: NSRange, with: String, actionName: String)   // one undoable edit (annotation block rewrite)
func insertAtCaret(_ string: String)             // replaces the selection; at the end when the user never placed a caret
func insertImageMarkdown(alt: String, path: String)                // D9 placement (below)
func reloadImage(path: String?)                  // drop cached info for a path (nil = all) and redraw
func focus(); func setFontScale(_ scale: CGFloat)
func setFolded(_ folded: Bool, headingAt location: Int); var foldedHeadingLocations: [Int]
func invalidateAccessoryLayout()                 // an accessory changed its height
var imagePathAtCaret: String?; func caretRect() -> NSRect?
var onTextChange, onCaretChange, onPasteImage, imageResolver, imageAccessoryProvider,
    titleAccessory, onOpenLink, onEditImageAnnotations, onCommandReturn
var hiddenFenceInfoStrings: Set<String> = ["codd-annotations"]
var placeholderTitle = "標題"; var revealsCaretLineWhenInactive = false
var textViewForTesting: NSTextView
```

Callbacks: `onTextChange` fires for every committed document change (typing, paste, delete, undo,
task toggle, `replace`, `insertAtCaret`, `insertImageMarkdown`), never while composing and never for
`load` / `applyExternalText` (the app knows that text) — unless a composition was committed while
they waited, then once with the merged text. `onOpenLink` gets the URL as written (`codd://note/<id>`
for a chip, `[[note:<id>]]` included). `onEditImageAnnotations` gets the image line's relative path
(⌘⇧A on the image line or its hidden block, double click on the figure). `onCommandReturn` is ⌘⏎.

## Live preview

Rendering follows the Notebook artboard document column (`.nb-doc` padding 22 / 40 / · / 44, gaps
10): title 22 pt Space Mono cream (line height 1.3); H2 16 pt amber with a dashed `--line-bright`
rule above (margin 8, padding 12) and the `▾` / `▸` fold glyph 24 pt left of it (click folds the
section up to the next heading ≤ 2; view state only); H3–H6 display amber-dim; paragraphs 13 pt /
1.75 bone with the helmet's .01em tracking; bold cream; italic as an oblique; inline code in the
helmet `code` box (amber on #050505, 1 px `--line`, 6 pt to the box edge); links cyan; note
references (`codd://note/<id>`, `[[note:<id>]]`, links to them) in the amber chip look; bullets as
5 × 5 amber-dim squares; ordered numbers amber-dim; tasks `[x]` (amber bold x) / `[ ]` (dim) with the
text at 36 pt, done text dimmer with a `--line-bright` strike; quotes with a 2 pt amber-dim bar;
dashed rules; tables as monospaced text with dim pipes; fenced code on #000 in a 1 px border,
12 / 1.6, with the caps language label top right and `MarkdownCodeHighlighter` colors.

- **Hiding** is glyph generation only (the text never changes): `NSLayoutManagerDelegate.shouldGenerateGlyphs`
  turns hidden characters into control glyphs and `shouldUse(_:forControlCharacterAt:)` gives them
  zero advance. (Not `.null`: TextKit moves null glyphs at a line start into the previous line's
  fragment, and the line would then get its paragraph's head indent.) Marks carry no tracking kern,
  so a hidden mark takes no space at all.
- **What is hidden**, off the caret's blocks: `inlineMarks` (`**`, `*`, `_`, `~~`, backticks,
  backslashes, `## `, link syntax, the list / quote prefix), a fence's own lines (when it has code),
  a `---` rule's text, a resolved image line's text, and always (live preview) a `codd-annotations`
  block after an image and folded sections. An unresolved image (`imageResolver` nil) stays visible
  text.
- **Reveal**: the blocks the selection touches show their syntax (marks in `--dimmer`) with the
  `.nb-raw` band (amber gradient + 2 pt amber-dim bar, full width) — only while the editor is first
  responder (`revealsCaretLineWhenInactive` for snapshots). List / task / quote prefixes stay
  hidden on the caret line (the bullet stays drawn); a code block reveals its fences when the caret
  is anywhere in it. Hidden `codd-annotations` blocks are revealed only in source mode.
- **Caret**: a 2 pt amber bar with glow sized to the text line (`drawInsertionPoint`); it never
  rests in hidden text: a hidden fence or folded section is skipped in the direction of travel, a
  hidden list prefix moves it to the item text (← from there goes to the line above). Backspace at
  an item's text start removes the marker.
- **Line heights** are set in `shouldSetLineFragmentRect`: fixed text line box per block kind,
  baseline from CSS half-leading (negative leading included), block gaps / margins / rules /
  code padding above or below, zero height for hidden lines, and space for block decorations.
- **Source mode** (⌘E): nothing hidden, JetBrains Mono 12.5 / 1.6 everywhere, marks dimmed, headings
  amber, code highlighted, no decorations, no accessories.

## Decorations

- **Title accessory** (`titleAccessory`, the chips row): placed under line 1, 10 pt below the
  title; its height reserved in line 1's fragment. Hidden in source mode.
- **Figures**: an image line becomes the `.nb-figrow`: #000 plate, 7 pt padding, 1 px amber-dim
  border, 3 pt `rgba(255,184,74,.08)` ring; tall screenshots at most 220 pt high, a @2x image never
  larger than its point size, the image width leaves `accessoryMinWidth` (220) + 18 for the
  accessory; caption (11 pt dim, the info's `caption`) 6 pt under the plate; the accessory
  (`imageAccessoryProvider`, created lazily, cached per path) right of the figure, top aligned, as
  wide as what is left. On the caret the raw line shows above the figure.
- **Overlay** (`MarkdownImageInfo.overlay`, original pixels → view points): rect = 1.5 pt box (10 %
  fill, black outer ring) with its numbered 18 pt pin on the top-left corner; point = pin; arrow =
  black 3.5 pt halo + 1.5 pt line + filled head, pin at the start; text = label on a black plate with
  its pin. Colors by name (`amber` default, `cyan`, `danger`, `success`, `cream`).
- Code plates, inline code and chip boxes are drawn by the layout manager under the glyphs; the
  caret band, rules, bullets, fold glyphs, code labels and figures by the text view (the layout
  manager's passes are clipped to the text container; the clip `NSTextView.draw` leaves is restored
  first).

## IME rules (non-negotiable, D11)

- No `keyDown` interception: every key goes through `interpretKeyEvents`; list continuation lives
  in `insertNewline`, indent in `insertTab` / `insertBacktab`, ⌘⏎ / ⌘B / ⌘I / ⌘⇧A in
  `performKeyEquivalent` (only while first responder); every one checks `hasMarkedText()` first.
  Return with marked text commits the composition (no newline, no list item); ⌘⏎ with marked text
  is swallowed; Esc goes to AppKit while composing, else up the responder chain.
- While marked text exists nothing is restyled, revealed / hidden, replaced or reloaded:
  character edits only shift block ranges (`provisionalShift`) and are reparsed at the commit;
  `load`, `applyExternalText`, `replace`, `insertAtCaret`, `insertImageMarkdown`, `reloadImage`,
  a new resolver / provider, `mode`, `setFontScale` and `hiddenFenceInfoStrings` wait and run in
  order at `unmarkText` / the committing `insertText` (or a cancelled composition); fold clicks are
  ignored. No timers. `onTextChange` never fires while composing.
- A waiting `applyExternalText` merges: the external change is applied to the user's text and a
  composition committed meanwhile is kept (one ⌘Z restores the user's text).
- Smart quotes / dashes, text replacement, spelling correction, data / link detection, completion,
  inline prediction and Writing Tools are off. Marked text is amber, underlined. The input method's
  candidate window is placed under the text line (`firstRect`), not under a figure or chips row
  sharing its fragment.
- The pasteboard is read only in the user's paste / drop: image files and image data (PNG, TIFF,
  JPEG, HEIC, GIF, WebP) → `onPasteImage`; rich text → its plain text; other files → their paths;
  line endings become LF.

## Editing

Return continues bullets (same marker and indent), ordered items (`n + 1`, same delimiter), tasks
(`- [ ] `) and quotes; Return on an empty item removes its marker; Shift / Option+Return is a plain
LF; in code a new line keeps the indentation. Tab / ⇧Tab indent / outdent the touched list lines by
two spaces (one undo step); elsewhere Tab is a tab. ⌘B / ⌘I wrap the selection in `**` / `*`, or
unwrap it (empty selection: the pair with the caret inside). A click on a task box toggles it (one
undo step, `切換待辦`). Inserted line endings are LF; loaded text is kept as given (CRLF parses).
Each document has its own undo manager (`load` clears it).

`insertImageMarkdown(alt:path:)` (D9): `![alt](path)` on its own line at the caret (line feeds
added as needed, caret after it); at the end when the note changed since the paste that asked for
it, or when the user never placed a caret since `load`. One undo step `貼上圖片`.

## Integration notes (I1a)

- Load the body without its frontmatter (a leading `---` block is parsed as `frontmatterLike` and
  shown dimmed, not hidden). Seed a new note with `# ` and the caret after it: the title look and
  the `標題` placeholder need an H1 on line 1.
- `imageResolver` runs during glyph generation and layout: it must be fast and must not call back
  into the editor. Return the original pixel size (from the annotation block or the image header)
  and an `NSImage` that decodes lazily (or nil, then `reloadImage(path:)` when decoded).
- Accessories: conform to `MarkdownAccessorySizing` (or use Auto Layout); call
  `invalidateAccessoryLayout()` when their height changes.
- ⌘E (mode), ⌘⇧A (`imagePathAtCaret` / `onEditImageAnnotations`) and ⌘⏎ (`onCommandReturn`) can
  also be driven by main-menu items; the editor's own key equivalents act only while it is first
  responder and never with marked text.

## Numbers (debug build, this Mac, other agents compiling meanwhile)

1 MiB note (652,399 UTF-16 units, 10,804 blocks, 200 unresolved image lines with annotation blocks):
load ≈ 246 ms best / 247 ms median of 5 (first load ≈ 270 ms: font caches); a keystroke in its
middle restyles in p50 7.4 ms, p95 13.8 ms, max 24 ms (incl. the visible relayout); a newline +
`## ` heading 7.7 ms. About a third of the load is AppKit's own attribute fixing (CJK font
substitution), which happens whatever the editor does.

## Known limitations

- TextKit 1 with non-contiguous layout: the scroll height of a long note with figures is estimated
  until background layout reaches them.
- No pointing-hand cursor over links, task boxes and fold glyphs.
- Folding is H2 only and view state only (not saved).
- Inline Markdown is a pragmatic subset (not CommonMark): no setext headings, no indented code
  blocks, no HTML; tables are not formatted, only monospaced.
- Long code lines wrap (the artboard's `pre` does not).
