import AppKit
import CoddClaudeSettings
import CoddCore
import CoddDialogsUI
import CoddHooks
import Foundation
import Observation

/// Where Claude Code's user-scope registration is written (D22, D37): `<claudeDir>/../.claude.json`
/// (`~/.claude.json`) on the standard data root only. Any other root writes nothing unless DEBUG
/// `-codd-claude-json <file>` names a file, and that file is refused before it is ever read when it
/// resolves (lexically, through symlinks, a dangling link through its destination) into the real
/// home's `.claude.json`, `.claude/` or `.claude-swap-backup/` (M3's A13 guard rule).
enum MCPRegistrationTarget: Equatable, Sendable {
    case file(URL)
    case disabled(String)

    static let testRootReason = "測試資料根目錄不會寫入 ~/.claude.json"

    var file: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    var disabledReason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }

    static func resolve(standardRoot: Bool, claudeDirectory: ClaudeDirectory, debugFile: String?,
                        home: String = RealModeOptions.realHome) -> MCPRegistrationTarget {
        if let debugFile {
            if let reason = RealModeOptions.protectedPathReason(debugFile, home: home) {
                return .disabled("-codd-claude-json 被拒絕：\(reason)")
            }
            return .file(URL(fileURLWithPath: (debugFile as NSString).standardizingPath))
        }
        guard standardRoot else { return .disabled(testRootReason) }
        return .file(MCPService.globalConfigURL(claudeDirectory: claudeDirectory))
    }
}

/// D22 / D23 (M4 I2b): CODD's MCP server registered into Claude Code's user scope through
/// CoddClaudeSettings' `ClaudeUserConfigMCPInstaller` (plan → dialog B → `套用並備份` under
/// Claude's own lock, the edit rebased onto bytes Claude rewrote meanwhile, refused only when
/// `mcpServers` itself changed since the preview), the same for `移除`; the Codex snippet (CODD
/// never writes `~/.codex`); and the external MCP token's rotation (config.json first, then the
/// running hook server, so old note URLs and registered clients stop working at once).
/// Blocking file work runs off the main actor. Never a token in a log or the dump.
@MainActor @Observable
final class MCPRegistrationService {
    enum Kind: String, Sendable {
        case register = "claude-code"
        case remove
    }

    enum Failure: Error, Equatable, Sendable {
        /// Nothing can be planned (a test root, the hook server not up, no MCP token yet).
        case unavailable(String)
        case installer(ClaudeUserConfigMCPError)
    }

    struct PlanFacts: Equatable, Sendable {
        var kind: Kind
        var added: Int
        var removed: Int
        var upToDate: Bool
        var backupName: String
        var summary: String
        /// The dialog's diff lines (`+` / `-` / `  ` / `@@` / `…` prefixed), the token already `••••`
        /// from C10: the dump shows what the dialog would, so the e2e can check the masking.
        var diff: [String] = []
    }

    struct AppliedFacts: Equatable, Sendable {
        var kind: Kind
        var backup: String?
        var wrote: Bool
        var at: Date
    }

    static let serverName = "codd"
    static let codexTitle = "註冊到 Codex"
    /// CODE-3: the snippet carries the external token, so the file it goes into should be the
    /// user's alone.
    static let codexMessage = "把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）。內含 token，存檔後執行 "
        + "chmod 600 ~/.codex/config.toml，不讓其他帳號讀取"
    static let rotateQuestion = "輪替 token？"
    static let rotateDetail = "已註冊的 client 需要重新註冊，舊的筆記網址會失效。"

    let target: MCPRegistrationTarget
    @ObservationIgnored let backupsIndex: URL?
    @ObservationIgnored private weak var holders: HolderSessionStore?
    @ObservationIgnored private weak var mcp: MCPService?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let log: @MainActor (String) -> Void
    /// DEBUG `-codd-mcp-register-apply-delay`: the wait between the preview and the write (the
    /// rebase / changed-since checks get a window for another writer).
    @ObservationIgnored var applyDelayMilliseconds = 0
    @ObservationIgnored var lockWait: Duration = .seconds(3)

    private(set) var lastPlan: PlanFacts?
    private(set) var lastApplied: AppliedFacts?
    /// The last refusal, in 繁體中文 (the dump and the toast).
    private(set) var lastError: String?
    private(set) var tokenRotatedAt: Date?
    private(set) var isApplying = false
    private(set) var isRotating = false

    init(target: MCPRegistrationTarget, backupsIndex: URL?, holders: HolderSessionStore?, mcp: MCPService?,
         clock: @escaping @Sendable () -> Date = { Date() }, log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.target = target
        self.backupsIndex = backupsIndex
        self.holders = holders
        self.mcp = mcp
        self.clock = clock
        self.log = log
    }

