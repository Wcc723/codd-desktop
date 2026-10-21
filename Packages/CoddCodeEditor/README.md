# CoddCodeEditor

The file editor's code view (M4 C5; D11, D27, D28; the FileEditor artboard's `.fe-code`): a TextKit 1
`NSTextView` with the artboard's gutter, native syntax highlighting, the find / replace widget,
inline AI diff hunks with `[還原此段]` `[接受]`, and the 14 pt overview ruler. AppKit, built only on
CoddUI's public API; no CoddCore / CoddFiles / App types: the app maps its data in (integration I3).

```sh
swift test --package-path Packages/CoddCodeEditor --scratch-path .build-code
swift run  --package-path Packages/CoddCodeEditor --scratch-path .build-code codd-code-demo --fonts App/Fonts --snapshot <dir>
```

The demo writes `punch-vue.png` (the artboard's `punch.vue` lines 13–49 at 1100 × 760: hunk
`@@ -40,2 +40,4 @@` in pink, the `.mod` bar on line 33, find `sticky` 3/7, the caret on line 42),
`find-states.png` (replace row, invalid `.*` pattern), `typescript.png`, `json.png` and `python.png`.
Without `--snapshot` it opens a window (a manual tool; it refuses to run under `CLAUDECODE` /
`CODD_BACKGROUND`, where it would take focus).

## Contract

| Type | What it is |
|---|---|
| `CodeLanguage` | 27 cases (`vue` … `sql`, `plain`), `displayName` for the status bar (`Vue`, `JavaScript`, `Plain Text`). |
| `CodeLanguageDetector.language(fileName:firstLine:)` | Special names (`Makefile`, `Dockerfile`, `.zshrc`, `Gemfile`, `.env*` …), then the extension, then a shebang (`env -S` handled) or an `<?xml` / `<!DOCTYPE html>` / `<?php` prologue; else `plain`. Names without a lexer of their own map to the closest one (Makefile / Dockerfile → `shell`, INI-like → `toml`). |
| `SyntaxHighlighter(language:)` | `tokens(line:startState:) -> (tokens, endState)`: one line (no terminator), UTF-16 ranges sorted and disjoint, plain runs omitted, touching runs of one class merged. `tokenize(_:)` lexes a whole text (tests, samples). `LexState.initial` starts a file. |
| `SyntaxToken` | `keyword string comment number punctuation tag attribute directive function property plain` → the artboard's `.k .s .cm .nu .p .tg .at .dv .fn .pr` (`CodeEditorStyle.color(for:)`). |
| `FindOptions`, `FindEngine` | `matches(in:query:options:)` (literal or ICU regex, case, whole word; empty matches skipped; `FindError.invalidPattern` for a bad `.*`), `replacement(for:in:query:template:options:)` (`$0` `$1` … in regex mode, the template as typed otherwise). Whole word: a match may not continue a Latin / digit / `_` word; CJK characters are words of their own (`API` matches in `修正API錯誤`, not in `myAPI`). |
| `CodeCaret` | 1-based line and column; column and `selectionLength` in UTF-16 units. |
| `InlineDiffHunk`, `InlineDiffHeader`, `HunkAction` | `newLines`: 0-based lines of the current text (empty = pure deletion before `lowerBound`, at the end when it is the line count), `deletedLines`, the bar's header (`tagColor`, `showAIChip`, `who`, `range`, counts, `position`). |
| `OverviewMark` | `hit / aiChange / added / removed / cursor`, 0-based `line`, `lineCount`, optional color. |
| `CodeEditorStyle.fileEditor` | Every token of the artboard (colors, 12.5 pt / 20 pt rows, 46 + 16 pt gutter, tints, caret, hits, hunk bar, ruler, find widget). |
| `CodeEditorView` | Below. |

`CodeEditorView` (`@MainActor`, `init(style: = .fileEditor)`):

- `load(_:language:readOnly:plainMode:)` replaces the text (no undo step, undo cleared, no
  `onTextChange`), caret at the start, scrolled to the top, hunks / markers / ruler marks cleared;
  a composition in progress is discarded. Line endings become LF (the codec restores them on save).
