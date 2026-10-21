import CoddPosix
import CoddProtocol
import Darwin

/// Accepting, handshake (single client + takeover), frame handling and the outbound pump.
extension Holder {
    // MARK: - Accept

    func acceptConnections() {
        while let fd = endpoint.accept() {
            guard UnixSocket.peerUID(fd) == geteuid() else {
                log.info("rejected connection from another uid")
                Descriptor.closeQuietly(fd)
                continue
            }
            guard pendingConnections.count < Holder.maxPendingConnections else {
                Descriptor.closeQuietly(fd)
                continue
            }
            let connection = ClientConnection(tag: nextTag, fd: fd, now: Clock.monotonicNanoseconds())
            nextTag += 1
            do {
                try loop.addRead(fd, tag: connection.tag)
                try loop.addWrite(fd, tag: connection.tag, enabled: false)
            } catch {
                Descriptor.closeQuietly(fd)
                continue
            }
            pendingConnections.append(connection)
            if !handshakeTimerArmed {
                handshakeTimerArmed = true
                loop.setTimer(HolderTimer.handshake, nanoseconds: 1_000_000_000, repeating: true)
            }
        }
    }

    func handshakeTimerFired() {
        let now = Clock.monotonicNanoseconds()
        for connection in pendingConnections
        where now - connection.acceptedAtNanoseconds >= Holder.handshakeTimeoutNanoseconds {
            reject(connection, code: HolderErrorCode.helloTimeout, message: "no HELLO within 5 s")
        }
        if pendingConnections.isEmpty {
            handshakeTimerArmed = false
            loop.cancelTimer(HolderTimer.handshake)
        }
    }

    // MARK: - Reading frames

    func connectionReadable(_ connection: ClientConnection) {
        var total = 0
        while total < 1 << 20 && !connection.readPaused {
            let count = read(connection.fd, readBuffer.baseAddress, readBuffer.count)
            if count > 0 {
                total += count
                connection.decoder.append(UnsafeRawBufferPointer(start: readBuffer.baseAddress, count: count))
                guard processFrames(connection) else { return }
            } else if count == 0 {
                close(connection, reason: "peer closed")
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                close(connection, reason: "read failed (errno \(errno))")
                return
            }
        }
    }

    /// Handles every complete frame. Returns false when the connection was closed.
    private func processFrames(_ connection: ClientConnection) -> Bool {
        while true {
            let message: Message
            do throws(ProtocolError) {
                guard let frame = try connection.decoder.next() else { return true }
                message = try Message(frame: frame)
            } catch {
                reject(connection, code: HolderErrorCode.badFrame, message: error.description)
                return false
            }
            guard handle(message, from: connection) else { return false }
        }
    }

    /// Returns false when the connection was closed while handling the message.
    private func handle(_ message: Message, from connection: ClientConnection) -> Bool {
        guard connection.handshakeDone else {
            guard case .hello(let hello) = message else {
                reject(connection, code: HolderErrorCode.helloRequired, message: "send HELLO first")
                return false
            }
            return acceptHello(hello, from: connection)
        }
        switch message {
        case .attach(let offset):
            attach(connection, from: offset)
        case .detach:
            connection.attached = false
            // Control frames waiting for output this client will no longer get go out now.
            flush(connection)
        case .input(let flags, let bytes):
            queueInput(bytes, flags: flags, from: connection)
        case .resize(let size):
            resize(size)
        case .signal(let signo):
            sendSignal(signo)
        case .repaint:
            startRepaint()
        case .ping(let token):
            connection.enqueue(.pong(token: token), kind: .pong, afterOffset: 0)
            flush(connection)
        case .hello, .pong, .unknown, .welcome, .output, .gap, .exit, .title, .cwd, .bell, .error:
            break  // duplicates, holder-to-client types and unknown extensions are ignored
        }
        return client === connection
    }

    private func acceptHello(_ hello: Hello, from connection: ClientConnection) -> Bool {
        guard hello.proto == Int(CoddProtocolVersion.current) else {
            reject(connection, code: HolderErrorCode.unsupportedProto, message: "holder speaks proto \(CoddProtocolVersion.current)")
            return false
        }
        let name = TextLimits.printable(hello.client, maxBytes: TextLimits.clientName)
        if let current = client {
            guard hello.takeover else {
                reject(connection, code: HolderErrorCode.busy, message: "session is attached by \(current.clientName)")
                return false
            }
            reject(current, code: HolderErrorCode.takenOver, message: "taken over by \(name)")
        }
        pendingConnections.removeAll { $0 === connection }
        connection.handshakeDone = true
        connection.clientName = name
        connection.wantsAttachAck = hello.caps.contains(HolderCapability.attachAck)
        client = connection
        loop.cancelTimer(HolderTimer.exitLinger)
        connection.enqueue(.welcome(makeWelcome()), kind: .other, afterOffset: 0)
        flush(connection)
        return client === connection
    }

