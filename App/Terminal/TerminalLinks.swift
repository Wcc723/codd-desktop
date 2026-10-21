import AppKit
import CoddUI

/// What a ⌘-clicked terminal link does. Program output decides both a link's label and its
/// target (an OSC 8 hyperlink shows any text), so only web and mail links open straight away.
enum TerminalLinkAction: Equatable {
    /// http, https, mailto: opened with the default app.
    case open
    /// A file: URL or an absolute path: that local path, selected in Finder. Never opened, so a
    /// script or an app a link points at is never run.
    case reveal(URL)
    /// Any other scheme (smb:, ssh:, another app's): opened only after the user saw the full URL.
    case confirm
    /// Nothing to act on (a file URL without a path, a relative path).
    case ignore
}

enum TerminalLinkPolicy {
    /// Schemes that open without asking.
    static let directSchemes: Set<String> = ["http", "https", "mailto"]

    static func action(for url: URL) -> TerminalLinkAction {
        let scheme = url.scheme?.lowercased() ?? ""
        if directSchemes.contains(scheme) { return .open }
        if scheme == "file" || scheme.isEmpty {
            // The path only: a host part (`file://server/…`) never reaches Finder. `..` is
            // removed from the text alone; nothing here touches the file system.
            let path = scheme.isEmpty ? (url.path as NSString).expandingTildeInPath : url.path
            guard path.hasPrefix("/") else { return .ignore }
            return .reveal(URL(fileURLWithPath: path, isDirectory: false).standardized)
        }
        return .confirm
    }

    /// A link as the hover label and the confirmation show it: the target as is, except that
    /// characters which would hide or reorder what is shown (controls, line breaks, bidi
    /// overrides, zero-width marks) appear percent-encoded. Nil for no link.
    static func displayText(_ link: String?) -> String? {
        guard let link, !link.isEmpty else { return nil }
        var text = ""
        for scalar in link.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                for byte in String(scalar).utf8 { text += String(format: "%%%02X", byte) }
            default:
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    /// The confirmation's text for a link of another scheme.
    static func confirmation(_ url: URL) -> (message: String, info: String) {
        ("要開啟這個連結嗎？", displayText(url.absoluteString) ?? "")
    }
}

/// Carries out `TerminalLinkPolicy` for a ⌘-clicked link. Every step is a closure, so tests
/// replace them: nothing opens, Finder stays put and no sheet appears.
@MainActor
struct TerminalLinkOpener {
    var open: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Asks about `url` (a sheet on `window`); `answer(true)` opens it.
    var confirm: @MainActor (_ url: URL, _ window: NSWindow?, _ answer: @escaping @MainActor (Bool) -> Void) -> Void
        = TerminalLinkOpener.confirmWithSheet

    func handle(_ url: URL, window: NSWindow?) {
        switch TerminalLinkPolicy.action(for: url) {
        case .open:
            open(url)
        case .reveal(let file):
            reveal(file)
        case .confirm:
            let open = self.open
            confirm(url, window) { yes in if yes { open(url) } }
        case .ignore:
            break
        }
    }

    /// `[開啟]` `[取消]` on the terminal's window, with the full URL; no window (or a sheet already
    /// up): nothing opens.
    static func confirmWithSheet(_ url: URL, window: NSWindow?, answer: @escaping @MainActor (Bool) -> Void) {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return answer(false)
        }
        let text = TerminalLinkPolicy.confirmation(url)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.info
        alert.addButton(withTitle: "開啟")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1B}"
        Task { @MainActor in
            answer(await alert.beginSheetModal(for: window) == .alertFirstButtonReturn)
        }
    }
}

/// A terminal slot's view: the deck of engine views and, over its bottom-left corner, the link
/// under the pointer (a browser's status bubble, `.path` style). The bubble never takes the mouse,
/// so the pointer and ⌘-click reach the terminal below it; it moves to the bottom-right while
/// the pointer is over its corner.
final class TerminalSlotView: FlippedView {
    let deck: TerminalDeckView
    private let bubble = LinkBubbleView(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.lineBright)
    private let label = Label.make(style: TerminalSlotView.linkStyle)
    private var onRight = false

    static var linkStyle: TextStyle { TextStyle.mono(11, Palette.dim) }
    static let inset: CGFloat = 6
    static let padding = NSSize(width: 8, height: 3)

    init(deck: TerminalDeckView) {
        self.deck = deck
        super.init(frame: .zero)
        deck.frame = bounds
        deck.autoresizingMask = [.width, .height]
        addSubview(deck)
        label.lineBreakMode = .byTruncatingMiddle
        bubble.addSubview(label)
        bubble.isHidden = true
        addSubview(bubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shown link (display text), nil while hidden.
    private(set) var linkText: String?

    /// Shows `link` (as `TerminalLinkPolicy.displayText` makes it) or hides the bubble (nil).
    func showLink(_ link: String?) {
        let text = TerminalLinkPolicy.displayText(link)
        guard text != linkText else { return }
        linkText = text
        bubble.isHidden = text == nil
        guard let text else { return }
        label.attributedStringValue = Self.linkStyle.string(text, lineBreak: .byTruncatingMiddle)
        onRight = false
        layoutBubble()
        // A link in the bubble's corner would sit under it: the bubble moves out of the way.
        if let window, bubble.frame.insetBy(dx: -Self.inset, dy: -Self.inset).contains(
            convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            onRight = true
            layoutBubble()
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutBubble()
    }

    override func layout() {
        super.layout()
        layoutBubble()
    }

    private func layoutBubble() {
        guard linkText != nil else { return }
        let padding = Self.padding
        let natural = label.intrinsicContentSize
        let width = min(natural.width + 2 * padding.width, max(0, bounds.width - 2 * Self.inset))
        let height = ceil(natural.height) + 2 * padding.height
        let x = onRight ? bounds.width - Self.inset - width : Self.inset
        bubble.frame = NSRect(x: x, y: bounds.height - Self.inset - height, width: width, height: height)
        label.frame = NSRect(x: padding.width, y: padding.height, width: max(0, width - 2 * padding.width),
                             height: ceil(natural.height))
    }
}

/// The bubble: hit-testing passes through it to the terminal below.
private final class LinkBubbleView: PanelView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
