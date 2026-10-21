import Foundation

/// The `codd-annotations` block that follows an image in a note (§3.3, SPEC R6, D10): numbered
/// rect / point / arrow / text items in ORIGINAL image pixels (origin top-left) and the per-image
/// send options. Keys CODD does not know are kept and written back.
public struct ImageAnnotations: Sendable, Equatable, Codable {
    public struct PixelSize: Sendable, Equatable, Codable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            width = try Self.int(&c)
            height = try Self.int(&c)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(width)
            try c.encode(height)
        }

        private static func int(_ c: inout any UnkeyedDecodingContainer) throws -> Int {
            if let i = try? c.decode(Int.self) { return i }
            return Int(try c.decode(Double.self).rounded())
        }
    }

    public struct Item: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable, CaseIterable {
            case rect, point, arrow, text
        }

        public var n: Int
        public var type: Kind
        public var x: Int
        public var y: Int
        public var w: Int?
        public var h: Int?
        public var x2: Int?
        public var y2: Int?
        public var note: String
        /// `amber` (default), `cyan`, `danger`, `success`, `cream`.
        public var color: String?
        public var extra: [String: JSONValue]

        public init(n: Int, type: Kind, x: Int, y: Int, w: Int? = nil, h: Int? = nil, x2: Int? = nil, y2: Int? = nil,
                    note: String, color: String? = nil, extra: [String: JSONValue] = [:]) {
            self.n = n
            self.type = type
            self.x = x
            self.y = y
            self.w = w
            self.h = h
            self.x2 = x2
            self.y2 = y2
            self.note = note
            self.color = color
            self.extra = extra
        }

        static let knownKeys: Set<String> = ["n", "type", "x", "y", "w", "h", "x2", "y2", "note", "color"]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            n = try c.int("n") ?? 0
            let t = try c.decodeIfPresent(String.self, forKey: AnyKey("type")) ?? "rect"
            guard let kind = Kind(rawValue: t) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown item type \(t)"))
            }
            type = kind
            x = try c.int("x") ?? 0
            y = try c.int("y") ?? 0
            w = try c.int("w")
            h = try c.int("h")
            x2 = try c.int("x2")
            y2 = try c.int("y2")
            note = try c.decodeIfPresent(String.self, forKey: AnyKey("note")) ?? ""
            color = try c.decodeIfPresent(String.self, forKey: AnyKey("color"))
            extra = try c.extras(excluding: Self.knownKeys)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(n, forKey: AnyKey("n"))
            try c.encode(type.rawValue, forKey: AnyKey("type"))
            try c.encode(x, forKey: AnyKey("x"))
            try c.encode(y, forKey: AnyKey("y"))
            try c.encodeIfPresent(w, forKey: AnyKey("w"))
            try c.encodeIfPresent(h, forKey: AnyKey("h"))
            try c.encodeIfPresent(x2, forKey: AnyKey("x2"))
            try c.encodeIfPresent(y2, forKey: AnyKey("y2"))
            try c.encode(note, forKey: AnyKey("note"))
            try c.encodeIfPresent(color, forKey: AnyKey("color"))
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        }

        fileprivate func write(into out: inout String) {
            out += "{\"n\":\(n),\"type\":\(JSONText.quoted(type.rawValue)),\"x\":\(x),\"y\":\(y)"
            if let w { out += ",\"w\":\(w)" }
            if let h { out += ",\"h\":\(h)" }
            if let x2 { out += ",\"x2\":\(x2)" }
            if let y2 { out += ",\"y2\":\(y2)" }
            out += ",\"note\":" + JSONText.quoted(note)
            if let color { out += ",\"color\":" + JSONText.quoted(color) }
            writeExtras(extra, into: &out)
            out += "}"
        }
    }

    public struct SendOptions: Sendable, Equatable, Codable {
        /// 附上原圖.
        public var original: Bool
        /// 附上標註後的圖.
        public var annotated: Bool
        /// 附上座標清單.
        public var list: Bool
        public var extra: [String: JSONValue]

        public init(original: Bool = false, annotated: Bool = true, list: Bool = true, extra: [String: JSONValue] = [:]) {
            self.original = original
            self.annotated = annotated
            self.list = list
            self.extra = extra
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            original = try c.decodeIfPresent(Bool.self, forKey: AnyKey("original")) ?? false
            annotated = try c.decodeIfPresent(Bool.self, forKey: AnyKey("annotated")) ?? true
            list = try c.decodeIfPresent(Bool.self, forKey: AnyKey("list")) ?? true
            extra = try c.extras(excluding: ["original", "annotated", "list"])
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(original, forKey: AnyKey("original"))
            try c.encode(annotated, forKey: AnyKey("annotated"))
            try c.encode(list, forKey: AnyKey("list"))
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        }
    }

    public var v: Int
    /// The image's path as linked in the note (`assets/<id>/<hash6>.png`).
    public var image: String
    public var size: PixelSize
    public var items: [Item]
    public var send: SendOptions
    public var extra: [String: JSONValue]

    public init(v: Int = 1, image: String, size: PixelSize, items: [Item], send: SendOptions = SendOptions(),
                extra: [String: JSONValue] = [:]) {
        self.v = v
        self.image = image
        self.size = size
        self.items = items
        self.send = send
        self.extra = extra
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        v = try c.int("v") ?? 1
        image = try c.decodeIfPresent(String.self, forKey: AnyKey("image")) ?? ""
        size = try c.decodeIfPresent(PixelSize.self, forKey: AnyKey("size")) ?? PixelSize(width: 0, height: 0)
        items = try c.decodeIfPresent([Item].self, forKey: AnyKey("items")) ?? []
        send = try c.decodeIfPresent(SendOptions.self, forKey: AnyKey("send")) ?? SendOptions()
        extra = try c.extras(excluding: ["v", "image", "size", "items", "send"])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(v, forKey: AnyKey("v"))
        try c.encode(image, forKey: AnyKey("image"))
        try c.encode(size, forKey: AnyKey("size"))
        try c.encode(items, forKey: AnyKey("items"))
        try c.encode(send, forKey: AnyKey("send"))
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
    }

    /// Decodes a block's JSON; nil when it is not a JSON object of this shape.
    public static func decode(_ json: String) -> ImageAnnotations? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ImageAnnotations.self, from: data)
    }

    /// Compact JSON in the §3.3 key order (`v`, `image`, `size`, `items`, `send`, then unknown keys
    /// sorted), CJK unescaped: the same input always gives the same bytes.
    public func encoded() -> String {
        var out = "{\"v\":\(v),\"image\":" + JSONText.quoted(image) + ",\"size\":[\(size.width),\(size.height)],\"items\":["
        for (k, item) in items.enumerated() {
            if k > 0 { out += "," }
            item.write(into: &out)
        }
        out += "],\"send\":{\"original\":\(send.original),\"annotated\":\(send.annotated),\"list\":\(send.list)"
        writeExtras(send.extra, into: &out)
        out += "}"
        writeExtras(extra, into: &out)
        out += "}"
        return out
    }

    /// The header line of the list (the ImageAnnotate artboard's `AI 會收到` text).
    public static let listHeader = "annotations（原圖像素，左上為原點）:"

    /// The §3.7 coordinate list: the header line, then one line per item in `n` order
    /// (`  1 rect  x=20 y=1150 w=710 h=120  <note>`), no trailing newline.
    public func formattedList() -> String {
        var lines = [Self.listHeader]
        for item in items.sorted(by: { $0.n < $1.n }) {
            let typeColumn = item.type.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
            let coords: String
            switch item.type {
            case .rect:
                coords = "x=\(item.x) y=\(item.y) w=\(item.w ?? 0) h=\(item.h ?? 0)"
            case .point, .text:
                coords = "x=\(item.x) y=\(item.y)"
            case .arrow:
                coords = "\(item.x),\(item.y) → \(item.x2 ?? item.x),\(item.y2 ?? item.y)"
            }
            var line = "  \(item.n) \(typeColumn) \(coords)"
            let note = item.note.replacingOccurrences(of: "\n", with: " ")
            if !note.isEmpty { line += "  " + note }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The SHA-256 of the canonical encoding: the annotated copy's cache key.
    var cacheKey: String { Hashing.sha256Hex(encoded()) }
}

private func writeExtras(_ extra: [String: JSONValue], into out: inout String) {
    for key in extra.keys.sorted() {
        out += "," + JSONText.quoted(key) + ":"
        extra[key]!.write(into: &out)
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func int(_ key: String) throws -> Int? {
        let k = AnyKey(key)
        guard contains(k), !(try decodeNil(forKey: k)) else { return nil }
        if let i = try? decode(Int.self, forKey: k) { return i }
        return Int(try decode(Double.self, forKey: k).rounded())
    }

    func extras(excluding known: Set<String>) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in allKeys where !known.contains(k.stringValue) {
            out[k.stringValue] = try decode(JSONValue.self, forKey: k)
        }
        return out
    }
}
