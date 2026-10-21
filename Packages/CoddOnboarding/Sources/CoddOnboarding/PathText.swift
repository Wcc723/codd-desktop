import Foundation

/// Path spelling for the wizard: comparisons, `~` for the home folder, front elision (D10).
public enum PathText {
    /// `path` lexically standardized: `~/` expanded with `home`, `.` and `..` resolved, repeated and
    /// trailing slashes dropped. Symlinks are not resolved (D8 compares spellings).
    public static func standardize(_ path: String, home: String? = nil) -> String {
        var path = path
        if let home, path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `~` for the home folder (`/Users/x/Github/a` → `~/Github/a`); other paths as they are.
    public static func abbreviate(_ path: String, home: String) -> String {
        let home = standardize(home)
        guard home != "/", !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The parent folder (`/a/b/c` → `/a/b`; `/a` → `/`).
    public static func parent(_ path: String) -> String {
        let standardized = standardize(path)
        guard let slash = standardized.lastIndex(of: "/"), slash != standardized.startIndex else { return "/" }
        return String(standardized[..<slash])
    }

    /// The last path component (`/a/b/c` → `c`; `/` → `/`).
    public static func lastComponent(_ path: String) -> String {
        let standardized = standardize(path)
        guard standardized != "/" else { return "/" }
        return standardized.split(separator: "/").last.map(String.init) ?? standardized
    }

    /// The last two components behind `~/…/` (`~/Library/Application Support/CODD/notes` →
    /// `~/…/CODD/notes`), for the stepper's short notebook line. Short paths are kept.
    public static func compact(_ path: String) -> String {
        let (head, components) = split(path)
        guard components.count > 2 else { return path }
        return head + "/…/" + components.suffix(2).joined(separator: "/")
    }

    /// D10's PATH column rule: the full path when `fits` accepts it, else the front elided by whole
    /// components (`~/…/websites/業主/Northstar invoice system`), keeping as many trailing components
    /// as fit and at least the last one (which the caller then tail-truncates when even that is too
    /// wide). `fits` measures in the view's font; this stays pure so it is tested without AppKit.
    public static func elide(_ path: String, fits: (String) -> Bool) -> String {
        if fits(path) { return path }
        let (head, components) = split(path)
        guard components.count > 1 else { return path }
        for keep in stride(from: components.count - 1, through: 1, by: -1) {
            let candidate = head + "/…/" + components.suffix(keep).joined(separator: "/")
            if fits(candidate) { return candidate }
        }
        return head + "/…/" + (components.last ?? "")
    }

    /// The root marker (`~` or empty for `/`) and the components after it.
    private static func split(_ path: String) -> (String, [String]) {
        if path == "~" { return ("~", []) }
        if path.hasPrefix("~/") {
            return ("~", path.dropFirst(2).split(separator: "/").map(String.init))
        }
        return ("", path.split(separator: "/").map(String.init))
    }
}

/// The 最近使用 column (D10): `今天 10:34`, `昨天 22:47`, else `10/13`, `9/21` (month unpadded, day
/// padded, as the artboard), `—` without a date. `now` and the time zone are injected (tests,
/// samples); the App passes the current ones.
public enum LastUsedFormat {
    public static func text(_ date: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let date else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let clock = "\(pad(hour)):\(pad(minute))"
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today { return "今天 \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "昨天 \(clock)" }
        return "\(parts.month ?? 1)/\(pad(parts.day ?? 1))"
    }

    private static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
