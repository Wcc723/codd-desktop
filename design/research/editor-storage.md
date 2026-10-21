# CODD Desktop Notebook: editor and storage recommendation

**Decisions:**
- **Editor:** use CodeMirror 6 for both modes, with two configurations ("profiles"). Don't add Monaco or a WYSIWYG editor.
- **Storage:** notes are plain `.md` files with YAML frontmatter, and those files are the real data. SQLite only holds a search index (FTS5 with the trigram tokenizer) and app-only metadata, so it can be deleted and rebuilt.
- **Images:** each note gets its own assets folder, and image files are named by a hash of their content. Notes use standard relative Markdown links.
- **AI access:** an MCP server provides tools plus `note://{id}` resources. Every note gets three "copy for AI" handles: an `@codd:note://…` mention, a stable file path, and a token-protected `127.0.0.1` URL.
- **History:** use built-in snapshots that get thinned over time, like VS Code's Local History. Don't use git.

No files were modified.

---

## 0. What to reuse from the CODD web app

| Pattern | Where | Reuse it for |
|---|---|---|
| MCP tool table, a `Map` lookup, and a JSON text result | `apps/mcp/src/index.js:27-209`, `:211`, `:222-236` | Notebook tools. Today the server only declares `tools` (`:213-216`) and exits when `CHANNEL_PATH` is missing (`:18-21`). That env var must become optional, and a `resources` capability must be added. The installed SDK is `^1.0.4` (`apps/mcp/package.json`); the latest is 1.32.1. |
| `gray-matter` parsing, plus atomic tmp-file-then-rename writes | `apps/server/src/services/channel-reader.js:4`, `:361-374`, `:376-390` | Note save. Change the conflict check from mtime with a 5 ms tolerance (`:364`) to a content-hash check, because mtime is unreliable under iCloud and sync tools. **Gotcha:** `matter.stringify` (`:386`) re-serializes YAML, which turns dates into `Date` objects and loses formatting. Don't round-trip frontmatter through it. Let CodeMirror edit the raw text, and patch individual keys with the `yaml` package's Document API, which keeps formatting. |
| Binary sniffing (a NUL byte in the first 8 KB) and a size cap | `channel-reader.js:7-14`, `:169-172` | File mode guards. |
| Path-traversal and realpath containment checks | `channel-reader.js:139-166` | Anything exposed over MCP or the local URL. |
| Recursive walk with a depth guard | `channel-reader.js:115-134` | Fallback file tree when the folder isn't a git repo. |
| Safe Markdown rendering (markdown-it with `html:false`, plus DOMPurify) | `apps/web/src/components/MarkdownView.vue:6-18` | Reading view and the hover preview of a note. |
| Sending text to a session: multi-line text wrapped in bracketed-paste markers, then Enter after `SUBMIT_DELAY_MS=60` | `apps/web/src/views/SessionDetail.vue:17`, `:227-238` → `POST /:id/input` (`apps/server/src/routes/sessions.js:163-181`) → `terminal.write` (`services/terminal-manager.js:138-143`) | "Send to session". |
| PreToolUse/PostToolUse hook keyed by `CODD_TERMINAL_ID` | `configs/hooks/status-writer.js:148-158`, `:186` | Tracking which files the AI touched. The comment at `:99` confirms that child processes inherit `CODD_TERMINAL_ID`, so the MCP server can tell which session called it. |
| Current editors are just `<textarea>`s | `SkillEditor.vue:305`, `ResourceEditor.vue:55-59` | Replace them with the same CodeMirror component, so one editor serves the whole app. |

---

## 1. Editor engine

