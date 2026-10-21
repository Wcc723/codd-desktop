import Foundation

/// Everything the menu bar panel body shows, as plain values (MenuBar artboard, R4 order):
/// ACCOUNTS · NEEDS YOU · READY · RUNNING (tinted group blocks, first `runningLimit` working
/// sessions, the rest summarised as `+n more · ● a · ○ b idle`).
///
/// The panel computes this inside its observation loop and compares `layout`: when only row
/// contents changed (a tool, a title, a duration origin) the existing row views are updated in
/// place, so a hovered row keeps its `[前往] [1 允許]` buttons while other sessions change.
struct MenuBarPanelContent: Equatable {
    struct Row<Model: Equatable>: Equatable {
        var id: SessionID
        var model: Model
    }

    struct GroupBlock: Equatable {
        var id: GroupID
        var name: String
        var color: TagColor?
        var rows: [Row<PanelCompactRowView.Model>]
    }

    /// `+5 more · ● 1 · ○ 4 idle` under RUNNING.
    struct More: Equatable {
        var hidden: Int
        var busy: Int
        var idle: Int
    }

    var live: Int
    var hostLine: String
    var cleanupSuggestions: Int
    /// The ACCOUNTS rows shown (D23: at most 3 in R7 order, the active one always among them,
    /// unless expanded).
    var accountIDs: [AccountID]
    /// Every account (`▸ 全部帳號 n` when more than the rows shown).
    var accountTotal: Int
    var accountsExpanded: Bool
    /// The availability copy while the accounts are not cswap's (D1 / D3).
    var accountsNote: String?
    var autoSwitchOn: Bool
    var needs: [Row<PanelNeedsRowView.Model>]
    var ready: [Row<PanelCompactRowView.Model>]
    var runningCount: Int
    var running: [GroupBlock]
    var more: More?

    /// Which views exist (and in which order). Equal layout = update rows in place.
    struct Layout: Equatable {
        var accountIDs: [AccountID]
        var accountTotal: Int
        var accountsExpanded: Bool
        var accountsNote: String?
        var needs: [SessionID]
        var ready: [SessionID]
        var runningCount: Int
        var groups: [[String]]
        var hasMore: Bool
    }

    var layout: Layout {
        Layout(accountIDs: accountIDs, accountTotal: accountTotal, accountsExpanded: accountsExpanded, accountsNote: accountsNote,
               needs: needs.map(\.id), ready: ready.map(\.id), runningCount: runningCount,
               groups: running.map { [$0.id, $0.name, $0.color?.rawValue ?? "-"] + $0.rows.map(\.id) },
               hasMore: more != nil)
    }

    static let runningLimit = 4
    /// D23: ACCOUNTS rows before `▸ 全部帳號 n`.
    static let accountLimit = 3

    /// D23: the first `limit` accounts in R7 order, the active one always among them (it takes the
    /// last place shown when it sorts below; the order shown stays R7); all of them when expanded.
    static func visibleAccounts(_ ids: [AccountID], active: AccountID?, expanded: Bool, limit: Int = accountLimit) -> [AccountID] {
        guard !expanded, ids.count > limit else { return ids }
        var shown = Array(ids.prefix(limit))
        if let active, ids.contains(active), !shown.contains(active) {
            shown[limit - 1] = active
            shown.sort { (ids.firstIndex(of: $0) ?? 0) < (ids.firstIndex(of: $1) ?? 0) }
        }
        return shown
    }

