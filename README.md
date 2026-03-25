# Gpuer

SwiftUI menu bar app for monitoring macOS GPU and memory stats.

> [!NOTE]
> This app was vibe coded using Claude Opus 4.6 and GPT-5.4. The macOS stats shown here come from a mix of Mach VM APIs, `sysctl`, `ps`, and `ioreg`, and some of the displayed categories are approximations rather than exact Activity Monitor equivalents.

## Features

- Live Apple Silicon GPU utilization from `AGXAccelerator` `PerformanceStatistics`
- Unified memory breakdown using Mach VM stats and `sysctl`
- Swap usage display
- Top processes by resident memory and CPU from `ps`
- Two-minute sparklines for memory, GPU utilization, and GPU-tracked memory
- Menu bar popover UI built with SwiftUI

## How measurement works

Gpuer uses macOS system interfaces and command-line tools rather than private frameworks.

- Total physical memory comes from `sysctl hw.memsize`.
- Memory breakdown comes from `host_statistics64(HOST_VM_INFO64)`, using page counters such as active, inactive, wired, compressed, speculative, free, and purgeable.
- The displayed "used" memory is an approximation computed as `total - free - speculative - purgeable`.
- The displayed "app" memory is also approximate. It is currently computed as `active + inactive - purgeable`.
- Swap usage comes from `sysctl vm.swapusage`.
- The top-right memory load card is derived from `/usr/bin/memory_pressure` by parsing the reported system-wide free percentage and converting it to `1 - free%`.
- GPU model, core count, utilization, and tracked memory come from `/usr/sbin/ioreg -r -c AGXAccelerator -d 2`, specifically the `PerformanceStatistics` dictionary exposed by Apple Silicon AGX drivers.
- Per-process memory and CPU come from `ps -eo pid,rss,pcpu,comm -r`, then processes are aggregated by executable name.

Important limitations:

- GPU stats are Apple-Silicon-specific. The current implementation depends on `AGXAccelerator`, so non-AGX Macs may show `Unknown` and zeroed GPU values.
- The memory load card is not true macOS memory pressure. It is derived from free percentage, which is a weaker signal than the real VM pressure/compression behavior.
- "App" memory and "used" memory are best-effort approximations and should not be treated as exact matches for Activity Monitor categories.
- GPU tracked memory is shown as a fraction of total unified memory, not as a GPU-specific capacity limit.
- The `ioreg` parsing is text-based, so future macOS formatting changes could break some fields.
- Process totals are aggregated by binary name, which can merge multiple helpers or unrelated processes with the same executable name.

## Building

```bash
git clone https://github.com/simonw/gpuer
cd gpuer
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework IOKit -o Gpuer GpuerApp.swift
./Gpuer
```

Requires macOS and Xcode command line tools (`xcode-select --install`).
