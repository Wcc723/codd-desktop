import CoddCore
import CoddHooks
import CoddNotes
import CoddPreferences
import Foundation
import Observation

/// D32 `交給 Claude 濃縮`: the Cleanup bulk bar's one-shot `claude -p` that summarises the
/// selected notes into one new note, and the apply that archives the originals.
///
/// A run: the run folder `<dataRoot>/run/condense-<uuid>/` (0700) with a 0600 `mcp.json` whose
/// caller is registered in `MCPService` as a transient, read-only caller (the run's UUID) for the
/// run's life; stdin is a 繁體中文 instruction plus each source's §3.7 AI text (a long-note source
/// only its dated sections older than 30 days); argv exactly
/// `-p --model <m> --output-format text --tools "" --permission-prompts none --strict-mcp-config
/// --mcp-config <run>/mcp.json --allowedTools mcp__codd__notes_read --no-session-persistence`
/// (every variadic flag is followed by another option); the environment is the session one
/// without `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` (`CLAUDE_CONFIG_DIR` for a pinned account, never
/// logged). 180 s timeout; `取消` ends the child's process group. The folder goes when the run ends.
///
/// Nothing changes before `建立摘要並封存原稿`: then a new NOTE `摘要 · M/D 清理（n 則）`
/// (`cleanup-<MMdd>-xxxx`, `condensedFrom`), each whole-note source snapshotted and archived by
/// `condense` with `condensedInto`; a long-note source is snapshotted, stays ACTIVE and unchanged
/// and gets `keepUntil` +30 d. UNDO unarchives the sources and trashes the summary.
@MainActor @Observable
final class CondenseRunner {
    struct Source: Equatable, Sendable {
        var id: NoteID
        var title: String
        var kind: NoteKind
        var promptDraft: Bool
        var project: String?
        /// The long-note candidate (`9 段 > 30d`): only its old dated sections go in.
        var oldSectionsOnly: Bool
        /// How many old sections it gave (set when the run's input was built).
        var oldSections: Int?
    }

    enum Phase: Equatable, Sendable {
        case idle
        case running(started: Date)
        case preview(output: String)
        case failed(String)
    }

    struct Applied: Equatable, Sendable {
        var summary: NoteID
        var title: String
        var archived: [NoteID]
        var kept: [NoteID]
    }

    /// What the last run did (the dump; never the text, never the environment).
    struct RunFacts: Equatable, Sendable {
        var runID: String
        var exit: Int32?
        var ms: Double
        var inputBytes: Int
        var outputBytes: Int
        var timedOut: Bool
        var cancelled: Bool
        var folderRemoved: Bool
    }

    // MARK: Configuration

    @ObservationIgnored let notes: NotesService
    @ObservationIgnored weak var holders: HolderSessionStore?
    @ObservationIgnored weak var mcp: MCPService?
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored let timeZone: TimeZone
    @ObservationIgnored private let log: @Sendable (String) -> Void
    /// The claude to run (the login-PATH `claude` on the standard data root, only the DEBUG
    /// `-codd-claude-path` elsewhere), nil when there is none.
    @ObservationIgnored var claudeExecutable: () async -> String? = { nil }
    /// Why no run is possible before it starts (the card's disabled reason), nil when one is.
    @ObservationIgnored var unavailableReason: () -> String? = { nil }
    /// `follow` → nil (the global login); an account number → its cswap profile (`CLAUDE_CONFIG_DIR`)
    /// or the refusal to show.
    @ObservationIgnored var configDirectory: (String) -> Result<String?, Refusal> = { _ in .success(nil) }
    /// The app's and the login shell's environments (tests pass their own).
    @ObservationIgnored var environment: () async -> (base: [String: String], login: [String: String]?) = {
        (ProcessInfo.processInfo.environment, await LoginEnvironment.current())
    }
    @ObservationIgnored var timeout: Duration = .seconds(180)
    @ObservationIgnored var maxOutputBytes = 2 << 20

    struct Refusal: Error, Equatable {
        var message: String
    }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var sources: [Source] = []
    /// AI OFF notes left out of the last selection.
    private(set) var excluded: [NoteID] = []
    private(set) var lastRun: RunFacts?
    private(set) var lastApplied: Applied?
    /// The account and model of the shown preview.
    private(set) var runAccount: String?
    private(set) var runModel: String?

    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The child and its run folder while a run goes (the quit ends both).
    @ObservationIgnored private var current: (process: CondenseProcess, folder: String)?

