import AppKit
import CoddUI

// The STATUS page is drawn from these plain values only (no CoddCore / App types): the app maps
// its stores into a `StatusPageModel` every refresh (I2) and calls `apply(_:)` on both views,
// which redraw only the parts whose values changed. Every relative time (`3m`, `2h57m後`,
// `12s 前`) is kept as an absolute date (`StatusClock`) so the views can tick it at 1 Hz without
// a new model.

// MARK: - Time

/// A relative time the views re-render once a second from an absolute date.
public enum StatusClock: Sendable, Equatable {
    /// Time left until a date: `2h57m後`, `1d12h後`, `已重置` once it passed (quota resets).
    case countdown(Date)
    /// Time since a date: `12s 前`, `3m 前` (source ages, last data received).
    case ago(Date)
    /// Time spent in a state: `3m`, `1m12s` (NEEDS YOU rows).
    case elapsed(Date)

    public func text(now: Date) -> String {
        switch self {
        case .countdown(let date): DurationFormat.countdown(to: date, now: now)
        case .ago(let date): DurationFormat.ago(date, now: now)
        case .elapsed(let date): DurationFormat.compact(now.timeIntervalSince(date))
        }
    }
}

/// Text with an optional ticking part, drawn as `prefix + clock(now) + suffix`
/// (`statusline · 12s 前` = prefix `statusline · ` + `.ago(capturedAt)`).
public struct StatusText: Sendable, Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var prefix: String
    public var clock: StatusClock?
    public var suffix: String

    public init(_ prefix: String = "", clock: StatusClock? = nil, suffix: String = "") {
        self.prefix = prefix
        self.clock = clock
        self.suffix = suffix
    }

    public init(stringLiteral value: String) { self.init(value) }

    public static func countdown(_ date: Date) -> StatusText { StatusText(clock: .countdown(date)) }
    public static func ago(_ date: Date, prefix: String = "") -> StatusText { StatusText(prefix, clock: .ago(date)) }
    public static func elapsed(_ date: Date) -> StatusText { StatusText(clock: .elapsed(date)) }

    /// True when the text changes with time (the views subscribe to the 1 Hz ticker only then).
    public var ticks: Bool { clock != nil }

    public func text(now: Date) -> String { prefix + (clock?.text(now: now) ?? "") + suffix }

    /// The text without its ticking part (diagnostics, `String(describing:)`).
    public var description: String { clock == nil ? prefix + suffix : prefix + "…" + suffix }
}

// MARK: - Shared atoms

/// A state glyph and its color (`●` success, `▲` danger, `◆` amber, …), always drawn together
/// (SPEC §3: glyph + color double encoded).
public struct StatusGlyph: Sendable, Equatable {
    public var text: String
    public var color: NSColor

    public init(_ text: String, _ color: NSColor) {
        self.text = text
        self.color = color
    }

    public static var ok: StatusGlyph { StatusGlyph("●", Palette.success) }
    public static var bad: StatusGlyph { StatusGlyph("▲", Palette.danger) }
    public static var attention: StatusGlyph { StatusGlyph("◆", Palette.amber) }
    public static var remote: StatusGlyph { StatusGlyph("◉", Palette.cyan) }
    public static var off: StatusGlyph { StatusGlyph("○", Palette.dimmer) }
}

/// The page's sections, in page order; the sidebar nav and `scroll(to:)` use them.
public enum StatusSection: String, CaseIterable, Sendable {
    case host, accounts, hooks, mcp, remote

    /// Structural label (drawn uppercase): nav item and section header.
    public var title: String {
        switch self {
        case .host: "Host"
        case .accounts: "Accounts"
        case .hooks: "Hooks"
        case .mcp: "MCP"
        case .remote: "Remote"
        }
    }

    /// The nav item's 繁中 subtitle (artboard `.sx-ni small`).
    public var subtitle: String {
        switch self {
        case .host: "主機"
        case .accounts: "帳號 · cswap"
        case .hooks: "狀態回報"
        case .mcp: "本機 server"
        case .remote: "遠端連線"
        }
    }
}

/// One sidebar SECTIONS item: `● HOST 主機 … cpu 23%`.
public struct StatusNavItem: Sendable, Equatable {
    public var id: StatusSection
    public var glyph: StatusGlyph
    public var title: String
    public var subtitle: String
    /// Right-aligned summary (`cpu 23%`, `1w 15%`, `需更新`, `M4`, `1 rc`).
    public var value: String
    /// nil draws `--dim` (the artboard colors only bad / attention values).
    public var valueColor: NSColor?

    public init(id: StatusSection, glyph: StatusGlyph, value: String, valueColor: NSColor? = nil,
                title: String? = nil, subtitle: String? = nil) {
        self.id = id
        self.glyph = glyph
        self.title = title ?? id.title
        self.subtitle = subtitle ?? id.subtitle
        self.value = value
        self.valueColor = valueColor
    }
}

/// One NEEDS YOU mini row (`.srow.flat`): lamp · tag · title · pill, line 2 `3m · detail`.
public struct StatusSessionRow: Sendable, Equatable {
    /// Row look: waiting (amber wash, solid amber pill, pulsing lamp), error (red wash, outlined
    /// pill), other (plain, outlined pill in the glyph color).
    public enum Attention: Sendable, Equatable { case waiting, error, other }

