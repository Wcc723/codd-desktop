import CoddCore
import CoddDataStore
import Foundation
import CoddUI

/// `<dataRoot>/panes.json`: each session's tab strip and ⌘J panel (real mode), so a relaunch
/// reattaches every shell tab to its still-running holder and restores the panel.
///
/// A file of its own next to 4b's `layout.json` rather than inside it: CoddCore's `Layout` encodes
/// only the fields it knows and would drop these on its next save. Same machinery: versioned
/// JSON, tolerant decoding (bad entries are skipped), atomic 0600 writes off the main actor.
///
/// M5 D14: a file a newer CODD wrote is read as far as this version decodes it (its tabs come
/// back) and never replaced: the store stays read-only for the run, and every write checks the
/// version on disk right before it (`VersionGuard`), so a newer file that appeared later is safe too.
@MainActor
final class PaneLayoutStore {
    let fileURL: URL
    private let shell: ShellState
    private var loop: ObservationLoop?
    private var saveTask: Task<Void, Never>?
    private var lastSaved: Data?
    /// The file on disk is a newer version's (its number): nothing is saved this run.
    private(set) var newerVersion: Int?
    /// Saves run one after another, off the main actor.
    private let queue = DispatchQueue(label: CoddIdentity.label("pane-layout"), qos: .utility)

    static let fileName = "panes.json"
    nonisolated static let currentVersion = 1
    static let saveDelay: Duration = .milliseconds(500)

    init(root: CoddDataRoot, shell: ShellState) {
        fileURL = URL(fileURLWithPath: root.path).appendingPathComponent(Self.fileName)
        self.shell = shell
    }

    /// Reads the file (off the main actor) into `shell.panes`, then saves every later change
    /// (none when a newer CODD wrote the file).
    func load() async {
        let url = fileURL
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        lastSaved = data
        if let data, let file = Self.decodeFile(data) {
            for (id, layout) in file.panes where shell.panes[id] == nil { shell.panes[id] = layout }
            if file.version > Self.currentVersion {
                newerVersion = file.version
                HolderSessionStore.printLog("error panes.json is v\(file.version) (newer CODD): shown read-only, not saved")
            }
        }
        loop = ObservationLoop(track: { [weak self] in self?.shell.panes ?? [:] }, apply: { [weak self] panes in
            self?.scheduleSave(panes)
        })
    }

    /// Drops layouts of sessions that no longer exist (after discovery).
    func prune(keeping ids: Set<SessionID>) {
        for id in shell.panes.keys where !ids.contains(id) { shell.panes[id] = nil }
    }

