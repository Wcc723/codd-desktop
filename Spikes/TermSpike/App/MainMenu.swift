import AppKit

/// Minimal menu bar: Quit, the standard Edit actions (so Cmd+C / Cmd+V /
/// Cmd+A reach the focused engine through the responder chain) and full screen.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "TermSpike")
        appMenu.addItem(withTitle: "Quit TermSpike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        return menu
    }
}
