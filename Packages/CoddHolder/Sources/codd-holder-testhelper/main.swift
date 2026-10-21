import CoddPosix
import Darwin

/// Child-side probes for the integration tests (run as the holder's child).
///
///   fds     print the open descriptor numbers ("0 1 2") and exit
///   stamp   raw mode; print "READY", then for each input byte "<hex> <CLOCK_UPTIME_RAW ns>"; 'Q' exits
///   chunks [bracketed]
///           raw mode (with `bracketed`, first `ESC [ ? 2004 h`); print "READY", then for each read()
///           "C <CLOCK_UPTIME_RAW µs> <hex bytes>"
///   flood <bytes> [clearEvery]
///           raw mode; print "READY", wait for one input byte, then write <bytes> of numbered lines
///           ("L0000000001\n", unique per offset) with `ESC [ 2 J` before every <clearEvery>th
///           (default 1000, 0 = never), print "FLOOD-END", and wait for EOF
let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    try? Descriptor.writeAll(2, "usage: codd-holder-testhelper fds|stamp|chunks|flood\n")
    exit(64)
}

/// Lowercase hex of `bytes`, two digits each.
func hex(_ bytes: UnsafeRawBufferPointer) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

switch arguments[1] {
case "fds":
    var open: [String] = []
    for fd in Int32(0)..<Int32(4096) where fcntl(fd, F_GETFD) >= 0 {
        open.append(String(fd))
    }
    try? Descriptor.writeAll(1, "FDS " + open.joined(separator: " ") + "\n")
    exit(0)

case "stamp":
    _ = try? TerminalIO.makeRaw(0)
    try? Descriptor.writeAll(1, "READY\r\n")
    var byte: UInt8 = 0
    while true {
        let count = read(0, &byte, 1)
        guard count == 1 else { exit(0) }
        let now = Clock.monotonicNanoseconds()
        let hex = String(byte, radix: 16)
        try? Descriptor.writeAll(1, "S \(hex.count == 1 ? "0" + hex : hex) \(now)\r\n")
        if byte == UInt8(ascii: "Q") { exit(0) }
    }

case "chunks":
    _ = try? TerminalIO.makeRaw(0)
    if arguments.count >= 3, arguments[2] == "bracketed" {
        try? Descriptor.writeAll(1, "\u{1B}[?2004h")
    }
    try? Descriptor.writeAll(1, "READY\r\n")
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        guard count > 0 else { exit(0) }
        let micros = Clock.monotonicNanoseconds() / 1000
        let text = buffer.withUnsafeBytes { hex(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        try? Descriptor.writeAll(1, "C \(micros) \(text)\r\n")
    }

case "flood":
    let total = arguments.count >= 3 ? Int(arguments[2]) ?? 0 : 0
    let clearEvery = arguments.count >= 4 ? UInt64(arguments[3]) ?? 1000 : 1000
    _ = try? TerminalIO.makeRaw(0)
    try? Descriptor.writeAll(1, "READY\r\n")
    var byte: UInt8 = 0
    guard read(0, &byte, 1) == 1 else { exit(0) }
    let clear: [UInt8] = [0x1B, 0x5B, 0x32, 0x4A]
    var line: UInt64 = 0
    var written = 0
    var chunk: [UInt8] = []
    chunk.reserveCapacity(64 * 1024 + 32)
    while written < total {
        chunk.removeAll(keepingCapacity: true)
        while chunk.count < 64 * 1024 {
            line += 1
            if clearEvery > 0, line % clearEvery == 0 { chunk.append(contentsOf: clear) }
            chunk.append(UInt8(ascii: "L"))
            var digits = [UInt8](repeating: UInt8(ascii: "0"), count: 10)
            var value = line
            for index in stride(from: 9, through: 0, by: -1) {
                digits[index] = UInt8(ascii: "0") + UInt8(value % 10)
                value /= 10
            }
            chunk.append(contentsOf: digits)
            chunk.append(0x0A)
        }
        let count = min(chunk.count, total - written)
        guard (try? chunk.withUnsafeBytes({ try Descriptor.writeAll(1, UnsafeRawBufferPointer(rebasing: $0[0..<count])) })) != nil else {
            exit(0)
        }
        written += count
    }
    try? Descriptor.writeAll(1, "FLOOD-END\r\n")
    while read(0, &byte, 1) == 1 {}
    exit(0)

default:
    try? Descriptor.writeAll(2, "unknown probe \(arguments[1])\n")
    exit(64)
}
