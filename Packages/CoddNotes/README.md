# CoddNotes

CODD's notebook (M4): Markdown files with their pasted images under `<dataRoot>/notes/`, a derived SQLite index that also finds 繁體中文, an FSEvents watcher, history snapshots, image assets and annotations, retention and cleanup rules, and the text an AI receives for a note. The files are the truth; the index can be deleted at any time and is rebuilt.

No AppKit: the MCP backend (CoddMCP, in the app) calls this off the main actor. Frameworks: Foundation, CoreServices (FSEvents), ImageIO, CoreGraphics, CoreText, UniformTypeIdentifiers, CryptoKit, plus GRDB 7.11.1 (pinned exactly; it builds with zero warnings on Swift 6.4 / the macOS 26 SDK; FTS5 is used through raw SQL against the system SQLite 3.54).

| Part | Role |
|---|---|
| `NotesLibrary` | The actor: open / close, lists, counts, search, documents, create / save / metadata, archive / trash / restore / purge, AI writes, assets, history, activity, retention, cleanup candidates, AI text, prompt expansion, the `changes` stream |
| `Frontmatter` | Lossless YAML-subset frontmatter with line patching |
| `NoteNaming` | Ids and file names (D3) |
| `NoteReferences` | `codd://note/<id>` parsing and the five COPY REF forms (§3.6) |
| `NoteAIText` | The §3.7 AI text, paging, the expansion result type, the ImageAnnotate preview text |
| `ImageAnnotations` | The `codd-annotations` block codec and its coordinate list |
| `AnnotatedImageRenderer` | Burns annotations into a PNG |
| `FencedBlocks` | Finds and rewrites fenced blocks (the annotation block after an image line) |

```sh
swift test --package-path Packages/CoddNotes --scratch-path .build-notes
```

## Folder layout

```
<dataRoot>/notes/                                   0700, never excluded from backups
  .codd/notebook.json                               {"v":1,"createdAt":"<ISO>"}  marker
  .codd/state.json                                  per-note app state, written 1 s after a change and at close
  .codd/activity.jsonl                              AI activity, append-only; compacted at open (5,000 lines / 90 days)
  .codd/history/<note-id>/<yyyyMMdd-HHmmss-SSS>-<hash8>.md   snapshots (UTC names; reason in xattr com.codd.notes.snapshot-reason)
  .codd/trash/<relative note path>                  trashed notes (`trashed:` added); assets under .codd/trash/assets/<note-id>/
  .codd/tombstones.json                             {"v":1,"items":[{"id","title","trashedAt","purgedAt"}]}
  .codd/tmp/                                        temp files of atomic writes (emptied at open)
  <name>.md                                         notes, flat by default; sub-folders are indexed
  assets/<note-id>/<hash6>.<ext>                    images; <hash6>.orig.<ext>
<dataRoot>/cache/notes-index.sqlite (+ -wal, -shm)  derived index (`indexURL`), NSURLIsExcludedFromBackupKey
<dataRoot>/cache/annotated/<hash12>-<stem>.annotated.png   derived burned-in copies (`annotatedFolder`)
```

- Every write is a temp file in `.codd/tmp/` + `F_FULLFSYNC` + `rename(2)`, so a note is never partly on disk. New files are 0600, folders 0700; an existing note keeps its mode and extended attributes.
- Indexed as notes: `*.md` outside dot-folders and outside the root `assets/`, plus `.codd/trash/**/*.md` (status `trashed`). Symlinked folders are not followed.
- The `.codd/` JSON files are tolerant: a corrupt file is moved aside to `<name>.corrupt-<ms>` and started over; a newer `v` is read but never written.

## A note file (§3.2, D2, D3)

