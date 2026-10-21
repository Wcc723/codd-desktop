// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalView+Process.swift
//  libghostty-spm
//
//  Public read access to the pty's foreground process, available on both
//  AppKit (`AppTerminalView`) and UIKit (`UITerminalView`) hosts via the
//  `TerminalView` typealias. Both concrete views expose the same internal
//  `surface` accessor, so a single extension covers every platform.
//

import Foundation

public extension TerminalView {
    /// PID of the pty's foreground process group (`tcgetpgrp(pty)`). When the
    /// user runs a program in the pty this is that program's pid, so hosts can
    /// correlate the surface with an external process list. Nil until the
    /// surface has a process.
    var foregroundPid: pid_t? {
        surface?.foregroundPid
    }

    /// Name of the pty's controlling tty (e.g. `/dev/ttys004`), or nil until
    /// the surface has a process.
    var ttyName: String? {
        surface?.ttyName
    }
}
