# M4 fixtures

Helper scripts for the M4 integration steps and end-to-end run (`scripts/m4-e2e.sh`, docs/M4-PLAN.md
C11, I1a-I4b): made-up notes in CODD's notes format, a made-up git project for the file editor, a
fake `~/.claude.json`, an aged session layout, a fake `claude` that speaks MCP, prompt hooks,
PostToolUse edits and print mode, and a small MCP client. Bash (`set -euo pipefail`) and
`/usr/bin/python3 -I` (Python 3.9, standard library) only. Every path is an argument. Nothing here
touches `$HOME`, `~/.claude*`, `~/.codex`, the real data root, a real `claude`, cswap or any host
but 127.0.0.1. All content is made up (the SPEC §5 sample is design data).

| Script | What it is |
|---|---|
| `make-png.py` | Writes a PNG with zlib only; `--phone` draws the made-up 750 x 1334 punch-page screenshot of the artboards. |
| `make-notes.sh` | The notes folder: SPEC §5 notes n1-n7, the M4 test notes, `.codd/` state, an image with R6 annotations, a trashed note, history, a tombstone; `--old` back-dates the retention cases; `--count N` adds ~4 KB notes. |
| `make-git-project.sh` | A orb-toolkit-frontend-like repo: the FileEditor artboard's `punch.vue`, `feat/punch-rwd ↑2`, three modified files, CRLF / BOM / Big5 / UTF-16 / Latin-1 / binary / 6 MiB files, ignored files. |
| `make-claude-json.sh` | A fake `~/.claude.json` laid out like Claude Code writes it, with or without a `codd` server. |
| `age-layout.py` | Ages a seeded layout (stopped / archived sessions), writes a dummy `ring`, and `cleanup.json` `retention.firstRunAt`. |
| `mcp-client.py` | A loopback MCP Streamable HTTP client (call / script / get), JSON-line output, never prints a token. |
| `mcp-script-session.jsonl` | The MCP sequence of a CODD session (discover, initialize, tools, search, read, append, OFF read). |
| `fake-claude-m4.sh` | `scripts/m3-fixtures/fake-claude-m3.sh` plus `--mcp-config`, an MCP script, prompt hooks, tool edits, a stdin log and `-p`. |
| `mock-codd.py` | A tiny stand-in for CODD's hook server, used only by the self test. |
| `selftest.sh` | Runs everything in a temp folder and prints `M4FIXTURES pass=<n> fail=0`. |
| `_m4fix.py`, `_selftest.py` | The Python behind the generators and the self test. |

## Safety rules

- **Refused targets (exit 1).** Every writing script refuses a target inside `~/Library`,
  `~/.claude`, `~/.claude.json`, `~/.claude-swap-backup`, `~/.codex`, or inside `~` but not under
  `$TMPDIR`. The check uses the realpath, so a link (dangling or not) into those places is refused
  too. `$HOME` and the account's home from the password database both count as `~`. A refusal
  happens before anything is written.