| | Notes (a): live preview, paste images | Files (b): VS Code-like editing | Size | CJK input (IME) evidence | Vim mode | Markdown fidelity |
|---|---|---|---|---|---|---|
| **CodeMirror 6** | Good. Obsidian's Live Preview runs on CodeMirror 6 (Obsidian 0.13.8 changelog). You build it from decorations. | Good: lazy-loaded languages (`@codemirror/language-data`), search and replace (`@codemirror/search` 6.7.2), diff view (`@codemirror/merge` 6.12.2). No IntelliSense. | view ≈79 KB gzip; markdown support with dependencies ≈175 KB gzip (bundlephobia) | Fixed actively. `@codemirror/view` 6.43.14 shipped 2026-10-07, and there are dozens of composition fixes in 2025–26, including Safari and composition next to widgets or decorations. | `@replit/codemirror-vim` 6.4.0 (2026-07) | Byte-exact: it edits the text itself |
| Monaco | Poor: no inline rendering, so it needs a split preview | Best VS Code parity: tab models, find widget, diff editor, TS/JSON IntelliSense | Replit measured ≈5 MB gzip with languages; Sourcegraph measured 2.4 MB; web workers need setup | Mature in Chromium (VS Code has an IME test plan). I found no evidence either way for WKWebView. | `monaco-vim` 0.4.4 (2025-11) | Byte-exact |
| Milkdown Crepe | WYSIWYG, polished | No | ≈461 KB gzip | Built on ProseMirror, which has a long record of Safari CJK composition bugs | No | Rebuilds the Markdown from a document tree, so saving reformats the file |
| TipTap + `@tiptap/markdown` | WYSIWYG | No | core ≈37 KB gzip plus extensions | Same ProseMirror history | No | The official Markdown extension is labelled an "early release" with edge cases |
| Vditor 4 | Typora-style instant rendering, CJK-oriented | No | 23.6 MB unpacked, because it bundles its own Markdown engine | Not verified | No | Uses its own engine; not Vue-native |
| Toast UI | — | — | — | — | — | Last published 2023-02-17. Exclude it. |

**Recommendation: CodeMirror 6 for both modes.**
1. **One engine means one IME test matrix,** one keymap and theme, one undo model, and one diff component. A Monaco plus CodeMirror pair would double the IME testing and add about 5 MB plus worker setup, mainly for IntelliSense. In CODD the AI writes the code; the editor is for reviewing and small edits.
2. **It never rewrites what you didn't touch.** WYSIWYG editors rebuild the Markdown on save. That creates diff noise in `CLAUDE.md` and `SKILL.md`, and in notes the AI or git also reads.
3. **Live preview is proven here.** Obsidian ships it on CodeMirror 6.
4. **Monaco stays an escape hatch.** If you ever want IntelliSense, lazy-load it only for an "Open in advanced editor" command.

**Notebook profile:**
- GFM Markdown, with code-block languages loaded from `language-data`.
- A custom live-preview plugin: hide `**`, `#` and similar marks on lines without the cursor, size headings, show images as block widgets under their line, render task checkboxes, and make links ⌘-clickable.
- Image paste and drop handlers.
- `@` autocomplete for linking notes, sessions and projects.
- Reading view uses `MarkdownView.vue`.

**File profile:**
- Line numbers, code folding, ⌘F / ⌘⌥F search, bracket matching, whitespace display.
- Language picked from the filename (`LanguageDescription.matchFilename`).
- Optional vim mode and merge (diff) view.
- **Preserve line endings:** CodeMirror converts line breaks to `\n` unless the `EditorState.lineSeparator` facet is set. Detect CRLF and set it, and keep the BOM and the final newline.

**IME rules (non-negotiable for Traditional Chinese):**
1. **Never change the document or decorations from outside during composition.** While `view.composing` is true, defer autosave, live-preview recomputes, and reloads from disk until `compositionend`. The 2026 CodeMirror fixes cluster exactly here: 6.39.9 and 6.39.10 (composition next to widgets) and 6.39.16 (decoration changes just before a composition). Pin `@codemirror/view` to ≥6.43.14 and keep it current.
2. **Don't bind CodeMirror with `v-model`.** CodeMirror owns the text; send changes out with a ~400 ms debounce, only when not composing.
3. **Check composition before acting on keys.** Enter and Space confirm candidates in Zhuyin, so every custom key handler (list continuation, ⌘↩ "Send") must check `event.isComposing` or keyCode 229.
4. **Vim is off by default in notes.** In normal mode an active IME can swallow keys; Zed fixed the same problem natively.
5. **Test matrix:**
   - Input methods: Apple Zhuyin, Cangjie, Sucheng, McBopomofo, Natural Input.
   - Engines: whichever the shell uses, WKWebView (Tauri) or Chromium (Electron).
   - Scenarios: base them on VS Code's IME Test wiki.
   - Known Chromium issue: Chrome 149 drops alternate Chinese punctuation keypresses (Chromium issue 521205128). It's a browser bug, not a CodeMirror bug, but it matters if the shell is Electron.

