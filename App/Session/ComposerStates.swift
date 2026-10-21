import CoddComposer
import Darwin
import Foundation

/// Every session's composer draft and history (D3), read from `<sessionDir>/composer.json` the
/// first time a session needs it and written 500 ms after the last change. Reads and writes happen
/// off the main actor; writes go through one queue, in order. Sessions without a folder (mock
/// mode) keep theirs in memory only.
///
/// A change made before the file is in (typing into a just-opened composer) is queued and
/// applied on top of what the file held, so neither the edit nor the saved history is lost.
@MainActor
final class ComposerStates {
    /// `<sessionDir>` for a session, or nil (memory only).
    let directory: @MainActor (SessionID) -> String?
    let saveDelay: Duration
    private var states: [SessionID: ComposerState] = [:]
    private var loading: [SessionID: Task<Void, Never>] = [:]
    private var queued: [SessionID: [(inout ComposerState) -> Void]] = [:]
    private var pendingSaves: [SessionID: Task<Void, Never>] = [:]
    private var dirty: Set<SessionID> = []
    /// M5 D14: sessions whose composer.json a newer CODD wrote (its `v`): the draft and history
    /// stay in memory and nothing is saved over the file for the rest of the run.
    private(set) var newerFiles: [SessionID: Int] = [:]
    private let queue = DispatchQueue(label: CoddIdentity.label("composer-state"), qos: .utility)
    private let log: @MainActor (String) -> Void
    /// A session's state arrived from disk (the bar shows the draft if nothing was typed meanwhile).
    var onLoaded: ((SessionID) -> Void)?

    static let defaultSaveDelay: Duration = .milliseconds(500)

    init(directory: @escaping @MainActor (SessionID) -> String?, saveDelay: Duration = ComposerStates.defaultSaveDelay,
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.directory = directory
        self.saveDelay = saveDelay
        self.log = log
    }

    /// The state, or nil while it has not been read yet.
    func state(_ id: SessionID) -> ComposerState? { states[id] }

