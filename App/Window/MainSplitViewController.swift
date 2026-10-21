import AppKit
import CoddStatusUI
import CoddUI

/// 1 px dividers in `--line`.
final class CoddSplitView: NSSplitView {
    override var dividerColor: NSColor { Palette.line }
    override var dividerThickness: CGFloat { 1 }
}

/// The split's sidebar column: the session sidebar, or (rail on STATUS, D16) the 220 px STATUS
/// sidebar in its place. Toasts go over whichever is shown.
final class SidebarContainerViewController: NSViewController {
    let sidebar: SidebarViewController
    let statusSidebar: NSView
    private(set) var showsStatus = false

    init(sidebar: SidebarViewController, statusSidebar: NSView) {
        self.sidebar = sidebar
        self.statusSidebar = statusSidebar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        addChild(sidebar)
        for view in [sidebar.view, statusSidebar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            view.pinEdges(to: root)
        }
        statusSidebar.isHidden = true
        view = root
    }

    func showStatus(_ on: Bool) {
        guard on != showsStatus else { return }
        showsStatus = on
        _ = view
        statusSidebar.isHidden = !on
        sidebar.view.isHidden = on
    }

    /// The D5 / installer toast over the visible sidebar.
    @discardableResult
    func showToast(_ text: String, undo: (@MainActor () -> Void)?) -> ToastView {
        guard showsStatus else { return sidebar.showToast(text, undo: undo) }
        view.subviews.compactMap { $0 as? ToastView }.forEach { $0.removeFromSuperview() }
        let toast = ToastView(text: text, undo: undo, countdown: nil)
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            toast.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            // Above the STATUS sidebar's refresh footer.
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -64),
        ])
        toast.dismiss(after: 6)
        return toast
    }

    /// The toast on screen (tests, DEBUG).
    var currentToast: ToastView? {
        showsStatus ? view.subviews.compactMap { $0 as? ToastView }.last : sidebar.currentToast
    }
}

/// rail (72, fixed) | sidebar (280, 220–400, collapsible with ⌘\) | main (≥ 560).
/// Plain `NSSplitViewItem`s: the sidebar item type would float a glass sidebar on Tahoe.
///
/// D16: on STATUS the sidebar column shows the STATUS sidebar at its fixed 220 px (at the zoom); leaving gives the
/// session sidebar its width (and collapsed state) back. The divider autosave is off meanwhile, so
/// the 220 px never becomes the session sidebar's saved width.
///
/// M4 D12: on NOTES the sidebar column is collapsed (the NOTES area has its own lists column);
/// leaving restores the session sidebar's width and collapsed state the same way.
final class MainSplitViewController: NSSplitViewController {
    /// What the sidebar column shows for the rail's area.
    enum SidebarMode: Equatable { case sessions, status, notes }

    let railItem: NSSplitViewItem
    let sidebarItem: NSSplitViewItem
    let paneItem: NSSplitViewItem
    let sidebarContainer: SidebarContainerViewController
    private var didSetInitialWidth = false
    static let defaultAutosaveName = "CODDMainSplit"
    /// nil in tests: a test split must never write the app's (the user's) defaults.
    private let autosaveName: String?
    /// The session sidebar's width and collapsed state while STATUS or NOTES shows.
    private var savedSidebar: (width: CGFloat, collapsed: Bool)?
    private(set) var sidebarMode: SidebarMode = .sessions

    init(rail: NSViewController, sidebar: SidebarViewController, pane: NSViewController, statusSidebar: NSView,
         autosaveName: String? = MainSplitViewController.defaultAutosaveName) {
        railItem = NSSplitViewItem(viewController: rail)
        sidebarContainer = SidebarContainerViewController(sidebar: sidebar, statusSidebar: statusSidebar)
        sidebarItem = NSSplitViewItem(viewController: sidebarContainer)
        paneItem = NSSplitViewItem(viewController: pane)
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let split = CoddSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        railItem.minimumThickness = Metrics.railWidth
        railItem.maximumThickness = Metrics.railWidth
        railItem.canCollapse = false
        railItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
        sidebarItem.minimumThickness = Metrics.sidebarMinWidth
        sidebarItem.maximumThickness = Metrics.sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        paneItem.minimumThickness = Metrics.mainMinWidth
        paneItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        for item in [railItem, sidebarItem, paneItem] { addSplitViewItem(item) }
        splitView.autosaveName = autosaveName
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSetInitialWidth else { return }
        didSetInitialWidth = true
        let key = autosaveName.map { "NSSplitView Subview Frames \($0)" }
        if key.map({ UserDefaults.standard.object(forKey: $0) == nil }) ?? true {
            splitView.setPosition(Metrics.railWidth, ofDividerAt: 0)
            splitView.setPosition(Metrics.railWidth + 1 + Metrics.sidebarWidth, ofDividerAt: 1)
        }
    }

