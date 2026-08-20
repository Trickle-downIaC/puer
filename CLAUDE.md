# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Puer (repo still named `gpuer`; the source file is still `GpuerApp.swift` with `@main struct GpuerApp`) is a macOS windowed app that monitors Apple Silicon CPU, GPU, and unified memory. It lives in the Dock and keeps collecting data even while its window is closed. All app code is a single Swift file, `GpuerApp.swift` — there is no test suite.

## Build & run

Primary build is the Xcode project (this is what produces a real `Puer.app` and carries the app icon):

```bash
# Regenerate the project from project.yml after changing structure (needs `brew install xcodegen`):
xcodegen generate
# Build/run: open Puer.xcodeproj in Xcode and hit Run, or from the CLI:
xcodebuild -project Puer.xcodeproj -scheme Puer -configuration Debug build
```

`Puer.xcodeproj` is committed, so opening it needs no tooling; XcodeGen + `project.yml` is only needed to regenerate it. The app target has **no App Sandbox** on purpose — it shells out to `/usr/sbin/ioreg`, `/bin/ps`, and `/usr/bin/memory_pressure`, which the sandbox would block; do not add a sandbox entitlement.

**App icon:** open `Assets.xcassets` → `AppIcon` in Xcode and drop images into the slots (or supply a single 1024² and let Xcode resize).

Quick alternative for a throwaway binary (no bundle, no icon):

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework IOKit -o Gpuer GpuerApp.swift && ./Gpuer
```

`-parse-as-library` is required there because the entry point is `@main` rather than top-level code. There is no lint or CI configuration.

## Architecture

The file is organized top-to-bottom as: data models → system-reading free functions → `SystemMonitor` (the store) → formatting helpers → SwiftUI views → `AppDelegate` (window/lifecycle wiring) → `@main`.

**Data flows one way:** free functions read the system → `SystemMonitor` (`ObservableObject`) publishes snapshots on two timers → SwiftUI views render them. System reads happen on a background `qos: .utility` queue and are marshalled back to the main queue before assigning to `@Published` properties. The fast timer (memory + GPU + per-core CPU) fires every 2s; the slow timer (process list, since `ps` is heavier) every 5s. History arrays are capped at `maxHistory = 60` samples (~2 min of the fast timer). Rate metrics that come from cumulative counters (per-core CPU, per-process CPU) are computed by diffing against a previous sample the monitor holds (`prevCPUTicks`, `prevProcCPUTime`/`prevProcSampleTime`), seeded in `init()`.

**Windowed Dock app that outlives its window:** `AppDelegate` **owns** the `SystemMonitor` (not the SwiftUI view) so the timers keep collecting after the window closes, sets `.regular` activation policy (Dock icon + standard menu), and builds a fixed-size `NSWindow`. `applicationShouldTerminateAfterLastWindowClosed` returns `false` and `applicationShouldHandleReopen` re-shows the same window (`isReleasedWhenClosed = false`) on Dock click. `ContentView` takes the monitor via `@ObservedObject` (injected), not `@StateObject`. The UI is a four-column layout (Unified Memory / GPU / CPU / Processes) under a device-wide top bar; ideal widths are tuned to sum near `windowWidth`. The SwiftUI `App.body` is still just an empty `Settings` scene — the real window is created in the delegate.

## Where the data comes from

All system stats come from public interfaces and shelling out to CLI tools — no private frameworks. When touching these, the parsing is fragile and the semantics are subtle:

- **Memory** (`readMemoryStats`): `sysctl hw.memsize` for total; `host_statistics64(HOST_VM_INFO64)` for the page-count breakdown; `sysctl vm.swapusage` for swap; shelling to `/usr/bin/memory_pressure` and text-parsing "free percentage" for pressure. The used/available formula is deliberate and has been the subject of multiple bug fixes (see git log) — `used = appMem + wired + compressed` where `appMem = active - purgeable`, and `available = total - used`. Inactive/speculative/purgeable/free are all treated as reclaimable. Do not "simplify" this without understanding why double-counting inflated the number past physical RAM.
- **GPU** (`readGPUStats`): shells to `/usr/sbin/ioreg -r -c AGXAccelerator -d 2` and **text-parses** the output for `model`, `gpu-core-count`, and the `PerformanceStatistics` dict (`Device/Renderer/Tiler Utilization %`, `In use system memory` = active, `Alloc system memory` = mapped). This is Apple-Silicon/AGX-specific; non-AGX Macs yield `Unknown` and zeros. macOS formatting changes can silently break these fields.
- **CPU load** (`readPerCoreTicks` + `computeCPUStats`): `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` for per-core cumulative ticks; usage is the busy fraction between two samples (units cancel in the ratio, so no timebase conversion needed here). Core-cluster split uses `sysctl hw.perflevel0.logicalcpu` (Performance) and `hw.perflevel1.logicalcpu` (Efficiency). **Ordering is empirically established, not guessed:** `host_processor_info` enumerates **efficiency cores first (low indices)**, then performance cores — verified on 8P+2E hardware by loading 8 threads and watching the 8 high-index cores saturate. So E-cores are indices `0..<efficiencyCount`. If a future machine mislabels the clusters, that slice is the one line to flip.
- **Pressure/thermal/swap-rate layer**: kernel verdict from `sysctl kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4 critical); thermal from `ProcessInfo.thermalState`; swap in/out MB/s from diffing the cumulative `vm_statistics64.swapins/swapouts` counters (same prev-sample pattern as CPU); the configured GPU wired limit from `sysctl iogpu.wired_limit_mb` (0 = macOS default, shown as such). A "pressure event" is kernel level leaving normal or swap-out rate exceeding 5 MB/s; the monitor timestamps it and captures the current top *growers* (per-name footprint delta over the last process refresh, threshold 50 MB) — growth, not size, because the biggest resident is rarely the cause. There is no banner or other appearing/disappearing warning UI: pressure state lives in permanent cells (PRESSURE, LAST PRESSURE, OUT RATE) that change color, and event growers are captured in the report; the app cannot see pressure events from before its own launch and labels residue accordingly.
- **Per-process memory + recent CPU** (`sampleProcesses` → aggregated in `SystemMonitor.refreshProcesses`): `ps -eo pid,rss,pcpu,comm -r` for the list, then `proc_pid_rusage(RUSAGE_INFO_V4)` per PID for both `ri_phys_footprint` (accurate memory = the "physical footprint" Activity Monitor shows, RSS fallback on failure) and cumulative CPU time. **`ri_user_time`/`ri_system_time` are in mach absolute time units, NOT nanoseconds** — `getProcUsage` converts via `mach_timebase_info` (`machTimebase`); skipping this underreports CPU by ~42× on Apple Silicon (timebase 125/3). Recent CPU% per PID is the CPU-time delta over the wall-clock window (`processWindowSeconds`, ~5s), then processes are aggregated by executable name (summing footprint and CPU) with a `(count)` suffix. The "Top CPU" list and the memory list are two views over the same aggregated array.