    public var id: String
    public var glyph: StatusGlyph
    /// The session's color tag square (8 px); nil = none.
    public var tag: NSColor?
    public var title: String
    /// `Perm`, `Ask`, `Plan`, `Error` (drawn uppercase).
    public var pill: String
    /// Since when the session is in this state (line 2's ticking duration).
    public var since: Date
    /// Line 2 after the duration: `orb-toolkit-backend`, `overloaded · Gear3D`.
    public var detail: String
    public var attention: Attention

    public init(id: String, glyph: StatusGlyph, tag: NSColor? = nil, title: String, pill: String, since: Date,
                detail: String, attention: Attention = .waiting) {
        self.id = id
        self.glyph = glyph
        self.tag = tag
        self.title = title
        self.pill = pill
        self.since = since
        self.detail = detail
        self.attention = attention
    }
}

/// One SESSIONS count row: `◆ WAITING 2` (a zero count dims the row).
public struct StatusCount: Sendable, Equatable {
    public var glyph: StatusGlyph
    public var label: String
    public var count: Int

    public init(glyph: StatusGlyph, label: String, count: Int) {
        self.glyph = glyph
        self.label = label
        self.count = count
    }
}

// MARK: - HOST

/// A host card's `.meter` (CoddUI `MeterView` content and track height): one fill, MEM's 6 px
/// stacked meter (app / wired / compressed) or CLAUDE's split (CODD | external).
public struct StatusMeter: Sendable, Equatable {
    public var content: MeterView.Content
    /// Track height: 2 (`.meter`) or 6 (`.sx-stack`).
    public var height: CGFloat

    public init(content: MeterView.Content, height: CGFloat = 2) {
        self.content = content
        self.height = height
    }

    /// One fill, `--amber-dim` or a tone's color (`.meter.tone-ok`, `.tone-muted`).
    public static func single(_ fraction: Double, tone: Tone? = nil) -> StatusMeter {
        StatusMeter(content: .fraction(fraction, color: tone?.color ?? Palette.amberDim))
    }

    /// MEM: app, wired, compressed as fractions of the total, 6 px.
    public static func memory(app: Double, wired: Double, compressed: Double) -> StatusMeter {
        let colors = HostColors.legend
        return StatusMeter(content: .stacked([MeterView.Segment(fraction: app, color: colors[0]),
                                              MeterView.Segment(fraction: wired, color: colors[1]),
                                              MeterView.Segment(fraction: compressed, color: colors[2])]), height: 6)
    }

    /// CLAUDE: CODD processes then external ones.
    public static func split(_ main: Double, other: Double) -> StatusMeter {
        StatusMeter(content: .split(main: main, other: other))
    }
}

/// The MEM legend squares share the stacked meter's colors (`.sx-leg i`, `.sx-stack b`).
public enum HostColors {
    /// app (amber-dim), wired (bone 55 %), compressed (cyan 60 %): the same values as CoddUI's
    /// main-actor `MeterView.stackColors`, here usable while building models off the main actor.
    public static var legend: [NSColor] {
        [Palette.amberDim, Palette.bone.withAlphaComponent(0.55), Palette.cyan.withAlphaComponent(0.6)]
    }
}

/// One MEM legend line: `■ app ……… 13.8G`.
public struct HostLegendItem: Sendable, Equatable {
    public var label: String
    public var value: String
    public var color: NSColor

    public init(label: String, value: String, color: NSColor) {
        self.label = label
        self.value = value
        self.color = color
    }
}

/// One HOST metric card (`.sx-m`). CPU and MEM are the tall cards (two grid rows) with a
/// 10-minute sparkline; MEM puts its stacked meter under the value, followed by the legend.
public struct HostCardModel: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case cpu, memory, disk, swap, battery, claude, app, uptime }

    public var kind: Kind
    /// `CPU`, `MEM`, `Disk`, … (drawn uppercase).
    public var label: String
    /// Right side of the label line (`user + sys`, `● pressure normal`, `1T`, `AC`, `RSS`).
    public var right: String?
    /// nil draws `--dimmer`; MEM's pressure uses success / amber / danger.
    public var rightColor: NSColor?
    /// Big value (Space Mono 22): `23`, `21.4`, `412G`.
    public var value: String
    /// Small unit after the value: `%`, `/36G`, `free`, `MB`.
    public var unit: String?
    public var sub: String?
    public var meter: StatusMeter
    /// Spoken description of the meter (MEM: `記憶體 app 13.8G、wired 4.3G、…`).
    public var meterLabel: String?
    /// Sparkline samples, oldest first, each 0…1 of the card's range; nil = no sparkline.
    public var spark: [Double]?
    /// Dashed reference line across the sparkline (CPU: the current value), 0…1.
    public var sparkBaseline: Double?
    /// Labels under the sparkline, spread edge to edge: `-10m` / `peak 38%` / `now`.
    public var axis: [String]
    public var legend: [HostLegendItem]

    public init(kind: Kind, label: String, right: String? = nil, rightColor: NSColor? = nil, value: String,
                unit: String? = nil, sub: String? = nil, meter: StatusMeter, meterLabel: String? = nil,
                spark: [Double]? = nil, sparkBaseline: Double? = nil, axis: [String] = [], legend: [HostLegendItem] = []) {
        self.kind = kind
        self.label = label
        self.right = right
        self.rightColor = rightColor
        self.value = value
        self.unit = unit
        self.sub = sub
        self.meter = meter
        self.meterLabel = meterLabel
        self.spark = spark
        self.sparkBaseline = sparkBaseline
        self.axis = axis
        self.legend = legend
    }

    /// CPU and MEM span two grid rows.
    public var isTall: Bool { kind == .cpu || kind == .memory }
}

