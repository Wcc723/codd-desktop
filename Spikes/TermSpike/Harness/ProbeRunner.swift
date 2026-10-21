import AppKit
import TermSpikeKit

/// `--probe`: for each engine, write Claude Code's startup probes into the
/// engine as if the program had printed them, capture everything the engine
/// writes back, then check replay suppression and key encodings.
@MainActor
struct ProbeRunner {
    let outputDirectory: URL

    /// Keyboard setups Claude can leave the terminal in.
    private static let keyModes: [(name: String, setup: String)] = [
        ("legacy", ""),
        ("kitty >1u", "\u{1B}[>1u"),
        ("modifyOtherKeys 2", "\u{1B}[>4;2m"),
        ("claude (>1u + >4;2m)", "\u{1B}[>1u\u{1B}[>4;2m"),
    ]

    /// Modes repeated with the CJK input method active: what zsh and Claude get.
    private static let inputMethodModes = keyModes.filter { $0.name == "legacy" || $0.name.hasPrefix("claude") }

    /// One run of a set of key modes under one keyboard input source
    /// (nil source = whatever is current).
    private struct KeyPass {
        let source: InputSources.Source?
        let modes: [(name: String, setup: String)]
    }

    /// ASCII layout with every mode, then the CJK input method (if one is
    /// enabled) with legacy and Claude's mode. Same plan for both engines.
    private static func keyPasses() -> [KeyPass] {
        var passes = [KeyPass(source: InputSources.asciiLayout(), modes: keyModes)]
        if let method = InputSources.cjkInputMethod() {
            passes.append(KeyPass(source: method, modes: inputMethodModes))
        }
        return passes
    }

    /// Clears keyboard modes left by the previous step: RIS, pop the kitty stack, mOK off.
    private static let keyReset = "\u{1B}c\u{1B}[<10u\u{1B}[>4;0m"

    func run() async -> Int32 {
        print("TermSpike --probe (\(BuildInfo.configuration) build)")
        var results: [EngineProbeResult] = []
        for kind in EngineKind.allCases {
            let result = await probe(kind)
            print(Self.render(result))
            results.append(result)
        }
        let report = ProbeReport(
            generatedAt: Timestamp.now(),
            build: BuildInfo.configuration,
            machine: .current(),
            engines: results
        )
        do {
            try ResultsStore.write(report, name: "probe.json", in: outputDirectory)
            let markdown = try ResultsStore.regenerateMarkdown(in: outputDirectory)
            print("wrote \(ResultsStore.resultsURL(name: "probe.json", in: outputDirectory).path)")
            print("wrote \(markdown.path)")
            return 0
        } catch {
            print("could not write results: \(error)")
            return 1
        }
    }

    // MARK: - One engine

