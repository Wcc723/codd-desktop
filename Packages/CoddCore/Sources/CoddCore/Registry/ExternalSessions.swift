import Darwin
import Foundation

/// What this CODD instance runs, so its own claude processes are never shown as external (D6).
public struct OwnedClaudeProcesses: Sendable, Equatable {
    /// Children of this CODD's claude-session holders (from WELCOME / meta.json).
    public var claudePids: Set<Int>
    /// Current and initial Claude session ids of CODD claude sessions.
    public var claudeSessionIds: Set<String>
    /// Holders running claude sessions: a registry entry whose parent is one of them belongs to
    /// CODD even before the holder reported its child's pid.
    public var claudeHolderPids: Set<Int>
    /// Holders of shell sessions and shell tabs: a claude below one of them was started by hand in
    /// a CODD shell (EXT, `在 CODD shell 中`).
    public var shellHolderPids: Set<Int>

    public init(claudePids: Set<Int> = [], claudeSessionIds: Set<String> = [], claudeHolderPids: Set<Int> = [],
                shellHolderPids: Set<Int> = []) {
        self.claudePids = claudePids
        self.claudeSessionIds = claudeSessionIds
        self.claudeHolderPids = claudeHolderPids
        self.shellHolderPids = shellHolderPids
    }
}

/// A claude process CODD did not spawn, from Claude's live registry (read-only row with the EXT badge).
public struct ExternalSession: Sendable, Equatable, Identifiable {
    /// D27: `ext-<pid>-<startedAt epoch ms>`, or `ext-<pid>` without `startedAt`. Stable for the
    /// process even when `/clear` gives it a new Claude session id; a reused pid gets a new id.
    public var id: String
    public var pid: Int
    public var claudeSessionId: String?
    public var cwd: String
    /// Registry `name`, cleaned (controls removed, whitespace collapsed).
    public var name: String?
    /// Registry `kind` (`interactive`, `daemon-worker`, …).
    public var kind: String?
    public var entrypoint: String?
    public var version: String?
    /// `.busy`, `.idle`, `.waiting(reason)`, or `.unknown` when the registry has no known status.
    public var state: SessionState
    /// `statusUpdatedAt ?? updatedAt`.
    public var stateSince: Date?
    public var startedAt: Date?
    /// Remote Control is connected (the registry carries a bridge session id).
    public var remoteControl: Bool
    /// The CODD shell holder this claude runs under, if any.
    public var hostHolderPid: Int?

    public init(id: String, pid: Int, claudeSessionId: String? = nil, cwd: String, name: String? = nil, kind: String? = nil,
                entrypoint: String? = nil, version: String? = nil, state: SessionState = .unknown, stateSince: Date? = nil,
                startedAt: Date? = nil, remoteControl: Bool = false, hostHolderPid: Int? = nil) {
        self.id = id
        self.pid = pid
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.entrypoint = entrypoint
        self.version = version
        self.state = state
        self.stateSince = stateSince
        self.startedAt = startedAt
        self.remoteControl = remoteControl
        self.hostHolderPid = hostHolderPid
    }

    /// The D27 id for a process.
    public static func id(pid: Int, startedAt: Date?) -> String {
        startedAt.map { "ext-\(pid)-\(JSDate.milliseconds($0))" } ?? "ext-\(pid)"
    }
}

/// Which external sessions are hidden (D6: SDK / headless runs and the Claude desktop app's own).
public struct ExternalSessionFilter: Sendable, Equatable {
    /// `sdk-*` entrypoints and `kind: sdk` (like the official picker).
    public var hideSDK = true
    /// `entrypoint: claude-desktop`.
    public var hideDesktop = true

    public init() {}

    public init(hideSDK: Bool, hideDesktop: Bool) {
        self.hideSDK = hideSDK
        self.hideDesktop = hideDesktop
    }
}

/// Parent chains from the kernel (`sysctl KERN_PROC_PID`), no `ps`.
public enum ProcessAncestry {
    public static let maxDepth = 8

    /// `pid`'s ancestors, nearest first: at most ``maxDepth``, ending at launchd (1) when reached.
    /// Empty when `pid` is not running.
    public static func chain(_ pid: Int) -> [Int] {
        var out: [Int] = []
        var current = pid
        while out.count < maxDepth, current > 1, let parent = parentPid(current), parent > 0, parent != current {
            out.append(parent)
            current = parent
        }
        return out
    }

    /// `kp_eproc.e_ppid` of `pid`, or `nil` when no such process exists.
    public static func parentPid(_ pid: Int) -> Int? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let rc = mib.withUnsafeMutableBufferPointer { m in sysctl(m.baseAddress, u_int(m.count), &info, &size, nil, 0) }
        guard rc == 0, size > 0, info.kp_proc.p_pid == Int32(pid) else { return nil }
        return Int(info.kp_eproc.e_ppid)
    }
}

/// Turns Claude's live registry into the external sessions CODD shows (D6, D27).
public enum ExternalSessionDetector {
    /// - Parameters:
    ///   - entries: registry entries already filtered by liveness (RegistryWatcher).
    ///   - ancestors: parent chain of a pid, nearest first (injected by tests; only called for
    ///     entries that survive the other rules, and only when there are holders to look for).
    /// - Returns: the external sessions sorted by cwd, start time (unknown last) and pid; one per
    ///   id (the first entry wins when several registry directories list the same process).
    public static func detect(_ entries: [ClaudeRegistryEntry], owned: OwnedClaudeProcesses,
                              filter: ExternalSessionFilter = .init(),
                              ancestors: (Int) -> [Int] = ProcessAncestry.chain) -> [ExternalSession] {
        let needsAncestry = !owned.claudeHolderPids.isEmpty || !owned.shellHolderPids.isEmpty
        var out: [ExternalSession] = []
        var seen = Set<String>()
        for e in entries {
            guard let pid = e.pid, pid > 0, let cwd = e.cwd else { continue }
            if owned.claudePids.contains(pid) { continue }
            if let sid = e.sessionId, owned.claudeSessionIds.contains(sid) { continue }
            if filter.hideSDK, e.isSDK { continue }
            if filter.hideDesktop, e.entrypoint == "claude-desktop" { continue }
            let chain = needsAncestry ? ancestors(pid) : []
            // A CODD claude session's own child, seen before CODD learned its pid.
            if let parent = chain.first, owned.claudeHolderPids.contains(parent) { continue }
            let id = ExternalSession.id(pid: pid, startedAt: e.startedAt)
            guard seen.insert(id).inserted else { continue }
            out.append(ExternalSession(
                id: id, pid: pid, claudeSessionId: e.sessionId, cwd: cwd,
                name: e.name.flatMap { JSText.cleanText($0, max: LaunchBuilder.nameMax) },
                kind: e.kind, entrypoint: e.entrypoint, version: e.version, state: state(e),
                stateSince: e.statusUpdatedAt, startedAt: e.startedAt, remoteControl: e.hasRemoteControl,
                hostHolderPid: chain.first { owned.shellHolderPids.contains($0) }))
        }
        return out.sorted { a, b in
            if a.cwd != b.cwd { return a.cwd < b.cwd }
            switch (a.startedAt, b.startedAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.pid < b.pid
            }
        }
    }

    /// Registry `status` → state; an unknown or missing status is `.unknown`.
    static func state(_ e: ClaudeRegistryEntry) -> SessionState {
        switch e.statusValue {
        case .busy?: .busy
        case .idle?: .idle
        case .waiting?: .waiting(e.waitingReason ?? .other)
        case nil: .unknown
        }
    }
}
