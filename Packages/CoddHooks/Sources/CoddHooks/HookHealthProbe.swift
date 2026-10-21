import CoddHookClient
import Dispatch

/// Who answers on a hook port. Used when ``HookServerError/portInUse(_:)`` comes back: another
/// CODD (a second app instance, or later `coddd`) answers `/health` with `{"app":"codd"}`.
public enum HookHealthProbe {
    public enum Result: Sendable, Equatable {
        case codd
        /// Something answered, but not as CODD (status, or 0 when the response was not HTTP).
        case otherService(status: Int)
        case noListener
        case timedOut
    }

    /// `GET /health` on 127.0.0.1:`port`. Blocking socket work runs on a global queue.
    ///
    /// With `token`, `.codd` means proven: the answer carries the HMAC of a fresh nonce keyed with
    /// that token (``HookRequestPolicy/challengeHeader``), which only a CODD on the same data root
    /// can compute. A listener that merely says `{"app":"codd"}` is `.otherService(status: 200)`.
    public static func probe(port: UInt16, token: String? = nil, timeoutMilliseconds: Int = 500) async -> Result {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: probeSync(port: port, token: token, timeoutMilliseconds: timeoutMilliseconds))
            }
        }
    }

    static func probeSync(port: UInt16, token: String?, timeoutMilliseconds: Int) -> Result {
        let url = LoopbackURL(authority: "127.0.0.1:\(port)", port: port, target: HookRequestPolicy.healthPath)
        var expected = HookRequestPolicy.healthBody
        var headers: [(String, String)] = []
        if let token {
            var nonce = SystemRandomNumberGenerator()
            let challenge = (0..<4).map { _ in hex(nonce.next()) }.joined()
            headers.append((HookRequestPolicy.challengeHeader, challenge))
            expected = HookRequestPolicy(token: token, port: port).healthBody(challenge: challenge)
        }
        let request = LoopbackHTTPClient.requestBytes(method: "GET", url: url, headers: headers, body: [])
        switch LoopbackHTTPClient.send(request, port: port, deadline: .after(milliseconds: timeoutMilliseconds)) {
        case .success(let response):
            return response.status == 200 && response.body == expected ? .codd : .otherService(status: response.status)
        case .failure(.connect):
            return .noListener
        case .failure(.timedOut):
            return .timedOut
        case .failure:
            return .otherService(status: 0)
        }
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
