// MARK: - Interface zoom (M4: 顯示方式 › 放大 ⌘+ / 縮小 ⌘− / 實際大小 ⌘0)

extension CoddPreferences.Appearance {
    /// 放大 (`delta` 1) / 縮小 (−1): UI 字級 and 終端機字級 move together by `delta` pt, so their
    /// offset is kept. Each is clamped to its own range (UI 10–20, terminal 8–28): once one
    /// reaches its bound only the other keeps moving, and nothing changes once both did. The
    /// terminal's actual move is counted in ``zoomTerminalSteps`` (⌘0 takes it back).
    public func zoomed(by delta: Int) -> Self {
        var copy = self
        copy.uiFontSize = Self.clamp(uiFontSize + delta, Self.uiFontSizeRange)
        copy.terminalFontSize = Self.clamp(terminalFontSize + delta, Self.terminalFontSizeRange)
        copy.zoomTerminalSteps = Self.clamp(zoomTerminalSteps + copy.terminalFontSize - terminalFontSize, Self.zoomTerminalStepsRange)
        return copy
    }

    /// Whether ``zoomed(by:)`` changes anything (the menu item's enabled state).
    public func canZoom(by delta: Int) -> Bool { zoomed(by: delta) != self }

    /// 實際大小 ⌘0: UI 字級 back to 13, and the terminal back by what ⌘+ / ⌘− moved it (so a
    /// 終端機字級 chosen in Settings or with A− / A+ comes back, it is never reset to 13); every
    /// other field kept.
    public func zoomReset() -> Self {
        var copy = self
        copy.uiFontSize = Self().uiFontSize
        copy.terminalFontSize = Self.clamp(terminalFontSize - zoomTerminalSteps, Self.terminalFontSizeRange)
        copy.zoomTerminalSteps = 0
        return copy
    }

    /// The UI is at 13 and the terminal at the size the user chose (⌘0 has nothing to do).
    public var isActualSize: Bool { zoomReset() == self }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