---

## 2. Image paste

- **Capture:**
  - Use CodeMirror `domEventHandlers({paste, drop})` and read `clipboardData.files` or `dataTransfer.files`.
  - For drops from Finder, prefer the native path so large files aren't copied through JavaScript: Tauri `DragDropEvent` paths, or Electron `webUtils.getPathForFile`. (Tauri's `dragDropEnabled` defaults to true; only Windows needs it off for HTML5 drag and drop.)
  - Insert a placeholder `![上傳中…]()` and swap it for the real link when the write finishes.
- **Store:**
  - Path: `assets/<note-id>/<sha256[:16]>.<ext>`. Hash the final processed bytes; if the file already exists, skip the write.
  - **Why per-note folders and not one shared, deduplicated store:** deleting, exporting and trashing a note stays self-contained, and nothing needs cross-note reference counting. If an image is pasted from one note into another, copy the file.
- **Limits and processing:**
  - Reject files over 20 MB.
  - Downscale screenshots to a long edge of ≤2576 px. That is Claude's high-resolution maximum; anything larger is downscaled by the API anyway, which only wastes disk and tokens.
  - Offer a "keep originals" setting.
  - Formats: PNG, JPEG, GIF, WebP. Claude reads only the first frame of a GIF.
- **Link syntax:** standard relative `![截圖 2026-10-15 09:32](assets/<id>/<hash>.png)`, not `![[wikilinks]]`. Claude Code's Read tool, Obsidian, VS Code and GitHub all resolve it.
- **Rendering:**
  - Keep `src` relative in the file. Rewrite it at render time, in a markdown-it image rule, to the app's asset protocol (Tauri `convertFileSrc` or a custom `codd-asset:` scheme).
  - DOMPurify's default `ALLOWED_URI_REGEXP` strips unknown schemes. Extend it with that one scheme only, and never set `ALLOW_UNKNOWN_PROTOCOLS`.
- **Cleaning up unused images (nightly, at idle):** delete a file in `assets/<id>/` only when all of these hold:
  - the current note body doesn't reference it;
  - no snapshot inside the retention window references it, so restoring old versions still works;
  - it is older than 7 days.

  Purging a note from the trash deletes its whole assets folder. The info panel shows something like "Assets 12 MB · 3 unused".

---

## 3. Storage

**Files are the real data; SQLite is a rebuildable index.**
- The AI can `Read` a note by path even when CODD isn't running.
- Obsidian, VS Code, git, Time Machine and iCloud all keep working.
- The MCP server stays stateless.
- Storing everything in SQLite would break the core requirement that you can paste a path and the AI reads it.

### Folder layout
```
~/.codd/notebook/                       ← notes folder (relocatable: iCloud Drive / Obsidian vault subfolder)
├── 2026-10-15-登入流程想法.md            ← flat; filename set at creation, NEVER auto-renamed (pasted paths stay valid)
├── 2026-10-15-給-session-的-prompt.md
├── assets/<note-id>/<sha16>.png
├── .trash/                             ← soft-deleted notes + their assets (30 d)
└── .codd-notebook.json                 ← {version, rootId} marker
~/Library/Application Support/CODD/
├── codd.db                             ← app DB + notebook index + history (WAL). Never in a synced folder.
└── history/<sha>.zst                   ← snapshot blobs, if not stored in the DB
```
- **Location:** the default has no spaces, so pasted paths and shell commands need no quoting, and it sits next to `~/.claude`. The app offers "Reveal in Finder" because Finder hides dot-folders.
- **Filenames:** NFC-normalize them.

