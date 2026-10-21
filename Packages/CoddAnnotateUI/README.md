# CoddAnnotateUI

The ImageAnnotate screen (frozen artboard `design/artboards-src/ImageAnnotate.src.html`, SPEC §8
R6, M4 D10 / §3.3 / §3.7): the 52 pt top bar, the 48 pt tool strip, the canvas with the image in its
frame and the 380 pt panel (annotation list, send options, `AI 會收到`, Markdown source). AppKit,
`@MainActor`, built on CoddUI only. No CoddNotes or App types: the app maps its `ImageAnnotations`
to `AnnotationDocument` and back, and passes the CoddNotes §3.7 formatter and the block codec as
closures.

```sh
swift build --package-path Packages/CoddAnnotateUI --scratch-path .build-m4-annotate --build-tests
swift test  --package-path Packages/CoddAnnotateUI --scratch-path .build-m4-annotate
swift run   --package-path Packages/CoddAnnotateUI --scratch-path .build-m4-annotate codd-annotate-demo --fonts App/Fonts --snapshot <dir>
```

The demo writes `annotate-fit.png` (the artboard state: Fit = 50 %, item 1 selected),
`annotate-200.png` (200 %, centered on item 1) and `annotate-kinds.png` (an extra: a cyan text label
and a red box added, the arrow selected), all 1368 × 876 at 2×, offscreen; it never activates the
app. Without `--snapshot` it opens a window behind the others (not activated).

## API

```swift
public enum AnnotationKind: String, Sendable, CaseIterable { case rect, point, arrow, text }      // chipLabel, title
public enum AnnotationColor: String, Sendable, CaseIterable { case amber, cyan, danger, success, cream } // title
public struct AnnotationDraft: Sendable, Equatable, Identifiable {
    public var n: Int; public var kind: AnnotationKind; public var x, y: Int; public var w, h, x2, y2: Int?
    public var note: String; public var color: AnnotationColor; public var id: Int { n }
    // .rect(_:x:y:w:h:note:color:), .point, .arrow, .text; width, height, endX, endY; coordinateText
}
public struct AnnotationSendOptions: Sendable, Equatable { original = false, annotated = true, list = true }
public struct AnnotationDocument: Sendable, Equatable { pixelSize: CGSize; items: [AnnotationDraft]; send; item(_ n:) }
public struct ImageAnnotateHeader: Sendable, Equatable { crumbs; fileName; meta; originalFileName }
public enum AnnotateTool: Sendable, CaseIterable { case select, rect, point, arrow, text }        // key, title
public enum AnnotateZoom: Sendable, Equatable, CaseIterable { case fit, actual, double }        // title

@MainActor public final class ImageAnnotateView: NSView {
    public init(image: CGImage, document: AnnotationDocument, header: ImageAnnotateHeader)
    public private(set) var document: AnnotationDocument
    public let header: ImageAnnotateHeader
    public var tool: AnnotateTool; public var zoom: AnnotateZoom; public var selection: Int?
    public var currentColor: AnnotationColor                       // new items; picking one recolors the selection
    public var previewText: ((AnnotationDocument) -> String)?      // AI 會收到 (CoddNotes §3.7 formatter)
    public var markdownSource: ((AnnotationDocument) -> String)?   // the codd-annotations block (CoddNotes codec)
    public var onChange: ((AnnotationDocument) -> Void)?
    public var onDone: ((AnnotationDocument) -> Void)?
    public var onCancel: (() -> Void)?
    public var statusText: String { get }                          // "標註模式 · 3 個標註"
    public var canvasScale: CGFloat { get }                        // 0.5 = 顯示 50%
    public override var undoManager: UndoManager? { get }          // its own
    public func focusCanvas(); public func centerOnSelection(); public func commitPendingEdits()
    public func undo(); public func redo(); public func done(); public func cancel()
}
public enum ImageAnnotateSamples   // made-up R6 data: document, header, previewText, markdownSource, placeholderImage()
```

## Behaviour

- **Coordinates**: integers in ORIGINAL image pixels, origin top-left, clamped to `0…width` ×
  `0…height` (a rect stays inside the image and is at least 1 × 1). `n` is the creation order;
  deleting renumbers the rest. The initializer renumbers and takes the image's size when
  `pixelSize` is zero.
