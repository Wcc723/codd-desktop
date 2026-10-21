import CoddCore
import Foundation

/// What the Settings › 啟動設定檔 editor sheet edits (SPEC §7.12 PROFILES, D5). Pure: text fields
/// in, a `LaunchProfile` plus CoddCore's `LaunchProfileEditing` problems out, each problem with
/// one 繁體中文 message.
struct ProfileEditorForm: Equatable, Sendable {
    /// nil: a new profile (its id is made from the name when saved).
    var id: String?
    var name: String
    var kind: LaunchProfile.Kind
    /// Blank: no `--model` (Claude's own default).
    var model: String
    /// `default` (no flag), `acceptEdits`, `plan`, `auto`, or a mode the file had.
    var permissionMode: String
    /// `--remote-control --verbose`, shell-like quoting (`LaunchProfileEditing.parseArguments`).
    var arguments: String
    /// One `KEY=VALUE` per line.
    var environment: String
    /// Shell profiles: blank = the user's `$SHELL`.
    var shellPath: String
    var makeDefault: Bool
    /// It is the default now (the switch cannot turn that off: another profile has to become the
    /// default instead).
    let wasDefault: Bool
    /// The kind it had when the editor opened (nil for a new one).
    let originalKind: LaunchProfile.Kind?

    static let argumentsHint = "空白分隔，引號可包含空白；--session-id、--resume、--settings、-n、--model、--permission-mode 由 CODD 管理"
    static let environmentHint = "每行一個 KEY=VALUE"
    static let newName = "新設定檔"

    init(profile: LaunchProfile?, document: LaunchProfileDocument) {
        id = profile?.id
        name = profile?.name ?? LaunchProfiles.uniqueName(Self.newName, in: document)
        kind = profile?.kind ?? .claude
        model = profile?.defaultModel ?? ""
        permissionMode = profile?.defaultPermissionMode?.rawValue ?? PermissionMode.default.rawValue
        arguments = LaunchProfileEditing.formatArguments(profile?.extraArguments ?? [])
        environment = LaunchProfileEditing.formatEnvironment(profile?.environment ?? [:])
        shellPath = profile?.shellPath ?? ""
        let isDefault = profile.map { $0.id == document.defaultProfileId } ?? false
        makeDefault = isDefault
        wasDefault = isDefault
        originalKind = profile?.kind
    }

    /// The profile to save and what keeps it from being saved (empty: it can be saved). Fields a
    /// kind does not use are dropped (a shell has no model, mode or flags).
    func build(in document: LaunchProfileDocument) -> (profile: LaunchProfile, issues: [ProfileEditorIssue]) {
        var issues: [ProfileEditorIssue] = []
        var extra: [String] = []
        if kind == .claude {
            switch LaunchProfileEditing.parseArguments(arguments) {
            case .success(let args): extra = args
            case .failure(let issue): issues.append(.profile(issue))
            }
        }
        var env: [String: String] = [:]
        switch LaunchProfileEditing.parseEnvironment(environment) {
        case .success(let parsed): env = parsed
        case .failure(let issue): issues.append(.profile(issue))
        }
        let mode = permissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = LaunchProfile(
            id: id ?? Self.newID(for: name, in: document), name: JSText.trim(name), kind: kind,
            defaultModel: kind == .claude ? JSText.nonBlankTrimmed(model) : nil,
            defaultPermissionMode: kind == .claude && mode != PermissionMode.default.rawValue && !mode.isEmpty
                ? PermissionMode(rawValue: mode) : nil,
            extraArguments: extra, shellPath: kind == .shell ? JSText.nonBlankTrimmed(shellPath) : nil, environment: env)
        issues += LaunchProfileEditing.validate(profile, in: document).map(ProfileEditorIssue.profile)
        // Turning the only claude profile into a shell one would leave ⌘N without claude.
        if originalKind == .claude, kind == .shell, let id,
           !document.profiles.contains(where: { $0.id != id && $0.kind == .claude }) {
            issues.append(.profile(.lastClaudeProfile))
        }
        if kind == .shell, let path = profile.shellPath, !path.hasPrefix("/") {
            issues.append(.relativeShellPath(path))
        }
        return (profile, Self.unique(issues))
    }

    /// The editor's live preview: the command ⌘N would run with this profile and no sheet options.
    func preview(in document: LaunchProfileDocument) -> String {
        LaunchProfileEditing.commandPreview(build(in: document).profile, sessionId: ProfilesSettingsModel.sampleSessionID, model: nil,
                                            permissionMode: nil, name: nil, resumeId: nil, remoteControl: false)
    }

