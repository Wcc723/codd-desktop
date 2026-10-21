import CoddCore
import Foundation

/// A folder the new-session sheet offers: a CODD project (最近) or a folder Claude has used that
/// CODD does not know yet (建議 · 來自 ~/.claude.json).
struct ProjectChoice: Equatable, Sendable {
    var path: String
    var name: String
    /// The project's group color (CODD projects only).
    var tag: TagColor?
    var isKnown: Bool
    var lastUsed: Date?
    /// The project's group (nil: 未分類, or not a CODD project).
    var groupID: GroupID? = nil
    var groupName: String? = nil
    /// Running sessions in it (`2 live`).
    var live = 0

    /// The saved projects of `store` in tree order (transient projects are not CODD's, D6), with
    /// the latest session activity as "last used".
    @MainActor
    static func known(in store: any SessionStore) -> [ProjectChoice] {
        var out: [ProjectChoice] = []
        for group in store.groups {
            for id in group.projectIDs {
                guard let project = store.project(id), !project.isTransient else { continue }
                let sessions = project.sessionIDs.compactMap { store.session($0) }
                let lastUsed = sessions.filter { !$0.external }.map(\.stateSince).max()
                out.append(ProjectChoice(path: HolderSessionStore.standardize(project.cwd), name: project.name,
                                         tag: group.isUngrouped ? nil : group.color, isKnown: true, lastUsed: lastUsed,
                                         groupID: group.isUngrouped ? nil : group.id, groupName: group.isUngrouped ? nil : group.name,
                                         live: sessions.filter { $0.state.isLive }.count))
            }
        }
        return out
    }
}

/// What the ⌘N sheet edits (NewSession artboard, SPEC §7.5, D16 / D18 / D22 / D30). Pure: the
/// sheet draws it, tests drive it. The presenter fills in what it cannot know itself (the launch
/// profiles and Claude's own default model) before the sheet opens.
struct NewSessionForm: Equatable, Sendable {
    /// `開始方式 Start`.
    enum Start: Equatable, Sendable {
        /// `新對話` (`--session-id <sessionID>`).
        case new
        /// `接續先前對話` (`claude --resume <id>`); nil until the picker has a selection.
        case resume(TranscriptChoice?)
        /// `從 Remote Control 啟動` (D22: adds `--remote-control`).
        case remoteControl

        /// `new`, `resume`, `rc` (DEBUG flag and state dump spelling).
        var mode: String {
            switch self {
            case .new: "new"
            case .resume: "resume"
            case .remoteControl: "rc"
            }
        }

        init?(mode: String) {
            switch mode.lowercased() {
            case "new": self = .new
            case "resume": self = .resume(nil)
            case "rc", "remote-control": self = .remoteControl
            default: return nil
            }
        }

        var isResume: Bool {
            if case .resume = self { return true }
            return false
        }
    }

    /// The conversation the resume picker selected.
    struct TranscriptChoice: Equatable, Sendable {
        var id: String
        /// Its title when it has a real one (custom, AI or first prompt), else nil.
        var title: String?
    }

    /// `模型 Model` choices: Claude's aliases, or a typed model.
    enum ModelChoice: String, CaseIterable, Sendable {
        case `default`, opus, sonnet, haiku, other
    }

