import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin

/// `kill --dir <sessionDir>` ends the session (SIGTERM to the holder, which hangs up the PTY).
/// `kill --socket <path> --signal <sig>` sends a signal to the PTY foreground process group.
enum KillCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandLineOptions(arguments, valueKeys: ["--dir", "--socket", "--signal"], flagKeys: ["--takeover"])
            if let name = options.value("--signal") {
                guard let signo = signalNumber(name) else {
                    Console.error("kill: unknown signal \(name)\n")
                    return 64
                }
                let (connection, _) = try ConnectionHelpers.open(options)
                try connection.send(.signal(signo))
                try connection.send(.ping(token: 2))
                while let message = try connection.receive(timeoutMilliseconds: 5000) {
                    if case .pong = message { return 0 }
                }
                return 1
            }
            let directory = try options.required("--dir")
            guard let meta = SessionDirectory.readMeta(directory: directory) else {
                Console.error("kill: no meta.json in \(directory)\n")
                return 1
            }
            guard SessionDirectory.isLive(meta) else {
                Console.error("kill: holder \(meta.holderPid) is not running\n")
                return 1
            }
            guard kill(meta.holderPid, SIGTERM) == 0 else {
                Console.error("kill: \(SystemError.current("kill(\(meta.holderPid))"))\n")
                return 1
            }
            let deadline = Clock.monotonicNanoseconds() + 6_000_000_000
            while ProcessQueries.isAlive(meta.holderPid) && Clock.monotonicNanoseconds() < deadline {
                Clock.sleep(milliseconds: 10)
            }
            if ProcessQueries.isAlive(meta.holderPid) {
                Console.error("kill: holder \(meta.holderPid) still running\n")
                return 1
            }
            return 0
        } catch {
            Console.error("kill: \(error)\n")
            return 1
        }
    }

    static func signalNumber(_ text: String) -> UInt8? {
        if let number = UInt8(text), number > 0, number < 32 { return number }
        let name = text.uppercased().hasPrefix("SIG") ? String(text.uppercased().dropFirst(3)) : text.uppercased()
        let table: [String: Int32] = [
            "HUP": SIGHUP, "INT": SIGINT, "QUIT": SIGQUIT, "KILL": SIGKILL, "TERM": SIGTERM, "USR1": SIGUSR1,
            "USR2": SIGUSR2, "WINCH": SIGWINCH, "TSTP": SIGTSTP, "CONT": SIGCONT, "STOP": SIGSTOP,
        ]
        return table[name].map { UInt8($0) }
    }
}
