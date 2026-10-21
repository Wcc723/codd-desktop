import AppKit

/// D39: every pasteboard write CODD makes (COPY REF, ⌘⇧C, the Codex snippet's 複製, 複製 ID) goes
/// through here. The general pasteboard is written only for a user action in a foreground run;
/// a background run (`AppActivation.isBackground`: scripts, agents, tests) and any write that no
/// user asked for go to a private named pasteboard instead, so automation never replaces what the
/// user copied. Every write logs `pasteboard target=general|private` (never the content); the
/// last write is kept for the state dump. Writes that carry a token are marked concealed.
@MainActor
final class CoddPasteboard {
    enum Target: String, Sendable {
        case general
        case `private`
    }

    struct Write: Equatable, Sendable {
        var target: Target
        /// Characters written (the dump never carries the text of a general write).
        var characters: Int
        var at: Date
    }

    /// `app.codd.CODD.private`: not one the user's apps read.
    static let privateName = NSPasteboard.Name(CoddIdentity.bundleIdentifier + ".private")

    private let isBackground: Bool
    private let log: @MainActor (String) -> Void
    private let clock: () -> Date
    private(set) var lastWrite: Write?

    init(isBackground: Bool = AppActivation.isBackground, log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) },
         clock: @escaping () -> Date = { Date() }) {
        self.isBackground = isBackground
        self.log = log
        self.clock = clock
    }

    /// Where a write goes: the general pasteboard only when the user asked for it in the foreground.
    func target(userAction: Bool) -> Target {
        userAction && !isBackground ? .general : .private
    }

    /// nspasteboard.org's marker: clipboard history apps keep no readable copy of the item.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Writes `text` as plain text and returns where it went. `concealed`: the text carries a
    /// secret (the Codex snippet's external token, a note URL's `?t=`): marked
    /// ``concealedType`` and kept off Universal Clipboard (`currentHostOnly`).
    @discardableResult
    func write(_ text: String, userAction: Bool, concealed: Bool = false) -> Target {
        let target = target(userAction: userAction)
        let board = target == .general ? NSPasteboard.general : NSPasteboard(name: Self.privateName)
        board.prepareForNewContents(with: concealed ? .currentHostOnly : [])
        board.setString(text, forType: .string)
        if concealed { board.setData(Data(), forType: Self.concealedType) }
        lastWrite = Write(target: target, characters: text.count, at: clock())
        log("pasteboard target=\(target.rawValue) chars=\(text.count)" + (concealed ? " concealed=true" : ""))
        return target
    }

    /// What the private pasteboard holds (tests, the DEBUG dump).
    static func privateString() -> String? {
        NSPasteboard(name: privateName).string(forType: .string)
    }
}
