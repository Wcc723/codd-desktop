import CoddPosix
import Darwin

/// Minimal `--key value` / `--flag` parser for the subcommands.
struct CommandLineOptions {
    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positional: [String] = []
    /// Everything after a literal `--`.
    private(set) var trailing: [String] = []

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// `valueKeys` take a value; `flagKeys` do not. Unknown `--options` are errors.
    init(_ arguments: [String], valueKeys: Set<String>, flagKeys: Set<String> = []) throws(Failure) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                trailing = Array(arguments[(index + 1)...])
                return
            }
            if argument.hasPrefix("--") {
                if let equals = argument.firstIndex(of: "=") {
                    let key = String(argument[..<equals])
                    guard valueKeys.contains(key) else { throw Failure(description: "unknown option \(key)") }
                    values[key] = String(argument[argument.index(after: equals)...])
                } else if flagKeys.contains(argument) {
                    flags.insert(argument)
                } else if valueKeys.contains(argument) {
                    index += 1
                    guard index < arguments.count else { throw Failure(description: "\(argument) needs a value") }
                    values[argument] = arguments[index]
                } else {
                    throw Failure(description: "unknown option \(argument)")
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func value(_ key: String) -> String? { values[key] }

    func required(_ key: String) throws(Failure) -> String {
        guard let value = values[key], !value.isEmpty else { throw Failure(description: "missing \(key)") }
        return value
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func integer<T: FixedWidthInteger>(_ key: String, default fallback: T) throws(Failure) -> T {
        guard let text = values[key] else { return fallback }
        guard let value = T(text) else { throw Failure(description: "\(key) must be an integer") }
        return value
    }
}

/// stdout / stderr helpers (raw writes; no buffering surprises when mixing with terminal output).
enum Console {
    static func out(_ text: String) {
        try? Descriptor.writeAll(1, text)
    }

    static func error(_ text: String) {
        try? Descriptor.writeAll(2, text)
    }

    static func outBytes(_ bytes: [UInt8]) {
        try? Descriptor.writeAll(1, bytes)
    }
}
