import AppKit
import CoddComposer

// codd-composer-demo: one window, one composer laid out like the Split artboard's composer bar.
// For the manual 注音 check: compose, pick a candidate, Enter commits without sending; Enter again
// sends. Every send prints the payload the holder would get:
//
//   SUBMIT paste=1 submit=1 bytes=19
//   HEX e7 ac ac e4 b8 80 e8 a1 8c 0d e7 ac ac e4 ba 8c e8 a1 8c
//   TEXT 第一行⏎第二行
//
//   swift run --package-path Packages/CoddComposer --scratch-path .build-composer codd-composer-demo
//   … codd-composer-demo --state-dir <dir>      # draft + history kept in <dir>/composer.json
//   … codd-composer-demo --smoke                # unattended check, prints SMOKE OK / SMOKE FAIL and exits
//   … codd-composer-demo --snapshot <file.png>  # renders the window to a PNG and exits
//
// Pasted images are saved under $TMPDIR/codd-composer-demo/ and their escaped path is inserted.
// The Reserved menu holds the shortcuts CODD keeps for itself; each prints `MENU <key>` when it
// reaches the menu (the composer must never swallow them). ⌘L focuses the composer.

enum Out {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

enum Palette {
    static let bg = ComposerStyle.rgb(0x050505)
    static let bgSoft = ComposerStyle.rgb(0x0A0A0A)
    static let line = ComposerStyle.rgb(0x1A1A1A)
    static let lineBright = ComposerStyle.rgb(0x2A2A2A)
    static let amber = ComposerStyle.rgb(0xFFB84A)
    static let amberDim = ComposerStyle.rgb(0xE09A2C)
    static let cream = ComposerStyle.rgb(0xF5ECD6)
    static let dim = ComposerStyle.rgb(0xA8A298)
    static let dimmer = ComposerStyle.rgb(0x7A7468)
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// A view that fills itself and optionally draws a top rule or a border.
final class Box: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var innerGlow: NSColor? { didSet { needsDisplay = true } }
    var topRule: NSColor? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        if let fill {
            fill.setFill()
            bounds.fill()
        }
        if let topRule {
            topRule.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if let border {
            border.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
        if let innerGlow {
            innerGlow.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// `.btn.primary`: amber fill, black `[ SEND ]` in mono caps.
final class SendButton: NSControl {
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 40) }

    override func draw(_: NSRect) {
        Palette.amber.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Palette.mono(11.5, .medium), .foregroundColor: NSColor.black, .kern: 0.9,
        ]
        let label = NSAttributedString(string: "[  SEND  ]", attributes: attributes)
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with _: NSEvent) {
        onPress?()
    }
}

/// `.kbd`: a bordered key cap, 10.5 pt dim text.
final class Kbd: NSView {
    private let label: NSAttributedString

    init(text: String) {
        label = NSAttributedString(string: text, attributes: [.font: Palette.mono(10.5), .foregroundColor: Palette.dim])
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("built in code")
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.size().width) + 12, height: 18) }

    override func draw(_: NSRect) {
        Palette.bg.setFill()
        bounds.fill()
        Palette.lineBright.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// The Split artboard's composer bar: field (focused border), hint row, Send.
final class ComposerBar: NSView {
    let field = ComposerField(style: .standard)
    private let fieldFrame = Box()
    private let hint = ComposerBar.label("Enter 送出 · ⇧Enter 換行 · 貼上圖片會存成檔案路徑", Palette.dimmer)
    private let kbd = Kbd(text: "⌘L")
    private let send = SendButton()
    private let background = Box()
    var onSend: (() -> Void)?

    // .sp-composer padding 8 12 8 16, .composer gap 8, .sp-cwrap gap 5.
    static let padding = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
    static let hintHeight: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.fill = Palette.bgSoft
        background.topRule = Palette.line
        addSubview(background)
        fieldFrame.fill = Palette.bg
        fieldFrame.border = Palette.lineBright
        addSubview(fieldFrame)
        fieldFrame.addSubview(field)
        addSubview(hint)
        addSubview(kbd)
        send.onPress = { [weak self] in self?.onSend?() }
        addSubview(send)
        field.textView.placeholder = "給 Claude 的訊息（⌘L）"
        field.textView.onFocusChange = { [weak self] focused in
            self?.fieldFrame.border = focused ? Palette.amberDim : Palette.lineBright
            self?.fieldFrame.innerGlow = focused ? Palette.amber.withAlphaComponent(0.25) : nil
        }
        field.onHeightChange = { [weak self] _ in
            self?.needsLayout = true
            self?.superview?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("built in code")
    }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        Self.padding.top + field.preferredHeight + 2 + 5 + Self.hintHeight + Self.padding.bottom
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let p = Self.padding
        let sendSize = send.intrinsicContentSize
        let wrapWidth = max(40, bounds.width - p.left - p.right - sendSize.width - 8)
        let fieldHeight = field.preferredHeight + 2
        fieldFrame.frame = NSRect(x: p.left, y: p.top, width: wrapWidth, height: fieldHeight)
        field.frame = fieldFrame.bounds.insetBy(dx: 1, dy: 1)
        let hintY = p.top + fieldHeight + 5
        let kbdWidth = kbd.intrinsicContentSize.width
        kbd.frame = NSRect(x: p.left + wrapWidth - kbdWidth, y: hintY, width: kbdWidth, height: Self.hintHeight)
        hint.frame = NSRect(x: p.left, y: hintY + 1, width: wrapWidth - kbdWidth - 10, height: Self.hintHeight - 2)
        send.frame = NSRect(x: p.left + wrapWidth + 8, y: p.top, width: sendSize.width, height: sendSize.height)
    }

    static func label(_ text: String, _ color: NSColor, size: CGFloat = 11.5) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Palette.mono(size)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// Log on top (what was sent), composer bar at the bottom.
final class DemoRootView: NSView {
    let bar = ComposerBar()
    let logScroll = NSScrollView()
    let log = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.bg.cgColor
        log.isEditable = false
        log.isRichText = false
        log.drawsBackground = true
        log.backgroundColor = Palette.bg
        log.textColor = Palette.dim
        log.font = Palette.mono(11.5)
        log.textContainerInset = NSSize(width: 14, height: 10)
        log.isVerticallyResizable = true
        log.autoresizingMask = [.width]
        log.string = "// codd-composer-demo · 送出的內容會顯示在這裡，也會印到 stdout\n"
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = true
        logScroll.backgroundColor = Palette.bg
        logScroll.borderType = .noBorder
        addSubview(logScroll)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("built in code")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let barHeight = bar.preferredHeight
        bar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        logScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
    }

    func append(_ text: String) {
        log.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: Palette.mono(11.5), .foregroundColor: Palette.cream,
        ]))
        log.scrollToEndOfDocument(nil)
    }
}

