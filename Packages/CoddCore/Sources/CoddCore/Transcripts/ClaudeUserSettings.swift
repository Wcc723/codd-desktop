import Foundation

/// The two values CODD shows from Claude's own `settings.json` (D18 expiry warning, D30 `預設 (opus)`).
public struct ClaudeUserSettingsSummary: Sendable, Equatable {
    /// Top-level `cleanupPeriodDays` (Claude deletes transcripts older than this; default 30).
    public var cleanupPeriodDays: Int?
    /// Top-level `model` (the model `claude` starts with when no `--model` is passed).
    public var model: String?

    public init(cleanupPeriodDays: Int? = nil, model: String? = nil) {
        self.cleanupPeriodDays = cleanupPeriodDays
        self.model = model
    }
}

/// Reads `<claudeDir>/settings.json` READ-ONLY. CODD never edits Claude's settings (its hooks travel
/// in each session's `--settings`), so this only summarizes; tests pass temp files.
public enum ClaudeUserSettings {
    /// settings.json is a few KB; anything larger is not read at all.
    public static let maxFileBytes = 1 << 20
    /// A model id is short; a longer value is not something to show in a select.
    static let maxModelLength = 128

    /// Tolerant: a missing, oversized, non-regular or invalid file yields an empty summary, and a
    /// value of the wrong shape is `nil` (the rest is still read).
    public static func read(settingsFile: URL) -> ClaudeUserSettingsSummary {
        let bytes: [UInt8]? = ReadOnlyFile.with(settingsFile.path) { fd, info in
            guard info.size <= maxFileBytes else { return nil }
            // One byte more than allowed tells a file that grew while being read.
            guard let data = ReadOnlyFile.read(fd, offset: 0, count: maxFileBytes + 1), data.count <= maxFileBytes else { return nil }
            return data
        }
        guard let bytes, let object = JSONValue.parse(Data(bytes))?.objectValue else { return ClaudeUserSettingsSummary() }
        return summary(object)
    }

    static func summary(_ object: [String: JSONValue]) -> ClaudeUserSettingsSummary {
        var out = ClaudeUserSettingsSummary()
        if let days = object["cleanupPeriodDays"]?.exactIntegerValue, days >= 1 { out.cleanupPeriodDays = days }
        if let raw = object["model"]?.stringValue {
            let model = JSText.trim(raw)
            if !model.isEmpty, model.count <= maxModelLength, (try? LaunchBuilder.validateToken(model, flag: "--model")) != nil {
                out.model = model
            }
        }
        return out
    }
}
