import Foundation
import Testing
@testable import CoddOnboarding

@Suite("OnboardingStep and OnboardingFlow")
struct FlowTests {
    @Test("ids, titles, English labels and kickers")
    func steps() {
        #expect(OnboardingStep.allCases.map(\.id) == ["detect", "import", "hooks", "notebook", "accounts", "done"])
        #expect(OnboardingStep.allCases.map(\.title) == ["偵測環境", "匯入專案", "安裝 hooks", "筆記本與 MCP", "帳號 (cswap)", "完成"])
        #expect(OnboardingStep.importProjects.english == "IMPORT PROJECTS")
        #expect(OnboardingStep.hooks.english == "HOOKS & STATUSLINE")
        #expect(OnboardingStep.importProjects.kicker == "STEP 02 / 06 · IMPORT PROJECTS")
        #expect(OnboardingStep(id: "import") == .importProjects)
        #expect(OnboardingStep(id: "nope") == nil)
    }

    @Test("next: current → done, the following → current; the last step stays")
    func next() {
        var flow = OnboardingFlow()
        #expect(flow.current == .detect)
        #expect(flow.progress[.detect] == .current)
        #expect(flow.progress[.hooks] == .todo)
        flow.next()
        #expect(flow.current == .importProjects)
        #expect(flow.progress[.detect] == .done)
        #expect(flow.progress[.importProjects] == .current)
        for _ in 0..<10 { flow.next() }
        #expect(flow.current == .done)
        #expect(flow.isAtLastStep)
        #expect(flow.state(of: .done) == .done)
        #expect(flow.progress[.done] == .current)
    }

    @Test("skip: current → skipped (a done step stays done)")
    func skip() {
        var flow = OnboardingFlow()
        flow.next()
        flow.skip()
        #expect(flow.progress[.importProjects] == .skipped)
        #expect(flow.current == .hooks)
        _ = flow.go(to: .detect)
        flow.skip()
        #expect(flow.progress[.detect] == .done)
        #expect(flow.current == .importProjects)
    }

    @Test("back keeps every state; go(to:) only to done, skipped or current")
    func backAndGo() {
        var flow = OnboardingFlow()
        flow.next()
        flow.skip()
        flow.back()
        #expect(flow.current == .importProjects)
        #expect(flow.progress[.importProjects] == .current)
        #expect(flow.state(of: .importProjects) == .skipped)
        #expect(flow.progress[.hooks] == .todo)
        let refused = flow.go(to: .hooks)
        #expect(!refused)
        #expect(flow.current == .importProjects)
        let moved = flow.go(to: .detect)
        #expect(moved)
        #expect(flow.progress[.importProjects] == .skipped)
        let stayed = flow.go(to: .detect)
        #expect(stayed)
        flow.back()
        #expect(flow.current == .detect)
    }

    @Test("a flow restored at a step, and the final states")
    func restoredAndFinal() {
        let flow = OnboardingFlow(current: .notebook, states: [.detect: .done, .importProjects: .done, .hooks: .skipped, .done: .current])
        #expect(flow.progress[.hooks] == .skipped)
        #expect(flow.progress[.done] == .todo)
        #expect(flow.finalStates(finishing: .skipped) == ["detect": .done, "import": .done, "hooks": .skipped, "notebook": .skipped,
                                                         "accounts": .todo, "done": .todo])
        var last = OnboardingFlow(current: .done, states: [.detect: .done])
        last.next()
        #expect(last.finalStates(finishing: .skipped)["done"] == .done)
    }
}