- `text` (committed only), `isComposing`, `language` (re-highlights), `fontSize` (rows scale:
  `round(20 × size / 12.5)`), `readOnly`, `plainMode` (read only; no highlighting, no wrapping),
  `wrapsLines` (default off, the artboard's `white-space: pre`), `showsInactiveCaret` (snapshots).
- `applyExternalText(_:)`: a clean reload from disk; only the changed middle is replaced (colors,
  states and layout outside it survive), caret line / column and scroll position kept, one undo
  step `重新載入`, no `onTextChange`; waits while an input method composes.
- `replaceLines(_:with:actionName:)`: one undoable edit (`還原此段`), reported through
  `onTextChange`; an empty range inserts. Ignored when read-only or out of range; waits while composing.
- `onTextChange` (typing, paste, delete, undo / redo, replace, `replaceLines`; never marked text),
  `onCaretChange`, `caret`, `goTo(line:column:)`, `scrollToLine(_:)`.
- Find: `showFind(replace:query:)` (nil query: a single-line selection seeds it), `hideFind()`,
  `findNext()` / `findPrevious()` (⌘G / ⇧⌘G, Return / ⇧Return in the field), `findOptions`,
  `findQuery`, `onFindChange(query, options, current, total)` (`current` 1-based, 0 for none;
  `total` -1 while the pattern does not compile). The view answers ⌘F, ⌥⌘F (with replace), ⌘G,
  ⇧⌘G as key equivalents while it has focus and nothing is composed; Esc closes the widget.
- Inline diff: `setInlineDiff(_:)` (out-of-range hunks dropped), `inlineDiff` (after edits shifted or
  dropped some), `onHunkAction(id, .revert / .accept)`, `scrollToHunk(_:)`.
- `modifiedLineMarkers: [Int: NSColor]` (0-based lines; `.mod` 3 pt bars outside a shown hunk's added
  lines; they follow line insertions), `overviewMarks` (the owner's AI / added / removed marks; hits and
  the caret are drawn by the view).
- `textViewForTesting`.

## How it works

- **TextKit 1** (asserted: `textLayoutManager == nil`): an explicit `NSTextStorage` →
  `CodeLayoutManager` → `NSTextContainer` stack, contiguous layout (lazy from the top; non-contiguous
  layout estimated far fragments ~4.6 × too short, which broke scrolling and the decorations).
- **IME (D11)**: the composer's rules. No `keyDown` interception; Return / Esc while marked text
  exists commit or go to AppKit; nothing is restyled, replaced or reloaded while marked text exists
  (edits update the line index and state cache as data; the flush runs when the composition
  ends); `onTextChange` only for committed text; smart substitutions, completion, spelling and
  Writing Tools off. The find and replace fields are `NSTextField`s whose cell hands out the
  widget's own TextKit 1 field editor, which searches only on committed text.
- **Rows**: the layout manager's delegate gives every fragment 20 pt and a CSS-centered baseline,
  and adds a decoration's height above a hunk's anchor line (`shouldSetLineFragmentRect`), or below
  the last fragment for deletions at the end. The gutter, the text background (tints, current line,
  removed lines at .72 with their own highlighting from the anchor's lexer state, find hits) and
  the hunk bars all draw from one row enumeration. Selection backgrounds are clipped to text rows;
  the caret (amber 2 × 16 pt, glow, 1 s blink while focused, solid under Reduce Motion) is drawn by
  the view in the text row. Comments are slanted at draw time (JetBrains Mono Italic is not bundled).
- **Highlighting (D28)**: hand-written per-line lexers (C family with template literals, JSX, regex
  literals, raw / triple-quoted strings; markup with Vue directives, `{{ }}` and embedded
  `<script lang>` / `<style lang>` regions; CSS / SCSS; JSON(C); YAML; TOML; Python; Ruby; shell with
  heredocs; SQL; Markdown with front matter and fenced code in the fence's language). Line-start
  states are cached; after an edit lexing restarts at the edited line and stops once a computed
  state equals the cached one past the edit. Tokens become **temporary attributes** for the visible
  lines ± 200; texts over 2 MiB color only the visible lines (from the initial state when they are
  more than 4,000 lines below the lexed part).
- **Find**: hits are amber 16 % boxes with a 1 px amber 50 % inset, the current one solid amber with
  black text and a glow; replace and replace-all are one undo step each (replace-all replaces the
  span from the first to the last match in one edit).
- **Overview ruler**: the vertical scroll indicator (no scroll bar, as in the artboard): viewport
  thumb, hits, AI changes, added / removed, caret; click or drag scrolls.

## Numbers (debug build, this Mac)

1 MB JavaScript, first highlighted screen 46–48 ms (budget 150); a keystroke median 2.0 ms, p90
2.5 ms, max 6 ms (budget 16); jumping to the last line of that file ~310 ms (lays out and lexes all
of it once).

## Known limits

- Vue / HTML attribute values that span lines are lexed per line from a fresh JavaScript state;
  `{{ }}` contents likewise. JSX detection is heuristic (`<` in expression position), so a TSX
  generic arrow `<T,>(x) => x` reads as an element.
- Above 2 MiB a jump far below the lexed part colors those lines from the initial state (no
  background lexing catches up), so they can be wrong inside a block comment or string.
- An empty text cannot show a pure-deletion hunk (no line fragment to carry it).
- Columns count UTF-16 units; a tab is one column.
