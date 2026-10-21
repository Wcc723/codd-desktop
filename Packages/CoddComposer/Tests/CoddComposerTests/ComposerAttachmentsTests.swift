import AppKit
import Darwin
import Foundation
import Testing
@testable import CoddComposer

/// Post-M4 attachment expiry (user decision 2026-10-18, 「暫存可以 24 小時刪除」): names, the paths a
/// text names, `[圖已過期]` for a gone image, the sent mark and the sweep. Temp folders only; `now`
/// is passed in (the injected clock).
@Suite("Composer attachments (post-M4 expiry)", .serialized)
struct ComposerAttachmentsTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: TimeInterval = 60 * 60
    static let nameA = "20261016-153000-a1b2c3.png"
    static let nameB = "20261017-080102-00ff9e.png"
    static let nameC = "20261018-235959-123abc.png"

    // MARK: Fixtures

    private func makeTemp() throws -> String {
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/codd-attach.XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        return String(cString: created)
    }

    /// `<temp>/sessions/<id>` with an `attachments/` folder (0700).
    private func makeSession(_ temp: String, _ id: String = "s1") throws -> String {
        let session = temp + "/sessions/" + id
        try FileManager.default.createDirectory(atPath: session + "/attachments", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return session
    }

    @discardableResult
    private func makeFile(_ path: String, modified: Date) throws -> String {
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path))
        try setModified(path, modified)
        return path
    }

    private func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: Names and references

    @Test func onlyCODDsOwnNamesCount() {
        #expect(ComposerAttachments.isAttachmentName(Self.nameA))
        #expect(ComposerAttachments.isAttachmentName("20261018-093000-abcdef.png"))
        for name in ["20261018-093000-ABCDEF.png", "20261018-093000-a1b2c3.PNG", "IMG_0001.png", "x.png", "notes.txt",
                     "20261018-093000-a1b2c3.png.tmp", ".20261018-093000-a1b2c3.png", "2026101-093000-a1b2c3.png",
                     "20261018-093000-a1b2c3g.png", "２０２６１０１８-093000-a1b2c3.png", ""] {
            #expect(!ComposerAttachments.isAttachmentName(name), "\(name)")
        }
    }

    @Test func referencesAreTheEscapedPathsTheComposerInserts() throws {
        let path = "/Users/a/Library/Application Support/CODD/sessions/s1/attachments/" + Self.nameA
        let escaped = ComposerPaths.escaped(path)
        let text = "看這張 " + escaped + " 為什麼壞了"
        let refs = ComposerAttachments.references(in: text)
        #expect(refs.count == 1)
        let ref = try #require(refs.first)
        #expect(ref.name == Self.nameA)
        #expect(ref.path == path, "unescaped")
        #expect((text as NSString).substring(with: ref.range) == escaped)
        #expect(ComposerAttachments.referencedNames(in: text) == [Self.nameA])
        // Two images pasted one after the other touch: two paths.
        let second = ComposerPaths.escaped("/r/sessions/s1/attachments/" + Self.nameB)
        let both = ComposerAttachments.references(in: escaped + second)
        #expect(both.map(\.name) == [Self.nameA, Self.nameB])
        #expect(both.map { NSMaxRange($0.range) } == [(escaped as NSString).length, ((escaped + second) as NSString).length])
        #expect(both.last?.path == "/r/sessions/s1/attachments/" + Self.nameB)
        // A bracket before the path is not part of it; a relative path has no absolute form.
        let wrapped = "（" + second + "）"
        #expect(ComposerAttachments.references(in: wrapped).first.map { (wrapped as NSString).substring(with: $0.range) } == second)
        let relative = ComposerAttachments.references(in: "看 foo/attachments/" + Self.nameC)
        #expect(relative.first?.path == nil)
        #expect(relative.first?.name == Self.nameC)
        #expect(relative.first?.range.location == 2)
        // Not CODD's name: not an attachment.
        #expect(ComposerAttachments.references(in: "/x/attachments/photo.png /x/attachments/IMG_1.png").isEmpty)
        #expect(ComposerAttachments.references(in: "沒有附件").isEmpty)
    }

    /// Review attachments-1: the composer inserts a pasted image's path at the caret, and Chinese has
    /// no spaces, so the user's words often touch the path. They are never part of it.
    @Test func wordsWrittenRightBeforeAPathAreNotPartOfIt() throws {
        let path = "/Users/a/Library/Application Support/CODD/sessions/s1/attachments/" + Self.nameA
        let escaped = ComposerPaths.escaped(path)
        let words = "請幫我看這張截圖裡的錯誤"
        let text = words + escaped
        let ref = try #require(ComposerAttachments.references(in: text).first)
        #expect(ref.path == path, "absolute: the existence check looks where it points")
        #expect(ref.range.location == (words as NSString).length)
        #expect((text as NSString).substring(with: ref.range) == escaped)
        // Gone: only the path becomes the marker, the sentence stays.
        #expect(ComposerAttachments.replacingMissing(in: text + "，謝謝", sessionDirectory: nil, exists: { _ in false })
            == words + ComposerAttachments.expiredMarker + "，謝謝")
        // Punctuation and brackets touching the path, a relative path after words, a path right after another.
        let colon = "截圖:" + escaped
        #expect(ComposerAttachments.references(in: colon).first?.path == path)
        let quoted = "看「" + escaped + "」"
        #expect(ComposerAttachments.references(in: quoted).first.map { (quoted as NSString).substring(with: $0.range) } == escaped)
        let home = ComposerAttachments.references(in: "看這張~/x/attachments/" + Self.nameB)
        #expect(home.first?.path == nil, "relative")
        #expect(home.first?.range.location == 3, "from the ~")
        let bare = ComposerAttachments.references(in: "看這張attachments/" + Self.nameB)
        #expect(bare.first?.range.location == 3 && bare.first?.path == nil)
        let second = ComposerPaths.escaped("/r/sessions/s1/attachments/" + Self.nameC)
        let pair = ComposerAttachments.references(in: "看" + escaped + "和" + second)
        #expect(pair.map(\.path) == [path, "/r/sessions/s1/attachments/" + Self.nameC])
        // An escaped character before the first `/` belongs to a relative path.
        let spaced = ComposerAttachments.references(in: "my\\ dir/attachments/" + Self.nameA)
        #expect(spaced.first?.range.location == 0 && spaced.first?.path == nil)
    }

    // MARK: History recall of a removed image

    @Test func aGoneImageReadsAsExpiredAndItsPathIsNeverKept() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let session = try makeSession(temp)
        let kept = try makeFile(session + "/attachments/" + Self.nameA, modified: Self.t0)
        let gone = session + "/attachments/" + Self.nameB
        let text = "前 " + ComposerPaths.escaped(kept) + " 中 " + ComposerPaths.escaped(gone) + " 後"
        let shown = ComposerAttachments.replacingMissing(in: text, sessionDirectory: session)
        #expect(shown == "前 " + ComposerPaths.escaped(kept) + " 中 " + ComposerAttachments.expiredMarker + " 後")
        #expect(!shown.contains(Self.nameB), "the missing path is gone from what can be sent")
        // Two gone images in a row become two chips with a space between them.
        let pair = ComposerPaths.escaped(gone) + ComposerPaths.escaped(session + "/attachments/" + Self.nameC)
        #expect(ComposerAttachments.replacingMissing(in: pair, sessionDirectory: session)
            == ComposerAttachments.expiredMarker + " " + ComposerAttachments.expiredMarker)
        // A relative path is looked up in the session's folder; without a folder it is left as is.
        let relative = "看 attachments/" + Self.nameB
        #expect(ComposerAttachments.replacingMissing(in: relative, sessionDirectory: session) == "看 " + ComposerAttachments.expiredMarker)
        #expect(ComposerAttachments.replacingMissing(in: relative, sessionDirectory: nil) == relative)
        // Nothing missing: the text comes back unchanged.
        #expect(ComposerAttachments.replacingMissing(in: "前 " + ComposerPaths.escaped(kept), sessionDirectory: session)
            == "前 " + ComposerPaths.escaped(kept))
    }

    // MARK: The 24 h rule

    @Test func anImageAnUnsentDraftUsesIsKept() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let session = try makeSession(temp)
        let file = try makeFile(session + "/attachments/" + Self.nameA, modified: Self.t0 - 72 * Self.hour)
        let sweep = ComposerAttachments.sweep(sessionDirectory: session, keeping: [Self.nameA], now: Self.t0)
        #expect(sweep.folderFound)
        #expect(sweep.removed.isEmpty)
        #expect(sweep.keptInDraft == 1)
        #expect(exists(file))
    }

    @Test func aSentImageGoes24HoursAfterItsSendAndStaysAt23Hours() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let session = try makeSession(temp)
        // Pasted ten days ago and kept in a draft; its 24 h start when it is sent.
        let file = try makeFile(session + "/attachments/" + Self.nameA, modified: Self.t0 - 240 * Self.hour)
        #expect(ComposerAttachments.markSent([Self.nameA, Self.nameB, "notes.txt"], sessionDirectory: session, at: Self.t0) == 1)
        #expect(modified(file).map { abs($0.timeIntervalSince(Self.t0)) < 0.001 } == true)
        let at23 = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: Self.t0 + 23 * Self.hour)
        #expect(at23.removed.isEmpty)
        #expect(at23.keptRecent == 1)
        #expect(exists(file))
        let at24 = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: Self.t0 + 24 * Self.hour)
        #expect(at24.removed == [Self.nameA])
        #expect(!exists(file))
    }

    @Test func aDraftImageNeverSentGoesOnceTheDraftDropsIt() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let session = try makeSession(temp)
        let file = try makeFile(session + "/attachments/" + Self.nameA, modified: Self.t0)
        let fresh = try makeFile(session + "/attachments/" + Self.nameB, modified: Self.t0 + 29 * Self.hour)
        let now = Self.t0 + 30 * Self.hour
        #expect(ComposerAttachments.sweep(sessionDirectory: session, keeping: [Self.nameA], now: now).keptInDraft == 1)
        #expect(exists(file), "still in the draft")
        let dropped = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: now)
        #expect(dropped.removed == [Self.nameA], "30 h since it was written, no longer in a draft")
        #expect(dropped.keptRecent == 1)
        #expect(!exists(file))
        #expect(exists(fresh), "written an hour ago")
    }

    @Test func linksAndForeignFilesAreLeftAlone() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let session = try makeSession(temp)
        let old = Self.t0 - 72 * Self.hour
        let outside = try makeFile(temp + "/outside.png", modified: old)
        let link = session + "/attachments/" + Self.nameA
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let foreign = ["notes.txt", "IMG_0001.png", "20261019-101010-ABCDEF.png"].map { session + "/attachments/" + $0 }
        for path in foreign { try makeFile(path, modified: old) }
        let folderNamedLikeAnImage = session + "/attachments/" + Self.nameB
        try FileManager.default.createDirectory(atPath: folderNamedLikeAnImage, withIntermediateDirectories: false)
        try setModified(folderNamedLikeAnImage, old)
        let ours = try makeFile(session + "/attachments/" + Self.nameC, modified: old)
        // A send naming the link never follows it.
        #expect(ComposerAttachments.markSent([Self.nameA], sessionDirectory: session, at: Self.t0) == 0)
        #expect(modified(outside).map { abs($0.timeIntervalSince(old)) < 0.001 } == true)
        let sweep = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: Self.t0)
        #expect(sweep.removed == [Self.nameC])
        #expect(!exists(ours))
        #expect(exists(link) && exists(outside))
        for path in foreign { #expect(exists(path), "\(path)") }
        #expect(exists(folderNamedLikeAnImage))
        // A linked attachments/ or session folder is not entered.
        let elsewhere = try makeSession(temp, "elsewhere")
        let theirs = try makeFile(elsewhere + "/attachments/" + Self.nameA, modified: old)
        let linkedFolder = temp + "/sessions/s2"
        try FileManager.default.createDirectory(atPath: linkedFolder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: linkedFolder + "/attachments", withDestinationPath: elsewhere + "/attachments")
        try FileManager.default.createSymbolicLink(atPath: temp + "/sessions/s3", withDestinationPath: elsewhere)
        for session in [linkedFolder, temp + "/sessions/s3"] {
            let result = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: Self.t0)
            #expect(!result.folderFound && result.removed.isEmpty)
            #expect(ComposerAttachments.markSent([Self.nameA], sessionDirectory: session, at: Self.t0) == 0)
        }
        #expect(exists(theirs))
        #expect(modified(theirs).map { abs($0.timeIntervalSince(old)) < 0.001 } == true)
    }

    @Test func aSweepNeverReachesAnotherSession() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let one = try makeSession(temp, "s1")
        let two = try makeSession(temp, "s2")
        let old = Self.t0 - 48 * Self.hour
        let mine = try makeFile(one + "/attachments/" + Self.nameA, modified: old)
        let theirs = try makeFile(two + "/attachments/" + Self.nameA, modified: old)
        #expect(ComposerAttachments.sweep(sessionDirectory: one, keeping: [], now: Self.t0).removed == [Self.nameA])
        #expect(!exists(mine))
        #expect(exists(theirs))
        // A session without the folder: nothing found, nothing done.
        let bare = temp + "/sessions/s4"
        try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: false)
        #expect(ComposerAttachments.sweep(sessionDirectory: bare, keeping: [], now: Self.t0) == ComposerAttachments.Sweep())
    }

    /// Review attachments-3: a prompt copied from one session to another names the first session's
    /// image; sending it from the second marks the file where the path points.
    @Test func aSendMarksAnotherSessionsImageWhereItsPathPoints() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let one = try makeSession(temp, "s1")
        let two = try makeSession(temp, "s2")
        let old = Self.t0 - 240 * Self.hour
        let theirs = try makeFile(one + "/attachments/" + Self.nameA, modified: old)
        let mine = try makeFile(two + "/attachments/" + Self.nameB, modified: old)
        let elsewhere = try makeSession(temp + "/other", "s1")
        let outside = try makeFile(elsewhere + "/attachments/" + Self.nameC, modified: old)
        let text = "比較 " + ComposerPaths.escaped(theirs) + " 和 " + ComposerPaths.escaped(mine) + " 還有 " + ComposerPaths.escaped(outside)
        #expect(ComposerAttachments.markSent(in: text, sessionDirectory: two, at: Self.t0) == 2)
        #expect(modified(theirs).map { abs($0.timeIntervalSince(Self.t0)) < 0.001 } == true, "s1's file, by its path")
        #expect(modified(mine).map { abs($0.timeIntervalSince(Self.t0)) < 0.001 } == true)
        #expect(modified(outside).map { abs($0.timeIntervalSince(old)) < 0.001 } == true, "not a sibling session: untouched")
        #expect(ComposerAttachments.sessionFolder(of: one + "/attachments/" + Self.nameA, besides: two) == one)
        #expect(ComposerAttachments.sessionFolder(of: two + "/attachments/" + Self.nameA, besides: two) == nil, "its own")
        #expect(ComposerAttachments.sessionFolder(of: temp + "/sessions/../x/attachments/" + Self.nameA, besides: two) == nil)
        #expect(ComposerAttachments.sessionFolder(of: one + "/notes/" + Self.nameA, besides: two) == nil)
    }

    /// Review attachments-5: a file dated in the future (a clock set ahead, then corrected) is dated
    /// back to the sweep's now, so it goes 24 h later instead of months later.
    @Test func aFutureDateIsDatedBackToTheSweep() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let session = try makeSession(temp)
        let future = try makeFile(session + "/attachments/" + Self.nameA, modified: Self.t0 + 400 * 24 * Self.hour)
        let slightly = try makeFile(session + "/attachments/" + Self.nameB, modified: Self.t0 + 60)
        let first = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: Self.t0)
        #expect(first.redated == 1 && first.keptRecent == 2 && first.removed.isEmpty)
        #expect(modified(future).map { abs($0.timeIntervalSince(Self.t0)) < 0.001 } == true)
        #expect(modified(slightly).map { abs($0.timeIntervalSince(Self.t0 + 60)) < 0.001 } == true, "within the slack: untouched")
        let later = ComposerAttachments.sweep(sessionDirectory: session, keeping: [], now: Self.t0 + 24 * Self.hour + 61)
        #expect(later.removed == [Self.nameA, Self.nameB])
    }

    @Test func aWalkKeepsTheStashedDraft() {
        var history = ComposerHistory(entries: ["舊的"])
        #expect(history.stashedText == nil)
        #expect(history.previous(current: "草稿") == "舊的")
        #expect(history.stashedText == "草稿")
        _ = history.next()
        #expect(history.stashedText == nil)
    }
}

