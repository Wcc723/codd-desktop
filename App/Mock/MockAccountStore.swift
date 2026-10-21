import Foundation
import Observation

/// In-memory `AccountStore` with the three SPEC §5 accounts. `switchTo` flips the active
/// account at once (R3); it never calls cswap.
@MainActor @Observable
final class MockAccountStore: AccountStore {
    private(set) var accounts: [AccountVM]
    private(set) var activeAccountID: AccountID? = "3"
    var autoSwitch = AutoSwitchConfig()
    var followingSessionCount = 12
    private(set) var switchState: AccountSwitchState = .idle
    var availability: AccountAvailability { .ready }
    /// D29: these are the SPEC §5 sample accounts.
    var isPlaceholder: Bool { true }
    var sourceLabel: String? { "cswap 0.26.0" }

    init() {
        accounts = AccountOrdering.byWeeklyReset(MockData.accounts())
        for account in accounts { account.hasSessionProfile = account.id != activeAccountID }
    }

    func account(_ id: AccountID) -> AccountVM? { accounts.first { $0.id == id } }

    /// s11 (`#2 · cswap run`) is the SPEC's one pinned session.
    func pinnedCount(for id: AccountID) -> Int { id == "2" ? 1 : 0 }

    var newSessionAccountOptions: [NewSessionAccountOption] {
        AccountPinOptions.build(accounts: accounts, activeID: activeAccountID)
    }

    func switchTo(_ id: AccountID, reason: AccountSwitchReason) async -> AccountSwitchOutcome {
        guard let target = account(id), !target.isPseudo else { return .refused("沒有這個帳號") }
        guard id != activeAccountID else { return .alreadyActive }
        let previous = activeAccountID
        activeAccountID = id
        return .switched(from: previous, to: id, following: followingSessionCount)
    }

    func refresh(userInitiated: Bool) async {}
}
