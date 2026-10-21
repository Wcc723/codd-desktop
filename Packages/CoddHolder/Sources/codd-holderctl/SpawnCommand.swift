import CoddHolderClient
import CoddPosix
import Darwin

/// `spawn`: start a holder detached from this process (SETSID, CLOEXEC_DEFAULT, /dev/null stdio) and
/// wait until its socket accepts connections. The holder is reparented to launchd when ctl exits.
enum SpawnCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandLineOptions(
                arguments,
                valueKeys: [
                    "--dir", "--socket", "--session", "--holder", "--cols", "--rows", "--cwd", "--ring-size",
                    "--env-file", "--exit-linger-ms", "--log", "--timeout-ms",
                ])
            guard !options.trailing.isEmpty else {
                Console.error("spawn: missing child argv after --\n")
                return 64
            }
            guard let holder = options.value("--holder") ?? defaultHolderPath() else {
                Console.error("spawn: cannot locate codd-holder; pass --holder\n")
                return 64
            }
            // Optional integers must not be dropped silently (e.g. "--ring-size 8M" is not a byte count).
            let ringSize: Int? = options.value("--ring-size") == nil ? nil : try options.integer("--ring-size", default: 0)
            let linger: Int? = options.value("--exit-linger-ms") == nil ? nil : try options.integer("--exit-linger-ms", default: 0)
            let launch = HolderLaunch(
                holderExecutable: holder,
                session: options.value("--session") ?? randomSessionID(),
                sessionDirectory: try options.required("--dir"),
                socketPath: try options.required("--socket"),
                cols: try options.integer("--cols", default: 120),
                rows: try options.integer("--rows", default: 30),
                cwd: options.value("--cwd") ?? currentDirectory(),
                ringSize: ringSize,
                envFile: options.value("--env-file"),
                exitLingerMilliseconds: linger,
                logPath: options.value("--log"),
                argv: options.trailing)
            let timeout: Int = try options.integer("--timeout-ms", default: 5000)
            let pid = try HolderSpawner.spawn(launch)
            guard HolderSpawner.waitForSocket(launch.socketPath, timeoutMilliseconds: timeout, pid: pid) else {
                Console.error("spawn: holder \(pid) did not open \(launch.socketPath)\n")
                return 1
            }
            Console.out("pid=\(pid) session=\(launch.session) socket=\(launch.socketPath)\n")
            return 0
        } catch let failure as CommandLineOptions.Failure {
            Console.error("spawn: \(failure)\n")
            return 64
        } catch {
            Console.error("spawn: \(error)\n")
            return 1
        }
    }

    /// `codd-holder` next to this executable.
    static func defaultHolderPath() -> String? {
        guard let me = ProcessQueries.executablePath() else { return nil }
        let candidate = PosixFile.join(PosixFile.directoryName(me), "codd-holder")
        return access(candidate, X_OK) == 0 ? candidate : nil
    }

    static func currentDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard getcwd(&buffer, buffer.count) != nil else { return "/" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Random RFC 4122 version 4 UUID (lowercase).
    static func randomSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { byte -> String in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }
}