/// HOST section: `HOST studio-mbp · 曲線為最近 10 分鐘 ┄┄ ● 正常` and the metric grid.
public struct HostSectionModel: Sendable, Equatable {
    public var name: String
    /// false shows `◆ 注意` instead of `● 正常`.
    public var healthy: Bool
    /// Cards in grid order (CPU, MEM, then the small cards row by row); a Mac without a battery
    /// simply has no `.battery` card.
    public var cards: [HostCardModel]

    public init(name: String, healthy: Bool, cards: [HostCardModel]) {
        self.name = name
        self.healthy = healthy
        self.cards = cards
    }

    public static let historyHint = "曲線為最近 10 分鐘"
}

// MARK: - ACCOUNTS

/// One quota row of an account card: `5h ▮▮▮▮▮▮▮▮▮▯ 98%` and under it `重置 13:19 … 2h37m後`.
public struct AccountQuotaRow: Sendable, Equatable {
    /// Which window the row is: auto-switch's threshold tick goes on the 5h / 1w rows it checks only.
    public enum Window: Sendable, Equatable { case fiveHour, weekly, scoped }

    /// `5h`, `1w`, `Fable`.
    public var key: String
    public var window: Window
    /// Remaining percent (0…100); nil draws `—` and an empty bar.
    public var remaining: Double?
    public var tone: Tone
    /// Left of the line under the bar: `重置 13:19`, `未開始`, `快取未提供`, `週額度 · 同 1w 重置`.
    public var reset: String
    /// Right of that line: `.countdown(resetsAt)` or a fixed note (`等待回報`, `第一則訊息後起算`).
    public var countdown: StatusText
    /// The 1w reset is the sort key (R7): its line is drawn brighter.
    public var isSortKey: Bool

    /// `window` defaults from the key (`5h`, `1w`, anything else a scoped window).
    public init(key: String, remaining: Double?, tone: Tone, reset: String, countdown: StatusText, isSortKey: Bool = false,
                window: Window? = nil) {
        self.key = key
        self.window = window ?? (key == "5h" ? .fiveHour : key == "1w" ? .weekly : .scoped)
        self.remaining = remaining
        self.tone = tone
        self.reset = reset
        self.countdown = countdown
        self.isSortKey = isSortKey
    }
}

/// The card's health line before its source: `● ok`, `◌ 舊資料`, `▲ 需要重新登入`.
public struct AccountHealth: Sendable, Equatable {
    public var text: String
    public var color: NSColor

    public init(text: String, color: NSColor) {
        self.text = text
        self.color = color
    }

    public static var ok: AccountHealth { AccountHealth(text: "● ok", color: Palette.success) }
    public static var stale: AccountHealth { AccountHealth(text: "◌ 舊資料", color: Palette.amber) }
    public static var reloginRequired: AccountHealth { AccountHealth(text: "▲ 需要重新登入", color: Palette.danger) }
}

/// The card header's button.
public enum AccountButton: Sendable, Equatable {
    /// `[ACTIVE]`, disabled: this is the global login.
    case active
    /// `[SWITCH]` (accent): switches directly (R3).
    case switchable
    /// This account is being switched to: `[切換中…]`, disabled, with an optional progress line
    /// (`◌ 等待 Claude Code credential lock… 9s（1/3）`).
    case switching(progress: String?)
    /// `[SWITCH]` disabled with the reason as a dim line and tooltip (another switch runs, the
    /// account is disabled in cswap, it needs a new login).
    case disabled(reason: String)
}

/// Bottom line of a card: `● 12 個 session 跟隨全域登入`, `○ 0 個 session` (muted).
public struct AccountWho: Sendable, Equatable {
    public var glyph: StatusGlyph
    public var text: String
    public var muted: Bool

    public init(glyph: StatusGlyph, text: String, muted: Bool = false) {
        self.glyph = glyph
        self.text = text
        self.muted = muted
    }

    /// `● n 個 session 跟隨全域登入` (active account).
    public static func following(_ count: Int) -> AccountWho {
        count == 0 ? none : AccountWho(glyph: StatusGlyph("●", Palette.cyan), text: "\(count) 個 session 跟隨全域登入")
    }

    /// `● n 個 session 固定（cswap run）` (other accounts).
    public static func pinned(_ count: Int) -> AccountWho {
        count == 0 ? none : AccountWho(glyph: StatusGlyph("●", Palette.cyan), text: "\(count) 個 session 固定（cswap run）")
    }

    /// `○ 0 個 session`.
    public static var none: AccountWho { AccountWho(glyph: .off, text: "0 個 session", muted: true) }
}

/// One account card (`.card.sx-acct`, `.hot` when active). Aliases are drawn as given: the app
/// passes cswap's alias already redacted (D31); there is no e-mail field.
public struct AccountCardModel: Sendable, Equatable, Identifiable {
    public var id: String
    /// `#2`.
    public var slot: String
    public var alias: String
    /// `MAX 20x`; nil = no chip.
    public var plan: String?
    public var isActive: Bool
    public var health: AccountHealth
    /// `cswap cache · 3m 前`, `statusline · 12s 前`.
    public var source: StatusText
    /// 5h, 1w, scoped windows, in that order.
    public var rows: [AccountQuotaRow]
    /// Amber pace warning (`↗ 1w 用量超前預期 · 預估 10/17 18:00 用完`).
    public var pace: String?
    public var who: AccountWho
    public var button: AccountButton

