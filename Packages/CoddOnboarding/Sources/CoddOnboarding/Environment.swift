import Foundation

/// One line of the boot block (`.ob-bl`): tag · name · value · dim detail.
public struct BootLine: Sendable, Equatable {
    public enum Tag: String, Sendable {
        case ok, pending, fail, skipped, waiting

        /// `[ OK ]` (success), `[ .. ]` (pending, amber), `[FAIL]` (danger), `[ -- ]` (skipped, dim);
        /// the step's waiting line is `[ .. ]` too.
        public var label: String {
            switch self {
            case .ok: "[ OK ]"
            case .pending, .waiting: "[ .. ]"
            case .fail: "[FAIL]"
            case .skipped: "[ -- ]"
            }
        }
    }

    public let tag: Tag
    public let name: String
    public let value: String
    public let detail: String
    /// The blinking `_` after the value (the waiting line).
    public let cursor: Bool

    public init(tag: Tag, name: String, value: String, detail: String = "", cursor: Bool = false) {
        self.tag = tag
        self.name = name
        self.value = value
        self.detail = detail
        self.cursor = cursor
    }

    /// VoiceOver reads `<tag> <name> <value>` (§2.4).
    public var spoken: String {
        [tag.label, name, value].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What the App probed (only while the wizard shows, D5). Plain values: the App fills them.
public struct EnvironmentFacts: Sendable, Equatable {
    public enum Claude: Sendable, Equatable {
        case found(version: String, path: String), missing, failed(String)
    }

    public enum Cswap: Sendable, Equatable {
        case ready(version: String, path: String, accounts: Int), missing, unsupported(String), unreadable(String), loading
    }

    public enum Hooks: Sendable, Equatable {
        /// `file` and every path here are absolute; the report writes `~` for the home folder.
        case upToDate(file: String), legacy(events: [String], file: String), statuslineOutdated(file: String),
             unreadable(String), unknown
    }

    public struct DataRoot: Sendable, Equatable {
        public let path: String
        public let writable: Bool
        /// `127.0.0.1:47821`; nil when the hook server has no port.
        public let mcpEndpoint: String?
        public let mcpRunning: Bool

        public init(path: String, writable: Bool, mcpEndpoint: String?, mcpRunning: Bool) {
            self.path = path
            self.writable = writable
            self.mcpEndpoint = mcpEndpoint
            self.mcpRunning = mcpRunning
        }
    }

    /// The import source (the boot block's fifth row before step 2 is done).
    public enum Projects: Sendable, Equatable {
        case found(count: Int, source: String), missing(source: String), unreadable(source: String, reason: String), unknown
    }

    public var claude: Claude
    public var cswap: Cswap
    public var hooks: Hooks
    public var dataRoot: DataRoot
    public var checkedAt: Date
    public var milliseconds: Int
    public var projects: Projects

    public init(claude: Claude, cswap: Cswap, hooks: Hooks, dataRoot: DataRoot, checkedAt: Date, milliseconds: Int,
                projects: Projects = .unknown) {
        self.claude = claude
        self.cswap = cswap
        self.hooks = hooks
        self.dataRoot = dataRoot
        self.checkedAt = checkedAt
        self.milliseconds = milliseconds
        self.projects = projects
    }
}

/// The boot block (D11): rows `claude`, `cswap`, `hooks`, the data root, the import source (or, after
/// step 2, what it imported), then the step's own last line (`[ .. ] projects waiting for operator_`
/// … `[ OK ] ready`). The counts and the header cover every row but that last line.
public struct EnvironmentReport: Sendable, Equatable {
    public let lines: [BootLine]
    public let ok: Int
    public let pending: Int
    public let failed: Int
    /// `4 OK · 1 待處理` (`· 1 失敗` when something failed).
    public let header: String
    /// `10:41:58 · 0.8s` (the facts' time in the given zone and the probe's duration).
    public let checked: String
    /// `4 項正常 · 1 項待處理` (step 1's stepper detail and footer summary).
    public let summary: String

    public init(lines: [BootLine], ok: Int, pending: Int, failed: Int, header: String, checked: String, summary: String) {
        self.lines = lines
        self.ok = ok
        self.pending = pending
        self.failed = failed
        self.header = header
        self.checked = checked
        self.summary = summary
    }

    public static func make(_ facts: EnvironmentFacts, step: OnboardingStep, imported: Int?, timeZone: TimeZone) -> EnvironmentReport {
        make(facts, step: step, imported: imported, timeZone: timeZone, home: NSHomeDirectory())
    }

    /// `make` with the home folder used for `~`.
    public static func make(_ facts: EnvironmentFacts, step: OnboardingStep, imported: Int?, timeZone: TimeZone,
                            home: String) -> EnvironmentReport {
        let short = { (path: String) in PathText.abbreviate(path, home: home) }
        var lines: [BootLine] = []
        switch facts.claude {
        case .found(let version, let path):
            lines.append(BootLine(tag: .ok, name: "claude", value: version, detail: short(path)))
        case .missing:
            lines.append(BootLine(tag: .fail, name: "claude", value: "找不到", detail: "先安裝 Claude Code"))
        case .failed(let reason):
            lines.append(BootLine(tag: .fail, name: "claude", value: "無法執行", detail: reason))
        }
        switch facts.cswap {
        case .ready(let version, let path, let accounts):
            lines.append(BootLine(tag: .ok, name: "cswap", value: "\(version) · \(accounts) 個帳號", detail: short(path)))
        case .missing:
            lines.append(BootLine(tag: .pending, name: "cswap", value: "沒有安裝", detail: "選用：要切換多個帳號再安裝（0.26 以上）"))
        case .unsupported(let version):
            lines.append(BootLine(tag: .pending, name: "cswap", value: "\(version) 太舊", detail: "需要 0.26 以上"))
        case .unreadable(let reason):
            lines.append(BootLine(tag: .pending, name: "cswap", value: "讀不到狀態", detail: reason))
        case .loading:
            lines.append(BootLine(tag: .pending, name: "cswap", value: "讀取中…"))
        }
        switch facts.hooks {
        case .upToDate(let file):
            lines.append(BootLine(tag: .ok, name: "hooks", value: "已是最新", detail: short(file)))
        case .legacy(let events, let file):
            lines.append(BootLine(tag: .pending, name: "hooks", value: "需要更新（\(events.count) 個事件）",
                                  detail: "\(short(file)) · 舊版 CODD web：\(events.joined(separator: " / "))"))
        case .statuslineOutdated(let file):
            lines.append(BootLine(tag: .pending, name: "hooks", value: "需要更新（狀態列）", detail: "\(short(file)) · 全域狀態列是舊版"))
        case .unreadable(let reason):
            lines.append(BootLine(tag: .fail, name: "hooks", value: "讀不到設定", detail: reason))
        case .unknown:
            lines.append(BootLine(tag: .skipped, name: "hooks", value: "尚未檢查"))
        }
        let root = facts.dataRoot
        let mcp = root.mcpEndpoint.map { root.mcpRunning ? "MCP \($0) 可用" : "MCP \($0) 未啟動" } ?? "MCP 未啟動"
        if !root.writable {
            lines.append(BootLine(tag: .fail, name: short(root.path), value: "無法寫入", detail: mcp))
        } else {
            lines.append(BootLine(tag: root.mcpRunning ? .ok : .pending, name: short(root.path), value: "可寫入", detail: mcp))
        }
        if step.rawValue > OnboardingStep.importProjects.rawValue, let imported {
            lines.append(imported > 0
                ? BootLine(tag: .ok, name: "projects", value: "已匯入 \(imported) 個")
                : BootLine(tag: .skipped, name: "projects", value: "未匯入"))
        } else {
            switch facts.projects {
            case .found(let count, let source):
                lines.append(BootLine(tag: .ok, name: short(source), value: "\(count) 個專案", detail: "只讀取，不會改動"))
            case .missing(let source):
                lines.append(BootLine(tag: .skipped, name: short(source), value: "找不到", detail: "還沒用過 Claude Code？"))
            case .unreadable(let source, let reason):
                lines.append(BootLine(tag: .pending, name: short(source), value: "讀不到", detail: reason))
            case .unknown:
                break
            }
        }
        let ok = lines.filter { $0.tag == .ok }.count
        let pending = lines.filter { $0.tag == .pending }.count
        let failed = lines.filter { $0.tag == .fail }.count
        lines.append(waitingLine(for: step))

        var header = ["\(ok) OK"]
        if pending > 0 { header.append("\(pending) 待處理") }
        if failed > 0 { header.append("\(failed) 失敗") }
        var summary = ["\(ok) 項正常"]
        if pending > 0 { summary.append("\(pending) 項待處理") }
        if failed > 0 { summary.append("\(failed) 項失敗") }
        return EnvironmentReport(lines: lines, ok: ok, pending: pending, failed: failed, header: header.joined(separator: " · "),
                                 checked: "\(clock(facts.checkedAt, timeZone: timeZone)) · \(duration(facts.milliseconds))",
                                 summary: summary.joined(separator: " · "))
    }

    /// The step's own last line: the operator is expected (`waiting for operator_`), or `ready` on step 6.
    public static func waitingLine(for step: OnboardingStep) -> BootLine {
        let name: String
        switch step {
        case .detect: name = "detect"
        case .importProjects: name = "projects"
        case .hooks: name = "hooks"
        case .notebook: name = "notebook"
        case .accounts: name = "accounts"
        case .done: return BootLine(tag: .ok, name: "ready", value: "")
        }
        return BootLine(tag: .waiting, name: name, value: "waiting for operator", cursor: true)
    }

    /// `HH:mm:ss` in `timeZone`.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        func pad(_ value: Int?) -> String { let v = value ?? 0; return v < 10 ? "0\(v)" : "\(v)" }
        return "\(pad(parts.hour)):\(pad(parts.minute)):\(pad(parts.second))"
    }

    /// `0.8s` (one decimal, at least 0.1s).
    static func duration(_ milliseconds: Int) -> String {
        let tenths = max(1, Int((Double(max(0, milliseconds)) / 100).rounded()))
        return "\(tenths / 10).\(tenths % 10)s"
    }
}

/// One line under step 1's lead: something that needs attention, with the button that helps
/// (`target` nil: `↻ 重新偵測`).
public struct DetectItem: Sendable, Equatable {
    /// `▲`, `○`, `◆`, or `//` for the all-fine comment.
    public let glyph: String
    /// `danger`, `dim`, `amber`, `comment`.
    public let tone: String
    public let text: String
    public let button: String?
    public let target: OnboardingStep?

