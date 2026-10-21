import CoreGraphics

/// What an annotation is (M4 §3.3 `type`): a box, a numbered point, an arrow or a text label drawn on
/// the image (the artboard's T tool).
public enum AnnotationKind: String, Sendable, CaseIterable {
    case rect, point, arrow, text

    /// The type chip (`.chip.caps.ia-ty`): `RECT`, `POINT`, `ARROW`, `TEXT`.
    public var chipLabel: String { rawValue.uppercased() }

    /// The explanatory name next to the chip (`框選` / `點` / `箭頭` / `文字`).
    public var title: String {
        switch self {
        case .rect: "框選"
        case .point: "點"
        case .arrow: "箭頭"
        case .text: "文字"
        }
    }
}

/// The five annotation colors of §3.3 (`amber` is the default and the only one the artboard shows).
public enum AnnotationColor: String, Sendable, CaseIterable {
    case amber, cyan, danger, success, cream

    /// The color menu's name (new copy, D34-like).
    public var title: String {
        switch self {
        case .amber: "琥珀"
        case .cyan: "青藍"
        case .danger: "紅"
        case .success: "綠"
        case .cream: "米白"
        }
    }
}

/// One annotation in ORIGINAL image pixels (origin top-left, integers). `rect` uses `w` / `h`,
/// `arrow` uses `x2` / `y2`; `point` and `text` use only `x` / `y` (a text label's top-left).
/// `n` is the 1-based creation order; deleting renumbers the rest (`依建立順序編號`).
public struct AnnotationDraft: Sendable, Equatable, Identifiable {
    public var n: Int
    public var kind: AnnotationKind
    public var x: Int
    public var y: Int
    public var w: Int?
    public var h: Int?
    public var x2: Int?
    public var y2: Int?
    public var note: String
    public var color: AnnotationColor

    public var id: Int { n }

    public init(n: Int, kind: AnnotationKind, x: Int, y: Int, w: Int? = nil, h: Int? = nil, x2: Int? = nil, y2: Int? = nil,
                note: String = "", color: AnnotationColor = .amber) {
        self.n = n
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.x2 = x2
        self.y2 = y2
        self.note = note
        self.color = color
    }

    public static func rect(_ n: Int, x: Int, y: Int, w: Int, h: Int, note: String = "", color: AnnotationColor = .amber) -> AnnotationDraft {
        AnnotationDraft(n: n, kind: .rect, x: x, y: y, w: w, h: h, note: note, color: color)
    }

    public static func point(_ n: Int, x: Int, y: Int, note: String = "", color: AnnotationColor = .amber) -> AnnotationDraft {
        AnnotationDraft(n: n, kind: .point, x: x, y: y, note: note, color: color)
    }

    public static func arrow(_ n: Int, x: Int, y: Int, x2: Int, y2: Int, note: String = "", color: AnnotationColor = .amber) -> AnnotationDraft {
        AnnotationDraft(n: n, kind: .arrow, x: x, y: y, x2: x2, y2: y2, note: note, color: color)
    }

    public static func text(_ n: Int, x: Int, y: Int, note: String, color: AnnotationColor = .amber) -> AnnotationDraft {
        AnnotationDraft(n: n, kind: .text, x: x, y: y, note: note, color: color)
    }

    /// Width / height of a rect (0 for the other kinds or a draft without them).
    public var width: Int { w ?? 0 }
    public var height: Int { h ?? 0 }
    /// The arrow's head (its start for a draft without `x2` / `y2`).
    public var endX: Int { x2 ?? x }
    public var endY: Int { y2 ?? y }

    /// The coordinate line of the list rows and the tooltip, in the artboard's words:
    /// `x 20 · y 1150 · 710×120`, `x 375 · y 330`, `x 600 · y 760 → x 700 · y 1080`.
    public var coordinateText: String {
        switch kind {
        case .rect: "x \(x) · y \(y) · \(width)×\(height)"
        case .point, .text: "x \(x) · y \(y)"
        case .arrow: "x \(x) · y \(y) → x \(endX) · y \(endY)"
        }
    }
}

/// What goes to the AI with this image (§3.3 `send`; defaults false / true / true).
public struct AnnotationSendOptions: Sendable, Equatable {
    /// 附上原圖
    public var original = false
    /// 附上標註後的圖（燒進框線與編號）
    public var annotated = true
    /// 附上座標清單
    public var list = true

    public init(original: Bool = false, annotated: Bool = true, list: Bool = true) {
        self.original = original
        self.annotated = annotated
        self.list = list
    }
}

/// The annotations of one image: its original pixel size, the items in creation order and the
/// send options. The app maps CoddNotes' `ImageAnnotations` to and from this value.
public struct AnnotationDocument: Sendable, Equatable {
    public var pixelSize: CGSize
    public var items: [AnnotationDraft]
    public var send: AnnotationSendOptions

    public init(pixelSize: CGSize, items: [AnnotationDraft] = [], send: AnnotationSendOptions = AnnotationSendOptions()) {
        self.pixelSize = pixelSize
        self.items = items
        self.send = send
    }

    /// The item numbered `n`.
    public func item(_ n: Int) -> AnnotationDraft? { items.first { $0.n == n } }

    /// Integer pixel bounds (at least 1 × 1).
    var pixelWidth: Int { max(1, Int(pixelSize.width.rounded())) }
    var pixelHeight: Int { max(1, Int(pixelSize.height.rounded())) }
}

/// The top bar's texts: crumbs (`["INBOX", "打卡頁 RWD 跑版紀錄"]`), the image file name (`.ttl`),
/// the meta line items (joined with ` · `) and the original's file name (the `附上原圖` hint).
public struct ImageAnnotateHeader: Sendable, Equatable {
    public var crumbs: [String]
    public var fileName: String
    public var meta: [String]
    public var originalFileName: String

    public init(crumbs: [String], fileName: String, meta: [String], originalFileName: String) {
        self.crumbs = crumbs
        self.fileName = fileName
        self.meta = meta
        self.originalFileName = originalFileName
    }
}

/// The tool strip's tools (keys V R P A T while the canvas has focus).
public enum AnnotateTool: Sendable, CaseIterable {
    case select, rect, point, arrow, text

    /// The key letter drawn in the button's corner and typed on the canvas.
    public var key: String {
        switch self {
        case .select: "V"
        case .rect: "R"
        case .point: "P"
        case .arrow: "A"
        case .text: "T"
        }
    }

    /// The button's accessibility label (the artboard's `aria-label`).
    public var title: String {
        switch self {
        case .select: "選取"
        case .rect: "框選"
        case .point: "點"
        case .arrow: "箭頭"
        case .text: "文字"
        }
    }
}

/// Fit (the largest scale that fits the stage, ≤ 100 %), 100 % (one image pixel per point) and 200 %.
public enum AnnotateZoom: Sendable, Equatable, CaseIterable {
    case fit, actual, double

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .actual: "100%"
        case .double: "200%"
        }
    }
}
