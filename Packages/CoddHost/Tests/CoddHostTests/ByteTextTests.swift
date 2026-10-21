import Testing
@testable import CoddHost

@Suite("ByteText")
struct ByteTextTests {
    static let k: Double = 1024
    static func bytes(_ value: Double, _ power: Int) -> UInt64 {
        UInt64((value * pow1024(power)).rounded())
    }
    static func pow1024(_ n: Int) -> Double { (0..<n).reduce(1) { acc, _ in acc * k } }

    @Test(arguments: [
        // The artboard's own figures.
        (bytes(21.4, 3), "21.4G"),
        (bytes(36, 3), "36G"),
        (bytes(412, 3), "412G"),
        (bytes(1, 4), "1T"),
        (bytes(412, 2), "412MB"),
        (bytes(1.2, 3), "1.2G"),
        (bytes(13.8, 3), "13.8G"),
        (bytes(2, 3), "2G"),
        (0, "0B"),
        // Plain bytes are whole.
        (1, "1B"),
        (1023, "1023B"),
        // Kilobytes and the one-decimal rule below 100.
        (1024, "1KB"),
        (1536, "1.5KB"),
        (bytes(99.94, 1), "99.9KB"),
        (bytes(99.96, 1), "100KB"),
        (bytes(100.4, 1), "100KB"),
        (bytes(100.5, 1), "101KB"),
        (bytes(5.05, 2), "5.1MB"),
        (bytes(5.04, 2), "5MB"),
        // Rounding up to 1024 moves to the next unit.
        (bytes(1023.4, 2), "1023MB"),
        (bytes(1023.6, 2), "1G"),
        (bytes(1, 3) - 1, "1G"),
        (bytes(1.04, 4), "1T"),
        (bytes(1.05, 4), "1.1T"),
        (bytes(2.5, 5), "2.5P"),
        (UInt64.max, "16E"),
    ])
    func table(input: UInt64, expected: String) {
        #expect(ByteText.short(input) == expected)
    }
}