    func makeWelcome() -> Welcome {
        Welcome(
            holder: Holder.version, session: options.session, childPid: childPid,
            cols: requestedSize.cols, rows: requestedSize.rows,
            ringStart: ring.oldestOffset, ringEnd: ring.writeOffset, resync: ring.latestResync,
            modes: scanner.modes, title: scanner.title, cwd: scanner.cwd,
            exited: childExit != nil, exitStatus: childExit?.status, signaled: childExit?.signaled,
            caps: HolderCapability.v1, holderPid: getpid(), ringSize: UInt64(ring.capacity),
            spawnOffset: ring.spawnOffset, progress: scanner.progress, resyncModes: ring.latestResyncModes)
    }

    private func attach(_ connection: ClientConnection, from requested: UInt64) {
        let oldest = ring.oldestOffset
        let start: UInt64
        var gap: GapInfo?
        if requested == Message.latestResync {
            start = ring.latestResync
        } else if requested < oldest {
            // The requested bytes were overwritten. Same policy as a client lapped in drop mode
            // (`refill`): report the hole and restart at a resync point, so replay never begins in the
            // middle of an escape sequence (critique M3).
            let resume = ring.latestResync
            gap = GapInfo(from: requested, to: resume, replayEnd: ring.writeOffset, resumeModes: ring.latestResyncModes)
            start = resume
        } else {
            start = min(requested, ring.writeOffset)
        }
        // ATTACHED and GAP go straight into the outbound buffer, behind whatever an earlier attach
        // left there: everything after ATTACHED belongs to this attach (the client drops older
        // OUTPUT still in flight), and the GAP must precede the replayed OUTPUT even if control
        // frames with later offsets are queued.
        if connection.wantsAttachAck {
            let reported = gap?.from ?? start
            AttachedInfo(start: reported, replayEnd: ring.writeOffset, modes: ring.resyncModes(at: reported), currentModes: scanner.modes)
                .frame.append(to: &connection.outbuf)
        }
        gap?.frame.append(to: &connection.outbuf)
        connection.cursor = start
        connection.attached = true
        connection.dropping = false
        connection.lastProgressNanoseconds = Clock.monotonicNanoseconds()
        flush(connection)
        updateFlowControl()
    }

    // MARK: - Rejecting and closing

    /// How long `reject` may block on a client's socket (the holder has one thread).
    static let rejectWriteTimeoutMilliseconds = 500

    /// Sends ERROR and closes the connection. ERROR must start on a frame boundary: frames not
    /// started on the wire are dropped, a partly written one is finished, then ERROR follows,
    /// written with the socket blocking for at most `rejectWriteTimeoutMilliseconds`. While
    /// output streams the buffer is never empty, and a taken-over client that only saw EOF
    /// reconnected with takeover and took the holder back (review finding); a client that is
    /// reading now always gets the ERROR. One that stopped reading with full socket buffers still
    /// sees only EOF, and does not take over on its reconnect (PtyConnection).
    func reject(_ connection: ClientConnection, code: String, message: String) {
        let message = TextLimits.printable(message, maxBytes: TextLimits.errorMessage)
        log.info("closing connection: \(code) \(message)")
        connection.dropUnsentFrames()
        Message.error(ErrorInfo(code: code, message: message)).append(to: &connection.outbuf)
        writeRemaining(connection, timeoutMilliseconds: Holder.rejectWriteTimeoutMilliseconds)
        close(connection, reason: code)
    }

