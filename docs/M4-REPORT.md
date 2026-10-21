# CODD Desktop: M4 report

Written 2026-10-18 after integration step I4b (end to end, docs, this report). M4 = notebook, file
editor, MCP, cleanup (docs/M4-PLAN.md): CODD has its own notebook (Markdown files with their pasted,
annotated images in `<dataRoot>/notes/`, a derived index that also finds 繁體中文), a local file editor
with git badges, AI-touched files and SHOW AI CHANGES, and an MCP server on the hook port so every
CODD claude session can search, read and (where a note allows it) append to notes; `codd://note/<id>`
in a prompt is expanded by CODD's UserPromptSubmit hook. Retention moves old notes and stopped
sessions out of the way (reversibly), the Cleanup page offers bulk actions and 交給 Claude 濃縮, and a
Monday digest says when there is something to clean. The user's feedback on the M3 build (mouse drag
reorder, Finder folders as projects, interface zoom, layout at small sizes, an icon, the CODD name) is
part of this milestone. This report covers the twelve components (C1–C12), the seven integration
steps (I1a–I4b) and the three user-feedback steps, how to run everything, the numbers, what is not
done, and what you should try by hand.

**Status (read this first):**
- **Fix round 1 (2026-10-18, §12):** the first full test run and the review found 21 problems (six
  failing suites or scripts, fifteen code problems). Round 1 fixed every one of them; §12 has the
  table (cause, fix, regression test) and the results of the re-runs. The paragraphs below describe
  the state before that run and are kept as written.
- **Built, compiled, not yet tested as a whole.** The user asked for each stage to be finished before
  anything is tested or reviewed, so from integration step I2a on (I2a, I2b, I3, I4a, the three
  user-feedback steps and this step I4b) the steps only compiled. One test run after this step runs
  everything (every package suite, the app tests, `scripts/m4-e2e.sh` twice, the older e2e scripts and
  self tests, the mock snapshots) and its failures go to a fix agent. **None of §3's "pending" rows
  has a result yet, and `scripts/m4-e2e.sh` has never run.** Treat this report's behaviour statements
  as the design and the step reports, not as verified facts, until §3 is filled in.
- **Builds (this step):** Debug `build-for-testing` from fresh derived data (`build/m4-e2e-report`,
  every target including all app test files): `** TEST BUILD SUCCEEDED **`, zero `warning:` and zero
  `error:` lines. Release (`build/m4-e2e-report-rel`): `** BUILD SUCCEEDED **`, zero warnings.
- **Last full runs (before the compile-only steps):** at I1b, app tests 479/479, `scripts/m3-e2e.sh`
  166/166, `scripts/m2-e2e.sh` 110/110 (109/110 once: an M2 timing check, §5), `scripts/m1-e2e.sh`
  42/42, `scripts/m1-smoke.sh` 22/22, the three fixture self tests 268 / 333 / 176, the shortcut
  matrix 97/97, `-CODDSelfTest YES` → `SELFTEST OK`. Every package suite was green with zero warnings
  when its component finished (§3).
- **New end to end:** `scripts/m4-e2e.sh` (B1–B13 from the plan plus U1 / U2 for the user feedback,
  about 290 checks in about 50 app launches, about 15 minutes), written and syntax-checked; its Python
  helpers were checked against sample data and the C11 fixtures, nothing else.
- **Isolation by design:** every automated launch runs in the background on a temp data root with a
  temp Claude directory, fake claudes, a fake cswap and a temp `.claude.json`; every M4 path flag
  refuses the real home's `.claude*`, `.codex`, `.claude-swap-backup` and CODD data root; automatic
  trash moves on a test root go to a folder, never `~/.Trash`; background runs never write your
  general pasteboard. The e2e's B12 checks what can be proven from the outside (§3).
- **Default mode:** real mode on `~/Library/Application Support/CODD`, as before. New there:
  `notes/` (with `.codd/`), `cache/` (post-M4, §13: the notes index and burned-in annotated images),
  `files/`, `cleanup.json`, `sessions/<id>/mcp.json`, `config.json`'s `mcpToken`. The first M4 launch on your data root archives nothing and trashes
  nothing (D30 first-run grace); retention starts counting from that moment.
- **Not verified with the real thing:** no real `claude`, no real `~/.claude.json`, no real cswap, no
  real 注音 input method, no real mouse drag (automation may not post system input). §6 is the
  繁體中文 checklist for you.
- **Questions for you** (§7, end): ⌘0 is now 實際大小 (CODD 主視窗 moved to ⌥⌘0); quitting with unsaved
  file tabs drops them without asking; FILES rows have no 封存; the ImageAnnotate zoom switch and
  sheets at the minimum window at UI 字級 20; the new copy of §8; and the CLAUDE.md build lines (§11:
  not changed by this step, waiting for your OK).

---

## 1. What was built

### Components (parallel, outside App/)

**C1 notes-core — `Packages/CoddNotes`** (new; GRDB 7.11.1 exact, builds warning-free on Swift 6.4,
FTS5 `trigram` through raw SQL against the system SQLite 3.54)
- `NotesLibrary` actor: the §3.1 folder, the lossless YAML-subset frontmatter, ids and file names,
  create / save with conflict detection / metadata changes, archive / trash / restore / purge with
  tombstones, the AI append / write, assets (paste processing, 2576 px, HEIC re-encoding), history
  snapshots, the `codd-annotations` codec and the burn-in renderer (`<hash6>.annotated.png`),
  activity, retention, cleanup candidates (stale, due, sent PROMPTs, SCRATCH, near-duplicates, long
  notes with dated sections, unused images), references (`codd://`, `[[note:]]`, the five COPY REF
  forms), the §3.7 AI text and the prompt expansion, an FSEvents watcher, a single-consumer change
  stream. Index rebuilt when missing / corrupt / another version / built for another root.
- 73 tests in 13 suites.

**C2 mcp — `Packages/CoddMCP`** (new; Foundation only, hand-written JSON)
- Transport-free JSON-RPC server: `initialize` (2025-11-25 / 2025-06-18 / 2025-03-26),
  `server/discover` → -32601 (forces the legacy handshake), `ping`, tools `notes_search`,
  `notes_list`, `notes_read`, `notes_append` (+ `notes_write` only while writing is allowed),
  resources (`codd://note/{id}`), prompts (`note`), batches, 202 for notifications, 405 on GET,
  stateless (no session id), an events stream. Golden fixtures for initialize and tools/list.
- 82 tests in 10 suites.

**C3 hooks-launch — `Packages/CoddHooks`, `Packages/CoddCore`**
- CoddHooks: `/mcp`, `/hooks/prompt`, `/n/<id>.md` routes with async handlers and deadlines,
  `MCPAuth` (per-session HMAC token, per-note URL token), `mcpToken` in config.json (added to an M3
  file at the first start, kept by every rewrite, `rotateMCPToken()`), statistics.
- CoddCore: `ClaudeHookSettings` prompt route + `permissions.allow`, `MCPLaunchConfig`,
  `MCPServerNameResolver` (names only), `LaunchRequest.mcpConfigPath` (right before `--settings`),
  `SessionRetention` (D30 with the first-run grace), `HookPayload.prompt` / `toolFilePaths`.
- CoddCore 390 → 423 tests, CoddHooks 125 → 163 (+ 42 client tests). M3 call shapes unchanged (D40).

**C4 textkit — `Packages/CoddTextKit`** (new) **+ composer chips in `Packages/CoddComposer`**
- `MarkdownEditorView`: TextKit 1 live preview (marks hidden as zero-advance control glyphs, block
  decorations for figures with overlays, code plates, rules, task boxes, quotes, H2 folding), source
  mode, image paste, IME rules (nothing restyles, reveals, saves or reloads while text is composed;
  every API call made meanwhile runs at the commit). `MarkdownBlockParser`, `MarkdownRender`, a code
  highlighter, `codd-markdown-demo`.
- `codd://note/<id>` drawn as amber chips in the composer (off by default; I2b turned them on).
- CoddTextKit 71 tests, CoddComposer 85 → 93.

**C5 code-editor — `Packages/CoddCodeEditor`** (new)
- `CodeEditorView`: TextKit 1 code view, gutter, per-line lexers for 27 languages (Vue SFC, JS / TS /
  JSX, CSS / SCSS, JSON, YAML, TOML, Python, Ruby, shell, SQL, Markdown, C family, Java, Kotlin,
  Swift, Go, Rust, PHP, HTML, XML), incremental highlighting, the find / replace widget, inline diff
  hunks with 還原此段 / 接受, `.mod` bars, the overview ruler, read-only and plain modes. 61 tests.

**C6 files — `Packages/CoddFiles`** (new; libraries CoddFiles and CoddFileEditorUI)
- Read-only `GitReader` (never writes `.git/index`, no fsmonitor daemon, inherited `GIT_*` stripped),
  `FileTreeModel`, `TextFileCodec` (UTF-8 / BOM / UTF-16 / Big5 / Latin-1 read only, LF / CRLF / CR /
  mixed, byte-identical round trips), `FileWatch`, `DirectoryWatcher`, `FileSaver` (atomic, mode /
  ACL / xattrs kept, hard links in place, refused when changed on disk), `OpenFileState`, `LineDiff`,
  `RecentFilesStore`, `AITouchLog`; the FileEditor chrome views. 61 + 17 tests.

**C7 notebook-ui — `Packages/CoddNotebookUI`** (new): lists column, note list, editor chrome (top
bar, COPY REF / SEND / AI / scope / kind / ⋯ menus as non-activating popovers), chips row, image
annotation summary, info panel, doc status, prompt footer, notes drawer, history compare, link / tag
pickers, `codd-notebook-demo`. 57 tests.

**C12 cleanup-ui — `Packages/CoddCleanupUI`** (new): the whole Cleanup artboard page (tabs, table,
sticky bulk bar, CONDENSE card states, POLICY card, keyboard). 40 tests.

**C8 annotate-ui — `Packages/CoddAnnotateUI`** (new): the ImageAnnotate screen (V / R / P / A / T
tools, colors, Fit / 100 % / 200 %, handles, ⇧ locks, IME-safe comment field, send options, the
`AI 會收到` preview, Markdown disclosure, undo / redo). 45 tests.

**C9 settings-status-ui — `Packages/CoddSettingsUI`, `Packages/CoddStatusUI`, `Packages/CoddPreferences`:**
Settings 08 筆記本 & MCP, 09 清理, 12 進階 live; STATUS › MCP SERVER card and nav. 75 / 37 / 31 tests.

**C10 claude-config — `Packages/CoddClaudeSettings`:** `ClaudeUserConfigMCPInstaller` for
`mcpServers.<name>` in `~/.claude.json` (inspect / plan with a masked diff / apply under Claude's own
`<file>.lock` mkdir protocol, read from the installed 2.1.302 bundle; rebases onto a file Claude
changed outside `mcpServers`; byte splicing so every other byte stays; backup), `CodexMCPSnippet`.
78 → 119 tests.

**C11 fixtures — `scripts/m4-fixtures/`:** `make-notes.sh` (SPEC §5 notes + test notes, `--old`
retention ages, `--count N`), `make-png.py`, `make-git-project.sh` (the FileEditor artboard's repo
under an isolated git config), `make-claude-json.sh`, `age-layout.py`, `mcp-client.py`,
`fake-claude-m4.sh` (MCP over the session's mcp.json, prompt hooks, PostToolUse edits, `-p` print
mode), `mock-codd.py`, `selftest.sh` (176 checks).

### Integration steps (sequential, App/)

