#if DEBUG
import AppKit

/// A drag held still at one window point, for driving the real drop path in-process: the DEBUG
/// drag self-test, `-codd-drop-folders` and the app tests hand it to the outline's own
/// `draggingUpdated` / `performDragOperation`, which compute AppKit's proposal and call the data
/// source exactly as during a mouse drag. No dragging session exists, so the system pointer, the
/// window server and other apps are never involved (no posted events).
@MainActor
final class SyntheticDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    private static var sequence = 0

    var draggingLocation: NSPoint
    let window: NSWindow
    private let source: AnyObject?
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    let draggingSourceOperationMask: NSDragOperation
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    /// - Parameters:
    ///   - source: the sidebar outline for a drag of its own rows, nil for a drag from Finder.
    ///   - pasteboard: a uniquely named pasteboard (never the general one); `fileURLs` fills it.
    init(location: NSPoint, window: NSWindow, source: AnyObject?, pasteboard: NSPasteboard = .withUniqueName(),
         fileURLs: [URL] = [], operationMask: NSDragOperation? = nil) {
        Self.sequence += 1
        draggingLocation = location
        self.window = window
        self.source = source
        draggingPasteboard = pasteboard
        draggingSequenceNumber = 900_000 + Self.sequence
        draggingSourceOperationMask = operationMask ?? (source == nil ? [.copy, .link, .generic] : .move)
        super.init()
        if !fileURLs.isEmpty {
            pasteboard.clearContents()
            pasteboard.writeObjects(fileURLs.map { $0 as NSURL })
        }
    }

    /// A drag at `fraction` of the way down a row of `view` (a table or outline row rect).
    convenience init(row rect: CGRect, fraction: CGFloat, in view: NSView, window: NSWindow, source: AnyObject?,
                     fileURLs: [URL] = []) {
        let point = view.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
        self.init(location: point, window: window, source: source, fileURLs: fileURLs)
    }

    /// Drops the private pasteboard (call once the drop is done).
    func release() { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { window }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { source }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// What one synthetic drop did (the self-test and the tests check it).
struct SyntheticDropResult {
    /// `validateDrop`'s operation (empty = no target).
    var operation: NSDragOperation
    /// The amber line was shown, above every row view.
    var lineShown: Bool
    var plan: DropPlan?
    var targetBlock: BlockID?
    /// `acceptDrop` ran and returned true.
    var performed: Bool
}

extension SidebarViewController {
    /// Drives one drop through the outline the way AppKit does during a mouse drag: entered,
    /// updated (AppKit proposes, `validateDrop` plans), then prepare / perform / conclude (the
    /// data source's `acceptDrop`) when there is a target, else exited; then ended.
    func syntheticDrop(_ info: SyntheticDraggingInfo, perform: Bool = true) -> SyntheticDropResult {
        _ = outline.draggingEntered(info)
        let operation = outline.draggingUpdated(info)
        let result = SyntheticDropResult(operation: operation,
                                         lineShown: !dropLine.isHidden && outline.subviews.last === dropLine,
                                         plan: dropPlan, targetBlock: dropTargetBlock, performed: false)
        var performed = false
        if perform, !operation.isEmpty, outline.prepareForDragOperation(info) {
            performed = outline.performDragOperation(info)
            outline.concludeDragOperation(info)
        } else {
            outline.draggingExited(info)
        }
        outline.draggingEnded(info)
        var out = result
        out.performed = performed
        return out
    }

    /// The last visible row of `node`'s block (its own row when collapsed or childless).
    func lastVisibleRow(of node: NodeKind) -> NodeKind {
        applyNow()
        let rows = dropRows()
        guard let start = rows.firstIndex(where: { $0.node == node }) else { return node }
        var end = start
        while end + 1 < rows.count, rows[end + 1].depth > rows[start].depth { end += 1 }
        return rows[end].node
    }

    /// A synthetic drag at `fraction` of the way down `node`'s row (nil when the row is not shown).
    func syntheticInfo(at node: NodeKind, fraction: CGFloat, ownRows: Bool, fileURLs: [URL] = []) -> SyntheticDraggingInfo? {
        guard let window = view.window else { return nil }
        let row = outline.row(forItem: item(for: node))
        guard row >= 0 else { return nil }
        return SyntheticDraggingInfo(row: outline.rect(ofRow: row), fraction: fraction, in: outline, window: window,
                                     source: ownRows ? outline : nil, fileURLs: fileURLs)
    }
}
#endif
