# CoddFiles

The local file editor's model layer and chrome (M4 C6; plan D24–D27, D34, D35, §3.4).

| Target | What it is |
|---|---|
| `CoddFiles` | Foundation + CoreServices (FSEvents) only, no AppKit: read-only git, the lazy tree, text codecs, file / folder watching, the save rules, the open-tab state machine, line diffs, the recent / AI-touch stores. |
| `CoddFileEditorUI` | AppKit on CoddUI's public API: the FileEditor artboard's tree, tab strip, toolbar, disk banner, status items and dirty-close sheet over value models with closures (no CoddCore / App types). The code view is an `NSView` slot. |
| `codd-files-demo` | `--fonts <dir> --snapshot <dir>` renders the artboard composition offscreen at 1440 × 900 (`file-editor.png`, `file-editor@2x.png`, `dirty-close-sheet.png`, `banner-note.png`) and exits. It never activates. |

```sh
swift build --package-path Packages/CoddFiles --scratch-path .build-m4-files --build-tests
swift test  --package-path Packages/CoddFiles --scratch-path .build-m4-files
swift run   --package-path Packages/CoddFiles --scratch-path .build-m4-files codd-files-demo --fonts App/Fonts --snapshot <dir>
```

## Read-only git (`GitReader`, `GitReading`)

- Every run: `/usr/bin/git -C <folder> --no-optional-locks -c core.fsmonitor=false <sub> …`, stdin
  `/dev/null`, `posix_spawn` in a new session, killed with its process group at the timeout (5 s).
- Environment: the process environment minus every inherited `GIT_*` variable (a parent's `GIT_DIR`
  must not redirect the reader), plus `GitReader(environment:)` (tests pass `GIT_CONFIG_GLOBAL=<empty
  file>` and `GIT_CONFIG_NOSYSTEM=1`), plus `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`.
- Log line per run: `exec git path=<the -C folder, ~-abbreviated> sub=<subcommand>` (the path is the
  repository, so an e2e can check that git only ran in its temp folders).
- Calls: `repoRoot` (`rev-parse --show-toplevel`; nil outside a work tree), `status`
  (`status --porcelain=v2 --branch -z --untracked-files=all`, parsed without quoting issues: spaces,
  CJK and newlines in names), `headText` (`cat-file blob HEAD:<path>`: plumbing, no textconv, no
  filters, no pager; any non-zero exit = nil), `ignored` (`ls-files -o -i --exclude-standard
  --directory -z`, folders collapsed, trailing `/` removed), `trackedAndUntracked` (`ls-files -co
  --exclude-standard -z`, ⌘P). Only reading subcommands exist in the code.
- `GitRepoStatus.renamedFrom[new] = old`: a renamed file's HEAD text is at its old path.
- Proof in the tests: `.git/index` (inode, size, mtime ns) is unchanged after every call even when
  the index is stale (a plain `git status` in the same state rewrites it); a repository with
  `core.fsmonitor=true` gets no daemon socket; no git process is left.
- `status` paths are relative to `root`: always pass the `repoRoot` result.
- `StaticGitReader` is a fixed-value `GitReading` for mock mode (D35) and tests; it never runs git.

## Tree (`FileTreeModel`)

Names only (`readdir` + `d_type`; `lstat` only when the file system reports no type, `stat` only for
symlinks), folders first (links to folders count as folders), natural case- and width-insensitive
order, `.git` and `.DS_Store` never listed, ≤ 2,000 entries per folder followed by one `…` entry
(`isOverflow`, `overflowCount`). `isIgnored` covers entries inside an ignored folder. `walk()` (⌘P
outside git): depth-first in tree order, ≤ 20,000 files, ≤ 12 levels, `node_modules` / `.git`
skipped, symlinked folders never entered.

## Codec (`TextFileCodec`, `DecodedText`)

- Sizes: > 50 MiB → `.tooLarge` (`FileFingerprint.read` refuses before reading); > 5 MiB → `readOnly`.
- Detection: UTF-8 BOM, UTF-16 LE / BE BOM (must round-trip, no NUL), then NUL in the first 8 KB →
  `.binary`, valid UTF-8, Big5 (code page 950; only when not UTF-8, it decodes and encodes back to
  the same bytes), else Latin-1 (`readOnly`).
- `text` is LF-normalized and excludes the final terminator (`a⏎b⏎` → `"a\nb"`,
  `hasFinalNewline`); `lineEnding` is the majority (ties LF, CRLF, CR); `lineEndings` per line only
  when mixed; `indentation` is VS Code's guess (tabs, or the most common positive step).
- `encode(_:like:)` writes back the encoding, BOM, final newline and endings. Mixed files: unchanged
  lines (matched with `LineDiff`) keep their own terminator, a replaced line keeps the terminator of
  the line it replaces (pairwise inside a hunk), added lines take the majority. Characters the
  encoding cannot hold → `.unencodable`. Unchanged text → byte-identical output (tested for UTF-8,
  BOM, UTF-16 LE / BE, Big5 `發票匯出`, Latin-1, CR, CRLF, mixed, no final newline).
- HEAD blobs are raw (no `core.autocrlf` conversion): decode them with the same codec and compare
  `text`, never bytes.

## Watching

- `FileWatch(url:)`: a vnode `DispatchSource` per open file (write, extend, delete, rename, attrib,
  link, revoke). After an atomic replace (or delete + recreate) it reopens the path; while nothing is
  at the path it watches the parent folder. 100 ms coalescing, one event per window decided by the
  final state: `deleted` / `renamed` (path empty), `modified`, `attributes`.
