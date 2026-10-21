import Foundation
import Observation

/// Rail destinations (SPEC §2).
enum RailArea: String, CaseIterable, Sendable {
    case sessions, notes, status, settings
}

enum SidebarMode: Sendable { case tree, state }

/// Which PTY of a session a terminal shows: the session's own (`◆ CLAUDE`, or `$ zsh` for a SHELL
/// session) or one of its shell tabs (`$ ZSH n`, also the ⌘J panel's shell), named by tab id.
enum PaneTab: Hashable, Sendable {
    case claude
    case shell(String)
}

/// A shell tab or one of the ⌘J panel's tabs. In real mode it is its own holder (`id` is that
/// holder's session id), spawned the first time the tab is shown.
struct ShellTab: Hashable, Sendable, Codable {
    var id: String
    /// Label number (`ZSH`, `ZSH 2`, …; the panel's `ZSH 1`, `ZSH 2`, …). Numbers grow; a closed
    /// tab's number is not reused while a higher one is open.
    var number: Int

    static func make(number: Int) -> ShellTab {
        ShellTab(id: UUID().uuidString.lowercased(), number: number)
    }
}

/// Tab strip and ⌘J panel of one session pane (persisted in real mode, `PaneLayoutStore`).
struct PaneLayout: Equatable, Sendable {
    /// Shell tabs after the session's own tab, in strip order. The app opens none any more (extra
    /// terminals go to the panel); an older panes.json's are moved there (`moveStripTabsToPanel`).
    var tabs: [ShellTab] = []
    var selected: PaneTab = .claude
    /// The bottom panel's shell tabs in strip order (D11); the first is created the first time
    /// ⌘J opens the panel.
    var panelTabs: [ShellTab] = []
    /// The panel tab shown; nil (or a tab that is gone) shows the first.
    var panelSelected: String?
    var panelOpen = false
    /// The panel fills the terminal area: the tab strip's terminal (occluded, still hot), the
    /// composer and the splitter are hidden (D11). Only meaningful while the panel is open.
    var panelMaximized = false
    /// Points; the splitter clamps it to the space the pane has.
    var panelHeight: Double = PaneLayout.defaultPanelHeight
    /// The ⌘L composer bar is shown under the tab strip's terminal (D13: additive panes.json key).
    var composerOpen = false

    static let defaultPanelHeight: Double = 280

    /// The selected tab, falling back to the session's own when it names a tab that is gone.
    var effectiveSelection: PaneTab {
        if case .shell(let id) = selected, !tabs.contains(where: { $0.id == id }) { return .claude }
        return selected
    }

    /// The panel tab the panel shows (M1's single panel shell; still written as `panel`, D13).
    var panel: ShellTab? {
        if let id = panelSelected, let tab = panelTabs.first(where: { $0.id == id }) { return tab }
        return panelTabs.first
    }

    /// Open, maximized and with a tab to show.
    var isPanelMaximized: Bool { panelOpen && panelMaximized && !panelTabs.isEmpty }

    /// Every shell tab of the pane (strip and panel).
    var allShellTabs: [ShellTab] { tabs + panelTabs }

    /// Every extra terminal lives in the bottom panel now (the user's note 2026-10-19), but an
    /// older panes.json can still hold shell tabs in the strip above it. Moves them to the end
    /// of the panel with the same ids (the same holders), numbered after the panel's own; when one
    /// of them was shown, the panel opens on it and the strip shows the session's own tab. Returns
    /// whether anything moved (a layout without strip tabs is left alone).
    @discardableResult
    mutating func moveStripTabsToPanel() -> Bool {
        guard !tabs.isEmpty else { return false }
        var shown: String?
        if case .shell(let id) = effectiveSelection { shown = id }
        var number = (panelTabs.map(\.number).max() ?? 0) + 1
        for tab in tabs where !panelTabs.contains(where: { $0.id == tab.id }) {
            panelTabs.append(ShellTab(id: tab.id, number: number))
            number += 1
        }
        tabs = []
        selected = .claude
        if let shown {
            panelSelected = shown
            panelOpen = true
        }
        return true
    }
}

