import AppKit

/// Which optional pieces of a one-line row fit its width (window resize, interface zoom).
///
/// A row's always-shown part takes `fixed`; each optional piece adds its `cost` (its natural
/// width plus the spacing in front of it), most important first. Pieces are taken in order
/// while they fit; the first one that does not hides together with every less important one,
/// so a row never shows a later piece without an earlier one and the result only depends on the
/// width (never on what is shown now: no flicker while a window is dragged).
///
/// The optional pieces must not resist compression above the window's stay-put priority (500):
/// the row decides to hide them, the layout engine must never grow the window to keep them.
public enum RowFit {
    /// The compression resistance of an optional piece: below the window's stay-put priority
    /// (500), so the engine can squeeze it for the one layout pass before the row hides it, and
    /// above a label's (250), so labels give way first.
    public static let optionalCompression = NSLayoutConstraint.Priority(260)

    /// How many of `costs` (most important first) fit in `available` after `fixed`.
    public static func shownCount(available: CGFloat, fixed: CGFloat, costs: [CGFloat]) -> Int {
        var used = fixed
        for (index, cost) in costs.enumerated() {
            used += cost
            if used > available + 0.5 { return index }
        }
        return costs.count
    }

    /// `shownCount` as one flag per piece (true: shown).
    public static func shown(available: CGFloat, fixed: CGFloat, costs: [CGFloat]) -> [Bool] {
        let count = shownCount(available: available, fixed: fixed, costs: costs)
        return costs.indices.map { $0 < count }
    }
}
