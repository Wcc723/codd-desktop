import Foundation
import TermSpikeKit

/// Plain-text and Markdown rows for bench results (shared by stdout and RESULTS.md).
enum BenchTable {
    struct Rows {
        var throughput: [[String]] = []
        var memory: [[String]] = []
        var marginal: [[String]] = []
        var budget: [[String]] = []
        var latency: [[String]] = []
        var flood: [[String]] = []
        var errors: [String] = []
        var warnings: [String] = []
    }

    static let throughputHeader = ["ENGINE", "MODE", "STREAM", "RENDERER", "ON SCREEN", "GRID", "RUNS (s)", "MEDIAN (s)", "MiB/s", "PEAK fp MiB"]
    static let memoryHeader = [
        "ENGINE", "CONFIG", "LIVE", "BASE fp", "TOTAL fp", "Δ fp", "Δ fp / INSTANCE", "TOTAL rss", "THREADS",
        "IDLE CPU %", "STREAMING PEAK fp", "STREAMING CPU %", "HIDDEN AS",
    ]
    static let budgetHeader = ["ENGINE", "CONFIG", "15 SESSIONS IDLE fp", "15 SESSIONS, 1 STREAMING, PEAK fp", "BUDGET < 300 MB (286.1 MiB)", "IDLE CPU (budget < 0.5 %)"]
    /// 300 MB (decimal, as written in docs/ARCHITECTURE.md) in MiB.
    static let memoryBudgetMiB = 300_000_000.0 / 1_048_576
    static let marginalHeader = ["ENGINE", "MARGINAL fp PER HIDDEN INSTANCE (6→15)", "FIRST INSTANCE fp (incl. engine init)"]
    static let latencyHeader = ["ENGINE", "keyDown→ptyWrite", "keyDown→engine output", "keyDown→echo fed", "UNMATCHED", "INPUT SOURCE"]
    static let floodHeader = [
        "ENGINE", "MODE", "ON SCREEN", "GRID", "FILE MiB", "SECONDS", "MiB/s (budget >= 143)", "Ctrl+C → STOPPED ms (budget < 50)",
        "READ PAUSES", "MAX QUEUED MiB", "PEAK fp MiB", "FLOW CONTROL",
    ]
    /// 150 MB/s (decimal, docs budget) in MiB/s.
    static let floodBudgetMiBps = 150_000_000.0 / 1_048_576

    static func rows(_ report: BenchReport) -> Rows {
        var rows = Rows()
        for result in report.results {
            if let error = result.error {
                rows.errors.append("\(result.spec.label): \(error)")
            }
            for warning in result.warnings ?? [] {
                rows.warnings.append("\(result.spec.label): \(warning)")
            }
            if let value = result.throughput {
                let mode = result.spec.engine == "swiftterm-headless" ? "headless" : (result.spec.visible ? "visible" : "hidden")
                let onScreen = mode == "visible" ? (value.visibleOnScreen ? "yes" : "**NO**") : "-"
                rows.throughput.append([
                    result.spec.engine, mode, result.spec.streamVariant, value.renderer, onScreen, value.grid,
                    value.seconds.map { f2($0) }.joined(separator: " / "),
                    f3(value.medianSeconds), f1(value.mibPerSecond), mib(value.peakFootprintMiB),
                ])
            }
            if let value = result.memory {
                rows.memory.append([
                    result.spec.engine, result.spec.configLabel, "\(value.instances)",
                    mib(value.baseline.footprintMiB), mib(value.loaded.footprintMiB),
                    mib(value.deltaFootprintMiB), mib(value.perInstanceFootprintMiB),
                    mib(value.loaded.residentMiB),
                    "\(value.baseline.threads)→\(value.loaded.threads)",
                    value.idleCPUPercent.map { f2($0) } ?? "-",
                    value.streamingPeakFootprintMiB.map { mib($0) } ?? "-",
                    value.streamingCPUPercent.map { f1($0) } ?? "-",
                    value.hiddenStrategy,
                ])
                if value.instances == 15 {
                    let streaming = value.streamingPeakFootprintMiB
                    let worst = max(value.loaded.footprintMiB, streaming ?? 0)
                    rows.budget.append([
                        result.spec.engine, result.spec.configLabel,
                        mib(value.loaded.footprintMiB),
                        streaming.map { mib($0) + (value.visibleOnScreen == false ? " (window off screen)" : "") } ?? "-",
                        (worst < memoryBudgetMiB ? "within" : "**OVER** by \(mib(worst - memoryBudgetMiB))")
                            + (value.visibleOnScreen == false ? " (not comparable: window off screen)" : ""),
                        value.idleCPUPercent.map { ($0 < 0.5 ? "" : "**OVER** ") + f2($0) + " %" } ?? "-",
                    ])
                }
            }
            if let value = result.keyLatency {
                rows.latency.append([
                    "\(result.spec.engine) #\(result.spec.round)",
                    latency(value.keyToWrite),
                    value.keyToEmit.map { latency($0) } ?? "-",
                    latency(value.keyToEcho),
                    "\(value.unmatched)/\(value.keys)",
                    value.inputSource,
                ])
            }
        }
        for result in report.results {
            guard let value = result.ptyFlood else { continue }
            let mode = result.spec.visible ? "visible" : "hidden"
            let speed = f1(value.mibPerSecond) + (value.mibPerSecond >= floodBudgetMiBps ? "" : " **under**")
            let interrupt = value.interruptLatency
            var interruptText = interrupt.count == 0 ? "n=0" : latency(interrupt) + (interrupt.max < 50 ? "" : " **over**")
            if value.interruptTimeouts > 0 { interruptText += " · **\(value.interruptTimeouts) did not stop**" }
            rows.flood.append([
                result.spec.engine, mode, result.spec.visible ? (value.visibleOnScreen ? "yes" : "**NO**") : "-",
                value.grid, "\(value.fileBytes >> 20)", f2(value.seconds), speed, interruptText,
                "\(value.pauses)", f1(value.maxQueuedMiB),
                mib(value.peakFootprintMiB), value.flowControl,
            ])
        }
        for engine in ["ghostty", "swiftterm"] {
            // Same configuration across N only (Ghostty: the blink-off series).
            let memory = report.results.filter { $0.spec.engine == engine && $0.spec.isMainSeries }.compactMap(\.memory)
            guard let one = memory.first(where: { $0.instances == 1 }) else { continue }
            var marginal = "-"
            if let six = memory.first(where: { $0.instances == 6 }), let fifteen = memory.first(where: { $0.instances == 15 }) {
                marginal = mib((fifteen.loaded.footprintMiB - six.loaded.footprintMiB) / 9)
            } else if let six = memory.first(where: { $0.instances == 6 }) {
                marginal = mib((six.loaded.footprintMiB - one.loaded.footprintMiB) / 5) + " (1→6)"
            }
            rows.marginal.append([engine == "ghostty" ? "ghostty (cursor-style-blink=false)" : engine, marginal, mib(one.deltaFootprintMiB)])
        }
        return rows
    }

