import AppKit
import CoddPreferences
import CoddUI

/// What every section needs: the model to edit, the app's actions, and navigation to another
/// section (`在「遠端」設定 →`).
@MainActor
final class SectionContext {
    let model: SettingsModel
    let actions: SettingsActions
    var navigate: (SettingsSection) -> Void = { _ in }

    init(model: SettingsModel, actions: SettingsActions) {
        self.model = model
        self.actions = actions
    }
}

/// One section page (`.sx-sec`: max 880 wide, groups 20 apart, `.sx-body` padding 26 / 40). A
/// subclass builds its rows in `build()` with the factories below; each factory registers a
/// binding, so `apply(_:_:)` sets every control from the preferences and the facts. Controls are
/// registered by key (the preference path) for the search and the tests.
class SettingsSectionView: FlippedView {
    let section: SettingsSection
    let context: SectionContext
    let column: NSStackView
    private(set) var searchables: [SxSearchable] = []
    private(set) var rowsByKey: [String: SxRow] = [:]
    private(set) var controlsByKey: [String: NSView] = [:]
    private var appliers: [(CoddPreferences, SettingsInfo) -> Void] = []
    private var targets: [ClosureTarget] = []
    /// Targets of buttons in rows rebuilt from the facts, per group (`components`, `backups`): a
    /// rebuild replaces its group's, where the section-level list would grow with every rebuild
    /// for as long as the window controller lives (M3 review).
    private var rebuiltTargets: [String: [ClosureTarget]] = [:]
    /// Every button target the section keeps alive (tests).
    var targetCount: Int { targets.count + rebuiltTargets.values.map(\.count).reduce(0, +) }
    /// Section-level text the search also matches (title, lead, static boxes).
    var sectionSearchText: String

    init(section: SettingsSection, context: SectionContext) {
        self.section = section
        self.context = context
        column = columnStack([], spacing: xz(20), edgeInsets: SettingsSectionView.insets(width: .greatestFiniteMagnitude))
        sectionSearchText = "\(section.pageTitle) \(section.pageZh) \(section.navTitle) \(section.navEnglish)"
        super.init(frame: .zero)
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: xz(880 + 80)),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        // Fill up to the 880 max, but below the window's own size (500): a stronger fill would
        // shrink the Settings window to 230 + 960.
        let fill = column.trailingAnchor.constraint(equalTo: trailingAnchor)
        fill.priority = NSLayoutConstraint.Priority(490)
        fill.isActive = true
        build()
        apply(context.model.preferences, context.model.info)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `.sx-body` padding 26 / 40; a narrow page (small window, zoom 20) keeps 20 at the sides so
    /// the rows get the width.
    static func insets(width: CGFloat) -> NSEdgeInsets {
        let side = width < xz(600) ? xz(20) : xz(40)
        return NSEdgeInsets(top: xz(26), left: side, bottom: xz(28), right: side)
    }

    override func layout() {
        let insets = SettingsSectionView.insets(width: bounds.width)
        if insets.left != column.edgeInsets.left {
            column.setFullWidthInsets(insets)
        }
        super.layout()
    }

    /// Builds the section's views (override).
    func build() {}

    final var model: SettingsModel { context.model }
    final var actions: SettingsActions { context.actions }

    final func add(_ view: NSView) { column.addFullWidth(view) }

    func apply(_ preferences: CoddPreferences, _ info: SettingsInfo) {
        for applier in appliers { applier(preferences, info) }
    }

    /// Runs on every apply (initially too).
    final func bind(_ applier: @escaping (CoddPreferences, SettingsInfo) -> Void) {
        appliers.append(applier)
    }

    final func edit(_ change: (inout CoddPreferences) -> Void) { model.update(change) }

    final func makeTarget(_ handler: @escaping @MainActor () -> Void, group: String? = nil) -> ClosureTarget {
        let target = ClosureTarget(handler)
        if let group { rebuiltTargets[group, default: []].append(target) } else { targets.append(target) }
        return target
    }

    /// Drops the targets of `group`'s previous rows (call before building their replacements).
    final func releaseTargets(_ group: String) { rebuiltTargets[group] = nil }

    final func register(_ searchable: SxSearchable) { searchables.append(searchable) }

    final func registerControl(_ key: String, _ view: NSView) { controlsByKey[key] = view }

    // MARK: Search

    /// Marks the rows matching `query`; true when the section has a hit (a row, or the section's
    /// own text). An empty query clears the marks.
    @discardableResult
    final func applySearch(_ query: String) -> Bool {
        let active = !SettingsSearch.fold(query).isEmpty
        var any = false
        for item in allSearchables {
            let hit = active && SettingsSearch.matches(item.searchText, query: query)
            item.isSearchHit = hit
            any = any || hit
        }
        guard active else { return true }
        return any || SettingsSearch.matches(sectionSearchText + " " + factSearchText, query: query)
    }

