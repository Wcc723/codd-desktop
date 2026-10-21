import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import CoddNotes

/// A temp folder per test: `<tmp>/codd-notes-tests-<uuid>/{data/notes, data/notes-index.sqlite,
/// data/cache/annotated, trash}`.
final class TempRoot: Sendable {
    let base: URL
    var data: URL { base.appendingPathComponent("data", isDirectory: true) }
    var notes: URL { data.appendingPathComponent("notes", isDirectory: true) }
    var index: URL { data.appendingPathComponent("notes-index.sqlite") }
    /// Where the library writes burned-in annotated copies (the app: `<dataRoot>/cache/annotated`).
    var annotated: URL { data.appendingPathComponent("cache/annotated", isDirectory: true) }
    var trash: URL { base.appendingPathComponent("trash", isDirectory: true) }

    init() {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("codd-notes-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        base = FileFacts.realPath(raw)
        try! FileManager.default.createDirectory(at: base.appendingPathComponent("data/notes"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: base.appendingPathComponent("trash"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func write(_ rel: String, _ text: String) {
        let u = notes.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: u)
    }

    func read(_ rel: String) -> String {
        String(decoding: (try? Data(contentsOf: notes.appendingPathComponent(rel))) ?? Data(), as: UTF8.self)
    }

    func exists(_ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: notes.appendingPathComponent(rel).path)
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let now: Mutex<Date>
    init(_ start: Date) { now = Mutex(start) }
    var date: Date { now.withLock { $0 } }
    func advance(days: Double = 0, hours: Double = 0, minutes: Double = 0, seconds: Double = 0) {
        now.withLock { $0 = $0.addingTimeInterval(days * 86_400 + hours * 3600 + minutes * 60 + seconds) }
    }
    func set(_ d: Date) { now.withLock { $0 = d } }
    var closure: @Sendable () -> Date { { [self] in date } }
}

/// What the injected trash function received.
final class TrashRecorder: Sendable {
    let folder: URL
    private let moved = Mutex<[String]>([])
    init(folder: URL) { self.folder = folder }
    var items: [String] { moved.withLock { $0 } }
    var closure: @Sendable (URL) throws -> Void {
        { [self] url in
            let dest = folder.appendingPathComponent("\(items.count)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
            moved.withLock { $0.append(url.path) }
        }
    }
}

let taipei = TimeZone(identifier: "Asia/Taipei")!

func iso(_ s: String) -> Date { ISODate.parse(s, timeZone: taipei)! }

func makeLibrary(_ root: TempRoot, clock: ManualClock? = nil, policy: RetentionPolicy = .defaults,
                 defaultAccess: NoteAIAccess = .read, trash: TrashRecorder? = nil) -> NotesLibrary {
    let c = clock ?? ManualClock(iso("2026-10-15T10:05:44+08:00"))
    let t = trash ?? TrashRecorder(folder: root.trash)
    let move = t.closure
    // The trash closure holds the temp root, so the folder lives exactly as long as the library.
    return NotesLibrary(root: root.notes, indexURL: root.index, annotatedFolder: root.annotated, policy: policy, defaultAccess: defaultAccess,
                        clock: c.closure, trash: { [root] url in
                            _ = root
                            try move(url)
                        }, timeZone: taipei)
}

/// The SPEC §5 n1 note (design data), as §3.2 shows it.
func specNote1(withAnnotations: Bool = true) -> String {
    var s = """
    ---
    id: rwd-punch-k7x2
    title: 打卡頁 RWD 跑版紀錄
    kind: note
    tags: [rwd, punch]
    sessions: [7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10]
    projects: [~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend]
    ai: read
    scope: project
    pinned: false
    status: active
    created: 2026-10-14T18:20:11+08:00
    updated: 2026-10-15T10:05:44+08:00
    ---
    # 打卡頁 RWD 跑版紀錄

    ## 問題
    iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。

    ![截圖 2026-10-15 09:32 · iPhone SE](assets/rwd-punch-k7x2/9f3a1c.png)

    """
    if withAnnotations {
        s += "```codd-annotations\n" + specAnnotationsJSON + "\n```\n"
    }
    s += """

    ## 想請 AI 做的
    - [x] 先重現（Chrome DevTools 375 寬）
    - [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`
    - [ ] 表格改卡片式（<640px）

    ```css
    @media (max-width: 640px) { .punch-table { display: block; } }
    ```

    """
    return s
}

let specAnnotationsJSON = """
{"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[{"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},{"n":2,"type":"point","x":375,"y":330,"note":"時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},{"n":3,"type":"arrow","x":600,"y":760,"x2":700,"y2":1080,"note":"打卡紀錄卡片離按鈕太近，間距加到 16px"}],"send":{"original":false,"annotated":true,"list":true}}
"""

/// A generated PNG (no fixtures from the machine): a gradient with a blue band, optionally with alpha.
func makeImage(width: Int, height: Int, type: String = UTType.png.identifier, alpha: Bool = false, quality: Double = 0.9) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: alpha ? 0.5 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height / 10, width: width, height: height / 10))
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: width / 4, y: height / 2, width: width / 2, height: height / 6))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return out as Data
}

/// Random pixels: a PNG that cannot compress.
func makeNoise(width: Int, height: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for k in 0..<(width * height) {
        let v = rng.next()
        bytes[k * 4] = UInt8(truncatingIfNeeded: v)
        bytes[k * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[k * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
    return out as Data
}

func pixelSize(_ data: Data) -> CGSize {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    return CGSize(width: (p[kCGImagePropertyPixelWidth] as! NSNumber).intValue, height: (p[kCGImagePropertyPixelHeight] as! NSNumber).intValue)
}

func imageType(_ data: Data) -> String? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
}

/// Waits (polling every 20 ms) until `condition` holds or `timeout` passes.
func waitUntil(timeout: Double = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Collects `changes` in the background.
final class ChangeCollector: Sendable {
    private let seen = Mutex<[NotesChange]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ library: NotesLibrary) {
        let stream = library.changes
        let t = Task { [weak self] in
            for await c in stream { self?.seen.withLock { $0.append(c) } }
        }
        task.withLock { $0 = t }
    }

    var all: [NotesChange] { seen.withLock { $0 } }

    func externalIDs() -> [NoteID] {
        all.flatMap { if case .external(let ids) = $0 { return ids } else { return [] } }
    }

    func changedIDs() -> [NoteID] {
        all.flatMap { if case .changed(let ids) = $0 { return ids } else { return [] } }
    }

    func removedIDs() -> [NoteID] {
        all.flatMap { if case .removed(let ids) = $0 { return ids } else { return [] } }
    }

    func cancel() { task.withLock { $0?.cancel() } }
}

extension NoteID {
    static func of(_ s: String) -> NoteID { NoteID(rawValue: s)! }
}
