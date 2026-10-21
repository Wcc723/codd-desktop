import AppKit
import CoddPreferences
import CoddUI

/// The Settings page: the 230 pt sidebar and the scrolling section content (Settings artboard,
/// SPEC §7.12). Sections are built on first use (the search builds them all); one observation
/// loop re-applies the model to every built section and the sidebar after any change.
///
/// Search: the field filters the nav to sections with a row (or section text) matching the
/// query, case / width / diacritic insensitive, and marks the matching rows; ⏎ selects the
/// first visible section and scrolls to its first hit.
@MainActor
public final class SettingsRootView: NSView {
    public let model: SettingsModel
    public private(set) var selected: SettingsSection = .general
    public private(set) var searchQuery = ""
    /// Empty space above the sidebar head and the content (a full-size-content window's title
    /// bar, where the traffic lights sit); it drags the window.
    public var topInset: CGFloat = 0 {
        didSet {
            sidebar.topInset = topInset
            scrollTop?.constant = topInset
        }
    }

    private let context: SectionContext
    private let profilesView: NSView
    private let sidebar = SettingsSidebarView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let contentDrag = WindowDragView(fill: Palette.bg)
    private var scrollTop: NSLayoutConstraint?
    private var sections: [SettingsSection: SettingsSectionView] = [:]
    private var shown: SettingsSectionView?
    private var loop: ObservationLoop?

    public init(model: SettingsModel, actions: SettingsActions, profilesView: NSView) {
        self.model = model
        context = SectionContext(model: model, actions: actions)
        self.profilesView = profilesView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.bg.cgColor
        context.navigate = { [weak self] section in self?.select(section) }
        sidebar.onSelect = { [weak self] section in self?.select(section) }
        sidebar.search.onChange = { [weak self] text in self?.setSearchQuery(text) }
        sidebar.search.onSubmit = { [weak self] in self?.submitSearch() }

        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        for view in [sidebar, contentDrag, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let top = scroll.topAnchor.constraint(equalTo: topAnchor, constant: topInset)
        scrollTop = top
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentDrag.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentDrag.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentDrag.topAnchor.constraint(equalTo: topAnchor),
            contentDrag.bottomAnchor.constraint(equalTo: scroll.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loop = ObservationLoop(track: { [weak self] () -> (CoddPreferences, SettingsInfo)? in
            guard let self else { return nil }
            return (self.model.preferences, self.model.info)
        }, apply: { [weak self] value in
            guard let self, let value else { return }
            self.apply(value.0, value.1)
        })
        select(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    // MARK: Sections

    /// Shows `section` (scrolled to the top).
    public func select(_ section: SettingsSection) {
        let view = sectionView(section)
        selected = section
        sidebar.setSelected(section)
        if shown !== view {
            // A field of the outgoing section that is being edited commits first (the nav items
            // never take the keyboard, so nothing else ends its editing).
            if let shown { endEditing(in: shown) }
            shown?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                view.topAnchor.constraint(equalTo: document.topAnchor),
                view.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ])
            shown = view
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The section's view, built on first use.
    func sectionView(_ section: SettingsSection) -> SettingsSectionView {
        if let built = sections[section] { return built }
        let view: SettingsSectionView = switch section {
        case .general: GeneralSectionView(section: section, context: context)
        case .appearance: AppearanceSectionView(section: section, context: context)
        case .sessions: SessionsSectionView(section: section, context: context)
        case .profiles: ProfilesHostSectionView(context: context, profilesView: profilesView)
        case .notifications: NotificationsSectionView(section: section, context: context)
        case .accounts: AccountsSectionView(section: section, context: context)
        case .hooks: HooksSectionView(section: section, context: context)
        case .notebook: NotebookSectionView(section: section, context: context)
        case .cleanup: CleanupSectionView(section: section, context: context)
        case .shortcuts: ShortcutsSectionView(section: section, context: context)
        case .remote: RemoteSectionView(section: section, context: context)
        case .advanced: AdvancedSectionView(section: section, context: context)
        case .about: AboutSectionView(section: section, context: context)
        }
        sections[section] = view
        if !SettingsSearch.fold(searchQuery).isEmpty { view.applySearch(searchQuery) }
        return view
    }

    private func apply(_ preferences: CoddPreferences, _ info: SettingsInfo) {
        sidebar.apply(info)
        for view in sections.values { view.apply(preferences, info) }
        // Rows built from the facts (aliases, backups) are searchable too.
        if !SettingsSearch.fold(searchQuery).isEmpty { setSearchQuery(searchQuery) }
    }

    /// Ends editing in a text field inside `view` (or anywhere in the page when nil), which commits
    /// what was typed: the window closes, the app quits, another section shows.
    public func endEditing(in view: NSView? = nil) {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: view ?? self) else { return }
        window.makeFirstResponder(nil)
    }

    /// Applies the model now instead of on the next main-actor turn (tests, snapshots).
    func applyNow() { apply(model.preferences, model.info) }

    // MARK: Search

    /// Filters the nav and marks matching rows (what typing in the field does).
    public func setSearchQuery(_ query: String) {
        searchQuery = query
        if sidebar.search.text != query { sidebar.search.text = query }
        guard !SettingsSearch.fold(query).isEmpty else {
            for view in sections.values { view.applySearch("") }
            sidebar.setVisible(nil)
            return
        }
        var matching: Set<SettingsSection> = []
        for section in SettingsSection.allCases where sectionView(section).applySearch(query) {
            matching.insert(section)
        }
        sidebar.setVisible(matching)
    }

    /// ⏎ in the field: the first visible section, scrolled to its first matching row.
    public func submitSearch() {
        guard !SettingsSearch.fold(searchQuery).isEmpty, let first = sidebar.visibleSections.first else { return }
        select(first)
        layoutSubtreeIfNeeded()
        if let hit = sectionView(first).firstSearchHit {
            let rect = hit.convert(hit.bounds, to: document)
            document.scrollToVisible(rect.insetBy(dx: 0, dy: -xz(24)))
        }
    }

    /// Sections the nav shows now (all, or the search's matches), in nav order.
    public var visibleSections: [SettingsSection] { sidebar.visibleSections }

    // MARK: Inspection (tests, the app's dump)

    var sidebarView: SettingsSidebarView { sidebar }
    var scrollView: NSScrollView { scroll }
    var builtSections: [SettingsSection] { SettingsSection.allCases.filter { sections[$0] != nil } }
}
