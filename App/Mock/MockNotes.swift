import AppKit
import CoddAnnotateUI
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// D35 (notes part): mock mode's notebook is a temporary folder (`$TMPDIR/codd-mock-notes-<pid>`,
/// removed at quit) seeded with the SPEC §5 notes n1–n7, the generated 750 × 1334 placeholder
/// screenshot of n1 with the three R6 annotations, its AI activity and HISTORY, so
/// `-codd-mock -codd-show notebook` snapshots compare with the Notebook artboard. Made-up design
/// data; nothing here reads or writes outside that folder.
@MainActor
enum MockNotes {
    nonisolated static let folderPrefix = "codd-mock-notes-"

    /// `$TMPDIR/codd-mock-notes-<pid>`.
    static func folder(pid: Int32 = getpid()) -> URL {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp, isDirectory: true).appendingPathComponent("\(folderPrefix)\(pid)", isDirectory: true)
    }

    static let timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    /// Writes the seed (once) off the main actor; the placeholder images are drawn here first.
    static func seed(into folder: URL) async {
        let portrait = pngData(ImageAnnotateSamples.placeholderImage())
        let landscape = pngData(landscapePlaceholder())
        let files = seedFiles(now: MockData.referenceDate, portrait: portrait, landscape: landscape)
        await Task.detached(priority: .userInitiated) {
            removeStaleFolders(besides: folder)
            write(files, into: folder)
        }.value
    }

    /// Removes the folder (at quit).
    nonisolated static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Mock folders of CODD runs that are gone (a crash skips the quit cleanup).
    nonisolated static func removeStaleFolders(besides keep: URL) {
        let parent = keep.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) && name != keep.lastPathComponent {
            guard let pid = Int32(name.dropFirst(folderPrefix.count)), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    struct SeedFile: Sendable {
        var path: String
        var data: Data
        var modified: Date?
    }

    nonisolated static func write(_ files: [SeedFile], into folder: URL) {
        let manager = FileManager.default
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            guard !manager.fileExists(atPath: url.path) else { continue }
            manager.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600])
            if let modified = file.modified { try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
    }

    // MARK: Content (SPEC §5)

    static let n1ID = "rwd-punch-k7x2"
    static let frontend = "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend"
    static let backend = "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend"
    static let mcp = "~/Project/Northstar/lab/agent-lab-2026/整合範例/MCP"
    static let gear = "~/Github/Gear3D"

    static let n1Annotations = """
    {"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[\
    {"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},\
    {"n":2,"type":"point","x":375,"y":330,"note":"時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},\
    {"n":3,"type":"arrow","x":600,"y":760,"x2":700,"y2":1080,"note":"打卡紀錄卡片離按鈕太近，間距加到 16px"}],\
    "send":{"original":false,"annotated":true,"list":true}}
    """

    static func n1Body(final: Bool) -> String {
        var body = """
        # 打卡頁 RWD 跑版紀錄

        ## 問題
        iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。

        - 影響頁面：`/punch`（打卡）與 `/punch/history`（打卡紀錄表格）
        - **Safari 底部工具列展開時**才會完全蓋住，收起後還露出上半截

        ![截圖 2026-10-15 09:32 · iPhone SE](assets/rwd-punch-k7x2/9f3a1c.png)
        ```codd-annotations
        \(n1Annotations)
        ```

        ## 想請 AI 做的
        - [x] 先重現（Chrome DevTools 375 寬）
        - [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`

        """
        if final {
            body += """
            - [ ] 表格改卡片式（<640px）

            ```css
            @media (max-width: 640px) {
              .punch-table { display: block; }
            }
            ```

            """
        }
        return body
    }

    struct Note {
        var file: String
        var id: String
        var title: String
        var kind: String
        var tags: [String] = []
        var sessions: [String] = []
        var projects: [String] = []
        var ai = "read"
        var pinned = false
        var created: Date
        var updated: Date
        var sent: Date?
        var sentTo: String?
        var body: String
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func text(_ note: Note) -> String {
        var lines = ["---", "id: \(note.id)", "title: \(note.title)", "kind: \(note.kind)", "tags: [\(note.tags.joined(separator: ", "))]"]
        if !note.sessions.isEmpty { lines.append("sessions: [\(note.sessions.joined(separator: ", "))]") }
        if !note.projects.isEmpty { lines.append("projects: [\(note.projects.joined(separator: ", "))]") }
        lines.append("ai: \(note.ai)")
        lines.append("scope: \(note.projects.isEmpty && note.sessions.isEmpty ? "global" : "project")")
        lines.append("pinned: \(note.pinned)")
        lines.append("status: active")
        if let sent = note.sent { lines.append("sent: \(iso(sent))") }
        if let sentTo = note.sentTo { lines.append("sentTo: \(sentTo)") }
        lines.append("created: \(iso(note.created))")
        lines.append("updated: \(iso(note.updated))")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + note.body
    }

    static func notes(now: Date) -> [Note] {
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        return [
            Note(file: "2026-10-15-打卡頁-rwd-跑版紀錄.md", id: n1ID, title: "打卡頁 RWD 跑版紀錄", kind: "note", tags: ["rwd", "punch"],
                 sessions: ["s9"], projects: [frontend], created: at(-1, 18, 20), updated: at(0, 10, 5), body: n1Body(final: true)),
            // The Split artboard's second drawer card (s9's linked notes: n1 and this one).
            Note(file: "2026-10-14-打卡頁-qa-清單.md", id: "punch-qa-m4n2", title: "打卡頁 QA 清單", kind: "note", tags: ["qa", "punch"],
                 sessions: ["s9"], projects: [frontend], created: at(-1, 16, 40), updated: at(-1, 17, 5),
                 body: "# 打卡頁 QA 清單\n\n- [ ] iPhone SE 直向：按鈕不被導覽列蓋住\n- [ ] iPhone SE 橫向：紀錄不需橫向捲動\n"
                     + "- [x] iPad mini（768 寬）維持表格版面\n"),
            Note(file: "2026-10-15-給後端的-prompt-401-修正條件.md", id: "prompt-401-b3m9", title: "給後端的 prompt：401 修正條件",
                 kind: "prompt", sessions: ["s1"], projects: [backend], created: at(0, 9, 50), updated: at(0, 10, 2), sent: at(0, 10, 2),
                 sentTo: "s1", body: "# 給後端的 prompt：401 修正條件\n\ntoken 過期先走 refresh，失敗才回 401 並帶 code: EXPIRED；補 auth.spec.ts 三種情境的測試。\n"),
            Note(file: "2026-10-14-mcp-示範腳本重點.md", id: "mcp-demo-r8q1", title: "MCP 示範腳本重點", kind: "note", tags: ["mcp"],
                 projects: [mcp], pinned: true, created: at(-1, 16, 0), updated: at(0, 9, 40),
                 body: "# MCP 示範腳本重點\n\n開場先示範 claude mcp add，再連 codd server 讀筆記；示範前關掉通知，帳號切到 #2 藍鵲。\n"),
            Note(file: "2026-10-15-程式碼審查標準-v2.md", id: "v2-review-h4n6", title: "程式碼審查標準 v2", kind: "note",
                 sessions: ["s6"], created: at(0, 8, 30), updated: at(0, 9, 12),
                 body: "# 程式碼審查標準 v2\n\n四個面向：需求理解、錯誤處理、驗證方式、文件。v1 的「程式碼風格」拿掉。\n"),
            Note(file: "2026-10-15-隨手記-10-15.md", id: "quick-scratch-s5c2", title: "隨手記 10/15", kind: "scratch", ai: "off",
                 created: at(0, 8, 47), updated: at(0, 8, 47),
                 body: "# 隨手記 10/15\n\n#3 本週額度只剩 15%，重的工作先改用 #2 藍鵲；下午記得回頭看 Gear3D 那個卡住的 session。\n"),
            Note(file: "2026-10-14-keynote-第-3-章大綱.md", id: "keynote-p6d1", title: "keynote 第 3 章大綱", kind: "prompt",
                 sessions: ["s11"], created: at(-1, 20, 10), updated: at(-1, 21, 30),
                 body: "# keynote 第 3 章大綱\n\n3-1 為什麼要同時開多個 session · 3-2 NEEDS YOU 與狀態燈 · 3-3 筆記怎麼交給 AI。\n"),
            Note(file: "2026-09-24-gear3d-載入效能想法.md", id: "gear3d-n7q0", title: "Gear3D 載入效能想法", kind: "note", tags: ["perf"],
                 projects: [gear], created: at(-22, 14, 0), updated: at(-21, 15, 30),
                 body: "# Gear3D 載入效能想法\n\n場景第一次載入要 6 秒：先量 GLTF 解析與貼圖上傳，再試 KTX2 壓縮與分批載入。\n"),
        ]
    }

    static func seedFiles(now: Date, portrait: Data, landscape: Data) -> [SeedFile] {
        var files: [SeedFile] = []
        let created = iso(now)
        files.append(SeedFile(path: "notes/.codd/notebook.json", data: Data("{\"v\":1,\"createdAt\":\"\(created)\"}\n".utf8)))
        let all = notes(now: now)
        for note in all {
            files.append(SeedFile(path: "notes/" + note.file, data: Data(text(note).utf8), modified: note.updated))
        }
        files.append(SeedFile(path: "notes/assets/\(n1ID)/9f3a1c.png", data: portrait, modified: all[0].created))
        files.append(SeedFile(path: "notes/assets/\(n1ID)/2b7e04.png", data: landscape, modified: all[0].created))
        // AI ACTIVITY (`打卡頁 RWD 調整 讀取 · 10:12`).
        let read = all[0].updated.addingTimeInterval(7 * 60)
        let activity = "{\"v\":1,\"at\":\"\(iso(read))\",\"note\":\"\(n1ID)\",\"action\":\"read\",\"client\":\"Claude Code\","
            + "\"session\":\"s9\",\"sessionTitle\":\"打卡頁 RWD 調整\",\"via\":\"mcp\"}\n"
        files.append(SeedFile(path: "notes/.codd/activity.jsonl", data: Data(activity.utf8)))
        // HISTORY: 昨天 18:20 (建立) · 09:41 · 10:05 (目前).
        var n1 = all[0]
        let versions: [(Date, String)] = [(n1.created, n1Body(final: false)), (n1.updated.addingTimeInterval(-24 * 60), n1Body(final: false) + "\n"),
                                          (n1.updated, n1Body(final: true))]
        for (date, body) in versions {
            n1.body = body
            let data = Data(text(n1).utf8)
            let hash8 = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
            files.append(SeedFile(path: "notes/.codd/history/\(n1ID)/\(compactUTC(date))-\(hash8).md", data: data))
        }
        return files
    }

    /// `yyyyMMdd-HHmmss-SSS` in UTC (C1's snapshot names).
    static func compactUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    // MARK: Images

    static func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// The artboard's second thumbnail (`2b7e04.png`): a landscape table that overflows.
    static func landscapePlaceholder() -> CGImage {
        let width = 1334
        let height = 750
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return ImageAnnotateSamples.placeholderImage()
        }
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.18, green: 0.44, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 90, width: width, height: 90))
        context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.79, alpha: 1))
        for row in 0..<8 {
            context.fill(CGRect(x: 40, y: height - 150 - row * 70, width: width + 200, height: 44))
        }
        return context.makeImage() ?? ImageAnnotateSamples.placeholderImage()
    }
}
