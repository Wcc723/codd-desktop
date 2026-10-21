import AppKit
import CoddStatusUI
import CoddUI

/// `--accounts-sweep`: the ACCOUNTS section at several window widths (sidebar 220 + page), cropped
/// from the whole area. A fresh render lays out and draws every view at the width; a resized render
/// (`--resize-from`) draws at the first width, resizes the window in place and captures the layer
/// tree as it stands, so views that kept their old drawing show it.
@MainActor
struct AccountsSweep {
    let model: StatusPageModel
    let dir: URL
    /// Tall enough for one column of cards at the narrowest widths.
    static let height: CGFloat = 2600
    static let scale: CGFloat = 2

    func run(widths: [CGFloat], resizeFrom: CGFloat?) {
        var report: [String] = []
        for width in widths {
            fresh(width: width)
            if let resizeFrom, resizeFrom != width { report.append(resized(from: resizeFrom, to: width)) }
        }
        guard !report.isEmpty else { return }
        report.forEach { print($0) }
        try? (report.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("resize-report.txt"), atomically: true, encoding: .utf8)
    }

    private func makeArea(width: CGFloat) -> Demo.Area {
        let area = Demo.Area(actions: StatusPageActions())
        area.frame = CGRect(x: 0, y: 0, width: width, height: Self.height)
        let fixed = StatusSamples.referenceNow
        area.sidebar.now = { fixed }
        area.page.now = { fixed }
        area.sidebar.calendar = StatusSamples.calendar
        area.page.calendar = StatusSamples.calendar
        area.sidebar.apply(model)
        area.page.apply(model)
        return area
    }

    /// The ACCOUNTS section's rect in the area, with a margin for the hanging card corners.
    private func cropRect(_ area: Demo.Area) -> CGRect {
        let rect = area.convert(area.page.sectionRect(.accounts), from: area.page)
        return rect.insetBy(dx: -16, dy: -12).intersection(area.bounds)
    }

    private func fresh(width: CGFloat) {
        let area = makeArea(width: width)
        guard let rep = ViewSnapshot.render(area, size: CGSize(width: width, height: Self.height), scale: Self.scale) else {
            print("cannot render accounts at \(Int(width))")
            return
        }
        write(rep, crop: cropRect(area), name: "accounts-\(Int(width)).png")
    }

    /// Counts its draws (the live-resize probe).
    final class Probe: NSView {
        var draws = 0
        override func draw(_ dirtyRect: NSRect) {
            draws += 1
            Palette.bg.setFill()
            bounds.fill()
        }
    }

    private func resized(from start: CGFloat, to width: CGFloat) -> String {
        let area = makeArea(width: start)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: start, height: Self.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = area
        area.autoresizingMask = [.width, .height]
        // Two probes that follow the window's width, one per redraw policy.
        let policies: [NSView.LayerContentsRedrawPolicy] = [.onSetNeedsDisplay, .duringViewResize]
        let probes = policies.map { policy -> Probe in
            let probe = Probe(frame: CGRect(x: 0, y: Self.height - 2, width: start, height: 1))
            probe.wantsLayer = true
            probe.layerContentsRedrawPolicy = policy
            probe.autoresizingMask = [.width]
            area.addSubview(probe)
            return probe
        }
        settle(area)
        let sizes = Dictionary(uniqueKeysWithValues: Self.views(area).map { (ObjectIdentifier($0), $0.bounds.size) })
        let drawsBefore = probes.map(\.draws)
        // A window dragged to a new size: AppKit's live resize (the offscreen window cannot be
        // dragged, so the demo starts and ends it itself; tooling only, never in the app).
        let liveStart = NSSelectorFromString("_startLiveResize"), liveEnd = NSSelectorFromString("_endLiveResize")
        let live = window.responds(to: liveStart) && window.responds(to: liveEnd)
        if live { window.perform(liveStart) }
        let steps = 4
        for step in 1...steps {
            window.setContentSize(CGSize(width: start + (width - start) * CGFloat(step) / CGFloat(steps), height: Self.height))
            settle(area)
        }
        if live { window.perform(liveEnd) }
        settle(area)
        let draws = zip(probes, drawsBefore).map { $0.draws - $1 }
        // The page's drawn views that changed size while still on `.onSetNeedsDisplay` (the probe
        // shows what that policy does in a live resize).
        var stale: [String: Int] = [:]
        var resized = 0
        for view in Self.views(area) where !(view is Probe) && view.layer?.contents != nil {
            guard let old = sizes[ObjectIdentifier(view)], old != view.bounds.size else { continue }
            resized += 1
            if view.layerContentsRedrawPolicy == .onSetNeedsDisplay { stale[String(describing: type(of: view)), default: 0] += 1 }
        }
        window.contentView = nil
        window.close()
        let list = stale.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        return "\(Int(start)) → \(Int(width))\(live ? " live resize" : " resize") in \(steps) steps: probe draws "
            + "onSetNeedsDisplay \(draws[0]) · duringViewResize \(draws[1]); \(resized) drawn page views resized, "
            + "\(stale.values.reduce(0, +)) on onSetNeedsDisplay (keep the old drawing)\(list.isEmpty ? "" : ": " + list)"
    }

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    /// Lays out and draws every view that needs it into its layer.
    private func settle(_ area: NSView) {
        area.layoutSubtreeIfNeeded()
        area.displayIfNeeded()
        Self.displayLayers(area)
        CATransaction.flush()
    }

    private static func displayLayers(_ view: NSView) {
        view.layer?.displayIfNeeded()
        for sub in view.subviews { displayLayers(sub) }
    }

    private func write(_ rep: NSBitmapImageRep, crop: CGRect, name: String) {
        let pixels = CGRect(x: crop.minX * Self.scale, y: crop.minY * Self.scale, width: crop.width * Self.scale,
                            height: crop.height * Self.scale).integral
        guard let image = rep.cgImage?.cropping(to: pixels) else {
            print("cannot crop \(name)")
            return
        }
        let out = NSBitmapImageRep(cgImage: image)
        out.size = crop.size
        do {
            try ViewSnapshot.writePNG(out, to: dir.appendingPathComponent(name))
            print("wrote \(name) (\(Int(crop.width)) × \(Int(crop.height)) pt)")
        } catch {
            print("cannot write \(name): \(error)")
        }
    }
}