    final var firstSearchHit: NSView? { allSearchables.first(where: \.isSearchHit) }

    /// Text from the facts that has no row of its own (event names, group names).
    var factSearchText: String { "" }

    /// Rows built from the facts (account aliases), searched like the static ones.
    var dynamicSearchables: [SxSearchable] { [] }

    final var allSearchables: [SxSearchable] { searchables + dynamicSearchables }

    // MARK: Factories

    final func pageHead(lead: SxRich, marks: [NSView] = [], actions: [NSView] = []) -> SxPageHead {
        sectionSearchText += " " + lead.plain
        return SxPageHead(title: section.pageTitle, zh: section.pageZh, marks: marks, actions: actions, lead: lead)
    }

    /// A `.sx-row`, registered for search (and by key).
    @discardableResult
    final func row(_ key: String, _ name: String, en: String? = nil, hint: String? = nil, chips: [NSView] = [], extra: [NSView] = [],
             controls: [NSView] = [], tight: Bool = false, milestone: String? = nil, labelGap: CGFloat = 2,
             keywords: [String] = [], inColumn: Bool = false) -> SxRow {
        row(key, SxRich(name), en: en, hint: hint.map { SxRich($0) }, chips: chips, extra: extra, controls: controls, tight: tight,
            milestone: milestone, labelGap: labelGap, keywords: keywords, inColumn: inColumn)
    }

    @discardableResult
    final func row(_ key: String, _ name: SxRich, en: String? = nil, hint: SxRich?, chips: [NSView] = [], extra: [NSView] = [],
             controls: [NSView] = [], tight: Bool = false, milestone: String? = nil, labelGap: CGFloat = 2,
             keywords: [String] = [], inColumn: Bool = false) -> SxRow {
        let made = SxRow(key: key, name: name, en: en, hint: hint, chips: chips, extra: extra, controls: controls, tight: tight,
                         milestone: milestone, labelGap: labelGap, keywords: keywords, inColumn: inColumn)
        rowsByKey[key] = made
        register(made)
        return made
    }

    /// `.sw` bound to a Bool preference.
    final func toggle(_ key: String, label: String, get: @escaping (CoddPreferences) -> Bool,
                set: @escaping (inout CoddPreferences, Bool) -> Void) -> SwitchToggle {
        let control = SwitchToggle(label: label)
        let handler = makeTarget { [weak self, weak control] in
            guard let self, let control else { return }
            let on = control.isOn
            self.edit { set(&$0, on) }
        }
        control.target = handler
        control.action = #selector(ClosureTarget.fire(_:))
        bind { [weak control] prefs, _ in control?.isOn = get(prefs) }
        registerControl(key, control)
        return control
    }

    /// A locked `.sw` (D17): always ON, disabled, at 55 %.
    final func lockedToggle(_ key: String, label: String) -> SwitchToggle {
        let control = SwitchToggle(label: label)
        control.isOn = true
        control.isEnabled = false
        control.alphaValue = 0.55
        registerControl(key, control)
        return control
    }

    /// `.seg` bound to a preference among `values` (artboard order). `disabled` segments cannot be
    /// picked; `chips` puts a milestone chip after a segment's title (位置's `M5`).
    final func segmented<Value: Equatable>(_ key: String, titles: [String], values: [Value], label: String, raw: Bool = false,
                                     disabled: Set<Int> = [], chips: [Int: String] = [:], get: @escaping (CoddPreferences) -> Value,
                                     set: @escaping (inout CoddPreferences, Value) -> Void) -> SxSegmented {
        let control = SxSegmented(titles: titles, raw: raw, accessibilityLabel: label)
        control.disabledIndices = disabled
        control.segmentChips = chips
        control.onSelect = { [weak self] index in
            guard let self, values.indices.contains(index) else { return }
            let value = values[index]
            self.edit { set(&$0, value) }
        }
        bind { [weak control] prefs, _ in
            control?.selectedIndex = values.firstIndex(of: get(prefs)) ?? -1
        }
        registerControl(key, control)
        return control
    }

