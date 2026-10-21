import CoddPosix
import CoddProtocol
import Darwin

/// One session found under a sessions root.
public struct SessionRecord: Sendable, Equatable {
    public var directory: String
    public var meta: HolderMeta
    /// The holder process recorded in meta.json is running (and still is a codd-holder).
    public var holderAlive: Bool
}

/// Reads `<root>/<session>/meta.json` records (discovery never scans sockets).
public enum SessionDirectory {
    public static func readMeta(directory: String) -> HolderMeta? {
        let path = PosixFile.join(directory, HolderMeta.fileName)
        guard let bytes = try? PosixFile.readAll(path, maxBytes: 1 << 20),
              let json = try? JSONValue.parse(bytes)
        else { return nil }
        return HolderMeta(json: json)
    }

    public static func list(root: String) throws(SystemError) -> [SessionRecord] {
        let currentBoot = ProcessQueries.bootSessionUUID()
        var records: [SessionRecord] = []
        for name in try PosixFile.listDirectory(root) {
            let directory = PosixFile.join(root, name)
            guard let meta = readMeta(directory: directory) else { continue }
            records.append(SessionRecord(directory: directory, meta: meta, holderAlive: isLive(meta, currentBoot: currentBoot)))
        }
        return records
    }

    /// Whether the holder recorded in `meta` is still running. A record from an earlier boot is
    /// never live, even if its pid now belongs to another holder (pids restart on every boot).
    public static func isLive(_ meta: HolderMeta, currentBoot: String? = ProcessQueries.bootSessionUUID()) -> Bool {
        guard !meta.holderExited else { return false }
        if let recorded = meta.boot, let currentBoot, recorded != currentBoot { return false }
        return isHolderProcess(meta.holderPid)
    }

    /// Guards against pid reuse: the pid must be alive and run a holder executable (`codd-holder`, the
    /// installed copy `codd-holder-<12 hex>` from `HolderBinaryInstaller`, or the earlier proposal's
    /// `holder-<hash>`; not `codd-holderctl`, `codd-holder-testhelper` or other tools).
    public static func isHolderProcess(_ pid: pid_t) -> Bool {
        guard ProcessQueries.isAlive(pid), let path = ProcessQueries.processPath(pid) else { return false }
        let name = PosixFile.baseName(path)
        return name == "codd-holder" || HolderBinaryInstaller.isInstalledHolderName(name) || name.hasPrefix("holder-")
    }
}