/// One entry of a session's tab strip.
enum PaneTabItem: Equatable {
    /// The session's own PTY.
    case main
    case shell(ShellTab)
    /// `$ ZSH` of a claude session that has no shell tab yet: created and spawned when opened.
    case pendingShell
}

/// A PTY that rang its bell (BEL) while not on screen (D12): a session's own (`tabID` nil), a
/// shell tab or a panel tab. Drawn as an amber `◆` after the tab label until the PTY is shown.
struct BellKey: Hashable, Sendable {
    var sessionID: SessionID
    var tabID: String?
}

/// Window-level UI state shared by the sidebar, the session pane and the menu bar panel.
/// Real mode persists `panes` (`PaneLayoutStore`); nothing here touches disk.
@MainActor @Observable
final class ShellState {
    /// Session shown in the main pane (drawn as `current` in every sidebar row that mirrors it).
    var currentSessionID: SessionID? {
        didSet { if let id = currentSessionID, id != oldValue { noteViewed(id) } }
    }
    /// Sessions shown in the main pane, most recent first (the ⌘K list with an empty query, D14).
    /// Not observed and not persisted.
    @ObservationIgnored private(set) var viewedSessionIDs: [SessionID] = []

    static let viewedLimit = 20
    var area: RailArea = .sessions
    var sidebarMode: SidebarMode = .tree
    var filterText: String = ""
    /// The inline new-group editor replaces `[+ 新增群組]` (SidebarStates D; tree mode, no filter).
    var isAddingGroup = false
    var footerExpanded = false
    /// D23: the menu bar ACCOUNTS list shows every account (`▸ 全部帳號 n`), not only 3.
    var menuBarAccountsExpanded = false
    /// Collapsed sidebar sections (NEEDS YOU, PINNED, STATE lists).
    var collapsedSections: Set<SidebarSection> = []
    /// Tab strip and panel per session; missing = defaults (CLAUDE selected, no shell spawned).
    var panes: [SessionID: PaneLayout] = [:]
    var terminalFontSize: Double = 13
    /// D11: each shell tab's OSC title (one line, ≤ 24 characters; the label instead of `zsh n`
    /// while a shell sets one) and OSC 7 folder (the panel strip's cwd), one observed object per
    /// tab: the pane reads only its session's tabs, so a title another session's shell animates
    /// never re-renders it (review concurrency-perf-4). Not persisted (the holder reports them
    /// again on reattach).
    @ObservationIgnored private var tabFacts: [String: ShellTabFacts] = [:]
    /// Bumped when a tab gets its first title or folder (the state dump tracks every tab).
    private var tabFactsGeneration = 0
    /// Every tab's title by tab id (state dump, tests; tracks every tab).
    var tabTitles: [String: String] {
        _ = tabFactsGeneration
        return tabFacts.compactMapValues(\.title)
    }
    /// Every tab's folder by tab id (tests).
    var tabCwds: [String: String] {
        _ = tabFactsGeneration
        return tabFacts.compactMapValues(\.cwd)
    }
    /// D12: PTYs that rang while not on screen (amber `◆` after the label). Not persisted.
    var bells: Set<BellKey> = []
    /// D25: shells running a foreground job (green `●` lamp): tab ids, and the session id for a
    /// SHELL session's own PTY. Not persisted; the terminal hub polls it while the window shows.
    var runningTabs: Set<String> = []

    /// Settings › 終端機字級 (`CoddPreferences.Appearance.terminalFontSizeRange`, M4: 8–28).
    static let fontSizeRange: ClosedRange<Double> = 8...28
    /// Longest tab label taken from an OSC title (D11).
    nonisolated static let tabTitleLimit = 24