- Frontmatter: `---` lines with `key: scalar`, `key: [a, b]`, block lists, quoted strings and `#` comments. Every line is kept as read; CODD rewrites only the lines of the keys it changes, or appends a key before the closing `---`. A CRLF file stays CRLF (`NoteDocument.body` is always LF; `save` converts back). Booleans are written bare (`pinned: true`), strings that YAML would misread are double-quoted.
- Outside the subset (nested maps, block scalars, flow maps, anchors, duplicate keys, an unterminated quote): the note is indexed with defaults and `NoteFlags.unparsableFrontmatter` (only a recognisable `id:` line is kept, so references survive). `update`, `archive` and `trash` throw `.unparsableFrontmatter`; `save` writes the new body and leaves the frontmatter text untouched.
- Title = the body's first H1 outside code blocks, mirrored into `title:` at every save; without an H1, `title:` or `未命名筆記`.
- Keys read: `id title kind tags sessions projects ai scope pinned status archived archivedBy trashed sent sentTo created updated condensedFrom condensedInto createdBy`; all optional, unknown keys kept. A missing `ai:` follows the library's current default access; a missing `scope:` is `project` when the note links a session or project, else `global`.
- Ids: up to two ASCII words of the NFKC-lowercased title, then of the tags (≤ 20 characters, else `note`) + `-` + 4 random base36 (`rwd-punch-k7x2`), never one the index, a tombstone, a history folder or an assets folder already uses. A file without a usable `id:` gets a derived id (its file name's ASCII words + 4 hex of the SHA-256 of its relative path), written at its first save or metadata change. Duplicate ids: the file indexed first (at a rebuild: oldest birth time, then path) keeps the id, the other becomes `<id>-dup<n>` with `NoteFlags.duplicateID` and gets that id written at its next save.
- File name at creation: `YYYY-MM-DD-<slug>.md`, slug = the title with letters / digits of every script kept, ASCII lowercased, everything else → `-` (collapsed, ≤ 48 graphemes, else `note`), NFC, `-2`, `-3` on collision. Never renamed.
- Dates are written as `2026-10-14T18:20:11+08:00` in the library's time zone (init parameter, default `.current`).
- `updated` shown in lists = the frontmatter `updated:`, or a later mtime when another program changed the file. Retention never counts a bare mtime (see below).

## Index (§3.5 as refined; `PRAGMA user_version = 1`)

`notes` (id, path, declared id, title, kind, ai (`''` = not set), scope, pinned, status, created, updated, updated_fm, archived, archived_by, trashed, sent, sent_to, condensed lists, tags / sessions / projects as `\u{1F}`-joined text, mtime, size, birth, hash, snippet, body_text, asset_count, asset_bytes, flags, line_ending, search_text), `note_tags`, `note_links`, `index_meta(root)` and

```sql
CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, tags, content='', contentless_delete=1, tokenize='trigram case_sensitive 0');
```

- Rebuilt in full when the file is missing (`missing`), unopenable or failing `PRAGMA quick_check` (`corrupt`), of another `user_version` (`version`), built for another notes root (`root`), or on request (`rebuildIndex`, `requested`). Otherwise every file's (path, mtime, size) is compared at open and changed files are re-parsed. Afterwards it is updated by the watcher and by CODD's own writes.
- A build sorts files by birth time, writes batches of 50 rows (one short transaction each) and yields between files, so other actor calls (MCP reads) interleave.
- `body_text` is the body as plain text (Markdown stripped, the H1 left out, code kept, annotation blocks reduced to their comments, HTML comments dropped, original case); `search_text` and the FTS columns hold NFKC-lowercased title / body_text / tags.

## Search rules (D6)

- `NoteQuery.text` is split on whitespace; `"…"` keeps spaces (a quote inside a term is literal, a lone `"` searches the quote character); `#tag` filters tags (case-insensitive, NFKC); every term is AND-ed.
- Terms are NFKC-lowercased. A term of ≥ 3 Unicode scalars goes to `notes_fts MATCH` as an FTS5 string literal (double quotes, inner `"` doubled), so `a-b`, `AND`, `*`, `NEAR(` are searched as text. Shorter terms use `search_text LIKE '%term%' ESCAPE '\'` with `%`, `_`, `\` escaped (a scan, fine at notebook scale: p95 ≈ 7 ms over 1,000 notes in debug).
- Ranking: `bm25(notes_fts, 5, 1, 2)` when any term used MATCH, then pinned, then updated.
- Status: active only; `includeArchived`, `includeTrashed` add those. `kinds`, `project` (exact `~` path) and `limit` filter.
- Each hit's snippet is built in Swift (a contentless FTS5 table has no `snippet()`): about 110 characters of `body_text` around the first occurrence of any term (newlines shown as spaces, `…` at cut ends), matched case- and width-insensitively (`ＲＷＤ` is found by `rwd`), with UTF-16 `NSRange` highlights of every occurrence. A match only in the title or tags falls back to the list snippet.

## Watcher (D7)

FSEvents on the realpath of the root: file events, recursive, 200 ms latency (the coalescing window), delivered on a private queue into an `AsyncStream` that one task inside the actor consumes in order. `.codd/` and dot-folders are ignored; `assets/<id>/` changes only refresh that note's asset count. A changed `.md` is re-hashed: equal to the index → nothing; equal to a remembered own write (relative path → SHA-256) → `.changed`; otherwise → re-indexed and `.external([id])`. A vanished file → `.removed`; a renamed file keeps its id at the new path. A dropped event batch (`MustScanSubDirs`) runs the open-time comparison again. The root disappearing → `.unavailable("筆記資料夾不見了")`. `externalEventCount` counts external changes for the app's dump.

## Lists, lifecycle and retention (D29)

- `counts()`: INBOX = active, PINNED, PROMPTS, STALE, ARCHIVE, TRASH, `byProject` (active notes per linked `~` path). `list(.project(p))` matches the exact path.
- Last activity = the newest of the frontmatter `created` / `updated` / `sent`, state.json `lastUserActivityAt` and `lastOpenedAt`. CODD saves, `markOpened` (the app calls it after 3 s), pin / kind / tag / link / scope-with-project changes, send, unarchive, restore and edits by other programs seen by the watcher (at their mtime) are activity. AI reads and AI writes (`appendFromAI` does not touch `updated:`) never are.
- Exempt (`policy.exempt`): pinned, linked to a live session, read (`read` / `expand` / `url` activity) by a live session; `keep(until:)` always exempts. Live sessions come from `setLiveSessions` / `runRetention(liveSessions:)`.
- STALE = active, not exempt, last activity + `staleDays` ≤ now. Archive due = last activity + `archiveDays`; SCRATCH and sent PROMPTs: max(last activity, sent) + `scratchArchiveDays`.
- `runRetention`: archives what is due (`status: archived`, `archived:`, `archivedBy: auto`; an unparsable note is skipped and logged), purges trash older than `trashPurgeDays` by handing the note file, `.codd/trash/assets/<id>/`, any `assets/<id>/` and `.codd/history/<id>/` to the injected `trash` closure (a failure of the note file keeps it), writes a tombstone, expires tombstones after `tombstoneDays` (nil = never), thins history. `purge(_:)` does the same for the TRASH list's explicit delete.

## Cleanup candidates (§3.4, D31)

One row per note (priority: SCRATCH, sent PROMPT, auto-archive within 7 days, near-duplicate, long note, stale), plus unused images. Texts are the Cleanup artboard's: `21 天未開啟` / `最後開啟 9/24` / `stale 21d` (never opened: `<n> 天未動` / `最後更新 M/dd`), `草稿 18 天未動` / `從未送出`, `已送出 7 天` / `送到 <session title>` / `archives in 0d`, `SCRATCH` / `快速筆記 7 天後自動封存` / `archives in 6d`, `27 天無活動` / `3 天後自動封存` / `archives in 3d`, `近似重複（與第 3 章 82% 相同）` / `對照「keynote 第 3 章大綱」` / `dup 82%`, `長期筆記 · 9 段超過 30 天` / `9/01–9/12 的段落` / `9 段 > 30d`, `未使用的圖片 · 2b7e04.png` / `unused 12d`. AI hints: `AI 2d 前讀取 → 建議保留` (an AI read within 7 days), `AI 9d 前讀取` (within 30), `適合濃縮` (duplicates), `適合濃縮舊段落` (long notes, `aiHintText`). Notes kept with `keep(until:)` are left out.

- Near-duplicate: trigram Jaccard of `body_text` ≥ 0.80 among active, unpinned notes of the same project (notes without a project form one group), at least 20 trigrams; candidates come from MinHash LSH (16 bands × 4 rows), then the exact value; reported once, on the older note (by `created`). The `<label>` is the part of the other title that differs (`第 3 章`), else the whole title in 「」.
- Long note: ≥ 3 H2 / H3 sections outside code whose heading starts with `2026-09-03`, `2026/09/03`, `9/03`, `09/03` or `9/3` older than 30 days (`datedSections(_:olderThanDays:)` gives them with UTF-16 ranges; a date without a year is this year, or last year when that is in the future).
- Unused image: a file in `assets/<id>/` (a `.orig` copy counts with its image) named neither in the body nor in a kept snapshot, mtime ≥ 7 days ago. Annotated copies are not assets (they live in `annotatedFolder`) and are never offered. These rows share their note's id: key rows by `rowKey`.

## History (D8)

A snapshot of the whole file after a save when the newest one is older than 5 minutes (also at creation), and forced (reason in the xattr) before an AI append (`ai-append`) / write (`ai-write`), a restore (`restore`), trash (`trash`) and through `snapshot(_:reason:)` (condense, applying an external change over a dirty editor). Identical bytes to the newest snapshot are skipped; files over 2 MiB are not snapshotted; at most 200 per note. Thinning at each retention run: everything for 48 h, the newest per hour for 14 days, the newest per local day for 90 days, nothing older. `snapshotText` returns the snapshot's body; `restoreSnapshot` replaces the body only (the current frontmatter, access and links stay).

## Images (D9, D10, D17)

- `saveAsset`: > 20 MiB refused (`.tooLarge`); PNG / JPEG / GIF / WebP kept as they are; TIFF and other ImageIO formats → PNG; HEIC / HEIF → JPEG (PNG with alpha); an EXIF rotation is applied; a long edge over `resizeLongEdge` is downscaled with high-quality interpolation, written as PNG (JPEG stays JPEG at 0.9). Name = the first 6 hex of the written bytes' SHA-256, lengthened by 2 while another file holds the name; identical bytes reuse the file. `keepOriginal` keeps the input as `<hash6>.orig.<ext>` when the written bytes differ. `AssetRef.markdownPath` is the link relative to the note's folder (`../assets/…` from a sub-folder).
- `annotatedImage`: `<annotatedFolder>/<hash12>-<stem>.annotated.png` (`<hash12>`: SHA-256 of the image's standardized path) when its `codd-annotations` block has items, never beside the image; the block JSON's SHA-256 rides in an xattr and the copy is regenerated when it differs (without the xattr: when the note is newer). The source path and the note id ride in xattrs too: `open()` removes copies whose image is gone or whose note is no longer indexed, files without the source xattr and temp leftovers; a removed copy is rendered again when needed.
- `AnnotatedImageRenderer`: amber (or the item's color) 3 px strokes with a black halo, 10 % fill for boxes, arrows with heads, numbered 28 px squares (box corner, point, arrow start), text items on a black plate; sizes scale with `max(1, longEdge / 1400)`; coordinates follow a resized file proportionally.
- `aiImage`: ≤ `maxLongEdge`, ≤ `maxBytes`: an image that fits goes unchanged (PNG / JPEG / WebP), otherwise PNG when it has alpha and fits, else JPEG at falling quality, then smaller.

## AI text (§3.7) and expansion (D19)

- `aiText(id, offset:, maxChars:)` (default page 12,000 characters, cut at a line break in the page's last fifth): `# <title>`, `codd://note/<id> · NOTE · #tags · updated yyyy-MM-dd HH:mm · AI READ` (`· ARCHIVED <date>`), `file: <absolute path>`, `links: session <title> · project <path>` (titles from `setSessionTitles`), a blank line, then the body without its H1. Image lines become `[image] <absolute path> (<w>×<h>)` per the block's send options (original and / or annotated copy), followed by `annotations（原圖像素，左上為原點）:` and the list when `list` is on; the block itself is dropped; other relative links become absolute (`<…>` when they contain a blank). `Rendered.images` lists the images on that page with what to attach. Annotated copies are generated first. Access rules are not checked here (the MCP backend applies them; the user may send any note).
- `NoteAIText.imagePreview` gives the same lines for the ImageAnnotate `AI 會收到` panel, home shown as `~`.
- `expansion(for:maxChars:)`: up to 5 distinct refs (each element a ref or text containing refs), `CODD 已展開使用者提到的筆記（不需要再呼叫 notes_read）：` then `<codd-note ref="codd://note/<id>" title="…">` + the AI text + `</codd-note>` per visible note, then one line per refused ref (`codd://note/<id> 無法展開（AI 存取為 OFF | 這則筆記在 CODD 垃圾桶 | 這則筆記已永久刪除 | 找不到這則筆記）`; an OFF note is never named). The total stays ≤ `maxChars`; a note that does not fit is cut with `…（內容過長已截斷；完整內容請用 notes_read 讀取 codd://note/<id>，或讀檔 <path>）`. `systemMessage`: `codd：已展開 codd://note/<id>（<title> · n 張圖片）`, `codd：已展開 2 則筆記（<title>、<title>）`, plus `codd：codd://note/<id> 無法展開（<reason>）` lines. `imageCounts` per note. The caller records the `expand` activity.
- `copyMarkdown`: the body without the frontmatter, image links absolute, annotation blocks kept.

## AI writes

`appendFromAI` (APPEND notes only; READ / OFF → `.accessDenied("這則筆記的 AI 存取是 READ，不能附加")` / `…OFF…`; ≤ 20,000 characters): the `OpenNoteCoordinator` flushes the editor first, a snapshot is taken, then `\n<!-- codd:ai-append session="<title>" at="<ISO>" -->\n### <heading or "AI 附加 · HH:mm">\n<markdown>\n` is appended, the frontmatter left as it is, `append` activity recorded. `replaceBodyFromAI` replaces everything after the H1 line (a repeated H1 at the top of the AI's text is dropped), `write` activity.

## Threading

- `NotesLibrary` is an actor. File IO and GRDB calls block inside it; long loops (index build, open-time update, retention) `await Task.yield()` between files so other calls interleave.
- FSEvents delivers on its own serial queue and hops into the actor through an ordered `AsyncStream`.
- `changes` (nonisolated) is single-consumer: each access returns a stream over one shared buffer. Pending entries coalesce newest-wins per id (`.changed` / `.external` / `.removed`), `.activity(id)` and `.indexRebuilt` dedupe, at most 1,024 are kept. `close()` ends it; a closed library is not reopened (make a new one).
- `OpenNoteCoordinator.flushPendingEdits` is awaited during an AI write; the actor is reentrant there, so the app's own `save` can run.

## API notes for the app

- `NotesLibrary(root:indexURL:annotatedFolder:policy:defaultAccess:clock:trash:log:timeZone:)` (the index and the annotated folder are derived data outside `root`; the app passes `<dataRoot>/cache/…`); `open()` creates the folders and the marker, builds or updates the index, starts the watcher, and reports `rebuilt`, `reason`, `count`, `buildMs`, `warnings` (unparsable frontmatter, duplicate ids).
- Extra entry points beyond the M4 plan's list: `setLiveSessions`, `setSessionTitles`, `snapshot(_:reason:)`, `purge(_:)`, `externalEventCount`, `NoteAIText.imagePreview`, `Frontmatter.set(_:bool:)`, `NoteReferences.forms(…, serverName:)`, `AssetRef.markdownPath` / `originalPath`, `NoteCleanupCandidate.title` / `aiHintText` / `rowKey`, `NoteAIText.Rendered.offset` / `totalChars`, `NoteAIText.Expansion.imageCounts`, and for condense (D32) `NewNote.idPrefix` (`cleanup-1015` → `cleanup-1015-xxxx`), `NewNote.condensedFrom`, `MetadataChange.condensedInto`, `NoteNaming.makeID(prefix:taken:)`.
- `ImageAnnotations.size` is a `PixelSize` (`[w, h]` integers in JSON); unknown keys at every level survive in `extra` and are written back sorted after the known ones.
- The log closure gets ids, counts and file names, never note text or tokens.
