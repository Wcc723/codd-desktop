# CODD Desktop — design-mockup SPEC (single source of truth for all artboards)

You are building artboards for a **Design canvas** (claude.ai Design artifact). Each artboard is ONE self-contained `.dc.html` file.
Product: **FANCY/CODD Desktop**, a local macOS app (Electron 44 + Vue 3 + xterm.js + node-pty, implementation later) that
manages MANY Claude Code sessions. It extends the user's existing web app "FANCY/CODD" (Phosphor Console: black CRT, amber phosphor,
mono type, `[ BRACKET ]` buttons, ASCII corners, dashed rules, glyph lamps). UI copy is **Traditional Chinese (台灣用語)** for
explanatory text + **English UPPERCASE** for structural labels (CODD's bilingual voice). Today in the mock: **2026-10-15 (週四) 10:42**.

Files you MUST use (all paths relative to the scratchpad root `S` given in your prompt):
- `S/spec/helmet.html` — shared fonts + CSS. READ IT (you must know the classes). Do NOT paste it: write the marker `<!--@HELMET-->`
  inside `<helmet>`; the build script inlines it. You may add ONE extra `<style>` block after the marker for board-specific classes
  (prefix them per board, e.g. `.nb-…`), never redefine shared classes.
- `S/spec/shell-sessions.html` — canonical static window shell (traffic lights + rail + SESSIONS sidebar tree). READ IT. Include it with markers:
  `<!--@SHELL on=sessions current=s1-->` (rail + sidebar), `<!--@RAIL on=notes-->` (traffic lights + rail only; on = sessions|notes|status|settings|none),
  `<!--@SIDEBAR current=s9-->` (sidebar only; current = s1…s14|none), `<!--@STATUSBAR-->` (app status bar). Markers go exactly where the
  markup should appear (SHELL/RAIL/SIDEBAR directly inside the `.codd.win` root, before `<div class="main">`).
- Write your SOURCE to `S/src/<Name>.src.html` with the Write tool (whole file), then run `python3 -I S/build_dc.py <Name>` — it writes the
  final self-contained `S/canvas/project/<Name>.dc.html` and lints it (`dc_lint.py`). Fix every ERROR in the source and rebuild until 0 errors.
  Never edit files in `canvas/project/` directly, never touch other boards' files, never touch `canvas/project/canvas.json`.

---------------------------------------------------------------------------------------------------------------------
## 1. Authoring rules (.dc.html) — violations fail SILENTLY, follow exactly

Skeleton (copy):
```html
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<title>主視窗 · Session</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<!--@HELMET-->
</helmet>
<div class="codd win {{ crtClass }}">
<!--@SHELL on=sessions current=s1-->
<div class="main">
  …board content…
<!--@STATUSBAR-->
</div>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"crt":{"editor":"enum","options":["subtle","full","off"],"default":"subtle","section":"Look"},"$preview":{"width":1440,"height":900}}'>
class Component extends DCLogic {
  renderVals() {
    const crt = this.props.crt ?? 'subtle';
    return { crtClass: crt === 'off' ? '' : 'crt-' + crt };
  }
}
</script>
</body>
</html>
```
- Keep `<script src="./support.js"></script>` EXACTLY in `<head>`. `lang="zh-Hant"`. A short unique `<title>`.
- Close EVERY non-void element explicitly (also SVG: `<path …></path>`, `<rect …></rect>`). Quote EVERY attribute value.
- Holes `{{ path }}` are dotted lookups into `renderVals()` ONLY (`{{ cur.title }}`, `{{ $index }}`, literals `{{ true }}`). NEVER an
  expression (`{{ a + b }}`, `{{ !x }}`, `{{ f() }}` fail silently). Compute everything in `renderVals()` and expose by name.
  Interpolated attrs work: `class="srow {{ s.cls }}"`, `style="width: {{ q.pct }}%"` (style holes only for live/state values).
- Events: `onClick="{{ handler }}"` (JSX camelCase, whole-value hole) where the function comes from `renderVals()`. Per-item handlers:
  build them in renderVals: `items: xs.map(x => ({...x, pick: () => this.setState({sel: x.id})}))` and bind `onClick="{{ item.pick }}"`.
- Control flow: `<sc-if value="{{ flag }}" hint-placeholder-val="{{ true }}">…</sc-if>` (no else: use two sc-if with two flags);
  `<sc-for list="{{ items }}" as="item" hint-placeholder-count="3">…{{ item.x }}…</sc-for>`. Always set the hint attrs.
- State: `this.state` + `this.setState` (React-class style). Initialize with `constructor(props){ super(props); this.state = {...}; }`
  or `state = {...}` class field. Read with `(this.state && this.state.x) ?? default` defensively.
- ALL UI is `<x-dc>` markup. Never build DOM in script (no innerHTML/appendChild/createElement/window.X). No global keydown listeners.
  No `<iframe>/<object>/<embed>`. No network except the Google Fonts link already in helmet.
- `data-props` is single-quoted JSON; inside it escape `&`→`&amp;`, `'`→`&#39;`, `"`→`\"`. Declare FEW tweaks (levers, not copy):
  every board declares `crt` (enum subtle/full/off) + `$preview`. Interactive boards may add 1 behavioural lever (e.g. a `startSession` enum).
  Copy text stays literal markup (retypeable), not props.
- Accessibility as drawn: real `<button type="button">`, `<a href="#…">`, `<input>` with `<label>` (or aria-label). `aria-label` on
  icon-only buttons. Decorative SVG `aria-hidden="true"`. Never `onClick` on div/span. Never `role="button"`.
- NO EMOJI anywhere. Icons = inline stroke SVG (style of shell-sessions.html: viewBox 0 0 20 20, stroke 1.5, square caps, `currentColor`)
  or CODD Unicode glyphs from this allow-list ONLY: `▸ ▾ ◆ ◇ ● ○ ◌ ◉ ▲ ✕ ⟲ ↻ ↗ → ← ↑ ↓ ⋯ ⠿ ■ □ ▮ ▯ $ ⎇ ⌘ ⌥ ⌃ ⇧ ⏎ ⎋ ✓ ✎ ★ ┌ ─ ┘ │ ╭ ╮ ╰ ╯ ⎿ ❯ ✻ · …`.
  FORBIDDEN (render as emoji): ⚠ ⚡ ⚙ ⏺ ⏳ ⏰ ▶ ⌨ ✏ ✔ ✖ ❌ ✅ ⭐ ☀ ♻ and anything in U+1F000+.
- Layout with flex/grid + `gap` (not margins between siblings). `text-wrap: pretty` for prose.
- Window boards are PAGES (canvas `expand:"fill"`): the shared `.codd.win` root is `width:100%; height:900px`, `flex-wrap:wrap`;
  `.rail`, `.side` are fixed-width flex items, `.main` is `flex:999 1 560px; min-width:0`. Do not add px widths to the root.
  Non-window pages (spec sheets) use a fluid root: `<div class="codd {{ crtClass }}" style="width:100%; min-height:…px; padding:48px 56px">`
  with grids `repeat(auto-fit, minmax(min(320px,100%),1fr))`.
- Contrast: body text cream/bone; secondary dim (#a8a298); `--dimmer` (#7a7468) only on #050505/#0a0a0a backgrounds, ≥10.5px.
  Never white text on amber/cyan fills — use #000 (as the shared CSS does).
- No filler/lorem. Every string is realistic for this product (data in §5). Rationale/explanations NOT inside artboards, except short
  functional captions on spec-sheet boards (SidebarStates, Foundations, Remote) which document interactions.
- File size target ≤ 150 KB per artboard. Don't over-repeat; use `<sc-for>` for long lists in interactive boards.

---------------------------------------------------------------------------------------------------------------------
## 2. Information architecture

Window = traffic lights (hiddenInset title bar) + **Rail 72px** (4 destinations) + **Sidebar 280px** (list for the active area) + **Main**.
- Rail: `SESSIONS` (badge = attention count 3), `NOTES`, `STATUS`, `SETTINGS`; bottom: `● MCP` indicator and active-account chip
  `#3` with two micro bars (5h / 1w remaining). Rail active item: amber text + glow gradient + 2px inset left bar.
- SESSIONS sidebar (canonical in shell-sessions.html): brand `FANCY/CODD`, ⌘K search icon, `[+ NEW ▾]`; filter input + `TREE|STATE` toggle;
  **◆ NEEDS YOU** strip (mirror of waiting + error sessions across all groups; plus a one-line "◇ 1 個待看" for DONE-unseen) →
  **PINNED** → **Groups** (大群組, colored square, aggregate badges) → **Projects** (= a cwd) → **Sessions** (lamp, color tag square,
  title, state pill; line 2 = reason/tool · duration · uptime · badges) → `未分類 UNGROUPED` → `[+ 新增群組]`.
  Footer: host one-liner + active account 5h/1w remaining bars + reset time.
- Hierarchy rules: Group → Project → Session, one level of groups. A session belongs to exactly one project (its cwd) — sessions reorder
  only within their project; projects drag between groups; groups reorder. Sessions/projects can be PINNED. Manual order is never
  reshuffled by state (NEEDS YOU mirrors instead). Colors: groups + sessions (projects inherit group color unless overridden).
- Session kinds: `CLAUDE` (claude CLI in a PTY) and `SHELL` (plain zsh in the project's cwd; glyph `$`).
- Session pane: header (52px) = lamp · title · state chip · meta line; actions: `✎ NOTES n` pill, Files, bottom-terminal toggle (⌘J),
  `A− 13 A+`, `⋯`. Tab strip: `◆ CLAUDE` + shell tabs `$ ZSH` + `+`. Body = xterm (black). When WAITING: an **answer bar** under the
  terminal (`[1] Yes` `[2] Always` `[3] No` `[ESC]`) built from CODD's KeyBar. Composer (⌘L) optional on desktop. Bottom ⌘J split = shell panel.
- App status bar (24px, bottom of Main): `● MCP 127.0.0.1:47821 · 3 clients` · `hooks ● ok` · right side `13 live · ◆ 3 · ● 4` · `⌘K`.
- NOTES area: Rail NOTES active; lists column (smart lists) + note list + editor (CodeMirror-style live preview) + info panel.
  Local files open in the same editor surface (VSCode-like tabs + tree), reachable from session header "Files" and Notebook "LOCAL FILES".
- STATUS area: Host, Accounts (cswap), Hooks & Statusline, MCP server, Remote.
- SETTINGS area: section list in sidebar, content right.
- Menu bar extra: monochrome bracket glyph `[■]` + `◆2 ▲1` counts; popover 380px: NEEDS YOU, RUNNING, ACCOUNTS (remaining quota), footer.

Keyboard: ⌘1–9 jump session · ⌃Tab cycle · ⌘K quick switch · ⌘N new session · ⌘T new shell tab · ⌘J bottom terminal · ⌘L composer ·
⌘⇧N quick note · ⌘\ focus mode (hide sidebar) · ⌥⇧↑/↓ reorder · ⌘, settings · ⌘⏎ allow (answer bar).

---------------------------------------------------------------------------------------------------------------------
## 3. Session state model (glyph + color double-encoded, from CODD STATE_META, extended)

| state class | glyph | pill label | header chip text example | meaning | attention |
|---|---|---|---|---|---|
| st-waiting | ◆ (pulse) | WAITING (sidebar NEEDS-YOU: PERM / ASK / PLAN) | `◆ WAITING · PERMISSION · 3m` / `· QUESTION` / `· PLAN` | Claude needs approval / an answer / plan approval | YES high |
| st-error | ▲ | ERROR | `▲ ERROR · OVERLOADED · 1m` (`RATE LIMIT`, `AUTH`) | turn failed (StopFailure) | YES high |
| st-done | ◇ | DONE (filled cyan) | `◇ DONE · 4m` | finished while you weren't looking (unseen) | soft |
| st-busy | ● (green glow) | BUSY | `● BUSY · Edit · 6m` | generating / running tools | no |
| st-compacting | ◌ | COMPACT | `◌ COMPACTING · 20s` | context compaction | no |
| st-idle | ○ | IDLE | `○ IDLE · 2h` | your turn, already seen | no |
| st-starting | ◌ (blink) | START | `◌ STARTING · 4s` | spawned, no hook data yet (<20s) | no |
| st-unknown | ● (60%) | — + `! NO HOOK` | | running, no hook data ≥20s | nudge |
| st-shell | $ | SHELL | `$ SHELL · zsh` | PTY alive, claude not running / plain terminal | no |
| st-exited | ✕ | EXITED | `✕ EXITED · code 0 · 3h` | process ended this run | no |
| st-stopped | ⟲ | STOPPED | `⟲ STOPPED · 可接續` | persisted from earlier run, resumable | no |

Badges (modifiers): `EXT` (external session, not app-spawned), `◉ rc` (Remote Control connected), `stale` (idle >1h → dim row 75%),
`#2` cyan account chip (session pinned to a non-active cswap account), `AI` (file touched by AI), `BG` (background job).
Aggregates on group header: `◆n ▲n ◇n ●n ◌n ○n $n ✕n` (only non-zero). Rail/menubar attention = waiting + error.

Color tags (8 Claude Code `/color` names + none) — render ONLY as small squares (8px on rows, 10px with glow on group headers, 20px swatches):
red #ef5b5b · blue #5b8def · green #4ec9b0 · yellow #e6c84e · purple #b07cff · orange #ff9b4e · pink #ff7cb5 · cyan #4ed1e6 (CSS vars --t-*).
Tags never color lamps or titles (state owns color; tag owns the square).

---------------------------------------------------------------------------------------------------------------------
## 4. Visual system recap (all in helmet.html — read it)

Tokens: --bg #050505 / --bg-soft #0a0a0a / --bg-lift #111 / --bg-raise #161616 / --line #1a1a1a / --line-bright #2a2a2a /
--amber #ffb84a / --amber-dim #e09a2c / --amber-glow / --cream #f5ecd6 / --bone #d4cdb8 / --dim #a8a298 / --dimmer #7a7468 /
--cyan #6ee0f0 / --danger #ff7058 / --success #7cff9a / --success-dim #52c472.
Type: body 13px JetBrains Mono (CJK falls back to PingFang TC / Noto Sans TC); display Space Mono 700 (page title 26px `.h-page`,
pane title 15px `.sh .ttl`, card heads 12px caps .16em); labels 10–10.5px caps .14–.18em; meta 10.5–11.5px; terminal 12.5px/1.45.
Radius 0 everywhere (only macOS traffic lights and the iPhone mock are round). Borders 1px; dividers dashed. Glow = amber-glow.
Components (classes): .btn(.primary .danger .accent .sm .plain) · .icon-btn(.on) · .pillbtn · .input .select .lbl .hint .field ·
.sw(.on) switch · .seg segmented · .chip(.amber .ok .cy .bad .fill .caps) · .kbd · .badge(.cy .bad .dim) · .tag(.lg) ·
.lamp .state .stchip + st-* · .card(.hot) (ASCII corners) · .panel · .menu .mh .mi(.hl .danger) .sep · .pop · .toast ·
.backdrop .modal .m-h .m-b .m-f · .swatches .sw8(.on .none) · .bar10 + tone-ok/warn/crit/muted · .meter · .qrow ·
.tabs .tab(.on) .tfill · .term (+ spans .d .w .a .g .c .r .cc .inv .cur .add .del) · .answerbar .keybtn(.danger) ·
.banner(.bad .warn) · .composer .ta · .statusbar · .sec .h-page .h-sub .meta-rule .comment .cursor .path code ·
.spark (SVG polyline sparkline) · shell: .tl .rail .ri .acct .side .side-head .brand .side-scroll .side-foot .main .sh .needs
.sbsec .grp .proj .srow(.flat .current .sel) .grip .ext .addrow.
Voice: `// 註解式空狀態`, middle-dot separators, compact durations `45s 12m 1h02m 2d03h`, `UP`, `CTX 58%`, boot-log `[ OK ] [ .. ]`,
blinking `_` cursor on active tab/nav, `[ERROR]` prefix, lowercase data chips (`pid 48211`, `up 42m`), UPPERCASE structural labels.

---------------------------------------------------------------------------------------------------------------------
## 5. Canonical mock data (use EXACTLY these names/numbers everywhere)

Accounts (cswap 0.26.0, aliases — never show emails; plan MAX 20x for all):
- `#3 工作` ACTIVE — 5h 剩 91% (重置 13:39 · 2h57m後, ok) · 1w 剩 15% (重置 10/18 週日 12:00 · 3d01h後, crit) · Fable 1w 100% ·
  pace: 「1w 用量超前預期 · 預估 10/17 18:00 用完」 · source statusline · 12s 前 · 12 個 session 跟隨全域登入.
- `#2 藍鵲` — 5h 剩 98% (重置 13:19) · 1w 剩 46% (重置 10/16 週五 22:59, warn) · source cswap cache · 3m 前 · 1 個 session 固定 (cswap run).
- `#1 個人` — 5h 未開始 (100%, muted) · 1w 剩 100% (重置 10/19 週一 20:00) · source cswap cache · 3m 前 · 0 session.
- Auto-switch: OFF (閾值 90% · cooldown 300s · 策略 best). Extra usage: off.

Host: CPU 23% (load 3.12 · 12 cores) · MEM 21.4/36G (pressure normal) · DISK 412G free / 1T · SWAP 1.2G · BAT 86% AC · uptime 3d4h ·
claude processes 12 (11 CODD + 1 外部) · CODD app RSS 412MB · event loop p99 3ms.
MCP: `● 127.0.0.1:47821 · 3 clients` (修正登入 API 401, 打卡頁 RWD 調整, codex). Hooks: `~/.claude/settings.json` — hooks ◆ 需要更新
(缺 PreCompact / PostCompact / SubagentStart / SubagentStop), statusline ● 已安裝 (chain CODD → hook-tap → statusline.sh), status dir
`~/Github/codd-web/agent-sandbox/.claude/codd-status` (! 與預設不同), 最近收到資料 8s 前; foreign hooks:
`hook-tap` (11 events, PermissionRequest 會阻擋 600s), osascript 通知 ×2 (Notification, Stop).

Groups → projects → sessions (13 live, 1 exited). Fields: id · state · title · tag · reason/tool · duration-in-state · uptime · branch · model · CTX · cost · account
- 藍鵲 · 實驗室 (orange) — 原型試做 `~/Project/Northstar/lab/agent-lab-2026/原型試做`
  - s4 st-done 「第二版原型 · 審查流程」 · — · 4m · up 38m · ⎇ main · sonnet-5.5 · CTX 62% · $1.07 · #3
  - s6 st-idle 「產生程式碼審查清單」 · — · 2h · up 3h10m · ⎇ main · sonnet-5.5 · CTX 80% · $0.41 · #3
  — MCP 整合範例 `~/Project/Northstar/lab/agent-lab-2026/整合範例/MCP`
  - s7 st-busy 「現場示範：連線 MCP」 · Bash · 1m12s · up 51m · ⎇ main · opus-5.5 · CTX 66% · $1.88 · **#2 (cswap run)**
  — Skills 整合範例 (no live session, 封存 3)
- 藍鵲 · 網站 (blue) — orb-toolkit-backend `~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend`
  - s1 st-waiting PERMISSION 「修正登入 API 401」 tag red · Bash `npm test -- auth.spec.ts` · 3m · up 42m · ⎇ fix/login-401 · opus-5.5 ·
    CTX 58% · $2.14 · #3 · ◉ rc
  - s8 st-shell 「npm run dev」 (kind SHELL, zsh) · up 42m
  — orb-toolkit-frontend `~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend`
  - s9 st-busy 「打卡頁 RWD 調整」 tag pink · Edit · 6m · up 1h18m · ⎇ feat/punch-rwd · sonnet-5.5 · CTX 49% · $1.36 · #3
  — Northstar invoice system `~/Project/Northstar/websites/業主/Northstar invoice system`
  - s2 st-waiting QUESTION 「發票匯出 CSV」 · AskUserQuestion 「CSV 要用 UTF-8 BOM 還是 Big5？」 · 12m · up 1h05m · ⎇ main · sonnet-5.5 · CTX 71% · $0.62 · #3
- 個人 · Github (green) — Gear3D `~/Github/Gear3D`
  - s3 st-error OVERLOADED 「場景載入優化」 tag yellow · API 529 · 1m · up 2h12m · ⎇ perf/scene-load · opus-5.5 · CTX 34% · $4.80 · #3
  — pixel-town-demo `~/Github/pixel-town-demo`
  - s10 st-compacting 「像素小鎮 NPC 對話」 · 20s · up 4h02m · opus-5.5 · CTX 9% → compacting · $5.12 · #3
  — keynote-deck `~/Github/keynote-deck`
  - s11 st-idle (stale) 「keynote 第 3 章」 · 1d · up 1d02h · sonnet-5.5 · CTX 55% · $0.93 · #3
  — UsageBar `~/Github/UsageBar`
  - s12 st-exited 「選單列額度顯示」 · code 0 · 3h ago
- CODD (purple, collapsed in shell) — codd-web `~/Github/codd-web`
  - s13 st-idle 「web: session 側欄」 · 5h · sonnet-5.5 · #3
  — codd-desktop `~/Github/codd-desktop`
  - s5 st-busy PINNED 「CODD Desktop 設計稿」 tag purple · Write · 2m · up 3h20m · opus-5.5 · CTX 47% · $6.31 · #3
- 未分類 (none) — claude-line-test `~/Desktop/temp_測試專案/claude-line-test`
  - s14 st-idle EXT 「LINE bot 測試」 · 25m · 外部啟動 (detected via `claude agents --json`) · #3
Summary line: `13 LIVE · ◆ 3 NEEDS YOU · ● 4 WORKING · ✕ 1 EXITED`. Menu bar title: `[■] ◆2 ▲1`.
Past transcripts (resume picker, orb-toolkit-backend): 「refresh token 流程改寫」 ⎇ fix/refresh · 2d · 1.2MB; 「auth middleware 單元測試」
⎇ main · 5d · 640KB; 「登入頁錯誤訊息 i18n」 ⎇ feat/i18n · 12d · 2.3MB (「resume 5 天後過期」 warning on the 25d+ one: 「CI 設定」 · 26d).

Launch profiles: `claude-default` (`claude`), `claude-plan` (`claude --permission-mode plan`), `claude-rc` (`claude --remote-control`),
`zsh` (shell). New session command preview: `$ claude --session-id 7c1e9a04-… --model opus-5.5 --permission-mode acceptEdits -n "修正登入 API 401"`.

Notebook (`~/.codd/notebook/`, MCP `codd`): lists INBOX 6 · PINNED 2 · PROMPTS 3 · STALE 4 · ARCHIVE 34 · TRASH 3; BY PROJECT:
orb-toolkit-frontend 2 · orb-toolkit-backend 1 · MCP 整合範例 1 · Gear3D 1. LOCAL FILES: recent 4.
Notes:
- n1 「打卡頁 RWD 跑版紀錄」 NOTE · id `rwd-punch-k7x2` · tags #rwd #punch · linked s9 + project orb-toolkit-frontend · AI: READ ·
  2 張圖片 (1.4 MB) · updated 10:05 · file `~/.codd/notebook/2026-10-15-打卡頁-rwd-跑版紀錄.md` · AI activity: 「打卡頁 RWD 調整 讀取 · 10:12」
  Body: H2 問題 — iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。 Screenshot image (placeholder) 「截圖 2026-10-15 09:32 · iPhone SE」.
  H2 想請 AI 做的 — task list: [x] 先重現（Chrome DevTools 375 寬） [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)` [ ] 表格改卡片式（<640px）
  code block `@media (max-width: 640px) { .punch-table { display: block; } }`.
- n2 「給後端的 prompt：401 修正條件」 PROMPT · linked s1 · 已送出 10:02 (sent → scratch-archive in 7d)
- n3 「MCP 示範腳本重點」 NOTE · PINNED · project MCP 整合範例
- n4 「程式碼審查標準 v2」 NOTE · linked s6
- n5 「隨手記 10/15」 SCRATCH · 「7 天後自動封存」
- n6 「keynote 第 3 章大綱」 PROMPT draft · linked s11
- n7 「Gear3D 載入效能想法」 NOTE · stale 21d
References for n1: `codd://note/rwd-punch-k7x2` (recommended; CODD-launched sessions auto-expand via UserPromptSubmit hook) ·
`@codd:codd://note/rwd-punch-k7x2` (Claude Code @-attach via MCP resource) · `~/.codd/notebook/2026-10-15-打卡頁-rwd-跑版紀錄.md`
(any agent can Read it) · 複製全文 Markdown · `http://127.0.0.1:47821/n/rwd-punch-k7x2.md?t=••••` (瀏覽器 / curl；Claude 的 WebFetch 讀不到 localhost).
Retention defaults: stale after 14 天無活動 · auto-archive 30 天 · SCRATCH/已送出 prompt 7 天 · 垃圾桶 30 天後清除 · tombstone 90 天 ·
pinned & 使用中 session 的筆記豁免 · 週一 09:00 清理建議（≥5 項才提醒） · 「交給 Claude 濃縮」手動，原稿只封存不刪除.
Sessions retention: 停止 3 天 → stale, 7 天 → 自動封存; Claude Code `cleanupPeriodDays` 30 → 「resume 5 天後過期」提醒; 終端機紀錄封存 30 天後刪除.
Cleanup candidates: NOTES 8 · SESSIONS 5 · FILES 2 (= 15).

---------------------------------------------------------------------------------------------------------------------
## 6. Shared mini-patterns

Terminal (Claude Code TUI approximation, inside `<pre class="term">`; use `●` for assistant bullets, `⎿` for tool results,
box drawing `╭─╮│╰─╯` for dialogs, `❯` for the selected option, `✻` for the working spinner, `>` for the user prompt line).
Never use ⏺. Keep lines ≤ 96 chars. Use spans for color (.d dim, .a amber, .g green, .r red, .c cyan, .cc claude-orange, .w bold white).
Example (waiting permission):
```
<span class="d">></span> 登入 API 在 token 過期後會回 401，幫我修好並補測試

<span class="cc">●</span> 我先看 auth middleware 的流程。

<span class="cc">●</span> <span class="w">Read</span>(src/middleware/auth.ts)
  <span class="d">⎿  Read 84 lines</span>

<span class="cc">●</span> <span class="w">Update</span>(src/middleware/auth.ts)
  <span class="d">⎿  Updated src/middleware/auth.ts with 12 additions and 3 removals</span>
     <span class="del"> 41 -   if (isExpired(token)) return res.status(401).end()        </span>
     <span class="add"> 41 +   if (isExpired(token)) {                                    </span>
     <span class="add"> 42 +     const next = await refreshSession(req, res)              </span>
     <span class="add"> 43 +     if (!next) return res.status(401).json({ code: 'EXPIRED' })</span>

<span class="a">╭──────────────────────────────────────────────────────────────────────╮</span>
<span class="a">│</span> <span class="w">Bash command</span>                                                         <span class="a">│</span>
<span class="a">│</span>                                                                      <span class="a">│</span>
<span class="a">│</span>   npm test -- auth.spec.ts                                           <span class="a">│</span>
<span class="a">│</span>   <span class="d">執行 auth 相關的單元測試</span>                                           <span class="a">│</span>
<span class="a">│</span>                                                                      <span class="a">│</span>
<span class="a">│</span> Do you want to proceed?                                              <span class="a">│</span>
<span class="a">│</span> <span class="a">❯ 1. Yes</span>                                                             <span class="a">│</span>
<span class="a">│</span>   2. Yes, and don't ask again for <span class="w">npm test</span> commands in this project  <span class="a">│</span>
<span class="a">│</span>   3. No, and tell Claude what to do differently <span class="d">(esc)</span>                  <span class="a">│</span>
<span class="a">╰──────────────────────────────────────────────────────────────────────╯</span>
```
(CJK chars are double-width in a real terminal; don't obsess over right-border alignment on CJK lines — you may omit the right `│` on lines with CJK.)

Answer bar (when waiting):
`<div class="answerbar"><span class="lamp st-waiting">◆</span><span>Claude 需要授權 · <code>Bash: npm test -- auth.spec.ts</code></span><span style="flex:1"></span>
<button class="keybtn" type="button"><span class="k">1</span>Yes</button><button class="keybtn" type="button"><span class="k">2</span>Always</button>
<button class="keybtn danger" type="button"><span class="k">3</span>No</button><button class="keybtn" type="button"><span class="k">ESC</span>取消</button><span class="kbd">⌘⏎</span></div>`

Status bar (bottom of .main):
`<div class="statusbar"><span><span class="lamp st-busy" style="width:auto">●</span> MCP 127.0.0.1:47821 · 3 clients</span><span>hooks <span class="ok">●</span> ok</span>
<span style="flex:1"></span><span class="num">13 live · <span class="amber">◆ 3</span> · <span class="ok">● 4</span></span><span class="kbd">⌘K</span></div>`

Brand mark (menu bar + app icon): `[■]` — inline SVG `<path d="M6 3H3v14h3M14 3h3v14h-3"></path><rect x="8.25" y="8.25" width="3.5" height="3.5" fill="currentColor"></rect>`
(viewBox 0 0 20 20, stroke 1.5). App icon = this mark in amber on a black rounded-square (the only rounded thing besides macOS chrome) with faint scanlines.

---------------------------------------------------------------------------------------------------------------------
## 7. Artboards (file → content). All window boards 1440×900 unless noted. Canvas layout is pre-set; just build the file.

### 7.1 `Main.dc.html` — 主視窗 · Session (INTERACTIVE, is_interactive)
Shell (rail SESSIONS on, sidebar tree) rebuilt INTERACTIVELY from data: sessions array (§5) rendered with `<sc-for>` under each
project; clicking any session row (in NEEDS YOU, PINNED or tree) selects it (class `current`), clicking a group header toggles collapse
(caret rotates, aggregate badges stay), TREE/STATE toggle is static (only TREE implemented). Initial selection: s1.
Main pane bound to the selected session: header (lamp, title, stchip with label/reason/duration, meta line: short cwd `~/…/orb-toolkit-suite/orb-toolkit-backend`
· `⎇ branch` · model · `CTX n%` (danger color when <20%) · `$cost` · `UP x` · account chip `#3 工作` · `◉ RC` when rc), actions (`✎ NOTES 2` pillbtn,
Files icon, bottom-terminal icon, `A− 13 A+`, `⋯`). Tabs `◆ CLAUDE` / `$ ZSH` / `+` (clicking CLAUDE/ZSH switches body; right side of tab
strip shows `120×38 · ⌘J 終端機`). Body variants by the selected session's view:
- waiting-permission (s1): terminal from §6 + answer bar.
- waiting-question (s2): terminal with an AskUserQuestion dialog: 「CSV 要用哪種編碼？ ❯ 1. UTF-8 with BOM（Excel 開啟不亂碼） 2. Big5（舊系統相容） 3. UTF-8（無 BOM）
  4. Type something」 + answer bar with `[1] [2] [3] [4] [ESC]` and label 「Claude 在問你 · 回答問題」.
- busy (s5, s7, s9): terminal showing tool calls streaming + spinner line `✻ Editing… (34s · ↓ 1.2k tokens · esc to interrupt)`; no answer bar.
- done (s4): final summary output + empty prompt box; header shows `◇ DONE · 4m` and a small note under the tab strip 「剛完成 · 開啟後標為已讀」.
- error (s3): a `.banner.bad` under the header: `▲ API 過載（529 overloaded）· 1m 前 · 本輪未完成` + `[↻ 重送上一則]` `[⟲ 稍後自動重試]`; terminal shows the error output.
- idle (s6, s11, s13, s14): calm prompt `> _` after a short last exchange; s14 shows a `EXT · 外部啟動的 session，唯讀狀態偵測` banner with `[接管到 CODD]`.
- compacting (s10): `✻ Compacting conversation… (CTX 9%)` line.
- shell (s8): zsh running `npm run dev` (vite ready output, HMR lines).
ZSH tab (any session): zsh prompt in the session's cwd, e.g. `dev@mbp orb-toolkit-backend % git status` output.
Status bar at bottom. Tweaks: `crt`. Keep total ≤ 200 KB (it's the biggest board). Use helper maps in renderVals to avoid duplicating markup.

### 7.2 `Split.dc.html` — Session + 下方終端機 + 筆記抽屜 + Composer
Static. Selected s9 「打卡頁 RWD 調整」 (busy). Shell: copy shell-sessions.html but move `current` to the s9 row. Main pane:
header (NOTES pill `.on`), tabs, upper Claude terminal (busy: Edit punch.vue, diff lines, spinner), a horizontal splitter (6px, dashed line
with centered `⋯` grip, `aria-label` 調整高度), bottom panel 280px: its own tab strip `$ ZSH 1` (on) · `$ NPM RUN DEV` · `+` · right: `⤢` maximize, `✕ ⌘J`;
terminal shows `git status` + `npm run lint` output in the frontend cwd. Composer (⌘L) visible between Claude terminal and splitter:
textarea with draft 「iPhone SE 寬度下的打卡按鈕改成固定在底部，參考 」 + an inline chip `codd://note/rwd-punch-k7x2` + `[SEND]`, hint
「Enter 送出 · ⇧Enter 換行 · 貼上圖片會存成檔案路徑」. Right drawer 300px (inside .main, flex row): `SESSION PAD · 筆記` header with `✕`;
linked notes cards (n1 with image thumbnail placeholder, "QA 清單" note) each with `[插入引用]` `[送出全文]`; `[+ 新筆記（連結此 session）]`;
section `AI 改過的檔案 · 3`: `src/pages/punch.vue  M  AI 10:41`, `src/components/PunchButton.vue  M  AI`, `tailwind.config.js  M` each with `[差異]`.
Status bar.

### 7.3 `Home.dc.html` — 主頁（未選取 session）
Static. Shell with NO `current` row. Main = scrollable dashboard (padding 28px 36px): `// 沒有選取 session` comment, `.h-page` SESSIONS,
`.meta-rule` `13 LIVE · ◆ 3 NEEDS YOU · ● 4 WORKING · ✕ 1 EXITED`. Section NEEDS YOU: 3 wide cards (s1, s2, s3) with lamp, title, project,
reason line (e.g. `Bash: npm test -- auth.spec.ts`), duration, buttons `[前往 ⌘1]` and for s1 `[1 允許]`. Section LAUNCH 最近專案: grid of 6 project cards
(group square, name, short path, last activity, live count) each with `[+ CLAUDE]` `[+ SHELL]`. Section RECENTLY STOPPED 可接續: list rows
(s12 + 2 resumable from the resume picker list) with `[⟲ RESUME]`. Section USAGE 剩餘: 3 compact account rows (5h/1w bars). Status bar.

### 7.4 `SidebarStates.dc.html` — 側欄互動狀態（規格頁）
Spec-sheet PAGE (fluid root, padding 48px 56px, h ≈ 1900). Title `.h-page` 側欄互動 + `.meta-rule` SIDEBAR · DRAG · MENU · MULTI-SELECT · STATE VIEW.
Top: a state legend strip (all 11 lamps with pill labels). Then panels (each a 280px-wide × ~720px sidebar fragment framed by `.panel`, with a
caption above: `A · 拖曳` etc. and 1–2 caption lines below in `.hint`):
- A 拖曳 DRAG: project 「Northstar invoice system」 lifted (float: --bg-lift, shadow `0 6px 24px rgba(0,0,0,.6), 0 0 0 1px var(--line-bright)`, slight
  rotate none) hovering over group 藍鵲·實驗室; original slot shows dashed ghost (`1px dashed --amber-dim`); amber 2px drop line between projects;
  target group header highlighted. Caption: 專案可拖到其他群組；session 只在所屬專案內排序（cwd 固定）；⌥⇧↑↓ 鍵盤排序；拖曳 4px 後才開始.
- B 右鍵選單 CONTEXT MENU on s9: `.menu` with items: 重新命名 (⏎) · 顏色 → inline swatch row (8 + none, pink selected) · 釘選到 PINNED (⌘P) ·
  ⟲ 接續對話 resume · ↻ 重新開始（新對話） · ↗ 在 Terminal.app 開啟 · 複製 resume 指令 · 複製 session ID · sep · 封存 (⌫) · ■ 停止 (danger, ⌘.) · sep ·
  刪除對話紀錄…（danger, 需輸入名稱確認）.
- C 多選 MULTI-SELECT: 4 rows with `.sel` (⌘-click), a bottom action bar inside the sidebar: `已選 4` `[封存]` `[停止]` `[顏色]` `[✕]`; a `.toast`
  below it: `✕ 3 個 session 已封存` `[UNDO]` `5s`. Caption: ⌘ / ⇧ 多選；群組標題 hover 出現 `清理已停止 (5)`；所有移除都可 UNDO.
- D 新增群組 + 顏色: inline new group row with focused `.input` 「內部工具」 + color popover (`.pop`, 8 swatches + none, hint `1–8 快速選色`),
  group header hover actions `+` (new session in group) and `⋯`; group `⋯` menu: 重新命名 · 顏色 · 全部收合 · 清理已停止 · 刪除群組（專案移到未分類）.
- E STATE 檢視: TREE/STATE toggle on STATE: sections NEEDS YOU / WORKING / READY / IDLE / SHELL / STOPPED; rows show group square + `project` dim.
- F Hover card: a 340px `.pop` next to a row (s1): state line `◆ 權限確認 · 3m`, title, `最近 prompt：` box (dashed, --bg) with the prompt text,
  path, meta `opus-5.5 · tool Bash · ctx 58% · up 42m · ⌘1`, hint 「拖曳或 ⌥⇧↑↓ 調整順序」.
Layout: 2 rows of 3 panels, `display:grid; grid-template-columns: repeat(auto-fit, minmax(min(300px,100%),1fr)); gap: 40px`.

### 7.5 `NewSession.dc.html` — 新增 Session（⌘N）
Static. Window shell (sidebar as canonical) dimmed by `.backdrop`; centered `.modal` 720px: m-h `NEW SESSION · 新增 session` + `⌘N`.
Fields: 專案 PROJECT — a combobox (input showing `orb-toolkit-backend` + path) with an OPEN dropdown list (`.menu` style, 300px tall): section
`最近` (5 projects with group squares), section `建議 · 來自 ~/.claude.json` (3 not-yet-added projects with `+ 加入`), footer `+ 選擇資料夾…`;
類型 KIND `.seg` CLAUDE (on) / SHELL; 開始方式: radio list 新對話 / ● 接續先前對話 / 從 Remote Control 啟動 — with the resume picker visible (rows from §5
past transcripts: title, ⎇ branch, age, size; the 26d one marked `resume 4 天後過期` in amber); 帳號 ACCOUNT `.select` 「跟隨全域登入（#3 工作）」
+ hint 「改選固定帳號會以 cswap run 建立獨立設定目錄，對話紀錄分開存放」; 模型 MODEL select `預設 (opus-5.5)`; 權限 `.seg` default / acceptEdits (on) / plan / auto;
名稱 input + 顏色 swatches; ▸ 進階 (collapsed): launch profile, env, `--remote-control`. Command preview `.term`-like 1-line box with the §5 command.
m-f: `[取消]` `[建立 ⌘⏎]` (primary).

### 7.6 `QuickSwitch.dc.html` — ⌘K 快速切換
Static. Window shell + main showing s1 (header + a dimmed terminal) under `.backdrop` (align top, padding-top 80px). Palette 640px (`.modal` look,
no m-f): input row with `>` prompt glyph, value 「打卡」 + blinking cursor, right `esc`. Results grouped with `.mh`-style headers: SESSIONS
(s9 ● 打卡頁 RWD 調整 · 藍鵲·網站 / orb-toolkit-frontend · BUSY 6m · `⌘3` — highlighted `.hl`), NOTES (n1 打卡頁 RWD 跑版紀錄 · note · 10:05),
PROJECTS (orb-toolkit-suite/打卡紀錄前端介面 · 未加入 · `+ 加入`), ACTIONS (`> 在 orb-toolkit-frontend 新增 session`, `> 在 orb-toolkit-frontend 開啟終端機`,
`> 切換帳號到 #2 藍鵲`). Matched substrings in amber. Footer hints: `↑↓ 選擇 · ⏎ 開啟 · ⌘⏎ 在下方終端機開啟 · ⌥⏎ 新視窗 · esc 關閉`.

### 7.7 `StatusDialogs.dc.html` — 對話框：切換帳號 · Hook 差異 · 新增帳號 · 結束
Spec-sheet PAGE (fluid, padding 48px 56px, h ≈ 1300). Title + meta-rule. 2×2 grid of modal mocks (each `.modal` rendered inline, not over backdrop,
width 100% of its cell):
(a) SWITCH ACCOUNT 「切換到 #2 藍鵲？」: from/to account mini rows with quota (5h/1w), warning list (12 個跟隨全域登入的 session 約 30 秒內改用 #2；
    第一則訊息可能需要重建快取；固定帳號的 session（現場示範：連線 MCP）不受影響), checkbox 「同時暫停自動切換」, progress line `◌ 等待 Claude Code credential lock… 9s（1/3）`,
    m-f `[取消]` `[切換]`(primary).
(b) HOOK DIFF 「預覽 ~/.claude/settings.json 變更」: diff box (black, `- ` lines danger tint, `+ ` lines success tint) adding PreCompact/PostCompact/SubagentStart/SubagentStop
    entries (JSON), `foreign hooks 保持不動：hook-tap ×11 · osascript ×2`, backup `settings.json.codd-bak-20261015-104210`, m-f `[取消]` `[套用並備份]`.
(c) ADD ACCOUNT 「加入帳號（cswap add）」: 3-step list: 1 在終端機執行 `claude /login` 登入新帳號 (button `[開啟登入終端機]`) · 2 `[擷取目前登入]` → shows
    detected `新帳號 · MAX 20x` · 3 別名 input + slot select `#4`; alt link 「改用 setup-token / API key（cswap add-token）」.
(d) QUIT 「結束 FANCY/CODD？」: `13 個 session 執行中 · ◆ 3 需要你`, options as stacked buttons `[全部停止並結束]`(danger) `[保留在選單列（關閉視窗）]`(primary) `[取消]`,
    checkbox 「下次直接保留在選單列」.

### 7.8 `Notebook.dc.html` — 筆記本
Static (show one menu open). Rail NOTES on (badge none; Sessions keeps badge 3). Layout: rail 72 + lists 220 + note list 300 + editor flex.
Lists column (`.side`-like, 220px): head `NOTEBOOK` brand-ish label + `[+ ⌘⇧N]`; search input; smart lists with counts (INBOX 6 on, PINNED 2, PROMPTS 3,
STALE 4 (amber-dim count), ARCHIVE 34, TRASH 3 with hint 「30 天後永久刪除」); `BY PROJECT` (group squares + counts); `LOCAL FILES` (最近 4 · `[開啟資料夾…]`);
footer: `~/.codd/notebook` + `● MCP 3 clients`.
Note list (300px): sort `最近更新 ▾`; rows n1 (selected), n2 (PROMPT chip, `已送出 10:02` dim), n3 (★ pinned), n4, n5 (SCRATCH `7d 後封存`), n6 (PROMPT 草稿),
each: title, 2-line snippet, chips (kind, linked session lamp+name), time, AI access glyph (eye = READ, lock = OFF).
Editor: top bar breadcrumb `INBOX / 打卡頁 RWD 跑版紀錄` · `AI 可讀 READ ▾` pill (eye icon) · scope `PROJECT: orb-toolkit-frontend ▾` · split button
`[COPY REF ▾]` (OPEN: `.menu` listing the 5 references from §5 with one-line hints; first item `.hl` with `推薦` chip) · `[SEND TO SESSION ▾]` · `⋯`.
Document (live preview look): title 22px cream display, chips row (NOTE · #rwd · #punch · linked `● 打卡頁 RWD 調整` · `orb-toolkit-frontend` · updated 10:05),
body per n1 with: rendered H2s (amber display), bullets, an image block (placeholder: a framed phone-screen schematic drawn with CSS boxes + caption),
a task list (checkbox glyphs `[x]`/`[ ]` styled), a code block, and ONE line in raw-markdown state where the cursor is (show `**粗體**` marks dimmed + caret)
to show live-preview behaviour. A small toast near the image: `已貼上圖片 → assets/rwd-punch-k7x2/9f3a1c.png`.
Right info panel 240px (inside editor): LINKS, AI ACTIVITY (讀取 by 打卡頁 RWD 調整 · 10:12; 附加 —), HISTORY (10:05 · 09:41 · 昨天 18:20, `[比較]`),
ASSETS (2 張 · 1.4 MB), RETENTION (最後活動 2h 前 · 14 天後標示 stale · `[釘選以保留]`). Bottom: prompt footer bar: `送到` `[● 打卡頁 RWD 調整 ▾]` `[插入引用]` `[插入全文]` `[送出 ⌘⏎]`.
Status bar (MCP indicator).

### 7.9 `FileEditor.dc.html` — 本機檔案編輯（類 VSCode）
Static. Rail NOTES on. Lists column replaced by FILE TREE for project orb-toolkit-frontend (header `FILES · orb-toolkit-frontend` + `⎇ feat/punch-rwd`):
folders src/pages, src/components, public; files with badges `M` (amber) and `AI` (pink tag-colored chip = session color) e.g. punch.vue M AI, PunchButton.vue M AI,
tailwind.config.js M, package.json. Recent section on top. Editor area: tab strip (`punch.vue ●` dirty on; `*tailwind.config.js*` italic preview; `打卡頁 RWD 跑版紀錄.md` note tab),
breadcrumb `src › pages › punch.vue`, toolbar: switch `SHOW AI CHANGES` (on) · `基準：git HEAD` · `[⌘F]`; a `.banner.warn`: 「磁碟上的檔案已被 AI 變更（打卡頁 RWD 調整 · 10:41）」 `[重新載入]` `[保留我的]` `[比較]`.
Code view with line numbers (Vue SFC, ~34 lines visible), syntax colors (amber keywords, cyan strings, dim comments), an inline unified diff chunk
(2 removed lines red tint, 4 added green tint) with a chunk toolbar `[還原此段]` `[接受]`, a find widget top-right (`sticky` · 3/7 · ↑ ↓ · ✕).
Bottom status bar: `Ln 42, Col 18 · UTF-8 · LF · Vue · 2 spaces · ● 已儲存 10:39`.

### 7.10 `Cleanup.dc.html` — 清理建議 · 保留規則
Static. Rail NOTES on; main shows a full-width review page (no lists column; or a narrow one). Title `.h-page` CLEANUP · 清理建議 + meta-rule
`每週一 09:00 · 15 項 · 上次 10/08`. Tabs `NOTES 8` (on) · `SESSIONS 5` · `FILES 2`. Table rows (checkbox · item · why · badge · AI hint · row actions):
n7 Gear3D 載入效能想法 · 21 天未開啟 · `stale 21d` · `AI 2d 前讀取 → 建議保留`; n2 給後端的 prompt · 已送出 7 天 · `archives in 0d`; n5 隨手記 10/15 · SCRATCH ·
`archives in 6d`; 「keynote 第 2 章大綱」· 近似重複（與第 3 章 82% 相同）; 「舊審查清單草稿」· 30 天未動 · `stale 30d`; plus 3 more.
Row actions `[保留 30 天]` `[封存]`. Sticky bulk bar: `已選 5` `[封存]` `[移到垃圾桶]` `[交給 Claude 濃縮…]`(accent). Right column: a CONDENSE preview card:
「濃縮 5 則 → 1 則摘要」, account/model select (`#1 個人 · sonnet-5.5`), preview text of the summary note, notice 「原稿會移到封存（不刪除），摘要連回原稿」,
`[產生摘要]`. Below: POLICY card summarizing §5 retention defaults as a lifecycle line: `ACTIVE → STALE 14d → ARCHIVE 30d → TRASH (只有你能丟) → PURGE 30d`,
exemptions, `[調整規則 → 設定]`. SESSIONS tab content is not shown (tab only).

### 7.11 `Status.dc.html` — 狀態（PAGE, h 1300)
Static. Rail STATUS on. Sidebar 220px: section nav (HOST, ACCOUNTS, HOOKS, MCP, REMOTE) + a compact NEEDS YOU mini list (3 rows) so attention stays visible.
Main scroll page (padding 28px 36px): `.h-page` STATUS + meta-rule `UPDATED 10:42:07 · 每 5 秒`.
- HOST: grid of metric cards (CPU, MEM, DISK, SWAP, BAT, CLAUDE, CODD APP, UPTIME) each: label, big value (display 22px), sub-line, `.meter`, and for CPU/MEM a 10-min
  `.spark` SVG polyline. MEM shows breakdown app/wired/compressed.
- ACCOUNTS (`cswap 0.26.0 · ~/.claude-swap-backup`): 3 account cards (#3 `.card.hot` ACTIVE first, then #2, #1) with alias, plan chip `MAX 20x`, status `● ok`,
  rows 5h / 1w / Fable as `.qrow` + reset text + countdown, pace line on #3 (amber), source + age (`statusline · 12s 前`), session count, button
  (`[ACTIVE]` disabled on #3, `[SWITCH]` others); 4th dashed card `+ 加入帳號`. Under cards: AUTO-SWITCH row (`.sw` off, threshold/cooldown/strategy chips, `[設定]`)
  and note 「用量只讀 statusline 與 cswap 快取，不另外打 API（避免 429）」.
- HOOKS & STATUSLINE: card for `~/.claude` with part rows (HOOKS ◆ 需要更新 + missing events chips; STATUSLINE ● 已安裝 + chain; STATUS DIR path with `! 與預設不同`;
  最近收到資料 8s 前), FOREIGN HOOKS list (hook-tap ×11, osascript ×2 + `[停用重複通知]`), buttons `[預覽變更]` `[更新]`(primary) `[解除安裝]`(danger);
  second smaller card `cswap session profile #2 → settings.json 連結自 ~/.claude（共用）`.
- MCP SERVER: `● RUNNING 127.0.0.1:47821 · 3 clients` + client list; registrations: Claude Code (user scope) ● 已註冊 `[移除]`, Codex ○ `[註冊]`, Claude Desktop ○ `[安裝 .mcpb]`;
  token `••••` `[輪替]`.
- REMOTE: `◉ 1 個 session 已連 Remote Control（修正登入 API 401）` + link 「Remote & Mobile 設定 →」.

### 7.12 `Settings.dc.html` — 設定 (INTERACTIVE)
Rail SETTINGS on. Sidebar = section list (buttons, current amber): 一般 GENERAL · 外觀 APPEARANCE · 工作階段 SESSIONS · 啟動設定檔 PROFILES · 通知 NOTIFICATIONS ·
帳號 ACCOUNTS · HOOKS & STATUS · 筆記本 & MCP · 清理 CLEANUP · 快捷鍵 SHORTCUTS · 遠端 REMOTE `FUTURE` · 進階 ADVANCED · 關於 ABOUT.
Clicking switches the right content (`<sc-if>` per section, state `sec`). Content = form rows (label + hint left, control right; dashed separators), section title `.h-page`.
Sections content (concise but real):
- GENERAL: 登入時啟動 sw on · 顯示於 Dock sw on · 關閉視窗時保留在選單列 sw on · 結束時 seg 詢問/全部停止/保留 · 預設專案根目錄 input `~/Github` · 全域快捷鍵 `⌥Space` kbd · 語言 select 繁體中文.
- APPEARANCE: CRT 效果 seg FULL/SUBTLE(on)/OFF · 介面密度 seg COMPACT(on)/COMFORT · UI 字級 13 · 終端機字型 select JetBrains Mono · 終端機字級 `A− 13 A+` ·
  原生玻璃側欄 sw off `實驗` · 減少動態 select 跟隨系統.
- SESSIONS: 預設啟動設定檔 select claude-default · 自動加上 --session-id sw on · NO HOOK 警示 20s · STALE 判定 1h · App 重開後恢復為 STOPPED·可接續 sw on ·
  外部 session seg 顯示在專案下/DETECTED 區/不顯示 · 隱藏 SDK / Desktop 來源 sw on · 狀態來源說明 `hook → registry → claude agents --json`.
- PROFILES: list of the 4 launch profiles (name, command code, cwd, account, model) with `[複製]` `[編輯]` `[刪除]` + `[+ NEW PROFILE]`.
- NOTIFICATIONS: matrix rows WAITING (通知 on · 聲音 on) / ERROR (on/on) / DONE (僅在未聚焦時) / EXITED 非 0 (on/off) · 勿擾時段 23:00–08:00 · 依群組靜音 (chips) · Dock 徽章 seg 等待數/全部/關 ·
  選單列標題 seg `◆2 ▲1`/僅圖示 · Remote Control 手機推播 → 遠端.
- ACCOUNTS: cswap 路徑 `~/.local/bin/cswap` · v0.26.0 ● (需 ≥ 0.26) · 隱藏 email sw on · 帳號別名 rows (#1 個人 #2 藍鵲 #3 工作, editable inputs) · 自動切換 sw off + 閾值 90% + cooldown 300s +
  策略 seg best/consume-first · 用量來源說明.
- HOOKS & STATUS: status dir path + `[在 Finder 顯示]` · 安裝部件 rows (Hooks ◆ / Statusline ● / Legacy ○) · 事件 chips (14 events, 4 missing in amber) · 備份列表 3 rows · `[重新安裝]` `[解除安裝]`.
- 筆記本 & MCP: 位置 seg LOCAL `~/.codd/notebook` (on) / iCloud Drive / 自訂… · 圖片 長邊壓到 2576px sw on · 保留原檔 sw off · MCP port 47821 · token `[輪替]` · 註冊 rows
  (Claude Code ● · Codex ○ · Claude Desktop ○) · CODD 啟動的 session 自動掛載 MCP 並展開 codd:// 引用 sw on · 新筆記預設 AI 存取 seg OFF/READ(on)/APPEND · AI 可寫入 sw off.
- CLEANUP: two columns NOTES / SESSIONS with the §5 defaults as selects (7/14/30/60/Never etc.) · 每週清理建議 seg 每週(on)/雙週/每月/關 · 交給 Claude 濃縮 帳號/模型 selects.
- SHORTCUTS: table from §2 keyboard list (action · keys kbd · `[修改]`).
- REMOTE (FUTURE): disabled-looking rows (opacity .55) + chips PHASE 0/1/2 + link 「看規劃 → Remote 畫板」.
- ADVANCED: 資料位置 (`~/Library/Application Support/CODD/codd.db`, logs) · 終端機紀錄保留 30 天 · 從 CODD Web 匯入 `[匯入]` · 重建筆記索引 `[重建]` · `[重設所有設定]`(danger).
- ABOUT: brand mark, version `0.1.0 (design)`, Electron 44 · Node 24 · Claude Code 2.1.300 · cswap 0.26.0, 更新頻道 seg STABLE/BETA.
Initial section: GENERAL. Tweak `crt` + `startSection` enum (general|appearance|sessions|profiles|notifications|accounts|hooks|notebook|cleanup|shortcuts|remote|advanced|about).

### 7.13 `MenuBar.dc.html` — 選單列 · 通知（FIXED composition 1440×900)
Fixed root `width:1440px;height:900px` (not a page). Background: dark desktop `#0d0d10` with a very faint 40px grid (`--line` at 40% opacity), no wallpaper.
- Top: a 24px macOS menu-bar strip spanning width (rgba(20,20,22,.85), bottom hairline) containing ONLY: left `FANCY/CODD` app menu name is NOT needed;
  right side: generic items drawn as neutral dim text blocks (Wi-Fi/battery are NOT drawn as icons — just `週四 10:42` clock text) and OUR status item
  in pressed state: brand mark svg + `◆2` (amber) `▲1` (danger), with a pressed background.
- Popover (380×~720) below our item, `.pop` look (border --amber-dim, glow): header (brand mark + `FANCY/CODD` + `13 live` + icon buttons: new session, open window, settings);
  NEEDS YOU (s1, s2, s3 rows: lamp, tag, title, group·project, reason, duration; s1 row has hover state with inline `[前往]` `[1 允許]`); READY (s4 ◇ row);
  RUNNING 9 (compact single-line rows grouped by group color square headers; show 5 + `+4 more`); ACCOUNTS (3 compact blocks: alias, plan, active marker,
  5h + 1w `.qrow` bars with reset countdown, `[SWITCH]` on inactive, stale/source age); footer: host mini line, `清理建議 15 →`, `[QUICK NOTE ⌘⇧N]` `[OPEN CODD]`.
- Status item variants row (left area): 4 small specimens with captions: 一般 `[■]` · 等待 `[■] ◆2` · 錯誤 `[■] ◆2 ▲1` · Hook 未安裝 `[■] !`.
- Right-click menu specimen (`.menu`): 開啟 FANCY/CODD · 新增 session ⌘N · 快速筆記 ⌘⇧N · 切換帳號 ▸ · 暫停通知 1 小時 · 設定… ⌘, · sep · 結束 ⌘Q.
- Two notification banners (macOS style, top-right stack, 360px, rounded 14px dark translucent — system UI exception): app icon (brand mark on black rounded square),
  `FANCY/CODD · 現在`, title `◆ 修正登入 API 401 需要授權`, body `orb-toolkit-backend · Bash: npm test -- auth.spec.ts`, actions `前往` `稍後`; second: `▲ 場景載入優化 失敗 · API 過載（529）`.
- Dock specimen (small): app icon with red badge `3`.

### 7.14 `Onboarding.dc.html` — 首次啟動
Static. Window without the session tree: traffic lights + full-width wizard (rail hidden). Left stepper column 260px: 1 偵測環境 ✓ · 2 匯入專案 (current, amber) ·
3 安裝 hooks · 4 筆記本與 MCP · 5 帳號 (cswap) · 6 完成. Top of content: boot-log block (`.term` style, short): `[ OK ] claude 2.1.300` `[ OK ] cswap 0.26.0 · 3 個帳號`
`[ .. ] hooks 需要更新（4 個事件）` `[ OK ] node 24.21` `[ OK ] ~/.codd/notebook 可寫入` + `waiting for operator_`.
Step 2 content: `.h-page` 匯入專案 + text 「從 ~/.claude.json 找到 187 個專案（依最近使用排序）。只勾選你要的，CODD 不會一次全部匯入。」; toolbar: filter input,
`[依父資料夾建議分組]` (accent), chip `已選 9`. Table (12 rows from sample paths: agent-lab-2026/原型試做, 整合範例/MCP, 整合範例/Skills, orb-toolkit-backend,
orb-toolkit-frontend, Northstar invoice system, Gear3D, keynote-deck, pixel-town-demo, UsageBar, chat-bot-mcp, mysite.github.io):
checkbox · project name · path (dim, tail) · 最近使用 · transcripts count · group select (藍鵲·實驗室 / 藍鵲·網站 / 個人·Github / CODD / 未分類 / + 新群組…) with color square.
Note row: 「~/.claude-worktrees/* 與 SDK 產生的專案預設隱藏」. Footer: `[上一步]` `[略過]` `[下一步：安裝 hooks →]`(primary).

### 7.15 `Remote.dc.html` — 遠端連線（未來規劃）
Spec-sheet PAGE (fluid, padding 48px 56px, h ≈ 1250). `.h-page` REMOTE & MOBILE + meta-rule `FUTURE · PHASE 0 → 2`. Lead line (short, factual):
「最可能的是 Claude Code Remote Control：Mac 上的 session 繼續跑，用 iPhone 的 Claude App 接手。」 Three phase columns (cards):
- PHASE 0 · Remote Control（Claude 官方 · 不需 Apple 開發者帳號）: mock of a session header chip `◉ RC · 已連線` + `[QR]` `[複製連結]`; QR modal mock (QR drawn as a
  CSS grid placeholder labelled `QR · claude.ai/code/session/…`); toggles: 新 session 預設連 Remote Control (`remoteControlAtStartup`) · 需要操作時推播到手機
  (`inputNeededNotifEnabled`) · 在 Mac 前時不推播（presence file）; caveat chip 「切帳號後手機需登入同一帳號」.
- PHASE 1 · 自架遠端（Tailscale / Cloudflare Tunnel）: provider seg OFF/TAILSCALE/CLOUDFLARE, URL `https://studio-mbp.example.ts.net`, health `● 連線中`, pairing QR + 6 碼 `482 913`
  + 倒數 `04:59`; text 「CODD Web 介面當手機版（加入主畫面 + Web Push）」.
- PHASE 2 · 原生 iOS App（需 Apple Developer US$99/年）: an iPhone mock (rounded 44px frame, 300×620, black screen; NO fake status bar) showing a lock-screen
  Live Activity card: brand mark + `FANCY/CODD` + `◆ 3 需要你` + top row `修正登入 API 401 · 需要授權` with buttons `允許` `前往`; above it a Dynamic Island pill
  showing `[■] ◆3`; beside the phone: paired devices list (`我的 iPhone · 上次 10:40 · [撤銷]`, `[+ 配對新裝置]`) and bullets: Bonjour 區網配對 · APNs 可操作通知 · Live Activity / 動態島.
Bottom row: comparison table (方案 · 需要 · 能做到 · 限制) for Remote Control / Tailscale+Web / 原生 iOS / Screen Sharing.

### 7.16 `Foundations.dc.html` — 設計基礎（規格頁, h ≈ 2100)
Spec-sheet PAGE. Sections (each with `.sec` header + `.meta-rule`):
COLOR (all tokens as swatches: name, hex, usage), TAG PALETTE (8 + none: 20px squares, `/color` names, hex), TYPE (scale specimens: page title 26 display, pane title 15 display,
body 13 mono with CJK sample 「修正登入 API 401」, label 10.5 caps, meta 11, terminal 12.5), STATUS (the §3 table as live rows: lamp, pill, stchip, meaning, attention),
COMPONENTS (buttons: default/hover/primary/danger/accent/sm/disabled; icon-btn normal/on; pillbtn; input default/focus; select; switch off/on; seg; chips all variants; kbd;
badges; bar10 in 4 tones; meter; tabs; card with ASCII corners; menu; toast; modal header), SIDEBAR ROW ANATOMY (one enlarged session row with dimension callouts: 38px
height, 24px indent, lamp 12px, tag 8px, pill 15px), ICONS (all rail/action SVG icons + glyph allow-list), MOTION (lamp-pulse 1.1s, blink 1s steps, scan 600ms, menu-in 110ms
— each with a live specimen), BRAND (brand mark, app icon 128px rounded square amber-on-black with scanlines, menu bar template icon 16px).

---------------------------------------------------------------------------------------------------------------------
## 8. REVISION v2 (user feedback, 2026-10-15) — these OVERRIDE anything above that conflicts

R1 · Groups = light tinted blocks (「用淺底色分群，不要那行佔太多空間」).
  Each group is ONE block `<div class="gblk g-<color>">` wrapping its header + projects + session rows (helmet.html "Groups = tinted
  blocks"). The header `.grp` inside a gblk is compact (22px, 9.5px caps, name drawn in the group color) and has NO color square
  anymore — the tint IS the color. Collapsed group: `gblk … closed` with only its header. Ungrouped: `gblk none` (dashed, no tint).
  Drag target while dragging a project: `gblk … drop`. Canonical markup: spec/shell-sessions.html (already updated).
  Session color tags (8px squares on rows) stay as before. Menu-bar RUNNING list groups use the same gblk tint.
R2 · Sidebar footer usage is EXPANDABLE to all accounts (「可以展開看所有帳號的用量」).
  Collapsed (default, canonical shell): Host line + `.sf-toggle` (▸ USAGE 剩餘 · #3 工作 · 全部帳號 3) + active account 5h/1w qrows + reset line.
  Expanded: `.sf-toggle` caret open + `.acctlist` of 3 `.acrow` buttons (#3 工作 active `.on` with ✓ ACTIVE, #2 藍鵲, #1 個人; each: alias, plan,
  source age, `.q2` grid with 5h and 1w qrows) + hint 「點一下直接切換 · 12 個跟隨全域登入的 session 約 30 秒內套用」.
R3 · Accounts switch DIRECTLY (「這邊可以直接切換」): clicking an account row/block switches immediately — no confirm sheet by default.
  After switching show a `.toast`: 「已切換到 #2 藍鵲 · 12 個 session 約 30 秒內套用」 + [UNDO]. The confirm sheet (StatusDialogs A) only
  appears when Settings › 帳號 › 「切換前確認」 is ON (default OFF).
R4 · Menu bar popover: ACCOUNTS section is FIRST (right under the popover header), then NEEDS YOU, READY, RUNNING, footer.
  Account blocks are full-width buttons (radio-like): active = amber left bar + ✓ ACTIVE; others show 「切換 →」 on hover; no separate [SWITCH] buttons.
R5 · Menu bar status item = ONE small icon, NO counts (「小一點，一個 icon 就好」). Width ~28px. Brand mark SVG with class `mbi`
  and the inner square `<rect class="core" …>`: normal = monochrome; `mbi need` = inner square amber (any waiting/error); `mbi nohook` =
  hollow square. Counts live only in the popover, Dock badge and notifications. Settings › 通知 › 選單列圖示 becomes seg
  「僅圖示 (on, default) / 圖示 + 數字」.
R6 · Image annotations in notes (「圖片是否可以給予座標跟文字 comment，讓 AI 知道可以改哪裡」).
  A pasted image can carry numbered annotations: rect (框選), point (點), arrow (箭頭); each has coordinates in ORIGINAL image pixels
  (origin top-left) + a text comment. Classes: `.ann-wrap` (relative wrapper around the image), `.ann-box` (+`.sel`), `.ann-pin`
  (numbered square), `.ann-list` / `.ann-item` (`.no` `.xy`). Canonical annotations for n1's screenshot 9f3a1c.png (750×1334 px, iPhone SE @2x):
    ① rect  x 20 · y 1150 · 710×120 — 「上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)」
    ② point x 375 · y 330          — 「時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px」
    ③ arrow x 600,y 760 → x 700,y 1080 — 「打卡紀錄卡片離按鈕太近，間距加到 16px」
  How AI receives them: stored in the note as a fenced block right after the image:
    ```codd-annotations
    {"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[{"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"…"}, …]}
    ```
  In the live-preview editor the fenced block is hidden; the image shows pins/boxes and a list under it. MCP `notes_read` returns the image +
  an annotated copy (`9f3a1c.annotated.png`, boxes and numbers burned in) + the coordinates list as text; Send-to-session inserts the annotated
  image path + the list. Shortcut: ⌘⇧A 標註模式.
