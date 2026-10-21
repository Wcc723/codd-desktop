import Darwin

/// A failed system call: the operation that failed plus its errno.
public struct SystemError: Error, Sendable, Equatable, CustomStringConvertible {
    public var operation: String
    public var code: Int32

    public init(_ operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    /// Captures the current `errno`.
    public static func current(_ operation: String) -> SystemError {
        SystemError(operation, code: errno)
    }

    public var description: String {
        "\(operation): \(String(cString: strerror(code))) (errno \(code))"
    }
}