    public init(id: String, slot: String, alias: String, plan: String? = nil, isActive: Bool = false,
                health: AccountHealth = .ok, source: StatusText, rows: [AccountQuotaRow], pace: String? = nil,
                who: AccountWho, button: AccountButton) {
        self.id = id
        self.slot = slot
        self.alias = alias
        self.plan = plan
        self.isActive = isActive
        self.health = health
        self.source = source
        self.rows = rows
        self.pace = pace
        self.who = who
        self.button = button
    }
}

/// The AUTO-SWITCH row under the cards (R8): OFF shows the configured rule as dim dashed chips;
/// ON draws normal chips and the threshold tick on the 5h / 1w bars the rule checks (never on a
/// scoped window, which auto-switch does not read).
public struct AutoSwitchModel: Sendable, Equatable {
    public var on: Bool
    /// The tick position on the bars (remaining %), used only while `on`.
    public var thresholdPercent: Double
    /// 檢查 5 小時 / 檢查每週: which bars get the tick.
    public var checksFiveHour: Bool
    public var checksWeekly: Bool
    /// Rule chips: `剩餘 ≤ 2%`, `5h / 1w`, `依排序第一個額度足夠的`, `冷卻 300s` (`ruleChips`).
    public var chips: [String]
    public var note: String
    /// `! cswap menubar 也在執行，兩邊可能同時切換` (D13), amber.
    public var warning: String?

    public init(on: Bool, thresholdPercent: Double = 2, chips: [String], note: String = AutoSwitchModel.defaultNote,
                warning: String? = nil, checksFiveHour: Bool = true, checksWeekly: Bool = true) {
        self.checksFiveHour = checksFiveHour
        self.checksWeekly = checksWeekly
        self.on = on
        self.thresholdPercent = thresholdPercent
        self.chips = chips
        self.note = note
        self.warning = warning
    }

    public static let defaultNote = "// 用量只讀 statusline 與 cswap 快取，不另外打 API（避免 429）"

    /// The tick for a bar of `window`: the threshold while ON and the rule checks that window.
    public func threshold(for window: AccountQuotaRow.Window) -> Double? {
        guard on else { return nil }
        switch window {
        case .fiveHour: return checksFiveHour ? thresholdPercent : nil
        case .weekly: return checksWeekly ? thresholdPercent : nil
        case .scoped: return nil
        }
    }
    public static let menubarWarning = "! cswap menubar 也在執行，兩邊可能同時切換"

    /// FB 「自動切換帳號加上警語」: shown under the switch (amber) and asked once each time it is turned ON.
    public static let policyWarning = "Claude 官方不建議用多個帳號自動輪替來延長用量，可能違反 Anthropic 的使用條款；開啟前請自行評估風險。"
    /// The amber line as drawn (the `! ` of the other amber warnings).
    public static var policyLine: String { "! " + policyWarning }

    /// The four rule chips of the artboard from the configured values.
    public static func ruleChips(thresholdPercent: Int = 2, fiveHour: Bool = true, weekly: Bool = true,
                                 cooldownSeconds: Int = 300) -> [String] {
        let windows = [fiveHour ? "5h" : nil, weekly ? "1w" : nil].compactMap { $0 }
        return ["剩餘 ≤ \(thresholdPercent)%", windows.isEmpty ? "—" : windows.joined(separator: " / "),
                "依排序第一個額度足夠的", "冷卻 \(cooldownSeconds)s"]
    }
}

/// ACCOUNTS section: header chips and hints, the cards in the given (R7) order, `+ 加入帳號`,
/// and the auto-switch row. `unavailable` replaces the cards with one comment line.
public struct AccountsSectionModel: Sendable, Equatable {
    /// `cswap 0.26.0` chip; nil = no chip.
    public var version: String?
    /// `~/.claude-swap-backup` path box; nil = none.
    public var rootPath: String?
    /// `3 個帳號 · 不顯示 email` (`countHint(_:)`).
    public var countHint: String
    public var cards: [AccountCardModel]
    /// Shows the dashed `+ 加入帳號` card.
    public var canAdd: Bool
    /// `// 找不到 cswap（設定 › 帳號）`, `// cswap 0.25.1 太舊，需要 ≥ 0.26`, `// 讀不到 cswap 狀態：…`.
    public var unavailable: String?
    public var autoSwitch: AutoSwitchModel

    public init(version: String?, rootPath: String?, countHint: String, cards: [AccountCardModel], canAdd: Bool,
                unavailable: String? = nil, autoSwitch: AutoSwitchModel) {
        self.version = version
        self.rootPath = rootPath
        self.countHint = countHint
        self.cards = cards
        self.canAdd = canAdd
        self.unavailable = unavailable
        self.autoSwitch = autoSwitch
    }

    /// R7 sort basis, shown in every account list header.
    public static let sortHint = "依每週重置排序 · 越快重置越上面"
    public static let addTitle = "加入帳號"
    public static let addHint = "cswap add · 用 claude /login 登入後擷取"