    var path = ""
    var kind: SessionKind = .claude
    var start: Start = .new
    /// The id the preview shows and the session gets (`--session-id`, lowercase in the command):
    /// generated per sheet, so the copied command is the one that runs (D16 rule of the plan §3).
    var sessionID = UUID()
    /// The claude launch profile (nil: the default one).
    var profileID: String?
    var modelChoice: ModelChoice = .default
    /// `其他…`: the typed model.
    var customModel = ""
    /// `--permission-mode`: `default` (no flag), `acceptEdits`, `plan`, `auto`, or another mode a
    /// profile brought.
    var permissionMode = "default"
    var name = ""
    /// `name` came from the picked transcript (replaced when another one is picked, cleared when
    /// the start is no longer a resume); typing makes it the user's own.
    var nameFromTranscript = false
    var tag: TagColor?
    /// Group of a project created for a new folder (nil = 未分類).
    var groupID: GroupID?
    var advancedOpen = false
    /// The launch profiles and the `model` of `<claudeDir>/settings.json` (D30), from the presenter.
    var profiles = LaunchProfileDocument.seeded
    var settingsModel: String?
    /// D12: the `帳號 Account` select as the account store builds it (follow first).
    var accountOptions: [NewSessionAccountOption] = []
    /// The picked entry (`follow` or an account number).
    var accountOptionID = NewSessionAccountOption.followID

    /// The permission `.seg` (raw values, NewSession artboard `.ns-raw`).
    static let permissionModes = ["default", "acceptEdits", "plan", "auto"]
    /// SPEC §7.5: 5 recent projects and 3 suggestions fit the 300 pt list with its footer.
    static let recentLimit = 5
    static let suggestionLimit = 3

    // MARK: Folder

