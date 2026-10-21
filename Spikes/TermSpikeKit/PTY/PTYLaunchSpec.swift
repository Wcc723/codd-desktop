/// Terminal window size as carried by `TIOCSWINSZ`.
public struct PTYWindowSize: Sendable, Equatable, Codable, CustomStringConvertible {
    public var columns: UInt16
    public var rows: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16

    public init(columns: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Clamps pixel sizes that do not fit `UInt16` (5K panels at 2x can exceed it).
    public init(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        func clamp(_ value: Int) -> UInt16 { UInt16(max(0, min(Int(UInt16.max), value))) }
        self.init(
            columns: clamp(columns),
            rows: clamp(rows),
            pixelWidth: clamp(pixelWidth),
            pixelHeight: clamp(pixelHeight)
        )
    }

    public static let fallback = PTYWindowSize(columns: 120, rows: 40)

    public var description: String { "\(columns)×\(rows)" }
}

/// Everything needed to start a child on a fresh PTY.
public struct PTYLaunchSpec: Sendable {
    /// Absolute path of the executable (no PATH search is done).
    public var executable: String
    /// Full argv, including argv[0].
    public var arguments: [String]
    /// The child's exact environment (nothing is inherited).
    public var environment: [String: String]
    public var workingDirectory: String?
    public var size: PTYWindowSize

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        size: PTYWindowSize = .fallback
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.size = size
    }
}

public enum PTYError: Error, Equatable, CustomStringConvertible {
    case invalidSpec(String)
    case forkFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .invalidSpec(reason): "invalid PTY launch spec: \(reason)"
        case let .forkFailed(code): "forkpty failed: errno \(code)"
        }
    }
}
