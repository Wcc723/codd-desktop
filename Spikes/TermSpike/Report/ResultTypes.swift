import Foundation
import TermSpikeKit

// MARK: - Probe

struct ProbeReport: Codable {
    var generatedAt: String
    var build: String
    var machine: MachineInfo
    var engines: [EngineProbeResult]
}

struct EngineProbeResult: Codable {
    var engine: String
    var engineVersion: String
    var grid: String
    var answers: [ProbeInterpreter.Answer]
    var rawReplies: String
    var unclaimed: [String]
    /// Feed of the probe burst → first reply byte.
    var firstReplyMs: Double?
    var replay: ReplayCheck
    var keyModes: [KeyModeResult]
    var notes: [String]
    /// The probe window's backing scale (CSI 16 t answers in device pixels).
    var backingScale: Double?
    /// What Claude Code 2.1.300 would enable from these replies (TERM_PROGRAM unset).
    var claude: [ClaudeCapabilities.Verdict]?
    /// Keys typed after `processExited` was reported to the engine.
    var inputAfterExit: [KeyResult]?
}

struct ReplayCheck: Codable {
    var supported: Bool
    /// Reply bytes the engine wrote while (and 500 ms after) replaying.
    var replyBytes: Int
    var note: String
    /// The replayed marker is in the viewport, i.e. the history was parsed.
    var markerShown: Bool?
    /// Answers to live queries sent after the replay.
    var verdict: ReplayProbe.Verdict?
    /// Leaving the alt screen afterwards removed the marker, so the replay
    /// really entered it (needed where DECRQM 1049 is not reported).
    var altScreenConfirmed: Bool?

    /// One line, e.g. `0 reply bytes · marker drawn · modes restored · kitty flags 1 · live replies ok`.
    var summary: String {
        guard supported else { return "unsupported" }
        var parts = ["\(replyBytes) reply bytes"]
        if let markerShown {
            parts.append(markerShown ? "marker drawn" : "**marker NOT drawn** (history not parsed?)")
        }
        if let verdict {
            parts.append(verdict.allModesRestored ? "modes restored" : "**modes lost**: \(verdict.lostModes.joined(separator: ", "))")
            if !verdict.unreportedModes.isEmpty {
                let modes = verdict.unreportedModes.map(String.init).joined(separator: ", ")
                parts.append("DECRQM \(modes) not reported by the engine")
            }
            parts.append(verdict.kittyRestored ? "kitty flags \(ReplayProbe.kittyFlags)" : "**kitty flags \(verdict.kittyFlags ?? "no reply")**")
            parts.append(verdict.sentinelAnswered ? "live replies ok" : "**no live reply after replay**")
        }
        if let altScreenConfirmed {
            parts.append(altScreenConfirmed ? "alt screen confirmed (marker gone after ?1049l)" : "**alt screen NOT confirmed** (marker still shown after ?1049l)")
        }
        return parts.joined(separator: " · ")
    }
}

struct KeyModeResult: Codable {
    var mode: String
    var setup: String
    /// Keyboard input source the keys were sent under (nil in older results).
    var inputSource: String?
    /// What the engine answered to `CSI ? u` after the setup.
    var kittyFlagsReply: String
    var keys: [KeyResult]
}

struct KeyResult: Codable {
    var key: String
    var bytes: String
    var ok: Bool
    /// keyDown dispatch → first byte the engine wrote back.
    var latencyMs: Double?
}

// MARK: - Bench

struct BenchOptions {
    var quick: Bool
    var outputDirectory: URL
}

struct WorkerSpec: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case throughput
        case memory
        case keyLatency
        case ptyFlood
    }

    var kind: Kind
    /// `ghostty`, `swiftterm`, or `swiftterm-headless` (throughput only).
    var engine: String
    var visible: Bool = true
    var instances: Int = 1
    var streamPath: String = ""
    var streamBytes: Int = 0
    /// `realistic` (rare OSC 0 titles) or `title-heavy` (one segment in ten is a title).
    var streamVariant: String = "realistic"
    var runs: Int = 1
    var historyBytes: Int = 0
    var keyCount: Int = 0
    /// Extra environment for the worker process (e.g. `SPIKE_GHOSTTY_CONFIG`).
    var environment: [String: String] = [:]
    /// Repetition index for measurements repeated across processes (key latency).
    var round: Int = 1
    /// `ptyFlood`: how many times `cat` prints the stream file.
    var floodCopies: Int = 1

    init(
        kind: Kind, engine: String, visible: Bool = true, instances: Int = 1, streamPath: String = "",
        streamBytes: Int = 0, streamVariant: String = "realistic", runs: Int = 1, historyBytes: Int = 0,
        keyCount: Int = 0, environment: [String: String] = [:], round: Int = 1, floodCopies: Int = 1
    ) {
        self.kind = kind
        self.engine = engine
        self.visible = visible
        self.instances = instances
        self.streamPath = streamPath
        self.streamBytes = streamBytes
        self.streamVariant = streamVariant
        self.runs = runs
        self.historyBytes = historyBytes
        self.keyCount = keyCount
        self.environment = environment
        self.round = round
        self.floodCopies = floodCopies
    }

    /// Fields added after the first results were written default when absent.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        engine = try values.decode(String.self, forKey: .engine)
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        instances = try values.decodeIfPresent(Int.self, forKey: .instances) ?? 1
        streamPath = try values.decodeIfPresent(String.self, forKey: .streamPath) ?? ""
        streamBytes = try values.decodeIfPresent(Int.self, forKey: .streamBytes) ?? 0
        streamVariant = try values.decodeIfPresent(String.self, forKey: .streamVariant) ?? "realistic"
        runs = try values.decodeIfPresent(Int.self, forKey: .runs) ?? 1
        historyBytes = try values.decodeIfPresent(Int.self, forKey: .historyBytes) ?? 0
        keyCount = try values.decodeIfPresent(Int.self, forKey: .keyCount) ?? 0
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        round = try values.decodeIfPresent(Int.self, forKey: .round) ?? 1
        floodCopies = try values.decodeIfPresent(Int.self, forKey: .floodCopies) ?? 1
    }

    var label: String {
        let config = configLabel == "default" ? "" : " [\(configLabel)]"
        switch kind {
        case .throughput: return "throughput \(engine) \(engine == "swiftterm-headless" ? "headless" : (visible ? "visible" : "hidden"))\(streamVariant == "realistic" ? "" : " [\(streamVariant)]")\(config)"
        case .memory: return "memory \(engine) ×\(instances)\(config)"
        case .keyLatency: return "key latency \(engine) #\(round)"
        case .ptyFlood: return "pty flood \(engine) \(visible ? "visible" : "hidden")"
        }
    }

    /// Engine configuration this worker ran with, from its environment.
    var configLabel: String {
        if let ghostty = environment["SPIKE_GHOSTTY_CONFIG"] { return ghostty }
        if environment["SPIKE_SWIFTTERM_METAL"] == "0" { return "CoreGraphics renderer" }
        return "default"
    }

    /// The configuration each engine's main series uses (marginal and budget rows).
    var isMainSeries: Bool {
        switch engine {
        case "ghostty": environment["SPIKE_GHOSTTY_CONFIG"] == "cursor-style-blink=false"
        default: environment.isEmpty
        }
    }
}