    public static func countHint(_ accounts: Int) -> String { "\(accounts) 個帳號 · 不顯示 email" }

    /// The three unavailable lines of D1 / D3.
    public static let cswapMissing = "// 找不到 cswap（設定 › 帳號）"
    public static func cswapTooOld(_ version: String) -> String { "// cswap \(version) 太舊，需要 ≥ 0.26" }
    public static func stateUnreadable(_ reason: String) -> String {
        "// 讀不到 cswap 狀態：\(reason) · 按 ↻ 立即更新 改用 cswap list（會查詢一次用量）"
    }

    /// FB 「引導安裝 cswap」: the install (cswap missing) or upgrade (too old) guide under the
    /// unavailable line, derived from it so every caller of the D1 / D3 lines gets it.
    public var guide: CswapInstallGuide? {
        guard let unavailable else { return nil }
        if unavailable == Self.cswapMissing { return CswapInstallGuide(kind: .install) }
        if unavailable.hasPrefix("// cswap "), unavailable.hasSuffix("太舊，需要 ≥ 0.26") { return CswapInstallGuide(kind: .upgrade) }
        return nil
    }
}

/// How to get cswap (the PyPI package `claude-swap`, github.com/realiti4/claude-swap): installed
/// with uv; without uv, Homebrew or uv's own installer first. `在終端機執行` types the command into
/// a SHELL session without running it (the user presses Return); `重新偵測` looks for cswap again.
/// Settings › 帳號 and onboarding step 5 show the same commands.
public struct CswapInstallGuide: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// cswap was not found.
        case install
        /// cswap is older than 0.26.
        case upgrade
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public static let installCommand = "uv tool install claude-swap"
    public static let upgradeCommand = "uv tool upgrade claude-swap"
    /// uv first, when it is missing: Homebrew, or uv's official installer.
    public static let uvCommands = ["brew install uv", "curl -LsSf https://astral.sh/uv/install.sh | sh"]
    public static let projectURL = "https://github.com/realiti4/claude-swap"

    /// `INSTALL` / `UPGRADE`.
    public var label: String { kind == .install ? "Install" : "Upgrade" }
    public var lead: String {
        switch kind {
        case .install: "cswap（PyPI 套件 claude-swap）負責切換帳號與讀取用量快取。用 uv 安裝："
        case .upgrade: "這個 cswap 太舊，CODD 需要 0.26 以上。用 uv 更新（用 pipx 裝的改用 pipx upgrade claude-swap）："
        }
    }
    /// The command `在終端機執行` types.
    public var command: String { kind == .install ? Self.installCommand : Self.upgradeCommand }
    /// The uv lines (install only).
    public var uvCommands: [String] { kind == .install ? Self.uvCommands : [] }
    public static let uvHint = "還沒有 uv？先用其中一行安裝："
    public static let note = "// 在終端機執行 只會打好指令，按 Return 才會執行 · 裝好後按 重新偵測，再用 + 加入帳號 登入各個帳號"
    public static let copyTitle = "複製"
    public static let copiedTitle = "已複製"
    public static let runTitle = "在終端機執行"
    public static let redetectTitle = "↻ 重新偵測"
    /// Every command the guide shows, in order.
    public var commands: [String] { [command] + uvCommands }
}

/// The guide's buttons (the app: the pasteboard (D39) and an ephemeral SHELL session).
@MainActor
public struct CswapGuideActions {
    /// `[複製]`: the command as shown.
    public var copy: (String) -> Void
    /// `[在終端機執行]`: a terminal with the command typed, not run.
    public var runInTerminal: (String) -> Void

    public init(copy: @escaping (String) -> Void = { _ in }, runInTerminal: @escaping (String) -> Void = { _ in }) {
        self.copy = copy
        self.runInTerminal = runInTerminal
    }
}

/// FB: turning auto-switch ON asks first, with the policy warning (an alert sheet on the page's
/// window; tests and demos pass their own answer).
@MainActor
public enum AutoSwitchConfirmation {
    public static let title = "開啟自動切換帳號？"
    public static let confirmTitle = "仍要開啟"
    public static let cancelTitle = "取消"

    /// Asks over `window` (application-modal without one); `done(true)` when the user confirms.
    public static func ask(on window: NSWindow?, done: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = AutoSwitchModel.policyWarning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        guard let window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { done(response == .alertFirstButtonReturn) }
        }
    }
}

// MARK: - HOOKS & STATUSLINE

/// The Statusline part row: CODD Desktop's optional global wrapper (D11) and what it chains.
public struct StatuslinePart: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// CODD Desktop's global wrapper, current: `● 已安裝`.
        case installed
        /// CODD Desktop's wrapper pointing at an old data root / binary: `◆ 需要更新`.
        case outdated
        /// CODD web's `codd-statusline.js` wrapper (legacy): `◆ 舊版 CODD web statusline`.
        case legacyWeb
        /// The user's own status line or none: `○ 未安裝全域 statusline`.
        case notInstalled
        /// A wrapper whose chain cannot be decoded: `▲ 無法解析`.
        case undecodable
    }

    public var state: State
    /// The chain as code chips: `CODD` → `hook-tap` → `statusline.sh`.
    public var chain: [String]

    public init(state: State, chain: [String] = []) {
        self.state = state
        self.chain = chain
    }
}

