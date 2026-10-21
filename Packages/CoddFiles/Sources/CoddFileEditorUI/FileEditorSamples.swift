import AppKit
import CoddUI

/// The FileEditor artboard's sample (SPEC §5 design data: the `orb-toolkit-frontend` project, the
/// `打卡頁 RWD 調整` session). Demos and tests render it; integration compares by eye.
@MainActor
public enum FileEditorSamples {
    static let pink = FileEditorColors.tagPink
    static let session = "打卡頁 RWD 調整"

    public static func tree() -> FileTreeModelView {
        let ai = AIChip(color: pink)
        let recent = [
            FileTreeRow(id: "src/pages/punch.vue", name: "punch.vue", dirHint: "src/pages", modified: true, ai: ai),
            FileTreeRow(id: "note:rwd-punch-k7x2", name: "打卡頁 RWD 跑版紀錄.md", dirHint: "notebook"),
            FileTreeRow(id: "src/components/PunchButton.vue", name: "PunchButton.vue", dirHint: "src/components", modified: true, ai: ai),
            FileTreeRow(id: "tailwind.config.js", name: "tailwind.config.js", dirHint: "/", modified: true),
        ]
        let rows = [
            FileTreeRow(id: "node_modules", name: "node_modules", kind: .folder(expanded: false), ignored: true),
            FileTreeRow(id: "public", name: "public", kind: .folder(expanded: true)),
            FileTreeRow(id: "public/favicon.svg", name: "favicon.svg", depth: 1),
            FileTreeRow(id: "src", name: "src", kind: .folder(expanded: true), containsChanges: true),
            FileTreeRow(id: "src/assets", name: "assets", kind: .folder(expanded: false), depth: 1),
            FileTreeRow(id: "src/components", name: "components", kind: .folder(expanded: true), depth: 1, containsChanges: true),
            FileTreeRow(id: "src/components/AppNav.vue", name: "AppNav.vue", depth: 2),
            FileTreeRow(id: "src/components/PunchButton.vue", name: "PunchButton.vue", depth: 2, modified: true, ai: ai),
            FileTreeRow(id: "src/components/PunchRecordCard.vue", name: "PunchRecordCard.vue", depth: 2),
            FileTreeRow(id: "src/pages", name: "pages", kind: .folder(expanded: true), depth: 1, containsChanges: true),
            FileTreeRow(id: "src/pages/history.vue", name: "history.vue", depth: 2),
            FileTreeRow(id: "src/pages/login.vue", name: "login.vue", depth: 2),
            FileTreeRow(id: "src/pages/punch.vue", name: "punch.vue", depth: 2, modified: true, ai: ai),
            FileTreeRow(id: "src/router", name: "router", kind: .folder(expanded: false), depth: 1),
            FileTreeRow(id: "src/stores", name: "stores", kind: .folder(expanded: false), depth: 1),
            FileTreeRow(id: "src/App.vue", name: "App.vue", depth: 1),
            FileTreeRow(id: "src/main.js", name: "main.js", depth: 1),
            FileTreeRow(id: "src/style.css", name: "style.css", depth: 1),
            FileTreeRow(id: ".env.local", name: ".env.local", ignored: true),
            FileTreeRow(id: "index.html", name: "index.html"),
            FileTreeRow(id: "package.json", name: "package.json"),
            FileTreeRow(id: "postcss.config.js", name: "postcss.config.js"),
            FileTreeRow(id: "tailwind.config.js", name: "tailwind.config.js", modified: true),
            FileTreeRow(id: "vite.config.js", name: "vite.config.js"),
        ]
        return FileTreeModelView(project: "orb-toolkit-frontend",
                                 git: FileTreeGitHead(branch: "feat/punch-rwd", ahead: 2, modified: 3),
                                 aiCount: 2, aiColor: pink, recent: recent, rows: rows, currentID: "src/pages/punch.vue",
                                 footPath: "~/…/orb-toolkit-suite/orb-toolkit-frontend",
                                 session: FileTreeSessionLine(tag: pink, title: session, detail: "AI 改 2 · 10:41"))
    }

    public static func tabs() -> EditorTabStripModel {
        EditorTabStripModel(tabs: [
            EditorTab(id: "src/pages/punch.vue", title: "punch.vue", isDirty: true),
            EditorTab(id: "tailwind.config.js", title: "tailwind.config.js", isPreview: true),
            EditorTab(id: "note:rwd-punch-k7x2", title: "打卡頁 RWD 跑版紀錄.md", isNote: true),
        ], selectedID: "src/pages/punch.vue",
        session: EditorSessionPill(tag: pink, title: session, detail: "Edit · 6m", shortcut: "⌘9"))
    }

    public static func toolbar() -> EditorToolbarModel {
        EditorToolbarModel(crumbs: EditorCrumb.path("src/pages/punch.vue") + [EditorCrumb("<style>", kind: .symbol),
                                                                              EditorCrumb(".punch-sticky", kind: .symbol)],
                           aiChangeCount: 2, showAIChanges: true,
                           baselines: EditorToolbarModel.baselineTitles(lastSave: "10:39", aiStart: "10:30"), selectedBaseline: 0)
    }

    public static func banner() -> DiskChangeBannerModel {
        .fileChanged(aiSession: session, time: "10:41")
    }

    public static func status() -> EditorStatusModel {
        EditorStatusModel(branch: "feat/punch-rwd", ahead: 2, session: (tag: pink, title: session), line: 42, column: 18, encoding: "UTF-8",
                          lineEnding: "LF", language: "Vue", indentation: "2 spaces", saved: .saved("10:39"))
    }
}
