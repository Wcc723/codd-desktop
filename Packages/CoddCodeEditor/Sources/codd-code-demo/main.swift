import AppKit
import CoddCodeEditor
import CoddUI

// codd-code-demo: the FileEditor artboard's code view.
//
//   swift run --package-path Packages/CoddCodeEditor codd-code-demo --fonts <repo>/App/Fonts --snapshot <dir>
//       renders offscreen (2x, never ordered in, works with a locked screen) and exits:
//       punch-vue.png   the artboard's punch.vue lines 13–49, hunk @@ -40,2 +40,4 @@ (pink), the
//                       `.mod` marker on line 33, find `sticky` 3/7, the caret on line 42 (1100 × 760)
//       find-states.png the replace row and an invalid `.*` pattern (`—`)
//       typescript.png, json.png, python.png   other lexers (1100 × 620)
//   swift run --package-path Packages/CoddCodeEditor codd-code-demo --fonts <repo>/App/Fonts
//       opens a window with punch.vue (manual tool; it never activates itself when run by an agent)

func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("codd-code-demo: \(message)\n".utf8))
    exit(1)
}

@MainActor
func makePunchEditor() -> CodeEditorView {
    let editor = CodeEditorView()
    editor.load(Samples.punchVue, language: .vue, readOnly: false, plainMode: false)
    editor.setInlineDiff([Samples.punchHunk])
    editor.modifiedLineMarkers = [32: Samples.pink]
    editor.overviewMarks = [
        OverviewMark(kind: .aiChange, line: 32, color: Samples.pink),
        OverviewMark(kind: .removed, line: 39),
        OverviewMark(kind: .added, line: 39, lineCount: 4),
    ]
    editor.onHunkAction = { id, action in print("HUNK \(id) \(action)") }
    return editor
}

/// After the editor sits in its window: find from line 39 (so `.punch-sticky` there is 3 / 7),
/// then the caret on line 42 before `64px` and line 13 at the top, as the artboard shows.
@MainActor
func arrangePunch(_ editor: CodeEditorView) {
    editor.goTo(line: 39, column: 1)
    editor.showFind(replace: false, query: "sticky")
    editor.goTo(line: 42, column: 18)
    editor.showsInactiveCaret = true
    editor.scrollToLine(13)
}

@MainActor
func render(_ editor: CodeEditorView, size: NSSize, arrange: (CodeEditorView) -> Void, to url: URL) {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    let host = PanelView(fill: .black)
    host.frame = NSRect(origin: .zero, size: size)
    window.contentView = host
    editor.frame = host.bounds
    editor.autoresizingMask = [.width, .height]
    host.addSubview(editor)
    host.layoutSubtreeIfNeeded()
    arrange(editor)
    host.layoutSubtreeIfNeeded()
    // Let deferred work (flushes, overlay placement) run before drawing.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("could not allocate a bitmap") }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    do {
        try ViewSnapshot.writePNG(rep, to: url)
        print("WROTE \(url.path) \(Int(size.width))x\(Int(size.height))")
    } catch {
        fail("\(url.path): \(error)")
    }
    editor.removeFromSuperview()
    window.contentView = nil
    window.close()
}

let app = NSApplication.shared
app.appearance = NSAppearance(named: .darkAqua)

if let fonts = argument(after: "--fonts") {
    if !Typeface.registerFonts(in: URL(fileURLWithPath: fonts, isDirectory: true)) {
        FileHandle.standardError.write(Data("codd-code-demo: JetBrains Mono / Space Mono not found in \(fonts)\n".utf8))
    }
} else {
    FileHandle.standardError.write(Data("codd-code-demo: no --fonts; using the system monospaced font\n".utf8))
}

if let snapshot = argument(after: "--snapshot") {
    app.setActivationPolicy(.prohibited)
    let directory = URL(fileURLWithPath: snapshot, isDirectory: true)
    MainActor.assumeIsolated {
        render(makePunchEditor(), size: NSSize(width: 1100, height: 760), arrange: arrangePunch,
               to: directory.appendingPathComponent("punch-vue.png"))

        let states = makePunchEditor()
        render(states, size: NSSize(width: 1100, height: 360), arrange: { editor in
            editor.goTo(line: 47, column: 3)
            editor.showFind(replace: true, query: "(sticky")
            editor.findOptions = FindOptions(caseSensitive: true, wholeWord: false, regex: true)
            editor.scrollToLine(36)
        }, to: directory.appendingPathComponent("find-states.png"))

        let samples: [(String, String, CodeLanguage)] = [
            ("typescript", Samples.typescript, .typescript),
            ("json", Samples.json, .json),
            ("python", Samples.python, .python),
        ]
        for (name, text, language) in samples {
            let editor = CodeEditorView()
            editor.load(text, language: language, readOnly: false, plainMode: false)
            render(editor, size: NSSize(width: 1100, height: 620), arrange: { editor in
                editor.goTo(line: 3, column: 1)
            }, to: directory.appendingPathComponent("\(name).png"))
        }
    }
    exit(0)
}

/// Window mode: punch.vue in a resizable window (manual 注音 / find checks).
@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let editor = makePunchEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "codd-code-demo · punch.vue"
        window.contentView = editor
        window.center()
        editor.onTextChange = { text in print("TEXT \((text as NSString).length) units") }
        editor.onCaretChange = { caret in print("CARET Ln \(caret.line), Col \(caret.column)") }
        editor.onFindChange = { query, _, current, total in print("FIND \(query) \(current)/\(total)") }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        arrangePunch(editor)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Run by an agent (Claude Code, CODD's background mode) the window would take focus from the
// user: the window mode is a manual tool, so it refuses there.
let environment = ProcessInfo.processInfo.environment
if environment["CLAUDECODE"] != nil || environment["CODD_BACKGROUND"] != nil {
    fail("the window mode is a manual tool and does not run under CLAUDECODE / CODD_BACKGROUND; use --snapshot")
}

let delegate = DemoDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
