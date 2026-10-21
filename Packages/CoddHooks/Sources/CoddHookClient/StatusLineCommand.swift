import Darwin

/// Names `codd-statusline` reads, besides ``HookWireNames``. Duplicated from CoddCore
/// (`CoddEnvironmentName`) for the same reason as ``HookWireNames``.
public enum StatusLineWireNames {
    /// Base64 of the user's own status-line command, chained after the report (M3 D8).
    public static let chainEnvironment = "CODD_STATUSLINE_CHAIN"
    /// Test knob: the chain timeout in milliseconds. Only shortens the default (1…10000); see
    /// ``StatusLineCommand/chainTimeoutMilliseconds``.
    public static let timeoutEnvironment = "CODD_STATUSLINE_TIMEOUT_MS"
    public static let claudeConfigDirEnvironment = "CLAUDE_CONFIG_DIR"
    public static let homeEnvironment = "HOME"
    /// The endpoint path; the per-session URL is `CODD_HOOK_URL` with its path replaced by this.
    public static let path = "/statusline"
}

/// The `codd-statusline` command (M3 D8 / D11): Claude Code's status-line `command` for CODD
/// sessions, and optionally the global one.
///
///     per session : codd-statusline-<hex12>                          (CODD_HOOK_URL, CODD_HOOK_TOKEN,
///                                                                     CODD_SESSION_ID, CODD_STATUSLINE_CHAIN)
///     global      : codd-statusline --data-root <root> [--chain-b64 <b64>]   (port + token from <root>/config.json)
///
/// Claude writes one JSON object to stdin per refresh. The command forwards its `rate_limits`
/// member verbatim to `POST /statusline` and runs the user's own status line (the "chain") with
/// the same stdin, so the user still sees theirs. This type only decides what to send and what to
/// run; ``StatusLineMain`` does the process work.
public struct StatusLineCommand: Sendable, Equatable {
    /// The endpoint's body limit for `/statusline` (CoddHooks `HookRequestPolicy.statusLineMaxBodyBytes`).
    public static let maxReportBytes = 64 * 1024
    /// stdin beyond this is not buffered (Claude's input is a few KiB).
    public static let maxStdinBytes = 1 << 20
    public static let stdinBudgetMilliseconds = 1000
    /// Writing stdin to the chain (the pipe buffer takes typical inputs at once).
    public static let chainStdinBudgetMilliseconds = 500
    /// Connect, send and read the status: the report must never delay the status line noticeably.
    public static let postBudgetMilliseconds = 300
    public static let defaultChainTimeoutMilliseconds = 10_000
    /// Between SIGTERM and SIGKILL to the chain's process group.
    public static let killGraceMilliseconds = 1000
    /// `<dataRoot>/config.json` is about 100 bytes; anything larger is not CODD's.
    public static let maxConfigBytes = 4096
    /// A `session_id` token longer than this is reported as `null` (Claude's is a UUID).
    static let maxSessionIDTokenBytes = 258

    /// `--data-root <dir>`: global mode (D11).
    public var dataRoot: String?
    /// `--url <u>`, else `CODD_HOOK_URL` (per-session mode; only its port is used).
    public var url: String?
    /// `CODD_HOOK_TOKEN` (per-session mode).
    public var token: String?
    /// `CODD_SESSION_ID` (per-session mode).
    public var sessionID: String?
    /// ``StatusLineAccountKey`` of `CLAUDE_CONFIG_DIR` / `HOME`.
    public var configKey: String
    /// The decoded chain: `--chain-b64`, else `CODD_STATUSLINE_CHAIN`. `nil` when absent, invalid
    /// base64, not UTF-8, containing NUL, or blank.
    public var chain: String?
    /// `CODD_STATUSLINE_TIMEOUT_MS` when it is 1…10000, else 10000. It can only shorten the
    /// timeout, so an inherited value can never make a status line hold Claude longer.
    public var chainTimeoutMilliseconds: Int
    /// `CODD_HOOK_DEBUG=1`: one diagnostic line per run on stderr.
    public var debug: Bool

    public init(dataRoot: String?, url: String?, token: String?, sessionID: String?, configKey: String, chain: String?,
                chainTimeoutMilliseconds: Int = StatusLineCommand.defaultChainTimeoutMilliseconds, debug: Bool = false) {
        self.dataRoot = dataRoot
        self.url = url
        self.token = token
        self.sessionID = sessionID
        self.configKey = configKey
        self.chain = chain
        self.chainTimeoutMilliseconds = chainTimeoutMilliseconds
        self.debug = debug
    }

