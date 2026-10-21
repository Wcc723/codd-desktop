import CCoddShim
import Darwin

/// Window-size ioctls (TIOCSWINSZ / TIOCGWINSZ are function-like macros Swift cannot import).
public enum TerminalIO {
    public static func setWindowSize(
        _ fd: Int32, cols: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0
    ) throws(SystemError) {
        guard codd_set_winsize(fd, cols, rows, pixelWidth, pixelHeight) == 0 else { throw .current("TIOCSWINSZ") }
    }

    /// (cols, rows, pixelWidth, pixelHeight) of a terminal descriptor.
    public static func windowSize(_ fd: Int32) -> (cols: UInt16, rows: UInt16, pixelWidth: UInt16, pixelHeight: UInt16)? {
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        var width: UInt16 = 0
        var height: UInt16 = 0
        guard codd_get_winsize(fd, &cols, &rows, &width, &height) == 0 else { return nil }
        return (cols, rows, width, height)
    }

    /// Puts a terminal into raw mode and returns the previous attributes for `restore`.
    public static func makeRaw(_ fd: Int32) throws(SystemError) -> termios {
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { throw .current("tcgetattr") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(fd, TCSAFLUSH, &raw) == 0 else { throw .current("tcsetattr") }
        return original
    }

    public static func restore(_ fd: Int32, _ attributes: termios) {
        var attributes = attributes
        _ = tcsetattr(fd, TCSAFLUSH, &attributes)
    }
}
