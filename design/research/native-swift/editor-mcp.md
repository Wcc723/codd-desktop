# Native Notebook, File Editor and MCP in Swift: Research Report (2026-10-15)

**Recommendation:** build both the notebook and the file editor on one custom `NSTextView` running in TextKit 1 mode. Add tree-sitter for syntax highlighting, GRDB with an FTS5 trigram index for search, and a stdio MCP helper binary built on the official swift-sdk. Use Hummingbird on 127.0.0.1 only for the Claude Code `http` hooks, hosted in the process that survives app quit. Keep WKWebView+CodeMirror 6 as the planned fallback for the notebook only.

## 0. Checked on this machine (read-only)
- **Toolchain:** Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1 on arm64.
- **TextKit 1 is still supported.** In the macOS 27 SDK, `NSLayoutManager` is not deprecated, and `layoutManager(_:shouldGenerateGlyphs:properties:characterIndexes:font:forGlyphRange:)` is still there. That method is how you hide characters at the glyph level.
- **New TextKit 2 APIs, macOS 27.0 only:**
  - `-[NSTextView registerTextAttachmentViewProviderReusePolicy:forTextAttachmentViewProviderType:]`, with the policies `OnScrollingOutOfViewport` and `OnEditingInlineParagraphs`.
  - Viewport methods you can override in an `NSTextView` subclass: `textViewportLayoutControllerWillLayout`, `textViewportLayoutControllerDidLayout`, `configureRenderingSurfaceForTextLayoutFragment`.
  - The `NSTextViewportRenderingSurface` protocol.
- **System SQLite is 3.54.0 with FTS5.** I compiled a small Swift test against it with a trigram table:
  - `MATCH '注音輸'` finds the row.
  - `MATCH '筆記'` (2 characters) returns 0 rows.
  - `LIKE '%筆記%'` finds the row.
  - `highlight()` works.
- **PencilKit on macOS has no drawing canvas.** The SDK has `PKDrawing` and `PKStroke` but no `PKCanvasView`, so the image-annotation canvas has to be custom AppKit code.
- **Existing CODD code offers little to reuse here.**
  - The web notebook only renders with markdown-it; there is no editor engine.
  - The MCP server is Node stdio (`StdioServerTransport`) plus better-sqlite3, which maps directly onto a Swift stdio helper.

## 1. Markdown editor engine comparison

