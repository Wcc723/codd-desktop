import Foundation

extension NotesLibrary {
    /// D29, run at launch, every 24 h and after a CLEANUP setting changes: archives what is due
    /// (`archivedBy: auto`), purges trash older than `trashPurgeDays` through the injected trash
    /// function (note file, its assets and history) with a tombstone, expires tombstones, thins
    /// history. Every automatic move is logged.
    public func runRetention(liveSessions: Set<String>) async -> RetentionReport {
        setLiveSessions(liveSessions)
        guard let index, let rows = try? index.rows(where: "1") else { return RetentionReport() }
        let now = clock()
        var report = RetentionReport()
        for r in rows where r.isActive {
            let l = lifecycle(r, now: now)
            if let due = l.archivesAt, due <= now {
                if archiveAutomatically(r, now: now) { report.archived.append(r.id) }
            } else if l.staleSince != nil {
                report.staleIDs.append(r.id)
            }
            await Task.yield()
        }
        for r in rows where r.isTrashed {
            if let due = lifecycle(r, now: now).purgeAt, due <= now, purge(r, now: now) { report.purged.append(r.id) }
        }
        if tombstones.expire(days: policy.tombstoneDays, now: now) { flushTombstones() }
        for id in historyStore.noteIDs() {
            report.snapshotsRemoved += historyStore.thin(id, now: now, calendar: calendar)
        }
        log("retention notes stale=\(report.staleIDs.count) archived=\(report.archived.count) purged=\(report.purged.count) snapshots=\(report.snapshotsRemoved)")
        if !report.archived.isEmpty { channel.yield(.changed(report.archived)) }
        if !report.purged.isEmpty { channel.yield(.removed(report.purged)) }
        return report
    }

    private func archiveAutomatically(_ r: IndexRow, now: Date) -> Bool {
        do {
            let (row, parsed, _) = try load(r.id)
            var fm = try editableFrontmatter(row, parsed)
            fm.set("status", scalar: "archived")
            fm.set("archived", scalar: iso(now))
            fm.set("archivedBy", scalar: ArchiveReason.auto.rawValue)
            try commit(row, text: NoteFile.compose(frontmatter: fm, body: parsed.body, lineEnding: parsed.lineEnding), updatedHint: row.updated)
            log("retention archive id=\(r.id.rawValue)")
            return true
        } catch {
            log("retention archive skipped id=\(r.id.rawValue): \(error)")
            return false
        }
    }

    /// TRASH → 永久刪除 now (the TRASH list), the same way the retention purge does it.
    public func purge(_ ids: [NoteID]) async throws {
        let now = clock()
        var done: [NoteID] = []
        for id in ids {
            let row = try requireRow(id)
            guard row.isTrashed else { continue }
            if purge(row, now: now) { done.append(id) }
        }
        if !done.isEmpty { channel.yield(.removed(done)) }
    }

    /// Moves the note file, `assets/<id>/` (trash and live) and `.codd/history/<id>/` through the
    /// injected trash function and keeps a tombstone. False (nothing removed from the index) when
    /// the note file itself could not be moved.
    func purge(_ r: IndexRow, now: Date) -> Bool {
        let fm = FileManager.default
        let file = url(r.path)
        if fm.fileExists(atPath: file.path) {
            do {
                try trashItem(file)
            } catch {
                log("retention purge failed id=\(r.id.rawValue): \(error)")
                return false
            }
        }
        for folder in [assetFolder(r.id, trashed: true), assetFolder(r.id, trashed: false), historyStore.folder(r.id)]
            where fm.fileExists(atPath: folder.path) {
            do {
                try trashItem(folder)
            } catch {
                log("retention purge folder failed id=\(r.id.rawValue) name=\(folder.lastPathComponent): \(error)")
            }
        }
        try? index?.delete(paths: [r.path])
        state.remove(r.id)
        touchState()
        activityLog.remove(r.id)
        tombstones.add(Tombstone(id: r.id, title: r.title, trashedAt: Date(timeIntervalSince1970: r.trashed ?? r.mtime), purgedAt: now))
        flushTombstones()
        log("retention purge id=\(r.id.rawValue)")
        return true
    }

    func flushTombstones() {
        do {
            try tombstones.flush(writer: writer)
        } catch {
            log("notes tombstones write failed: \(error)")
        }
    }

    /// §3.4 long-note rule / D32 condense input: the note's H2 / H3 sections whose heading date is
    /// more than `olderThanDays` days old, in body order.
    public func datedSections(_ id: NoteID, olderThanDays: Int) async throws -> [NoteSection] {
        let doc = try await document(id)
        let now = clock()
        let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        return DatedSections.sections(in: doc.body, now: now, calendar: calendar).filter { ($0.date ?? now) < cutoff }
    }

