import AppKit
import CoddPreferences
import CoddUI

/// The Dock badge (Settings › 通知 › Dock 徽章, D29): `等待數` = waiting + error (the default, M1's
/// badge), `全部` = every live session, `關` = none. Written only when the text changes; the
/// pause and quiet hours never touch it (badges keep updating).
///
/// It also owns the live Dock tile (post-M4, `DockTileController`): the amber cell blinks, then
/// stays lit while a session needs the user. The badge does not depend on it.
@MainActor
final class AttentionMonitor {
    private var loop: ObservationLoop?
    private var lastLabel: String??
    /// Where the label goes (tests capture it instead of the Dock).
    private let write: @MainActor (String?) -> Void
    /// The live Dock tile (nil: tests, which never touch the Dock).
    let tile: DockTileController?

    init(store: any SessionStore, mode: @escaping @MainActor () -> CoddPreferences.DockBadge = { .waiting },
         write: @escaping @MainActor (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 },
         tile: DockTileController? = nil) {
        self.write = write
        self.tile = tile
        loop = ObservationLoop(track: { [weak store] in
            Self.label(sessions: store?.allSessions ?? [], mode: mode())
        }, apply: { [weak self] label in self?.update(label) })
    }

    /// The badge text for `mode` (nil: no badge).
    static func label(sessions: [SessionVM], mode: CoddPreferences.DockBadge) -> String? {
        let count: Int
        switch mode {
        case .waiting: count = sessions.filter { $0.state.needsAttention }.count
        case .all: count = sessions.filter { $0.state.isLive }.count
        case .off: count = 0
        }
        return count > 0 ? "\(count)" : nil
    }

    /// The Dock icon was shown or hidden (D20): the tile looks again.
    func dockPolicyChanged() { tile?.refresh() }

    private func update(_ label: String?) {
        guard lastLabel != .some(label) else { return }
        lastLabel = .some(label)
        write(label)
    }
}