    private func probe(_ kind: EngineKind) async -> EngineProbeResult {
        let harness = HarnessWindow(title: "TermSpike probe · \(kind.label)")
        let host = EngineFactory.make(kind)
        harness.host(host.view)
        host.viewDidChangeWindow()
        harness.makeKey(host.view)
        var notes: [String] = []
        if !(await Wait.until(timeout: .seconds(5)) { host.isReady }) {
            notes.append("engine did not report ready within 5 s")
        }
        let capture = ReplyCapture()
        host.io.setOutput(capture.sink)
        await Wait.sleep(.milliseconds(300))
        capture.reset()

        // 1. Startup probes, one burst, DA1 last.
        let feeder = host.feeder
        let start = Monotonic.nanos()
        await Wait.offMain { feeder.feed(ClaudeProbes.burst) }
        await Wait.until(timeout: .seconds(3)) {
            ReplyDecoder.decode(capture.bytes).contains { ProbeInterpreter.matches($0, ClaudeProbes.da1) }
        }
        await Wait.sleep(.milliseconds(300)) // stragglers after the sentinel
        let replyBytes = capture.bytes
        let tokens = ReplyDecoder.decode(replyBytes)
        let firstReply = capture.firstArrival.map { Monotonic.millis(from: start, to: $0) }

        // 2. Reattach: replay history holding Claude's probes, its fullscreen
        // modes and a marker. Zero reply bytes only counts if the marker was
        // drawn (the bytes were parsed), the modes came back and live replies
        // still work afterwards.
        let replay = await replayCheck(host: host, capture: capture)

        // 3. Key encodings in each keyboard mode, per input source. The
        // user's source is put back afterwards.
        let originalSource = InputSources.currentIdentifier()
        var modes: [KeyModeResult] = []
        let passes = Self.keyPasses()
        if passes.count < 2 {
            notes.append("no CJK input method enabled: key encodings measured under one layout only")
        }
        for pass in passes {
            if let source = pass.source, !(await InputSources.select(source)) {
                notes.append("could not select input source \(source.id); its key pass was skipped")
                continue
            }
            harness.makeKey(host.view)
            await Wait.sleep(.milliseconds(150))
            let sourceID = InputSources.currentIdentifier()
            if let source = pass.source, sourceID != source.id {
                // Secure Event Input (lock screen, a password field) pins an
                // ASCII layout; results under it would be mislabelled.
                notes.append("input source \(source.id) did not stay selected (now \(sourceID)\(InputSources.secureInputNote)); its key pass was skipped, rerun --probe with the screen unlocked")
                continue
            }
            for mode in pass.modes {
                modes.append(await keyMode(
                    mode.name, setup: mode.setup, inputSource: sourceID,
                    host: host, capture: capture, window: harness.window
                ))
            }
        }

        // 4. After the host reports the child's exit, does the engine still
        // send keys? (A restart in the same surface, or CODD's "resume" in the
        // same tab, depends on it.) Measured under the ASCII layout.
        let afterExit = await inputAfterExit(host: host, capture: capture, harness: harness)
        await InputSources.restore(originalSource)

        if let swiftTerm = host as? SwiftTermHost {
            notes.append("renderer: \(swiftTerm.usesMetal ? "Metal" : "CoreGraphics")")
            if let metalError = swiftTerm.metalError { notes.append("Metal error: \(metalError)") }
        }

        let result = EngineProbeResult(
            engine: kind.label,
            engineVersion: kind == .ghostty ? BuildInfo.ghosttyVersion : BuildInfo.swiftTermVersion,
            grid: host.io.currentSize?.description ?? "?",
            answers: ProbeInterpreter.answers(for: ClaudeProbes.all, tokens: tokens),
            rawReplies: ByteEscaper.escape(replyBytes),
            unclaimed: ProbeInterpreter.unclaimed(tokens, probes: ClaudeProbes.all).map(\.display),
            firstReplyMs: firstReply,
            replay: replay,
            keyModes: modes,
            notes: notes,
            backingScale: Double(harness.window.backingScaleFactor),
            claude: ClaudeCapabilities.evaluate(tokens: tokens),
            inputAfterExit: afterExit
        )
        host.tearDown()
        harness.close()
        await Wait.sleep(.milliseconds(200))
        return result
    }

    private func replayCheck(host: any TerminalEngineHost, capture: ReplyCapture) async -> ReplayCheck {
        capture.reset()
        guard let method = await host.replayWithoutReplies(ReplayProbe.history) else {
            return ReplayCheck(supported: false, replyBytes: 0, note: "no replay path")
        }
        await Wait.sleep(.milliseconds(500)) // a late or asynchronous reply would land here
        let leaked = capture.bytes
        let markerShown = host.screenText().contains(ReplayProbe.marker)

        capture.reset()
        let feeder = host.feeder
        await Wait.offMain { feeder.feed(ReplayProbe.liveQueries) }
        await Wait.until(timeout: .seconds(2)) {
            ReplayProbe.evaluate(ReplyDecoder.decode(capture.bytes)).sentinelAnswered
        }
        await Wait.sleep(.milliseconds(100))
        let verdict = ReplayProbe.evaluate(ReplyDecoder.decode(capture.bytes))

        let control = host.parseControl
        await Wait.offMain {
            feeder.feed(ReplayProbe.leaveAltScreen)
            control.waitUntilParsed()
        }
        await Wait.sleep(.milliseconds(100))
        let altScreenConfirmed = markerShown && !host.screenText().contains(ReplayProbe.marker)
        return ReplayCheck(
            supported: true,
            replyBytes: leaked.count,
            note: leaked.isEmpty ? method : "replies leaked: \(ByteEscaper.escape(leaked)) · \(method)",
            markerShown: markerShown,
            verdict: verdict,
            altScreenConfirmed: altScreenConfirmed
        )
    }

    private func inputAfterExit(
        host: any TerminalEngineHost, capture: ReplyCapture, harness: HarnessWindow
    ) async -> [KeyResult] {
        if let ascii = InputSources.asciiLayout() { _ = await InputSources.select(ascii) }
        let feeder = host.feeder
        let control = host.parseControl
        let reset = Array(Self.keyReset.utf8)
        await Wait.offMain {
            feeder.feed(reset)
            control.waitUntilParsed()
        }
        host.processExited(status: 0)
        await Wait.sleep(.milliseconds(300))
        harness.makeKey(host.view)
        var results: [KeyResult] = []
        for press in 1 ... 2 {
            capture.reset()
            let key = SyntheticKey.letterA
            guard let down = key.event(.keyDown, in: harness.window), let up = key.event(.keyUp, in: harness.window) else {
                results.append(KeyResult(key: "a #\(press) after exit", bytes: "(could not build event)", ok: false, latencyMs: nil))
                continue
            }
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            await Wait.until(timeout: .milliseconds(400)) { !capture.isEmpty }
            await Wait.sleep(.milliseconds(40))
            let bytes = capture.bytes
            results.append(KeyResult(
                key: "a #\(press) after exit",
                bytes: bytes.isEmpty ? "(nothing)" : ByteEscaper.escape(bytes),
                ok: String(decoding: bytes, as: UTF8.self) == "a",
                latencyMs: nil
            ))
        }
        return results
    }