| Engine | CJK IME (marked text) | Large files | Live-preview fit | 2026 status | License |
|---|---|---|---|---|---|
| **NSTextView, TextKit 1** (`NSTextView(usingTextLayoutManager:false)`) | **Best.** Apple's own text-input implementation. CotEditor's main view is built on `NSLayoutManager`; its maintainer says they don't touch text input, and their recent Japanese IME bug (#1980) was macOS itself. | Good with non-contiguous layout (CotEditor-class). | **Best for hiding syntax off-caret** (glyph-level hiding, proven). Images via `NSTextAttachment` with a custom cell; overlays are positioned NSViews. | Apple; not deprecated in macOS 27 but gets no new features. | System |
| **NSTextView, TextKit 2** | Apple's implementation too. A marked-range timing quirk is reported (FB21230723). | Viewport-based layout, but known problems: estimated scroll height, extra-line-fragment bugs, silent fallback to TextKit 1 if `.layoutManager` is touched (this drops view attachments). | Hiding syntax needs custom layout fragments plus manual caret/selection handling (Apple DTS guidance). Neon's author hasn't found flicker-free per-keystroke highlighting. Plus side: macOS 27 attachment-view reuse suits images with annotations. | Apple's focus. | System |
| **STTextView 2.4.1** (2026-09-08; commits to 2026-10-06) | Implements text input itself, so IME correctness depends on the library. I found no public CJK IME issues, which says little either way. | Good; inherits TextKit 2 bugs (the author's own "TextKit 2: The Promised Land" post). | Gutter, multi-cursor, find/replace, attachment views, plugins (Neon/TreeSitter, Annotations, TextFormation). | Active. Requires macOS 14+. | **GPL-3.0 or paid commercial** |
| **CodeEditSourceEditor 0.15.2** (2025-09-16) on CodeEditTextView 0.12.1 (custom CoreText) | Had Chinese IME bugs (#26, #37) fixed by "Fix Marked Text Input" (#40, 2024). | Fastest for huge files (handles million-line files, per a CodeEdit developer). | Code-oriented, not a Markdown/rich-text engine. | README says "**not ready for production use**". Last release 2025-09; last commit 2025-12-31. Slowing. | MIT |
| **Runestone 0.5.2** | — | — | — | **iOS only** (`.iOS(.v14)`); the `mac` branch is unmerged. **Excluded.** | MIT |
| **WKWebView + CodeMirror 6** (@codemirror/view 6.43.14, 2026-10-07) | Workable but needs ongoing patching. CM6 had IME bugs at highlight/decoration boundaries (#1650, fixed in 6.39.7, Dec 2025; #1654; #1684, Mar 2026). MarkEdit (native macOS + WKWebView + CM6) shipped "Fix WebKit composition mode issues" (#1473, Jun 2026), "Prevent unwanted scrolling due to IME" (#1485) and "Harden IME issue fixes" (#1640, Jul 2026). | MarkEdit says 10 MB files open "in the blink of an eye" (their own claim). | Best ecosystem: Obsidian-style decorations, DOM/SVG widgets for image overlays, @codemirror/merge 6.12.2 for diffs. | Very active. | MIT |

WKWebView costs: an extra WebContent process (its memory is my estimate, not measured), an asynchronous JS bridge, and text controls that don't feel native (MarkEdit rebuilt its controls).

**Verdict for the notebook: a TextKit 1 `NSTextView` subclass.**
- The two hard requirements are Zhuyin IME correctness and hiding syntax off the caret. Only TextKit 1 `NSTextView` handles both with proven techniques: Apple's input path stays untouched, and glyph-level hiding works.
- Every other option moves IME or hiding risk into code you don't control.
- Put the text engine behind a small abstraction (ChimeHQ Glyph or TextStory) so the macOS 27 TextKit 2 attachment reuse can be adopted later.

**IME-safety rules for the native editor:**
- Never intercept `keyDown` for Return, Tab, Backspace or arrows. Put list continuation, task toggles and auto-pairing in `insertNewline(_:)`, `insertTab(_:)`, `doCommand(by:)` and `insertText(_:replacementRange:)`. Those only run after the IME has passed on the key.
- While `hasMarkedText()` is true:
  - Freeze the hide/reveal state of syntax.
  - Don't restyle the paragraph being composed; restyle after the text is committed.
- Use `addTemporaryAttributes` for colors. It doesn't edit the text storage, so the undo stack stays clean.
- Apply real font changes (for example heading size) only outside the marked range.
- Turn off smart quotes and text replacement by default (compare CotEditor #2020, where half-width quotes turned full-width).

**Parsing:**
- Use tree-sitter-markdown (v0.5.3, separate block and inline grammars) through SwiftTreeSitter 0.10.0 for fast per-keystroke updates.
- Use swift-markdown 0.9.0 for export if needed.

**Pasted images and annotations:**
- On paste, catch image data, write it to `assets/<sha256>.png`, and insert `![](assets/…)`.
- Draw the image plus a vector annotation layer (stored as a JSON sidecar file) in a custom attachment cell.
- Edit annotations in a separate custom NSView canvas. `PKDrawing` can serve as the stroke data model.

## 2. VSCode-like file editor
- **Same engine as the notebook,** so there is only one IME surface to test.
  - Highlighting: SwiftTreeSitter + Neon. Neon highlights lazily, only the visible range. Its README recommends TextStory's `TSYTextStorage` for flicker-free highlighting on TextKit 1.
  - Grammars: use individual SPM grammar packages. The CodeEditLanguages bundle is stale (0.1.20, Nov 2024).
- **Find/replace:** use the built-in `NSTextFinder` find bar. For project-wide search, run `rg --json` (VS Code itself uses ripgrep).
- **Line numbers:** an `NSRulerView` subclass. **Tabs:** a custom tab strip; only the visible tab needs a live text view, while the others keep their text storage and undo manager.
- **Huge files:** above a size threshold (for example 5–10 MB), switch to a plain mode with no highlighting and no wrapping.
- **Alternatives considered:**
  - STTextView + Plugin-Neon: fastest to feature parity (multi-cursor, gutter, annotations). Only if you accept GPL or buy the commercial license, and it must pass the same IME tests.
  - CodeEditSourceEditor: has the most IDE features, but it calls itself not production-ready and releases have stalled. Not recommended.
- **Diff view of AI changes:** no native AppKit diff component exists, so build one.
  - Line diff with `git diff --no-index --histogram`, or Swift's `CollectionDifference` (Myers algorithm), refined to word level.
  - Show it unified, or side by side in two read-only text views with background highlights and synchronized scrolling.
  - Capture exact AI edits from hooks: PreToolUse/PostToolUse give Write (`file_path`, `content`) and Edit (`file_path`, `old_string`, `new_string`, `replace_all`) plus `tool_use_id`.
  - Snapshot the file before each edit at PreToolUse. That gives a diff per tool call, even outside git.
  - Fallback: @codemirror/merge in a WebView.

## 3. MCP server and local HTTP

**Official Swift SDK (modelcontextprotocol/swift-sdk):**
- Version 0.12.1 (2026-05-07), client and server, implementing the 2025-11-25 spec.
- Version 0.11.0 (2026-02-19) added server-side HTTP transports:
  - `StatefulHTTPServerTransport`: sessions, SSE streaming, resumable streams.
  - `StatelessHTTPServerTransport`: plain request/response.
- Both are framework-agnostic (`handleRequest(HTTPRequest) -> HTTPResponse`); its own example server runs them on raw SwiftNIO.
- License is moving from MIT to Apache-2.0.

**The SDK is behind the current spec.**
- The MCP 2026-07-28 spec is a major break:
  - Removed: the `initialize` handshake and the `Mcp-Session-Id` header.
  - Replaced: the GET stream, by `subscriptions/listen`.
  - Added: `server/discover` and a required `resultType` on results.
- The C#, TypeScript, Python and Go SDKs are updated. Swift has only a work-in-progress branch (`feat/intermediate-updates-to-newest-protocol`).
- Main's last commit is 2026-04-29, and about 10 pull requests from Sep 2026 are unmerged.
- The spec requires clients to stay backward compatible, so a 2025-11-25 server should still work with Claude Code 2.1.300. That needs testing.

**MCP recommendation: a stdio helper, `codd-mcp`.**
- A small executable using the SDK's stdio transport, pinned to exactly 0.12.1, launched by Claude Code for each session.
- It keeps working while the app is quit, crashed or updating, needs no port, token or origin checks, and matches the current Node design.
- The tool set is small (list, search, read, append notes). Keep the SDK behind a thin adapter; the fallback is hand-written JSON-RPC over stdio.

**Hooks endpoint:**
- Claude Code `type: "http"` hooks POST the event JSON to a URL. Non-2xx responses and refused connections are non-blocking.
- **`SessionStart` does not support http hooks** (only command and mcp_tool), so it needs a command hook (a tiny binary or curl).
- Settings to use: `headers` with `allowedEnvVars` for a bearer token, and `allowedHttpHookUrls` as an allowlist.
- Host the endpoint in the long-lived PTY daemon, not the UI app:
  - Bind to 127.0.0.1 only, use a random port, and write the endpoint and token to a file with 0600 permissions.
  - Check the Host and Origin headers to block DNS-rebinding attacks.
- PreToolUse hooks make Claude wait, so the handler should queue the event and immediately return an empty 200.

**HTTP server library:**
- **Hummingbird 2.28.0** (2026-10-13, Apache-2.0, built on SwiftNIO, async/await, can stream SSE): **pick this.**
- Raw SwiftNIO 2.104.0: most control, more boilerplate.
- Vapor: 5.0.0-beta.4, mid-transition and heavy. Avoid for now.
- Network.framework: TCP only, no HTTP parser or SSE; you would write HTTP yourself.
- FlyingFox 0.27.1 (MIT): a lighter alternative.
- swift-server/swift-http-server 0.3.0: too early.

## 4. SQLite, search and file watching

**Database:**
- **GRDB 7.11.1** (2026-06-18, MIT):
  - Concurrent reads in WAL mode (`DatabasePool`) and live queries (`ValueObservation`).
  - FTS5 enabled in its SPM build.
  - Custom FTS5 tokenizers can be written in Swift.
- There is no `.trigram` helper yet (PR #1655 is still open); use `FTS5TokenizerDescriptor(components: ["trigram"])` or raw SQL.
- SwiftData has no FTS5 and no raw SQL, so it doesn't fit. sqlite-data 1.12.1 (Point-Free, built on GRDB) is optional SwiftUI convenience.
- **Two processes write to the database** (the MCP helper and the daemon). GRDB's change observation does not see writes from other processes.
  - Use WAL mode with `busyMode = .timeout` and persistent WAL.
  - Notify the app with a Darwin notification or FSEvents.

**CJK search:**
- Use an FTS5 trigram table over the notes.
- If every search term is 3+ characters, use `MATCH` with bm25 ranking and highlight/snippet.
- 1–2 character terms are very common in Chinese (筆記, 注音), and `MATCH` returns nothing for them. Route those to `LIKE '%…%'`, which scans the whole table.
- If scanning gets slow, add a second table with a Swift tokenizer that indexes CJK character pairs (bigrams).
- Limitations: `LIKE` with an `ESCAPE` clause can't use the index, and a 2023 report of overlapping `highlight()` matches is worth re-checking.

**File watching:**
- **FSEvents** (file-level events, 50–100 ms latency) for project trees and the notes folder.
- **`DispatchSource.makeFileSystemObjectSource`** (write/rename/delete) for each open tab.
- Handle atomic saves (a rename means reopening the file descriptor), and ignore the app's own writes (compare mtime or hash).
- When Claude's Write tool changes an open file, show "changed on disk", then offer reload or diff.
- Ship as a non-sandboxed Developer ID app. PTYs and editing ~/.claude rule out the App Sandbox anyway.

## 5. Recommended stack
- **UI:** AppKit core with SwiftUI for the surrounding chrome. Minimum macOS 26; macOS 27 if you later adopt the new TextKit APIs.
- **Text:** one `CoddTextView` (an `NSTextView` subclass in TextKit 1 mode) for both notebook and code, plus TextStory, SwiftTreeSitter 0.10.0, Neon, tree-sitter-markdown, `NSTextFinder` and `NSRulerView`.
- **Diff:** `git diff --histogram` or `CollectionDifference`, shown in two read-only text views.
- **Data:** GRDB 7.11.x in WAL mode, FTS5 trigram plus the short-query fallback, FSEvents and DispatchSource.
- **MCP:** a `codd-mcp` stdio helper on swift-sdk 0.12.1 (pinned) through a thin adapter.
- **Hooks:** Hummingbird 2.28 in the PTY daemon on 127.0.0.1 with a bearer token, plus a command hook for `SessionStart`.

## 6. Risks
- **Live preview is the biggest cost.** Hiding syntax, attachments and overlays are all custom code, and the IME edge cases live there.
- **TextKit 1 is legacy.** New Apple features (such as attachment-view reuse) are TextKit 2-only, so keep the abstraction layer.
- **Swift MCP SDK lag and API churn** (it is pre-1.0). Pin the version and keep the adapter thin.
- **STTextView licensing** (GPL or paid) if you choose it.
- **Short-query CJK search** depends on full scans. Measure it on the real notes.
- **Hook noise when the daemon is down:** the errors are non-blocking, but I haven't verified whether Claude's terminal shows them.
- **WebView fallback:** it brings back the composition-bug maintenance that MarkEdit is still doing.

## 7. Spike gate (1–2 weeks; these are targets, not measurements)
- **IME tests pass:** zero lost or duplicated characters, and the candidate window appears at the caret.
  - Input methods: Apple 注音, 倉頡, 速成, Pinyin, 小麥注音 (McBopomofo), 威注音 (vChewing), Japanese Kotoeri, Korean.
  - Positions: empty line, line start, inside `**bold**`, next to hidden syntax, task item, table cell, next to an image.
- **Speed:**
  - A 1 MB note with 200 images: 95th-percentile keystroke-to-paint under 8 ms.
  - Scrolling at 120 fps with no hitches.
  - A 10 MB source file shows its first screen highlighted in under 300 ms.
- **MCP:** `codd-mcp` works with Claude Code 2.1.300, including while the app is quit.
- **If the native live preview fails this gate,** switch only the notebook to WKWebView+CM6, MarkEdit-style.

## Sources
- STTextView: https://github.com/krzyzanowskim/STTextView (LICENSE.md, releases)
- "TextKit 2: The Promised Land": https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/ and https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/
- WWDC26 TextKit session: https://developer.apple.com/videos/play/wwdc2026/370/
- Hiding characters in TextKit 2 (Apple forums): https://developer.apple.com/forums/thread/776824
- Marked-text timing (Apple forums): https://developer.apple.com/forums/thread/808915
- TextKit 2 opt-out: https://indiestack.com/2022/11/opting-out-of-textkit2-in-nstextview/
- CodeEditSourceEditor: https://github.com/CodeEditApp/CodeEditSourceEditor
- CodeEditTextView IME fix: https://github.com/CodeEditApp/CodeEditTextView/pull/40 (issues #26, #37)
- Runestone: https://github.com/simonbs/Runestone
- CodeEditorView: https://github.com/mchakravarty/CodeEditorView
- MarkEdit: https://github.com/MarkEdit-app/MarkEdit and https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit
- MarkEdit IME fixes: https://github.com/MarkEdit-app/MarkEdit/issues/1473, /1485, /1640
- CodeMirror IME issues: https://github.com/codemirror/dev/issues/1650, /1654, /1684, and https://discuss.codemirror.net/t/chinese-ime-punctuation-input-loses-every-other-keypress-requires-2-presses-per-character/9741
- CodeMirror packages: https://www.npmjs.com/package/@codemirror/view and https://www.npmjs.com/package/@codemirror/merge
- CotEditor: https://github.com/coteditor/CotEditor (issues #1980, #2020)
- FSNotes: https://github.com/glushchenko/fsnotes
- Neon: https://github.com/ChimeHQ/Neon
- SwiftTreeSitter: https://github.com/tree-sitter/swift-tree-sitter
- TextStory: https://github.com/ChimeHQ/TextStory
- Glyph: https://github.com/ChimeHQ/Glyph
- tree-sitter-markdown: https://github.com/tree-sitter-grammars/tree-sitter-markdown
- swift-markdown: https://github.com/swiftlang/swift-markdown
- MCP Swift SDK: https://github.com/modelcontextprotocol/swift-sdk and https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.11.0
- MCP 2026-07-28 changelog: https://modelcontextprotocol.io/specification/2026-07-28/changelog
- Claude Code hooks: https://code.claude.com/docs/en/hooks
- Hummingbird: https://github.com/hummingbird-project/hummingbird
- Vapor: https://github.com/vapor/vapor
- SwiftNIO: https://github.com/apple/swift-nio
- FlyingFox: https://github.com/swhitty/FlyingFox
- swift-http-server: https://github.com/swift-server/swift-http-server
- GRDB: https://github.com/groue/GRDB.swift, trigram PR https://github.com/groue/GRDB.swift/pull/1655, and https://github.com/groue/GRDB.swift/blob/master/Documentation/FTS5Tokenizers.md
- sqlite-data: https://github.com/pointfreeco/sqlite-data
- SQLite FTS5: https://www.sqlite.org/fts5.html
- FSEvents: https://developer.apple.com/documentation/coreservices/file_system_events

The trigram test was a scratch file (`ftstest/t.swift`), not included in the repo. No project files were modified.