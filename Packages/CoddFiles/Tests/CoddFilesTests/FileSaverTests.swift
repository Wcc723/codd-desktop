import Darwin
import Foundation
import Testing
@testable import CoddFiles

@Suite("FileSaver")
struct FileSaverTests {
    private func info(_ url: URL) -> stat {
        var st = stat()
        _ = stat(url.path, &st)
        return st
    }

    private func lstatMode(_ url: URL) -> mode_t {
        var st = stat()
        _ = lstat(url.path, &st)
        return st.st_mode & S_IFMT
    }

    private func leftovers(_ dir: TempDir) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.url.path)) ?? []).filter { $0.contains(".codd-save-") }
    }

    @Test func atomicReplaceKeepsModeAndXattrs() throws {
        let dir = TempDir()
        for mode: mode_t in [0o644, 0o600, 0o755] {
            let file = try dir.write("f\(mode).txt", "old\n")
            chmod(file.path, mode)
            #expect(setxattr(file.path, "com.codd.test", "keep", 4, 0, 0) == 0)
            let before = info(file)
            let (_, fingerprint) = try FileFingerprint.read(file)
            let result = try FileSaver.saveReporting(Data("new\n".utf8), to: file, expected: fingerprint, force: false)
            #expect(result.method == .atomic)
            #expect(try Data(contentsOf: file) == Data("new\n".utf8))
            let after = info(file)
            #expect(after.st_ino != before.st_ino, "renamed over")
            #expect(after.st_mode & 0o7777 == mode)
            var buffer = [UInt8](repeating: 0, count: 16)
            let size = getxattr(file.path, "com.codd.test", &buffer, buffer.count, 0, 0)
            #expect(size == 4 && String(decoding: buffer.prefix(4), as: UTF8.self) == "keep")
            #expect(result.fingerprint.sha256 == FileFingerprint.sha256Hex(Data("new\n".utf8)))
            #expect(result.fingerprint.inode == UInt64(after.st_ino))
        }
        #expect(leftovers(dir).isEmpty)
    }

    @Test func aSymlinkIsWrittenThroughToItsTarget() throws {
        let dir = TempDir()
        let target = try dir.write("real/config.json", "{}\n")
        let link = dir.file("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileSaver.save(Data("{\"a\":1}\n".utf8), to: link, expected: nil, force: false)
        #expect(lstatMode(link) == S_IFLNK, "the link stays a link")
        #expect(try Data(contentsOf: target) == Data("{\"a\":1}\n".utf8))
    }

    @Test func aHardLinkedFileIsWrittenInPlace() throws {
        let dir = TempDir()
        let file = try dir.write("a.txt", "shared contents that are long\n")
        let other = dir.file("b.txt")
        #expect(link(file.path, other.path) == 0)
        let inode = info(file).st_ino
        let result = try FileSaver.saveReporting(Data("short\n".utf8), to: file, expected: nil, force: false)
        #expect(result.method == .inPlace)
        #expect(info(file).st_ino == inode && info(file).st_nlink == 2, "the link survives")
        #expect(try Data(contentsOf: other) == Data("short\n".utf8), "truncated to the new length")
        #expect(leftovers(dir).isEmpty)
    }

    @Test func noWritePermissionIsRefused() throws {
        let dir = TempDir()
        let file = try dir.write("ro.txt", "x\n")
        chmod(file.path, 0o444)
        #expect(throws: FileSaveError.readOnly(path: file.path)) {
            try FileSaver.save(Data("y\n".utf8), to: file, expected: nil, force: true)
        }
        #expect(try Data(contentsOf: file) == Data("x\n".utf8))
    }

    @Test func aChangeOnDiskIsRefusedUnlessForced() throws {
        let dir = TempDir()
        let file = try dir.write("c.txt", "v1\n")
        let (_, loaded) = try FileFingerprint.read(file)
        try Data("v2 from someone else\n".utf8).write(to: file)
        do {
            try FileSaver.save(Data("mine\n".utf8), to: file, expected: loaded, force: false)
            Issue.record("expected changedOnDisk")
        } catch let FileSaveError.changedOnDisk(current) {
            #expect(current?.sha256 == FileFingerprint.sha256Hex(Data("v2 from someone else\n".utf8)))
        }
        #expect(try Data(contentsOf: file) == Data("v2 from someone else\n".utf8))
        try FileSaver.save(Data("mine\n".utf8), to: file, expected: loaded, force: true)
        #expect(try Data(contentsOf: file) == Data("mine\n".utf8))
        // A touch alone (same bytes, new mtime) is not a conflict.
        let (_, fresh) = try FileFingerprint.read(file)
        var times = [timespec(tv_sec: 1_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, file.path, &times, 0)
        try FileSaver.save(Data("again\n".utf8), to: file, expected: fresh, force: false)
    }

    @Test func aMissingFileIsCreatedAndAVanishedOneIsAConflict() throws {
        let dir = TempDir()
        let file = dir.file("new.txt")
        let result = try FileSaver.saveReporting(Data("hello\n".utf8), to: file, expected: nil, force: false)
        #expect(result.method == .created)
        let mask = umask(0)
        umask(mask)
        #expect(info(file).st_mode & 0o777 == 0o666 & ~mask)
        let (_, fingerprint) = try FileFingerprint.read(file)
        try FileManager.default.removeItem(at: file)
        #expect(throws: FileSaveError.changedOnDisk(current: nil)) {
            try FileSaver.save(Data("x".utf8), to: file, expected: fingerprint, force: false)
        }
    }

    @Test func aFolderIsNotAFile() throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.file("sub"), withIntermediateDirectories: true)
        #expect(throws: FileSaveError.notAFile(path: dir.file("sub").path)) {
            try FileSaver.save(Data("x".utf8), to: dir.file("sub"), expected: nil, force: false)
        }
    }
}