/// `[圖已過期]` is drawn as a muted chip; the text, and so the payload, stays as shown.
@Suite("Composer expired image chip (post-M4)", .serialized)
@MainActor
struct ComposerExpiredChipTests {
    static var chipStyle: ComposerStyle {
        var style = ComposerStyle.standard
        style.referenceChips = true
        return style
    }

    @Test func theMarkerIsAMutedChip() {
        let harness = ComposerHarness(style: Self.chipStyle)
        defer { harness.tearDown() }
        let text = "看這張 " + ComposerAttachments.expiredMarker + " 參考 codd://note/rwd-punch-k7x2"
        harness.set(text)
        let ns = text as NSString
        let marker = ns.range(of: ComposerAttachments.expiredMarker)
        let note = ns.range(of: "codd://note/rwd-punch-k7x2")
        #expect(harness.textView.string == text, "attributes only")
        #expect(harness.textView.referenceChipRanges == [marker, note])
        #expect(harness.textView.drawableReferenceChipRanges() == [marker, note])
        let storage = harness.textView.textStorage
        #expect(storage?.attribute(.composerReferenceChip, at: marker.location, effectiveRange: nil) as? String == "expiredImage")
        #expect(storage?.attribute(.composerReferenceChip, at: note.location, effectiveRange: nil) as? String == "note")
        #expect(storage?.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor == Self.chipStyle.expiredChipText)
        #expect(storage?.attribute(.foregroundColor, at: note.location, effectiveRange: nil) as? NSColor == Self.chipStyle.referenceChipText)
        let payload = try? ComposerEncoding.payload(for: harness.field.text)
        #expect(payload.map { String(decoding: $0.bytes, as: UTF8.self) } == text)
        // Chips off: plain text.
        let plain = ComposerHarness()
        defer { plain.tearDown() }
        plain.set(text)
        #expect(plain.textView.referenceChipRanges.isEmpty)
    }
}
