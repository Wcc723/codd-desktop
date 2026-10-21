import AppKit
import CoddUI

// codd-ui-gallery: specimen boards of the CoddUI design system.
//
//   swift run --package-path Packages/CoddUI codd-ui-gallery --fonts <repo>/App/Fonts --snapshot <dir>
//       renders every board to <dir>/<board>.png (2x, offscreen; works with a locked screen) and exits
//   swift run --package-path Packages/CoddUI codd-ui-gallery --fonts <repo>/App/Fonts
//       opens a window with all boards
//
// Fonts are only registered when `--fonts` is given (nothing registers them implicitly); without it
// the boards fall back to the system monospaced font.

func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let app = NSApplication.shared
app.appearance = NSAppearance(named: .darkAqua)

if let fonts = argument(after: "--fonts") {
    if !Typeface.registerFonts(in: URL(fileURLWithPath: fonts, isDirectory: true)) {
        FileHandle.standardError.write(Data("codd-ui-gallery: JetBrains Mono / Space Mono not found in \(fonts)\n".utf8))
    }
} else {
    FileHandle.standardError.write(Data("codd-ui-gallery: no --fonts; using the system monospaced font\n".utf8))
}

if let snapshot = argument(after: "--snapshot") {
    app.setActivationPolicy(.prohibited)
    let directory = URL(fileURLWithPath: snapshot, isDirectory: true)
    var failed = false
    for board in GalleryBoards.all() {
        let url = directory.appendingPathComponent("\(board.name).png")
        guard let rep = ViewSnapshot.render(board.view, width: board.width) else {
            FileHandle.standardError.write(Data("codd-ui-gallery: could not render \(board.name)\n".utf8))
            failed = true
            continue
        }
        do {
            try ViewSnapshot.writePNG(rep, to: url)
            print("WROTE \(url.path) \(Int(rep.size.width))x\(Int(rep.size.height))")
        } catch {
            FileHandle.standardError.write(Data("codd-ui-gallery: \(url.path): \(error)\n".utf8))
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}

/// Window mode: every board in one scrolling column.
@MainActor
final class GalleryDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let boards = GalleryBoards.all()
        let column = columnStack(boards.map { board in
            board.view.translatesAutoresizingMaskIntoConstraints = false
            board.view.widthAnchor.constraint(equalToConstant: board.width).isActive = true
            return board.view
        }, spacing: 1)
        let document = FlippedView()
        document.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        let size = column.fittingSize
        document.frame = NSRect(origin: .zero, size: size)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = Palette.bg
        scroll.documentView = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1440, size.width), height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "codd-ui-gallery"
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = GalleryDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
