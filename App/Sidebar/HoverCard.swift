import AppKit
import CoddUI

/// What the sidebar hover card says (SidebarStates F, D20). Pure: built from the model, the clock,
/// the row's ⌘ number and the last prompt (the `UserPromptSubmit` hook's, else the transcript's).
struct HoverCardModel: Equatable, Sendable {
    var state: SessionState
    /// D8: drawn in the UNREACHABLE style (`◌ holder 無回應 · 30s`).
    var unreachable: Bool
    var glyph: String
    /// `權限確認 · 3m`, `工作中 · Edit · 6m`, `shell · zsh`, …
    var stateText: String
    var title: String
    /// `最近 prompt：` box (claude sessions with a known prompt only).
    var prompt: String?
    /// The project's folder, `~` for the home folder.
    var path: String
    /// `opus-5.5`, `tool Bash`, `ctx 58%`, `up 42m` (unknown parts left out); externals:
    /// `外部啟動 · pid 48211` / `在 CODD shell 中 · pid 48211`.
    var meta: [String]
    /// `⌘1`…`⌘9` (the row's place in ⌘1–9 order).
    var shortcut: String?
    /// `拖曳或 ⌥⇧↑↓ 調整順序` where the row can be reordered (never for externals).
    var hint: String?

    static let dragHint = "拖曳或 ⌥⇧↑↓ 調整順序"
    static let promptLabel = "最近 prompt："

    /// `◆ 權限確認 · 3m`.
    var stateLine: String { "\(glyph) \(stateText)" }

    @MainActor
    static func make(session s: SessionVM, store: any SessionStore, now: Date, number: Int?, prompt: String?,
                     reorderable: Bool) -> HoverCardModel {
        let unreachable = s.unreachableSince != nil
        let style = StateStyle.of(s)
        let duration = DurationFormat.compact(now.timeIntervalSince(s.unreachableSince ?? s.stateSince))
        let project = store.project(s.projectID)
        var meta: [String] = []
        if let info = s.externalInfo {
            meta = ["\(info.rowLabel) · pid \(info.pid)"]
        } else {
            if let model = s.model, !model.isEmpty { meta.append(model) }
            if let tool = s.tool, !tool.isEmpty, s.state == .busy || s.state == .waiting { meta.append("tool \(tool)") }
            if let context = s.contextPercent { meta.append("ctx \(context)%") }
            if let startedAt = s.startedAt, s.state.isLive { meta.append("up \(DurationFormat.compact(now.timeIntervalSince(startedAt)))") }
        }
        let cleanPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HoverCardModel(
            state: s.state, unreachable: unreachable, glyph: style.glyph,
            stateText: unreachable ? "holder 無回應 · \(duration)" : stateText(s, duration: duration),
            title: s.title,
            prompt: s.kind == .claude && cleanPrompt?.isEmpty == false ? cleanPrompt : nil,
            path: PathFormat.abbreviateHome(project?.cwd ?? ""),
            meta: meta,
            shortcut: number.flatMap { $0 >= 1 && $0 <= 9 ? "⌘\($0)" : nil },
            hint: reorderable && !s.external ? dragHint : nil)
    }

    /// The §3 state lines (M2-PLAN UI copy), without the glyph.
    @MainActor
    static func stateText(_ s: SessionVM, duration: String) -> String {
        switch s.state {
        case .waiting:
            let what: String
            switch s.waitingReason {
            case .permission?: what = "權限確認"
            case .question?: what = "等你回答"
            case .plan?: what = "計畫待核准"
            case .other?, nil: what = "等待輸入"
            }
            return "\(what) · \(duration)"
        case .error:
            return (["失敗", s.errorReason?.uppercased(), duration] as [String?]).compactMap { $0 }.joined(separator: " · ")
        case .done: return "完成待看 · \(duration)"
        case .busy:
            let tool = s.tool.flatMap { $0.isEmpty ? nil : $0 }
            return (["工作中", tool, duration] as [String?]).compactMap { $0 }.joined(separator: " · ")
        case .compacting: return "壓縮中 · \(duration)"
        case .idle: return "閒置 · \(duration)"
        case .starting: return "啟動中 · \(duration)"
        case .unknown: return s.external ? "執行中" : "執行中 · 沒有 hook"
        case .shell: return "shell · \(s.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "zsh")"
        case .exited: return "已結束 · code \(s.exitCode ?? 0)"
        case .stopped: return "已停止 · 可接續"
        }
    }

