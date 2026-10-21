import AppKit
import CoddUI

/// A text the user copies into another tool's own config (M4 D22: `註冊到 Codex` with the
/// `config.toml` snippet): one explanatory line, the snippet in the dialogs' black code box
/// (one numberless line per snippet line) and `[關閉]` `[複製]`. Nothing is written anywhere by
/// this view; `onCopy` asks the app to copy (through its pasteboard rule), then the button says
/// `已複製`. ⏎ = 複製, ⎋ = 關閉.
@MainActor
public final class SnippetDialogView: DialogContentView {
    public static let width: CGFloat = 560
    public static let copiedTitle = "已複製"

    public let snippet: String
    private let onCopy: () -> Void
    private let onClose: () -> Void
    private let message = RichWrappingLabel()
    private let box = DiffBoxView()
    let closeButton = CoddButton("關閉", style: .bracket(.normal, small: false))
    let copyButton = CoddButton("複製", style: .bracket(.primary, small: false))

    /// - Parameters:
    ///   - title: the `.m-h` title (drawn uppercase).
    ///   - message: the line above the snippet (`把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）`).
    ///   - footerNote: the footer's left note (nil: none).
    public init(title: String, message: String, snippet: String, footerNote: String? = nil,
                onCopy: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.snippet = snippet
        self.onCopy = onCopy
        self.onClose = onClose
        super.init(width: Self.width, title: title)
        self.message.set(DialogText.listItem.string(message, lineBreak: .byWordWrapping))
        var lines = snippet.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        box.set(lines.map { DiffLineModel(.context, text: $0) }, emptyText: nil)
        frameView.addBody([self.message, box])
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.setAccessibilityLabel("複製設定")
        frameView.setFooter(note: footerNote, buttons: [closeButton, copyButton])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The copy went through: the button says `已複製` (it can be pressed again).
    public func markCopied() {
        copyButton.label = Self.copiedTitle
    }

    /// The copy button's current label (tests).
    public var copyTitle: String { copyButton.label }
    /// The message line (tests).
    public var messageText: String { message.attributedStringValue.string }

    override var isPrimaryEnabled: Bool { true }
    override func performPrimary() { onCopy() }
    override func performCancel() { onClose() }

    @objc private func closeClicked() { performCancel() }
    @objc private func copyClicked() { performPrimary() }
}
