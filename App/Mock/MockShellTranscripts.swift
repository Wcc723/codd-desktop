import Foundation
import CoddUI

/// Mock zsh content: the `npm run dev` SHELL session (s8) and the ZSH tab of any session.
enum MockShellTranscripts {
    static let npmRunDev = """
    <g>dev@mbp</g> <c>orb-toolkit-backend</c> % npm run dev

    > orb-toolkit-backend@3.0.0 dev
    > vite --port 3001

      <g>VITE v7.1.4</g>  <d>ready in</d> <w>412</w> <d>ms</d>

      <g>→</g>  <w>Local</w>:   <c>http://localhost:3001/</c>
      <g>→</g>  <d>Network: use --host to expose</d>
      <g>→</g>  <d>press h + enter to show help</d>
    <d>10:00:31</d> <c>[vite]</c> <g>(ssr) page reload</g> <d>src/routes/auth.ts</d>
    <d>10:21:07</d> <c>[vite]</c> <g>(ssr) page reload</g> <d>src/middleware/auth.ts</d>
    <d>10:38:52</d> <c>[vite]</c> <g>(ssr) page reload</g> <d>src/middleware/auth.ts</d>
    <d>10:38:53</d> <c>[vite]</c> <g>(ssr) page reload</g> <d>test/auth.spec.ts</d> <d>(x2)</d>
    <d>10:39:20</d> <r>[vite] Internal server error: Cannot find module './refreshSession'</r>
             <d>at src/middleware/auth.ts:3:29</d>
    <d>10:39:41</d> <c>[vite]</c> <g>(ssr) page reload</g> <d>src/middleware/auth.ts</d>
    <d>10:39:41</d> <c>[vite]</c> <g>hmr update</g> <d>/src/routes/auth.ts</d>
    <cur> </cur>
    """

    private struct Git {
        let branch: String
        let upstream: String
        let ahead: String
        let changes: [(code: String, path: String)]
    }

    /// `git status -sb` per project (nil = not shown; `notARepo` = fatal message).
    private static let git: [ProjectID: Git] = [
        "proto": Git(branch: "main", upstream: "origin/main", ahead: "",
                     changes: [(" M", "review/README.md"), ("??", "checklist/"), ("??", "review/flow.md")]),
        "mcp": Git(branch: "main", upstream: "origin/main", ahead: "", changes: []),
        "backend": Git(branch: "fix/login-401", upstream: "origin/fix/login-401", ahead: "[ahead 2]",
                       changes: [(" M", "src/middleware/auth.ts"), (" M", "test/auth.spec.ts")]),
        "frontend": Git(branch: "feat/punch-rwd", upstream: "origin/feat/punch-rwd", ahead: "",
                        changes: [(" M", "src/components/PunchButton.vue"), (" M", "src/pages/punch.vue"),
                                  (" M", "tailwind.config.js")]),
        "invoice": Git(branch: "main", upstream: "origin/main", ahead: "", changes: [("??", "src/export/")]),
        "gear": Git(branch: "perf/scene-load", upstream: "origin/perf/scene-load", ahead: "[ahead 1]",
                    changes: [(" M", "src/scene/loader.ts")]),
    ]
    private static let notARepo: Set<ProjectID> = ["desk"]

    /// ZSH tab content for a session in `project`.
    static func zshTab(projectID: ProjectID, cwd: String) -> String {
        let dir = PathFormat.lastComponent(cwd)
        let prompt = "<g>dev@mbp</g> <c>\(dir)</c> %"
        var lines = [
            "<d>Last login: Thu Oct 15 09:58:12 on ttys004</d>",
            "\(prompt) pwd",
            cwd.replacingOccurrences(of: "~", with: "/Users/me", options: .anchored),
        ]
        if let g = git[projectID] {
            lines.append("\(prompt) git status -sb")
            lines.append("## <g>\(g.branch)</g>...<r>\(g.upstream)</r> \(g.ahead)")
            lines += g.changes.map { "<r>\($0.code)</r> \($0.path)" }
        } else if notARepo.contains(projectID) {
            lines.append("\(prompt) git status -sb")
            lines.append("fatal: not a git repository (or any of the parent directories): .git")
        }
        lines.append("\(prompt) <cur> </cur>")
        return lines.joined(separator: "\n")
    }
}