    private func keyMode(
        _ name: String,
        setup: String,
        inputSource: String,
        host: any TerminalEngineHost,
        capture: ReplyCapture,
        window: NSWindow
    ) async -> KeyModeResult {
        let feeder = host.feeder
        let control = host.parseControl
        let setupBytes = Array((Self.keyReset + setup).utf8)
        await Wait.offMain {
            feeder.feed(setupBytes)
            control.waitUntilParsed()
        }
        await Wait.sleep(.milliseconds(100))

        capture.reset()
        await Wait.offMain { feeder.feed(Array("\u{1B}[?u".utf8)) }
        await Wait.until(timeout: .milliseconds(500)) { !capture.isEmpty }
        await Wait.sleep(.milliseconds(30))
        let flagsReply = ByteEscaper.escape(capture.bytes)

        var keys: [KeyResult] = []
        for key in SyntheticKey.probeSet {
            capture.reset()
            guard let down = key.event(.keyDown, in: window), let up = key.event(.keyUp, in: window) else {
                keys.append(KeyResult(key: key.name, bytes: "(could not build event)", ok: false, latencyMs: nil))
                continue
            }
            let start = Monotonic.nanos()
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            await Wait.until(timeout: .milliseconds(400)) { !capture.isEmpty }
            await Wait.sleep(.milliseconds(40))
            let bytes = capture.bytes
            let text = String(decoding: bytes, as: UTF8.self)
            keys.append(KeyResult(
                key: key.name,
                bytes: bytes.isEmpty ? "(nothing)" : ByteEscaper.escape(bytes),
                ok: key.acceptable.contains(text),
                latencyMs: capture.firstArrival.map { Monotonic.millis(from: start, to: $0) }
            ))
        }
        return KeyModeResult(
            mode: name, setup: ByteEscaper.escape(Array(setup.utf8)), inputSource: inputSource,
            kittyFlagsReply: flagsReply, keys: keys
        )
    }

    // MARK: - Console rendering

    static func render(_ result: EngineProbeResult) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("== \(result.engine) · \(result.engineVersion) · grid \(result.grid) ==")
        for (probe, answer) in zip(ClaudeProbes.all, result.answers) {
            let mark = answer.answered ? "[OK]" : "[--]"
            let raw = answer.answered ? answer.raw : ""
            lines.append("  \(mark) \(probe.label.padding(toLength: 40, withPad: " ", startingAt: 0)) \(raw)  \(answer.meaning)")
        }
        if !result.unclaimed.isEmpty {
            lines.append("  other output: \(result.unclaimed.joined(separator: " "))")
        }
        if let first = result.firstReplyMs {
            lines.append(String(format: "  first reply after %.2f ms", first))
        }
        lines.append("  replay: \(result.replay.summary) · \(result.replay.note)")
        for mode in result.keyModes {
            lines.append("  keys [\(mode.mode)] [\(mode.inputSource ?? "?")] CSI ? u → \(mode.kittyFlagsReply.isEmpty ? "(no reply)" : mode.kittyFlagsReply)")
            for key in mode.keys {
                let latency = key.latencyMs.map { String(format: "%.3f ms", $0) } ?? "-"
                lines.append("      \(key.ok ? "ok " : "BAD") \(key.key.padding(toLength: 13, withPad: " ", startingAt: 0)) \(key.bytes.padding(toLength: 18, withPad: " ", startingAt: 0)) \(latency)")
            }
        }
        if let afterExit = result.inputAfterExit {
            lines.append("  input after reported exit: " + afterExit.map { "\($0.key) \($0.ok ? "ok" : "BAD") \($0.bytes)" }.joined(separator: " · "))
        }
        if let claude = result.claude {
            lines.append("  Claude 2.1.300 would enable: " + claude.map { "\($0.capability)=\($0.enabled ? "yes" : "no")" }.joined(separator: " "))
        }
        if let scale = result.backingScale {
            lines.append(String(format: "  backing scale %.0fx (CSI 16 t and pixel sizes are device pixels at this scale)", scale))
        }
        for note in result.notes {
            lines.append("  note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