- **Zoom**: Fit is the largest scale ≤ 100 % at which the frame, the origin labels and the caption
  fit the stage with 40 pt margins, floored to 5 % steps (1 % under 10 %), so the caption reads a
  round number (`顯示 50%` on the artboard's 940 × 824 stage). 100 % = one pixel per point, 200 %;
  larger than the stage scrolls; changing zoom keeps the visible center. Pixels are drawn crisp
  from 100 % up.
- **Tools**: rect by drag (⇧ square), point by click (drag to place it before release), arrow by
  drag (⇧ 45° steps, the head pulled back along the ray when clamped), text by click with an inline
  field (⏎ commits only without marked text, ⎋ cancels, leaving the field commits; empty text
  creates nothing). Drags under 3 pt draw nothing. The select tool picks pins, points, arrow lines,
  labels and box edges first (topmost first), then box interiors (smallest first), so a point inside
  a box stays reachable; drag moves, the four 9 pt corner handles resize (⇧ keeps the ratio), a
  selected arrow shows both endpoint handles; a 2 pt jitter is not an edit. The coordinate tooltip
  sits under the selection. ⌫ / ⌦ delete, ⎋ cancels a drag, else deselects, else = 完成.
- **Keys**: V R P A T, ⌫ / ⌦ and ⎋ only while the canvas itself is first responder (it takes focus
  when the view enters a window and on every canvas click). ⌘Z / ⌘⇧Z (`performKeyEquivalent`, and
  `undo:` / `redo:` from the app's Edit menu) undo the document on the canvas and the typing of a
  focused field inside the screen; nothing while an input method composes. M5 (D21, no mouse
  needed): ⏎ on the canvas adds the current tool's item at the visible center (a box a fifth of
  the image, a point, a rightward arrow; the text tool opens its field there), ← → ↑ ↓ move the
  selected item one pixel (⇧ ten), one undo step each. Under Full Keyboard Access the tool and
  zoom controls, the color button, the collapsed rows (↑ ↓ step), the send options and the
  Markdown disclosure are key views; VoiceOver reads every pin as an image (`標註 n · 類型：說明，
  座標`) that selects on press, and the zoom switch as one radio button per zoom.
- **Panel**: the selected item is expanded (type chip + name, `已選取`, `▾` collapses; X / Y / W / H,
  arrow X1 / Y1 / X2 / Y2, point and text X / Y fields commit on ⏎ or blur, full-width digits and a
  trailing `px` accepted, invalid input restored, out-of-range values clamped, ⎋ restores; the
  comment commits on blur, on a selection change, on `完成` and before undo, never with the
  composing range); the others are collapsed rows that select on click. Edits always land on the
  item they were typed for (a pending edit is committed before the selection changes). Send options,
  `AI 會收到` (styled by pattern: `[image]` / sizes dim, paths and types cyan, numbers amber, comments
  cream, 4 ch hanging indent, a comment that does not fit after its coordinates starts on the next
  line, the home folder shown as `~`) and the Markdown disclosure follow the document live.
- **Undo**: every create / move / resize / endpoint move / delete / coordinate / comment / color /
  send-option change is one step (named, e.g. `新增標註`) on the view's own `UndoManager`
  (`groupsByEvent = false`, explicit groups), followed by `onChange`; undo and redo restore the
  selection too and also call `onChange`. Typing in the fields and the comment has its own undo
  stacks. A drag reports once, at mouse-up.
- **Never** activates the app, orders a window front or writes anything; the color menu is an
  `NSMenu` popped up from the strip button.

## Integration notes (for I1b)

- Map `ImageAnnotations` ⇄ `AnnotationDocument` (unknown JSON keys are the app's to keep), pass the
  CoddNotes formatter and codec as `previewText` / `markdownSource`, write the block on `onDone`
  (one undoable edit of the note text, D10), discard on `onCancel`.
- The status bar shows `statusText` + the app's save state; the view does not draw a status bar.
- Call `commitPendingEdits()` before reading `document` outside `onDone` (mode switch, quit).
- `undoManager` is the screen's own; the app's Edit menu reaches it through the responder chain.
