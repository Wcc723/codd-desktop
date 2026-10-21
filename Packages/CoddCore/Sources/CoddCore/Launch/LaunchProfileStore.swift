import Foundation

/// The launch profiles of one data root (D5, `<dataRoot>/profiles.json`).
///
/// Invariant after decoding (``normalized()``): ids are unique and non-blank, at least one claude
/// profile exists, and `defaultProfileId` names an existing profile.
public struct LaunchProfileDocument: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    /// The built-in default (`claude-default`).
    public static let builtInDefaultId = "claude-default"

    public var profiles: [LaunchProfile]
    /// The profile ⌘N and Home preselect (may be a shell profile).
    public var defaultProfileId: String

    public init(profiles: [LaunchProfile], defaultProfileId: String) {
        self.profiles = profiles
        self.defaultProfileId = defaultProfileId
    }

    /// The four built-ins with `claude-default` as the default (what a fresh data root starts with).
    public static var seeded: LaunchProfileDocument {
        LaunchProfileDocument(profiles: LaunchProfile.builtIn, defaultProfileId: builtInDefaultId)
    }

    public func profile(id: String) -> LaunchProfile? { profiles.first { $0.id == id } }

    public var defaultProfile: LaunchProfile? { profile(id: defaultProfileId) }

    /// D5: the profile a claude session launches with: the one it names when that is a claude
    /// profile, else the default when it is one, else the first claude profile. A profile
    /// `LaunchBuilder` would refuse (a hand-edited `--settings`, an invalid model or mode:
    /// ``LaunchProfileEditing/launchIssues(_:)``) is skipped the same way, so a bad profiles.json
    /// never makes every new session fail (review e2e-4); the built-in default is the last resort.
    public func claudeProfile(id: String?) -> LaunchProfile {
        if let id, let p = profile(id: id), p.kind == .claude, Self.isLaunchable(p) { return p }
        if let p = defaultProfile, p.kind == .claude, Self.isLaunchable(p) { return p }
        return profiles.first { $0.kind == .claude && Self.isLaunchable($0) } ?? Self.builtInClaudeDefault
    }

    /// Claude profiles `LaunchBuilder` would refuse to launch (they stay listed for the editor).
    public var unlaunchableProfiles: [LaunchProfile] {
        profiles.filter { $0.kind == .claude && !Self.isLaunchable($0) }
    }

    static func isLaunchable(_ profile: LaunchProfile) -> Bool {
        profile.kind != .claude || LaunchProfileEditing.launchIssues(profile).isEmpty
    }

    /// D5: shell sessions and shell tabs use the first shell profile, else the built-in `zsh`.
    public var shellProfile: LaunchProfile {
        profiles.first { $0.kind == .shell }
            ?? LaunchProfile.builtIn.first { $0.kind == .shell } ?? LaunchProfile(id: "zsh", name: "zsh", kind: .shell)
    }

    static var builtInClaudeDefault: LaunchProfile {
        LaunchProfile.builtIn.first { $0.id == builtInDefaultId }
            ?? LaunchProfile(id: builtInDefaultId, name: builtInDefaultId, kind: .claude)
    }

    /// Repairs a hand-edited or partial document: blank and repeated ids dropped (first wins), the
    /// built-in `claude-default` added back when no claude profile is left (an id that is taken
    /// gets a suffix), and a missing or unknown default replaced by the first claude profile.
    public func normalized() -> LaunchProfileDocument {
        var seen = Set<String>()
        var kept: [LaunchProfile] = []
        for p in profiles where !JSText.trim(p.id).isEmpty && seen.insert(p.id).inserted {
            kept.append(p)
        }
        if !kept.contains(where: { $0.kind == .claude }) {
            var fallback = Self.builtInClaudeDefault
            fallback.id = LaunchProfileEditing.uniqueId(fallback.id, taken: seen)
            kept.insert(fallback, at: 0)
        }
        var defaultId = defaultProfileId
        if !kept.contains(where: { $0.id == defaultId }) {
            defaultId = kept.first { $0.kind == .claude }?.id ?? Self.builtInDefaultId
        }
        return LaunchProfileDocument(profiles: kept, defaultProfileId: defaultId)
    }

    enum CodingKeys: String, CodingKey { case version, defaultProfileId, profiles }

    /// Tolerant: a profile that cannot be read is skipped (``LossyArray``), the rest is repaired by
    /// ``normalized()``. The version is checked by ``LaunchProfileStore/load()``.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = c.lenient(LossyArray<LenientProfile>.self, forKey: .profiles)?.elements.map(\.profile) ?? []
        let defaultId = c.lenient(String.self, forKey: .defaultProfileId) ?? ""
        self = LaunchProfileDocument(profiles: profiles, defaultProfileId: defaultId).normalized()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(defaultProfileId, forKey: .defaultProfileId)
        try c.encode(profiles, forKey: .profiles)
    }
}

