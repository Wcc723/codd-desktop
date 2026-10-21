import AppKit
import Testing
@testable import CoddStatusUI

/// Review fixes of the fb round (user feedback 2026-10-19): the AUTO-SWITCH switch asks for a value, so a
/// change made elsewhere while the ON confirmation is up is never turned back.
@MainActor
@Suite struct FBReviewFixTests {
    /// What the switch asked for, and the confirmation's answer held until the test gives it.
    @MainActor
    final class Recorder {
        var sets: [Bool] = []
        var toggles = 0
        var pending: (@MainActor (Bool) -> Void)?

        func actions(explicit: Bool) -> StatusPageActions {
            StatusPageActions(
                toggleAutoSwitch: { [weak self] in self?.toggles += 1 },
                confirmAutoSwitch: { [weak self] _, done in self?.pending = done },
                setAutoSwitch: explicit ? { [weak self] on in self?.sets.append(on) } : nil)
        }
    }

    /// ui-autoswitch-toggle-race: the user confirms ON after Settings › 帳號 already turned it
    /// ON: the app is asked for ON (never a toggle that would turn it OFF again).
    @Test func confirmingOnAfterItTurnedOnElsewhereKeepsItOn() throws {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let recorder = Recorder()
        harness.page.setActions(recorder.actions(explicit: true))
        let row = harness.page.accounts.autoSwitch
        _ = row.toggle.accessibilityPerformPress()
        let done = try #require(recorder.pending, "turning ON asks first")
        harness.apply(StatusSamples.model(.autoSwitchOn))
        done(true)
        #expect(recorder.sets == [true] && recorder.toggles == 0)
        // OFF asks nothing and asks for OFF.
        _ = row.toggle.accessibilityPerformPress()
        #expect(recorder.sets == [true, false] && recorder.toggles == 0)
    }

    /// Without a value setter the page toggles only while it still shows the other state.
    @Test func theToggleFallbackSkipsAStaleConfirmation() throws {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let recorder = Recorder()
        harness.page.setActions(recorder.actions(explicit: false))
        let row = harness.page.accounts.autoSwitch
        _ = row.toggle.accessibilityPerformPress()
        let stale = try #require(recorder.pending)
        harness.apply(StatusSamples.model(.autoSwitchOn))
        stale(true)
        #expect(recorder.toggles == 0, "already ON: nothing to toggle")
        harness.apply(StatusSamples.model(.spec))
        recorder.pending = nil
        _ = row.toggle.accessibilityPerformPress()
        let fresh = try #require(recorder.pending)
        fresh(true)
        #expect(recorder.toggles == 1, "still OFF: the confirmed toggle turns it ON")
    }
}
