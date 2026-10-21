import Foundation
import Testing
@testable import CODD

/// M3 I4: the DEBUG hooks the end-to-end script relies on beyond §6 (`scripts/m3-e2e.sh` A6 / A13 /
/// A14 exercise them against the real app; these pin the parsing and the guard they depend on).
@Suite("M3 end-to-end hooks")
struct M3EndToEndHookTests {
    @Test func applyDelayParsesWithinItsRangeAndReleaseIgnoresIt() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-hooks-plan", "uninstall", "-codd-hooks-apply", "YES",
                                                        "-codd-hooks-apply-delay", "2500"], environment: [:], home: "/h")
        #expect(options.hooksPlan == "uninstall" && options.hooksApply && options.hooksApplyDelayMilliseconds == 2500)
        #expect(options.releaseSubset.hooksApplyDelayMilliseconds == nil && !options.releaseSubset.hooksApply)
        for bad in ["-1", "30001", "soon"] {
            let parsed = RealModeOptions.parse(arguments: ["CODD", "-codd-hooks-apply-delay", bad], environment: [:], home: "/h")
            #expect(parsed.hooksApplyDelayMilliseconds == nil, "\(bad)")
        }
    }

    /// A13: a settings path whose missing tail sits under a link into the real `~/.claude` is refused
    /// by the guard that now runs before the plan reads anything (the e2e checks the order).
    @Test func guardSeesThroughALinkToAMissingPathInTheRealClaudeDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codd-i4-guard-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("realclaude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".claude"))
        let target = link.appendingPathComponent("missing/settings.json")
        let verdict = ClaudeSettingsService.isDebugApplyAllowed(target: target, claudeDirGiven: true, settingsGiven: true, home: home.path)
        #expect(!verdict.allowed && verdict.reason == "the target resolves into the real ~/.claude")
        let own = base.appendingPathComponent("own/settings.json")
        #expect(ClaudeSettingsService.isDebugApplyAllowed(target: own, claudeDirGiven: true, settingsGiven: false, home: home.path).allowed)
    }
}