/// CODD web leftovers in the user's settings (D10 Legacy): the hook events still calling
/// `status-writer.js`.
public struct LegacyHooks: Sendable, Equatable {
    public var events: [String]

    public init(events: [String]) { self.events = events }
}

/// When CODD last heard from hooks / status lines (`8s 前 · hook 事件與 statusline 都有回報`).
public struct LastReceived: Sendable, Equatable {
    public var at: Date?
    public var hooks: Bool
    public var statusline: Bool

    public init(at: Date?, hooks: Bool, statusline: Bool) {
        self.at = at
        self.hooks = hooks
        self.statusline = statusline
    }
}

/// One FOREIGN HOOKS row: `hook-tap ×11 events [PermissionRequest 會阻擋 600s]`,
/// `osascript 通知 ×2 · Notification, Stop`.
public struct ForeignHookRow: Sendable, Equatable {
    /// The command's tool (`hook-tap`, `osascript`), drawn as code.
    public var code: String
    /// `通知` for `osascript`, else the program name again (`hook-tap`): the row then shows only the code.
    public var name: String
    public var events: [String]
    /// Amber chips (`PermissionRequest 會阻擋 600s`).
    public var warnings: [String]
    /// The row is the duplicate macOS notification (`osascript … display notification`) and
    /// offers `[停用重複通知]`.
    public var duplicateNotifications: Bool

    public init(code: String, name: String, events: [String], warnings: [String] = [], duplicateNotifications: Bool = false) {
        self.code = code
        self.name = name
        self.events = events
        self.warnings = warnings
        self.duplicateNotifications = duplicateNotifications
    }
}

/// The small card per cswap session profile used by pinned sessions:
/// `cswap session profile #2 → settings.json 連結自 ~/.claude（共用） ● 已連結`.
public struct ProfileCardModel: Sendable, Equatable {
    public var slot: String
    /// The profile's settings.json is a symlink to the main one (nil: could not be checked).
    public var linked: Bool?
    /// Titles of the sessions pinned to this account.
    public var sessionTitles: [String]

    public init(slot: String, linked: Bool?, sessionTitles: [String]) {
        self.slot = slot
        self.linked = linked
        self.sessionTitles = sessionTitles
    }
}

/// The `~/.claude settings.json` card and its profile cards.
public struct HooksCardModel: Sendable, Equatable {
    /// Card title (`~/.claude`) and file (`settings.json`).
    public var claudeDir: String
    public var fileName: String
    /// Header chip: 0 → `● 正常`, n → `◆ n 項需要更新`.
    public var pendingUpdates: Int
    /// The settings file cannot be inspected (`// 讀不到 settings.json：…`), drawn above the parts.
    public var problem: String?
    /// Hook events every CODD session gets through `--settings` (`● 14 / 14`).
    public var hooksInjected: Int
    public var hooksTotal: Int
    public var legacy: LegacyHooks?
    public var statusline: StatuslinePart
    /// CODD's hook record directory (abbreviated) and whether it is not the default one.
    public var statusDir: String
    public var statusDirDiffers: Bool
    public var lastReceived: LastReceived
    public var foreign: [ForeignHookRow]
    public var canPreview: Bool
    public var canUpdate: Bool
    public var canUninstall: Bool
    public var canRemoveLegacy: Bool
    public var canDisableDuplicates: Bool
    /// One card per cswap session profile in use by pinned sessions (none without pins).
    public var profiles: [ProfileCardModel]
    /// The hook endpoint's diagnostics (state, accepted / rejected counts, the last rejection, refused
    /// connections), one line each, shown under the 最近收到資料 row by its `▸ 詳細` toggle: a hook
    /// Claude sends and the endpoint refuses stays diagnosable. Empty hides the toggle.
    public var details: [String]

    public init(claudeDir: String = "~/.claude", fileName: String = "settings.json", pendingUpdates: Int, problem: String? = nil,
                hooksInjected: Int = 14, hooksTotal: Int = 14, legacy: LegacyHooks? = nil, statusline: StatuslinePart,
                statusDir: String, statusDirDiffers: Bool, lastReceived: LastReceived, foreign: [ForeignHookRow],
                canPreview: Bool, canUpdate: Bool, canUninstall: Bool, canRemoveLegacy: Bool, canDisableDuplicates: Bool,
                profiles: [ProfileCardModel] = [], details: [String] = []) {
        self.claudeDir = claudeDir
        self.fileName = fileName
        self.pendingUpdates = pendingUpdates
        self.problem = problem
        self.hooksInjected = hooksInjected
        self.hooksTotal = hooksTotal
        self.legacy = legacy
        self.statusline = statusline
        self.statusDir = statusDir
        self.statusDirDiffers = statusDirDiffers
        self.lastReceived = lastReceived
        self.foreign = foreign
        self.canPreview = canPreview
        self.canUpdate = canUpdate
        self.canUninstall = canUninstall
        self.canRemoveLegacy = canRemoveLegacy
        self.canDisableDuplicates = canDisableDuplicates
        self.profiles = profiles
        self.details = details
    }
}

// MARK: - MCP SERVER (M4, D16, D21–D23)

/// One connected client of CODD's MCP server (D21: a CODD session, or an external token +
/// `clientInfo.name` seen in the last 30 minutes): `● 修正登入 API 401  Claude Code … 連線 42m`.
public struct StatusMCPClient: Sendable, Equatable, Identifiable {
    public var id: String
    /// The session's title, or the external client's name (`codex`).
    public var title: String
    /// `Claude Code`, `Codex CLI`, or the client's raw `clientInfo.name`.
    public var kind: String
    /// `連線 42m` (formatted by the app; the card redraws when the model changes).
    public var connectedFor: String

