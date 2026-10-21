import CoddHolderClient
import CoddProtocol

/// `send <text> [--submit] [--paste]`: one INPUT (split if large), then PING/PONG so the holder has
/// processed it. `--paste` sends it as one paste (`input.paste`; bracketed when the child has
/// `?2004` on, the submit `\r` 50 ms later); a holder without the capability gets it bracketed by
/// ctl from the WELCOME modes.
enum SendCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let options = try CommandLineOptions(
                arguments, valueKeys: ["--socket"], flagKeys: ["--submit", "--paste", "--escapes", "--takeover"])
            guard let text = options.positional.first else {
                Console.error("send: missing <text>\n")
                return 64
            }
            let bytes = options.has("--escapes") ? ConnectionHelpers.unescape(text) : Array(text.utf8)
            let (connection, _) = try ConnectionHelpers.open(options)
            try connection.sendInput(bytes, submit: options.has("--submit"), paste: options.has("--paste"))
            try connection.send(.ping(token: 1))
            while let message = try connection.receive(timeoutMilliseconds: 5000) {
                if case .pong = message { return 0 }
            }
            Console.error("send: no PONG from holder\n")
            return 1
        } catch {
            Console.error("send: \(error)\n")
            return 1
        }
    }
}