    var color: NSColor {
        unreachable ? StateStyle.unreachable.color : StateStyle.of(state).color
    }
}

/// The card itself (`.pop.ss-hc`, 340 px): a 2 px state-colored left border, state line, title,
/// dashed `最近 prompt：` box, path, meta with the ⌘ number at the right, drag hint. Custom drawn;
/// `fit(_:)` measures the wrapped text and sizes the view.
final class HoverCardView: NSView, SecondTicking {
    static let width: CGFloat = 340
    private(set) var model: HoverCardModel?
    /// Once a second while shown (the durations).
    var onTick: ((Date) -> Void)?

    private struct Layout {
        var state = CGRect.zero
        var title = CGRect.zero
        var prompt: CGRect?
        var promptText: CGRect?
        var path = CGRect.zero
        var meta = CGRect.zero
        var hint: CGRect?
        var height: CGFloat = 0
    }

    private var frames = Layout()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Text

    private static let inner = width - 2 - 12 - 12 - 1

    private static func paragraph(lineHeight: CGFloat, wrap: NSLineBreakMode) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = wrap
        return style
    }

    private static func attributed(_ text: String, size: CGFloat, color: NSColor, lineHeight: CGFloat,
                                   wrap: NSLineBreakMode = .byWordWrapping, tracking: CGFloat = 0) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Typeface.mono(size), .foregroundColor: color, .ligature: 0,
            .paragraphStyle: paragraph(lineHeight: lineHeight, wrap: wrap),
        ]
        if tracking != 0 { attributes[.kern] = tracking * size }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func stateString(_ m: HoverCardModel) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: Self.attributed(m.glyph, size: 10.5, color: m.color, lineHeight: 16))
        out.append(Self.attributed("  " + m.stateText, size: 10.5, color: m.color, lineHeight: 16, tracking: 0.14))
        return out
    }

    private func titleString(_ m: HoverCardModel) -> NSAttributedString {
        Self.attributed(m.title, size: 14, color: Palette.cream, lineHeight: 21)
    }

    private func promptString(_ prompt: String) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: Self.attributed(HoverCardModel.promptLabel, size: 13, color: Palette.amberDim,
                                                                              lineHeight: 20))
        out.append(Self.attributed(prompt, size: 13, color: Palette.bone, lineHeight: 20))
        return out
    }

    private func pathString(_ m: HoverCardModel) -> NSAttributedString {
        Self.attributed(m.path, size: 12, color: Palette.dim, lineHeight: 18, wrap: .byCharWrapping)
    }

    private static func height(_ text: NSAttributedString, width: CGFloat, maxLines: Int, lineHeight: CGFloat) -> CGFloat {
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(ceil(rect.height), lineHeight * CGFloat(maxLines))
    }

    // MARK: Model

    /// Applies a model and sizes the view to it (width 340, height from the wrapped text).
    @discardableResult
    func fit(_ model: HoverCardModel) -> CGSize {
        self.model = model
        var y: CGFloat = 10
        let x: CGFloat = 2 + 12
        let w = Self.inner
        var l = Layout()
        l.state = CGRect(x: x, y: y, width: w, height: 16)
        y += 16 + 7
        let titleHeight = Self.height(titleString(model), width: w, maxLines: 2, lineHeight: 21)
        l.title = CGRect(x: x, y: y, width: w, height: titleHeight)
        y += titleHeight + 7
        if let prompt = model.prompt {
            let textHeight = Self.height(promptString(prompt), width: w - 16 - 2, maxLines: 6, lineHeight: 20)
            l.prompt = CGRect(x: x, y: y, width: w, height: textHeight + 12 + 2)
            l.promptText = CGRect(x: x + 9, y: y + 7, width: w - 18, height: textHeight)
            y += textHeight + 14 + 7
        }
        let pathHeight = model.path.isEmpty ? 0 : Self.height(pathString(model), width: w, maxLines: 3, lineHeight: 18)
        l.path = CGRect(x: x, y: y, width: w, height: pathHeight)
        if pathHeight > 0 { y += pathHeight + 7 }
        l.meta = CGRect(x: x, y: y, width: w, height: 18)
        y += 18
        if model.hint != nil {
            y += 7
            l.hint = CGRect(x: x, y: y, width: w, height: 15)
            y += 15
        }
        y += 9
        l.height = y
        frames = l
        let size = CGSize(width: Self.width, height: y)
        setFrameSize(size)
        setAccessibilityLabel([model.stateLine, model.title, model.prompt.map { HoverCardModel.promptLabel + $0 }, model.path,
                               (model.meta + [model.shortcut].compactMap { $0 }).joined(separator: " "), model.hint]
            .compactMap { $0 }.joined(separator: "\n"))
        needsDisplay = true
        return size
    }

    func secondTick(now: Date) { onTick?(now) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let b = bounds
        // `.pop`: --bg-soft, 1 px --line-bright; `.ss-hc{border-left:2px solid var(--st)}`.
        Draw.fill(b, Palette.bgSoft)
        Draw.strokeRect(b, color: Palette.lineBright)
        Draw.fill(CGRect(x: 0, y: 0, width: 2, height: b.height), model.color)

        stateString(model).draw(with: frames.state, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        titleString(model).draw(with: frames.title, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let box = frames.prompt, let text = frames.promptText, let prompt = model.prompt {
            Draw.fill(box, Palette.bg)
            Draw.dashedRect(box, color: Palette.lineBright)
            promptString(prompt).draw(with: text, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if frames.path.height > 0 {
            pathString(model).draw(with: frames.path, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        // `.hm{gap:4px 10px;font-size:11px;color:var(--dimmer)}`, kbd pushed to the right.
        var x = frames.meta.minX
        var right = frames.meta.maxX
        if let shortcut = model.shortcut {
            let kbd = ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 5)
            right -= kbd.size(for: shortcut).width
            kbd.draw(shortcut, x: right, centerY: frames.meta.midY)
            right -= 10
        }
        for part in model.meta where x < right {
            x += Draw.text(TextStyle.mono(11, Palette.dimmer, tracking: 0.04).string(part), x: x, centerY: frames.meta.midY,
                           maxWidth: right - x) + 10
        }
        if let hint = frames.hint, let text = model.hint {
            Draw.text(TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string(text), x: hint.minX, centerY: hint.midY, maxWidth: hint.width)
        }
    }
}

/// Borderless, non-activating child panel for the hover card: it never takes focus or clicks
/// (mouse events pass through to whatever is under it).
final class HoverCardPanel: NSPanel {
    let card = HoverCardView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: HoverCardView.width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = card
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the hover card 380 ms after the pointer settles on a session row, 10 px right of the row
/// (over the main pane), clamped to the window's bottom edge. Hidden on exit, scroll, click, drag
/// start, window resign and while a menu tracks; the palette and sheets take the key window, which
/// hides it too. After a click or a scroll it waits until the pointer moves to another row.
@MainActor
final class HoverCardController {
    static let delay: Duration = .milliseconds(380)
    /// Gap between the row's right edge and the card (`列右側 10px`).
    static let gap: CGFloat = 10

    weak var sidebar: SidebarViewController?
    /// D20 fallback: the transcript's `last-prompt` (real mode: `AppServices.lastPrompt(for:)`).
    var promptProvider: ((SessionID) async -> String?)?
    private(set) var panel: HoverCardPanel?
    private var pending: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    /// The session the card shows, and the row it belongs to.
    private(set) var shownSessionID: SessionID?
    private var shownNode: NodeKind?
    /// The row the pointer is on (outline row index), as last reported.
    private var hoveredRow = -1
    /// A click put the card away: no card until the pointer reaches another row.
    private var suppressedRow: Int?
    /// A scroll put the card away: no card until the pointer moves.
    private var waitsForMove = false
    private var menuTracking = 0
    private var observers: [NSObjectProtocol] = []
    /// Prompts read from transcripts, per session, with what each was read for (the session's
    /// state change and conversation, like the read-only pane): a new turn reads it again, so an
    /// external claude's card follows its prompts (review concurrency-perf-2). A hook prompt wins
    /// once it arrives.
    private var transcriptPrompts: [SessionID: (key: String, prompt: String?)] = [:]
    /// How long the last `show` took, from building the card to the panel on screen (measurements).
    private(set) var lastShowDuration: Duration?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuTracking += 1
                self?.hide()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuTracking = max(0, self.menuTracking - 1) } }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let resigned = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.sidebar?.view.window, ObjectIdentifier(window) == resigned else { return }
                self.hide()
            }
        })
    }

    var isShown: Bool { panel?.isVisible == true && shownSessionID != nil }

    // MARK: Events from the outline

    func hoverChanged(row: Int) {
        hoveredRow = row
        if let suppressed = suppressedRow, suppressed != row { suppressedRow = nil }
        guard let sidebar, row >= 0, let node = sidebar.kind(atRow: row), node.sessionID != nil else {
            hide()
            return
        }
        if suppressedRow == row || waitsForMove { return }
        if isShown {
            // Moving along the list with the card up: follow at once.
            show(node, row: row)
        } else {
            schedule(row: row)
        }
    }

    /// A click on the list (away until the pointer reaches another row) or a scroll (away until the
    /// pointer moves).
    func dismissForInteraction(scroll: Bool = false) {
        if scroll { waitsForMove = true } else { suppressedRow = hoveredRow }
        hide()
    }

    func mouseMoved() {
        guard waitsForMove else { return }
        waitsForMove = false
        hoverChanged(row: hoveredRow)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        promptTask?.cancel()
        promptTask = nil
        modelLoop?.cancel()
        modelLoop = nil
        guard let panel else { return }
        if panel.isVisible {
            UITicker.shared.removeSecond(panel.card)
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        shownSessionID = nil
        shownNode = nil
    }

    private func schedule(row: Int) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, self.hoveredRow == row, self.suppressedRow != row, !self.waitsForMove,
                  let node = self.sidebar?.kind(atRow: row), node.sessionID != nil else { return }
            self.show(node, row: row)
        }
    }

    /// Whether nothing else owns the user's attention right now.
    var canShow: Bool {
        guard let sidebar, let window = sidebar.view.window, window.isVisible, window.isKeyWindow,
              window.attachedSheet == nil, menuTracking == 0, sidebar.draggedNodes.isEmpty else { return false }
        return true
    }

    // MARK: Showing

    /// Shows the card for a session row now (the timer, a debug flag and tests call this). The card
    /// then follows its session (state, prompt: observed), the clock (1 Hz) and its row (`reposition`).
    func show(_ node: NodeKind, row: Int, force: Bool = false) {
        pending?.cancel()
        pending = nil
        guard let sidebar, let id = node.sessionID, sidebar.store.session(id) != nil, force || canShow,
              let window = sidebar.view.window else { hide(); return }
        let start = ContinuousClock.now
        let panel = self.panel ?? HoverCardPanel()
        self.panel = panel
        if shownSessionID != id { promptTask?.cancel(); promptTask = nil }
        shownSessionID = id
        shownNode = node
        modelLoop?.cancel()
        // Tracked: the session's fields, the mode and the filter; the clock is read untracked.
        modelLoop = ObservationLoop(track: { [weak self] in self?.currentModel(now: nil) },
                                    apply: { [weak self] model in self?.apply(model) })
        guard shownSessionID == id else { return }
        panel.card.onTick = { [weak self] now in self?.apply(self?.currentModel(now: now)) }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        reposition(row: row)
        panel.orderFront(nil)
        UITicker.shared.addSecond(panel.card)
        lastShowDuration = ContinuousClock.now - start
        if let session = sidebar.store.session(id) { loadPromptIfNeeded(session) }
    }

    private var modelLoop: ObservationLoop?

    private func currentModel(now: Date?) -> HoverCardModel? {
        guard let id = shownSessionID, let node = shownNode, let sidebar, let session = sidebar.store.session(id) else { return nil }
        return model(for: session, node: node, now: now ?? sidebar.store.clock.now())
    }

    /// A new model: re-measure; when the height changes, keep the card on its row.
    private func apply(_ model: HoverCardModel?) {
        guard let panel else { return }
        guard let model else { hide(); return }
        guard model != panel.card.model else { return }
        let old = panel.card.frame.size
        panel.card.fit(model)
        if panel.card.frame.size != old, panel.isVisible { reposition() }
    }

    /// The rows moved (a diff above the card's row) or the card changed size: back next to its row;
    /// gone when the row is.
    func reposition(row knownRow: Int? = nil) {
        guard let sidebar, let node = shownNode, let panel, let window = sidebar.view.window else { return }
        let row = knownRow ?? sidebar.outline.row(forItem: sidebar.item(for: node))
        guard row >= 0 else { hide(); return }
        panel.setFrame(frame(for: row, size: panel.card.frame.size, in: window), display: panel.isVisible)
    }

    private func model(for session: SessionVM, node: NodeKind, now: Date) -> HoverCardModel? {
        guard let sidebar else { return nil }
        let order = sidebar.snapshot.sessionOrder
        let number = order.firstIndex(of: session.id).map { $0 + 1 }
        let reorderable: Bool = {
            guard case .session(_, .tree) = node else { return false }
            return sidebar.shell.sidebarMode == .tree && sidebar.shell.filterText.isEmpty
        }()
        return HoverCardModel.make(session: session, store: sidebar.store, now: now, number: number,
                                   prompt: session.lastPrompt ?? transcriptPrompts[session.id]?.prompt, reorderable: reorderable)
    }

    /// What a transcript prompt is read for: a new state (a turn started or ended) or another
    /// conversation (`/clear`) reads again.
    static func promptKey(_ session: SessionVM) -> String {
        "\(session.stateSince.timeIntervalSince1970)|\(session.externalInfo?.claudeSessionID ?? session.claudeSessionID ?? "-")"
    }

    /// D20: no hook prompt → the transcript's `last-prompt`, read off the main actor once per state
    /// change (the previous answer stays on the card meanwhile).
    private func loadPromptIfNeeded(_ session: SessionVM) {
        let key = Self.promptKey(session)
        guard session.kind == .claude, session.lastPrompt == nil, transcriptPrompts[session.id]?.key != key,
              let provider = promptProvider, promptTask == nil else { return }
        let id = session.id
        promptTask = Task { @MainActor [weak self] in
            let prompt = await provider(id)
            // A cancelled read records nothing: the next hover reads again.
            guard let self, !Task.isCancelled else { return }
            self.promptTask = nil
            let previous = self.transcriptPrompts[id]?.prompt
            let found = prompt.flatMap { $0.isEmpty ? nil : $0 } ?? previous
            self.transcriptPrompts[id] = (key, found)
            if self.shownSessionID == id, found != previous { self.apply(self.currentModel(now: nil)) }
        }
    }

    /// The transcript prompt the card has for a session (tests).
    func cachedTranscriptPrompt(_ id: SessionID) -> String? { transcriptPrompts[id]?.prompt }

    /// 10 px right of the row, top aligned with it, moved up to stay inside the window's bottom.
    func frame(for row: Int, size: CGSize, in window: NSWindow) -> CGRect {
        guard let sidebar else { return CGRect(origin: .zero, size: size) }
        let rowRect = sidebar.outline.rect(ofRow: row)
        var onScreen = window.convertToScreen(sidebar.outline.convert(rowRect, to: nil))
        // The row's right edge is the sidebar's (a legacy scroller makes the list itself narrower).
        let sidebarOnScreen = window.convertToScreen(sidebar.view.convert(sidebar.view.bounds, to: nil))
        onScreen.size.width = max(onScreen.width, sidebarOnScreen.maxX - onScreen.minX)
        return Self.place(size: size, rowOnScreen: onScreen, windowFrame: window.frame)
    }

    /// Pure placement (tests): right of the row, clamped to the window's bottom edge (8 px margin).
    static func place(size: CGSize, rowOnScreen row: CGRect, windowFrame: CGRect) -> CGRect {
        var origin = CGPoint(x: row.maxX + gap, y: row.maxY - size.height)
        let bottom = windowFrame.minY + 8
        if origin.y < bottom { origin.y = bottom }
        let top = windowFrame.maxY - 8
        if origin.y + size.height > top { origin.y = max(bottom, top - size.height) }
        return CGRect(origin: origin, size: size)
    }
}