/// Reads one stored profile in ``LaunchProfile``'s own key layout, but forgiving about what a hand
/// edit may leave out: a missing optional key takes its default and a missing name the id. A value
/// of the wrong type, a blank id or an unknown kind makes the whole entry unreadable (skipped)
/// rather than silently dropping part of it, e.g. the `--remote-control` of `claude-rc`.
private struct LenientProfile: Decodable {
    var profile: LaunchProfile

    enum Keys: String, CodingKey {
        case id, name, kind, defaultModel, defaultPermissionMode, extraArguments, shellPath, environment
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: Keys) throws -> T? {
            guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
            return try c.decode(T.self, forKey: key)
        }
        let id = try c.decode(String.self, forKey: .id)
        guard !JSText.trim(id).isEmpty, let kind = LaunchProfile.Kind(rawValue: try c.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "blank id or unknown kind")
        }
        profile = LaunchProfile(
            id: id, name: try optional(String.self, .name) ?? id, kind: kind,
            defaultModel: JSText.nonBlankTrimmed(try optional(String.self, .defaultModel)),
            defaultPermissionMode: try optional(String.self, .defaultPermissionMode).flatMap(JSText.nonBlankTrimmed)
                .map(PermissionMode.init(rawValue:)),
            extraArguments: try optional([String].self, .extraArguments) ?? [],
            shellPath: JSText.nonBlankTrimmed(try optional(String.self, .shellPath)),
            environment: try optional([String: String].self, .environment) ?? [:])
    }
}

public enum LaunchProfileStoreError: Error, Sendable, Equatable {
    /// Written by a newer CODD; never overwritten.
    case unsupportedVersion(Int)
    case corrupt(String)
    case io(String)
}

/// `<dataRoot>/profiles.json`: `{"defaultProfileId":…,"profiles":[…],"version":1}` (sorted keys,
/// pretty printed, 0600, atomic). Only the app writes it. Synchronous I/O: call off the main actor.
public struct LaunchProfileStore: Sendable {
    public static let fileName = "profiles.json"
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A missing file is ``LaunchProfileDocument/seeded`` (nothing is written until ``save(_:)``).
    /// Bad entries are skipped and the rest repaired (``LaunchProfileDocument/normalized()``); a
    /// file from a newer version throws ``LaunchProfileStoreError/unsupportedVersion(_:)`` and must
    /// not be saved over; an unreadable one throws ``LaunchProfileStoreError/corrupt(_:)`` (see
    /// ``moveAside(now:)``).
    public func load() throws(LaunchProfileStoreError) -> LaunchProfileDocument {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .seeded
        } catch {
            throw .io(String(describing: error))
        }
        guard let object = JSONValue.parse(data)?.objectValue else { throw .corrupt("not a JSON object") }
        guard let version = object["version"]?.exactIntegerValue else { throw .corrupt("missing version") }
        guard version <= LaunchProfileDocument.currentVersion else { throw .unsupportedVersion(version) }
        guard version >= 1 else { throw .corrupt("invalid version \(version)") }
        do {
            return try JSONDecoder().decode(LaunchProfileDocument.self, from: data)
        } catch {
            throw .corrupt(String(describing: error))
        }
    }

    /// Writes `document` as given (callers edit through ``LaunchProfileEditing``). Refuses to replace
    /// a file of a newer version, like ``LayoutStore/save(_:)``.
    public func save(_ document: LaunchProfileDocument) throws(LaunchProfileStoreError) {
        if let existing = try? Data(contentsOf: fileURL),
           let version = JSONValue.parse(existing)?["version"]?.exactIntegerValue, version > LaunchProfileDocument.currentVersion {
            throw .unsupportedVersion(version)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw .corrupt(String(describing: error))
        }
        do {
            try AtomicFile.write(data, to: fileURL)
        } catch {
            throw .io(String(describing: error))
        }
    }

    /// Renames an unreadable file aside (`profiles.json.corrupt-<epoch-ms>`) so a fresh one can be
    /// saved without losing the original. Returns the new location.
    @discardableResult
    public func moveAside(now: Date = Date()) throws -> URL {
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(JSDate.milliseconds(now))")
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }
}

