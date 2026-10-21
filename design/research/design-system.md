# CODD web visual design system ("FANCY/CODD — Phosphor Console")

Source root: `~/GitHub/codd-web/apps/web/src/`. The header of `styles.css:1-4` names the style **"Brutalist CRT amber terminal aesthetic"**. The app is dark only: `index.html:7-8` sets `theme-color #050505` and `color-scheme: dark`. There is **no light theme** and no `prefers-color-scheme` handling anywhere.

---

## 1. CSS custom properties (`styles.css:6-29`)

| Token | Value | Use / note (from source comments) |
|---|---|---|
| `--bg` | `#050505` | page, sidebar, inset fields |
| `--bg-soft` | `#0a0a0a` | cards, headers, inputs, modals, composer |
| `--bg-lift` | `#111111` | hover rows, current row, popovers, menus |
| `--line` | `#1a1a1a` | quiet dividers (often `dashed`) |
| `--line-bright` | `#2a2a2a` | default control and card borders, scrollbar thumb |
| `--amber` | `#ffb84a` | "brighter amber for AA": primary accent, titles, waiting state |
| `--amber-dim` | `#e09a2c` | secondary accent, borders of accent elements, ASCII corners |
| `--amber-glow` | `rgba(255,184,74,0.22)` | every glow, text-shadow and active-nav gradient |
| `--cream` | `#f5ecd6` | primary text |
| `--bone` | `#d4cdb8` | secondary text (~11:1 on #0a0a0a) |
| `--dim` | `#a8a298` | labels and meta (~7.5:1, AAA) |
| `--dimmer` | `#7a7468` | tertiary text, timestamps (~4.6:1, AA) |
| `--cyan` | `#6ee0f0` | idle state, markdown links, account key |
| `--danger` | `#ff7058` | errors, kill/remove, crit |
| `--success` | `#7cff9a` | busy state, OK, "running" chip |
| `--mono` | `'JetBrains Mono','Noto Sans Mono CJK TC',ui-monospace,'SF Mono',Menlo,Consolas,monospace` | body |
| `--display` | `'Space Mono','JetBrains Mono',monospace` | brand, h2/h3, titles |
| `--cjk` | `'PingFang TC','Noto Sans CJK TC','Microsoft JhengHei',sans-serif` | CJK fallback |

Runtime vars: `--app-h` and `--app-top`, set from visualViewport (`App.vue:105-116`). Scoped vars: `--st-color` for session state (SessionSidebar) and `--tone` for usage rows (DeviceStatus).

Hard-coded colors outside the tokens:
- `#000`: text on amber or danger fills, terminal and `pre` backgrounds
- `rgba(255,176,0,…)`: scanlines, login/modal glow `0 0 60px rgba(255,176,0,0.12)`, NEW menu glow `0.08`
- `rgba(0,0,0,0.75)`: modal backdrop
- Danger glow `rgba(255,90,60,0.4)`
- Success lamp glow `rgba(124,255,154,0.55)`
- Diff backgrounds `rgba(255,112,88,0.08)` and `rgba(124,255,154,0.07)`

xterm theme (`composables/terminalPool.js:32-36`): `background #000000`, `foreground #e8e6d8`, `cursor #ffb300`. Other terminal settings (lines 104-111, 28-29): `cursorBlink:false`, `fontFamily 'ui-monospace, SFMono-Regular, Menlo, monospace'`, `scrollback 5000`. Font size is 15 on desktop and 14 on touch, clamped to 10–24.

The one existing color-tag palette is the agent colors (`AgentEditor.vue:69-73`). It is a reasonable seed for group/session colors: `red #ef5b5b, blue #5b8def, green #4ec9b0, yellow #e6c84e, purple #b07cff, orange #ff9b4e, pink #ff7cb5, cyan #4ed1e6`. It renders as a square 10×10 `.color-dot` with `box-shadow: 0 0 6px currentColor` (AgentsList). Swatches are 36×36. The active swatch gets `border-color: cream; outline: 1px solid amber; outline-offset: 2px`, and the "none" swatch is `×`.

## 2. Typography

- **Loaded fonts** (`index.html:12-15`): Google Fonts JetBrains Mono (wght 100–800, plus italic) and Space Mono (400/700, plus italic).
- **Base** (`styles.css:35-47`): `font-family: var(--mono)`, `17px`, `line-height 1.62`, `letter-spacing 0.01em`, `font-variant-ligatures: none`, `font-feature-settings 'calt' 0`, antialiased.
- **Display uses**: brand 18px/700/0.04em; `.main h2` 32px/700/0.02em with glow (24px on mobile); card h3 16px/0.16em uppercase; modal h3 17px/0.16em; kanban h3 15px/0.2em; login h1 44px; session title 19px, `var(--display), var(--cjk)`.
- **Size ladder in use**: 10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 14, 15, 15.5, 16, 17, 18, 19, 22, 24, 26, 30, 32, 44.
  - Sidebar micro text: 10–12.5
  - Sidebar row title: 14
  - Buttons: 15 (500 weight)
  - Inputs: 16 (≥16 to stop iOS zoom)
  - Body: 17
- **Letter-spacing tiers**:
  - `0`: icon buttons, numbers, keys
  - `0.01–0.02em`: body, titles
  - `0.04em`: meta, notices
  - `0.06–0.08em`: buttons, chips, tags
  - `0.10–0.14em`: state labels, nav links, chips
  - `0.16–0.20em`: section and group labels (`SESSIONS`, `WORKSPACE`, `LAUNCH PROFILE`, `section-meta`)
- **Case**:
  - Buttons are always `text-transform: uppercase`. Icon, menu, item and profile buttons opt out with `text-transform:none`.
  - Section labels and nav are UPPERCASE.
  - Data chips are deliberately **lowercase** (`pid: 123`, `run: 4m02s`, `show removed`).
  - h2 is `text-transform:none`, but titles are usually written in caps.
- **Weights**: 500 (buttons), 600 (`strong`, th), 700 (brand, h2, waiting pill, mobile badge). The UI is otherwise regular.
- **Numbers**: `font-variant-numeric: tabular-nums` on counts, times and DeviceStatus.
- **CJK handling**:
  - `--cjk` is appended explicitly where Chinese is likely: titles `var(--display), var(--cjk)`, composer `var(--mono), var(--cjk)`, hint, and `.tag-sub` (剩餘), which uses `--cjk` alone.
  - Labels mix English caps with Traditional Chinese (`USAGE 剩餘`, `最近 PROMPT`, `5h/1w 用量尚未接上 設定 →`).
  - Composer IME guard: Enter is ignored while `isComposing`, `keyCode 229`, or a composition is active (`Composer.vue:72-79`).
  - Long paths use an RTL trick so the tail stays visible: `direction: rtl` with an inner `dir="ltr"` (SessionSidebar `.cwd` 542-551).

## 3. Shapes, effects, motion

- **Radius**: `0` everywhere (`border-radius: 0` is explicit on buttons, inputs, cards, modal, kanban). There are no rounded corners at all.
- **Borders**: 1px solid `--line-bright` by default.
  - Dividers are **1px dashed** `--line` or `--line-bright`.
  - Accent containers (login, modal, NEW menu, popover) use 1px solid `--amber-dim`.
  - State or selection is shown with a **2px left border** (rows, popover, blockquote, explain block).
- **Glows**:
  - Hover: `0 0 16px var(--amber-glow), inset 0 0 8px var(--amber-glow)`
  - Focus: `inset 0 0 0 1px amber, 0 0 8px glow`
  - Text: `text-shadow: 0 0 6–16px var(--amber-glow)` on brand, titles and active nav
- **Elevation shadows**:
  - Menus: `0 10px 30px rgba(0,0,0,.6)`
  - NEW menu: `0 10px 40px rgba(0,0,0,.8), 0 0 24px rgba(255,176,0,.08)`
  - Popover: `0 8px 30px rgba(0,0,0,.7), 0 0 0 1px rgba(0,0,0,.6)`
  - Drag float: `0 6px 24px rgba(0,0,0,.6), 0 0 0 1px var(--line-bright)`
  - Mobile drawer: `12px 0 40px rgba(0,0,0,.75)`
- **Overlays**: scanlines are `body::before` at z 9999. Vignette plus amber-tinted fractal-noise grain is `body::after` at z 9998, opacity .6. Both have `pointer-events:none`; see snippets 2–3.
- **Keyframes**:
  - `blink { 50% { opacity: 0 } }`, used as `1s steps(1) infinite` for the `_` cursor
  - `stagger-in { from {opacity:0; transform:translateY(4px)} to {opacity:1; transform:none} }`, 320ms `cubic-bezier(.2,.8,.2,1)`. List items get 20ms + 40ms·n delays for the first 12; the modal uses it at 200ms.
  - `scan { from {width:0;opacity:1} to {width:100%;opacity:0} }`, 600ms underline sweep on list-item hover
  - `boot-line { from {opacity:0; translateX(-4px)} }`, 200ms, login lines delayed 80/200/340/500/680ms
  - `lamp-pulse` (sidebar waiting): `0%,100% {opacity:1; text-shadow:0 0 10px amber, 0 0 2px amber} 50% {opacity:.3; text-shadow:none}`, 1.1s ease-in-out
  - `pulse { 50% {opacity:.35} }`, 1.1s (session header lamp)
  - `badge-pulse { 50% { box-shadow:0 0 2px glow; opacity:.75 } }`, 1.2s (mobile waiting badge)
  - `blink-soft { 50% {opacity:.45} }`, 1.2s (CONNECTING… stream label)
  - `shimmer` (skeleton, 200% background slide, 1.4s linear), `sk-pulse { 50% {opacity:.4} }` 1.4s
  - `pop-in` (translateX(-3px)→0, 120ms), `menu-in` (translateY(-3px)→0, 110ms), `fade-in` 160ms, `spin` 600ms linear (↻ refresh)
  - All pulses and skeletons are disabled under `prefers-reduced-motion`.
- **Transition speeds**: 80ms (buttons, `all ease-out`), 90ms (rows, cards), 100ms (nav), 120ms (caret rotate 90°), 160ms (shell grid column collapse), 200ms (drawer `cubic-bezier(.2,.8,.2,1)`), 400ms (usage bar width).

## 4. Component patterns

**Buttons** (`styles.css:91-155`)
- Base: transparent, `1px solid --line-bright`, `6px 14px`, 15px/500, uppercase, 0.08em. `::before '[ '` and `::after ' ]'` in `--dim`.
- Hover: amber border and text, brackets turn amber, double glow.
- `.primary`: amber fill with black text and black brackets; hover is a cream fill.
- `.danger`: danger outline; hover is a danger fill with black text and a red glow.
- `:disabled`: opacity .4.
- Bracket-less variants set `::before/::after {content:none}`: icon-btn, menu items, keys, toggles, send, tool-chip, rm, title-btn.
- `.icon-btn` (`SessionDetail.vue:580-596`): min 38×36, 15px; `.glyph` is 19px. `.on` gives amber text, `--amber-dim` border and `inset 0 0 8px glow`.
- NEW trigger (`NewSessionButton.vue:104-123`): 12.5px, `4px 8px`, amber text and amber-dim border/brackets; hover/open is an amber fill with black text. Label `+ NEW ▾`.
- `button.small`: 13px, `4px 10px`.

**Inputs** (`styles.css:158-194`)
- `--bg-soft`, `1px --line-bright`, `7px 10px`, 16px, `caret-color: amber`.
- Focus: `border amber` + `inset 0 0 0 1px amber, 0 0 8px glow`, no outline.
- Select chevron is drawn with two 45°/135° amber linear-gradients at `right 14px/9px`, size 5px.
- Checkbox: `accent-color: amber`.
- Form labels: 12–15px, 0.16em, uppercase, `--dim`. Required `*` is danger; `.hint` is lowercase dimmer 13px.

**Composer** (`Composer.vue:131-178`): a row with `--bg-soft` and `border-top --line`, padding 8. Textarea is `--bg`, min-height 44, max 150 (120 on mobile), auto-growing. SEND button is amber text with an amber-dim border, min 72×44, filling amber on hover. Placeholder: `訊息 · Enter 送出 · ⇧Enter 換行`.

**KeyBar** (`KeyBar.vue:51-99`): horizontally scrolling row, no scrollbar, gap 6. Keys are `--bg` with a `--line-bright` border, min 44×40, 15px. Hover is amber with an inset glow; active is an amber fill. `^C` is danger with border `rgba(255,112,88,.45)`. Keys: `ESC TAB ⇧TAB ↑ ↓ ← → ⏎ ^C 1 2 3`.

**Tabs**: none exist. The closest analogs are:
- Sidebar nav `.on`: gradient plus blinking `_`
- `.icon-btn.on`
- Memory rail `.day-item.active`: `--bg-soft` with a 2px amber left border

**Cards** (`styles.css:527-575`): `--bg-soft`, `1px --line-bright`, padding `18px 20px`, mb 14. ASCII corners: `┌─` top-left and `─┘` bottom-right, 11px `--amber-dim` on a `--bg` patch. h3 is display, 16px, 0.16em, uppercase amber, with a dashed bottom rule. Editing state overrides `border-color: var(--amber)`; error state uses `var(--danger)`.

**List items** (`styles.css:578-651`): `--bg-soft`, `1px --line`, padding `12px 16px 12px 28px`. Bullet `•` at left 12 becomes `▸` amber on hover. Hover also sets an amber border, `--bg-lift`, `translateX(2px)`, and a 1px amber→transparent underline that sweeps in (`scan`). The `.meta` line is 15px bone, with code in amber-dim.

**Chips / pills / tags**
- Generic chip: transparent, `1px --line-bright`, `2–3px 10–12px`, 12–15px, 0.06–0.08em, **lowercase**, mono.
- `.chip.primary`: success or amber fill with black text.
- `.chip.dim`: `--dim` text.
- `.chip.success`: success outline.
- State chip: `border-color: currentColor`, uppercase. The waiting variant is an amber fill with black text.
- Session header chip (`SessionDetail.vue:478-492`): 12px, 0.1em, `1px 8px`, `border:1px solid currentColor`. Waiting adds `background: rgba(255,184,74,.12)`. Text reads e.g. `◆ WAITING · PERMISSION · 3m`.
- Sidebar state label: 10px, 0.14em, `0 4px`. Waiting is a solid amber pill, 700 weight, with a glow.
- Kanban `.tag`: `3px 10px`, 13px, uppercase.
- `.kbd`: `1px --line-bright`, `0 5px`.
- `.sec-waiting`: black on amber, `0 6px`, 11px, glow, reads `◆ 3`.

**Status dots ("lamps")**: Unicode glyphs, not CSS circles (see §7). Exceptions are the square `.color-dot` for agents and a 9px `●` in DeviceStatus cells.

**Sidebar session rows** (`SessionSidebar.vue:468-610`)
- Layout: `flex column`, padding `7px 8px 7px 10px`, min-height 44 (52 on touch), `border-left: 2px solid transparent`.
- Hover: `--bg-soft` with a `--line-bright` left border. `.current`: `--bg-lift` with an amber left border and a cream title. Focus-visible: `1px --amber-dim` outline at offset -1.
- line1: lamp (12px column, 11px glyph) · title (14px, ellipsis) · state label.
- line2: indented 20px, 12px dimmer. Shows cwd (RTL-truncated, `--dim`) · `t-state` duration (state-colored) · `·` · uptime. Optional `⚠ NO HOOK` (10.5px amber-dim).
- Drag:
  - Grip `⠿` (10px, opacity 0 → .7 on hover; always shown at 30px on touch).
  - Ghost: `1px dashed --amber-dim` with a 2px left border and hidden contents.
  - Float: `--bg-lift` with a shadow.
  - Starts after 4px of movement; clicks are swallowed for 300ms after a drop.
- Removable stopped rows: `✕` button 28×28 (40 on touch), opacity .55 → 1. Hover gives a danger text and border.

**Section headers**:
- `.sec-head` (11.5px, 0.18em, dim): `SESSIONS 4 ··· ◆ 2`, with the count in amber-dim tabular nums.
- Collapsible toggles `▸ STOPPED (12)` and `▸ WORKSPACE`: the caret rotates 90°, min-height 32 (40 on touch).
- Page level (`styles.css:471-524`): h2 32px amber with glow, then `.section-meta` (15px, 0.18em, uppercase dim, e.g. `INDEX · 004 files · 2 active`) flanked by 1px gradient hairlines. `.path` / `code` pills sit inside it.

**Session header bar** (`SessionDetail.vue:412-632`): `--bg-soft`, `border-bottom 1px --line-bright`, padding `8px 12px 8px 16px`.
- Left: lamp 14px + title 19px amber glow + chip, with line2 at 13px dim: `~/…/a/b · UP 1h02m · CTX 42%` (CTX <20 turns danger).
- Right: `A− 15 A+ ⤢ ⌨ ⋯`.
- `⋯` menu: `--bg-lift`, `1px --line-bright`, min-width 250, padding 6, items 14px and min-height 40. Items are `↗ OPEN IN TERMINAL.APP`, `↻ RESTART`, `■ KILL`, `✕ REMOVE`; the last two are danger-colored.

**Popovers**:
- Sidebar hover card (`SessionSidebar.vue:726-807`): 340px wide, `--bg-soft`, `border-left 2px var(--st-color)`, 13px, 380ms hover delay. Sections:
  - state line (10.5px, 0.14em)
  - title (14px cream)
  - last prompt (dashed box on `--bg`, 8-line clamp)
  - path
  - meta row (profile · tool · ctx % · up · `Alt+n` kbd)
  - hint `拖曳或 Alt+Shift+↑↓ 調整順序`
- Header prompt popover: `--bg-lift`, `1px --amber-dim`, `0 10px 30px rgba(0,0,0,.6), 0 0 18px glow`.

**Dropdown menu (NEW)** (`NewSessionButton.vue:126-219`): 252px, `--bg-soft`, `1px --amber-dim`, padding `6px 0`.
- Header `LAUNCH PROFILE` (10.5px, 0.2em) with a dashed rule.
- Items: `▸ name` (14px cream) over cwd (11.5px dimmer). Hover is `--bg-lift` plus `inset 2px 0 0 amber`.
- Footer `管理 profiles →`.

**Modal** (`styles.css:919-968`):
- Backdrop: `rgba(0,0,0,.75)` + `blur(2px)`.
- Box: 520px, `--bg-soft`, `1px --amber-dim`, padding `28px 32px`, `0 0 60px rgba(255,176,0,.12)`.
- h3: 17px, 0.16em, uppercase, dashed rule.
- Rows: column, gap 8. Actions are right-aligned above a dashed top rule.

**Toasts**: none. Errors are inline `.error` text (danger 15px, prefixed `[ERROR] ` in bold through `::before`), plus browser `confirm()` dialogs. Setup success is a box with `1px solid --success`.

**Tables**: only inside markdown (`styles.css:707-725`): `1px --line-bright` cells, `8px 12px`. `th` sits on `--bg` with amber 600 text, 0.08em, uppercase, 15px.

**Code / pre**:
- Inline: `--bg`, amber text, `1px --line`, `2px 7px` (SetupGuide uses `0 5px`).
- `pre`: `#000` background, `1px --line-bright`, `16px 18px`.
- Diff: `-` lines danger and `+` lines success on tinted backgrounds; context lines dimmer.

**Banner** (SetupGuide compact, 412-436): `1px --amber-dim`, `linear-gradient(90deg, var(--amber-glow) 0%, transparent 70%), var(--bg-soft)`. Content: `◆` + message + `→ 設定` + `✕` dismiss.

**Skeletons**: 9px bars on `--line-bright`, shimmer or sk-pulse.

**Scrollbars** (`styles.css:1002-1008`): 10px wide; track `--bg`; thumb `--line-bright` with a `2px solid --bg` border (inset look), hover `--amber-dim`. Firefox: `scrollbar-width: thin; scrollbar-color: var(--line-bright) transparent`. Selection: amber background with black text.

**Terminal frame** (`TerminalPane.vue:117-198`): the pane and viewport are `#000` with no border; the session header provides the frame. The host is inset `top 6 / left 10 / right 2 / bottom 4`.
- Overlay hint (top-right): `◇ 跟隨其他裝置的尺寸 120×40 · 點此接管`, 12.5px amber on `rgba(5,5,5,.88)` with `1px dashed --amber-dim`. Hover fills amber and the border turns solid.
- Stream label (bottom-right): `CONNECTING…` / `RECONNECTING…` / `STREAM CLOSED`, 12px, 0.14em, dim, `blink-soft`.
- Exit banner: `--bg-soft` with a top border, `✕ SESSION EXITED · code 0`, plus a primary `↻ RESTART` and a danger `REMOVE`.

**Login** (`styles.css:839-916` and `LoginView.vue`):
- Card: radial background `#0a0a05 → --bg 60% → #000`, `1px --amber-dim`, `48px 56px`, max 460, with the ASCII `┌────…┐` rule centered on the top edge.
- h1 44px. Tag line `// channel operator console` (15px, 0.2em, uppercase dim).
- Boot log: `[ OK ]` in success, `[ .. ]` in amber, `waiting for operator_`.
- Footer hint `// allowlist only · session: jwt · cookie: httpOnly`.

**DeviceStatus** (sidebar footer, `DeviceStatus.vue:295-464`): 12.5px mono, tabular, container-query.
- `HOST` section: tag in amber-dim, freshness on the right (`up 3d4h`). 2-column grid of `K  value` cells (CPU / MEM / DISK / SWAP / BAT; `.k` 11px 0.12em dim, `.v` cream right-aligned), each with a 2px meter (`--line-bright` track, `--amber-dim` fill).
- `USAGE 剩餘` section: optional account key in cyan. Each window row is `5h ▮▮▮▮▮▮▯▯▯▯ 62%` (10-segment bar, 7px tall) with a second line `重置 14:30 … 2h10m後`.
- Not connected: `5h/1w 用量尚未接上 設定 →`.

## 5. Layout

- **App shell** (`styles.css:199-213`):
  - `position: fixed` and sized to the visual viewport.
  - `grid-template-columns: 280px minmax(0,1fr)`: the **sidebar is 280px**.
  - The document never scrolls; the sidebar and `.main` scroll internally.
- **Sidebar** = `sb-head` (padding `16px 14px 12px 16px`, dashed bottom; brand left, `+ NEW` right) → `sb-scroll` (padding `14px 8px 16px`) → `sb-foot` (padding `10px 14px`, dashed top).
  - Inside sb-scroll: setup banner, `SESSIONS` rows (gap 2px), `STOPPED` (mt 10, max 12 items, then `+N more → ALL SESSIONS`), `WORKSPACE` (mt 18, dashed top) nav.
  - Nav links: `6px 10px 6px 28px`, 13.5px, 0.12em, `▸` at left 12.
  - Workspace items: IDENTITY, SKILLS, AGENTS, TASKS, MEMORY, KANBAN, PROFILES, ALL SESSIONS.
  - The foot holds DeviceStatus and an account row (11.5px: email · SETUP · LOGOUT).
- **Main**: padding `28px 36px 60px`. `.full-bleed` (session page) has padding 0, overflow hidden and a flex column: header → error → terminal (flex 1) → exit banner → KeyBar → Composer.
- **Focus mode** (≥768px, session page only): the grid collapses to `0 minmax(0,1fr)` over 160ms. A 14×56 edge handle `›` (opacity .55, widening to 20px on hover) brings the sidebar back.
- **Content widths**: home 920; setup 860; modal 520; popover 340; memory rail 240px column (gap 24); skill tree `minmax(180px,280px)`; profile grid `repeat(auto-fill, minmax(240px,1fr))` gap 10; kanban 3 equal columns (min-height 460, dashed separators).
- **Header heights**: there is no fixed-height top bar on desktop. The session header is about 56px (8px padding, 19px title + 13px meta line). The mobile bar is `48px + safe-area`.
- **Spacing values seen**: 1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 28, 30, 36.
  - Common gaps: 2 (rows), 4 (header actions), 6, 8 (toolbar, menus), 10, 12.
  - Section rhythm: mb 14 / mt 18 / mt 22.
  - Control heights: 32 (toggles), 36–38 (icon buttons), 40 (menu items, touch), 44 (rows, composer, keys).
- **Breakpoints and media queries**:
  - `max-width: 767px`: off-canvas drawer `min(86vw,320px)`, `translateX(-102%)`, 200ms, backdrop `rgba(0,0,0,.62)` + blur 1px. Mobile top bar `≡` with a waiting badge, page title, and a state pill `◆ WAITING`.
  - `pointer: coarse`: 40px minimum hit targets.
  - `hover: hover and pointer: fine`: popovers.
  - `@container (max-width:200px)`: the DeviceStatus grid drops to 1 column.
  - `max-width: 720px`: SkillFiles stacks.
- **Z-index**: scanlines 9999, grain 9998, popover 200, modal 100, drawer 60, backdrop 55, NEW menu 50, focus handle 40, session menu 30, mobile bar / header popover 20, header 5.
- **Keyboard**: Alt+1..9 jumps to the nth active session (uses `e.code`, App.vue:79-88). Alt+Shift+↑/↓ reorders the focused row. Esc closes the drawer and menus.

## 6. Iconography and voice

- **No SVG or icon font.** Everything is Unicode glyphs in the mono font:
  - Markers: `▸` (bullets, carets, active marker), `•`, `■`, `◆ ● ○ ✕ ◇`, `⠿` (grip), `⚠`
  - Navigation: `→ ← ↗ ↻`, `⋯`, `≡` (menu), `›` (focus handle), `▾`
  - Actions: `⤢` (focus), `⌨` (composer), `A− A+`, `⇧ ⏎ ^C`
  - Box-drawing for frames: `┌─ ─┘ ┌────┐`
- Emoji leak in a few legacy spots that break the voice: `✏️ 編輯`, `💾 儲存`, `🗑 刪除`, and the favicon `🎛️`.
- **Voice**:
  - `[ BRACKETED ]` uppercase button labels; the brackets come from CSS.
  - Code-comment empty and loading states: `// loading …`, `// scanning .claude/skills …`, `// 沒有執行中的 session`, `// no sessions — click + NEW to spawn`.
  - Middle-dot `·` separators everywhere (`INDEX · 004 files · 2 active`).
  - Zero-padded counts (`String(n).padStart(3,'0')`).
  - Boot-log `[ OK ] / [ .. ]`, the blinking `_` cursor on active nav, `[ERROR] ` prefix, `$ command` and `→ command` meta lines, `.model` chip, `perm:x`, `effort:x`.
  - Compact durations `45s / 12m / 1h02m / 2d03h`, `UP`/`RAN`, `CTX 42%`.
  - Brand is `FANCY/CODD`; the tab title becomes `(n) FANCY/CODD` while sessions are waiting.
  - Bilingual: structural labels in English caps, explanatory and help text in Traditional Chinese.

## 7. Status visualization

Every state is double-encoded with glyph and color (comment: "形狀 + 顏色雙重編碼（色弱也分得出 waiting）"). Defined in `STATE_META`, `stores/sessions.js:65-78`. The state comes from `s.status !== 'running'` (→ `ended`), otherwise from `s.activity.state ∈ {waiting,busy,idle}`, otherwise `unknown`.

| State | Glyph | Label | Color | Extra treatment |
|---|---|---|---|---|
| waiting | ◆ | WAITING | `--amber` | **Sidebar row**: gradient `rgba(255,184,74,.09)→.02` background, amber 2px left border, cream title, lamp at 12px with `lamp-pulse` 1.1s, label as a solid amber pill (black 700 text, glow). Hover background `.13`; when current `.16`. **Header**: lamp pulses with glow, chip gets `rgba(255,184,74,.12)` fill. **Mobile**: amber-filled pill and a pulsing count badge. **Counts**: `◆ n` amber pill in the SESSIONS header, `(n)` in the document title |
| busy | ● | BUSY | `--success` | lamp `text-shadow 0 0 6px rgba(124,255,154,.55)` |
| idle | ○ | IDLE | `--cyan` | in-state duration shown in `--dim` instead of cyan |
| unknown | ● | — | `--bone` | lamp opacity .6; screen-reader text "UNKNOWN" |
| ended | ✕ | EXITED | `--dimmer` | dim title, 10px lamp, listed under collapsible STOPPED with exit time |

- **Waiting reasons** (`activity.reason`): `permission/question/plan`. The sidebar popover shows `權限確認/回答問題/確認計畫`; the header chip shows `PERMISSION/QUESTION/PLAN`.
- **Duration in the current state** comes from `activity.since`, ticking every 1s.
- **Missing-hook warning**: `⚠ NO HOOK` in amber-dim when `hook_seen === false` 20s or more after start on a claude command.
- **Other session fields used**: `title, profile_name, cwd, cwd_short, last_prompt, context_left_pct, activity.last_tool, started_at, exited_at, exit_code ('signal:15'), order, removed, restart_count, pid, command`.
- **Meter tones** (DeviceStatus): `ok` = success, `warn` = amber, `crit` = danger, `muted` = dimmer.
  - Usage remaining <50% is warn, <20% is crit; a window past its reset shows "已重置" as muted at 100%.
  - Disk used ≥85% is warn, ≥95% is crit.
  - Battery ≤20% is warn, ≤10% is crit (on battery only).
  - Memory pressure `normal/warn/critical` maps to ok/warn/crit.
  - Stale data: host >60s or usage >1800s renders at `opacity:.5; filter:grayscale(1)`, and the freshness text turns amber-dim.
- **Setup items**: installed `●` (success), outdated `◆` (amber), missing `○` (dimmer). Overall: `● 設定完成` or `◆ n 項待處理`.

---

## 10 most characteristic rules (verbatim)

**1. Bracket buttons with phosphor hover** (`styles.css:91-123`)
```css
button { font-family: var(--mono); text-transform: uppercase; letter-spacing: 0.08em; font-size: 15px; font-weight: 500;
  background: transparent; color: var(--cream); border: 1px solid var(--line-bright); padding: 6px 14px; border-radius: 0;
  cursor: pointer; transition: all 80ms ease-out; position: relative; }
button::before { content: '[ '; color: var(--dim); }
button::after  { content: ' ]'; color: var(--dim); }
button:hover { border-color: var(--amber); color: var(--amber);
  box-shadow: 0 0 16px var(--amber-glow), inset 0 0 8px var(--amber-glow); }
button.primary { background: var(--amber); color: #000; border-color: var(--amber); }
```

**2. CRT scanlines** (`styles.css:50-64`)
```css
body::before { content: ''; position: fixed; inset: 0; pointer-events: none; z-index: 9999;
  background: repeating-linear-gradient(to bottom, rgba(255,176,0,0.025) 0px, rgba(255,176,0,0.025) 1px, transparent 1px, transparent 3px);
  mix-blend-mode: screen; }
```

**3. Vignette + amber grain** (`styles.css:67-77`)
```css
body::after { content: ''; position: fixed; inset: 0; pointer-events: none; z-index: 9998;
  background: radial-gradient(ellipse at center, transparent 50%, rgba(0,0,0,0.55) 100%),
    url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1  0 0 0 0 0.69  0 0 0 0 0  0 0 0 0.07 0'/></filter><rect width='200' height='200' filter='url(%23n)'/></svg>");
  opacity: 0.6; }
```

**4. ASCII-corner card** (`styles.css:527-558`)
```css
.card { background: var(--bg-soft); border: 1px solid var(--line-bright); border-radius: 0; padding: 18px 20px; position: relative; }
.card::before { content: '┌─'; position: absolute; top: -1px; left: -1px; background: var(--bg); color: var(--amber-dim);
  padding: 0 4px; font-size: 11px; line-height: 1; transform: translateY(-50%); }
.card::after { content: '─┘'; position: absolute; bottom: -1px; right: -1px; background: var(--bg); color: var(--amber-dim);
  padding: 0 4px; font-size: 11px; line-height: 1; transform: translateY(50%); }
```

**5. Active nav with glow gradient + blinking cursor** (`styles.css:332-358`, `985-987`)
```css
.sidebar .nav a::before { content: '▸'; position: absolute; left: 12px; color: var(--dimmer); }
.sidebar .nav a.on { color: var(--amber); background: linear-gradient(90deg, var(--amber-glow) 0%, transparent 100%);
  text-shadow: 0 0 6px var(--amber-glow); }
.sidebar .nav a.on::after { content: '_'; color: var(--amber); animation: blink 1s steps(1) infinite; margin-left: 4px; }
@keyframes blink { 50% { opacity: 0; } }
```

**6. Waiting session row** (`SessionSidebar.vue:578-595`, `612-615`)
```css
.srow.st-waiting { background: linear-gradient(90deg, rgba(255,184,74,0.09) 0%, rgba(255,184,74,0.02) 100%); border-left-color: var(--amber); }
.srow.st-waiting .lamp { font-size: 12px; animation: lamp-pulse 1.1s ease-in-out infinite; }
.srow.st-waiting .state { color: #000; background: var(--amber); border-color: var(--amber); font-weight: 700; box-shadow: 0 0 8px var(--amber-glow); }
@keyframes lamp-pulse { 0%, 100% { opacity: 1; text-shadow: 0 0 10px var(--amber), 0 0 2px var(--amber); } 50% { opacity: 0.3; text-shadow: none; } }
```

**7. Session row base + current** (`SessionSidebar.vue:468-495`)
```css
.srow { display: flex; flex-direction: column; gap: 1px; padding: 7px 8px 7px 10px; color: var(--bone);
  border-left: 2px solid transparent; transition: background 90ms, border-color 90ms; min-height: 44px; justify-content: center; }
.srow:hover { background: var(--bg-soft); border-left-color: var(--line-bright); }
.srow.current { background: var(--bg-lift); border-left-color: var(--amber); }
```

**8. 10-segment usage bar** (`DeviceStatus.vue:450-464`)
```css
.bar { position: relative; display: block; height: 7px; background: var(--line-bright);
  mask-image: repeating-linear-gradient(90deg, #000 0 calc(10% - 1px), transparent calc(10% - 1px) 10%); }
.bar b { position: absolute; inset: 0 auto 0 0; max-width: 100%; background: var(--tone); transition: width 400ms ease-out; }
```

**9. Page title + flanked section meta** (`styles.css:471-524`)
```css
.main h2, .section-title { font-family: var(--display); font-weight: 700; font-size: 32px; letter-spacing: 0.02em;
  color: var(--amber); text-shadow: 0 0 12px var(--amber-glow); }
.section-meta { font-size: 15px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--dim); display: flex; align-items: center; gap: 12px; }
.section-meta::before { content: ''; flex: 1; height: 1px; background: linear-gradient(90deg, var(--line) 0%, transparent 100%); }
```

**10. List-item hover: marker swap + scan sweep** (`styles.css:597-620`, `992-995`)
```css
.list-item:hover { border-color: var(--amber); background: var(--bg-lift); transform: translateX(2px); }
.list-item:hover::before { content: '▸'; color: var(--amber); text-shadow: 0 0 6px var(--amber-glow); }
.list-item:hover::after { content: ''; position: absolute; left: 0; bottom: 0; width: 100%; height: 1px;
  background: linear-gradient(90deg, var(--amber) 0%, transparent 100%); animation: scan 600ms ease-out; }
@keyframes scan { from { width: 0; opacity: 1; } to { width: 100%; opacity: 0; } }
```

**Runner-up:** input focus (`styles.css:171-177`).
```css
input:focus { outline: none; border-color: var(--amber); box-shadow: inset 0 0 0 1px var(--amber), 0 0 8px var(--amber-glow); }
```

---

## Things the desktop design has to invent (not in CODD web)

- **Groups and folders, plus color tags on sessions and groups.** Only an agent color palette and a `.color-dot` exist. The sidebar today is a flat SESSIONS list plus STOPPED.
- **Tabs or a split-pane switcher between Claude and a plain terminal.** No tab component exists.
- **Toast and notification components.** Only inline `.error` and `confirm()` exist.
- **A light theme.** None exists.
- **Multi-account usage display.** DeviceStatus shows one account (`usage.config_key`), with 5h/1w rows.
- **Native macOS chrome** (traffic-light inset, vibrancy, menu bar extra). Everything today is web-only. The sidebar header padding (16px top) would need room for the traffic lights.