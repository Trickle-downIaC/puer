# Gpuer

SwiftUI menu bar app for monitoring macOS GPU and memory stats.

> [!NOTE]
> This app was vibe coded using Claude Opus 4.6 and GPT-5.4. The macOS stats shown here come from a mix of Mach VM APIs, `sysctl`, `ps`, and `ioreg`, and some of the displayed categories are approximations rather than exact Activity Monitor equivalents.

## Features

- **"Available" headline** showing how much unified memory you can still use, with a plain-English estimate of headroom
- **Unified memory pool visualization** showing GPU-mapped memory, apps/OS, and available space as competing claims on one shared pool — no more pretending GPU has its own VRAM
- Live Apple Silicon GPU utilization from `AGXAccelerator` `PerformanceStatistics`
- **Physical footprint** for per-process memory (the same metric Activity Monitor uses) instead of RSS, which inflates numbers by counting shared pages multiple times
- Swap usage with contextual explanation
- Two-minute sparklines for available memory and GPU utilization
- Two-column menu bar popover: stats on the left, process list on the right

## How measurement works

Gpuer uses macOS system interfaces and command-line tools rather than private frameworks.

### Memory

- Total physical memory comes from `sysctl hw.memsize`.
- Memory breakdown comes from `host_statistics64(HOST_VM_INFO64)`, using page counters such as active, inactive, wired, compressed, speculative, free, and purgeable.
- **Available memory** is computed as `free + speculative + purgeable + inactive`. This represents everything the OS can reclaim on demand — not just pages that are currently unused, but also caches and inactive pages that will be freed if an app needs them.
- Swap usage comes from `sysctl vm.swapusage`.
- Memory pressure is derived from `/usr/bin/memory_pressure` by parsing the reported system-wide free percentage.

### GPU and unified memory

On Apple Silicon, there is no separate VRAM. The CPU and GPU share the same physical memory pool. Gpuer shows this as a single unified bar rather than separate sections:

- GPU model, core count, utilization, and tracked memory come from `/usr/sbin/ioreg -r -c AGXAccelerator -d 2`, specifically the `PerformanceStatistics` dictionary.
- **GPU mapped** (`Alloc system memory` from IOKit) is the total memory the GPU driver has reserved. On machines running local AI models, this can be very large (e.g. 70 GB for a large LLM) because the model weights are memory-mapped for GPU access.
- **GPU active** (`In use system memory` from IOKit) is the subset actively being read/written by the GPU right now.
- The gap between mapped and active is memory that's allocated (often wired/pinned) but idle — for example, model weights that aren't being processed this instant.
- When GPU mapped memory is large, Gpuer explains why: this memory is your RAM shared with the GPU, not separate VRAM. This is typically the reason "wired" memory appears very high on machines running local inference.

### Per-process memory

- Process list comes from `ps -eo pid,rss,pcpu,comm -r`.
- Each process's memory is measured using **physical footprint** via `proc_pid_rusage(RUSAGE_INFO_V4)` and the `ri_phys_footprint` field. This is the same metric Activity Monitor shows in its "Memory" column. It avoids the problem where RSS (Resident Set Size) double-counts shared libraries and memory-mapped files across processes.
- Processes are aggregated by executable name with a count shown (e.g. `node (10)`).
- If `proc_pid_rusage` fails for a process (e.g. insufficient permissions for system processes), Gpuer falls back to RSS from `ps`.

### Important limitations

- GPU stats are Apple-Silicon-specific. The current implementation depends on `AGXAccelerator`, so non-AGX Macs may show `Unknown` and zeroed GPU values.
- Memory pressure is derived from free percentage, which is a weaker signal than the real VM pressure/compression behavior.
- The unified pool bar shows GPU-mapped, Apps/OS, and Available as non-overlapping segments, but in reality GPU allocations overlap with the wired memory category. The bar caps GPU-mapped at `total - available` to ensure it never exceeds 100%.
- The `ioreg` parsing is text-based, so future macOS formatting changes could break some fields.
- Process aggregation by binary name can merge unrelated processes with the same executable name.

## Building

```bash
git clone https://github.com/simonw/gpuer
cd gpuer
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework IOKit -o Gpuer GpuerApp.swift
./Gpuer
```

Requires macOS and Xcode command line tools (`xcode-select --install`).