### Frontmatter (stays in the file, travels with it, visible to the AI)
```yaml
---
id: 01JA2Z9K8QW3E5R7T9Y1U3I5O7     # ULID, never changes; key for MCP and URLs
title: 登入流程想法                   # editing it does not rename the file
created: 2026-10-15T09:32:10+08:00
updated: 2026-10-15T10:05:44+08:00  # app writes it on save; if another editor skips it, use mtime
kind: note                           # note | prompt | scratch
tags: [auth, idea]                   # Obsidian built-in list property
pinned: false
ai: read                             # hidden | read | write
projects: [~/GitHub/codd-web]
sessions: [codd:7c1e…]               # CODD session id (survives /clear)
expires: 2026-11-15                  # optional; used by the cleanup rules
status: active                       # active | archived
---
```
**Only in the database, never in the file:** `last_opened_at`, open count, send log, snapshots, asset sizes, content hash, and the AI-touch log. Opening a note must not rewrite it, because a rewrite triggers iCloud uploads, file-watcher loops and git noise.

### SQLite schema
```sql
CREATE TABLE notes(id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT, kind TEXT, status TEXT,
  ai TEXT, pinned INT, created_at TEXT, updated_at TEXT, expires_at TEXT,
  mtime_ms REAL, size INT, content_hash TEXT, last_opened_at TEXT, open_count INT DEFAULT 0);
CREATE TABLE note_tags(note_id TEXT, tag TEXT, PRIMARY KEY(note_id, tag));
CREATE TABLE note_links(note_id TEXT, target_type TEXT CHECK(target_type IN('project','session','note','file')),
  target TEXT, PRIMARY KEY(note_id, target_type, target));        -- derived from frontmatter
CREATE TABLE note_sends(id INTEGER PRIMARY KEY, note_id TEXT, session_id TEXT, sent_at TEXT, mode TEXT, snapshot_hash TEXT);
CREATE TABLE snapshots(id INTEGER PRIMARY KEY, subject TEXT, -- 'note:<id>' | 'file:<abs path>'
  taken_at TEXT, reason TEXT, blob_hash TEXT, bytes INT);
CREATE TABLE note_assets(note_id TEXT, hash TEXT, ext TEXT, bytes INT, w INT, h INT, created_at TEXT, PRIMARY KEY(note_id, hash));
CREATE TABLE recent_files(project TEXT, path TEXT, opened_at TEXT, source TEXT, -- user | ai:<session>
  PRIMARY KEY(project, path));
CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, tags, tokenize='trigram');
```

**Search for Chinese text:**
- The default `unicode61` tokenizer treats a whole run of Chinese characters as one token, so it can't find words inside a sentence. Use `trigram` instead: it matches any substring and indexes `LIKE '%…%'`.
- Queries shorter than 3 characters, such as "登入", fall back to a linear scan. That still returns the right results, and it's instant at notebook scale. So always query with `LIKE`.
- better-sqlite3 bundles SQLite 3.53.4 with FTS5 enabled; trigram has existed since SQLite 3.34.0.
- I'd skip a jieba-based tokenizer (`wangfenjin/simple`) for v1: it's a native extension you'd have to build and sign for each architecture.

### Version history and undo
- **Undo:** CodeMirror's in-memory history for each open tab. Keep each tab's `EditorState` when switching tabs.
- **Snapshots, modelled on VS Code Local History** (defaults there: an entry per save, a 10 s merge window, 50 entries per file, 256 KB maximum file size):
  - Notes: take a snapshot on save, merging saves within 5 minutes.
  - Forced snapshots before applying an external change, an AI write over MCP, Send, delete, and restore.
  - Thinning: keep everything for 48 h, then hourly for 14 days, then daily for 90 days.
  - Blobs are compressed and stored by hash.
  - The same mechanism covers project files saved from CODD (256 KB cap).
- **Not git:** a user's vault may already use git, nested repos clash, and commit noise is annoying. The folder is plain, so users can add git themselves.

