import AppKit
import CoddComposer
import CoddNotes
import Darwin
import Foundation
import Testing
@testable import CODD

/// Post-M4: ⌘L composer images are temporary (user decision 2026-10-18, 「暫存可以 24 小時刪除」).
/// A send marks its images and sweeps the session; the launch sweep covers every session folder;
/// ↑ shows a removed image as `[圖已過期]` and a missing path is never sent. Temp folders only, an
/// injected clock, mock sessions (no PTY, no claude).

private func makeTemp(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return String(cString: created)
}

@MainActor
private func settle(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

@MainActor
private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func modified(_ path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
}

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

/// The injected clock (a class, so the closure reads the current value).
@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// What a wrapped PTY send saw (a class, so the closure can record).
@MainActor
private final class SendProbe {
    var inputs: [TerminalInput] = []
    var modifiedAtSend: [Date?] = []
}

private func writeImage(_ dir: String, _ name: String, modified: Date) throws -> String {
    let path = dir + "/attachments/" + name
    try FileManager.default.createDirectory(atPath: dir + "/attachments", withIntermediateDirectories: true)
    try png.write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    return path
}

private func isNear(_ date: Date?, _ wanted: Date) -> Bool {
    date.map { abs($0.timeIntervalSince(wanted)) < 0.001 } == true
}

/// One pane on mock sessions in a window that is never ordered on screen; s9 is busy (live).
@MainActor
private final class AttachmentPaneHarness {
    let store = MockSessionStore(shiftClock: false)
    let shell = ShellState()
    let pane: SessionPaneViewController
    let window: NSWindow

    init(directory: @escaping @MainActor (SessionID) -> String?) {
        shell.currentSessionID = "s9"
        pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell,
                                         surfaceFactory: FakeTerminalSurfaceFactory { _ in "<d>></d> mock" },
                                         composerDirectory: directory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.layoutIfNeeded()
    }

    var fake: FakeTerminalSurface { pane.surface as! FakeTerminalSurface }
    var states: ComposerStates { pane.composer.states }

    deinit { MainActor.assumeIsolated { window.close() } }
}

@MainActor
@Suite("Composer attachment expiry (post-M4)", .serialized)
struct ComposerAttachmentExpiryTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: TimeInterval = 60 * 60
    static var expired: String { ComposerAttachments.expiredMarker }

    @Test func aSentImageGoes24HoursLaterAndComesBackExpired() async throws {
        let temp = try makeTemp("codd-attach-send")
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let sessionDir = temp + "/sessions/s9"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let h = AttachmentPaneHarness(directory: { _ in sessionDir })
        let clock = TestClock(Self.t0)
        h.states.attachmentClock = { clock.now }
        h.pane.toggleComposer()
        await settle()
        await eventually("state loaded") { h.states.state("s9") != nil }
        // Pasted ten days ago: its 24 h start at the send.
        let path = try ComposerStates.writeAttachment(png, sessionDirectory: sessionDir, now: Self.t0)
        try FileManager.default.setAttributes([.modificationDate: Self.t0 - 240 * Self.hour], ofItemAtPath: path)
        let text = "看這張 " + ComposerPaths.escaped(path)
        h.pane.composer.bar.field.text = text
        #expect(h.pane.composer.submit(text))
        await h.states.attachmentWorkDone()
        #expect(modified(path).map { abs($0.timeIntervalSince(Self.t0)) < 0.001 } == true, "the send set its clock")
        // 23 h later another send sweeps the session: kept.
        clock.now = Self.t0 + 23 * Self.hour
        #expect(h.pane.composer.submit("下一則"))
        await h.states.attachmentWorkDone()
        #expect(exists(path))
        // 24 h after its send: removed.
        clock.now = Self.t0 + 24 * Self.hour
        #expect(h.pane.composer.submit("再一則"))
        await h.states.attachmentWorkDone()
        #expect(!exists(path))
        // ↑ brings the entry back with the chip, never the path; the saved entry keeps the path.
        let recall = try #require(h.pane.composer.bar.textView.onHistory)
        #expect(recall(.previous) == "再一則")
        #expect(recall(.previous) == "下一則")
        #expect(recall(.previous) == "看這張 " + Self.expired)
        #expect(h.states.state("s9")?.history.entries.first == text)
        h.states.resetCursor(for: "s9")
        // A missing path in the field is never sent: the field shows the chip, Enter again sends it.
        let sentBefore = h.fake.sentInputs.count
        h.pane.composer.bar.field.text = text
        #expect(!h.pane.composer.submit(text))
        #expect(h.fake.sentInputs.count == sentBefore)
        #expect(h.pane.composer.bar.field.text == "看這張 " + Self.expired)
        #expect(h.states.state("s9")?.draft == "看這張 " + Self.expired)
        #expect(h.pane.composer.submit(h.pane.composer.bar.field.text))
        #expect(h.fake.sentInputs.last == .payload(bytes: Array(("看這張 " + Self.expired).utf8), submit: true, paste: false))
    }

    @Test func draftImagesStayAndTheLaunchSweepReadsSavedDrafts() async throws {
        let temp = try makeTemp("codd-attach-launch")
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let shown = temp + "/sessions/s9"
        let saved = temp + "/sessions/s5"
        for dir in [shown, saved] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let h = AttachmentPaneHarness(directory: { temp + "/sessions/" + $0 })
        let clock = TestClock(Self.t0)
        h.states.attachmentClock = { clock.now }
        h.pane.toggleComposer()
        await settle()
        await eventually("state loaded") { h.states.state("s9") != nil }
        let old = Self.t0 - 72 * Self.hour
        func image(_ dir: String, _ name: String, modified: Date) throws -> String {
            let path = dir + "/attachments/" + name
            try FileManager.default.createDirectory(atPath: dir + "/attachments", withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
            return path
        }
        // s9 (in memory): one image in the draft, one in the text a history walk stashed, one in neither.
        let inDraft = try image(shown, "20261015-090000-aaaaaa.png", modified: old)
        let inStash = try image(shown, "20261015-090001-bbbbbb.png", modified: old)
        let dropped = try image(shown, "20261015-090002-cccccc.png", modified: old)
        h.states.recordSent("舊的一則", for: "s9")
        _ = h.states.previous(current: "先存著 " + ComposerPaths.escaped(inStash), for: "s9")
        h.states.setDraft("草稿 " + ComposerPaths.escaped(inDraft), for: "s9")
        // s5 (not in memory): its saved composer.json draft names one image; another is old, one is new.
        let savedDraft = try image(saved, "20261015-090003-dddddd.png", modified: old)
        let savedOld = try image(saved, "20261015-090004-eeeeee.png", modified: old)
        let savedNew = try image(saved, "20261018-090005-ffffff.png", modified: Self.t0 - Self.hour)
        try ComposerStateFile.save(ComposerState(draft: "等等 " + ComposerPaths.escaped(savedDraft)), directory: saved)
        // A link and a foreign file in s5's folder, both old.
        let outside = temp + "/outside.png"
        try png.write(to: URL(fileURLWithPath: outside))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: outside)
        let link = saved + "/attachments/20261015-090006-121212.png"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let foreign = saved + "/attachments/notes.txt"
        try png.write(to: URL(fileURLWithPath: foreign))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: foreign)
        #expect(h.states.state("s5") == nil, "s5 is judged by its saved draft")

        let result = await h.states.sweepAttachments(in: ["s9": shown, "s5": saved]).value
        let sweep = try #require(result)
        #expect(sweep.removed.sorted() == ["20261015-090002-cccccc.png", "20261015-090004-eeeeee.png"])
        #expect(sweep.keptInDraft == 3)
        #expect(sweep.keptRecent == 1)
        #expect(exists(inDraft) && exists(inStash) && exists(savedDraft) && exists(savedNew))
        #expect(!exists(dropped) && !exists(savedOld))
        #expect(exists(link) && exists(outside) && exists(foreign))
    }
    /// Review attachments-2: the images a send names are marked before its bytes go to the PTY, so a
    /// sweep already queued (the launch sweep, an earlier send's) can never remove one whose path
    /// just went out: either it removed the file first and the send is refused with the chip, or the
    /// file stays.
    @Test func theMarkLandsBeforeThePTYSendAndAQueuedSweepNeverRemovesASentImage() async throws {
        let temp = try makeTemp("codd-attach-order")
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let sessionDir = temp + "/sessions/s9"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let h = AttachmentPaneHarness(directory: { _ in sessionDir })
        let clock = TestClock(Self.t0)
        h.states.attachmentClock = { clock.now }
        h.pane.toggleComposer()
        await settle()
        await h.states.load("s9")
        let probe = SendProbe()
        let original = h.pane.composer.send
        let watched = try writeImage(sessionDir, "20261015-090000-aaaaaa.png", modified: Self.t0 - 240 * Self.hour)
        h.pane.composer.send = { input, target in
            probe.inputs.append(input)
            probe.modifiedAtSend.append(modified(watched))
            return original?(input, target) ?? false
        }
        let text = "看這張 " + ComposerPaths.escaped(watched)
        h.pane.composer.bar.field.text = text
        #expect(h.pane.composer.submit(text))
        #expect(probe.modifiedAtSend.count == 1 && isNear(probe.modifiedAtSend[0], Self.t0), "marked before the send")
        await h.states.attachmentWorkDone()
        // An old image only the history names, a sweep queued that does not keep it, then a send of it.
        for round in 0..<5 {
            let path = try writeImage(sessionDir, "20261015-09000\(round)-bbbbb\(round).png", modified: Self.t0 - 48 * Self.hour)
            h.states.sweepAttachments(in: ["s9": sessionDir])
            let recalled = "再看 " + ComposerPaths.escaped(path)
            h.pane.composer.bar.field.text = recalled
            let sent = h.pane.composer.submit(recalled)
            await h.states.attachmentWorkDone()
            if sent {
                #expect(exists(path), "round \(round): a sent path names a file that is there")
            } else {
                #expect(h.pane.composer.bar.field.text == "再看 " + Self.expired, "round \(round): removed first, refused with the chip")
                h.pane.composer.bar.field.text = ""
                h.states.setDraft("", for: "s9")
            }
        }
    }

    /// Review attachments-3: drafts keep their images in every session's folder (a prompt copied
    /// from one session to another), and a send marks the image where its path points.
    @Test func draftsKeepAndSendsMarkAnotherSessionsImages() async throws {
        let temp = try makeTemp("codd-attach-cross")
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let shown = temp + "/sessions/s9"
        let other = temp + "/sessions/s5"
        let saved = temp + "/sessions/s6"
        for dir in [shown, other, saved] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let h = AttachmentPaneHarness(directory: { temp + "/sessions/" + $0 })
        let clock = TestClock(Self.t0)
        h.states.attachmentClock = { clock.now }
        h.pane.toggleComposer()
        await settle()
        await h.states.load("s9")
        let old = Self.t0 - 72 * Self.hour
        // s9's draft (in memory) names s5's image; s6's saved draft names another of s5's images.
        let inShownDraft = try writeImage(other, "20261015-090000-aaaaaa.png", modified: old)
        let inSavedDraft = try writeImage(other, "20261015-090001-bbbbbb.png", modified: old)
        let unused = try writeImage(other, "20261015-090002-cccccc.png", modified: old)
        h.states.setDraft("比較 " + ComposerPaths.escaped(inShownDraft), for: "s9")
        try ComposerStateFile.save(ComposerState(draft: "也看 " + ComposerPaths.escaped(inSavedDraft)), directory: saved)
        let launchResult = await h.states.sweepAttachments(in: ["s9": shown, "s5": other, "s6": saved]).value
        let launch = try #require(launchResult)
        #expect(launch.removed == ["20261015-090002-cccccc.png"])
        #expect(launch.keptInDraft == 2)
        #expect(exists(inShownDraft) && exists(inSavedDraft) && !exists(unused))
        // A send sweep in s5 keeps both too (s6 not in memory: what the launch sweep read).
        let afterSendResult = await h.states.sweepAttachmentsAfterSend(for: "s5").value
        let afterSend = try #require(afterSendResult)
        #expect(afterSend.removed.isEmpty && afterSend.keptInDraft == 2)
        // Sending s9's draft marks s5's file (by its path); its 24 h then run from that send.
        let text = "比較 " + ComposerPaths.escaped(inShownDraft)
        h.pane.composer.bar.field.text = text
        #expect(h.pane.composer.submit(text))
        #expect(isNear(modified(inShownDraft), Self.t0))
        await h.states.attachmentWorkDone()
        clock.now = Self.t0 + 23 * Self.hour
        let at23 = await h.states.sweepAttachmentsAfterSend(for: "s5").value
        #expect(at23?.removed.isEmpty == true)
        clock.now = Self.t0 + 24 * Self.hour
        let dueResult = await h.states.sweepAttachmentsAfterSend(for: "s5").value
        let due = try #require(dueResult)
        #expect(due.removed == ["20261015-090000-aaaaaa.png"], "sent and in no draft any more")
        #expect(exists(inSavedDraft), "still in s6's saved draft")
    }

    /// Review attachments-4: 送出 of a note that names composer images marks them and sends a gone
    /// one as `[圖已過期]`, like the composer.
    @Test func aNoteSendMarksItsComposerImagesAndNeverSendsAGoneOne() async throws {
        let rig = try await SendRig("codd-attach-note")
        let temp = try makeTemp("codd-attach-note-sessions")
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let sessionDir = temp + "/sessions/s9"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let composer = PaneComposer(states: ComposerStates(directory: { temp + "/sessions/" + $0 }))
        composer.states.attachmentClock = { Self.t0 }
        rig.sending.composer = { composer }
        let kept = try writeImage(sessionDir, "20261015-090000-aaaaaa.png", modified: Self.t0 - 240 * Self.hour)
        let gone = sessionDir + "/attachments/20261015-090001-bbbbbb.png"
        let note = try await rig.notes.create("截圖對照", body: "# 截圖對照\n\n先看 " + ComposerPaths.escaped(kept) + "\n再看 "
                                               + ComposerPaths.escaped(gone) + "\n")
        #expect(await rig.sending.perform(.submit, note: note.metadata.id, to: "s9") == .sent("s9"))
        let sent = SendRig.text(try #require(rig.sent.last?.input))
        #expect(sent.contains(ComposerPaths.escaped(kept)))
        #expect(!sent.contains("20261015-090001-bbbbbb.png") && sent.contains("再看 " + Self.expired))
        #expect(isNear(modified(kept), Self.t0), "marked by the send")
        await composer.states.attachmentWorkDone()
        #expect(exists(kept))
        await rig.tearDown()
    }

    /// Review attachments-6: a note's annotated copy (cache/annotated, DERIVED) that a draft made
    /// with 插入全文 names is rendered again before the send when the cache lost it; one that cannot
    /// come back goes as `[圖已過期]`.
    @Test func anAnnotatedCopyGoneFromTheCacheIsRenderedAgainBeforeTheSend() async throws {
        let rig = try await SendRig("codd-attach-copy")
        let composer = rig.composer
        let service = rig.notes.service
        composer.annotatedCopies = AnnotatedCopies(folder: service.annotatedFolder.path) { [weak service] text in
            await service?.restoreAnnotatedCopies(in: text)
        }
        let probe = SendProbe()
        composer.send = { input, _ in
            probe.inputs.append(input)
            return true
        }
        #expect(await rig.sending.perform(.full, note: rig.n1, to: "s9") == .inserted("s9"))
        await m3Eventually("draft") { composer.states.state("s9")?.draft.contains(".annotated.png") == true }
        let draft = try #require(composer.states.state("s9")?.draft)
        let folder = service.annotatedFolder.path
        let start = try #require(draft.range(of: folder + "/"))
        let end = try #require(draft.range(of: ".annotated.png", range: start.upperBound..<draft.endIndex))
        let copy = String(draft[start.lowerBound..<end.upperBound])
        #expect(FileManager.default.fileExists(atPath: copy))
        // An update emptied the cache.
        try FileManager.default.removeItem(atPath: folder)
        #expect(composer.annotatedCopies?.missing(in: draft).count == 1)
        composer.bind(session: "s9", target: TerminalTarget(sessionID: "s9", tab: .claude), shell: false, live: true, busy: false)
        composer.bar.field.text = draft
        #expect(!composer.submit(draft), "waits for the render")
        #expect(!composer.submit(draft), "a second Enter while it renders sends nothing either")
        await m3Eventually("sent once the copy is back") { !probe.inputs.isEmpty }
        #expect(probe.inputs.count == 1)
        #expect(FileManager.default.fileExists(atPath: copy))
        #expect(SendRig.text(try #require(probe.inputs.first)).contains(copy))
        // A copy no note can render again: the chip in its place, refused once, then sent.
        let orphan = folder + "/0123456789ab-不存在.annotated.png"
        let text = "看 " + orphan + " 這張"
        composer.bar.field.text = text
        #expect(!composer.submit(text))
        await m3Eventually("refused with the chip") { composer.bar.field.text == "看 " + Self.expired + " 這張" }
        #expect(probe.inputs.count == 1)
        #expect(composer.submit(composer.bar.field.text))
        #expect(SendRig.text(try #require(probe.inputs.last)) == "看 " + Self.expired + " 這張")
        await rig.tearDown()
    }
}
