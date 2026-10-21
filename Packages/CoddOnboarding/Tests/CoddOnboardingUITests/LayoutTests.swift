import AppKit
import CoddOnboarding
import CoddUI
import Testing
@testable import CoddOnboardingUI

@MainActor
@Suite("Layout of every step at the artboard and the minimum size")
struct LayoutTests {
    static let sizes = [Harness.artboardSize, OnboardingView.minimumContentSize]

    static var models: [(String, OnboardingViewModel)] {
        OnboardingStep.allCases.map { ("step\($0.rawValue)", OnboardingSamples.step($0)) } + [
            ("step1-problems", OnboardingSamples.step(.detect, variant: [.claudeMissing, .cswapMissing])),
            ("step2-hidden", OnboardingSamples.step(.importProjects, variant: .showHidden)),
            ("step5-nocswap", OnboardingSamples.step(.accounts, variant: .cswapMissing)),
            ("step6-granted", OnboardingSamples.step(.done, variant: .notificationsGranted)),
        ]
    }

    @Test("no ambiguous layout, the fixed bars, and the body above the footer")
    func everyStep() {
        for (name, model) in Self.models {
            for size in Self.sizes {
                let harness = Harness(model, size: size)
                defer { harness.tearDown() }
                let view = harness.view
                let label = "\(name) \(Int(size.width))x\(Int(size.height))"
                #expect(harness.allViews.filter(\.hasAmbiguousLayout).isEmpty, "\(label)")
                #expect(harness.allViews.allSatisfy { $0.frame.minX.isFinite && $0.frame.minY.isFinite && $0.frame.width >= 0 }, "\(label)")
                #expect(view.stepper.frame == CGRect(x: 0, y: 0, width: 260, height: size.height), "\(label)")
                #expect(view.footer.frame == CGRect(x: 260, y: size.height - 60, width: size.width - 260, height: 60), "\(label)")
                #expect(view.boot.frame.minX == 300 && view.boot.frame.minY == 28, "\(label)")
                let body = model.flow.current == .importProjects ? view.importView.frame : view.bodyScroll.frame
                #expect(body.maxY <= view.footer.frame.minY - 14 + 1, "\(label)")
                #expect(body.minY == view.head.frame.maxY + 20, "\(label)")
                // The stepper's rows stay above its foot.
                let lastRow = view.stepper.rows.last!.frame
                #expect(lastRow.maxY <= view.stepper.version.frame.minY, "\(label)")
            }
        }
    }

    @Test("the table: 30 px header and rows, 36 px foot, the artboard's columns at 1440")
    func table() {
        let harness = Harness()
        defer { harness.tearDown() }
        let table = harness.view.importView.table
        #expect(table.header.frame.height == 30)
        #expect(table.foot.frame.height == 36)
        #expect(harness.rows.rowViews.count == 12)
        #expect(harness.rows.rowViews.allSatisfy { $0.frame.height == 30 })
        #expect(table.columns == ImportColumns(check: 42, name: 262, path: 350, last: 118, transcripts: 112, group: 214))
        #expect(table.frame.width == 1100)
        #expect(harness.view.importView.filter.frame.size == CGSize(width: 340, height: 30))
        let select = harness.row("/Github/Gear3D")!.select
        #expect(select.frame.height == 24)
        #expect(select.frame.width == 194)
        // Everything fits without scrolling at the artboard size.
        #expect(table.scroll.frame.height == 360)
        // At the minimum size the rows scroll inside the table and the path column keeps 160 px.
        let small = Harness(size: OnboardingView.minimumContentSize)
        defer { small.tearDown() }
        let smallTable = small.view.importView.table
        #expect(smallTable.scroll.frame.height < 360)
        #expect(smallTable.columns.path >= 160)
        #expect(smallTable.columns.check + smallTable.columns.name + smallTable.columns.path + smallTable.columns.last
                + smallTable.columns.transcripts + smallTable.columns.group <= smallTable.frame.width - 2 + 1)
    }

    @Test("the stepper: 260 px, the hint at 900 px, given up at 640 px")
    func stepper() {
        let tall = Harness()
        defer { tall.tearDown() }
        #expect(tall.view.stepper.showsHint)
        #expect(!tall.view.stepper.hint.isHidden)
        #expect(tall.view.stepper.rows.map(\.frame.minX) == Array(repeating: 12, count: 6))
        let short = Harness(size: OnboardingView.minimumContentSize)
        defer { short.tearDown() }
        #expect(!short.view.stepper.showsHint)
        #expect(short.view.stepper.rows.last!.frame.maxY <= short.view.stepper.link.frame.minY)
    }

    @Test("the interface zoom scales the layout (UI 字級 15)")
    func zoom() {
        UIZoom.withScale(15.0 / 13.0) {
            let harness = Harness()
            defer { harness.tearDown() }
            #expect(harness.view.stepper.frame.width == UIZoom.pt(260))
            #expect(harness.view.footer.frame.height == UIZoom.pt(60))
            #expect(harness.rows.rowViews.first?.frame.height == UIZoom.pt(30))
            #expect(harness.allViews.filter(\.hasAmbiguousLayout).isEmpty)
        }
    }

    @Test("the PATH column keeps as many trailing components as fit (D10)")
    func pathElision() throws {
        Harness.registerFonts()
        try #require(Harness.fontsAvailable, "App/Fonts not found: the widths are JetBrains Mono's")
        let harness = Harness()
        defer { harness.tearDown() }
        let invoice = try #require(harness.row("/Project/Northstar/websites/業主/Northstar invoice system"))
        let backend = try #require(harness.row("/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend"))
        let gear = try #require(harness.row("/Github/Gear3D"))
        #expect(invoice.pathCell.displayedText == "~/…/websites/業主/Northstar invoice system")
        #expect(backend.pathCell.displayedText == "~/…/orb-toolkit-suite/orb-toolkit-backend")
        #expect(gear.pathCell.displayedText == "~/Github/Gear3D")
        #expect(invoice.pathCell.toolTip == "~/Project/Northstar/websites/業主/Northstar invoice system")
        #expect(invoice.pathCell.accessibilityValue() as? String == "~/Project/Northstar/websites/業主/Northstar invoice system")
        #expect(PathCellView.elided("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend", width: 120) == "~/…/orb-toolkit-backend")
    }
}