### Watching for outside edits
- **Notes folder:** watch it recursively with `@parcel/watcher` (FSEvents, merges bursts of events) or chokidar 5 (ESM-only, Node ≥20.19).
- **Project trees:** watch only expanded folders and open files. VS Code's docs warn that recursive watching is resource-intensive.
- **Ignore your own writes** by remembering the last-written `{path → hash}`.
- **Conflicts:**
  - Clean editor: reload in place with a minimal diff, which keeps the cursor and undo history.
  - Unsaved edits: show a banner with **Reload / Keep mine / Compare**, where Compare opens the merge view.
- **On startup:** re-parse files whose `(mtime, size)` changed. Settings has a "Rebuild index" command.

### Backup, iCloud and Obsidian
- **Notebook location setting:** Local (default; Time Machine covers it), iCloud Drive, or a custom folder such as `<vault>/CODD/`. Moving copies the files, verifies them, then switches, and keeps the old copy as a backup.
- **iCloud caveats:**
  - Files evicted by "Optimize Mac Storage" are placeholders until downloaded. The indexer must not block on them.
  - When two Macs edit the same note, iCloud creates conflict copies. Detect a duplicate `id` and show a "Conflict copy" view.
  - **The database never lives in iCloud.** sqlite.org warns that sync and network filesystems can corrupt databases.
- **Obsidian compatibility:**
  - Obsidian ignores dot-folders.
  - `tags` is one of Obsidian's built-in list properties.
  - Obsidian stores date properties as `YYYY-MM-DD` and date-times as `YYYY-MM-DDTHH:mm:ss`.
  - Obsidian resolves relative Markdown links.
  - Per-note asset folders work like Obsidian's "In subfolder under current folder" attachment setting.

---

## 4. Opening local files

- **Ways in:**
  - A **Files** button in the session header opens a tree rooted at the session's working directory.
  - ⌘P quick open.
  - Open file… for any path.
  - Drop a file from Finder.
  - **Click a `path:line:col` in the terminal output.** Add an xterm link provider for this; Claude prints these constantly.
