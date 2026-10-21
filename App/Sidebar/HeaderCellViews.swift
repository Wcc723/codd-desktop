import AppKit
import CoddUI

/// Group header inside its tinted block (R1: compact 22 px, name in the group color, no
/// square) with aggregate badges `◆2 ●1 $1`. While hovered (or while its menu is open) the
/// badges give way to real buttons (SidebarStates C / D `.ss-gh`): `清理已停止 (n)` when the group
/// has stopped CODD sessions, `+` (new session in the group) and `⋯` (the group menu). As the
/// target of a project drag it says `移入` (SidebarStates A).
final class GroupHeaderCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("group")

    private var name = ""
    private var nameColor = Palette.dim
    private var counts: [(SessionState, Int)] = []
    private var isOpen = true
    private var renaming = false
    /// Stopped / exited CODD sessions in the group (`清理已停止 (n)`).
    private(set) var stoppedCount = 0
    private(set) var groupID: GroupID?
    /// `藍鵲·網站 群組，展開，3 個 session：等待中 1、工作中 1、Shell 1` (M5 D21).
    private var groupSpeech: String?
    override var spokenLabel: String? { groupSpeech }

    let cleanButton = CoddButton("清理已停止", style: .plain)
    let addButton = CoddButton("+", style: .glyph(size: 22))
    let moreButton = CoddButton("⋯", style: .glyph(size: 22))
    /// The `⋯` menu is open: the actions stay up and `⋯` is drawn `.on`.
    var isMenuOpen = false {
        didSet {
            moreButton.isOn = isMenuOpen
            updateActions()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        for button in [cleanButton, addButton, moreButton] {
            button.isHidden = true
            button.target = self
            addSubview(button)
        }
        cleanButton.action = #selector(cleanClicked)
        addButton.action = #selector(addClicked)
        moreButton.action = #selector(moreClicked)
    }

    override var isHovered: Bool { didSet { if isHovered != oldValue { updateActions() } } }

    var nameFrame: CGRect {
        let z = UIZoom.pt
        return CGRect(x: contentLeft + z(20), y: Metrics.groupGap + 1, width: max(z(60), contentRight - contentLeft - z(110)), height: z(20))
    }

    func setRenaming(_ value: Bool) { renaming = value; needsDisplay = true }

    /// Whether the hover buttons are up (tests, drawing).
    var showsActions: Bool { (isHovered || isMenuOpen) && !renaming }

    /// The buttons a click at `windowPoint` hits (the row's own click must then do nothing).
    func actionButton(atWindowPoint windowPoint: NSPoint) -> CoddButton? {
        [cleanButton, addButton, moreButton].first { button in
            !button.isHidden && button.bounds.contains(button.convert(windowPoint, from: nil))
        }
    }

    override func refresh() {
        guard case .group(let id)? = node, let env, let group = env.store.group(id) else { return }
        groupID = id
        name = group.name
        let block = blockStyle(forGroup: id)
        if case .tinted(let tag) = block {
            nameColor = tag.color.mixed(with: Palette.cream, fraction: 0.62)
        } else {
            nameColor = Palette.dim
        }
        var tally: [SessionState: Int] = [:]
        var stopped = 0
        for project in group.projectIDs.compactMap(env.store.project) {
            for session in project.sessionIDs.compactMap(env.store.session) {
                tally[session.state, default: 0] += 1
                if !session.external, !session.state.isLive { stopped += 1 }
            }
        }
        counts = StateStyle.aggregateOrder.compactMap { state in tally[state].map { (state, $0) } }
        stoppedCount = stopped
        cleanButton.label = "清理已停止 (\(stopped))"
        isOpen = !group.isCollapsed
        decoration = RowDecoration(block: block, hover: .header, topGap: Metrics.groupGap)
        let sessions = counts.reduce(0) { $0 + $1.1 }
        let spokenTally = counts.isEmpty ? "" : "：" + SessionSpeech.tally(counts)
        groupSpeech = "\(group.name) 群組，\(isOpen ? "展開" : "收合")，\(sessions) 個 session\(spokenTally)"
        addButton.setAccessibilityLabel("在 \(group.name) 新增 session")
        moreButton.setAccessibilityLabel("\(group.name) 群組選項")
        updateActions()
    }

    private func updateActions() {
        let show = showsActions
        cleanButton.isHidden = !show || stoppedCount == 0
        addButton.isHidden = !show
        moreButton.isHidden = !show
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // `.ss-gh{gap:2px;padding-right:3px}`, buttons 22 px high in the 22 px header band.
        var right = contentRight - UIZoom.pt(3)
        for button in [moreButton, addButton, cleanButton] where !button.isHidden {
            let width = button.intrinsicContentSize.width
            right -= width
            button.frame = CGRect(x: right, y: Metrics.groupGap, width: width, height: Metrics.groupHeaderHeight)
            right -= UIZoom.pt(2)
        }
    }

    private var isDropTarget: Bool { (superview as? SidebarRowView)?.isDropTarget ?? false }

    override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        let centerY = Metrics.groupGap + Metrics.groupHeaderHeight / 2
        let color = (isHovered || isMenuOpen) ? Palette.cream : nameColor
        Draw.caret(open: isOpen, at: CGPoint(x: contentLeft + z(5), y: centerY), color: Palette.dimmer)
        var right = contentRight - z(6)
        if showsActions {
            let first = [cleanButton, addButton, moreButton].filter { !$0.isHidden }.map(\.frame.minX).min()
            right = (first ?? right) - z(4)
        } else {
            for (state, n) in counts.reversed() {
                let style = StateStyle.of(state)
                let number = TextStyle.mono(10, Palette.dim).string("\(n)")
                right -= Draw.width(number)
                Draw.text(number, x: right, centerY: centerY)
                let glyph = TextStyle.mono(9, style.color).string(style.glyph)
                right -= Draw.width(glyph) + z(2)
                Draw.text(glyph, x: right, centerY: centerY)
                right -= z(6)
            }
            if isDropTarget {
                // `.ss-into`: amber caps, 8 px before the aggregates.
                let into = TextStyle.caps(9.5, Palette.amber, tracking: 0.14).string("移入")
                right -= Draw.width(into) + (counts.isEmpty ? 0 : z(2))
                Draw.text(into, x: right, centerY: centerY)
                right -= z(6)
            }
        }
        if !renaming {
            Draw.text(TextStyle.caps(9.5, color, tracking: 0.16).string(name), x: contentLeft + z(22), centerY: centerY,
                      maxWidth: right - contentLeft - z(26))
        }
    }

    // MARK: Actions

    @objc private func cleanClicked() {
        guard let groupID else { return }
        env?.controller?.cleanupStopped(inGroup: groupID)
    }

    @objc private func addClicked() {
        guard let groupID else { return }
        env?.controller?.newSession(inGroup: groupID)
    }

    @objc private func moreClicked() {
        guard let groupID else { return }
        env?.controller?.showGroupMenu(groupID, from: self)
    }
}

