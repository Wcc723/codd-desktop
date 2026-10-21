# M2 plan — Sessions complete

Goal: everything about sessions, the sidebar, panes and the keyboard flow that M1 did not finish.
At the end of M2 the sidebar behaves exactly like the approved artboards (SidebarStates, Main, Home)
on real data, claude sessions started outside CODD show up read-only with the EXT badge, ⌘K / ⌘1–9 /
⌃Tab / ⌘\ / ⌘⏎ / ⌘L / ⌘T / ⌘J all work from any focus, a native composer sends IME-safe multi-line
prompts, the ⌘J panel has tabs and maximize, the ⌘N sheet matches the NewSession artboard (resume
picker, launch profiles), a session whose holder is gone shows its last screen, and CODD is robust
against a second instance, unanswered holders and its own errors.

Sources: design/SPEC.md (§8 v2 and §9 v3 override), design/artboards-src/{SidebarStates,Main,Home,
QuickSwitch,Split,NewSession,Settings}.src.html (APPROVED, frozen: implement them, do not redesign),
design/helmet.html (tokens), docs/ARCHITECTURE.md, docs/M1-REPORT.md.

Out of scope: accounts / cswap / quota / menu bar popover content (M3), STATUS beyond hooks (M3),
Settings beyond 通知 and 啟動設定檔 (M3), notebook / editor / MCP / session pad drawer / `codd://`
chips in the composer (M4), onboarding and hardening (M5).

Revision 2 (critique, 2026-10-16): §0 corrected against the code, D4/D6/D9/D17/D18 amended, D23–D31
added, C1/C3/C4 contracts extended, the three integration steps split into seven smaller sequential
steps (I1–I7), §5 dump keys and §6 e2e runs extended, §8 rules for every agent added.

---

## 0. Starting point (code survey, 2026-10-16, re-checked by the critique)

| Item | Exists after M1 | Gap M2 closes |
|---|---|---|
| 1 Sidebar | View-based NSOutlineView fed by `SidebarSnapshot` diffs; NEEDS YOU + `◇ n 個待看` line; PINNED; R1 tinted group blocks with aggregates; projects; 未分類; `[+ 新增群組]` (creates `新群組`, then inline rename); filter; TREE \| STATE toggle; drag & drop (`DropPlanner`, native gap feedback, target block highlight); ⌥⇧↑↓; ⏎ rename; ⌘⌫ archive + UNDO toast (fixed 6 s, no countdown); multi-select bar; session / group / project context menus with the swatch row; layout.json persistence; stale / EXT drawing in `SessionCellView` | `isStale` is never set in real mode; group header hover actions `+` `⋯` `清理已停止 (n)`; 清理已停止 in the group menu; inline new-group row with color popover + 1–8 (SidebarStates D); STATE view details (glyph + count headers, `n stale`, line 2 = group square + project); hover card (F); toast countdown; amber drop line; restoring archived sessions after the toast; ⌘P / ⌘. as real shortcuts (today they are key equivalents of context-menu items only); external rows. **Also (critique):** the filter does not apply to NEEDS YOU / PINNED and matches only titles in STATE mode; `刪除對話紀錄…` only removes the session from CODD although its alert says the transcript is deleted (D23); the archive toast counts every selected id, not the archived ones |
| 2 External | `SessionVM.external`, `EXT` chip, EXT banner with a dead `接管到 CODD` button and the wrong source text `偵測自 claude agents --json` | nothing populates it in real mode; the menu bar panel would offer `[1 允許]` for it |
| 3 Keyboard | ⌘1–9, ⌃Tab, ⌘\, ⌘⏎, ⌘T, ⌘J, ⌘N, ⌥⌘F are menu key equivalents; terminals already decline ⌘L (`KeyEquivalentPolicy.codd`) | ⌘K is a placeholder (sessions only, substring); no ⌘L / ⌘P / ⌘. menu items; terminals do not decline ⌘P / ⌘. |
| 4 Composer | — | everything |
| 5 Panel | one shell per session, strip `zsh · 120×38 · ⌘J · ✕`, splitter; tab TITLE / CWD events ignored | panel tabs, `+`, maximize, bells drawn, OSC titles, the `●` running lamp of a tab (Split artboard, D25) |
| 6 New Session | M1 subset (single column: folder, 最近/建議 lists, kind, permission, model text, name, color, preview with `<new>` and `--settings '{hooks → CODD}'`) | the artboard (two columns, combobox, start radios + resume picker, account placeholder, profiles, preview copy, destination) + Settings › 啟動設定檔 |
| 7 Home | M1 subset (plain lists) | the artboard (NEEDS YOU cards, DONE line, LAUNCH cards, RECENTLY STOPPED with transcripts, USAGE) |
| 8 Dead sessions | `CoddTerminalSetup.holderGoneNote` (also a blank terminal when an engine attaches to a connection whose holder already ended after an exit) | ring replay from disk, read-only, in both cases |
| 9 Robustness | `HolderSessionStore.lastError` only logged (and returned by `AppDelegate.launch`); no lock; reconnecting holder keeps its last state; the error banner's `↻ 重送上一則` / `⟲ 稍後自動重試` buttons do nothing; `scripts/m1-smoke.sh` and manual runs on a temp root may take the user's hook port 47821 | single-instance lock, problem banner, UNREACHABLE, error-banner actions (D26), test roots on their own port range (D24) |
| 10 Lifecycle | closing the window keeps CODD (`applicationShouldTerminateAfterLastWindowClosed` false), Dock reopen, menu bar `開啟 FANCY/CODD`, ⌘0, ⌘Q flushes hooks and leaves holders running | verify (including that terminals stop rendering while the window is closed), test, document; coddd deferred in ARCHITECTURE.md |

---

## 1. Decisions (reversible technical defaults; listed again in the report)

