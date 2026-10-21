import AppKit
import CoddCodeEditor
import CoddFiles
import CoddNotes
import Foundation

/// D35 (files part): mock mode's Files workspace is a made-up `orb-toolkit-frontend` project the
/// app writes into its temporary mock folder (`<mock>/projects/orb-toolkit-frontend`, removed at
/// quit with the notes), with its git facts from a fixed `GitReading` (`feat/punch-rwd ↑2`, three
/// `M` files, punch.vue's HEAD text with `position: fixed; bottom: 0;`): mock mode never runs git.
/// `-codd-mock -codd-show files:orb-toolkit-frontend/src/pages/punch.vue` then draws the FileEditor
/// artboard: the AI touches of 打卡頁 RWD 調整, the dirty punch.vue under the AI disk banner with
/// SHOW AI CHANGES on, the preview tab and the note tab. Made-up design data only.
@MainActor
enum MockFiles {
    nonisolated static let projectName = "orb-toolkit-frontend"
    /// The mock session working in the project (SPEC §5 s9).
    nonisolated static let sessionID = "s9"

    /// `<mock>/projects/orb-toolkit-frontend`.
    nonisolated static func projectRoot(in folder: URL) -> URL {
        folder.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(projectName, isDirectory: true)
    }

    /// The mock project's cwd in `MockData` maps onto the written project.
    nonisolated static func root(forCwd cwd: String, folder: URL) -> String {
        cwd.hasSuffix("/" + projectName) ? projectRoot(in: folder).path : PathFormatShim.expandTilde(cwd)
    }

    // MARK: Git (never runs git)

    nonisolated static func gitReader(folder: URL) -> StaticGitReader {
        let root = projectRoot(in: folder)
        let status = GitRepoStatus(root: root, branch: "feat/punch-rwd", upstream: "origin/feat/punch-rwd", ahead: 2,
                                   changes: ["src/pages/punch.vue": .modified, "src/components/PunchButton.vue": .modified,
                                             "tailwind.config.js": .modified])
        let head: [String: Data] = ["src/pages/punch.vue": Data(punchVue(head: true).utf8),
                                    "src/components/PunchButton.vue": Data(punchButton(work: false).utf8),
                                    "tailwind.config.js": Data(tailwind(work: false).utf8)]
        let tracked = files().map(\.path).filter { !$0.hasPrefix("node_modules/") && $0 != ".env.local" }
        return StaticGitReader(root: root, status: status, headFiles: head, ignored: ["node_modules", ".env.local"], files: tracked)
    }

    // MARK: Seed

    /// Writes the project, `files/recent.json` and `files/ai-touches.json` (once, off the main actor).
    static func seed(into folder: URL, now: Date) async {
        let root = projectRoot(in: folder)
        let seeds = files().map { MockNotes.SeedFile(path: "projects/\(projectName)/" + $0.path, data: Data($0.text.utf8), modified: now) }
        let recent = RecentFilesStore(file: folder.appendingPathComponent("files/recent.json"), clock: { now })
        let touches = AITouchLog(file: folder.appendingPathComponent("files/ai-touches.json"), clock: { now }, saveDelay: .zero)
        await Task.detached(priority: .userInitiated) {
            MockNotes.write(seeds, into: folder)
            // The disk already holds the AI's newest edit (z-index 20, 10:41): the tab's buffer is
            // the artboard's text with the user's unsaved margin.
            let punch = root.appendingPathComponent("src/pages/punch.vue")
            try? Data(punchVue(head: false, zIndex: 20).utf8).write(to: punch)
            for (path, minutes) in [("tailwind.config.js", 7), ("src/components/PunchButton.vue", 4), ("src/pages/punch.vue", 1)] {
                recent.record(root.appendingPathComponent(path), root: root, source: "user", at: now.addingTimeInterval(-Double(minutes) * 60))
            }
            touches.record([
                AITouch(path: root.appendingPathComponent("src/components/PunchButton.vue").path, session: sessionID, tool: "Edit",
                        at: now.addingTimeInterval(-4 * 60)),
                AITouch(path: punch.path, session: sessionID, tool: "Edit", at: now.addingTimeInterval(-60)),
            ])
            touches.flush()
        }.value
    }