/// Project row (= one cwd): caret · name · count (`2`, `封存 3`, `✕ 1`). While hovered (or while
/// its `+` has keyboard focus) a `+` at the right starts a claude session in the folder right away
/// (no sheet: the default launch profile, the global login, no `--model`) and the count moves
/// left of it, like the group header's buttons. The `+` stays in the view tree while it is not
/// drawn (transparent, clicks pass through to the row) so VoiceOver and Full Keyboard Access reach
/// it with its label; the row also offers it as an accessibility action. A transient project (D6)
/// has no `+`.
final class ProjectCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("project")

    private var name = ""
    private var count = ""
    private var isOpen = true
    /// Not transient: CODD sessions can start in it.
    private var canStart = false
    private(set) var projectID: ProjectID?

    let addButton = CoddButton("+", style: .glyph(size: 22))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.alphaValue = 0
        // Keyboard focus shows the `+` (the button's own focus glow keeps working).
        let glow = addButton.focusTracker.onChange
        addButton.focusTracker.onChange = { [weak self] in
            glow?()
            self?.updateActions()
        }
        addSubview(addButton)
    }

    override var isHovered: Bool { didSet { if isHovered != oldValue { updateActions() } } }

    override func refresh() {
        guard case .project(let id)? = node, let env, let project = env.store.project(id) else { return }
        projectID = id
        name = project.name
        count = Self.countText(project, store: env.store)
        isOpen = !project.isCollapsed
        canStart = !project.isTransient
        decoration = RowDecoration(block: blockStyle(forGroup: project.groupID), hover: .header)
        toolTip = project.cwd
        projectSpeech = Self.spokenCount(project, store: env.store).map { "\(project.name) 專案，\(isOpen ? "展開" : "收合")，\($0)" }
        addButton.setAccessibilityLabel(Self.addLabel(project.name))
        addButton.toolTip = Self.addToolTip
        // A transient project has no `+` at all (not even for VoiceOver).
        addButton.isHidden = !canStart
        updateActions()
    }

    /// `在 backend 開新的 Claude session` (the `+` and the row's accessibility action).
    static func addLabel(_ project: String) -> String { "在 \(project) 開新的 Claude session" }
    static let addToolTip = "立即開新的 Claude session（預設啟動設定檔、跟隨全域登入、模型跟隨 Claude Code）"

    /// The `+` is drawn and takes clicks: hovered or keyboard-focused, in a project CODD owns.
    var showsAdd: Bool { canStart && (isHovered || addButton.focusTracker.showsFocusRing) }

    /// The `+` when a click at `windowPoint` hits it (the row's own click must then do nothing).
    func actionButton(atWindowPoint windowPoint: NSPoint) -> CoddButton? {
        guard showsAdd, addButton.bounds.contains(addButton.convert(windowPoint, from: nil)) else { return nil }
        return addButton
    }

    private func updateActions() {
        let alpha: CGFloat = showsAdd ? 1 : 0
        if addButton.alphaValue != alpha { addButton.alphaValue = alpha }
        needsLayout = true
        needsDisplay = true
    }

    /// A transparent `+` takes no clicks: the row's own click toggles the project.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === addButton, !showsAdd { return self }
        return hit
    }

    override func layout() {
        super.layout()
        let size = addButton.intrinsicContentSize
        addButton.frame = CGRect(x: contentRight - UIZoom.pt(3) - size.width, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
    }

    @objc private func addClicked() {
        guard let projectID else { return }
        env?.controller?.startClaudeSession(inProject: projectID)
    }

    /// VoiceOver's actions rotor: the same `+`.
    override var rowAccessibilityActions: [NSAccessibilityCustomAction] {
        guard canStart, projectID != nil else { return [] }
        return [NSAccessibilityCustomAction(name: Self.addLabel(name), target: self, selector: #selector(performAddAction))]
    }

    @objc private func performAddAction() -> Bool {
        guard let projectID else { return false }
        return env?.controller?.startClaudeSession(inProject: projectID) ?? false
    }

    /// `backend 專案，展開，2 個 session` (M5 D21).
    private var projectSpeech: String?
    override var spokenLabel: String? { projectSpeech }

    /// The count as words: `2 個 session`, `沒有執行中的 session，封存 3 個`, `1 個 session，都已結束`.
    @MainActor
    static func spokenCount(_ project: ProjectVM, store: any SessionStore) -> String? {
        let sessions = project.sessionIDs.compactMap(store.session)
        if sessions.isEmpty {
            return project.archivedCount > 0 ? "沒有執行中的 session，封存 \(project.archivedCount) 個" : "沒有 session"
        }
        if sessions.allSatisfy({ !$0.state.isLive }) { return "\(sessions.count) 個 session，都已結束" }
        return "\(sessions.count) 個 session"
    }

    /// `2`, `封存 3` (no sessions), `✕ 1` (none running).
    @MainActor
    static func countText(_ project: ProjectVM, store: any SessionStore) -> String {
        let sessions = project.sessionIDs.compactMap(store.session)
        if sessions.isEmpty { return project.archivedCount > 0 ? "封存 \(project.archivedCount)" : "0" }
        if sessions.allSatisfy({ !$0.state.isLive }) { return "✕ \(sessions.count)" }
        return "\(sessions.count)"
    }

    override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        let centerY = bounds.midY
        Draw.caret(open: isOpen, at: CGPoint(x: contentLeft + z(13), y: centerY), color: Palette.dimmer)
        let countText = TextStyle.mono(10, Palette.dimmer).string(count)
        let countWidth = Draw.width(countText)
        // With the `+` up the count sits left of it.
        let countRight = showsAdd ? addButton.frame.minX - z(4) : contentRight - z(6)
        Draw.text(countText, x: countRight - countWidth, centerY: centerY)
        Draw.text(TextStyle.mono(11.5, isHovered ? Palette.cream : Palette.bone).string(name), x: contentLeft + z(30), centerY: centerY,
                  maxWidth: countRight - z(6) - countWidth - contentLeft - z(30))
    }
}

/// Section header (`.sbsec`): `▸ ◆ NEEDS YOU [3] ┄┄┄` / `▸ PINNED ┄┄┄`, and in the STATE view
/// (SidebarStates E `.ss-tsec`) `▸ ● WORKING 4 ┄┄┄` with the state glyph in its color, the count in
/// `--amber-dim` and, for Idle, `1 stale` after the rule. Counts follow the filter.
final class SectionHeaderCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section")

    private var title = ""
    private var badge: Int?
    private var count: Int?
    private var glyphStyle: StateStyle?
    private var hint: String?
    private var isNeeds = false
    private var isOpen = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    override func refresh() {
        guard case .section(let section)? = node, let env else { return }
        let content = Self.content(section, store: env.store, filter: env.shell.filterText)
        title = section.title
        isNeeds = section == .needsYou
        isOpen = !env.shell.collapsedSections.contains(section)
        badge = isNeeds ? content.count : nil
        count = isNeeds || section == .pinned ? nil : content.count
        glyphStyle = section.glyphState.map(StateStyle.of)
        hint = content.hint
        decoration = RowDecoration(block: isNeeds ? .needs : .none, hover: .none)
        // The title's own `◆` is a glyph, not a word.
        let spokenTitle = section.title.hasPrefix("◆ ") ? String(section.title.dropFirst(2)) : section.title
        sectionSpeech = [spokenTitle.uppercased(), isOpen ? "展開" : "收合", content.count.map { "\($0) 個 session" }, content.hint]
            .compactMap { $0 }.joined(separator: "，")
    }

    /// `NEEDS YOU，展開，3 個 session` (M5 D21).
    private var sectionSpeech: String?
    override var spokenLabel: String? { sectionSpeech }

    /// The head's count and hint (`1 stale`), shared with the `sidebar` state dump.
    @MainActor
    static func content(_ section: SidebarSection, store: any SessionStore, filter: String) -> (count: Int?, hint: String?) {
        switch section {
        case .pinned:
            return (nil, nil)
        case .needsYou:
            return (SidebarSnapshotBuilder.needsYou(store: store, filter: filter).count, nil)
        default:
            let sessions = SidebarSnapshotBuilder.sessions(in: section, store: store, filter: filter)
            let stale = section == .idle ? sessions.filter(\.isStale).count : 0
            return (sessions.count, stale > 0 ? "\(stale) stale" : nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        let centerY = z(glyphStyle == nil ? 16 : 15)
        let color = isNeeds ? Palette.amber : Palette.dim
        let gap = z(6)
        var x = contentLeft + z(8)
        Draw.caret(open: isOpen, at: CGPoint(x: x, y: centerY), color: Palette.dimmer)
        x += z(16)
        if let glyphStyle {
            x += Draw.text(TextStyle.mono(10, glyphStyle.color).string(glyphStyle.glyph), x: x, centerY: centerY) + gap
        }
        x += Draw.text(TextStyle.caps(10, color, tracking: 0.18).string(title), x: x, centerY: centerY) + gap
        if let badge, badge > 0 {
            x += ChipStyle.badge.draw("\(badge)", x: x, centerY: centerY) + gap
        }
        if let count {
            x += Draw.text(TextStyle.mono(10, Palette.amberDim).string("\(count)"), x: x, centerY: centerY) + gap
        }
        var ruleEnd = contentRight - z(8)
        if let hint {
            let text = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string(hint)
            let width = Draw.width(text)
            Draw.text(text, x: contentRight - z(8) - width, centerY: centerY)
            ruleEnd -= width + z(8)
        }
        if ruleEnd > x + z(4) {
            Draw.dashedLine(from: CGPoint(x: x + z(4), y: centerY), to: CGPoint(x: ruleEnd, y: centerY), color: Palette.line)
        }
    }
}

/// `◇ 1 個待看 · 第二版原型 · 審查流程  DONE` at the bottom of NEEDS YOU.
final class DoneSummaryCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("done")
    private var text = ""
    private var isCurrent = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    /// The first unseen DONE session (clicking the row opens it).
    private(set) var targetSessionID: SessionID?

    override func refresh() {
        guard let env else { return }
        let done = SidebarSnapshotBuilder.unseenDone(store: env.store, filter: env.shell.filterText)
        targetSessionID = done.first?.id
        text = Self.text(done)
        isCurrent = targetSessionID != nil && env.shell.currentSessionID == targetSessionID
        decoration = RowDecoration(block: .needs, emphasis: isCurrent ? .current : .none, hover: .session)
    }

    /// `1 個待看 · 第二版原型 · 審查流程，完成` (M5 D21).
    override var spokenLabel: String? { text.isEmpty ? nil : "\(text)，\(StateStyle.spokenName(.done))" }

    /// `1 個待看 · 第二版原型 · 審查流程`.
    @MainActor
    static func text(_ done: [SessionVM]) -> String {
        done.first.map { "\(done.count) 個待看 · \($0.title)" } ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        let style = StateStyle.of(.done)
        let left = contentLeft + z(12)
        Draw.text(TextStyle.mono(11, style.color).string(style.glyph), x: left, centerY: bounds.midY)
        let pill = ChipStyle.statePill(style)
        let pillWidth = pill.size(for: "Done").width
        pill.draw("Done", x: contentRight - z(8) - pillWidth, centerY: bounds.midY)
        Draw.text(TextStyle.mono(11.5, Palette.dim).string(text), x: left + z(19), centerY: bounds.midY,
                  maxWidth: contentRight - z(16) - pillWidth - left - z(19))
    }
}

/// `// 沒有執行中的 session · 封存 3` under an empty project.
final class EmptyProjectCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("empty")
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    override func refresh() {
        guard case .emptyProject(let id)? = node, let env, let project = env.store.project(id) else { return }
        text = Self.text(project)
        decoration = RowDecoration(block: blockStyle(forGroup: project.groupID), hover: .none)
    }

    /// The comment without its `// ` (M5 D21).
    override var spokenLabel: String? { text.hasPrefix("// ") ? String(text.dropFirst(3)) : text }

    @MainActor
    static func text(_ project: ProjectVM) -> String {
        project.archivedCount > 0 ? "// 沒有執行中的 session · 封存 \(project.archivedCount)" : "// 沒有執行中的 session"
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(text), x: contentLeft + UIZoom.pt(34), centerY: bounds.midY,
                  maxWidth: contentRight - contentLeft - UIZoom.pt(40))
    }
}

/// `[+ 新增群組]` dashed row at the end of the tree.
final class AddGroupCellView: SidebarCellView {
    static let identifier = NSUserInterfaceItemIdentifier("addGroup")
    private let button = CoddButton("+ 新增群組", style: .addRow)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        addSubview(button)
        button.target = self
        button.action = #selector(addGroup)
    }

    override func layout() {
        super.layout()
        button.frame = CGRect(x: Metrics.sidebarInset, y: UIZoom.pt(8), width: bounds.width - Metrics.sidebarInset * 2, height: UIZoom.pt(28))
    }

    @objc private func addGroup() { env?.controller?.beginNewGroup() }

    /// The row says what its one button does (M5 D21).
    override var spokenLabel: String? { "新增群組" }
}
