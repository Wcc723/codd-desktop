// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.

import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    ///
    /// CODD: always nil. CODD drives every surface through the host-managed (in-memory) backend, so
    /// the exec backend's shell integration and terminfo are not vendored (no resource bundle).
    public static var directoryURL: URL? {
        nil
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    ///
    /// CODD: always nil (see `directoryURL`); children run with `TERM=xterm-256color`.
    public static var terminfoDirectoryURL: URL? {
        nil
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else {
            // CODD: a value inherited from the launching shell (a developer starting CODD from
            // Ghostty) would point libghostty at another app's resources; keep the runtime
            // independent of it. Runs once, on the main thread, before ghostty_init.
            unsetenv("GHOSTTY_RESOURCES_DIR")
            return
        }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
