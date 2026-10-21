import Foundation

/// A dotted path or value ``CoddPreferences/set(_:atPath:)`` cannot take.
public enum PreferencesPathError: Error, Sendable, Equatable {
    /// No leaf has this path (a group such as `general.hotkey` is not a leaf).
    case unknownPath(String)
    /// The value has the wrong form or is not one of the row's options.
    case invalidValue(path: String, value: String)
    /// ``CoddPreferences/apply(assignment:)`` got text without `=`.
    case malformedAssignment(String)
}

// MARK: - Dotted paths (DEBUG `-codd-set-pref`, the e2e, the state dump)

extension CoddPreferences {
    /// Every leaf in file order, e.g. `sessions.staleAfterSeconds`, `general.hotkey.keyCode`.
    public static var leafPaths: [String] { CoddPreferences.fields.flatMap(\.leafPaths) }

    /// The leaf at `path` as text: `true` / `false`, numbers, strings, enum raw values, `nil`
    /// for an empty optional, ISO 8601 for dates, comma-joined lists. nil for an unknown path.
    public func value(atPath path: String) -> String? {
        value(at: path.split(separator: ".", omittingEmptySubsequences: false)[...])
    }

    /// Sets the leaf at `path` from text in the form ``value(atPath:)`` returns (booleans also
    /// take `YES` / `NO` / `1` / `0`, enums any letter case, optionals `nil` or `null`). Ranged
    /// numbers are clamped like on load; a value outside a select row's options is refused.
    public mutating func set(_ value: String, atPath path: String) throws(PreferencesPathError) {
        switch assign(value, at: path.split(separator: ".", omittingEmptySubsequences: false)[...]) {
        case .done: return
        case .unknownPath: throw .unknownPath(path)
        case .invalidValue: throw .invalidValue(path: path, value: value)
        }
    }

    /// `path=value` (one `-codd-set-pref` argument); the value may itself contain `=`.
    public mutating func apply(assignment: String) throws(PreferencesPathError) {
        guard let eq = assignment.firstIndex(of: "=") else { throw .malformedAssignment(assignment) }
        let path = assignment[..<eq].trimmingCharacters(in: .whitespaces)
        try set(String(assignment[assignment.index(after: eq)...]), atPath: path)
    }
}

// MARK: - Codable (tolerant, same rules as the store; optionals written as null)

extension CoddPreferences: Codable {
    public init(from decoder: any Decoder) throws {
        self = try Self.decodeTable(from: decoder, over: CoddPreferences())
    }

    public func encode(to encoder: any Encoder) throws {
        try documentJSON().encode(to: encoder)
    }

    /// The whole file: every section plus `"version"`.
    func documentJSON() -> PrefJSON {
        guard case .object(var object) = tableJSON() else { return tableJSON() }
        object["version"] = .int(Self.currentVersion)
        return .object(object)
    }

    /// Decodes a parsed file over the defaults; returns the repaired paths in field order.
    static func read(_ json: PrefJSON) -> (CoddPreferences, [String]) {
        var value = CoddPreferences()
        let repaired = read(json, into: &value, path: "")
        return (value, repaired)
    }
}

// The field tables are built once (`static let`): computed, every `value(atPath:)` rebuilt all of
// them, which made the DEBUG state dump cost about 5 ms (M3 review). They are immutable after
// their lazy initialisation and their closures capture only key paths and codecs, hence the
// `nonisolated(unsafe)` (the closures are not `@Sendable`).
extension CoddPreferences: FieldTable {
    nonisolated(unsafe) static let fields: [PrefField<CoddPreferences>] = [
        .group("general", \.general),
        .group("appearance", \.appearance),
        .group("sessions", \.sessions),
        .group("notifications", \.notifications),
        .group("accounts", \.accounts),
        .group("notebook", \.notebook),
        .group("cleanup", \.cleanup),
        .group("shortcuts", \.shortcuts),
        .group("advanced", \.advanced),
        .group("about", \.about),
    ]
}

extension CoddPreferences.General: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("launchAtLogin", \.launchAtLogin, .bool),
        .leaf("showInDock", \.showInDock, .bool),
        .leaf("keepInMenuBarOnClose", \.keepInMenuBarOnClose, .bool),
        .leaf("quitBehavior", \.quitBehavior, .enumeration),
        .group("hotkey", \.hotkey),
        .leaf("projectRoot", \.projectRoot, .string(nonBlank: true)),
        .leaf("language", \.language, .enumeration),
    ]
}

extension CoddPreferences.Hotkey: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("enabled", \.enabled, .bool),
        .leaf("keyCode", \.keyCode, .uint32),
        .leaf("modifiers", \.modifiers, .uint32),
        .leaf("display", \.display, .string(nonBlank: false)),
    ]
}

extension CoddPreferences.Appearance: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("crt", \.crt, .enumeration),
        .leaf("density", \.density, .enumeration),
        .leaf("uiFontSize", \.uiFontSize, .clamped(Self.uiFontSizeRange)),
        .leaf("terminalFont", \.terminalFont, .oneOf(Self.terminalFontOptions)),
        .leaf("terminalFontSize", \.terminalFontSize, .clamped(Self.terminalFontSizeRange)),
        .leaf("nativeVibrancy", \.nativeVibrancy, .bool),
        .leaf("reduceMotion", \.reduceMotion, .enumeration),
        .leaf("zoomTerminalSteps", \.zoomTerminalSteps, .clamped(Self.zoomTerminalStepsRange)),
    ]
}