    func pane(for id: SessionID) -> PaneLayout { panes[id] ?? PaneLayout() }
    func tab(for id: SessionID) -> PaneTab { pane(for: id).effectiveSelection }

    /// The strip after the session's own tab: claude sessions always offer `$ ZSH`.
    func tabItems(for id: SessionID, kind: SessionKind) -> [PaneTabItem] {
        let tabs = pane(for: id).tabs
        if tabs.isEmpty, kind == .claude { return [.main, .pendingShell] }
        return [.main] + tabs.map(PaneTabItem.shell)
    }

    func select(_ tab: PaneTab, in id: SessionID) {
        var layout = pane(for: id)
        guard layout.selected != tab else { return }
        layout.selected = tab
        panes[id] = layout
    }

    /// Selects the first shell tab, creating `ZSH` when the session has none.
    @discardableResult
    func selectFirstShellTab(in id: SessionID, kind: SessionKind) -> ShellTab {
        var layout = pane(for: id)
        let tab = layout.tabs.first ?? ShellTab.make(number: Self.firstNumber(kind))
        if layout.tabs.isEmpty { layout.tabs = [tab] }
        layout.selected = .shell(tab.id)
        panes[id] = layout
        return tab
    }

    /// ⌘T / `+`: appends a shell tab and selects it.
    @discardableResult
    func addShellTab(in id: SessionID, kind: SessionKind) -> ShellTab {
        var layout = pane(for: id)
        let number = max(Self.firstNumber(kind), (layout.tabs.map(\.number).max() ?? 0) + 1)
        let tab = ShellTab.make(number: number)
        layout.tabs.append(tab)
        layout.selected = .shell(tab.id)
        panes[id] = layout
        return tab
    }

    /// Drops a shell tab (closed, or its shell ended). The selection moves to the tab before it,
    /// else the session's own tab.
    func removeShellTab(_ tabID: String, in id: SessionID) {
        var layout = pane(for: id)
        guard let index = layout.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        layout.tabs.remove(at: index)
        if layout.selected == .shell(tabID) {
            layout.selected = index > 0 ? .shell(layout.tabs[index - 1].id) : .claude
        }
        panes[id] = layout
        forgetTab(tabID)
    }

    /// ⌘J. Returns the shown panel tab when the panel is now open (`zsh 1` is created when it has
    /// none), nil when closed. Closing keeps the tabs (their shells keep running) and ends maximize.
    @discardableResult
    func togglePanel(in id: SessionID) -> ShellTab? {
        var layout = pane(for: id)
        layout.panelOpen.toggle()
        if layout.panelOpen, layout.panelTabs.isEmpty {
            let tab = ShellTab.make(number: 1)
            layout.panelTabs = [tab]
            layout.panelSelected = tab.id
        }
        if !layout.panelOpen { layout.panelMaximized = false }
        panes[id] = layout
        return layout.panelOpen ? layout.panel : nil
    }

    /// The panel's `+`: appends a panel tab, selects it and opens the panel.
    @discardableResult
    func addPanelTab(in id: SessionID) -> ShellTab {
        var layout = pane(for: id)
        let tab = ShellTab.make(number: (layout.panelTabs.map(\.number).max() ?? 0) + 1)
        layout.panelTabs.append(tab)
        layout.panelSelected = tab.id
        layout.panelOpen = true
        panes[id] = layout
        return tab
    }

    func selectPanelTab(_ tabID: String, in id: SessionID) {
        var layout = pane(for: id)
        guard layout.panelTabs.contains(where: { $0.id == tabID }), layout.panelSelected != tabID else { return }
        layout.panelSelected = tabID
        panes[id] = layout
    }