    public init(id: String, title: String, kind: String, connectedFor: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.connectedFor = connectedFor
    }
}

/// One REGISTRATIONS row (D22): `Claude Code  user scope … ● 已註冊 [移除]`.
public struct StatusMCPRegistration: Sendable, Equatable, Identifiable {
    /// What `StatusPageActions.onMCPRegistration` receives: `claude-code`, `codex`, `claude-desktop`.
    public var id: String
    public var name: String
    /// `user scope`, `~/.codex/config.toml`, `擴充功能`.
    public var hint: String
    /// `● 已註冊`, `○ 未註冊`, `○ 未安裝`, `◆ 需要重新註冊`.
    public var state: String
    /// The state's color: ok success, muted dimmer, warn amber, crit danger.
    public var stateTone: Tone
    /// `移除`, `註冊`, `安裝 .mcpb`; nil = no button.
    public var actionTitle: String?
    public var actionEnabled: Bool
    /// `.btn.accent` (註冊) instead of the plain look.
    public var accent: Bool
    /// A milestone chip before the button (`FUTURE`); the button is then disabled.
    public var chip: String?
    /// The button's tooltip (why it is disabled: `註冊在 I2b 接上`).
    public var toolTip: String?

    public init(id: String, name: String, hint: String, state: String, stateTone: Tone, actionTitle: String? = nil,
                actionEnabled: Bool = true, accent: Bool = false, chip: String? = nil, toolTip: String? = nil) {
        self.id = id
        self.name = name
        self.hint = hint
        self.state = state
        self.stateTone = stateTone
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
        self.accent = accent
        self.chip = chip
        self.toolTip = toolTip
    }

    /// The button can be pressed.
    public var isActionable: Bool { actionTitle != nil && actionEnabled && chip == nil }
}

/// The MCP SERVER card (Status artboard): `CODD MCP · <notes>`, the run line, the clients, the
/// registrations and the token row. nil in `StatusPageModel.mcp` keeps M3's placeholder card.
public struct StatusMCPModel: Sendable, Equatable {
    /// The endpoint and its handler run (`● RUNNING`); false draws `○ STOPPED` dim with `note`.
    public var running: Bool
    /// `127.0.0.1:47821` (the hook server's port, D16); empty = not shown.
    public var endpoint: String
    /// D21's count (`3 clients`), which may exceed the listed rows.
    public var clientsCount: Int
    public var clients: [StatusMCPClient]
    public var registrations: [StatusMCPRegistration]
    /// `••••` (never the token itself).
    public var tokenMasked: String
    /// `<dataRoot>/notes` abbreviated (`~/Library/Application Support/CODD/notes`).
    public var notesPath: String
    /// A comment under the run line (`// hook server 未執行，MCP 暫停`); nil = none.
    public var note: String?
    /// `[輪替]` pressable (`StatusPageActions.onRotateMCPToken`, D23).
    public var canRotateToken: Bool

    public init(running: Bool, endpoint: String, clientsCount: Int, clients: [StatusMCPClient] = [],
                registrations: [StatusMCPRegistration] = [], tokenMasked: String = "••••", notesPath: String, note: String? = nil,
                canRotateToken: Bool = true) {
        self.running = running
        self.endpoint = endpoint
        self.clientsCount = clientsCount
        self.clients = clients
        self.registrations = registrations
        self.tokenMasked = tokenMasked
        self.notesPath = notesPath
        self.note = note
        self.canRotateToken = canRotateToken
    }

    /// `3 clients` (the run line, the nav value; SPEC §5 writes the plural for every count).
    public static func clientsText(_ count: Int) -> String { "\(count) clients" }
    public static let localOnlyHint = "只接受本機連線"
    public static let noClients = "// 沒有 client 連線"
    public static let tokenHint = "client 連線時需附上"
    public static let registrationsHint = "註冊到其他 app"
}

extension StatusNavItem {
    /// The sidebar's `MCP 本機 server … 3 clients` (glyph ok while running, off otherwise);
    /// without a model (an M3 caller) `○ —`.
    public static func mcp(_ model: StatusMCPModel?) -> StatusNavItem {
        guard let model else { return StatusNavItem(id: .mcp, glyph: .off, value: "—") }
        return StatusNavItem(id: .mcp, glyph: model.running ? .ok : .off, value: StatusMCPModel.clientsText(model.running ? model.clientsCount : 0))
    }
}

// MARK: - REMOTE

/// REMOTE: `◉ 1 個 session 已連 Remote Control（修正登入 API 401）`.
public struct RemoteModel: Sendable, Equatable {
    public var count: Int
    public var titles: [String]

    public init(count: Int, titles: [String]) {
        self.count = count
        self.titles = titles
    }
}

// MARK: - Page