    /// The Cleanup page's NOTES rows (and unused images for FILES), texts as on the artboard.
    public func cleanupCandidates(liveSessions: Set<String>) async -> [NoteCleanupCandidate] {
        setLiveSessions(liveSessions)
        guard let index, let rows = try? index.rows(where: "status = 'active'", withBody: true) else { return [] }
        let now = clock()
        var byNote: [NoteID: (priority: Int, candidate: NoteCleanupCandidate)] = [:]
        func offer(_ c: NoteCleanupCandidate, priority: Int) {
            if let existing = byNote[c.id], existing.priority <= priority { return }
            byNote[c.id] = (priority, c)
        }
        let candidatesRows = rows.filter { (state[$0.id].keepUntil ?? .distantPast) <= now }
        for r in candidatesRows {
            let l = lifecycle(r, now: now)
            guard l.exempt == nil else { continue }
            let hint = aiHint(r.id, now: now)
            if r.kind == .scratch, let due = l.archivesAt {
                let left = Self.daysLeft(now, due)
                offer(NoteCleanupCandidate(
                    id: r.id, reason: .scratch(days: left), title: r.title, why: "SCRATCH",
                    sub: "快速筆記 \(policy.scratchArchiveDays ?? 7) 天後自動封存", badge: "archives in \(left)d", aiHint: hint,
                    suggestsCondense: false), priority: 0)
            } else if r.kind == .prompt, let sent = r.sent, let due = l.archivesAt {
                let since = LocalCalendar.days(from: Date(timeIntervalSince1970: sent), to: now)
                let left = Self.daysLeft(now, due)
                let target = r.sentTo.flatMap { sessionTitles[$0] }.map { "送到 \($0)" } ?? "送到 session"
                offer(NoteCleanupCandidate(
                    id: r.id, reason: .sentPrompt(days: since), title: r.title, why: "已送出 \(since) 天", sub: target,
                    badge: "archives in \(left)d", aiHint: hint, suggestsCondense: false), priority: 1)
            } else if let due = l.archivesAt, due <= now.addingTimeInterval(7 * 86_400) {
                let inactive = LocalCalendar.days(from: l.lastActivity, to: now)
                let left = Self.daysLeft(now, due)
                offer(NoteCleanupCandidate(
                    id: r.id, reason: .archivesSoon(days: left), title: r.title, why: "\(inactive) 天無活動",
                    sub: "\(left) 天後自動封存", badge: "archives in \(left)d", aiHint: hint, suggestsCondense: false), priority: 2)
            } else if l.staleSince != nil {
                let inactive = LocalCalendar.days(from: l.lastActivity, to: now)
                let why: String
                let sub: String
                if r.kind == .prompt {
                    why = "草稿 \(inactive) 天未動"
                    sub = "從未送出"
                } else if let opened = state[r.id].lastOpenedAt {
                    why = "\(LocalCalendar.days(from: opened, to: now)) 天未開啟"
                    sub = "最後開啟 \(calendar.monthDay(opened))"
                } else {
                    why = "\(inactive) 天未動"
                    sub = "最後更新 \(calendar.monthDay(l.lastActivity))"
                }
                offer(NoteCleanupCandidate(
                    id: r.id, reason: .stale(days: inactive), title: r.title, why: why, sub: sub, badge: "stale \(inactive)d",
                    aiHint: hint, suggestsCondense: false), priority: 5)
            }
        }
        // Near-duplicates within a project (notes without a project form one group), reported once,
        // on the older note.
        let pool = candidatesRows.filter { !$0.pinned }
        var groups: [String: [Int]] = [:]
        for (k, r) in pool.enumerated() {
            if r.projects.isEmpty { groups["", default: []].append(k) }
            for p in Set(r.projects) { groups[p, default: []].append(k) }
        }
        var sets: [Int: Set<UInt64>] = [:]
        var bestDup: [NoteID: (NoteID, Double)] = [:]
        for members in groups.values where members.count > 1 {
            let memberSets = members.map { k -> Set<UInt64> in
                if let s = sets[k] { return s }
                let t = Similarity.trigrams(pool[k].bodyText)
                let s = t.count >= 20 ? t : []
                sets[k] = s
                return s
            }
            for (a, b, j) in Similarity.pairs(memberSets, threshold: 0.80) {
                let ra = pool[members[a]], rb = pool[members[b]]
                let (older, newer) = ra.created <= rb.created ? (ra, rb) : (rb, ra)
                if let best = bestDup[older.id], best.1 >= j { continue }
                bestDup[older.id] = (newer.id, j)
            }
        }
        let titleByID = Dictionary(pool.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        for (id, (other, j)) in bestDup {
            let percent = Int((j * 100).rounded(.down))
            let mine = titleByID[id] ?? "", theirs = titleByID[other] ?? ""
            offer(NoteCleanupCandidate(
                id: id, reason: .duplicate(of: other, percent: percent), title: mine,
                why: "近似重複（與\(Similarity.differenceLabel(mine: mine, other: theirs)) \(percent)% 相同）",
                sub: "對照「\(theirs)」", badge: "dup \(percent)%", aiHint: .condense, suggestsCondense: true), priority: 3)
        }
        // Long notes: ≥ 3 dated H2 / H3 sections older than 30 days (prefiltered on the plain text).
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        for r in candidatesRows {
            let datedLines = r.bodyText.split(separator: "\n").filter { DatedSections.leadingDate(String($0), now: now, calendar: calendar) != nil }
            guard datedLines.count >= 3, let data = try? Data(contentsOf: url(r.path)) else { continue }
            let body = NoteFile.parse(data: data, timeZone: timeZone).body
            let old = DatedSections.sections(in: body, now: now, calendar: calendar).filter { ($0.date ?? now) < cutoff }
            guard old.count >= 3 else { continue }
            let dates = old.compactMap(\.date).sorted()
            let sub = dates.isEmpty ? "舊段落" : "\(calendar.monthDay(dates.first!))–\(calendar.monthDay(dates.last!)) 的段落"
            offer(NoteCleanupCandidate(
                id: r.id, reason: .longNote(sections: old.count, olderThanDays: 30), title: r.title,
                why: "長期筆記 · \(old.count) 段超過 30 天", sub: sub, badge: "\(old.count) 段 > 30d", aiHint: .condense,
                aiHintText: "適合濃縮舊段落", suggestsCondense: true), priority: 4)
        }
        var out = byNote.values.sorted { $0.priority == $1.priority ? $0.candidate.title < $1.candidate.title : $0.priority < $1.priority }
            .map(\.candidate)
        out.append(contentsOf: unusedAssets(now: now))
        return out
    }

    /// `AI 2d 前讀取 → 建議保留` within a week of an AI read, `AI 9d 前讀取` within a month.
    func aiHint(_ id: NoteID, now: Date) -> NoteCleanupCandidate.AIHint? {
        guard let last = activityLog.lastRead(of: id) else { return nil }
        let d = LocalCalendar.days(from: last.at, to: now)
        if d <= 7 { return .keep(lastReadDaysAgo: d) }
        if d <= 30 { return .read(daysAgo: d) }
        return nil
    }

    static func daysLeft(_ now: Date, _ due: Date) -> Int {
        max(0, Int((due.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// §3.4 unused image: a file in `assets/<id>/` (not the `.orig` copy of a used one) that
    /// neither the body nor a kept snapshot references, untouched for 7 days. Annotated copies live
    /// in `annotatedFolder` (derived), so they are never offered here nor trashed with the assets.
    func unusedAssets(now: Date) -> [NoteCleanupCandidate] {
        guard let rows = try? index?.rows(where: "status != 'trashed'") else { return [] }
        let fm = FileManager.default
        var out: [NoteCleanupCandidate] = []
        for r in rows {
            let folder = assetFolder(r.id, trashed: false)
            guard fm.fileExists(atPath: folder.path) else { continue }
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".tmp") }
            guard !names.isEmpty, let data = try? Data(contentsOf: url(r.path)) else { continue }
            let body = NoteFile.decodeText(data)
            var snapshotTexts: [String]?
            for name in names.sorted() where !Self.isReferenced(name, in: body) {
                if snapshotTexts == nil {
                    snapshotTexts = historyStore.list(r.id).compactMap { s in
                        (try? historyStore.data(r.id, snapshot: s.id)).map(NoteFile.decodeText)
                    }
                }
                if snapshotTexts!.contains(where: { Self.isReferenced(name, in: $0) }) { continue }
                guard let st = FileFacts.info(folder.appendingPathComponent(name).path) else { continue }
                let days = LocalCalendar.days(from: Date(timeIntervalSince1970: st.mtime), to: now)
                guard days >= 7 else { continue }
                let rel = "assets/\(r.id.rawValue)/\(name)"
                out.append(NoteCleanupCandidate(
                    id: r.id, reason: .unusedAsset(path: rel, days: days), title: name, why: "未使用的圖片 · \(name)",
                    sub: "「\(r.title)」 · \(Self.byteText(st.size))", badge: "unused \(days)d", aiHint: nil, suggestsCondense: false))
            }
        }
        return out
    }

    static func byteText(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(n / 1000) KB" }
        return "\(n) B"
    }
}