    // MARK: Facts for the rows

    /// The MCP URL and the external token registrations carry (§3.12), or why there are none.
    private var endpoint: Result<(url: String, token: String), Failure> {
        guard let url = mcp?.url else { return .failure(.unavailable("hook server 尚未啟動，無法註冊")) }
        guard let token = holders?.hooks?.config?.mcpToken else { return .failure(.unavailable("MCP token 尚未建立")) }
        return .success((url, token))
    }

    /// Why Claude Code's `註冊` / `移除` cannot be pressed now (nil: it can).
    var claudeCodeReason: String? {
        if let reason = target.disabledReason { return reason }
        if isApplying { return "正在寫入 ~/.claude.json…" }
        if case .failure(.unavailable(let reason)) = endpoint { return reason }
        return nil
    }

    /// Why Codex's `註冊` cannot open its snippet now.
    var codexReason: String? {
        if case .failure(.unavailable(let reason)) = endpoint { return reason }
        return nil
    }

    var canRotate: Bool { holders?.hooks?.config?.mcpToken != nil && !isRotating }

    /// `~/.claude.json` as the dialog and the toasts name it (a test file: its short path).
    var displayPath: String {
        guard let file = target.file else { return "~/.claude.json" }
        return ClaudeSettingsService.questionPath(HolderSessionStore.abbreviate(file.path))
    }

    private func installer(_ file: URL) -> ClaudeUserConfigMCPInstaller {
        ClaudeUserConfigMCPInstaller(file: file, backupsIndex: backupsIndex, clock: clock, lockWait: lockWait)
    }

    // MARK: Plan and apply (D22)

