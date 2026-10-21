# CoddHost

Host metrics for the STATUS page HOST cards and the footer host line (`cpu 23% · mem 21/36G · bat 86%`), M3 D26 / D36. Darwin, Foundation and IOKit only. There is no AppKit and no CoddCore.

| Part | Role |
|---|---|
| `HostSample` | One reading: CPU (user + sys, load, cores), memory (used / total, app / wired / compressed, pressure), disk (free / total, volume name), swap, battery, boot time, host name. Plain `Sendable` values with public initializers for mocks. |
| `HostSampler` | `sample()` blocks and is cheap. It never throws, keeps the previous CPU ticks under a `Mutex`, and returns `cpu == nil` on its first sample. `footprint(pid:)` gives `ri_phys_footprint` and the resident size. |
| `HostHistory` | Ring of the last `capacity` (120 = 10 min at 5 s) CPU totals and memory fractions, oldest first, plus `cpuPeak`. |
| `ByteText.short` | `21.4G`, `412G`, `1T`, `412MB`, `1.2G`, `0B` (rules in the doc comment). |
| `MainThreadLatencyProbe` | A 1 Hz utility-queue timer posts a block to the main queue and records the wait. It keeps the last 300 waits, `p99Milliseconds` is nil before 10 of them, and `start` / `stop` are idempotent. |

```sh
swift test --package-path Packages/CoddHost --scratch-path .build-m3-host
```

## Sources

| Figure | Source |
|---|---|
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, with the per-processor ticks summed. This is the same total as `host_cpu_load_info`, see below. User includes nice. `total = user + system`. |
| Load, cores | `getloadavg`, `hw.logicalcpu` |
| Memory | `host_statistics64(HOST_VM_INFO64)`: app = internal - purgeable pages, wired, compressed = compressor pages; used = app + wired + compressed; total = `hw.memsize` |
| Pressure | `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical |
| Disk | The volume of `diskPath` (default home): total capacity and localized name. Available = statfs free space + the purgeable share from the last `volumeAvailableCapacityForImportantUsage` lookup. |
| Swap | `vm.swapusage` |
| Battery | `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList`, internal battery only (nil on desktops) |
| Boot, name | `kern.boottime`; `gethostname` without `.local` (no DNS, unlike `ProcessInfo.hostName`) |

## Why not the obvious calls

- **`host_statistics(HOST_CPU_LOAD_INFO)` is rate limited.** For processes that are not Apple platform binaries, XNU serves only 2 to 10 fresh answers per flavor per second, counted across the whole system. After that it returns a cached copy. Measured here, 34 of 40 reads 25 ms apart came back identical. `host_processor_info` has no such limit and costs about 20 µs. Memory still uses `host_statistics64`, so a memory figure can be up to a second old. That is harmless at 5 s and 30 s sampling.
- **`volumeAvailableCapacityForImportantUsage` is slow.** It asks the cache-delete service for purgeable space, which costs 7 to 25 ms, and 20 ms cold. The first sample of a sampler does this lookup inline, so the first DISK figure already counts purgeable space. After that, the lookup runs on a utility queue at most once per `importantUsageRefresh` (60 s), and every sample adds the last purgeable share to the cheap statfs free figure.

## Cost on the M-series MacBook Pro this was built on (16 cores, 64 GB)

`sample()`: first call about 20 ms (the inline important-usage lookup and the first Foundation volume lookup), then a median of 0.1 ms over 50 (p90 0.12 ms, max 0.3 ms). The probe costs one tiny main-queue block per second.

## Integration notes

- Call `sample()` off the main actor. Use one sampler per cadence (STATUS at 5 s, the footer at 30 s): the CPU figure is the average since that sampler's previous call.
- Feed the STATUS sampler into a `HostHistory` that is kept while CODD runs (D26).
- Keep one `MainThreadLatencyProbe` for the app. `stop()` keeps the recorded waits, so a paused STATUS still shows the last p99, and `reset()` clears them.
- `HostSampler.footprint()` for CODD's own RSS card. It returns `physFootprint`, which is what Activity Monitor shows, and `resident`.