**I1a notebook-core** — project graph (the eight packages), the `-codd-show` parser fix, `AppTrash`
(D38, also M2's 刪除對話紀錄), `CoddPasteboard` (D39), `NotesService`, the NOTES area and the
Notebook mode, the editor binding (autosave, conflicts, outside edits, image paste, source mode),
search, ⌘⇧N, the 筆記 menu, `notesCount`, mock notes, DEBUG flags and the `notes` dump key. Tested:
458 app tests, smoke 36/36, every older e2e green.

**I1b notebook-features** — ImageAnnotate mode (C8 wired, `完成` = one undoable block rewrite, the
annotated copy regenerated), the AI / scope / kind / ⋯ menus, archive / trash / restore with UNDO,
COPY REF (five forms), link / tag pickers, the info panel (history compare and restore, assets, links,
pin), ⌘K NOTES, ⌘⇧A / ⌘⇧C. Added `MarkdownEditorView.revealLocation(_:)` to CoddTextKit. Tested: 479
app tests, smoke 46/46, matrix 97/97, every older e2e green.

**I2a mcp-server** — `MCPService` + `NotesMCPBackend` on the hook server (D16, D17, D21), per-session
injection (D18), prompt expansion with `systemMessage` (D19), the note URL route, live AI activity,
STATUS MCP and Settings 筆記本 & MCP, `mcp` / `promptExpansion` dump keys. Compiled; an interrupted
earlier attempt had run the app tests (503) and m2 / m3 e2e green.

**I2b send-register** — send to session (prompt footer, SEND menu, ⌘⏎), the `✎ NOTES` pill and drawer,
composer chips, Claude Code registration and removal (dialog B), the Codex snippet sheet, token
rotation, `registration` dump key. Added `HookDiffModel` texts and `SnippetDialogView` to
CoddDialogsUI. Compiled only.

**I3 file-editor** — Files mode (tree, tabs incl. note tabs, code editor, toolbar, banner, status
items), the session header's files button, Notebook LOCAL FILES, git badges, AI touches and the
drawer's `AI 改過的檔案`, SHOW AI CHANGES with hunk actions, find / replace, save and dirty close, disk
watching, the 檔案 menu, mock Files, `files` dump key. Compiled only.

**I4a cleanup** — `RetentionService` (notes and sessions, first-run grace), `cleanup.json`, the
Cleanup page, the digest, `CondenseRunner` with its own spawner, Settings 清理 wiring, `retention` /
`cleanup` dump keys. Fixed the in-memory `archivedAt` of 封存 (the ring clock restarted at every save).
Compiled only.

**User-feedback steps (2026-10-18), see §10** — sidebar-dnd (drops planned from the pointer, Finder
folders), ui-zoom (CoddUI `UIZoom`, ⌘+ / ⌘− / ⌘0), layout-sweep (every screen at the minimum window
and at UI 字級 20; rendered and reviewed, 140 PNGs). Compiled only (the sweep rendered screenshots).

**I4b e2e-report (this step)** — `scripts/m4-e2e.sh`, three small DEBUG additions it needs (§11),
docs/ARCHITECTURE.md (M4 decisions, layout, process model, data root, the App sections, DEBUG
flags), docs/ROADMAP.md, this report. Compiled (Debug and Release) only, per the test policy.

## 2. How to run

```bash
# Packages (separate scratch paths avoid lock clashes)
for p in CoddCore CoddHolder CoddHooks CoddTerminal CoddComposer CoddUI CoddPreferences CoddClaudeSettings \
         CoddHost CoddStatusUI CoddSettingsUI CoddNotes CoddMCP CoddTextKit CoddCodeEditor CoddFiles \
         CoddNotebookUI CoddAnnotateUI CoddCleanupUI; do
  swift test --package-path Packages/$p --scratch-path .build-$p
done
swift test --package-path Packages/CoddDialogsUI --scratch-path .build-CoddDialogsUI --skip PresenterTests

# UI demos (PNG snapshots, offscreen; without --snapshot some open a window: manual use only)
swift run --package-path Packages/CoddNotebookUI --scratch-path .build-CoddNotebookUI codd-notebook-demo --fonts App/Fonts --snapshot /tmp/nb-demo
#   likewise codd-markdown-demo (CoddTextKit), codd-code-demo (CoddCodeEditor), codd-files-demo (CoddFiles),
#   codd-annotate-demo (CoddAnnotateUI), codd-cleanup-demo (CoddCleanupUI)

# App + tests
xcodegen generate
xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd build
CODD_BACKGROUND=1 xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/dd test

# End to end (temp roots, temp Claude dirs, the fakes only; they end every process they started)
scripts/m4-e2e.sh            # M4: B1–B13 + U1 / U2; KEEP=1 keeps the temp folder; CODD_APP=<binary>
scripts/m3-e2e.sh; scripts/m2-e2e.sh; scripts/m1-e2e.sh; scripts/m1-smoke.sh
scripts/m4-sidebar-dnd.sh; scripts/m4-ui-zoom.sh          # also folded into m4-e2e (U1, U2); MATRIX=1 for the keys
scripts/m4-layout-sweep.sh /tmp/sweep                      # PNGs of every screen at several sizes (mock mode)
scripts/m2-fixtures/selftest.sh --with-app build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
bash scripts/m3-fixtures/selftest.sh; bash scripts/m4-fixtures/selftest.sh
```

**The app on your real data** (what you use day to day): just open it. The notebook lives in
`~/Library/Application Support/CODD/notes` (Settings › 筆記本 & MCP › `開啟筆記本資料夾`); every CODD
claude session you start or RESUME gets CODD's MCP server (Settings › 自動掛載 MCP, ON by default);
nothing is written to `~/.claude.json` until you press Claude Code `註冊` and then `套用並備份`;
`~/.codex` is never written (Codex `註冊` shows a snippet to copy). Sessions started before this build
get the MCP server at their next RESUME or RESTART.

**A throwaway try-out with the fakes** (nothing of `~/.claude`, `~/.claude.json`, your cswap or your
accounts is read; no Anthropic call):

```bash
APP=build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
ROOT="$(mktemp -d "${TMPDIR%/}/codd-try.XXXXXX")"; ROOT="$(cd "$ROOT" && pwd -P)"
scripts/m2-fixtures/make-root.sh "$ROOT/data" >/dev/null
mkdir -p "$ROOT/bin" "$ROOT/home/.claude/sessions" "$ROOT/work" "$ROOT/trash" "$ROOT/fakelog"
bash scripts/m4-fixtures/make-notes.sh "$ROOT/data/notes" --project "$ROOT/work" >/dev/null   # SPEC §5 notes + test notes
bash scripts/m4-fixtures/make-git-project.sh "$ROOT/work/frontend" >/dev/null               # the FileEditor repo
cp scripts/m4-fixtures/fake-claude-m4.sh "$ROOT/bin/fake-claude"; cp scripts/m4-fixtures/mcp-client.py "$ROOT/bin/"
printf '看一下 codd://note/rwd-punch-k7x2\n' >"$ROOT/prompts.txt"
cat >"$ROOT/bin/fake-claude.env" <<EOF
FAKE_REGISTRY_DIR=auto
FAKE_DEFAULT_CLAUDE_DIR=$ROOT/home/.claude
FAKE_LOG_DIR=$ROOT/fakelog
FAKE_STATUSLINE_INTERVAL_MS=0
FAKE_MCP_SCRIPT=$PWD/scripts/m4-fixtures/mcp-script-session.jsonl
FAKE_MCP_LOG=$ROOT/mcp.jsonl
FAKE_PROMPTS=$ROOT/prompts.txt
EOF
"$APP" -codd-data-root "$ROOT/data" -codd-claude-dir "$ROOT/home/.claude" -codd-claude-path "$ROOT/bin/fake-claude" \
  -codd-trash-dir "$ROOT/trash" -codd-login-env NO -codd-notifications NO -codd-shell-argv "/bin/zsh -f"
# Rail NOTES: the notebook (打卡頁 RWD 跑版紀錄 with its annotated screenshot); ⌘⇧N; paste an image; ⌘⇧A.
# ⌘N a claude session in $ROOT/work: its terminal shows the fake's MCP calls (FAKE-MCP …) and the
# `codd：已展開 …` line; STATUS › MCP SERVER lists the session. The session header's files button opens
# $ROOT/work in Files (git badges come from the frontend repo when you open it).
# Clean up: pkill -TERM -f "$ROOT/"; sleep 1; pkill -KILL -f "$ROOT/"; rm -rf "$ROOT"
```

Mock data (screenshots): `"$APP" -codd-mock -codd-show notebook|note:rwd-punch-k7x2|annotate:rwd-punch-k7x2:9f3a1c.png|files:orb-toolkit-frontend/src/pages/punch.vue|cleanup|split|status|settings-notebook|settings-cleanup|settings-advanced -codd-snapshot <png> -codd-quit-after 5`.
DEBUG flags are listed in `App/Real/RealModeOptions.swift` (and ARCHITECTURE "Testing hooks");
`-codd-dump-state <file>` writes what the e2e checks.

## 3. Test results (2026-10-18)

Every package suite below was green with zero warnings when its component finished; every one is
re-run in the final test run, because later steps (and the CODD rename) changed several of them.

| Suite | Result |
|---|---|
| Debug build (`build-for-testing`, fresh `build/m4-e2e-report`) | `** TEST BUILD SUCCEEDED **`, zero `warning:` / `error:` lines (this step) |
| Release build (`build/m4-e2e-report-rel`) | `** BUILD SUCCEEDED **`, zero warnings (this step) |
| App tests (`CODD_BACKGROUND=1 xcodebuild test`) | **pending** (final test run). Last runs: 479/479 at I1b; 503 in 119 suites in I2a's interrupted attempt. Written but never run since: M4MCP* (part), M4Send, M4Registration, M4Files*, M4Cleanup*, M4SidebarDragDrop, M4UIZoom, M4LayoutSweep |
| CoddNotes / CoddMCP | 73 / 82 passed at C1 / C2; **pending re-run** (the CODD rename changed CoddMCP's server title and golden fixtures afterwards) |
| CoddCore / CoddHooks | 423 / 163 + 42 passed at C3; **pending re-run** |
| CoddTextKit / CoddComposer | 71 / 93 passed (CoddTextKit re-run at I1b after `revealLocation`); **pending re-run** |
| CoddCodeEditor / CoddFiles | 61 / 61 + 17 at C5 / C6; **pending** (layout-sweep changed both; compiled only) |
| CoddNotebookUI / CoddCleanupUI / CoddAnnotateUI | 57 (re-run at I1a) / 40 / 45; **pending** (ui-zoom and layout-sweep changed them; compiled only) |
| CoddSettingsUI / CoddStatusUI / CoddPreferences | 75 / 37 / 31 at C9; **pending** (ui-zoom, layout-sweep; compiled only) |
| CoddClaudeSettings | 119 passed at C10; **pending re-run** |
| CoddUI / CoddDialogsUI | **pending** (I2b, ui-zoom, layout-sweep added tests and changed code; compiled only); CoddDialogsUI with `--skip PresenterTests` |
| `scripts/m4-e2e.sh` | **written, never run** (`bash -n` clean; helpers checked on sample data). Must be green twice in a row |
| `scripts/m3-e2e.sh` / `m2-e2e.sh` / `m1-e2e.sh` / `m1-smoke.sh` | **pending**; last at I1b: 166/166, 110/110 (109/110 once, §5), 42/42, 22/22 |
| `scripts/m2-fixtures/selftest.sh --with-app` / `m3-fixtures` / `m4-fixtures` | **pending**; last at I1b: 268 / 333 / 176 |
| `scripts/m4-sidebar-dnd.sh`, `scripts/m4-ui-zoom.sh` | **written, never run** (also covered by m4-e2e U1 / U2) |
| `-CODDSelfTest YES` / `-codd-shortcut-matrix YES` | **pending**; last at I1b: `SELFTEST OK` / `SHORTCUTS ok=97 fail=0` (the Files and zoom checks added later never ran) |
| Mock snapshots vs the artboards | Compared by eye: every component demo (C4–C12), the app's Notebook and ImageAnnotate (I1a, I1b), the layout sweep's 140 renders (for layout, not the artboards). **Pending:** the app's FileEditor, Cleanup, Split drawer, STATUS MCP and Settings 08 / 09 / 12 snapshots of the final binary |

How `scripts/m4-e2e.sh` is laid out: one mktemp folder (`codd-m4e.XXXXXX`, under the per-user temp
folder); one group folder per scenario group (one or two letters, so holder sockets stay under 104
bytes), each with its own data root (make-root.sh: its own hook port and token), its own Claude
directory (`home/.claude`, so `home/.claude.json` is the "user's" `.claude.json`), its own trash
folder (`-codd-trash-dir` on every launch), copies of the fakes with `.env` sidecars, and a work
folder. Every launch is a background CODD with every flag as its own argument, `-codd-quit-after` and
`-codd-dump-state`; the dump is polled every 100 ms, waits are at most 30 s; holders are ended at the
end of each group; the cleanup ends every process whose argv names the folder (both `/private/var/…`
and the standardized `/var/…` spelling) and removes it unless `KEEP=1`. Groups:

| Group | What it checks |
|---|---|
| B1 (n) | counts 18 / 1 / 2 / 1 / 1, search 打卡 / 打卡頁 / #rwd ids, `notes-index.sqlite` next to `notes/`, deleted → rebuilt `missing`, garbage bytes → rebuilt `corrupt`, an outside create / edit / delete while running within 3 s (the shown clean note reloaded, its hash), no `.md` outside `notes/` |
| B2 (n) | `-codd-notes-new` + `-codd-notes-type` → one `YYYY-MM-DD-e2e-新筆記.md` with an id; a 4000 × 3000 paste → `assets/rwd-punch-k7x2/<hash6>.png` at 2576 × 1932 and its `![截圖 …]` line; `-codd-notes-annotate` → the block + a 750 × 1334 `9f3a1c.annotated.png` |
| B3 (m) | the fake session's MCP script from its mcp.json: discover -32601, initialize 2025-11-25, 202, four tools, search 打卡, read (the §3.7 text, the annotation list, one image), append (file, `codd:ai-append` marker, history snapshot, activity), refused on a READ note, OFF and trashed reads isError, resources without the OFF note; `mcp.clients` = 1; external token 200, Bearer search of the OFF secret empty, wrong token 401, foreign Origin 403; note URL 200 / wrong `t` 404 / OFF 404 / trashed 410; `notes_write` listed with AI 可寫入 |
| B4 (m) | `systemMessage` `codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）`, `additionalContext` with `<codd-note …>`, the OFF ref's refusal without its title or text, 204 without a ref, the session's last prompt, `promptExpansion` count / late |
| B5 (m) | `--mcp-config <sessionDir>/mcp.json` right before `--settings`, the file 0600 with the HMAC token, `/hooks/prompt` (timeout 3) and the allow rules, `codd-desktop` with a foreign `codd` in `home/.claude.json` (read only), 自動掛載 MCP off → no file, UserPromptSubmit on `/hooks` |
| B6 (s) | submit → one paste with the note's AI text and a submit in the fake's stdin log; ref → the composer draft; refused while WAITING (a pending PermissionRequest); a PROMPT gets `sent` / `sentTo` |
| B7 (f) | on the fixture repo: banner naming the session while dirty (nothing written), reload while clean, UTF-8 / LF / Vue, `feat/punch-rwd` ↑2 and three `M`, ignored files, the AI touch, SHOW AI CHANGES one hunk `@@ -40,2 +40,4 @@`, 還原此段 + ⌘S = HEAD byte for byte, CRLF / BOM / Big5 saved with only the typed byte added, `.git/index` untouched, no other repo file changed or created, git only inside the repo, no fsmonitor daemon |
| B8 (r) | plan: summary and the masked diff (`"X-CODD-Token": "••••"`, other servers elided); apply with a 6 s delay while "Claude" rewrites `numStartups` → kept (rebased), backup = the replaced bytes, only `mcpServers` changed (JSON, key order and every byte outside the member), no lock left, 0600; remove → the bytes before; rotation → new `mcpToken`, `needsReregister`; a link to `$HOME/.claude.json` refused before any plan |
| B9 (t) | first run on a fresh root: `firstRunAt`, nothing archived although a session stopped 8 days ago; then (aged): the 30 d note, the SCRATCH and the sent PROMPT archived (`archivedBy: auto`), the pinned and the live-linked notes kept, the 21 d note stale, the 31 d trashed note purged into the trash folder with its image and a tombstone (its URL 410 `purged`), the stopped session archived, the old ring + holder.log trashed, `trash target=folder` only |
| B10 (t, d) | counts per tab; Monday 09:05 digest recorded once (suppressed), not again in the period, none with < 5 candidates; `保留 30 天` → `keepUntil` |
| B11 (c) | D32's exact argv in the fake's JSON log, `FAKE-P-ENV CODD_HOOK_TOKEN=unset CODD_SESSION_ID=unset`, the run folder as cwd, stdin with the notes (the long note's sections older than 30 days only, no OFF note), the summary note with `condensedFrom`, the sources archived with `condensedInto`, the long note byte-identical, one more note file, no run folder left; a pinned cswap #2: `CLAUDE_CONFIG_DIR=set`, no profile path anywhere |
| U1 (u) | the DEBUG drag self-test (sessions, projects, groups, folders), the order after a relaunch, two folders dropped first into a group (a file ignored), persisted |
| U2 (z) | ⌘+ twice → 15 / 15 in preferences.json, the relaunch starts at 15 (launch peek, scale 15/13, the zoomed row height), 實際大小 back to 13 |
| B13 (q) | numbers (§4): 1,000-note index, search p95 打 / 打卡 / 打卡頁, notes_read with / without images, note open, 1 MB / 10 MB file open, idle CPU and footprint with the Notebook and Files shown (3 silent fake claudes) |
| B12 | every `exec` line inside the temp folder (git, the fake claude, the fake cswap only); no `anthropic.com`; no hook token, `mcpToken` (rotated ones too), session token or note URL token in any dump, app log, fake log or client output; no `trash target=system` / `pasteboard target=general`; no new `$HOME/.claude.json.codd-bak-*` / `~/.claude/settings.json.codd-bak-*` (names only); `~/.codex/config.toml` size and mtime unchanged; a source grep: no `.codex` write; no `.md` added to any work folder |

## 4. Measured numbers (this Mac)

All numbers so far come from the component and step reports (debug builds, other agents compiling at
the same time). The e2e's B13 prints `E2E number …` lines for the app-level numbers; they are
**pending** (it has not run).

| What | Measured | Budget |
|---|---|---|
| Notes index build, 1,000 generated notes of ~4 KB (C1) | 811–961 ms (first try 1.79 s before the byte-scanning rewrite) | < 2 s debug |
| Notes search p95, 1,000 notes: 打 / 打卡 / 打卡頁 (C1) | 6.2–7.2 ms (注音 / position / `#gen 跑版` ≈ 7 ms) | < 20 ms |
| Reopen with the index up to date, 1,000 notes / counts / list of 200 (C1) | 72–79 ms / 5.5 ms / 8.8 ms | — |
| Slowest read while a full rebuild runs (C1) | 26–28 ms | ≈ 50 ms |
| Burn-in render 750 × 1334 / 2576 × 1932 (C1) | 11–19 ms / 43–46 ms | — |
| AI text of n1 first / cached; prompt expansion (C1) | 16–20 ms / 1.8 ms; 1.6 ms | — |
| App, 20 fixture notes: index build / reopen / search 打卡 (I1a) | 12.8–19.7 ms / 4.4–4.8 ms / 0.68–0.74 ms | — |
| Note open, 1.2 KB note / 1 MiB note (I1a, read + parse + editor load) | 19.3 ms / 484 ms | — |
| 1 MiB note in the editor: load (C4) | best 236 ms, median 238–250 ms (about 80 ms is AppKit fixing CJK fonts) | < 300 ms |
| Keystroke in a 1 MiB note: restyle (C4) / insert + layout + display through the app (I1a) | p50 7.4 ms, p95 13.8–14.6 ms / p50 23.7 ms, p95 24.1 ms | < 30 ms |
| 1 MB JavaScript in the code view: first highlighted screen / keystroke (C5) | 46–49 ms / median 1.95–2.03 ms, p90 2.4–3.1 ms; jump to the last line ~310 ms (printed only) | < 150 ms / < 16 ms |
| git status of 5,000 files; LineDiff 20,000 lines with 100 edits (C6) | 21–25 ms; 9–12 ms | < 300 ms |
| MCP: 100 concurrent notes_search (fake backend); a 3 MB image result encoded (C2) | 4–7 ms; 6.4 ms | — |
| MCP server-name scan of a 9.6 MB `.claude.json` (C3) | 71 ms | — |
| `~/.claude.json` installer on 2.39 MB: plan / apply / inspect (C10) | 0.086–0.090 s / 0.022–0.035 s / 0.076–0.082 s | — |
| Fixtures: 1,000 notes / a 4000 × 3000 PNG / the git repo (C11) | 0.48 s / 0.17 s / 0.8–0.97 s | — |
| `notes_read` server time with / without images, prompt expansion round trip, 1 MB / 10 MB file open, idle CPU with the Notebook / Files shown, footprint | **pending** (e2e B4, B13) | idle visible < 0.5 % |

## 5. Known issues

**Not verified with the real thing** (automated runs never use them):
- **A real `claude`.** The MCP negotiation (discover → legacy initialize), the `mcp-protocol-version`
  header, `structuredContent` validation against `outputSchema`, the http hook answer shapes
  (`additionalContext`, `systemMessage`), the 401-without-`WWW-Authenticate` behaviour and the
  variadic `--mcp-config` placement were read from the installed 2.1.302 bundle and reproduced by the
  fake claude; no live session has used them. Whether `/mcp` shows `codd` as connected next to your
  own servers, whether Claude asks permission for `notes_append` as expected and how Claude renders
  the `codd：已展開 …` line are in §6.
- **The real `~/.claude.json`.** The installer follows Claude's lock (`<file>.lock` mkdir, 10 s
  stale rule) as read from the bundle. Some Claude writers skip that lock (two synchronous writers and
  the fallback after its retries) and can still land between CODD's last check and its rename; the
  rebase narrows the window, it cannot close it. A storage-v5 write path behind a server flag was not
  examined. CODD never removes a stale lock (you delete `~/.claude.json.lock` by hand if Claude is not
  running). Back the file up before the first registration (§6).
- **The real cswap.** Condense with a pinned account uses M3's pin rules on the fake cswap's state.
- **Real 注音 input.** Every editor and field was tested with `setMarkedText` / `insertText` only.
- **Real mouse drags.** The drag fixes are tested through AppKit's own drop path with synthetic
  dragging infos; a real dragging session (drag image, threshold, autoscroll, Finder as the source)
  never ran (§10).

**By design or limits of M4:**
- **Bash-made file changes are not attributed to AI** (D26): only Edit / Write / MultiEdit /
  NotebookEdit paths from PostToolUse; a file changed by a Bash command shows only git's `M`.
- **MCP is down while CODD is quit** (no stdio bridge): sessions keep working, Claude marks `codd`
  failed until you reconnect it in `/mcp`. Sessions started before an M4 build get MCP only after
  RESUME / RESTART.
- **Scope is advisory:** a project note is hidden from other projects' MCP calls, but any session with
  a Bash tool can `cat` any file in the notes folder, OFF notes included.
- **A managed MCP config** (`managed-mcp.json`) makes Claude refuse dynamic servers: such users get no
  `codd` in CODD sessions (Claude's rule).
- **Pinned sessions outside CODD** read user-scope servers from their profile's `.claude.json`, not
  `~/.claude.json`, so a Claude Code registration does not reach them (CODD's own pinned sessions get
  the per-session file anyway).
- **Notes paths have a space** (`Application Support`): COPY REF's file path is absolute and
  unquoted; `@` mentions of such paths may not resolve (use `codd://`).
- **No list_changed:** turning AI 可寫入 on or off shows up in a client at its next `tools/list` (in
  Claude Code: reconnect through `/mcp`); a stale `notes_write` while off gets an isError explaining it.
- **Search** covers the Markdown-stripped text only (link URLs, backticks and `**` are not searchable).
- **A note without frontmatter** that you rename outside CODD changes its derived id until CODD writes
  an `id:` at its first save or metadata change.

**Not done / known problems:**
- **Quitting with unsaved file tabs (fix round 1):** ⌘Q / 結束 asks first (one sheet for all of them:
  `[不儲存]` `[取消]` `[儲存全部]`); a quit that cannot ask (logout, restart, `-codd-quit-after`, dialog
  D's answer) keeps each buffer as a copy in `<dataRoot>/files/unsaved/<yyyyMMdd-HHmmss>/` (0600, never
  over the file). There is no restore UI for those copies yet: open them from that folder.
- **An open file that is deleted or moved away gets no banner**; a later ⌘S is refused as changed on
  disk.
- ⌘K `在 <project> 開啟檔案…` was skipped (the ACTIONS section is full); the tab strip's `⋯` menu,
  breadcrumb symbols and clicks on status items other than Ln / Col do nothing; the tab strip does not
  scroll when tabs overflow.
- On your standard data root CODD's git uses your own global git config (only fsmonitor and
  optional locks are forced off); on any other data root (tests, fixtures, a try-out) it runs with
  `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` (fix round 1).
- **C4 display loop (from I1b):** in a small displayed window, a note like n1 (a tall figure with text
  after it) can make AppKit raise "more Display Window passes than there are views"; the real window
  idled at 0 % CPU with n1 shown, the cause is in CoddTextKit's decoration drawing; not fixed.
- The editor caret is drawn through `drawInsertionPoint`; if macOS 26 draws its own indicator instead,
  you see the system caret in amber.
- Long code lines wrap in the note editor's code blocks (the artboard's `pre` does not); comments in the
  code view are slanted upright glyphs (no italic JetBrains Mono is bundled).
- Mock Cleanup rows and bulk actions only toast `mock 模式不會變更任何東西`; mock mode never gives the
  library its live sessions, so mock RETENTION rows differ from the artboard.
- A stopped CODD claude session whose transcript is gone always shows a SESSIONS row
  `transcript gone`; candidate refreshes read every stopped session's transcript head (no cache).
- `SessionRetention` has a single `keepUntil`: 保留 30 天 on a FILES ring row keeps the whole session.
- External MCP clients count only after an `initialize` (stateless MCP); `n clients` is always plural.
- STATUS `連線 42m` and the session pill's duration update with the page's own refreshes, not every
  second.
- At UI 字級 20 the minimum Settings window grows to 895 pt on 08 筆記本 & MCP; the new-session sheet
  and some dialogs are larger than the 1011 × 560 minimum window (sheets overhang it); at the minimum
  window ImageAnnotate drops its Fit / 100 % / 200 % switch and shows the image at about 10 %. Views
  built before a live zoom keep some init-time spacings until they are rebuilt.
- An M2 timing check (m2-e2e R11, the sidebar STATE-view head count) failed once in four runs at
  I1b and passed when rerun.
- The test policy above: the integration from I2a on, the user-feedback steps and this report were not
  tested before the final test run; its failures and the review's findings are fixed in round 1 (§12),
  which lists what is still open.

**Isolation notes:** the e2e never lists `~/.Trash` (TCC refuses it) and never compares listings of
`~/.claude` or `~/.claude.json` (real sessions write there all the time); it checks log lines
(`exec`, `trash target`, `pasteboard target`), backup names in `$HOME` and `~/.claude` (names only)
and `~/.codex/config.toml`'s size and mtime instead. Its one link to the real home
(`realclaudejson → ~/.claude.json`) is only resolved by CODD's guard, never read, and removed right
after. It never uses a fake home (`CFFIXED_USER_HOME`).

## 6. 手動測試清單（請用真的 claude、真的 ~/.claude.json、真的 cswap 與注音輸入法）

先打開你自己 build 的 CODD（Debug 或 Release 都可以）。這會用你真的資料夾
`~/Library/Application Support/CODD`：第一次打開會多出 `notes/`（筆記本，含 `.codd/`）、`cache/`（可重建的資料：
筆記索引與標註圖，可以整個刪掉）、`files/`、`cleanup.json`，`config.json` 會多一個 `mcpToken`。第一次打開時不會封存任何 session、也不會把任何
終端機紀錄移到垃圾桶（first-run grace，3 / 7 / 30 天後才開始照規則走）。有問題時請附上終端機輸出裡
`REALHOLDERS` 開頭的那幾行，以及 STATUS 頁的截圖（裡面不會有 token）。

**A. 注音輸入（每個新的輸入位置都試一次：組字中按 Enter 只確認選字，不能換行、不能送出、不能存檔）**
1. 筆記編輯器：標題那一行（空的 `# ` 時，候選字窗要在標題下方）、清單項目結尾、`**粗體**` 旁邊、待辦項目的文字、
   表格那一行、圖片下一行、程式碼區塊裡。組字中不應自動存檔，也不應把語法標記突然顯示或隱藏。
2. 筆記本左上的搜尋欄、⌘K、標籤編輯器、連結選擇器、標籤列的 `+ #` 欄位。
3. 標註模式（⌘⇧A）的說明欄、座標欄、T 工具在圖上直接打字。
4. 檔案編輯器的 `/ 篩選檔案… ⌘P`、尋找欄（⌘F）、程式碼本身。
5. 清理頁與 設定 › 筆記本 & MCP 若有輸入欄也試一下。

**B. 真的 CODD claude session 與 MCP**
6. 開一個新的 CODD claude session（或對舊的按 RESUME），在裡面輸入 `/mcp`：應看到 `codd`（connected），你自己的
   MCP server 也都還在、都能啟動。如果你自己已經有一個叫 `codd` 的 server，CODD 會改用 `codd-desktop`。
7. 請 Claude「用 notes_search 找打卡頁的筆記並讀出來」：應能找到並讀到內容；有標註的圖片應以「標註後的圖」
   附上，文字裡有座標清單（原圖像素，左上為原點）。
8. 在提示裡直接寫 `codd://note/<某則筆記的 id>`（筆記右上 COPY REF 的第一項）送出：終端機裡 Claude 的回應前
   應出現一行 `codd：已展開 codd://note/…（標題 · n 張圖片）`，Claude 不需要再呼叫 notes_read 就知道內容。
9. 把一則筆記的 AI 存取改成 `APPEND`，請 Claude 附加一行到那則筆記：Claude 應先問你是否允許
   （`notes_append`），允許後筆記最後多一段 `AI 附加 · HH:mm`，HISTORY 多一個版本，資訊欄的 AI ACTIVITY 有紀錄。
10. 把一則筆記改成 `OFF`：請 Claude 搜尋它的標題或內容，應找不到；在提示裡寫它的 `codd://` 應出現
    `codd：codd://note/… 無法展開（AI 存取為 OFF）`，而且不會出現它的標題。COPY REF 的網址那一項應是灰的。
11. STATUS › MCP SERVER：應列出這個 session（client 類型、連線多久），選單列與下方狀態列的 `● MCP` 是亮的。
12. 結束 CODD（session 繼續跑），在 session 裡用一下 `/mcp`：`codd` 會顯示失敗；重新打開 CODD 後在 `/mcp`
    重新連線即可恢復（這是已知限制）。

**C. 註冊到 Claude Code（會寫入你真的 ~/.claude.json，請先備份）**
13. 先自己備份：`cp ~/.claude.json ~/.claude.json.mybackup`。到 設定 › 筆記本 & MCP（或 STATUS › MCP SERVER）
    按 Claude Code 的 `註冊`：對話框應只顯示 `mcpServers` 裡新增 `codd` 的差異，token 顯示成 `••••`，其他 server
    以 `…（保留既有 n 個 MCP server）` 帶過。按 `套用並備份` 後：`~/.claude.json` 旁邊多一個
    `.claude.json.codd-bak-<日期時間>`，`~/.claude.json` 裡除了 `mcpServers.codd` 以外一字不變
    （可以用 `diff` 比對備份）。在 Terminal.app 開一個 claude，`/mcp` 應看到 `codd`。
14. 按 `輪替`（token）：確認後 Claude Code 那一列應顯示 `需要重新註冊（token 已輪替）`；再按 `註冊` 會更新 token。
15. 按 `移除`：`~/.claude.json` 應回到註冊前的樣子（除了 Claude 自己這段時間改過的地方）。
16. Codex 的 `註冊`：應跳出一段 `config.toml` 設定讓你複製，CODD 不會改 `~/.codex/config.toml`。

**D. 檔案編輯器（用一個真的專案）**
17. 在某個 session 的標題列按檔案按鈕：左邊檔案樹顯示專案，git 改過的檔案有 `M`，分支與 ↑ 數字正確，
    被忽略的檔案是灰的。⌘P 篩選、⌘F 尋找、⌘S 存檔、⌘W 關分頁都要能用；有未存的修改時關分頁會問你。
18. 打開一個檔案先打幾個字（不要存），再請那個 session 的 Claude 改同一個檔案：上方應出現
    `磁碟上的檔案已被 AI 變更（<session> · HH:mm）· 你有未儲存的修改`，可以選 `重新載入` / `保留我的` / `比較`。
    檔案樹與分頁上應出現 AI 標記。
19. 打開 SHOW AI CHANGES：與 git HEAD 比較的段落以行內差異顯示；對一段按 `還原此段` 再按 ⌘S，存檔後的內容
    應正確；`接受` 只是收起那一段。整個過程中，沒有按 ⌘S 就不應寫入任何檔案。
20. 試一個 CRLF 或 Big5 的檔案：狀態列顯示正確的換行與編碼，存檔後其他行的換行不變。

**E. 清理與保留**
21. 筆記本左下 `清理建議 n →`：清理頁的 NOTES / SESSIONS / FILES 三個分頁、`保留 30 天`、`封存`、`移到垃圾桶`
    都要能用（封存與垃圾桶都可以復原）。
22. `交給 Claude 濃縮…`（會用你真的帳號跑一次 `claude -p`，消耗少量額度）：選幾則筆記，按 `✻ 產生摘要`，
    應在幾十秒內出現摘要預覽；按 `建立摘要並封存原稿` 後多一則 `摘要 · M/D 清理（n 則）`，原稿被封存
    （可在 ARCHIVE 找到並取消封存）；AI 存取為 OFF 的筆記不會被送出。也試一次選別的 cswap 帳號。
23. 週一早上 09:00 後第一次打開（或 CODD 一直開著）：若清理建議 ≥ 5 項，應收到一則
    `清理建議 · n 項` 的通知，按 `查看` 會打開清理頁；同一週不會再提醒。
24. 一週後與 first-run grace 之後：停止超過 3 天的 session 變淡，停止超過 7 天的 session 自動封存（可復原），
    封存超過 30 天的 session 的終端機紀錄移到垃圾桶；14 天沒動的筆記出現在 STALE，30 天沒動的筆記自動封存，
    你丟進垃圾桶 30 天的筆記才會被真正刪除（移到 macOS 垃圾桶）。釘選的筆記與正在使用的 session 連結的筆記不會被封存。

**F. 使用者回饋（2026-10-18）**
25. 用滑鼠拖曳：session 拖到同一專案的下一個 session 下面、專案拖到另一個群組與 `未分類`、群組上下拖：
    琥珀色的插入線要準確顯示放下的位置，放下後順序正確，重開 CODD 後仍保留。
26. 從 Finder 拖一個或多個資料夾到側欄：放到群組標題上會加到該群組最後，放到兩個專案之間會插在中間，
    其他位置加到 `未分類`；已經是專案的資料夾不會重複加入，而是被選取並提示。檔案（非資料夾）會被忽略。
27. 介面縮放：⌘+ 放大、⌘− 縮小、⌘0 實際大小（介面字級與終端機字級一起調整，重開後保留）；
    `CODD 主視窗` 的快捷鍵改成 ⌥⌘0。請確認你接受這個改動。
28. 把視窗縮到最小、拉到全螢幕，各在 UI 字級 13 與 20 下看：Notebook、Files、清理頁、STATUS、設定、標註模式、
    各對話框都不應重疊或被切掉（太窄時次要的元件會隱藏或換行）。
29. Dock 與 Finder 裡的新圖示、各處顯示的名稱是 `CODD`。

## 7. Decisions taken (all reversible)

### The plan's decisions as implemented

| # | As implemented |
|---|---|
| D1 | As planned: `<dataRoot>/notes/` (0700) with `assets/<id>/` and `.codd/`; the index outside it; nothing written into a project. Mock mode uses a temporary folder. |
| D2 | As planned: a lossless YAML subset, only the lines of changed keys patched, CRLF kept; an unparsable frontmatter keeps only a recognisable `id:` line, is indexed with defaults, and metadata edits / trash are refused with the toast. |
| D3 | As planned; a new note is written only at its first real change or first pasted image (NOTE seeded `# `, quick note `# 隨手記 M/D`); duplicate ids → `<id>-dup<n>` (the file already indexed keeps the id; a full rebuild orders by birth time); a note without frontmatter gets a path-derived id. |
| D4 | As planned; `state.json` written 1 s after a change and at close (a crash can lose up to ~1 s of opened / keep state); activity.jsonl compacted at open. |
| D5 | GRDB 7.11.1 as planned (warning-free); the §3.5 schema refined (extra columns, a root check → rebuild reason `root`); a full build writes batches of 50 rows and yields between files. |
| D6 | As planned; a quote inside a term is literal, a quoted phrase keeps its spaces; FTS and LIKE over the Markdown-stripped text; snippets built in Swift. |
| D7 | As planned; a clean editor reloads in place, a dirty one shows the banner; 保留我的 snapshots the disk version first; 比較 opens the compare sheet. |
| D8 | As planned; snapshot names in UTC, a forced snapshot's reason in an xattr, a snapshot identical to the newest skipped. |
| D9 | As planned; the toast `已貼上圖片 → …（· 已縮小到 2576px）`. |
| D10 | As planned plus the T tool's text items; the annotated copy's cache key in an xattr; `完成` with no items and default send options removes the block; unknown keys kept. |
| D11 | TextKit 1 for both editors; hidden marks are zero-advance control glyphs (`.null` broke first-line indents); the caret paragraph shows its syntax only while the editor has focus. |
| D12 | As planned; the Notebook draws its own status bar under the editor column; a NOTES reselect from Files goes back to the Notebook. |
| D13 | As planned; ⌘⇧N while NOTES makes a NOTE, elsewhere (and QUICK NOTE, 快速筆記) the linked SCRATCH; the key equivalent is `N` with ⌘⇧ (a real ⌘⇧N reports `N`). |
| D14 | As planned; 插入引用 / 插入全文 are allowed into a non-running session's draft (only 送出 checks running / WAITING / the PTY); the 256 KiB limit applies to 插入全文 too. |
| D15 | As planned; the dump and logs show the URL token as `?t=••••`; the DEBUG copy-ref flag writes no pasteboard. |
| D16 | As planned; `notifications/initialized` is exempt from the version 400 too; batches accepted for every version; a live CODD session that kept running across a CODD restart is counted at its first request. |
| D17 | As planned; invalid tool arguments are isError results (so the model can correct itself); `notes_write` while off is an isError pointing to the setting; ≤ 8 MiB of image bytes per result. |
| D18 | As planned; on a test data root a global config path into the real home is treated as absent (`global-config=skipped`); the name scan is cached 10 s by size and mtime; when the user registered this endpoint, no file and no allow rules but the prompt route stays. |
| D19 | As planned; CODD's deadline is 1.3 s inside the server's 1.5 s so a late answer is counted (`promptExpansion.late`). |
| D20, D21 | As planned; external clients need an `initialize` for their name; Codex is shown `未註冊` (CODD never reads `~/.codex`). |
| D22 | As planned (C10 byte splicing, rebase, Claude-compatible lock); backups `.claude.json.codd-bak-YYYYMMDD-HHMMSS[-2…]`; a plan that cannot be made is a toast; on any non-standard root only `-codd-claude-json`, refused before reading when it resolves into the real home. |
| D23 | As planned; an NSAlert sheet confirms 輪替; config.json is written first, then the running server gets the token. |
| D24 | As planned, stricter for mixed EOL (a replaced line keeps the terminator of the line it replaces); the tree never lists `.git` / `.DS_Store`; a file without write permission opens read-only; ⌘S on a clean buffer writes nothing. |
| D25 | As planned; the ±10 s attribution also when the PostToolUse arrives after the watcher fired; 比較 is a temporary 4th baseline. |
| D26 | As planned; AI chips also on tabs (the artboard draws none). |
| D27 | As planned; opening from an AI badge turns the switch on; `接受` leaves a `.mod` bar in the session color. |
| D28 | As planned (27 languages); comments slanted at draw time (no italic font); > 2 MiB only the visible lines. |
| D29 | As planned: at launch (after the sessions are known and the notebook is open), every 24 h (an hourly tick), 1 s after a retention setting changes. |
| D30 | As planned with the grace; sessions whose holder is still alive are never archived or trashed; 封存 now keeps `archivedAt` in memory (fix). |
| D31 | As planned; FILES has no bulk 封存 (images, rings and Recent entries can only be kept or trashed); digest periods: weekly every Monday 09:00, biweekly every other Monday from 2026-01-05, monthly the first Monday; once per period, ≥ 5 candidates, no sound. |
| D32 | As planned; posix_spawn with SETSID, stdin / stdout / stderr files in the run folder, 2 MiB output cap; CODD's H1 replaces Claude's first H1 and a `## 濃縮自` list follows; the run's MCP caller is read only (global notes + its sources). |
| D33 | As planned; rows whose integration is missing are disabled with a reason (gate flags). |
| D34 | §8. |
| D35 | As planned; a ninth mock note `打卡頁 QA 清單` makes the drawer match the Split artboard (mock INBOX 8). |
| D36 | As planned plus the 檔案 menu; ⌘0 became 實際大小 (ui-zoom), CODD 主視窗 moved to ⌥⌘0 (**question for you**). |
| D37–D40 | As planned. |
| D41 | As planned, plus three user-feedback steps after I4a (§10). |

### Added by the components and steps (selection; the full lists are in the step reports)

- **C1–C3:** history in UTC; activity never counts as user activity for AI writes; atomic note saves
  keep Finder tags and mode; `/mcp` check order Host → Origin → method → auth → length (an
  unauthenticated GET gets 405); migration of an M3 config.json degrades instead of failing.
- **C4–C8:** the composer chip's document icon omitted; `insertAtCaret` replaces the selection;
  contiguous TextKit layout in the code view; no vertical scroller (the overview ruler is it); the
  dirty-close sheet custom drawn (`不儲存` left, `取消` and `儲存` right); a deferred / non-activating
  popover that never becomes key in background runs; ImageAnnotate Fit floored to 5 % steps.
- **I1a–I4a:** day sections `Today · M/D`, `Yesterday`, `M/D`, `YYYY-MM`; auto-select the first row;
  the tag editor opens from a tag click; scope menu lists Global, the note's projects, then the
  others; COPY REF in mock mode uses port 47821 and a per-run token; Claude Code's button chooses
  移除 when registered with the current token, else 註冊; the drawer leaves the terminal ≥ 200 pt; a
  single file opens in the deepest known project; notebook `.md` files open as note tabs.
- **User feedback:** drop position from the pointer; folders in a mixed drop kept, files ignored,
  packages are files; existing projects revealed and selected; the zoom range 10–20 (terminal 8–28),
  both sizes step together and clamp independently; lengths rounded to whole points at a
  non-default zoom; dialog widths follow the zoom; zooming in grows a too-small window.

### Added in this step (I4b)

- The `registration.claudeCode.plan` dump carries the dialog's masked diff lines and the summary
  (`MCPRegistrationService.PlanFacts.diff`), so the e2e can prove the token is masked (`••••`).
- `debug file-show-ai-changes` logs the hunk headers (`ranges=@@ -40,2 +40,4 @@`), because a later
  `-codd-file-hunk` in the same launch changes the hunks before the dump is written.
- `-codd-condense` with a numbered account waits (≤ 15 s) until cswap's state is read, so a pinned
  condense in a script is not refused with `還在讀取 cswap 的帳號`.
- CLAUDE.md was **not** changed (an agent's task cannot authorize edits to CLAUDE.md); the proposed
  build lines are in §11 for you.

**Questions for you:**
1. ⌘0 is now 實際大小 and 「CODD 主視窗」 is ⌥⌘0. Keep it, or another chord for one of them?
2. Quitting CODD with unsaved file tabs: fix round 1 took the safe default (⌘Q asks with one sheet;
   a quit that cannot ask keeps copies under `files/unsaved/`). Keep it, or another behaviour?
3. FILES rows have no 封存 (only 保留 30 天 / 移到垃圾桶). Keep, or treat 封存 there as 保留 30 天?
4. At the minimum window and UI 字級 20, ImageAnnotate drops its zoom switch and some sheets are
   larger than the window. Acceptable, or a redesign of those screens?
5. The new copy in §8 (not on the artboards).
6. The CLAUDE.md build lines in §11.

## 8. New copy not on the artboards (D34; please review)

- **Notebook:** placeholders `// 選一則筆記 · ⌘⇧N 新增`, `// 筆記本開啟中…`, `// 這個清單沒有筆記`,
  `// 還沒有筆記 · ⌘⇧N 新增`, `// 找不到符合的筆記`, `// 筆記資料夾無法使用：<reason>`; the unsaved
  tooltip `筆記尚未建立：輸入內容後才會存成檔案`, `沒有執行中的 Claude session`; AI menu hints
  `AI 看不到這則筆記（MCP 與引用展開都不提供）`, `AI 可透過 MCP 讀取`, `AI 可讀取，也可以在最後附加內容`;
  send hints `AI 會收到原圖、標註後的圖與座標清單` (and variants), `AI 不會收到這張圖`; history labels
  `AI 附加`, `AI 改寫`, `還原前`, `刪除前`, `外部變更`, `濃縮前`; retention values
  `豁免 · 已釘選/session 使用中/session 讀取過/保留中`, `不會`, `已標示`; the banner `磁碟上的筆記已變更`;
  the compare sheet `HISTORY · 比較版本`, `還原這一版`, `磁碟上的版本`, `你的未儲存版本`, `目前的內容`,
  `左邊選一個較早的版本`, `這一版與目前的內容相同`, `相同`, `還原前會先保存目前的內容`,
  `用橫幅的［重新載入］或［保留我的］決定`; toasts `已封存`, `✕ 已移到垃圾桶 · 30 天後永久刪除`,
  `已取消封存`, `已從垃圾桶還原`, `已複製 <display>`, `已複製全文 Markdown`, `已複製 ID <id>`,
  `已還原 <time> 的版本`, `這則筆記沒有圖片`, `找不到圖片 <name>`, `無法開啟圖片 <name>`,
  `這張圖片沒有出現在內文裡`, `還沒有其他版本`, `無法建立筆記`, `這則筆記的 frontmatter 無法解析，請先手動修正`;
  refusals `本機網址目前無法使用（MCP token 尚未建立）`, `這個引用目前無法使用`, `AI 存取為 OFF，不提供網址`;
  tooltips `先選一則筆記`, `這則筆記在垃圾桶：先從 ⋯ 還原`; menus `標註模式`, `複製引用`; status bar
  `● 未儲存`, `◌ 儲存中…`; end comment `// 顯示最近 n 則，共 N 則`.
- **ImageAnnotate:** color names `琥珀` / `青藍` / `紅` / `綠` / `米白`; `// 還沒有標註 · 選工具後在圖上點按或拖曳`;
  `（尚無說明）`; undo names `新增標註` / `移動標註` / `調整標註大小` / `移動箭頭端點` / `刪除標註` /
  `修改標註座標` / `修改標註說明` / `修改送出選項` / `修改標註顏色` / `編輯標註`.
- **Send and drawer:** `Claude 在等你確認 · 先用下方按鍵回答`, `session 沒有在執行`, `筆記太長，改用插入引用`,
  `這則筆記沒有內容`, `只能送到 CODD 啟動的 Claude session`, `已送到「<session>」`,
  `已放進「<session>」的訊息草稿 · ⌘L`, `// 還沒有連結這個 session 的筆記`, the pill tooltip
  `筆記 · 連結這個 session 的筆記`.
- **MCP and registration:** the prompt refusals `codd：codd://note/<id> 無法展開（AI 存取為 OFF / 這則筆記在 CODD
  垃圾桶 / 這則筆記已永久刪除 / 找不到這則筆記）`; `MCP server 尚未啟動`, `hook server 尚未啟動，無法註冊`,
  `MCP token 尚未建立`, `正在寫入 ~/.claude.json…`, `測試資料根目錄不會寫入 ~/.claude.json`,
  `-codd-claude-json 被拒絕：…`, `~/.claude.json 不是有效的 JSON（…），CODD 不會修改它`,
  `~/.claude.json 的 mcpServers 不是物件，CODD 不會修改它`, `無法寫入 ~/.claude.json（…）`, `無法輪替 token（…）`,
  `~/.claude.json.lock 看起來是殘留的鎖，請確認沒有 claude 在執行後再試`; toasts
  `已註冊到 Claude Code（<path>）· 備份 <name>`, `已從 Claude Code 移除（<path>）· 備份 <name>`,
  `已輪替 MCP token · 已註冊的 client 需要重新註冊`; dialog `MCP 註冊 · 預覽變更`, `預覽 ~/.claude.json 變更`,
  `只動 mcpServers 裡的 codd，其他設定不碰`, `// 沒有需要變更的地方：mcpServers 已是最新`, `移除並備份`,
  the Codex sheet `註冊到 Codex`, `把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）`, `已複製`;
  `輪替 token？`; `notes_write 未開啟：使用者需要在 CODD 設定 › 筆記本 & MCP 打開「AI 可寫入」。可以改用 notes_append。`;
  Settings `— · 每則筆記是一個 .md 檔`, `iCloud Drive M5 提供，自訂… M5 提供`; STATUS
  `// hook server 未執行，MCP 暫停`, `// 沒有 client 連線`.
- **Files:** `// 二進位檔案，無法以文字開啟`, `檔案超過 50 MB，無法開啟`, `無法開啟 <name>（…）`,
  `無法開啟 <name>：不是一般檔案`, `這個檔案是唯讀的`, `磁碟上的檔案已變更：先選［重新載入］或［保留我的］`,
  `磁碟上的檔案已變更，沒有儲存：先選［重新載入］或［保留我的］`, `這個檔案的編碼（<enc>）存不下輸入的字元`,
  `無法儲存 <name>（…）`, `// 從左側選一個檔案 · ⌘P 篩選`, `// 不是 git 專案`, `… 還有 n 個項目`,
  `基準：磁碟上的版本`, `磁碟上的版本 · HH:mm`, `與 git HEAD 不同`, `未儲存的修改`, `找不到資料夾 <path>`,
  the open panel `開啟` / `選擇要在檔案編輯器開啟的資料夾`, menu items `儲存`, `關閉分頁`, `篩選檔案`, `尋找`,
  `檔案（在編輯器開啟專案）`, `這裡無法開啟檔案`, the dirty-close sheet `儲存「<name>」的變更？`
  `[儲存]` `[不儲存]` `[取消]`; quitting with unsaved tabs (fix round 1) `n 個檔案有未儲存的變更`,
  `不儲存的話，這些修改會遺失。`, `[儲存全部]` (one file: the dirty-close sheet's texts).
- **Notebook (fix round 1):** the history label `未儲存的編輯` and the toast `未儲存的編輯已存到 HISTORY`.
- **Cleanup:** `// 這一類目前沒有清理建議`, `// 尚未產生摘要`, `◌ 產生中… <elapsed>`, `[取消]`, `[ERROR] <text>`,
  `mock 模式不會變更任何東西`, `已保留 n 項 · 30 天內不再建議`, `已封存 n 則筆記`,
  `✕ n 則筆記已移到垃圾桶 · 30 天後永久刪除`, `已移到垃圾桶 · n 項`, `沒有移動任何檔案`, `無法封存`, `無法移到垃圾桶`,
  `✻ 已建立「…」· n 則原稿已封存 · n 則長期筆記保留`; SESSIONS / FILES rows `transcript gone`, `無法接續`,
  `停止 n 天 · 無法接續`, `對話紀錄 n 天後刪除`, `最後畫面不會自動刪除`, `筆記與保留的版本都沒有引用`,
  `「<title>」的終端機紀錄`, `最近開啟 · <name>`, `檔案已不存在`, badge `missing`, chips IMAGE / LOG / FILE /
  EXITED / STOPPED; policy `不標示`, `不自動封存`, `tombstone 永久`, `關閉`, `不標示 stale`, `終端機紀錄不自動刪除`,
  `隔週一 09:00 · ≥5 項才提醒`, `每月第一個週一 09:00 · ≥5 項才提醒`, `清理提醒已關閉`; condense
  `hook server 尚未啟動，無法掛載 codd MCP`, `找不到 claude`, `找不到要濃縮的筆記`, `無法準備濃縮工作（…）`,
  `無法啟動 claude（…）`, `claude 的輸出太大`, `超過 180 秒沒有完成，已停止`, `claude 結束碼 n：…`,
  `claude 沒有輸出摘要`, `還沒有摘要`, `無法建立摘要`, `濃縮工作只能讀取筆記`, `測試資料根目錄只用 -codd-claude-path`,
  `AI 存取為 OFF 的筆記不會交給 Claude`, the `## 濃縮自` heading; accounts `使用目前的全域登入`,
  `cswap 的帳號還不能用`, `還在讀取 cswap 的帳號`, `cswap 沒有這個帳號`; the digest `清理建議 · n 項` /
  `筆記 n · session n · 檔案 n`.
- **Sidebar and zoom:** `「<專案名>」已經是專案`, `<n> 個資料夾已經是專案`; UI 字級 `13 px（預設）`, the
  terminal hint `範圍 8–28`; the composer's compact `[ ⏎ ]` send button; the Settings page head's
  shortened filter placeholder `篩選…`.

## 9. Visible deviations from the artboards

From the component and step comparisons (the app-level snapshots of FileEditor, Cleanup, Split,
STATUS MCP and Settings 08 / 09 / 12 of the final binary are pending, §3):
- **Everywhere:** CoreText renders text a little heavier than the artboards' WebKit
  `-webkit-font-smoothing: antialiased`, and some CJK lines break one character differently (CSS
  `text-wrap: pretty`, `text-spacing-trim`); glows that need layer shadows (hover, the current HISTORY
  dot, the expanded annotation item) are approximated or missing; lamps never pulse in the new views.
- **Paths:** the artboards' `~/.codd/notebook` is design copy; the app shows the real
  `~/Library/Application Support/CODD/notes` (mock mode: its temporary folder), so the COPY REF path
  item is truncated.
- **Notebook (C4, C7, I1a, I1b):** mock counts INBOX 8 / PINNED 1 / PROMPTS 2 / STALE 1 / ARCHIVE 0 /
  TRASH 0 (artboard 6 / 2 / 3 / 4 / 34 / 3); n7 appears as a seventh row; BY PROJECT frontend 1; LOCAL
  FILES 0; ASSETS `2 張 · 114 KB`; n1's snippet starts with 問題; the open-section caret is CoddUI's
  triangle; the `+ #` add-tag chip is an addition; mock RETENTION shows `30 天後` (no live sessions
  in mock mode); no paste toast, no raw caret line in offscreen snapshots; long code lines wrap; the
  footer shows `清理建議 15 →`.
- **ImageAnnotate (C8, I1b):** meta `iPhone SE` (artboard `iPhone SE @2x`); the `AI 會收到` text shows
  the full comments; undo / redo drawn at 40 % when empty; CODD-drawn checkboxes; at 200 % the stage
  hint gets a backing plate; list numbers in each item's color.
- **FileEditor (C5, C6, I3):** comments slanted, not true italic; hunk bar texts 1–2 pt off; the
  branch name truncates first at 264 pt (`feat/punch…`); tabs carry AI chips; the drawer's touched
  rows all show `AI HH:mm`; mock hunk time 10:41 (artboard 10:36) and `● 未儲存` for the dirty
  punch.vue (artboard `已儲存 10:39`).
- **Cleanup (C12):** dark CoddUI checkboxes (the artboard's render shows Chrome's light ones); the
  preview-state buttons wrap onto two lines in the 306 px card (the as-drawn idle state matches);
  heights rounded to whole points.
- **Split (C7, I2b):** the drawer render is ~15 pt narrower in the artboard's offscreen WebKit only
  (old-style scrollbar); n1 shows both its images in the drawer card like the artboard although its
  body links one.
- **STATUS / Settings (C9):** `n clients` always plural; `跟隨全域登入（#3 工作）` truncates in the 120 pt
  select; a disabled accent button keeps CoddButton's amber-tinted disabled look.

## 10. 使用者回饋（2026-10-18）

使用者在 M3 版本上提出的六點回饋，M4 加了三個步驟（sidebar-dnd、ui-zoom、layout-sweep）處理前四點；
圖示與產品名稱另外完成（`App/AppIcon.icon` 以 `ASSETCATALOG_COMPILER_APPICON_NAME` 接上；SPEC §10：產品名
稱改為 CODD，bundle id 留到 M5）。

**1. 拖曳排序（session、群組、專案）— 根本原因與修正。** 拖曳本身會開始、放下也被接受，但「放在哪裡」算錯了：
- AppKit 對每一列的中間區域都提議「放在這一列上」（child index −1），只有靠近列的上下邊緣才提議「插在兩列之間」。
  舊的規劃把「放在這一列上」固定解成某一邊（session 放在被指的 session 之前、專案放在被指的專案之後、群組放在
  被指的群組之前），所以把 session 拖到下一個 session 上、把專案往上拖、把群組往下拖，都會落回原位（無變動），
  雖然插入線有顯示。
- AppKit 回報的是指標下最深的那一列：專案拖到另一個專案的 session 列上、群組拖到群組裡面的任何列上都被拒絕，
  於是沒有插入線、放開後彈回去。
- 插入線是 outline 的子視圖但排在列的後面，被列（尤其是目前 session 的亮底）蓋住。

修正：放下的位置改由「指標所在的同層區塊」決定（一個 session 列、一個專案連同它展開的 session、一個群組連同裡面
的一切）：上半部 = 放在它之前，下半部 = 之後；`validateDrop` 與 `acceptDrop` 用同一個規劃，插入線移到最上層。

**2. 從 Finder 拖資料夾成為專案。** 側欄接受 `.fileURL`：放在群組標題上 → 加到該群組最後；放在專案區塊上 → 插在
它前或後；其他位置與 STATE 檢視、篩選中 → 和「新增專案」一樣加到未分類。已是專案的資料夾不重複加入，而是展開、
選取並提示；檔案與 .app 等套件被忽略，混合拖曳時只取資料夾。新增專案 / ⌘O 也走同一條路徑。

**3. 介面縮放（文字大小）。** UI 字級 10–20（設定 › 外觀，預設 13）：所有 Typeface 字型與設計尺寸一起縮放，
每個視窗就地更新；顯示方式 › 放大 ⌘+、縮小 ⌘−、實際大小 ⌘0 同時調整 UI 字級與終端機字級（8–28），存進
preferences.json，重開後沿用；終端機把這些按鍵讓給選單。`CODD 主視窗` 改為 ⌥⌘0（請確認）。

**4. RWD 縮放跑版。** 在最小視窗（UI 13：854 × 560，UI 20：1011 × 560）、1280 與 2560 寬、各種側欄寬度、四個
對話框與每個設定分頁上逐一檢查並修正 28 類問題（列表見 layout-sweep 報告）：次要元件依優先順序隱藏、欄位依序
摺疊、設定列太窄時把控制項放到標籤下方、對話框寬度跟著縮放、放大時視窗自動長到新的最小尺寸。

**自動化（不需要你）：** `-codd-sidebar-drag-test`（用 outline 自己的 drop 路徑與合成的 NSDraggingInfo 跑每一種
拖曳，不送系統事件）、`-codd-drop-folders`、`-codd-zoom`、`scripts/m4-sidebar-dnd.sh`、`scripts/m4-ui-zoom.sh`、
m4-e2e 的 U1 / U2（重開後順序與縮放都保留）、`scripts/m4-layout-sweep.sh`（每個畫面在多種尺寸下的 PNG）、
單元測試 M4SidebarDragDropTests、M4UIZoomTests、M4LayoutSweepTests 與各套件的 LayoutSweepTests。以上都還沒在最後
的測試輪跑過（§3）。

**需要你手動（§6 F）：** 真的用滑鼠拖 session、專案、群組；從 Finder 拖資料夾；⌘+ ⌘− ⌘0；把視窗縮到最小與拉到
全螢幕。自動化不能移動你的滑鼠或送出系統層級的輸入，所以真正的拖曳手感（拖曳門檻、自動捲動、Finder 當來源）
只能由你確認。

## 11. Changes made in this step, and the CLAUDE.md lines

| What | Why |
|---|---|
| `scripts/m4-e2e.sh` (new) | the M4 end to end (B1–B13, U1, U2) |
| `MCPRegistrationService.PlanFacts.diff` / `summary` in the `registration` dump (`App/MCP/MCPRegistrationService.swift`) | B8 checks the masked diff the dialog shows |
| `ranges=` in `debug file-show-ai-changes` (`App/AppDelegate+Files.swift`) | B7's one-hunk check survives a later `-codd-file-hunk` in the same launch |
| `-codd-condense` waits for cswap's state with a numbered account (`App/AppDelegate+Cleanup.swift`) | B11's pinned run was racing the accounts read |
| docs/ARCHITECTURE.md, docs/ROADMAP.md, this report | the M4 docs |

**CLAUDE.md (not changed; proposed for your OK).** The build lines would gain, after the M3 packages:
`M4 packages: CoddNotes, CoddMCP, CoddTextKit, CoddCodeEditor, CoddFiles, CoddNotebookUI, CoddAnnotateUI and
CoddCleanupUI (swift test --package-path Packages/CoddNotes --scratch-path .build-notes, likewise .build-mcp,
.build-textkit, .build-code, .build-files, .build-notebook, .build-annotate, .build-cleanup); demos
codd-markdown-demo, codd-code-demo, codd-files-demo, codd-notebook-demo, codd-annotate-demo, codd-cleanup-demo`;
the end-to-end line would add `scripts/m4-e2e.sh`, `scripts/m4-sidebar-dnd.sh`, `scripts/m4-ui-zoom.sh`,
`scripts/m4-layout-sweep.sh <out dir>` and `bash scripts/m4-fixtures/selftest.sh`; the manual-run line would
point to `scripts/m4-fixtures/README.md` and add `-codd-trash-dir <temp dir>`; and the rules would add
`~/.claude.json` and `~/.codex` to the files tests never touch, plus "git in tests runs only in temp repos
with an isolated config".

## 12. Fix round 1 (2026-10-18)

The first full test run (every package suite, the app tests, `scripts/m4-e2e.sh` twice) and the code
review together confirmed 21 problems. Round 1 fixed all of them, most severe first; each fix has a
regression test where one is practical.

| Id | Problem | Cause | Fix | Regression test |
|---|---|---|---|---|
| test-0 | CoddUI `scaleMathAndClamping` failed (3 issues) | the test: on this toolchain an untyped `14.0 / 13.0` on the right of `==` inside `#expect` compares false although both sides print the same bits (reproduced in a two-line package); the code is right | the expected values are typed (`CGFloat(14) / 13`) | the test itself |
| test-1 | CoddAnnotateUI `thePanelNarrowsSoTheImageKeepsItsRoom` (2 issues) | the same toolchain quirk (`600 - 48 - 260`) | typed `CGFloat(…)` | the test itself |
| test-2 | CoddCleanupUI table 6 pt wider than a 684 pt table | `TableColumns`: a column clamped up to its minimum (AI at 96) overflowed the width, and the overflow was only taken back on a folded table | the excess now comes off the other flexible columns (ITEM first) down to their minimums, then ITEM down to 40 on a folded table | the existing sweep (480–1600 pt) |
| test-3 | CoddSettingsUI: matrix not stacked one point under the grid's width; stepper value `8` not `10` | the matrix ignored the second gap of the 0-wide hint track (`150 \| 1fr \| 150`, gap 16); the stepper test was not updated when the terminal range became 8–28 | `condition - gap < hint` stacks; the test expects `8` | both tests |
| test-4 (1) | app `rowsActionsAndTheBulkBarPerTab`: the NOTE chip missing | the test read the page before the notebook's active notes refreshed (40 ms after each create) | the test refreshes and waits for the chips | the test itself |
| test-4 (2–4) | app M4FilesTests: the AI banner, the session-colored chip and the drawer's touched files missing | `AITouchLog` compared spellings: Foundation's `standardizedFileURL` and `resolvingSymlinksInPath` both drop `/private`, so a hook's `/private/var/…` path (the session's physical cwd) never matched the app's `/var/…` URLs | every touch query matches both spellings (as given, standardized, resolved, `realpath`, with and without `/private` before `/var`, `/tmp`, `/etc`) | `aiTouchesMatchEitherSpellingOfAPrivatePath` (CoddFiles) + the three app tests |
| test-4 (5) | app `mainMenuKeyEquivalentsNeverCollide`: 3 duplicates | the test predates I3: D36 shares ⌘W / ⌘P / ⌘F between the Files mode and the other areas on purpose | the test allows exactly those three pairs and checks `MenuAreaRules` keeps each pair exclusive | the test itself |
| test-4 (6–8) | app sidebar drag tests: nothing dropped | the test window: `contentViewController` shrank it to the view's own 208 × 229 (a 0 pt scroll view), so AppKit's `draggingUpdated` saw no visible row | the rig sets the content size to 300 × 900 | the three tests |
| test-5 | m4-e2e: B3 (2), B7 (4), B10 (1) failed; B9 flaky | B3: the search answer echoes the query (`找不到符合「OFF-NOTE-SECRET-42」的筆記。`), which the check took for a leak; B7: `-codd-open-file` ran before `-codd-new-claude`'s project existed (the notes DEBUG flags raced the session start), so the file opened with `src/pages` as its root, plus the `/private` spelling above; B10: the session shown at the end of the launch took the area away from `-codd-show cleanup`; B9 (flaky): most likely the same race, the debug retention run starting before the live session was known | the checks allow the echo only (title, body sentence and any other occurrence still fail); the notes DEBUG flags wait for the launch's sessions (`launchSessionsReady`) | the e2e itself |
| correctness-1 | an AI append to the open note never reached the editor; the next autosave raised a false `磁碟上的筆記已變更` and 保留我的 dropped the AI block | an AI write is CODD's own write (no watcher event) and only `.changed` was yielded | `OpenNoteCoordinator.didWriteFromAI` after every AI append / write; the editor (no save in flight) adopts it: a clean editor shows the new body in place, newer typing gets the banner at once | `anAIAppendReachesTheOpenEditor` (app), `appendFromAIRules` (CoddNotes) |
| correctness-3 | unsaved note text silently dropped on a note switch, a quick note or quit while the banner showed | `flush()` writes nothing while the banner waits, and `show` / `startDraft` / quit loaded over the buffer | leaving the note first stores the buffer as a HISTORY version (`未儲存的編輯`, also for a composition that kept it from saving), with a toast; the file is not overwritten | `leavingANoteWithTheBannerKeepsTheBufferInHistory` (app), the snapshot part of `appendFromAIRules` |
| correctness-4 / security-data-3 | quitting dropped dirty file tabs without asking | only `QuitPolicy` (sessions) was asked | ⌘Q / 結束 with unsaved tabs returns `.terminateCancel` and shows one sheet (`n 個檔案有未儲存的變更` · `[不儲存]` `[取消]` `[儲存全部]`; one file: the dirty-close texts), then the same quit again; a refused save keeps CODD on that tab; a quit that cannot ask keeps copies under `files/unsaved/` | `aQuitThatCannotAskKeepsUnsavedCopies`, `dirtySheetTakesTheQuitTexts` (CoddFiles) |
| security-data-1 | an AI read wrote `<stem>.annotated.png` beside any image a note links, outside the data root | `annotatedImage` wrote next to whatever image the note body named (absolute, `~/`, `..`) | burned-in copies are written beside an image only inside `<notes>/assets/` (lexically and with symlinks resolved); any other image's copy goes to `<notes>/.codd/annotated/<hash>-<stem>.annotated.png`, and the AI text and the ImageAnnotate preview point there | `annotatedCopiesOfOutsideImagesStayInsideTheNotesRoot` (CoddNotes) |
| correctness-2 | text typed during ⌘S was marked saved; two quick ⌘S refused CODD's own write | `saved()` took the buffer after the write; two writes used the same expected fingerprint | `saved(_:at:text:)` takes the text that was written (the buffer stays, so the tab stays dirty); one write at a time per tab; the disk watcher reads after CODD's own write | `textTypedDuringTheWriteStaysDirty` (CoddFiles), `backToBackSavesNeverRefuseTheirOwnWrite` (app) |
| correctness-5 | Cleanup FILES 移到垃圾桶 on a ring row could move a resumed session's live ring | the manual path skipped the archived / holder-alive check | `trashRing` itself checks (whoever asks); the page also refreshes its candidates when archived or live sessions change | `aRingOfAnUnarchivedSessionIsNeverTrashed` |
| correctness-6 | ⌘0 overwrote a chosen 終端機字級; steps at a bound were not reversible | ⌘0 set both sizes to 13 | `appearance.zoomTerminalSteps` (new key, default 0) counts the terminal's net ⌘+ / ⌘− move; ⌘0 sets the UI to 13 and takes back exactly those steps; ⌘0 is disabled at UI 13 with no steps | `resetTakesBackOnlyTheZoomSteps` (CoddPreferences), `stepsWriteBothSizesAndPersist` (app) |
| security-data-2 | m4-e2e r5 applied a registration against a link to the real `~/.claude.json` (only the guard stopped it) | `-codd-mcp-register-apply YES` on that launch | r5 plans only; the refusal is proven by the plan | the e2e's r5 |
| security-data-4 | CODD's git used this Mac's global and system git config on test roots, and a harness could not override it | `GitReader` strips every `GIT_*` and the app passed none | on any non-standard data root git runs with `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` | `gitOnATestRootIgnoresTheUsersGitConfig` |
| security-data-5 | the Codex snippet (external token) and COPY REF form 5 (`?t=`) went to the pasteboard unmarked | `CoddPasteboard.write` set `.string` only | `write(_:userAction:concealed:)` adds `org.nspasteboard.ConcealedType` and keeps the item off Universal Clipboard (`currentHostOnly`); both token writes use it | `backgroundPasteboardWritesNeverTouchTheGeneralPasteboard` |

**Decisions taken in round 1 (reversible):**
- Quitting with unsaved file tabs asks (⌘Q / 結束); logout, restart, `-codd-quit-after` and dialog D's
  answer never ask and keep copies in `<dataRoot>/files/unsaved/` (§7 question 2).
- ⌘0 keeps the terminal size the user chose: a new preference key `appearance.zoomTerminalSteps`.
- Burned-in copies of images outside `assets/` live in `<notes>/.codd/annotated/` (never beside the image).
- Git on any non-standard data root ignores the global and system git config.
- The notes DEBUG flags run after the launch's sessions are in (DEBUG only).

**Still open after round 1:**
- The unsaved file copies have no restore UI (open them from `files/unsaved/`); they are never cleaned up.
- An AI write while the user types in the same note (after CODD's flush, before the write) shows the
  banner over the AI's version: a real concurrent edit, resolved by 重新載入 / 保留我的.
- The Cleanup page skips a candidate refresh when one is already running (the `trashRing` check still
  protects a live ring).
- Untouched from §5: the C4 display loop, the real-claude / real-`~/.claude.json` / real-cswap / 注音 /
  real-mouse items of §6.
- Test hygiene: a detached write still on its way at a rig's tear-down (the RECENT list after an
  open, the notebook's state.json) recreated `data/…` in the removed temp folder; the Files and
  Cleanup rigs now remove their folder again 3 s later. Eight such folders from runs before round 1
  are still in the per-user temp folder (`codd-m4-digest.*`, `codd-m4f-kinds.*`, `codd-m4f-open.*`,
  `codd-m4f-preview.*`, a few hundred bytes each); round 1 left none.
- B9's flaky check passed in round 1's run; one run is not proof that the race is gone.

**Re-runs (round 1):**

| Suite | Result |
|---|---|
| CoddUI | 43 / 43 passed (also the whole suite) |
| CoddAnnotateUI | 46 / 46 passed |
| CoddCleanupUI | 41 / 41 passed |
| CoddSettingsUI | 83 / 83 passed (after the CoddPreferences change too) |
| CoddFiles | 63 + 18 passed (3 new tests) |
| CoddNotes | 74 passed (1 new test, 2 extended) |
| CoddPreferences | 38 passed (1 new test; the leaf count is 72 with `appearance.zoomTerminalSteps`) |
| App build (`build-for-testing`, Debug, `build/m4fix1`) | `** TEST BUILD SUCCEEDED **`, zero `warning:` lines |
| App tests (`CODD_BACKGROUND=1 xcodebuild test-without-building`) | 605 / 605 in 136 suites, twice (the second after the rig tear-down change); the 8 failing tests of the first run pass, 6 new regression tests in `App/Tests/M4FixRound1Tests.swift` |
| `scripts/m4-e2e.sh` (that build, `CODD_BACKGROUND=1`) | **pass=298 fail=0**, exit 0, run alone once; no process or temp folder left |

Numbers from that e2e run (B13, debug build, this Mac): 1,020-note index 891 ms; notes_search p95
9.3 ms (打), 5.5 ms (打卡), 0.54 ms (打卡頁); notes_read with / without its image median 2.6 / 2.4 ms;
note open (n1) 484 ms; 1 MB JavaScript open 569 ms; 10 MB plain open 883 ms; idle CPU 0.00 % with the
Notebook and with the Files mode shown (3 silent fake claudes), footprint 118 / 104 MB; prompt
expansion round trip 8.5 ms. The other scripts (m1 / m2 / m3 e2e, smoke, self tests, the shortcut
matrix) were not re-run in round 1 (the verify step runs them).

## 13. Post-M4 (2026-10-18)

A small wrap-up after M4, not a milestone.

**Cache folder** (user decision 2026-10-18, 「可以放在 CODD/cache」, chosen over `~/Library/Caches`).
Rebuildable data lives in `<dataRoot>/cache/` (0700, excluded from Time Machine, prepared by
`NotesService.prepareCache` off the main actor at the notebook's open); an update may delete it and
CODD rebuilds it. User data (notes, note images, sessions, layout, preferences, …) stays where it is
and survives every update. docs/ARCHITECTURE.md's data-root tree now marks every entry USER DATA or
DERIVED, with the rule at its top.

- **Notes index:** `<dataRoot>/cache/notes-index.sqlite` (+ `-wal`, `-shm`). A leftover
  `<dataRoot>/notes-index.sqlite` with its `-wal` / `-shm` (an M4 build's) is removed at launch, one
  log line `notes legacy-index removed files=…`; the index is then rebuilt (reason `missing`). Nothing
  else migrates.
- **Burned-in annotated images (D10):** every copy is
  `<dataRoot>/cache/annotated/<hash12>-<stem>.annotated.png` (`<hash12>`: SHA-256 of the image's
  standardized path), never beside the image and never in `notes/` (this also replaces fix round 1's
  `notes/.codd/annotated/`). `NotesLibrary(root:indexURL:annotatedFolder:…)` takes the folder, so the
  package knows no data root. The AI text's `[image] …` line, `notes_read`'s images, prompt
  expansion, Send and the ImageAnnotate `AI 會收到` preview all name the cache copy. A copy is no
  longer an asset: asset counts, Cleanup FILES' unused images and a note's purge never see it; the
  `.annotated.` name rules and `AssetInfo.isAnnotatedCopy` are gone.
- **Stale renders** are collected at every notebook open, inside the notes actor (one listing, an
  xattr read and a stat per file): a copy whose source image is gone (a trashed or purged note's
  assets moved away), whose note is no longer indexed, that has no source xattr (not CODD's), or a
  temp file of an interrupted write. The next AI read renders it again. Log
  `notes annotated-cache removed=<n>` (only when something went).
- M4 never shipped, so old annotated copies are not migrated. An old `<hash6>.annotated.png` still in
  `assets/` on a development root now counts as an ordinary image (Cleanup may offer it as unused
  after 7 days).

**Dock icon:** the bundle's `App/AppIcon.icon` (Icon Composer, every appearance). The old `BrandMark`
app-icon drawing and the `NSApp.applicationIconImage` override were removed (by the orchestrator).

**Live Dock tile** (user decision 2026-10-18, 「dock icon 按照你建議的」). The Dock icon stays still
(`dockTile.contentView = nil`, the bundle icon in the user's icon style). When a session starts
needing the user (the menu bar's attention condition, waiting or error), the d1 icon drawn by CODD
blinks its amber cell slowly 3 times (0.6 s dim, 0.6 s lit), then stays lit (full amber with a soft
glow) until no session needs the user, then the bundle icon returns. It blinks again whenever the
number of sessions needing the user grows; a decrease keeps it lit. 暫停通知: no blink, no lit tile
(when the pause ends with sessions waiting, it blinks). Reduced motion (減少動態, else the system
setting): straight to lit. No Dock icon (顯示於 Dock OFF, background launches): nothing. The badge is
unchanged. New: `App/MenuBar/DockTile.swift` (`DockTileMachine`, `DockTileController` with an
injected clock and scheduler, `DockTileRenderer`), `App/MenuBar/DockTileArt.swift` (the frames:
8-bit sRGB 512 px bitmaps, about 1 MB each, only while attention lasts; no timer outside a blink;
`display()` only when the frame changes); `AttentionMonitor` owns the controller, `applyDockPolicy`
refreshes it. The art follows the macOS grid (824 px continuous-corner square, radius 210 fitted to
the system shape, centered in 1024) with the system's drop shadow and edge light approximated:
against `NSWorkspace.icon(forFile:)` of a fresh-path copy of the built app, the drawn normal frame
differs by 1.15 / 255 on average (2.2 % of pixels above 8 / 255, all on anti-aliased edges);
`build/post-m4-dock/compare.png` shows SYSTEM ICON | CODD DRAWN · NORMAL | DIFF ×4 | DIM | LIT.
DEBUG `-CODDSnapshotDir` now also writes `dock-normal.png`, `dock-dim.png`, `dock-lit.png` (beside
`app-icon.png`). Tests: `App/Tests/PostM4DockTileTests.swift` (normal → blink → lit → normal, growth
blinks again and restarts a running blink, the end of attention mid-blink stops the timer, paused
with its one wake-up, reduced motion before and during a blink, hidden Dock, the observation path
over the mock store and the preferences, the frames' size, depth and colors). Verified by compiling
only (the app and the app test bundle); the targeted test run follows.

**Tests and scripts:** `annotatedCopiesOfOutsideImagesStayInsideTheNotesRoot` is now
`annotatedCopiesAlwaysLandInTheCacheFolder` (assets, outside and `..` images all land in the cache
folder, nothing in `notes/`, the folder inside the data root); new
`staleAnnotatedCopiesAreCollectedAtOpen` (CoddNotes); the annotated-path assertions of
`specNoteText`, `imagePreviewText`, `annotatedCopyIsCached` and the app's annotate test follow the
new location. `scripts/m4-e2e.sh` B1 plants an M4-style index next to `notes/` and checks
`cache/notes-index.sqlite`, that the root has no `notes-index.sqlite` left and the log line; B2 checks
the copy in `cache/annotated/`. Verified here by compiling only (CoddNotes and its tests, the app,
the app test bundle; zero warnings); the targeted test run follows.

**Other DERIVED entries not moved** (listed for a later decision): `hooks/<session-uuid>.json` (the
state engine's last hook record) and `quota.json` (quota snapshots; it also holds
`autoSwitch.lastAt`). The runtime ones stay where they are on purpose: `bin/` copies (named by
running holders, sessions and the global status-line wrapper), `run/` sockets, `codd.lock`,
`sessions/<id>/mcp.json`, `answer.json`, `spawn.env`, `notes/.codd/tmp/`.

**⌘L composer images are temporary** (user decision 2026-10-18, 「暫存可以 24 小時刪除」, the
proposal as offered). A file in `<sessionDir>/attachments/` goes once no unsent draft of that session
names it and 24 h have passed since it was last sent (since it was written, when it never was).
Images pasted straight into the terminal stay libghostty's own 24 h temp files (「終端機的圖檔不另外
存」); notes keep storing theirs.

- **The clock is the file's mtime** (chosen over a record in `composer.json`): writing the file sets
  it, every send of a prompt that names the file sets it again (`utimensat`, no link followed), so the
  rule is one `lstat` per file, survives a lost or corrupt `composer.json`, needs no schema change and
  no migration, and an image a draft kept for days still gets its full 24 h from its send. A program
  that rewrites the file only makes it stay longer.
- **Kept while in a draft:** any session's draft and the text a ↑ walk stashed (the in-memory state
  when loaded, else the saved `composer.json` draft; a prompt may name another session's image, see
  the review fixes below). Files are matched by name after `attachments/`, so an escaped, unescaped
  or old-root spelling of the path all keep it.
- **Sweeps:** at launch, once the sessions are discovered, over `HolderSessionStore.sessionDirectories`
  (all CODD session folders), and after each send of a session (Enter / SEND, the error banner's
  `↻ 重送上一則`, a note's 送出), that session only; no idle timer. Off the main actor on one serial
  queue; the send's own mark is made before its bytes go out (review fixes below). Only regular files directly inside `attachments/`
  whose names are CODD's (`<yyyyMMdd-HHmmss>-<6 lowercase hex>.png`); the session folder and
  `attachments/` are opened with `O_NOFOLLOW`, entries checked with `AT_SYMLINK_NOFOLLOW`; links,
  folders and other names are left alone. Log: `composer attachments sweep reason=launch sessions=<n>
  folders=<n> removed=<n> draft=<n> recent=<n> failed=<n>`, and `reason=send session=<id> …` when the
  session has the folder (a session that never had an image logs nothing per send).
- **Recall:** ↑ / ↓ show an entry's image whose file is gone as `[圖已過期]`, drawn as a muted chip
  (dim text, dimmer border; plain text like the `codd://note/` chips, so what is shown is what is
  sent); the saved entry keeps its path. A send whose text still names a gone image (a draft whose
  file vanished, a path typed in) is refused once: beep, the field shows `[圖已過期]` in its place,
  Enter again sends that. The resend sends `[圖已過期]` in place of a gone image too. A missing path is
  never sent.
- **Unchanged:** deleting a session or 刪除對話紀錄 removes the whole session folder as before;
  Cleanup's FILES rows are rings of archived sessions and note images, so attachments were never
  counted there and nothing changed.
- **Code:** `Packages/CoddComposer/Sources/CoddComposer/ComposerAttachments.swift` (names, the paths
  a text names, `[圖已過期]`, mark and sweep), `ComposerHistory.stashedText`, the chip kinds in
  `ComposerReferenceChips.swift` and `ComposerStyle.expiredChip*`; `ComposerStates`
  (`attachmentsSent`, `sweepAttachments(in:)`, `expiringMissingAttachments`, an injectable
  `attachmentClock`), `PaneComposer` (send guard, mark after a send, recall), the resend in
  `SessionPaneViewController`, one line in `AppDelegate.startRealMode`.
- **Tests:** new `ComposerAttachmentsTests` + `ComposerExpiredChipTests` (CoddComposer: CODD's names
  only, escaped / touching / bracketed / relative paths, a gone image reads as `[圖已過期]`, kept
  while in a draft, removed 24 h after its send and kept at 23 h, a draft image never sent then
  dropped, links and foreign files and linked folders left alone, never another session's folder,
  the stash, the muted chip) and `App/Tests/PostM4AttachmentTests.swift` (send marks and sweeps with
  an injected clock, ↑ recall of a removed image, the refused send; the launch sweep with an in-memory
  draft and stash, a saved draft, a link and a foreign file). Verified by compiling only (CoddComposer
  and its tests, the app and the app test bundle, `build/post-m4-attach`); the targeted test run
  follows.

**Background windows stay behind every app** (user, during a test run, 「不要跳到幕前干擾我」). A
background CODD (DEBUG, `CODD_BACKGROUND=1`, `.accessory`, never activated) still put its main window
directly behind the active app's key window, above every other app. Now every CODD window stays behind
every other app's normal windows in background mode, at launch, on relaunch and on every later
ordering; foreground launches install nothing and behave as before.

- **One hook, installed once** (`App/Window/BackgroundWindows.swift`, from main.swift before any
  window, only when `AppActivation.isBackground`): `NSWindow.orderWindow(_:relativeTo:)` and
  `orderFrontRegardless` turn a front ordering into one just above CODD's frontmost window (a sheet or
  child window: above its parent; none shown: the back of the level), orderings relative to CODD's own
  windows, to the back and out pass; `level` above `.normal` is held at `.normal` (system status-item,
  menu and tool-tip windows untouched); AppKit's private `_orderFrontModalWindow:relativeToWindow:`
  (the `runModal` path, which skips the public methods) is hooked only when present and puts the
  window back in the same call. Chosen over a fixed level below `.normal`: that would leave CODD out of
  the normal layer (zorder-watch's `withOwner` would read 0) and still let a panel's own level float.
  A safety net sinks every window when the window server shows one above another app (resign active,
  unhide; key / main / occlusion changes at most once a second; other background CODD runs do not
  count, so two of them never chase each other, while the user's own CODD does, review fixes below);
  it logs `background windows: sunk behind other apps' windows (<n>)`. The launch logs
  `background windows: kept behind other apps' windows`.
- **A click still brings it forward** (the choice): clicking a CODD window activates it as for any
  app, and while CODD is active, or while a real mouse click is dispatched (`CoddApplication.sendEvent`:
  the status item, a non-activating panel; synthetic key events never count), orderings run unchanged
  and a held panel gets its level back. Leaving CODD sinks its windows behind the other apps again.
- **Unchanged:** drawing and `cacheDisplay` snapshots, key / main window inside CODD, child windows
  attached to their parent, modal loops (they run with the window behind), terminal state and text (a
  covered window is occluded, libghostty pauses drawing only), `isViewing` (a background window counts
  as seen). `AppActivation`'s doc comment and docs/ARCHITECTURE.md ("Background launches") describe it.
- **Verified:** a standalone harness (alpha 0, click-through windows of an accessory app, plus a 3 ms
  window-server sampler for flashes) over `makeKeyAndOrderFront`, `orderFront`, `showWindow`,
  `orderFrontRegardless`, `isVisible = true`, a floating panel, a child panel, `beginSheet`, an `NSAlert`
  sheet, `NSAlert.runModal`, a level change on a visible window, hide + unhide and a status item: without
  the hook every step lands above all other apps; with it every step stays behind them, CODD's own order
  as expected, no flash, the status item at level 25. App build `build/post-m4-bg`, zero warnings.
  `scripts/m1-smoke.sh` pass=22 fail=0 with `zorder-watch 120`: samples=586 withOwner=142 violations=0.
  `ONLY=B2,B7,B10,U1,U2 scripts/m4-e2e.sh` pass=103 fail=0 (319 s) with `zorder-watch 120` back to back
  over the whole run: violations=0 in all three windows (withOwner 508 / 516 / 342). App unit tests not
  run here (the hosted test process installed no hook then; it does since the review fixes below).

**Review and test fixes** (after the wrap-up's own review and test run). Every finding was checked
against the code first; all seven held, none was skipped.

- **Two failing app tests (2 of 616), both races in the tests under load, not regressions.**
  `ComposerTests/pastedImageIsSavedAsAPrivatePNGAndInsertedEscaped` set the field text in code (not an
  edit) 60 ms after opening the composer; when the saved draft's read finished later (the main actor
  busy with the suites running beside it), `PaneComposer.loaded` showed the saved draft (empty) in
  place of the unedited field, so `看 ` was gone and the path stood alone. A temporary probe that set
  the text before the read confirmed it (after the read the field was `""`); the test now awaits
  `states.load("s9")` first. A user's typing is an edit (`editedSinceSwitch`), which a late read never
  replaces, so the product is unchanged. `ResumePickerTests/pickerOverAFixtureCatalog…` stopped the
  session it had just created before its holder was spawned (the picker was faster under load):
  `stop` signals the holder pid, found none and did nothing, so `stopped` never came. The test now
  waits for the holder pid first. Both suites passed in this step before the fix too (the failures
  need load), and after it.
- **zorder-watch** (a scratch helper, not in the repo) wrote to a fully buffered, redirected stdout and
  printed only at its natural end, so a run stopped with SIGINT / SIGTERM left an empty log. It now
  writes line-buffered, prints a start line, each violation as it happens (with the time) and the
  summary on SIGINT / SIGTERM (`… stopped=signal`).
- **Hosted test windows.** The app's unit tests run inside CODD as the test host, which installed no
  window hook, while some tests order windows front (the hover card, sheets, panels): a full test run
  may have put windows over the user's apps (not observed: the earlier watch's log was empty). main.swift now installs `BackgroundWindows` in the hosted
  test process too; `BackgroundWindowsTests/hostedTestWindowsStayBehindOtherApps` checks it with a
  transparent, click-through window (so even a failure shows nothing).
- **attachments-1 (medium).** A path with words touching it (`請幫我看這張截圖裡的錯誤/Users/…`, the
  composer inserts a pasted path at the caret and Chinese has no spaces) was read as one relative
  reference from 請, so a gone image's `[圖已過期]` swallowed the sentence and the check looked in the
  session folder. `ComposerAttachments.references` now starts a path after the last character before
  its first `/` that a relative path would not hold (anything but ASCII letters, digits,
  `._-~+@%=$` and backslash escapes): `看這張/Users/…` names `/Users/…` (absolute, checked where it
  points), `看這張~/…` the relative `~/…`, `截圖:/…` and `看「/…」` the path only.
- **attachments-2.** A send's images are now marked synchronously before its bytes go to the PTY
  (`ComposerStates.markAttachmentsSending`: a few `utimensat` on the main actor) in the composer's
  submit, the resend and a note's 送出, then checked for gone files, then sent; the sweep after the
  send no longer marks. A mark and each file's check-and-unlink of a sweep hold one lock
  (`ComposerAttachments.fileLock`), so a sweep already queued or running at that moment either
  removed the file first (the send then sees it gone and is refused with the chip) or keeps it; no
  queued mark can be lost at quit.
- **attachments-3.** `ComposerAttachments.markSent(in:sessionDirectory:at:)` also marks where an
  absolute path points when that is another session's `attachments/` under the same `sessions/`
  folder (compared without touching the disk, opened with the same no-link rules). Keep sets are
  every session's drafts: the launch sweep builds one set from all in-memory drafts and all saved
  `composer.json` drafts and remembers the saved ones; a send sweep keeps every in-memory draft's
  images plus the remembered saved drafts of sessions not in memory.
- **attachments-4.** `NoteSending.perform(.submit)` marks the composer images the note's text names,
  sends a gone one as `[圖已過期]` and sweeps the session afterwards, like the composer.
- **attachments-5.** A sweep dates a file more than 5 min in the future (`futureSlack`) back to its
  `now` and keeps it (`Sweep.redated`, ` redated=<n>` in the log line when non-zero), so after a
  clock set ahead is corrected the file stays at most 24 h. A clock jumped forward cannot be told
  from the dates; docs/ARCHITECTURE.md states the limit.
- **attachments-6.** `PaneComposer.annotatedCopies` (`AnnotatedCopies`, wired in `wireSending`):
  before a composer send or a resend whose text names a `cache/annotated/` copy that is gone, the
  notes the text references (`codd://note/<id>`, the AI text's header) render theirs again
  (`NotesService.restoreAnnotatedCopies` → `NotesLibrary.renderAnnotatedCopies(of:)`, inside the
  actor, the notebook opened when needed; log `notes annotated-cache restore notes=<n>`); the text is
  then submitted while the field still shows it (a second Enter meanwhile sends nothing; a resend
  goes right after). A copy that does not come back goes as `[圖已過期]`, refused once.
- **dock-bg-1.** The safety net skipped every process with CODD's bundle identifier, the user's own
  Release CODD included (Debug and Release share `app.fancycodd.CODD`). It now skips only another
  background run: `BackgroundWindows.isBackgroundRun(pid:)` reads that process's arguments and
  environment (`KERN_PROCARGS2`, this user's processes) and applies `AppActivation.resolve`; any other
  CODD, or one that cannot be read, counts as another app (the run then sinks, which never hurts the
  user).
- **Code:** `ComposerAttachments.swift`, `ComposerStates.swift`, `PaneComposer.swift` (with
  `AnnotatedCopies`), `SessionPaneViewController.resend`, `NoteSending.swift`, `NotesService.swift`,
  `NotesLibrary+AI.swift`, `AppDelegate+Send.swift`, `BackgroundWindows.swift`, `main.swift`;
  docs/ARCHITECTURE.md (attachments, annotated copies, background launches).
- **Tests:** CoddComposer `wordsWrittenRightBeforeAPathAreNotPartOfIt`,
  `aSendMarksAnotherSessionsImageWhereItsPathPoints`, `aFutureDateIsDatedBackToTheSweep`; app
  `theMarkLandsBeforeThePTYSendAndAQueuedSweepNeverRemovesASentImage`,
  `draftsKeepAndSendsMarkAnotherSessionsImages`, `aNoteSendMarksItsComposerImagesAndNeverSendsAGoneOne`,
  `anAnnotatedCopyGoneFromTheCacheIsRenderedAgainBeforeTheSend` (PostM4AttachmentTests),
  `onlyAnotherBackgroundRunCountsAsCODD`, `hostedTestWindowsStayBehindOtherApps` (`BackgroundWindowsTests` in
  AppActivationTests.swift);
  the two racy tests fixed as above.

| Check (this step, `build/post-m4`) | Result |
|---|---|
| CoddComposer `ComposerAttachmentsTests` + `ComposerExpiredChipTests` | 13 / 13 passed (3 new) |
| App build (`build-for-testing`, Debug) | `** TEST BUILD SUCCEEDED **`, zero `warning:` lines |
| App tests, the two failing suites and the changed areas (`ComposerTests`, `ResumePickerTests`, `ComposerAttachmentExpiryTests`, `ErrorBannerActionTests`, `M4SendTests`, `AppActivationTests`, `BackgroundWindowsTests`, `HoverCardTests`; `CODD_BACKGROUND=1 xcodebuild test-without-building`) | 51 / 51 in 8 suites (with the temporary probe); `ComposerAttachmentExpiryTests` again after removing it: 6 / 6 |
| zorder-watch over this step's app test runs after the fixes (the probe suite, the 51, the 6) | samples=856 withOwner=5 violations=0 (stopped with SIGINT, summary printed) |

Not run in this step (lean testing): the full app suite, the other package suites, the e2e scripts.
