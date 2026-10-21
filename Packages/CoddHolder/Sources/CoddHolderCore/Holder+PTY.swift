import CoddPosix
import CoddProtocol
import Darwin

/// PTY output (ring + scanner + flow control) and input (queue, submit, resize, signals, repaint).
extension Holder {
    // MARK: - Child start

    func startChild() {
        do throws(SystemError) {
            let child = try PTYChild.spawn(
                argv: options.argv, environment: environment, cwd: options.cwd,
                cols: options.cols, rows: options.rows)
            masterFD = child.masterFD
            childPid = child.pid
            ptyReadable = true
            ring.setProcesses(holder: getpid(), child: child.pid)
            if let failure = child.launchFailure {
                // A chdir failure names the folder: `claude: chdir failed` read as if claude were
                // missing (review E2E-6).
                let subject = failure.isDirectoryFailure ? options.cwd : options.argv[0]
                appendHolderMessage("codd-holder: \(subject): \(failure.message)")
            }
            try loop.addRead(masterFD, tag: HolderTag.master)
            try loop.addWrite(masterFD, tag: HolderTag.master, enabled: false)
        } catch {
            appendHolderMessage("codd-holder: cannot start \(options.argv[0]): \(error)")
            if childPid == 0 {
                // No process at all: report it like a shell would report a failed exec.
                recordChildExit(ProcessTermination(status: 126, signaled: false))
                writeMeta()
                return
            }
            // Forked but not observable (kqueue registration failed): do not leave it running unseen.
            kill(childPid, SIGKILL)
        }
        writeMeta()
        do {
            try loop.watchProcessExit(childPid, tag: HolderTag.child)
            // NOTE_EXIT is edge-triggered: a child that finished exiting before the registration (a
            // fast exec failure) never posts it. Its zombie is still there, so check once now.
            reapChildIfExited()
        } catch {
            childDidExit()  // ESRCH: it already exited (typically a failed exec)
        }
    }

    /// Text the holder itself puts into the stream (shown to the user like terminal output).
    func appendHolderMessage(_ text: String) {
        log.info(text)
        ring.append(Array("\r\n\(text)\r\n".utf8))
    }

    // MARK: - Output

    func readPTY() {
        guard masterFD >= 0, ptyReadable else { return }
        var budget = 1 << 20
        while budget > 0 {
            // Stop as soon as a protected client is over the high-water mark: reading on until the
            // budget ran out could lap it (pending > ring capacity) with a small ring, which would turn
            // backpressure into a GAP for a client that is keeping up.
            if isProtectedClientOverHighWater { break }
            let region = ring.writableRegion()
            let count = read(masterFD, region.baseAddress, region.count)
            if count > 0 {
                consumeOutput(UnsafeRawBufferPointer(start: region.baseAddress, count: count))
                budget -= count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                break
            } else {
                // 0 / EIO: every slave descriptor is closed.
                ptyHangup()
                break
            }
        }
        if let client { flush(client) }
        updateFlowControl()
    }

    /// Reads whatever is left in the PTY when the child exits (or the session is hung up), so EXIT
    /// follows all of the child's output. The high-water mark is ignored: XNU revokes the terminal
    /// when the session leader exits, so only the few KiB already buffered remain (background jobs
    /// get EIO). The lap check is defensive, in case a writer survives: a protected client is never
    /// lapped, and anything left stays in the PTY for `readPTY` and its flow control.
    func drainPTY() {
        guard masterFD >= 0, ptyReadable else { return }
        var budget = ring.capacity
        while budget > 0 {
            if isProtectedClientNearLap { return }
            let region = ring.writableRegion()
            let count = read(masterFD, region.baseAddress, region.count)
            if count > 0 {
                consumeOutput(UnsafeRawBufferPointer(start: region.baseAddress, count: count))
                budget -= count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                return
            } else {
                ptyHangup()
                return
            }
        }
    }

    /// `bytes` were just read into the ring's writable region: scan, then publish.
    private func consumeOutput(_ bytes: UnsafeRawBufferPointer) {
        scanner.scan(bytes, at: ring.writeOffset)
        ring.commit(bytes.count)
        if repaint.active { repaint.lastOutputAt = Clock.monotonicNanoseconds() }
        handleScannerEvents()
    }

