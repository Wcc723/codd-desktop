# M4 plan — Notebook, file editor, MCP, cleanup

Goal: CODD gets its own notebook and a local file editor, and the AI can reach the notes. Notes are
Markdown files with their pasted images under `<dataRoot>/notes/` (never inside projects), indexed in
a derived SQLite (GRDB, FTS5 trigram) index that also finds 繁體中文; the NOTES area implements the
Notebook, ImageAnnotate, FileEditor and Cleanup artboards with a native TextKit 1 live-preview
editor that is safe for 注音; notes link to sessions and projects and go into a session's composer or
terminal through the M2 composer path (`✎ NOTES` drawer, prompt footer, COPY REF). Every CODD claude
session gets CODD's MCP server (`codd`) through a per-session `--mcp-config` that only adds to the
user's own servers, served on the hook server's loopback port; tools list / search / read notes
(images with their annotations) and append only where the note allows it; `codd://note/<id>` in a
prompt is expanded by the per-session UserPromptSubmit hook. The status bar, the rail, STATUS and
Settings show the MCP server live. Files the user opens in the editor get git `M` badges, the
`AI` badge from PostToolUse paths, the disk-change banner and SHOW AI CHANGES against git HEAD with
per-chunk 還原此段 / 接受. A retention engine moves notes ACTIVE → STALE → ARCHIVE automatically,
only the user puts things in TRASH, TRASH is purged after 30 days, and the weekly Cleanup page offers
bulk actions and 交給 Claude 濃縮 (explicit, previewed, originals archived).

Sources (read before working): design/SPEC.md §2, §5 (Notebook data, ids, the five reference forms,
retention defaults), §7.2 (Split: NOTES pill, notes drawer, composer chip), §7.8 Notebook, §7.9
FileEditor, §7.10 Cleanup, §7.11 (STATUS › MCP SERVER), §7.12 (Settings › 筆記本 & MCP, 清理,
進階), with the §8 (R6 image annotations) and §9 overrides; the APPROVED, frozen artboards
`design/artboards-src/{Notebook,ImageAnnotate,FileEditor,Cleanup,Split,Status,Settings,Main,QuickSwitch,MenuBar}.src.html`
(implement them, do not redesign; the artboards' `~/.codd/notebook` is design-time copy: the real
path is `<dataRoot>/notes`, user decision 2026-10-17); `design/helmet.html`; background research
`design/research/{editor-storage,ai-access,retention}.md` and `design/research/native-swift/editor-mcp.md`
(this plan overrides them where it differs: no CodeMirror, no tree-sitter in M4, notes in the data
root, MCP over the hook port); docs/ARCHITECTURE.md; docs/M3-REPORT.md (§5 known issues, §7
decisions); docs/ROADMAP.md (standing decisions).

Out of scope: onboarding, performance hardening, data versioning / migration framework, release
packaging, accessibility audit (M5); iCloud Drive / custom notebook location (M5, the Settings
segments are drawn disabled); a stdio MCP bridge and the Claude Desktop `.mcpb` (FUTURE); split
editor, new-file creation, language servers, project-wide search / replace; CODD-side CJK account
names (M3 D34: not wanted); remote (placeholder).

---

## 0. Starting point (code survey, 2026-10-17)