@MainActor
final class DemoController: NSObject {
    let window: NSWindow
    let root = DemoRootView(frame: NSRect(x: 0, y: 0, width: 760, height: 380))
    var state: ComposerState
    let stateDirectory: String?
    var field: ComposerField { root.bar.field }

    init(stateDirectory: String?) {
        self.stateDirectory = stateDirectory
        state = stateDirectory.map { ComposerStateFile.load(directory: $0) } ?? .empty
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "codd-composer-demo"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.bg
        window.contentView = root
        window.isReleasedWhenClosed = false
        let textView = field.textView
        textView.onSubmit = { [weak self] text in self?.submit(text) }
        textView.onEscape = { Out.line("ESCAPE") }
        textView.onHistory = { [weak self] direction in self?.history(direction) }
        textView.onPasteImage = { [weak self] image in
            guard let self, let png = image.pngData(), let path = self.saveImage(png) else { return false }
            textView.insertAttachmentText(path)
            return true
        }
        textView.onTextChange = { [weak self] text in
            self?.state.draft = text
            self?.persist()
        }
        root.bar.onSend = { [weak self] in
            guard let self else { return }
            submit(field.text)
        }
        field.text = state.draft
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        field.focus()
    }

    func submit(_ text: String) {
        do {
            let payload = try ComposerEncoding.payload(for: text)
            Out.line("SUBMIT paste=\(payload.paste ? 1 : 0) submit=\(payload.submit ? 1 : 0) bytes=\(payload.bytes.count)")
            Out.line("HEX " + payload.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
            let shown = String(decoding: payload.bytes, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
            Out.line("TEXT " + shown)
            root.append((payload.paste ? "PASTE " : "TYPE  ") + shown + "  (\(payload.bytes.count) bytes)")
            state.history.record(text)
            state.draft = ""
            field.text = ""
            persist()
        } catch {
            Out.line("SUBMIT error=\(error)")
            root.append("// 沒有送出：\(error)")
        }
    }

    func history(_ direction: ComposerHistoryDirection) -> String? {
        switch direction {
        case .previous: state.history.previous(current: field.text)
        case .next: state.history.next()
        }
    }

    func saveImage(_ png: Data) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codd-composer-demo", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = formatter.string(from: Date()) + "-" + String(format: "%06x", UInt32.random(in: 0 ... 0xFFFFFF)) + ".png"
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            Out.line("IMAGE error=\(error)")
            return nil
        }
        Out.line("IMAGE \(url.path) \(png.count) bytes")
        return ComposerPaths.escaped(url.path)
    }

    func persist() {
        guard let stateDirectory else { return }
        do {
            try ComposerStateFile.save(state, directory: stateDirectory)
        } catch {
            Out.line("STATE error=\(error)")
        }
    }

    @objc func reservedShortcut(_ sender: NSMenuItem) {
        Out.line("MENU \(sender.title)")
        if sender.keyEquivalent == "l" {
            field.focus()
        }
    }

    // MARK: Unattended modes