    /// The rail divider is not draggable; neither is the STATUS sidebar's (it is 220 px) nor the
    /// collapsed column's on NOTES.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        if dividerIndex == 0 || (dividerIndex == 1 && sidebarMode != .sessions) { return .zero }
        return super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    }

    /// ⌘\ — focus mode (hide / show the sidebar). NOTES has no sidebar column to show (D12).
    func toggleSessionSidebar() {
        guard sidebarMode != .notes else { return }
        sidebarItem.animator().isCollapsed.toggle()
    }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// M4 interface zoom: the rail's fixed width and the session sidebar's limits follow the
    /// zoom (the thicknesses hold the columns); the session sidebar keeps its width inside the new
    /// limits instead of giving the rail's growth away.
    func applyZoom() {
        guard isViewLoaded else { return }
        let sidebarWidth = sidebarContainer.view.frame.width
        railItem.minimumThickness = Metrics.railWidth
        railItem.maximumThickness = Metrics.railWidth
        if sidebarMode != .status {
            sidebarItem.minimumThickness = Metrics.sidebarMinWidth
            sidebarItem.maximumThickness = Metrics.sidebarMaxWidth
        } else {
            // The STATUS sidebar's 220 follows the zoom too (it stays within the session sidebar's minimum).
            let status = StatusSidebarView.preferredWidth
            sidebarItem.minimumThickness = status
            sidebarItem.maximumThickness = status
            splitView.setPosition(Metrics.railWidth + 1 + status, ofDividerAt: 1)
        }
        if sidebarMode == .sessions, !sidebarItem.isCollapsed, sidebarWidth > 0 {
            let width = min(max(sidebarWidth, Metrics.sidebarMinWidth), Metrics.sidebarMaxWidth)
            splitView.setPosition(Metrics.railWidth + 1 + width, ofDividerAt: 1)
        }
    }

    /// DEBUG layout sweep (`-codd-sidebar-width`): the session sidebar at `width`, clamped to its
    /// limits at the current zoom, or (nil) collapsed to the rail.
    func setSessionSidebar(width: CGFloat?) {
        guard isViewLoaded, sidebarMode == .sessions else { return }
        guard let width else {
            sidebarItem.isCollapsed = true
            return
        }
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        let clamped = min(max(width, Metrics.sidebarMinWidth), Metrics.sidebarMaxWidth)
        splitView.setPosition(Metrics.railWidth + 1 + clamped, ofDividerAt: 1)
    }

    var isShowingStatus: Bool { sidebarMode == .status }
    var isShowingNotes: Bool { sidebarMode == .notes }

    /// D16: the STATUS sidebar (220 px) on, or the session sidebar back.
    func setStatusMode(_ on: Bool) {
        setSidebarMode(on ? .status : (sidebarMode == .status ? .sessions : sidebarMode))
    }

    /// The sidebar column for an area: the session sidebar, the STATUS sidebar (D16) or nothing
    /// (NOTES, D12). The session sidebar's width and collapsed state are saved on the way out of
    /// `.sessions` and restored on the way back; the autosave is off meanwhile.
    func setSidebarMode(_ next: SidebarMode) {
        _ = view
        guard next != sidebarMode else { return }
        let previous = sidebarMode
        if previous == .sessions {
            let width = sidebarContainer.view.frame.width
            savedSidebar = (width > 0 ? width : Metrics.sidebarWidth, sidebarItem.isCollapsed)
            splitView.autosaveName = nil
        }
        sidebarMode = next
        switch next {
        case .status:
            sidebarContainer.showStatus(true)
            let status = StatusSidebarView.preferredWidth
            sidebarItem.minimumThickness = status
            sidebarItem.maximumThickness = status
            if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
            splitView.setPosition(Metrics.railWidth + 1 + status, ofDividerAt: 1)
        case .notes:
            sidebarContainer.showStatus(false)
            sidebarItem.minimumThickness = Metrics.sidebarMinWidth
            sidebarItem.maximumThickness = Metrics.sidebarMaxWidth
            if !sidebarItem.isCollapsed { sidebarItem.isCollapsed = true }
        case .sessions:
            let saved = savedSidebar
            savedSidebar = nil
            sidebarContainer.showStatus(false)
            sidebarItem.minimumThickness = Metrics.sidebarMinWidth
            sidebarItem.maximumThickness = Metrics.sidebarMaxWidth
            if let saved {
                if sidebarItem.isCollapsed, !saved.collapsed { sidebarItem.isCollapsed = false }
                splitView.setPosition(Metrics.railWidth + 1 + saved.width, ofDividerAt: 1)
                if saved.collapsed { sidebarItem.isCollapsed = true }
            }
            splitView.autosaveName = autosaveName
        }
    }

    /// The session sidebar's width / collapse saved while another area shows (tests).
    var savedSessionSidebar: (width: CGFloat, collapsed: Bool)? { savedSidebar }
}
