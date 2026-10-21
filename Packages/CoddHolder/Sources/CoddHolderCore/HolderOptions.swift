/// Command line of `codd-holder` (docs/ARCHITECTURE.md):
///
/// ```
/// codd-holder --session <uuid> --dir <sessionDir> --socket <path> --cols <n> --rows <n> --cwd <dir>
///             [--ring-size <bytes>] [--env-file <path>] [--exit-linger-ms <ms>] [--log <path>]
///             [--flow-limit <bytes>] -- <argv…>
/// ```
///
/// `--exit-linger-ms` (default 10000), `--log` and `--flow-limit` (default 1 MiB; the backpressure
/// threshold is min(limit, ring / 2)) are additions for tests, measurements and debugging.
public struct HolderOptions: Sendable, Equatable {
    public var session: String
    public var sessionDirectory: String
    public var socketPath: String
    public var cols: UInt16
    public var rows: UInt16
    public var cwd: String
    public var ringSize: Int
    public var envFile: String?
    public var exitLingerMilliseconds: Int
    public var logPath: String?
    /// Upper bound of the flow-control high-water mark (the mark is min(limit, ring / 2)).
    public var flowControlLimit: Int
    public var argv: [String]

    public static let defaultRingSize = 8 << 20
    public static let minimumRingSize = 128 << 10
    public static let maximumRingSize = 1 << 30
    public static let defaultExitLingerMilliseconds = 10_000
    /// Upper bound for `--exit-linger-ms` (one day; keeps the nanosecond timer arithmetic in range).
    public static let maximumExitLingerMilliseconds = 86_400_000
    /// 1 MiB keeps Ctrl+C responsive under a flood: everything above the mark is output the
    /// terminal still has to chew through after the child stopped (4 MiB added ~30 ms in M0).
    public static let defaultFlowControlLimit = 1 << 20
    public static let flowControlLimitRange = (64 << 10)...(64 << 20)

    public static let usage = """
        usage: codd-holder --session <id> --dir <sessionDir> --socket <path> --cols <n> --rows <n> --cwd <dir>
                           [--ring-size <bytes|K|M>] [--env-file <path>] [--exit-linger-ms <ms>] [--log <path>]
                           [--flow-limit <bytes|K|M>] -- <argv...>
        """

    public struct UsageError: Error, Sendable, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public static func parse(_ arguments: [String]) throws(UsageError) -> HolderOptions {
        var values: [String: String] = [:]
        var argv: [String] = []
        var index = 0
        let known: Set<String> = [
            "--session", "--dir", "--socket", "--cols", "--rows", "--cwd", "--ring-size", "--env-file",
            "--exit-linger-ms", "--log", "--flow-limit",
        ]
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                argv = Array(arguments[(index + 1)...])
                break
            }
            var key = argument
            var value: String?
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                key = String(argument[..<equals])
                value = String(argument[argument.index(after: equals)...])
            }
            guard known.contains(key) else { throw UsageError(message: "unknown option \(argument)") }
            if value == nil {
                index += 1
                guard index < arguments.count else { throw UsageError(message: "\(key) needs a value") }
                value = arguments[index]
            }
            values[key] = value
            index += 1
        }

        func required(_ key: String) throws(UsageError) -> String {
            guard let value = values[key], !value.isEmpty else { throw UsageError(message: "missing \(key)") }
            return value
        }
        func dimension(_ key: String) throws(UsageError) -> UInt16 {
            let text = try required(key)
            guard let value = UInt16(text), value > 0 else { throw UsageError(message: "\(key) must be 1...65535") }
            return value
        }

        let session = try required("--session")
        guard session.utf8.count <= 64, session.utf8.allSatisfy(isSessionCharacter) else {
            throw UsageError(message: "--session must be 1-64 characters of [A-Za-z0-9_-]")
        }
        var ringSize = defaultRingSize
        if let text = values["--ring-size"] {
            guard let parsed = parseByteCount(text), parsed >= minimumRingSize, parsed <= maximumRingSize else {
                throw UsageError(message: "--ring-size must be between 128K and 1G")
            }
            ringSize = parsed
        }
        var linger = defaultExitLingerMilliseconds
        if let text = values["--exit-linger-ms"] {
            guard let parsed = Int(text), parsed >= 0, parsed <= maximumExitLingerMilliseconds else {
                throw UsageError(message: "--exit-linger-ms must be 0...\(maximumExitLingerMilliseconds)")
            }
            linger = parsed
        }
        var flowLimit = defaultFlowControlLimit
        if let text = values["--flow-limit"] {
            guard let parsed = parseByteCount(text), flowControlLimitRange.contains(parsed) else {
                throw UsageError(message: "--flow-limit must be between 64K and 64M")
            }
            flowLimit = parsed
        }
        guard !argv.isEmpty, !argv[0].isEmpty else { throw UsageError(message: "missing child argv after --") }

        return HolderOptions(
            session: session,
            sessionDirectory: try required("--dir"),
            socketPath: try required("--socket"),
            cols: try dimension("--cols"),
            rows: try dimension("--rows"),
            cwd: try required("--cwd"),
            ringSize: ringSize,
            envFile: values["--env-file"],
            exitLingerMilliseconds: linger,
            logPath: values["--log"],
            flowControlLimit: flowLimit,
            argv: argv)
    }

    /// "8388608", "512K", "8M", "1G" (binary units).
    static func parseByteCount(_ text: String) -> Int? {
        guard let last = text.last else { return nil }
        let multiplier: Int
        var digits = Substring(text)
        switch last {
        case "K", "k": multiplier = 1 << 10
        case "M", "m": multiplier = 1 << 20
        case "G", "g": multiplier = 1 << 30
        default: multiplier = 1
        }
        if multiplier != 1 { digits = digits.dropLast() }
        guard let value = Int(digits), value >= 0 else { return nil }
        let (product, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : product
    }

    private static func isSessionCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}
