import CoddHolderClient
import CoddPosix
import CoddProtocol

/// `ring <sessionDir> [--raw] [--limit <bytes>]`: what `RingFileReader` reads from `<sessionDir>/ring`
/// (the replay a dead session would show). Without `--raw`, one `key=value` line per field; with
/// `--raw`, only the bytes `[start, end)` on stdout. Exit status 2 when there is no ring file.
enum RingCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandLineOptions(arguments, valueKeys: ["--limit"], flagKeys: ["--raw"])
            guard let directory = options.positional.first else {
                Console.error("ring: missing <sessionDir>\n")
                return 64
            }
            let limit: Int = try options.integer("--limit", default: 8 << 20)
            let path = PosixFile.join(directory, "ring")
            let snapshot: RingSnapshot
            do {
                snapshot = try RingFileReader.read(path: path, limit: limit)
            } catch .missing {
                Console.error("ring: no ring file at \(path)\n")
                return 2
            } catch {
                Console.error("ring: \(path): \(error)\n")
                return 1
            }
            if options.has("--raw") {
                Console.outBytes(snapshot.bytes)
                return 0
            }
            Console.out(summary(snapshot))
            return 0
        } catch {
            Console.error("ring: \(error)\n")
            return 64
        }
    }

    static func summary(_ snapshot: RingSnapshot) -> String {
        let modes = snapshot.modes.map { $0.jsonValue().serializedString() } ?? "unknown"
        let lines = [
            "start=\(snapshot.start)",
            "end=\(snapshot.end)",
            "size=\(snapshot.bytes.count)",
            "modes=\(modes)",
            "spawnOffset=\(snapshot.spawnOffset)",
            "childExited=\(snapshot.childExited)",
            "exitStatus=\(snapshot.exitStatus.map { String($0) } ?? "none")",
            "signaled=\(snapshot.signaled)",
            "holderExitedCleanly=\(snapshot.holderExitedCleanly)",
            "cols=\(snapshot.columns)",
            "rows=\(snapshot.rows)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
