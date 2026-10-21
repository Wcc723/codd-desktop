import CoddPosix
import CoddProtocol
import Darwin

/// Child exit, exit linger, termination, meta.json and socket-path supervision.
extension Holder {
    // MARK: - Child exit

    /// NOTE_EXIT (or ESRCH when registering it): reap the child and record how it ended.
    func childDidExit() {
        guard childExit == nil, childPid > 0 else { return }
        if !reapChildIfExited() {
            // NOTE_EXIT can precede the zombie becoming reapable by a moment.
            loop.setTimer(HolderTimer.reap, nanoseconds: 5_000_000)
        }
    }

    /// Non-blocking `waitpid`; records the exit when the child is gone. Returns false while it runs.
    @discardableResult
    func reapChildIfExited() -> Bool {
        guard childExit == nil, childPid > 0 else { return true }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(childPid, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 { return false }
        // ECHILD (someone else reaped it): the status is unknown.
        let termination = result == childPid ? ProcessTermination(waitStatus: status) : nil
        recordChildExit(termination ?? ProcessTermination(status: -1, signaled: false))
        return true
    }

    func recordChildExit(_ termination: ProcessTermination) {
        guard childExit == nil else { return }
        drainPTY()
        childExit = termination
        childExitedAt = Clock.wallMilliseconds()
        ring.setExit(status: termination.status, signaled: termination.signaled)
        if repaint.active {
            repaint.active = false
            loop.cancelTimer(HolderTimer.repaint)
        }
        input.removeAll()
        // Queued input is gone: a client paused by input backpressure must be read again, or its
        // DETACH / close would go unnoticed (and the exit linger would never start).
        resumeClientReadsIfNeeded()
        log.info("child exited: status \(termination.status) signaled \(termination.signaled)")
        sendControl(.exit(ExitInfo(status: termination.status, signaled: termination.signaled)), kind: .exit)
        writeMeta()
        if terminating {
            exitCode = 0
        } else if client == nil {
            armExitLinger()
        }
    }

    func armExitLinger() {
        let nanoseconds = UInt64(options.exitLingerMilliseconds) * 1_000_000
        loop.setTimer(HolderTimer.exitLinger, nanoseconds: nanoseconds)
    }

    func lingerFired() {
        if client == nil && childExit != nil {
            log.info("exiting: child gone and no client")
            exitCode = 0
        }
    }

    // MARK: - Termination (SIGTERM / SIGINT)

    /// Hangs up the session the way closing a terminal window does (close the master → SIGHUP),
    /// escalates to SIGKILL after 3 s, and exits once the child is gone.
    func beginTermination(reason: String) {
        guard !terminating else { return }
        terminating = true
        log.info("terminating: \(reason)")
        guard childExit == nil, childPid > 0 else {
            exitCode = 0
            return
        }
        drainPTY()
        if masterFD >= 0 {
            loop.removeDescriptor(masterFD)
            Descriptor.closeQuietly(masterFD)
            masterFD = -1
            ptyReadable = false
        }
        kill(childPid, SIGHUP)
        kill(childPid, SIGCONT)
        loop.setTimer(HolderTimer.terminate, nanoseconds: Holder.terminateGraceNanoseconds)
    }

    func terminateGraceExpired() {
        guard childExit == nil, childPid > 0 else { return }
        log.info("child ignored SIGHUP; sending SIGKILL")
        killpg(childPid, SIGKILL)
        kill(childPid, SIGKILL)
    }

    /// Final bookkeeping before the process exits: last frames to the client, meta, ring, socket.
    func shutdown() {
        if let client {
            // Give the client up to 200 ms to receive the last frames (EXIT in particular).
            let deadline = Clock.monotonicNanoseconds() + 200_000_000
            flush(client)
            while let current = self.client, current.unsentByteCount > 0, Clock.monotonicNanoseconds() < deadline {
                var poller = pollfd(fd: current.fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 20)
                flush(current)
            }
            if let current = self.client { Descriptor.closeQuietly(current.fd) }
            self.client = nil
        }
        for connection in pendingConnections { Descriptor.closeQuietly(connection.fd) }
        pendingConnections.removeAll()
        ring.markHolderExited()
        ring.flush(synchronous: true)
        writeMeta(holderExited: true)
        endpoint.shutdown()
        if directoryFD >= 0 { Descriptor.closeQuietly(directoryFD) }
        if masterFD >= 0 { Descriptor.closeQuietly(masterFD) }
        log.info("holder exit")
    }

    // MARK: - meta.json

    func scheduleMetaWrite() {
        guard !metaTimerArmed else { return }
        metaTimerArmed = true
        loop.setTimer(HolderTimer.meta, nanoseconds: Holder.metaDebounceNanoseconds)
    }

    func writeMeta(holderExited: Bool = false) {
        let meta = HolderMeta(
            session: options.session, holderVersion: Holder.version, holderPid: getpid(), childPid: childPid,
            argv: options.argv, cwd: options.cwd, socket: options.socketPath, ring: ring.path,
            ringSize: UInt64(ring.capacity), cols: requestedSize.cols, rows: requestedSize.rows,
            startedAt: startedAt, boot: bootSession, title: scanner.title, oscCwd: scanner.cwd, progress: scanner.progress,
            exited: childExit != nil, exitStatus: childExit?.status, signaled: childExit?.signaled,
            exitedAt: childExitedAt, holderExited: holderExited)
        let path = PosixFile.join(options.sessionDirectory, HolderMeta.fileName)
        do {
            try PosixFile.writeAtomically(path, meta.jsonValue().serialized())
        } catch {
            log.info("meta.json write failed: \(error)")
        }
    }

    // MARK: - Socket path supervision

    func watchDirectory() {
        guard directoryFD < 0, let descriptor = endpoint.openDirectoryForEvents() else { return }
        do {
            try loop.watchVnode(descriptor, tag: HolderTag.directory)
            directoryFD = descriptor
        } catch {
            Descriptor.closeQuietly(descriptor)
        }
    }

    func directoryChanged(flags: UInt32) {
        let gone = UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)
        if flags & gone != 0, directoryFD >= 0 {
            Descriptor.closeQuietly(directoryFD)
            directoryFD = -1
        }
        verifySocketPath()
    }

    /// Re-binds when the socket file (or its directory) disappeared.
    func verifySocketPath() {
        guard !terminating, exitCode == nil else { return }
        if endpoint.isPathMissing {
            do throws(SystemError) {
                try endpoint.bind()
                try loop.addRead(endpoint.fd, tag: HolderTag.listener)
                log.info("socket path disappeared; re-bound \(endpoint.path)")
            } catch {
                log.info("re-bind failed: \(error)")
            }
        }
        if directoryFD < 0 { watchDirectory() }
    }
}