    /// Drops a panel tab (closed, or its shell ended). The selection moves to the tab before it,
    /// else the next one; the last one closes the panel (and ends maximize), so the next ⌘J starts
    /// a new `zsh 1`.
    func removePanelTab(_ tabID: String, in id: SessionID) {
        var layout = pane(for: id)
        guard let index = layout.panelTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasShown = layout.panel?.id == tabID
        layout.panelTabs.remove(at: index)
        if layout.panelTabs.isEmpty {
            layout.panelSelected = nil
            layout.panelOpen = false
            layout.panelMaximized = false
        } else if wasShown {
            layout.panelSelected = layout.panelTabs[max(0, index - 1)].id
        }
        panes[id] = layout
        forgetTab(tabID)
    }

    /// `PaneLayout.moveStripTabsToPanel()` for every session (the terminal hub, once panes.json
    /// is loaded and before tab holders are discovered).
    func moveStripTabsToPanel() {
        for (id, layout) in panes where !layout.tabs.isEmpty {
            var moved = layout
            moved.moveStripTabsToPanel()
            panes[id] = moved
        }
    }

    /// Drops every panel tab and closes the panel.
    func removePanel(in id: SessionID) {
        var layout = pane(for: id)
        guard !layout.panelTabs.isEmpty || layout.panelOpen else { return }
        let ids = layout.panelTabs.map(\.id)
        layout.panelTabs = []
        layout.panelSelected = nil
        layout.panelOpen = false
        layout.panelMaximized = false
        panes[id] = layout
        ids.forEach(forgetTab)
    }

    /// The panel's maximize button: fills the terminal area with the panel, or restores the
    /// split. Returns whether it is maximized now (never while the panel is closed).
    @discardableResult
    func toggleMaximize(in id: SessionID) -> Bool {
        setPanelMaximized(!pane(for: id).panelMaximized, in: id)
    }

    @discardableResult
    func setPanelMaximized(_ maximized: Bool, in id: SessionID) -> Bool {
        var layout = pane(for: id)
        let value = maximized && layout.panelOpen && !layout.panelTabs.isEmpty
        if layout.panelMaximized != value {
            layout.panelMaximized = value
            panes[id] = layout
        }
        return value
    }

    // MARK: Tab labels, bells, running lamps (D11, D12, D25)

    /// `$ <label>` of a shell tab: its OSC title while the shell sets one, else `zsh n` (the
    /// strip's first tab is plain `zsh`; panel tabs always carry their number, Split artboard).
    func label(for tab: ShellTab, inPanel: Bool) -> String {
        if let title = facts(tab.id).title { return title }
        return inPanel || tab.number > 1 ? "zsh \(tab.number)" : "zsh"
    }

    /// A tab's OSC 7 folder (tracks that tab only).
    func tabCwd(_ tabID: String) -> String? { facts(tabID).cwd }

    /// The tab's facts, made on first use (reading them tracks only this tab).
    private func facts(_ tabID: String) -> ShellTabFacts {
        if let facts = tabFacts[tabID] { return facts }
        let facts = ShellTabFacts()
        tabFacts[tabID] = facts
        return facts
    }

    /// Records a shell's OSC title for its tab label (nil or blank: back to `zsh n`).
    func setTabTitle(_ title: String?, for tabID: String) {
        let cleaned = title.flatMap(Self.tabTitle)
        guard (tabFacts[tabID]?.title ?? nil) != cleaned else { return }
        let first = tabFacts[tabID] == nil
        facts(tabID).title = cleaned
        if first { tabFactsGeneration += 1 }
    }

    func setTabCwd(_ cwd: String?, for tabID: String) {
        let value = cwd.flatMap { $0.isEmpty ? nil : $0 }
        guard (tabFacts[tabID]?.cwd ?? nil) != value else { return }
        let first = tabFacts[tabID] == nil
        facts(tabID).cwd = value
        if first { tabFactsGeneration += 1 }
    }

    func hasBell(_ key: BellKey) -> Bool { bells.contains(key) }

    func ringBell(_ key: BellKey) {
        if !bells.contains(key) { bells.insert(key) }
    }