- **git is isolated.** `make-git-project.sh` runs git only with `GIT_CONFIG_GLOBAL=<empty temp
  file>`, `GIT_CONFIG_NOSYSTEM=1`, `HOME` and `XDG_CONFIG_HOME` pointing at a throwaway temp folder
  (so the user's config, global attributes and excludes never apply), every inherited `GIT_*`
  variable unset, `--template=` (no hooks copied), `-c core.hooksPath=/dev/null` and
  `-c core.fsmonitor=false` (no fsmonitor daemon is ever spawned). Use the same isolation when you
  run git on the fixture yourself:
  `GIT_CONFIG_GLOBAL=<empty file> GIT_CONFIG_NOSYSTEM=1 git -C <repo> --no-optional-locks -c core.fsmonitor=false …`.
- **The fakes stay local.** The fake claude and `mcp-client.py` connect to `127.0.0.1` only (a
  `localhost` url keeps its `Host` header but still connects to 127.0.0.1); `mcp-client.py` refuses
  any other url (exit 2). Tool edits apply only under `FAKE_EDIT_ROOT` and never in a protected
  place.
- **Tokens.** No script prints a token. `mcp-client.py` never prints request headers, reads tokens
  from files (`--token-from-config`, `--note-token-from-config`, `--config`) so none is on a command
  line, masks a URL's `t`, and replaces a token found in a response with `<SECRET-LEAK>`
  (`"secretInBody": true`). The fake claude masks `CODD_HOOK_TOKEN` and runs of >= 32 hex digits in
  its argv lines and logs, and prints `set` / `unset` for secrets and `CLAUDE_CONFIG_DIR`.
  `make-claude-json.sh --codd-ours <url> @<config.json>` reads `mcpToken` itself.
- **No bytecode.** Nothing leaves a `__pycache__` next to the fixtures (`-B` /
  `sys.dont_write_bytecode`).

## Cleanup rule

Every process the fixtures start carries the caller's root path in its argv: copy the fake claude
(and `mcp-client.py` next to it) into your temp root; `mcp-client.py` runs get `--config
<root>/…/mcp.json`; git runs get `-C <root>/…`. `make-*.sh` and `age-layout.py` start no process that
outlives them (git included; the self test proves that no git / fsmonitor process is left). Clean up
with `pkill -TERM -f "<root>/"`, wait, then `pkill -KILL -f "<root>/"`. Never kill anything else.

## make-png.py

```sh
scripts/m4-fixtures/make-png.py <out.png> <w> <h> [--phone] [--seed <n>] [--alpha]
# -> prints <out.png>
```

- 8-bit RGB (colour type 2), one IDAT, filter 0 on every row, written atomically, mode 0600; missing
  parent folders are created 0700. ImageIO (`sips`) reads the files.
- Default picture: a vertical gradient with a 64 px checker. A 4000 x 3000 file is ~0.26 MB and takes
  ~0.2 s (the D9 resize test input). `--seed <n>` shifts the colours: two seeds give different bytes,
  the same seed the same bytes (D9 dedupe / collision tests).
- `--alpha`: RGBA (colour type 6), the top-left 64 x 64 block fully transparent.
- `--phone`: the made-up iPhone SE punch page of the Notebook / ImageAnnotate artboards, defined in
  750 x 1334 coordinates and scaled to `<w> x <h>`:

  | Band | Pixels (750 x 1334) | Colour |
  |---|---|---|
  | background | everything else | `#ecebe6` |
  | status bar | y 0-40 | white |
  | header | y 40-128 (+ rule) | white |
  | clock block | x 175-575, y 266-394 | `#1d1d1d` (R6 point 2 at 375,330 lies on it) |
  | two cards | x 32-718, y 472-600 and 632-1124 | white with `#dcd8cf` borders |
  | button | x 20-730, y 1150-1270 | `#2f6fe0` (R6 rect 1 lies on it; white label at x 290-460) |
  | bottom nav | y 1222-1334, drawn over the button (the bug the note describes) | `#fafaf9` |

## make-notes.sh

```sh
scripts/m4-fixtures/make-notes.sh <notesDir> [--count N] [--old <ISO now>] [--now <ISO>] [--spec|--no-spec]
    [--session <uuid>] [--project <path>] [--two-images] [--text-annotation] [--manifest <file>]
# -> prints the created ids, one per line
```

`<notesDir>` is normally `<dataRoot>/notes` (a `make-root.sh` root). The script refuses (exit 1) a
protected target and a folder that already holds `.md` files; bad arguments exit 2.

| Option | Effect |
|---|---|
| `--spec` (default) / `--no-spec` | Write (or skip) the SPEC + test notes below. |
| `--count N` | Add N generated notes `gen-00001` … under `generated/生成資料-<n>.md`. |
| `--now <ISO>` | Anchor every date at `<ISO>` instead of the current time (deterministic output). |
| `--old <ISO now>` | `--now <ISO>` plus the back-dated retention cases (table below). |
| `--session <uuid>` | The session n1 links (and v2-review-h4n6, for the live-session exemption). Default `7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10` for n1, s6's made-up uuid for v2-review. Lowercased. |
| `--project <path>` | n1's project. Default `~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend` (SPEC). A project-scope note is visible over MCP only to sessions whose cwd is inside it or that it links (D17): **for MCP tests pass the fake session's cwd here** (or `--session` with the CODD session id). |
| `--two-images` | n1 also gets `assets/rwd-punch-k7x2/2b7e04.png` (1334 x 750, no annotations): "2 張圖片" in D19's systemMessage, two image blocks in `notes_read`. |
| `--text-annotation` | n1's annotation block also gets §3.3's text item 4 (`color: cyan`). |
| `--manifest <file>` | Writes a JSON manifest (below). |

Without `--old` every note's last activity is within the last 4 days (nothing is stale or due), so a
retention run at launch changes nothing, whatever the date.

### What is written

```
<notesDir>/                                       0700 (every folder 0700, every file 0600)
  .codd/notebook.json                             {"v":1,"createdAt":"<now - 60 d, UTC>"}
  .codd/state.json                                {"v":1,"notes":{"<id>":{"lastOpenedAt","openCount","lastUserActivityAt","keepUntil":null}}}
  .codd/activity.jsonl                            n1 read by the --session ("打卡頁 RWD 調整", via mcp, 7 min after its update); gear3d-n7q0 read 2 d ago (session null)
  .codd/tombstones.json                           {"v":1,"items":[{"id":"gone-note-g0n3","title":"很久以前刪掉的筆記","trashedAt","purgedAt"}]}
  .codd/history/rwd-punch-k7x2/<yyyyMMdd-HHmmss-SSS>-<hash8>.md   two older versions of n1 (UTC stamps, hash8 = sha256 of the content)
  .codd/history/trashed-idea-t3x1/…               one snapshot
  .codd/trash/2026-09-10-已丟掉的舊想法.md         the trashed note (frontmatter + `trashed: <ISO>`)
  .codd/trash/assets/trashed-idea-t3x1/1a2b3c.png its image (64 x 64)
  assets/rwd-punch-k7x2/9f3a1c.png                n1's screenshot (make-png --phone, 750 x 1334)
  assets/gear3d-n7q0/7e8f90.png                   an image no note references (mtime 1 d ago; 12 d with --old: the unused-image candidate)
  <the note files below>
```

Formats are docs/M4-PLAN.md §3.1-§3.4 exactly. Dates: frontmatter in the anchor's own UTC offset
(`2026-10-17T08:00:00+08:00`, like §3.2); JSON state files in UTC seconds (`2026-10-17T00:00:00Z`).
Each note file's mtime equals its `updated` (D2: a newer mtime would count as activity).
`state.json`'s `lastUserActivityAt` / `lastOpenedAt` equal the note's last activity (`sent` for the
sent PROMPT). Filenames are NFC. Frontmatter key order: `id, title, kind, tags, sessions, projects,
ai, scope, pinned, status, [archived, archivedBy], [sent, sentTo], created, updated, [trashed]`;
empty lists are left out.

### The notes

| id | title | kind | AI | scope | file | notes |
|---|---|---|---|---|---|---|
| `rwd-punch-k7x2` | 打卡頁 RWD 跑版紀錄 | note | read | project | `2026-10-15-打卡頁-rwd-跑版紀錄.md` | n1: tags rwd punch, links `--session` + `--project`, the SPEC body (H2s, a `**bold**` bullet, the image + §3.3 `codd-annotations` block with items 1-3, tasks, a css code block), open count 12 |
| `prompt-401-b3m9` | 給後端的 prompt：401 修正條件 | prompt | read | project | `2026-10-15-給後端的-prompt-401-修正條件.md` | n2: sent (`sent` + `sentTo` s1) 3 h ago |
| `mcp-demo-r8q1` | MCP 示範腳本重點 | note | read | project | `2026-10-10-mcp-示範腳本重點.md` | n3: pinned, project `…/整合範例/MCP` |
| `v2-review-h4n6` | 程式碼審查標準 v2 | note | read | project | `2026-10-12-程式碼審查標準-v2.md` | n4: links `--session` (else s6), a table |
| `quick-scratch-s5c2` | 隨手記 10/15 | scratch | read | global | `2026-10-15-隨手記-10-15.md` | n5 |
| `keynote-p6d1` | keynote 第 3 章大綱 | prompt | read | project | `2026-10-13-keynote-第-3-章大綱.md` | n6: draft (no `sent`), links s11, `~/Github/keynote-deck` |
| `gear3d-n7q0` | Gear3D 載入效能想法 | note | read | project | `2026-09-24-gear3d-載入效能想法.md` | n7: `~/Github/Gear3D`, AI read 2 d ago |
| `ai-append-note` | AI 附加測試 | note | **append** | global | `2026-10-16-ai-附加測試.md` | the APPEND note |
| `ai-off-note` | 不給 AI 的私人紀錄 | note | **off** | global | `2026-10-16-不給-ai-的私人紀錄.md` | body has `OFF-NOTE-SECRET-42`; neither that nor the title may appear in any MCP answer, expansion or URL |
| `global-note` | 全域：常用指令 | note | read | global | `2026-10-16-全域-常用指令.md` | a READ note visible everywhere (`notes_append` must be refused) |
| `cjk-search-note` | 注音輸入法筆記 | note | read | global | `2026-10-16-注音輸入法筆記.md` | `注音輸入法`, `筆記`, `打卡` (not `打卡頁`) |
| `subfolder-note` | 子資料夾裡的待辦 | note | read | global | `work/2026-10-12-子資料夾裡的待辦.md` | a sub-folder note |
| `crlf-note` | Windows 換行測試 | note | read | global | `2026-10-16-windows-換行測試.md` | CRLF throughout (frontmatter too) |
| `daily-log-d9w1` | 每日工作日誌 | note | read | global | `2026-08-01-每日工作日誌.md` | 12 dated H2 sections (3 newer, 9 older than 30 days: `YYYY-MM-DD`, one `M/DD`, one `MM/DD`): the `9 段 > 30d` long note and the D32 long-note source |
| `keynote-ch2-k2d8` | keynote 第 2 章大綱 | note | read | project | `2026-10-12-keynote-第-2-章大綱.md` | near-duplicate of n6, same project (character-trigram Jaccard 0.91 of the bodies) |
| `old-review-r30d` | 舊審查清單草稿 | note | read | global | `2026-09-15-舊審查清單草稿.md` | the 30 d case with `--old` |
| `yaml-subset-note` | YAML 子集測試 | note | read | global | `2026-10-11-yaml-子集測試.md` | frontmatter with a `#` comment line, a double-quoted title, a block list (`tags:` + `  - yaml`, two-space indent as Obsidian writes it), a single-quoted value and unknown keys (`customKey`, `quoted`) |
| `archived-login-a1z9` | 已封存：舊版登入流程 | note | read | global | `2026-09-01-已封存-舊版登入流程.md` | `status: archived`, `archivedBy: user`, 5 d ago |
| (derived by CODD) | 從別處拖進來的 Markdown | | | | `從別處拖進來.md` | no frontmatter (D3 derived id; not printed) |
| `trashed-idea-t3x1` | 已丟掉的舊想法 | note | read | global | `.codd/trash/2026-09-10-已丟掉的舊想法.md` | trashed 2 d ago (31 d with `--old`), with an image and a snapshot |

Printed ids: the 18 frontmatter notes in the table order, then `trashed-idea-t3x1`, then the
generated ids. Expected lists before any retention run: INBOX 18 (17 + the note without
frontmatter), PINNED 1, PROMPTS 2, STALE 0, ARCHIVE 1, TRASH 1; BY PROJECT one note each for
orb-toolkit-frontend (n1), orb-toolkit-backend (n2), MCP (n3), 原型試做 (n4), Gear3D (n7) and two for
keynote-deck.

**Search** (D6; active notes, without `--count`; the self test re-derives this from the files):

| Query | Hits |
|---|---|
| `打卡頁` (MATCH) | `rwd-punch-k7x2` |
| `打卡` (LIKE) | `rwd-punch-k7x2`, `cjk-search-note` |
| `筆記` | `cjk-search-note` |
| `注音輸入法` | `cjk-search-note` |
| `#rwd` | `rwd-punch-k7x2` |
| `RWD 打卡` | `rwd-punch-k7x2` |
| `OFF-NOTE-SECRET-42` | `ai-off-note` (in-app search only; never over MCP) |

**`--old <now>`** (default policy: stale 14 d, archive 30 d, SCRATCH / sent PROMPT 7 d, purge 30 d,
exemptions ON); last activity relative to `<now>`:

| Note | Last activity | Expected retention run |
|---|---|---|
| `gear3d-n7q0` | 21 d 3 h | STALE (`stale 21d`, AI read 2 d ago → `AI 2d 前讀取 → 建議保留`), not archived |
| `old-review-r30d` | 30 d 2 h | archived (`archivedBy: auto`) |
| `quick-scratch-s5c2` (SCRATCH) | 8 d 1 h | archived |
| `prompt-401-b3m9` (sent PROMPT) | sent 8 d 1 h ago | archived |
| `mcp-demo-r8q1` (pinned) | 40 d 1 h | kept (pinned) |
| `v2-review-h4n6` (links `--session`) | 35 d 1 h | kept while that session is live, else stale + archived |
| `trashed-idea-t3x1` | trashed 31 d 1 h ago | purged (file, image, history → the trash target; tombstone) |
| `assets/gear3d-n7q0/7e8f90.png` | mtime 12 d | FILES: unused image (`unused 12d`) |
| everything else | < 4 d | unchanged |

`--count N`: each generated note is ~4.1-4.4 KB (title `生成資料 <n> · <word>`, tags `gen perf`,
global, AI read, updated within the last 10 days so none is stale), mixed CJK / ASCII from a fixed
vocabulary with a fixed seed. Every one contains `效能`, `部署`, `資料庫` and ASCII words; none
contains `打卡`, `筆記`, `注音`, `RWD`, `keynote` or the OFF secret, so the search table above
still holds. 1,000 notes plus the spec notes take ~0.5 s.

**Manifest** (`--manifest`): `{"notesDir", "now", "old", "session", "project", "count",
"expect": {counts, search, mcpInvisible, appendable, longNote, nearDuplicate, trashed, tombstone,
noFrontmatter, retention (with --old), ids}, "notes": [{id (null without frontmatter), title, kind,
ai, scope, pinned, status, path (relative; the trashed one under .codd/trash/), tags, sessions,
projects, updated, activity, sent, archived, trashed, assets, eol, frontmatter}]}`.

## make-git-project.sh

```sh
scripts/m4-fixtures/make-git-project.sh <dir>      # <dir> missing or empty
# -> prints <dir> (absolute, realpath)
```

| Path | Content |
|---|---|
| `src/pages/punch.vue` | 56 lines; lines 13-49 are the FileEditor artboard's (`onMounted(() => store.fetchToday())` … `@media (max-width: 640px) {`), `sticky` 7 times (find `3/7`) |
| `src/components/PunchButton.vue`, `PunchRecordCard.vue` | Vue SFCs |
| `src/main.js`, `src/App.vue`, `src/stores/punch.js`, `index.html`, `vite.config.js`, `public/favicon.svg`, `README.md`, `package.json`, `tailwind.config.js` | the rest of a small Vue + Tailwind project |
| `.gitignore` | `node_modules/`, `.env.local`, `dist/` |
| `node_modules/x/index.js`, `.env.local` | present and ignored (no secrets) |
| `src/legacy-crlf.js` | CRLF only |
| `src/mixed-eol.js` | 4 CRLF + 1 LF lines (`CRLF*`) |
| `src/bom.css` | UTF-8 with BOM |
| `docs/big5.csv` | Big5 bytes of `發票匯出,金額` + 2 rows (not valid UTF-8) |
| `docs/utf16le.txt` | UTF-16 LE with BOM |
| `docs/latin1.txt` | Latin-1 (neither UTF-8 nor Big5) |
| `assets/blob.bin` | NUL bytes in the first 8 KB (binary) |
| `big/large.txt` | exactly 6 MiB of ASCII lines (> 5 MiB: read-only plain mode) |

History (identity `fixture <fixture@localhost>`, fixed dates, so hashes are the same on every run):
`init: orb-toolkit-frontend 打卡頁` (main, 2026-10-13 09:00 +08:00) → branch `feat/punch-rwd`,
pushed to the local bare upstream `<dir>/.git/fixture-upstream.git` as `origin/feat/punch-rwd` →
`feat: 打卡紀錄卡片（窄螢幕）` → `fix: 打卡按鈕 loading 狀態`. Working tree:

```
# branch.head feat/punch-rwd
# branch.upstream origin/feat/punch-rwd
# branch.ab +2 -0
1 .M … src/components/PunchButton.vue
1 .M … src/pages/punch.vue          git diff -U0: one hunk @@ -40,2 +40,4 @@ (position: fixed; bottom: 0; -> the artboard's 4 lines)
1 .M … tailwind.config.js
```

Nothing untracked; the index stat data is refreshed before the script returns, so read-only git
(`--no-optional-locks`) never rewrites `.git/index`. A FAKE_TOOL_EDITS line that changes the file
while keeping SHOW AI CHANGES at one hunk (`@@ -40,2 +40,4 @@`):
`Edit <dir>/src/pages/punch.vue   z-index: 10;→  z-index: 20;` (note the two leading spaces of the old
and new text; the path must not contain spaces, or give it as a JSON string).

## make-claude-json.sh

```sh
scripts/m4-fixtures/make-claude-json.sh <file> [--codd-foreign | --codd-ours <url> <token|@config.json>]
    [--no-mcp-servers] [--project <cwd>]... [--project-codd <cwd>]... [--extra-projects N] [--force]
# -> prints <file>
```

- Layout: `JSON.stringify(x, null, 2)` byte for byte (2-space indent, `"key": value`, non-ASCII
  unescaped, `[]` / `{}` for empty values, no final newline), mode 0600, written atomically.
- Top-level keys in order: `numStartups`, `installMethod`, `autoUpdates`, `theme`, `tipsHistory`,
  `promptQueueUseCount`, `userID`, `firstStartTime`, `projects`, `mcpServers`, `oauthAccount` (the M3
  fixtures' #3 `work@example.com`), `hasCompletedOnboarding`, `lastOnboardingVersion`,
  `cachedGrowthBookFeatures` (the number tokens `12345678901234567890`, `1e21`, `-0`, `1.0`,
  `1.5e-7`, nested arrays), `fixtureStrings` (CJK, escapes, ` `), `subscriptionNoticeCount`.
- `projects`: four made-up `/Users/fixture/…` paths (one CJK), each with `mcpServers` (some empty)
  and Claude's usual per-project keys. `mcpServers`: `pencil-like` (stdio), `stitch-like` (http to
  `https://stitch-like.invalid/mcp` with a `${STITCH_LIKE_KEY}` header). No real host, no token.
- `--codd-foreign`: adds `mcpServers.codd` as a stdio server (D18 → `codd-desktop`).
- `--codd-ours <url> <token>`: adds §3.12's `{"type":"http","url":<url>,"headers":{"X-CODD-Token":<token>}}`
  (url must be `http://127.0.0.1:<port>/…` or `http://localhost:<port>/…`); `@<config.json>` reads
  the token from CODD's config.json `mcpToken`. Outside the `codd` member the file is byte-identical
  to the plain one.
- `--no-mcp-servers`: no top-level `mcpServers` (the installer's "create it" case).
- `--project <cwd>`: a project entry for `<cwd>` with an `mcpServers.local-db`; `--project-codd <cwd>`
  adds `projects[<cwd>].mcpServers.codd` (stdio): a project-scope foreign `codd`.
- `--extra-projects N`: N more made-up projects (4000 → ~3 MB, ~0.2 s) for size tests.
- An existing file is refused (exit 1, unchanged) unless `--force`. The real `~/.claude.json` (also
  through a link) is always refused. Bad arguments exit 2.

## age-layout.py

```sh
scripts/m4-fixtures/age-layout.py <layout.json> [--stopped <session id> <ISO>]... [--archived <session id> <ISO>]...
    [--ring <dataRoot> <session id> <MiB>]... [--first-run <dataRoot> <ISO>]
# -> one line per change: stopped <id> <iso> | archived <id> <iso> | ring <path> <bytes> | first-run <cleanup.json> <iso>
```

- For a layout seeded by `scripts/m2-fixtures/seed-layout.sh` (or written by CODD). Run it while CODD
  is not running (the app rewrites `layout.json`). The layout is rewritten in CoddCore's format
  (version 1, sorted keys, `"key" : value`, 2-space indent, final newline, mode kept); dates are
  JSDate's (`2026-10-09T02:00:00.000Z`).
- `--stopped`: `lastState` `{"kind":"stopped"}` + `lastStateAt`. `--archived`: `archivedAt` (lastState
  untouched unless `--stopped` too). Session ids match case-insensitively; other sessions are
  untouched.
- `--ring`: `<dataRoot>/sessions/<lowercase id>/ring` of that many MiB (0600) and a small
  `holder.log` next to it (D30 moves both).
- `--first-run`: `<dataRoot>/cleanup.json` (§3.4) gets `retention.firstRunAt` (UTC seconds,
  `2026-09-17T02:00:00Z`); every other key is kept; a new file starts as
  `{"v":1,"sessions":{},"files":{},"retention":{…}}`. A date 30 days back ends the D30 grace.
- Refuses (exit 1) protected targets, an unknown session (nothing written) or an unreadable file;
  bad arguments exit 2.

## mcp-client.py

```sh
mcp-client.py --config <mcp.json|-> [--server <name>] [options] call <method> [<params json>]
mcp-client.py --config <mcp.json|-> [--server <name>] [options] script <jsonl|->
mcp-client.py --url <u> [--header K:V]... [--token-from-config <config.json>] [options] call|script …
mcp-client.py [--note-token-from-config <config.json> <id>] get <url>
# options: --token <t>  --bearer  --no-session  --origin <o>  --protocol <v>  --init  --timeout <s>
```

- **Connection.** `--config`: the url and headers of one server of a Claude MCP config (the
  per-session `<sessionDir>/mcp.json`, a run's `mcp.json`); default server = the first http server
  on a loopback url; `-` reads the config from stdin. `--url` + `--header`: no config;
  `--token-from-config <config.json>` sends CODD's external `mcpToken` as `X-CODD-Token` (with
  `--bearer` as `Authorization: Bearer`).
- **Overrides for negative tests.** `--token` replaces the token value, `--no-session` drops
  `X-CODD-Session`, `--origin` adds an `Origin` header, `--protocol` sends `MCP-Protocol-Version`
  before / without an initialize. `--init` (call mode) sends initialize + notifications/initialized
  first.
- **Requests.** `POST` with `Content-Type: application/json`, `Accept: application/json,
  text/event-stream`, the config's headers; after an initialize answer `MCP-Protocol-Version` is its
  `protocolVersion` (and an `Mcp-Session-Id` reply header is echoed). Methods under
  `notifications/` are sent without an id. SSE answers are read too (the last `data:` JSON).
- **Output.** One JSON line per response: `{"label"?, "method", "id", "tool"? (tools/call),
  "status", "contentType", "ms", "body"}` (`status` 0 + `"error"` when the connection fails). Image
  blocks become `{"type":"image","mimeType",…,"image":{"mimeType","bytes","size":[w,h]}}` (PNG,
  JPEG, GIF, WebP sizes), resource blobs `{"blob":{"bytes"}}`. A token found in a response is
  replaced by `<SECRET-LEAK>` and the line gets `"secretInBody": true`.
- **get.** `--note-token-from-config <config.json> <id>` computes `t` = the first 24 hex of
  HMAC-SHA256(`mcpToken`, `codd-note-url-v1:<id>`) (§3.9) and appends it. Prints `{"method":"GET",
  "url" (t shown as ••••), "status", "contentType", "bytes", "ms", "body"}`.
- **Exit codes.** 0 whatever the HTTP status, 1 when a connection fails (script mode stops there),
  2 for bad arguments or a url that is not loopback http.

**Script lines** (JSONL; blank lines and `#` lines are skipped):

```
{"method": "initialize", "params": {...}}          a request (ids 1, 2, … unless "id" is given)
{"method": "notifications/initialized"}            a notification (also "notify": true)
{"tool": "notes_read", "arguments": {"ref": "x"}}  shorthand for tools/call
{"raw": "{bad json"}                               a raw body (parse error test)
{"sleep": 200}                                     wait 200 ms, no output
per line: "label", "id", "origin", "token", "bearer": true, "noSession": true, "protocol", "headers": {...}
```

`mcp-script-session.jsonl` is the session sequence (labels `discover`, `initialize`, `initialized`,
`tools`, `search` (`打卡`), `read` (`rwd-punch-k7x2`), `append` (`ai-append-note`), `append-read-note`
(`global-note`, must be isError), `read-off` (`ai-off-note`, must be isError), `resources`).

## fake-claude-m4.sh

A copy of `scripts/m3-fixtures/fake-claude-m3.sh`. Everything in scripts/m3-fixtures/README.md
"fake-claude-m3.sh" (and the M2 README it builds on) still holds: the sidecar `<copy>.env`,
`FAKE_REGISTRY_DIR` (`auto` too), `FAKE_PRINT_ENV` with masked secrets, `FAKE_LOG_DIR`,
`FAKE_STOP_DELAY_MS`, DA1, bracketed paste / typed input, `FAKE-EXIT`, `FAKE-CLEAR`, the status
line runner, the fake `/login`, signals, the bash polyglot (keep `_M4_SHELL_END=0` as its last line).
It differs in these ways:

- **Title / version.** OSC 0 title `fake claude m4`; `--version` and the registry say `2.1.302`.
- **argv parsing like commander.** Value flags (`--settings`, `--session-id`, `--resume`, `--model`,
  `--output-format`, `--permission-prompts`, …), variadic flags (`--mcp-config`, `--allowedTools`,
  `--tools`, `--disallowedTools`, `--add-dir`, `--betas`: every following argument that does not
  start with `-` (an empty `""` is a value)), booleans (`-p`, `--strict-mcp-config`,
  `--no-session-persistence`, `--remote-control`, …), `--flag=value`, `--`. `FAKE-ARGV` shows an
  empty argument as `""`, inline JSON as `<json:NB>` and masks the hook token and long hex runs; the
  `FAKE_LOG_DIR` json `argv` is masked the same way (otherwise exact).
- **Hooks per event.** Each event goes to its own `--settings` http handler: its url, its headers
  interpolated like Claude (`$VAR` / `${VAR}` resolve only for names in `allowedEnvVars`, every other
  reference becomes empty; `FAKE_HEADER_BLANK=<names>` blanks listed names like Claude's credential
  rule), its timeout. An event without a handler falls back to `CODD_HOOK_URL` (or the
  UserPromptSubmit url) with `X-CODD-Token` / `X-CODD-Session` from the environment (the M3
  behaviour). So with D18's settings UserPromptSubmit goes to `/hooks/prompt` and every other event
  to `/hooks`. Answers are read like Claude: empty → `{}`, otherwise it must be a JSON object; a
  `systemMessage` is printed as `FAKE-SYSTEM-MESSAGE <text>` (one line per line).

### New settings (sidecar or environment)

| Setting | Effect |
|---|---|
| `FAKE_MCP_SCRIPT=<jsonl>` | After `FAKE-READY`: `mcp-client.py --config <mcp config> [--server <n>] script <jsonl>` once; every result line is appended to `FAKE_MCP_LOG` verbatim and printed as a `FAKE-MCP` line. |
| `FAKE_MCP_LOG=<file>` | JSONL of the client's result lines (MCP script and `FAKE_P_MCP`). |
| `FAKE_MCP_SERVER=<name>` | The server to use; default the first http server on a loopback url over all `--mcp-config` files (CODD's `codd` / `codd-desktop`). |
| `FAKE_MCP_CLIENT=<path>` | The client; default `mcp-client.py` next to the fake (copy it there) or next to the fake's realpath. Missing: `FAKE-MCP-CLIENT-MISSING`. |
| `FAKE_MCP_TIMEOUT_S` | Kill the client after this (default 60). |
| `FAKE_PROMPTS=<file>` | After the MCP script (and `FAKE_PROMPT_DELAY_MS`, default 0): each non-empty line is a prompt: UserPromptSubmit `{"hook_event_name","session_id","cwd","prompt","permission_mode"}` to the UserPromptSubmit handler, then Stop after `FAKE_STOP_DELAY_MS`, one turn after the other (registry busy meanwhile). |
| `FAKE_PROMPT_LOG=<file>` | JSONL per UserPromptSubmit answer (file and typed prompts): `{"v":1,"source":"file"\|"typed","prompt","status","bytes","ms","valid","body"(parsed JSON or null),"raw"?(invalid answers)}`. |
| `FAKE_HEADER_BLANK=<names>` | Comma-separated env names never interpolated into hook headers (emulates Claude blanking a credential-looking variable: every CODD hook then gets 401). |
| `FAKE_TOOL_EDITS=<file>` | Edit lines (below), after `FAKE_TOOL_EDIT_DELAY_MS` (default 0, counted from `FAKE-READY`). |
| `FAKE_EDIT_ROOT=<dir>` | Edits are applied only to files under this folder (realpath); others are posted but not applied. Unset: nothing is applied. |
| `FAKE_TOOL_EDIT_ATOMIC=1` | Write temp + rename (new inode, mode kept) instead of in place (truncate + write, inode kept, like Claude's Edit). |
| `FAKE_STDIN_LOG=<file>` | JSONL of the input: `{"at","kind":"paste","text"}` (exact text, CR kept), `{"kind":"line","text"}`, `{"kind":"submit","prompt","pasted"}`, `{"kind":"key","hex"}`, `{"kind":"command","text"}`. |

**Edit lines** (`FAKE_TOOL_EDITS`; blank and `#` lines skipped):

```
Edit <path> <old>→<new>          replace the first <old> (PostToolUse; PostToolUseFailure + `no-match` when absent)
MultiEdit <path> <old>→<new>     the same with tool_input.edits
Write <path> →<content>          write the whole file (created when missing)
NotebookEdit <path> <old>→<new>  tool_input.notebook_path
Edit <path>                      post only, change nothing (`posted-only`)
sleep <ms>                       wait (so CODD can open and dirty the file first)
Hook <Event> [<json object>]     post that hook event with the extra payload fields
                                 (e.g. Hook PermissionRequest {"tool_name": "Bash", "tool_input": {"command": "npm test"}})
```

`<path>` is absolute, relative to the session cwd (posted as given, D26 resolves it), or a JSON
string literal for paths with spaces. In `<old>` / `<new>`: `\n`, `\t`, `\r`, `\\`, `\uXXXX`. The
PostToolUse payload: `{"hook_event_name":"PostToolUse","session_id","cwd","permission_mode",
"tool_name","tool_input":{"file_path",("old_string","new_string","replace_all")|("content")|("edits")},
"tool_use_id","tool_response":{"filePath","success":true}}`. The batch is a turn (registry busy);
Stop is posted after a batch that ran at least one edit line, so a batch of only `Hook` lines (a
PermissionRequest) leaves the session WAITING.

### Output contract additions (interactive)

| Line | When |
|---|---|
| `FAKE-MCP-CONFIG <path>` | One per `--mcp-config` value, in argv order, right after the FAKE-ENV lines. |
| `FAKE-MCP-SERVER name=<n> type=<t> url=<u\|-> headers=<names\|-> config=<index>` | One per server (header names only). |
| `Error: Invalid MCP configuration: <path>` + exit 1 | A missing or invalid config (Claude aborts startup the same way). |
| `FAKE-SETTINGS prompt-url=<url\|-> allow=<rules\|->` | After `FAKE-CLAUDE`: the UserPromptSubmit url and `permissions.allow`. |
| `FAKE-MCP <method> <code> [label=…] [details]` | `<code>` = the JSON-RPC error code when the answer is an error (then `http=<status>`), else the HTTP status (`000` = no connection). Details: initialize `protocolVersion=<v>`; tools/list `tools=<names>`; tools/call `tool=<name> isError=<bool> images=<n> chars=<n>`; resources/list `resources=<n>`; `SECRET-IN-BODY`. |
| `FAKE-MCP-DONE exit=<rc\|timeout> lines=<n>` | After the client run. |
| `FAKE-PROMPT-HOOK <status\|000> <bytes>` / `FAKE-PROMPTS-DONE <n>` | Per FAKE_PROMPTS line / after the last turn's Stop. Typed prompts keep the M3 `FAKE-HOOK UserPromptSubmit <status>`. |
| `FAKE-SYSTEM-MESSAGE <text>` | A hook answer's `systemMessage`. |
| `FAKE-TOOL-EDIT <path> <status\|000> <applied\|posted-only\|refused-outside-root\|refused-protected\|no-match>` | Per edit line; `FAKE-HOOK <event> <status>` per Hook line; `FAKE-TOOL-EDIT-BAD line=<n>`; `FAKE-TOOL-EDITS-DONE <n edits>`. |

### Print mode (`-p` / `--print`, D32)

What CODD's condense run starts: `claude -p --model <m> --output-format text --tools ""
--permission-prompts none --strict-mcp-config --mcp-config <run>/mcp.json --allowedTools
mcp__codd__notes_read --no-session-persistence` with the prompt on stdin.

- stdout carries **only the result**: `FAKE_P_OUTPUT` (a file, printed as is), else the default
  summary `# 摘要 · <M/D> 清理（<n> 則）` + one `## <title>` per distinct `codd://note/<id>` in the
  input (title = the nearest `# ` line above its first mention) with `- 來源：codd://note/<id>` and
  `- 重點：<first content line>`. `<M/D>` = `FAKE_P_DATE`, else today's local date.
  `--output-format json` wraps it as `{"type":"result","subtype":"success","is_error":false,"result",…}`.
- stderr (and `FAKE_LOG_DIR/fake-<pid>.log`) gets:
  `FAKE-P-ARGV <argv as FAKE-ARGV shows it>`,
  `FAKE-P-ENV CODD_HOOK_TOKEN=set|unset CODD_SESSION_ID=set|unset`,
  `FAKE-P-ENV CLAUDE_CONFIG_DIR=set|unset` (the value is never printed),
  `FAKE-P-FLAGS model=… output-format=… tools=<JSON list> permission-prompts=… strict-mcp-config=yes|no mcp-config=<n> allowedTools=<list> no-session-persistence=yes|no prompt=argv|stdin`,
  `FAKE-MCP-CONFIG` / `FAKE-MCP-SERVER` lines, `FAKE-P-STDIN bytes=<n> refs=<n>`, the `FAKE-MCP` lines
  of `FAKE_P_MCP`, `FAKE-P-OUTPUT bytes=<n>`, `FAKE-P-EXIT <code>`.
- `FAKE_LOG_DIR/fake-<pid>.json`: `{"pid","mode":"print","argv" (masked, otherwise exact),"cwd",
  "flags":{model, output_format, tools, permission_prompts, strict_mcp_config, mcp_configs,
  allowed_tools, no_session_persistence, prompt},"env":{CODD_HOOK_TOKEN, CODD_SESSION_ID,
  CODD_HOOK_URL, CLAUDE_CONFIG_DIR: "set"|"unset"},"stdinBytes","refs","startedAt"}`.
- Settings: `FAKE_P_INPUT=<file>` (stdin copied byte for byte, 0600), `FAKE_P_OUTPUT=<file>`,
  `FAKE_P_EXIT=<code>` (default 0), `FAKE_P_DELAY=<seconds>` (default 0; a SIGTERM during it exits
  143 at once), `FAKE_P_MCP=1` (one `notes_read` of the first ref through its `--mcp-config`:
  discover, initialize, initialized, tools/call; lines into `FAKE_MCP_LOG`), `FAKE_P_DATE`.
- No registry file, no DA1, no hooks. No stdin and no prompt: Claude's `Error: Input must be
  provided either through stdin or as a prompt argument when using --print`, exit 1. A missing or
  invalid `--mcp-config` aborts with exit 1.

## mock-codd.py (self test only)

```sh
mock-codd.py --config <codd config.json> --port-file <file> [--log <jsonl>] [--port <n>]
```

Not CODD: canned answers in the wire shapes of §3.9 / §3.10 / D16 / D19 for the self test. 127.0.0.1
only; auth like D16 (hook token; per-session HMAC token with `X-CODD-Session`; the external
`mcpToken` as `X-CODD-Token` or Bearer); foreign `Origin` 403; `server/discover` -32601;
notifications 202; `GET /mcp` 405; `/hooks` 204; `/hooks/prompt` 200 with `systemMessage` +
`additionalContext` for a ref, else 204; `/n/<id>.md?t=` 200 / 404 / 410. Its log masks
`X-CODD-Token` / `Authorization` as `<set>`.

## selftest.sh

```sh
bash scripts/m4-fixtures/selftest.sh        # KEEP=1 keeps the temp folder
```

Runs in one fresh mktemp folder (also its `TMPDIR`) and checks, in about 20 s:

- **make-png.py:** sizes, CRCs, filter bytes, the phone bands under the R6 rect and point, RGBA,
  seeds, `sips` decoding, refusals, usage errors.
- **make-notes.sh:** the printed ids, every note through a §3.2-subset parser (key order, values,
  H1 mirror, dates, mtime = `updated`, modes 0600 / 0700), n1's image line + annotation block +
  tasks + code block + PNG, the OFF note, the note without frontmatter, the sub-folder and CRLF
  notes, the YAML subset note, the daily log's dated sections, the near-duplicate Jaccard,
  `state.json` / `activity.jsonl` / `tombstones.json` / `notebook.json`, the trash and history
  layout, the manifest counts and search table re-derived from the files; `--two-images` /
  `--text-annotation`; `--old` ages and the retention expectations re-derived with the default
  policy; `--count 1000` (time, sizes, vocabulary); refusals and usage errors.
- **make-git-project.sh** under a hostile user git config (wrong identity, fsmonitor on, autocrlf,
  gpg, a template hook, global attributes and excludes, `GIT_DIR` / `GIT_CONFIG_PARAMETERS` set):
  status (branch, upstream, `+2 -0`, three `.M`), commits, the one hunk `@@ -40,2 +40,4 @@`,
  punch.vue's artboard lines, ignored files, every encoding's bytes, the bare upstream,
  `.git/index` untouched by read-only git, reproducible hashes, the suggested edit line, no git /
  fsmonitor process left, refusals, usage errors.
- **make-claude-json.sh:** the exact JSON.stringify layout (raw number tokens kept), key order,
  `--codd-foreign` / `--codd-ours` (byte-identical outside the member), `--no-mcp-servers`,
  `--project(-codd)`, `--extra-projects`, `--force`, refusals (incl. a dangling link to
  `~/.claude.json`), usage errors.
- **age-layout.py** on a `seed-layout.sh` layout: format, the aged fields, other sessions untouched,
  ring + holder.log, cleanup.json (new and merged), refusals, usage errors.
- **mcp-client.py** against mock-codd.py: call / script / get, headers, protocol version handling,
  image summaries, parse errors, every override, the leak marker, `--config -`, exit codes.
- **fake-claude-m4.sh** under a pty against mock-codd.py: argv and MCP config lines, masked env,
  FAKE-SETTINGS, SessionStart, the shipped MCP script, prompts (logs, systemMessage, header
  interpolation), tool edits (results, file contents, payloads, the delay and `sleep`), typed /
  pasted input and the stdin log, the registry, FAKE-CLEAR, FAKE-EXIT; without a tty:
  `FAKE_HEADER_BLANK`, `FAKE_TOOL_EDIT_ATOMIC`, `FAKE_MCP_SERVER`, `Hook` lines; invalid / missing
  MCP configs; `--version` (also through bash).
- **print mode:** stdout, the exact D32 argv line, env lines (token / profile path never printed),
  flags, stdin copy, `FAKE_P_MCP`, the JSON log, `FAKE_P_OUTPUT` / `FAKE_P_EXIT` / `FAKE_P_DELAY`,
  `--output-format json`, no-input error, variadic parsing, SIGTERM.
- **No token anywhere:** every hook token, mcpToken and derived session token of the run (and the
  fake profile path) is absent from every file outside `<tmp>/secret-inputs`.
- **Hygiene:** `bash -n` on every `.sh`, Python compilation, the bash polyglot, no `__pycache__`,
  no process carrying the temp folder left.

It prints `M4FIXTURES ok|FAIL …`, `M4FIXTURES number …` lines and `M4FIXTURES pass=N fail=M`, and
exits 1 on any failure.

## Recipes

Every CODD launch: `export CODD_BACKGROUND=1`, a bash array with every flag as its own argument,
`-codd-data-root <fresh temp>` and `-codd-claude-dir <temp>`, `-codd-login-env NO`,
`-codd-notifications NO`, `-codd-trash-dir "$T/trash"`.

**A root with notes (I1a, B1):**

```sh
T="$(mktemp -d "${TMPDIR%/}/codd-m4.XXXXXX")"; T="$(cd "$T" && pwd -P)"
scripts/m2-fixtures/make-root.sh "$T/data" >/dev/null
mkdir -p "$T/home/.claude/sessions" "$T/work"
bash scripts/m4-fixtures/make-notes.sh "$T/data/notes" --project "$T/work" --manifest "$T/notes.json" >/dev/null
```

**A fake claude session with MCP, prompts and edits (I2a, I3, B3-B7):**

```sh
mkdir -p "$T/bin"
cp scripts/m4-fixtures/fake-claude-m4.sh "$T/bin/fake-claude"
cp scripts/m4-fixtures/mcp-client.py "$T/bin/mcp-client.py"
printf '看一下 codd://note/rwd-punch-k7x2\n' >"$T/prompts.txt"
cat >"$T/bin/fake-claude.env" <<EOF
FAKE_REGISTRY_DIR=auto
FAKE_DEFAULT_CLAUDE_DIR=$T/home/.claude
FAKE_LOG_DIR=$T/fakelog
FAKE_STATUSLINE_INTERVAL_MS=0
FAKE_MCP_SCRIPT=$PWD/scripts/m4-fixtures/mcp-script-session.jsonl
FAKE_MCP_LOG=$T/mcp.jsonl
FAKE_PROMPTS=$T/prompts.txt
FAKE_PROMPT_LOG=$T/prompts.jsonl
FAKE_STDIN_LOG=$T/stdin.jsonl
EOF
args=(-codd-data-root "$T/data" -codd-claude-dir "$T/home/.claude" -codd-login-env NO -codd-notifications NO
      -codd-trash-dir "$T/trash" -codd-claude-path "$T/bin/fake-claude" -codd-new-claude "$T/work"
      -codd-dump-state "$T/dump.json" -codd-quit-after 20)
CODD_BACKGROUND=1 "$APP" "${args[@]}" >"$T/app.log" 2>&1
grep '^FAKE-MCP ' "$T"/fakelog/fake-*.log          # discover -32601, initialize 2025-11-25, tools, …
```

For the file editor add `bash scripts/m4-fixtures/make-git-project.sh "$T/work/frontend"`, start the
session in `"$T/work/frontend"`, and put into the sidecar `FAKE_TOOL_EDITS=$T/edits.txt`,
`FAKE_TOOL_EDIT_DELAY_MS=6000`, `FAKE_EDIT_ROOT=$T/work`, with `edits.txt` =
`Edit $T/work/frontend/src/pages/punch.vue   z-index: 10;→  z-index: 20;`. For a WAITING session
use an edits file with only `Hook PermissionRequest {"tool_name": "Bash", "tool_input": {"command": "npm test"}}`.

**External MCP token and the note URL (B3):**

```sh
scripts/m4-fixtures/mcp-client.py --url "http://127.0.0.1:$PORT/mcp" --token-from-config "$T/data/config.json" --init call tools/list
scripts/m4-fixtures/mcp-client.py --url "http://127.0.0.1:$PORT/mcp" --header X-CODD-Token:wrong call tools/list      # 401
scripts/m4-fixtures/mcp-client.py --config "$T/data/sessions/<id>/mcp.json" --origin http://evil.example call tools/list  # 403
scripts/m4-fixtures/mcp-client.py --note-token-from-config "$T/data/config.json" rwd-punch-k7x2 get "http://127.0.0.1:$PORT/n/rwd-punch-k7x2.md"
```

**Registration (I2b, B8):** `bash scripts/m4-fixtures/make-claude-json.sh "$T/claude.json"` (or
`--codd-foreign` at `"$T/home/.claude.json"` = `<claudeDir>/../.claude.json` for the D18 name
resolution), then `-codd-claude-json "$T/claude.json"`.

**Retention (I4a, B9):**

```sh
NOW=2026-10-17T10:00:00+08:00
bash scripts/m4-fixtures/make-notes.sh "$T/data/notes" --old "$NOW" --session "$LIVE_SESSION" >/dev/null
M="$(scripts/m2-fixtures/seed-layout.sh "$T/data" "$T/work")"
scripts/m4-fixtures/age-layout.py "$T/data/layout.json" --stopped "$SID" 2026-10-09T10:00:00+08:00 \
    --archived "$AID" 2026-09-16T10:00:00+08:00 --ring "$T/data" "$AID" 1 --first-run "$T/data" 2026-09-17T10:00:00+08:00
# then -codd-now "$NOW" -codd-retention-run YES -codd-trash-dir "$T/trash"
```

**Condense (I4a, B11):** the same fake copy is the `-codd-claude-path`; add `FAKE_P_INPUT=$T/p-input.txt`
(and `FAKE_P_MCP=1`, `FAKE_P_DATE=10/17`) to its sidecar; the argv / env lines are in
`$T/fakelog/fake-<pid>.json` and `.log`.

## Known limits

- **C1 is built in parallel.** The formats follow §3.1-§3.4 to the letter, but they are not yet
  checked against CoddNotes. Three things to watch when I1a first opens the fixture: the
  yaml-subset note's two-space-indented block list (the subset must accept it, or that note shows as
  unparsable); history snapshot names are stamped in UTC (C1 may choose local time; only the
  displayed time would differ); the note without frontmatter gets C1's derived id, which this
  script cannot print.
- **The near-duplicate pair** is about 91 % similar (character trigrams), not the artboard's 82 %,
  to stay clear of the 80 % threshold however C1 normalises the text.
- **The fake claude** models the hook / MCP / print-mode surfaces CODD uses, not Claude itself: no
  model, no transcript, no tool permission flow beyond what `Hook` lines post, no MCP over stdio,
  no `${VAR}` expansion inside MCP configs, no `--resume` picker. Typed prompts post UserPromptSubmit
  to the settings handler (`/hooks/prompt` with D18), unlike the M3 fake which used `CODD_HOOK_URL`
  for every event.
- **mock-codd.py** is canned data, not CODD's rules; never use it to judge CODD.
- **mcp-client.py** speaks JSON (and reads SSE answers) over one POST per message; it does not keep
  a GET stream, retry, or do OAuth.