    private func handleScannerEvents() {
        let events = scanner.takeEvents()
        guard !events.isEmpty else { return }
        for point in events.resyncs { ring.recordResync(point) }
        if events.modesChanged { ring.setModes(scanner.modes) }
        if events.titleChanged, let title = scanner.title {
            sendControl(.title(title), kind: .title)
            scheduleMetaWrite()
        }
        if events.cwdChanged, let cwd = scanner.cwd {
            sendControl(.cwd(cwd), kind: .cwd)
            scheduleMetaWrite()
        }
        if events.bells > 0 { sendControl(.bell, kind: .bell) }
        if events.progressChanged { scheduleMetaWrite() }
        if events.syncEnded && repaint.active && repaint.lastOutputAt != 0 { finishRepaint() }
    }

    private func ptyHangup() {
        guard ptyReadable else { return }
        ptyReadable = false
        if masterFD >= 0 { loop.setReadEnabled(masterFD, tag: HolderTag.master, false) }
        log.info("pty hangup")
    }

    // MARK: - Flow control

    /// The attached client is protected by backpressure (healthy, not in drop mode).
    private var protectedClient: ClientConnection? {
        guard let client, client.attached, !client.dropping, !terminating else { return nil }
        return client
    }

    /// Invariant: while a protected client exists, its pending bytes never exceed
    /// `highWater + ring.maxChunk` (<= capacity / 2 + 64 KiB), so the ring never laps it.
    private var isProtectedClientOverHighWater: Bool {
        guard let client = protectedClient else { return false }
        return client.pendingBytes(writeOffset: ring.writeOffset) > highWater
    }

    /// One more full-size PTY read could overwrite bytes the protected client has not received yet.
    private var isProtectedClientNearLap: Bool {
        guard let client = protectedClient else { return false }
        return client.pendingBytes(writeOffset: ring.writeOffset) + UInt64(ring.maxChunk) > UInt64(ring.capacity)
    }

    /// Pauses PTY reads while a healthy attached client has more than `highWater` bytes pending and
    /// resumes below `lowWater`. A client in drop mode (or no client) never pauses the child.
    func updateFlowControl() {
        guard masterFD >= 0, ptyReadable else { return }
        var shouldPause = false
        if let client = protectedClient {
            let pending = client.pendingBytes(writeOffset: ring.writeOffset)
            shouldPause = ptyPaused ? pending > lowWater : pending > highWater
        }
        guard shouldPause != ptyPaused else { return }
        ptyPaused = shouldPause
        loop.setReadEnabled(masterFD, tag: HolderTag.master, !shouldPause)
        if shouldPause, let client {
            client.lastProgressNanoseconds = max(client.lastProgressNanoseconds, Clock.monotonicNanoseconds())
            if !watchdogArmed {
                watchdogArmed = true
                loop.setTimer(HolderTimer.watchdog, nanoseconds: Holder.watchdogIntervalNanoseconds, repeating: true)
            }
        } else if watchdogArmed {
            watchdogArmed = false
            loop.cancelTimer(HolderTimer.watchdog)
        }
    }

    /// 500 ms without write progress while the PTY is paused: stop protecting this client.
    func watchdogFired() {
        guard ptyPaused, let client else {
            watchdogArmed = false
            loop.cancelTimer(HolderTimer.watchdog)
            return
        }
        if Clock.monotonicNanoseconds() - client.lastProgressNanoseconds >= Holder.stallNanoseconds {
            client.dropping = true
            log.info("client stalled; drop mode")
            updateFlowControl()
        }
    }

    // MARK: - Input

    /// One INPUT frame. With `paste` the bytes are one paste: bracketed (markers inside removed) when
    /// the child's current modes, i.e. everything read from the PTY so far, have `?2004` on, else
    /// unchanged; a submit then follows 50 ms after the unit instead of 10 ms.
    func queueInput(_ bytes: [UInt8], flags: InputFlags, from connection: ClientConnection) {
        guard childExit == nil, masterFD >= 0 else { return }
        let paste = flags.contains(.paste)
        let unit = paste && scanner.modes.bracketedPaste ? BracketedPaste.wrap(bytes) : bytes
        input.append(unit, submit: flags.contains(.submit), paste: paste)
        writePTY()
        if input.pendingBytes > Holder.inputPauseBytes, !connection.readPaused {
            log.info("input queue at \(input.pendingBytes) bytes; pausing client reads")
            connection.readPaused = true
            loop.setReadEnabled(connection.fd, tag: connection.tag, false)
        }
    }

