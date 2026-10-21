import AppKit
import CoreText

/// Fonts: JetBrains Mono (body, variable `wght` axis) and Space Mono Bold (display), both
/// bundled in `Contents/Resources/Fonts` (ATSApplicationFontsPath). CJK falls back to
/// PingFang TC through an explicit cascade list, so Chinese never lands on a random font.
///
/// Sizes are design sizes (helmet px at UI 字級 13): every font is made at `size ×`
/// ``UIZoom/scale``, so the whole interface follows the interface zoom. Each font made here is
/// remembered with its design size, so a font stored earlier (in a ``TextStyle``, an attributed
/// string, a label) can be made again at the current zoom (``current(_:)``, ``rescaled(_:)``).
/// ``fixed(_:_:)`` makes a font that never follows the zoom (terminal text has its own size).
@MainActor
public enum Typeface {
    public enum Weight: CGFloat {
        case regular = 400, medium = 500, semibold = 600, bold = 700
    }

    /// What a font is in the design: face, design size and weight (`wght`). `name` is another
    /// face by PostScript name (``named(_:_:)``); nil for CODD's two faces.
    public struct Spec: Hashable, Sendable {
        public var display: Bool
        public var size: CGFloat
        public var weight: CGFloat
        public var name: String?

        public init(display: Bool, size: CGFloat, weight: CGFloat, name: String? = nil) {
            self.display = display
            self.size = size
            self.weight = weight
            self.name = name
        }
    }

    /// A made font: its design spec, the zoom it was made at (nil: a fixed font, never rescaled)
    /// and the cache generation (fonts made before ``registerFonts(in:)`` are made again).
    private struct Made: Hashable {
        let spec: Spec
        let scale: CGFloat?
        let generation: Int
    }

    private static var cache: [Made: NSFont] = [:]
    /// Every font made here, by identity. Entries are never removed and the fonts stay alive
    /// (`retired` keeps the ones a cache clear dropped), so an identity is never reused.
    private static var made: [ObjectIdentifier: Made] = [:]
    private static var retired: [NSFont] = []
    private static var generation = 0
    private static let monoName = "JetBrainsMono-Regular"
    private static let displayName = "SpaceMono-Bold"
    /// OpenType axis tag `wght` as CoreText expects it (0x77676874).
    private static let weightAxis = NSNumber(value: 0x7767_6874)

    /// Body / UI mono font at the current zoom.
    public static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        font(Spec(display: false, size: size, weight: weight.rawValue), scale: UIZoom.scale)
    }

    /// Display font (page titles, pane title, brand): Space Mono 700, at the current zoom.
    public static func display(_ size: CGFloat) -> NSFont {
        font(Spec(display: true, size: size, weight: Weight.bold.rawValue), scale: UIZoom.scale)
    }

    /// Another face by PostScript name (Settings' PingFang TC page heads) at the current zoom,
    /// JetBrains Mono when it is missing. Follows the zoom like the CODD faces.
    public static func named(_ postScriptName: String, _ size: CGFloat) -> NSFont {
        font(Spec(display: false, size: size, weight: Weight.regular.rawValue, name: postScriptName), scale: UIZoom.scale)
    }

    /// JetBrains Mono at exactly `size`, whatever the zoom (terminal text, which has its own
    /// size setting and its own ⌘+ / ⌘− step). Never rescaled by ``current(_:)``.
    public static func fixed(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        font(Spec(display: false, size: size, weight: weight.rawValue), scale: nil)
    }

    /// The font for `spec` at `scale` (the current zoom when omitted).
    public static func font(_ spec: Spec, at scale: CGFloat? = nil) -> NSFont {
        font(spec, scale: scale ?? UIZoom.scale)
    }

    /// The design spec of a font made here (nil for any other font).
    public static func spec(of font: NSFont) -> Spec? {
        made[ObjectIdentifier(font)]?.spec
    }

    /// The zoom a font made here was made at (nil for a fixed font or any other font).
    public static func scale(of font: NSFont) -> CGFloat? {
        made[ObjectIdentifier(font)]?.scale
    }

    /// `font` at the current zoom: a font made here at another zoom (or before the bundled fonts
    /// were registered) is made again from its design spec; a fixed font or any other font is
    /// returned as is. Cheap when nothing changed (one dictionary lookup).
    public static func current(_ font: NSFont) -> NSFont {
        guard let info = made[ObjectIdentifier(font)], let madeScale = info.scale else { return font }
        let scale = UIZoom.scale
        if madeScale == scale, info.generation == generation { return font }
        return self.font(info.spec, scale: scale)
    }

    private static func font(_ spec: Spec, scale: CGFloat?) -> NSFont {
        let key = Made(spec: spec, scale: scale, generation: generation)
        if let cached = cache[key] { return cached }
        let size = spec.size * (scale ?? 1)
        // AppKit hands out one instance per identical descriptor (`mono(14)` and a zoomed
        // `mono(13)` would share one): a private attribute naming the key keeps every made font
        // its own instance, so its identity tells its design spec. It does not change rendering.
        let identity = "\(spec.display)|\(spec.size)|\(spec.weight)|\(spec.name ?? "")|\(scale.map { "\($0)" } ?? "fixed")|\(generation)"
        let created = spec.name.flatMap { named($0, size: size, identity: identity) }
            ?? make(display: spec.display, size: size, weight: spec.weight, identity: identity)
        cache[key] = created
        made[ObjectIdentifier(created)] = key
        return created
    }

    /// The private descriptor attribute that keeps made fonts apart (see `font(_:scale:)`).
    private static let identityAttribute = NSFontDescriptor.AttributeName("CODDTypefaceIdentity")

    private static func named(_ name: String, size: CGFloat, identity: String) -> NSFont? {
        // With only a name AppKit returns its shared instance; the cascade list (JetBrains Mono
        // for anything the face lacks) makes it build one from this descriptor.
        let descriptor = NSFontDescriptor(fontAttributes: [.name: name, identityAttribute: identity,
                                                           .cascadeList: [NSFontDescriptor(name: monoName, size: size)]])
        guard let font = NSFont(descriptor: descriptor, size: size), font.fontName == name else { return nil }
        return font
    }

    private static func make(display: Bool, size: CGFloat, weight: CGFloat, identity: String) -> NSFont {
        let cjkName = weight >= 600 ? "PingFangTC-Semibold" : (weight >= 500 ? "PingFangTC-Medium" : "PingFangTC-Regular")
        let cascade = [NSFontDescriptor(name: cjkName, size: size)]
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .name: display ? displayName : monoName,
            .cascadeList: cascade,
            identityAttribute: identity,
        ]
        if !display, weight != Weight.regular.rawValue {
            attributes[.variation] = [weightAxis: weight]
        }
        let descriptor = NSFontDescriptor(fontAttributes: attributes)
        if let font = NSFont(descriptor: descriptor, size: size), font.fontName.contains(display ? "SpaceMono" : "JetBrains") {
            return font
        }
        // Bundle fonts missing (should not happen): system mono with the same CJK cascade.
        let fallbackWeight: NSFont.Weight = weight >= 700 ? .bold : (weight >= 500 ? .medium : .regular)
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: fallbackWeight)
        let withCascade = system.fontDescriptor.addingAttributes([.cascadeList: cascade, identityAttribute: identity])
        return NSFont(descriptor: withCascade, size: size) ?? system
    }

    /// Drops the cache (fonts made before were fallbacks); made fonts stay alive and known, and
    /// ``current(_:)`` makes them again in the next generation.
    private static func clearCache() {
        retired.append(contentsOf: cache.values)
        cache.removeAll()
        generation += 1
    }

    /// Registers the bundled fonts for this process if ATS did not pick them up
    /// (e.g. when the bundle layout is unusual). Cheap no-op in the normal case.
    public static func registerBundledFontsIfNeeded() {
        guard NSFont(name: monoName, size: 12) == nil || NSFont(name: displayName, size: 12) == nil else { return }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let fonts = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
        clearCache()
    }

    /// Height of one text line for layout (ascender − descender + leading), rounded up.
    public static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

