/// Paths the composer inserts (pasted images, dropped files), M2 plan D31.
public enum ComposerPaths {
    /// The characters a Terminal.app drop puts a backslash before.
    static let escapedScalars: Set<Unicode.Scalar> = [
        " ", "\t", "'", "\"", "`", "$", "&", ";", "|", "<", ">", "(", ")", "[", "]", "{", "}",
        "*", "?", "!", "#", "~", "=", "%", "\\",
    ]

    /// Escapes `path` like a Terminal.app drop: a backslash before space, TAB, quotes and shell
    /// metacharacters (and before a backslash). Claude Code recognizes this form as a file
    /// attachment; the default data root contains `Application Support`, so an unescaped path
    /// would split at the space. Everything else, CJK included, is left as is.
    public static func escaped(_ path: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if escapedScalars.contains(scalar) {
                out.append("\\")
            }
            out.append(scalar)
        }
        return String(out)
    }

    /// Whether `path` can be inserted as text at all: no line break of any kind (LF, CR, NEL,
    /// U+2028 / U+2029) and no other control character but TAB. A backslash does not keep a
    /// line break inside the word: the send turns it into a Return, and a shell tab would run the
    /// rest of the name as a second command (review security-data-3).
    public static func isInsertable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x09: false
            case 0x00 ... 0x1F, 0x7F, 0x80 ... 0x9F, 0x2028, 0x2029: true
            default: false
            }
        }
    }
}
