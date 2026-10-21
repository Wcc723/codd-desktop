import Foundation
import CoddUI

// M5 D21: what VoiceOver says for the parts CODD draws as glyph + color (SPEC §3). A lamp, a state
// pill or an aggregate badge is never only a color: each one is spoken as text, in 繁體中文, with
// English kept for the names Claude Code itself shows (tool names, error kinds, `EXT`).

extension StateStyle {
    /// A state's spoken name (`等待中`, `工作中`, …).
    static func spokenName(_ state: SessionState) -> String {
        switch state {
        case .waiting: "等待中"
        case .error: "錯誤"
        case .done: "完成"
        case .busy: "工作中"
        case .compacting: "壓縮中"
        case .idle: "閒置"
        case .starting: "啟動中"
        case .unknown: "執行中"
        case .shell: "Shell"
        case .exited: "已結束"
        case .stopped: "已停止"
        }
    }

    /// D8's overlay (`UNREACHABLE`).
    static let unreachableSpokenName = "無法連線"
}

extension WaitingReason {
    /// `權限`, `提問`, `計畫`, `等待輸入`.
    var spokenName: String {
        switch self {
        case .permission: "權限"
        case .question: "提問"
        case .plan: "計畫"
        case .other: "等待輸入"
        }
    }
}

extension TagColor {
    /// The tag's color name (`標籤：紅`): the 8 px square is the only place a tag shows.
    var spokenName: String {
        switch self {
        case .red: "紅"
        case .blue: "藍"
        case .green: "綠"
        case .yellow: "黃"
        case .purple: "紫"
        case .orange: "橘"
        case .pink: "粉紅"
        case .cyan: "青"
        }
    }
}

/// Durations as VoiceOver reads them: `12 秒`, `3 分鐘`, `1 小時 5 分鐘`, `2 天 3 小時`. Minutes
/// from one minute on (a spoken label is read once, a ticking second would only be noise).
enum SpokenDuration {
    static func text(_ interval: TimeInterval) -> String {
        let bounded = interval.isFinite ? min(max(interval, 0), 1e9) : 0
        let total = Int(bounded.rounded(.down))
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分鐘" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小時" : "\(hours) 小時 \(rest) 分鐘"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days) 天" : "\(days) 天 \(rest) 小時"
    }
}

/// Spoken text for sessions (lamps, rows, headers) and state tallies.
@MainActor
enum SessionSpeech {
    /// The lamp's description: `等待中 · 權限 · 3 分鐘`, `工作中 · Edit · 6 分鐘`, `已停止 · 可接續`.
    static func state(_ session: SessionVM, now: Date) -> String {
        let since = session.unreachableSince ?? session.stateSince
        let duration = SpokenDuration.text(now.timeIntervalSince(since))
        if session.unreachableSince != nil {
            return [StateStyle.unreachableSpokenName, "holder 無回應", duration].joined(separator: " · ")
        }
        let name = StateStyle.spokenName(session.state)
        var parts: [String?]
        switch session.state {
        case .waiting: parts = [name, session.waitingReason?.spokenName, duration]
        case .error: parts = [name, session.errorReason, duration]
        case .busy: parts = [name, session.tool, duration]
        case .shell: parts = [name, session.detail ?? "zsh"]
        case .exited: parts = [name, "結束碼 \(session.exitCode ?? 0)", duration + "前"]
        case .stopped: parts = [name, "可接續"]
        // An external without a registry status has no hooks to miss.
        case .unknown: parts = session.external ? [name, duration] : [name, "沒有 hook 資料", duration]
        case .done, .compacting, .idle, .starting: parts = [name, duration]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A state for a lamp that has no session behind it (an aggregate, a sample row).
    static func state(_ state: SessionState) -> String { StateStyle.spokenName(state) }

    /// The badges a row draws, spoken: tag, `EXT`, the account chip, `stale`, Remote Control.
    static func badges(_ session: SessionVM, accountChip: String?) -> [String] {
        var badges: [String] = []
        if let tag = session.tag { badges.append("標籤：\(tag.spokenName)") }
        if session.external { badges.append("EXT 外部 session") }
        if let accountChip { badges.append("帳號 \(accountChip)") }
        if session.isStale { badges.append("stale，閒置超過 1 小時") }
        if session.remoteControl { badges.append("Remote Control 已連線") }
        return badges
    }

    /// One session row as one element: `修正登入 API 401，等待中 · 權限 · 3 分鐘，標籤：紅`.
    static func row(_ session: SessionVM, accountChip: String?, now: Date) -> String {
        ([session.title, state(session, now: now)] + badges(session, accountChip: accountChip)).joined(separator: "，")
    }

    /// An aggregate badge run (`◆2 ●1 $1`): `等待中 2、工作中 1、Shell 1`.
    static func tally(_ counts: [(SessionState, Int)]) -> String {
        counts.map { "\(StateStyle.spokenName($0.0)) \($0.1)" }.joined(separator: "、")
    }
}
