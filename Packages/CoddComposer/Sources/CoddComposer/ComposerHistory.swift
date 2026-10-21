/// One session's sent prompts, walked with ↑ / ↓ like a shell history.
///
/// Only `entries` is persisted and compared: the walk position and the stashed text are transient
/// UI state, so a history read back from disk equals the one that was saved.
public struct ComposerHistory: Sendable, Equatable, Codable {
    /// Newest entries kept (M2 plan D3).
    public static let limit = 100

    /// Oldest first.
    public private(set) var entries: [String]
    /// Index into `entries` of the entry shown while walking; nil when not walking.
    private var cursor: Int?
    /// What the composer held when the walk started; given back once when walking past the newest.
    private var stash: String?

    public init(entries: [String] = []) {
        self.entries = entries.suffix(Self.limit).map { $0 }
    }

    /// Adds a sent prompt: trailing whitespace trimmed, empty text ignored, a repeat of the newest
    /// entry collapsed, only the newest `limit` kept. Always ends a walk.
    public mutating func record(_ text: String) {
        resetCursor()
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return }
        let entry = String(trimmed)
        guard entries.last != entry else { return }
        entries.append(entry)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    /// One step back. The first step stashes `current` (the unsent text) and shows the newest entry;
    /// nil when there is nothing older (the composer keeps its text).
    public mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let index = cursor else {
            stash = current
            cursor = entries.count - 1
            return entries[entries.count - 1]
        }
        guard index > 0 else { return nil }
        cursor = index - 1
        return entries[index - 1]
    }

    /// One step forward. Past the newest entry it returns the stashed text once and ends the walk;
    /// nil when not walking.
    public mutating func next() -> String? {
        guard let index = cursor else { return nil }
        if index + 1 < entries.count {
            cursor = index + 1
            return entries[index + 1]
        }
        let stashed = stash ?? ""
        resetCursor()
        return stashed
    }

    /// Ends a walk (after a send, on a session switch); the next ↑ starts from the newest entry again.
    public mutating func resetCursor() {
        cursor = nil
        stash = nil
    }

    /// Whether a walk is in progress.
    public var isWalking: Bool {
        cursor != nil
    }

    /// The unsent text the walk stashed (it comes back past the newest entry); nil when not walking.
    /// Still a draft: the images it names are kept (post-M4 attachment expiry).
    public var stashedText: String? {
        stash
    }

    public static func == (lhs: ComposerHistory, rhs: ComposerHistory) -> Bool {
        lhs.entries == rhs.entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decodeIfPresent([String].self, forKey: .entries) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    /// The same entries with each one cut to at most `maxBytes` UTF-8 bytes (the state file's cap).
    func capped(entryBytes maxBytes: Int) -> ComposerHistory {
        ComposerHistory(entries: entries.map { ComposerText.prefix($0, maxUTF8: maxBytes) })
    }
}

enum ComposerText {
    /// The longest prefix of `text` that is at most `maxUTF8` bytes and ends on a character boundary.
    static func prefix(_ text: String, maxUTF8: Int) -> String {
        guard text.utf8.count > maxUTF8 else { return text }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if used + size > maxUTF8 { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