    /// The plan for `kind` (read only). `remove` removes the entry that points at this endpoint
    /// (the one named `codd` first), else the one named `codd`.
    func plan(_ kind: Kind) async -> Result<ClaudeUserConfigMCPPlan, Failure> {
        guard let file = target.file else { return fail(.unavailable(target.disabledReason ?? MCPRegistrationTarget.testRootReason)) }
        let ends: (url: String, token: String)
        switch endpoint {
        case .success(let value): ends = value
        case .failure(let failure): return fail(failure)
        }
        let installer = installer(file)
        let serverName = Self.serverName
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ClaudeUserConfigMCPPlan, ClaudeUserConfigMCPError> in
            do throws(ClaudeUserConfigMCPError) {
                switch kind {
                case .register:
                    return .success(try installer.plan(.register(name: serverName, url: ends.url, token: ends.token)))
                case .remove:
                    let inspection = try installer.inspect(ourURL: ends.url, token: ends.token)
                    let name = inspection.codd.map(\.name) ?? serverName
                    return .success(try installer.plan(.remove(name: name)))
                }
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let plan):
            lastPlan = PlanFacts(kind: kind, added: plan.addedLines, removed: plan.removedLines, upToDate: plan.upToDate,
                                 backupName: plan.backupName, summary: plan.summary, diff: Self.diffText(plan.diff))
            lastError = nil
            log("mcp register-plan action=\(kind.rawValue) added=\(plan.addedLines) removed=\(plan.removedLines) upToDate=\(plan.upToDate)")
            return .success(plan)
        case .failure(let error):
            return fail(.installer(error))
        }
    }

    /// `套用並備份`: writes the previewed plan (C10 takes Claude's lock and rebases or refuses).
    func apply(_ plan: ClaudeUserConfigMCPPlan) async -> Result<ClaudeUserConfigMCPResult, Failure> {
        guard let file = target.file else { return fail(.unavailable(target.disabledReason ?? MCPRegistrationTarget.testRootReason)) }
        guard !isApplying else { return fail(.unavailable("正在寫入 ~/.claude.json…")) }
        isApplying = true
        defer { isApplying = false }
        if applyDelayMilliseconds > 0 {
            log("mcp register-apply waiting ms=\(applyDelayMilliseconds)")
            try? await Task.sleep(for: .milliseconds(applyDelayMilliseconds))
        }
        let kind = Self.kind(of: plan.action)
        let installer = installer(file)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ClaudeUserConfigMCPResult, ClaudeUserConfigMCPError> in
            do throws(ClaudeUserConfigMCPError) {
                return .success(try installer.apply(plan))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let applied):
            lastApplied = AppliedFacts(kind: kind, backup: applied.backup?.lastPathComponent, wrote: applied.wrote, at: clock())
            lastError = nil
            if let indexError = applied.indexError { log("error mcp register backups index: \(indexError)") }
            log("mcp register-apply action=\(kind.rawValue) wrote=\(applied.wrote) backup=\(applied.backup?.lastPathComponent ?? "-") "
                + "tightened=\(applied.tightened)")
            await mcp?.refreshRegistrations(force: true)
            return .success(applied)
        case .failure(let error):
            return fail(.installer(error))
        }
    }

    private func fail<T>(_ failure: Failure) -> Result<T, Failure> {
        let text = Self.message(failure)
        lastError = text
        log("mcp register refused (\(Self.errorKind(failure)))")
        return .failure(failure)
    }

    static func kind(of action: ClaudeUserConfigMCPAction) -> Kind {
        switch action {
        case .register: .register
        case .remove: .remove
        }
    }

    /// The toast after a write (`modeOnly`: a tighten-only plan, CODE-3).
    func successText(_ kind: Kind, backup: String?, modeOnly: Bool = false) -> String {
        if modeOnly { return "已把含 token 的檔案改成 0600（\(displayPath)）" }
        let verb = kind == .register ? "已註冊到 Claude Code（\(displayPath)）" : "已從 Claude Code 移除（\(displayPath)）"
        return verb + (backup.map { " · 備份 \($0)" } ?? "")
    }

    /// The brief's 繁體中文 texts for every refusal.
    static func message(_ failure: Failure) -> String {
        switch failure {
        case .unavailable(let reason): reason
        case .installer(let error):
            switch error {
            case .lockBusy: "Claude Code 正在寫入 ~/.claude.json，請稍後再試"
            case .missingFile: "找不到 ~/.claude.json，請先執行一次 claude"
            case .changedSinceRead: "~/.claude.json 的 mcpServers 在預覽後被改過，請重新預覽"
            case .staleLock(let text): text
            case .invalidJSON(let position): "~/.claude.json 不是有效的 JSON（\(position)），CODD 不會修改它"
            case .notAnObject: "~/.claude.json 的 mcpServers 不是物件，CODD 不會修改它"
            case .io(let detail): "無法寫入 ~/.claude.json（\(detail)）"
            }
        }
    }

    /// The log's / dump's word for a refusal (never a path or a token).
    static func errorKind(_ failure: Failure) -> String {
        switch failure {
        case .unavailable: "unavailable"
        case .installer(let error):
            switch error {
            case .lockBusy: "lockBusy"
            case .missingFile: "missingFile"
            case .changedSinceRead: "changedSinceRead"
            case .staleLock: "staleLock"
            case .invalidJSON: "invalidJSON"
            case .notAnObject: "notAnObject"
            case .io: "io"
            }
        }
    }

    /// Dialog B for a plan: `預覽 ~/.claude.json 變更`, the plan's summary, the `mcpServers` diff
    /// (other servers elided, the token `••••`), the backup it will take.
    /// The plan's diff as text lines for the dump (C10 already masks the token and secrets).
    static func diffText(_ lines: [DiffLine]) -> [String] {
        lines.map { line in
            switch line.kind {
            case .hunk, .elided: line.text
            case .context: "  " + line.text
            case .added: "+ " + line.text
            case .removed: "- " + line.text
            }
        }
    }

    func diffModel(_ plan: ClaudeUserConfigMCPPlan) -> HookDiffModel {
        let lines = plan.diff.map { line -> DiffLineModel in
            let kind: DiffLineModel.Kind = switch line.kind {
            case .hunk: .hunk
            case .context: .context
            case .added: .added
            case .removed: .removed
            case .elided: .elided
            }
            return DiffLineModel(kind, oldNumber: line.oldNumber, newNumber: line.newNumber, text: line.text)
        }
        let full = target.file.map { HolderSessionStore.abbreviate($0.path) } ?? "~/.claude.json"
        let directory = (full as NSString).deletingLastPathComponent
        let backup = plan.upToDate || plan.modeOnly ? "" : (directory.isEmpty ? plan.backupName : directory + "/" + plan.backupName)
        let applyTitle = plan.modeOnly ? "收緊權限" : Self.kind(of: plan.action) == .remove ? "移除並備份" : HookDiffModel.defaultApplyTitle
        // CODE-3: a file or backup written 0600 because it holds the token says so; a tighten-only
        // plan has no diff but can be applied.
        let summary = [plan.summary] + (plan.modeNote.map { [$0] } ?? [])
        return HookDiffModel(settingsPath: displayPath, summary: summary, lines: lines, added: plan.addedLines,
                             removed: plan.removedLines, backupPath: backup, canApply: !plan.upToDate, applyTitle: applyTitle,
                             dialogTitle: "MCP 註冊 · 預覽變更", footerNote: "只動 mcpServers 裡的 codd，其他設定不碰",
                             noChangesText: plan.modeOnly ? "// mcpServers 已是最新，只改檔案權限" : "// 沒有需要變更的地方：mcpServers 已是最新",
                             appliesWithoutDiff: plan.modeOnly)
    }

    // MARK: Codex (D22)

    /// The `config.toml` snippet (§3.12), or nil while there is no endpoint or token.
    func codexSnippet() -> String? {
        guard case .success(let ends) = endpoint else { return nil }
        return CodexMCPSnippet.toml(url: ends.url, token: ends.token)
    }

    // MARK: Token rotation (D23)

    /// `輪替` (after the confirmation): a new external token in config.json, applied to the running
    /// server; per-session tokens stay (they derive from the hook token). Nil on success, else why.
    @discardableResult
    func rotateToken() async -> String? {
        guard let hooks = holders?.hooks else { return "hook server 尚未啟動" }
        guard !isRotating else { return "token 正在輪替" }
        isRotating = true
        defer { isRotating = false }
        if let error = await hooks.rotateMCPToken() {
            lastError = "無法輪替 token（\(error)）"
            return lastError
        }
        tokenRotatedAt = clock()
        await mcp?.refreshRegistrations()
        return nil
    }

    // MARK: Dump (§6 `registration`; never a token)

    var dumpObject: [String: Any] {
        var claude: [String: Any] = ["state": mcp.map { MCPService.registrationName($0.claudeCode) } ?? "unknown",
                                     "target": target.file != nil ? "file" : "disabled",
                                     "enabled": claudeCodeReason == nil]
        if let reason = target.disabledReason { claude["reason"] = reason }
        if let plan = lastPlan {
            claude["plan"] = ["action": plan.kind.rawValue, "added": plan.added, "removed": plan.removed, "upToDate": plan.upToDate,
                              "backupName": plan.backupName, "summary": plan.summary, "diff": plan.diff]
        } else {
            claude["plan"] = NSNull()
        }
        if let applied = lastApplied {
            claude["applied"] = ["action": applied.kind.rawValue, "backup": applied.backup.map { $0 as Any } ?? NSNull(),
                                 "wrote": applied.wrote, "at": JSDate.isoString(applied.at)]
        } else {
            claude["applied"] = NSNull()
        }
        claude["error"] = lastError.map { $0 as Any } ?? NSNull()
        return ["claudeCode": claude, "codexEnabled": codexReason == nil,
                "tokenRotatedAt": tokenRotatedAt.map { JSDate.isoString($0) as Any } ?? NSNull()]
    }
}