/// Problems the profile editor (Settings › 啟動設定檔) reports before saving. `Error` only so it
/// can be the failure of the parsers' `Result`.
public enum LaunchProfileIssue: Error, Sendable, Equatable {
    case emptyName
    /// Another profile has the same name (case-insensitive).
    case duplicateName
    /// A flag CODD sets itself (``LaunchBuilder/reservedFlags``).
    case reservedArgument(String)
    case invalidModel(String)
    case invalidPermissionMode(String)
    /// A variable profiles may not set (`PATH`, `DYLD_*`, `CODD_*`, …).
    case blockedEnvironment(String)
    case invalidEnvironmentLine(String)
    case unbalancedQuotes
    /// Removing it would leave no claude profile.
    case lastClaudeProfile
}

/// Pure helpers behind the profile editor, the ⌘N command strip and the Settings rows.
public enum LaunchProfileEditing {
    /// Everything that would make ``LaunchBuilder`` refuse the profile or silently drop part of it,
    /// in a stable order (name, arguments, model, mode, environment by name).
    public static func validate(_ profile: LaunchProfile, in document: LaunchProfileDocument) -> [LaunchProfileIssue] {
        var issues: [LaunchProfileIssue] = []
        let name = JSText.trim(profile.name)
        if name.isEmpty {
            issues.append(.emptyName)
        } else if document.profiles.contains(where: {
            $0.id != profile.id && JSText.trim($0.name).caseInsensitiveCompare(name) == .orderedSame
        }) {
            issues.append(.duplicateName)
        }
        if profile.kind == .claude {
            for arg in profile.extraArguments {
                let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
                if LaunchBuilder.reservedFlags.contains(flag) { issues.append(.reservedArgument(arg)) }
            }
            if let raw = profile.defaultModel, let model = JSText.nonBlankTrimmed(raw), !isToken(model) {
                issues.append(.invalidModel(raw))
            }
            if let mode = profile.defaultPermissionMode, mode != .default, mode.rawValue.isEmpty || !isToken(mode.rawValue) {
                issues.append(.invalidPermissionMode(mode.rawValue))
            }
        }
        for key in profile.environment.keys.sorted() {
            let value = profile.environment[key] ?? ""
            if !SpawnEnvironmentBuilder.isValidName(key) || value.contains("\0") {
                issues.append(.invalidEnvironmentLine("\(key)=\(value)"))
            } else if !SpawnEnvironmentBuilder.isAllowedOverride(key) {
                issues.append(.blockedEnvironment(key))
            }
        }
        return issues
    }

    /// The issues of ``validate(_:in:)`` that make ``LaunchBuilder`` refuse a claude profile (a
    /// reserved argument, an invalid model or permission mode); name problems and environment
    /// names it drops do not stop a launch. Empty for a shell profile.
    public static func launchIssues(_ profile: LaunchProfile) -> [LaunchProfileIssue] {
        guard profile.kind == .claude else { return [] }
        let alone = LaunchProfileDocument(profiles: [profile], defaultProfileId: profile.id)
        return validate(profile, in: alone).filter { issue in
            switch issue {
            case .reservedArgument, .invalidModel, .invalidPermissionMode: true
            default: false
            }
        }
    }

    private static func isToken(_ value: String) -> Bool {
        (try? LaunchBuilder.validateToken(value, flag: "")) != nil
    }

    /// A model `LaunchBuilder` takes for `--model`: no whitespace or control characters and no
    /// leading `-` (a blank one means no flag and is fine). The ⌘N sheet checks a typed model
    /// with it, so a session is never saved with a model it could never launch.
    public static func isValidModel(_ value: String?) -> Bool {
        guard let model = JSText.nonBlankTrimmed(value) else { return true }
        return isToken(model)
    }

    // MARK: - Arguments

