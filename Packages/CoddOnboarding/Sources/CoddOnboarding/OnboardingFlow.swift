import Foundation

/// The six steps of the first-launch wizard (M5 §2.4, the Onboarding artboard's stepper).
public enum OnboardingStep: Int, CaseIterable, Sendable, Codable {
    case detect = 1, importProjects, hooks, notebook, accounts, done

    /// The key in `onboarding.json` `steps` (§2.3) and in the dump.
    public var id: String {
        switch self {
        case .detect: "detect"
        case .importProjects: "import"
        case .hooks: "hooks"
        case .notebook: "notebook"
        case .accounts: "accounts"
        case .done: "done"
        }
    }

    /// The step for an `onboarding.json` key.
    public init?(id: String) {
        guard let step = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = step
    }

    /// Stepper and page title (§2.4).
    public var title: String {
        switch self {
        case .detect: "偵測環境"
        case .importProjects: "匯入專案"
        case .hooks: "安裝 hooks"
        case .notebook: "筆記本與 MCP"
        case .accounts: "帳號 (cswap)"
        case .done: "完成"
        }
    }

    /// The structural label under the title (drawn in caps).
    public var english: String {
        switch self {
        case .detect: "DETECT"
        case .importProjects: "IMPORT PROJECTS"
        case .hooks: "HOOKS & STATUSLINE"
        case .notebook: "NOTEBOOK & MCP"
        case .accounts: "ACCOUNTS"
        case .done: "DONE"
        }
    }

    /// `STEP 02 / 06 · IMPORT PROJECTS`.
    public var kicker: String {
        "STEP \(Self.twoDigits(rawValue)) / \(Self.twoDigits(Self.allCases.count)) · \(english)"
    }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}

/// How a step shows in the stepper: done (✓, clickable), skipped (number kept, clickable), the
/// current one, or not reached yet.
public enum StepProgress: String, Sendable, Codable {
    case todo, current, done, skipped
}

/// Where the wizard is and what each step became. Pure state: the App applies the effects (import,
/// writing `onboarding.json`) and the view only reads it.
///
/// Each step keeps a settled state (todo, done or skipped) apart from being current, so going back
/// to a finished step and on again never loses what it was (`back()` keeps the states).
public struct OnboardingFlow: Sendable, Equatable {
    public private(set) var current: OnboardingStep
    /// Every step's state as the stepper draws it: `.current` for the current step, the settled
    /// state for the others.
    public private(set) var progress: [OnboardingStep: StepProgress]
    private var settled: [OnboardingStep: StepProgress]

    public init(start: OnboardingStep = .detect) {
        self.init(current: start, states: [:])
    }

    /// A flow at `current` whose other steps already have `states` (missing steps are todo;
    /// `.current` in `states` counts as todo). Samples and a reopened wizard use it.
    public init(current: OnboardingStep, states: [OnboardingStep: StepProgress]) {
        self.current = current
        var settled: [OnboardingStep: StepProgress] = [:]
        for step in OnboardingStep.allCases {
            let state = states[step] ?? .todo
            settled[step] = state == .current ? .todo : state
        }
        self.settled = settled
        progress = [:]
        refresh()
    }

    /// The settled state of `step` (todo, done or skipped), also for the current step.
    public func state(of step: OnboardingStep) -> StepProgress { settled[step] ?? .todo }

    /// The current step becomes done and the following one current (the last step stays current).
    public mutating func next() {
        settled[current] = .done
        if let following = current.next { current = following }
        refresh()
    }

    /// The current step becomes skipped (a step that was done stays done) and the following one current.
    public mutating func skip() {
        if settled[current] != .done { settled[current] = .skipped }
        if let following = current.next { current = following }
        refresh()
    }

    /// The previous step becomes current; every state is kept. No-op on the first step.
    public mutating func back() {
        guard let previous = current.previous else { return }
        current = previous
        refresh()
    }

    /// Jumps to a done or skipped step (or stays on the current one). Returns whether it moved or
    /// was already there; a step not reached yet is refused.
    @discardableResult
    public mutating func go(to step: OnboardingStep) -> Bool {
        guard step == current || settled[step] == .done || settled[step] == .skipped else { return false }
        current = step
        refresh()
        return true
    }

    public var isAtLastStep: Bool { current == .done }

    /// The `onboarding.json` `steps` member when the wizard ends now: the current step is
    /// `finishing` (done for 開始使用, skipped for 略過 or a closed window), the others their state.
    public func finalStates(finishing: StepProgress) -> [String: StepProgress] {
        var out: [String: StepProgress] = [:]
        for step in OnboardingStep.allCases {
            let state = step == current ? (settled[step] == .done ? .done : finishing) : (settled[step] ?? .todo)
            out[step.id] = state
        }
        return out
    }

    private mutating func refresh() {
        var shown = settled
        shown[current] = .current
        progress = shown
    }
}