- `DirectoryWatcher(root:latency:)`: FSEvents with file events; each batch = deduplicated
  root-relative paths (both the given and the resolved root spelling are stripped). `.git/` changes
  are included. Both streams are for one consumer; `cancel()` finishes them.

## Saving (`FileSaver`, `FileFingerprint`)

Only an explicit ⌘S or the dirty-close sheet's 儲存 calls `save`.
- Symlinks are written through to their fully resolved target (the link stays).
- Normal: temp file in the same folder, original ACL + xattrs copied (`fcopyfile`
  `COPYFILE_ACL | COPYFILE_XATTR`), mode via `fchmod`, hidden flag kept, `F_FULLFSYNC`, `rename`.
  `COPYFILE_STAT` is not used (it would copy the old mtime).
- In place (write from offset 0, `ftruncate`, `F_FULLFSYNC`): more than one hard link, another owner,
  or a folder where no temp file can be created.
- No write permission → `.readOnly` (`這個檔案是唯讀的`); not a regular file → `.notAFile`.
- `expected` vs current contents (size + SHA-256) → `.changedOnDisk(current:)` unless `force`. A
  `touch` or an identical rewrite is not a conflict. A missing file is created (mode 0666 & ~umask).

## Open tab (`OpenFileState`)

`load` → `edit` → `diskChanged(newData:fingerprint:aiTouch:)` → `.none` (same contents, also a change
back to the base, which clears the banner) / `.reloaded` (clean) / `.banner(aiSession:at:)` (dirty;
the new version waits in `pendingDisk`). An attributed change keeps the text before it as
`aiBaseline` (memory only; later changes by the same session keep the first). `keepMine` makes the
disk version the base the next save is checked against, `reloadFromDisk` takes it, `saved` records a
save (and refreshes a mixed file's endings to what was written). `encodedBuffer()` = the bytes ⌘S
writes. The ±10 s AI attribution window is the caller's (`AITouchLog.latest`).

## Diff (`LineDiff`)

Myers O(ND), linear space (diff-match-patch's middle-snake bisection) after trimming common prefix
and suffix; deterministic; a work budget (~5·10⁷ steps per bisection) turns pathological regions
into one replace hunk. `hunks(old:new:context:)`, `reverting(_:in:)` (only that hunk's region),
`unifiedHeader` (git's form, `@@ -40,2 +40,4 @@`).

## Stores (§3.4)

`files/recent.json` (`RecentFilesStore`: ≤ 20, newest first, 30-day expiry) and
`files/ai-touches.json` (`AITouchLog`: 7 days, ≤ 2,000 newest, debounced save, `flush()`):
`{"v":1,"items":[…]}`, dates as JavaScript ISO strings with milliseconds, 0600 files in a 0700
folder, atomic writes, a corrupt file renamed to `<name>.corrupt-<ms>` and started over, a newer `v`
read but never written. Both are thread-safe (`Mutex`); file I/O is synchronous, so call them off the
main actor.

## UI (`CoddFileEditorUI`)

| View | Model | Callbacks |
|---|---|---|
| `FileTreeView` (264 pt) | `FileTreeModelView` (`FileTreeRow`, `FileTreeGitHead`, `FileTreeSessionLine`, `AIChip`) | `onOpen(id, preview)`, `onToggle`, `onFilter` (never while 注音 composes), `onFilterCommand`, `onCollapseAll`, `onToggleSection`; `focusFilter()` |
| `EditorTabStripView` | `EditorTabStripModel` (`EditorTab`, `EditorSessionPill`) | `onSelect`, `onClose`, `onPin` (double click), `onOpenSession`, `onMore` |
| `EditorToolbarView` | `EditorToolbarModel` (`EditorCrumb`, `baselineTitles`) | `onCrumb`, `onPreviousChange`, `onNextChange`, `onShowAIChanges`, `onBaseline`, `onFind` |
| `DiskChangeBannerView` | `DiskChangeBannerModel` (`fileChanged`, `noteChanged` for D7) | `onReload`, `onKeepMine`, `onCompare` |
| `EditorStatusItemsView` | `EditorStatusModel` (`init(decoded:…)` gives `CRLF*`) | `onItem(EditorStatusItem)` |
| `DirtyCloseSheetView` | the file name | `onChoice(.save / .discard / .cancel)`; ⏎ / ⎋ / ⌘D |

Disabled in M4 with tooltips: 新增檔案 (`新增檔案（之後提供）`), 分割編輯器 (`分割編輯器（之後提供）`).
`FileEditorSamples` holds the artboard data; `FileEditorComposition` lays the views out like the
artboard (rail placeholder, code-view slot); `FileEditorSnapshot` renders offscreen in sRGB.
Rows and tabs are custom-drawn (only visible rows are drawn); labels with CJK text use `DrawnLabel`
(measured and drawn with the same `Draw` calls, so they are never cut short).

Accessibility (M5 D21): the tree is an AX list of row elements (name, folder state, modified, AI,
the open file selected) and, under Full Keyboard Access, a key view: ↑ ↓ move a cursor, ⏎ opens a
file (a kept tab) or folds a folder / section, space opens a preview, → ← expand and collapse. The
tabs are tab buttons with a `關閉` action (← → on the focused strip select the neighbour); crumbs
and status items are buttons / links with a ← → cursor; the icon buttons, the selects and the
session pill take focus with CoddUI's `KeyboardFocus` rules. `AccessibilityAuditTests` audits the
composition, each part and the dirty-close sheet.
