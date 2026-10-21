import AppKit
import CoddUI

/// The SPEC §5 sample data in each dialog's states, for the demo, tests and the app's
/// `-codd-mock -codd-show dialog-…` snapshots. Times are relative to `now`.
@MainActor
public enum DialogSamples {
    // MARK: A

    public static func switchAccount(now: Date) -> SwitchAccountModel {
        let from = DialogAccount(slot: "#3", alias: "工作", plan: "MAX 20x",
                                 fiveHourRemaining: 91, fiveHourTone: .ok, weeklyRemaining: 15, weeklyTone: .crit,
                                 reset: "1w 重置 10/18 12:00", resetsAt: now.addingTimeInterval(3 * 86_400 + 3_600 + 30),
                                 source: "statusline", sourceAt: now.addingTimeInterval(-12), chips: [.active])
        let to = DialogAccount(slot: "#2", alias: "藍鵲", plan: "MAX 20x",
                               fiveHourRemaining: 98, fiveHourTone: .ok, weeklyRemaining: 46, weeklyTone: .warn,
                               reset: "1w 重置 10/16 22:59", source: "cswap cache", sourceAt: now.addingTimeInterval(-180),
                               chips: [.pinned(1)])
        return SwitchAccountModel(from: from, to: to, followingCount: 12, pinnedTitles: ["現場示範：連線 MCP"],
                                  autoSwitchOn: false, cswapVersion: "cswap 0.26.0")
    }

    public static func switchAccountSwitching(now: Date) -> SwitchAccountModel {
        var model = switchAccount(now: now)
        model.progress = SwitchProgress(attempt: 1, of: 3, since: now.addingTimeInterval(-9))
        return model
    }

    public static func switchAccountFailed(now: Date) -> SwitchAccountModel {
        var model = switchAccount(now: now)
        model.error = "ClaudeCodeLockTimeout · Claude Code 的 credential lock 一直被佔用（已試 3 次）"
        return model
    }

    // MARK: B

    public static func hookDiff() -> HookDiffModel {
        let command = "      \"command\": \"[ -z \\\"$CODD_TERMINAL_ID\\\" ] || … status-writer.js'\" }] }]"
        var lines: [DiffLineModel] = [
            DiffLineModel(.hunk, text: "@@ -38,5 +38,13 @@  \"hooks\""),
            DiffLineModel(.context, oldNumber: 38, newNumber: 38, text: "    \"StopFailure\": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5, … }] }],"),
            DiffLineModel(.context, oldNumber: 39, newNumber: 39, text: "    \"SessionEnd\": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5,"),
            DiffLineModel(.removed, oldNumber: 40, text: command),
            DiffLineModel(.added, newNumber: 40, text: command + ","),
        ]
        var number = 41
        for (index, event) in ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"].enumerated() {
            lines.append(DiffLineModel(.added, newNumber: number, text: "    \"\(event)\": [{ \"hooks\": [{ \"type\": \"command\", \"timeout\": 5,",
                                       emphasis: ["\"\(event)\""]))
            lines.append(DiffLineModel(.added, newNumber: number + 1, text: command + (index < 3 ? "," : "")))
            number += 2
        }
        lines.append(DiffLineModel(.context, oldNumber: 41, newNumber: 49, text: "  },"))
        lines.append(DiffLineModel(.context, oldNumber: 42, newNumber: 50, text: "  \"statusLine\": { \"type\": \"command\", \"command\": \"… codd-statusline.js …\" }"))
        return HookDiffModel(settingsPath: "~/.claude/settings.json",
                             chips: ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"].map { DiffChip("+ \($0)", kind: .added) },
                             lines: lines, added: 9, removed: 1, foreignKept: "hook-tap ×11 · osascript ×2",
                             backupPath: "~/.claude/settings.json.codd-bak-20261015-104210")
    }

    public static func hookDiffNoChanges() -> HookDiffModel {
        HookDiffModel(settingsPath: "~/.claude/settings.json", summary: ["hooks 與 statusLine 已是 CODD Desktop 的設定"],
                      lines: [], added: 0, removed: 0, foreignKept: "hook-tap ×11 · osascript ×2")
    }

    public static func hookDiffError() -> HookDiffModel {
        var model = hookDiff()
        model.canApply = false
        model.error = "settings.json 在預覽後被修改，請關閉後重新預覽"
        return model
    }

    // MARK: C

    public static func addAccountStep1() -> AddAccountModel {
        AddAccountModel(slots: [4, 5], slot: 4, previousActive: "#3 工作", cswapVersion: "cswap 0.26.0")
    }

    public static func addAccountStep2(now: Date) -> AddAccountModel {
        var model = addAccountStep1()
        model.step1Done = now.addingTimeInterval(-60)
        return model
    }

    public static func addAccountStep3(now: Date, alias: String = "") -> AddAccountModel {
        var model = addAccountStep2(now: now)
        model.detected = .newAccount(plan: "MAX 20x")
        model.alias = alias
        return model
    }

    public static func addAccountExisting(now: Date) -> AddAccountModel {
        var model = addAccountStep2(now: now)
        model.detected = DetectedLogin(isNew: false, text: "#2 藍鵲", plan: "MAX 20x")
        model.alias = "north"
        return model
    }

    public static func addAccountFailed(now: Date) -> AddAccountModel {
        var model = addAccountStep3(now: now, alias: "studio")
        model.error = "cswap add 失敗：slot 4 已被使用"
        return model
    }

    // MARK: D

    public static func quit(now: Date) -> QuitModel {
        QuitModel(running: 13, needs: 3, rows: [
            DialogSessionRow(id: "s1", glyph: "◆", color: Palette.amber, tag: NSColor(hex: 0xEF5B5B), title: "修正登入 API 401",
                             pill: "Perm", pillFilled: true, since: now.addingTimeInterval(-180), location: "藍鵲·網站 / orb-toolkit-backend"),
            DialogSessionRow(id: "s2", glyph: "◆", color: Palette.amber, title: "發票匯出 CSV", pill: "Ask", pillFilled: true,
                             since: now.addingTimeInterval(-720), location: "藍鵲·網站 / Northstar invoice system"),
            DialogSessionRow(id: "s3", glyph: "▲", color: Palette.danger, tag: NSColor(hex: 0xE6C84E), title: "場景載入優化",
                             pill: "Error", pillFilled: false, since: now.addingTimeInterval(-60), location: "overloaded · 個人·Github / Gear3D"),
        ], stoppable: 12)
    }

    public static func quitNoNeeds() -> QuitModel {
        QuitModel(running: 13, needs: 0, rows: [], stoppable: 12)
    }
}

/// Offscreen rendering for the demo and tests: an sRGB bitmap at 2x (cacheDisplay draws every
/// view's `draw`; layer shadows such as the current step's glow are not included).
@MainActor
public enum DialogSnapshot {
    public static func sRGBBitmap(for size: NSSize, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
        rep?.size = size
        return rep
    }

    /// Renders `view` (laid out at its fitting size) to PNG data.
    public static func png(of view: NSView) -> Data? {
        guard let rep = sRGBBitmap(for: view.bounds.size) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