    /// Lenient argv parsing like ``HookCommand``: `--flag value` and `--flag=value`, unknown
    /// arguments ignored, a flag without a value is `nil`. `arguments[0]` is the program.
    public init(arguments: [String], environment: (String) -> String?) {
        let flags = ["--data-root", "--chain-b64", "--url"]
        // A flag that was given, even without a value; the value when it had one.
        var given: Set<String> = []
        var values: [String: String] = [:]
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if flags.contains(arg) {
                given.insert(arg)
                if i + 1 < arguments.count { values[arg] = arguments[i + 1] }
                i += 2
                continue
            }
            if let flag = flags.first(where: { arg.hasPrefix($0 + "=") }) {
                given.insert(flag)
                values[flag] = String(arg.dropFirst(flag.count + 1))
            }
            i += 1
        }
        func flag(_ name: String) -> String? { values[name].flatMap { $0.isEmpty ? nil : $0 } }
        func env(_ name: String) -> String? { environment(name).flatMap { $0.isEmpty ? nil : $0 } }

        // `--chain-b64` wins over the environment even when it is invalid: the global wrapper's
        // own chain is the one to run, never a variable inherited from some other session.
        let chainText = given.contains("--chain-b64") ? flag("--chain-b64") : env(StatusLineWireNames.chainEnvironment)
        self.init(
            dataRoot: flag("--data-root"),
            url: flag("--url") ?? env(HookWireNames.urlEnvironment),
            token: env(HookWireNames.tokenEnvironment),
            sessionID: env(HookWireNames.sessionEnvironment),
            configKey: StatusLineAccountKey.from(claudeConfigDir: environment(StatusLineWireNames.claudeConfigDirEnvironment),
                                                 home: environment(StatusLineWireNames.homeEnvironment)),
            chain: chainText.flatMap(Self.decodeChain),
            chainTimeoutMilliseconds: Self.timeout(environment(StatusLineWireNames.timeoutEnvironment)),
            debug: environment(HookWireNames.debugEnvironment) == "1")
    }

    static func decodeChain(_ base64: String) -> String? {
        guard let bytes = Base64.decode(base64), !bytes.contains(0),
              let text = String(validating: bytes, as: UTF8.self),
              text.utf8.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }) else { return nil }
        return text
    }

    static func timeout(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 5, raw.utf8.allSatisfy(ASCII.isDigit), let ms = Int(raw),
              (1...defaultChainTimeoutMilliseconds).contains(ms) else { return defaultChainTimeoutMilliseconds }
        return ms
    }

    // MARK: - Endpoint

    /// Why no report is sent.
    public enum Skip: String, Error, Sendable, Equatable {
        case noEndpoint = "no --data-root, --url or CODD_HOOK_URL"
        case notLoopbackURL = "url is not http://127.0.0.1 or http://localhost"
        case missingToken = "CODD_HOOK_TOKEN missing or unsafe"
        case configUnreadable = "config.json missing, unreadable or over 4 KiB"
        case configInvalid = "config.json has no valid port and token"
    }

    /// Where to post: `(port, token, session)`. Global mode (`--data-root`) reads
    /// `<root>/config.json` through `readFile` and never sends a session; per-session mode uses the
    /// port of `--url` / `CODD_HOOK_URL` (loopback only, the path becomes `/statusline`), the token
    /// and `CODD_SESSION_ID` when it is a canonical UUID (another value would only get the report
    /// refused, and the account numbers do not need it).
    public func endpoint(readFile: (String) -> [UInt8]?) -> (port: UInt16, token: String, session: String?)? {
        try? resolveEndpoint(readFile: readFile).get()
    }

    public func resolveEndpoint(readFile: (String) -> [UInt8]?) -> Result<(port: UInt16, token: String, session: String?), Skip> {
        if let dataRoot {
            guard let bytes = readFile(Self.configPath(dataRoot: dataRoot)), bytes.count <= Self.maxConfigBytes else {
                return .failure(.configUnreadable)
            }
            guard let m = JSONScan.members(bytes),
                  let port = m["port"].flatMap({ JSONScan.integer(bytes, $0) }), (1...65535).contains(port),
                  let token = m["token"].flatMap({ JSONScan.string(bytes, $0) }), ASCII.isSafeHeaderValue(token) else {
                return .failure(.configInvalid)
            }
            return .success((UInt16(port), token, nil))
        }
        guard let url else { return .failure(.noEndpoint) }
        guard let target = LoopbackURL(url) else { return .failure(.notLoopbackURL) }
        guard let token, ASCII.isSafeHeaderValue(token) else { return .failure(.missingToken) }
        return .success((target.port, token, sessionID.flatMap { Self.isCanonicalUUID($0) ? $0 : nil }))
    }

    /// `<dataRoot>/config.json`.
    public static func configPath(dataRoot: String) -> String {
        StatusLineAccountKey.trimmingTrailingSlashes(dataRoot) + "/config.json"
    }

    /// 8-4-4-4-12 hex digits (the server's `X-CODD-Session` rule).
    static func isCanonicalUUID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 36 else { return false }
        for (i, c) in b.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard c == UInt8(ascii: "-") else { return false }
            } else {
                guard JSONScan.hexValue(c) != nil else { return false }
            }
        }
        return true
    }

    // MARK: - Report

    /// `{"v":1,"session_id":<string or null>,"config_key":"<key>","rate_limits":<raw or null>}`.
    /// `rate_limits` is the stdin member's bytes verbatim (any JSON value; the server interprets
    /// it), `null` when stdin is not a valid JSON object, has no such member, or the body would
    /// exceed ``maxReportBytes``. A `session_id` that is not a short string is `null`.
    public func reportBody(stdin: [UInt8]) -> [UInt8] {
        let m = JSONScan.members(stdin)
        let null = Array("null".utf8)
        var session = null
        if let r = m?["session_id"], stdin[r.lowerBound] == UInt8(ascii: "\""), r.count <= Self.maxSessionIDTokenBytes {
            session = Array(stdin[r])
        }
        func body(_ rateLimits: ArraySlice<UInt8>) -> [UInt8] {
            var out = Array(#"{"v":1,"session_id":"#.utf8)
            out.reserveCapacity(out.count + session.count + rateLimits.count + 64)
            out += session
            out += Array(#","config_key":""#.utf8)
            out += Array(configKey.utf8.filter { ASCII.isSafeKeyByte($0) })
            out += Array(#"","rate_limits":"#.utf8)
            out += rateLimits
            out.append(UInt8(ascii: "}"))
            return out
        }
        if let r = m?["rate_limits"] {
            let full = body(stdin[r])
            if full.count <= Self.maxReportBytes { return full }
        }
        return body(null[...])
    }

    /// The complete request, or why there is none.
    public func request(stdin: [UInt8], readFile: (String) -> [UInt8]?) -> Result<(port: UInt16, bytes: [UInt8]), Skip> {
        switch resolveEndpoint(readFile: readFile) {
        case .failure(let skip):
            return .failure(skip)
        case .success(let endpoint):
            var headers = [("Content-Type", "application/json"), (HookWireNames.tokenHeader, endpoint.token)]
            if let session = endpoint.session { headers.append((HookWireNames.sessionHeader, session)) }
            let target = LoopbackURL(authority: "127.0.0.1:\(endpoint.port)", port: endpoint.port, target: StatusLineWireNames.path)
            let bytes = LoopbackHTTPClient.requestBytes(method: "POST", url: target, headers: headers,
                                                        body: reportBody(stdin: stdin), userAgent: "codd-statusline/1")
            return .success((endpoint.port, bytes))
        }
    }
}

extension ASCII {
    /// Characters of an account key (`default`, `cswap-3`, `cfg-<hex>`): never needs JSON escaping.
    static func isSafeKeyByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x61...0x7A).contains(b) || (0x41...0x5A).contains(b) || b == UInt8(ascii: "-")
    }
}

/// Reads `<dataRoot>/config.json` for global mode: a regular file (the last component is not
/// followed if it is a symlink) owned by this user, at most `limit` bytes.
public enum StatusLineConfigFile {
    public static func read(_ path: String, limit: Int = StatusLineCommand.maxConfigBytes) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= off_t(limit) else { return nil }
        var out = [UInt8](repeating: 0, count: limit + 1)
        var total = 0
        while total <= limit {
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if n > 0 {
                total += n
            } else if n == 0 {
                break
            } else if errno != EINTR {
                return nil
            }
        }
        guard total <= limit else { return nil }
        return Array(out[0..<total])
    }
}
