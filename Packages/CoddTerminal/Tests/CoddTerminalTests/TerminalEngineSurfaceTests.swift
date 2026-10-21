import AppKit
import Foundation
import Synchronization
import Testing
@testable import CoddTerminal

/// Real libghostty surfaces in an offscreen window (Metal works headlessly in `swift test`).
/// Set `CODD_TERMINAL_SKIP_SURFACE_TESTS=1` to skip them on a machine without a GPU.
@Suite(
    "TerminalEngine on a real surface",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CODD_TERMINAL_SKIP_SURFACE_TESTS"] == nil)
)
@MainActor
struct TerminalEngineSurfaceTests {
    /// Startup queries Claude Code sends, plus a few more that libghostty answers.
    static let probes = "\u{1B}[c" // DA1
        + "\u{1B}[>c" // DA2
        + "\u{1B}[>0q" // XTVERSION
        + "\u{1B}[6n" // DSR cursor position
        + "\u{1B}[5n" // DSR status
        + "\u{1B}[?2026$p" // DECRQM synchronized output
        + "\u{1B}[?1016$p" // DECRQM SGR pixel mouse
        + "\u{1B}[?u" // kitty keyboard flags
        + "\u{1B}[16t" // cell size in pixels
        + "\u{1B}[18t" // text area in characters
        + "\u{1B}]10;?\u{1B}\\" // OSC 10 foreground query
        + "\u{1B}]11;?\u{1B}\\" // OSC 11 background query
        + "\u{1B}[21t" // title report

