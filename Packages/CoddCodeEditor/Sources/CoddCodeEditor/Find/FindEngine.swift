import Foundation

/// The find widget's three toggles (`Aa`, `ab`, `.*`).
public struct FindOptions: Sendable, Equatable {
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public enum FindError: Error, Equatable, Sendable {
    /// The `.*` query does not compile (the widget shows `—` and an amber-dim field).
    case invalidPattern(String)
}

/// Text search for the find widget: literal or ICU regular expression, case and whole-word options,
/// and `$1` group templates for replacements. Ranges are UTF-16 (`NSRange`). Empty matches are
/// never reported (nothing to highlight or step through).
///
/// Whole word: a match may not continue a Latin / digit / `_` word on either side. CJK characters
/// are their own words (中文 has no spaces), so `API` is a whole word in `修正API錯誤` but not in
/// `myAPI`, and a CJK query matches next to any neighbour.
public enum FindEngine {
    public static func matches(in text: String, query: String, options: FindOptions) throws -> [NSRange] {
        try matches(in: text as NSString, query: query, options: options)
    }

    /// The text that replaces `match` (one of `matches`' results): `template` with `$0`, `$1`, …
    /// filled in when `options.regex`, else `template` as is.
    public static func replacement(for match: NSRange, in text: String, query: String, template: String,
                                   options: FindOptions) throws -> String {
        try replacement(for: match, in: text as NSString, query: query, template: template, options: options)
    }

    static func matches(in text: NSString, query: String, options: FindOptions, limit: Int = .max) throws -> [NSRange] {
        guard !query.isEmpty, let expression = try expression(query: query, options: options) else { return [] }
        var found: [NSRange] = []
        expression.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { result, _, stop in
            guard let range = result?.range, range.length > 0 else { return }
            found.append(range)
            if found.count >= limit { stop.pointee = true }
        }
        return found
    }

    static func replacement(for match: NSRange, in text: NSString, query: String, template: String,
                            options: FindOptions) throws -> String {
        guard options.regex else { return template }
        guard let expression = try expression(query: query, options: options) else { return template }
        let rest = NSRange(location: match.location, length: text.length - match.location)
        if let result = expression.firstMatch(in: text as String, options: [.anchored, .withTransparentBounds], range: rest),
           result.range == match {
            return expression.replacementString(for: result, in: text as String, offset: 0, template: template)
        }
        // The text changed since the match was found: fill the groups from the match alone.
        let substring = text.substring(with: match)
        if let result = expression.firstMatch(in: substring, options: [], range: NSRange(location: 0, length: (substring as NSString).length)) {
            return expression.replacementString(for: result, in: substring, offset: 0, template: template)
        }
        return template
    }

    /// Latin-script word characters; CJK scripts are excluded (each of their characters is a word).
    private static let word = #"[[\p{L}\p{N}\p{M}_]--[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Bopomofo}]]"#
    private static let boundary = "(?:(?<!\(word))|(?!\(word)))"

    static func expression(query: String, options: FindOptions) throws -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = boundary + "(?:" + pattern + ")" + boundary }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw FindError.invalidPattern(query)
        }
    }
}