    /// The PTY is on screen: its `◆` goes away.
    func clearBell(_ key: BellKey) {
        if bells.contains(key) { bells.remove(key) }
    }

    func setRunning(_ running: Set<String>) {
        if runningTabs != running { runningTabs = running }
    }

    /// A tab is gone: its title, folder, bell and lamp with it.
    func forgetTab(_ tabID: String) {
        if let facts = tabFacts.removeValue(forKey: tabID) {
            if facts.title != nil { facts.title = nil }
            if facts.cwd != nil { facts.cwd = nil }
            tabFactsGeneration += 1
        }
        if runningTabs.contains(tabID) { runningTabs.remove(tabID) }
        if bells.contains(where: { $0.tabID == tabID }) { bells = bells.filter { $0.tabID != tabID } }
    }

    /// A session is gone: everything transient about its PTYs.
    func forgetSession(_ id: SessionID) {
        for tab in pane(for: id).allShellTabs { forgetTab(tab.id) }
        if runningTabs.contains(id) { runningTabs.remove(id) }
        if bells.contains(where: { $0.sessionID == id }) { bells = bells.filter { $0.sessionID != id } }
    }

    /// D11: an OSC title as a tab label: one line, control characters removed, whitespace runs
    /// collapsed, at most `tabTitleLimit` characters (`…` when cut); nil when nothing is left.
    nonisolated static func tabTitle(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            // Bidi controls could reorder the rest of the strip's text.
            if value == 0x200E || value == 0x200F || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { continue }
            if value < 0x20 || (0x7F...0x9F).contains(value) || scalar.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var text = String(scalars)
        if text.hasSuffix(" ") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        guard text.count > tabTitleLimit else { return text }
        return String(text.prefix(tabTitleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// ⌘L: shows or hides the composer bar of a session.
    func setComposerOpen(_ open: Bool, in id: SessionID) {
        var layout = pane(for: id)
        guard layout.composerOpen != open else { return }
        layout.composerOpen = open
        panes[id] = layout
    }

    private func noteViewed(_ id: SessionID) {
        viewedSessionIDs.removeAll { $0 == id }
        viewedSessionIDs.insert(id, at: 0)
        if viewedSessionIDs.count > Self.viewedLimit { viewedSessionIDs.removeLast(viewedSessionIDs.count - Self.viewedLimit) }
    }

    func setPanelHeight(_ height: Double, in id: SessionID) {
        var layout = pane(for: id)
        guard abs(layout.panelHeight - height) >= 1 else { return }
        layout.panelHeight = height
        panes[id] = layout
    }

    /// Shell sessions are `zsh` themselves, so their extra tabs count from 2.
    private static func firstNumber(_ kind: SessionKind) -> Int { kind == .shell ? 2 : 1 }
}

/// One shell tab's transient facts (D11), observed per tab (see `ShellState.label(for:inPanel:)`).
@MainActor @Observable
final class ShellTabFacts {
    var title: String?
    var cwd: String?
}

/// Counts shown in the status bar, rail badge, Dock badge and menu bar panel.
struct SessionCounts: Equatable, Sendable {
    var live = 0
    var waiting = 0
    var error = 0
    var working = 0
    var done = 0
    /// `✕ EXITED` only: STOPPED (`⟲ 可接續`, every claude after a relaunch) is not a crash
    /// (review spec-fidelity-6).
    var exited = 0
    var stopped = 0

    /// Attention = waiting + error (Rail / Dock / menu bar icon).
    var attention: Int { waiting + error }

    @MainActor
    init(sessions: [SessionVM]) {
        for session in sessions {
            let state = session.state
            if state.isLive { live += 1 }
            switch state {
            case .waiting: waiting += 1
            case .error: error += 1
            case .done: done += 1
            case .busy, .compacting: working += 1
            case .exited: exited += 1
            case .stopped: stopped += 1
            default: break
            }
        }
    }

    init() {}
}