- **Tree:**
  - In a git repo, list files with `git ls-files -co --exclude-standard`: it respects `.gitignore` and is fast. Otherwise use the depth-guarded walker.
  - Badges: `M` for git-modified, and `AI` (in the session's colour) for files the AI touched in the last N hours.
- **Tabs, VS Code style:**
  - A single click opens a preview tab (italic), which the next single click replaces. Editing or double-clicking pins it.
  - Dirty dot, ⌘S, and a prompt on ⌘W.
  - Open tabs are restored per project.
- **Guards:**
  - NUL-byte sniffing for binaries: preview images, mark everything else as binary.
  - Over 5 MB: read-only large-file mode. Over 50 MB: refuse to open.
  - UTF-8 only in v1; preserve CRLF line endings and the BOM.
- **Recent files:** `recent_files` rows from both what you opened and what the AI touched, shown as a "Recent" section under each project in the sidebar.
- **Files the AI edited:**
  - Extend the `PostToolUse` branch of the hook (`status-writer.js:154`) to append `{ts, tool_use_id, tool, file_path}` for Edit, Write, MultiEdit and NotebookEdit to `term/<id>.files.jsonl`. `tool_input.file_path` is always absolute, per the hooks docs.
  - Optionally, in `PreToolUse` (`:148`), copy the file's current contents (≤1 MB) into a hash-named store. That gives a diff for each tool call even outside git.
  - **Edit/Write hooks don't fire when the AI changes files with `Bash`.** So also show `git status`, or use the `FileChanged` hook.
- **Diffs:**
  - A "Show AI changes" toggle in the file tab uses `@codemirror/merge`'s `unifiedMergeView`: inline red/green with a revert button for each chunk.
  - `MergeView` (side by side) handles conflicts.
  - The baseline is git `HEAD`, or the pre-edit snapshot when there is no git.
- **Out of scope for v1:** language servers, cross-file search and replace (could come later with ripgrep), and a full source-control panel.

---

## 5. Linking notes to sessions and projects, and "Send to session"

- **Linking:**
  - ⌘⇧N or the menu bar "Quick note" while a session is focused links the new note to that session and its project automatically. A "Link to…" picker covers the rest.
  - Links live in frontmatter (so the AI sees the context) and are mirrored into `note_links`.
  - Projects are keyed by path written with `~`. Sessions are keyed by CODD session id; if a session ends, the link stays and its chip shows "ended".
- **Session view:** a "Notes (3)" pill in the header opens a drawer with linked notes, project notes, and "New note for this session".
- **Prompt drafts (`kind: prompt`):** the editor footer has a session picker (defaulting to the linked session) and three actions:
  - **Insert**: paste only, so you can review it in the terminal.
  - **Send**: paste, then Enter.
  - **Send selection**.

  All three reuse the bracketed-paste path in `SessionDetail.vue:227-238`.
  - **Images:** rewrite relative image links to absolute paths before sending. Claude Code reads image paths it is given ("Provide an image path to Claude").
  - **Long notes:** "send as reference" (`請讀取 @codd:note://01JA…`) instead of the full text. I haven't verified that an `@` mention typed into the terminal gets resolved; test it.
  - **Safety:** block Send while the hook reports `state=waiting`, because pasted text could answer a permission prompt. Warn while the session is `busy`.
  - **Afterwards:** log a `note_sends` row, show "Sent to ‹session› 10:42", and offer "archive after send".

---

## 6. AI access: MCP and the "local URL"

**MCP tools** (same table pattern as today; never expose `ai: hidden` notes):

| Tool | Behaviour |
|---|---|
| `notes_search {query, tags?, project?, limit≤20}` | Returns id, title, snippet, updated, path, tags. |
| `notes_list {project?, session?: 'current'\|id, kind?, pinned?}` | `'current'` reads the `CODD_TERMINAL_ID` env var, so "my notes for this session" needs no arguments. Check that Claude Code passes the env through to stdio MCP servers; the hook comment at `:99` shows child processes inherit it. |
| `notes_get {id, images: 'none'\|'paths'\|'inline'}` | Returns frontmatter and body. `inline` attaches images downscaled to ≤1568 px (about 1.5k tokens each) and caps the total under `MAX_MCP_OUTPUT_TOKENS`. Claude Code's default is 25k tokens and it warns at 10k. |
| `notes_create {title, body, tags, link_current_session?}` | Writes `created_by: ai` into a new note. |
| `notes_append {id, text}` | Only for notes with `ai: write`. Takes a snapshot first. There is no delete over MCP. |

**Resources:** a `note://{id}` template, plus pinned and recent notes listed. Install with `claude mcp add --scope user codd -- node …/codd-mcp.js`; the mention prefix (`@codd:`) is this configured name. Claude Code then shows notes in `@` autocomplete as `@codd:note://…` and attaches them automatically when mentioned.

**"Copy for AI" menu, with three handles:**
1. `@codd:note://01JA2Z9K`: best inside Claude Code.
2. `~/.codd/notebook/2026-10-15-登入流程想法.md`: works with any CLI agent, and stays valid because files are never renamed. Claude Code asks permission to read outside its working directories, so CODD should launch sessions with `--add-dir ~/.codd/notebook` (or set `additionalDirectories`).
3. `http://127.0.0.1:<port>/n/<id>.md?t=<token>`: for browsers and other tools.
   - Bind to 127.0.0.1 only and require the token.
   - Serve `text/markdown; charset=utf-8`.
   - **Claude Code's WebFetch can't fetch localhost**, so tell the AI to use `curl` with this URL. That makes the file path and MCP handles the main ones.

---

## 7. Removing old content (options to discuss)

- **A. Manual, with nudges (suggested default).**
  - A "Stale" smart list: not pinned, and not opened or edited in 60 days.
  - A weekly menu bar nudge.
  - Per-note actions: Archive, Delete, or Keep (which sets `expires` +90 d).
- **B. Rules.** These only ever archive; nothing auto-deletes.
  - A `prompt` that was sent: archive after 7 days.
  - An untouched `scratch` note: archive after 14 days.
  - `expires` reached: archive.
- **C. AI compaction.** "Summarize & archive": a `notes_stale_candidates` tool, or a session, writes a digest note that links to the originals, and the originals get archived.
- **Lifecycle:** active → archived (still searchable) → `.trash/` (30 days, restorable) → purge (note, assets and snapshots).
  - One nightly maintenance job runs snapshot thinning, unused-image cleanup and trash purge.
  - Settings shows storage usage.
- **Questions for you:**
  - Should archived notes stay visible to the AI?
  - Should anything ever be deleted automatically?

---

## 8. Screens to design

1. **Notebook main view:**
   - List: Inbox, Pinned, Prompts, By project, Stale, Archive.
   - Live-preview editor.
   - Info panel: links, tags, AI visibility, assets, history.
2. Prompt footer: session picker, Insert, Send.
3. Notes drawer in the session view.
4. File mode: tree, tabs, AI-changes toggle, conflict banner.
5. History timeline with diff and restore.
6. Copy-for-AI menu.
7. Stale-notes review sheet.
8. Settings: notebook location, image policy, cleanup rules, MCP install snippet.

---

## Sources
- CodeMirror changelog (composition, Safari, 6.43.14): https://codemirror.net/docs/changelog/
- Chrome Chinese-punctuation IME bug thread: https://discuss.codemirror.net/t/chinese-ime-punctuation-input-loses-every-other-keypress-requires-2-presses-per-character/9741
- Obsidian 0.13.8 (Live Preview on CodeMirror 6): https://obsidian.md/bn/changelog/2021-12-09-desktop-v0.13.8/ · Properties: https://obsidian.md/help/properties · Attachments: https://obsidian.md/help/attachments
- Monaco vs CodeMirror sizes: https://blog.repl.it/codemirror · https://sourcegraph.com/blog/migrating-monaco-codemirror
- VS Code IME test plan: https://github.com/Microsoft/vscode/wiki/IME-Test · Local History (1.66): https://code.visualstudio.com/updates/v1_66
- ProseMirror Safari CJK issues: https://discuss.prosemirror.net/t/ime-composing-problems-on-td-or-th-element-in-safari-browser/4501 · https://discuss.prosemirror.net/t/chinese-ime-not-work-fine-in-safari-when-use-marks/2090
- TipTap Markdown (early release): https://tiptap.dev/docs/editor/markdown
- Zed vim/IME fix: https://git.secluded.site/zed/commit/ddc327fe035beb690d52a55c0d7645f0def233b8
- SQLite FTS5 (trigram, external content): https://www.sqlite.org/fts5.html · 3.34.0 release log: https://sqlite.org/releaselog/3_34_0.html · Over a network: https://www.sqlite.org/useovernet.html · better-sqlite3 build: https://github.com/WiseLibs/better-sqlite3/blob/master/docs/compilation.md
- Chinese tokenizer option: https://github.com/wangfenjin/simple
- Claude Code MCP (resources and @ mentions, output limits, scopes): https://code.claude.com/docs/en/mcp · Hooks (PostToolUse input, FileChanged): https://code.claude.com/docs/en/hooks · Permissions (working dirs, `--add-dir`): https://code.claude.com/docs/en/permissions · Images by path: https://code.claude.com/docs/en/common-workflows
- WebFetch can't open localhost: https://claudeissues.com/issue/7722-bug-update-fetch-tool-docstring-to-indicate-that-it-cannot-open-localhost-urls
- MCP resources spec: https://modelcontextprotocol.io/specification/latest/server/resources
- Claude vision limits (2576 / 1568 px, formats): https://platform.claude.com/docs/en/build-with-claude/vision
- DOMPurify URI allow-list: https://github.com/cure53/DOMPurify
- Tauri `dragDropEnabled`: https://v2.tauri.app/reference/config/
- @parcel/watcher: https://github.com/parcel-bundler/watcher · chokidar 5: https://newreleases.io/project/npm/chokidar/release/5.0.0
- Package versions (npm registry, 2026-10-15): `@codemirror/view` 6.43.14, `@codemirror/merge` 6.12.2, `@replit/codemirror-vim` 6.4.0, `monaco-editor` 0.57.0, `@milkdown/crepe` 7.22.3, `@tiptap/markdown` 3.32.0, `@toast-ui/editor` 3.2.2 (2023-02-17), `vditor` 4.0.0, `@modelcontextprotocol/sdk` 1.32.1
- Bundle sizes: bundlephobia.com API