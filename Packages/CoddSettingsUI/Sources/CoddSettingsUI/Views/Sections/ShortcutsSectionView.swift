import AppKit
import CoddPreferences
import CoddUI

/// 10 SHORTCUTS 快捷鍵: the artboard's table (SPEC §2 keys). Only the Global row's `[修改]`
/// records (D22); the others are `M5`. `還原預設` puts the global hotkey back to ⌥ Space through
/// `tryHotkey` (a refusal shows under the table).
final class ShortcutsSectionView: SettingsSectionView {
    static let groups: [(head: String, keys: [(action: String, note: String, keys: String)])] = [
        ("Navigation", [("跳到第 1–9 個 session", "依側欄由上而下的順序", "⌘1–9"), ("切換到下一個 session", "循環切換", "⌃Tab"),
                        ("快速切換", "session、筆記、專案與動作", "⌘K"), ("開啟設定", "就是這一頁", "⌘,")]),
        ("Session", [("新增 session", "在目前選取的專案", "⌘N"), ("新增終端機", "在下方面板開一個 zsh", "⌘T"),
                     ("下方終端機", "開 / 關", "⌘J"), ("Composer", "多行輸入，可貼圖片", "⌘L"), ("允許", "answer bar 的 [1] Yes", "⌘⏎"),
                     ("調整順序", "只在所屬專案內移動", "⌥⇧↑ / ↓")]),
        ("View & Notes", [("專注模式", "隱藏側欄", "⌘\\"), ("快速筆記", "自動連結目前 session", "⌘⇧N")]),
    ]

    static let globalAction = "叫出 CODD"

    private(set) var recorder: HotkeyRecorderView?
    private(set) var keyRows: [KeyRowView] = []
    private let errorLine = SxLabel("", style: TextStyle.mono(11.5, Palette.danger))
    private var recorderError: String?

    override func build() {
        let reset = button("還原預設") { [weak self] in self?.restoreDefaults() }
        registerControl("shortcuts.reset", reset)
        add(pageHead(lead: SxRich("按 [修改] 後直接按下新的組合鍵；⎋ 取消。"), actions: [reset]))

        var rows: [NSView] = [KeyHeaderView()]
        for group in Self.groups {
            rows.append(KeyGroupView(group.head, milestone: "M5"))
            for key in group.keys {
                let modify = SxStaticButton("修改", accessibilityLabel: "修改「\(key.action)」的快捷鍵（M5）")
                modify.alphaValue = 0.55
                let row = KeyRowView(action: key.action, note: key.note, keysText: key.keys, control: modify)
                keyRows.append(row)
                register(row)
                rows.append(row)
            }
        }
        rows.append(KeyGroupView("Global", milestone: nil))
        let recorder = hotkeyRecorder("shortcuts.global", compact: true, kbdHeight: 22, kbdColumnWidth: 120 + 16,
                                      accessibilityLabel: "修改「\(Self.globalAction)」的快捷鍵") { [weak self] error in
            self?.recorderError = error
            self?.refreshError()
        }
        self.recorder = recorder
        let global = KeyRowView(action: Self.globalAction, note: "任何 App 中都有效", keysText: nil, control: recorder)
        keyRows.append(global)
        register(global)
        rows.append(global)
        add(SxCard(rows))
        errorLine.isHidden = true
        add(errorLine)
        bind { [weak self] _, _ in self?.refreshError() }
    }

    private func refreshError() {
        let text = model.info.hotkeyError ?? recorderError
        errorLine.isHidden = text == nil
        errorLine.set(SxRich("▲ " + (text ?? "")).attributed(TextStyle.mono(11.5, Palette.danger), lineHeight: 17))
    }

    var errorText: String? { errorLine.isHidden ? nil : errorLine.text }

    func restoreDefaults() {
        recorderError = storeHotkey(KeyCombo(CoddPreferences.defaults.general.hotkey))
        actions.resetSection(.shortcuts)
        refreshError()
    }
}

/// `.sx-krow` columns: 210 | 1fr | 120 | 64, gap 16, padding 0 / 16 (at the zoom). A narrow table
/// (small window, zoom 20) drops the note column under 60 design points and narrows the keys
/// column to 90 (the Global recorder still fits keys + button); the action column then ends at
/// the keys column (its text ends in `…`).
@MainActor
enum KeyColumns {
    static func origins(width: CGFloat) -> (action: CGFloat, note: CGFloat, keys: CGFloat, button: CGFloat) {
        let button = width - xz(16) - xz(64)
        let keys = button - xz(16) - keysWidth(width: width)
        return (xz(16), xz(16) + xz(210) + xz(16), keys, button)
    }

    /// Whether the note column shows at `width` (at least 60 design points of it, with the keys
    /// column at its full 120).
    static func showsNote(width: CGFloat) -> Bool {
        let keys = width - xz(16) - xz(64) - xz(16) - xz(120)
        return keys - xz(16) - (xz(16) + xz(210) + xz(16)) >= xz(60)
    }

    /// The keys column: 120, or 90 once the note column folded.
    static func keysWidth(width: CGFloat) -> CGFloat { showsNote(width: width) ? xz(120) : xz(90) }
}