extension Typeface {
    /// Registers every `.ttf` / `.otf` in `directory` for this process (demos, galleries and tests;
    /// the app registers through `ATSApplicationFontsPath` and never calls this). Idempotent: a font
    /// that is already registered is skipped. Clears the font cache so later lookups see the fonts.
    /// Returns whether both CODD faces (JetBrains Mono, Space Mono Bold) resolve afterwards.
    @discardableResult
    public static func registerFonts(in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // kCTFontManagerErrorAlreadyRegistered (105) and duplicates are expected on repeat calls.
                _ = error?.takeRetainedValue()
            }
        }
        clearCache()
        return NSFont(name: monoName, size: 12) != nil && NSFont(name: displayName, size: 12) != nil
    }

    /// `text` with every font made here at another zoom made again at the current one, and the
    /// lengths that go with the type (letter spacing, fixed line heights, paragraph spacing and
    /// indents, baseline offsets) multiplied by the same ratio. nil when nothing changed (no font
    /// of this enum, or all already current): labels and buttons set early follow a zoom change.
    public static func rescaled(_ text: NSAttributedString) -> NSAttributedString? {
        guard text.length > 0 else { return nil }
        let whole = NSRange(location: 0, length: text.length)
        var ratio: CGFloat?
        var fonts: [(NSRange, NSFont)] = []
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let now = current(font)
            guard now !== font else { return }
            fonts.append((range, now))
            if ratio == nil, font.pointSize > 0 { ratio = now.pointSize / font.pointSize }
        }
        guard !fonts.isEmpty else { return nil }
        let out = NSMutableAttributedString(attributedString: text)
        for (range, font) in fonts { out.addAttribute(.font, value: font, range: range) }
        if let ratio, ratio != 1 { scaleTypeLengths(in: out, by: ratio) }
        return out
    }

    /// Multiplies kern, baseline offsets and paragraph lengths in `text` by `ratio`.
    static func scaleTypeLengths(in text: NSMutableAttributedString, by ratio: CGFloat) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.kern, in: whole) { value, range, _ in
            guard let kern = (value as? NSNumber).map({ CGFloat($0.doubleValue) }), kern != 0 else { return }
            text.addAttribute(.kern, value: kern * ratio, range: range)
        }
        text.enumerateAttribute(.baselineOffset, in: whole) { value, range, _ in
            guard let offset = (value as? NSNumber).map({ CGFloat($0.doubleValue) }), offset != 0 else { return }
            text.addAttribute(.baselineOffset, value: offset * ratio, range: range)
        }
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let scaled = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            scaled.minimumLineHeight = style.minimumLineHeight * ratio
            scaled.maximumLineHeight = style.maximumLineHeight * ratio
            scaled.lineSpacing = style.lineSpacing * ratio
            scaled.paragraphSpacing = style.paragraphSpacing * ratio
            scaled.paragraphSpacingBefore = style.paragraphSpacingBefore * ratio
            scaled.firstLineHeadIndent = style.firstLineHeadIndent * ratio
            scaled.headIndent = style.headIndent * ratio
            if style.tailIndent != 0 { scaled.tailIndent = style.tailIndent * ratio }
            text.addAttribute(.paragraphStyle, value: scaled, range: range)
        }
    }
}