    /// An id for a new profile: the name's ASCII letters and digits (`acct-2`), `profile` when that
    /// has no letter (`帳號 #2`), made unique.
    static func newID(for name: String, in document: LaunchProfileDocument) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if (0x61...0x7A).contains(scalar.value) || (0x30...0x39).contains(scalar.value) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let hasLetter = slug.unicodeScalars.contains { (0x61...0x7A).contains($0.value) }
        return LaunchProfileEditing.uniqueId(hasLetter ? String(slug.prefix(40)) : "profile", in: document)
    }

    private static func unique(_ issues: [ProfileEditorIssue]) -> [ProfileEditorIssue] {
        var out: [ProfileEditorIssue] = []
        for issue in issues where !out.contains(issue) { out.append(issue) }
        return out
    }

    /// One line per problem (繁體中文).
    static func message(_ issue: LaunchProfileIssue) -> String {
        switch issue {
        case .emptyName: "名稱不能空白"
        case .duplicateName: "已經有同名的設定檔"
        case .reservedArgument(let arg):
            "\(arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg) 由 CODD 管理，不能放在額外參數"
        case .invalidModel(let model): "模型「\(model)」不正確：要是一個字，不能以 - 開頭"
        case .invalidPermissionMode(let mode): mode.isEmpty ? "權限模式不能空白" : "權限模式「\(mode)」不正確"
        case .blockedEnvironment(let key): "\(key) 由 CODD 或系統設定，不能放在環境變數"
        case .invalidEnvironmentLine(let line): "看不懂這一行環境變數：\(line)（要寫成 KEY=VALUE）"
        case .unbalancedQuotes: "額外參數的引號沒有成對"
        case .lastClaudeProfile: "至少要保留一個 Claude 設定檔"
        }
    }
}

/// A problem the editor shows under its fields: CoddCore's, or one only the editor checks.
enum ProfileEditorIssue: Equatable, Sendable {
    case profile(LaunchProfileIssue)
    /// A shell profile's path must be absolute (the builder refuses anything else).
    case relativeShellPath(String)

    var message: String {
        switch self {
        case .profile(let issue): ProfileEditorForm.message(issue)
        case .relativeShellPath(let path): "Shell 路徑要是絕對路徑（\(path)）"
        }
    }
}

/// The PROFILES section's rows and preview (Settings artboard 04). Pure.
struct ProfilesSettingsModel: Equatable {
    struct Row: Equatable {
        var id: String
        var glyph: String
        var isClaude: Bool
        var name: String
        /// `CLAUDE` / `SHELL` chip (drawn in caps).
        var kind: String
        var isDefault: Bool
        /// `LaunchProfileEditing.profileCommand`.
        var command: String
        var cwd: String
        var account: String
        var model: String
        var envCount: Int
        /// `cwd 跟隨專案 · 帳號 跟隨全域 · 模型 預設（Claude Code：opus）`.
        var meta: String { "cwd \(cwd) · 帳號 \(account) · 模型 \(model)" }
    }

    var rows: [Row]
    var defaultName: String
    /// The `.term` preview: the default profile with typical ⌘N options.
    var preview: String
    var readOnly: Bool

    /// `7c1e9a04-…` in previews (a sample id; the ⌘N sheet shows the real one).
    static let sampleSessionID = "7c1e9a04-5b6c-4d2e-9f10-2a3b4c5d6e7f"
    /// The ⌘N options the preview shows next to the default profile (SPEC §5 sample).
    static let samplePermission = PermissionMode.acceptEdits
    static let sampleName = "修正登入 API 401"

    /// The model column of a claude profile that names no model: CODD passes no `--model`, so
    /// Claude Code's own setting runs (the ⌘N `預設（跟隨 Claude Code 設定）`, user feedback 2026-10-19);
    /// `預設（Claude Code：opus）` when that setting is known.
    static func followClaudeModelLabel(_ settingsModel: String?) -> String {
        JSText.nonBlankTrimmed(settingsModel).map { "預設（Claude Code：\($0)）" } ?? NewSessionForm.followClaudeModelTitle
    }

    /// - Parameters:
    ///   - settingsModel: Claude's own `model` (D30), named in the model column only (CODD never
    ///     passes it).
    ///   - accountLabel: `跟隨全域` (real mode until M3) or `跟隨全域（#3 工作）`.
    static func build(document: LaunchProfileDocument, settingsModel: String?, accountLabel: String, readOnly: Bool) -> Self {
        let rows = document.profiles.map { profile -> Row in
            let isClaude = profile.kind == .claude
            let model: String
            if !isClaude {
                model = "—"
            } else if let own = JSText.nonBlankTrimmed(profile.defaultModel) {
                model = own
            } else {
                model = followClaudeModelLabel(settingsModel)
            }
            return Row(id: profile.id, glyph: isClaude ? "◆" : "$", isClaude: isClaude, name: profile.name,
                       kind: isClaude ? "Claude" : "Shell", isDefault: profile.id == document.defaultProfileId,
                       command: LaunchProfileEditing.profileCommand(profile), cwd: "跟隨專案",
                       account: isClaude ? accountLabel : "—", model: model, envCount: profile.environment.count)
        }
        let profile = document.defaultProfile ?? document.claudeProfile(id: nil)
        // A typical ⌘N pick (Settings artboard 04) with the ⌘N model `預設`: the argv the launch
        // really builds, so `--model` only when the profile names one (never Claude's own
        // setting, which Claude Code applies by itself).
        let isClaude = profile.kind == .claude
        let preview = LaunchProfileEditing.commandPreview(
            profile, sessionId: sampleSessionID, model: nil, permissionMode: isClaude ? samplePermission : nil,
            name: profile.kind == .claude ? sampleName : nil, resumeId: nil, remoteControl: false)
        return Self(rows: rows, defaultName: profile.name, preview: preview, readOnly: readOnly)
    }
}