| Item | Exists after M3 | Gap M4 closes |
|---|---|---|
| NOTES rail item | `RailArea.notes`, rail button; the pane shows `// NOTES · 尚未實作` (`SessionPaneViewController.render`) | the whole NOTES area (Notebook, files, Cleanup, ImageAnnotate) |
| Session header | `notesButton` (`✎ NOTES n` pill, `SessionVM.notesCount` always 0 in real mode) and `filesButton`, tooltips `筆記（尚未實作）` / `檔案（尚未實作）` | the notes drawer (Split artboard) and the file editor rooted at the session's cwd |
| Status bar / rail MCP | `StatusBarView` draws `● MCP <host.mcpEndpoint> · n clients`; `HolderSessionStore.host` returns `mcpEndpoint "—"`, `mcpClients 0`, `mcpRunning false`; rail `● MCP` dim | live values |
| STATUS | `MCPRemoteSectionViews` shows the D27 placeholder `// M4：筆記本與 MCP server 尚未提供`; nav `MCP · M4` | the Status artboard's MCP SERVER card |
| Settings | 08 筆記本 & MCP, 09 清理, 12 進階 › 終端機紀錄保留 / 重建筆記索引 rows drawn disabled with `M4`; values stored in `CoddPreferences.Notebook` / `.Cleanup` / `.Advanced` | rows enabled and obeyed (D33) |
| Hook server | `HookServer` (NWListener, 127.0.0.1, one request per connection, `Connection: close`), routes `POST /hooks` (204 before decoding), `POST /statusline`, `GET /health`; `HookRequestPolicy` refuses any `Origin`; token in `config.json` | `/mcp`, `/hooks/prompt`, `/n/<id>.md`, async handlers with bodies, an external MCP token |
| Per-session `--settings` | CoddCore `ClaudeHookSettings`: 13 http events (UserPromptSubmit → `/hooks`) + SessionStart command hook + `statusLine` | UserPromptSubmit → `/hooks/prompt`, `permissions.allow` for the read tools, `--mcp-config <sessionDir>/mcp.json` |
| Launch | `HolderLauncher.planClaude` → CoddCore `LaunchBuilder` (argv) + `ShellEnvironment.build(extra:)` (environment) | the MCP config path in argv (before `--settings`) |
| Composer | CoddComposer `ComposerTextView` (IME-safe), `PaneComposer` send path (`TerminalInput.payload`, paste + submit), `ComposerStates.appendToDraft` | `codd://note/<id>` drawn as an amber chip (Split artboard); notes inserted / sent through this path |
| ⌘K | `QuickSwitchModel` sessions (8) / projects (5) / actions (6) | NOTES section (QuickSwitch artboard) |
| Menu bar | `QUICK NOTE ⌘⇧N` and status item `快速筆記` call `NSSound.beep()`; footer has no 清理建議 line | quick note, `清理建議 n →` |
| Main menu | ⌘⏎ = 允許, ⌘P = 釘選, ⌥⌘F = 篩選 session, ⌘W = 關閉分頁或視窗 (`NSWindow.performClose`, D19 keeps the app in the menu bar): menu key equivalents | notebook ⌘⏎ 送出, files ⌘P / ⌘F / ⌘S / ⌘W, ⌘⇧N, ⌘E, ⌘⇧A, ⌘⇧C (D36) |
| Design system | CoddUI: `DiffLinesView`, `ToastView`, `CardView`, chips, `SVGPath.parse` (so packages draw their own icons without editing CoddUI) | used by every new UI package |
| Dependencies | libghostty-spm, DisplayLink | GRDB 7.11.1 (exact) for the notes index |
| DEBUG flags | `RealModeOptions` parses `-codd-show` with `next.lowercased()` (whole value) | the new `files:<path>` / `note:<id>` / `annotate:<id>:<asset>` forms keep everything after the first `:` as given (I1a fixes the parser; the keyword stays case-insensitive) |
| Trash | `HolderSessionStore.trash` = the macOS Trash unless `-codd-trash-dir` (M2 D23, only on the user's 刪除對話紀錄) | automatic M4 moves (purge, rings) must never reach `~/.Trash` from a test root (D38) |
| Existing package APIs | `SettingsInfo` / `SettingsActions` / `HookConfig(port:token:)` / `LaunchRequest` / `ClaudeHookSettings` are built by App code with memberwise / defaulted initialisers | every change to an existing package keeps the current App sources compiling (D40), because I1a builds the app before I2a wires anything |

## 1. Verified facts (2026-10-17; read only: `claude --version` = 2.1.302, `claude --help`, `claude mcp --help`, the JS embedded in `~/.local/share/claude/versions/2.1.302`; no session started, no config written)

- **`--mcp-config <configs...>`** "Load MCP servers from JSON files or strings (space-separated)". It is
  **variadic**: every following argument that is not an option is taken as another config, so CODD
  always puts `--mcp-config <path>` immediately before another option (D18). Each entry is parsed as
  JSON or read as a file (`OIt({filePath, expandVars: true, scope: "dynamic"})`); a validation error
  aborts startup (`Error: Invalid MCP configuration`), a per-server problem skips that server with a
  warning. `--strict-mcp-config` uses only `--mcp-config` servers (never used for sessions). A managed
  `managed-mcp.json` refuses dynamic servers (`You cannot dynamically configure MCP servers when an
  enterprise MCP config is present`): such users get no codd MCP (known issue).
- **`${VAR}` in MCP configs** is expanded, but "credential variable(s) … are never expanded toward a
  remote server (read as empty)" (`gV(…, {remoteSink})`, name patterns plus value heuristics). CODD
  therefore writes a **literal per-session token** into a 0600 file instead of `${CODD_HOOK_TOKEN}`
  (D16).
- **MCP client negotiation**: Claude first probes `server/discover` (2026-07-28 era). A JSON-RPC
  error reply, an HTTP error with a non-JSON body, a malformed reply, an id mismatch or a stream end
  all mean "legacy" → `initialize`; only a network error fails the connection. Legacy versions the
  client knows: `2025-11-25` (requested), `2025-06-18`, `2025-03-26`, `2024-11-05`, `2024-10-07`.
  The bundled Streamable HTTP transport accepts `application/json` replies, `202` for
  notifications, and a `405` on GET (no server stream).
- **Meta keys** present in the bundle: `anthropic/alwaysLoad`, `anthropic/requiresUserInteraction`,
  `anthropic/maxResultSizeChars`; also `readOnlyHint`, `resource_link`, `MAX_MCP_OUTPUT_TOKENS`.
- **http hooks** (`PNn` / `DNn`): POST JSON, per-hook timeout; header values interpolate only names in
  `allowedEnvVars` and blank credential-looking variables (`Hooks: env var $X is a credential and is
  not interpolated into an HTTP hook header`; the M1 design depends on `CODD_HOOK_TOKEN` passing that
  test: risk §8). Response body: empty → `{}`; otherwise it must start with `{` and be valid hook
  output JSON, else a non-blocking validation error. For UserPromptSubmit the JSON's
  `hookSpecificOutput.additionalContext` is added to the turn (large text is saved to a file with a
  preview). So `/hooks/prompt` answers 204 or valid JSON, never plain text.
- **`~/.claude.json`** (user-scope MCP servers live in its top-level `mcpServers`) is written by Claude
  Code with a lock (bundled proper-lockfile, `saveGlobalConfig` "with lock", the file re-read under the
  lock and merged before writing). An outside writer must take a compatible lock and must never
  write from a stale read (D22). `claude mcp add --transport http <name> <url> --header "…"` exists;
  CODD never runs it.
- **GRDB**: latest release `v7.11.1` (2026-06-18, tag `b83108d10f42680d78f23fe4d4d80fc88dab3212`).
  System SQLite (3.54 on this Mac) has FTS5 with the `trigram` tokenizer: `MATCH` finds substrings of
  ≥ 3 characters (`注音輸`), returns nothing for 1–2 characters (`筆記`), `LIKE '%筆記%'` finds them
  (design/research/native-swift/editor-mcp.md §0) → D6.
- **PencilKit on macOS has no canvas** → the annotation canvas is custom AppKit (C8).
- The standard data root `~/Library/Application Support/CODD` contains a space: note paths copied
  for AI use are absolute and unquoted (Claude's Read takes a path string); shells need quoting.

Added by the plan review (2026-10-17, same read-only sources):
- **Hook output `systemMessage`** ("Display a message to the user (all hooks)") exists next to
  `hookSpecificOutput`. The Main artboard's claude terminal shows
  `⎿ codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 2 張圖片）`: `/hooks/prompt` answers carry
  that line as `systemMessage` (D19).
- **MCP output budget**: `MAX_MCP_OUTPUT_TOKENS` defaults to 25,000. Claude estimates a result as
  text tokens + 1,600 per image block; above half the limit it counts tokens itself, above the limit
  it cuts the result to 100,000 characters and appends `[OUTPUT TRUNCATED - exceeded … token limit]`.
  A CJK note costs about one token per character, so `notes_read` pages 12,000 characters by default
  (≤ 50,000 on request) with ≤ 4 images (D17).
- **More variadic flags**: `--allowedTools <tools...>` and `--tools <tools...>` are variadic like
  `--mcp-config`; `--tools ""` disables every built-in tool; `--permission-prompts none` (print
  mode) denies anything that would prompt; `--bare` limits auth to `ANTHROPIC_API_KEY` /
  `apiKeyHelper` (OAuth logins fail), so CODD never uses it (D32).
- **Contentless FTS5** (`content=''`) returns empty `snippet()` / `highlight()` (checked with the
  system sqlite3 3.54): search snippets are built in Swift (D6). 1–2 character `MATCH` returns 0
  rows, as expected.
- **Pinned sessions** run with `CLAUDE_CONFIG_DIR=<cswap profile>`; Claude then reads user-scope MCP
  servers from `<profile>/.claude.json`, not `~/.claude.json` (D18 name resolution).
- **Automation limits on this Mac**: `ls ~/.Trash` is refused from the agent shell (TCC), and real
  Claude sessions (including the orchestrator's) write `~/.claude.json` and `~/.claude/` all the
  time, so "nothing changed there" cannot be proven by before / after listings (§7, B12).
- **GRDB** tag `v7.11.1` → `b83108d1…` confirmed with `git ls-remote`. `HookServer` keeps
  `readTimeout` 5 s, `headTimeout` 1 s and 64 connections; `HookConfigStore.reassignPort` / `setPort`
  rewrite config.json from `HookConfig(port:token:)` (C3 must carry `mcpToken` through them).

---

## 2. Decisions (reversible technical defaults; repeated in the report)

| # | Topic | Decision |
|---|---|---|
| D1 | Notes location and layout | `<dataRoot>/notes/` (0700): notes as `.md` files (flat by default; sub-folders are allowed and indexed), images in `assets/<note-id>/`, CODD's own state in the dot-folder `.codd/` (marker, per-note state, AI activity, history, trash, tombstones; §3.1). Dot-folders and `assets/` are never indexed as notes. The index lives outside the folder: `<dataRoot>/notes-index.sqlite` (derived, deletable; excluded from Time Machine like `sessions/`). The notes folder itself is never excluded from backups. No note is ever written inside a project. |
| D2 | Note file format | Markdown + a YAML **subset** frontmatter (§3.2): `key: scalar`, `key: [a, b]`, block lists `- a`, single / double quoted strings, `#` comment lines. Unknown keys, comments and their order are kept byte for byte; CODD patches only the lines of keys it changes (no YAML library, no reformat). The title is the body's first H1 (`# …`); `title:` is written as a mirror for other tools. A frontmatter CODD cannot parse is indexed with defaults and a warning, and CODD then refuses metadata edits on that note (toast `這則筆記的 frontmatter 無法解析，請先手動修正`) instead of rewriting it. CODD writes LF; a file read with CRLF keeps CRLF on save. Filenames NFC. |
| D3 | Ids and filenames | Id = up to two ASCII words from the title, then from the tags (lowercased, `[a-z0-9]+`, deduped, ≤ 20 characters, else `note`) + `-` + 4 random base36 (`rwd-punch-k7x2`); unique against the index and the tombstones; never changes. Filename at creation: `YYYY-MM-DD-<slug>.md`, slug = the title with CJK kept, ASCII lowercased, whitespace and punctuation → `-` (collapsed, ≤ 48 graphemes, else `note`), `-2`, `-3` on collision; **never renamed** (pasted paths stay valid). A note is created on disk only at its first non-empty save (an untouched new note leaves nothing behind). A `.md` without frontmatter (dropped in by the user) gets a derived id (filename slug + 4 hex of a hash of its relative path, stable across rebuilds) and default metadata; its frontmatter is written at its first CODD save or metadata change. Duplicate ids (copied files, sync conflicts): the newer file is indexed as `<id>-dup<n>` with a `ID 重複` chip and gets that id written at its next save. |
| D4 | Metadata vs app state | Everything another tool or a rebuild needs is in the file's frontmatter (id, kind, tags, links, AI access, scope, pinned, status, lifecycle dates, condense links). App-only state that is not derivable lives in files under `.codd/` (never in the index): `state.json` (last opened, open count, `keepUntil`), `activity.jsonl` (AI activity), `history/` (snapshots), `trash/`, `tombstones.json`. Opening a note never rewrites it. |
| D5 | Index | GRDB **7.11.1 exact** (`DatabasePool`, WAL) at `<dataRoot>/notes-index.sqlite`, schema version in `PRAGMA user_version` (§3.5). Derived only: rebuilt in full when missing, unopenable, failing `PRAGMA quick_check`, or of another schema version; brought up to date at open by comparing every note's (relative path, mtime, size) and re-parsing changed files; updated incrementally from the watcher and CODD's own writes; Settings › 進階 › 重建筆記索引 drops and rebuilds it. Only the app process writes it (MCP is in-app, D16). Never on the main actor; an index build yields between files so MCP reads never wait more than ~50 ms behind it. If GRDB does not build warning-free with Swift 6.4 / macOS 26, C1 reports it and falls back to the system `SQLite3` module behind the same API. |
| D6 | Search (CJK) | Query = terms split on whitespace (`#tag` terms filter tags, `"…"` keeps spaces). Terms of ≥ 3 Unicode scalars (of the NFKC-lowercased term; what the trigram tokenizer needs) go to the FTS5 `trigram` table (`case_sensitive 0`; the indexed columns hold NFKC-lowercased text; every term is written as an FTS5 string literal with `"` doubled, never as raw query syntax), shorter ones to `LIKE '%term%' ESCAPE '\'` over a NFKC-lowercased `search_text` column; all terms AND-ed. Ranking: bm25 when any MATCH term, then pinned, then updated. Hits carry a snippet with highlight ranges, built in Swift from a stored plain-text body column (original case; contentless FTS5 has no `snippet()`), matched case- and width-insensitively so the UTF-16 ranges point into the shown text. FTS5 through raw SQL (no dependency on GRDB's FTS5 Swift types). Archived notes only in ARCHIVE or with `include_archived`; trashed only in TRASH. |
| D7 | Watching the notes folder | FSEvents (file events, recursive) on `<dataRoot>/notes`, coalesced 200 ms; `.codd/` ignored; CODD's own writes are recognised by (path, content hash) and ignored. External create / edit / delete / rename update the index and the lists. An open note that changes on disk: clean editor → reloaded in place (selection kept; deferred while marked text exists); dirty editor → banner `磁碟上的筆記已變更` `[重新載入]` `[保留我的]` `[比較]` (the FileEditor banner component). |
| D8 | History snapshots (HISTORY panel) | A snapshot (the whole file) is written after a save when the newest snapshot is older than 5 minutes, and always before: applying an external change over a dirty editor, an AI append / write, a restore, condense, trash. Thinning at each retention run: everything for 48 h, then one per hour for 14 days, one per day for 90 days, nothing older; ≤ 200 per note; files > 2 MiB are not snapshotted. `[比較]` opens a compare sheet (two versions, CoddUI `DiffLinesView` over CoddFiles `LineDiff`) with `還原這一版` (snapshots the current text first). Snapshots go with the note when it is purged. |
| D9 | Image paste | An image on the pasteboard / dropped into the note editor → `assets/<note-id>/<hash6>.<ext>` (first 6 hex of SHA-256 of the processed bytes; lengthened by 2 on a collision with other bytes; identical bytes reuse the file). Formats PNG (TIFF / screenshots re-encoded as PNG), JPEG, GIF (first frame for AI), WebP; HEIC / HEIF re-encoded (JPEG without alpha, PNG with alpha) because Claude's image reader takes only PNG / JPEG / GIF / WebP; a downscaled image is written as PNG (JPEG input stays JPEG, quality 0.9) and the extension follows the written format; > 20 MiB refused (toast). 圖片長邊壓到 2576px ON (default): longer edge > 2576 px is downscaled first; 保留原檔 ON also keeps `<hash6>.orig.<ext>`. The editor inserts `![截圖 <yyyy-MM-dd HH:mm>](assets/<id>/<hash6>.png)` at the caret (never while marked text exists; at the end if the note changed meanwhile) and the toast `已貼上圖片 → assets/<id>/<hash6>.png` (`· 已縮小到 2576px` when resized). Files 0600, written off the main actor. |
| D10 | Image annotations (R6) | Stored in the note right after the image as a fenced `codd-annotations` JSON block (§3.3): items `rect` / `point` / `arrow` / `text` (the artboard's T tool) in ORIGINAL image pixels, origin top-left, numbered `n`, optional `color`; per-image `send` options (附上原圖 / 附上標註後的圖 / 附上座標清單, defaults false / true / true). The live preview hides the block and draws boxes, numbered pins and arrows over the image, with the annotation list to its right (Notebook artboard). The annotated copy `<hash6>.annotated.png` (boxes and numbers burned in, CoreGraphics) is derived: regenerated when the block's JSON changes, deleted with the note. ⌘⇧A or `編輯標註` opens the ImageAnnotate screen; `完成` rewrites the block as one undoable edit of the note text. |
| D11 | Editor engines | Notebook: CoddTextKit `MarkdownEditorView` — an `NSTextView` forced into **TextKit 1** (`NSTextView(usingTextLayoutManager: false)` / an explicit `NSLayoutManager` stack). Live preview: syntax marks hidden off the caret's paragraph by glyph generation (`NSLayoutManagerDelegate.shouldGenerateGlyphs`, `.null` / zero-advance), headings / lists / tasks / code / quotes styled through text-storage attributes applied after processing, images and other blocks drawn by **block decorations** (line-fragment heights adjusted in `shouldSetLineFragmentRect` + overlay views). IME rules (non-negotiable): every key goes through `interpretKeyEvents`; list continuation, task toggles and ⌘⏎ live in `insertNewline` / `doCommand(by:)` / `performKeyEquivalent` and check `hasMarkedText()` first; while marked text exists nothing is restyled, revealed / hidden, autosaved, reloaded or replaced, and `onTextChange` never fires; smart quotes / dashes / text replacement / automatic spelling correction are off. File editor: CoddCodeEditor `CodeEditorView`, its own TextKit 1 text view with the same IME rules, gutter, find / replace widget, inline diff blocks. Syntax highlighting is **native**: per-language lexers with line-start states, applied as temporary attributes to the visible range (no WebView, no tree-sitter in M4; reversible behind `SyntaxHighlighter`). The two packages duplicate a small text-view base on purpose (parallel work; a later merge is noted). |
| D12 | NOTES area layout | Rail NOTES on. The session sidebar column is collapsed while NOTES shows (like D16 of M3 restores it on leave) and the pane hosts `NotesAreaViewController` with four modes: **Notebook** (lists 220 · note list 300 · editor flex with info panel 240 · doc status bar · prompt footer), **Files** (tree 264 · tab strip · toolbar · banner · code / note editor; the app status bar shows the editor's status items), **Cleanup** (full-width page), **Annotate** (full-width ImageAnnotate). The mode and the selected note / open tabs are remembered for the run (not persisted in M4). |
| D13 | Quick note ⌘⇧N | `+ ⌘⇧N` in the Notebook and ⌘⇧N while NOTES shows → a new NOTE in INBOX. ⌘⇧N elsewhere, the menu bar `QUICK NOTE ⌘⇧N` and the status item `快速筆記` → a new SCRATCH titled `隨手記 M/D`, linked to the session on screen (and its project) when there is one, and the window switches to NOTES with the caret in it. Both follow D3 (nothing on disk until something is typed). |
| D14 | Send to session | Prompt footer (`送到 [● <session> ▾]` · `插入引用` · `插入全文` · `送出 ⌘⏎`), `SEND TO SESSION ▾` (live CODD claude sessions, each with the three actions) and the drawer cards (`插入引用` / `送出全文`): **插入引用** puts `codd://note/<id>` into that session's composer draft (opens ⌘L; appended like `ComposerStates.appendToDraft`), **插入全文** puts the AI text (§3.7) into the draft, **送出** sends the AI text through `ComposerEncoding.payload` → `TerminalInput.payload` (paste + submit) to claude's own PTY — refused with `Claude 在等你確認 · 先用下方按鍵回答` while the session is WAITING, queued by Claude while BUSY; ≤ 256 KiB else `筆記太長，改用插入引用`. A PROMPT records `sent` / `sentTo` (row `已送出 HH:mm`; SCRATCH-like archive 7 days later). Default target: the first live linked session, else the most recently viewed live CODD claude session. Externals are never targets. |
| D15 | COPY REF | The five §3.6 forms in the artboard's order; the split button's left part (and ⌘⇧C) copies `codd://note/<id>`. The local URL carries a per-note token derived from the external MCP token (`MCPAuth.noteURLToken`), so a leaked URL reads only that note and dies at 輪替. An AI OFF note's URL item is disabled (hint `AI 存取為 OFF，不提供網址`) and the route answers 404 for it, so an OFF note never leaves CODD through a URL an agent could `curl`. A note that is not on disk yet (D3) has COPY REF / SEND disabled and shows `id —`. |
| D16 | MCP transport and auth | In-app **Streamable HTTP on the hook server's port**: `POST /mcp` (§3.9), **stateless** (no `Mcp-Session-Id`, so an app relaunch never invalidates a client), JSON replies only, `202` for notifications, `GET` / `DELETE` → `405`, `server/discover` → JSON-RPC `-32601` (forces the legacy handshake, §1), protocol versions `2025-11-25`, `2025-06-18`, `2025-03-26` (echo the requested one if supported, else `2025-11-25`). Same Host rule as the hooks; `Origin` absent or exactly `http://127.0.0.1:<port>` / `http://localhost:<port>`, else 403. Auth: CODD sessions send `X-CODD-Session: <uuid>` + `X-CODD-Token: MCPAuth.sessionToken(hookToken, uuid)` (HMAC-SHA256, literal in a 0600 per-session file, D18); registered external clients send the **external MCP token** (`config.json` `mcpToken`, 32 random bytes hex) as `X-CODD-Token` or `Authorization: Bearer`. 401 without `WWW-Authenticate` on failure. MCP is down while CODD is not running (sessions keep working; Claude marks the server failed; documented). No stdio bridge in M4. |
| D17 | MCP surface | Server name `codd`, instructions ≤ 4,096 characters (§3.10). Tools: `notes_search`, `notes_read`, `notes_list` (`readOnlyHint`, `alwaysLoad` on search and read), `notes_append`, and `notes_write` only while Settings › AI 可寫入 is ON (`_meta["anthropic/requiresUserInteraction"]: true`). Resources: `codd://note/{id}` template + the ≤ 200 newest visible notes. Prompts: `note`. Access: AI OFF notes never appear anywhere (search, list, read, resources, expansion); READ notes are read-only; APPEND notes accept `notes_append` (and `notes_write` when allowed). Scope: a `global` note is visible to every caller; a `project` note to sessions whose cwd (realpath) is inside one of its projects, to sessions linked to it, and to external clients. The tools' `scope` argument only narrows what the caller may see (`all`, the default = every visible note; `project` = the caller's project / linked notes). Archived notes only with `include_archived`; trashed / purged answer isError (tools) or `-32602` with `data.state` (resources). Limits (§1 output budget): text 12,000 characters by default (`max_chars` 1,000…50,000, `offset` paging), ≤ 4 image blocks per read (annotated copy when the image has annotations and `send.annotated`), each ≤ 1568 px long edge and ≤ 900 KB, the rest listed as absolute paths. |
| D18 | Per-session injection | When Settings › 自動掛載 MCP is ON and the hook server is up: CODD writes `<sessionDir>/mcp.json` (0600, atomic) and passes `--mcp-config <that path>` **right before `--settings`**; regenerated at every launch, RESUME and RESTART; goes with the session directory. Server name: `codd`, unless the user's config already defines a `codd` (top-level `mcpServers` and `projects[<cwd>].mcpServers` / `projects[<realpath cwd>].mcpServers` keys of the session's global config, i.e. `<claudeDir>/../.claude.json`, or `<CLAUDE_CONFIG_DIR>/.claude.json` for a pinned session (path never logged), and `<cwd>/.mcp.json` keys; read only, names only): one that points at this endpoint (the user registered CODD, D22) → no per-session file (that session is an external caller), any other `codd` → `codd-desktop`. `--settings` also gets UserPromptSubmit → `/hooks/prompt` (timeout 3 s) and `permissions.allow` for `mcp__<name>__notes_search`, `…notes_read`, `…notes_list` (append / write keep Claude's normal permission prompt). OFF → neither file nor route change (UserPromptSubmit stays on `/hooks`). |
| D19 | Prompt expansion | `/hooks/prompt` yields the event like `/hooks` (states, last prompt), then parses the prompt for `codd://note/<id>` and `[[note:<id>]]` (≤ 5 distinct refs) and answers 200 `{"systemMessage":"codd：已展開 codd://note/<id>（<title> · n 張圖片）","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":…}}` (the Main artboard's terminal line; several refs → `codd：已展開 2 則筆記（<title>、<title>）`; refused refs → `codd：codd://note/<id> 無法展開（<reason>）`) with the §3.7 text of each visible note, ≤ 9,500 characters in total (cut with a pointer to `notes_read` / the file); an OFF, unknown, trashed or purged ref gets one line saying why (an OFF note's line never names its title); no ref → 204. Deadline 1.5 s, else 204 (logged `prompt-expand late`). Each expanded note records AI activity `expand`. |
| D20 | AI activity and defaults | Recorded per note in `.codd/activity.jsonl` (reads, appends, writes, expansions, URL reads; never search hits): time, action, client name, CODD session id + title when known, via. Shown in the info panel (`讀取 · <session> · 10:12`, `附加 —`) and the drawer (`AI 讀取 10:12`). AI reads never count as user activity (retention). New-note AI access = Settings › 新筆記預設 AI 存取 (default READ, design/research/ai-access.md); new-note scope = `project` when created linked to a session / project, else `global`. |
| D21 | MCP surfaces | A client = one CODD session (its `initialize` while the session is live) or one external token + `clientInfo.name` seen in the last 30 minutes. Status bar `● MCP 127.0.0.1:<port> · n clients` (lamp green while the endpoint and the handler run, dim otherwise), rail `● MCP`, Notebook footer `● MCP codd · n clients`, STATUS › MCP SERVER (clients with title, client kind and `連線 42m`; registrations; token `••••` `[輪替]`), Settings › 筆記本 & MCP. |
| D22 | Registration into other clients | Only on an explicit button, never in tests against real files. **Claude Code (user scope)**: CoddClaudeSettings installer on `~/.claude.json` (injectable path; DEBUG `-codd-claude-json`, refused when it resolves to the real file): plan → diff dialog (only the `mcpServers.codd` member; token shown `••••`) → `套用並備份`: take Claude's lock (C10 verifies the path; `<file>.lock` mkdir protocol), re-read under the lock and refuse only when the `mcpServers` member (or the file's parsability) changed since the preview (Claude rewrites other members of `~/.claude.json` every few seconds while sessions run; those fresh bytes are kept and the previewed member edit is applied to them, as Claude's own locked read-merge-write does), back up to `.claude.json.codd-bak-YYYYMMDD-HHMMSS[-n]` (mode kept), write atomically keeping key order, indentation and every other byte, release the lock; `移除` the same way. The entry carries the external token literally (§3.13). **Codex**: `註冊` opens a dialog with a `config.toml` snippet and `[複製]` — CODD never writes `~/.codex`. **Claude Desktop** `安裝 .mcpb`: disabled with `FUTURE`. |
| D23 | Token rotation | `輪替` (STATUS / Settings) regenerates `mcpToken` in config.json (0600) and applies it without a restart; per-session tokens do not change (they derive from the hook token). Registered Claude Code then shows `需要重新註冊（token 已輪替）` until the user re-registers; old note URLs stop working. |
| D24 | Local file editor rules | Only files the user opens are read; the tree lists names only (lazy per expanded folder, ≤ 2,000 entries per folder). git is read-only: `git -C <root> --no-optional-locks -c core.fsmonitor=false` with `GIT_OPTIONAL_LOCKS=0` (no fsmonitor daemon is ever spawned from a user's config) (`status --porcelain=v2 --branch -z --untracked-files=all`, `rev-parse --show-toplevel`, `cat-file blob HEAD:<path>` (plumbing: no textconv, no pager), `ls-files -o -i --exclude-standard --directory -z`, `ls-files -co --exclude-standard -z` for ⌘P), 5 s timeout, logged `exec git path=… sub=…`. Tests and fixtures run git with `GIT_CONFIG_GLOBAL=<empty temp file>` and `GIT_CONFIG_NOSYSTEM=1`, so the user's own git config never applies to them. Files: NUL in the first 8 KB → binary (`// 二進位檔案，無法以文字開啟`); > 5 MiB → read-only plain mode; > 50 MiB → refused. Encodings: UTF-8, UTF-8 BOM, UTF-16 LE/BE with BOM, Big5 (only when not valid UTF-8 and it decodes), else Latin-1 read-only; EOL LF / CRLF / CR (mixed → shown `CRLF*` for the majority; on save every unchanged line keeps its own ending, mapped through `LineDiff`, and only new lines take the majority); the final newline, the BOM and the encoding are written back unchanged. **Nothing is written without ⌘S** (or the dirty-close sheet's `儲存`): atomic temp + rename in the same directory, mode, xattrs and ACL kept (copied from the original onto the temp), a symlink written through to its target, a file with more than one hard link written in place (truncate + write + `F_FULLFSYNC`) so the link survives, a file without write permission refused (`這個檔案是唯讀的`), refused when the disk changed since the load unless the user chose 保留我的. `還原此段` edits the buffer (undoable, dirty) and `接受` only hides the chunk until the file changes; neither writes. |
| D25 | Disk changes and AI attribution | A per-open-file DispatchSource (write / delete / rename / extend; reopened after an atomic replace). Clean buffer → reloaded in place. Dirty buffer → banner: `磁碟上的檔案已被 AI 變更（<session> · HH:mm）` when a CODD session's PostToolUse named that path within ±10 s, else `磁碟上的檔案已變更`, plus `· 你有未儲存的修改`, `[重新載入]` `[保留我的]` `[比較]` (比較 = inline diff of the buffer against the disk text). |
| D26 | AI-touched badges | From PostToolUse hook payloads of CODD sessions: `tool_input.file_path` of Edit / Write / MultiEdit and `notebook_path` of NotebookEdit (relative paths resolved against the payload `cwd`); kept in `<dataRoot>/files/ai-touches.json` (7 days, ≤ 2,000). `AI` chip in the session's color tag (no tag → bone outline) on tree rows, Recent rows and tabs; the tree head `AI n`; the drawer's `AI 改過的檔案 · n` (with `vs HEAD`). Bash-made changes are not seen (only git `M`; known issue). |
| D27 | SHOW AI CHANGES | Switch per tab, default ON for a tab opened from an AI badge / `差異`, else OFF. Baselines: `基準：git HEAD` (default), `基準：上次儲存 HH:mm` (the text at the last load / save), `基準：AI 開始前 HH:mm` (only for files that were open when a session changed them: the disk text before that change, memory only). Inline unified hunks: removed lines drawn as a block above the added lines, hunk bar `AI · <session> · HH:mm · @@ -a,b +c,d @@ · −n +m · i / n · [還原此段] [接受]`, `AI 變更 n 段 ↑ ↓` navigation, overview ruler marks. |
| D28 | Highlighting and size | Lexers for Vue SFC, JS / TS (+ JSX / TSX), JSON, CSS / SCSS, HTML / XML, Markdown, Swift, Python, Shell, YAML, TOML, Go, Rust, C / C++ / Objective-C, Java / Kotlin, Ruby, PHP, SQL, plain; token classes map to the artboard's colors (keywords amber, strings cyan, comments dimmer italic, tags `#e0896a`, numbers `#a6e9f2`, …). Highlighting covers the visible range plus a margin; files > 2 MiB highlight only on demand, > 5 MiB plain mode (D24). |
| D29 | Notes retention | Lifecycle ACTIVE → STALE (`notesStaleDays`, default 14, a badge / STALE list only) → ARCHIVE (`notesArchiveDays` 30; SCRATCH and sent PROMPTs `scratchArchiveDays` 7 after their last activity / send) → TRASH (only by the user) → PURGE (`trashPurgeDays` 30 after trashing). Activity = the user's edits, opening a note for ≥ 3 s, pin, kind / tag / link changes, send; never AI reads. Exempt (when 豁免 is ON): pinned notes, notes linked to a live session, notes read by a live session during its life; `保留 30 天` sets `keepUntil`. Trash = move to `.codd/trash/` (restorable); **purge moves the note, its assets and history to the macOS Trash** through an injectable trash function (tests and DEBUG `-codd-trash-dir` use a folder; any non-standard data root never reaches the macOS Trash, D38) and keeps a tombstone (`tombstoneDays` 90, 永久 = forever) so old `codd://` refs answer `已刪除`. Runs at launch, every 24 h and after a CLEANUP setting changes; each automatic move is logged. |
| D30 | Sessions retention | Stopped / exited CODD sessions (not running, not pinned): `sessionsStaleDays` (3) after `lastStateAt` → the stale dim (the existing `SessionVM.isStale` look); `sessionsArchiveDays` (7) → archived like `封存` (restorable, `archivedAt` set); `scrollbackDeleteDays` (30) after `archivedAt` → the session's `ring` (and `holder.log`) moved to the macOS Trash (same injectable trash, D38). Settings › 清理 › 終端機紀錄 is the engine's value; Settings › 進階 › 終端機紀錄保留 shows and edits **the same value** (`advanced.scrollbackRetentionDays` stays stored, unused). Externals and running sessions are never touched; `cleanupPeriodDays` drives `resume expires nd` (5 days before Claude's sweep; off when 清理 › resume 過期提醒 is off). **First-run grace:** the first retention run on a data root records `retention.firstRunAt` in `cleanup.json`; the session clocks (stopped → stale / archive, archived → ring) count from no earlier than that moment, so upgrading to M4 never archives the user's existing stopped sessions or trashes rings at the first launch (they follow the policy 3 / 7 / 30 days later). Notes are new in M4 and need no grace. |
| D31 | Cleanup page and digest | Candidates (§3.4 rules): NOTES (stale, auto-archive within 7 days, sent PROMPTs, SCRATCH, near-duplicates ≥ 80 % trigram Jaccard, long notes with ≥ 3 dated sections older than 30 days), SESSIONS (stopped ≥ stale days, auto-archive soon, `resume expires nd`, transcript gone), FILES (note images no body or kept snapshot references and older than 7 days, rings of archived sessions, Recent entries whose file is gone). Badges `stale 21d`, `archives in 0d`, `dup 82%`, `9 段 > 30d`, `resume expires 4d`, `deletes in 4d`, `unused 12d`; AI hints (`AI 2d 前讀取 → 建議保留`, `✻ 適合濃縮`). Row actions `保留 30 天` / `封存` (FILES: `保留 30 天` / `移到垃圾桶`); bulk bar `已選 n` `[封存]` `[移到垃圾桶]` (notes and files only) `[✻ 交給 Claude 濃縮…]` (notes only). Digest: 每週 (default) Monday 09:00 local, 雙週, 每月, 關; at the first launch / hourly tick after that time and only with ≥ 5 candidates: notification `清理建議 · 15 項` / `筆記 8 · session 5 · 檔案 2` (action 查看) through AppNotifier; the counts also on the Notebook footer, the menu bar footer and Settings › 清理's head button. |
| D32 | 交給 Claude 濃縮 | Only from the Cleanup bulk bar, only notes with AI READ / APPEND (OFF notes are left out with `AI 存取為 OFF 的筆記不會交給 Claude`). Account: `跟隨全域登入（#3 工作）` or an account with a usable cswap profile (M3 D12 pin rules, `CLAUDE_CONFIG_DIR`); model from Settings › 清理 or the card. `[✻ 產生摘要]` runs `claude -p --model <m> --output-format text --tools "" --permission-prompts none --strict-mcp-config --mcp-config <run mcp.json> --allowedTools mcp__codd__notes_read --no-session-persistence` (every variadic flag followed by another option; no positional prompt) in `<dataRoot>/run/condense-<id>/` with the prompt and the notes' AI text on stdin (180 s timeout, cancellable; no built-in tools, nothing that could prompt, `--strict-mcp-config` only for this internal one-shot job so the user's servers do not start; no `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` in its environment; the run folder with its 0600 `mcp.json` is removed when the run ends); the output is the preview; a **long-note** source (the `9 段 > 30d` candidate) contributes only its dated sections older than 30 days (labelled `（舊段落 n 段）` like the artboard), is snapshotted and listed under `濃縮自` but stays ACTIVE and unchanged (CODD never cuts sections out of a living note; the user removes them by hand if wanted) and gets `keepUntil` +30 d so Cleanup stops suggesting it; nothing changes until `[建立摘要並封存原稿]`: a new NOTE `摘要 · M/D 清理（n 則）` (id `cleanup-<MMdd>-xxxx`, body = summary + `濃縮自` list of `codd://note/<id>`, `condensedFrom`), each original snapshotted, archived (`archivedBy: condense`, `condensedInto`); never deleted; toast with UNDO (unarchive originals, trash the summary). On any non-standard data root the claude is only the DEBUG `-codd-claude-path` executable (automation: a fake claude). |
| D33 | Settings rows | 筆記本 & MCP: 位置 `LOCAL` on with hint `<dataRoot>/notes · 每則筆記是一個 .md 檔`, `iCloud Drive` / `自訂…` disabled `M5`; `開啟筆記本資料夾` reveals the folder; 圖片長邊壓到 2576px, 保留原檔, 自動掛載 MCP, 新筆記預設 AI 存取, AI 可寫入 live; Port 與 token shows the hook port read-only (MCP shares it; the stored `mcpPort` is unused) + `••••` + `輪替`; 註冊 rows per D22. 清理: every row live; head `查看清理建議 · n →` opens Cleanup; 交給 Claude 濃縮 account / model selects. 進階: 終端機紀錄保留 = D30 mirror; 重建筆記索引 `重建` live (progress / result line `已重建 · 128 則 · 0.4 s`). |
| D34 | New copy (not on the artboards; listed in the report) | AI access menu hints (`AI 看不到這則筆記（MCP 與引用展開都不提供）`, `AI 可透過 MCP 讀取`, `AI 可讀取，也可以在最後附加內容`), `磁碟上的筆記已變更`, frontmatter / ID 重複 messages, history compare sheet (`HISTORY · 比較版本`, `還原這一版`), dirty-close sheet (`儲存「<name>」的變更？` `[儲存]` `[不儲存]` `[取消]`), condense states, digest notification, Codex dialog, registration dialog, empty states (`// 還沒有筆記 · ⌘⇧N 新增`, `// 還沒有連結這個 session 的筆記`, `// 找不到符合的筆記`), cleanup SESSIONS / FILES row texts, `// 筆記資料夾無法使用：<reason>`, error toasts. |
| D35 | Mock mode | `-codd-mock` seeds a temporary notes folder (`$TMPDIR/codd-mock-notes-<pid>`, removed at quit) with the SPEC §5 notes n1–n7 (made-up design data), a generated 750×1334 placeholder image with the R6 annotations, a mock project folder for the Files mode (files written by Swift; its git facts — `feat/punch-rwd ↑2`, the `M` badges, the HEAD text of punch.vue — come from a mock `GitReading`, mock mode never runs git), and a mock MCP state (`127.0.0.1:47821 · 3 clients`), so `-codd-mock -codd-show notebook|annotate|files|cleanup|split` snapshots compare with the artboards. Mock mode never starts the MCP route. |
| D36 | Shortcuts | New main-menu items (key equivalents, never event monitors): `筆記` menu with 快速筆記 ⌘⇧N, 原始碼 / 即時預覽 ⌘E, 標註模式 ⌘⇧A, 複製引用 ⌘⇧C, 搜尋筆記 ⌘F (NOTES only); `檔案` items 儲存 ⌘S, 關閉分頁 ⌘W (Files mode). Items validate by area / mode, so the session items step aside: 允許 ⌘⏎ is disabled outside the sessions area (the notebook's 送出 ⌘⏎ and the editor's `performKeyEquivalent` get it), 釘選 ⌘P outside sessions (Files: filter ⌘P), 關閉分頁或視窗 ⌘W while Files shows an open tab (then 關閉分頁 ⌘W). AppKit uses the first enabled item with a key equivalent, so every pair that shares a key is mutually exclusive in `validateMenuItem` (checked by the shortcut matrix). Every handler checks marked text first. ⌘⇧N is an in-app key equivalent plus the menu bar / status item entries, never a system-wide hotkey (it would take Finder's 新增檔案夾); from another app the M3 global hotkey shows CODD first. The DEBUG shortcut matrix grows accordingly. |
| D37 | Isolation of automated runs | Notes, the index and every M4 state file live under the run's data root. `.claude.json` for MCP names is `<claudeDir>/../.claude.json` (a temp dir in tests). Registration writes refuse any path resolving to the real `~/.claude.json`; `~/.codex` is never written. git runs only in folders the run opened (temp repos). Condense runs only the DEBUG claude on test roots. Trash moves use `-codd-trash-dir` in tests (never `~/.Trash`, D38). No Anthropic host is contacted; the e2e greps the logs for `anthropic.com`. |
| D38 | Trash target | Every M4 move to a system-level trash (notes purge, rings / `holder.log`, Cleanup FILES `移到垃圾桶` of unused images; a note's own TRASH stays CODD's `.codd/trash/`) goes through one app trash function: the macOS Trash only on the standard data root; on any other root `-codd-trash-dir` when given, else `<dataRoot>/trash/` (0700). Each move logs `trash target=system|folder name=<last component>`; the e2e asserts `target=system` never appears. |
| D39 | Automation never touches the user's desktop state | Pasteboard writes (COPY REF, ⌘⇧C, the Codex snippet 複製, 複製 ID) go through one helper that writes `NSPasteboard.general` only on a user action in a foreground run; in background runs (`AppActivation.isBackground`) it writes a private named pasteboard and the dump; every write logs `pasteboard target=general|private` (never the content). Pasteboard reads for image paste come from the editor's paste action only (DEBUG `-codd-notes-paste-image` injects the data). `NSWorkspace` opens / reveals, `NSOpenPanel`, sounds and notification prompts happen only on user actions. |
| D40 | Source compatibility of existing packages | C3 (CoddHooks, CoddCore), C4 (CoddComposer), C9 (CoddSettingsUI, CoddStatusUI, CoddPreferences) and C10 (CoddClaudeSettings) change packages the App compiles today: new stored properties have defaults, new initialiser parameters have default values, existing public signatures stay, no new case is added to a public enum the App switches over exhaustively (`grep -rn` App/ for each changed type before finishing and list what was checked). Behaviour the App sees stays M3's until an I step opts in (e.g. composer chips default OFF, `promptPath` nil). |
| D41 | Plan review additions | §1 "Added by the plan review"; D38–D40; the integration split into seven smaller steps (I1a, I1b, I2a, I2b, I3, I4a, I4b) and the Cleanup page as its own package (C12) to keep each agent's scope finishable. |

---

## 3. Data formats

### 3.1 The notes folder

```
<dataRoot>/notes/                                   0700
  .codd/notebook.json                               {"v":1,"createdAt":"<ISO>"}  marker
  .codd/state.json                                  per-note app state (D4), v1, 0600, atomic, written 1 s after a change and at quit
  .codd/activity.jsonl                              AI activity (D20), append-only; at open compacted to the newest 5,000 lines / 90 days
  .codd/history/<note-id>/<yyyyMMdd-HHmmss-SSS>-<hash8>.md   snapshots (D8)
  .codd/trash/<relative note path>                  trashed notes (D29); assets under .codd/trash/assets/<note-id>/
  .codd/tombstones.json                             {"v":1,"items":[{"id","title","trashedAt","purgedAt"}]}
  .codd/tmp/                                        temp files for atomic writes (renamed into place)
  2026-10-15-打卡頁-rwd-跑版紀錄.md                 a note (sub-folders allowed)
  assets/<note-id>/<hash6>.png                      pasted image (D9); <hash6>.orig.<ext>; <hash6>.annotated.png (D10, derived)
<dataRoot>/notes-index.sqlite (+ -wal, -shm)        derived index (D5)
<dataRoot>/files/recent.json                        recent local files (C6)
<dataRoot>/files/ai-touches.json                    AI-touched paths (D26)
<dataRoot>/cleanup.json                             session / file keepUntil and digest state (D30, D31)
<dataRoot>/sessions/<uuid>/mcp.json                 per-session MCP config (D18), 0600
```
New files are 0600, folders 0700; existing notes keep their mode.

### 3.2 A note file

```markdown
---
id: rwd-punch-k7x2
title: 打卡頁 RWD 跑版紀錄
kind: note
tags: [rwd, punch]
sessions: [7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10]
projects: [~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend]
ai: read
scope: project
pinned: false
status: active
created: 2026-10-14T18:20:11+08:00
updated: 2026-10-15T10:05:44+08:00
---
# 打卡頁 RWD 跑版紀錄

## 問題
iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。

![截圖 2026-10-15 09:32 · iPhone SE](assets/rwd-punch-k7x2/9f3a1c.png)
```codd-annotations
{"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[…],"send":{"original":false,"annotated":true,"list":true}}
```

## 想請 AI 做的
- [x] 先重現（Chrome DevTools 375 寬）
- [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`
```

Keys (all optional when reading; CODD writes the ones it knows): `id`; `title` (mirror of the H1);
`kind` `note|prompt|scratch`; `tags` (no `#`); `sessions` (CODD session UUIDs, lowercase); `projects`
(paths, `~`-abbreviated); `ai` `off|read|append`; `scope` `global|project` (the primary project = the
first of `projects`); `pinned`; `status` `active|archived`; `archived` (ISO) and `archivedBy`
`auto|user|condense`; `sent` (ISO, a PROMPT's last send) and `sentTo` (session UUID); `created`,
`updated` (CODD writes `updated` at every save; when the file's mtime is newer, the mtime counts);
`condensedFrom` (ids), `condensedInto` (id); `createdBy` `user|ai`. A PROMPT without `sent` is a draft
(`Prompt · 草稿`). Trash is not a status: a trashed note is the file under `.codd/trash/` with
`trashed: <ISO>` added.

### 3.3 The `codd-annotations` block (R6 + the T tool)

```json
{"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],
 "items":[
  {"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},
  {"n":2,"type":"point","x":375,"y":330,"note":"時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},
  {"n":3,"type":"arrow","x":600,"y":760,"x2":700,"y2":1080,"note":"打卡紀錄卡片離按鈕太近，間距加到 16px"},
  {"n":4,"type":"text","x":40,"y":80,"note":"這段文字直接畫在圖上","color":"cyan"}],
 "send":{"original":false,"annotated":true,"list":true}}
```
One block per image, directly after its image line (a block not after an image is shown as a plain
code block). Coordinates are integers in original pixels; `color` is one of `amber` (default),
`cyan`, `danger`, `success`, `cream`. Unknown keys are kept.

### 3.4 App state files

`state.json`: `{"v":1,"notes":{"<id>":{"lastOpenedAt":"<ISO>","openCount":12,"lastUserActivityAt":"<ISO>","keepUntil":null}}}`.

`activity.jsonl`, one object per line: `{"v":1,"at":"<ISO>","note":"<id>","action":"read|append|write|expand|url",
"client":"Claude Code","session":"<uuid>|null","sessionTitle":"打卡頁 RWD 調整|null","via":"mcp|hook|url"}`.

`cleanup.json`: `{"v":1,"sessions":{"<uuid>":{"keepUntil":"<ISO>"}},"files":{"<abs path>":{"keepUntil":"<ISO>"}},"digest":{"lastShownAt":"<ISO>","lastCount":15},"retention":{"firstRunAt":"<ISO>","lastRunAt":"<ISO>"}}` (D30 first-run grace).

Formats §3.1–§3.4 are normative for C1 and C11 alike (C11 writes them in parallel): neither changes a
file format, key name or date format without the plan; only the index schema (§3.5) may be refined
by C1.

`files/recent.json`: `{"v":1,"items":[{"path":"<abs>","root":"<abs project root>","openedAt":"<ISO>","source":"user|note"}]}`
(≤ 20; an entry not opened for 30 days drops). `files/ai-touches.json`: `{"v":1,"items":[{"path":"<abs>","session":"<uuid>","tool":"Edit","at":"<ISO>"}]}` (7 days, ≤ 2,000).
All: 0600, atomic, tolerant (a corrupt file is moved aside to `<name>.corrupt-<ms>` and started over),
a newer `v` read-only.

Cleanup candidate rules (D31): near-duplicate = trigram Jaccard of the bodies ≥ 0.80 among active
notes of the same project (pairs reported once, on the older note); long note = ≥ 3 H2 / H3 sections
whose heading starts with a date (`2026-09-03`, `9/03`, `09/03`) older than 30 days; unused image =
a file in `assets/<id>/` (not `.orig` / `.annotated` of a used one) referenced neither by the body
nor by a snapshot kept by D8, mtime older than 7 days.

### 3.5 Index schema (`PRAGMA user_version = 1`; C1 may refine, the behaviour is the contract)

```sql
CREATE TABLE notes(rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, path TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL, kind TEXT NOT NULL, ai TEXT NOT NULL, scope TEXT NOT NULL, pinned INTEGER NOT NULL,
  status TEXT NOT NULL,            -- active | archived | trashed
  created REAL, updated REAL, archived REAL, trashed REAL, sent REAL,
  mtime REAL NOT NULL, size INTEGER NOT NULL, hash TEXT NOT NULL,
  snippet TEXT NOT NULL, asset_count INTEGER NOT NULL, asset_bytes INTEGER NOT NULL,
  flags INTEGER NOT NULL,          -- frontmatter unparsable, duplicate id, no frontmatter
  search_text TEXT NOT NULL);      -- NFKC lowercased title + body + tags (LIKE path)
CREATE TABLE note_tags(note_rowid INTEGER NOT NULL REFERENCES notes(rowid) ON DELETE CASCADE, tag TEXT NOT NULL, PRIMARY KEY(note_rowid, tag));
CREATE TABLE note_links(note_rowid INTEGER NOT NULL REFERENCES notes(rowid) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK(type IN ('session','project')), target TEXT NOT NULL, PRIMARY KEY(note_rowid, type, target));
CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, tags, content='', contentless_delete=1, tokenize='trigram case_sensitive 0');
```

### 3.6 Reference forms (COPY REF, in the artboard's order)

| # | Form | Hint (artboard) |
|---|---|---|
| 1 | `codd://note/<id>` (`推薦`, ⌘⇧C) | `CODD 啟動的 session 會由 UserPromptSubmit hook 自動展開內容` |
| 2 | `@codd:codd://note/<id>` | `在 Claude Code 輸入框用 @ 附加（MCP resource）` |
| 3 | the absolute file path (shown `~`-abbreviated) | `檔案路徑 · 任何 agent 都能用 Read 讀取` |
| 4 | 複製全文 Markdown | `貼到任何地方；圖片改寫成絕對路徑` |
| 5 | `http://127.0.0.1:<port>/n/<id>.md?t=<24 hex>` (shown `?t=••••`) | `瀏覽器 / curl 用；Claude 的 WebFetch 讀不到 localhost` |

Accepted when parsing (MCP `ref`, the hook): `codd://note/<id>`, `[[note:<id>]]`, `@<server>:codd://note/<id>`
and, for `ref` only, a bare id. Id charset `[a-z0-9]+(-[a-z0-9]+)*`, ≤ 48 characters.

### 3.7 AI text of a note (notes_read, expansion, 插入全文 / 送出, 複製全文 uses the same body rewrite)

```
# 打卡頁 RWD 跑版紀錄
codd://note/rwd-punch-k7x2 · NOTE · #rwd #punch · updated 2026-10-15 10:05 · AI READ
file: ~/Library/Application Support/CODD/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md
links: session 打卡頁 RWD 調整 · project ~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend

## 問題
iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。

[image] /Users/…/notes/assets/rwd-punch-k7x2/9f3a1c.annotated.png (750×1334)
annotations（原圖像素，左上為原點）:
  1 rect  x=20 y=1150 w=710 h=120  上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)
  2 point x=375 y=330  時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px
  3 arrow 600,760 → 700,1080  打卡紀錄卡片離按鈕太近，間距加到 16px
…
```
The annotation header line is the ImageAnnotate artboard's `AI 會收到` text (that preview shows exactly
this text, with the home folder abbreviated to `~` for display only; the AI text keeps absolute paths).
The frontmatter is replaced by the two header lines (+ `links:` when any); image links become
`[image] <absolute path> (<w>×<h>)` following the image's `send` options (原圖 path, annotated copy
path, the list); other relative links become absolute; the rest of the Markdown is unchanged.
`複製全文 Markdown` is the body with the frontmatter dropped and image links rewritten to absolute
paths (the annotation blocks kept).

### 3.8 Per-session MCP config and settings (D18)

`<sessionDir>/mcp.json` (0600):
```json
{"mcpServers":{"codd":{"type":"http","url":"http://127.0.0.1:47821/mcp",
  "headers":{"X-CODD-Token":"<64 hex HMAC-SHA256(hookToken, \"codd-mcp-v1:\" + uuid)>","X-CODD-Session":"<uuid>"}}}}
```
argv: `claude … --mcp-config <sessionDir>/mcp.json --settings '<json>' …` (`--mcp-config` immediately
before `--settings`). `--settings` additions: the UserPromptSubmit handler's `url` is
`http://127.0.0.1:<port>/hooks/prompt` with `timeout: 3` (other fields as today), and
`"permissions":{"allow":["mcp__codd__notes_search","mcp__codd__notes_read","mcp__codd__notes_list"]}`
(with the resolved server name).

### 3.9 Routes on the hook server (C3; wire contract added to Packages/CoddHooks/README.md)

| Route | Auth | Body | Answer |
|---|---|---|---|
| `POST /mcp` | Host rule; `Origin` absent or `http://127.0.0.1:<port>` / `http://localhost:<port>`; `X-CODD-Session` (UUID) + `X-CODD-Token` = `MCPAuth.sessionToken(hookToken, session)`, or the external token as `X-CODD-Token` / `Authorization: Bearer` (no session header) | ≤ 1 MiB | whatever the MCP handler returns (200 `application/json`, 202 empty, 400); 401 / 403 / 413 / 503 (handler > 10 s) from the server |
| `GET`, `DELETE /mcp` | — | — | 405 `Allow: POST` |
| `POST /hooks/prompt` | exactly as `/hooks` | ≤ 1 MiB | the event is yielded on `events` first; then the prompt handler (≤ 1.5 s): 200 `application/json` `{"systemMessage":"…","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…"}}` (`systemMessage` omitted when the handler gives none), or 204 |
| `GET /n/<id>.md?t=<tok>` | Host rule as `/hooks`; no `Origin`; `t` = `MCPAuth.noteURLToken(mcpToken, id)` | — | 200 `text/markdown; charset=utf-8` (§3.7 copy form); 404 unknown id, bad token or an AI OFF note; 410 trashed / purged with a one-line Markdown body |

Response bodies ≤ 16 MiB, `Connection: close` as today. `MCPAuth.sessionToken` = lowercase hex
HMAC-SHA256 keyed with the hook token's UTF-8 over `codd-mcp-v1:<uuid lowercase>`;
`MCPAuth.noteURLToken` = the first 24 hex of HMAC-SHA256 keyed with `mcpToken` over
`codd-note-url-v1:<id>`. Both compared in constant time.

### 3.10 MCP surface (C2)

- `initialize` → `{protocolVersion, capabilities:{tools:{listChanged:false}, resources:{listChanged:false}, prompts:{listChanged:false}},
  serverInfo:{name:"codd", title:"CODD notes", version:<app version>}, instructions}`. Instructions (English, ≤ 4,096
  characters): what CODD notes are, that `codd://note/<id>` / `[[note:<id>]]` in the user's message are note refs to read with
  `notes_read` (unless the prompt already carries `<codd-note …>` context), that images come back with their annotation
  coordinates in original pixels, that append is allowed only where the note says so, never to guess note content.
- `notes_search {query: string, scope?: "project"|"all" (default "all" = everything D17 lets this caller see; "project" narrows to the caller's project / linked notes), tags?: [string],
  kind?: "note"|"prompt"|"scratch", include_archived?: bool, limit?: int 1…20 (10)}` → text list
  `1. 打卡頁 RWD 跑版紀錄 · codd://note/rwd-punch-k7x2 · NOTE · updated 10/15 10:05\n   …snippet…` + `structuredContent {results:[{id, uri, title, kind, tags, updated, snippet, path, state}]}`.
- `notes_list {session?: "current"|<uuid>, project?: "current"|<path>, kind?, pinned?: bool, days?: int, include_archived?: bool, limit?: int 1…50 (20)}`.
- `notes_read {ref: string, offset?: int (0), max_chars?: int 1000…50000 (12000), include_images?: bool (true)}` → content
  `[text §3.7 (+ "（第 n–m 字，共 N 字；下一段 offset=m）" when cut), image blocks…]`; `_meta["anthropic/maxResultSizeChars"]: 200000`.
- `notes_append {ref, markdown: string ≤ 20,000, heading?: string}` → appends
  `\n<!-- codd:ai-append session="<title>" at="<ISO>" -->\n### <heading or "AI 附加 · HH:mm">\n<markdown>\n`, snapshot first;
  isError `這則筆記的 AI 存取是 READ，不能附加` / `… OFF …` otherwise.
- `notes_write {ref, markdown}` (listed only while AI 可寫入 is ON; requiresUserInteraction): replaces the body after the H1
  line of an APPEND note, snapshot first.
- Resources: `resources/templates/list` → `codd://note/{id}` (`text/markdown`); `resources/list` → ≤ 200 visible active notes,
  newest first, `{uri, name: title, mimeType: "text/markdown", annotations:{lastModified}}`; `resources/read` → §3.7 text;
  trashed / purged / unknown / not visible → JSON-RPC `-32602` with `data:{state:"trashed"|"purged"|"unknown", purgeAt?}`.
- Prompts: `note {id}` → one user message with the §3.7 text.
- Errors: parse error `-32700` (HTTP 400), invalid request `-32600`, unknown method `-32601` (incl. `server/discover`),
  bad params `-32602`; batches (2025-03-26) answered as arrays; notifications and responses → 202.
- The `MCP-Protocol-Version` header is checked only for methods other than `initialize` and `server/discover`:
  those two always get their JSON-RPC answer with HTTP 200 (whatever version a newer client's probe names), so the
  legacy fallback of §1 can never be blocked by a 400.

### 3.11 config.json addition

`{"port":…,"token":…,"mcpToken":"<64 hex>","v":1}`; created when missing (an existing file gains the
key at the first start), kept 0600, `HookConfigStore.rotateMCPToken()` replaces it.

### 3.12 Registration entry (`~/.claude.json`, D22)

Top-level `"mcpServers": { …the user's servers unchanged…, "codd": {"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"X-CODD-Token":"<mcpToken>"}} }`.
Codex snippet (dialog text only):
```toml
[mcp_servers.codd]
url = "http://127.0.0.1:47821/mcp"
http_headers = { "X-CODD-Token" = "<mcpToken>" }
```

---

## 4. Components (parallel, outside App/; owned paths disjoint; no dependsOn)

Every component: Swift 6 language mode, strict concurrency complete, zero warnings in its code,
Swift Testing, temp directories only, its own `--scratch-path <repo>/.build-m4-<key>`,
no process left running, a package `README.md` describing its contract (like Packages/CoddHooks/README.md),
and a final report (what was built, public API, tests and numbers, deviations, known issues).
UI packages build only on CoddUI's public API (`Palette`, `TextStyle`, `Draw`, `ChipStyle`, controls,
`SVGPath.parse` for their own icons) and **never edit `Packages/CoddUI`**; they define their own value
models (no CoddCore / CoddNotes / App types), take closures for actions, and host the editors in
`NSView` slots, so integration maps data in. UI tests never order windows front (views without
windows or never-ordered offscreen windows); demos with `--snapshot` render offscreen and never
activate. Every demo renders the artboard's §5 sample so integration can compare by eye.
Components that change an existing package follow D40 (the App at HEAD keeps compiling against it;
grep App/ for every changed type and list the check in the report). Notes, images, repos and JSON
in tests and fixtures are made up; git in tests runs with `GIT_CONFIG_GLOBAL=<empty temp file>`,
`GIT_CONFIG_NOSYSTEM=1` and `-c core.fsmonitor=false`.

- **C1 `notes-core`** — `Packages/CoddNotes` (new): storage, index, search, watcher, history, assets,
  annotations, retention, references, AI text. Uses GRDB 7.11.1.
- **C2 `mcp`** — `Packages/CoddMCP` (new): transport-free MCP JSON-RPC server for notes.
- **C3 `hooks-launch`** — `Packages/CoddHooks`, `Packages/CoddCore`: routes, MCP auth, config token,
  hook settings, launch config, session retention policy, tool file paths.
- **C4 `textkit`** — `Packages/CoddTextKit` (new), `Packages/CoddComposer`: the Markdown live-preview
  editor; composer reference chips.
- **C5 `code-editor`** — `Packages/CoddCodeEditor` (new): code view, lexers, find / replace, inline diff.
- **C6 `files`** — `Packages/CoddFiles` (new; targets `CoddFiles`, `CoddFileEditorUI`): git, tree,
  codecs, watch, save, line diff, recent / AI-touch stores, file editor chrome.
- **C7 `notebook-ui`** — `Packages/CoddNotebookUI` (new): Notebook chrome, drawer, history compare,
  pickers, popover menus.
- **C12 `cleanup-ui`** — `Packages/CoddCleanupUI` (new): the whole Cleanup artboard page (table,
  bulk bar, CONDENSE and POLICY cards). Split out of C7 by the review (D41).
- **C8 `annotate-ui`** — `Packages/CoddAnnotateUI` (new): the ImageAnnotate screen.
- **C9 `settings-status-ui`** — `Packages/CoddSettingsUI`, `Packages/CoddStatusUI`, `Packages/CoddPreferences`.
- **C10 `claude-config`** — `Packages/CoddClaudeSettings`: the `~/.claude.json` MCP installer, Codex snippet.
- **C11 `fixtures`** — `scripts/m4-fixtures/`: notes, images, git project, fake claude m4, MCP client, selftest.

The full component briefs are the `components[].prompt` texts of this plan (repeated below in short):

### C1 `notes-core`
`NotesLibrary` actor (open / list / counts / search / document / create / save with conflict /
metadata update / archive / trash / restore / AI append / AI write / assets / history / activity /
opened / keep / retention / candidates / rebuild / tombstones / changes stream / open-note
coordinator), `Frontmatter` (lossless subset), `NoteID` / filename rules, `NoteReferences`, `NoteAIText`,
`ImageAnnotations` (codec, formatter, burn-in renderer), `ImageAssetStore`, `RetentionPolicy`,
`NoteCleanupRules`, FSEvents watcher. Tests: round trips, CJK search, rebuild cases, watcher, retention,
assets, annotations, performance (1,000 notes index < 2 s debug, search p95 < 20 ms).

### C2 `mcp`
`MCPServer` (`handle(MCPHTTPRequest) async -> MCPHTTPResponse`, events), `MCPNotesBackend` protocol,
tools / resources / prompts per §3.10, negotiation per D16, caps per D17. Tests with a fake backend.

### C3 `hooks-launch`
CoddHooks: §3.9 routes in `HookRequestPolicy` / `HookServer` (async handlers, bodies, content types,
deadlines), `MCPAuth`, `mcpToken` in `HookConfig` (+ rotation), statistics. CoddCore: `ClaudeHookSettings`
prompt route + `permissions.allow`, `MCPLaunchConfig` (file JSON, atomic 0600 write, allowed rules),
`ClaudeMCPServerNames` (read-only key scan), `LaunchRequest.mcpConfigPath` + argv placement,
`SessionRetention` (pure policy), `HookPayload.toolFilePaths`.

### C4 `textkit`
`MarkdownEditorView` (D11 live preview, block decorations, images with overlays + accessory slot,
hidden `codd-annotations`, tasks, code blocks, H2 folding, source mode, paste image callback, ⌘⏎,
links), `MarkdownBlockParser`, `MarkdownRender.attributedPreview`; CoddComposer chips for
`codd://note/<id>`. `codd-markdown-demo` renders the Notebook artboard's document. IME tests.

### C5 `code-editor`
`CodeEditorView` (gutter, lexers D28, find / replace widget, inline diff hunks with actions, AI line
markers, overview ruler, plain / read-only modes, undoable line replacement), `CodeLanguage` +
detector, `SyntaxHighlighter`, `FindEngine`. `codd-code-demo` renders the FileEditor artboard's view.

### C6 `files`
CoddFiles: `GitReader`, `FileTreeModel`, `TextFileCodec`, `FileWatch` + `DirectoryWatcher`,
`FileSaver`, `LineDiff`, `RecentFilesStore`, `AITouchLog`. CoddFileEditorUI: tree, tab strip,
toolbar, disk banner, status items, dirty-close sheet view. `codd-files-demo`.

### C7 `notebook-ui`
Lists column, note list, editor chrome (top bar, COPY REF menu, SEND menu, AI / scope / kind / ⋯
menus), chips row, image annotation summary view, info panel, doc status bar, prompt footer, notes
drawer, history compare view, link / tag pickers. `codd-notebook-demo`.

### C12 `cleanup-ui`
`CleanupPageView` (crumb, title, meta rule, NOTES / SESSIONS / FILES tabs, table with checkboxes,
why / sub, status chips, AI hints, row actions, sticky bulk bar, CONDENSE card states, POLICY card,
keyboard). `codd-cleanup-demo`.

### C8 `annotate-ui`
`ImageAnnotateView` (tools V / R / P / A / T, color, zoom Fit / 100 % / 200 %, handles, ⇧ lock,
Del, ⎋, undo / redo, list with numeric fields and IME-safe comment, send options, AI preview slot,
Markdown source disclosure). `codd-annotate-demo`.

### C9 `settings-status-ui`
Settings 08 / 09 / 12 rows enabled per D33 with new facts / actions; STATUS MCP SERVER card and nav
per D21; preferences untouched unless a field is missing (report it).

### C10 `claude-config`
`ClaudeUserConfigMCPInstaller` (inspect / plan / diff with masked token / apply with lock, backup,
changed-since refusal / remove), `CodexMCPSnippet`. Verifies Claude's lock path in the bundle (read only).

### C11 `fixtures`
`make-notes.sh`, `make-png.py`, `make-git-project.sh`, `make-claude-json.sh`, `fake-claude-m4.sh`
(MCP client over the session's mcp.json, UserPromptSubmit to `/hooks/prompt`, PostToolUse with
file paths, `-p` condense mode), `mcp-client.py`, `selftest.sh`.

---

## 5. Integration (sequential, App/ + project.yml; one agent at a time)

Each step: read the component reports and the previous step's report first; build Debug with fresh
derived data `build/m4i<n>`; app tests green (`CODD_BACKGROUND=1 xcodebuild … test`); zero warnings in
CODD code; no process left; a step report (what changed, numbers, known issues, decisions). Small
fixes inside packages are allowed when an API gap blocks the step (note them). Every CODD launch
passes `-codd-data-root <fresh temp>` and `-codd-claude-dir <temp>` as separate arguments (or
`-codd-mock`), with `export CODD_BACKGROUND=1`.

The review (D41) split the original four steps into seven, each with its own derived data
(`build/m4i1a` … `build/m4i4b`), report and smoke; a step reads every earlier step's report.

- **I1a `notebook-core`** — project graph (all M4 packages incl. CoddCleanupUI), the `-codd-show`
  parser fix, the D38 trash function and the D39 pasteboard helper, `NotesService`, the NOTES area
  (D12) with the Notebook mode (lists, note list, chrome shell, doc status, prompt footer shell), the
  editor binding (load, autosave, conflicts, external changes, image paste, source mode, links),
  search, ⌘⇧N (D13) and the `筆記` menu (D36 notebook part), `SessionVM.notesCount`, mock mode notes
  (D35), DEBUG flags / dump `notes` (core part).
- **I1b `notebook-features`** — Annotate mode (ImageAnnotate), the AI / scope / kind / ⋯ menus, COPY
  REF, the SEND menu shell, link / tag pickers, archive / trash / restore with UNDO, info panel
  content (LINKS, HISTORY with compare, ASSETS, RETENTION), ⌘K NOTES, DEBUG flags / dump (rest of
  `notes`), Notebook and ImageAnnotate mock snapshots.
- **I2a `mcp-server`** — `MCPService` + `NotesMCPBackend` on the hook server (D16, D17, D21),
  per-session injection (D18), prompt expansion with `systemMessage` (D19), note URL route, AI
  activity live, STATUS MCP live, Settings 筆記本 & MCP (registration rows read-only until I2b) +
  重建筆記索引, rail / status bar / Notebook footer, DEBUG / dump `mcp`, `promptExpansion`.
- **I2b `send-register`** — send to session (D14) with the prompt footer, SEND menu and ⌘⏎, the
  session `✎ NOTES` pill + drawer, composer chips, registration (D22) with the Codex sheet and token
  rotation (D23), DEBUG / dump `registration`, `-codd-show split`.
- **I3 `file-editor`** — Files mode (tree, tabs incl. note tabs, code editor, toolbar, banner, status
  items), session header Files, Notebook LOCAL FILES + 開啟資料夾…, git badges, AI-touch tracking
  (D26) and the drawer's `AI 改過的檔案`, SHOW AI CHANGES (D27) with chunk actions, find / replace,
  save / dirty close, disk watching (D25), encodings, DEBUG / dump `files`.
- **I4a `cleanup`** — retention engine (D29, D30 with the first-run grace) incl. sessions, the Cleanup
  page (C12, D31), digest, condense (D32), Settings 清理 rows and the scrollback mirror, DEBUG / dump
  `retention`, `cleanup`.
- **I4b `e2e-report`** — `scripts/m4-e2e.sh`, every older e2e / selftest, Release build, numbers,
  docs (ARCHITECTURE, ROADMAP, CLAUDE.md, package list) and **docs/M4-REPORT.md** (built, how to run,
  numbers, known issues, decisions as implemented, 繁體中文 manual checklist).

---

## 6. DEBUG flags and dump keys (added to `RealModeOptions` / `StateDump`; Release ignores them)

Flags: `-codd-show notebook|note:<id>|annotate:<id>:<asset>|files:<path>|cleanup|split|settings-notebook|settings-cleanup`
(also with `-codd-mock`); `-codd-notes-select <id>`; `-codd-notes-new <title>` (NOTE) /
`-codd-quick-note YES` (D13 path); `-codd-notes-type "<text>"` (typed into the shown editor through
`insertText`); `-codd-notes-paste-image <png>`; `-codd-notes-annotate <id>:<asset>:<json file>`
(the ImageAnnotate `完成` path); `-codd-notes-search "<query>"`; `-codd-notes-set <id>:<key>=<value>`
(ai, scope, kind, pinned, tags); `-codd-notes-trash <id>` / `-codd-notes-archive <id>`;
`-codd-notes-send <id>:ref|full|submit` (to the shown session); `-codd-notes-copy-ref <id>:<1…5>`
(written to the dump, never the pasteboard); `-codd-notes-rebuild YES`; `-codd-now <ISO8601>` (the clock
for retention, digest and lists); `-codd-trash-dir <dir>` (M2 flag, now also for purge and rings);
`-codd-retention-run YES`; `-codd-cleanup-action <tab>:<ids>:keep|archive|trash`; `-codd-condense <ids>`
+ `-codd-condense-account <n|follow>` + `-codd-condense-apply YES`; `-codd-mcp-rotate YES`;
`-codd-claude-json <file>` + `-codd-mcp-register-plan claude-code|remove` + `-codd-mcp-register-apply YES`
(refused for a path resolving to the real `~/.claude.json`) + `-codd-mcp-register-apply-delay <ms>` (0…30000,
like M3's `-codd-hooks-apply-delay`, for the rebase / changed-since checks); `-codd-notes-menu
copy-ref|ai|scope|send` (opens that menu for snapshots); `-codd-open-file <path>`;
`-codd-file-type "<text>"`; `-codd-file-show-ai-changes YES`; `-codd-file-baseline head|saved|ai`;
`-codd-file-hunk <index>:revert|accept`; `-codd-file-save YES`; `-codd-file-find "<query>"`.
`-codd-show` keeps the text after the first `:` exactly as given (paths, ids, asset names); only the
keyword before it is case-insensitive (today the whole value is lowercased: I1a fixes it with a test).
Every new M4 DEBUG flag that takes a path refuses one inside the real home's `.claude*`, `.codex`,
`.claude-swap-backup` or `Library/Application Support/CODD` before reading it (the M3 A13 guard rule,
realpath and lexical, dangling links included).

Dump keys: `notes {root, available, index{rebuilt, reason, count, buildMs}, counts{inbox, pinned, prompts, stale, archive, trash, byProject},
list{name, ids}, selected{id, title, kind, ai, scope, pinned, status, dirty, mode, caret, hash}, search{query, ids, ms},
lastPaste{asset, resized, bytes}, history{id, count}, activity{id, last[]}, externalEvents, copyRef{form, text}, quickNote{id, kind}}`;
`mcp {running, endpoint, clients[{key, kind, name, since}], requests, lastTool, rejections, sessionConfigs[{session, serverName, file}]}`;
`promptExpansion {count, lastRefs, lastChars, lastMs, late}`; `registration {claudeCode{state, plan{added, removed}, applied{backup}}, tokenRotatedAt}`;
`files {root, branch, ahead, behind, modified, aiTouched, tabs[{path, dirty, preview, encoding, eol, language, readOnly, showAI, baseline, hunks}], banner}`;
`retention {firstRunAt, lastRunAt, staleIDs, archived[], purged[], sessionsArchived[], ringsTrashed[], trashTarget}`;
`cleanup {counts{notes, sessions, files}, digest{lastShownAt, notified}, condense{state, previewChars, applied{summary, archived[]}}}`.
Never a token, never an e-mail, never a cswap profile path in a dump or a log.

## 7. Acceptance

Automated: every package suite green with zero warnings (all existing packages + CoddNotes, CoddMCP,
CoddTextKit, CoddCodeEditor, CoddFiles, CoddNotebookUI, CoddAnnotateUI; CoddDialogsUI with
`--skip PresenterTests`); app tests green; Debug and Release `BUILD SUCCEEDED` with zero `warning:`
lines from CODD code (third-party package warnings, if any, listed separately); `scripts/m4-e2e.sh`
all pass twice in a row; `scripts/m3-e2e.sh`, `m2-e2e.sh`, `m1-e2e.sh`, `m1-smoke.sh`,
`m2-fixtures/selftest.sh --with-app`, `m3-fixtures/selftest.sh`, `m4-fixtures/selftest.sh`,
`-CODDSelfTest YES`, `-codd-shortcut-matrix` green; no file written outside the run's temp roots (the
e2e checks what it can prove (§1 automation limits): no `.md` created in project folders, the fake
`.claude.json` byte-identical outside `mcpServers`, no `trash target=system` log line, no
`$HOME/.claude.json.codd-bak-*` created, `~/.codex/config.toml` (if it exists) with an unchanged
fingerprint, every `exec` and write log line inside the temp root, and a source grep that no CODD
code path writes under `.codex`); no `anthropic.com` in any log; no token in any dump or log; the
user's general pasteboard never written by a background run (D39); no process of the run left. Numbers recorded: index build (1,000 notes), search p95 (CJK
1–3 characters), note open, keystroke-to-paint in a 1 MB note, `notes_read` server time (with / without
images), prompt expansion latency, 1 MB / 10 MB file open, idle CPU with the Notebook and the Files
mode shown, footprint.

Manual (user, 繁體中文 checklist in docs/M4-REPORT.md): 注音 in the note editor (title, list items,
`**粗體**` 旁, task items, table, next to an image, code block), the annotation comment field and the
search fields; a real CODD claude session: `/mcp` shows `codd` connected, Claude reads a note via
`notes_search` / `notes_read` (with an annotated image), `codd://note/<id>` in a prompt is expanded,
append on an APPEND note asks permission and lands in the note, OFF notes stay invisible; the user's
own MCP servers still all start; the Claude Code registration on the real `~/.claude.json` with its
backup; the file editor on a real project (git badges, Claude edits an open file → banner / AI badge,
SHOW AI CHANGES, 還原此段 then ⌘S); 交給 Claude 濃縮 with a real account; the Monday digest.

## 8. Risks

- **Live preview + IME** is the largest cost: strict rules (D11), marked-text tests in C4 / C5 / C8,
  a manual 注音 checklist; fallback (documented, not built): plain source mode stays usable.
- **TextKit 1 is legacy**: no new Apple features; the editors sit behind their own views.
- **Claude Code changes** (MCP negotiation, http hook output, credential blanking of
  `CODD_HOOK_TOKEN` in hook headers — if Claude ever blanks it every CODD hook gets 401: the STATUS
  HOOKS `▸ 詳細` counters show it; the MCP path does not depend on env expansion): verified against
  2.1.302 only; the e2e uses a fake claude.
- **`--mcp-config` is variadic**: argv placement is a C3 contract with a test.
- **MCP down while CODD is quit**: sessions continue; Claude marks `codd` failed until `/mcp` reconnect.
- **Writing `~/.claude.json`** while Claude runs: lock, re-read, changed-since refusal, backup; only on
  the button; tests on temp files only.
- **Notes in a path with a space** (`Application Support`): absolute paths are copied unquoted; `@`
  file mentions of such paths may not resolve (use `codd://`).
- **GRDB with Swift 6.4** might warn or fail: D5 fallback to the system SQLite module.
- **Short CJK queries** use `LIKE` scans: fine at notebook scale (measured), noted for > 10k notes.
- **Retention moves things automatically** (archive only; purge only what the user trashed, into the
  macOS Trash): every move logged, restorable, tombstones.
- **Sync / external editors**: content-hash conflicts, D7 banner, duplicate ids (D3).
- **Scope (project notes) is advisory** against a session with Bash: it can `cat` any note file
  (OFF included) — documented, as in design/research/ai-access.md §5.
- **Bash-made file changes** are not attributed to AI (D26).
- **Workload**: the integration is split into seven steps (D41) and the Cleanup page into its own
  package; each step's report lists what moved to the next. C1 (CoddNotes) stays the largest
  component: its brief orders the work (storage, index, search, watcher first) so I1a is not blocked.
- **Automatic moves on the user's real data** (review): retention archives stopped sessions and moves
  rings to the Trash; the D30 first-run grace and D38 keep the first M4 launch and every test root
  from doing either at once.
- **Claude's MCP output budget** (review, §1): pages of 12,000 characters + ≤ 4 images stay under the
  25,000-token cap for CJK notes; longer notes page with `offset`.
- **`~/.claude.json` churn** (review): a real file changes every few seconds while sessions run; the
  installer rebases the member edit under the lock instead of refusing every apply (D22).

## 9. Rules for every agent

Swift 6 language mode, strict concurrency complete, zero warnings in code you touch; concise doc
comments explaining why; no emoji anywhere; UI copy 繁體中文 for explanations, English UPPERCASE for
structural labels, exactly as the artboards. Real mode is the default: every CODD launch passes
`-codd-data-root <fresh temp>` and `-codd-claude-dir <temp>` as separate arguments (bash arrays, never
an unquoted variable holding several flags) or `-codd-mock`, and runs with `CODD_BACKGROUND=1`; never
`open`, never `-codd-background NO`, never AppleScript `activate`, never `CODD_ALLOW_STANDARD_ROOT` /
`CFFIXED_USER_HOME` to dodge the guard; new code never activates the app or orders windows front while
`AppActivation.isBackground`. Never touch `~/.claude/settings.json`, `~/.claude.json` (read-only key
inspection only when a brief needs a format; never print values), `~/.codex`, `~/.claude-swap-backup`,
`~/Library/Application Support/CODD`; never run the real cswap, a real claude session, any claude
subcommand that writes config, or any Anthropic API; `claude --version` / `--help` / `mcp --help` and
reading the installed bundle are allowed. Notes, images and files in tests and fixtures are made up
(the SPEC §5 sample is design data), never copied from the user's machine. Tests only in temp
directories, Swift Testing, your own scratch path and derived data path. Clean up every process you
start; never kill processes you did not start. Background runs never write the user's general
pasteboard and never open / reveal anything (D39); automatic trash moves never reach `~/.Trash` from a
test root (D38); git in tests and fixtures runs with an isolated config (`GIT_CONFIG_GLOBAL=<empty temp
file>`, `GIT_CONFIG_NOSYSTEM=1`, `-c core.fsmonitor=false`) and only in temp repos. A change to an
existing package keeps the App compiling (D40). When a decision with lasting product impact is needed,
take the safest reversible default and list it in your report. Be honest about what does not work.

---

## 10. Briefs (the exact prompts the components and integration steps receive)

The texts below are the `components[].prompt` / `integration[].prompt` of this plan. Each agent also
gets the orchestrator's COMMON rules and the previous reports.

### C1 `notes-core` — new package `Packages/CoddNotes`

You build CODD Desktop M4 component C1 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§1, §2 D1–D10, D17, D19, D20, D29, D31, §3.1–§3.7, §9), design/SPEC.md §5 (Notebook data, n1–n7, ids, references, retention defaults) and §8 R6, design/research/editor-storage.md §3 and retention.md (background; the plan wins), Packages/CoddHooks/README.md (style of a package README), Packages/CoddCore/Sources/CoddCore/Store/AtomicFile.swift (atomic write style to copy, not import).

**Owned paths:** `Packages/CoddNotes/**` only. Do not edit any other package or App/.

**Package:** swift-tools-version 6.2, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`, product library `CoddNotes`, dependency `.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")` (product `GRDB`). Frameworks: Foundation, CoreServices (FSEvents), ImageIO, CoreGraphics, CoreText (burned-in labels; system font with CJK fallback), UniformTypeIdentifiers, CryptoKit. **No AppKit** (the MCP backend calls this off the main actor). **Work order** (I1a starts from your report, so finish the first group solidly before the rest): (1) layout, frontmatter, naming, create / save / metadata, index + search + rebuild, watcher, references, AI text; (2) history, assets, annotations codec + renderer, AI writes, expansion; (3) retention, cleanup candidates, performance. Test target `CoddNotesTests` (Swift Testing) with made-up fixtures only (SPEC §5 sample text is design data; never copy anything from the user's machine). First verify that GRDB 7.11.1 builds warning-free with this toolchain (Swift 6.4, macOS 26 SDK) and that FTS5 + `tokenize='trigram'` works through it; if not, use the system `SQLite3` module behind the same internal API and say so in your report (D5).

**Public API (names are the contract; you may add, report any change):**
```swift
public struct NoteID: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible { public let rawValue: String; public init?(rawValue: String) } // [a-z0-9]+(-[a-z0-9]+)*, ≤ 48
public enum NoteKind: String, Sendable, Codable, CaseIterable { case note, prompt, scratch }
public enum NoteAIAccess: String, Sendable, Codable, CaseIterable { case off, read, append }
public enum NoteScope: String, Sendable, Codable, CaseIterable { case global, project }
public enum ArchiveReason: String, Sendable, Codable { case auto, user, condense }
public enum NoteState: Sendable, Equatable { case active, archived(at: Date, by: ArchiveReason), trashed(at: Date) }
public struct NoteLinks: Sendable, Equatable { public var sessions: [String]; public var projects: [String] }   // lowercase UUIDs; ~-abbreviated paths
public struct NoteFlags: OptionSet, Sendable { unparsableFrontmatter, duplicateID, noFrontmatter }
public struct NoteMetadata: Sendable, Equatable { id, title, kind, tags, links, ai, scope, pinned, state, created, updated, sentAt: Date?, sentTo: String?, condensedFrom: [NoteID], condensedInto: NoteID?, createdBy: String; var isPromptDraft: Bool }
public struct NoteDocument: Sendable, Equatable { metadata, body: String, fileURL: URL, relativePath: String, contentHash: String, flags: NoteFlags, lineEnding: NoteLineEnding }
public enum ExemptReason: String, Sendable { case pinned, linkedLiveSession, readByLiveSession, kept }
public struct NoteSummary: Sendable, Equatable, Identifiable { metadata, snippet (2 lines of plain text, Markdown stripped), assetCount, assetBytes, lastActivity: Date, staleSince: Date?, archivesAt: Date?, purgeAt: Date?, exempt: ExemptReason?, flags, fileURL; var id: NoteID }
public enum SmartList: Sendable, Hashable { case inbox, pinned, prompts, stale, archive, trash, project(String) }
public enum NoteSort: Sendable { case updated, created, title }
public struct NotesCounts: Sendable, Equatable { inbox, pinned, prompts, stale, archive, trash: Int; byProject: [String: Int] }
public struct NoteQuery: Sendable { text: String; includeArchived, includeTrashed: Bool; kinds: Set<NoteKind>?; project: String?; limit: Int }
public struct NoteSearchHit: Sendable, Equatable { summary: NoteSummary; snippet: String; highlights: [NSRange]   /* UTF-16 ranges in snippet */; score: Double }
public struct NewNote: Sendable { title: String; body: String?; kind: NoteKind; tags: [String]; links: NoteLinks; ai: NoteAIAccess?; scope: NoteScope?; createdBy: String }
public enum SaveOutcome: Sendable, Equatable { case saved(NoteDocument), conflict(disk: NoteDocument) }
public enum MetadataChange: Sendable { case kind(NoteKind), tags([String]), addTag(String), removeTag(String), linkSession(String), unlinkSession(String), linkProject(String), unlinkProject(String), ai(NoteAIAccess), scope(NoteScope, primaryProject: String?), pinned(Bool), markSent(at: Date, to: String) }
public struct AIActor: Sendable, Equatable { client: String?; sessionID: String?; sessionTitle: String?; via: String /* mcp|hook|url */ }
public struct NoteActivityEvent: Sendable, Codable, Equatable { at, note: NoteID, action: String /* read|append|write|expand|url */, client, session, sessionTitle, via }
public struct AssetRef: Sendable, Equatable { relativePath: String; pixelSize: CGSize; bytes: Int; resized: Bool; reused: Bool }
public struct AssetInfo: Sendable, Equatable { relativePath, url, bytes, pixelSize, isOriginalCopy, isAnnotatedCopy, referenced: Bool, modified: Date }
public struct NoteSnapshotInfo: Sendable, Equatable, Identifiable { id: String /* file name */; takenAt: Date; bytes: Int; reason: String? }
public struct RetentionPolicy: Sendable, Equatable { staleDays: Int?; archiveDays: Int?; scratchArchiveDays: Int?; trashPurgeDays: Int; tombstoneDays: Int?; exempt: Bool }
public struct RetentionReport: Sendable, Equatable { staleIDs: [NoteID]; archived: [NoteID]; purged: [NoteID]; snapshotsRemoved: Int }
public struct NoteCleanupCandidate: Sendable, Equatable, Identifiable { id: NoteID; reason: Reason; why: String; sub: String; badge: String; aiHint: AIHint?; suggestsCondense: Bool
  public enum Reason: Sendable, Equatable { case stale(days: Int), archivesSoon(days: Int), sentPrompt(days: Int), scratch(days: Int), duplicate(of: NoteID, percent: Int), longNote(sections: Int, olderThanDays: Int), unusedAsset(path: String, days: Int) }
  public enum AIHint: Sendable, Equatable { case keep(lastReadDaysAgo: Int), condense, read(daysAgo: Int) } }
public struct Tombstone: Sendable, Equatable, Codable { id, title, trashedAt, purgedAt }
public struct NoteSection: Sendable, Equatable { heading: String; date: Date?; range: NSRange /* UTF-16 in the body */; text: String }
public enum NoteResolution: Sendable, Equatable { case note(NoteSummary), trashed(NoteSummary, purgeAt: Date), purged(Tombstone), unknown(String) }
public enum NotesChange: Sendable, Equatable { case changed([NoteID]), removed([NoteID]), external([NoteID]), indexRebuilt(count: Int), activity(NoteID), unavailable(String) }
public protocol OpenNoteCoordinator: Sendable { func flushPendingEdits(of id: NoteID) async }   // the app saves its editor before an AI write
public struct NotesOpenReport: Sendable, Equatable { rebuilt: Bool; reason: String?; count: Int; buildMs: Double; warnings: [String] }
public enum NotesError: Error, Sendable, Equatable { case notFound(NoteID), trashed(NoteID, purgeAt: Date), purged(NoteID), unparsableFrontmatter(NoteID), accessDenied(String), tooLarge(String), io(String), unavailable(String) }

public actor NotesLibrary {
  public init(root: URL, indexURL: URL, policy: RetentionPolicy, defaultAccess: NoteAIAccess,
              clock: @escaping @Sendable () -> Date = { Date() },
              trash: @escaping @Sendable (URL) throws -> Void,       // the app moves to the macOS Trash; tests: a folder
              log: @escaping @Sendable (String) -> Void = { _ in })
  public nonisolated let rootURL: URL
  public nonisolated var changes: AsyncStream<NotesChange> { get }   // single consumer
  public func open() async throws(NotesError) -> NotesOpenReport      // creates folders + marker, opens / builds / updates the index, starts the watcher
  public func close() async
  public func setPolicy(_ policy: RetentionPolicy, defaultAccess: NoteAIAccess)
  public func setOpenNoteCoordinator(_ coordinator: (any OpenNoteCoordinator)?)
  public func counts() async throws -> NotesCounts
  public func list(_ list: SmartList, sort: NoteSort, limit: Int) async throws -> [NoteSummary]
  public func summaries(linkedToSession id: String) async throws -> [NoteSummary]
  public func search(_ query: NoteQuery) async throws -> [NoteSearchHit]
  public func summary(_ id: NoteID) async throws -> NoteSummary
  public func document(_ id: NoteID) async throws -> NoteDocument
  public func resolve(_ reference: String) async -> NoteResolution
  public func create(_ note: NewNote) async throws -> NoteDocument      // assigns id + filename (D3), writes the file; the app calls it at the note's first non-empty save (or first image paste), never for an untouched new note
  public func datedSections(_ id: NoteID, olderThanDays: Int) async throws -> [NoteSection]   // §3.4 long-note rule; condense input (D32): heading, date, UTF-16 range, text
  public func save(_ id: NoteID, body: String, basedOn hash: String?) async throws -> SaveOutcome
  public func update(_ id: NoteID, _ change: MetadataChange) async throws -> NoteDocument
  public func archive(_ ids: [NoteID], by reason: ArchiveReason) async throws
  public func unarchive(_ ids: [NoteID]) async throws
  public func trash(_ ids: [NoteID]) async throws
  public func restore(_ ids: [NoteID]) async throws
  public func appendFromAI(_ id: NoteID, markdown: String, heading: String?, actor: AIActor) async throws -> NoteDocument
  public func replaceBodyFromAI(_ id: NoteID, markdown: String, actor: AIActor) async throws -> NoteDocument
  public func saveAsset(_ data: Data, typeHint: String?, for id: NoteID, resizeLongEdge: Int?, keepOriginal: Bool) async throws -> AssetRef
  public func assets(of id: NoteID) async throws -> [AssetInfo]
  public func annotatedImage(for id: NoteID, image relativePath: String) async throws -> URL?
  public func aiImage(_ url: URL, maxLongEdge: Int, maxBytes: Int) async throws -> (data: Data, mimeType: String, pixelSize: CGSize)
  public func history(of id: NoteID) async throws -> [NoteSnapshotInfo]
  public func snapshotText(_ snapshot: NoteSnapshotInfo, of id: NoteID) async throws -> String
  public func restoreSnapshot(_ snapshot: NoteSnapshotInfo, of id: NoteID) async throws -> NoteDocument
  public func recordActivity(_ event: NoteActivityEvent) async
  public func activity(of id: NoteID, limit: Int) async -> [NoteActivityEvent]
  public func markOpened(_ id: NoteID, at: Date) async
  public func keep(_ id: NoteID, until: Date) async
  public func runRetention(liveSessions: Set<String>) async -> RetentionReport
  public func cleanupCandidates(liveSessions: Set<String>) async -> [NoteCleanupCandidate]
  public func rebuildIndex() async throws -> NotesOpenReport
  public func aiText(_ id: NoteID, offset: Int, maxChars: Int) async throws -> NoteAIText.Rendered
  public func expansion(for references: [String], maxChars: Int) async -> NoteAIText.Expansion   // D19
  public func copyMarkdown(_ id: NoteID) async throws -> String
  public func tombstone(_ id: NoteID) async -> Tombstone?
}
public enum NoteReferences { public static func parse(_ text: String, limit: Int) -> [NoteID]   /* codd://note/<id>, [[note:<id>]], @x:codd://note/<id>; order kept, deduped */
  public static func parseRef(_ ref: String) -> NoteID?   /* also a bare id */
  public static func forms(id: NoteID, fileURL: URL, port: Int?, urlToken: String?) -> [NoteReferenceForm] }   // §3.6 order, text + display text + hint
public enum NoteAIText { public struct Rendered: Sendable { text: String; truncated: Bool; nextOffset: Int?; images: [ImagePart] }
  public struct ImagePart: Sendable { original: URL; annotated: URL?; pixelSize: CGSize; includeOriginal: Bool; includeAnnotated: Bool }
  public struct Expansion: Sendable { context: String?; systemMessage: String?; noteIDs: [NoteID]; refused: [String] }
  public static func render(_ document: NoteDocument, root: URL, links: (sessionTitle: (String) -> String?, project: (String) -> String?)?, offset: Int, maxChars: Int) -> Rendered }
public struct ImageAnnotations: Sendable, Equatable, Codable { v, image: String, size: CGSize-ish [w,h] ints, items: [Item], send: SendOptions
  public struct Item: Sendable, Equatable, Codable { n: Int; type: Kind /* rect point arrow text */; x, y: Int; w, h, x2, y2: Int?; note: String; color: String? }
  public struct SendOptions: Sendable, Equatable, Codable { original = false, annotated = true, list = true }
  public static func decode(_ json: String) -> ImageAnnotations?; public func encoded() -> String   /* stable key order, compact, CJK unescaped */
  public func formattedList() -> String   /* §3.7 lines */ }
public enum AnnotatedImageRenderer { public static func render(image: URL, annotations: ImageAnnotations) throws -> Data }   // PNG, boxes / pins / arrows / text burned in
public enum FencedBlocks { public static func find(info: String, in body: String) -> [FencedBlock]; public static func replacingBlock(after imageLine: Int, info: String, with json: String?, in body: String) -> String }
public enum NoteNaming { public static func makeID(title: String, tags: [String], taken: (NoteID) -> Bool) -> NoteID; public static func fileName(title: String, date: Date, timeZone: TimeZone, taken: (String) -> Bool) -> String }
public struct Frontmatter: Sendable, Equatable { public static func split(_ text: String) -> (frontmatter: Frontmatter?, body: String, bodyOffset: Int); public var isParsable: Bool; public func scalar(_ key: String) -> String?; public func list(_ key: String) -> [String]?; public mutating func set(_ key: String, scalar: String?); public mutating func set(_ key: String, list: [String]?); public func serialized() -> String }
```

**Behaviour (the plan's D1–D10, D19, D20, D29, D31 and §3 are normative):**
- Layout §3.1: create `.codd/` with `notebook.json` (0700 folders, 0600 files); every write = temp in `.codd/tmp/` + rename (atomic), never a partial note on disk. Own writes remembered as (relative path, SHA-256) and ignored by the watcher.
- Frontmatter §3.2 / D2: lossless subset parser + line patcher; untouched files round-trip byte for byte; changing one key changes only that line (or appends the key before the closing `---`); unknown keys / comments / order kept; CRLF files stay CRLF; unparsable → defaults + flag, and every `update` / `archive` / `trash` of that note throws `.unparsableFrontmatter` (the body save still works and never touches the frontmatter text). Title = first H1 of the body (`# x`), mirrored into `title:` at save; no H1 → `title:` or `未命名筆記`.
- Ids / filenames D3 (NFC, CJK kept, collisions, never renamed; created on disk only by `create`; no frontmatter → derived stable id; duplicate ids → `<id>-dup<n>` + flag).
- Index D5 / §3.5 (`PRAGMA user_version`, `quick_check`, missing / corrupt / version → full rebuild; at open compare (path, mtime, size); incremental from watcher and own writes; yield between files; never blocks a read > ~50 ms; report `buildMs`; the sqlite files get `NSURLIsExcludedFromBackupKey`, the notes folder never does). FTS5 through raw SQL; the contentless table stores NFKC-lowercased title / body / tags; add a plain-text `body_text` column (Markdown stripped, original case) for snippets.
- Search D6: trigram MATCH for terms ≥ 3 Unicode scalars (each term an FTS5 string literal with `"` doubled — a query like `a-b`, `AND` or `"` must never be parsed as FTS syntax), LIKE for shorter (escape `%` `_` `\`), `#tag` filters, quotes, AND; snippet built in Swift around the first match in `body_text` (contentless FTS5 returns no `snippet()`), matched case- and width-insensitively, with UTF-16 highlight ranges into the snippet; ranking bm25 → pinned → updated.
- Formats §3.1–§3.4 are shared with C11's fixtures (built in parallel): keep them exactly; only §3.5 may be refined.
- Watcher D7: FSEvents file events, recursive on the root, 200 ms coalescing, `.codd/` and `assets/` ignored for notes (assets changes update asset counts), external create / modify / delete / rename → index + `changes` (`.external([id])` for files not written by CODD).
- Lists / counts §2 D29: INBOX = active; PINNED; PROMPTS; STALE (active, not exempt, last activity older than staleDays); ARCHIVE; TRASH; `project(path)` = active notes linking that project (normalized `~` path; a note's project link matches the path or a parent? exact path only).
- History D8 (merge window 5 min, forced reasons, thinning schedule, ≤ 200 per note, > 2 MiB skipped).
- Assets D9 (hash6 naming + lengthening, reuse, 20 MiB cap, formats via ImageIO, HEIC / HEIF / TIFF re-encoded, downscaled output as PNG (JPEG stays JPEG), downscale to 2576 long edge with high quality, `.orig` copy, 0600). `aiImage` downscales to ≤ 1568 px and re-encodes JPEG / PNG under `maxBytes`.
- Annotations D10 / §3.3: codec, `formattedList`, burn-in renderer (amber 3 px boxes with black halo, numbered 28 px squares, arrows with heads, text labels on a black plate; scale with image size), cached `<hash6>.annotated.png` keyed by the block JSON (store the block hash in a sidecar name or regenerate when older than the note); deleted with the note.
- AI text §3.7 (`render`, offset paging by characters (default page 12,000), the image `send` options decide which paths / lists appear, the annotation header `annotations（原圖像素，左上為原點）:` as the ImageAnnotate artboard shows it) and `expansion` (D19: ≤ 5 refs, ≤ maxChars total with a cut message, one line per OFF / unknown / trashed / purged ref (an OFF ref's line never names the note's title), wraps each note in `<codd-note ref="codd://note/<id>" title="…">…</codd-note>` after the header line `CODD 已展開使用者提到的筆記（不需要再呼叫 notes_read）：`; `Expansion` also carries the `systemMessage` text of D19 and the image count per note).
- AI writes: `appendFromAI` only when ai == append (else `.accessDenied("這則筆記的 AI 存取是 READ，不能附加")` / OFF text), asks the coordinator to flush first, snapshots, appends the §3.10 block, records activity; `replaceBodyFromAI` keeps the H1 line.
- Retention D29 (activity rules, exemptions incl. activity of live sessions, keepUntil, scratch / sent prompt timing, purge through `trash` of the note file + `assets/<id>/` + `.codd/history/<id>/`, tombstones with `tombstoneDays`, nil = forever) and cleanup candidates §3.4 / D31 (why / sub / badge strings exactly as the Cleanup artboard: `21 天未開啟` / `最後開啟 9/24` / `stale 21d`, `已送出 7 天` / `archives in 0d`, `SCRATCH` / `快速筆記 7 天後自動封存`, `近似重複（與第 3 章 82% 相同）` / `對照「…」` / `dup 82%`, `長期筆記 · 9 段超過 30 天` / `9 段 > 30d`, `草稿 18 天未動` / `從未送出`, `27 天無活動` / `3 天後自動封存` / `archives in 3d`; AI hints `AI 2d 前讀取 → 建議保留`, `適合濃縮`, `AI 9d 前讀取`).
- Threading: an actor; blocking file IO is fine inside it but long loops yield; FSEvents on its own dispatch queue hopping into the actor; `changes` buffered newest-wins per id.

**Tests (Swift Testing, temp dirs only):** frontmatter round trip (byte-identical untouched, single-key patch, comments, CRLF, unparsable refusal), naming (the SPEC title → `2026-10-15-打卡頁-rwd-跑版紀錄.md`; id rules incl. `rwd-punch-xxxx` from title + tags, collisions, tombstoned ids not reused), create / save / conflict (`basedOn` mismatch), metadata changes, archive / trash / restore / purge (trash closure receives the right URLs; tombstone; resolve answers), index: build, out-of-date update after touching files, rebuild after deleting / corrupting the db / changing `user_version`, external create / edit / delete / rename picked up by the watcher within 3 s (own writes not reported as external), duplicate ids, notes without frontmatter, sub-folders, dot-folders ignored; CJK search: `打卡頁` (MATCH), `打卡` and `卡` (LIKE), `RWD 打卡` (mixed AND), `#rwd`, `"跑版 紀錄"`, ASCII case-insensitive, highlight ranges correct in UTF-16 for CJK and emoji-free text (and for a full-width `ＲＷＤ` body found by `rwd`), FTS syntax characters (`a-b`, `AND`, `"`, `*`) searched literally, archived excluded unless asked; `datedSections` (`2026-09-03`, `9/03`, `09/03` headings); counts and lists incl. STALE / exemptions; history merge / forced / thinning with a manual clock; assets (resize of a generated 4000×3000 PNG to 2576, keep original, dedupe, collision lengthening, 20 MiB refusal, a generated HEIC re-encoded); annotations codec (the SPEC R6 example round trip, unknown keys kept), `formattedList` text equals §3.7, renderer (output size, a pixel inside box 1's stroke is amber-ish); AI text (§3.7 for the SPEC n1 note incl. send options, paging), expansion (cap, refused lines), appendFromAI (block format, snapshot, activity, coordinator called), access errors; retention table (stale at 14 d, archive at 30 d, scratch 7 d, sent prompt 7 d, pinned / linked-live / read-by-live exempt, keepUntil, purge at 30 d, tombstone expiry); cleanup candidates (each reason, Jaccard duplicate ≥ 0.80, long-note sections, unused asset rules incl. snapshot references); performance: index build of 1,000 generated notes (~4 KB each) < 2 s in debug, search p95 < 20 ms over them for 1-, 2- and 3-character CJK terms (print the numbers).

**Acceptance (run exactly):**
`swift build --package-path Packages/CoddNotes --scratch-path <repo>/.build-m4-notes --build-tests 2>&1 | grep -E "warning:|error:" | grep -v "/.build-m4-notes/checkouts/"` → empty (list GRDB's own warnings separately if any);
`swift test --package-path Packages/CoddNotes --scratch-path <repo>/.build-m4-notes` → all pass. Write `Packages/CoddNotes/README.md` (layout, formats, API, threading, search rules). Report: API as built, deviations, numbers (build, search, render), known issues.

### C2 `mcp` — new package `Packages/CoddMCP`

You build CODD Desktop M4 component C2 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§1 facts about Claude Code's MCP client, §2 D16, D17, D20, D21, §3.6, §3.7, §3.9, §3.10, §9), design/research/ai-access.md §1–§2 (background). You may read the installed Claude Code bundle (`~/.local/share/claude/versions/2.1.302`, read only, e.g. with a small python mmap search) to confirm client behaviour; never start claude.

**Owned paths:** `Packages/CoddMCP/**` only.

**Package:** swift-tools-version 6.2, macOS 26, `swiftLanguageModes: [.v6]`, Foundation only, no dependencies (hand-written JSON-RPC; no MCP SDK: the Swift SDK lags the spec, D16). Library `CoddMCP`, test target `CoddMCPTests`.

**Contract:**
```swift
public struct MCPHTTPRequest: Sendable { public var method: String; public var headers: [(name: String, value: String)]; public var body: [UInt8]; public var caller: MCPCaller }
public struct MCPHTTPResponse: Sendable, Equatable { public var status: Int; public var contentType: String?; public var headers: [(name: String, value: String)]; public var body: [UInt8] }
public struct MCPCaller: Sendable, Hashable { public enum Kind: Sendable, Hashable { case session(UUID), external }; public var kind: Kind }
public struct MCPServerInfo: Sendable { public var name = "codd"; public var title = "CODD notes"; public var version: String; public var instructions: String = MCPInstructions.notes }
public enum MCPToolOutcome: Sendable, Equatable { case ok, isError(String), failed(String) }
public enum MCPEvent: Sendable, Equatable { case initialized(caller: MCPCaller, clientName: String?, clientVersion: String?, protocolVersion: String, at: Date)
  case tool(caller: MCPCaller, name: String, outcome: MCPToolOutcome, ms: Double, at: Date)
  case resource(caller: MCPCaller, uri: String, ok: Bool, at: Date)
  case request(caller: MCPCaller, method: String, at: Date) }
public struct MCPSearchRequest: Sendable, Equatable { query: String; scope: Scope /* project | all */; tags: [String]; kind: String?; includeArchived: Bool; limit: Int }
public struct MCPListRequest: Sendable, Equatable { session: String? /* "current" | uuid */; project: String? /* "current" | path */; kind: String?; pinned: Bool?; days: Int?; includeArchived: Bool; limit: Int }
public struct MCPReadRequest: Sendable, Equatable { ref: String; offset: Int; maxChars: Int; includeImages: Bool }
public struct MCPAppendRequest: Sendable, Equatable { ref: String; markdown: String; heading: String? }
public struct MCPWriteRequest: Sendable, Equatable { ref: String; markdown: String }
public struct MCPNoteHit: Sendable, Equatable { id, uri, title, kind: String; tags: [String]; updated: Date; snippet: String; path: String; state: String }
public struct MCPImage: Sendable, Equatable { data: Data; mimeType: String; path: String }
public struct MCPNoteContent: Sendable, Equatable { text: String; images: [MCPImage]; extraImagePaths: [String]; truncated: Bool; nextOffset: Int? }
public struct MCPWriteResult: Sendable, Equatable { id: String; uri: String; text: String /* short confirmation */ }
public struct MCPResourceEntry: Sendable, Equatable { uri, name, mimeType: String; lastModified: Date? }
public struct MCPBackendCapabilities: Sendable, Equatable { writeEnabled: Bool }
public enum MCPBackendError: Error, Sendable, Equatable { case notFound(String), trashed(id: String, purgeAt: Date?), purged(id: String), accessDenied(String), invalid(String), tooLarge(String), unavailable(String) }
public protocol MCPNotesBackend: Sendable {
  func search(_ r: MCPSearchRequest, caller: MCPCaller) async throws -> [MCPNoteHit]
  func list(_ r: MCPListRequest, caller: MCPCaller) async throws -> [MCPNoteHit]
  func read(_ r: MCPReadRequest, caller: MCPCaller) async throws -> MCPNoteContent
  func append(_ r: MCPAppendRequest, caller: MCPCaller) async throws -> MCPWriteResult
  func write(_ r: MCPWriteRequest, caller: MCPCaller) async throws -> MCPWriteResult
  func resources(caller: MCPCaller) async throws -> [MCPResourceEntry]
  func readResource(uri: String, caller: MCPCaller) async throws -> String
  func promptNote(id: String, caller: MCPCaller) async throws -> String
  func capabilities(caller: MCPCaller) async -> MCPBackendCapabilities }
public final class MCPServer: Sendable {
  public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  public init(info: MCPServerInfo, backend: any MCPNotesBackend, clock: @escaping @Sendable () -> Date = { Date() })
  public func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse
  public var events: AsyncStream<MCPEvent> { get }   // single consumer, newest 512 buffered
}
public enum MCPInstructions { public static let notes: String }   // English, ≤ 4,096 characters (test it)
```

**Behaviour (D16 / D17 / §3.10 are normative):**
- HTTP: only `POST` reaches `handle` in practice, but answer `GET` / `DELETE` with 405 `Allow: POST` too. Body = one JSON-RPC message or (2025-03-26) a batch array. Requests → 200 `application/json` (write JSON with `.withoutEscapingSlashes`, CJK unescaped UTF-8). Only notifications / responses → 202 with an empty body. Invalid JSON → 400 with a `-32700` error object (`id: null`). A `MCP-Protocol-Version` header naming a version not in `supportedProtocolVersions` → 400 (`-32600`, message lists the supported versions) — except for `initialize` and `server/discover`, which always get their JSON-RPC answer with HTTP 200 (a newer client's probe may name a newer version; the legacy fallback must never be blocked). The negotiated version of a request = that header, else `2025-03-26` (spec default); `structuredContent` / `outputSchema` only for `2025-06-18`+.
- Stateless: never emit `Mcp-Session-Id`; every request stands alone (an app relaunch never breaks a client).
- Methods: `initialize` (echo `params.protocolVersion` when supported, else `2025-11-25`; capabilities `tools`, `resources`, `prompts` each `{listChanged:false}`; `serverInfo {name, title, version}`; `instructions`); `notifications/initialized`, `notifications/cancelled` → 202; `ping` → `{}`; `tools/list`; `tools/call`; `resources/list`; `resources/templates/list`; `resources/read`; `prompts/list`; `prompts/get`; anything else, **including `server/discover`**, → `-32601` (Claude then uses the legacy handshake, §1). Unknown params ignored; wrong types → `-32602`.
- Tools (§3.10): `notes_search`, `notes_list`, `notes_read` (annotations `readOnlyHint: true, destructiveHint: false, openWorldHint: false`; `_meta: {"anthropic/alwaysLoad": true}` on search and read; `"anthropic/maxResultSizeChars": 200000` on read), `notes_append` (`readOnlyHint: false, destructiveHint: false`), `notes_write` listed only when `capabilities(caller).writeEnabled` (`destructiveHint: true`, `_meta {"anthropic/requiresUserInteraction": true}`). JSON Schemas with descriptions (English, short, mention 繁體中文 notes are common). Argument validation and clamping per §3.10 (limits, `max_chars` 1000…50000 with default 12000 — §1 output budget: Claude caps an MCP result at 25,000 tokens and a CJK note costs about a token per character —, `scope` default `all` (it only narrows what the backend lets the caller see), markdown ≤ 20,000 characters for append). Results: text block(s) + for read up to 4 `{type:"image", data:<base64>, mimeType}` blocks + a text line listing `extraImagePaths`; search / list also `structuredContent {results:[…]}` when negotiated ≥ 2025-06-18. Backend errors → tool result `isError: true` with the 繁體中文 / English reason text (`MCPBackendError` messages: trashed → `這則筆記在 CODD 垃圾桶（<date> 永久刪除），請使用者先還原`; purged → `這則筆記已永久刪除`; not found → `找不到筆記 <ref>`); a thrown non-backend error → isError with a generic message (never a stack trace).
- Resources: list / templates (`codd://note/{id}`, `text/markdown`), read → `{contents:[{uri, mimeType:"text/markdown", text}]}`; errors → JSON-RPC `-32602` with `data {state: "trashed"|"purged"|"unknown", purgeAt?}`.
- Prompts: `note` with required argument `id` → `{messages:[{role:"user", content:{type:"text", text}}]}`.
- Events: `initialized` (with `clientInfo.name` / `version`), `tool` (name, outcome, duration), `resource`, `request` (every call).
- Concurrency: `MCPServer` is `Sendable` (immutable config + an `AsyncStream` continuation); `handle` may run many requests concurrently.

**Tests (Swift Testing, a fake backend):** negotiation (`server/discover` → -32601 with HTTP 200, also with an unknown `MCP-Protocol-Version: 2026-07-28` header; initialize echoes `2025-06-18`, unknown version → `2025-11-25`, an unknown header on initialize ignored; bad protocol header on `tools/list` → 400), 202 for notifications and for a batch of only notifications, batch with requests → array, parse error 400, GET/DELETE 405, tools/list contents (names, schemas valid JSON Schema shapes, annotations, `_meta` keys, notes_write hidden / shown by capabilities), each tool's argument validation and clamping, results shape (text + base64 images + structuredContent only when ≥ 2025-06-18), isError mapping for every `MCPBackendError`, resources list / templates / read / -32602 data, prompts, CJK text survives byte-exact, slashes unescaped, instructions ≤ 4,096 characters, events emitted in order, concurrent `handle` calls (100 in parallel), a 3 MB image result encodes correctly. A golden test of the exact `initialize` and `tools/list` responses (pretty-printed fixture files).

**Acceptance (run exactly):** `swift build --package-path Packages/CoddMCP --scratch-path <repo>/.build-m4-mcp --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddMCP --scratch-path <repo>/.build-m4-mcp` → all pass. Write `Packages/CoddMCP/README.md` (wire contract: methods, tools, errors, versions, statelessness). Report: API, the golden responses, deviations, known issues (e.g. no SSE, no list_changed).

### C3 `hooks-launch` — `Packages/CoddHooks` + `Packages/CoddCore`

You build CODD Desktop M4 component C3 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§1, §2 D15, D16, D18, D19, D21, D23, D26, D30, §3.8, §3.9, §3.11, §9), Packages/CoddHooks/README.md and every file in Packages/CoddHooks/Sources/CoddHooks (HookServer.swift, HTTP/HookRequestPolicy.swift, HTTP/HTTPMessage.swift, HookConfig.swift), Packages/CoddCore/Sources/CoddCore/Launch/{HookSettings,LaunchBuilder}.swift, Hooks/HookPayload.swift, Models/LayoutModels.swift (SessionRecord: `lastState`, `lastStateAt`, `archivedAt`), docs/ARCHITECTURE.md "App: terminals, sessions, states" and "Hook endpoint" parts.

**Owned paths:** `Packages/CoddHooks/**`, `Packages/CoddCore/**`. Changes are additive: every existing test of both packages stays green and every existing wire behaviour (`/hooks` 204 before decoding, `/statusline`, `/health`, the Origin refusal on those routes, config.json compatibility) is unchanged.

**CoddHooks contract:**
```swift
public enum MCPAuth {
  public static func sessionToken(hookToken: String, sessionID: UUID) -> String   // hex HMAC-SHA256(key: hookToken UTF-8, "codd-mcp-v1:" + uuid lowercased)
  public static func noteURLToken(mcpToken: String, noteID: String) -> String      // first 24 hex of HMAC-SHA256(key: mcpToken, "codd-note-url-v1:" + id)
  public static func makeToken() -> String                                         // 32 random bytes, hex (SecRandomCopyBytes)
}
public enum MCPRouteCaller: Sendable, Hashable { case session(UUID), external }
public struct HTTPRouteRequest: Sendable { public var method: String; public var path: String; public var query: [String: String]; public var headers: [(name: String, value: String)]; public var body: [UInt8] }
public struct HTTPRouteResponse: Sendable, Equatable { public var status: Int; public var contentType: String?; public var headers: [(name: String, value: String)]; public var body: [UInt8]; public static func status(_ code: Int) -> HTTPRouteResponse }
public struct PromptHookAnswer: Sendable, Equatable { public var additionalContext: String; public var systemMessage: String? }   // D19: systemMessage is shown to the user by Claude
// HookRoute gains: case mcp(caller: MCPRouteCaller), case promptHook(sessionID: UUID), case noteURL(id: String, token: String)
// HookServer gains (all async, hop onto its queue):
public func setMCPHandler(_ handler: (@Sendable (MCPRouteCaller, HTTPRouteRequest) async -> HTTPRouteResponse)?) async
public func setPromptHandler(_ handler: (@Sendable (UUID, HookPayload) async -> PromptHookAnswer?)?) async
public func setNoteURLHandler(_ handler: (@Sendable (String) async -> HTTPRouteResponse)?) async
public func setMCPToken(_ token: String?) async
// HookConfig gains `mcpToken: String?` with `init(port:token:mcpToken: String? = nil)` so every existing `HookConfig(port:token:)` call
// (App/Real/HookPipeline.swift, tests) still compiles (D40); `loadOrCreate` adds a missing key (an existing config.json gains it at load,
// rewritten 0600 atomically, port, token and unknown keys untouched) so a loaded config always has one; `reassignPort` / `setPort` /
// every rewrite carry the existing mcpToken through; HookConfigStore.rotateMCPToken() throws -> HookConfig.
// HookServerStatistics gains mcpRequests, mcpRejected, lastMCPAt, promptHooks, promptAnswered, promptLate, noteURLRequests.
```
Routes and rules exactly as §3.9: `/mcp` (POST; GET / DELETE → 405 `Allow: POST`; Host rule as today; **Origin**: absent or exactly `http://127.0.0.1:<port>` / `http://localhost:<port>` (case-insensitive scheme/host), anything else 403; auth: `X-CODD-Session` exactly once and a UUID + `X-CODD-Token` equal (constant time) to `MCPAuth.sessionToken(hookToken, session)` → `.session(uuid)`; else no session header and `X-CODD-Token` or `Authorization: Bearer <t>` equal to the mcp token → `.external`; else 401 with no `WWW-Authenticate`; body framing required, ≤ 1 MiB else 413); `/hooks/prompt` (exactly the `/hooks` auth and limits; the decoded `HookPayload` is yielded on `events` **before** the prompt handler runs; handler deadline 1.5 s; answer 200 `application/json` `{"systemMessage":<string, only when given>,"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":<string>}}` (encoded with JSONSerialization or your JSON writer, UTF-8, slashes unescaped) when the handler returns an answer in time, else 204; no handler → 204); `GET /n/<id>.md?t=<tok>` (the Host rule as `/hooks`; no Origin at all; parse the query; `t` must equal `MCPAuth.noteURLToken(mcpToken, id)` else 404; handler result passed through (200 / 404 / 410), no handler → 404). The request path with a query must still route `/hooks`, `/statusline`, `/health` exactly as before (no query accepted there). Handlers run in a Task off the server queue; the connection's timeouts must not fire while a handler runs; responses are written back on the queue; bodies ≤ 16 MiB; MCP handler > 10 s → 503 with a JSON-RPC error body; a closed client connection cancels nothing harmful. Statistics and the last-rejection reason cover the new routes (never quoting a token). Update the README wire contract.

**CoddCore contract:**
```swift
// Launch/HookSettings.swift
public struct ClaudeHookSettings { …existing…
  public var promptPath: String?            // nil: UserPromptSubmit → endpoint.url (/hooks); "/hooks/prompt" (D18/D19)
  public var promptTimeoutSeconds: Int = 3
  public var permissionsAllow: [String] = []   // emitted as "permissions":{"allow":[…]} only when non-empty
}
// Launch/MCPLaunchConfig.swift (new)
public struct MCPLaunchConfig: Sendable, Equatable {
  public var serverName: String; public var port: UInt16; public var token: String; public var sessionID: UUID
  public var url: String { get }                                    // http://127.0.0.1:<port>/mcp
  public func jsonData() throws -> Data                              // §3.8, sorted keys, compact
  public func write(to file: URL) throws                             // atomic, 0600, parent must exist (throws otherwise)
  public static func allowRules(serverName: String) -> [String]      // mcp__<name>__notes_search, …notes_read, …notes_list
}
public enum MCPServerNameResolver {
  public struct Existing: Sendable, Equatable { public var names: Set<String>; public var coddURL: String? }
  public enum Resolution: Sendable, Equatable { case inject(name: String), userRegisteredOurs }
  public static func scan(claudeJSON: URL?, cwd: String, projectMCPJSON: URL?) -> Existing   // keys only (top-level mcpServers, projects[cwd].mcpServers and projects[realpath(cwd)].mcpServers, .mcp.json mcpServers); only the `codd` entry's url string is read; ≤ 64 MiB; unreadable → empty; the caller passes <claudeDir>/../.claude.json, or <CLAUDE_CONFIG_DIR>/.claude.json for a pinned session (never logged)
  public static func resolve(_ existing: Existing, ourURL: String) -> Resolution              // codd absent → codd; codd == ours → userRegisteredOurs; else codd-desktop (then codd-desktop-2 …)
}
// Launch/LaunchBuilder.swift
// LaunchRequest gains `mcpConfigPath: String?`; LaunchBuilder emits `--mcp-config <path>` IMMEDIATELY BEFORE `--settings` (the flag is variadic,
// §1); with no hooks there is no MCP (the path is ignored and logged by the caller). Profile extraArguments that already contain --mcp-config stay.
// Retention/SessionRetention.swift (new)
public struct SessionRetentionPolicy: Sendable, Equatable { public var staleDays: Int?; public var archiveDays: Int?; public var scrollbackDeleteDays: Int?; public var cleanupPeriodDays: Int; public var resumeWarning: Bool = true; public var resumeWarningDays: Int = 5
  public var countFrom: Date? }   // D30 first-run grace: every clock (stopped → stale / archive, archived → ring) starts no earlier than this
public struct SessionRetentionInput: Sendable, Equatable { id: UUID; title: String; kind: SessionKind; isRunning, isPinned, isExternal: Bool; lastState: SessionState?; lastStateAt: Date?; archivedAt: Date?; keepUntil: Date?; transcriptModifiedAt: Date?; transcriptExists: Bool?; ringBytes: Int64? }
public struct SessionCleanupCandidate: Sendable, Equatable, Identifiable { id: UUID; reason: Reason; why: String; sub: String; badge: String
  public enum Reason: Sendable, Equatable { case stopped(days: Int), archivesSoon(days: Int), resumeExpires(days: Int), transcriptGone, ring(bytes: Int64, deletesInDays: Int) } }
public struct SessionRetentionResult: Sendable, Equatable { staleIDs: Set<UUID>; archiveIDs: [UUID]; ringDeleteIDs: [UUID]; candidates: [SessionCleanupCandidate] }
public enum SessionRetention { public static func evaluate(_ sessions: [SessionRetentionInput], policy: SessionRetentionPolicy, now: Date) -> SessionRetentionResult }
// Hooks/HookPayload.swift
extension HookPayload {
  public var prompt: String? { get }          // UserPromptSubmit `prompt`
  public var toolFilePaths: [String] { get }  // PostToolUse only: Edit / Write / MultiEdit tool_input.file_path, NotebookEdit notebook_path; relative → resolved against cwd; standardized absolute paths; deduped
}
```
SessionRetention rules (D30): only CODD sessions (`isExternal` false), not running, not pinned, `keepUntil` in the future exempts; stopped = `lastState` in {stopped, exited} with `lastStateAt`; stale after `staleDays`; archive after `archiveDays` (not already archived); ring delete when `archivedAt` older than `scrollbackDeleteDays` and `ringBytes` > 0; `resumeExpires` when `resumeWarning` is on and a claude session's transcript mtime + `cleanupPeriodDays` − now ≤ `resumeWarningDays`; `transcriptGone` when `transcriptExists == false`; with `countFrom` set, a session stopped (or archived) before it is treated as stopped (archived) at `countFrom` for the stale / archive / ring clocks (candidates still list it, with the later due date). Texts (Cleanup artboard voice): why `停止 5 天` / sub `最後畫面保留到 11/12` / badge `stale 5d`; `archives in 2d`; `resume expires 4d` (sub `Claude Code 30 天後刪除對話紀錄`); `對話紀錄已不存在`; ring: why `終端機紀錄 · 8.0 MB` / sub `封存 26 天` / badge `deletes in 4d`. nil days = never.

**Tests (Swift Testing; temp dirs; the existing suites stay green):** policy routing table for every new route × method × Origin × Host × token kind (session token right / wrong / for another uuid, external token as X-CODD-Token and as Bearer, missing), 413 / 411, query parsing, `/hooks` with a query still 404 as before; a live `HookServer` on a test port: MCP handler pass-through (status, content type, body bytes), slow handler (200 ms) keeps the connection, > 10 s → 503 (use a short injectable deadline in tests), prompt route yields the event before the handler and answers JSON / 204 / late 204, note URL token check, statistics; config: `mcpToken` added to an existing M3 config.json without changing port / token / mode, rotation persists, a corrupt file still handled as before; `MCPAuth` known-answer vectors; HookSettings JSON (prompt URL + timeout, permissions only when non-empty, everything else byte-identical to M3's output for the same input); MCPLaunchConfig JSON / 0600 file / atomicity; name resolver over fixture .claude.json (absent, codd ours, codd foreign, codd + codd-desktop taken) and .mcp.json, values never read except codd.url; LaunchBuilder argv: `--mcp-config` directly before `--settings` for new / resume / restart and with profile extras (including a profile that passes its own `--mcp-config`); SessionRetention table tests (every rule, boundaries at exactly N days, nil = never, pinned / running / external / keepUntil exempt, `countFrom` grace, `resumeWarning` off); `toolFilePaths` for each tool, relative paths, non-PostToolUse events → []; prompt answer JSON with and without `systemMessage`; `/n/` with a foreign Host → refused; `HookConfig(port:token:)` still compiles and `reassignPort` keeps `mcpToken`. D40: grep App/ for every changed CoddCore / CoddHooks type (`HookConfig`, `HookRoute`, `HookServerStatistics`, `ClaudeHookSettings`, `LaunchRequest`, `HookPayload`) and list the check in the report.

**Acceptance (run exactly):** for both packages `swift build --package-path Packages/<P> --scratch-path <repo>/.build-m4-hooks-<P> --build-tests 2>&1 | grep -E "warning:|error:"` → empty, and `swift test --package-path Packages/CoddCore --scratch-path …/.build-m4-hooks-CoddCore` and `swift test --package-path Packages/CoddHooks --scratch-path …/.build-m4-hooks-CoddHooks` → all pass. Report: API, test counts before / after, deviations, known issues.

### C4 `textkit` — new package `Packages/CoddTextKit` + composer chips in `Packages/CoddComposer`

You build CODD Desktop M4 component C4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D9, D10, D11, D14, D34, D36, §3.2, §3.3, §9), design/artboards-src/Notebook.src.html (the document column: `.nb-doc`, `.nb-title`, `.nb-meta`, `.nb-h2` with `.fold`, `.nb-p`, `.nb-ul` and the raw caret line `.nb-raw` / `.nb-mk` / `.nb-caret`, `.nb-figrow` / `.nb-shot` / `.ann-*` overlay, `.nb-tasks`, `.nb-code`), design/artboards-src/Split.src.html (`.sp-ref` chip in the composer), design/helmet.html (tokens, `code`, `.ann-box`, `.ann-pin`), design/research/native-swift/editor-mcp.md §1 (TextKit 1 techniques, IME rules), Packages/CoddComposer/Sources/CoddComposer/ComposerTextView.swift (the existing IME-safe text view: copy its rules), Packages/CoddUI public API (Palette, Typeface / TextStyle, Draw).

**Owned paths:** `Packages/CoddTextKit/**` (new) and `Packages/CoddComposer/**` (only the reference-chip addition; every existing CoddComposer test stays green). Do not edit CoddUI.

**Package:** swift-tools-version 6.2, macOS 26, Swift 6 mode; library `CoddTextKit` (AppKit, depends on `../CoddUI`), executable `codd-markdown-demo`, test target. Everything UI is `@MainActor`.

**Contract:**
```swift
public enum MarkdownEditorMode: Sendable { case livePreview, source }
public struct MarkdownCaret: Sendable, Equatable { public var line: Int; public var column: Int; public var selectionLength: Int }   // 1-based
public struct MarkdownPastedImage: Sendable { public var data: Data; public var typeIdentifier: String; public var suggestedName: String? }
public enum ImageOverlayShape: Sendable, Equatable { case rect(n: Int, CGRect, color: String?), point(n: Int, CGPoint, color: String?), arrow(n: Int, from: CGPoint, to: CGPoint, color: String?), text(n: Int, CGPoint, String, color: String?) }   // ORIGINAL image pixels
public struct MarkdownImageInfo { public var path: String; public var image: NSImage?; public var pixelSize: CGSize; public var caption: String; public var overlay: [ImageOverlayShape] }
public struct MarkdownEditorStyle { …fonts and colors defaulting to the Notebook artboard tokens via CoddUI…; public static var notebook: MarkdownEditorStyle }
@MainActor public final class MarkdownEditorView: NSView {
  public init(style: MarkdownEditorStyle = .notebook)
  public var mode: MarkdownEditorMode
  public private(set) var text: String                                    // committed text only
  public var isComposing: Bool { get }                                    // the text view has marked text
  public func load(_ text: String, selection: NSRange?)                   // new document, clears undo; waits while composing
  public func applyExternalText(_ text: String)                           // reload keeping selection / scroll; waits while composing
  public func replace(_ range: NSRange, with string: String, actionName: String)   // one undoable edit (annotation block rewrite)
  public func insertAtCaret(_ string: String)                             // undoable; at the end when no caret
  public func insertImageMarkdown(alt: String, path: String)              // D9 placement rules
  public var onTextChange: ((String) -> Void)?                            // never while composing
  public var onCaretChange: ((MarkdownCaret) -> Void)?
  public var onPasteImage: ((MarkdownPastedImage) -> Bool)?               // true = handled (the app saves and calls insertImageMarkdown)
  public var imageResolver: ((String) -> MarkdownImageInfo?)?             // relative path → image + overlay
  public var imageAccessoryProvider: ((MarkdownImageInfo) -> NSView?)?    // the annotation summary panel to the right of the figure
  public var titleAccessory: NSView?                                      // the chips row under the H1 title line
  public var onOpenLink: ((String) -> Void)?                              // click in preview / ⌘-click in source
  public var onEditImageAnnotations: ((String) -> Void)?                  // ⌘⇧A on an image line, double click on a figure
  public var onCommandReturn: (() -> Void)?                               // ⌘⏎ (send), only without marked text
  public var hiddenFenceInfoStrings: Set<String> = ["codd-annotations"]
  public var placeholderTitle: String = "標題"
  public func focus()
  public func setFontScale(_ scale: CGFloat)
  public var textViewForTesting: NSTextView { get }
}
public enum MarkdownBlockKind: Sendable, Equatable { case heading(level: Int), paragraph, bullet(indent: Int), ordered(indent: Int, number: Int), task(indent: Int, done: Bool), quote, codeFence(info: String), hiddenFence(info: String), image(alt: String, path: String), rule, table, blank, frontmatterLike }
public struct MarkdownBlock: Sendable, Equatable { public var kind: MarkdownBlockKind; public var range: NSRange /* UTF-16, whole lines */; public var inlineMarks: [NSRange] /* ranges hidden off-caret: **, *, `, #, link syntax */ }
public enum MarkdownBlockParser { public static func blocks(in text: String) -> [MarkdownBlock]; public static func reparse(_ blocks: [MarkdownBlock], text: String, edited: NSRange, delta: Int) -> [MarkdownBlock] }
public enum MarkdownRender { @MainActor public static func attributedPreview(_ markdown: String, style: MarkdownEditorStyle, maxLines: Int?) -> NSAttributedString }   // read-only cards (condense preview, drawer)
public enum MarkdownCodeHighlighter { public static func spans(code: String, language: String) -> [(NSRange, Token)] }  // small generic lexer for fenced code (keywords / strings / comments / numbers for js, ts, css, swift, python, shell, json, html); amber / cyan / dim per the artboard
```

**Live preview (D11) — implement with TextKit 1 only** (`NSTextView(usingTextLayoutManager: false)` or an explicit NSTextStorage / NSLayoutManager / NSTextContainer stack; assert `textLayoutManager == nil` in a test):
- Rendering per the Notebook artboard: document padding 22 / 40 / 0 / 44; H1 title 22 pt display font (CoddUI display face), cream, line-height 1.3; H2 16 pt display amber with a dashed `--line-bright` rule above and the `▾` fold glyph at −24 pt (click folds / unfolds the section: the folded lines are hidden like other hidden ranges; folding state is view-only); H3–H6 smaller display amber-dim; paragraphs 13 pt, line-height 1.75, bone; bold cream; italic; inline code in the helmet `code` look; links cyan (`codd://note/<id>` in the amber chip look); bullets drawn as 5 × 5 amber-dim squares (the `- ` hidden); ordered lists; tasks `[x]` / `[ ]` drawn as `[x]` with an amber bold x / `[ ]` in dim (click toggles = one undoable edit), done text dimmer with a line-bright strike; quotes with a 2 px amber-dim bar; dashed rule; tables as monospaced text with dim pipes; fenced code on #000 with a 1 px line-bright border, 12 pt / 1.6, the language label top-right (caps, 10 pt, dim, left / bottom border), highlighted with `MarkdownCodeHighlighter`; the caret paragraph shows its raw marks dimmed (`--dimmer`) with the `.nb-raw` gradient band and amber-dim inset bar; the insertion point is a 2 pt amber bar with glow.
- Hidden ranges = glyphs generated as `.null` (or zero-advance control glyphs) through `NSLayoutManagerDelegate.layoutManager(_:shouldGenerateGlyphs:properties:characterIndexes:font:forGlyphRange:)`; whole hidden lines (frontmatter-like blocks are not expected in bodies; `hiddenFence` blocks, folded sections) collapse to zero height via `layoutManager(_:shouldSetLineFragmentRect:lineFragmentUsedRect:baselineOffset:in:forGlyphRange:)`; the same delegate reserves vertical space for **block decorations**: the title accessory after line 1, image figures (the image line's paragraph is replaced visually by the figure: #000 plate, 7 pt padding, 1 px amber-dim border + 3 pt rgba(255,184,74,.08) ring, caption 11 pt dim below; display height ≤ 220 pt for tall screenshots, width ≤ content width − accessory width − 18; the accessory view to the right, top-aligned), overlay shapes scaled from original pixels (rect = amber 1.5 pt box with a numbered amber square pin at its top-left; point = pin; arrow = black 3.5 pt halo + amber 1.5 pt line + filled head; text = label on a black plate).
- Moving the caret into a hidden range's paragraph reveals it (source text visible, dimmed marks); a hidden `codd-annotations` block is revealed only in source mode. Source mode (⌘E is the app's menu item calling `mode`): nothing hidden, monospaced 12.5 pt, marks dimmed, no decorations.
- Restyling is incremental (only the edited paragraphs plus code-fence / list state propagation), applied in `textStorage(_:didProcessEditing:…)` / after `didChangeText`, **never while marked text exists** (queued and applied after `unmarkText` / commit). Use attribute changes inside `beginEditing` / `endEditing` without registering undo; heading font sizes only outside the marked range.
- Editing behaviours, all without intercepting `keyDown`: `insertNewline` continues lists / tasks / quotes (empty item ends the list), `insertTab` / `insertBacktab` indent list items, ⌘B / ⌘I wrap the selection (`**` / `*`), paste: an image (pasteboard image data or a file URL of an image) → `onPasteImage`; rich text → plain text. Smart quotes, smart dashes, text replacement, automatic spelling correction and data detection are off. ⌘⏎ → `onCommandReturn` via `performKeyEquivalent`, checked against marked text.
- Performance: a 1 MB note with 200 image lines (unresolved images) loads < 300 ms (debug) and a keystroke in its middle re-styles < 30 ms (debug; print p95); images decode lazily off the main actor through the resolver's NSImage (the view never reads files itself).

**Composer chips (CoddComposer):** `ComposerTextView` draws every `codd://note/[a-z0-9]+(-[a-z0-9]+)*` range as the Split artboard's `.sp-ref` chip (amber text, rgba(255,184,74,.08) fill, 1 px amber-dim border, drawn by a layout-manager background pass or temporary attributes plus a custom background drawing) without changing the text (the payload stays plain text) and never inside the marked range; the chip's document icon is optional (report if left out). Add `public var referenceChips: Bool = false` to `ComposerStyle` (App/Session/ComposerBarView.swift builds `ComposerStyle(…)` today: the new field needs its default, D40) or the view; I2b turns it on, so the App's composer is unchanged until then.

**Demo:** `codd-markdown-demo --fonts <dir> --snapshot <dir>` renders (offscreen, never activating) the SPEC §5 n1 document (title, chips placeholder accessory, H2s, list with the raw `**Safari 底部工具列展開時**` caret line, a generated 750 × 1334 placeholder image with the three R6 annotations and a dummy accessory, tasks, the css code block) at 760 × 820 and the same in source mode; without `--snapshot` it opens a window for a manual 注音 try (that window may activate: it is a manual tool only, never run by automation).

**Tests (Swift Testing):** TextKit 1 assertion; parser blocks for every kind and incremental reparse equals a full parse after random edits (property test with a fixed seed); hidden glyph ranges off-caret and revealed on-caret (inspect `layoutManager.propertyForGlyph` / glyph rects); hidden fence zero height; decoration heights for title accessory and an image (line fragment rects); overlay geometry (original pixels → view points for the SPEC example); **IME**: `setMarkedText("ㄓ", …)` then a restyle trigger and a timer → no attribute change in that paragraph, `onTextChange` not called, `applyExternalText` deferred until `unmarkText` / `insertText("注")`; ⌘⏎ with marked text ignored; list continuation on `insertNewline` (bullet, ordered increment, task, empty item ends), tab indent; task toggle undo / redo; ⌘B wrap; paste image callback and plain-text paste; `insertImageMarkdown` at the caret and at the end; `replace` undo groups; `applyExternalText` keeps the selection; `MarkdownRender` output attributes for headings / lists; `MarkdownCodeHighlighter` spans; composer chips: ranges found, text unchanged, none inside marked text, existing composer tests green; performance numbers printed.

**Acceptance (run exactly):** `swift build --package-path Packages/CoddTextKit --scratch-path <repo>/.build-m4-textkit --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddTextKit --scratch-path …/.build-m4-textkit` and `swift test --package-path Packages/CoddComposer --scratch-path …/.build-m4-textkit-composer` → all pass; `swift run --package-path Packages/CoddTextKit --scratch-path …/.build-m4-textkit codd-markdown-demo --fonts App/Fonts --snapshot <scratch dir>` writes the PNGs (look at them; compare with the Notebook artboard's document column and list differences). Write `Packages/CoddTextKit/README.md` (API, live-preview rules, IME rules, decorations). Report: API, numbers, snapshot paths, deviations, known issues (incl. what a manual 注音 run should check).

### C5 `code-editor` — new package `Packages/CoddCodeEditor`

You build CODD Desktop M4 component C5 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D11, D24, D27, D28, D36, §9), design/artboards-src/FileEditor.src.html (the code view: `.fe-code`, `.fe-lines`, `.fe-l` with `.n` / `.m` / `.c`, `.add`, `.del`, `.curl`, `.mod`, token classes `.k .s .cm .p .tg .at .dv .fn .pr .nu`, `.fe-hit`, `.fe-caret`, `.fe-hunk`, `.fe-ruler`, `.fe-find` and its parts), design/helmet.html, design/research/native-swift/editor-mcp.md §2, Packages/CoddComposer/Sources/CoddComposer/ComposerTextView.swift (IME rules to copy), CoddUI public API.

**Owned paths:** `Packages/CoddCodeEditor/**` only. Do not edit CoddUI.

**Package:** swift-tools-version 6.2, macOS 26, Swift 6 mode; library `CoddCodeEditor` (AppKit, depends on `../CoddUI`), executable `codd-code-demo`, test target.

**Contract:**
```swift
public enum CodeLanguage: String, Sendable, CaseIterable { case vue, javascript, typescript, jsx, tsx, json, css, scss, html, xml, markdown, swift, python, shell, yaml, toml, go, rust, c, cpp, objc, java, kotlin, ruby, php, sql, plain
  public var displayName: String }                                         // "Vue", "JavaScript", … (status bar)
public enum CodeLanguageDetector { public static func language(fileName: String, firstLine: String?) -> CodeLanguage }   // extension, special names (Makefile, Dockerfile, .zshrc), shebang
public enum SyntaxToken: Sendable { case keyword, string, comment, number, punctuation, tag, attribute, directive, function, property, plain }
public struct SyntaxHighlighter: Sendable { public init(language: CodeLanguage)
  public func tokens(line: String, startState: LexState) -> (tokens: [(NSRange, SyntaxToken)], endState: LexState) }   // per-line lexing with line-start states
public struct FindOptions: Sendable, Equatable { public var caseSensitive = false; public var wholeWord = false; public var regex = false }
public enum FindEngine { public static func matches(in text: String, query: String, options: FindOptions) throws -> [NSRange]
  public static func replacement(for match: NSRange, in text: String, query: String, template: String, options: FindOptions) throws -> String }   // $1 groups
public struct CodeCaret: Sendable, Equatable { public var line: Int; public var column: Int; public var selectionLength: Int }   // 1-based
public struct InlineDiffHeader: Sendable, Equatable { public var tagColor: NSColor; public var showAIChip: Bool; public var who: String /* "打卡頁 RWD 調整 · 10:36" */; public var range: String /* "@@ -40,2 +40,4 @@" */; public var removed: Int; public var added: Int; public var position: String /* "2 / 2" */ }
public struct InlineDiffHunk: Sendable, Equatable, Identifiable { public var id: Int; public var newLines: Range<Int> /* 0-based lines of the current text; empty = pure deletion before lowerBound */; public var deletedLines: [String]; public var header: InlineDiffHeader }
public enum HunkAction: Sendable { case revert, accept }
public struct OverviewMark: Sendable, Equatable { public enum Kind: Sendable { case hit, aiChange, added, removed, cursor }; public var kind: Kind; public var line: Int; public var lineCount: Int; public var color: NSColor? }
@MainActor public final class CodeEditorView: NSView {
  public init(style: CodeEditorStyle = .fileEditor)
  public func load(_ text: String, language: CodeLanguage, readOnly: Bool, plainMode: Bool)   // clears undo
  public private(set) var text: String
  public var isComposing: Bool { get }
  public func applyExternalText(_ text: String)                       // keeps caret / scroll; waits while composing
  public func replaceLines(_ lines: Range<Int>, with newLines: [String], actionName: String)   // one undoable edit (還原此段)
  public var onTextChange: ((String) -> Void)?                        // committed only
  public var onCaretChange: ((CodeCaret) -> Void)?
  public var language: CodeLanguage
  public var fontSize: CGFloat
  public var readOnly: Bool
  public func goTo(line: Int, column: Int)
  // find / replace (the artboard's widget, top-right of the code view)
  public func showFind(replace: Bool, query: String?)
  public func hideFind()
  public var onFindChange: ((query: String, options: FindOptions, current: Int, total: Int) -> Void)?
  // AI changes
  public func setInlineDiff(_ hunks: [InlineDiffHunk])
  public var onHunkAction: ((Int, HunkAction) -> Void)?
  public func scrollToHunk(_ id: Int)
  public var modifiedLineMarkers: [Int: NSColor]                      // `.mod` 3 pt bars in the marker column (AI-changed lines outside a shown hunk)
  public var overviewMarks: [OverviewMark]
  public var textViewForTesting: NSTextView { get }
}
public struct CodeEditorStyle { …the FileEditor artboard tokens…; public static var fileEditor: CodeEditorStyle }
```

**Behaviour:**
- TextKit 1 text view (assert `textLayoutManager == nil`), IME rules identical to D11 (no keyDown interception for editing keys; nothing restyled / replaced / reloaded while marked text exists; `onTextChange` committed only; smart substitutions off; ⌘F / ⌘G / ⇧⌘G / esc handled in `performKeyEquivalent` / `cancelOperation` only without marked text).
- Look per the artboard: #000 background, 12.5 pt mono, 20 pt lines, gutter = 46 pt right-aligned line numbers (`--dimmer`, cream on the caret line) + a 16 pt marker column (`+` green / `−` red / the `.mod` bar in the hunk's tag color), current-line band, added lines rgba(124,255,154,.075) with a 2 pt inset bar in the hunk color, removed lines rgba(255,112,88,.085) at opacity .72 without numbers, the caret line's `.curl` look, amber 2 pt caret with glow.
- Highlighting (D28): lexers for every `CodeLanguage` (Vue SFC: `<template>` as HTML with directives `v-if`, `:key`, `@punch` and `{{ }}` in amber-dim, `<script>` as JS / TS, `<style>` as CSS / SCSS), line-start states cached per line and recomputed from the first edited line until the end state matches; colors keyword amber, string cyan, comment dimmer italic, punctuation #8a8578, tag #e0896a, attribute / property bone, directive amber-dim, function cream, number #a6e9f2; applied as **temporary attributes** to the visible range + 200 lines; > 2 MiB text highlights only what scrolls into view; `plainMode` = no highlighting, no wrapping, read-only allowed.
- Find widget (`.fe-find`): replace toggle `▸`, a 232 × 24 query field with amber border and glow, option buttons `Aa` / underlined `ab` / `.*`, count `3/7`, `↑` `↓` `✕`; replace row (field + `取代` / `全部取代`) when toggled; hits = amber 16 % fill with a 1 px amber 50 % inset, the current one solid amber with black text; enter = next, ⇧enter = previous, esc = close; regex errors show the count as `—` and keep the field amber-dim; replace-all is one undo group. The query field is IME-safe (an NSTextField / field editor; no search while it has marked text).
- Inline diff (D27): each hunk = a block decoration above its first new line (or at the deletion point): the 26 pt hunk bar (`.fe-hunk`: tag square, `AI` chip when `showAIChip`, `who`, the range, `−n +m`, `position`, `[還原此段]` `[接受]` buttons → `onHunkAction`) followed by the deleted lines drawn as removed lines (not part of the text); added lines tinted. Decorations reserve height through the layout-manager delegate (`shouldSetLineFragmentRect`), overlay views are positioned at those rects and follow scrolling / edits; invalid hunks (lines out of range after an edit) are dropped until the app sends new ones.
- Overview ruler (`.fe-ruler`, 14 pt): viewport thumb, hit marks amber, AI changes in their color, added green, removed red, cursor cream; click scrolls.
- Undo: one `UndoManager` per view; `replaceLines` and replace-all are single groups.

**Demo:** `codd-code-demo --fonts <dir> --snapshot <dir>` renders (offscreen) the artboard's `punch.vue` lines 13–49 with the hunk `@@ -40,2 +40,4 @@` (2 removed, 4 added, pink tag), the `.mod` marker on line 33, the find widget with `sticky` · `3/7`, the caret on line 42, at 1100 × 760; plus a TypeScript, a JSON and a Python sample. Without `--snapshot` it opens a window (manual tool only).

**Tests:** TextKit 1; detector table; lexer token positions on a Vue SFC, JS with template strings and regex literals, CSS, JSON, Swift multi-line strings, Python triple quotes, shell heredoc-lite, Markdown; incremental re-lex equals full lex after random edits (fixed seed); FindEngine (case, whole word with CJK neighbours, regex groups, invalid regex), replace-all undo; IME (`setMarkedText` → no restyle / no onTextChange / applyExternalText deferred); `replaceLines` undo / redo; hunk decoration heights and overlay frames; buttons fire `onHunkAction`; gutter numbers skip deleted lines; plainMode; performance: a 1 MB JS file's first highlighted screen < 150 ms (debug), a keystroke < 16 ms (print numbers).

**Acceptance (run exactly):** `swift build --package-path Packages/CoddCodeEditor --scratch-path <repo>/.build-m4-code --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddCodeEditor --scratch-path …/.build-m4-code` → all pass; the demo snapshots written (compare with the FileEditor artboard, list differences). Write `Packages/CoddCodeEditor/README.md`. Report: API, numbers, snapshot paths, deviations, known issues.

### C6 `files` — new package `Packages/CoddFiles` (targets `CoddFiles` and `CoddFileEditorUI`)

You build CODD Desktop M4 component C6 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D24, D25, D26, D27, D34, §3.4 (recent.json, ai-touches.json), §9), design/artboards-src/FileEditor.src.html (tree `.fe-tree` / `.fe-head` / `.fe-node` / badges, tab strip `.fe-tab`, toolbar `.fe-bar`, the warn banner, the status bar), design/research/editor-storage.md §4 (background), Packages/CoddCore/Sources/CoddCore/Store/AtomicFile.swift and Packages/CoddCore/Sources/CoddCore/Process/ProcessCommandRunner.swift (styles to copy; do not depend on CoddCore), CoddUI public API.

**Owned paths:** `Packages/CoddFiles/**` only.

**Package:** swift-tools-version 6.2, macOS 26, Swift 6 mode; libraries `CoddFiles` (Foundation + CoreServices only, no AppKit) and `CoddFileEditorUI` (AppKit, depends on `CoddFiles` and `../CoddUI`), executable `codd-files-demo`, test targets for both.

**CoddFiles contract:**
```swift
public enum GitFileChange: String, Sendable { case modified, added, deleted, renamed, copied, untracked, conflicted, typeChanged }
public struct GitRepoStatus: Sendable, Equatable { public var root: URL; public var branch: String?; public var detached: Bool; public var upstream: String?; public var ahead: Int; public var behind: Int; public var changes: [String: GitFileChange] /* repo-relative */ }
public struct GitReader: Sendable {
  public init(gitPath: String = "/usr/bin/git", timeout: Duration = .seconds(5), log: @escaping @Sendable (String) -> Void)   // logs `exec git path=<abbrev> sub=<subcommand>`
  public func repoRoot(for folder: URL) async -> URL?
  public func status(root: URL) async throws -> GitRepoStatus          // status --porcelain=v2 --branch -z --untracked-files=all
  public func headText(root: URL, relativePath: String) async throws -> Data?   // cat-file blob HEAD:<path> (no textconv, no pager); nil when absent from HEAD
  public func ignored(root: URL) async throws -> Set<String>            // ls-files -o -i --exclude-standard --directory -z
  public func trackedAndUntracked(root: URL) async throws -> [String]   // ls-files -co --exclude-standard -z (⌘P)
}   // every run: `-C <root> --no-optional-locks -c core.fsmonitor=false`, env GIT_OPTIONAL_LOCKS=0, LC_ALL=C, GIT_TERMINAL_PROMPT=0, no stdin, killed at the timeout; never a writing subcommand
public protocol GitReading: Sendable { /* the four GitReader calls; GitReader conforms; mock mode (D35) and tests use a fake */ }
public struct FileTreeEntry: Sendable, Equatable, Identifiable { public var relativePath: String; public var name: String; public var isDirectory: Bool; public var isSymlink: Bool; public var isHidden: Bool; public var isIgnored: Bool; public var id: String }
public struct FileTreeModel: Sendable { public init(root: URL)
  public func children(of relativePath: String, ignored: Set<String>) throws -> [FileTreeEntry]   // names only, folders first, natural case-insensitive order, ≤ 2,000 entries (then a `…` marker entry)
  public func walk(limit: Int = 20_000, maxDepth: Int = 12, skipping: Set<String> = ["node_modules", ".git"]) -> [String] }   // ⌘P outside git
public enum TextEncodingKind: String, Sendable { case utf8, utf8BOM, utf16LE, utf16BE, big5, latin1 }
public enum LineEnding: String, Sendable { case lf, crlf, cr }
public enum Indentation: Sendable, Equatable { case spaces(Int), tabs, unknown }
public struct DecodedText: Sendable, Equatable { public var text: String /* LF-normalized */; public var encoding: TextEncodingKind; public var lineEnding: LineEnding /* majority */; public var mixedLineEndings: Bool; public var lineEndings: [LineEnding]? /* per line, only when mixed */; public var hasFinalNewline: Bool; public var indentation: Indentation; public var readOnly: Bool /* latin1 fallback, > 5 MiB */ }
public enum TextFileCodec {
  public static let binarySniffBytes = 8192, readOnlyBytes = 5 * 1024 * 1024, refuseBytes = 50 * 1024 * 1024
  public static func decode(_ data: Data) -> Result<DecodedText, TextFileError>   // .binary, .tooLarge(bytes)
  public static func encode(_ text: String, like original: DecodedText) throws -> Data   // EOL, BOM, encoding, final newline restored; mixed files: unchanged lines keep their own ending (mapped with LineDiff), new lines take the majority
}
public enum FileWatchEvent: Sendable, Equatable { case modified, deleted, renamed, attributes }
public final class FileWatch: Sendable { public init(url: URL); public var events: AsyncStream<FileWatchEvent> { get }; public func cancel() }   // DispatchSource per file; reopens after an atomic replace; coalesces 100 ms
public final class DirectoryWatcher: Sendable { public init(root: URL, latency: Double = 0.3); public var changes: AsyncStream<[String]> { get } /* relative paths */; public func cancel() }   // FSEvents
public struct FileFingerprint: Sendable, Equatable { size, mtime, inode, sha256 }
public enum FileSaver { public static func save(_ data: Data, to url: URL, expected: FileFingerprint?, force: Bool) throws -> FileFingerprint }   // atomic temp in the same folder + rename, mode / xattrs / ACL kept (copyfile metadata from the original onto the temp), symlink written through to its target, nlink > 1 written in place (truncate + write + F_FULLFSYNC), no write permission → .readOnly; throws .changedOnDisk when expected ≠ current and !force
public struct OpenFileState: Sendable, Equatable {   // the pure state machine of one open tab
  public static func load(_ url: URL) throws -> OpenFileState
  public var url: URL; public var decoded: DecodedText; public var savedText: String; public var savedAt: Date; public var disk: FileFingerprint
  public var buffer: String; public var isDirty: Bool { get }
  public var aiBaseline: (text: String, at: Date, session: String?)?
  public mutating func edit(_ text: String)
  public enum DiskDecision: Sendable, Equatable { case none, reloaded, banner(aiSession: String?, at: Date) }
  public mutating func diskChanged(newData: Data, fingerprint: FileFingerprint, aiTouch: (session: String, at: Date)?) -> DiskDecision   // clean → reload; dirty → banner; keeps the pre-change text as aiBaseline when attributed
  public mutating func keepMine(); public mutating func reloadFromDisk(); public mutating func saved(_ fingerprint: FileFingerprint, at: Date)
}
public struct DiffHunk: Sendable, Equatable { public var oldRange: Range<Int>; public var newRange: Range<Int>; public var oldLines: [String]; public var newLines: [String] }
public enum LineDiff { public static func hunks(old: [String], new: [String], context: Int = 0) -> [DiffHunk]   // Myers O(ND), stable
  public static func reverting(_ hunk: DiffHunk, in new: [String]) -> [String]
  public static func unifiedHeader(_ hunk: DiffHunk) -> String }   // "@@ -40,2 +40,4 @@"
public struct RecentFile: Sendable, Equatable, Codable { path, root, openedAt, source }
public final class RecentFilesStore: Sendable { public init(file: URL /* <dataRoot>/files/recent.json */); public func load() -> [RecentFile]; public func record(_ path: URL, root: URL, source: String, at: Date); public func remove(_ path: URL) }   // ≤ 20, 30-day expiry, atomic 0600, tolerant
public struct AITouch: Sendable, Equatable, Codable { path, session, tool, at }
public final class AITouchLog: Sendable { public init(file: URL /* <dataRoot>/files/ai-touches.json */, clock: @escaping @Sendable () -> Date); public func record(_ touches: [AITouch]); public func touches(under root: URL?, since: Date) -> [AITouch]; public func latest(for path: String) -> AITouch? }   // 7 days, ≤ 2,000, debounced atomic save
```

**CoddFileEditorUI contract** (value models + closures, no CoddCore / App types; the code view is an `NSView` slot):
- `FileTreeView` (264 pt; `.fe-head`: `FILES · <project>`, line 2 `⎇ <branch>` `↑2` `· M 3 · AI 2` + icon buttons 新增檔案 (disabled, tooltip `新增檔案（之後提供）`) / 全部收合; filter field `/ 篩選檔案… ⌘P` (IME-safe); `RECENT n` section; `PROJECT` tree with `.fe-node` rows (ext label, name, dir hint in Recent, badges `M` amber / `AI` chip in a given color, folder dot when it contains changes, ignored rows dimmer, the current file `.cur`); foot `LOCAL <path>` and `● <tag> <session title> · AI 改 2 · 10:41`). Model `FileTreeModelView { … }`, callbacks `onOpen(path, preview: Bool)`, `onToggle(path)`, `onFilter(text)`, `onCollapseAll`.
- `EditorTabStripView` (`.tabs` with `.fe-tab`: ext label or note icon, name, dirty `●` / `✕`, preview tabs italic dim; `.tfill` with the session pill `● <tag> <title> <tool · 6m> ⌘9`, a disabled split-editor icon (tooltip `分割編輯器（之後提供）`) and `⋯`). Callbacks select / close / openSession / more.
- `EditorToolbarView` (`.fe-bar`: breadcrumb `src › pages › punch.vue › <style> › .punch-sticky` (the app passes the parts), `AI 變更 n 段` + ↑ ↓, `SHOW AI CHANGES` switch, baseline select (`基準：git HEAD` / `基準：上次儲存 10:39` / `基準：AI 開始前 10:30`), `⌘F` button).
- `DiskChangeBannerView` (`.banner.warn`: the `!` box, `磁碟上的檔案已被 AI 變更（<session> · HH:mm）` or `磁碟上的檔案已變更`, `· 你有未儲存的修改`, `[重新載入] [保留我的] [比較]` (比較 accent)); the title text comes from the model, so the notes editor reuses it with `磁碟上的筆記已變更` (D7).
- `EditorStatusItemsView` (the artboard status bar's middle and right items: `⎇ feat/punch-rwd ↑2`, `<tag> <session> 正在編輯此專案`, `Ln 42, Col 18 · UTF-8 · LF · Vue · 2 spaces · ● 已儲存 10:39` as clickable texts) — the app embeds it in its status bar.
- `DirtyCloseSheetView` (`儲存「<name>」的變更？`, hint `不儲存的話，這次的修改會遺失。`, `[儲存]` primary, `[不儲存]` danger, `[取消]`).

**Tests:** GitReader against temp repos created in the test (`git init`, commits with `-c user.name=t -c user.email=t@localhost -c commit.gpgsign=false`, a local bare upstream for ahead / behind, a rename, untracked, a conflict-free merge state) incl. porcelain v2 `-z` parsing with spaces / CJK / newlines in names, `headText` of a renamed file, ignored dirs collapsed, and **`.git/index` mtime unchanged after every reader call** (read-only proof); codec (UTF-8, BOM, UTF-16 LE/BE BOM, Big5 bytes for `發票匯出`, invalid UTF-8 non-Big5 → latin1 read-only, NUL → binary, CRLF / CR / mixed, no final newline, unchanged round trip byte-identical, a mixed-EOL file with one edited line changes only that line's bytes); FileWatch (in-place write, atomic replace via rename, delete, recreate); DirectoryWatcher (create / modify / delete under nested folders); FileSaver (atomic, mode 0644 / 0600 kept, an xattr kept, symlink target written, a hard-linked file keeps its link, read-only refused, `changedOnDisk`); every test repo with `GIT_CONFIG_GLOBAL=<empty temp file>` and `GIT_CONFIG_NOSYSTEM=1` (the user's own git config never applies; no fsmonitor daemon is left running); OpenFileState transitions (clean reload, dirty banner with and without an AI touch, keepMine, saved); LineDiff (classic Myers cases, empty sides, reverting each hunk of a multi-hunk diff restores the old lines there only); stores (caps, expiry, corrupt file moved aside); UI views: models render, callbacks fire, IME-safe filter (marked text → no callback). Performance: status of a repo with 5,000 files < 300 ms (print).

**Demo:** `codd-files-demo --fonts <dir> --snapshot <dir>` renders the FileEditor artboard composition (rail placeholder 72, tree 264 with the artboard's rows, tab strip, toolbar, banner, a placeholder rectangle for the code view, the status bar items) at 1440 × 900, offscreen.

**Acceptance (run exactly):** `swift build --package-path Packages/CoddFiles --scratch-path <repo>/.build-m4-files --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddFiles --scratch-path …/.build-m4-files` → all pass; demo PNG written and compared by eye. Write `Packages/CoddFiles/README.md` (read-only git rules, codec, save rules, stores). Report: API, numbers, deviations, known issues.

### C7 `notebook-ui` — new package `Packages/CoddNotebookUI`

You build CODD Desktop M4 component C7 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D8, D12–D15, D20, D29, D34, D39, §3.6, §9), the frozen artboards design/artboards-src/Notebook.src.html (everything except the document text itself, which C4 renders), Split.src.html (the `.sp-pad` drawer), QuickSwitch.src.html (only to keep chip looks consistent), design/helmet.html, design/SPEC.md §5 / §7.2 / §7.8, Packages/CoddStatusUI (an example of a value-model UI package built on CoddUI: StatusModels.swift, StatusSamples.swift, the demo), CoddUI public API (CoddButton styles incl. pill, ChipView, InputField, SelectButton, CheckboxButton, ToastView, CardView, DiffLinesView, SVGPath).

**Owned paths:** `Packages/CoddNotebookUI/**` only. Do not edit CoddUI (missing primitives are written `internal` here and listed in your report).

**Package:** swift-tools-version 6.2, macOS 26, Swift 6 mode; library `CoddNotebookUI` (AppKit, depends on `../CoddUI` only), executable `codd-notebook-demo`, test target. Everything `@MainActor`; models are plain `Equatable` values with already formatted strings (the app formats times like `10:05`, `已送出 10:02`, `37m 前`); actions are closures; views update in place from a new model (`update(_:)`) and keep their own transient state (open menus, field text being edited).

**Views and models (artboard parts; exact copy from the artboards; icons via `SVGPath.parse` with the artboard paths):**
- `NotebookListsView` (220 pt, `.nb-lists`): head `NOTEBOOK` + `[+ ⌘⇧N]` (sm accent); search field `/ 搜尋筆記、#標籤… ⌘F` (IME-safe: no `onSearch` while marked text; debounce is the app's); smart lists INBOX / PINNED / PROMPTS / STALE (count in amber-dim) / ARCHIVE / TRASH (two-line with hint `30 天後永久刪除`) with icons and counts, the selected one `.on`; `▸ BY PROJECT` section (collapsible) rows `■ name n` (tag color square); `▸ LOCAL FILES 最近 n` rows (file icon, name, dim root hint) + `[開啟資料夾…]`; footer `清理建議 [n] →` (hidden when nil), the notes path (dim, middle-truncated), `● MCP codd · n clients` (lamp green / dim). Model `NotebookListsModel`, callbacks `onNew`, `onSearch(String)`, `onSelect(ListID)`, `onToggleSection`, `onOpenFile(String)`, `onOpenFolder`, `onOpenCleanup`.
- `NoteListView` (300 pt, `.nb-notes`): head (`INBOX` h-sub + count + `最近更新 ▾` sort menu: 最近更新 / 建立時間 / 標題); day separators (`TODAY · 10/15`, `YESTERDAY`, …, given by the model); rows `.nb-nrow` (title, time, 2-line snippet, chips: kind `NOTE` / `PROMPT` (amber) / `SCRATCH` (dashed) / `PROMPT · 草稿` (amber dashed), linked session chip with its state lamp color or a project chip with its tag square, extra text like `7d 後封存`, the AI glyph eye `READ` / lock `OFF` / plus `APPEND` at the right; pinned star before the title; stale rows dimmed; `ID 重複` / `frontmatter` warning chips); end comment (`// INBOX 6 則 · 已全部顯示`); search mode with highlighted snippet ranges; empty states. Selection, double click, context menu items given by the model (`釘選` / `封存` / `移到垃圾桶` / `還原` / …).
- `NoteEditorChromeView`: top bar (52 pt, `.nb-top`): crumb `INBOX / <title>`; props row: AI pill (`AI 可讀 READ ▾` cyan, `AI 可附加 APPEND ▾` cyan, `AI 關閉 OFF ▾` dim) opening a menu with the three options and their hints (D34), scope pill (`Project: <name> ▾` / `Global ▾`) with a menu of Global + projects, `id <id>`; actions: the COPY REF split button `[ ⧉ COPY REF | ▾ ]` (left copies form 1, right opens the `.nb-refmenu` menu: header `COPY REFERENCE · 複製引用` + id, five two-line items with icons, the first `.hl` with the `推薦` chip and `⌘⇧C`, a separator before the URL item), `SEND TO SESSION ▾` (a menu of live sessions with lamps; each opens 插入引用 / 插入全文 / 送出全文), `⋯` (釘選 / 取消釘選, 類型 ▸, 封存, 移到垃圾桶, 在 Finder 顯示, 原始碼 ⌘E, 複製 ID). Body: a `documentView: NSView` slot (C4's editor) + the info panel; under it the doc status bar and the prompt footer. Menus are custom popover content views (`NotebookMenuView`) hosted by a borderless, non-activating `PopoverPanel` helper the app shows as a child window (never activate the app, never `orderFrontRegardless`); keyboard ↑↓⏎esc inside.
- `NoteChipsRowView` (the `.nb-meta` row under the title, used as C4's `titleAccessory`): kind chip, `#tag` chips (+ an add-tag inline field, IME-safe, Enter only without marked text), linked session chip (lamp + title), project chip (tag square + name), `updated HH:mm`.
- `ImageAnnotationSummaryView` (`.nb-annp`, C4's image accessory): `標註 n · ⌘⇧A [編輯標註]`, the ordered list with number squares, note text and the `xy` line (`rect · x 20 y 1150 · 710×120`), hint `AI 會收到標註後的圖與座標清單`.
- `NoteInfoPanelView` (240 pt): LINKS n (session rows with lamp + `session`, project rows with tag square + `project`, `+ 連結 session / 專案`), AI ACTIVITY `codd MCP` (rows eye 讀取 / plus 附加 with session and time, `—` when none; hint `AI 讀取不計入活動時間`), HISTORY `n 版` (timeline dots: current `.on`, selected `.sel`; `你 · 目前`, `建立`; `[比較]`), ASSETS `n 張 · 1.4 MB` (thumbnails from NSImages the app passes; click), RETENTION (dl rows `最後活動` / `標示 stale` / `自動封存` (ok color for 豁免) and `[釘選以保留]` / `[取消釘選]`).
- `NoteDocStatusView` (22 pt `.nb-docstat`: `LIVE PREVIEW · ⌘E 原始碼` or `SOURCE · ⌘E 即時預覽`, `Ln 14, Col 38 · Markdown · ● 已儲存 10:05` / `● 未儲存` amber / `◌ 儲存中…`).
- `PromptFooterView` (`.nb-send`: `送到` + target pill (lamp + title ▾, menu of live sessions) + dim `project · state duration` + `[插入引用] [插入全文] [送出 ⌘⏎]` (primary); disabled states with tooltips when there is no target).
- `NotesDrawerView` (Split artboard `.sp-pad`, 300 pt): head `SESSION PAD · 筆記` + `✕`; `LINKED NOTES n`; cards (kind chip, title link, AI glyph, up to 2 thumbnails each with its small caption (`直向` / `橫向` in the artboard) + caption `<caption> · n 張 · 1.4 MB`, up to 3 tasks, `#tags · <done>/<total> · 更新 10:05 · AI 讀取 10:12` (the task progress only when the card shows no image, as `打卡頁 QA 清單` does), `[插入引用] [送出全文]`; the referenced one `.ref` amber border); `+ 新筆記（連結此 session）`; an optional section `AI 改過的檔案 · n` `vs HEAD` with rows (name, `M`, `AI 10:41` chip, dir, `[差異]`) — model-driven, hidden when nil; footer path + `⌘⇧N 快速筆記`; empty state `// 還沒有連結這個 session 的筆記`.
- `HistoryCompareView` (sheet content: `HISTORY · 比較版本`, two version selects, CoddUI `DiffLinesView` with lines the app passes, `[還原這一版]`, `[關閉]`).
- `LinkPickerView` (searchable list of sessions (lamp, title, project dim) and projects (tag square, name), IME-safe search) and `TagEditorView`.

**Samples + demo:** `NotebookSamples` with the SPEC §5 data (INBOX 6 · PINNED 2 · PROMPTS 3 · STALE 4 · ARCHIVE 34 · TRASH 3; BY PROJECT; LOCAL FILES 4; n1–n6 rows; info panel of n1; the drawer of s9). `codd-notebook-demo --fonts <dir> --snapshot <dir>` renders offscreen: the Notebook composition at 1440 × 900 (rail placeholder 72 + lists + list + chrome with an empty document slot filled by a dim placeholder + info panel + footer, COPY REF menu open), the drawer at 300 × 900 (with and without the files section), the history sheet.

**Tests:** each view renders its sample without layout ambiguity at its artboard width (frames of key subviews, e.g. list widths 220 / 300 / 240, row heights), texts from the models appear (search the view tree for labels), callbacks fire for every button / menu item, the COPY REF menu lists the five forms in order with their hints, AI / scope / kind menus, keyboard navigation in the popover menus, search and tag fields do not call back while marked text exists (`setMarkedText` on their field editor), the COPY REF URL item disabled with its hint for an OFF note and every action disabled for an unsaved note (D15), drawer with and without the files section, empty states. No test orders a window front.

**Acceptance (run exactly):** `swift build --package-path Packages/CoddNotebookUI --scratch-path <repo>/.build-m4-notebook --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddNotebookUI --scratch-path …/.build-m4-notebook` → all pass; `swift run … codd-notebook-demo --fonts App/Fonts --snapshot <scratch dir>` and compare each PNG with the artboards by eye (list visible differences). Write `Packages/CoddNotebookUI/README.md`. Report: API, snapshot paths, deviations, internal primitives that could move to CoddUI, known issues.

### C12 `cleanup-ui` — new package `Packages/CoddCleanupUI`

You build CODD Desktop M4 component C12 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D29–D32, D34, D38, D39, §3.4 (candidate rules), §9), the frozen artboard design/artboards-src/Cleanup.src.html (the whole page), design/helmet.html, design/SPEC.md §5 (retention defaults, `Cleanup candidates: NOTES 8 · SESSIONS 5 · FILES 2`) and §7.10, Packages/CoddStatusUI (an example value-model UI package: StatusModels.swift, StatusSamples.swift, its demo) and the CoddUI public API (CoddButton, ChipView, CheckboxButton, SelectButton, CardView, ToastView, SVGPath).

**Owned paths:** `Packages/CoddCleanupUI/**` only. Do not edit CoddUI (missing primitives are `internal` here and listed in your report).

**Package:** swift-tools-version 6.2, macOS 26, Swift 6 mode; library `CoddCleanupUI` (AppKit, depends on `../CoddUI` only), executable `codd-cleanup-demo`, test target. Everything `@MainActor`; models are plain `Equatable` values with already formatted strings (the app formats `stale 21d`, `最後開啟 9/24`, `每週一 09:00 · 15 項 · 上次 10/08`); actions are closures; the view updates in place from a new model and keeps its own transient state (selection, the open select menu, scroll). No CoddCore / CoddNotes / App types.

**Contract (names are the contract; you may add, report any change):**
```swift
public enum CleanupTab: String, Sendable, CaseIterable { case notes, sessions, files }
public struct CleanupChip: Equatable { public var text: String; public var tone: Tone? /* kind chips NOTE / PROMPT / SCRATCH / PROMPT · 草稿, project name with tag color */; public var tagColor: NSColor?; public var dashed: Bool }
public enum CleanupAIHint: Equatable { case none, keep(String) /* "AI 2d 前讀取 → 建議保留" eye cyan */, condense(String) /* "✻ 適合濃縮" / "✻ 適合濃縮舊段落" */, read(String) /* "AI 9d 前讀取" */ }
public struct CleanupRow: Equatable, Identifiable { public var id: String; public var title: String; public var chips: [CleanupChip]; public var why: String; public var sub: String; public var badge: String /* stale 21d | archives in 0d | dup 82% | 9 段 > 30d | resume expires 4d | deletes in 4d | unused 12d */; public var badgeTone: Tone; public var aiHint: CleanupAIHint; public var actions: [String] /* ["保留 30 天", "封存"] or ["保留 30 天", "移到垃圾桶"] */ }
public enum CondenseState: Equatable, Sendable { case idle, running(elapsed: String), preview, failed(String) }
public struct CondenseSource: Equatable { public var title: String; public var kind: String }
public struct CondenseAccountOption: Equatable, Identifiable { public var id: String; public var title: String; public var enabled: Bool }
public struct CondenseModel: Equatable { public var title: String /* 濃縮 5 則 → 1 則摘要 */; public var sources: [CondenseSource]; public var accountTitle: String /* #1 個人 · sonnet-5.5 */; public var accounts: [CondenseAccountOption]; public var models: [String]; public var accountHint: String; public var previewRef: String /* codd://note/cleanup-1015-q8m3 */; public var preview: NSAttributedString?; public var state: CondenseState; public var disabledReason: String? /* 測試資料根目錄只用 -codd-claude-path */ }
public struct CleanupPolicyStep: Equatable { public var name: String; public var sub: String }
public struct CleanupPolicyRule: Equatable { public var term: String; public var text: String }
public struct CleanupPolicyModel: Equatable { public var lifecycle: [CleanupPolicyStep]; public var rules: [CleanupPolicyRule] }
public struct CleanupPageModel: Equatable { public var meta: String; public var counts: [CleanupTab: Int]; public var tab: CleanupTab; public var rows: [CleanupRow]; public var selected: Set<String>; public var condense: CondenseModel?; public var policy: CleanupPolicyModel; public var bulkDisabled: [CleanupTab: Set<String>] /* e.g. sessions: ["移到垃圾桶", "交給 Claude 濃縮…"] */ }
@MainActor public final class CleanupPageView: NSView {
  public init(model: CleanupPageModel); public func update(_ model: CleanupPageModel)
  public var onBack, onOpenSettings, onGenerate, onCancelRun, onApply, onRegenerate, onDiscard: (() -> Void)?
  public var onTab: ((CleanupTab) -> Void)?; public var onSelection: ((Set<String>) -> Void)?; public var onRowAction: ((String, String) -> Void)? /* row id, action title */
  public var onBulk: ((String, Set<String>) -> Void)? /* 封存 | 移到垃圾桶 | 交給 Claude 濃縮… */; public var onCondenseAccount: ((String) -> Void)?; public var onCondenseModel: ((String) -> Void)?
}
public enum CleanupSamples { public static var artboard: CleanupPageModel }   // the Cleanup artboard: 8 NOTES rows, 5 selected, the condense card in preview, the policy card
```

**Behaviour (exact artboard copy):** crumb `← NOTEBOOK / CLEANUP` + `esc 返回筆記本`; `.h-page` `CLEANUP · 清理建議` + the meta rule; tabs `NOTES 8` / `SESSIONS 5` / `FILES 2` + key hints `space 勾選 ⌘A 全選 ⌫ 封存`; table header `ITEM 項目 · WHY 原因 · STATUS · AI` with `已選 n / m`; rows (checkbox, title + chips, why + dim sub, status chip, AI hint, row actions); the sticky bulk bar (`已選 n` fill chip, `[封存]`, `[移到垃圾桶]` danger, `[✻ 交給 Claude 濃縮…]` accent, hint `封存可隨時還原 · 垃圾桶 30 天後清除`, `✕` clears the selection; actions in `bulkDisabled` drawn disabled); the CONDENSE card (`.card.hot`: `✻ CONDENSE · PREVIEW`, title, source list, `帳號 / 模型 · Account` select showing `accountTitle` and opening a two-section menu 帳號 / 模型 (an `NSMenu` popped up from the select is fine; never activate the app), the account hint line, `摘要預覽` + `previewRef`, the preview box drawing `preview` with a bottom fade mask, the cyan note `◇ 原稿會移到封存（不刪除），摘要連回原稿`, states: idle `[✻ 產生摘要]` + hint `claude -p · 掛載 codd MCP` (disabled with `disabledReason` when set), running `◌ 產生中… 12s` + `[取消]`, preview `[建立摘要並封存原稿] [重新產生] [捨棄]`, failed `[ERROR] <text>` + `[重新產生]`); the POLICY card (`POLICY · 保留規則` + `[調整規則 → 設定]`, the lifecycle boxes and the rules list from the model). Keyboard while the page has focus and no field has marked text: space toggles the focused row, ⌘A selects all of the tab, ⌫ = 封存 of the selection, esc = `onBack`.

**Demo:** `codd-cleanup-demo --fonts <dir> --snapshot <dir>` renders offscreen (never activating) the artboard composition at 1368 × 900 (the window minus the rail) and the SESSIONS and FILES tabs with made-up rows in the D30 / D31 voice (`停止 5 天` / `最後畫面保留到 11/12` / `stale 5d`; `終端機紀錄 · 8.0 MB` / `封存 26 天` / `deletes in 4d`; `未使用的圖片 · 2b7e04.png` / `unused 12d`).

**Tests:** artboard widths and row heights, every text of the sample present, tab switching, selection (click, space, ⌘A) and `已選 n / m`, bulk bar visibility and per-tab disabled actions, every callback, condense card transitions (idle → running → preview → apply / discard; failed), `disabledReason`, keyboard ignored while a field editor has marked text, no window ordered front.

**Acceptance (run exactly):** `swift build --package-path Packages/CoddCleanupUI --scratch-path <repo>/.build-m4-cleanup --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddCleanupUI --scratch-path …/.build-m4-cleanup` → all pass; the demo PNGs compared with the Cleanup artboard by eye (list differences). Write `Packages/CoddCleanupUI/README.md`. Report: API, snapshot paths, deviations, primitives that could move to CoddUI, known issues.

### C8 `annotate-ui` — new package `Packages/CoddAnnotateUI`

You build CODD Desktop M4 component C8 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D10, D34, §3.3, §3.7, §9), the frozen artboard design/artboards-src/ImageAnnotate.src.html (every part: `.sh` top bar, `.ia-tools`, `.ia-stage`, `.ia-frame`, `.ann-*` overlay, `.ia-hdl`, `.ia-tip`, `.ia-o` origin labels, `.ia-cap`, `.ia-panel` with the expanded / collapsed items, the send options, the AI preview term box, the Markdown disclosure, the status bar text), design/SPEC.md §8 R6, design/helmet.html, CoddUI public API (CoddButton, ChipView, InputField, TextAreaField, CheckboxButton, SegmentedSwitch, SVGPath).

**Owned paths:** `Packages/CoddAnnotateUI/**` only. Do not edit CoddUI.

**Package:** swift-tools-version 6.2, macOS 26, Swift 6 mode; library `CoddAnnotateUI` (AppKit, depends on `../CoddUI`), executable `codd-annotate-demo`, test target. `@MainActor` views; no CoddNotes types (the app maps its `ImageAnnotations` to these drafts).

**Contract:**
```swift
public enum AnnotationKind: String, Sendable, CaseIterable { case rect, point, arrow, text }
public enum AnnotationColor: String, Sendable, CaseIterable { case amber, cyan, danger, success, cream }
public struct AnnotationDraft: Sendable, Equatable, Identifiable { public var n: Int; public var kind: AnnotationKind; public var x, y: Int; public var w, h, x2, y2: Int?; public var note: String; public var color: AnnotationColor; public var id: Int { n } }
public struct AnnotationSendOptions: Sendable, Equatable { public var original = false; public var annotated = true; public var list = true }
public struct AnnotationDocument: Sendable, Equatable { public var pixelSize: CGSize; public var items: [AnnotationDraft]; public var send: AnnotationSendOptions }
public struct ImageAnnotateHeader: Sendable, Equatable { public var crumbs: [String] /* ["INBOX", "打卡頁 RWD 跑版紀錄"] */; public var fileName: String; public var meta: [String] /* ["assets/rwd-punch-k7x2/9f3a1c.png", "750×1334 px", "iPhone SE @2x", "截圖 2026-10-15 09:32"] */; public var originalFileName: String }
public enum AnnotateTool: Sendable { case select, rect, point, arrow, text }
public enum AnnotateZoom: Sendable, Equatable { case fit, actual, double }   // Fit / 100% / 200%
@MainActor public final class ImageAnnotateView: NSView {
  public init(image: CGImage, document: AnnotationDocument, header: ImageAnnotateHeader)
  public private(set) var document: AnnotationDocument
  public var tool: AnnotateTool; public var zoom: AnnotateZoom; public var selection: Int?
  public var previewText: ((AnnotationDocument) -> String)?      // "AI 會收到" (the app passes CoddNotes' §3.7 formatter)
  public var markdownSource: ((AnnotationDocument) -> String)?   // the codd-annotations block text
  public var onChange: ((AnnotationDocument) -> Void)?
  public var onDone: ((AnnotationDocument) -> Void)?
  public var onCancel: (() -> Void)?
  public var statusText: String { get }                           // "標註模式 · 3 個標註" (the app adds "· ● 已儲存 10:46")
  public override var undoManager: UndoManager? { get }           // its own
}
```

**Behaviour (artboard):**
- Top bar: crumb `INBOX / <note> /` + the file name as `.ttl` + chip `標註模式 ⌘⇧A`; meta line joined with ` · `; undo / redo icon buttons (⌘Z / ⌘⇧Z), `[取消]`, `[完成]` (primary).
- Tool strip (48 pt): select V, rect R, point P, arrow A, text T (icon buttons with key letters, `.on` = selected), separator, color button (opens a small menu of the five colors), zoom `Fit / 100% / 200%` vertical segmented. Tool keys work only while the canvas is first responder (never while a text field is editing).
- Canvas: grid background, the image in a `.ia-frame` (#000 plate, 8 pt padding, line-bright border, shadow), hint line top-left `拖曳控制點調整大小 · ⇧ 鎖定比例 · Del 刪除 · ⎋ 結束標註`, origin labels `0,0` and `<w>,<h>`, caption `原圖 750×1334 · 顯示 50% · 座標以原圖像素、左上為原點` (the actual percentage). Fit = the largest scale that fits the stage with 40 pt margins (≤ 100 %); 100 % = one image pixel per point; 200 %; larger than the stage scrolls.
- Drawing: rect by drag (⇧ = square), point by click, arrow by drag (⇧ = 45° steps), text by click then an inline field (IME-safe; commit on Enter only without marked text, esc cancels); every coordinate converted to integer ORIGINAL pixels, clamped to the image. Select tool: click selects (topmost), drag moves, the 4 rect corner handles (9 pt black squares with amber border and glow) resize, arrow endpoints move; the coordinate tooltip under a selected rect `x 20 · y 1150 · 710×120 px`; Del / ⌫ deletes; ⎋ deselects, else = 完成. New items get `n = count + 1`; deleting renumbers the rest sequentially (`依建立順序編號`). Overlay drawing exactly like the Notebook preview: amber boxes, numbered amber squares (black number), arrows with a black halo and a filled head, text labels.
- Right panel (380 pt): `ANNOTATIONS n` + hint `依建立順序編號`; the selected item expanded (`.ia-ex`: chip `RECT` amber + `框選` / `點` / `箭頭` / `文字`, `已選取`, collapse `▾`; X / Y / W / H fields (arrow: X1 / Y1 / X2 / Y2; point: X / Y) committing on Enter or blur, invalid input restored; `說明 · Comment` text area (IME-safe; commits on blur and on `完成`, never with marked text); hint `單位 px（原圖）· Del`; `[刪除]` danger); other items collapsed rows (number, type chip, note, xy text) selecting on click; `送給 AI 時` with three checkboxes (`附上原圖` + file name hint, `附上標註後的圖（燒進框線與編號）`, `附上座標清單`); `AI 會收到` + hint `notes_read · 送到 session` + the term box with `previewText(document)` (monospace, amber numbers / cyan types when the text follows §3.7: style by simple pattern); `▸ Markdown 原始碼（codd-annotations 區塊）` disclosure showing `markdownSource(document)`.
- Undo: every create / move / resize / delete / field edit / send-option change is one undo step on the view's own manager; `onChange` after each.

**Demo:** `codd-annotate-demo --fonts <dir> --snapshot <dir>` draws a made-up 750 × 1334 placeholder (CoreGraphics: white status bar, a header `打卡`, a large `09:32`, two cards, a blue `上班打卡` button, a bottom nav) with the three R6 annotations (item 1 selected) and renders the screen at 1368 × 876 (the window minus the rail and the status bar) offscreen; a second PNG at 200 %.

**Tests:** coordinate mapping at Fit / 100 % / 200 % (a drag from view point A to B produces the expected original-pixel rect for the 750 × 1334 sample at 50 %), point / arrow / text creation, ⇧ locks, clamping, select / move / resize via handles, delete + renumbering, field edits (valid / invalid), comment IME (`setMarkedText` in the text area → document unchanged until commit), tool keys ignored while a field edits, undo / redo of each operation, send options, `onDone` / `onCancel`, ⎋ behaviour, `statusText`. Events are synthesized on the views (no window ordered front).

**Acceptance (run exactly):** `swift build --package-path Packages/CoddAnnotateUI --scratch-path <repo>/.build-m4-annotate --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddAnnotateUI --scratch-path …/.build-m4-annotate` → all pass; the demo PNGs compared by eye with the artboard (list differences). Write `Packages/CoddAnnotateUI/README.md`. Report: API, snapshots, deviations, known issues.

### C9 `settings-status-ui` — `Packages/CoddSettingsUI`, `Packages/CoddStatusUI`, `Packages/CoddPreferences`

You build CODD Desktop M4 component C9 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D16, D21, D22, D23, D29, D30, D31, D32, D33, D34, §9), design/artboards-src/Settings.src.html (sections 08 筆記本 & MCP, 09 清理, 12 進階) and Status.src.html (the MCP nav item and the MCP SERVER card), docs/M3-REPORT.md §5 (Settings / STATUS notes, D17 milestone rows), the three packages' sources and READMEs (Packages/CoddSettingsUI/Sources/CoddSettingsUI/Views/Sections/{NotebookSectionView,CleanupSectionView,RemoteAdvancedAboutSections}.swift, Model/{SettingsInfo,SettingsActions,SettingsModel,SettingsSamples}.swift; Packages/CoddStatusUI/Sources/CoddStatusUI/{StatusModels,StatusSamples,StatusPageView,StatusSidebarView}.swift, Sections/MCPRemoteSectionViews.swift; Packages/CoddPreferences/Sources/CoddPreferences/CoddPreferences.swift).

**Owned paths:** `Packages/CoddSettingsUI/**`, `Packages/CoddStatusUI/**`, `Packages/CoddPreferences/**`. Keep every existing test green; changes are strictly source-compatible (D40): App/Settings/SettingsInfoBuilder.swift builds `SettingsInfo(…)`, App/Settings/SettingsCoordinator.swift `SettingsInfo()`, App/Real/StatusPageData.swift `StatusPageModel(…)` and the App builds `SettingsActions(…)` today, and I1a builds the app before I2a wires anything — so every new member has a default and every new initialiser parameter a default value (`notebook: SettingsNotebookInfo = .unavailable`, `condenseAccounts: []`, `mcp: nil`, new action closures `{}`); with the defaults the M4 rows draw a neutral `—` state, never a crash. Grep App/ for every changed type and list the check in your report.

**CoddPreferences:** no new fields are expected (`Notebook` and `Cleanup` already hold every artboard value). Add doc comments that `notebook.mcpPort` is unused since M4 (MCP shares the hook port, D33) and that `advanced.scrollbackRetentionDays` is unused (the ADVANCED row mirrors `cleanup.scrollbackDeleteDays`, D30). If you find an artboard value with no field, add it (tolerant decode, default = artboard) and report it.

**CoddSettingsUI:**
```swift
public struct SettingsMCPRegistration: Equatable, Identifiable { public var id: String /* "claude-code" | "codex" | "claude-desktop" */; public var name: String; public var hint: String /* "已註冊 · user scope" | "未註冊" | "需要重新註冊（token 已輪替）" | "未安裝" */; public var isOn: Bool; public var actionTitle: String? /* "移除" | "註冊" | "安裝 .mcpb" */; public var actionEnabled: Bool; public var accent: Bool; public var chip: String? /* "FUTURE" */ }
public struct SettingsNotebookInfo: Equatable { public var notesPath: String; public var mcpRunning: Bool; public var mcpClients: Int; public var port: Int?; public var tokenMasked: String; public var registrations: [SettingsMCPRegistration]; public var indexLine: String? /* "已重建 · 128 則 · 0.4 s" | "重建中…" */; public var rebuilding: Bool }
public struct SettingsCondenseAccount: Equatable, Identifiable { public var id: String /* "follow" | "<n>" */; public var title: String }
// SettingsInfo gains: notebook: SettingsNotebookInfo, condenseAccounts: [SettingsCondenseAccount]   (cleanupCandidateCount exists)
// SettingsActions gains: openNotesFolder, rotateMCPToken, mcpRegistration(String /* id */), rebuildNotesIndex, openCleanup
```
- 08 筆記本 & MCP: head button `開啟筆記本資料夾` enabled (→ `openNotesFolder`); 位置 seg with `LOCAL` selectable and `iCloud Drive` / `自訂…` drawn disabled with an `M5` chip each (per-segment disable: build an internal segmented primitive if `SegmentedSwitch` cannot; report it); the hint shows `<notesPath> · 每則筆記是一個 .md 檔`; 圖片長邊壓到 2576px / 保留原檔 / 自動掛載 MCP switches and 新筆記預設 AI 存取 seg live (bound to the existing preferences); the group head right text `● 執行中 · n clients` / `○ 未執行`; Port 與 token: the port as read-only text in the input look (`47821`, `—` when unknown), the masked token code chip, `[輪替]` → `rotateMCPToken`; the registrations box from `registrations` (glyph ● / ○, name, hint, button → `mcpRegistration(id)`; disabled with chip when `chip` is set); AI 可寫入 live. Remove the `M4` milestone chips from these rows.
- 09 清理: every row enabled (the existing preference bindings); the head `查看清理建議 · n →` (→ `openCleanup`; `查看清理建議 →` when the count is nil); 交給 Claude 濃縮 account select from `condenseAccounts` (stores `cleanup.condenseAccount`; nil shows the first) and the model select (the stored model is shown even when not in the options).
- 12 進階: 終端機紀錄保留 binds to `cleanup.scrollbackDeleteDays` with the artboard's options `[30, 7, 90]`; a stored `nil` (`永不`, chosen in 09) is shown as the select's title like an out-of-list model value, without adding a fourth option to the frozen row — edits there and in 09 are the same leaf (D30); 重建筆記索引 `[重建]` enabled (→ `rebuildNotesIndex`; disabled while `rebuilding`) with `indexLine` under the hint; import stays `FUTURE`, logs stay `M5`.
- Search keywords updated; samples per SPEC §5 (`127.0.0.1:47821`, `3 clients`, Claude Code registered, Codex not, Claude Desktop FUTURE); `codd-settings-demo` snapshots of 08 / 09 / 12 updated.

**CoddStatusUI:**
```swift
public struct StatusMCPClient: Equatable, Identifiable { public var id: String; public var title: String; public var kind: String /* "Claude Code" | "Codex CLI" | raw */; public var connectedFor: String /* "連線 42m" */ }
public struct StatusMCPRegistration: Equatable, Identifiable { public var id: String; public var name: String; public var hint: String /* "user scope" | "~/.codex/config.toml" | "擴充功能" */; public var state: String /* "● 已註冊" | "○ 未註冊" | "○ 未安裝" | "◆ 需要重新註冊" */; public var stateTone: Tone; public var actionTitle: String?; public var actionEnabled: Bool; public var accent: Bool; public var chip: String? }
public struct StatusMCPModel: Equatable { public var running: Bool; public var endpoint: String; public var clientsCount: Int; public var clients: [StatusMCPClient]; public var registrations: [StatusMCPRegistration]; public var tokenMasked: String; public var notesPath: String; public var note: String? /* e.g. "// hook server 未執行，MCP 暫停" */ }
// StatusPageModel gains `mcp: StatusMCPModel?` (nil keeps the D27 placeholder for older callers); actions: onMCPRegistration(String), onRotateMCPToken
```
- MCP SERVER card per the Status artboard: head `codd` + `MCP · <notesPath>`; run line `● RUNNING 127.0.0.1:47821 · 3 clients · 只接受本機連線` (stopped: `○ STOPPED` dim + `note`); client rows (`●` ok, title, kind hint, `連線 42m`), `// 沒有 client 連線` when empty; `REGISTRATIONS 註冊到其他 app` sub-head and rows (name, hint, state, button); token row `TOKEN •••• client 連線時需附上 [輪替]`. Nav item `MCP 本機 server` with value `n clients` and glyph ok / off. Per-section diffing as the other sections (a client count change re-renders only the MCP card). Samples / demo updated (SPEC §5 three clients).

**Tests:** for each changed row: enabled / disabled state, binding round trip, the action closure fires; the location segments (LOCAL selectable, others not); the scrollback mirror (a change in 12 shows in 09 and vice versa, `永不` set in 09 shown as 12's title without a fourth option); `SettingsInfo()` / the M3 `SettingsInfo(…)` call shape still compiles (a test with the M3 argument list); registrations box states; index line and the rebuilding disable; STATUS MCP card rendering for running with clients, running without clients, stopped; nav value; buttons fire actions; snapshots via the demos (no window ordered front).

**Acceptance (run exactly):** for each of the three packages `swift build --package-path Packages/<P> --scratch-path <repo>/.build-m4-settings-<P> --build-tests 2>&1 | grep -E "warning:|error:"` → empty and `swift test --package-path Packages/<P> --scratch-path …/.build-m4-settings-<P>` → all pass; the demos' snapshots of Settings 08 / 09 / 12 and STATUS (MCP section scrolled into view) compared with the artboards by eye. Update the three READMEs. Report: API changes (exact), snapshots, deviations, known issues.

### C10 `claude-config` — `Packages/CoddClaudeSettings`: the `~/.claude.json` MCP installer and the Codex snippet

You build CODD Desktop M4 component C10 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§1 the `~/.claude.json` lock fact, §2 D22, D23, §3.12, §9), docs/M3-PLAN.md D10 and docs/M3-REPORT.md §5 (CoddClaudeSettings behaviour and limits), the package's sources and README (OrderedJSONParser, ClaudeSettingsFile, SettingsDiff, Installer, the backups index), and its tests / fixtures.

**Owned paths:** `Packages/CoddClaudeSettings/**` only. Every existing test stays green; the M3 installer's behaviour is unchanged.

**Verify first (read only):** in the installed Claude Code bundle `~/.local/share/claude/versions/2.1.302` (e.g. a python mmap search; never run claude, never read or print `~/.claude.json`'s values), find how `saveGlobalConfig` locks the global config (the bundled proper-lockfile: the `lockfilePath` option or the default `<file>.lock` directory, its `stale` and `update` settings, the realpath handling). Implement a compatible lock and document what you found (with the minified function names as evidence) in the README.

**Contract:**
```swift
public struct ClaudeUserConfigMCPEntry: Sendable, Equatable { public var name: String; public var url: String?; public var hasHeaders: Bool; public var tokenMatches: Bool? }
public struct ClaudeUserConfigMCPInspection: Sendable, Equatable { public var fileExists: Bool; public var parsable: Bool; public var serverNames: [String] /* keys only */; public var codd: ClaudeUserConfigMCPEntry?; public var fingerprint: SettingsFingerprint? }
public enum ClaudeUserConfigMCPAction: Sendable, Equatable { case register(name: String, url: String, token: String), remove(name: String) }
public struct ClaudeUserConfigMCPPlan: Sendable, Equatable { public var action: ClaudeUserConfigMCPAction; public var diff: [DiffLine] /* the token value shown as "••••" */; public var summary: String /* 繁中, e.g. "只會在 mcpServers 加入 codd，其他設定不變" */; public var upToDate: Bool; public var fingerprint: SettingsFingerprint? }
public struct ClaudeUserConfigMCPResult: Sendable, Equatable { public var backup: URL?; public var wrote: Bool }
public enum ClaudeUserConfigMCPError: Error, Sendable, Equatable { case missingFile, invalidJSON(String), changedSinceRead, lockBusy, staleLock(String), notAnObject, io(String) }
public struct ClaudeUserConfigMCPInstaller: Sendable {
  public init(file: URL, backupsIndex: URL?, clock: @escaping @Sendable () -> Date = { Date() }, lockWait: Duration = .seconds(3))
  public func inspect(ourURL: String, token: String?) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPInspection
  public func plan(_ action: ClaudeUserConfigMCPAction) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPPlan
  public func apply(_ plan: ClaudeUserConfigMCPPlan) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPResult
}
public enum CodexMCPSnippet { public static func toml(url: String, token: String) -> String }   // §3.12 text, exactly
```

**Behaviour:**
- Inspect reads the file (≤ 64 MiB) with the order-preserving parser; only `mcpServers` member names and the `codd` entry's `url` / headers presence / token equality are examined; nothing else is decoded into values that leave the call; never logged.
- Plan: `register` adds or replaces `mcpServers.<name>` with `{"type":"http","url":…,"headers":{"X-CODD-Token":<token>}}` (creating `mcpServers` at the end of the top-level object when missing, as JSON.stringify would), `remove` deletes it (and leaves an empty `mcpServers` object if the user had one); `upToDate` when nothing would change; the diff shows only that member (other members elided like M3's diff), the token as `••••`.
- Apply: take the lock (mkdir of the verified lock path; wait up to `lockWait` while another holder's lock is fresh; a lock older than the stale age → `.staleLock` with the 繁中 message `~/.claude.json.lock 看起來是殘留的鎖，請確認沒有 claude 在執行後再試` — never delete a foreign lock), re-read under the lock: when the fingerprint (size, mtime, inode, SHA-256) equals the plan's, apply as planned; when it differs but the file still parses and the `mcpServers` member's bytes are identical to the plan's base, apply the same member edit to the fresh bytes (Claude rewrites other members every few seconds while sessions run; refusing those would make registration fail whenever claude runs); refuse `.changedSinceRead` only when `mcpServers` (or parsability) changed; back up the bytes actually replaced next to the file as `.claude.json.codd-bak-YYYYMMDD-HHMMSS[-n]` (`COPYFILE_EXCL`, mode kept), write temp + F_FULLFSYNC + rename through a symlink to its target, keep every other byte (the JSON.stringify(…, null, 2) layout Claude writes; untouched members byte-identical), record the backup with reason `mcp-register` / `mcp-remove` in the backups index, release the lock (also on every error path).
- A missing file → `.missingFile` (the app says `找不到 ~/.claude.json，請先執行一次 claude`); invalid JSON → refuse, never touch.

**Tests (temp files only; generated fixtures with made-up content — a 2 MB `.claude.json`-shaped file with `projects`, CJK keys and values, numbers like `1e21`, `-0`, `1.0`, `12345678901234567890`, nested arrays, existing `mcpServers` with stdio / http servers):** inspect states (absent, ours with matching / old token, foreign codd), plan diffs (masked token), register / remove round trips byte-identical outside `mcpServers`, create `mcpServers` when missing, upToDate, a change outside `mcpServers` between plan and apply (applied onto the fresh bytes; the other change survives byte for byte), a change inside `mcpServers` between plan and apply (`.changedSinceRead`, file untouched), lock busy (a fresh lock dir held by the test → waits then `.lockBusy`; released in time → succeeds), stale lock refusal, backup naming collision `-1`, mode kept (0600 / 0644), symlinked file written through, invalid JSON untouched, the backups index entry, Codex snippet exact text, performance (plan + apply of the 2 MB file < 1 s debug; print).

**Acceptance (run exactly):** `swift build --package-path Packages/CoddClaudeSettings --scratch-path <repo>/.build-m4-claudecfg --build-tests 2>&1 | grep -E "warning:|error:"` → empty; `swift test --package-path Packages/CoddClaudeSettings --scratch-path …/.build-m4-claudecfg` → all pass. Update the README (the new installer, the lock evidence). Report: API, the lock findings, numbers, deviations, known issues.

### C11 `fixtures` — `scripts/m4-fixtures/`

You build CODD Desktop M4 component C11 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D3, D9, D10, D14, D16, D18, D19, D22, D26, D29, D32, §3 all, §6 DEBUG flags, §9), scripts/m3-fixtures/README.md, scripts/m3-fixtures/fake-claude-m3.sh (a python script with a shell trampoline: reuse its structure — argv parsing, the sidecar `<script>.env`, SessionStart command hook, http hooks posting with `X-CODD-Token` / `X-CODD-Session` from the environment, registry file, DA1, the FAKE-* output contract), scripts/m3-fixtures/selftest.sh and _selftest.py, scripts/m2-fixtures/make-root.sh, design/SPEC.md §5 (the notes n1–n7, the R6 annotations; made-up design data you may reuse).

**Owned paths:** `scripts/m4-fixtures/**` only. Python only through `/usr/bin/python3 -I` with the standard library; bash with `set -euo pipefail`; everything works on temp paths given as arguments; nothing touches `$HOME`, `~/.claude*`, `~/.codex`, the real data root or the network beyond 127.0.0.1.

**Files:**
- `make-png.py <out.png> <w> <h> [--phone]`: writes a PNG with zlib (no PIL); `--phone` draws the made-up 750 × 1334 punch-page placeholder (white status bar, header band, big dark clock block, two light cards, a blue button band at y 1150–1270, a bottom nav band) so the R6 rect lies on the button.
- `make-notes.sh <notesDir> [--count N] [--old <ISO now>] [--spec]`: `--spec` (default) writes the SPEC §5 notes as §3.2 files: n1 `rwd-punch-k7x2` (NOTE, tags rwd punch, links a given session UUID via `--session <uuid>` and the project `--project <path>`, AI read, scope project, the image under `assets/rwd-punch-k7x2/9f3a1c.png` via make-png.py `--phone`, the `codd-annotations` block of §3.3 items 1–3, the task list, the css code block), n2 PROMPT sent, n3 pinned, n4, n5 SCRATCH, n6 PROMPT draft, n7 old; plus test notes: `ai-append-note` (AI append), `ai-off-note` (AI off, with a secret-looking line `OFF-NOTE-SECRET-42`), `global-note` (scope global), a note with `注音輸入法` / `筆記` / `打卡` words, a note without frontmatter, a note in a sub-folder, a note with CRLF. `--count N` adds N generated notes (~4 KB, mixed CJK / ASCII) for performance. `--old <now>` back-dates `updated` / `created` and writes `.codd/state.json` so that relative to `<now>`: one note stale 21 d, one 30 d (auto-archive due), a SCRATCH 8 d, a PROMPT sent 8 d ago, a pinned note 40 d, a note linked to a session (for the live-session exemption), and one trashed note in `.codd/trash/` with `trashed:` 31 d ago. Prints the created ids, one per line.
- `make-git-project.sh <dir>`: a orb-toolkit-frontend-like repo (`src/pages/punch.vue` with the FileEditor artboard's content lines 13–49 incl. `.punch-sticky { position: fixed; bottom: 0; }`, `src/components/PunchButton.vue`, `tailwind.config.js`, `package.json`, `.gitignore` with `node_modules/` and `.env.local`, `node_modules/x/index.js`, `.env.local`, `src/legacy-crlf.js` CRLF, `src/bom.css` UTF-8 BOM, `docs/big5.csv` Big5 bytes for `發票匯出,金額`, `assets/blob.bin` with NUL bytes, `big/large.txt` of 6 MiB); commits with `git -c user.name=fixture -c user.email=fixture@localhost -c commit.gpgsign=false -c init.defaultBranch=main -c core.fsmonitor=false` and `GIT_CONFIG_GLOBAL=<empty temp file>` `GIT_CONFIG_NOSYSTEM=1` only (the user's global config never applies; no fsmonitor daemon left), creates a branch `feat/punch-rwd`, a local bare upstream two commits behind (so `↑2`), then leaves working-tree changes: punch.vue (the AI hunk: `position: fixed;` + `bottom: 0;` → the four added lines of the artboard), PunchButton.vue and tailwind.config.js modified. Prints the repo path.
- `make-claude-json.sh <file> [--codd-foreign] [--codd-ours <url> <token>]`: a fake `~/.claude.json`-shaped file formatted like `JSON.stringify(x, null, 2)` (top-level `numStartups`, `projects` with a few made-up paths each with `mcpServers` keys, top-level `mcpServers` with made-up `pencil-like` stdio and `stitch-like` http servers, numbers like `1e21` / `1.0`, CJK strings); `--codd-foreign` adds `mcpServers.codd` as a stdio server; `--codd-ours` adds our http entry.
- `fake-claude-m4.sh`: everything fake-claude-m3.sh does (copy and extend; keep its output contract and add): parses `--mcp-config <file>` (the variadic form: every following non-option argument; log them all as `FAKE-MCP-CONFIG <path>`), and on startup, when `FAKE_MCP_SCRIPT=<jsonl>` is set, runs `mcp-client.py --config <file> script <jsonl>` and appends the results to `FAKE_MCP_LOG`; prints `FAKE-MCP <method> <status|rpc error code>` lines; when `FAKE_PROMPTS=<file>` is set, for each line posts a UserPromptSubmit payload (`{"hook_event_name":"UserPromptSubmit","session_id":…,"cwd":…,"prompt":<line>}`) to the UserPromptSubmit handler URL found in `--settings` (with the headers interpolated from the environment exactly as Claude would for `allowedEnvVars`), logs `FAKE-PROMPT-HOOK <status> <bytes>` and writes each response body to `FAKE_PROMPT_LOG` (JSONL); when `FAKE_TOOL_EDITS=<file>` is set, after `FAKE_TOOL_EDIT_DELAY_MS` (default 0) each line `Edit|Write <abs path> [<old>→<new>]` optionally applies the replacement to the file (only paths under `FAKE_EDIT_ROOT`) and posts PostToolUse `{"tool_name":…,"tool_input":{"file_path":…}}` to the hooks URL, logging `FAKE-TOOL-EDIT <path> <status>`, and a line `sleep <ms>` waits (so an e2e can let CODD open and dirty a file before the edit lands); typed / pasted input is appended to `FAKE_STDIN_LOG`; `-p` mode (condense): accepts D32's flags (`--model`, `--output-format`, `--tools ""`, `--permission-prompts none`, `--strict-mcp-config`, `--mcp-config <file>`, `--allowedTools <tools...>`, `--no-session-persistence`; variadic parsing as Claude does), reads stdin fully into `FAKE_P_INPUT`, logs argv (tokens and `CLAUDE_CONFIG_DIR` masked as `set`) and `FAKE-P-ENV CODD_HOOK_TOKEN=set|unset CODD_SESSION_ID=set|unset`, optionally (`FAKE_P_MCP=1`) calls `notes_read` once through its `--mcp-config` and logs `FAKE-MCP` lines, sleeps `FAKE_P_DELAY` seconds (default 0), prints `FAKE_P_OUTPUT` (a file) or a default Markdown summary (`# 摘要 · 10/15 清理（n 則）` with one `##` per `codd://note/<id>` found in the input) and exits `FAKE_P_EXIT` (default 0). Never contacts anything but 127.0.0.1.
- `mcp-client.py`: `mcp-client.py --config <mcp.json> [--server <name>] [--origin <o>] [--token <t>] [--no-session] call <method> [<params json>]` and `… script <jsonl>`; POSTs JSON-RPC with `Content-Type: application/json`, `Accept: application/json, text/event-stream`, the config's headers (overridable for negative tests), `MCP-Protocol-Version` after initialize; prints one JSON line per response (`{"method", "status", "body"}`), decoding image blocks to `{"image": {"mimeType", "bytes"}}`; never prints request headers or any token; exit 0 unless the connection fails. Also `--url <u> --header K:V` mode without a config, `--token-from-config <config.json>` (reads `mcpToken` itself so no token appears in an e2e command line or log) for external token tests, and `get <url>` for the `/n/<id>.md` route (`--note-token-from-config <config.json> <id>` computes `t` with the D15 HMAC).
- `age-layout.py <layout.json> [--stopped <session id> <ISO>] [--archived <session id> <ISO>] [--ring <dataRoot> <session id> <MiB>] [--first-run <dataRoot> <ISO>]` (`--first-run` writes `cleanup.json` `retention.firstRunAt` per §3.4 so the D30 grace is over): edits a seeded layout (scripts/m2-fixtures/seed-layout.sh) in CoddCore's exact format (sorted keys, the same date format), setting `lastState` stopped + `lastStateAt` and / or `archivedAt` for a session, and writes a dummy `ring` file of the given size into `<dataRoot>/sessions/<id>/` (retention tests); refuses paths inside `~/Library` or `~/.claude`.
- `mock-codd.py`: a tiny 127.0.0.1 HTTP server emulating `/mcp` (canned initialize / tools/list / tools/call answers, `server/discover` → -32601, 202 for notifications), `/hooks` (204), `/hooks/prompt` (JSON with `additionalContext`), used only by the selftest.
- `selftest.sh`: runs every script into a temp dir and checks the results (notes parse with a small python frontmatter check, the PNG's IHDR size, the annotation block JSON, `git status --porcelain=v2` of the project shows the three modified files and `ahead 2`, the Big5 / BOM / CRLF / NUL files' bytes, the claude json parses and keeps key order, fake-claude-m4 against mock-codd.py: MCP script results, prompt hook responses, tool edits posted (incl. `sleep` lines and the delay), `-p` output and its argv / env lines, no token in any fixture output or log, `make-git-project.sh` leaves no `git` / fsmonitor process), prints `M4FIXTURES pass=<n> fail=0`, exits non-zero on any failure, leaves no process running.
- `README.md`: every script, its arguments, its output contract.

**Acceptance (run exactly):** `bash scripts/m4-fixtures/selftest.sh` → `M4FIXTURES pass=<n> fail=0`; `bash scripts/m3-fixtures/selftest.sh` and `bash scripts/m2-fixtures/selftest.sh` still pass (you changed nothing there); `pgrep -f m4-fixtures` empty afterwards. Report: the output contracts, numbers (notes generation time for 1,000), known issues.

### Common to every integration step

One agent at a time edits App/ and project.yml; do not commit. Read every earlier step's report and the
component reports named below first. Build Debug with fresh derived data `build/m4<step>` (e.g.
`build/m4i1a`), app tests with `CODD_BACKGROUND=1`, zero `warning:` lines from CODD code, no process
left. Every CODD launch: `export CODD_BACKGROUND=1`, a bash array with every flag as its own argument,
`-codd-data-root <fresh temp>` and `-codd-claude-dir <temp>` (or `-codd-mock`), `-codd-login-env NO`,
`-codd-notifications NO`; never `open`, never `-codd-background NO`, never `CODD_ALLOW_STANDARD_ROOT` /
`CFFIXED_USER_HOME`. Clean up by the temp path only (`pkill -TERM -f "$T/"`, then `rm -rf "$T"`). New code
follows D38 (trash), D39 (no pasteboard / Finder / browser / panel / sound while `AppActivation.isBackground`
unless the user acted) and never activates the app or orders windows front in background runs. Small
fixes inside packages are allowed when an API gap blocks the step (note them). Report: files changed,
smoke excerpts, numbers, deviations, known issues, what the next step must know.

### I1a `notebook-core` — project graph, NotesService, the NOTES area, the Notebook mode and the editor

You are integration step I1a of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (all of §0–§3, §5, §6, §9, the common block above; you own the core notes parts of §6), the component reports of C1 (CoddNotes), C4 (CoddTextKit), C6 (CoddFiles / CoddFileEditorUI: `DiskChangeBannerView`, `RecentFilesStore`), C7 (CoddNotebookUI) and skim the others (C2, C3, C5, C8–C12), the packages' READMEs, and the App code you will touch: App/main.swift, App/AppDelegate.swift, App/AppDelegate+Lifecycle.swift, App/Window/{MainWindowController,MainSplitViewController,RailViewController,MainMenu}.swift, App/Session/{SessionPaneViewController,SessionHeaderView}.swift, App/MenuBar/{MenuBarPanelView,StatusItemController}.swift, App/Real/{HolderSessionStore,HolderSessionStore+External,PreferencesService,RealModeOptions,StateDump,CoddDataRoot,HookPipeline}.swift, App/Model/{Stores,ShellState,SessionModels}.swift, App/Mock/*, App/Debug/ShortcutMatrix.swift, project.yml, docs/ARCHITECTURE.md (App sections), the Notebook and MenuBar artboards.

**Build the project graph:** project.yml gains the local packages `CoddNotes`, `CoddMCP`, `CoddTextKit`, `CoddCodeEditor`, `CoddFiles` (products `CoddFiles` and `CoddFileEditorUI`), `CoddNotebookUI`, `CoddAnnotateUI`, `CoddCleanupUI`, all as CODD target dependencies now (the graph is final for the later steps); `xcodegen generate`; GRDB resolves through CoddNotes (check the Xcode project's Package.resolved; the libghostty pin is unchanged). The first build also proves D40: if a changed existing package (CoddCore, CoddHooks, CoddComposer, CoddSettingsUI, CoddStatusUI, CoddPreferences, CoddClaudeSettings) breaks the App, fix it in the package (noted), never by changing App behaviour.

**Do:**
1. Infrastructure: `RealModeOptions` keeps everything after the first `:` of `-codd-show` as given (only the keyword is case-insensitive; test); `App/Support/AppTrash.swift` (D38: one trash function — macOS Trash only on the standard data root, else `-codd-trash-dir` or `<dataRoot>/trash/`; logs `trash target=system|folder name=<last component>`); `App/Support/CoddPasteboard.swift` (D39: `.general` only for a user action in a foreground run, else a private named pasteboard + the dump).
2. `App/Notes/NotesService.swift` (`@MainActor @Observable`): owns the `NotesLibrary` (root `<dataRoot>/notes`, index `<dataRoot>/notes-index.sqlite`, policy from `PreferencesService` (`cleanup.*`, `notebook.defaultAIAccess`), trash = AppTrash, clock = DEBUG `-codd-now` or `Date`, log → the app log), opened off the main actor after the preferences load and before the NOTES area first shows; consumes `changes` (one consumer) into observable state: availability (`// 筆記資料夾無法使用：<reason>`), counts, the selected list and its rows, the selected note (document, summary, activity, history, assets), search results, the last paste; implements `OpenNoteCoordinator` (saves the editor when dirty and not composing; waits ≤ 2 s for a composition to end). A failed open never blocks sessions.
3. NOTES area (D12): `MainSplitViewController` / `MainWindowController` gain a notes mode like M3's D16 STATUS swap (the session sidebar column collapsed while NOTES shows, its width and collapse restored on leave, autosave off meanwhile); `SessionPaneViewController` shows `App/Notes/NotesAreaViewController.swift` for `.notes` instead of the placeholder. Modes: Notebook (this step), Annotate (I1b), Files (I3), Cleanup (I4a) reserved.
4. Notebook mode with CoddNotebookUI: lists (smart lists, BY PROJECT mapped to layout projects by realpath → name + group color, unknown paths → last path component without color; LOCAL FILES drawn from `<dataRoot>/files/recent.json` via CoddFiles `RecentFilesStore`, rows and `開啟資料夾…` disabled with the tooltip `檔案編輯在 I3 接上` until I3; footer path + `● MCP` from `HostSummary` (live in I2a); the cleanup line hidden until I4a), note list (sort, day sections in local time `TODAY · M/D`, `YESTERDAY`, then `M/D`, then `YYYY-MM`; row texts per D14 / §3.2), editor chrome (the AI / scope pills show the values; their menus, COPY REF and SEND are I1b / I2b and stay disabled with a tooltip until then), the info panel drawn read-only from the data (LINKS, AI ACTIVITY, HISTORY list, ASSETS, RETENTION; its buttons are I1b's), doc status bar, prompt footer (target picker of live CODD claude sessions; its three actions are I2b's: disabled with tooltip until then).
5. Editor binding `App/Notes/NoteEditorController.swift`: CoddTextKit `MarkdownEditorView` in the chrome's document slot; load on selection; a new note is created on disk by `NotesLibrary.create` only at its first non-empty committed text or first image paste (D3; until then the chrome shows `id —`); autosave 1 s after the last committed change, never while composing, flushed on note switch, area leave, window close and quit (`applicationWillTerminate` path); `basedOn` hash → conflict banner (D7); external changes: clean → `applyExternalText`, dirty → banner `磁碟上的筆記已變更` `[重新載入] [保留我的] [比較]` (C6's `DiskChangeBannerView` with this title; 比較 opens the C7 compare sheet over the buffer and the disk text); title accessory = C7 `NoteChipsRowView` (display; tag editing I1b); image resolver over `assets/` (NSImage decoded off the main actor, cached) with overlay shapes from the note's `codd-annotations` blocks (C1 `FencedBlocks` + `ImageAnnotations`); image accessory = C7 `ImageAnnotationSummaryView` (its `編輯標註` is I1b's); paste images per D9 (`NotesLibrary.saveAsset` with the two preferences; toast `已貼上圖片 → assets/<id>/<hash6>.png` (`· 已縮小到 2576px`)); ⌘E source mode; caret → doc status; links: `codd://note/<id>` selects that note, `http(s)` opens in the default browser (user action only, D39), relative file links reveal (I3 opens them in Files); `markOpened` after 3 s on a note; ⌘⏎ wired in I2b.
6. Search: the lists' search field → `NotesService.search` debounced 150 ms, never while the field has marked text; results replace the note list (`SEARCH · n`, highlighted snippets); `#tag` terms.
7. Quick note (D13): a `筆記` main menu with 快速筆記 ⌘⇧N, 原始碼 / 即時預覽 ⌘E, 搜尋筆記 ⌘F (I1b adds 標註模式 ⌘⇧A and 複製引用 ⌘⇧C), validated by area with marked-text checks (D36); the Notebook `+ ⌘⇧N`, the menu bar `QUICK NOTE ⌘⇧N` and the status item `快速筆記` wired (no beep); in-app only, never a system-wide hotkey. Extend `ShortcutMatrix` (the new items must not fire inside a terminal and must not break ⌘L / ⌘P / ⌘. / ⌘⏎ / ⌘W in the sessions area).
8. `SessionVM.notesCount` = active notes linked to the session (the header pill shows it; the drawer is I2b).
9. Mock mode (D35, notes part): a temporary notes folder seeded with the SPEC §5 notes and the generated image (`$TMPDIR/codd-mock-notes-<pid>`, removed at quit), so `-codd-mock -codd-show notebook|note:rwd-punch-k7x2 -codd-snapshot <png> -codd-quit-after 4` renders the Notebook artboard.
10. DEBUG flags and dump keys of §6 for this step: `-codd-show notebook|note:<id>`, `-codd-notes-select`, `-codd-notes-new`, `-codd-quick-note`, `-codd-notes-type`, `-codd-notes-paste-image`, `-codd-notes-search`, `-codd-notes-rebuild`, `-codd-now`; dump `notes {root, available, index, counts, list, selected, search, lastPaste, externalEvents, quickNote}` (never a token).

**Tests (App/Tests/M4NotebookCore*.swift, Swift Testing, temp roots, injected trash):** NotesService over a temp data root (open, counts, list rows, quick note → nothing on disk until typed → file appears with the D3 name, autosave debounce, no save while `setMarkedText` is active, search `打卡` / `打卡頁` / `#rwd`, paste image → asset + Markdown + toast text, external edit while clean → reloaded, while dirty → banner), the `-codd-show` parser keeping case, AppTrash targets per root kind, CoddPasteboard never touching `.general` in a background run, menu validation per area (⌘⏎ / ⌘P / ⌘W stay with the sessions area), the notes mode split swap restores the sidebar width, mock snapshot smoke.

**Acceptance (run exactly):**
```bash
cd <repo> && xcodegen generate
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/m4i1a build 2>&1 | grep -E "error:|warning:|BUILD"
CODD_BACKGROUND=1 xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/m4i1a test 2>&1 | grep -E "error:|warning:|failed|passed|BUILD" | tail -20
```
(zero `warning:` from CODD code, all tests pass), then a temp-root smoke (bash arrays; every flag its own argument):
```bash
export CODD_BACKGROUND=1
APP=build/m4i1a/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
T="$(mktemp -d "${TMPDIR%/}/codd-m4i1a.XXXXXX")"; T="$(cd "$T" && pwd -P)"
scripts/m2-fixtures/make-root.sh "$T/data"; mkdir -p "$T/home/.claude/sessions" "$T/work"
bash scripts/m4-fixtures/make-notes.sh "$T/data/notes"
args=(-codd-data-root "$T/data" -codd-claude-dir "$T/home/.claude" -codd-login-env NO -codd-notifications NO -codd-trash-dir "$T/trash" -codd-dump-state "$T/dump.json" -codd-quit-after 15)
"$APP" "${args[@]}" -codd-show notebook -codd-notes-search 打卡 >"$T/app.log" 2>&1
```
check the dump (counts, search ids, index rebuilt on first run, `buildMs`), relaunch after deleting `notes-index.sqlite` (rebuilt), append a line to a note file while the app runs (`external` event, updated hash), `-codd-notes-new` + `-codd-notes-type` (the D3 file appears) and `-codd-notes-paste-image` of a 4000 × 3000 PNG (asset at 2576); run the mock Notebook snapshot and compare it with the artboard by eye; clean up. Also run `scripts/m2-e2e.sh` and `scripts/m3-e2e.sh` once (`CODD_APP=<binary>`). Report: files changed, the dump excerpt, numbers (open / index / search / note open / keystroke in a 1 MB note through the app), snapshot deviations, known issues, what I1b must know.

### I1b `notebook-features` — Annotate mode, menus and metadata, COPY REF, history, ⌘K NOTES

You are integration step I1b of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§0–§3, §6, §9, the common block; D10, D15, D20, D29, D36, D39), the I1a report, the component reports and READMEs of C1, C4, C6 (`LineDiff`), C7 and C8 (CoddAnnotateUI), the artboards Notebook, ImageAnnotate and QuickSwitch, and the App code you will touch: App/Notes/* (I1a), App/Window/MainMenu.swift, App/Palette/{QuickSwitchModel,CommandPalette}.swift, App/Real/{RealModeOptions,StateDump}.swift, App/Mock/*, App/Debug/ShortcutMatrix.swift.

**Do:**
1. Annotate mode: ⌘⇧A / `編輯標註` / double click on a figure → C8 `ImageAnnotateView` in the NOTES area (image from the asset, document mapped from `ImageAnnotations`; `previewText` = C1's §3.7 formatter for that image, `markdownSource` = the block text); `完成` → one undoable `replace` of the block in the editor text (inserted after the image line when missing) and the annotated PNG regenerated off the main actor; `取消` discards; the app status bar shows `statusText` + `● 已儲存 HH:mm` while annotating; esc / 完成 return to the Notebook with the note selected.
2. Menus / metadata: AI access (with the D34 hints), scope (Global + the note's / layout projects), kind, ⋯ (pin, archive, trash, restore, reveal in Finder — user action only —, source mode, copy id); COPY REF (D15; the five forms from C1 `NoteReferences.forms` with the port from config.json and `MCPAuth.noteURLToken` with `mcpToken` — the URL answers once I2a installs the route; the URL item disabled for an OFF note with its hint; everything disabled for an unsaved note; ⌘⇧C copies form 1; copies through CoddPasteboard (D39), DEBUG `-codd-notes-copy-ref` writes the dump); SEND TO SESSION menu built (live CODD claude sessions; its three actions disabled with the tooltip `送到 session 在 I2b 接上`); link / tag pickers (C7) and the chips row's tag field; archive / trash / restore with UNDO toasts (`已封存 · [UNDO]`, `✕ 已移到垃圾桶 · 30 天後永久刪除 · [UNDO]`); unparsable-frontmatter refusals as toasts (`這則筆記的 frontmatter 無法解析，請先手動修正`).
3. Info panel actions: HISTORY `[比較]` opens C7 `HistoryCompareView` as a sheet (lines from CoddFiles `LineDiff` mapped to CoddUI `DiffLinesView.Line`), `還原這一版` → `restoreSnapshot`; RETENTION `[釘選以保留]` / `[取消釘選]`; `+ 連結 session / 專案` opens the link picker; an ASSETS thumbnail scrolls the editor to its image line.
4. ⌘K (QuickSwitch artboard): a NOTES section (≤ 5, `FuzzyMatcher` over titles and tags, order SESSIONS · NOTES · PROJECTS · ACTIONS, row = title (matched substrings amber) + sub `note · #rwd #punch` + time `10:05`, header `NOTES n`); opening switches to NOTES and selects it; an empty query lists the 3 most recently updated notes after the sessions.
5. The `筆記` menu gains 標註模式 ⌘⇧A and 複製引用 ⌘⇧C (validated by area, marked-text checks); `ShortcutMatrix` extended.
6. Mock: `-codd-mock -codd-show note:rwd-punch-k7x2` with the COPY REF menu open (DEBUG `-codd-notes-menu copy-ref`) and `-codd-show annotate:rwd-punch-k7x2:9f3a1c.png` render the Notebook and ImageAnnotate artboards; compare by eye.
7. DEBUG flags and dump keys of §6 for this step: `-codd-show annotate:<id>:<asset>`, `-codd-notes-annotate`, `-codd-notes-set`, `-codd-notes-trash`, `-codd-notes-archive`, `-codd-notes-copy-ref`, `-codd-notes-menu <copy-ref|ai|scope|send>` (snapshots only); dump `notes.history`, `notes.activity`, `notes.copyRef`.

**Tests (App/Tests/M4NotebookFeatures*.swift, temp roots):** annotate `完成` → block text in the note (one undo step) + annotated PNG exists, `取消` leaves the note unchanged; metadata changes reach the file (AI, scope, kind, tags, links, pin); COPY REF form texts (incl. the masked URL display, OFF disabled, unsaved disabled) through a private pasteboard; trash → UNDO → restored; history compare + restore (snapshot first); ⌘K notes ranking and empty-query rows; menu validation (⌘⇧A / ⌘⇧C only in NOTES; ⌘⏎ / ⌘P stay with the sessions area).

**Acceptance (run exactly):** build and test as in I1a with `build/m4i1b`; a temp-root smoke like I1a's with `-codd-notes-set rwd-punch-k7x2:ai=append`, `-codd-notes-copy-ref rwd-punch-k7x2:5`, `-codd-notes-annotate rwd-punch-k7x2:9f3a1c.png:<json>`, `-codd-notes-trash <id>` (the file under `.codd/trash/`, the dump's counts); the two mock snapshots compared with the artboards; `scripts/m2-e2e.sh` and `scripts/m3-e2e.sh` once. Report as in the common block.

### I2a `mcp-server` — the MCP server on the hook port, per-session injection, prompt expansion, note URL, STATUS / Settings

You are integration step I2a of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§1, §2 D15–D21, D33, D37, D38–D40, §3.6–§3.11, §6, §9, the common block), the I1a and I1b reports, the component reports of C2 (CoddMCP), C3 (CoddHooks / CoddCore), C9 (Settings / STATUS), C10 (inspection only), C11 (fake claude m4, mcp-client.py), the packages' READMEs, and the App code you will touch: App/Real/{HookPipeline,HolderLauncher,HolderSessionStore,HolderSessionStore+Launch,HolderSessionStore+Accounts,StatusPageData,RealModeOptions,StateDump}.swift, App/Notes/*, App/Session/{PaneBars,StatusArea}.swift (StatusBarView), App/Settings/{SettingsCoordinator,SettingsInfoBuilder}.swift, App/Window/RailViewController.swift.

**Do:**
1. `App/MCP/MCPService.swift` (`@MainActor @Observable`) + `App/MCP/NotesMCPBackend.swift` (a `Sendable` `MCPNotesBackend` over `NotesLibrary`, never touching the main actor on the request path except through a `@Sendable` snapshot of session facts: CODD session id → title, cwd realpath / project path, live flag): CoddMCP `MCPServer(info: name "codd", version = app version)`; access and scope rules D17 (OFF invisible everywhere, READ read-only, APPEND append, `notes_write` only while `notebook.aiCanWrite`; project scope by the caller session's cwd realpath inside a note project or the note linked to the session; external callers see all visible notes; the tools' `scope` argument only narrows), `session: "current"` / `project: "current"` from the caller, AI text from C1 (`aiText` with the 12,000-character default page, images through `annotatedImage` / `aiImage` per the image's send options, ≤ 4 images, the rest as paths), errors mapped to `MCPBackendError`, AI activity recorded for read / append / write (D20). `HookPipeline` installs on its `HookServer` (once after creating it; handlers survive rebinds — check C3's report) `setMCPHandler` (→ `MCPServer.handle`, the caller from the route), `setPromptHandler` (step 3), `setNoteURLHandler` (step 4), `setMCPToken` (config.json `mcpToken`). Client tracking D21 from `MCPServer.events` + session liveness; `HostSummary.mcpEndpoint` = `127.0.0.1:<port>`, `mcpClients`, `mcpRunning` → rail `● MCP`, status bar, Notebook footer live. Mock mode never installs routes (the mock HostSummary shows the SPEC values).
2. Per-session injection D18 in `HolderLauncher` for every claude launch, RESUME and RESTART when `notebook.autoAttachMCP` is ON and hooks are available: `MCPServerNameResolver.scan(claudeJSON:, cwd:, projectMCPJSON: <cwd>/.mcp.json)` with `claudeJSON` = `<claudeDir>/../.claude.json`, or `<CLAUDE_CONFIG_DIR>/.claude.json` for a pinned session (never logged) (off the main actor, cached by mtime for 10 s) → `resolve`; write `<sessionDir>/mcp.json` with `MCPLaunchConfig` (token `MCPAuth.sessionToken(hookToken, sessionID)`; create the session directory 0700 when it does not exist yet — check how `planClaude` and the holder create it), `LaunchRequest.mcpConfigPath`, `ClaudeHookSettings.promptPath = "/hooks/prompt"`, `permissionsAllow = MCPLaunchConfig.allowRules(serverName:)`; `userRegisteredOurs` → no file, no allow rules, the prompt route still on; OFF → none of it (M3 argv). The token never appears in argv, logs or dumps (`mcp.sessionConfigs` lists session, server name, file path only).
3. Prompt expansion D19 (`App/MCP/PromptExpansion.swift`): the prompt handler takes the payload's `prompt`, calls `NotesLibrary.expansion(for:maxChars: 9500)` within the deadline, records `expand` activity per note with the session's title, returns `PromptHookAnswer(additionalContext:, systemMessage:)` or nil; dump `promptExpansion` (count, refs, chars, ms, late).
4. Note URL route: `GET /n/<id>.md` → the §3.7 copy form (`copyMarkdown`) as `text/markdown; charset=utf-8`; trashed / purged → 410 with one Markdown line (`這則筆記在 CODD 垃圾桶` / `這則筆記已永久刪除`); unknown or AI OFF → 404; `url` activity.
5. STATUS: `StatusPageData` maps `StatusMCPModel` (running, endpoint, clients with `連線 <duration>`, registrations from C10's `inspect` (read-only: state and hint; the buttons stay disabled with the tooltip `註冊在 I2b 接上`), masked token, notes path, degraded note when the hook server is down) and wires the nav item live. Settings: `SettingsInfoBuilder` fills `SettingsNotebookInfo` (+ `condenseAccounts` for I4a) and the actions (`openNotesFolder` reveals `<dataRoot>/notes` in Finder — user action only, D39 —, `rebuildNotesIndex` → `NotesService.rebuild` with the index line; `rotateMCPToken`, `mcpRegistration` and `openCleanup` disabled until I2b / I4a).
6. AI ACTIVITY live in the info panel (activity changes stream).
7. DEBUG flags and dump keys of §6 for this step: dump `mcp` and `promptExpansion` (never a token).

**Tests (App/Tests/M4MCP*.swift; temp roots; the HookServer on a test port; never a real claude):** backend rules (OFF invisible in search / list / read / resources / expansion / URL, READ append refused, APPEND append lands with the block + snapshot + activity, write only when allowed, project scope visibility by caller cwd, `scope` narrowing, archived only with the flag, trashed / purged errors), an end-to-end request through `HookServer` → `MCPServer` → backend with a session token and with the external token, wrong token 401, foreign Origin 403, `server/discover` → -32601; launcher: argv has `--mcp-config <sessionDir>/mcp.json` directly before `--settings`, the file is 0600 and its token equals `MCPAuth.sessionToken`, settings carry `/hooks/prompt` and the allow rules, name resolution with a fixture `.claude.json` (foreign codd → `codd-desktop`; ours → no file; a pinned session reads its profile's file), OFF → unchanged M3 argv; prompt expansion (refs, cap, OFF line without its title, `systemMessage`, no refs → 204, late → 204, activity); note URL (200 / 404 / 410, OFF 404, token check); client counting.

**Acceptance (run exactly):** build and test as in I1a with `build/m4i2a`; then a temp-root smoke with the C11 fake claude (copy `scripts/m4-fixtures/fake-claude-m4.sh` into the temp root with its `.env` sidecar like `scripts/m3-e2e.sh` does; `FAKE_MCP_SCRIPT` with discover / initialize / notifications/initialized / tools/list / notes_search `打卡` / notes_read `rwd-punch-k7x2` / notes_append on the APPEND note / notes_read of the OFF note; `FAKE_PROMPTS` with `看一下 codd://note/rwd-punch-k7x2`) launched through `-codd-claude-path <copy> -codd-new-claude "$T/work"` (bash arrays, `CODD_BACKGROUND=1`): the fake's MCP log shows -32601, `2025-11-25`, the tool names, CJK hits, an image block, the append ok and the OFF refusal (its secret string absent everywhere); the prompt log shows `additionalContext` with the note title and the `systemMessage`; the dump shows 1 client and the session config; numbers: `notes_read` server time with / without images, expansion latency. Run `scripts/m3-e2e.sh` and `scripts/m2-e2e.sh` once. Report as in the common block.

### I2b `send-register` — send to session, the notes drawer, composer chips, registration and token rotation

You are integration step I2b of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§1, §2 D14, D15, D22, D23, D33, D36, D37, D39, §3.6, §3.7, §3.12, §6, §9, the common block), the I1a / I1b / I2a reports, the component reports of C4 (composer chips), C7 (drawer, footer), C9, C10 (CoddClaudeSettings), C11, the packages' READMEs, and the App code you will touch: App/Notes/*, App/MCP/*, App/Session/{SessionPaneViewController,SessionHeaderView,PaneComposer,ComposerStates,ComposerBarView}.swift, App/Terminal/TerminalHub.swift (`send(_:to:)`), App/Real/{ClaudeSettingsService,HookDiffDialog,AccountDialogs,StatusPageData,RealModeOptions,StateDump}.swift, App/Settings/{SettingsCoordinator,SettingsInfoBuilder}.swift, App/Window/MainMenu.swift, App/Debug/ShortcutMatrix.swift, CoddDialogsUI's `HookDiffModel`.

**Do:**
1. Send to session D14 (`App/Notes/NoteSending.swift`): prompt footer, SEND TO SESSION menu and drawer cards; 插入引用 / 插入全文 → the target session's composer draft (the M2 `ComposerStates.appendToDraft` + `panes.composerOpen = true`; when the session is on screen the bar shows and focuses); 送出 → the AI text through `ComposerEncoding.payload` → `TerminalInput.payload` (paste + submit) to claude's own PTY via the hub's `send(_:to:)`; WAITING refusal (`Claude 在等你確認 · 先用下方按鍵回答`), not-running / no connection refusal (`session 沒有在執行`), > 256 KiB refusal (`筆記太長，改用插入引用`), success toast `已送到「<session>」`; a PROMPT gets `markSent`. ⌘⏎ in the note editor = 送出 (menu `允許` ⌘⏎ is disabled outside the sessions area so the editor receives it; update `ShortcutMatrix`). Externals are never targets.
2. Session pane: the `✎ NOTES n` pill toggles the C7 `NotesDrawerView` as a 300 pt right column inside the pane (open state per session in memory; the pill `.on` while open); cards from `summaries(linkedToSession:)` (thumbnails from the first two assets, first three tasks with the `done/total` progress, tags, updated, `AI 讀取 HH:mm` from the activity); `插入引用` / `送出全文` through step 1; `+ 新筆記（連結此 session）` creates a NOTE linked to the session and its project (on disk at its first typing, D3) and switches to NOTES with it selected; the files section stays hidden (I3).
3. Composer chips: turn on C4's `referenceChips` in App/Session/ComposerBarView.swift.
4. Registration D22 / D23 (`App/MCP/MCPRegistrationService.swift`): Claude Code through C10's installer on `<claudeDir>/../.claude.json` (the standard data root: `~/.claude.json`; any other root: only DEBUG `-codd-claude-json <file>`, refused — before reading — when it resolves (realpath or lexically, dangling links included) into the real home's `.claude.json`, `.claude/` or `.claude-swap-backup/`, like M3's A13 guard; without the flag the row is disabled with the hint `測試資料根目錄不會寫入 ~/.claude.json`), the diff dialog = CoddDialogsUI dialog B with the title `預覽 ~/.claude.json 變更` and the plan summary (small additive CoddDialogsUI changes allowed; note them), `套用並備份` applies (the C10 rebase rule: only an `mcpServers` change since the preview refuses), errors as toasts (`.lockBusy` → `Claude Code 正在寫入 ~/.claude.json，請稍後再試`, `.missingFile` → `找不到 ~/.claude.json，請先執行一次 claude`, `.changedSinceRead` → `~/.claude.json 的 mcpServers 在預覽後被改過，請重新預覽`, …); `移除` the same way; Codex `註冊` → a small sheet `註冊到 Codex` with `把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）`, the `CodexMCPSnippet.toml` text and `[複製]` (CoddPasteboard) `[關閉]`; Claude Desktop disabled `FUTURE`. Token rotation: confirm sheet `輪替 token？已註冊的 client 需要重新註冊，舊的筆記網址會失效。` `[輪替]` `[取消]` → `HookConfigStore.rotateMCPToken()` off the main actor → `HookServer.setMCPToken` → registration state `需要重新註冊（token 已輪替）` when the registered entry's token no longer matches. STATUS and Settings rows enabled.
5. DEBUG flags and dump keys of §6 for this step: `-codd-show split` (the shown session with the notes drawer open; with `-codd-mock` the s9 session of the Split artboard), `-codd-notes-send`, `-codd-mcp-rotate`, `-codd-claude-json`, `-codd-mcp-register-plan`, `-codd-mcp-register-apply`; dump `registration`.

**Tests (App/Tests/M4Send*.swift, M4Registration*.swift; temp roots; never a real claude, never the real `~/.claude.json`):** send flows (draft append, submit payload to a fake surface, WAITING refusal, not running, size refusal, markSent, externals excluded), ⌘⏎ routing per area; drawer model (cards, progress, empty state, new linked note); composer chips on; registration on temp files (plan masked, apply + backup + other bytes identical, a concurrent change outside `mcpServers` rebased, remove, guard refusal for the real paths incl. a dangling link, rotation → needs re-register, Codex snippet text through a private pasteboard).

**Acceptance (run exactly):** build and test as in I1a with `build/m4i2b`; a temp-root smoke: `-codd-notes-send rwd-punch-k7x2:submit` to the fake claude m4 (its `FAKE_STDIN_LOG` has the note text as one paste + submit), `:ref` (the composer draft in the dump has the ref), registration with `-codd-claude-json "$T/claude.json"` made by `make-claude-json.sh` (plan → apply → backup next to it, only `mcpServers` changed, no lock dir left; remove → original bytes), `-codd-mcp-rotate YES` (registration state needs re-register); the mock `-codd-show split` snapshot compared with the Split artboard; `scripts/m3-e2e.sh` and `scripts/m2-e2e.sh` once. Report as in the common block.

### I3 `file-editor` — the local file editor (Files mode), git, AI-touched files, SHOW AI CHANGES

You are integration step I3 of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D12, D24–D28, D34–D37, D39, §3.4, §6, §9, the common block), the I1a–I2b reports, the component reports of C5 (CoddCodeEditor), C6 (CoddFiles / CoddFileEditorUI), C3 (`HookPayload.toolFilePaths`), C7 (drawer files section), C11 (`make-git-project.sh`, `FAKE_TOOL_EDITS`), their READMEs, the FileEditor and Split artboards, and the App code you will touch: App/Notes/*, App/Session/{SessionPaneViewController,SessionHeaderView,PaneBars}.swift, App/Real/{HookPipeline,HolderSessionStore,RealModeOptions,StateDump}.swift, App/Window/MainMenu.swift, App/Debug/ShortcutMatrix.swift, App/Palette/QuickSwitchModel.swift, App/Mock/*.

**Do:**
1. `App/Files/FileEditorService.swift` (`@MainActor @Observable`): one Files workspace per opened root (a project's cwd, a folder chosen with `開啟資料夾…` (NSOpenPanel, user action), or the parent of a single opened file); tabs (VS Code rules: a single click opens a preview tab (italic) that the next single click replaces; double click, an edit or a save pins it; note tabs open the note in a CoddTextKit `MarkdownEditorView` bound through I1a's `NoteEditorController`; dirty `●`; ⌘W on a dirty tab → C6 `DirtyCloseSheetView` as a sheet (`[儲存] [不儲存] [取消]`)), per tab a CoddFiles `OpenFileState` and a CoddCodeEditor `CodeEditorView` (language from `CodeLanguageDetector`; binary → the comment `// 二進位檔案，無法以文字開啟`; > 5 MiB read-only plain; > 50 MiB refused with a toast), file reads off the main actor, `FileWatch` per open file → `diskChanged` (D25: clean reload, dirty banner via C6 `DiskChangeBannerView` with the AI attribution from step 3; `重新載入` / `保留我的` / `比較` = an inline diff of the buffer against the disk text), ⌘S → `FileSaver.save` with the load fingerprint (refused when the disk changed unless 保留我的 was chosen; read-only files refused with `這個檔案是唯讀的`), the tree / git / AI badges refreshed after a save; `RecentFilesStore` records opens.
2. Files mode in `NotesAreaViewController`: C6 `FileTreeView` (264 pt) + `EditorTabStripView` + `EditorToolbarView` + banner + the editor; the app status bar shows C6 `EditorStatusItemsView` (branch, session, `Ln, Col`, encoding, EOL (`CRLF*` when mixed), language, indentation, `● 已儲存 HH:mm`) while Files shows. Git through `GitReading` (`GitReader` in real mode, `exec git …` log lines): repo root, status at open, on `DirectoryWatcher` changes (debounced 500 ms) and after saves; ignored paths dimmed; `M` badges and folder dots; the head `⎇ <branch> ↑n · M n · AI n`; not a repo → the head shows `// 不是 git 專案` and no badges. ⌘P → the filter field over `trackedAndUntracked` (or `FileTreeModel.walk`), fuzzy (CoddCore `FuzzyMatcher`), ⏎ opens. Collapse all. The tab-strip session pill (when the root is a CODD session's cwd): `● <tag> <title> <tool · duration> ⌘n` → shows that session.
3. AI touches (D26): `HookPipeline` hands PostToolUse payloads of CODD sessions to `AITouchLog.record` (`HookPayload.toolFilePaths`, the session id, the tool, the time) off the main actor; the service derives `AI` chips (session tag color, else a bone outline) for tree rows, Recent rows and tabs, the head `AI n`, the tree foot `● <tag> <title> · AI 改 n · HH:mm`, and the attribution window for D25 (±10 s).
4. SHOW AI CHANGES (D27): per tab switch (ON when opened from an AI badge or `差異`), baselines `基準：git HEAD` (`GitReading.headText`; not in HEAD → everything added), `基準：上次儲存 HH:mm` (`OpenFileState.savedText`), `基準：AI 開始前 HH:mm` (`aiBaseline`, only when present); `LineDiff.hunks(baseline, buffer)` recomputed 300 ms after edits off the main actor → `CodeEditorView.setInlineDiff` with headers (who = the AI touch's session title · time, the unified range, counts, `i / n`, the tag color); `AI 變更 n 段` + ↑ ↓; overview marks; `還原此段` → `replaceLines` (buffer only, undoable, tab dirty); `接受` → hidden until the file or the baseline changes. Nothing writes the file except ⌘S / the dirty-close `儲存`.
5. Entry points: the session header Files button → NOTES Files mode rooted at the session's cwd (the rail switches to NOTES); the Notebook LOCAL FILES rows (open that file) and `開啟資料夾…` (enabled now); the drawer's files section `AI 改過的檔案 · n` `vs HEAD` — rows = the files this session touched (with the `AI HH:mm` chip, newest first) followed by the other git-modified files of its cwd (no chip), ≤ 8, `[差異]` opens the tab with SHOW AI CHANGES on (the Split artboard shows `tailwind.config.js M` without a chip); its git status runs (read-only, names only) only while the drawer shows and the cwd is a repo — enable it in the drawer model; ⌘K gains `在 <project> 開啟檔案…` (opens the Files mode with ⌘P focused) if it fits the ACTIONS limit (else skip and report).
6. Find / replace (C5 widget) on ⌘F while Files shows; the `檔案` menu items (儲存 ⌘S, 關閉分頁 ⌘W, 篩選檔案 ⌘P, 尋找 ⌘F) validated by mode with marked-text checks, each pair that shares a key with an existing item mutually exclusive (D36); `ShortcutMatrix` extended (⌘P keeps pinning and ⌘W keeps closing the window in the sessions area).
7. Mock (D35): `-codd-mock -codd-show files:<mock project>/src/pages/punch.vue` renders the FileEditor artboard from a mock project folder written by Swift and a mock `GitReading` (`feat/punch-rwd ↑2`, the `M` badges, punch.vue's HEAD text with `position: fixed; bottom: 0;`); mock mode never runs git.
8. DEBUG flags and dump keys of §6 for files: `-codd-show files:<path>`, `-codd-open-file`, `-codd-file-type`, `-codd-file-show-ai-changes`, `-codd-file-baseline`, `-codd-file-hunk`, `-codd-file-save`, `-codd-file-find`; dump `files {…}`.

**Tests (App/Tests/M4Files*.swift; temp git repos built in the test or with `scripts/m4-fixtures/make-git-project.sh`, git with an isolated config):** open → encoding / EOL / language / indentation facts; preview-tab replacement and pinning; disk change while clean (reload, caret kept) and while dirty (banner with and without an AI touch inside the window), keep-mine then save refused / allowed per D24; save round trips byte-identical for CRLF, BOM and Big5 files, a mixed-EOL file changes only the edited line; binary / large / refused / read-only files; never a write without save (the file's mtime unchanged after edits, reverts and closes with 不儲存); `.git/index` mtime unchanged after a session of reads; AI touches recorded from a PostToolUse payload through the pipeline, chips with the session color; SHOW AI CHANGES hunks against HEAD for the fixture (`@@ -40,2 +40,4 @@`), revert one hunk → the buffer equals HEAD there, accept hides it, baselines switch; drawer files rows (touched first, then git `M`); ⌘P filter; menu validation.

**Acceptance (run exactly):** build and test as in I1a with `build/m4i3`; a temp-root smoke (bash arrays, `CODD_BACKGROUND=1`): `make-git-project.sh "$T/work/frontend"`, the fake claude m4 session in that folder with `FAKE_TOOL_EDITS` editing `src/pages/punch.vue` after `FAKE_TOOL_EDIT_DELAY_MS` (`FAKE_EDIT_ROOT="$T/work"`), `-codd-open-file "$T/work/frontend/src/pages/punch.vue"`, `-codd-file-type x` before the edit lands → the dump shows the banner with the session; `-codd-file-show-ai-changes YES` → hunks; `-codd-file-hunk 0:revert` + `-codd-file-save YES` → the disk text matches the expectation; `.git/index` mtime unchanged by CODD's reads; the mock FileEditor snapshot compared with the artboard. Numbers: open 1 MB file, first highlighted screen, git status time, idle CPU with the Files mode shown. Run `scripts/m3-e2e.sh` once. Report as in the common block.

### I4a `cleanup` — retention, the Cleanup page, digest, condense, Settings 清理

You are integration step I4a of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (§2 D29–D32, D37–D39, §3.4, §6, §9, the common block), the I1a–I3 reports, the component reports of C1 (retention, candidates, `datedSections`), C3 (`SessionRetention`), C9 (Settings 09 / 12), C11 (`make-notes.sh --old`, `age-layout.py`, the fake claude's `-p` mode) and C12 (CoddCleanupUI), design/artboards-src/Cleanup.src.html and MenuBar.src.html (footer `清理建議 15 →`), Settings.src.html §09, and the App code you will touch: App/Notes/*, App/MCP/*, App/Real/{HolderSessionStore,HolderSessionStore+Layout,HolderLauncher,CswapAccountStore,PreferencesService,ShellEnvironment,RealModeOptions,StateDump}.swift, App/AppNotifier.swift, App/MenuBar/MenuBarPanelView.swift, App/Settings/{SettingsCoordinator,SettingsInfoBuilder}.swift.

**Do:**
1. `App/Cleanup/RetentionService.swift`: at launch (after the notes open and the first session discovery), every 24 h and after a CLEANUP preference change: `NotesLibrary.runRetention(liveSessions:)` (live = running CODD claude sessions) and CoddCore `SessionRetention.evaluate` over CODD sessions (running, pinned, `lastState` / `lastStateAt`, `archivedAt`, `keepUntil` from `<dataRoot>/cleanup.json`, transcript mtime / existence via the store's `TranscriptCatalog`, the session ring's size, `resumeWarning` and `countFrom` = `cleanup.json retention.firstRunAt` — written at the first run, D30 grace) → apply: stopped-stale dims rows (extend `SessionVM.isStale`), auto-archive through the store's archive path (`archivedAt` set; restorable), rings (and `holder.log`) of sessions archived longer than `scrollbackDeleteDays` moved through AppTrash (D38); log `retention notes stale=… archived=… purged=…` and `retention sessions archived=… rings=…`. Never touches externals, running or pinned sessions, or anything outside the data root.
2. Cleanup mode in `NotesAreaViewController` with C12 `CleanupPageView`: NOTES candidates (`cleanupCandidates`), SESSIONS (`SessionRetention` candidates), FILES (unused note images from the NOTES reasons, rings of archived sessions with `deletes in nd`, Recent entries whose file is gone); row actions (`保留 30 天` → `keep` / cleanup.json `keepUntil`; `封存` → notes archive / session archive; FILES `移到垃圾桶` → AppTrash; Recent entries removed), the bulk bar per tab (SESSIONS: no 移到垃圾桶, no condense; FILES: no condense), keyboard (space, ⌘A, ⌫) without marked text, esc back to the Notebook; entry points: the Notebook footer `清理建議 n →`, the menu bar footer `清理建議 n →` (add the line per the MenuBar artboard), Settings › 清理's head button (C9 `openCleanup`, enabled now), the digest notification's `查看`. Counts are refreshed after every retention run and action.
3. Digest D31: `AppNotifier` gains the kind `cleanup-digest` (category action `查看`), scheduled at the first launch / hourly tick after Monday 09:00 local (biweekly / monthly / off per the preference; `-codd-now` in tests), only with ≥ 5 candidates, once per period (`cleanup.json digest.lastShownAt`), suppressed and recorded with `-codd-notifications NO`.
4. Condense D32 (`App/Cleanup/CondenseRunner.swift`): from the bulk bar with the selected NOTES (OFF notes left out with the toast `AI 存取為 OFF 的筆記不會交給 Claude`); account options from `CswapAccountStore` (follow global, or accounts with a usable cswap profile, M3 D12 rules) and the model; the claude executable = the login-PATH `claude` on the standard data root, only the DEBUG `-codd-claude-path` executable on any other root (else the button is disabled with `測試資料根目錄只用 -codd-claude-path`); environment from `ShellEnvironment.build` without `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` (+ `CLAUDE_CONFIG_DIR` for a pinned account, never logged); run folder `<dataRoot>/run/condense-<uuid>/` with an `mcp.json` (`MCPLaunchConfig` with a run UUID registered in `MCPService` as a transient read-only caller for the run's life) removed when the run ends; argv exactly per D32 (`--tools ""`, `--permission-prompts none`, `--strict-mcp-config` only here; every variadic flag followed by another option); stdin = a 繁體中文 instruction (summarise into one Markdown note, keep decisions / open tasks / numbers, one `##` per source, never invent) + each note's §3.7 text — a long-note source only its `datedSections(olderThanDays: 30)` labelled `（舊段落 n 段）`; 180 s timeout, `取消` kills the process group; `exec claude path=… sub=-p` log line; the card shows the running time, then the preview (`MarkdownRender.attributedPreview`); `建立摘要並封存原稿` → `create` (NOTE `摘要 · M/D 清理（n 則）`, id `cleanup-<MMdd>-xxxx`, body = output + `濃縮自` + one `codd://note/<id>` line per source, `condensedFrom`), each whole-note source snapshotted and archived `by: .condense` with `condensedInto`, a long-note source snapshotted, left ACTIVE and unchanged with `keepUntil` +30 d; toast `✻ 已建立「…」· n 則原稿已封存 [UNDO]` (UNDO = unarchive the sources, trash the summary into CODD's TRASH); `捨棄` drops the preview. Nothing changes before the apply. The condense child must not show up as an EXT session (exclude its pid from external detection while it runs).
5. Settings › 清理 rows obeyed (RetentionService reacts), the condense account / model selects (C9 `condenseAccounts`); 進階 › 終端機紀錄保留 = the same leaf (C9 mirror) — verify it reaches the engine.
6. DEBUG flags and dump keys of §6 for this step: `-codd-show cleanup`, `-codd-retention-run`, `-codd-cleanup-action`, `-codd-condense`, `-codd-condense-account`, `-codd-condense-apply`; dump `retention`, `cleanup`.

**Tests (App/Tests/M4Cleanup*.swift; temp roots; injected trash and clock; a fake claude script for condense):** the retention table through the service (notes stale / archive / scratch / sent prompt / purge with exemptions; sessions stale / archive / ring with the first-run grace: a first run never archives at once, a run with an old `firstRunAt` does), never externals / running / pinned, AppTrash folder targets; Cleanup rows and actions per tab, bulk disabling, keyboard; digest timing (Monday 09:00, ≥ 5, once per period, suppressed); condense argv (exact order, variadics followed by options), environment (no CODD token), stdin content (OFF excluded, long-note old sections only), timeout / cancel, preview then apply (summary, `condensedFrom`, archived sources with `condensedInto`, the long note untouched with `keepUntil`), UNDO, run folder removed; the ADVANCED mirror reaching the engine.

**Acceptance (run exactly):** build and test as in I1a with `build/m4i4a`; a temp-root smoke: `make-notes.sh --old <now>` + `age-layout.py` (`--stopped`, `--archived`, `--ring`, `--first-run`) + `-codd-now <now>` + `-codd-trash-dir "$T/trash"` + `-codd-retention-run YES` (the dump's `retention`; purged files in `$T/trash`; no `trash target=system` line), `-codd-show cleanup` counts, the digest at `-codd-now 2026-10-19T09:05:00+08:00`, `-codd-condense <ids> -codd-condense-account follow -codd-condense-apply YES` with the fake claude `-p`; the mock Cleanup snapshot compared with the artboard; `scripts/m3-e2e.sh` and `scripts/m2-e2e.sh` once. Report as in the common block.

### I4b `e2e-report` — the M4 end to end, full verification, docs and the report

You are integration step I4b (the last) of CODD Desktop M4 in <repo> (branch main; do not commit). Read first: docs/M4-PLAN.md (all; especially §1, §2 D29–D32, D37–D41, §6, §7, the common block), the I1a–I4a reports and every component report, docs/M3-REPORT.md (its structure and the 繁體中文 checklist style), scripts/m3-e2e.sh (structure: groups, fake roots, polling, cleanup, isolation greps), scripts/m4-fixtures/README.md, and the App code as needed for fixes.

**Do:**
1. `scripts/m4-e2e.sh` (`export CODD_BACKGROUND=1`; bash arrays; one `mktemp -d` root with one sub-root per group made with `scripts/m2-fixtures/make-root.sh`, a temp Claude dir, copies of the C11 fakes with `.env` sidecars; `-codd-trash-dir` on every launch; `-codd-dump-state` polled every 100 ms with waits ≤ 30 s; `KEEP=1` keeps the folder; `CODD_APP=<binary>`; ends every process it started by the temp path; prints `E2E ok …` / `E2E FAIL …` / `E2E number …` lines and `E2E pass=<n> fail=<m>`). Groups:
   **B1 notes storage** — make-notes fixture; counts in the dump; search `打卡` / `打卡頁` / `#rwd` ids; `notes-index.sqlite` created; deleted → rebuilt (`index.rebuilt`, reason); corrupted (garbage bytes) → rebuilt; an external edit / create / delete while running → reflected ≤ 3 s; no `.md` outside `<root>/data/notes`.
   **B2 editor, paste, annotate** — `-codd-notes-new` + `-codd-notes-type` → the file with the D3 name; `-codd-notes-paste-image` of a 4000 × 3000 PNG → the asset at 2576 long edge + the Markdown line; `-codd-notes-annotate` → the block in the file + `<hash6>.annotated.png`.
   **B3 MCP** — fake claude m4 session: discover -32601, initialize `2025-11-25`, tools list (4 tools; `notes_write` absent; present after `-codd-set-pref notebook.aiCanWrite=true` in a second run), `notes_search 打卡` hits, `notes_read rwd-punch-k7x2` text contains the annotation list and one image block, `notes_append` on the APPEND note lands (file, history snapshot, activity) and is refused on a READ note, the OFF note never appears (its secret string absent from every MCP log), a trashed note's read is isError; external token via `mcp-client.py --url … --token-from-config <config.json>` works, a wrong token → 401, `--origin http://evil.example` → 403; `/n/<id>.md?t=<tok>` 200 (`--note-token-from-config`), a wrong `t` → 404, the OFF note's URL → 404; dump `mcp.clients` = 1.
   **B4 prompt expansion** — `FAKE_PROMPTS`: a `codd://note/rwd-punch-k7x2` prompt → 200 JSON with the title in `additionalContext` and the `systemMessage` line, an OFF ref → the refusal line without the OFF note's title, no ref → 204; the session's last prompt still updated; latency number.
   **B5 per-session config** — argv log: `--mcp-config <sessionDir>/mcp.json` immediately before `--settings`; the file 0600 with the derived token; `--settings` has `/hooks/prompt` and the allow rules; a fake `.claude.json` with a foreign `codd` (C11 `make-claude-json.sh --codd-foreign` at `<claudeDir>/../.claude.json`) → `codd-desktop`; `-codd-set-pref notebook.autoAttachMCP=false` → no `--mcp-config`, UserPromptSubmit on `/hooks`.
   **B6 send to session** — `-codd-notes-send rwd-punch-k7x2:submit` to the fake claude → its stdin log has the note text (paste + submit); `:ref` → the composer draft has the ref; a WAITING fake (permission prompt) refuses; a PROMPT note gets `sent`.
   **B7 file editor** — make-git-project; open punch.vue: encoding / EOL / language / branch `feat/punch-rwd` ↑2, `M` badges; CRLF / BOM / Big5 files save byte-identical when unchanged; `FAKE_TOOL_EDITS` (with `sleep` lines) edit while dirty → banner with the session, while clean → reload; AI chip; SHOW AI CHANGES 1 hunk `@@ -40,2 +40,4 @@`; revert + save → the expected bytes; `.git/index` mtime unchanged; nothing written without save.
   **B8 registration** — `-codd-claude-json <temp file>` + plan → masked diff in the dump; apply → backup next to it, only `mcpServers` changed (python compare of every other member, byte compare after removing the member), no lock dir left; a change outside `mcpServers` made between plan and apply (with an apply delay flag like M3's `-codd-hooks-apply-delay`, add `-codd-mcp-register-apply-delay`) → applied on the fresh bytes; remove → identical to the original bytes; a `-codd-claude-json` that is a link to `$HOME/.claude.json` (only resolved, never read) → refused before reading (never a fake home: no `CFFIXED_USER_HOME`).
   **B9 retention** — `make-notes.sh --old <now>` + `-codd-now <now>` + `-codd-retention-run YES`: stale ids, the 30 d note archived (`status: archived`, `archivedBy: auto`), the SCRATCH and the sent PROMPT archived, the pinned and the live-linked notes not, the trashed 31 d note purged into `-codd-trash-dir` (file + assets) with a tombstone and `resolve` → purged; sessions: a first run on a fresh root archives nothing and records `firstRunAt`; with `age-layout.py --first-run <root> <now − 30 d>`, a stopped CODD session (`--stopped <id> <now − 8 d>`) is auto-archived and a session aged `--archived <id> <now − 31 d> --ring <dataRoot> <id> 1` has its `ring` moved to the trash dir.
   **B10 cleanup and digest** — candidate counts per tab in the dump; `-codd-cleanup-action notes:<id>:keep` → `keepUntil`; the digest at Monday 09:00 (`-codd-now 2026-10-19T09:05:00+08:00`) recorded once (suppressed); not with < 5 candidates.
   **B11 condense** — `-codd-condense <ids> -codd-condense-account follow -codd-condense-apply YES` with the fake claude `-p`: the argv in the fake's JSON log is exactly D32's (`-p`, `--model`, `--output-format text`, `--tools` with an empty value, `--permission-prompts none`, `--strict-mcp-config`, `--mcp-config <run>/mcp.json`, `--allowedTools mcp__codd__notes_read`, `--no-session-persistence`), `FAKE-P-ENV CODD_HOOK_TOKEN=unset`, the fake's stdin has the notes' text (a long note only its old sections), the summary note exists with `condensedFrom`, the whole-note sources are archived with `condensedInto`, the long note is unchanged, nothing deleted, the run folder is gone; an OFF note in the selection is left out; a pinned account (M3 fixtures: `make-cswap-state.sh`, the fake cswap, `-codd-cswap-root` / `-codd-cswap-path`) passes `CLAUDE_CONFIG_DIR` (logged as `set` only).
   **B12 isolation** (what can be proven here, §1 automation limits) — every `exec` line names a path inside the temp root (git, the fake claude); no `anthropic.com` in any log; neither the hook token, the `mcpToken` nor any derived session token (read from the temp config.json / mcp.json files) appears in any dump, app log or fake log; no `trash target=system` line in any app log; no `$HOME/.claude.json.codd-bak-*` and no new `$HOME/.claude/settings.json.codd-bak-*` (names only, before / after); `~/.codex/config.toml`, when it exists, has the same size and mtime before / after; a source grep shows no CODD code path that writes under `.codex`; no `.md` written into the work folders; no `pasteboard target=general` line in any app log (D39: every pasteboard write logs its target). Never list `~/.Trash` (TCC refuses it) and never compare listings of `~/.claude` or `~/.claude.json` (real sessions write there).
   **B13 numbers** — 1,000 notes index build, search p95 (1 / 2 / 3 characters), note open, `notes_read` with / without images, expansion latency, 1 MB / 10 MB file open, idle CPU with the Notebook and the Files mode shown (3 fake claudes silent), footprint.
   Run it twice in a row, both green.
2. Full verification: every package suite (zero warnings on clean `--build-tests` builds; CoddDialogsUI with `--skip PresenterTests`), app tests, Debug and Release builds with zero `warning:` from CODD code, `scripts/m3-e2e.sh`, `m2-e2e.sh`, `m1-e2e.sh`, `m1-smoke.sh`, `m2-fixtures/selftest.sh --with-app <binary>`, `m3-fixtures/selftest.sh`, `m4-fixtures/selftest.sh`, `-CODDSelfTest YES`, `-codd-shortcut-matrix YES`; fix regressions (small package fixes allowed, noted). Mock snapshots of Notebook, ImageAnnotate, FileEditor, Cleanup, Split (drawer), STATUS MCP and Settings 08 / 09 / 12 compared with the artboards; list the visible deviations.
3. Docs: docs/ARCHITECTURE.md (M4 decisions summary; repository layout with the eight new packages; process model: MCP and `/hooks/prompt` on the hook port, the per-session `mcp.json`; data root tree: `notes/`, `notes-index.sqlite`, `files/`, `cleanup.json`, `trash/` on test roots, `sessions/<id>/mcp.json`, config.json `mcpToken`; App sections for notes, MCP, files, cleanup; DEBUG flags / dump keys), CLAUDE.md build lines (the new packages' test commands, `scripts/m4-e2e.sh`, `scripts/m4-fixtures/selftest.sh`), docs/ROADMAP.md (M4 done, commit placeholder for the orchestrator), and **docs/M4-REPORT.md** in the M3 report's structure: status, what was built (components, steps), how to run (incl. a throwaway try-out with the fakes), test results table, numbers table, known issues (honest: not verified with a real claude / real `~/.claude.json` / real cswap; Bash-made changes not attributed; MCP down while CODD is quit; scope advisory; managed MCP config; pinned sessions outside CODD do not see a user-scope registration (their profile's `.claude.json`); anything not done), decisions as implemented (D1–D41 + additions), new copy not on the artboards, visible deviations, and a **繁體中文 manual checklist** for the user (注音 in every new field and the editor positions of §7; a real CODD claude session: `/mcp` lists `codd` and the user's own servers, Claude reads a note with its annotated image, `codd://` expansion with the `codd：已展開…` line, append on an APPEND note with the permission prompt, OFF notes invisible; Claude Code registration on the real `~/.claude.json` with the backup checked first; the file editor on a real project; 交給 Claude 濃縮 with a real account; the Monday digest; retention after a week and after the first-run grace).

**Acceptance:** `scripts/m4-e2e.sh` green twice; everything in step 2 green; the report complete and honest; no process of any run left (`pgrep -f <temp root>` empty).

---

## 11. Plan review (2026-10-17): what changed and why

Checked against design/SPEC.md (§2, §5, §7.2, §7.8–§7.12, §8, §9), the frozen artboards, docs/ARCHITECTURE.md,
the M1–M3 reports and the code; facts re-read from `claude --help` and the installed 2.1.302 bundle (read only).

- **Wrong assumptions about existing code:** `-codd-show` lowercases its whole value (paths / ids would be
  mangled); `HookConfig(port:token:)`, `SettingsInfo(…)`, `SettingsActions(…)`, `StatusPageModel(…)`,
  `LaunchRequest(…)` and `ComposerStyle(…)` are built by App code, so C3 / C4 / C9 must stay
  source-compatible or I1a cannot build (D40); `HookConfigStore.reassignPort` / `setPort` rewrite
  config.json from `HookConfig(port:token:)` and would have dropped `mcpToken`; ⌘W is already
  `關閉分頁或視窗`; `HolderSessionStore.trash` is the macOS Trash on test roots too (M2 only used it on a user
  action; M4's automatic moves would not) → D38.
- **Missing artboard / SPEC features:** the Main artboard's `⎿ codd：已展開 …` line (`systemMessage`, D19);
  the ImageAnnotate `AI 會收到` header text (§3.7); the QuickSwitch NOTES row shape; the drawer's image
  captions, task progress and the non-AI `M` row; the Cleanup artboard's long-note source
  `每日工作日誌（舊段落 9 段）` (D32); ADVANCED 終端機紀錄保留's frozen 30 / 7 / 90 options.
- **Risky choices fixed:** automatic archive / ring trashing on the first M4 launch over the user's
  existing sessions (D30 first-run grace); automatic trash moves from test roots reaching `~/.Trash`
  (D38); background runs writing the user's clipboard (D39); `notes_read` pages that exceed Claude's
  25,000-token MCP cap for CJK text (D17); a condense `claude -p` with built-in tools and prompts
  (D32: `--tools ""`, `--permission-prompts none`, no CODD tokens in its environment, run folder removed);
  registration refusing every apply while claude rewrites `~/.claude.json` (D22 rebase under the lock);
  the user's git config (fsmonitor daemons, textconv) reaching CODD's read-only git and the fixtures
  (D24); saves that dropped xattrs / hard links or rewrote every line ending of a mixed-EOL file (D24);
  OFF notes reachable through the note URL (D15); an unsupported protocol header blocking the
  `server/discover` fallback (§3.10).
- **Untestable checks replaced:** B12 no longer lists `~/.Trash` (TCC refuses it) or compares
  `~/.claude*` listings (real sessions write there); it checks log lines (`trash target`, `pasteboard
  target`, `exec`), backup names and the Codex config fingerprint instead.
- **Technical gaps:** contentless FTS5 has no `snippet()` (snippets in Swift, FTS5 string literals,
  NFKC text); HEIC / TIFF / resized WebP images re-encoded for Claude; pinned sessions read their
  profile's `.claude.json`; `cat-file blob` instead of `show`; mock Files without git.
- **Workload:** the Cleanup page moved to its own package (C12) and the integration split into seven
  steps (D41), each with its own smoke and report.