    /// Blocking writes of the unsent bytes until they are out or `timeoutMilliseconds` passed.
    /// Only for a connection that is closed right after (its descriptor stays blocking).
    private func writeRemaining(_ connection: ClientConnection, timeoutMilliseconds: Int) {
        let fd = connection.fd
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var timeout = timeval(tv_sec: 0, tv_usec: Int32(timeoutMilliseconds * 1000))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Clock.monotonicNanoseconds() + UInt64(timeoutMilliseconds) * 1_000_000
        while connection.unsentByteCount > 0, Clock.monotonicNanoseconds() < deadline {
            let start = connection.outIndex
            let count = connection.outbuf.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base + start, raw.count - start)
            }
            if count > 0 {
                connection.outIndex += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return  // timed out (EAGAIN), peer gone, or nothing written
            }
        }
    }

    func close(_ connection: ClientConnection, reason: String) {
        Descriptor.closeQuietly(connection.fd)
        pendingConnections.removeAll { $0 === connection }
        if client === connection {
            client = nil
            log.info("client \(connection.clientName) gone: \(reason)")
            updateFlowControl()
            if childExit != nil { armExitLinger() }
        }
    }

    // MARK: - Outbound pump

    /// Writes what the socket accepts, materializing frames from the control queue and the ring as
    /// the buffer drains (the ring is the client's output queue: nothing is copied ahead of time).
    func flush(_ connection: ClientConnection) {
        pump(connection)
        // Progress may have brought the client below the low-water mark: resume a paused PTY.
        if connection === client { updateFlowControl() }
    }

    private func pump(_ connection: ClientConnection) {
        while true {
            if connection.unsentByteCount > 0 {
                switch writeAvailable(connection) {
                case .blocked:
                    setWriteInterest(connection, true)
                    return
                case .failed:
                    close(connection, reason: "write failed")
                    return
                case .drained:
                    break
                }
            }
            guard refill(connection) else {
                setWriteInterest(connection, false)
                return
            }
        }
    }

    enum WriteResult {
        case drained, blocked, failed
    }

    /// Non-blocking write of the unsent part of `outbuf`.
    @discardableResult
    func writeAvailable(_ connection: ClientConnection) -> WriteResult {
        while connection.unsentByteCount > 0 {
            let start = connection.outIndex
            let count = connection.outbuf.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(connection.fd, base + start, raw.count - start)
            }
            if count > 0 {
                connection.outIndex += count
                connection.lastProgressNanoseconds = Clock.monotonicNanoseconds()
                if connection.dropping, connection.pendingBytes(writeOffset: ring.writeOffset) <= lowWater {
                    connection.dropping = false
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                return .blocked
            } else {
                return .failed
            }
        }
        connection.compactOutbuf()
        return .drained
    }

    /// Appends ready frames to `outbuf`. Returns false when there is nothing to send.
    private func refill(_ connection: ClientConnection) -> Bool {
        var added = false
        while connection.unsentByteCount < ClientConnection.refillThreshold {
            if let head = connection.control.first, !connection.attached || head.afterOffset <= connection.cursor {
                connection.outbuf.append(contentsOf: head.bytes)
                connection.control.removeFirst()
                added = true
                continue
            }
            guard connection.attached else { break }
            let oldest = ring.oldestOffset
            if connection.cursor < oldest {
                // Lapped while in drop mode: report the hole and continue from the ring's best resync point.
                let resume = ring.latestResync
                GapInfo(from: connection.cursor, to: resume, replayEnd: ring.writeOffset, resumeModes: ring.latestResyncModes)
                    .frame.append(to: &connection.outbuf)
                connection.cursor = resume
                added = true
                continue
            }
            let limit = min(ring.writeOffset, connection.control.first?.afterOffset ?? UInt64.max)
            guard limit > connection.cursor else { break }
            let count = Int(min(limit - connection.cursor, UInt64(ClientConnection.outputFrameBytes)))
            Frame.appendHeader(type: .output, payloadLength: 8 + count, to: &connection.outbuf)
            WireBytes.append(connection.cursor, to: &connection.outbuf)
            ring.copy(from: connection.cursor, count: count, into: &connection.outbuf)
            connection.cursor += UInt64(count)
            added = true
        }
        return added
    }

    func setWriteInterest(_ connection: ClientConnection, _ enabled: Bool) {
        guard connection.writeInterestEnabled != enabled else { return }
        connection.writeInterestEnabled = enabled
        loop.setWriteEnabled(connection.fd, tag: connection.tag, enabled)
    }

    /// Queues a control frame for the client. An attached client gets it after the output written so
    /// far; a client that has not attached (or detached) gets it right away, so EXIT can precede the
    /// OUTPUT of an ATTACH sent after it.
    func sendControl(_ message: Message, kind: ControlFrame.Kind) {
        guard let client, client.handshakeDone else { return }
        client.enqueue(message, kind: kind, afterOffset: client.attached ? ring.writeOffset : 0)
        flush(client)
    }
}
