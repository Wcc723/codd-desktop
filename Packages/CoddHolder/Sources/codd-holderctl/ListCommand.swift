import CoddHolderClient
import CoddProtocol

/// `list --root <sessionsDir>`: sessions from meta.json files (never by scanning sockets).
enum ListCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandLineOptions(arguments, valueKeys: ["--root"], flagKeys: ["--json"])
            let records = try SessionDirectory.list(root: try options.required("--root"))
            if options.has("--json") {
                let array = JSONValue.array(records.map { record in
                    var members = record.meta.jsonValue().objectValue ?? []
                    members.append(JSONMember("dir", .string(record.directory)))
                    members.append(JSONMember("alive", .bool(record.holderAlive)))
                    return .object(members)
                })
                Console.out(array.serializedString() + "\n")
                return 0
            }
            Console.out(pad("SESSION", 38) + pad("STATE", 14) + pad("HOLDER", 8) + pad("CHILD", 8) + pad("SIZE", 9) + "TITLE\n")
            for record in records {
                let meta = record.meta
                Console.out(
                    pad(meta.session, 38) + pad(state(of: record), 14) + pad(String(meta.holderPid), 8)
                        + pad(String(meta.childPid), 8) + pad("\(meta.cols)x\(meta.rows)", 9) + (meta.title ?? "") + "\n")
            }
            return 0
        } catch {
            Console.error("list: \(error)\n")
            return 1
        }
    }

    static func state(of record: SessionRecord) -> String {
        let meta = record.meta
        let exit = meta.exited ? "\(meta.signaled == true ? "sig" : "exit") \(meta.exitStatus ?? -1)" : nil
        if record.holderAlive { return exit.map { "EXITED \($0)" } ?? "RUNNING" }
        if meta.holderExited { return exit.map { "ENDED \($0)" } ?? "ENDED" }
        return "DEAD"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