    public init(glyph: String, tone: String, text: String, button: String?, target: OnboardingStep?) {
        self.glyph = glyph
        self.tone = tone
        self.text = text
        self.button = button
        self.target = target
    }

    /// The §2.4 step 1 lines for `facts` (`// 一切正常，按 下一步 繼續` when nothing needs attention).
    public static func items(for facts: EnvironmentFacts, home: String = NSHomeDirectory()) -> [DetectItem] {
        let short = { (path: String) in PathText.abbreviate(path, home: home) }
        var items: [DetectItem] = []
        switch facts.claude {
        case .found: break
        case .missing:
            items.append(DetectItem(glyph: "▲", tone: "danger", text: "找不到 claude：先安裝 Claude Code，裝好後按 ↻ 重新偵測。",
                                    button: "↻ 重新偵測", target: nil))
        case .failed(let reason):
            items.append(DetectItem(glyph: "▲", tone: "danger", text: "claude 無法執行（\(reason)）：修好後按 ↻ 重新偵測。",
                                    button: "↻ 重新偵測", target: nil))
        }
        switch facts.cswap {
        case .ready, .loading: break
        case .missing:
            items.append(DetectItem(glyph: "○", tone: "dim",
                                    text: "沒有 cswap：CODD 仍可使用目前登入的帳號；要切換多個帳號再安裝 cswap（0.26 以上）。",
                                    button: "第 5 步 →", target: .accounts))
        case .unsupported(let version):
            items.append(DetectItem(glyph: "○", tone: "dim", text: "cswap \(version) 太舊：要切換多個帳號請更新到 0.26 以上。",
                                    button: "第 5 步 →", target: .accounts))
        case .unreadable(let reason):
            items.append(DetectItem(glyph: "○", tone: "dim", text: "讀不到 cswap 狀態：\(reason)", button: "第 5 步 →", target: .accounts))
        }
        switch facts.hooks {
        case .upToDate, .unknown: break
        case .legacy(_, let file):
            items.append(DetectItem(glyph: "◆", tone: "amber", text: "\(short(file)) 有舊版 CODD web 的 hooks：第 3 步可以預覽並移除。",
                                    button: "第 3 步 →", target: .hooks))
        case .statuslineOutdated(let file):
            items.append(DetectItem(glyph: "◆", tone: "amber", text: "\(short(file)) 的全域狀態列是舊版：第 3 步可以預覽並更新。",
                                    button: "第 3 步 →", target: .hooks))
        case .unreadable(let reason):
            items.append(DetectItem(glyph: "▲", tone: "danger", text: "讀不到 hooks 設定：\(reason)", button: "第 3 步 →", target: .hooks))
        }
        if !facts.dataRoot.writable {
            items.append(DetectItem(glyph: "▲", tone: "danger", text: "資料夾無法寫入：\(short(facts.dataRoot.path))", button: nil, target: nil))
        } else if !facts.dataRoot.mcpRunning {
            items.append(DetectItem(glyph: "○", tone: "dim", text: "MCP 未啟動：hooks 連接埠被占用，claude 暫時讀不到筆記。",
                                    button: "第 4 步 →", target: .notebook))
        }
        if items.isEmpty {
            items.append(DetectItem(glyph: "//", tone: "comment", text: "一切正常，按 下一步 繼續", button: nil, target: nil))
        }
        return items
    }
}
