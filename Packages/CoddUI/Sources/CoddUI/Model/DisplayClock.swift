import Foundation

/// Wall clock used for every duration label. The mock store shifts it so the canonical
/// SPEC numbers (`3m`, `2h57m後`, …) show at launch and then tick; a real store uses offset 0.
/// Never store "now" in the model (research ui.md §5): views ask the clock when they tick.
public struct DisplayClock: Sendable {
    public var offset: TimeInterval = 0
    public init(offset: TimeInterval = 0) { self.offset = offset }
    public func now() -> Date { Date(timeIntervalSinceNow: offset) }
}