    static let offExcludedText = "AI 存取為 OFF 的筆記不會交給 Claude"
    static let testRootReason = "測試資料根目錄只用 -codd-claude-path"
    static let noHooksReason = "hook server 尚未啟動，無法掛載 codd MCP"
    static let serverName = MCPLaunchConfig.defaultServerName
    nonisolated static let readTool = "mcp__codd__notes_read"
    nonisolated static let longNoteDays = 30

    init(notes: NotesService, holders: HolderSessionStore?, mcp: MCPService?, clock: @escaping @Sendable () -> Date,
         timeZone: TimeZone = .current, log: @escaping @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.notes = notes
        self.holders = holders
        self.mcp = mcp
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    // MARK: Pure parts

    /// D32's argv after the executable, in this exact order.
    nonisolated static func arguments(model: String, mcpConfig: String) -> [String] {
        ["-p", "--model", model, "--output-format", "text", "--tools", "", "--permission-prompts", "none", "--strict-mcp-config",
         "--mcp-config", mcpConfig, "--allowedTools", readTool, "--no-session-persistence"]
    }

    /// The session environment without CODD's session variables, plus a pinned account's
    /// `CLAUDE_CONFIG_DIR`.
    nonisolated static func childEnvironment(base: [String: String], login: [String: String]?, runID: UUID,
                                             configDirectory: String?) -> [String: String] {
        var extra: [String: String] = [:]
        if let configDirectory { extra["CLAUDE_CONFIG_DIR"] = configDirectory }
        var env = ShellEnvironment.build(base: base, login: login, sessionID: runID, hookToken: nil, extra: extra)
        for name in [CoddEnvironmentName.sessionId, CoddEnvironmentName.hookToken, CoddEnvironmentName.hookURL] { env[name] = nil }
        return env
    }

    /// `摘要 · 10/15 清理（5 則）`.
    nonisolated static func summaryTitle(now: Date, count: Int, timeZone: TimeZone) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: now)
        return "摘要 · \(c.month ?? 0)/\(c.day ?? 0) 清理（\(count) 則）"
    }

    /// `cleanup-1015` (the id becomes `cleanup-1015-xxxx`).
    nonisolated static func idPrefix(now: Date, timeZone: TimeZone) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: now)
        return String(format: "cleanup-%02d%02d", c.month ?? 0, c.day ?? 0)
    }

    /// The instruction and the sources' texts (stdin).
    nonisolated static func prompt(title: String, sources: [(title: String, text: String, oldSections: Int?)]) -> String {
        var out = """
        請把下面 \(sources.count) 則筆記濃縮成「一則」Markdown 筆記。
        - 第一行是標題：# \(title)
        - 每則來源筆記寫一個 ## 段落，段落標題用來源筆記的標題。
        - 保留決定、還沒完成的工作、數字、日期與檔案路徑；重複或過時的內容可以刪掉。
        - 只根據下面的內容寫，不要編造；原文沒寫清楚的地方寫「（原文未說明）」。
        - 標示「（舊段落 n 段）」的來源只附上它超過 30 天的舊段落，只整理這些段落。
        - 直接輸出 Markdown，不要加任何前言或說明。

        """
        for (index, source) in sources.enumerated() {
            let label = source.oldSections.map { "（舊段落 \($0) 段）" } ?? ""
            out += "\n=== 來源 \(index + 1) / \(sources.count)：\(source.title)\(label) ===\n"
            out += source.text.hasSuffix("\n") ? source.text : source.text + "\n"
        }
        return out
    }

    /// A long note's AI text header (the lines before the first blank line) with only `sections`.
    nonisolated static func oldSectionsText(aiText: String, sections: [NoteSection]) -> String {
        let lines = aiText.components(separatedBy: "\n")
        let header = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return header.joined(separator: "\n") + "\n（舊段落 \(sections.count) 段）\n\n"
            + sections.map { $0.text.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n") + "\n"
    }

    /// The summary note's body: the output under our H1, then `濃縮自` with one reference per source.
    nonisolated static func summaryBody(output: String, title: String, sources: [NoteID]) -> String {
        var lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, first.hasPrefix("# ") { lines.removeFirst() }
        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var body = "# \(title)\n\n"
        if !rest.isEmpty { body += rest + "\n\n" }
        body += "## 濃縮自\n\n" + sources.map { "- \($0.uri)" }.joined(separator: "\n") + "\n"
        return body
    }

    /// `交給 Claude 濃縮…` from the selected NOTES: the notes in that order, AI OFF ones left out
    /// (`excluded`); `longNotes` are the long-note candidates among them.
    func prepare(_ ids: [NoteID], longNotes: Set<NoteID>) async {
        guard !isRunning else { return }
        var picked: [Source] = []
        var off: [NoteID] = []
        for id in ids {
            guard let summary = (try? await notes.summary(id)) ?? nil else { continue }
            let m = summary.metadata
            if m.ai == .off {
                off.append(id)
                continue
            }
            picked.append(Source(id: id, title: m.title, kind: m.kind, promptDraft: m.isPromptDraft, project: m.primaryProject,
                                 oldSectionsOnly: longNotes.contains(id)))
        }
        sources = picked
        excluded = off
        phase = .idle
        lastApplied = nil
    }

    /// Drops the card's sources (the card closed).
    func reset() {
        guard !isRunning else { return }
        sources = []
        excluded = []
        phase = .idle
    }

    // MARK: Run

    /// `[✻ 產生摘要]` / `[重新產生]`: one run with `account` (`follow` or a cswap number) and `model`.
    func generate(account: String, model: String) {
        guard !isRunning, !sources.isEmpty else { return }
        cancelRequested = false
        phase = .running(started: clock())
        runAccount = account
        runModel = model
        runTask = Task { [weak self] () -> Void in await self?.performRun(account: account, model: model) }
    }

    /// Waits for a run in progress (DEBUG flags, tests).
    func waitForRun() async {
        await runTask?.value
    }

    /// `[取消]`: the child's process group goes; back to idle.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
    }

    /// The app quits: a running child's process group goes and its run folder with it (the child
    /// leads its own session, so nothing else would end it).
    func shutdown() {
        guard let current else { return }
        _ = killpg(current.process.pid, SIGKILL)
        _ = current.process.poll()
        _ = Self.removeFolder(current.folder)
        log("condense stopped at quit")
    }

    /// `[捨棄]`: the preview goes, nothing changed.
    func discard() {
        guard !isRunning else { return }
        phase = .idle
        log("condense discard")
    }

    private func fail(_ text: String) {
        phase = .failed(text)
        log("condense failed reason=\(text)")
    }

    private func performRun(account: String, model: String) async {
        let started = ContinuousClock.now
        if let reason = unavailableReason() { return fail(reason) }
        guard let library = notes.library, notes.availability.isReady else { return fail("筆記本尚未開啟") }
        guard let holders, let config = holders.hooks?.config else { return fail(Self.noHooksReason) }
        guard let executable = await claudeExecutable(), executable.hasPrefix("/") else { return fail("找不到 claude") }
        let configDir: String?
        switch configDirectory(account) {
        case .success(let dir): configDir = dir
        case .failure(let refusal): return fail(refusal.message)
        }
        let runID = UUID()
        let folder = holders.root.runPath + "/" + HolderSessionStore.condenseRunPrefix + runID.uuidString.lowercased()
        let mcpFile = folder + "/mcp.json"
        let inputFile = folder + "/input.md"
        let outputFile = folder + "/output.md"
        let errorFile = folder + "/error.txt"
        var facts = RunFacts(runID: String(runID.uuidString.lowercased().prefix(8)), exit: nil, ms: 0, inputBytes: 0, outputBytes: 0,
                             timedOut: false, cancelled: false, folderRemoved: false)
        defer {
            mcp?.context.removeTransientCaller(runID)
            facts.folderRemoved = Self.removeFolder(folder)
            facts.ms = NotesService.milliseconds(ContinuousClock.now - started)
            lastRun = facts
        }
        // The sources' texts (a long note: its old dated sections only).
        let now = clock()
        let title = Self.summaryTitle(now: now, count: sources.count, timeZone: timeZone)
        var texts: [(title: String, text: String, oldSections: Int?)] = []
        var updated = sources
        for (index, source) in sources.enumerated() {
            guard let rendered = try? await library.aiText(source.id, offset: 0, maxChars: 50_000) else { continue }
            if source.oldSectionsOnly {
                let sections = (try? await library.datedSections(source.id, olderThanDays: Self.longNoteDays)) ?? []
                updated[index].oldSections = sections.count
                texts.append((source.title, Self.oldSectionsText(aiText: rendered.text, sections: sections), sections.count))
            } else {
                texts.append((source.title, rendered.text + (rendered.truncated ? "\n（後略）\n" : ""), nil))
            }
        }
        sources = updated
        guard !texts.isEmpty else { return fail("找不到要濃縮的筆記") }
        let input = Data(Self.prompt(title: title, sources: texts).utf8)
        facts.inputBytes = input.count
        let port = mcp?.port ?? config.port
        let mcpConfig = MCPLaunchConfig(serverName: Self.serverName, port: port,
                                        token: MCPAuth.sessionToken(hookToken: config.token, sessionID: runID), sessionID: runID)
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            try mcpConfig.write(to: URL(fileURLWithPath: mcpFile))
            try AtomicFile.write(input, to: URL(fileURLWithPath: inputFile), permissions: 0o600)
        } catch {
            return fail("無法準備濃縮工作（\(error)）")
        }
        mcp?.context.setTransientCaller(runID, notes: Set(sources.map(\.id.rawValue)))
        let env = await environment()
        let childEnv = Self.childEnvironment(base: env.base, login: env.login, runID: runID, configDirectory: configDir)
        let argv = Self.arguments(model: model, mcpConfig: mcpFile)
        log("exec claude path=\(HolderSessionStore.abbreviate(executable)) sub=-p")
        let process: CondenseProcess
        do {
            process = try CondenseProcess(executable: executable, arguments: argv, environment: childEnv, directory: folder,
                                          stdin: inputFile, stdout: outputFile, stderr: errorFile)
        } catch {
            return fail("無法啟動 claude（\(error)）")
        }
        // D32: CODD's own child, never an EXT session while it runs.
        current = (process, folder)
        holders.transientClaudePids.insert(Int(process.pid))
        holders.applyRegistry(holders.registryEntries)
        defer {
            current = nil
            holders.transientClaudePids.remove(Int(process.pid))
            holders.applyRegistry(holders.registryEntries)
        }
        let deadline = ContinuousClock.now + timeout
        var status: Int32?
        while true {
            status = process.poll()
            if status != nil { break }
            if cancelRequested {
                facts.cancelled = true
                await process.terminate()
                break
            }
            if ContinuousClock.now >= deadline {
                facts.timedOut = true
                await process.terminate()
                break
            }
            if Self.fileSize(outputFile) > maxOutputBytes {
                await process.terminate()
                facts.exit = process.poll()
                return fail("claude 的輸出太大")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        facts.exit = status ?? process.poll()
        let output = (try? String(contentsOfFile: outputFile, encoding: .utf8)) ?? ""
        facts.outputBytes = output.utf8.count
        log("condense run=\(facts.runID) sources=\(sources.count) exit=\(facts.exit.map { String($0) } ?? "-") "
            + "bytes=\(facts.outputBytes) timedOut=\(facts.timedOut) cancelled=\(facts.cancelled)")
        if facts.cancelled {
            phase = .idle
            return
        }
        if facts.timedOut { return fail("超過 \(Int(timeout.components.seconds)) 秒沒有完成，已停止") }
        guard facts.exit == 0 else {
            let detail = Self.firstLine(errorFile)
            return fail("claude 結束碼 \(facts.exit.map { String($0) } ?? "?")" + (detail.map { "：\($0)" } ?? ""))
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("claude 沒有輸出摘要") }
        phase = .preview(output: output)
    }

    nonisolated static func fileSize(_ path: String) -> Int {
        var st = stat()
        return stat(path, &st) == 0 ? Int(st.st_size) : 0
    }

    /// The first non-empty line of claude's stderr, short (shown in the card, never logged).
    nonisolated static func firstLine(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        return String(line.prefix(120))
    }

    /// Removes the run folder (it holds the token and the notes' text); true when it is gone.
    nonisolated static func removeFolder(_ folder: String) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder) { try? manager.removeItem(atPath: folder) }
        return !manager.fileExists(atPath: folder)
    }

    // MARK: Apply

    /// `[建立摘要並封存原稿]`: the summary note, the snapshotted originals archived by condense (a
    /// long-note source kept active with `keepUntil` +30 d). Nil (with the reason) when it failed.
    func apply() async -> Result<Applied, Refusal> {
        guard case .preview(let output) = phase else { return .failure(Refusal(message: "還沒有摘要")) }
        guard let library = notes.library else { return .failure(Refusal(message: "筆記本尚未開啟")) }
        let now = clock()
        let title = Self.summaryTitle(now: now, count: sources.count, timeZone: timeZone)
        let ids = sources.map(\.id)
        for id in ids { _ = try? await library.snapshot(id, reason: "condense") }
        let document: NoteDocument
        do {
            document = try await library.create(NewNote(
                title: title, body: Self.summaryBody(output: output, title: title, sources: ids), kind: .note,
                scope: .global, createdBy: "user", idPrefix: Self.idPrefix(now: now, timeZone: timeZone), condensedFrom: ids))
        } catch {
            return .failure(Refusal(message: (error as? NotesError)?.errorDescription ?? "無法建立摘要"))
        }
        let summary = document.metadata.id
        let whole = sources.filter { !$0.oldSectionsOnly }.map(\.id)
        let long = sources.filter(\.oldSectionsOnly).map(\.id)
        var archived: [NoteID] = []
        for id in whole {
            _ = try? await library.update(id, .condensedInto(summary))
            do {
                try await library.archive([id], by: .condense)
                archived.append(id)
            } catch {
                log("condense archive skipped id=\(id.rawValue): \(error)")
            }
        }
        let until = now.addingTimeInterval(Double(RetentionService.keepDays) * RetentionService.day)
        for id in long { await library.keep(id, until: until) }
        let applied = Applied(summary: summary, title: title, archived: archived, kept: long)
        lastApplied = applied
        phase = .idle
        sources = []
        log("condense apply summary=\(summary.rawValue) archived=\(archived.count) kept=\(long.count)")
        await notes.refreshNow()
        return .success(applied)
    }

    /// UNDO of an apply: the originals back to ACTIVE (`condensedInto` removed), the summary into
    /// CODD's TRASH.
    func undo(_ applied: Applied) async {
        guard let library = notes.library else { return }
        try? await library.unarchive(applied.archived)
        for id in applied.archived { _ = try? await library.update(id, .condensedInto(nil)) }
        try? await library.trash([applied.summary])
        if lastApplied == applied { lastApplied = nil }
        log("condense undo summary=\(applied.summary.rawValue) restored=\(applied.archived.count)")
        await notes.refreshNow()
    }

    /// `✻ 已建立「…」· n 則原稿已封存`.
    static func appliedToast(_ applied: Applied) -> String {
        var text = "✻ 已建立「\(applied.title)」· \(applied.archived.count) 則原稿已封存"
        if !applied.kept.isEmpty { text += " · \(applied.kept.count) 則長期筆記保留" }
        return text
    }

    // MARK: Dump

    /// `cleanup.condense {state, previewChars, applied{summary, archived[]}}`.
    var dumpObject: [String: Any] {
        var object: [String: Any] = ["sources": sources.map(\.id.rawValue), "excluded": excluded.map(\.rawValue)]
        switch phase {
        case .idle: object["state"] = "idle"
        case .running: object["state"] = "running"
        case .preview(let output):
            object["state"] = "preview"
            object["previewChars"] = output.count
        case .failed(let reason):
            object["state"] = "failed"
            object["error"] = reason
        }
        if object["previewChars"] == nil { object["previewChars"] = 0 }
        object["account"] = runAccount ?? NSNull()
        object["model"] = runModel ?? NSNull()
        if let applied = lastApplied {
            object["applied"] = ["summary": applied.summary.rawValue, "archived": applied.archived.map(\.rawValue),
                                 "kept": applied.kept.map(\.rawValue)]
        } else {
            object["applied"] = NSNull()
        }
        if let run = lastRun {
            object["run"] = ["id": run.runID, "exit": run.exit.map { Int($0) as Any } ?? NSNull(), "ms": run.ms,
                             "inputBytes": run.inputBytes, "outputBytes": run.outputBytes, "timedOut": run.timedOut,
                             "cancelled": run.cancelled, "folderRemoved": run.folderRemoved]
        }
        return object
    }
}
