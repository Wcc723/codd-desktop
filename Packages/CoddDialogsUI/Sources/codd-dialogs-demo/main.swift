import AppKit
import CoddDialogsUI
import CoddUI

// codd-dialogs-demo [--fonts <dir>] [--snapshot <dir>]
//   --snapshot: renders every dialog state (SPEC §5 sample) to <dir>/<name>.png and exits.
//   otherwise:  opens a window with one button per dialog (sheets for A / B / D, the child panel
//               for C) to try keys (⏎ / ⎋), the alias field (注音) and the panel's placement.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    if let fonts = value(after: "--fonts") {
        if !Typeface.registerFonts(in: URL(fileURLWithPath: fonts, isDirectory: true)) {
            FileHandle.standardError.write(Data("fonts not found in \(fonts)\n".utf8))
        }
    }
    app.appearance = NSAppearance(named: .darkAqua)
    if let dir = value(after: "--snapshot") {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, view) in DemoBoard.states(now: Date()) {
            DemoBoard.write(view, to: url.appendingPathComponent("\(name).png"))
        }
        print("SNAPSHOTS \(url.path)")
        exit(0)
    }
    app.setActivationPolicy(.regular)
    let demo = DemoBoard()
    demo.show()
    app.activate()
    withExtendedLifetime(demo) { app.run() }
}

@MainActor
final class DemoBoard: NSObject {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    private var dialog: NSWindow?

    static func states(now: Date) -> [(String, NSView)] {
        let noop: () -> Void = {}
        return [
            ("a-switch-idle", SwitchAccountDialogView(model: DialogSamples.switchAccount(now: now), onConfirm: { _ in }, onCancel: noop)),
            ("a-switch-switching", SwitchAccountDialogView(model: DialogSamples.switchAccountSwitching(now: now), onConfirm: { _ in },
                                                           onCancel: noop)),
            ("a-switch-failed", SwitchAccountDialogView(model: DialogSamples.switchAccountFailed(now: now), onConfirm: { _ in },
                                                        onCancel: noop)),
            ("b-hooks-sample", HookDiffDialogView(model: DialogSamples.hookDiff(), onApply: noop, onCancel: noop)),
            ("b-hooks-no-changes", HookDiffDialogView(model: DialogSamples.hookDiffNoChanges(), onApply: noop, onCancel: noop)),
            ("b-hooks-error", HookDiffDialogView(model: DialogSamples.hookDiffError(), onApply: noop, onCancel: noop)),
            ("c-add-step1", addAccount(DialogSamples.addAccountStep1())),
            ("c-add-step2", addAccount(DialogSamples.addAccountStep2(now: now))),
            ("c-add-step3", addAccount(DialogSamples.addAccountStep3(now: now, alias: "studio"))),
            ("c-add-step3-invalid-alias", addAccount(DialogSamples.addAccountStep3(now: now, alias: "工作室"))),
            ("c-add-existing", addAccount(DialogSamples.addAccountExisting(now: now))),
            ("c-add-failed", addAccount(DialogSamples.addAccountFailed(now: now))),
            ("d-quit-sample", QuitDialogView(model: DialogSamples.quit(now: now), onChoice: { _, _ in })),
            ("d-quit-no-needs", QuitDialogView(model: DialogSamples.quitNoNeeds(), onChoice: { _, _ in })),
        ]
    }

    private static func addAccount(_ model: AddAccountModel) -> AddAccountDialogView {
        AddAccountDialogView(model: model, onOpenLoginTerminal: {}, onCapture: {}, onAdd: { _, _ in }, onAddToken: {}, onCancel: {})
    }

    /// Renders `view` on the artboard background (#050505, 32 pt margin) at 2x into a PNG.
    static func write(_ view: NSView, to url: URL) {
        let margin: CGFloat = 32
        let host = FlippedView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = Palette.bg.cgColor
        host.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        view.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        host.layoutSubtreeIfNeeded()
        // A second pass: wrapping labels learn their width in the first layout.
        let refit = view.fittingSize
        if abs(refit.height - size.height) > 0.5 {
            host.setFrameSize(NSSize(width: refit.width + margin * 2, height: refit.height + margin * 2))
            window.setContentSize(host.frame.size)
            view.frame = NSRect(x: margin, y: margin, width: refit.width, height: refit.height)
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
        try? DialogSnapshot.png(of: host)?.write(to: url)
        window.contentView = nil
        window.close()
    }

    func show() {
        window.title = "codd-dialogs-demo"
        window.backgroundColor = Palette.bg
        let buttons: [(String, Selector)] = [("A 切換帳號", #selector(showA)), ("B Hook 差異", #selector(showB)),
                                              ("C 加入帳號", #selector(showC)), ("D 結束", #selector(showD))]
        let row = hStack(buttons.map { CoddButton($0.0, style: .bracket(.normal, small: false), target: self, action: $0.1) }, spacing: 10,
                         edgeInsets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        let content = FlippedView()
        content.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
        row.topAnchor.constraint(equalTo: content.topAnchor, constant: 30).isActive = true
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        if let dialog { DialogPresenter.dismiss(dialog) }
        dialog = nil
    }

    @objc private func showA() {
        close()
        let now = Date()
        var view: SwitchAccountDialogView?
        view = SwitchAccountDialogView(model: DialogSamples.switchAccount(now: now), onConfirm: { [weak self] pause in
            print("A confirm pauseAutoSwitch=\(pause)")
            guard let view else { return }
            var model = view.model
            model.progress = SwitchProgress(attempt: 1, of: 3, since: Date())
            view.update(model)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.close() }
        }, onCancel: { [weak self] in print("A cancel"); self?.close() })
        if let view { dialog = DialogPresenter.presentSheet(view, on: window) }
    }

    @objc private func showB() {
        close()
        let view = HookDiffDialogView(model: DialogSamples.hookDiff(), onApply: { [weak self] in print("B apply"); self?.close() },
                                      onCancel: { [weak self] in print("B cancel"); self?.close() })
        dialog = DialogPresenter.presentSheet(view, on: window)
    }

    @objc private func showC() {
        close()
        let view = AddAccountDialogView(model: DialogSamples.addAccountStep3(now: Date()), onOpenLoginTerminal: { print("C open terminal") },
                                        onCapture: { print("C capture") }, onAdd: { [weak self] alias, slot in
                                            print("C add alias=\(alias) slot=\(slot)")
                                            self?.close()
                                        }, onAddToken: { print("C add-token") }, onCancel: { [weak self] in print("C cancel"); self?.close() })
        dialog = DialogPresenter.presentPanel(view, over: window)
    }

    @objc private func showD() {
        close()
        let view = QuitDialogView(model: DialogSamples.quit(now: Date())) { [weak self] choice, keep in
            print("D choice=\(choice) keepNextTime=\(keep)")
            self?.close()
        }
        dialog = DialogPresenter.presentSheet(view, on: window)
    }
}