    @Test func surfaceBuildsAndShowsFedText() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        #expect(harness.engine.hasSurface)
        harness.feed("hello \u{1B}[1;33mCODD\u{1B}[0m\r\n第二行 注音")
        await harness.settle()
        #expect(harness.viewportLines.prefix(2) == ["hello CODD", "第二行 注音"])
        #expect(harness.written.bytes.isEmpty)
    }

    @Test func liveQueriesAreAnswered() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.feed("\u{1B}[c")
        await harness.settle()
        #expect(await eventually { harness.written.text.contains("\u{1B}[?62;22;52c") }, "\(harness.written.text.debugDescription)")
    }

    @Test func replayProducesNoReplies() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.replay("history line\r\n" + Self.probes + "after probes")
        await harness.settle()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.written.bytes.isEmpty, "replay leaked \(harness.written.text.debugDescription)")
        #expect(harness.viewportLines.first == "history line")
        #expect(harness.viewportLines.last?.hasPrefix("after probes") == true)
        #expect(harness.deviceAttributesReplies == 0)

        // The same queries fed live are answered: suppression is scoped to the replay.
        harness.feed(Self.probes)
        await harness.settle()
        #expect(await eventually { harness.written.text.contains("\u{1B}[?62;22;52c") })
        #expect(harness.written.text.contains("\u{1B}P>|ghostty"))
        #expect(await eventually { harness.deviceAttributesReplies == 1 })
    }

    /// A new surface starts at libghostty's default 800×600 px grid until the IO thread applies the
    /// view's size; bytes fed or replayed right after attaching must still be laid out for the real
    /// grid, and the default grid must never be reported for the PTY.
    @Test func firstBytesAreParsedAtTheRealGrid() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        // Straight after the surface attached: column 80 only exists on the real (96-column) grid.
        harness.replay("\u{1B}[1;80HZ")
        harness.feed("\u{1B}[18t")
        await harness.settle()
        #expect(await eventually { harness.engine.gridSize != nil })
        let grid = harness.engine.gridSize
        #expect(harness.viewportLines.first.map { $0.count == 80 && $0.hasSuffix("Z") } == true,
                "\(harness.viewportLines.first.debugDescription)")
        if let grid {
            #expect(await eventually { harness.written.text == "\u{1B}[8;\(grid.rows);\(grid.columns)t" },
                    "\(harness.written.text.debugDescription)")
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(harness.resizes == [grid].compactMap { $0 }, "\(harness.resizes)")
    }

    /// What a reattach depends on: modes the program set before the detach come back through the
    /// replay, so keys and pastes are encoded the way the program expects.
    @Test func replayRestoresModes() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.window.makeFirstResponder(harness.engine.view)
        // Bracketed paste and kitty keyboard "disambiguate" (what Claude Code pushes).
        harness.replay("\u{1B}[?2004h\u{1B}[>1u")
        await harness.settle()
        #expect(harness.written.bytes.isEmpty)
        _ = harness.engine.paste("x")
        #expect(await eventually { harness.written.text == "\u{1B}[200~x\u{1B}[201~" }, "\(harness.written.text.debugDescription)")
        harness.written.removeAll()
        harness.type("\u{1B}", keyCode: 0x35)
        #expect(await eventually { harness.written.text == "\u{1B}[27u" }, "\(harness.written.text.debugDescription)")
    }

    @Test func replayIsOrderedWithFeeds() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        for index in 0 ..< 50 {
            if index.isMultiple(of: 2) {
                harness.feed("\(index % 10)")
            } else {
                harness.replay("\(index % 10)")
            }
        }
        harness.replay("\r\nreplayed \u{1B}[c")
        harness.feed(" live")
        await harness.settle()
        let expected = (0 ..< 50).map { String($0 % 10) }.joined()
        #expect(harness.viewportLines.first == expected)
        #expect(harness.viewportLines.dropFirst().first == "replayed  live")
        #expect(harness.written.bytes.isEmpty)
    }

    @Test func bytesFedBeforeTheSurfaceExistAreKept() async {
        _ = NSApplication.shared
        let engine = TerminalEngine()
        let log = ByteLog()
        engine.onWrite = { log.append($0) }
        defer { engine.dispose() }
        engine.replay(Array(("history " + Self.probes).utf8))
        engine.feed(Array("live\r\n".utf8))
        #expect(!engine.hasSurface)
        #expect(engine.pendingOutputByteCount > 0)
        #expect(engine.waitUntilParsed() == false)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = engine.view
        #expect(engine.hasSurface)
        #expect(engine.waitUntilParsed())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.readViewportText()?.hasPrefix("history live") == true)
        #expect(log.bytes.isEmpty, "\(log.text.debugDescription)")
    }

    @Test func repliesWrittenBeforeOnWriteIsSetAreDelivered() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.engine.onWrite = nil
        harness.feed("\u{1B}[c")
        await harness.settle()
        try? await Task.sleep(for: .milliseconds(50))
        let late = ByteLog()
        harness.engine.onWrite = { late.append($0) }
        #expect(late.text.contains("\u{1B}[?62;22;52c"))
        #expect(await eventually { harness.deviceAttributesReplies == 1 })
    }

    @Test func firstDeviceAttributesReplyFiresOncePerProcess() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.feed("\u{1B}[>0q\u{1B}[c")
        await harness.settle()
        #expect(await eventually { harness.deviceAttributesReplies == 1 })
        #expect(harness.engine.hasWrittenDeviceAttributesReply)
        harness.feed("\u{1B}[c\u{1B}[c")
        await harness.settle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.deviceAttributesReplies == 1)

        harness.engine.rebuildForNewProcess()
        #expect(!harness.engine.hasWrittenDeviceAttributesReply)
        harness.feed("\u{1B}[c")
        await harness.settle()
        #expect(await eventually { harness.deviceAttributesReplies == 2 })
    }

    @Test func resetClearsScreenAndScrollback() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.feed((1 ... 200).map { "line \($0)" }.joined(separator: "\r\n"))
        await harness.settle()
        #expect(harness.engine.readScreenText()?.contains("line 1\n") == true)
        // Alternate screen and bracketed paste on, then the reset.
        harness.feed("\u{1B}[?1049h\u{1B}[?2004hon the alt screen")
        harness.engine.reset()
        harness.feed("fresh")
        await harness.settle()
        #expect(harness.viewportLines == ["fresh"])
        let screen = harness.engine.readScreenText() ?? ""
        #expect(!screen.contains("line"), "\(screen.prefix(200).debugDescription)")
        // Bracketed paste was reset with everything else: a paste arrives unframed.
        harness.written.removeAll()
        _ = harness.engine.paste("p")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.written.text == "p")
    }

    /// The holder stream's queue calls feed, reset and replay; they must land in that order.
    @Test func resetFromAnotherThreadIsOrderedWithTheStream() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        let engine = harness.engine
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                engine.feed(Array("before the gap\r\n".utf8))
                engine.reset()
                engine.replay(Array("resynced\r\n".utf8))
                engine.feed(Array("live".utf8))
                continuation.resume()
            }
        }
        await harness.settle()
        #expect(harness.viewportLines == ["resynced", "live"])
    }

    @Test func childExitStopsInputUntilRebuild() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.window.makeFirstResponder(harness.engine.view)
        harness.type("a", keyCode: 0x00)
        #expect(await eventually { harness.written.text == "a" })

        harness.feed("last words")
        harness.engine.childExited(status: 0)
        #expect(harness.engine.exitStatus == 0)
        harness.type("b", keyCode: 0x0B)
        harness.feed("\u{1B}[c")
        await harness.settle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.written.text == "a")
        #expect(harness.viewportLines.first == "last words")

        harness.engine.rebuildForNewProcess()
        #expect(harness.engine.hasSurface)
        #expect(harness.engine.exitStatus == nil)
        #expect(harness.viewportLines.isEmpty)
        harness.window.makeFirstResponder(harness.engine.view)
        harness.type("c", keyCode: 0x08)
        #expect(await eventually { harness.written.text == "ac" })
    }

    @Test func reservedKeyEquivalentsStayWithTheApp() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.window.makeFirstResponder(harness.engine.view)
        let reserved: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("k", 0x28, .command), ("1", 0x12, .command), ("9", 0x19, .command), ("\\", 0x2A, .command),
            ("j", 0x26, .command), ("t", 0x11, .command), ("l", 0x25, .command), (",", 0x2B, .command),
            ("n", 0x2D, .command), ("w", 0x0D, .command), ("q", 0x0C, .command),
            ("{", 0x21, [.command, .shift]), ("}", 0x1E, [.command, .shift]),
        ]
        for (characters, keyCode, modifiers) in reserved {
            let event = harness.keyDown(characters, keyCode: keyCode, modifiers: modifiers)
            #expect(harness.engine.isReservedKeyEquivalent(event), "\(characters)")
            #expect(!harness.engine.view.performKeyEquivalent(with: event), "\(characters) was consumed")
            // libghostty's own default binding is unbound too.
            #expect(!harness.engine.isTerminalKeyBinding(event), "\(characters) still bound in libghostty")
        }
        // A reserved chord no menu item took goes up the responder chain, never to the program;
        // so does its release, even when the program asked for key-release events.
        harness.feed("\u{1B}[>11u")
        await harness.settle()
        harness.engine.view.keyDown(with: harness.keyDown("k", keyCode: 0x28, modifiers: .command))
        let release = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, characters: "k",
            charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 0x28
        )!
        harness.engine.view.keyUp(with: release)
        #expect(harness.host.forwardedKeys == ["k", "k"])

        // The terminal keeps copy, paste, select all and zoom.
        let terminal: [(String, UInt16)] = [("c", 0x08), ("v", 0x09), ("a", 0x00), ("=", 0x18), ("-", 0x1B), ("0", 0x1D)]
        for (characters, keyCode) in terminal {
            let event = harness.keyDown(characters, keyCode: keyCode, modifiers: .command)
            #expect(!harness.engine.isReservedKeyEquivalent(event))
            #expect(harness.engine.isTerminalKeyBinding(event), "⌘\(characters) is not a libghostty binding")
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.written.bytes.isEmpty)
    }

    @Test func reportsGridSizeAndFollowsResizes() async {
        let harness = SurfaceHarness(size: NSSize(width: 800, height: 500))
        defer { harness.tearDown() }
        #expect(await eventually { harness.engine.gridSize != nil })
        let first = harness.engine.gridSize
        #expect((first?.columns ?? 0) > 40 && (first?.rows ?? 0) > 10, "\(String(describing: first))")
        #expect((first?.pixelWidth ?? 0) > 0)

        harness.window.setContentSize(NSSize(width: 1200, height: 700))
        harness.host.layoutSubtreeIfNeeded()
        #expect(await eventually { (harness.engine.gridSize?.columns ?? 0) > (first?.columns ?? 0) })
        #expect(harness.resizes.last == harness.engine.gridSize)
    }

    @Test func fontSizeChangesTheGrid() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        #expect(await eventually { harness.engine.gridSize != nil })
        let before = harness.engine.gridSize?.columns ?? 0
        #expect(harness.engine.fontSize == 13)
        harness.engine.fontSize = 20
        #expect(harness.engine.fontSize == 20)
        #expect(await eventually { (harness.engine.gridSize?.columns ?? .max) < before })
    }

    @Test func occludedSurfacesKeepParsing() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.engine.setOccluded(true)
        #expect(harness.engine.isOccluded)
        harness.feed("while hidden\u{1B}[c")
        await harness.settle()
        #expect(harness.viewportLines.first == "while hidden")
        #expect(await eventually { harness.written.text.contains("\u{1B}[?62;22;52c") })
        harness.engine.setOccluded(false)
    }

    @Test func backlogHandlerReportsQueuedBytes() async {
        _ = NSApplication.shared
        let engine = TerminalEngine()
        defer { engine.dispose() }
        let states = ByteLog()
        engine.setOutputBacklogHandler(highWater: 4096, lowWater: 1024) { backlogged in
            states.append([backlogged ? 1 : 0])
        }
        // No surface yet: everything stays queued.
        engine.feed([UInt8](repeating: UInt8(ascii: "x"), count: 3000))
        #expect(states.bytes.isEmpty)
        engine.replay([UInt8](repeating: UInt8(ascii: "y"), count: 2000))
        #expect(states.bytes == [1])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = engine.view
        engine.waitUntilParsed()
        #expect(await eventually { states.bytes == [1, 0] })
        #expect(engine.pendingOutputByteCount == 0)
    }

    /// Review F1: a crossing is decided under the session's lock but delivered after it, on the
    /// thread that crossed. A `true` from the feeding thread that reached the host after the
    /// parser's `false` left the host (a last-writer-wins pause flag, like HolderStream's) paused
    /// with nothing queued, and no further call ever came. Deliveries are serialized now and carry
    /// the state current when they run. The handler stalls on `true` to open the window wide.
    @Test func backlogTransitionsReachTheHostInOrder() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        await harness.settle()
        let paused = Mutex(false)
        let calls = Mutex<[Bool]>([])
        harness.engine.setOutputBacklogHandler(highWater: 4 << 20, lowWater: 1 << 20) { backlogged in
            if backlogged { usleep(150_000) }  // preempted between the decision and applying it
            paused.withLock { $0 = backlogged }
            calls.withLock { $0.append(backlogged) }
        }
        let engine = harness.engine
        let total = 12 << 20
        // A reader that stops while paused, like the holder stream. The first call alone crosses
        // the high mark (so the crossing happens on this thread while the parser drains).
        let fed = await Task.detached { () -> Int in
            var line = [UInt8](repeating: UInt8(ascii: "x"), count: 126)
            line += [0x0D, 0x0A]
            let chunk = Array([[UInt8]](repeating: line, count: 8192).joined())  // 1 MiB
            var fed = 0
            engine.replay(Array([[UInt8]](repeating: chunk, count: 5).joined()))
            fed += 5 * chunk.count
            while fed < total {
                var waited = 0
                while paused.withLock({ $0 }), waited < 3000 {
                    usleep(1000)
                    waited += 1
                }
                guard waited < 3000 else { break }  // stuck paused
                engine.replay(chunk)
                fed += chunk.count
            }
            return fed
        }.value
        #expect(fed == total, "the reader stayed paused after \(fed) bytes; calls \(calls.withLock { $0 })")
        #expect(await eventually(timeout: .seconds(10)) { engine.pendingOutputByteCount == 0 })
        #expect(paused.withLock { $0 } == false)
        let sequence = calls.withLock { $0 }
        #expect(!sequence.isEmpty && sequence.last == false)
        // Strictly alternating: never two of the same in a row.
        #expect(zip(sequence, sequence.dropFirst()).allSatisfy { $0 != $1 }, "\(sequence)")
    }

    @Test func titleAndWorkingDirectoryCallbacks() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        var titles: [String] = []
        var directories: [String] = []
        var bells = 0
        harness.engine.onTitle = { titles.append($0) }
        harness.engine.onWorkingDirectory = { directories.append($0) }
        harness.engine.onBell = { bells += 1 }
        var notifications: [String] = []
        harness.engine.onDesktopNotification = { title, body in notifications.append("\(title)|\(body)") }
        harness.feed("\u{1B}]2;✳ 修正登入 API 401\u{07}\u{1B}]7;file://localhost/tmp/codd%20dir\u{07}\u{07}")
        harness.feed("\u{1B}]777;notify;Claude;等待你的回覆\u{07}")
        await harness.settle()
        #expect(await eventually { titles.last == "✳ 修正登入 API 401" && harness.engine.title == titles.last })
        #expect(await eventually { directories.last?.hasSuffix("/tmp/codd dir") == true }, "\(directories)")
        #expect(await eventually { bells == 1 })
        #expect(await eventually { notifications == ["Claude|等待你的回覆"] }, "\(notifications)")
    }

    @Test func everyEngineSharesOneLibghosttyApp() {
        let first = TerminalRuntime.controller(for: .default)
        let second = TerminalRuntime.controller(for: .default)
        #expect(first === second)
        #expect(TerminalRuntime.lastConfigurationIssue == nil)
    }

    /// A settings change reaches surfaces that already exist.
    @Test func appliedConfigurationReachesLiveSurfaces() async {
        let harness = SurfaceHarness()
        defer {
            harness.tearDown()
            TerminalRuntime.apply(.default)
        }
        #expect(await eventually { harness.engine.gridSize != nil })
        let before = harness.engine.gridSize?.columns ?? 0
        var bigger = TerminalConfiguration.default
        bigger.fontSize = 22
        TerminalRuntime.apply(bigger)
        #expect(TerminalRuntime.configuration == bigger)
        #expect(TerminalRuntime.lastConfigurationIssue == nil)
        #expect(await eventually { (harness.engine.gridSize?.columns ?? .max) < before })
    }

    @Test func disposeStopsEverything() async {
        let harness = SurfaceHarness()
        harness.engine.dispose()
        #expect(harness.engine.isDisposed)
        #expect(!harness.engine.hasSurface)
        #expect(harness.engine.view.superview == nil)
        // Calls after dispose are harmless no-ops.
        harness.feed("ignored")
        harness.replay("ignored")
        harness.engine.reset()
        harness.engine.setOccluded(true)
        harness.engine.fontSize = 18
        #expect(harness.engine.waitUntilParsed())
        #expect(harness.engine.readViewportText() == nil)
        harness.tearDown()
    }

    @Test func poolDisposesColdEngines() {
        _ = NSApplication.shared
        var created: [String] = []
        var evicted: [String] = []
        let pool = TerminalPool<String>(hotCapacity: 1, disposalDelay: .zero) { key in
            created.append(key)
            return TerminalEngine()
        }
        pool.onEvict = { key, _ in evicted.append(key) }
        defer { pool.removeAll() }

        let first = pool.show(["a"])
        #expect(first.map(\.isNew) == [true])
        let a = first[0].engine
        pool.show(["b"])
        #expect(a.isOccluded && !a.isDisposed)
        #expect(pool.tier(of: "a") == .hot)
        let again = pool.show(["a"])
        #expect(again.map(\.isNew) == [false])
        #expect(again[0].engine === a && !a.isOccluded)
        pool.show(["c"])
        pool.show(["d"])
        #expect(evicted == ["b", "a"])
        #expect(a.isDisposed)
        #expect(pool.tier(of: "a") == .cold)
        #expect(pool.show(["a"]).first?.isNew == true)
        #expect(created == ["a", "b", "c", "d", "a"])
        #expect(pool.liveKeys == ["a", "d"])
        pool.setPinned(true, for: "a")
        pool.show(["e"])
        pool.show(["f"])
        #expect(pool.tier(of: "a") == .hot)
        pool.remove("a")
        #expect(evicted.last == "a")
    }

    /// Review F5: freeing a surface (5-16 ms of Metal teardown on the main thread) was part of the
    /// switch that evicted it. The engine is detached and hidden at once and freed a moment later.
    @Test func evictedEnginesAreFreedAfterTheSwitch() async {
        _ = NSApplication.shared
        var evicted: [String] = []
        let pool = TerminalPool<String>(hotCapacity: 0, disposalDelay: .milliseconds(50)) { _ in TerminalEngine() }
        pool.onEvict = { key, _ in evicted.append(key) }
        defer {
            pool.removeAll()
            pool.flushDisposals()
        }
        let a = pool.show(["a"])[0].engine
        let b = pool.show(["b"])[0].engine
        pool.show(["c"])
        // Detached (onEvict) and cold right away, freed later, one per main-queue turn.
        #expect(evicted == ["a", "b"])
        #expect(pool.tier(of: "a") == .cold && pool.tier(of: "b") == .cold)
        #expect(!a.isDisposed && a.isOccluded && a.view.isHidden)
        #expect(pool.pendingDisposalCount == 2)
        #expect(pool.show(["a"]).first?.isNew == true, "showing it again makes a new engine")
        #expect(await eventually { a.isDisposed && b.isDisposed })
        #expect(pool.pendingDisposalCount <= 1, "c, evicted by showing a again, may still wait")
        pool.flushDisposals()
        #expect(pool.pendingDisposalCount == 0)
    }
}