    /// Drives the composer through the input system the way keys would and checks the results.
    func runSmoke() -> Bool {
        var failures: [String] = []
        var submitted: [String] = []
        let textView = field.textView
        let original = textView.onSubmit
        textView.onSubmit = { submitted.append($0) }
        var flags: NSEvent.ModifierFlags = []
        textView.modifierFlagsProvider = { flags }
        func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
            flags = modifiers
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!
            textView.keyDown(with: event)
            flags = []
        }
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        field.text = ""
        textView.insertText("第一行", replacementRange: NSRange(location: NSNotFound, length: 0))
        key("\r", 36, .shift)
        textView.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(field.text == "第一行\n第二行", "shift-return newline: \(field.text.debugDescription)")
        textView.setMarkedText("ㄓㄨˋ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        key("\r", 36)
        check(submitted.isEmpty, "return while composing submitted")
        check(!textView.hasMarkedText(), "composition not committed")
        key("\r", 36)
        check(submitted == ["第一行\n第二行ㄓㄨˋ"], "submit: \(submitted)")
        let payload = try? ComposerEncoding.payload(for: submitted.first ?? "")
        check(payload?.paste == true && payload?.bytes == Array("第一行\r第二行ㄓㄨˋ".utf8), "payload")
        check(field.preferredHeight > ComposerStyle.standard.resolvedLineHeight * 2, "field did not grow")
        let commandL = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
        )!
        check(!textView.performKeyEquivalent(with: commandL), "⌘L consumed by the text view")

        textView.onSubmit = original
        textView.modifierFlagsProvider = { NSApp?.currentEvent?.modifierFlags ?? [] }
        field.text = ""
        if failures.isEmpty {
            Out.line("SMOKE OK")
        } else {
            Out.line("SMOKE FAIL " + failures.joined(separator: "; "))
        }
        return failures.isEmpty
    }

    /// Renders the window with a sample conversation and a two-line draft (placeholder first).
    func snapshot(to path: String) -> Bool {
        root.append("TYPE  修正登入 API 401  (21 bytes)")
        root.layoutSubtreeIfNeeded()
        guard let empty = render() else { return false }
        window.makeFirstResponder(field.textView)
        field.text = "iPhone SE 寬度下的打卡按鈕改成固定在底部，參考 /Users/a/Library/Application\\ Support/CODD/x.png\n第二行"
        field.textView.setMarkedText("ㄉㄥ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        guard let filled = render() else { return false }
        // Both states stacked: placeholder on top, draft with a composition below.
        let width = max(empty.pixelsWide, filled.pixelsWide)
        let height = empty.pixelsHigh + filled.pixelsHigh
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        filled.draw(in: NSRect(x: 0, y: 0, width: filled.pixelsWide, height: filled.pixelsHigh))
        empty.draw(in: NSRect(x: 0, y: filled.pixelsHigh, width: empty.pixelsWide, height: empty.pixelsHigh))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            Out.line("SNAPSHOT error=\(error)")
            return false
        }
        Out.line("SNAPSHOT \(path)")
        return true
    }

    private func render() -> NSBitmapImageRep? {
        root.display()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep
    }
}

@MainActor
enum DemoMenu {
    static func make(target: DemoController) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "codd-composer-demo")
        app.addItem(item("Quit codd-composer-demo", #selector(NSApplication.terminate(_:)), "q", target: nil))
        add(app, to: main)

        // nil targets: the first responder (the composer) answers the standard editing actions.
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", #selector(ComposerTextView.undo(_:)), "z", target: nil))
        let redo = item("Redo", #selector(ComposerTextView.redo(_:)), "z", target: nil)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", target: nil))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", target: nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", target: nil))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil))
        add(edit, to: main)

        // The shortcuts CODD reserves for its own menus. Each prints that it reached the menu.
        let reserved = NSMenu(title: "Reserved")
        var keys: [(String, String, NSEvent.ModifierFlags)] = [
            ("⌘L composer", "l", .command), ("⌘K quick switch", "k", .command), ("⌘⏎ allow", "\r", .command),
            ("⌘J bottom terminal", "j", .command), ("⌘T shell tab", "t", .command), ("⌘P pin", "p", .command),
            ("⌘. stop", ".", .command),
        ]
        keys += (1 ... 9).map { ("⌘\($0) session", String($0), .command) }
        for (title, key, modifiers) in keys {
            let menuItem = item(title, #selector(DemoController.reservedShortcut(_:)), key, target: target)
            menuItem.keyEquivalentModifierMask = modifiers
            reserved.addItem(menuItem)
        }
        add(reserved, to: main)
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DemoController?

    func applicationDidFinishLaunching(_: Notification) {
        let arguments = CommandLine.arguments
        let controller = DemoController(stateDirectory: Self.value(after: "--state-dir", in: arguments))
        self.controller = controller
        NSApp.mainMenu = DemoMenu.make(target: controller)
        if let path = Self.value(after: "--snapshot", in: arguments) {
            exit(controller.snapshot(to: path) ? 0 : 1)
        }
        controller.show()
        NSApp.activate()
        if arguments.contains("--smoke") {
            DispatchQueue.main.async {
                exit(controller.runSmoke() ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

let application = NSApplication.shared
let delegate = DemoAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