struct WorkerResult: Codable {
    var spec: WorkerSpec
    var build: String
    var error: String?
    /// Conditions that make some of the numbers invalid (e.g. a "visible"
    /// run whose window was not on screen, so nothing was drawn).
    var warnings: [String]?
    var throughput: ThroughputResult?
    var memory: MemoryResult?
    var keyLatency: KeyLatencyResult?
    var ptyFlood: PTYFloodResult?
}

/// `cat` of a large file through a real PTY into the engine (budget:
/// 256 MB at >= 150 MB/s, input latency during the flood < 50 ms, measured
/// as Ctrl+C until the flood has stopped).
struct PTYFloodResult: Codable {
    var grid: String
    /// Bytes `cat` printed (file size × copies).
    var fileBytes: Int
    /// Bytes read from the PTY master (the tty's ONLCR adds a CR per LF).
    var deliveredBytes: Int
    /// Spawn → child exit seen and every byte parsed.
    var seconds: Double
    /// `fileBytes` per second.
    var mibPerSecond: Double
    var visibleOnScreen: Bool
    var renderer: String
    var flowControl: String
    /// Times the engine's backlog paused the PTY read loop.
    var pauses: Int
    /// Largest engine backlog sampled every 25 ms (Ghostty's queued bytes).
    var maxQueuedMiB: Double
    var peakFootprintMiB: Double
    /// Ctrl+C written mid-flood → child exit seen and everything read parsed.
    var interruptLatency: LatencySummary
    /// Rounds where the child had not exited 5 s after Ctrl+C.
    var interruptTimeouts: Int
}

struct ThroughputResult: Codable {
    var grid: String
    var bytes: Int
    var chunkBytes: Int
    var seconds: [Double]
    var medianSeconds: Double
    var mibPerSecond: Double
    /// The window was unoccluded at the start AND the end of the timed runs.
    var visibleOnScreen: Bool
    var renderer: String
    /// Highest phys_footprint sampled (every 25 ms) during the timed runs.
    var peakFootprintMiB: Double
}

struct MemoryResult: Codable {
    var instances: Int
    var visibleInstances: Int
    var historyBytesPerInstance: Int
    var hiddenStrategy: String
    var baseline: ProcessMemory
    var loaded: ProcessMemory
    var deltaFootprintMiB: Double
    var deltaResidentMiB: Double
    var perInstanceFootprintMiB: Double
    /// CPU over 3 idle seconds after loading, % of one core (app process only).
    var idleCPUPercent: Double?
    /// Highest phys_footprint while the visible instance streamed for 3 s.
    var streamingPeakFootprintMiB: Double?
    /// CPU while the visible instance streamed, % of one core.
    var streamingCPUPercent: Double?
    var streamedBytes: Int?
    /// The visible instance's window was unoccluded before and after streaming.
    var visibleOnScreen: Bool?
}

struct KeyLatencyResult: Codable {
    var keys: Int
    var delivery: String
    var inputSource: String
    var keyToWrite: LatencySummary
    /// keyDown → the engine handed its encoding to the host (before the hop
    /// to the PTY queue). Nil in results from older builds.
    var keyToEmit: LatencySummary?
    var keyToEcho: LatencySummary
    var unmatched: Int
}

struct BenchReport: Codable {
    var generatedAt: String
    var build: String
    var machine: MachineInfo
    var quick: Bool
    var results: [WorkerResult]
}

// MARK: - Machine

struct MachineInfo: Codable {
    var model: String
    var cpu: String
    var memoryGiB: Int
    var os: String
    var screens: String
    /// 1 / 5 / 15 minute load average when the report was made (latency is load-sensitive).
    var loadAverage: String?

    static func current() -> MachineInfo {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        return MachineInfo(
            model: sysctlString("hw.model"),
            cpu: sysctlString("machdep.cpu.brand_string"),
            memoryGiB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            screens: "",
            loadAverage: count == 3 ? loads.map { String(format: "%.2f", $0) }.joined(separator: " / ") : nil
        )
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

enum Timestamp {
    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