    static func render(_ report: BenchReport) -> String {
        let rows = rows(report)
        var out: [String] = []
        let bytes = report.results.compactMap(\.throughput).first?.bytes ?? 0
        out.append("THROUGHPUT  \(bytes >> 20) MiB ANSI stream, \(FeedLoop.chunkBytes >> 10) KiB chunks, time until fully parsed (\(report.build) build)")
        out.append(text(throughputHeader, rows.throughput))
        out.append("")
        out.append("MEMORY  phys_footprint (fp) / resident (rss) in MiB; 1 visible + N-1 hidden, each on a live `zsh -f` PTY with history fed")
        out.append(text(memoryHeader, rows.memory))
        out.append(text(marginalHeader, rows.marginal))
        out.append(text(budgetHeader, rows.budget))
        out.append("")
        out.append("KEY LATENCY  synthetic 'a' keyDowns (NSApp.sendEvent) into a PTY running /bin/cat, ms")
        out.append(text(latencyHeader, rows.latency))
        if !rows.flood.isEmpty {
            out.append("")
            out.append("PTY FLOOD  /bin/cat of the stream file through a real PTY; Ctrl+C mid-flood until the child exited and all read output was parsed")
            out.append(text(floodHeader, rows.flood))
        }
        if !rows.errors.isEmpty {
            out.append("")
            out.append("ERRORS")
            out.append(contentsOf: rows.errors.map { "  " + $0 })
        }
        if !rows.warnings.isEmpty {
            out.append("")
            out.append("WARNINGS")
            out.append(contentsOf: rows.warnings.map { "  " + $0 })
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func text(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    static func markdown(_ header: [String], _ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "_no data_" }
        var lines = ["| " + header.joined(separator: " | ") + " |"]
        lines.append("|" + header.map { _ in "---" }.joined(separator: "|") + "|")
        for row in rows {
            lines.append("| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func latency(_ summary: LatencySummary) -> String {
        guard summary.count > 0 else { return "n=0" }
        return "p50 \(f3(summary.p50)) · p95 \(f3(summary.p95)) · p99 \(f3(summary.p99)) · max \(f3(summary.max)) (n=\(summary.count))"
    }

    static func f1(_ value: Double) -> String { String(format: "%.1f", value) }
    static func f2(_ value: Double) -> String { String(format: "%.2f", value) }
    static func f3(_ value: Double) -> String { String(format: "%.3f", value) }
    static func mib(_ value: Double) -> String { String(format: "%.1f", value) }
}
