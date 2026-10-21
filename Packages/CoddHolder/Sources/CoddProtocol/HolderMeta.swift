/// `meta.json` in a session directory: written by the holder (atomic rename), read by the app and
/// `codd-holderctl list`. Discovery of live sessions goes through this file, never by scanning sockets.
///
/// A record with `exited == false` can still describe a dead holder (crash, reboot): readers check
/// `holderPid` liveness and compare `boot` with the current `kern.bootsessionuuid`.
public struct HolderMeta: Sendable, Equatable {
    public static let fileName = "meta.json"
    public static let currentVersion = 1

    public var version: Int = HolderMeta.currentVersion
    public var session: String
    public var holderVersion: String
    public var holderPid: Int32
    public var childPid: Int32
    public var argv: [String]
    /// Directory the child was started in.
    public var cwd: String
    public var socket: String
    public var ring: String
    public var ringSize: UInt64
    public var cols: UInt16
    public var rows: UInt16
    /// Milliseconds since the Unix epoch.
    public var startedAt: UInt64
    /// `kern.bootsessionuuid` at holder start.
    public var boot: String?
    /// Latest OSC 0/2 title.
    public var title: String?
    /// Latest OSC 7 working directory (decoded path).
    public var oscCwd: String?
    /// Latest OSC 9;4 progress report.
    public var progress: TerminalProgress?
    public var exited: Bool
    public var exitStatus: Int32?
    public var signaled: Bool?
    public var exitedAt: UInt64?
    /// True once the holder process itself shut down cleanly.
    public var holderExited: Bool

    public init(
        session: String, holderVersion: String, holderPid: Int32, childPid: Int32, argv: [String], cwd: String,
        socket: String, ring: String, ringSize: UInt64, cols: UInt16, rows: UInt16, startedAt: UInt64,
        boot: String? = nil, title: String? = nil, oscCwd: String? = nil, progress: TerminalProgress? = nil,
        exited: Bool = false,
        exitStatus: Int32? = nil, signaled: Bool? = nil, exitedAt: UInt64? = nil, holderExited: Bool = false
    ) {
        self.session = session
        self.holderVersion = holderVersion
        self.holderPid = holderPid
        self.childPid = childPid
        self.argv = argv
        self.cwd = cwd
        self.socket = socket
        self.ring = ring
        self.ringSize = ringSize
        self.cols = cols
        self.rows = rows
        self.startedAt = startedAt
        self.boot = boot
        self.title = title
        self.oscCwd = oscCwd
        self.progress = progress
        self.exited = exited
        self.exitStatus = exitStatus
        self.signaled = signaled
        self.exitedAt = exitedAt
        self.holderExited = holderExited
    }

    public func jsonValue() -> JSONValue {
        .compactObject([
            ("v", .number(version)),
            ("session", .string(session)),
            ("holder", .string(holderVersion)),
            ("proto", .number(Int(CoddProtocolVersion.current))),
            ("holderPid", .number(holderPid)),
            ("childPid", .number(childPid)),
            ("argv", .strings(argv)),
            ("cwd", .string(cwd)),
            ("socket", .string(socket)),
            ("ring", .string(ring)),
            ("ringSize", .number(ringSize)),
            ("cols", .number(Int(cols))),
            ("rows", .number(Int(rows))),
            ("startedAt", .number(startedAt)),
            ("boot", boot.map(JSONValue.string)),
            ("title", title.map(JSONValue.string)),
            ("oscCwd", oscCwd.map(JSONValue.string)),
            ("progress", progress?.jsonValue()),
            ("exited", .bool(exited)),
            ("exitStatus", exitStatus.map { JSONValue.number($0) }),
            ("signaled", signaled.map(JSONValue.bool)),
            ("exitedAt", exitedAt.map { JSONValue.number($0) }),
            ("holderExited", .bool(holderExited)),
        ])
    }

    /// Tolerant decoding; `nil` when the required `session` / `holderPid` keys are missing.
    public init?(json: JSONValue) {
        guard let session = json["session"]?.stringValue, let holderPid = json["holderPid"]?.int64Value else {
            return nil
        }
        self.version = json["v"]?.intValue ?? HolderMeta.currentVersion
        self.session = session
        self.holderVersion = json["holder"]?.stringValue ?? ""
        self.holderPid = Int32(truncatingIfNeeded: holderPid)
        self.childPid = Int32(truncatingIfNeeded: json["childPid"]?.int64Value ?? 0)
        self.argv = json["argv"]?.stringArrayValue ?? []
        self.cwd = json["cwd"]?.stringValue ?? ""
        self.socket = json["socket"]?.stringValue ?? ""
        self.ring = json["ring"]?.stringValue ?? ""
        self.ringSize = json["ringSize"]?.uint64Value ?? 0
        self.cols = UInt16(truncatingIfNeeded: json["cols"]?.uint64Value ?? 0)
        self.rows = UInt16(truncatingIfNeeded: json["rows"]?.uint64Value ?? 0)
        self.startedAt = json["startedAt"]?.uint64Value ?? 0
        self.boot = json["boot"]?.stringValue
        self.title = json["title"]?.stringValue
        self.oscCwd = json["oscCwd"]?.stringValue
        self.progress = json["progress"].flatMap(TerminalProgress.init(json:))
        self.exited = json["exited"]?.boolValue ?? false
        self.exitStatus = json["exitStatus"]?.int64Value.map { Int32(truncatingIfNeeded: $0) }
        self.signaled = json["signaled"]?.boolValue
        self.exitedAt = json["exitedAt"]?.uint64Value
        self.holderExited = json["holderExited"]?.boolValue ?? false
    }
}
