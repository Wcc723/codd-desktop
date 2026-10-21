import Foundation

/// `<dataRoot>/onboarding.json` (§2.3, USER DATA): written when the wizard ends (開始使用, 略過 on step
/// 6 or closing the window; ⌘Q in the middle writes nothing, D7).
///
/// `{"v":1,"completedAt":"<ISO 8601>","appVersion":"1.0.0","build":"<n>","steps":{"detect":"done",…},
/// "imported":{"projects":9,"groups":3},"notifications":"granted|denied|notAsked|suppressed"}`
public struct OnboardingState: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public enum Notifications: String, Sendable, Codable {
        case granted, denied, notAsked, suppressed
    }

    public struct Imported: Sendable, Equatable, Codable {
        public var projects: Int
        public var groups: Int

        public init(projects: Int, groups: Int) {
            self.projects = projects
            self.groups = groups
        }
    }

    public var v: Int
    public var completedAt: Date
    public var appVersion: String
    public var build: String
    /// `OnboardingStep.id` → state.
    public var steps: [String: StepProgress]
    public var imported: Imported
    public var notifications: Notifications

    public init(v: Int = OnboardingState.currentVersion, completedAt: Date, appVersion: String, build: String,
                steps: [String: StepProgress], imported: Imported, notifications: Notifications) {
        self.v = v
        self.completedAt = completedAt
        self.appVersion = appVersion
        self.build = build
        self.steps = steps
        self.imported = imported
        self.notifications = notifications
    }

    /// The state for a wizard ending now (`finishing`: done for 開始使用, skipped for 略過 / closing).
    public init(flow: OnboardingFlow, finishing: StepProgress, imported: Imported, notifications: Notifications,
                appVersion: String, build: String, completedAt: Date = Date()) {
        self.init(completedAt: completedAt, appVersion: appVersion, build: build,
                  steps: flow.finalStates(finishing: finishing), imported: imported, notifications: notifications)
    }

    /// The notifications member for the done step's state (asking counts as not asked).
    public static func notifications(_ state: DoneStepModel.Notifications) -> Notifications {
        switch state {
        case .granted: .granted
        case .denied: .denied
        case .suppressed: .suppressed
        case .notAsked, .asking: .notAsked
        }
    }
}

/// Reads and writes `onboarding.json`: 0600, atomic (temp file + rename), sorted keys; a file with
/// a newer `v` (a newer CODD wrote it) is never replaced.
public struct OnboardingStateStore: Sendable {
    public enum StoreError: Error, Equatable {
        case newerVersion(Int)
        case writeFailed(String)
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `<root>/onboarding.json`.
    public init(dataRoot: URL) { url = dataRoot.appendingPathComponent("onboarding.json", isDirectory: false) }

    /// The decoded file; nil when missing or unreadable (any version that decodes is returned).
    public func load() -> OnboardingState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OnboardingState.self, from: data)
    }

    /// The integer `v` of the file on disk (nil: no file, not JSON or no integer `v`).
    public func existingVersion() -> Int? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["v"] as? NSNumber, CFNumberIsFloatType(number) == false else { return nil }
        return number.intValue
    }

    public func save(_ state: OnboardingState) throws {
        if let version = existingVersion(), version > OnboardingState.currentVersion {
            throw StoreError.newerVersion(version)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(state)
        data.append(0x0A)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".onboarding.json.tmp-\(getpid())-\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.writeFailed(String(cString: strerror(errno))) }
        var written = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count <= 0 { return false }
                written += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temp.path)
            throw StoreError.writeFailed(reason)
        }
    }
}

/// D5: whether a data root is new (the wizard shows by itself only there).
public enum OnboardingGate {
    /// Any of these (or a `sessions/*/meta.json`) means CODD ran here before.
    public static let markerFiles = ["layout.json", "panes.json", "onboarding.json"]

    public static func isNewDataRoot(_ root: URL) -> Bool {
        let base = root.path
        for name in markerFiles where exists(base + "/" + name) { return false }
        let sessions = base + "/sessions"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: sessions)) ?? [] where exists(sessions + "/" + name + "/meta.json") {
            return false
        }
        return true
    }

    /// Anything at `path` (a symlink counts, without following it).
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
