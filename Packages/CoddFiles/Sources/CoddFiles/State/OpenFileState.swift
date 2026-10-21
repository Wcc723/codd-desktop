import Foundation

/// The pure state machine of one open editor tab (D24, D25, D27). No I/O except ``load(_:)``;
/// the app feeds it the watcher's reads and the saver's results.
///
/// - `savedText` is the text the tab is in sync with on disk (the last load, reload, save or
///   保留我的); `isDirty` compares the buffer with it.
/// - A disk change while clean reloads in place; while dirty it raises the banner and keeps the
///   new disk version in `pendingDisk` until 重新載入 / 保留我的.
/// - A change attributed to an AI session keeps the text from before it as `aiBaseline`
///   (`基準：AI 開始前 HH:mm`, memory only); later changes by the same session keep the first one.
public struct OpenFileState: Sendable, Equatable {
    /// The disk version that arrived while the buffer was dirty.
    public struct PendingDisk: Sendable, Equatable {
        /// nil when the new bytes are not text the editor can open (binary, too large).
        public var decoded: DecodedText?
        public var fingerprint: FileFingerprint
        public var aiSession: String?
        public var at: Date
    }

    public var url: URL
    public var decoded: DecodedText
    public var savedText: String
    public var savedAt: Date
    public var disk: FileFingerprint
    public var buffer: String
    public var aiBaseline: (text: String, at: Date, session: String?)?
    public var pendingDisk: PendingDisk?

    public var isDirty: Bool { buffer != savedText }
    /// The disk-change banner shows.
    public var showsBanner: Bool { pendingDisk != nil }
    /// 重新載入 can apply the pending version (it decoded as text).
    public var canReload: Bool { pendingDisk?.decoded != nil }

    public init(url: URL, decoded: DecodedText, disk: FileFingerprint, at: Date = Date()) {
        self.url = url
        self.decoded = decoded
        self.savedText = decoded.text
        self.savedAt = at
        self.disk = disk
        self.buffer = decoded.text
    }

    /// Reads and decodes `url` (refused above ``TextFileCodec/refuseBytes`` before reading).
    /// Synchronous I/O: call off the main actor.
    public static func load(_ url: URL) throws -> OpenFileState {
        try load(url, at: Date())
    }

    public static func load(_ url: URL, at: Date) throws -> OpenFileState {
        let (data, fingerprint) = try FileFingerprint.read(url)
        switch TextFileCodec.decode(data) {
        case .success(let decoded): return OpenFileState(url: url, decoded: decoded, disk: fingerprint, at: at)
        case .failure(let error): throw error
        }
    }

    public mutating func edit(_ text: String) {
        buffer = text
    }

    public enum DiskDecision: Sendable, Equatable {
        /// Nothing to do (same contents, e.g. CODD's own save or a `touch`).
        case none
        /// The clean buffer now shows the disk text.
        case reloaded
        /// Dirty buffer: show the banner (`aiSession` nil → `磁碟上的檔案已變更`).
        case banner(aiSession: String?, at: Date)
    }

    /// The watcher saw a change and the app read `newData` with `fingerprint`. `aiTouch` is the
    /// CODD session whose PostToolUse named this file within the attribution window (D25: ±10 s).
    public mutating func diskChanged(newData: Data, fingerprint: FileFingerprint, aiTouch: (session: String, at: Date)?,
                                     now: Date = Date()) -> DiskDecision {
        if fingerprint.sameContent(as: disk) {
            // Unchanged, or changed back to the version the tab is based on: no banner any more.
            disk = fingerprint
            pendingDisk = nil
            return .none
        }
        if let pending = pendingDisk, pending.fingerprint.sameContent(as: fingerprint) {
            pendingDisk?.fingerprint = fingerprint
            return .none
        }
        let newDecoded = try? TextFileCodec.decode(newData).get()
        if let aiTouch { noteAIChange(session: aiTouch.session, at: aiTouch.at, before: pendingDisk?.decoded?.text ?? savedText) }
        if !isDirty, let newDecoded {
            decoded = newDecoded
            savedText = newDecoded.text
            buffer = newDecoded.text
            savedAt = now
            disk = fingerprint
            pendingDisk = nil
            return .reloaded
        }
        let at = aiTouch?.at ?? now
        pendingDisk = PendingDisk(decoded: newDecoded, fingerprint: fingerprint, aiSession: aiTouch?.session, at: at)
        return .banner(aiSession: aiTouch?.session, at: at)
    }

    /// 保留我的: the buffer stays; the disk version becomes the base the next save is checked
    /// against (so ⌘S overwrites it on purpose) and `isDirty` compares with it.
    public mutating func keepMine(now: Date = Date()) {
        guard let pending = pendingDisk else { return }
        disk = pending.fingerprint
        if let newDecoded = pending.decoded {
            decoded = newDecoded
            savedText = newDecoded.text
            savedAt = now
        }
        pendingDisk = nil
    }

    /// 重新載入: the buffer takes the pending disk text (the edits are dropped; the app keeps undo).
    public mutating func reloadFromDisk(now: Date = Date()) {
        guard let pending = pendingDisk, let newDecoded = pending.decoded else { return }
        decoded = newDecoded
        savedText = newDecoded.text
        buffer = newDecoded.text
        disk = pending.fingerprint
        savedAt = now
        pendingDisk = nil
    }

    /// ⌘S wrote `text` (the buffer when the write started; nil: the buffer now) with
    /// `fingerprint`. The decoded facts follow what was written (a mixed-EOL file's per-line
    /// endings are those ``TextFileCodec/encode(_:like:)`` chose). The buffer is left alone, so
    /// text typed while the write ran keeps the tab dirty.
    public mutating func saved(_ fingerprint: FileFingerprint, at: Date, text: String? = nil) {
        let text = text ?? buffer
        if decoded.mixedLineEndings, let data = try? TextFileCodec.encode(text, like: decoded),
           case .success(var written) = TextFileCodec.decode(data) {
            written.readOnly = decoded.readOnly
            decoded = written
        } else {
            decoded.text = text
        }
        savedText = text
        savedAt = at
        disk = fingerprint
        pendingDisk = nil
    }

    /// The bytes ⌘S writes.
    public func encodedBuffer() throws -> Data {
        try TextFileCodec.encode(buffer, like: decoded)
    }

    private mutating func noteAIChange(session: String, at: Date, before: String) {
        if let existing = aiBaseline, existing.session == session { return }
        aiBaseline = (text: before, at: at, session: session)
    }

    public static func == (lhs: OpenFileState, rhs: OpenFileState) -> Bool {
        lhs.url == rhs.url && lhs.decoded == rhs.decoded && lhs.savedText == rhs.savedText && lhs.savedAt == rhs.savedAt
            && lhs.disk == rhs.disk && lhs.buffer == rhs.buffer && lhs.pendingDisk == rhs.pendingDisk
            && lhs.aiBaseline?.text == rhs.aiBaseline?.text && lhs.aiBaseline?.at == rhs.aiBaseline?.at
            && lhs.aiBaseline?.session == rhs.aiBaseline?.session && (lhs.aiBaseline == nil) == (rhs.aiBaseline == nil)
    }
}