    /// Shell-like words: whitespace separates; `'…'` is literal; `"…"` groups with `\"`, `\\`, `\$`
    /// and `` \` `` escaped; outside quotes a backslash escapes the next character (and a backslash
    /// before a line break joins the lines). Adjacent parts form one word (`--x="a b"`).
    public static func parseArguments(_ text: String) -> Result<[String], LaunchProfileIssue> {
        enum Quote { case none, single, double }
        let chars = Array(text)
        var args: [String] = []
        var current = ""
        var inWord = false
        var quote = Quote.none
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch quote {
            case .none:
                if c == "\\" {
                    if i + 1 < chars.count {
                        i += 1
                        if !(chars[i] == "\n" || chars[i] == "\r\n" || chars[i] == "\r") {
                            current.append(chars[i])
                            inWord = true
                        }
                    } else {
                        current.append(c)
                        inWord = true
                    }
                } else if c.isWhitespace {
                    if inWord { args.append(current) }
                    current = ""
                    inWord = false
                } else if c == "'" {
                    quote = .single
                    inWord = true
                } else if c == "\"" {
                    quote = .double
                    inWord = true
                } else {
                    current.append(c)
                    inWord = true
                }
            case .single:
                if c == "'" { quote = .none } else { current.append(c) }
            case .double:
                if c == "\"" {
                    quote = .none
                } else if c == "\\", i + 1 < chars.count, doubleQuoteEscapable.contains(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                } else {
                    current.append(c)
                }
            }
            i += 1
        }
        guard quote == .none else { return .failure(.unbalancedQuotes) }
        if inWord { args.append(current) }
        return .success(args)
    }

    private static let doubleQuoteEscapable: Set<Character> = ["\"", "\\", "$", "`"]

    /// The inverse of ``parseArguments(_:)``, also safe to paste into zsh: plain words stay bare,
    /// others are double-quoted, or single-quoted when they hold `"`, `\`, `$`, `` ` `` or `!`.
    public static func formatArguments(_ args: [String]) -> String {
        args.map(quoted).joined(separator: " ")
    }

    static func quoted(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        if !arg.hasPrefix("="), arg.unicodeScalars.allSatisfy(isBare) { return arg }
        if !arg.contains(where: { "\"\\$`!".contains($0) }) { return "\"" + arg + "\"" }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Letters and digits of any script plus `- _ . / : , + @ % =` (no glob, quote, history,
    /// tilde or comment characters).
    private static func isBare(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII {
            return (0x30...0x39).contains(s.value) || (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
                || "-_./:,+@%=".unicodeScalars.contains(s)
        }
        return s.properties.isAlphabetic || s.properties.numericType != nil
    }

    // MARK: - Environment

    /// One `KEY=VALUE` per line; blank lines and `#` comments skipped, a leading `export ` allowed,
    /// whitespace around key and value trimmed, one pair of matching surrounding quotes removed.
    /// A line without `=`, with an empty or invalid key, or with a NUL is reported as is.
    public static func parseEnvironment(_ text: String) -> Result<[String: String], LaunchProfileIssue> {
        var env: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = JSText.trim(String(raw))
            if line.isEmpty || line.hasPrefix("#") { continue }
            var body = Substring(line)
            if body.hasPrefix("export "), body.contains("=") { body = body.dropFirst(7) }
            guard let eq = body.firstIndex(of: "=") else { return .failure(.invalidEnvironmentLine(line)) }
            let key = JSText.trim(String(body[..<eq]))
            var value = JSText.trim(String(body[body.index(after: eq)...]))
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, SpawnEnvironmentBuilder.isValidName(key), !value.contains("\0") else {
                return .failure(.invalidEnvironmentLine(line))
            }
            env[key] = value
        }
        return .success(env)
    }

    /// The editor text for an environment (sorted `KEY=VALUE` lines; a value with surrounding
    /// whitespace or quotes is double-quoted so ``parseEnvironment(_:)`` reads it back unchanged).
    public static func formatEnvironment(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { key in
            let value = environment[key] ?? ""
            let needsQuotes = value != JSText.trim(value) || value.hasPrefix("\"") || value.hasPrefix("'")
            return "\(key)=" + (needsQuotes ? "\"\(value)\"" : value)
        }.joined(separator: "\n")
    }

    // MARK: - Previews

    /// What the ⌘N command strip and Settings › Preview show: the argv ``LaunchBuilder`` produces
    /// for the request, minus `--settings` (the hooks) and with the claude path shown as `claude`.
    /// Ids are abbreviated (`7c1e9a04-…`) unless `abbreviated` is false (the copy button); a
    /// missing session id shows `<new>`. `remoteControl` (D22) adds `--remote-control` once.
    public static func commandPreview(_ profile: LaunchProfile, sessionId: String?, model: String?, permissionMode: PermissionMode?,
                                      name: String?, resumeId: String?, remoteControl: Bool, abbreviated: Bool = true) -> String {
        switch profile.kind {
        case .shell:
            return shellName(profile) + " -l"
        case .claude:
            func shown(_ id: String) -> String { abbreviated ? abbreviatedId(id) : id }
            var parts = ["claude"]
            if let resume = JSText.nonBlankTrimmed(resumeId) {
                parts += ["--resume", shown(resume)]
            } else {
                let id = JSText.nonBlankTrimmed(sessionId).map { UUID(uuidString: $0) != nil ? $0.lowercased() : $0 }
                parts += ["--session-id", id.map(shown) ?? "<new>"]
            }
            if let model = JSText.nonBlankTrimmed(model ?? profile.defaultModel) { parts += ["--model", quoted(model)] }
            if let mode = permissionMode ?? profile.defaultPermissionMode, mode != .default {
                parts += ["--permission-mode", quoted(mode.rawValue)]
            }
            if let name = LaunchBuilder.cleanName(name) {
                parts.append(name.hasPrefix("-") ? "--name=" + doubleQuoted(name) : "-n " + doubleQuoted(name))
            }
            if !profile.extraArguments.isEmpty { parts.append(formatArguments(profile.extraArguments)) }
            if remoteControl, !profile.extraArguments.contains(where: { $0 == "--remote-control" || $0.hasPrefix("--remote-control=") }) {
                parts.append("--remote-control")
            }
            return parts.joined(separator: " ")
        }
    }

    /// The profile's own command for the Settings rows: `claude`, `claude --permission-mode plan`,
    /// `claude --remote-control`, `zsh`.
    public static func profileCommand(_ profile: LaunchProfile) -> String {
        switch profile.kind {
        case .shell:
            return shellName(profile)
        case .claude:
            var parts = ["claude"]
            if let model = JSText.nonBlankTrimmed(profile.defaultModel) { parts += ["--model", quoted(model)] }
            if let mode = profile.defaultPermissionMode, mode != .default { parts += ["--permission-mode", quoted(mode.rawValue)] }
            if !profile.extraArguments.isEmpty { parts.append(formatArguments(profile.extraArguments)) }
            return parts.joined(separator: " ")
        }
    }

    /// `7c1e9a04-5b6c-…` style: a UUID-shaped id → its first 8 characters + `-…`; another id longer
    /// than 12 characters → first 8 + `…`; anything else unchanged.
    public static func abbreviatedId(_ id: String) -> String {
        if isUUIDShaped(id) { return String(id.prefix(8)) + "-…" }
        if id.count > 12 { return String(id.prefix(8)) + "…" }
        return id
    }

    static func isUUIDShaped(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard b == 0x2D else { return false }
            } else {
                guard (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b) else { return false }
            }
        }
        return true
    }

    private static func shellName(_ profile: LaunchProfile) -> String {
        profile.shellPath.flatMap { JSText.nonBlankTrimmed(($0 as NSString).lastPathComponent) } ?? "zsh"
    }

    /// `"…"` with `\`, `"`, `$` and `` ` `` escaped (the `-n` name in previews).
    private static func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for c in s {
            if doubleQuoteEscapable.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out + "\""
    }

    // MARK: - Editing

    /// Removes profile `id`. Refuses (returns ``LaunchProfileIssue/lastClaudeProfile``) when it is
    /// the only claude profile; when it was the default, the first remaining claude profile becomes
    /// the default. An unknown id changes nothing.
    public static func remove(_ id: String, from document: inout LaunchProfileDocument) -> LaunchProfileIssue? {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else { return nil }
        if document.profiles[index].kind == .claude,
           !document.profiles.enumerated().contains(where: { $0.offset != index && $0.element.kind == .claude }) {
            return .lastClaudeProfile
        }
        document.profiles.remove(at: index)
        if !document.profiles.contains(where: { $0.id == document.defaultProfileId }),
           let first = document.profiles.first(where: { $0.kind == .claude }) {
            document.defaultProfileId = first.id
        }
        return nil
    }

    /// An id for a new or copied profile: `base` when free, else `base-2`, `base-3`, …
    public static func uniqueId(_ base: String, in document: LaunchProfileDocument) -> String {
        uniqueId(base, taken: Set(document.profiles.map(\.id)))
    }

    static func uniqueId(_ base: String, taken: Set<String>) -> String {
        let stem = JSText.nonBlankTrimmed(base) ?? "profile"
        guard taken.contains(stem) else { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }
}
