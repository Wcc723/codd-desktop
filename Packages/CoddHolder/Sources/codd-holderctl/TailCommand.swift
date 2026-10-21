import CoddHolderClient
import CoddProtocol

/// `tail`: print OUTPUT bytes (raw) from an offset; follows until EXIT unless `--no-follow`.
enum TailCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandLineOptions(
                arguments, valueKeys: ["--socket", "--from"], flagKeys: ["--no-follow", "--takeover"])
            let (connection, welcome) = try ConnectionHelpers.open(options)
            let from = try ConnectionHelpers.attachOffset(options.value("--from"), welcome: welcome, default: "resync")
            let follow = !options.has("--no-follow")
            let stopAt = welcome.ringEnd
            let start = from == Message.latestResync ? welcome.resync : from
            if !follow && start >= stopAt { return 0 }
            try connection.send(.attach(fromOffset: from))
            while let message = try connection.receive(timeoutMilliseconds: -1) {
                switch message {
                case .output(let offset, let bytes):
                    Console.outBytes(bytes)
                    if !follow && offset + UInt64(bytes.count) >= stopAt { return 0 }
                case .gap(_, let to):
                    // A lapped client resumes at `to`; without follow, stop if that is past the end.
                    if !follow && to >= stopAt { return 0 }
                case .exit:
                    return 0
                case .error(let info):
                    Console.error("tail: \(info)\n")
                    return 1
                default:
                    break
                }
            }
            return 0
        } catch HolderClientError.closed {
            return 0
        } catch {
            Console.error("tail: \(error)\n")
            return 1
        }
    }
}
