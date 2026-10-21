import CoddPosix
import Darwin

/// The child's environment and executable resolution.
enum ChildEnvironment {
    /// Parses a NUL-separated `KEY=VALUE` list. Empty entries and entries without a key are skipped.
    static func parseEnvFile(_ bytes: [UInt8]) -> [String] {
        bytes.split(separator: 0, omittingEmptySubsequences: true).compactMap { entry in
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals != entry.startIndex else { return nil }
            return String(decoding: entry, as: UTF8.self)
        }
    }

    /// The env-file contents, or the holder's own environment when no file was given.
    static func load(envFile: String?) throws(SystemError) -> [String] {
        guard let envFile else { return ProcessQueries.environment() }
        return parseEnvFile(try PosixFile.readAll(envFile, maxBytes: 4 << 20))
    }

    static func value(of key: String, in environment: [String]) -> String? {
        let prefix = key + "="
        guard let entry = environment.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(entry.dropFirst(prefix.count))
    }

    static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolves `name` against the child's PATH like execvp would. Names containing a slash are
    /// returned unchanged; unresolvable names are returned unchanged so execve reports ENOENT.
    static func resolveExecutable(_ name: String, environment: [String]) -> String {
        if name.contains("/") { return name }
        let searchPath = value(of: "PATH", in: environment) ?? defaultSearchPath
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "." : String(directory)
            let candidate = PosixFile.join(base, name)
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return name
    }
}