/// Everything both STATUS views draw. Built by the app every refresh (D32, 5 s).
public struct StatusPageModel: Sendable, Equatable {
    public var updatedAt: Date
    public var refreshSeconds: Int
    public var paused: Bool
    /// Data is flowing (the hook endpoint listens); false shows `○ OFFLINE` instead of `● LIVE`.
    public var live: Bool
    public var nav: [StatusNavItem]
    public var needsYou: [StatusSessionRow]
    public var counts: [StatusCount]
    public var liveCount: Int
    public var host: HostSectionModel
    public var accounts: AccountsSectionModel
    public var hooks: HooksCardModel
    public var remote: RemoteModel
    /// MCP SERVER (M4); nil keeps the D27 placeholder card (callers from before M4).
    public var mcp: StatusMCPModel?

    public init(updatedAt: Date, refreshSeconds: Int = 5, paused: Bool = false, live: Bool = true, nav: [StatusNavItem],
                needsYou: [StatusSessionRow], counts: [StatusCount], liveCount: Int, host: HostSectionModel,
                accounts: AccountsSectionModel, hooks: HooksCardModel, remote: RemoteModel, mcp: StatusMCPModel? = nil) {
        self.updatedAt = updatedAt
        self.refreshSeconds = refreshSeconds
        self.paused = paused
        self.live = live
        self.nav = nav
        self.needsYou = needsYou
        self.counts = counts
        self.liveCount = liveCount
        self.host = host
        self.accounts = accounts
        self.hooks = hooks
        self.remote = remote
        self.mcp = mcp
    }
}

/// What the views call back. Every closure defaults to doing nothing, so the app fills only
/// what it wires.
@MainActor
public struct StatusPageActions {
    /// `↻` / `[↻ 立即更新]`.
    public var refresh: () -> Void
    /// `[暫停]` / `[繼續]`.
    public var togglePause: () -> Void
    /// `→ 開啟 SESSIONS`.
    public var openSessions: () -> Void
    /// A NEEDS YOU row (its session id).
    public var openSession: (String) -> Void
    /// `[SWITCH]` on an account card (its id).
    public var switchAccount: (String) -> Void
    /// `+ 加入帳號`.
    public var addAccount: () -> Void
    /// The AUTO-SWITCH row's `[設定]` (Settings › 帳號).
    public var openAutoSwitch: () -> Void
    /// The AUTO-SWITCH row's switch (used when ``setAutoSwitch`` is nil, and only while the page
    /// still shows the other state).
    public var toggleAutoSwitch: () -> Void
    /// The AUTO-SWITCH row's switch as the value it asks for: ON after the confirmation, OFF
    /// without one. A value, not a toggle: while the confirmation sheet is up the switch may move
    /// elsewhere (Settings › 帳號), and a toggle would then turn it back OFF.
    public var setAutoSwitch: ((Bool) -> Void)?
    /// FB: asked before the switch turns auto-switch ON (the page's window, then the answer);
    /// `toggleAutoSwitch` runs only on a yes. Defaults to ``AutoSwitchConfirmation/ask(on:done:)``.
    public var confirmAutoSwitch: (NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void
    /// `[預覽變更]`, `[更新]`, `[解除安裝]`, `[只移除舊版]`, `[停用重複通知]` (each opens the
    /// Hook 差異 preview first, D10).
    public var previewHooks: () -> Void
    public var update: () -> Void
    public var uninstall: () -> Void
    public var removeLegacy: () -> Void
    public var disableDuplicateNotifications: () -> Void
    /// `Remote & Mobile 設定 →`.
    public var openRemoteSettings: () -> Void
    /// A MCP SERVER registration row's button (`StatusMCPRegistration.id`).
    public var onMCPRegistration: (String) -> Void
    /// MCP SERVER `[輪替]` (the app confirms first, D23).
    public var onRotateMCPToken: () -> Void

    public init(refresh: @escaping () -> Void = {}, togglePause: @escaping () -> Void = {},
                openSessions: @escaping () -> Void = {}, openSession: @escaping (String) -> Void = { _ in },
                switchAccount: @escaping (String) -> Void = { _ in }, addAccount: @escaping () -> Void = {},
                openAutoSwitch: @escaping () -> Void = {}, toggleAutoSwitch: @escaping () -> Void = {},
                previewHooks: @escaping () -> Void = {}, update: @escaping () -> Void = {},
                uninstall: @escaping () -> Void = {}, removeLegacy: @escaping () -> Void = {},
                disableDuplicateNotifications: @escaping () -> Void = {}, openRemoteSettings: @escaping () -> Void = {},
                onMCPRegistration: @escaping (String) -> Void = { _ in }, onRotateMCPToken: @escaping () -> Void = {},
                confirmAutoSwitch: @escaping (NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void = { window, done in
                    AutoSwitchConfirmation.ask(on: window, done: done)
                }, setAutoSwitch: ((Bool) -> Void)? = nil) {
        self.refresh = refresh
        self.togglePause = togglePause
        self.openSessions = openSessions
        self.openSession = openSession
        self.switchAccount = switchAccount
        self.addAccount = addAccount
        self.openAutoSwitch = openAutoSwitch
        self.toggleAutoSwitch = toggleAutoSwitch
        self.previewHooks = previewHooks
        self.update = update
        self.uninstall = uninstall
        self.removeLegacy = removeLegacy
        self.disableDuplicateNotifications = disableDuplicateNotifications
        self.openRemoteSettings = openRemoteSettings
        self.onMCPRegistration = onMCPRegistration
        self.onRotateMCPToken = onRotateMCPToken
        self.confirmAutoSwitch = confirmAutoSwitch
        self.setAutoSwitch = setAutoSwitch
    }
}