/// Dialog B for one registration plan (`註冊` / `移除` / re-register after a rotation), a sheet on
/// the window the button was in. Written only by `套用並備份`; a refusal closes the dialog and
/// says why in a toast (the brief's texts), the inspection is read again either way.
@MainActor
final class MCPRegistrationDialog {
    let service: MCPRegistrationService
    let kind: MCPRegistrationService.Kind
    var onToast: ((String) -> Void)?
    var onFinish: (() -> Void)?
    private(set) var plan: ClaudeUserConfigMCPPlan?
    private(set) var view: HookDiffDialogView?
    private(set) var sheet: NSWindow?

    init(service: MCPRegistrationService, kind: MCPRegistrationService.Kind) {
        self.service = service
        self.kind = kind
    }

    /// Plans (off the main actor), then shows the sheet; a plan that cannot be made is a toast.
    func present(on window: NSWindow) async {
        switch await service.plan(kind) {
        case .success(let plan):
            self.plan = plan
            let view = HookDiffDialogView(model: service.diffModel(plan), onApply: { [weak self] in self?.applyPressed() },
                                          onCancel: { [weak self] in self?.close() })
            self.view = view
            sheet = DialogPresenter.presentSheet(view, on: window)
        case .failure(let failure):
            onToast?(MCPRegistrationService.message(failure))
            close()
        }
    }

    func applyPressed() {
        guard let plan, !plan.upToDate, !service.isApplying else { return }
        Task { [weak self] in await self?.apply(plan) }
    }

    func apply(_ plan: ClaudeUserConfigMCPPlan) async {
        switch await service.apply(plan) {
        case .success(let result):
            onToast?(service.successText(kind, backup: result.backup?.lastPathComponent, modeOnly: plan.modeOnly))
        case .failure(let failure):
            onToast?(MCPRegistrationService.message(failure))
        }
        close()
    }

    func close() {
        if let sheet { DialogPresenter.dismiss(sheet) }
        sheet = nil
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}
