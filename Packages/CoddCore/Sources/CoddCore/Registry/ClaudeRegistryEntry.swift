import Foundation

/// One live Claude Code session from the undocumented registry `~/.claude/sessions/<pid>.json`
/// (one file per running process, removed on exit).
///
/// Field names follow design/research/claude-local.md and were confirmed read-only on this Mac
/// (Claude Code 2.1.296–2.1.300): timestamps are epoch milliseconds, `procStart` is a ctime-style
/// local time string (`Thu Oct 15 01:02:22 2026`), `waitingFor` is absent unless waiting.
/// Decoding is tolerant: unknown fields are ignored and a field of the wrong type is `nil`.
/// The sibling `<pid>.<hash>.key` files are never read.
public struct ClaudeRegistryEntry: Sendable, Equatable {
    /// `pid` (only when it is an integer).
    public var pid: Int?
    /// `sessionId`, trimmed.
    public var sessionId: String?
    public var cwd: String?
    public var startedAt: Date?
    /// Process start time as Claude wrote it; compared with the live process to detect pid reuse.
    public var procStart: String?
    public var version: String?
    /// `kind`: `interactive`, `sdk`, `daemon-worker`, … (raw).
    public var kind: String?
    /// `entrypoint`: `cli`, `claude-desktop`, `claude-vscode`, `sdk-cli`, … (raw).
    public var entrypoint: String?
    public var name: String?
    /// `nameSource`: `derived`, `user`, `auto`, `hook`, `peer`, `collision` (raw).
    public var nameSource: String?
    /// `status`, trimmed (raw string; see ``statusValue``).
    public var status: String?
    /// `waitingFor`, e.g. `permission prompt`, `input needed` (raw).
    public var waitingFor: String?
    /// Millisecond value of `statusUpdatedAt ?? updatedAt` exactly as session-insights.js resolves
    /// it (a present-but-invalid `statusUpdatedAt` does NOT fall back to `updatedAt`).
    public var statusTimestampMilliseconds: Int64?
    public var updatedAt: Date?
    /// Remote Control bridge id (`cse_…`) when present.
    public var bridgeSessionId: String?

    public init(
        pid: Int? = nil, sessionId: String? = nil, cwd: String? = nil, startedAt: Date? = nil,
        procStart: String? = nil, version: String? = nil, kind: String? = nil, entrypoint: String? = nil,
        name: String? = nil, nameSource: String? = nil, status: String? = nil, waitingFor: String? = nil,
        statusTimestampMilliseconds: Int64? = nil, updatedAt: Date? = nil, bridgeSessionId: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.waitingFor = waitingFor
        self.statusTimestampMilliseconds = statusTimestampMilliseconds
        self.updatedAt = updatedAt
        self.bridgeSessionId = bridgeSessionId
    }

    /// Builds an entry from a decoded JSON object.
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        pid = o["pid"]?.exactIntegerValue
        sessionId = JSText.nonBlankTrimmed(o["sessionId"])
        cwd = JSText.nonBlank(o["cwd"])
        startedAt = JSDate.timestamp(o["startedAt"]).map(JSDate.date(milliseconds:))
        procStart = JSText.nonBlankTrimmed(o["procStart"])
        version = JSText.nonBlankTrimmed(o["version"])
        kind = JSText.nonBlankTrimmed(o["kind"])
        entrypoint = JSText.nonBlankTrimmed(o["entrypoint"])
        name = JSText.nonBlank(o["name"])
        nameSource = JSText.nonBlankTrimmed(o["nameSource"])
        status = JSText.nonBlankTrimmed(o["status"])
        waitingFor = JSText.nonBlankTrimmed(o["waitingFor"])
        // session-insights: `o.statusUpdatedAt ?? o.updatedAt ?? null`, then toIso().
        let statusStamp: JSONValue? = (o["statusUpdatedAt"].flatMap { $0 == .null ? nil : $0 }) ?? o["updatedAt"]
        statusTimestampMilliseconds = JSDate.timestamp(statusStamp)
        updatedAt = JSDate.timestamp(o["updatedAt"]).map(JSDate.date(milliseconds:))
        bridgeSessionId = JSText.nonBlankTrimmed(o["bridgeSessionId"])
    }

    /// Parses one registry file's bytes; `nil` unless it is a JSON object.
    public init?(data: Data) {
        guard let json = JSONValue.parse(data) else { return nil }
        self.init(json: json)
    }

    /// The status as a known value (`busy` / `idle` / `waiting`), else `nil`.
    public var statusValue: RegistryStatus? { status.flatMap(RegistryStatus.init(rawValue:)) }

    /// `statusUpdatedAt ?? updatedAt` as a `Date`.
    public var statusUpdatedAt: Date? { statusTimestampMilliseconds.map(JSDate.date(milliseconds:)) }

    /// The waiting reason when `status == waiting` (design/research/critic.md C3).
    public var waitingReason: WaitingReason? {
        statusValue == .waiting ? RegistryStatus.waitingReason(forWaitingFor: waitingFor) : nil
    }

    /// SDK / headless sessions (`sdk-*` entrypoints) — hidden by default like the official picker.
    public var isSDK: Bool { entrypoint?.hasPrefix("sdk-") ?? false || kind == "sdk" }

    /// Remote Control is connected (registry carries a bridge session id).
    public var hasRemoteControl: Bool { bridgeSessionId != nil }
}

/// Registry `status` values (claude-local.md: `busy`, `idle`, `waiting`).
public enum RegistryStatus: String, Sendable, CaseIterable {
    case busy
    case idle
    case waiting

    /// Maps `waitingFor` to a reason (critic.md C3): `input needed` → question;
    /// `permission prompt`, `sandbox request`, `worker request` → permission;
    /// `dialog open`, `goal proposal`, missing or unrecognised → other.
    public static func waitingReason(forWaitingFor raw: String?) -> WaitingReason {
        switch raw.map({ JSText.trim($0).lowercased() }) {
        case "input needed"?: return .question
        case "permission prompt"?, "sandbox request"?, "worker request"?: return .permission
        default: return .other
        }
    }
}

extension JSONValue {
    /// `Number.isInteger(v)` as an `Int` (any sign), else `nil`.
    var exactIntegerValue: Int? {
        guard case .number(let n) = self, n.isFinite, n.rounded(.towardZero) == n,
              abs(n) < 9_007_199_254_740_992 else { return nil }
        return Int(n)
    }
}
