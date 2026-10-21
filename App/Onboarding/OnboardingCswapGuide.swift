import AppKit

/// FB 「引導安裝 cswap」: step 5's guide buttons on the app (the same handlers as STATUS and
/// 設定 › 帳號; `↻ 重新偵測` is the wizard's own probe).
extension AppDelegate {
    func onboardingCopyCommand(_ command: String) {
        copyCswapGuideText(command)
        onboardingLog("onboarding action=cswap-copy")
    }

    func onboardingRunInTerminal(_ command: String) {
        let id = openCswapInstallTerminal(command)
        onboardingLog("onboarding action=cswap-terminal opened=\(id != nil)")
    }
}

extension AppDelegate {
    /// `↻ 重新偵測`: cswap's store looks for the executable again (and reads it) only while it
    /// was not found or too old; a working cswap is left alone (the probe reads it as before).
    func onboardingRelocateCswap() async {
        guard let cswap = cswapAccounts else { return }
        switch cswap.baseAvailability {
        case .noCswap, .unsupported:
            await cswap.refresh(userInitiated: true)
            onboardingLog("onboarding cswap relocated availability=\(cswap.baseAvailability.isReady ? "ready" : "not-ready")")
        default:
            break
        }
    }
}