    /// The artboard's state on an open workspace: folders expanded, the three tabs, the banner, SHOW
    /// AI CHANGES with hunk 1 accepted (its `.mod` bar on line 33), find `sticky` and the caret on
    /// line 42.
    static func showArtboard(_ service: FileEditorService, root: URL, file: URL, now: Date) async {
        let workspace = service.openRoot(root)
        for folder in ["public", "src", "src/components", "src/pages"] where !workspace.expanded.contains(folder) {
            service.toggleFolder(folder)
        }
        guard file.lastPathComponent == "punch.vue" else {
            await service.open(file, preview: false, root: root)
            return
        }
        let saved = punchVue(head: false, margin: "56px")
        let shown = punchVue(head: false)
        guard case .success(let decoded) = TextFileCodec.decode(Data(saved.utf8)) else { return }
        let data = Data(saved.utf8)
        var state = OpenFileState(url: file, decoded: decoded,
                                  disk: FileFingerprint(size: Int64(data.count), mtime: now, inode: 0, sha256: FileFingerprint.sha256Hex(data)),
                                  at: now.addingTimeInterval(-3 * 60))
        // The buffer: the artboard's text (DecodedText leaves the final newline out).
        state.edit(String(shown.dropLast()))
        if let disk = try? FileFingerprint.read(file) {
            _ = state.diskChanged(newData: disk.data, fingerprint: disk.fingerprint,
                                  aiTouch: (session: sessionID, at: now.addingTimeInterval(-60)), now: now.addingTimeInterval(-60))
        }
        state.aiBaseline = (text: decoded.text, at: now.addingTimeInterval(-12 * 60), session: sessionID)
        // The artboard's order: punch.vue, the preview tab, the note tab (each opens after the selected one).
        let tab = service.install(state, in: workspace, preview: false)
        let tailwind = await service.open(root.appendingPathComponent("tailwind.config.js"), preview: true, root: root, source: nil)
        tailwind?.openedAt = now.addingTimeInterval(-7 * 60)
        if let note = NoteID(rawValue: MockNotes.n1ID) {
            let noteTab = service.openNote(note, title: "打卡頁 RWD 跑版紀錄", preview: false)
            noteTab?.openedAt = now.addingTimeInterval(-2 * 60)
        }
        tab.openedAt = now.addingTimeInterval(-60)
        service.select(tab.id)
        service.setShowAI(tab, on: true)
        // Hunk 1 (line 33, `sticky`) was accepted earlier: its `.mod` bar stays.
        for _ in 0..<40 where tab.hunks.count < 2 { try? await Task.sleep(for: .milliseconds(25)) }
        if !tab.hunks.isEmpty { service.hunkAction(tab, index: 0, action: .accept) }
        tab.editor?.goTo(line: 39, column: 8)
        tab.editor?.showFind(replace: false, query: "sticky")
        tab.findQuery = "sticky"
        tab.editor?.goTo(line: 42, column: 18)
        tab.editor?.showsInactiveCaret = true
        tab.editor?.scrollToLine(13)
    }

    // MARK: Files

    struct File: Sendable {
        var path: String
        var text: String
    }

    nonisolated static func files() -> [File] {
        [
            File(path: "package.json", text: """
            {
              "name": "orb-toolkit-frontend",
              "private": true,
              "version": "0.3.0",
              "type": "module",
              "scripts": { "dev": "vite", "build": "vite build" }
            }

            """),
            File(path: "index.html", text: "<!doctype html>\n<html lang=\"zh-Hant\">\n  <body>\n    <div id=\"app\"></div>\n"
                 + "    <script type=\"module\" src=\"/src/main.js\"></script>\n  </body>\n</html>\n"),
            File(path: "vite.config.js", text: "import { defineConfig } from 'vite'\nimport vue from '@vitejs/plugin-vue'\n\n"
                 + "export default defineConfig({ plugins: [vue()] })\n"),
            File(path: "postcss.config.js", text: "export default {\n  plugins: { tailwindcss: {}, autoprefixer: {} },\n}\n"),
            File(path: "tailwind.config.js", text: tailwind(work: true)),
            File(path: "public/favicon.svg", text: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\"><rect width=\"16\" height=\"16\" fill=\"#2f6fe0\"/></svg>\n"),
            File(path: "src/main.js", text: "import { createApp } from 'vue'\nimport App from './App.vue'\nimport './style.css'\n\ncreateApp(App).mount('#app')\n"),
            File(path: "src/App.vue", text: "<template>\n  <AppNav />\n  <RouterView />\n</template>\n"),
            File(path: "src/style.css", text: "@tailwind base;\n@tailwind components;\n@tailwind utilities;\n"),
            File(path: "src/assets/logo.svg", text: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\"></svg>\n"),
            File(path: "src/components/AppNav.vue", text: "<template>\n  <nav class=\"app-nav\"></nav>\n</template>\n"),
            File(path: "src/components/PunchButton.vue", text: punchButton(work: true)),
            File(path: "src/components/PunchRecordCard.vue", text: "<script setup>\ndefineProps({ record: Object })\n</script>\n\n"
                 + "<template>\n  <article class=\"punch-card\">{{ record.time }}</article>\n</template>\n"),
            File(path: "src/pages/history.vue", text: "<template>\n  <main class=\"history-page\"></main>\n</template>\n"),
            File(path: "src/pages/login.vue", text: "<template>\n  <main class=\"login-page\"></main>\n</template>\n"),
            File(path: "src/pages/punch.vue", text: punchVue(head: false)),
            File(path: "src/router/index.js", text: "import { createRouter, createWebHistory } from 'vue-router'\n\nexport default createRouter({ history: createWebHistory(), routes: [] })\n"),
            File(path: "src/stores/punch.js", text: "import { defineStore } from 'pinia'\n\nexport const usePunchStore = defineStore('punch', {})\n"),
            File(path: "node_modules/x/index.js", text: "module.exports = 'ignored dependency'\n"),
            File(path: ".env.local", text: "# mock only, ignored; no secrets\nVITE_API_BASE=http://127.0.0.1:9/api\n"),
        ]
    }