    /// `.select` bound to a preference among `values`.
    final func select<Value: Equatable>(_ key: String, titles: [String], values: [Value], width: CGFloat, label: String,
                                  get: @escaping (CoddPreferences) -> Value, set: @escaping (inout CoddPreferences, Value) -> Void,
                                  unknownTitle: @escaping (Value) -> String = { "\($0)" }) -> SelectButton {
        let control = SelectButton(titles: titles, accessibilityLabel: label)
        control.widthAnchor.constraint(equalToConstant: width).zoomed(width).isActive = true
        control.onSelect = { [weak self] index in
            guard let self, values.indices.contains(index) else { return }
            let value = values[index]
            self.edit { set(&$0, value) }
        }
        bind { [weak control] prefs, _ in
            guard let control else { return }
            let value = get(prefs)
            if let index = values.firstIndex(of: value) {
                if control.selectedIndex != index || control.displayTitle != nil {
                    control.setItems(titles, selected: index)
                    control.displayTitle = nil
                }
            } else {
                control.displayTitle = unknownTitle(value)
            }
        }
        registerControl(key, control)
        return control
    }

    /// `.btn.sm` (`[還原本頁預設]`).
    /// `group`: the button sits in a row rebuilt from the facts (see ``releaseTargets(_:)``).
    final func button(_ title: String, variant: CoddButton.Variant = .normal, accessibilityLabel: String? = nil, group: String? = nil,
                action: @escaping @MainActor () -> Void) -> CoddButton {
        let made = CoddButton(title, style: .bracket(variant, small: true))
        let handler = makeTarget(action, group: group)
        made.target = handler
        made.action = #selector(ClosureTarget.fire(_:))
        if let accessibilityLabel { made.setAccessibilityLabel(accessibilityLabel) }
        return made
    }

    /// `.sx-gh`.
    final func groupHead(_ title: String, cjk: String? = nil, count: String? = nil, right: String? = nil) -> SxGroupHead {
        let head = SxGroupHead(title, cjk: cjk, count: count, right: right)
        sectionSearchText += " " + title + " " + (cjk ?? "")
        return head
    }

    /// A `.chip` view. A value chip (a path, a model, a version line) ends in `…` where a narrow
    /// window cannot hold it; short tags (`M5`, `實驗`) keep their width.
    final func chip(_ text: String, _ kind: ChipKind = .plain, caps: Bool = false, mini: Bool = false, height: CGFloat? = nil) -> ChipView {
        let view = ChipView(text, style: .chip(kind, caps: caps, mini: mini, height: height))
        view.truncates = text.count > 6
        return view
    }

    /// `.hint` text on one line (control columns: `剩餘 ≤`, `s`, the lock reasons).
    final func faint(_ text: String, size: CGFloat = 11.5, color: NSColor = Palette.dimmer) -> SxLabel {
        let label = SxLabel(SxRich(text).attributed(TextStyle.mono(size, color, tracking: 0.02), lineBreak: .byClipping), wraps: false)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    // MARK: Hotkey

    /// The global hotkey recorder bound to `general.hotkey`. A recorded combo goes through
    /// `SettingsActions.tryHotkey` first; a refusal is handed to `onError` and the previous combo
    /// stays (D22).
    final func hotkeyRecorder(_ key: String, compact: Bool, kbdHeight: CGFloat, kbdColumnWidth: CGFloat? = nil, accessibilityLabel: String,
                              onError: @escaping (String?) -> Void) -> HotkeyRecorderView {
        let recorder = HotkeyRecorderView(combo: KeyCombo(model.preferences.general.hotkey), accessibilityLabel: accessibilityLabel,
                                          kbdHeight: kbdHeight, kbdColumnWidth: kbdColumnWidth)
        recorder.compact = compact
        recorder.onStarted = { [weak self] in self?.actions.recordHotkeyStarted() }
        recorder.onCancelled = { [weak self] in self?.actions.recordHotkeyFinished() }
        recorder.onRecorded = { [weak self] combo in
            guard let self else { return }
            onError(self.storeHotkey(combo))
            self.actions.recordHotkeyFinished()
        }
        bind { [weak recorder] prefs, _ in recorder?.combo = KeyCombo(prefs.general.hotkey) }
        registerControl(key, recorder)
        return recorder
    }

    /// Stores `combo` as the global hotkey unless the app refuses it; returns the refusal.
    final func storeHotkey(_ combo: KeyCombo) -> String? {
        if let refusal = actions.tryHotkey(combo) { return refusal }
        edit { $0.general.hotkey = CoddPreferences.Hotkey(combo, enabled: $0.general.hotkey.enabled) }
        return nil
    }

    // MARK: Lookups (tests, the root's search)

    final func control<T: NSView>(_ key: String, as type: T.Type = T.self) -> T? { controlsByKey[key] as? T }

    final var rowTitles: [String] { allSearchables.compactMap { ($0 as? SxRow)?.title ?? ($0 as? SxTitled)?.title } }
}

/// A searchable row that is not an `SxRow` but has a title (matrix, alias and shortcut rows).
@MainActor
protocol SxTitled: AnyObject {
    var title: String { get }
}
