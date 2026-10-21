import os

/// os_signpost names used by the spike. View them in Instruments with the
/// "os_signpost" / "Points of Interest" instruments, subsystem `app.fancycodd.TermSpike`.
///
/// Intervals:
/// - `keyDown→ptyWrite` (category `latency`): from the app receiving a keyDown
///   (local event monitor, before the engine sees it) to the `write(2)` that
///   carried the engine's encoding of it to the PTY master.
/// - `ptyRead→feed` (category `io`): from a PTY read returning to the engine's
///   feed call returning. For Ghostty this is an enqueue (parsing happens on the
///   session's output queue); for SwiftTerm the feed parses synchronously.
public enum Signposts {
    public static let subsystem = "app.fancycodd.TermSpike"

    public static let latency = OSSignposter(subsystem: subsystem, category: "latency")
    public static let io = OSSignposter(subsystem: subsystem, category: "io")

    public static let keyToWrite: StaticString = "keyDown→ptyWrite"
    public static let readToFeed: StaticString = "ptyRead→feed"
}
