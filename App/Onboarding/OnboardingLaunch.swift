import CoddOnboarding
import Foundation

/// D5: whether the first-launch wizard opens by itself, decided once in
/// `applicationWillFinishLaunching` right after the instance lock (before anything writes the data
/// root, so the root's own files still say whether CODD ran here before).
///
/// - The standard data root: `OnboardingGate` (no layout.json, panes.json, onboarding.json and no
///   `sessions/*/meta.json`) unless DEBUG `-codd-onboarding` says otherwise.
/// - Any other root: only with DEBUG `-codd-onboarding auto|show` (default `never`), so no earlier
///   e2e script sees the wizard; a Release build never parses the flag (never automatic there).
/// - `-codd-show onboarding[:<n>|:all]` (DEBUG): shown in both modes; mock mode only this way.
struct OnboardingLaunch: Equatable, Sendable {
    var show: Bool
    /// Why (`new-root`, `existing-root`, `flag-show`, `flag-never`, `not-standard-root`, `show-flag`,
    /// `mock-show`, `mock`): the log line and the dump's `reason`.
    var reason: String
    var start: OnboardingStep
    /// `-codd-show onboarding:all`: every step goes into the snapshot.
    var snapshotsAllSteps = false

    static let none = OnboardingLaunch(show: false, reason: "mock", start: .detect)

    /// - Parameters:
    ///   - realMode: false in mock mode (only `-codd-show onboarding` shows it there).
    ///   - root: the data root folder (real mode).
    ///   - mode: DEBUG `-codd-onboarding` (`auto`, `show`, `never`; nil = the root's default).
    ///   - show: the `-codd-show` value as parsed.
    ///   - step: DEBUG `-codd-onboarding-step`.
    ///   - isNew: the gate (tests pass their own).
    static func decide(realMode: Bool, root: URL?, standardRoot: Bool, mode: String?, show: String?, step: Int?,
                       isNew: (URL) -> Bool = OnboardingGate.isNewDataRoot) -> OnboardingLaunch {
        let request = showRequest(show)
        let start = OnboardingStep(rawValue: request?.step ?? step ?? 1) ?? .detect
        if let request {
            return OnboardingLaunch(show: true, reason: realMode ? "show-flag" : "mock-show", start: start,
                                    snapshotsAllSteps: request.all)
        }
        guard realMode else { return OnboardingLaunch(show: false, reason: "mock", start: start) }
        switch mode ?? (standardRoot ? "auto" : "never") {
        case "show":
            return OnboardingLaunch(show: true, reason: "flag-show", start: start)
        case "never":
            return OnboardingLaunch(show: false, reason: mode == nil ? "not-standard-root" : "flag-never", start: start)
        default:
            guard let root, isNew(root) else { return OnboardingLaunch(show: false, reason: "existing-root", start: start) }
            return OnboardingLaunch(show: true, reason: "new-root", start: start)
        }
    }

    /// `onboarding`, `onboarding:<1-6>` or `onboarding:all` (nil: another `-codd-show` value).
    static func showRequest(_ show: String?) -> (step: Int?, all: Bool)? {
        guard let show else { return nil }
        if show == "onboarding" { return (nil, false) }
        guard show.hasPrefix("onboarding:") else { return nil }
        let argument = show.dropFirst("onboarding:".count).lowercased()
        if argument == "all" { return (nil, true) }
        return (Int(argument).flatMap { (1...6).contains($0) ? $0 : nil }, false)
    }

    /// The flow a wizard opened on `start` begins with: the earlier steps done.
    static func flow(start: OnboardingStep) -> OnboardingFlow {
        var states: [OnboardingStep: StepProgress] = [:]
        for step in OnboardingStep.allCases where step.rawValue < start.rawValue { states[step] = .done }
        return OnboardingFlow(current: start, states: states)
    }
}

/// One `-codd-onboarding-actions` entry (DEBUG, §5): `name` and what follows its first `:`.
struct OnboardingDebugAction: Equatable, Sendable {
    var name: String
    var argument: String?

    init(_ raw: String) {
        if let colon = raw.firstIndex(of: ":") {
            name = raw[..<colon].lowercased()
            argument = String(raw[raw.index(after: colon)...])
        } else {
            name = raw.lowercased()
            argument = nil
        }
    }

    /// `<path>=<value>` of `group:` and `new-group:` (split at the last `=`).
    var pathAndValue: (path: String, value: String)? {
        guard let argument, let equals = argument.lastIndex(of: "=") else { return nil }
        let path = String(argument[..<equals])
        let value = String(argument[argument.index(after: equals)...])
        guard !path.isEmpty, !value.isEmpty else { return nil }
        return (path, value)
    }

    static let known: Set<String> = [
        "redetect", "next", "skip", "back", "goto", "filter", "check", "uncheck", "check-visible", "suggest", "group",
        "new-group", "show-hidden", "more", "hooks-preview", "hooks-apply", "reveal-notes", "mcp-preview", "notify",
        "finish", "close",
    ]
}