    /// Reads the session's state once (off the main actor); later calls wait for the same read.
    @discardableResult
    func load(_ id: SessionID) async -> ComposerState {
        if let state = states[id] { return state }
        if let task = loading[id] {
            await task.value
            return states[id] ?? .empty
        }
        guard let folder = directory(id) else {
            finishLoad(id, .empty)
            return states[id] ?? .empty
        }
        let task = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { ComposerStateFile.load(directory: folder) }.value
            self?.finishLoad(id, loaded)
        }
        loading[id] = task
        await task.value
        return states[id] ?? .empty
    }

    /// Starts the read without waiting (the bar is told through `onLoaded`).
    func prefetch(_ id: SessionID) {
        guard states[id] == nil, loading[id] == nil else { return }
        Task { [weak self] in await self?.load(id) }
    }

    private func finishLoad(_ id: SessionID, _ loaded: ComposerState) {
        loading[id] = nil
        guard states[id] == nil, !forgotten.contains(id) else { return }
        var state = loaded
        let edits = queued.removeValue(forKey: id) ?? []
        for edit in edits { edit(&state) }
        states[id] = state
        if !edits.isEmpty { scheduleSave(id) }
        onLoaded?(id)
    }

    /// Applies `change` now, or right after the read when the state is not in yet.
    private func mutate(_ id: SessionID, save: Bool = true, _ change: @escaping (inout ComposerState) -> Void) {
        guard !forgotten.contains(id) else { return }
        if var state = states[id] {
            change(&state)
            states[id] = state
        } else {
            queued[id, default: []].append(change)
            prefetch(id)
        }
        if save { scheduleSave(id) }
    }

    // MARK: Edits

    func setDraft(_ text: String, for id: SessionID) {
        guard states[id]?.draft != text else { return }
        mutate(id) { $0.draft = text }
    }

    /// After a send: the text goes into the history (consecutive duplicates collapse) and the draft
    /// empties.
    func recordSent(_ text: String, for id: SessionID) {
        mutate(id) { state in
            state.history.record(text)
            state.draft = ""
        }
    }

    /// ↑ on the first line: the previous entry (the text being edited is stashed on the first step).
    func previous(current: String, for id: SessionID) -> String? {
        guard var state = states[id] else { return nil }
        let entry = state.history.previous(current: current)
        states[id] = state
        return entry
    }

    /// ↓ on the last line: the next entry, past the newest the stashed text.
    func next(for id: SessionID) -> String? {
        guard var state = states[id] else { return nil }
        let entry = state.history.next()
        states[id] = state
        return entry
    }

    /// Leaves the history walk (session switch, send).
    func resetCursor(for id: SessionID) {
        guard var state = states[id], state.history.isWalking else { return }
        state.history.resetCursor()
        states[id] = state
    }

    /// The session left CODD: its state goes with its folder (no pending save recreates it; a
    /// read still in flight finds nothing to fill).
    func forget(_ id: SessionID) {
        states[id] = nil
        queued[id] = nil
        loading.removeValue(forKey: id)?.cancel()
        pendingSaves.removeValue(forKey: id)?.cancel()
        dirty.remove(id)
        forgotten.insert(id)
    }

    /// Sessions `forget` dropped: a read that finishes later does not bring them back.
    private var forgotten: Set<SessionID> = []

    /// Sessions with a state in memory (tests).
    var loadedSessionIDs: Set<SessionID> { Set(states.keys) }

    // MARK: Saving

    private func scheduleSave(_ id: SessionID) {
        guard directory(id) != nil, newerFiles[id] == nil else { return }
        dirty.insert(id)
        pendingSaves[id]?.cancel()
        let delay = saveDelay
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save(id)
        }
    }

    private func save(_ id: SessionID) {
        pendingSaves[id] = nil
        guard dirty.remove(id) != nil, newerFiles[id] == nil, let state = states[id], let folder = directory(id) else { return }
        queue.async { [weak self] in
            do {
                try ComposerStateFile.save(state, directory: folder)
            } catch ComposerStateFileError.newerVersion(let version) {
                // The file stays as the newer CODD wrote it; the session keeps its draft in memory.
                Task { @MainActor in self?.markNewer(id, version: version) }
            } catch {
                HolderSessionStore.printLog("error composer state \(folder): \(error)")
            }
        }
    }

    /// Stops saving `id` for the run (logged once per session).
    private func markNewer(_ id: SessionID, version: Int) {
        guard newerFiles[id] == nil else { return }
        newerFiles[id] = version
        pendingSaves.removeValue(forKey: id)?.cancel()
        dirty.remove(id)
        log("composer state session=\(id) v=\(version) newer: not saved")
    }

    /// Writes every pending change now and waits for the queue (app quit, tests).
    func flush() {
        for (id, task) in pendingSaves {
            task.cancel()
            save(id)
        }
        pendingSaves = [:]
        queue.sync {}
    }

    // MARK: Pasted images (D4, D31)

    /// Whether a pasted image can be saved for the session (it has a folder).
    func canSaveAttachment(for id: SessionID) -> Bool { directory(id) != nil }

    /// Saves a pasted image as `<sessionDir>/attachments/<yyyyMMdd-HHmmss>-<6 hex>.png` (folder
    /// 0700, file 0600) and returns the path escaped like a Terminal.app drop, or nil when the
    /// session has no folder, the data is not an image or the write failed. The TIFF re-encode
    /// and the write run off the main actor (review concurrency-perf-3); the path is returned
    /// only once the file exists, so a send never names a file that is not there yet.
    func saveAttachment(_ image: ComposerPastedImage, for id: SessionID, now: Date = Date()) async -> String? {
        guard let folder = directory(id) else { return nil }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(path: String, bytes: Int), AttachmentError> in
            guard let png = image.pngData() else { return .failure(.notAnImage) }
            do {
                return .success((try Self.writeAttachment(png, sessionDirectory: folder, now: now), png.count))
            } catch let error as AttachmentError {
                return .failure(error)
            } catch {
                return .failure(.io(folder, EIO))
            }
        }.value
        switch result {
        case .success(let saved):
            log("composer attachment session=\(id) bytes=\(saved.bytes) path=\(saved.path)")
            return ComposerPaths.escaped(saved.path)
        case .failure(let error):
            HolderSessionStore.printLog("error composer attachment session=\(id): \(error)")
            return nil
        }
    }

    /// An attachment path finished saving after the field moved to another session: it goes at
    /// the end of that session's draft instead of being lost.
    func appendToDraft(_ text: String, for id: SessionID) {
        mutate(id) { state in state.draft = Self.appending(text, to: state.draft) }
    }

    /// `draft` + `text`, a space between them unless the draft is empty or ends in a space or a
    /// line break (a pasted path, a note reference, D14).
    nonisolated static func appending(_ text: String, to draft: String) -> String {
        let gap = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        return draft + gap + text
    }

    enum AttachmentError: Error, CustomStringConvertible {
        case noSessionFolder(String)
        case io(String, Int32)
        case notAnImage

        var description: String {
            switch self {
            case .noSessionFolder(let path): "no session folder \(path)"
            case .io(let path, let code): "\(path): \(String(cString: strerror(code)))"
            case .notAnImage: "the pasted data is not an image"
            }
        }
    }

    /// Blocking: one small file. The session folder must exist (a missing one is never created:
    /// discovery would see a session without meta.json). The file's modification date starts its
    /// 24 h until it is sent (`markAttachmentsSending`).
    nonisolated static func writeAttachment(_ png: Data, sessionDirectory: String, now: Date) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AttachmentError.noSessionFolder(sessionDirectory)
        }
        let folder = sessionDirectory + "/" + ComposerAttachments.folderName
        if mkdir(folder, 0o700) != 0, errno != EEXIST { throw AttachmentError.io(folder, errno) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        for _ in 0..<8 {
            let suffix = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
            let path = "\(folder)/\(stamp)-\(suffix).png"
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw AttachmentError.io(path, errno)
            }
            let failure: Int32? = png.withUnsafeBytes { raw -> Int32? in
                guard var pointer = raw.baseAddress else { return nil }
                var left = raw.count
                while left > 0 {
                    let written = write(fd, pointer, left)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    left -= written
                    pointer = pointer.advanced(by: written)
                }
                return nil
            }
            close(fd)
            if let failure {
                unlink(path)
                throw AttachmentError.io(path, failure)
            }
            return path
        }
        throw AttachmentError.io(folder, EEXIST)
    }

    // MARK: Attachment expiry (post-M4, user decision 2026-10-18)

    /// The clock of the 24 h rule (tests move it).
    var attachmentClock: @MainActor () -> Date = { Date() }
    /// Sweeps run here in the order they were asked for.
    private let attachmentQueue = DispatchQueue(label: CoddIdentity.label("composer-attachments"), qos: .utility)
    /// The saved drafts' image names by session folder, read by the launch sweep; send sweeps keep
    /// them for the sessions not in memory (only touched on `attachmentQueue`).
    private let savedDraftNames = SavedDraftNames()

    /// Right before a send of `text` from session `id` (the composer's Enter / SEND, a resend, a
    /// note's 送出): the images it names get their 24 h from now, in that session's folder and, for
    /// an absolute path into another session's folder, there too (review attachments-2 / -3). On the
    /// calling actor, a few `utimensat` calls: a sweep that runs at the same moment either removed a
    /// file first (the caller's missing-path check, made after this, then never sends it) or keeps it.
    func markAttachmentsSending(_ text: String, for id: SessionID) {
        guard let folder = directory(id), text.contains(ComposerAttachments.folderName + "/") else { return }
        ComposerAttachments.markSent(in: text, sessionDirectory: folder, at: attachmentClock())
    }

    /// After a send to session `id` (its images were marked by `markAttachmentsSending`): that
    /// session's folder is swept with what the unsent drafts still use: every draft in memory and,
    /// for the other sessions, the saved drafts the launch sweep read (a prompt may name another
    /// session's image). Off the main actor; one log line when the session has the folder.
    @discardableResult
    func sweepAttachmentsAfterSend(for id: SessionID) -> Task<ComposerAttachments.Sweep?, Never> {
        guard let folder = directory(id) else { return Task { nil } }
        let inMemory = inMemoryDraftNames()
        let loadedFolders = Set(states.keys.compactMap { directory($0) })
        let ownLoaded = states[id] != nil
        let saved = savedDraftNames
        let now = attachmentClock()
        return enqueueAttachmentWork {
            var keeping = inMemory
            for (savedFolder, names) in saved.byFolder where !loadedFolders.contains(savedFolder) { keeping.formUnion(names) }
            if !ownLoaded, saved.byFolder[folder] == nil { keeping.formUnion(Self.savedDraftAttachmentNames(folder)) }
            let sweep = ComposerAttachments.sweep(sessionDirectory: folder, keeping: keeping, now: now)
            if sweep.folderFound { HolderSessionStore.printLog("composer attachments sweep reason=send session=\(id) " + Self.counts(sweep)) }
            return sweep
        }
    }

    /// The launch sweep over every session folder (`HolderSessionStore.sessionDirectories`), off
    /// the main actor, one log line. Every session's unsent drafts keep their images in every
    /// folder (names are unique; a draft may name another session's image): a session whose
    /// composer state is in memory by it, the others by their saved `composer.json`.
    @discardableResult
    func sweepAttachments(in sessions: [SessionID: String]) -> Task<ComposerAttachments.Sweep?, Never> {
        let loaded = Set(sessions.keys.filter { states[$0] != nil })
        let inMemory = inMemoryDraftNames()
        let saved = savedDraftNames
        let now = attachmentClock()
        return enqueueAttachmentWork {
            let ordered = sessions.sorted(by: { $0.key < $1.key })
            var keeping = inMemory
            for (id, folder) in ordered where !loaded.contains(id) {
                let names = Self.savedDraftAttachmentNames(folder)
                saved.byFolder[folder] = names
                keeping.formUnion(names)
            }
            var total = ComposerAttachments.Sweep()
            var folders = 0
            for (_, folder) in ordered {
                let sweep = ComposerAttachments.sweep(sessionDirectory: folder, keeping: keeping, now: now)
                if sweep.folderFound { folders += 1 }
                total.add(sweep)
            }
            HolderSessionStore.printLog("composer attachments sweep reason=launch sessions=\(sessions.count) folders=\(folders) "
                                        + Self.counts(total))
            return total
        }
    }

    /// `text` with each attachment path whose file is gone shown as `[圖已過期]` (history recall,
    /// sends): a missing path is never sent. A few `stat` calls, only for CODD attachment paths.
    func expiringMissingAttachments(in text: String, for id: SessionID) -> String {
        ComposerAttachments.replacingMissing(in: text, sessionDirectory: directory(id))
    }

    /// Waits for every sweep asked for so far (tests).
    func attachmentWorkDone() async {
        _ = await enqueueAttachmentWork { true }.value
    }

    /// The images the session's unsent drafts use: the draft and the text a history walk stashed;
    /// nil when the state is not in memory (the sweep reads the saved draft then).
    private func draftAttachmentNames(_ id: SessionID) -> Set<String>? {
        guard let state = states[id] else { return nil }
        var names = ComposerAttachments.referencedNames(in: state.draft)
        if let stash = state.history.stashedText { names.formUnion(ComposerAttachments.referencedNames(in: stash)) }
        return names
    }

    /// The images every in-memory session's unsent drafts use.
    private func inMemoryDraftNames() -> Set<String> {
        states.keys.reduce(into: Set<String>()) { names, id in names.formUnion(draftAttachmentNames(id) ?? []) }
    }

    /// Blocking: the saved draft's images (`composer.json`; none when it is missing or unreadable).
    nonisolated static func savedDraftAttachmentNames(_ folder: String) -> Set<String> {
        ComposerAttachments.referencedNames(in: ComposerStateFile.load(directory: folder).draft)
    }

    nonisolated static func counts(_ sweep: ComposerAttachments.Sweep) -> String {
        "removed=\(sweep.removed.count) draft=\(sweep.keptInDraft) recent=\(sweep.keptRecent) failed=\(sweep.failed)"
            + (sweep.redated > 0 ? " redated=\(sweep.redated)" : "")
    }

    /// The launch sweep's reading of the saved drafts, kept for later send sweeps. A class only
    /// `attachmentQueue` touches (hence unchecked).
    private final class SavedDraftNames: @unchecked Sendable {
        var byFolder: [String: Set<String>] = [:]
    }

    /// Runs `work` on the attachment queue now (in call order) and hands back its result.
    private func enqueueAttachmentWork<T: Sendable>(_ work: @escaping @Sendable () -> T) -> Task<T?, Never> {
        let (stream, continuation) = AsyncStream.makeStream(of: T.self)
        attachmentQueue.async {
            continuation.yield(work())
            continuation.finish()
        }
        return Task {
            for await value in stream { return value }
            return nil
        }
    }
}
