import AppKit
import CoddUI

// The custom popover menus (helmet `.menu`, the Notebook artboard's `.nb-refmenu`) are drawn from
// these values. The chrome views build them from their own models; the app can build its own
// (e.g. a context menu shown as a popover) and present a `NotebookMenuView` itself.

/// What sits in an item's `.g` column.
public enum NotebookMenuGlyph: Sendable, Equatable {
    case icon(NotebookIcon)
    /// A text glyph (`@`, `❯`, `✓`).
    case text(String)
    /// A session lamp.
    case lamp(NotebookSessionState)
    /// A project's tag square (nil: the dashed "no color" square).
    case tag(NotebookTag?)
}

/// The color of an item's value line.
public enum NotebookMenuTone: Sendable, Equatable {
    case normal
    /// `.v.am` (the recommended reference).
    case amber
    /// `color:var(--dim)` (the masked URL).
    case dim
    /// `.mi.danger` (移到垃圾桶).
    case danger
}

/// One menu row. Two-line rows (`.nb-mi2`) have a `hint`; one-line rows are 28 pt.
public struct NotebookMenuItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var glyph: NotebookMenuGlyph?
    public var title: String
    public var tone: NotebookMenuTone
    /// A small filled chip after the title (`推薦`).
    public var chip: String?
    /// The dim second line (wraps to the menu width).
    public var hint: String?
    /// Right-aligned key hint (`⌘⇧C`, `⌘E`).
    public var shortcut: String?
    /// A dim second text on the title line (`orb-toolkit-frontend · busy 6m`).
    public var detail: String?
    public var isEnabled: Bool
    /// Why the item is disabled (its tooltip).
    public var disabledReason: String?
    /// The current value of a choice menu (drawn with an amber `✓` at the right).
    public var isChecked: Bool
    /// Items of a submenu shown in place (`▸`; → / ⏎ / click opens it, ← / ⎋ goes back).
    public var submenu: NotebookMenuModel?

    public init(id: String, glyph: NotebookMenuGlyph? = nil, title: String, tone: NotebookMenuTone = .normal, chip: String? = nil,
                hint: String? = nil, shortcut: String? = nil, detail: String? = nil, isEnabled: Bool = true,
                disabledReason: String? = nil, isChecked: Bool = false, submenu: NotebookMenuModel? = nil) {
        self.id = id
        self.glyph = glyph
        self.title = title
        self.tone = tone
        self.chip = chip
        self.hint = hint
        self.shortcut = shortcut
        self.detail = detail
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.isChecked = isChecked
        self.submenu = submenu
    }

    /// Two-line look (`.nb-mi2`).
    public var isTwoLine: Bool { hint != nil }
}

/// A row of a menu.
public enum NotebookMenuEntry: Sendable, Equatable {
    case item(NotebookMenuItem)
    /// `.menu .sep` (dashed rule).
    case separator
    /// `.mh`: caps title + an optional right text (`COPY REFERENCE · 複製引用   rwd-punch-k7x2`).
    case header(String, trailing: String?)
}

/// A whole menu.
public struct NotebookMenuModel: Sendable, Equatable {
    public var entries: [NotebookMenuEntry]
    /// nil: the widest row (≥ 220, helmet `.menu{min-width:220px}`); the COPY REF menu is 404.
    public var width: CGFloat?
    /// The item highlighted when the menu opens (nil: the first enabled item).
    public var initialHighlight: String?

    public init(entries: [NotebookMenuEntry], width: CGFloat? = nil, initialHighlight: String? = nil) {
        self.entries = entries
        self.width = width
        self.initialHighlight = initialHighlight
    }

    /// The items in order (headers and separators skipped).
    public var items: [NotebookMenuItem] {
        entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    public func item(_ id: String) -> NotebookMenuItem? { items.first { $0.id == id } }
}
