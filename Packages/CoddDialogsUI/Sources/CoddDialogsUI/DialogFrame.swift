import AppKit
import CoddUI

/// CoddUI's `ModalFrameView` (`.modal.sd-modal`: `.m-h` title + right-side views + ✕, `.m-b`,
/// `.m-f`) with the body as one full-width column (`.m-b{gap:14px}`) and the footer shapes the
/// four dialogs use.
@MainActor
final class DialogFrame {
    let view: ModalFrameView
    private let body = columnStack([], spacing: dz(14))
    /// The body scrolls when the dialog is shorter than its content: a sheet is capped at the
    /// screen's room under its window (`DialogPresenter.cappedHeight`), which only happens at a
    /// large UI 字級 on a short screen. Otherwise the scroll view is exactly the body's height.
    let scroll = NSScrollView()

    init(title: String) {
        view = ModalFrameView(title: title)
        // The frame fills its sheet / panel, which casts the window shadow; a 60 pt layer glow
        // would only be clipped and re-blurred on every 1 Hz tick of a subview.
        view.castsGlow = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        body.pinEdges(to: document)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        view.contentView.addSubview(scroll)
        scroll.pinEdges(to: view.contentView)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        // As tall as the body, below the window's own size (500): a capped sheet wins.
        let natural = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        natural.priority = NSLayoutConstraint.Priority(490)
        natural.isActive = true
    }

    var onClose: (() -> Void)? {
        get { view.onClose }
        set { view.onClose = newValue }
    }

    var title: String { view.title }
    var closeButton: CoddButton { view.closeButton }

    /// `.m-h` band height (the panel drags by it).
    var headerHeight: CGFloat { max(view.headerBandHeight, 52) }

    /// Views between the title's flexible gap and ✕ (chips, a kbd).
    func setHeader(chips: [NSView]) { view.setHeaderAccessories(chips) }

    /// `.m-b` children, each full width.
    func addBody(_ views: [NSView]) {
        for view in views { body.addFullWidth(view) }
    }

    /// `.m-f`: the note (`.sd-fnote`, `margin-right:auto`) at the left and the buttons at the right.
    func setFooter(note: String?, buttons: [NSView]) { view.setFooter(note: note, buttons: buttons) }

    /// `.m-f{justify-content:space-between}` (dialog D): a leading view and a trailing note.
    func setFooter(leading: NSView, trailingNote: String) {
        view.setFooter(leading: [leading], trailing: [ModalFrameView.noteLabel(trailingNote)])
    }

    /// The footer note's text (tests).
    var footerNote: String? {
        (view.footerLeading + view.footerTrailing).compactMap { ($0 as? NSTextField)?.stringValue }.first
    }
}