extension CoddPreferences.Sessions: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("autoSessionId", \.autoSessionId, .bool),
        .leaf("noHookWarningSeconds", \.noHookWarningSeconds, .oneOf(Self.noHookWarningOptions)),
        .leaf("staleAfterSeconds", \.staleAfterSeconds, .oneOf(Self.staleAfterOptions)),
        .leaf("restoreAsStopped", \.restoreAsStopped, .bool),
        .leaf("externalDisplay", \.externalDisplay, .enumeration),
        .leaf("hideSDKAndDesktop", \.hideSDKAndDesktop, .bool),
    ]
}

extension CoddPreferences.Notifications: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .group("waiting", \.waiting),
        .group("error", \.error),
        .group("done", \.done),
        .group("exitedNonZero", \.exitedNonZero),
        .group("quietHours", \.quietHours),
        .leaf("mutedGroupIDs", \.mutedGroupIDs, .stringList),
        .leaf("dockBadge", \.dockBadge, .enumeration),
        .leaf("menuBarIcon", \.menuBarIcon, .enumeration),
        .leaf("pausedUntil", \.pausedUntil, .optionalDate),
    ]
}

extension CoddPreferences.EventRule: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("condition", \.condition, .enumeration),
        .leaf("notify", \.notify, .bool),
        .leaf("sound", \.sound, .bool),
    ]
}

extension CoddPreferences.QuietHours: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("enabled", \.enabled, .bool),
        .leaf("start", \.start, .timeOfDay),
        .leaf("end", \.end, .timeOfDay),
    ]
}

extension CoddPreferences.Accounts: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("cswapPath", \.cswapPath, .optionalString),
        .leaf("confirmBeforeSwitch", \.confirmBeforeSwitch, .bool),
        .group("autoSwitch", \.autoSwitch),
    ]
}

extension CoddPreferences.AutoSwitch: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("enabled", \.enabled, .bool),
        .leaf("thresholdPercent", \.thresholdPercent, .clamped(Self.thresholdRange)),
        .leaf("checkFiveHour", \.checkFiveHour, .bool),
        .leaf("checkWeekly", \.checkWeekly, .bool),
        .leaf("cooldownSeconds", \.cooldownSeconds, .clamped(Self.cooldownRange)),
    ]
}

extension CoddPreferences.Notebook: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("location", \.location, .enumeration),
        .leaf("resizeImages", \.resizeImages, .bool),
        .leaf("keepOriginal", \.keepOriginal, .bool),
        .leaf("mcpPort", \.mcpPort, .clamped(Self.mcpPortRange)),
        .leaf("autoAttachMCP", \.autoAttachMCP, .bool),
        .leaf("defaultAIAccess", \.defaultAIAccess, .enumeration),
        .leaf("aiCanWrite", \.aiCanWrite, .bool),
    ]
}

extension CoddPreferences.Cleanup: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("notesStaleDays", \.notesStaleDays, .oneOf(Self.notesStaleOptions)),
        .leaf("notesArchiveDays", \.notesArchiveDays, .oneOf(Self.notesArchiveOptions)),
        .leaf("scratchArchiveDays", \.scratchArchiveDays, .oneOf(Self.scratchArchiveOptions)),
        .leaf("trashPurgeDays", \.trashPurgeDays, .oneOf(Self.trashPurgeOptions)),
        .leaf("tombstoneDays", \.tombstoneDays, .oneOf(Self.tombstoneOptions)),
        .leaf("exempt", \.exempt, .bool),
        .leaf("sessionsStaleDays", \.sessionsStaleDays, .oneOf(Self.sessionsStaleOptions)),
        .leaf("sessionsArchiveDays", \.sessionsArchiveDays, .oneOf(Self.sessionsArchiveOptions)),
        .leaf("scrollbackDeleteDays", \.scrollbackDeleteDays, .oneOf(Self.scrollbackDeleteOptions)),
        .leaf("resumeWarning", \.resumeWarning, .bool),
        .leaf("digest", \.digest, .enumeration),
        .leaf("condenseAccount", \.condenseAccount, .optionalString),
        .leaf("condenseModel", \.condenseModel, .string(nonBlank: true)),
    ]
}

extension CoddPreferences.Shortcuts: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = []
}

extension CoddPreferences.Advanced: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [
        .leaf("scrollbackRetentionDays", \.scrollbackRetentionDays, .oneOf(Self.scrollbackRetentionOptions)),
    ]
}

extension CoddPreferences.About: Codable, FieldTable {
    public init(from decoder: any Decoder) throws { self = try Self.decodeTable(from: decoder, over: Self()) }
    public func encode(to encoder: any Encoder) throws { try tableJSON().encode(to: encoder) }

    nonisolated(unsafe) static let fields: [PrefField<Self>] = [.leaf("updateChannel", \.updateChannel, .enumeration)]
}