/// `.sx-krow.h`: `ACTION 說明 KEYS` on --bg-lift, 30 pt.
final class KeyHeaderView: FlippedView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).zoomed(30).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgLift)
        let style = TextStyle.caps(10, Palette.dim, tracking: 0.16)
        let x = KeyColumns.origins(width: bounds.width)
        var labels = [("Action", x.action), ("Keys", x.keys)]
        if KeyColumns.showsNote(width: bounds.width) { labels.insert(("說明", x.note), at: 1) }
        for (text, origin) in labels {
            Draw.text(style.string(text), x: origin, centerY: bounds.midY)
        }
    }
}

/// `.sx-krow.g`: a 26 pt group line in amber-dim caps on --bg (with the `M5` chip at the right
/// for the rows whose keys cannot be changed yet).
final class KeyGroupView: FlippedView, SxSeparated {
    let title: String
    let milestone: String?
    var showsSeparator = false { didSet { needsDisplay = true } }

    init(_ title: String, milestone: String?) {
        self.title = title
        self.milestone = milestone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).zoomed(26).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        if showsSeparator { Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright) }
        Draw.text(TextStyle.caps(10, Palette.amberDim, tracking: 0.18).string(title), x: xz(16), centerY: bounds.midY)
        if let milestone {
            let style = ChipStyle.milestone
            style.draw(milestone, x: KeyColumns.origins(width: bounds.width).button, centerY: bounds.midY)
        }
    }
}

/// One `.sx-krow` (34 pt): the action (cream), the note (hint, truncated), the keys as a
/// `.kbd.sx-kbd` and the button (or, for the Global row, the recorder spanning both columns).
final class KeyRowView: FlippedView, SxSearchable, SxSeparated, SxTitled {
    let title: String
    let searchText: String
    var isSearchHit = false { didSet { if isSearchHit != oldValue { needsDisplay = true } } }
    var showsSeparator = false { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    let note: String
    let control: NSView
    private let noteLabel: SxLabel
    /// The note's column constraints: off while it is folded (a hidden view keeps its
    /// constraints, which would hold the table at the note's minimum width).
    private var noteConstraints: [NSLayoutConstraint] = []
    /// The keys column's leading edge (the kbd, or the Global recorder) and the action's end: they
    /// move with the keys column's width (`KeyColumns.keysWidth`).
    private var keysEdge: NSLayoutConstraint?
    private var actionEnd: NSLayoutConstraint?

    /// `.kbd.sx-kbd`: 22 pt, 11.5 cream.
    static func kbd(_ keys: String) -> ChipView {
        ChipView(keys, style: ChipStyle(text: TextStyle.mono(11.5, Palette.cream), border: Palette.lineBright, fill: Palette.bg, height: 22, padding: 8))
    }

    init(action: String, note: String, keysText: String?, control: NSView) {
        title = action
        self.note = note
        self.control = control
        let keys = keysText.map(Self.kbd)
        searchText = "\(action) \(note) \(keysText ?? "") 快捷鍵 shortcut"
        noteLabel = SxLabel(SxRich(note).attributed(SxStyle.hint, lineBreak: .byTruncatingTail), wraps: false)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).zoomed(34).isActive = true
        let actionLabel = SxLabel(SxRich(action).attributed(TextStyle.mono(12.5, Palette.cream), lineBreak: .byTruncatingTail), wraps: false)
        // A narrow table drops the note and may cut the action: both stay readable on hover.
        actionLabel.toolTip = note.isEmpty ? action : "\(action)：\(note)"
        actionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [actionLabel, noteLabel, control] + [keys].compactMap({ $0 }) as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = xz(16), gap = xz(16), buttonWidth = xz(64)
        // The keys column's leading edge, from the row's trailing edge (it moves when the note
        // column folds: `layout()`).
        let keysOffset = -(pad + buttonWidth + gap + xz(120))
        let actionEnd = actionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: keysOffset - gap)
        self.actionEnd = actionEnd
        var constraints = [
            actionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            actionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: xz(210)),
            actionEnd,
            actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        noteConstraints = [
            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + xz(210) + gap),
            noteLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: keysOffset - gap),
        ]
        constraints += noteConstraints
        if let keys {
            let edge = keys.leadingAnchor.constraint(equalTo: trailingAnchor, constant: keysOffset)
            keysEdge = edge
            constraints += [
                edge,
                keys.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.leadingAnchor.constraint(equalTo: trailingAnchor, constant: -(pad + buttonWidth)),
            ]
        } else {
            // The recorder: kbd in the keys column, its button in the button column.
            let edge = control.leadingAnchor.constraint(equalTo: trailingAnchor, constant: keysOffset)
            keysEdge = edge
            constraints.append(edge)
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(false)
    }

    /// The note column folds in a narrow table (`KeyColumns.showsNote`).
    override func layout() {
        let shows = KeyColumns.showsNote(width: bounds.width)
        if noteLabel.isHidden == shows {
            noteLabel.isHidden = !shows
            if shows { NSLayoutConstraint.activate(noteConstraints) } else { NSLayoutConstraint.deactivate(noteConstraints) }
            let offset = -(xz(16) + xz(64) + xz(16) + KeyColumns.keysWidth(width: bounds.width))
            keysEdge?.constant = offset
            actionEnd?.constant = offset - xz(16)
        }
        super.layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if isSearchHit {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        }
        if showsSeparator { Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright) }
    }
}