    func writePTY() {
        guard masterFD >= 0 else {
            input.removeAll()
            return
        }
        while let head = input.head {
            if input.headIsSubmit {
                if !submitArmed {
                    let now = Clock.monotonicNanoseconds()
                    let delay = head == .pasteSubmit ? Holder.pasteSubmitDelayNanoseconds : Holder.submitDelayNanoseconds
                    let deadline = lastInputWriteAt + delay
                    submitArmed = true
                    loop.setTimer(HolderTimer.submit, nanoseconds: deadline > now ? deadline - now : 1, critical: true)
                }
                setPTYWriteInterest(false)
                return
            }
            let fd = masterFD
            let written = input.withHeadBytes { write(fd, $0.baseAddress, $0.count) } ?? 0
            if written > 0 {
                input.consume(written)
                lastInputWriteAt = Clock.monotonicNanoseconds()
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                setPTYWriteInterest(true)
                return
            } else {
                log.info("pty write failed (errno \(errno)); dropping queued input")
                input.removeAll()
                break
            }
        }
        setPTYWriteInterest(false)
        resumeClientReadsIfNeeded()
    }

    func submitTimerFired() {
        submitArmed = false
        input.resolveSubmit()
        writePTY()
    }

    private func setPTYWriteInterest(_ enabled: Bool) {
        guard ptyWriteInterest != enabled, masterFD >= 0 else { return }
        ptyWriteInterest = enabled
        loop.setWriteEnabled(masterFD, tag: HolderTag.master, enabled)
    }

    func resumeClientReadsIfNeeded() {
        guard let client, client.readPaused, input.pendingBytes < Holder.inputResumeBytes else { return }
        client.readPaused = false
        loop.setReadEnabled(client.fd, tag: client.tag, true)
    }

    // MARK: - Size, signals, repaint

    func resize(_ size: WindowSize) {
        guard size.cols > 0, size.rows > 0 else { return }
        requestedSize = size
        if repaint.active {
            finishRepaint()
        } else {
            applyPTYSize(size)
        }
        ring.setSize(cols: size.cols, rows: size.rows)
        scheduleMetaWrite()
    }

    private func applyPTYSize(_ size: WindowSize) {
        guard masterFD >= 0 else { return }
        try? TerminalIO.setWindowSize(
            masterFD, cols: size.cols, rows: size.rows, pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight)
    }

    /// Delivers `signo` to the PTY's foreground process group (falls back to the child).
    func sendSignal(_ signo: UInt8) {
        guard signo > 0, signo < 32, childExit == nil else { return }
        let group = masterFD >= 0 ? tcgetpgrp(masterFD) : -1
        if group > 0 {
            killpg(group, Int32(signo))
        } else if childPid > 0 {
            kill(childPid, Int32(signo))
        }
    }

    /// Shrinks by one column so the child gets SIGWINCH and redraws, then restores the size once its
    /// output has been quiet for 30 ms or a synchronized update ends (`?2026l`), at most after 150 ms.
    ///
    /// The quiet window starts only after the child wrote something: restoring before it handled the
    /// first SIGWINCH would let both signals coalesce, and a child that sees an unchanged size may not
    /// redraw at all.
    func startRepaint() {
        guard masterFD >= 0, childExit == nil, !repaint.active else { return }
        var shrunk = requestedSize
        shrunk.cols = requestedSize.cols > 1 ? requestedSize.cols - 1 : requestedSize.cols + 1
        applyPTYSize(shrunk)
        repaint = RepaintState(active: true, startedAt: Clock.monotonicNanoseconds(), lastOutputAt: 0)
        loop.setTimer(HolderTimer.repaint, nanoseconds: Holder.repaintQuietNanoseconds, critical: true)
    }

    func repaintTimerFired() {
        guard repaint.active else { return }
        let now = Clock.monotonicNanoseconds()
        let hardDeadline = repaint.startedAt + Holder.repaintMaxNanoseconds
        let quietDeadline = repaint.lastOutputAt == 0
            ? hardDeadline
            : repaint.lastOutputAt + Holder.repaintQuietNanoseconds
        if now >= quietDeadline || now >= hardDeadline {
            finishRepaint()
        } else {
            loop.setTimer(HolderTimer.repaint, nanoseconds: min(quietDeadline, hardDeadline) - now, critical: true)
        }
    }

    func finishRepaint() {
        guard repaint.active else { return }
        repaint.active = false
        loop.cancelTimer(HolderTimer.repaint)
        applyPTYSize(requestedSize)
    }
}