    /// punch.vue as the FileEditor artboard shows it (lines 13–49), its HEAD (`position: fixed;
    /// bottom: 0;`, no `sticky` on line 33), and variants for the saved and disk versions.
    nonisolated static func punchVue(head: Bool, margin: String = "64px", zIndex: Int = 10) -> String {
        let style = head ? ["  position: fixed;", "  bottom: 0;"]
            : ["  position: sticky;", "  bottom: env(safe-area-inset-bottom);", "  margin-bottom: \(margin); /* 底部導覽列高度 */",
               "  z-index: \(zIndex);"]
        let button = head ? "      <PunchButton :loading=\"store.pending\" @punch=\"store.punch\" />"
            : "      <PunchButton :loading=\"store.pending\" sticky @punch=\"store.punch\" />"
        let lines = [
            "<script setup>",
            "import { computed, onMounted } from 'vue'",
            "import { useBreakpoints } from '@vueuse/core'",
            "import PunchButton from '@/components/PunchButton.vue'",
            "import PunchRecordCard from '@/components/PunchRecordCard.vue'",
            "import { usePunchStore } from '@/stores/punch'",
            "",
            "const store = usePunchStore()",
            "const breakpoints = useBreakpoints({ sm: 640 })",
            "const isNarrow = breakpoints.smaller('sm')",
            "const records = computed(() => store.todayRecords)",
            "",
            "onMounted(() => store.fetchToday())",
            "</script>",
            "",
            "<template>",
            "  <main class=\"punch-page\">",
            "    <header class=\"punch-head\">",
            "      <h1 class=\"text-lg font-bold\">今日打卡</h1>",
            "      <span class=\"text-sm text-stone-500\">{{ store.todayLabel }}</span>",
            "    </header>",
            "    <template v-if=\"isNarrow\">",
            "      <PunchRecordCard v-for=\"r in records\" :key=\"r.id\" :record=\"r\" />",
            "    </template>",
            "    <table v-else class=\"punch-table\">",
            "      <tr v-for=\"r in records\" :key=\"r.id\">",
            "        <td>{{ r.typeLabel }}</td>",
            "        <td class=\"tabular-nums\">{{ r.time }}</td>",
            "        <td class=\"truncate\">{{ r.location }}</td>",
            "      </tr>",
            "    </table>",
            "    <div class=\"punch-sticky\">",
            button,
            "    </div>",
            "  </main>",
            "</template>",
            "",
            "<style scoped>",
            ".punch-sticky {",
        ] + style + [
            "}",
            ".punch-page {",
            "  min-height: 100dvh;",
            "  padding-bottom: calc(64px + env(safe-area-inset-bottom));",
            "}",
            "@media (max-width: 640px) {",
            "  .punch-table { display: none; }",
            "  .punch-sticky { padding: 0 16px; }",
            "  .punch-head h1 { font-size: 1.125rem; }",
            "  /* sticky 在 iOS Safari 需要父層不是 overflow: hidden */",
            "  .punch-page:has(.punch-sticky) { overflow: visible; }",
            "}",
            "</style>",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func punchButton(work: Bool) -> String {
        let props = work ? "defineProps({ loading: Boolean, sticky: Boolean })" : "defineProps({ loading: Boolean })"
        let button = work ? "  <button class=\"punch-btn\" :class=\"{ 'is-sticky': sticky }\" type=\"button\" :disabled=\"loading\" @click=\"$emit('punch')\">"
            : "  <button class=\"punch-btn\" type=\"button\" :disabled=\"loading\" @click=\"$emit('punch')\">"
        return "<script setup>\n\(props)\ndefineEmits(['punch'])\n</script>\n\n<template>\n\(button)\n"
            + "    {{ loading ? '打卡中…' : '上班打卡' }}\n  </button>\n</template>\n"
    }

    nonisolated static func tailwind(work: Bool) -> String {
        let extend = work ? "    extend: {\n      spacing: {\n        'safe-b': 'env(safe-area-inset-bottom)',\n      },\n    },\n" : "    extend: {},\n"
        return "/** @type {import('tailwindcss').Config} */\nexport default {\n  content: ['./index.html', './src/**/*.{vue,js}'],\n"
            + "  theme: {\n\(extend)  },\n  plugins: [],\n}\n"
    }
}

/// `~` expansion without the main actor (`PathFormat` lives in CoddUI's main-actor world).
enum PathFormatShim {
    nonisolated static func expandTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
        return path
    }
}