    /// The folder, `~` expanded and trailing slashes dropped. A relative path stays as typed (and
    /// invalid): it would otherwise resolve against CODD's own working directory.
    var resolvedPath: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return trimmed }
        return HolderSessionStore.standardize(trimmed)
    }

    /// Absolute path given (whether the folder exists is checked when creating).
    var hasFolder: Bool { resolvedPath.hasPrefix("/") }

    /// Ready to create: a folder, and for a resume a picked conversation.
    var isValid: Bool { problem == nil }

    /// Why `建立` cannot run yet (繁體中文), nil when it can.
    var problem: String? {
        guard hasFolder else { return "請先選一個專案資料夾" }
        if kind == .claude, case .resume(nil) = start { return "請先在清單裡選一段要接續的對話" }
        if kind == .claude, modelChoice == .other, let model = JSText.nonBlankTrimmed(customModel),
           !LaunchProfileEditing.isValidModel(model) {
            return Self.invalidModelMessage(model)
        }
        return nil
    }

    /// claude would never start with it (review correctness-3): said before anything is saved.
    static func invalidModelMessage(_ model: String) -> String {
        "模型「\(model)」不正確：不能有空白或控制字元，也不能以 - 開頭。"
    }

    // MARK: Profile, model, permission

    /// The profile that runs: the named claude profile, else the default, else the first claude
    /// one (D5); a shell session runs the first shell profile.
    var profile: LaunchProfile {
        kind == .shell ? profiles.shellProfile : profiles.claudeProfile(id: profileID)
    }

    /// Picks a claude profile; the permission `.seg` follows its default mode.
    mutating func setProfile(_ id: String?) {
        let picked = profiles.claudeProfile(id: id)
        profileID = picked.id
        permissionMode = picked.defaultPermissionMode?.rawValue ?? PermissionMode.default.rawValue
    }

    /// The model a launch profile names on purpose (`預設` then passes it as `--model`); nil for
    /// the built-ins, which name none.
    var profileModel: String? { JSText.nonBlankTrimmed(profile.defaultModel) }

    /// `預設` without a profile model: no `--model`, so Claude Code's own setting (its `model`, or
    /// its default) applies. CODD never picks a model by itself (the fb user note).
    static let followClaudeModelTitle = "預設（跟隨 Claude Code 設定）"

    /// The select's titles: `預設（跟隨 Claude Code 設定）`, or `預設（啟動設定檔：opus）` when the
    /// profile names a model, then the aliases and `其他…`.
    func modelTitle(_ choice: ModelChoice) -> String {
        switch choice {
        case .default: profileModel.map { "預設（啟動設定檔：\($0)）" } ?? Self.followClaudeModelTitle
        case .other: "其他…"
        default: choice.rawValue
        }
    }

    /// The tooltip of the `預設` entry: what it passes, and Claude Code's own `model`
    /// (`<claudeDir>/settings.json`, D30) when it is known.
    var defaultModelHint: String {
        if let model = profileModel { return "啟動設定檔「\(profile.name)」指定 --model \(model)" }
        if let model = JSText.nonBlankTrimmed(settingsModel) { return "不傳 --model：Claude Code 目前設定的模型是 \(model)" }
        return "不傳 --model：由 Claude Code 自己的設定決定模型"
    }

    /// `--model` for the request: nil for `預設` (the profile's model when it names one, else no
    /// flag at all); a picked alias or a typed model otherwise.
    var requestModel: String? {
        switch modelChoice {
        case .default: nil
        case .other: JSText.nonBlankTrimmed(customModel)
        default: modelChoice.rawValue
        }
    }

    /// `--permission-mode` for the request. `default` is passed explicitly only over a profile
    /// that has a mode of its own (then it means "no flag"); nil otherwise.
    var requestPermission: String? {
        if permissionMode == PermissionMode.default.rawValue {
            let profileMode = profile.defaultPermissionMode ?? .default
            return profileMode == .default ? nil : PermissionMode.default.rawValue
        }
        return JSText.nonBlankTrimmed(permissionMode)
    }

    /// The hint under the permission `.seg` (plan §3 copy).
    var permissionHint: String {
        switch permissionMode {
        case "default": "依 Claude 自己的設定（permissions.defaultMode）"
        case "acceptEdits": "acceptEdits：檔案編輯自動接受，Bash 指令仍會詢問"
        case "plan": "plan：只規劃、不改檔，核准計畫後才動手"
        case "auto": "auto：由 Claude 判斷哪些操作需要詢問"
        default: "\(permissionMode)：來自啟動設定檔 \(profile.name)"
        }
    }

    // MARK: Account (D12)

    /// The picked entry when it exists and is enabled, else `跟隨全域登入`.
    var accountOption: NewSessionAccountOption? {
        accountOptions.first { $0.id == accountOptionID && $0.enabled }
            ?? accountOptions.first { $0.id == NewSessionAccountOption.followID }
    }

    /// The select's options changed (an account read): a pick that is gone or disabled falls back
    /// to following the global login.
    mutating func setAccountOptions(_ options: [NewSessionAccountOption]) {
        accountOptions = options
        if !options.contains(where: { $0.id == accountOptionID && $0.enabled }) { accountOptionID = NewSessionAccountOption.followID }
    }

    /// Picks an entry; a disabled one is refused (false).
    @discardableResult
    mutating func pickAccount(_ id: String) -> Bool {
        guard accountOptions.contains(where: { $0.id == id && $0.enabled }) else { return false }
        accountOptionID = id
        return true
    }

    // MARK: Start and name

    /// `建立` with a picked conversation resumes it.
    var resumeID: String? {
        if case .resume(let choice?) = start { return choice.id }
        return nil
    }

    var isRemoteControl: Bool { start == .remoteControl }

    /// The radio changed. Leaving a resume drops a name that came from its transcript.
    mutating func setStart(_ next: Start) {
        guard next != start else { return }
        if !next.isResume, nameFromTranscript {
            name = ""
            nameFromTranscript = false
        }
        start = next
    }

    /// The picker selected a conversation (nil: none, e.g. the folder has none). Its title becomes
    /// the name unless the user typed one (D18; the artboard's name field shows it).
    mutating func pick(_ transcript: TranscriptSummary?) {
        let choice = transcript.map { TranscriptChoice(id: $0.id, title: $0.titleSource == .none ? nil : $0.title) }
        start = .resume(choice)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameFromTranscript {
            if let title = choice?.title {
                name = title
                nameFromTranscript = true
            } else if nameFromTranscript {
                name = ""
                nameFromTranscript = false
            }
        }
    }

    /// The user typed in the name field.
    mutating func setName(_ text: String) {
        guard text != name else { return }
        name = text
        nameFromTranscript = false
    }

    /// `-n` (claude) / the sidebar title.
    var effectiveName: String? { LaunchNames.clean(name) }

    // MARK: Request and preview

    var request: NewSessionRequest {
        var request = NewSessionRequest(cwd: resolvedPath, kind: kind)
        request.name = effectiveName
        request.tag = tag
        request.groupID = groupID
        request.sessionID = sessionID
        guard kind == .claude else { return request }
        request.claude.profileID = profile.id
        request.claude.model = requestModel
        request.claude.permissionMode = requestPermission
        request.claude.accountNumber = accountOption?.accountNumber
        switch start {
        case .new:
            break
        case .resume(let choice):
            if let choice {
                request.claude.mode = .resume(choice.id)
                request.resumeTitle = choice.title
            }
        case .remoteControl:
            request.claude.remoteControl = true
        }
        return request
    }

    /// The black command strip (`claude --session-id 7c1e9a04-… --model … -n "…"`), the argv the
    /// holder will run minus `--settings`; `abbreviated: false` is what the copy button copies.
    func commandPreview(abbreviated: Bool = true) -> String {
        LaunchProfileEditing.commandPreview(
            profile, sessionId: sessionID.uuidString.lowercased(), model: kind == .claude ? requestModel : nil,
            permissionMode: kind == .claude ? requestPermission.map(PermissionMode.init(rawValue:)) : nil,
            name: kind == .claude ? effectiveName : nil, resumeId: kind == .claude ? resumeID : nil,
            remoteControl: kind == .claude && isRemoteControl, abbreviated: abbreviated)
    }

    /// Whether the session will get `--remote-control` (from the start or its profile).
    var passesRemoteControl: Bool {
        kind == .claude && (isRemoteControl || profile.extraArguments.contains(where: HolderLauncher.isRemoteControlFlag))
    }

    /// `launch profile claude-default · env 0 個 · --remote-control 關` (the advanced row's hint).
    var advancedSummary: (profile: String, rest: String) {
        let flag = passesRemoteControl ? "開" : "關"
        return (profile.name, "env \(profile.environment.count) 個 · --remote-control \(flag)")
    }

    // MARK: Destination

    /// `建立後放在 ■ <group> / <project>`, or `未分類 / <folder>` (the footer).
    struct Destination: Equatable, Sendable {
        var tag: TagColor?
        var text: String
        var line: String { "建立後放在 " + (tag == nil ? "" : "■ ") + text }
    }

    /// Where the session will show up: the known project of the folder (its group), else a new
    /// project named after the folder in `groupID`'s group (`groups` gives its name and color).
    func destination(known: [ProjectChoice], groups: [GroupID: (name: String, color: TagColor?)] = [:]) -> Destination? {
        guard hasFolder else { return nil }
        let folder = resolvedPath
        if let project = known.first(where: { HolderSessionStore.standardize($0.path) == folder }) {
            guard let group = project.groupName else { return Destination(tag: nil, text: "未分類 / \(project.name)") }
            return Destination(tag: project.tag, text: "\(group) / \(project.name)")
        }
        let name = HolderSessionStore.projectName(cwd: folder)
        if let id = groupID, let group = groups[id] {
            return Destination(tag: group.color, text: "\(group.name) / \(name)")
        }
        return Destination(tag: nil, text: "未分類 / \(name)")
    }

    // MARK: Keys

    /// `1–8 快速選色` while no text field has focus: 1…8 pick the swatches in order, 0 clears.
    /// nil for any other key.
    static func color(forDigit characters: String) -> TagColor?? {
        guard characters.count == 1, let n = Int(characters) else { return nil }
        if n == 0 { return .some(nil) }
        guard n >= 1, n <= TagColor.allCases.count else { return nil }
        return .some(TagColor.allCases[n - 1])
    }
}
