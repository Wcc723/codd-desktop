import Testing
@testable import CoddDialogsUI

/// cswap 0.26 `normalize_alias` (D34): strip, lowercase, `^[a-z0-9_.-]+$`, not all digits, no leading `-`.
@Suite("Alias rule (cswap)")
struct AliasRuleTests {
    @Test(arguments: [
        ("studio", "studio"), (" Studio ", "studio"), ("NORTH", "north"), ("a-b_c.d", "a-b_c.d"), ("1a", "1a"),
        ("x1", "x1"), ("a.", "a."), ("_", "_"), ("work\n", "work"), ("\u{3000}lab\u{3000}", "lab"),
    ])
    func accepts(_ input: String, _ normalized: String) {
        #expect(DialogAliasRule.normalize(input) == normalized)
    }

    @Test(arguments: ["工作室", "工作", "", "   ", "123", "0", "-abc", "-", "a b", "abc!", "é", "a/b", "studio工作室", "#4"])
    func refuses(_ input: String) {
        #expect(DialogAliasRule.normalize(input) == nil)
    }

    @Test func hintIsTheD34Copy() {
        #expect(DialogAliasRule.hint == "別名只能用英文小寫、數字與 - _ .（cswap 規則）")
        #expect(AddAccountModel.aliasRuleHint == DialogAliasRule.hint)
    }

    @MainActor @Test func modelShowsTheHintOnlyForARefusedNonEmptyAlias() {
        var model = DialogSamples.addAccountStep1()
        #expect(!model.showsAliasRuleHint)
        model.alias = "工作室"
        #expect(model.showsAliasRuleHint)
        #expect(model.normalizedAlias == nil)
        model.alias = "Studio"
        #expect(!model.showsAliasRuleHint)
        #expect(model.normalizedAlias == "studio")
    }
}
