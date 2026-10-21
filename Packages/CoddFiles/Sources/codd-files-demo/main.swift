import AppKit
import CoddFileEditorUI
import CoddUI

// codd-files-demo [--fonts <dir>] [--snapshot <dir>]
//   --snapshot: renders the FileEditor artboard composition (1440 × 900, offscreen, never shown)
//               to <dir>/file-editor.png (1x) and file-editor@2x.png, plus the dirty-close sheet and
//               the notes banner variant, then exits.
//   otherwise:  opens a window with the composition (not activated: it never takes focus).

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
        let size = NSSize(width: 1440, height: 900)
        for (name, scale) in [("file-editor.png", CGFloat(1)), ("file-editor@2x.png", 2)] {
            guard let rep = FileEditorSnapshot.render(FileEditorComposition(), size: size, scale: scale) else { continue }
            try? FileEditorSnapshot.writePNG(rep, to: url.appendingPathComponent(name))
        }
        let sheet = DirtyCloseSheetView(fileName: "punch.vue")
        if let rep = FileEditorSnapshot.render(sheet, size: NSSize(width: DirtyCloseSheetView.width, height: DirtyCloseSheetView.height)) {
            try? FileEditorSnapshot.writePNG(rep, to: url.appendingPathComponent("dirty-close-sheet.png"))
        }
        let note = DiskChangeBannerView(model: .noteChanged())
        if let rep = FileEditorSnapshot.render(note, size: NSSize(width: 1104, height: DiskChangeBannerView.height)) {
            try? FileEditorSnapshot.writePNG(rep, to: url.appendingPathComponent("banner-note.png"))
        }
        print("SNAPSHOTS \(url.path)")
        exit(0)
    }
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "codd-files-demo"
    window.contentView = FileEditorComposition()
    window.center()
    window.orderFront(nil)
    app.run()
}
