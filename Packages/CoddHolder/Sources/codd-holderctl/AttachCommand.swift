import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin

/// `attach`: interactive bridge between this terminal and the holder.
/// stdin → INPUT, SIGWINCH → RESIZE, OUTPUT → stdout. ctrl-\ detaches (the session keeps running).
enum AttachCommand {
    static let detachKey: UInt8 = 0x1C

    static func run(_ arguments: [String]) -> Int32 {
        let connection: HolderConnection
        let welcome: Welcome
        let options: CommandLineOptions
        do {
            options = try CommandLineOptions(arguments, valueKeys: ["--socket", "--from"], flagKeys: ["--takeover"])
            (connection, welcome) = try ConnectionHelpers.open(options)
        } catch {
            Console.error("attach: \(error)\n")
            return 1
        }
        let interactive = isatty(0) == 1
        var saved: termios?
        if interactive {
            do {
                saved = try TerminalIO.makeRaw(0)
            } catch {
                Console.error("attach: \(error)\n")
                return 1
            }
        }
        let status: Int32
        do {
            if interactive { try sendWindowSize(connection) }
            let from = try ConnectionHelpers.attachOffset(options.value("--from"), welcome: welcome, default: "resync")
            try connection.send(.attach(fromOffset: from))
            status = try bridge(connection)
        } catch {
            if let saved { TerminalIO.restore(0, saved) }
            Console.error("\r\nattach: \(error)\n")
            return 1
        }
        if let saved { TerminalIO.restore(0, saved) }
        return status
    }

    private static func sendWindowSize(_ connection: HolderConnection) throws {
        guard let size = TerminalIO.windowSize(0), size.cols > 0, size.rows > 0 else { return }
        try connection.send(.resize(WindowSize(
            cols: size.cols, rows: size.rows, pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight)))
    }

    /// kqueue loop over stdin, the socket and SIGWINCH / SIGTERM / SIGHUP.
    private static func bridge(_ connection: HolderConnection) throws -> Int32 {
        let queue = kqueue()
        guard queue >= 0 else { throw SystemError.current("kqueue") }
        defer { Descriptor.closeQuietly(queue) }
        signal(SIGWINCH, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        var changes = [
            kevent(ident: 0, filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(connection.fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGWINCH), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGHUP), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
        ]
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0 else { throw SystemError.current("kevent") }

        var events = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 8)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = kevent(queue, nil, 0, &events, Int32(events.count), nil)
            if count < 0 {
                if errno == EINTR { continue }
                throw SystemError.current("kevent wait")
            }
            for event in events[0..<Int(count)] {
                switch Int32(event.filter) {
                case EVFILT_READ where event.ident == 0:
                    let read = buffer.withUnsafeMutableBytes { Darwin.read(0, $0.baseAddress, $0.count) }
                    if read <= 0 {
                        if read < 0 && errno == EINTR { continue }
                        try connection.send(.detach)
                        return 0
                    }
                    let chunk = Array(buffer[0..<read])
                    if let keyIndex = chunk.firstIndex(of: detachKey) {
                        if keyIndex > 0 { try connection.send(Message.inputMessages(Array(chunk[..<keyIndex]), submit: false)) }
                        try connection.send(.detach)
                        Console.error("\r\n[detached]\r\n")
                        return 0
                    }
                    try connection.send(Message.inputMessages(chunk, submit: false))
                case EVFILT_READ:
                    while let message = try connection.receive(timeoutMilliseconds: 0) {
                        if let status = handle(message) { return status }
                    }
                case EVFILT_SIGNAL where event.ident == UInt(SIGWINCH):
                    try sendWindowSize(connection)
                case EVFILT_SIGNAL:
                    try? connection.send(.detach)
                    return 0
                default:
                    break
                }
            }
        }
    }

    /// Returns an exit status when the session ended or the holder closed us.
    private static func handle(_ message: Message) -> Int32? {
        switch message {
        case .output(_, let bytes):
            Console.outBytes(bytes)
        case .gap(let from, let to):
            Console.error("\r\n[codd-holderctl: missed \(to - from) bytes of output]\r\n")
        case .exit(let info):
            Console.error("\r\n[session exited: \(info.signaled ? "signal" : "status") \(info.status)]\r\n")
            return 0
        case .error(let info):
            Console.error("\r\n[holder: \(info)]\r\n")
            return 1
        default:
            break
        }
        return nil
    }
}
