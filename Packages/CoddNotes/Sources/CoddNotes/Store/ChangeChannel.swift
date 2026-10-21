import Foundation
import Synchronization

/// The `changes` buffer: single consumer, newest wins per id. A pending `.changed([a])` loses `a`
/// when a later change about `a` arrives, so a slow consumer never replays stale work, and the
/// buffer stays bounded (1,024 entries, oldest dropped first).
final class ChangeChannel: Sendable {
    private struct State {
        var pending: [NotesChange] = []
        var waiter: CheckedContinuation<NotesChange?, Never>?
        var finished = false
    }

    private let state = Mutex(State())
    static let limit = 1024

    func yield(_ change: NotesChange) {
        let resume: (CheckedContinuation<NotesChange?, Never>, NotesChange)? = state.withLock { s in
            guard !s.finished else { return nil }
            if let w = s.waiter, s.pending.isEmpty {
                s.waiter = nil
                return (w, change)
            }
            Self.merge(change, into: &s.pending)
            if s.pending.count > Self.limit { s.pending.removeFirst(s.pending.count - Self.limit) }
            return nil
        }
        if let (w, c) = resume { w.resume(returning: c) }
    }

    func finish() {
        let w: CheckedContinuation<NotesChange?, Never>? = state.withLock { s in
            s.finished = true
            let w = s.waiter
            s.waiter = nil
            return w
        }
        w?.resume(returning: nil)
    }

    func next() async -> NotesChange? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<NotesChange?, Never>) in
                let immediate: NotesChange?? = state.withLock { s in
                    if !s.pending.isEmpty { return .some(s.pending.removeFirst()) }
                    if s.finished || Task.isCancelled { return .some(nil) }
                    // A second concurrent consumer replaces the first (single consumer by contract).
                    let old = s.waiter
                    s.waiter = c
                    if let old { old.resume(returning: nil) }
                    return .none
                }
                if let value = immediate { c.resume(returning: value) }
            }
        } onCancel: {
            let w: CheckedContinuation<NotesChange?, Never>? = state.withLock { s in
                let w = s.waiter
                s.waiter = nil
                return w
            }
            w?.resume(returning: nil)
        }
    }

    static func merge(_ change: NotesChange, into pending: inout [NotesChange]) {
        func ids(of c: NotesChange) -> [NoteID]? {
            switch c {
            case .changed(let a), .removed(let a), .external(let a): a
            default: nil
            }
        }
        switch change {
        case .changed(let new), .removed(let new), .external(let new):
            let newSet = Set(new)
            pending = pending.compactMap { old in
                guard let oldIDs = ids(of: old) else { return old }
                let left = oldIDs.filter { !newSet.contains($0) }
                if left.isEmpty { return nil }
                switch old {
                case .changed: return .changed(left)
                case .removed: return .removed(left)
                case .external: return .external(left)
                default: return old
                }
            }
        case .activity(let id):
            pending.removeAll { $0 == .activity(id) }
        case .indexRebuilt:
            pending.removeAll { if case .indexRebuilt = $0 { return true }; return false }
        case .unavailable:
            pending.removeAll { if case .unavailable = $0 { return true }; return false }
        }
        pending.append(change)
    }
}
