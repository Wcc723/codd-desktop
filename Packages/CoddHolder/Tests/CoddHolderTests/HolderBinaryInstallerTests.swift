import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

/// `HolderBinaryInstaller` in temporary data roots, with holders spawned from the installed copies.
@Suite("Holder binary installer", .serialized, .timeLimit(.minutes(2)))
struct HolderBinaryInstallerTests {
    private func binEntries(_ root: TemporaryDirectory) -> [String] {
        (try? PosixFile.listDirectory(root.path + "/bin")) ?? []
    }

    private func setOld(_ path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path)
    }

    @Test("install: bin/codd-holder-<sha256 prefix>, 0755, same bytes, valid signature; idempotent")
    func installIsIdempotent() throws {
        let root = try TemporaryDirectory()
        let first = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        let shasum = try runCommand("/usr/bin/shasum", ["-a", "256", TestBinaries.holder]).output
        #expect(first.digest == String(shasum.prefix(12)))
        #expect(first.digest.count == HolderBinaryInstaller.digestLength)
        #expect(first.path == root.path + "/bin/codd-holder-" + first.digest)
        #expect(first.copied)
        #expect(HolderBinaryInstaller.isInstalledHolderName(PosixFile.baseName(first.path)))
        #expect(permissions(first.path) == 0o755)
        #expect(permissions(root.path + "/bin") == 0o700)
        #expect(try PosixFile.readAll(first.path, maxBytes: 256 << 20) == PosixFile.readAll(TestBinaries.holder, maxBytes: 256 << 20))
        if access("/usr/bin/codesign", X_OK) == 0 {
            let verify = try runCommand("/usr/bin/codesign", ["-v", first.path])
            #expect(verify.status == 0, "the copied ad-hoc signature verifies")
        }

        let identity = PosixFile.identity(first.path)
        let second = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        #expect(second.path == first.path)
        #expect(!second.copied)
        #expect(PosixFile.identity(second.path) == identity, "a verified copy is not rewritten")
        #expect(binEntries(root) == [PosixFile.baseName(first.path)], "no temporary files left")
    }

    @Test("a holder runs from the installed copy and is recognized as a holder process")
    func holderRunsFromCopy() throws {
        let root = try TemporaryDirectory()
        let installed = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        let session = try TestSession(["/bin/cat"], holderExecutable: installed.path)
        #expect(SessionDirectory.isHolderProcess(session.pid))
        let meta = try #require(session.meta)
        #expect(SessionDirectory.isLive(meta))
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        try connection.roundTrip(token: 1, into: &capture)
        #expect(!SessionDirectory.isHolderProcess(getpid()))
        #expect(!HolderBinaryInstaller.isInstalledHolderName("codd-holder-testhelper"))
        #expect(!HolderBinaryInstaller.isInstalledHolderName("codd-holderctl"))
        #expect(!HolderBinaryInstaller.isInstalledHolderName("codd-holder-ABCDEF123456"))
        #expect(!HolderBinaryInstaller.isInstalledHolderName("codd-holder-abcdef12345"))
    }

    @Test("a damaged copy is replaced by rename; a holder running from the old file keeps running")
    func damagedCopyIsReplaced() throws {
        let root = try TemporaryDirectory()
        let installed = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        let session = try TestSession(["/bin/cat"], holderExecutable: installed.path)
        // Never overwrite a running signed executable in place (the kernel kills it): unlink, then
        // put a damaged file under the name, as a disk error or a stray tool might.
        #expect(unlink(installed.path) == 0)
        try PosixFile.writeAtomically(installed.path, Array("not a holder".utf8), mode: 0o755)
        let again = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        #expect(again.copied)
        #expect(try PosixFile.readAll(again.path, maxBytes: 256 << 20) == PosixFile.readAll(TestBinaries.holder, maxBytes: 256 << 20))
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        try connection.roundTrip(token: 2, into: &capture)
        #expect(session.isRunning)
    }

    @Test("concurrent installs agree and leave exactly one intact file")
    func concurrentInstalls() throws {
        let root = try TemporaryDirectory()
        let paths = Mutex<[String]>([])
        let failures = Mutex<[String]>([])
        let dataRoot = root.path
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let installation = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: dataRoot)
                paths.withLock { $0.append(installation.path) }
            } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        let unique = Set(paths.withLock { $0 })
        #expect(unique.count == 1)
        let path = try #require(unique.first)
        #expect(try PosixFile.readAll(path, maxBytes: 256 << 20) == PosixFile.readAll(TestBinaries.holder, maxBytes: 256 << 20))
        #expect(binEntries(root) == [PosixFile.baseName(path)])
    }

    @Test("GC removes old unused copies and stale temporaries; keeps running, young, current and foreign files")
    func garbageCollection() throws {
        let root = try TemporaryDirectory()
        let current = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        let bin = root.path + "/bin"
        let holderBytes = try PosixFile.readAll(TestBinaries.holder, maxBytes: 256 << 20)
        let unused = bin + "/codd-holder-aaaaaaaaaaaa"
        let running = bin + "/codd-holder-bbbbbbbbbbbb"
        let young = bin + "/codd-holder-cccccccccccc"
        let temporary = bin + "/.codd-holder-dddddddddddd.123.456.tmp"
        let foreign = [bin + "/codd-holder-testhelper", bin + "/notes.txt", bin + "/codd-holder-ABCDEF123456"]
        for path in [unused, running, young] {
            try PosixFile.writeAtomically(path, holderBytes, mode: 0o755)
        }
        try PosixFile.writeAtomically(temporary, [1, 2, 3])
        for path in foreign { try PosixFile.writeAtomically(path, [0], mode: 0o755) }
        for path in [unused, running, temporary, current.path] + foreign { try setOld(path) }
        let session = try TestSession(["/bin/cat"], holderExecutable: running)

        let removed = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, keeping: [current.path], minimumAgeSeconds: 60)
        #expect(Set(removed) == [unused, temporary])
        for path in [running, young, current.path] + foreign { #expect(PosixFile.exists(path), "\(path) is kept") }
        #expect(session.isRunning)

        // Once its holder is gone, the copy goes too (and the young one without the grace period).
        session.stop()
        let later = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, keeping: [current.path], minimumAgeSeconds: 0)
        #expect(Set(later) == [running, young])
        #expect(PosixFile.exists(current.path))
        #expect(HolderBinaryInstaller.collectGarbage(dataRoot: root.path + "/missing", keeping: []).isEmpty)
    }

    @Test("other tools: own prefix, own GC; holder copies and other prefixes are never touched")
    func otherToolPrefix() throws {
        let root = try TemporaryDirectory()
        let holder = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        let tool = try HolderBinaryInstaller.install(bundled: TestBinaries.holder, dataRoot: root.path, namePrefix: "codd-hook-")
        #expect(tool.path == root.path + "/bin/codd-hook-" + tool.digest)
        #expect(tool.digest == holder.digest)
        #expect(tool.copied)
        #expect(!(try HolderBinaryInstaller.install(bundled: TestBinaries.holder, dataRoot: root.path, namePrefix: "codd-hook-")).copied)
        #expect(HolderBinaryInstaller.isInstalledName("codd-hook-0123456789ab", prefix: "codd-hook-"))
        #expect(!HolderBinaryInstaller.isInstalledName("codd-holder-0123456789ab", prefix: "codd-hook-"))

        let bin = root.path + "/bin"
        let referenced = bin + "/codd-hook-aaaaaaaaaaaa"
        let unused = bin + "/codd-hook-bbbbbbbbbbbb"
        for path in [referenced, unused] { try PosixFile.writeAtomically(path, [0], mode: 0o755) }
        for path in [referenced, unused, tool.path, holder.path] { try setOld(path) }
        let removed = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, namePrefix: "codd-hook-",
                                                           keeping: [tool.path, referenced], minimumAgeSeconds: 0)
        #expect(removed == [unused])
        for path in [referenced, tool.path, holder.path] { #expect(PosixFile.exists(path), "\(path) is kept") }
    }

    @Test("SHA-256 matches known vectors")
    func sha256() {
        #expect(HolderBinaryInstaller.sha256Hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(HolderBinaryInstaller.sha256Hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