    /// Reads the stores (call inside observation tracking).
    @MainActor
    static func build(store: any SessionStore, accounts: any AccountStore, expanded: Bool = false) -> MenuBarPanelContent {
        let ordered = SidebarSnapshotBuilder.treeOrder(store: store)
        let counts = SessionCounts(sessions: store.allSessions)
        let host = store.host

        func location(_ s: SessionVM) -> String {
            let project = store.project(s.projectID)
            let group = project.flatMap { store.group($0.groupID) }
            return [group?.shortName, project?.name].compactMap { $0 }.joined(separator: " / ")
        }

        let needs = ordered.filter { $0.state.needsAttention }.map { s -> Row<PanelNeedsRowView.Model> in
            let lead: String
            let detail: String
            switch (s.state, s.waitingReason) {
            case (.error, _): lead = s.detail.map { "\($0) " } ?? ""; detail = "\(s.errorReason?.lowercased() ?? "error") · 本輪未完成"
            case (_, .question?): lead = "問："; detail = s.detail ?? ""
            default: lead = s.tool.map { "\($0): " } ?? ""; detail = s.detail ?? ""
            }
            let pill = s.state == .waiting ? (s.waitingReason?.shortPill ?? "Wait") : StateStyle.of(s.state).pill
            return Row(id: s.id, model: .init(state: s.state, title: s.title, tag: s.tag, stateSince: s.stateSince,
                                             location: location(s), detailLead: lead, detail: detail, pill: pill,
                                             // D6: an external is never answered from CODD (its row opens the read-only pane).
                                             isPermission: s.state == .waiting && s.waitingReason != .question && !s.external))
        }

        let ready = ordered.filter { $0.state == .done }.map { s in
            Row(id: s.id, model: PanelCompactRowView.Model(state: s.state, title: s.title, tag: s.tag, stateSince: s.stateSince,
                                                         startedAt: s.startedAt, prefix: "",
                                                         suffix: store.project(s.projectID)?.name ?? "",
                                                         accountChip: nil, showsPill: true, tint: nil))
        }

        // RUNNING: working sessions first (busy / compacting / shell / starting), grouped by
        // group block in tree order; the rest is summarised.
        let runningSessions = ordered.filter { $0.state.isLive && !$0.state.needsAttention && $0.state != .done }
        let shown = Array(runningSessions.filter { $0.state != .idle }.prefix(runningLimit))
        var blocks: [GroupBlock] = []
        for s in shown {
            guard let gid = store.project(s.projectID)?.groupID, let group = store.group(gid) else { continue }
            var prefix = ""
            switch s.state {
            case .busy: prefix = s.tool ?? ""
            case .compacting: prefix = "compact"
            case .shell: prefix = s.detail ?? "zsh"
            default: break
            }
            let chip: String? = s.accountPinned && s.accountID != accounts.activeAccountID
                ? s.accountID.flatMap { accounts.account($0)?.slot } : nil
            let row = Row(id: s.id, model: PanelCompactRowView.Model(
                state: s.state, title: s.title, tag: s.tag, stateSince: s.stateSince, startedAt: s.startedAt, prefix: prefix,
                suffix: "", accountChip: chip, showsPill: false, tint: group.isUngrouped ? nil : group.color))
            if let index = blocks.firstIndex(where: { $0.id == gid }) {
                blocks[index].rows.append(row)
            } else {
                blocks.append(GroupBlock(id: gid, name: group.name, color: group.isUngrouped ? nil : group.color, rows: [row]))
            }
        }
        let shownIDs = Set(shown.map(\.id))
        let hidden = runningSessions.filter { !shownIDs.contains($0.id) }
        let more = hidden.isEmpty ? nil : More(hidden: hidden.count, busy: hidden.filter { $0.state.isWorking }.count,
                                               idle: hidden.filter { $0.state == .idle }.count)

        let ids = accounts.accounts.map(\.id)
        return MenuBarPanelContent(live: counts.live, hostLine: host.line, cleanupSuggestions: host.cleanupSuggestions,
                                   accountIDs: visibleAccounts(ids, active: accounts.activeAccountID, expanded: expanded),
                                   accountTotal: ids.count, accountsExpanded: expanded,
                                   accountsNote: accounts.isPlaceholder ? nil : accounts.availability.note,
                                   autoSwitchOn: accounts.autoSwitch.enabled,
                                   needs: needs, ready: ready, runningCount: runningSessions.count, running: blocks, more: more)
    }
}
