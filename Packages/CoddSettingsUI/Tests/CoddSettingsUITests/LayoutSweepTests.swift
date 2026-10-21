import AppKit
import CoddUI
import Testing
@testable import CoddSettingsUI

/// M4 layout sweep: the rules that keep every section usable from the 860 pt Settings window at
/// UI 字級 13 to UI 字級 20 (renders: `scripts/m4-layout-sweep.sh … settings`). Pure geometry at
/// a zoom runs in `UIZoom.withScale`.
@MainActor
@Suite struct SettingsLayoutSweepTests {
    private static let zoom20: CGFloat = 20.0 / 13.0

    @Test func aRowStacksItsControlsOnlyWhenTheLabelColumnWouldBeASliver() {
        // 600 wide, 16 padding, 24 gap, 200 of controls: 344 left for the labels.
        #expect(!SxRow.stacks(rowWidth: 600, padding: 16, gap: 24, controls: 200, minimumLabel: 160))
        #expect(!SxRow.stacks(rowWidth: 600, padding: 16, gap: 24, controls: 384, minimumLabel: 160), "exactly 160 left")
        #expect(SxRow.stacks(rowWidth: 600, padding: 16, gap: 24, controls: 385, minimumLabel: 160))
        #expect(SxRow.stacks(rowWidth: 300, padding: 16, gap: 24, controls: 46, minimumLabel: 300))
    }

    @Test func thePageHeadMovesItsButtonsUnderTheTitleBeforeCuttingIt() {
        #expect(!SxPageHead.wrapsActions(width: 600, heading: 300, marks: 0, actions: 200))
        #expect(SxPageHead.wrapsActions(width: 499, heading: 300, marks: 0, actions: 200))
        #expect(!SxPageHead.wrapsActions(width: 100, heading: 300, marks: 0, actions: 0), "no buttons, nothing to move")
    }

    @Test func narrowSectionsKeepTwentyAtTheSides() {
        #expect(SettingsSectionView.insets(width: 900).left == 40 && SettingsSectionView.insets(width: 900).right == 40)
        #expect(SettingsSectionView.insets(width: 599).left == 20)
        UIZoom.withScale(Self.zoom20) {
            #expect(SettingsSectionView.insets(width: 900).left == UIZoom.pt(20), "900 is narrow at UI 20 (under 923)")
            #expect(SettingsSectionView.insets(width: 1000).left == UIZoom.pt(40))
        }
    }

    @Test func theNotificationMatrixDropsTheHintThenStacks() {
        // 16 | 150 | 16 | hint | 16 | 150 | 16 | 44 | 16 | 44 | 16 at UI 13.
        let fixed: CGFloat = 16 + 150 + 16 + 16 + 150 + 16 + 44 + 16 + 44 + 16
        #expect(MatrixRowView.columns(width: fixed + 60).arrangement == .hint)
        #expect(MatrixRowView.columns(width: fixed + 59).arrangement == .grid, "the hint column folds under 60")
        #expect(MatrixRowView.columns(width: fixed).arrangement == .grid, "the grid without the hint still fits")
        #expect(MatrixRowView.columns(width: fixed - 1).arrangement == .stacked)
        let columns = MatrixRowView.columns(width: 700)
        #expect(columns.event < columns.hint && columns.hint < columns.condition && columns.condition < columns.notify
                && columns.notify < columns.sound)
        UIZoom.withScale(Self.zoom20) {
            // The 860 pt window at UI 20: a 442 pt card.
            #expect(MatrixRowView.columns(width: 442).arrangement == .stacked)
        }
    }

    @Test func theShortcutTableFoldsTheNoteAndNarrowsTheKeys() {
        // 16 | 210 | 16 | note | 16 | 120 | 16 | 64 | 16.
        let fixed: CGFloat = 16 + 210 + 16 + 16 + 120 + 16 + 64 + 16
        #expect(KeyColumns.showsNote(width: fixed + 60) && KeyColumns.keysWidth(width: fixed + 60) == 120)
        #expect(!KeyColumns.showsNote(width: fixed + 59) && KeyColumns.keysWidth(width: fixed + 59) == 90)
        let x = KeyColumns.origins(width: 500)
        #expect(x.button - x.keys == 90 + 16 && x.keys > x.action)
    }

    @Test func accountAliasesWrapTheSessionsThenTheQuotas() {
        // One line at a wide card, the sessions text on a second line, then the quotas too.
        let wide = AccountAliasRowView.Columns.make(width: 900, sessions: 120)
        #expect(!wide.sessionsOnSecondLine && !wide.quotasOnSecondLine && wide.quotaWidth >= 96 && wide.quotaWidth <= 120)
        let middle = AccountAliasRowView.Columns.make(width: 640, sessions: 120)
        #expect(middle.sessionsOnSecondLine && !middle.quotasOnSecondLine && middle.quotaWidth >= 96)
        let minimum13 = AccountAliasRowView.Columns.make(width: 548, sessions: 120)
        #expect(minimum13.quotasOnSecondLine && minimum13.quotaWidth >= 96,
                "the 860 pt window at UI 13: the quotas on their own line, never their values over the bars")
        UIZoom.withScale(Self.zoom20) {
            let narrow = AccountAliasRowView.Columns.make(width: 622, sessions: 120)
            #expect(narrow.quotasOnSecondLine && !narrow.sessionsOnSecondLine && narrow.quotaWidth >= UIZoom.pt(60))
        }
    }

    @Test func theAboutCardFoldsItsVersionGridInsteadOfCuttingValues() {
        let versions = [SettingsVersion(key: "App", value: "1.0.0"), SettingsVersion(key: "macOS", value: "27.0"),
                        SettingsVersion(key: "Claude Code", value: "2.1.302"), SettingsVersion(key: "cswap", value: "0.26.0"),
                        SettingsVersion(key: "libghostty", value: "1.2.0")]
        #expect(AboutCardView.columns(width: 900, versions: versions) == 5)
        let narrow = AboutCardView.columns(width: 300, versions: versions)
        #expect(narrow >= 1 && narrow < 5)
        #expect(AboutCardView.columns(width: 10, versions: versions) == 1)
        #expect(AboutCardView.columns(width: 300, versions: []) == 1)
        #expect(AboutCardView.height(rows: 2) - AboutCardView.height(rows: 1) == 62)
    }
}