| # | Topic | Decision |
|---|---|---|
| D1 | Composer transport | Holder INPUT with a new capability **`input.paste`** (flags bit1). The holder wraps the payload in `ESC[200~ … ESC[201~` only when the child has `?2004` on, strips bracket markers inside the payload, and sends the submit `\r` **50 ms** after the closing marker reached the PTY (plain submit stays 10 ms). Older holders (no cap): the client brackets when the last known modes (WELCOME / ATTACHED) have `?2004`. Single-line text without TAB = plain INPUT + submit. |
| D2 | Composer text rules | Line endings → `\r`; ESC, NUL, DEL and C0 controls except TAB / newline removed; trailing whitespace trimmed; paste when the text has a newline or TAB; at most 256 KiB per send. |
| D3 | Composer persistence | Per session `<dataRoot>/sessions/<id>/composer.json` (0600, atomic): draft + history (≤ 100 entries, consecutive duplicates collapsed). Goes with the session directory. |
| D4 | Pasted images | Saved as PNG to `<dataRoot>/sessions/<id>/attachments/<yyyyMMdd-HHmmss>-<6 hex>.png` (dir 0700, file 0600); the absolute path is inserted **backslash-escaped like a Terminal.app drop** (D31; the default data root contains `Application Support`). No automatic cleanup in M2. |
| D5 | Launch profiles | `<dataRoot>/profiles.json` (versioned, 0600, atomic), seeded with the 4 built-ins on first read, holds `defaultProfileId`. Built-ins are editable / deletable; the last claude profile cannot be deleted; deleting the default falls back to the first claude profile. Sessions naming a missing profile use the default. Shell sessions and shell tabs use the first shell profile (its `shellPath` and environment), else the built-in `zsh`. |
| D6 | External sessions | Source = the registry `<claudeDir>/sessions` only (no `claude agents --json`). Not ours = neither its pid, its Claude session id nor its parent belongs to one of this CODD's claude sessions. Shown under the project whose folder equals its cwd (both sides symlink-resolved; a subfolder is a different cwd); a folder CODD does not know gets a **transient** project in 未分類 that is never saved and becomes a real project as soon as a CODD session is created there or the user picks `加入為專案`. `sdk-*` and `claude-desktop` entrypoints hidden. Counted in live / NEEDS YOU / badges; **no notifications**; read-only (no terminal, no answer bar, no composer, no `[1 允許]` anywhere — menu bar panel and Home included); no adopt button (the artboard's `接管到 CODD` is not shown). A claude whose ancestor is one of this CODD's shell holders is EXT with `在 CODD shell 中` and a `[前往 shell]` action. Ids per D27. |
| D7 | Dead-session replay | `RingFileReader` reads the ring from the same point a live holder's WELCOME `resync` would pick, the replay passes the OSC 52 filter, input is disabled, a dim footer line follows. Used when a session's PTY has no connection **or its connection ended** (holder gone). Missing ring → the M1 note. |
| D8 | UNREACHABLE | An overlay flag (`SessionVM.unreachableSince`), not a `SessionState` (hook states keep flowing while the socket does not). Set after 5 s of failed reconnects (or a handshake that never completes) while meta.json says the holder runs; glyph `◌` in danger color, pill `Unreach`, `[↻ 立即重試]`. |
| D9 | Single instance | `<dataRoot>/codd.lock` (0600) held with `flock(LOCK_EX\|LOCK_NB)` for the app's life, content `{"pid":…,"app":"<bundle path>","startedAt":ms}`. A second instance on the same data root activates the first (`NSRunningApplication(processIdentifier:)`), asks it to show its main window (D28) and exits 0 before touching anything else; when it cannot find it, an alert `另一個 CODD 正在使用這個資料夾`, then exit. Mock mode takes no lock. Different data roots run side by side (tests next to the user's CODD). |
| D10 | Lifecycle | Closing the main window keeps CODD running with its menu bar extra and Dock icon; reopen from Dock, menu bar `開啟 FANCY/CODD` or ⌘0; ⌘Q quits, holders keep running. While the window is closed every terminal slot is occluded (no rendering). No quit dialog (StatusDialogs d + Settings GENERAL 結束時 are M3). The app hosts the hook endpoint; **coddd is deferred** (documented in ARCHITECTURE.md with the reasons). |
| D11 | Panel tabs | The ⌘J panel holds several shell tabs (own holders under `sessions/<id>/tabs/<tab>/`). Label = the shell's OSC title when it sets one (≤ 24 chars), else `zsh n`. Maximize hides the top terminal (occluded, stays hot). |
| D12 | Bells | A BEL on a tab that is not on screen draws an amber `◆` after its label until the tab is shown (main strip and panel). Not persisted. |
| D13 | panes.json | Version stays 1; additive keys `panelTabs`, `panelSelected`, `panelMaximized`, `composerOpen`; `panel` is still written (= selected panel tab) so an M1 build keeps working (it adopts the other live panel tabs as main-strip tabs; acceptable). |
| D14 | Quick switch | Sections SESSIONS / PROJECTS / ACTIONS (NOTES = M4, account actions = M3: not shown). `⌘⏎` = open + ⌘J panel. `⌥⏎ 新視窗` not shown (no multi-window in M2). Empty query = NEEDS YOU first, then most recently viewed sessions, then common actions. |
| D15 | Stale | IDLE for more than 1 h (fixed until Settings › SESSIONS in M3; DEBUG `-codd-stale-after <s>`), recomputed every 60 s and on transitions. |
| D16 | New Session account | Disabled select `跟隨全域登入` + the artboard hint; no quota line (no real account data before M3). |
| D17 | Home USAGE | Drawn from the same `AccountStore` as the sidebar footer (still `MockAccountStore` in real mode until M3), labelled as sample data per D29. |
| D18 | Resume picker | Lists `<claudeDir>/projects/<slug>/*.jsonl` whose lines' `cwd` equals the folder (the slug is lossy; the slugs of the typed, standardized and symlink-resolved folder are all tried); title `customTitle` > `aiTitle` > first user prompt; `sdk-*` hidden; transcripts a running CODD session **or a live registry entry (external claude)** uses are shown disabled `執行中`; expiry warning `! resume N 天後過期` when N ≤ 5 (N = cleanupPeriodDays − age; cleanupPeriodDays read-only from `<claudeDir>/settings.json`, default 30). Claude's files are never written. |
| D19 | Archive restore | Project context menu `封存 n ▸` lists archived sessions with `還原「…」` and `全部還原`. |
| D20 | Hover card | 380 ms delay, right of the row; last prompt from the latest `UserPromptSubmit` hook (`SessionVM.lastPrompt`, memory only), else the transcript's `last-prompt` record. Never while dragging. |
| D21 | Shortcuts | Main-menu items for ⌘L (composer), ⌘P (pin / unpin current), ⌘. (stop current, confirms like the menu); ⌘P and ⌘. are added to `CoddTerminalSetup.keyEquivalents` (⌘L already is) so a focused terminal declines them. |
| D22 | Remote Control start | `從 Remote Control 啟動` adds `--remote-control` (as `claude-rc` does); not remembered for a later RESUME (known issue). |
| D23 | 刪除對話紀錄… | Only for a CODD claude session that is not running and whose Claude session id no live registry entry uses. After the typed-name confirmation, `<claudeDir>/projects/<slug>/<id>.jsonl` (only when its lines carry the session's cwd) and its sibling `<id>/` folder are **moved to the macOS Trash** (recoverable), then the session leaves CODD. Alert copy says so. Tests and DEBUG runs inject a trash folder (`-codd-trash-dir`); nothing in automated runs touches `~/.Trash`. |
| D24 | Hook port of test roots | When the data root is not the default one (`-codd-data-root` / `CODD_DATA_ROOT`) and config.json does not exist yet, the app creates it with a port from **43000–43999** instead of 47821–47899, so test and throwaway instances never take the port the user's sessions post to. `scripts/m1-smoke.sh` writes its own config.json like `m1-e2e.sh`. |
| D25 | Tab running lamp | A shell tab (main strip and panel) shows the green `●` lamp (`執行中`, Split artboard `npm run dev`) while a foreground job runs in it: the app reads the shell child's `kinfo_proc` (`e_tpgid` ≠ its own pgid) at 1 Hz for open tabs only. No protocol change. |
| D26 | Error banner actions | `↻ 重送上一則` sends the session's last prompt (D20 sources) through the composer path (paste + submit); disabled when unknown. `⟲ 稍後自動重試` arms one resend after 60 s, shown as `⟲ 60s 後重試` counting down; a second click cancels; dropped when the session leaves ERROR. Nothing persisted. |
| D27 | External ids | Stable per process: `ext-<pid>-<startedAt ms>` (`ext-<pid>` without startedAt). A `/clear` inside the external claude changes its Claude session id but not its row. |
| D28 | Second instance | Besides activating the first instance, the second posts the distributed notification `app.fancycodd.CODD.showMainWindow` (object = the standardized data root path); the lock holder for that root shows its main window. |
| D29 | Sample account data | While the `AccountStore` is the mock in real mode, the Home USAGE header and the sidebar footer say so (`· 示意資料，M3 接上 cswap`). Mock mode shows the artboard unchanged. |
| D30 | Default model label | The model select's `預設` shows the `model` of `<claudeDir>/settings.json` when it has one (`預設 (opus)`), read-only; Settings › 啟動設定檔 meta uses the same. |
| D31 | Inserted paths | Paths the composer inserts (pasted images, dropped files) are escaped like a Terminal.app drop (`\` before space and shell metacharacters), the form Claude Code recognizes as an attachment. |

---

## 2. Components (parallel, outside App/; owned paths disjoint)

### C1 `core` — CoddCore: transcripts, fuzzy search, external sessions, launch profiles

Owned: `Packages/CoddCore/Sources/CoddCore/Transcripts/`, `Packages/CoddCore/Sources/CoddCore/Search/`,
`Packages/CoddCore/Sources/CoddCore/Registry/ExternalSessions.swift`,
`Packages/CoddCore/Sources/CoddCore/Launch/LaunchProfileStore.swift`,
`Packages/CoddCore/Sources/CoddCore/Launch/LaunchProfile.swift`, and the new test files
`Packages/CoddCore/Tests/CoddCoreTests/{TranscriptCatalogTests,FuzzyMatcherTests,ExternalSessionTests,LaunchProfileStoreTests}.swift`.
No Package.swift change (fixtures are written to temp dirs by the tests).

```swift
// Transcripts/TranscriptCatalog.swift
public struct TranscriptSummary: Sendable, Equatable, Identifiable {
    public enum TitleSource: String, Sendable { case custom, ai, firstPrompt, none }
    public var id: String              // Claude session id = file stem
    public var path: String            // absolute .jsonl path
    public var cwd: String?            // from the lines (never decoded from the folder name)
    public var title: String           // customTitle > aiTitle > first user prompt (≤ 80 chars) > "（沒有標題）"
    public var titleSource: TitleSource
    public var gitBranch: String?
    public var entrypoint: String?
    public var createdAt: Date?        // first line timestamp
    public var lastActivity: Date      // file mtime
    public var sizeBytes: Int64
}
/// Reads Claude's transcripts read-only. Thread-safe (Mutex-protected cache keyed by path + mtime + size).
public final class TranscriptCatalog: Sendable {
    public init(projectsDirectory: URL, headBytes: Int = 256 << 10, tailBytes: Int = 128 << 10)
    /// Newest first, at most `limit` (stat all, read only the newest `limit`), `sdk-*` dropped unless
    /// `includeSDK`; only files whose lines' cwd equals `cwd` (symlinks resolved on both sides). The
    /// folders of the typed, standardized and realpath'd cwd are all searched. Blocking: call off the main actor.
    public func list(cwd: String, limit: Int = 50, includeSDK: Bool = false) -> [TranscriptSummary]
    /// The latest `last-prompt` record's `lastPrompt`, else the last user message text (tail only).
    public func lastPrompt(cwd: String, sessionId: String) -> String?
    /// The files of one conversation for D23: `<id>.jsonl` (only when its lines carry `cwd`) and the
    /// sibling `<id>/` folder when present. Read-only; empty when not found.
    public func files(sessionId: String, cwd: String) -> [URL]
    /// Claude's folder name: every UTF-16 unit outside [A-Za-z0-9] → "-" (JS `replace(/[^a-zA-Z0-9]/g,'-')`);
    /// names over 200 chars: the folder is found by its 200-char prefix and verified by the lines' cwd.
    public static func folderName(for cwd: String) -> String
}
public enum TranscriptRetention {
    /// Days left before `cleanupPeriodDays` deletes the transcript, when ≤ `warnWithin` (else nil).
    public static func daysLeft(lastActivity: Date, now: Date, cleanupPeriodDays: Int = 30, warnWithin: Int = 5) -> Int?
    /// `cleanupPeriodDays` from Claude's settings.json (read only, tolerant; nil when absent/invalid).
    public static func cleanupPeriodDays(settingsFile: URL) -> Int?
}
// Transcripts/ClaudeUserSettings.swift
public struct ClaudeUserSettingsSummary: Sendable, Equatable { public var cleanupPeriodDays: Int?; public var model: String? }
public enum ClaudeUserSettings {
    /// Read-only, tolerant, ≤ 1 MiB: top-level `cleanupPeriodDays` (integer ≥ 1) and `model` (one token).
    public static func read(settingsFile: URL) -> ClaudeUserSettingsSummary
}

// Search/FuzzyMatcher.swift
public struct TextSpan: Sendable, Equatable { public var location: Int; public var length: Int } // UTF-16 units
public struct FuzzyMatch: Sendable, Equatable { public var score: Int; public var spans: [TextSpan] }
public enum FuzzyMatcher {
    /// Case- and width-insensitive. Ranking: whole prefix > substring at a word start (space / - _ . / · and
    /// CJK↔Latin boundaries) > substring elsewhere > subsequence (fewer gaps, longer runs better); shorter
    /// candidates win ties. nil when the query's characters do not all occur in order. Empty query → score 0.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch?
}

// Registry/ExternalSessions.swift
public struct OwnedClaudeProcesses: Sendable, Equatable {
    public var claudePids: Set<Int>          // children of this CODD's claude-session holders
    public var claudeSessionIds: Set<String> // current + initial Claude session ids of CODD sessions
    public var claudeHolderPids: Set<Int>    // holders running claude sessions
    public var shellHolderPids: Set<Int>     // holders of shell sessions and shell tabs
}
public struct ExternalSession: Sendable, Equatable, Identifiable {
    public var id: String                // D27: "ext-<pid>-<startedAt ms>" or "ext-<pid>"
    public var pid: Int
    public var claudeSessionId: String?
    public var cwd: String
    public var name: String?
    public var kind: String?             // registry `kind` (interactive, daemon-worker, …)
    public var entrypoint: String?
    public var version: String?
    public var state: SessionState       // .busy / .idle / .waiting(reason) / .unknown (no status)
    public var stateSince: Date?         // statusUpdatedAt
    public var startedAt: Date?
    public var remoteControl: Bool
    public var hostHolderPid: Int?       // first ancestor that is one of `shellHolderPids`
}
public struct ExternalSessionFilter: Sendable, Equatable { public var hideSDK = true; public var hideDesktop = true; public init() }
public enum ExternalSessionDetector {
    /// Pure apart from `ancestors` (default: sysctl KERN_PROC_PID parent chain, ≤ 8 levels).
    public static func detect(_ entries: [ClaudeRegistryEntry], owned: OwnedClaudeProcesses,
                              filter: ExternalSessionFilter = .init(),
                              ancestors: (Int) -> [Int] = ProcessAncestry.chain) -> [ExternalSession]
}

// Launch/LaunchProfileStore.swift
public struct LaunchProfileDocument: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public var profiles: [LaunchProfile]
    public var defaultProfileId: String
    public static var seeded: LaunchProfileDocument   // built-ins, default "claude-default"
}
public struct LaunchProfileStore: Sendable {
    public init(fileURL: URL)
    /// Missing file → `.seeded` (not written until `save`). Tolerant (bad entries skipped); newer version → throws.
    public func load() throws(LaunchProfileStoreError) -> LaunchProfileDocument
    public func save(_ document: LaunchProfileDocument) throws(LaunchProfileStoreError)   // atomic, 0600
}
public enum LaunchProfileIssue: Sendable, Equatable { case emptyName, duplicateName, reservedArgument(String),
    invalidModel(String), invalidPermissionMode(String), blockedEnvironment(String), invalidEnvironmentLine(String),
    unbalancedQuotes, lastClaudeProfile }
public enum LaunchProfileEditing {
    public static func validate(_ profile: LaunchProfile, in document: LaunchProfileDocument) -> [LaunchProfileIssue]
    public static func parseArguments(_ text: String) -> Result<[String], LaunchProfileIssue>   // quotes, backslash
    public static func parseEnvironment(_ text: String) -> Result<[String: String], LaunchProfileIssue> // KEY=VALUE lines
    public static func formatArguments(_ args: [String]) -> String
    /// The ⌘N strip / Settings preview: `claude --session-id 7c1e9a04-… --model … --permission-mode … -n "…" <extra>`
    /// or `claude --resume 3f2a91c0-… …`; ids abbreviated unless `abbreviated` is false (copy button). No `--settings`.
    public static func commandPreview(_ profile: LaunchProfile, sessionId: String?, model: String?, permissionMode: PermissionMode?,
                                      name: String?, resumeId: String?, remoteControl: Bool, abbreviated: Bool = true) -> String
    /// The profile's own command for the Settings rows: `claude`, `claude --permission-mode plan`, `claude --remote-control`, `zsh`.
    public static func profileCommand(_ profile: LaunchProfile) -> String
    public static func remove(_ id: String, from document: inout LaunchProfileDocument) -> LaunchProfileIssue?
}
```
`LaunchProfile.builtIn` keeps its ids; display names become `claude-default`, `claude-plan`, `claude-rc`,
`zsh` (the artboard's names). Environment checks reuse `SpawnEnvironmentBuilder`'s blocked-name rules;
argument checks reuse `LaunchBuilder.reservedFlags`.

### C2 `holder` — CoddHolder: ring file reader, `input.paste`

Owned: `Packages/CoddHolder/Sources/**`, `Packages/CoddHolder/Tests/**` (new files + edits),
and the `### codd-holder` and `### Holder wire protocol v1` sections of `docs/ARCHITECTURE.md`.

```swift
// CoddProtocol: InputFlags.paste = bit1; HolderCapability.inputPaste = "input.paste" (always in WELCOME caps)
// CoddHolderClient/HolderStream.swift
public func sendInput(_ bytes: [UInt8], submit: Bool = false, paste: Bool = false) throws(HolderStreamError)
public var supportsPaste: Bool { get }    // WELCOME caps contains "input.paste"
// Without the cap, `paste` brackets on the client when the newest known modes (WELCOME `modes` or
// ATTACHED current modes) have ?2004, with the same marker stripping; submit then is the holder's 10 ms.

// CoddHolderClient/RingFileReader.swift
public struct RingSnapshot: Sendable, Equatable {
    public var start: UInt64, end: UInt64     // stream offsets; bytes = [start, end)
    public var bytes: [UInt8]
    public var modes: TerminalModes?          // modes at `start`; nil = fell back to the oldest byte (unknown)
    public var spawnOffset: UInt64
    public var childExited: Bool, signaled: Bool, exitStatus: Int32?, holderExitedCleanly: Bool
    public var columns: Int, rows: Int
}
public enum RingFileError: Error, Sendable, Equatable { case missing, notARing(String), io(String) }
public enum RingFileReader {
    /// Blocking; never locks or writes the file. Start = the point a live holder's WELCOME `resync` would
    /// choose for this ring (share the selection code with the holder); at most `limit` bytes (newest).
    /// Safe against a concurrently writing holder (ARCHITECTURE "Ring" reader rule).
    public static func read(path: String, limit: Int = 8 << 20) throws(RingFileError) -> RingSnapshot
}
```
Holder: INPUT with `paste` → bracket iff the child's current modes (active screen) have ?2004, strip
`ESC[200~` / `ESC[201~` from the payload; `submit` + `paste` → `\r` 50 ms after the last byte reached the
PTY. One frame = one paste. `codd-holderctl send --paste` and `codd-holderctl ring <dir>` (prints a snapshot
summary and, with `--raw`, the bytes) for scripts.

### C3 `composer` — new package `Packages/CoddComposer`

Owned: `Packages/CoddComposer/**`. swift-tools 6.2, macOS 26, Swift 6 strict concurrency, no
dependencies. Products: library `CoddComposer`, executable `codd-composer-demo` (manual 注音 check).

```swift
public struct ComposerStyle: Sendable {   // the app passes Phosphor tokens; the package has no theme
    public var font: NSFont; public var textColor, placeholderColor, caretColor, markedTextColor, background: NSColor
    public var insets: NSEdgeInsets; public var minLines = 1; public var maxLines = 8
}
public enum ComposerHistoryDirection: Sendable { case previous, next }
@MainActor public final class ComposerTextView: NSTextView {
    public var onSubmit: ((String) -> Void)?          // Enter, never while marked text exists
    public var onEscape: (() -> Void)?                // esc, never while marked text exists
    public var onHistory: ((ComposerHistoryDirection) -> String?)?  // ↑ on first line / ↓ on last line
    public var onPasteImage: ((Data) -> String?)?     // PNG data in, text to insert out (an escaped path)
    public var onTextChange: ((String) -> Void)?
    public var placeholder: String
    public func apply(_ style: ComposerStyle)
}
@MainActor public final class ComposerField: NSView {     // scroll view + text view, grows 1…maxLines
    public let textView: ComposerTextView
    public var text: String { get set }
    public var onHeightChange: ((CGFloat) -> Void)?
    public func focus()
}
public struct ComposerHistory: Sendable, Equatable, Codable {
    public static let limit = 100
    public private(set) var entries: [String]          // oldest first
    public mutating func record(_ text: String)        // collapses consecutive duplicates, trims to limit
    public mutating func previous(current: String) -> String?   // stashes `current` on the first step
    public mutating func next() -> String?              // past the newest returns the stash
    public mutating func resetCursor()
}
public struct ComposerState: Sendable, Equatable, Codable { public var draft: String; public var history: ComposerHistory; public static let empty: ComposerState }
public enum ComposerStateFile {
    public static let name = "composer.json"
    public static func load(directory: String) -> ComposerState                 // blocking; missing/corrupt → .empty
    public static func save(_ state: ComposerState, directory: String) throws   // atomic 0600; no-op when the dir is gone
}
public struct ComposerPayload: Sendable, Equatable { public var bytes: [UInt8]; public var paste: Bool; public var submit: Bool }
public enum ComposerEncodingError: Error, Sendable, Equatable { case empty, tooLong(Int) }
public enum ComposerEncoding {
    public static let maxBytes = 256 << 10
    public static func payload(for text: String, submit: Bool = true) throws(ComposerEncodingError) -> ComposerPayload
}
public enum ComposerPaths {
    /// D31: Terminal.app drop style (`\` before space, quotes and shell metacharacters).
    public static func escaped(_ path: String) -> String
}
```
Key handling is IME-safe: everything goes through `interpretKeyEvents` / `doCommand(by:)`, so the input
method consumes keys while composing. `insertNewline:` with Shift or Option held (read from
`NSApp.currentEvent`) inserts a newline; without, it submits. Plain text paste only (no rich text, no
graphics); an image-only pasteboard (PNG / TIFF → PNG) goes to `onPasteImage`.

### C4 `fixtures` — scripts for the M2 end-to-end run

Owned: `scripts/m2-fixtures/**` and one change in `scripts/m1-smoke.sh` (its own config.json, D24).
Bash + `python3 -I` only; no network, nothing under `~`.
- `make-root.sh <root>`: creates a data root (0700) with its own `config.json` (random free port in
  43000–43999, fresh 32-byte hex token, 0600). Every manual CODD launch of every agent starts from it.
- `fake-claude-m2.sh`: CODD-compatible fake claude (same contract as `scripts/fake-claude.sh`: DA1 probe,
  SessionStart through the codd-hook in `--settings`), prints `FAKE-ARGV <args…>` and
  `FAKE-ENV <NAME>=<value>` for the names listed in `FAKE_PRINT_ENV`, enables `ESC[?2004h`, then reads raw
  input and prints `FAKE-PASTE <text, \r shown as ⏎>` for a bracketed paste, `FAKE-LINE <text>` for typed
  text ended by `\r`, `FAKE-SUBMIT` after each `\r`; posts `UserPromptSubmit` (with `prompt`) then `Stop`
  for each submit; `FAKE-EXIT` exits 3. With `FAKE_REGISTRY_DIR` set it also keeps a registry file
  `<dir>/<its pid>.json` like a real claude (busy / idle, removed on exit), so the e2e can prove CODD's own
  claude is never listed as external.
- `fake-external-claude.sh start|host|set-status|stop`: a long-lived dummy process whose argv contains the
  given marker path, plus `<claudeDir>/sessions/<pid>.json` (pid, sessionId, cwd, startedAt ms, procStart =
  `TZ=UTC ps -o lstart= -p <pid>`, version, kind `interactive`, entrypoint `cli`, name, status, waitingFor,
  statusUpdatedAt / updatedAt ms), rewritten atomically by `set-status`; `stop` removes the file and the
  process. `host` starts the dummy as its own child, registers it and then `exec cat` (used as a CODD
  shell's argv: the dummy's ancestor is that shell's holder).
- `make-transcripts.sh <claudeDir> <cwd>`: transcripts in `<claudeDir>/projects/<slug>/` (custom-title 2 d,
  ai-title 5 d, first prompt + `gitBranch` 12 d, one 26 d old, one `sdk-cli`, one with another `cwd` in the
  same folder), mtimes set, sibling `<id>/subagents/` folder for one of them, and `manifest-<slug>.json`
  with the expected ids, titles, branches, order and expiry.
- `seed-layout.sh <dataRoot> <workDir>`: folders + a `layout.json` in CoddCore's format (version 1, ISO
  dates) with 2 colored groups, 4 projects (one in 未分類), claude and shell session records, a pinned and an
  archived session, a collapsed project; `manifest-layout.json`.
- `selftest.sh` and `README.md`.

---

## 3. App contracts (shared by the integration steps)

View model and store additions (I1 / I2 add them; mock store gets the defaults):
```swift
final class SessionVM {            // App/Model/SessionModels.swift
    var unreachableSince: Date?    // D8 (I1)
    var lastPrompt: String?        // D20 (≤ 200 chars, cleaned) (I2)
    var externalInfo: ExternalInfo?   // non-nil ⇔ external (`external` stays the Bool the cells read) (I2)
}
struct ExternalInfo: Equatable, Sendable { var pid: Int32; var kind: String?; var entrypoint: String?; var claudeSessionID: String?
                                           var version: String?; var hostSessionID: SessionID?; var hostTabID: String? }
final class ProjectVM { var isTransient = false }        // only for externals; never saved (I2)
struct StoreProblem: Equatable, Sendable { var message: String; var at: Date; var sessionID: SessionID? }   // (I1)

protocol SessionStore {            // new requirements, defaults in an extension (mock: no-ops)
    var problem: StoreProblem? { get }                    // I1
    func dismissProblem()                                 // I1
    func retryConnection(_ id: SessionID)                 // I1
    func unarchive(_ ids: [SessionID])                    // I2
    func archivedSessions(inProject id: ProjectID) -> [SessionVM]   // I2
}
protocol AccountStore { var isPlaceholder: Bool { get } } // D29, default false; MockAccountStore true (I4)
```
Launch (I2): `ClaudeLaunchOptions` gains `remoteControl: Bool`; `NewSessionRequest` gains
`sessionID: UUID?` (the id the ⌘N preview showed; createSession uses it when free); `HolderSessionStore.createSession`
honours `options.mode == .resume(id)` from the request (record `claudeSessionId = id`, title from the transcript when
no name; `.restart` is refused from a request). `@MainActor @Observable final class LaunchProfiles` (App/Real)
wraps `LaunchProfileStore` (off-main I/O) and pushes its profiles into `HolderLauncher.profiles`. `AppServices`
gains `profiles`, `transcripts(for cwd:) async -> [TranscriptSummary]` (cached 10 s), `claudeSettings`
(`ClaudeUserSettingsSummary`, read once) and `lastPrompt(for:) async`.

Transient projects (I2): live in `projectsByID` with `isTransient = true`; `promoteTransient(_:)` runs before any
CODD session is created in, adopted into or added as that folder (`createSession`, `adopt`, `addProject(path:)`),
so a CODD session never lands in a project that is not saved. `LayoutMapping.layout` skips transient projects
and session ids without records; `knownProjectChoices()` excludes them.

Terminal: `PtyEvent.unreachable(Bool)`, `PtyConnection.retryNow()` (I1); `PtyConnection.send(_:submit:paste:)`
(held input keeps the flag) and `TerminalInput.payload(bytes: [UInt8], submit: Bool, paste: Bool)` (I4,
filled from `ComposerEncoding.payload`).

Externals live in their own table (`externalByID`): `session(_:)` and `allSessions` include them, every
code path that persists, registers with the hook engine, spawns, archives, answers or moves iterates
`sessionsByID` only. Externals sit after the CODD sessions in `project.sessionIDs`; `DropPlanner` clamps a
session drop to the CODD rows; the archive toast counts only what was archived.

Panes (`ShellState` / `PaneLayout`): I4 adds `composerOpen`; I5 adds `panelTabs: [ShellTab]`,
`panelSelected: String?`, `panelMaximized: Bool` (the old `panel` becomes the selected panel tab), plus
non-persisted `tabTitles: [String: String]`, `bells: Set<BellKey>` and `runningTabs: Set<String>` (D25).

New data-root files: `codd.lock` (I1), `profiles.json` (I2), `sessions/<id>/composer.json` and
`sessions/<id>/attachments/` (I4).

UI copy (verbatim, 繁體中文 + English caps labels):
- EXT: banner `EXT` + `外部啟動的 session，唯讀狀態偵測` + `· 偵測自 <claudeDir>/sessions`; pane
  `// 這個 session 在 CODD 外面執行（pid 48211 · cli）· CODD 只讀取狀態，不能在這裡輸入` plus, when the
  transcript has one, `最近 prompt：<text>`; inside a CODD shell: `// 這個 session 在 CODD 的 shell「<title>」裡執行`
  + `[前往 shell]`; row line 2 `外部啟動` / `在 CODD shell 中`; transient project menu `加入為專案`, `複製路徑`.
- UNREACHABLE: pill `Unreach`, line 2 `holder 無回應 · 30s`, chip `◌ UNREACHABLE · 30s`, banner
  `▲ holder 沒有回應 · 每 10 秒重試一次，畫面與狀態可能不是最新的` `[↻ 立即重試]`.
- Problem banner: `▲ <message> · 12s 前` `[知道了]`.
- Replay footer (dim): `// holder 已結束 · 以上是最後的畫面（唯讀）`.
- Second instance alert: `另一個 CODD 正在使用這個資料夾` / `<path>（pid 1234）。請切換到那個 CODD，或用 -codd-data-root 指定別的資料夾。` / `結束`.
- Error banner (D26): `↻ 重送上一則` (disabled hint `沒有可重送的 prompt`), `⟲ 稍後自動重試` → `⟲ 60s 後重試`.
- 刪除對話紀錄 (D23): alert `刪除「<title>」的對話紀錄？` / `對話紀錄會移到垃圾桶（可從垃圾桶還原），之後無法在 CODD 接續。請輸入 session 名稱確認。` / `移到垃圾桶` / `取消`; done toast `✕ 對話紀錄已移到垃圾桶`.
- Composer: placeholder `給 Claude 的訊息（⌘L）` (shell tab: `輸入要送到 shell 的文字（⌘L）`), hint
  `Enter 送出 · ⇧Enter 換行 · 貼上圖片會存成檔案路徑`, busy `Claude 工作中 · 送出後排入佇列`, kbd `⌘L`,
  button `Send`, disabled hint `session 沒有在執行`; strip `100×22 · ⌘L composer · ⌘J 終端機`.
- Panel: tabs `$ zsh 1` / OSC title, `●` running lamp (aria `執行中`), `+` (`新增終端機`), cwd, maximize
  (`最大化下方終端機` / `還原下方終端機`), `✕ ⌘J` (`關閉下方終端機 ⌘J`).
- Quick switch: `>` field (`搜尋 session、專案與動作`), `6 筆`, `esc`; heads `Sessions n` `Projects n`
  `Actions n`; unknown project `未加入 · 來自 ~/.claude.json` + `+ 加入`; actions `在 <project> 新增 session`
  `⌘N`, `在 <project> 開啟終端機` `$ zsh`, `新增 session…`, `新增 Shell session…`, `加入專案資料夾…`,
  `新增群組`, `隱藏 / 顯示側欄` `⌘\`, `下方終端機` `⌘J`, `Composer` `⌘L`, `新增 shell 分頁` `⌘T`, `STATUS`,
  `設定…` `⌘,`; footer `↑↓ 選擇 · ⏎ 開啟 · ⌘⏎ 在下方終端機開啟 · esc 關閉`; empty `// 沒有符合的結果`.
- Hover card state lines: `◆ 權限確認 · 3m`, `◆ 等你回答 · 12m`, `◆ 計畫待核准 · 2m`, `▲ 失敗 · OVERLOADED · 1m`,
  `◇ 完成待看 · 4m`, `● 工作中 · Edit · 6m`, `◌ 壓縮中 · 20s`, `○ 閒置 · 2h`, `◌ 啟動中 · 4s`,
  `● 執行中 · 沒有 hook`, `$ shell · zsh`, `✕ 已結束 · code 0`, `⟲ 已停止 · 可接續`, `◌ holder 無回應 · 30s`;
  `最近 prompt：`; meta `opus-5.5 · tool Bash · ctx 58% · up 42m · ⌘1` (missing parts omitted); hint
  `拖曳或 ⌥⇧↑↓ 調整順序`; external: path + `外部啟動 · pid n` (or `在 CODD shell 中 · pid n`).
- Sidebar: group hover `清理已停止 (5)`, `+` (`在 <group> 新增 session`), `⋯` (`<group> 群組選項`); group
  menu adds `清理已停止`; new-group row: color button (`群組顏色：cyan`), popover `Color · 群組顏色` with
  numbered swatches and `1–8 快速選色`, input `群組名稱`, `⏎`; STATE heads `● Working 4`, `○ Idle 4 · 1 stale`;
  project menu `封存 n ▸` → `還原「<title>」`, `全部還原`; toast `✕ 3 個 session 已封存 [Undo] 5s`.
- New Session (artboard text): `New session · 新增 session` `⌘N` `✕`; `專案 Project` + `輸入名稱或路徑篩選`;
  dropdown `最近 Recent n` (rows `n live`, ✓), `建議 · 來自 ~/.claude.json` `未加入` (`+ 加入`),
  `+ 選擇資料夾…` `⌘O`; `類型 Kind` `◆ Claude` `$ Shell` + `SHELL 只在專案目錄開 zsh`; `開始方式 Start`:
  `新對話` (`自動帶 --session-id`), `接續先前對話` (`claude --resume`), `從 Remote Control 啟動`
  (`--remote-control`); picker `Past transcripts` `<project> · n`, rows `❯ <title> <size>` /
  `⎇ <branch> · 2d` / `! resume 4 天後過期` / `執行中`, `// 讀取中…`, empty `// 這個資料夾沒有先前的對話紀錄`;
  `帳號 Account` disabled `跟隨全域登入` + `改選固定帳號會以 cswap run 建立獨立設定目錄，對話紀錄分開存放`;
  `模型 Model` `預設` (D30: `預設 (<model>)`) / `opus` / `sonnet` / `haiku` / `其他…`; `權限 Permission`
  default / acceptEdits / plan / auto with hints `依 Claude 自己的設定（permissions.defaultMode）`,
  `acceptEdits：檔案編輯自動接受，Bash 指令仍會詢問`, `plan：只規劃、不改檔，核准計畫後才動手`,
  `auto：由 Claude 判斷哪些操作需要詢問`; `名稱 Name` + `側欄顯示，並以 -n 傳給 claude`; `顏色 Color` +
  `1–8 快速選色`; `▸ 進階 Advanced` + `launch profile <id> · env n 個 · --remote-control 關`; command strip
  `$ claude --session-id 7c1e9a04-… --model opus-5.5 --permission-mode acceptEdits -n "修正登入 API 401"` + copy
  (`複製指令`, copies the full ids); footer `建立後放在 ■ <group> / <project>` (or `建立後放在 未分類 / <folder>`),
  `取消`, `建立 ⌘⏎`.
- Settings › 啟動設定檔: `PROFILES` `啟動設定檔`, lead `⌘N 新增 session 時可選的啟動方式。CODD 會自動補上
  --session-id 與 -n 名稱。`, `+ New profile`, `Launch profiles n`, rows (glyph, name, kind chip,
  `Default`, `code` = `profileCommand`, `cwd 跟隨專案 · 帳號 跟隨全域 · 模型 預設`), `複製` `編輯` `刪除`;
  `Preview 實際啟動指令` `<default profile> + ⌘N 對話框的選項`.
- Home: per the artboard (`// 沒有選取 session`, `SESSIONS`, live date, meta rule, `◆ Needs you`, cards with
  `[1 允許]` `[前往 ⌘n]`, DONE line `… 4m 前完成 Done`, `Launch 最近專案` + `Profile · <id> ▾` +
  `其他專案… ⌘N`, project cards `+ Claude` `+ Shell` `啟動 10:04`, `Recently stopped 可接續` +
  `全部對話紀錄 →`, `Usage 剩餘` + `↓ 依每週重置排序 · 越快重置越上面` (+ D29 note), `自動切換 OFF · 剩餘 ≤ 2% 時切換 · 設定 →`).

---

## 4. Integration steps (sequential; each edits App/ and project.yml; one agent at a time)

- **I1 — robustness and lifecycle.** Test-root hook port (D24); single-instance lock + show-window request
  (D9, D28); problem banner replacing `lastError`; UNREACHABLE (D8); dead-session ring replay incl. ended
  connections (D7); lifecycle check + occlusion while closed (D10); `-codd-select-session`; ARCHITECTURE.md
  (coddd deferred, process model, codd.lock, app section).
- **I2 — sessions data.** External sessions (registry fan-out from `HookPipeline`, detector, transient projects
  + promotion, read-only pane, menu subsets, no `[1 允許]` for externals, D6, D27); stale flag (D15); launch
  profiles service + resume / profile / remote-control / pre-chosen id launch plumbing, shell profile use (D5);
  transcript service + Claude settings summary + `lastPrompt`; `unarchive` API; 刪除對話紀錄 to Trash (D23).
- **I3 — sidebar.** Sidebar gaps of §0 (hover actions, inline new group, STATE view, hover card, toast
  countdown, drop line, archive restore, filter over all sections, external rows), ⌘P / ⌘. menu items +
  terminal declines, `sidebar` state dump.
- **I4 — home, quick switch, composer.** Home per artboard (D17, D29); ⌘K palette (FuzzyMatcher, D14); composer
  bar (CoddComposer) with drafts, history, image paste, send through `input.paste`, ⌘L; error-banner actions (D26).
- **I5 — bottom panel.** Panel tabs / maximize / bells / OSC titles / running lamp (D11–D13, D25), main strip
  bells, titles and lamps.
- **I6 — new session and profiles UI.** The ⌘N sheet per artboard with the resume picker (D16, D18, D22, D30);
  Settings › 啟動設定檔 (list, editor, preview).
- **I7 — end to end, report.** `scripts/m2-e2e.sh`, full test pass, numbers, `docs/M2-REPORT.md`
  (繁體中文 manual checklist), final ARCHITECTURE.md pass.

Every step: Debug and Release build with zero warnings in touched code, app tests green, package tests green,
`scripts/m1-e2e.sh` and `scripts/m1-smoke.sh` still green (`CODD_APP=<own build>`), `-CODDSelfTest YES` OK.

---

## 5. DEBUG flags and state dump (RealModeOptions, DEBUG only)

| Step | Flags |
|---|---|
| I1 | `-codd-unreachable-after <s>`, `-codd-keepalive <idleMs>,<timeoutMs>` (HolderStreamOptions), `-codd-close-main-window YES`, `-codd-select-session <id>` (show it after launch) |
| I2 | `-codd-new-profile <id>` (with `-codd-new-claude`), `-codd-resume-transcript <claude session id>` (with `-codd-new-claude`), `-codd-stale-after <s>`, `-codd-trash-dir <dir>` (D23 moves go there instead of the Trash), `-codd-delete-history <session id>` (runs D23 without the alert) |
| I3 | `-codd-sidebar-mode tree\|state`, `-codd-sidebar-filter "<text>"` |
| I4 | `-codd-palette-query "<q>"` (opens ⌘K with the query), `-codd-composer-send "<text>"` (`\n` / `\t` decoded; sent once the shown terminal streams), `-codd-composer-open YES` |
| I5 | `-codd-panel-tabs <n>` (with `-codd-open-panel`), `-codd-maximize-panel YES` |
| I6 | `-codd-new-session-path <cwd>`, `-codd-new-session-start new\|resume\|rc` (with `-codd-show new-session`), `-codd-open-project-dropdown YES`, `-codd-show settings-profiles` (with `-codd-snapshot`: `<name>-settings.png`) |

`-codd-dump-state` additions (existing keys unchanged): I1 per session `unreachable`, `replayed`; top level
`problem`, `windowVisible`, `instance {pid, lock}`. I2 per session `external`, `externalPid`, `hostSession`,
`hostTab`, `stale`, `lastPrompt`, `tag`, `pinned`; top level `projects [{id,name,cwd,group,transient,collapsed,
archivedCount,sessions}]`, `groupsInfo [{id,name,color,collapsed}]`, `pinned [ids]`, `archived [ids]`,
`profiles [{id,name,kind}]`, `defaultProfile`, `cleanupPeriodDays`, `claudeModel`. I3 `sidebar {mode, filter,
rows [{kind, id, section, title, line2, stale, depth}]}`. I4 `palette {query, rows [{section,title,detail}]}`,
per session `composer {open, draftLength, historyCount}`, `home {needsYou [ids], done, launch [cwd], stopped
[{kind,id,title}]}` (while Home is shown). I5 `pane {session, tabs [{id,label,bell,running}], panelTabs
[{id,label,bell,running}], panelSelected, panelOpen, panelMaximized, composerOpen}`. I6 `resumePicker
[{id,title,branch,sizeBytes,ageDays,expiresInDays,disabled}]` and `newSession {path,kind,start,profile,command}`
while the sheet is open.

---

## 6. Acceptance

Automated:
- `swift test` green for CoddCore, CoddHolder, CoddHooks, CoddTerminal, CoddComposer; app tests green;
  Debug + Release build, zero warnings in code touched in M2.
- `scripts/m2-fixtures/selftest.sh` passes (also `--with-app`).
- `scripts/m2-e2e.sh` (I7) passes, covering: seeded layout reproduced (groups, colors, pins, archive,
  collapse); external session appears under its project with live state (busy → waiting → gone) and is
  counted in attention, the transient project is never saved; CODD's own fake claude with a registry file is
  never external; a claude started inside a CODD shell shows its host shell; a second instance on the same
  root exits, the first shows its window and nothing else changed; custom profile flags and env reach the
  fake claude; resume from a transcript starts `--resume <id>`; the resume picker lists the fixture
  transcripts in order with the expiry warning and without the sdk / other-cwd ones, the in-use one disabled;
  composer single line and multi-line CJK arrive as `FAKE-LINE` / `FAKE-PASTE` + `FAKE-SUBMIT`, history
  persisted, `lastPrompt` learned; ⌘K query results; STATE view sections, stale and filter in the `sidebar`
  dump; two panel tabs + maximize persisted and reattached after relaunch; a dead shell's last output
  replayed read-only after relaunch; SIGSTOP'd holder → UNREACHABLE, SIGCONT → cleared and not STOPPED;
  closing the main window keeps CODD running; holders survive quit; 刪除對話紀錄 moves exactly the
  session's files into the injected trash folder; a fresh temp root's endpoint uses a port in 43000–43999.
- `scripts/m1-e2e.sh` and `scripts/m1-smoke.sh` still pass; `-CODDSelfTest YES` → `SELFTEST OK`.

Manual (for the user, real claude): see the 繁體中文 checklist in docs/M2-REPORT.md — 注音 in the composer
(compose, candidate window, Enter commits without sending), multi-line prompt + paste into a real claude,
image paste path accepted by claude, an external `claude` in Terminal.app showing up as EXT with live state,
the resume picker against real `~/.claude/projects`, 刪除對話紀錄 landing in the Trash, sidebar drag / menus /
hover card / inline group, ⌘K, panel tabs, maximize and the running lamp, profiles, the error-banner actions.

---

## 7. Risks

- **Claude Code and bracketed paste + submit.** If Claude's input handling swallows a `\r` that follows a
  paste too closely, the 50 ms paste-submit delay needs tuning; only a real claude shows it (manual check).
- **Transcript volume.** `~/.claude/projects` can hold gigabytes; the catalog reads only head/tail of the
  newest files and caches by mtime/size; a giant first prompt beyond the head falls back to `（沒有標題）`.
  Home reads at most 3 transcripts for each of its 6 most recent projects.
- **External detection races.** A new CODD session's claude may be seen in the registry before WELCOME
  delivers its pid; the session-id and parent-is-our-holder rules cover it. cswap-run sessions and profiles
  with another `CLAUDE_CONFIG_DIR` are not seen (their registry and transcripts live elsewhere; M3 adds those
  directories).
- **AppKit polish limits.** NSOutlineView's drop feedback and hover tracking need custom drawing; the hover
  card must never steal focus or block drags.
- **Key equivalents in panels.** ⌘⏎ is the main menu's 允許; the palette panel, the ⌘N sheet and its
  dropdown must claim ⌘⏎ / esc themselves before the main menu sees them.
- **New Session sheet size.** The largest UI piece of the milestone; the combobox dropdown is a child
  window that must close with the sheet and never trap ⌘⏎ / esc.
- **Old holders.** Sessions started by M1 holders lack `input.paste`; the client fallback brackets by the
  last known modes, which can be stale.
- **Parallel builds.** Components build the app while other components edit packages: a failure inside a
  package another agent owns is retried later, never fixed by the wrong agent (§8).
- **Carried from M1 (not addressed):** GPU memory while animating (F2), churn footprint (E2E-3), hot-tier LRU (F5).

---

## 8. Rules for every agent (in addition to CLAUDE.md)

- Launch CODD only on a root made by `scripts/m2-fixtures/make-root.sh <fresh mktemp dir>` (own hook port)
  with `-codd-data-root <root> -codd-claude-dir <temp dir> -codd-login-env NO -codd-notifications NO`, or
  `-codd-mock`. Before C4 has delivered make-root.sh, write `<root>/config.json` the way `scripts/m1-e2e.sh`
  does. Fake claude only (`-codd-claude-path scripts/m2-fixtures/fake-claude-m2.sh` or `scripts/fake-claude.sh`).
- Tests construct stores and pipelines with a temp `ClaudeDirectory` (never `.standard`, whose registry watcher
  would read the user's live `~/.claude/sessions`), a temp data root, and an injected trash folder.
- Components never change project.yml; they run `xcodegen generate` only when `CODD.xcodeproj` is missing, and
  then as `lockf build/.xcodegen.lock xcodegen generate`. Seed a new derived-data folder once with
  `mkdir -p build/<label> && cp -c -R build/dd/SourcePackages build/<label>/` (APFS clone) to avoid
  downloading libghostty again.
- When an app or package build fails inside code another agent owns, wait and retry (3 times, 3 min apart);
  if it still fails, report it under knownIssues. Never edit paths you do not own.
- Clean up with `pkill -CONT/-TERM/-KILL -f "<your temp root>/"` only; never kill other processes.