    /// Writes pending changes now (app quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        write(shell.panes)
        queue.sync {}
    }

    private func scheduleSave(_ panes: [SessionID: PaneLayout]) {
        guard newerVersion == nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.write(panes)
        }
    }

    private func write(_ panes: [SessionID: PaneLayout]) {
        guard newerVersion == nil, let data = Self.encode(panes), data != lastSaved else { return }
        // No file yet and nothing to keep: the observation's first run would otherwise write an
        // empty `{"version":1,"sessions":{}}` half a second into every first launch, and a data
        // root with panes.json is no longer new (OnboardingGate): an interrupted first run (⌘Q
        // mid-wizard, a crash) would never bring the wizard back.
        if lastSaved == nil, data == Self.encode([:]) { return }
        lastSaved = data
        let url = fileURL
        let current = Self.currentVersion
        queue.async {
            // Right before the write: a newer CODD may have written the file since the load.
            guard VersionGuard.mayReplace(url, key: "version", current: current) else {
                let found = VersionGuard.existingVersion(of: url, key: "version") ?? 0
                HolderSessionStore.printLog("error panes.json is v\(found) (newer CODD): not saved")
                return
            }
            do {
                try AtomicFile.write(data, to: url)
            } catch {
                HolderSessionStore.printLog("error cannot save \(url.path): \(error)")
            }
        }
    }

    // MARK: - Format

    /// `{"version":1,"sessions":{"<id>":{"tabs":[{"id","number"}],"selected":"claude"|"<tab id>",
    /// "panelTabs":[{"id","number"}],"panelSelected":"<tab id>"?,"panel":{"id","number"}?,
    /// "panelOpen":bool,"panelMaximized":bool,"panelHeight":n,"composerOpen":bool}}}`.
    ///
    /// D13: `panelTabs`, `panelSelected`, `panelMaximized` (M2 I5) and `composerOpen` (M2 I4) are
    /// additive and the version stays 1. `panel` is still written (= the shown panel tab) so an M1
    /// build keeps its panel; it adopts the other live panel tabs into its strip, and since it
    /// drops the keys it does not know, the next M2 read migrates its `panel` back. A file
    /// without `panelTabs` (M1) reads its `panel` as the only panel tab.
    ///
    /// Decoding is tolerant per field: a value of the wrong type, a tab entry that is not
    /// `{id, number}` and an id that is not a lowercase UUID are skipped, the rest of the session
    /// (and every other session) still loads.
    private struct File: Encodable {
        var version: Int
        var sessions: [String: Entry]
    }

    private struct LenientFile: Decodable {
        var version: Int
        var sessions: [String: Entry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            let raw = (try? container.decode([String: LenientEntry].self, forKey: .sessions)) ?? [:]
            sessions = raw.mapValues(\.entry)
        }

        enum CodingKeys: String, CodingKey { case version, sessions }
    }

    private struct Entry: Codable {
        var tabs: [ShellTab]?
        var selected: String?
        var panelTabs: [ShellTab]?
        var panelSelected: String?
        var panel: ShellTab?
        var panelOpen: Bool?
        var panelMaximized: Bool?
        var panelHeight: Double?
        var composerOpen: Bool?
    }

    /// One session's entry, every field optional and decoded on its own.
    private struct LenientEntry: Decodable {
        var entry: Entry

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: Key.self) else {
                entry = Entry()  // not an object: the session gets the defaults
                return
            }
            func tabs(_ key: Key) -> [ShellTab]? {
                guard var list = try? c.nestedUnkeyedContainer(forKey: key) else { return nil }
                var out: [ShellTab] = []
                while !list.isAtEnd {
                    if let tab = try? list.decode(ShellTab.self) { out.append(tab) } else { _ = try? list.decode(Skip.self) }
                }
                return out
            }
            entry = Entry(tabs: tabs(.tabs), selected: try? c.decodeIfPresent(String.self, forKey: .selected),
                          panelTabs: tabs(.panelTabs), panelSelected: try? c.decodeIfPresent(String.self, forKey: .panelSelected),
                          panel: try? c.decodeIfPresent(ShellTab.self, forKey: .panel),
                          panelOpen: try? c.decodeIfPresent(Bool.self, forKey: .panelOpen),
                          panelMaximized: try? c.decodeIfPresent(Bool.self, forKey: .panelMaximized),
                          panelHeight: try? c.decodeIfPresent(Double.self, forKey: .panelHeight),
                          composerOpen: try? c.decodeIfPresent(Bool.self, forKey: .composerOpen))
        }

        enum Key: String, CodingKey {
            case tabs, selected, panelTabs, panelSelected, panel, panelOpen, panelMaximized, panelHeight, composerOpen
        }

        /// Consumes one array element of any shape.
        private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
    }

    nonisolated static func encode(_ panes: [SessionID: PaneLayout]) -> Data? {
        var sessions: [String: Entry] = [:]
        for (id, layout) in panes where layout != PaneLayout() {
            let selected: String
            switch layout.selected {
            case .claude: selected = "claude"
            case .shell(let tabID): selected = tabID
            }
            sessions[id] = Entry(tabs: layout.tabs, selected: selected, panelTabs: layout.panelTabs,
                                 panelSelected: layout.panel?.id, panel: layout.panel, panelOpen: layout.panelOpen,
                                 panelMaximized: layout.isPanelMaximized, panelHeight: layout.panelHeight,
                                 composerOpen: layout.composerOpen)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(File(version: currentVersion, sessions: sessions))
    }

    /// Nil when the file is not ours (no integer `version`, not an object). M5 D14: a newer
    /// version's file is read as far as this version decodes it (``decodeFile(_:)`` says which).
    nonisolated static func decode(_ data: Data) -> [SessionID: PaneLayout]? {
        decodeFile(data)?.panes
    }

    /// The file's version and the layouts it holds (any version, tolerant per field).
    nonisolated static func decodeFile(_ data: Data) -> (version: Int, panes: [SessionID: PaneLayout])? {
        guard let file = try? JSONDecoder().decode(LenientFile.self, from: data) else { return nil }
        var panes: [SessionID: PaneLayout] = [:]
        for (id, entry) in file.sessions {
            panes[id] = layout(entry)
        }
        return (file.version, panes)
    }

    /// Ids name tab directories: only lowercase UUIDs, each in one place (the strip wins).
    nonisolated private static func layout(_ entry: Entry) -> PaneLayout {
        var layout = PaneLayout()
        var seen = Set<String>()
        layout.tabs = (entry.tabs ?? []).filter { TerminalHub.isValidTabID($0.id) && seen.insert($0.id).inserted }
        // M1 files have only `panel`: it becomes the only panel tab.
        let panelTabs = entry.panelTabs ?? entry.panel.map { [$0] } ?? []
        layout.panelTabs = panelTabs.filter { TerminalHub.isValidTabID($0.id) && seen.insert($0.id).inserted }
        let wanted = entry.panelSelected ?? entry.panel?.id
        if let wanted, layout.panelTabs.contains(where: { $0.id == wanted }) { layout.panelSelected = wanted }
        if !layout.panelTabs.isEmpty, layout.panelSelected == nil { layout.panelSelected = layout.panelTabs[0].id }
        layout.panelOpen = !layout.panelTabs.isEmpty && (entry.panelOpen ?? false)
        layout.panelMaximized = layout.panelOpen && (entry.panelMaximized ?? false)
        if let height = entry.panelHeight, height.isFinite, height > 0 { layout.panelHeight = height }
        layout.composerOpen = entry.composerOpen ?? false
        if let selected = entry.selected, selected != "claude", layout.tabs.contains(where: { $0.id == selected }) {
            layout.selected = .shell(selected)
        }
        return layout
    }
}