## Key domain concept

On Apple Silicon there is no separate VRAM: CPU and GPU share one unified memory pool. The allocation bar is an exact partition of physical memory built only from kernel and driver counters: reserved (pages in no named queue), app (internal minus purgeable, Activity Monitor's definition), wired shown as GPU In-Use plus a merged GPU Idle / Non-GPU remainder, compressed, then the reclaimable tiers of available (purgeable, speculative, file-backed, unallocated; file-backed includes live executable pages, reclaimable only at re-fault cost, so it is not called a cache). A finer GPU-vs-OS split within wired is not publicly measurable and is deliberately not guessed. The driver's "mapped" figure counts address space, can exceed wired or even total, and is shown in the GPU column as a driver claim, not as a bar segment.

Wired, distilled. Three populations share the wired count: GPU In-Use (the driver's own counter; actively-worked GPU memory, pinned by nature), GPU Idle (allocations still wired but outside the working set), and Non-GPU (the kernel's machinery: kernel text and heap, zone objects for every vnode, socket, Mach port, and process structure, kernel-thread stacks, page tables and the compressor's index, IOKit DMA and driver buffers, DART/IOMMU tables, a sliver of userland mlock; roughly 1-2 GB on any Mac, and distinct from Reserved, which is off-ledger entirely). Only In-Use is measurable; Idle and Non-GPU are shown merged because their boundary is not publicly knowable. `iogpu.wired_limit_mb` fences GPU wiring only: total WIRED can legally exceed the limit by the Non-GPU share (observed live), so never compute headroom as limit minus total wired. The headroom cell is limit minus GPU In-Use, an upper bound wearing its inequality: it can veto a plan that will not fit but never promises one will, and it is tightest under load, when In-Use captures nearly all GPU wiring. "In-Use" is kept over "Active" because it is the driver counter's own name and "active" already means the recency queue in the accounting identity.

App has no public subdivision left to mine: its pages are uniform in kind (anonymous, no backing file, must compress-then-swap to evict) but their hot/cold fate lives on recency queues that public counters do not cross-tabulate against anonymity, so a reclaimability ladder inside App would be a guess and is deliberately not made. Read the allocation readouts as one lifecycle instead: Compressed is dormant App memory in its squeezed afterlife, swap's On Disk is App in exile, and Wired is memory that opted out of the lifecycle entirely. Do not expect the Processes column to sum to App: per-process figures use phys_footprint, a different ruler that includes each process's compressed pages (double-counting against App plus Compressed), attributes shared memory by its own accounting, and the visible list truncates the daemon long-tail. Two rulers, both honest, definitionally non-summing; treat any attempt to reconcile them as a modeling error, not a bug to fix.

## Conventions

- Sizes: `formatMemory(UInt64 bytes)` and `formatMB(Double megabytes)` are the two formatters; pick by the unit you already hold.
- `MARK:` comments delimit every section — keep new code in the matching section.
- This is a "vibe coded" app (per the README) whose author does not deeply know macOS internals; be conservative and explain the reasoning when changing the measurement math.
