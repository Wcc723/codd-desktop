import Foundation
import Testing
@testable import CoddPreferences

/// M4 interface zoom: the ⌘+ / ⌘− / ⌘0 steps on the two font sizes, their clamping and their
/// persistence in preferences.json.
@Suite("Interface zoom steps")
struct InterfaceZoomTests {
    typealias A = CoddPreferences.Appearance

    @Test func stepsMoveBothSizesAndKeepTheirOffset() {
        var a = A(uiFontSize: 13, terminalFontSize: 15)
        a = a.zoomed(by: 1)
        #expect(a.uiFontSize == 14 && a.terminalFontSize == 16)
        a = a.zoomed(by: -1).zoomed(by: -1)
        #expect(a.uiFontSize == 12 && a.terminalFontSize == 14)
        #expect(a.terminalFontSize - a.uiFontSize == 2, "the offset survives the steps")
    }

    @Test func eachSizeClampsToItsOwnRange() {
        var a = A(uiFontSize: 19, terminalFontSize: 19)
        for _ in 0..<20 { a = a.zoomed(by: 1) }
        #expect(a.uiFontSize == 20, "UI 字級 stops at 20")
        #expect(a.terminalFontSize == 28, "the terminal keeps going to 28")
        #expect(!a.canZoom(by: 1))
        #expect(a.canZoom(by: -1))
        for _ in 0..<40 { a = a.zoomed(by: -1) }
        #expect(a.uiFontSize == 10 && a.terminalFontSize == 8)
        #expect(!a.canZoom(by: -1))
        #expect(A.uiFontSizeRange == 10...20 && A.terminalFontSizeRange == 8...28)
    }

    @Test func oneStepAtABoundMovesOnlyTheOther() {
        let a = A(uiFontSize: 20, terminalFontSize: 13)
        #expect(a.canZoom(by: 1))
        let b = a.zoomed(by: 1)
        #expect(b.uiFontSize == 20 && b.terminalFontSize == 14)
    }

    @Test func resetReturnsTheUIToThirteenAndKeepsTheRest() {
        let a = A(crt: .full, uiFontSize: 17, terminalFont: "Menlo", terminalFontSize: 22)
        let reset = a.zoomReset()
        #expect(reset.uiFontSize == 13 && reset.terminalFontSize == 22, "a terminal size set in Settings is not a zoom")
        #expect(reset.crt == .full && reset.terminalFont == "Menlo")
        #expect(reset.isActualSize && !a.isActualSize)
        #expect(A().isActualSize)
    }

    /// M4 fix: ⌘0 never overwrites the 終端機字級 the user chose, and takes back exactly what
    /// ⌘+ / ⌘− did, also after steps at a bound.
    @Test func resetTakesBackOnlyTheZoomSteps() {
        let chosen = A(uiFontSize: 13, terminalFontSize: 16)
        #expect(chosen.isActualSize, "UI 13 with the user's own terminal size: ⌘0 is disabled")
        var a = chosen.zoomed(by: 1).zoomed(by: 1)
        #expect(a.uiFontSize == 15 && a.terminalFontSize == 18 && a.zoomTerminalSteps == 2)
        #expect(a.zoomReset() == chosen)
        // At UI 20 the terminal keeps moving; ⌘0 still lands on the chosen size.
        a = A(uiFontSize: 19, terminalFontSize: 16)
        for _ in 0..<4 { a = a.zoomed(by: 1) }
        #expect(a.uiFontSize == 20 && a.terminalFontSize == 20 && a.zoomTerminalSteps == 4)
        #expect(a.zoomReset().terminalFontSize == 16 && a.zoomReset().uiFontSize == 13)
        // A− / A+ while zoomed is the user's choice: kept by ⌘0.
        a = chosen.zoomed(by: 2)
        a.terminalFontSize += 1
        #expect(a.zoomReset().terminalFontSize == 17)
        // The terminal's own bound: only its actual moves count.
        a = A(uiFontSize: 13, terminalFontSize: 27)
        for _ in 0..<3 { a = a.zoomed(by: 1) }
        #expect(a.terminalFontSize == 28 && a.zoomTerminalSteps == 1 && a.zoomReset().terminalFontSize == 27)
    }

    @Test func zoomedSizesPersistAndOutOfRangeValuesAreClamped() throws {
        try withStore { store, _ in
            var p = CoddPreferences.defaults
            p.appearance = p.appearance.zoomed(by: 1).zoomed(by: 1)
            try store.save(p)
            let (loaded, origin) = PreferencesStore(url: store.url).load()
            #expect(origin == .loaded)
            #expect(loaded.appearance.uiFontSize == 15 && loaded.appearance.terminalFontSize == 15)
            #expect(loaded.value(atPath: "appearance.uiFontSize") == "15")

            var object = try readObject(store.url)
            object = setting(object, "appearance.uiFontSize", 4)
            object = setting(object, "appearance.terminalFontSize", 40)
            try write(object, to: store.url)
            let (clamped, repaired) = PreferencesStore(url: store.url).load()
            #expect(clamped.appearance.uiFontSize == 10 && clamped.appearance.terminalFontSize == 28)
            #expect(repaired == .repaired("appearance.uiFontSize, appearance.terminalFontSize"))
        }
    }

    @Test func setPrefPathsClampLikeTheFile() throws {
        var p = CoddPreferences.defaults
        try p.apply(assignment: "appearance.uiFontSize=18")
        try p.apply(assignment: "appearance.terminalFontSize=7")
        #expect(p.appearance.uiFontSize == 18 && p.appearance.terminalFontSize == 8)
        try p.set("25", atPath: "appearance.uiFontSize")
        #expect(p.value(atPath: "appearance.uiFontSize") == "20")
    }
}
