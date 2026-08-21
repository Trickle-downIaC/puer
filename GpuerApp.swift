import SwiftUI
import AppKit
import Darwin
import Foundation
import IOKit
import Metal

// MARK: - Data Models

struct MemoryStats {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let appBytes: UInt64  // internal minus purgeable, per Activity Monitor
    let freeCountBytes: UInt64
    let kernelOtherBytes: UInt64  // pages in no named queue; AM folds these into Used
    let purgeableBytes: UInt64
    let speculativeBytes: UInt64
    let throttledBytes: UInt64
    let swapUsedBytes: UInt64
    let swapInsBytes: UInt64   // cumulative since boot (pages * pageSize)
    let swapOutsBytes: UInt64  // cumulative since boot
    let kernelPressureLevel: Int  // kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical

    var usedFraction: Double { Double(usedBytes) / Double(max(totalBytes, 1)) }
    var freeFraction: Double { Double(freeBytes) / Double(max(totalBytes, 1)) }
    var availableBytes: UInt64 { totalBytes - usedBytes }  // exactly the four reclaimable tiers: purgeable + speculative + file-backed + unallocated
    var availableFraction: Double { Double(availableBytes) / Double(max(totalBytes, 1)) }
}

struct GPUStats {
    let deviceUtilization: Int
    let rendererUtilization: Int
    let tilerUtilization: Int
    let inUseMemory: UInt64
    let allocatedMemory: UInt64
    let coreCount: Int
    let model: String
}

struct CPUStats {
    let overall: Double            // 0-1, average across all cores
    let performance: Double        // 0-1, average across performance cores
    let efficiency: Double         // 0-1, average across efficiency cores
    let perCore: [Double]          // 0-1 per core, efficiency cores first
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int
}

// One core's cumulative CPU tick counters (from PROCESSOR_CPU_LOAD_INFO).
struct CPUCoreTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

struct ProcessMemory: Identifiable {
    let id: String
    let name: String
    let pid: Int
    let residentMB: Double
    let cpuPercent: Double  // CPU% over the last sampling window (see readTopProcesses)
    let growthMB: Double    // footprint change over the last refresh window (~5s)
}

// Per-process sample before aggregation and recent-CPU computation.
struct RawProc {
    let name: String
    let pid: Int
    let footprintMB: Double
    let cpuTimeNs: UInt64  // cumulative user+system CPU time, nanoseconds
    let psCPU: Double      // ps lifetime %CPU, used as a fallback
}

enum ProcessSortKey: String, CaseIterable {
    case memory = "Memory"
    case cpu = "CPU"
    case growth = "Growth"
    case name = "Name"
    case pid = "PID"
}

// Launch fit: the metric columns stay individually scrollable, but the window
// should open tall enough that none of them needs to scroll. Each metric
// column's scroll content reports its height, each column frame reports its
// viewport, and ContentView posts the launch deficit exactly once for the
// window to absorb. Processes is exempt: its list always scrolls.
struct ColumnContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct ColumnViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
extension Notification.Name { static let puerLaunchHeightDeficit = Notification.Name("PuerLaunchHeightDeficit") }

// MARK: - System Info Helpers

func getPhysicalMemory() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return size
}

func getVMStats() -> vm_statistics64? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()

    let result = withUnsafeMutablePointer(to: &stats) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
        }
    }

    return result == KERN_SUCCESS ? stats : nil
}

func getSwapUsage() -> UInt64 {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
    return swap.xsu_used
}

func readMemoryStats() -> MemoryStats {
    let total = getPhysicalMemory()
    let pageSize = UInt64(vm_kernel_page_size)

    guard let vm = getVMStats() else {
        return MemoryStats(totalBytes: total, usedBytes: 0, activeBytes: 0, inactiveBytes: 0,
                           wiredBytes: 0, compressedBytes: 0, freeBytes: total, appBytes: 0, freeCountBytes: 0, kernelOtherBytes: 0, purgeableBytes: 0, speculativeBytes: 0, throttledBytes: 0,
                           swapUsedBytes: 0,
                           swapInsBytes: 0, swapOutsBytes: 0, kernelPressureLevel: 1)
    }

    let active = UInt64(vm.active_count) * pageSize
    let inactive = UInt64(vm.inactive_count) * pageSize
    let wired = UInt64(vm.wire_count) * pageSize
    let compressed = UInt64(vm.compressor_page_count) * pageSize
    let freeRaw = UInt64(vm.free_count) * pageSize
    let purgeable = UInt64(vm.purgeable_count) * pageSize
    let internalMem = UInt64(vm.internal_page_count) * pageSize
    let speculative = UInt64(vm.speculative_count) * pageSize
    let throttled = UInt64(vm.throttled_count) * pageSize
    // free_count includes speculative pages on this macOS (verified against
    // vm_stat, which subtracts them before printing "Pages free"). Subtract
    // here too, or speculative is double-counted, the identity oversums, and
    // the reserved carveout clamps to zero.
    let freeCount = freeRaw > speculative ? freeRaw - speculative : 0

    // App memory per Activity Monitor's definition: internal (anonymous) pages
    // minus purgeable. The upstream code used active - purgeable, which wrongly
    // counts recently-touched file cache as app memory and misses quiet app
    // heap on the inactive queue. Used (Strict) is the bottom-up sum of every
    // tier no reclaim can touch: reserved + app + wired + compressed. Reserved
    // belongs in it because boot-carveout pages are strictly spoken for and
    // available to nothing; leaving it out silently parked it inside Available,
    // overstating that readout by the reserve. Used (Loose) is then exactly
    // Strict + purgeable (the empirical fit to Activity Monitor's Memory Used),
    // and Available is exactly the four reclaimable tiers.
    let appMem = internalMem > purgeable ? internalMem - purgeable : 0
    // Pages in no named queue: kernel allocations outside the wire count.
    // This is the bucket Activity Monitor folds into its "Memory Used".
    let named = freeCount + active + inactive + speculative + wired + compressed + throttled
    let kernelOther = total > named ? total - named : 0
    let usedApprox = kernelOther + appMem + wired + compressed
    let swap = getSwapUsage()

    return MemoryStats(
        totalBytes: total, usedBytes: usedApprox, activeBytes: active,
        inactiveBytes: inactive, wiredBytes: wired, compressedBytes: compressed,
        freeBytes: total - usedApprox, appBytes: appMem, freeCountBytes: freeCount, kernelOtherBytes: kernelOther, purgeableBytes: purgeable, speculativeBytes: speculative, throttledBytes: throttled,
        swapUsedBytes: swap,
        swapInsBytes: vm.swapins &* pageSize, swapOutsBytes: vm.swapouts &* pageSize,
        kernelPressureLevel: readKernelPressureLevel()
    )
}

// Kernel's own memory pressure verdict. 1 = normal, 2 = warn, 4 = critical.
// Falls back to 1 (normal) if the sysctl is unavailable.
func readKernelPressureLevel() -> Int {
    var v: Int32 = 1
    var sz = MemoryLayout<Int32>.size
    return sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &sz, nil, 0) == 0 ? Int(v) : 1
}

func kernelPressureName(_ level: Int) -> String {
    switch level {
    case 2: return "warn"
    case 4: return "critical"
    default: return "normal"
    }
}

func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

// MARK: - GPU Stats via IOKit

func readGPUStats() -> GPUStats {
    var model = "Unknown"
    var coreCount = 0
    var deviceUtil = 0
    var rendererUtil = 0
    var tilerUtil = 0
    var inUse: UInt64 = 0
    var allocated: UInt64 = 0

    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    proc.arguments = ["-r", "-c", "AGXAccelerator", "-d", "2"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "Unknown") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else {
        return GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "Unknown")
    }

    // Parse model
    if let range = output.range(of: "\"model\" = \"") {
        let after = output[range.upperBound...]
        if let end = after.firstIndex(of: "\"") {
            model = String(after[after.startIndex..<end])
        }
    }

    // Parse gpu-core-count
    if let range = output.range(of: "\"gpu-core-count\" = ") {
        let after = output[range.upperBound...]
        let numStr = after.prefix(while: { $0.isNumber })
        coreCount = Int(numStr) ?? 0
    }

    // Parse PerformanceStatistics
    if let range = output.range(of: "\"PerformanceStatistics\" = {") {
        let after = output[range.upperBound...]
        if let end = after.firstIndex(of: "}") {
            let block = String(after[after.startIndex..<end])
            func extractInt(_ key: String) -> Int {
                if let r = block.range(of: "\"\(key)\"=") {
                    let a = block[r.upperBound...]
                    let numStr = a.prefix(while: { $0.isNumber || $0 == "-" })
                    return Int(numStr) ?? 0
                }
                return 0
            }
            func extractUInt64(_ key: String) -> UInt64 {
                if let r = block.range(of: "\"\(key)\"=") {
                    let a = block[r.upperBound...]
                    let numStr = a.prefix(while: { $0.isNumber })
                    return UInt64(numStr) ?? 0
                }
                return 0
            }
            deviceUtil = extractInt("Device Utilization %")
            rendererUtil = extractInt("Renderer Utilization %")
            tilerUtil = extractInt("Tiler Utilization %")
            inUse = extractUInt64("In use system memory")
            allocated = extractUInt64("Alloc system memory")
        }
    }

    return GPUStats(deviceUtilization: deviceUtil, rendererUtilization: rendererUtil,
                    tilerUtilization: tilerUtil, inUseMemory: inUse, allocatedMemory: allocated,
                    coreCount: coreCount, model: model)
}

// MARK: - CPU Stats via host_processor_info

// Number of performance vs efficiency logical cores on Apple Silicon.
// perflevel0 = Performance, perflevel1 = Efficiency (verified via sysctl hw.perflevelN.name).
func perfLevelCoreCounts() -> (performance: Int, efficiency: Int) {
    func sysctlInt(_ name: String) -> Int {
        var v: Int = 0
        var sz = MemoryLayout<Int>.size
        return sysctlbyname(name, &v, &sz, nil, 0) == 0 ? v : 0
    }
    return (sysctlInt("hw.perflevel0.logicalcpu"), sysctlInt("hw.perflevel1.logicalcpu"))
}

// Reads cumulative per-core tick counters. Usage is derived by diffing two reads.
func readPerCoreTicks() -> [CPUCoreTicks] {
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    var numCPUs: natural_t = 0
    let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &infoCount)
    guard err == KERN_SUCCESS, let info = info else { return [] }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                      vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
    }
    var result: [CPUCoreTicks] = []
    result.reserveCapacity(Int(numCPUs))
    for c in 0..<Int(numCPUs) {
        let base = c * Int(CPU_STATE_MAX)
        result.append(CPUCoreTicks(
            user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
            system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
            idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
            nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        ))
    }
    return result
}

// Busy fraction (0-1) of a single core between two tick samples.
func coreBusyFraction(_ prev: CPUCoreTicks, _ curr: CPUCoreTicks) -> Double {
    let user = Double(curr.user &- prev.user)
    let system = Double(curr.system &- prev.system)
    let nice = Double(curr.nice &- prev.nice)
    let idle = Double(curr.idle &- prev.idle)
    let total = user + system + nice + idle
    guard total > 0 else { return 0 }
    return (user + system + nice) / total
}

// Empirically, host_processor_info enumerates efficiency cores first (low indices),
// then performance cores. Confirmed on 8P+2E hardware: under an 8-thread load the 8
// high-index cores saturate while indices 0-1 (the E-cores) stay partial.
func computeCPUStats(prev: [CPUCoreTicks], curr: [CPUCoreTicks]) -> CPUStats {
    let (pCount, eCount) = perfLevelCoreCounts()
    guard !curr.isEmpty, prev.count == curr.count else {
        return CPUStats(overall: 0, performance: 0, efficiency: 0, perCore: [],
                        performanceCoreCount: pCount, efficiencyCoreCount: eCount)
    }
    let perCore = (0..<curr.count).map { coreBusyFraction(prev[$0], curr[$0]) }
    func avg(_ slice: ArraySlice<Double>) -> Double {
        slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
    }
    let eSlice = perCore.prefix(min(eCount, perCore.count))
    let pSlice = perCore.suffix(from: min(eCount, perCore.count))
    return CPUStats(
        overall: avg(perCore[...]),
        performance: avg(pSlice[...]),
        efficiency: avg(eSlice),
        perCore: perCore,
        performanceCoreCount: pCount,
        efficiencyCoreCount: eCount
    )
}

// MARK: - Physical Footprint (accurate memory, same metric as Activity Monitor)

// ri_user_time / ri_system_time are reported in mach absolute time units, NOT nanoseconds.
// On Apple Silicon the timebase is ~125/3, so treating them as ns underreports CPU by ~42x.
let machTimebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()

// Returns physical footprint (bytes) and cumulative CPU time (user+system, ns) for a pid.
func getProcUsage(_ pid: Int32) -> (footprint: UInt64, cpuTimeNs: UInt64)? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), reboundPtr)
        }
    }
    guard result == 0 else { return nil }
    let cpuTicks = info.ri_user_time &+ info.ri_system_time
    let cpuTimeNs = cpuTicks / machTimebase.denom &* machTimebase.numer
    return (info.ri_phys_footprint, cpuTimeNs)
}

// MARK: - Process Sampling

// One raw per-pid sample. Recent CPU% and name-aggregation happen in SystemMonitor,
// which owns the previous sample needed to diff cumulative CPU time.
func sampleProcesses() -> [RawProc] {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-eo", "pid,rss,pcpu,comm", "-m"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var results: [RawProc] = []
    let lines = output.split(separator: "\n").dropFirst() // skip header

    for line in lines.prefix(200) {
        let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard cols.count >= 4 else { continue }
        guard let pid = Int(cols[0]) else { continue }
        guard let rssKB = Double(cols[1]) else { continue }
        guard let psCPU = Double(cols[2]) else { continue }
        var name = String(cols[3])
        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        }
        // Physical footprint (accurate) instead of RSS (inflated by shared pages).
        let usage = getProcUsage(Int32(pid))
        let mb = (usage?.footprint ?? 0) > 0 ? Double(usage!.footprint) / 1_048_576.0 : rssKB / 1024.0
        if mb < 1 { continue }
        results.append(RawProc(name: name, pid: pid, footprintMB: mb,
                               cpuTimeNs: usage?.cpuTimeNs ?? 0, psCPU: psCPU))
    }
    return results
}

// MARK: - Monitor

class SystemMonitor: ObservableObject {
    @Published var memoryStats = MemoryStats(totalBytes: 0, usedBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, freeBytes: 0, appBytes: 0, freeCountBytes: 0, kernelOtherBytes: 0, purgeableBytes: 0, speculativeBytes: 0, throttledBytes: 0, swapUsedBytes: 0, swapInsBytes: 0, swapOutsBytes: 0, kernelPressureLevel: 1)
    @Published var gpuStats = GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "")
    @Published var cpuStats = CPUStats(overall: 0, performance: 0, efficiency: 0, perCore: [], performanceCoreCount: 0, efficiencyCoreCount: 0)
    @Published var processes: [ProcessMemory] = []
    @Published var processSortKey: ProcessSortKey = .memory
    @Published var processSortAscending: Bool = false
    @Published var memoryHistory: [Double] = []  // used fraction
    // Allocation partition history: each sample is the nine bar segments as
    // fractions of total, in bar order (reserved, gpuInUse, wiredOther, app,
    // compressed, purgeable, speculative, fileBacked, unallocated).
    @Published var allocHistory: [[Double]] = []
    @Published var gpuHistory: [Int] = []  // device utilization %
    @Published var gpuMemHistory: [Double] = []  // in-use GPU memory fraction
    @Published var gpuMappedHistory: [Double] = []  // GPU-mapped memory fraction
    @Published var cpuHistory: [Double] = []  // overall CPU busy fraction

    // Window (seconds) over which per-process recent CPU% is measured; matches the slow timer.
    let processWindowSeconds = 5

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private let maxHistory = 150  // 5 min at the 2s fast-timer cadence

    // Previous samples needed to turn cumulative counters into rates.
    private var prevCPUTicks: [CPUCoreTicks] = []
    private var prevProcCPUTime: [Int: UInt64] = [:]  // pid -> cumulative CPU ns
    private var prevProcSampleTime: Double = 0        // systemUptime seconds

    // Pressure/thermal/swap-rate state (feature: smarter pressure story)
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var lowPowerMode: Bool = false
    @Published var swapInRateMBs: Double = 0
    @Published var swapOutRateMBs: Double = 0
    @Published var lastPressureEvent: Date? = nil
    @Published var lastEventGrowers: [String] = []  // "name +N MB" captured near the event
    let launchDate = Date()  // for "monitoring for N min" context in the report
    // Launch baseline for the cumulative swap-out counter; its delta since launch
    // is this session's swap writes (SESSION OUT).
    var launchSwapOutsBytes: UInt64 = 0
    var launchSwapInsBytes: UInt64 = 0
    @Published var lastSwapIODate: Date? = nil  // last moment either swap rate was nonzero
    // Effective GPU wired limit when iogpu.wired_limit_mb is unset: Metal's
    // recommendedMaxWorkingSetSize is the macOS default ceiling. Public API,
    // no elevation; 0 only where no Metal device exists (non-AGX fallback).
    let defaultWiredLimitBytes: UInt64 = MTLCreateSystemDefaultDevice().map { UInt64($0.recommendedMaxWorkingSetSize) } ?? 0
    let wiredLimitMB: Int = {  // iogpu.wired_limit_mb; 0 means macOS default (unset)
        var v: Int = 0
        var sz = MemoryLayout<Int>.size
        return sysctlbyname("iogpu.wired_limit_mb", &v, &sz, nil, 0) == 0 ? v : 0
    }()
    private var prevSwapInsBytes: UInt64 = 0
    private var prevSwapOutsBytes: UInt64 = 0
    private var prevSwapSampleTime: Double = 0
    private var latestGrowers: [String] = []          // updated every process refresh
    private var prevAggMB: [String: Double] = [:]     // name -> footprint MB last refresh

    init() {
        // Seed cumulative-counter baselines so the first samples produce sane rates.
        prevCPUTicks = readPerCoreTicks()
        prevProcSampleTime = ProcessInfo.processInfo.systemUptime
        let seed = readMemoryStats()
        launchSwapOutsBytes = seed.swapOutsBytes
        launchSwapInsBytes = seed.swapInsBytes
        prevSwapInsBytes = seed.swapInsBytes
        prevSwapOutsBytes = seed.swapOutsBytes
        prevSwapSampleTime = ProcessInfo.processInfo.systemUptime
        refresh()
        refreshProcesses()
        // Memory + GPU stats every 2s
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Process list every 5s (ps is heavier)
        slowTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshProcesses()
        }
    }

    deinit {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            // GPU first: readGPUStats shells out to ioreg (50-200ms), while the
            // memory syscall is instant. Sampling memory AFTER the subprocess
            // returns puts the two snapshots milliseconds apart instead of the
            // full subprocess latency apart; during fast model loads that skew
            // was large enough for the driver's in-use counter to exceed the
            // stale wired total and falsely zero the Non-GPU wired bucket.
            let gpu = readGPUStats()
            let mem = readMemoryStats()
            let currTicks = readPerCoreTicks()
            let cpu = computeCPUStats(prev: self.prevCPUTicks, curr: currTicks)
            if !currTicks.isEmpty { self.prevCPUTicks = currTicks }

            // Swap in/out rates from cumulative counters (same diffing pattern as CPU).
            let nowUp = ProcessInfo.processInfo.systemUptime
            let dt = nowUp - self.prevSwapSampleTime
            var inRate = 0.0, outRate = 0.0
            if dt > 0.5 {
                inRate = Double(mem.swapInsBytes &- self.prevSwapInsBytes) / dt / 1_048_576.0
                outRate = Double(mem.swapOutsBytes &- self.prevSwapOutsBytes) / dt / 1_048_576.0
            }
            self.prevSwapInsBytes = mem.swapInsBytes
            self.prevSwapOutsBytes = mem.swapOutsBytes
            self.prevSwapSampleTime = nowUp
            let thermal = ProcessInfo.processInfo.thermalState
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            // Pressure "event": kernel leaves normal, or sustained swap-out activity.
            let eventNow = mem.kernelPressureLevel > 1 || outRate > 5.0
            DispatchQueue.main.async {
                self.memoryStats = mem
                self.gpuStats = gpu
                self.cpuStats = cpu
                self.thermalState = thermal
                self.lowPowerMode = lowPower
                self.swapInRateMBs = inRate
                self.swapOutRateMBs = outRate
                if inRate > 0.05 || outRate > 0.05 { self.lastSwapIODate = Date() }
                if eventNow {
                    self.lastPressureEvent = Date()
                    if !self.latestGrowers.isEmpty { self.lastEventGrowers = self.latestGrowers }
                }

                self.memoryHistory.append(mem.usedFraction)
                if self.memoryHistory.count > self.maxHistory { self.memoryHistory.removeFirst() }

                // Allocation partition sample, same math as the bar's segments.
                let tD = Double(max(mem.totalBytes, 1))
                // Coherence clamp: a partition segment cannot exceed its parent
                // bucket; residual cross-source skew caps at the wired total
                // instead of silently zeroing the Non-GPU remainder.
                let gpuA = min(Double(gpu.inUseMemory), Double(mem.wiredBytes))
                let wOther = max(0, Double(mem.wiredBytes) - gpuA)
                let fileB = max(0, Double(mem.activeBytes) + Double(mem.inactiveBytes) - Double(mem.appBytes) - Double(mem.purgeableBytes))
                self.allocHistory.append([
                    Double(mem.kernelOtherBytes) / tD, gpuA / tD, wOther / tD,
                    Double(mem.appBytes) / tD, Double(mem.compressedBytes) / tD,
                    Double(mem.purgeableBytes) / tD, Double(mem.speculativeBytes) / tD,
                    fileB / tD, Double(mem.freeCountBytes + mem.throttledBytes) / tD
                ])
                if self.allocHistory.count > self.maxHistory { self.allocHistory.removeFirst() }

                self.gpuHistory.append(gpu.deviceUtilization)
                if self.gpuHistory.count > self.maxHistory { self.gpuHistory.removeFirst() }

                let totalMem = mem.totalBytes
                let gpuMemFrac = totalMem > 0 ? Double(gpu.inUseMemory) / Double(totalMem) : 0
                self.gpuMemHistory.append(gpuMemFrac)
                if self.gpuMemHistory.count > self.maxHistory { self.gpuMemHistory.removeFirst() }
                let gpuMappedFrac = totalMem > 0 ? Double(gpu.allocatedMemory) / Double(totalMem) : 0
                self.gpuMappedHistory.append(gpuMappedFrac)
                if self.gpuMappedHistory.count > self.maxHistory { self.gpuMappedHistory.removeFirst() }

                self.cpuHistory.append(cpu.overall)
                if self.cpuHistory.count > self.maxHistory { self.cpuHistory.removeFirst() }
            }
        }
    }

    func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let raw = sampleProcesses()
            let now = ProcessInfo.processInfo.systemUptime
            let dt = now - self.prevProcSampleTime
            let prev = self.prevProcCPUTime

            // Recent CPU% per pid from the cumulative CPU-time delta over the window.
            var newPrev: [Int: UInt64] = [:]
            newPrev.reserveCapacity(raw.count)
            var recentCPU: [Int: Double] = [:]
            for p in raw {
                newPrev[p.pid] = p.cpuTimeNs
                if dt > 0, let prevNs = prev[p.pid], p.cpuTimeNs >= prevNs {
                    recentCPU[p.pid] = Double(p.cpuTimeNs - prevNs) / 1_000_000_000.0 / dt * 100.0
                } else {
                    recentCPU[p.pid] = p.psCPU  // first sample, new pid, or counter reset
                }
            }
            self.prevProcCPUTime = newPrev
            self.prevProcSampleTime = now

            // Aggregate by executable name, summing footprint and recent CPU.
            struct Agg { var mb = 0.0; var cpu = 0.0; var pids: [Int] = []; var count = 0 }
            var agg: [String: Agg] = [:]
            for p in raw {
                var e = agg[p.name] ?? Agg()
                e.mb += p.footprintMB
                e.cpu += recentCPU[p.pid] ?? 0
                e.pids.append(p.pid)
                e.count += 1
                agg[p.name] = e
            }
            let aggregated = agg.map { name, d -> ProcessMemory in
                let display = d.count > 1 ? "\(name) (\(d.count))" : name
                return ProcessMemory(id: name, name: display, pid: d.pids.first ?? 0,
                                     residentMB: d.mb, cpuPercent: d.cpu,
                                     growthMB: d.mb - (self.prevAggMB[name] ?? d.mb))
            }

            // Top growers since last refresh (~5s): the "what changed" hint for pressure
            // events. Growth, not size; the biggest resident is rarely the cause.
            var growers: [(String, Double)] = []
            for (name, d) in agg {
                let delta = d.mb - (self.prevAggMB[name] ?? d.mb)
                if delta > 50 { growers.append((name, delta)) }  // >50 MB growth is signal
            }
            growers.sort { $0.1 > $1.1 }
            self.latestGrowers = growers.prefix(3).map { String(format: "%@ +%.0f MB", $0.0, $0.1) }
            self.prevAggMB = agg.mapValues { $0.mb }

            DispatchQueue.main.async {
                self.processes = self.sortProcesses(aggregated)
            }
        }
    }

    func sortProcesses(_ procs: [ProcessMemory]) -> [ProcessMemory] {
        let sorted: [ProcessMemory]
        switch processSortKey {
        case .memory: sorted = procs.sorted { $0.residentMB > $1.residentMB }
        case .cpu: sorted = procs.sorted { $0.cpuPercent > $1.cpuPercent }
        case .growth: sorted = procs.sorted { $0.growthMB > $1.growthMB }
        case .name: sorted = procs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: sorted = procs.sorted { $0.pid < $1.pid }
        }
        return processSortAscending ? sorted.reversed() : sorted
    }

    func resortProcesses() {
        processes = sortProcesses(processes)
    }
}

// MARK: - Performance Report Export

// Builds a plaintext snapshot + ~5min history block suitable for pasting into a
// chat/agent for troubleshooting. Kept deliberately terse and unit-labeled.
func buildPerformanceReport(monitor: SystemMonitor) -> String {
    let mem = monitor.memoryStats
    let gpu = monitor.gpuStats
    let cpu = monitor.cpuStats

    func gib(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
    }
    func pct(_ frac: Double) -> String {
        String(format: "%.0f%%", frac * 100)
    }
    func seriesSummary(_ s: [Double]) -> String {
        guard !s.isEmpty else { return "n/a" }
        let mn = s.min() ?? 0, mx = s.max() ?? 0
        let avg = s.reduce(0, +) / Double(s.count)
        return "min \(pct(mn)) / avg \(pct(avg)) / max \(pct(mx))"
    }
    func seriesCompact(_ s: [Double]) -> String {
        s.map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")
    }

    let ts = ISO8601DateFormatter().string(from: Date())
    var out = "=== PUER PERFORMANCE REPORT ===\n"
    out += "time: \(ts)\n"
    out += "monitoring for: \(Int(Date().timeIntervalSince(monitor.launchDate) / 60)) min (history and events cover this window only)\n"
    out += "hardware: \(gpu.model), \(cpu.performanceCoreCount)P/\(cpu.efficiencyCoreCount)E CPU, \(gpu.coreCount) GPU cores, \(gib(mem.totalBytes)) GiB unified\n"
    out += "\n[MEMORY now]\n"
    out += "available: \(gib(mem.availableBytes)) GiB (\(pct(mem.availableFraction)))\n"
    out += "used (strict): \(gib(mem.usedBytes)) GiB (reserved \(gib(mem.kernelOtherBytes)) + wired \(gib(mem.wiredBytes)) + app \(gib(mem.appBytes)) + compressed \(gib(mem.compressedBytes)))\n"
    // Reserved identified live: the firmware carveout the VM system never
    // manages, declared by the kernel itself as memsize minus memsize_usable.
    var usableMem: UInt64 = 0
    var usableSz = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize_usable", &usableMem, &usableSz, nil, 0)
    if usableMem > 0 && mem.totalBytes > usableMem {
        out += "reserved cross-check: derived \(gib(mem.kernelOtherBytes)) GiB vs declared firmware carveout \(gib(mem.totalBytes - usableMem)) GiB (hw.memsize - hw.memsize_usable)\n"
    }
    // Plain file cache: file-backed pages on the active/inactive queues. With
    // purgeable and speculative this reconstructs Activity Monitor's Cached
    // Files; in Puer's model all three live inside Available.
    let fileCache = UInt64(max(0, Int64(mem.activeBytes) + Int64(mem.inactiveBytes) - Int64(mem.appBytes) - Int64(mem.purgeableBytes)))
    out += "purgeable: \(gib(mem.purgeableBytes)) GiB; speculative: \(gib(mem.speculativeBytes)) GiB; file-backed: \(gib(fileCache)) GiB\n"
    // Full kernel accounting identity: every physical page in a named bucket,
    // reconciled against total, with the bookkeeping residue shown explicitly.
    out += "kernel accounting: free \(gib(mem.freeCountBytes)) + active \(gib(mem.activeBytes)) + inactive \(gib(mem.inactiveBytes)) + speculative \(gib(mem.speculativeBytes)) + wired \(gib(mem.wiredBytes)) + compressed \(gib(mem.compressedBytes)) + throttled \(gib(mem.throttledBytes)) + reserved \(gib(mem.kernelOtherBytes)) = \(gib(mem.freeCountBytes + mem.activeBytes + mem.inactiveBytes + mem.speculativeBytes + mem.wiredBytes + mem.compressedBytes + mem.throttledBytes + mem.kernelOtherBytes)) GiB (identity vs \(gib(mem.totalBytes)) total)\n"
    // Empirical fit, within ~0.1 GiB across observed states: Activity Monitor's
    // "Memory Used" counts purgeable cache and the reserved carveout in Used,
    // which is why it reads above ours and overlaps its own Cached Files.
    out += "used (loose / activity monitor; empirical: strict + purgeable): \(gib(mem.usedBytes + mem.purgeableBytes)) GiB\n"
    out += "swap used: \(gib(mem.swapUsedBytes)) GiB\n"
    out += "kernel pressure: \(kernelPressureName(mem.kernelPressureLevel)), thermal: \(thermalStateName(monitor.thermalState)), power mode: \(monitor.lowPowerMode ? "low power" : "normal")\n"
    let sessionSwapOut = monitor.memoryStats.swapOutsBytes > monitor.launchSwapOutsBytes ? monitor.memoryStats.swapOutsBytes - monitor.launchSwapOutsBytes : 0
    let sessionSwapIn = monitor.memoryStats.swapInsBytes > monitor.launchSwapInsBytes ? monitor.memoryStats.swapInsBytes - monitor.launchSwapInsBytes : 0
    let lastIODesc = monitor.lastSwapIODate.map { "\(max(0, Int(Date().timeIntervalSince($0) / 60))) min ago" } ?? "none since launch"
    out += "swap rates: in \(String(format: "%.1f", monitor.swapInRateMBs)) MB/s, out \(String(format: "%.1f", monitor.swapOutRateMBs)) MB/s; session out: \(gib(sessionSwapOut)) GiB, session in: \(gib(sessionSwapIn)) GiB; last swap io: \(lastIODesc)\n"
    if monitor.wiredLimitMB > 0 {
        let limitBytes = UInt64(monitor.wiredLimitMB) * 1_048_576
        let headroom = limitBytes > monitor.gpuStats.inUseMemory ? limitBytes - monitor.gpuStats.inUseMemory : 0
        out += "wired: \(gib(mem.wiredBytes)) GiB of \(gib(limitBytes)) GiB gpu wired limit; headroom at most \(gib(headroom)) GiB (limit caps gpu wiring only)\n"
    } else if monitor.defaultWiredLimitBytes > 0 {
        let limitBytes = monitor.defaultWiredLimitBytes
        let headroom = limitBytes > monitor.gpuStats.inUseMemory ? limitBytes - monitor.gpuStats.inUseMemory : 0
        out += "wired: \(gib(mem.wiredBytes)) GiB of \(gib(limitBytes)) GiB gpu wired limit (macOS default via Metal recommendedMaxWorkingSetSize; iogpu.wired_limit_mb unset); headroom at most \(gib(headroom)) GiB\n"
    } else {
        out += "wired: \(gib(mem.wiredBytes)) GiB (wired limit: macOS default, iogpu.wired_limit_mb unset)\n"
    }
    if let evt = monitor.lastPressureEvent {
        let mins = Int(Date().timeIntervalSince(evt) / 60)
        out += "last pressure event: \(mins) min ago this session"
        out += monitor.lastEventGrowers.isEmpty ? "\n" : "; grew most before: \(monitor.lastEventGrowers.joined(separator: ", "))\n"
    } else {
        out += "last pressure event: none observed this session\n"
    }
    out += "\n[GPU now]\n"
    out += "utilization: \(gpu.deviceUtilization)% (renderer \(gpu.rendererUtilization)%, tiler \(gpu.tilerUtilization)%)\n"
    out += "memory in-use: \(gib(gpu.inUseMemory)) GiB, mapped: \(gib(gpu.allocatedMemory)) GiB\n"
    out += "\n[CPU now]\n"
    out += "overall: \(pct(cpu.overall)), P-cores: \(pct(cpu.performance)), E-cores: \(pct(cpu.efficiency))\n"
    out += "per-core: \(cpu.perCore.map { String(Int(($0 * 100).rounded())) }.joined(separator: ","))\n"
    out += "\n[HISTORY ~5min, 2s samples, oldest->newest, values are %]\n"
    out += "used (strict): \(seriesSummary(monitor.memoryHistory))\n"
    out += "  series: \(seriesCompact(monitor.memoryHistory))\n"
    let peakUsedFrac = monitor.memoryHistory.max() ?? 0
    out += "minimum available seen: \(gib(UInt64(Double(mem.totalBytes) * max(0, 1 - peakUsedFrac)))) GiB (lowest point in window)\n"
    out += "gpu util: \(seriesSummary(monitor.gpuHistory.map { Double($0) / 100.0 }))\n"
    out += "  series: \(monitor.gpuHistory.map(String.init).joined(separator: ","))\n"
    out += "gpu mem in-use: \(seriesSummary(monitor.gpuMemHistory))\n"
    out += "gpu mem mapped: \(seriesSummary(monitor.gpuMappedHistory))\n"
    out += "  series: \(seriesCompact(monitor.gpuMappedHistory))\n"
    out += "  series: \(seriesCompact(monitor.gpuMemHistory))\n"
    out += "cpu overall: \(seriesSummary(monitor.cpuHistory))\n"
    out += "  series: \(seriesCompact(monitor.cpuHistory))\n"
    out += "\n[PROCESSES, recent CPU over ~5s window]\n"
    out += "top by footprint:\n"
    for p in monitor.processes.sorted(by: { $0.residentMB > $1.residentMB }).prefix(15) {
        out += String(format: "%9.0f MB  %5.1f%% CPU  %@\n", p.residentMB, p.cpuPercent, p.name)
    }
    out += "top by cpu:\n"
    for p in monitor.processes.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(5) where p.cpuPercent > 0.5 {
        out += String(format: "%6.1f%% CPU  %9.0f MB  %@\n", p.cpuPercent, p.residentMB, p.name)
    }
    out += "=== END REPORT ===\n"
    return out
}

func copyPerformanceReport(monitor: SystemMonitor) {
    let report = buildPerformanceReport(monitor: monitor)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(report, forType: .string)
}

// MARK: - Formatting

func formatMemory(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

func formatMB(_ mb: Double) -> String {
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}

// MARK: - Views

struct SparklineView: View {
    let data: [Double]
    let color: Color
    let maxValue: Double?
    let sampleInterval: Double                 // seconds between samples (time axis)
    let showGrid: Bool                         // gridlines + gutter axis labels
    let yQuarterLabel: ((Double) -> String)?   // fraction (0.0...1.0) -> short label
    let hoverLabel: ((Double) -> String)?      // fraction -> precise scrub readout
    @State private var hoverX: CGFloat? = nil  // cursor x while scrubbing, local space
    @State private var hoverY: CGFloat = 0     // cursor y: the value chip rides at the mouse's height

    // Fixed x-axis window in grid mode; keep in sync with SystemMonitor.maxHistory
    // (150 samples at 2s). Data anchors to the right edge (now) and grows leftward.
    let windowSeconds: Double = 300

    init(data: [Double], color: Color, maxValue: Double? = nil,
         sampleInterval: Double = 2.0, showGrid: Bool = false,
         yQuarterLabel: ((Double) -> String)? = nil,
         hoverLabel: ((Double) -> String)? = nil) {
        self.data = data
        self.color = color
        self.maxValue = maxValue
        self.sampleInterval = sampleInterval
        self.showGrid = showGrid
        self.yQuarterLabel = yQuarterLabel
        self.hoverLabel = hoverLabel
    }

    private func timeTicks(span: Double, interval: Double) -> [Double] {
        var out: [Double] = []
        var t = interval
        while t < span * 0.98 {
            out.append(t)
            t += interval
        }
        return out
    }

    private func timeLabel(_ t: Double) -> String {
        t < 60 ? "-\(Int(t))s" : "-\(Int(t / 60))m"
    }

    var body: some View {
        GeometryReader { geo in
            let maxVal = maxValue ?? max((data.max() ?? 1), 0.001)
            let w = geo.size.width
            let h = geo.size.height
            // Reserved gutters: y labels live left of the plot, time labels below it,
            // so axis text never overlaps the data line or its fill.
            let gutterW: CGFloat = (showGrid && yQuarterLabel != nil) ? 26 : 0
            let axisH: CGFloat = showGrid ? 11 : 0
            let insetTop: CGFloat = showGrid ? 5 : 0
            let plotW = w - gutterW
            let plotH = h - axisH - insetTop
            let yFor: (CGFloat) -> CGFloat = { frac in insetTop + plotH * (1 - frac) }
            let xFor: (CGFloat) -> CGFloat = { frac in gutterW + plotW * frac }
            let span = showGrid ? windowSeconds : Double(max(data.count - 1, 1)) * sampleInterval
            let interval = [15.0, 30.0, 60.0, 120.0].first(where: { span / $0 <= 4 }) ?? 120.0
            // Age-based x: newest sample at the right edge, older samples at their true
            // time position; the left region stays empty until the window fills.
            let xForSample: (Int) -> CGFloat = { i in
                let age = Double(data.count - 1 - i) * sampleInterval
                return xFor(CGFloat(max(0, 1 - age / span)))
            }

            ZStack(alignment: .topLeading) {
                if showGrid {
                    Path { p in
                        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
                            p.move(to: CGPoint(x: gutterW, y: yFor(CGFloat(f))))
                            p.addLine(to: CGPoint(x: w, y: yFor(CGFloat(f))))
                        }
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)

                    Path { p in
                        for t in timeTicks(span: span, interval: interval) {
                            let x = xFor(CGFloat(1 - t / span))
                            p.move(to: CGPoint(x: x, y: insetTop))
                            p.addLine(to: CGPoint(x: x, y: insetTop + plotH))
                        }
                    }
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)

                    ForEach(timeTicks(span: span, interval: interval), id: \.self) { t in
                        Text(timeLabel(t))
                            .font(.system(size: 7))
                            .foregroundColor(.secondary.opacity(0.7))
                            .position(x: xFor(CGFloat(1 - t / span)), y: h - axisH / 2)
                    }

                    if let lbl = yQuarterLabel {
                        ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                            Text(lbl(f))
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.7))
                                .position(x: gutterW / 2, y: yFor(CGFloat(f)))
                        }
                    }
                }

                if data.count > 1 {
                    Path { path in
                        for (i, val) in data.enumerated() {
                            let x = xForSample(i)
                            let y = yFor(CGFloat(val / maxVal))
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, lineWidth: 1.5)

                    Path { path in
                        path.move(to: CGPoint(x: xForSample(0), y: yFor(0)))
                        for (i, val) in data.enumerated() {
                            path.addLine(to: CGPoint(x: xForSample(i), y: yFor(CGFloat(val / maxVal))))
                        }
                        path.addLine(to: CGPoint(x: w, y: yFor(0)))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.15))

                    // Hover scrub: the whole plot is a hover surface; a subtle
                    // vertical line marks the cursor, snapped to the nearest
                    // sample, with the sample's value as a small chip. The left
                    // region before history fills has no samples and shows nothing.
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hoverX = p.x; hoverY = p.y
                            case .ended: hoverX = nil
                            }
                        }
                    if let hx = hoverX, plotW > 0 {
                        let fx = min(max((hx - gutterW) / plotW, 0), 1)
                        let age = Double(1 - fx) * span
                        let idx = data.count - 1 - Int((age / sampleInterval).rounded())
                        if idx >= 0 && idx < data.count {
                            let frac = min(data[idx] / maxVal, 1.0)
                            let sx = xForSample(idx)
                            Path { p in
                                p.move(to: CGPoint(x: sx, y: insetTop))
                                p.addLine(to: CGPoint(x: sx, y: insetTop + plotH))
                            }
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                            Circle()
                                .fill(color)
                                .frame(width: 5, height: 5)
                                .position(x: sx, y: yFor(CGFloat(frac)))
                            Text((hoverLabel ?? yQuarterLabel ?? { f in String(format: "%.0f", f * 100) })(frac))
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundColor(color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10)))
                                .position(x: min(max(sx, gutterW + 22), w - 22),
                                          y: min(max(hoverY, insetTop + 8), insetTop + plotH - 8))
                        }
                    }
                }
            }
        }
    }
}

struct UsageBarView: View {
    let segments: [(Double, Color)]  // fraction, color
    let height: CGFloat

    init(segments: [(Double, Color)], height: CGFloat = 20) {
        self.segments = segments
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(seg.1)
                            .frame(width: max(0, geo.size.width * CGFloat(min(seg.0, 1.0))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: height)
    }
}

// Tab-style toggle for showing and hiding a column from the top bar.
struct ColumnToggle: View {
    let title: String
    let icon: String
    var compact: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                if !compact {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.primary.opacity(0.12) : Color.clear))
            // Transparent pixels don't hit-test, so without an explicit content
            // shape the inactive (clear) state has a smaller click area than the
            // active (filled) one. This makes both states clickable edge to edge.
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .foregroundColor(isOn ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide the \(title) column" : "Show the \(title) column")
    }
}

// Outline for a hovered span of the allocation bar: traces the bar's own
// rounded outline between two x cuts. Cut edges landing in the flat zone get
// a slight rounding (cutRadius); the section's sharp corner overlaps the
// rounded outline corner by under a point, accepted as the softer look. Cuts
// inside a bar-corner zone stay exact chords against the partial arc.
struct SpanOutline: Shape {
    var radius: CGFloat  // corner radius of the full bar outline
    var x0: CGFloat      // span cut positions in the full outline's coordinates
    var x1: CGFloat
    // Vertical use: the bar renders horizontally and rotates -90, so its
    // bar-local TOP side becomes the axis-facing left side, which is square.
    var squareTop: Bool = false

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        let W = rect.width
        let H = rect.height
        let a = max(0, min(x0, W))
        let b = max(a, min(x1, W))
        let q = max(0, min(2.0, (b - a) / 2, H / 2))  // cut-corner rounding, clamped for skinny spans
        func topY(_ x: CGFloat) -> CGFloat {
            if x < r { let d = r - x; return r - (max(0, r * r - d * d)).squareRoot() }
            if x > W - r { let d = x - (W - r); return r - (max(0, r * r - d * d)).squareRoot() }
            return 0
        }
        func ang(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) -> Angle {
            .radians(Double(atan2(y - cy, x - cx)))
        }
        let aFlat = a >= r && a <= W - r
        let bFlat = b >= r && b <= W - r
        if squareTop {
            // Square-top variant: the top edge runs flat at y=0 across the full
            // width (only cut-corner rounding), while the bottom keeps the full
            // corner arcs; used by the vertical bar via rotation.
            var p = Path()
            if q > 0 {
                p.move(to: CGPoint(x: a, y: q))
                p.addArc(center: CGPoint(x: a + q, y: q), radius: q,
                         startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                p.addLine(to: CGPoint(x: b - q, y: 0))
                p.addArc(center: CGPoint(x: b - q, y: q), radius: q,
                         startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            } else {
                p.move(to: CGPoint(x: a, y: 0))
                p.addLine(to: CGPoint(x: b, y: 0))
            }
            p.addLine(to: CGPoint(x: b, y: (bFlat && q > 0) ? H - q : H - topY(b)))
            if bFlat {
                if q > 0 {
                    p.addArc(center: CGPoint(x: b - q, y: H - q), radius: q,
                             startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                }
            } else if b > W - r {
                let s = max(a, W - r)
                p.addArc(center: CGPoint(x: W - r, y: H - r), radius: r,
                         startAngle: ang(W - r, H - r, b, H - topY(b)), endAngle: ang(W - r, H - r, s, H - topY(s)), clockwise: false)
            }
            if aFlat {
                p.addLine(to: CGPoint(x: a + q, y: H))
                if q > 0 {
                    p.addArc(center: CGPoint(x: a + q, y: H - q), radius: q,
                             startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                }
            } else if a < r {
                if b > r { p.addLine(to: CGPoint(x: r, y: H)) }
                let e = min(b, r)
                p.addArc(center: CGPoint(x: r, y: H - r), radius: r,
                         startAngle: ang(r, H - r, e, H - topY(e)), endAngle: ang(r, H - r, a, H - topY(a)), clockwise: false)
            }
            p.closeSubpath()
            return p
        }
        var p = Path()
        // Left cut, top side
        if aFlat && q > 0 {
            p.move(to: CGPoint(x: a, y: q))
            p.addArc(center: CGPoint(x: a + q, y: q), radius: q,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            p.move(to: CGPoint(x: a, y: topY(a)))
            if a < r {
                let e = min(b, r)
                p.addArc(center: CGPoint(x: r, y: r), radius: r,
                         startAngle: ang(r, r, a, topY(a)), endAngle: ang(r, r, e, topY(e)), clockwise: false)
            }
        }
        // Top edge to the right cut
        if bFlat {
            p.addLine(to: CGPoint(x: b - q, y: 0))
            if q > 0 {
                p.addArc(center: CGPoint(x: b - q, y: q), radius: q,
                         startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            }
        } else if b > W - r {
            let s = max(a, W - r)
            p.addLine(to: CGPoint(x: s, y: topY(s) == 0 ? 0 : topY(s)))
            p.addArc(center: CGPoint(x: W - r, y: r), radius: r,
                     startAngle: ang(W - r, r, s, topY(s)), endAngle: ang(W - r, r, b, topY(b)), clockwise: false)
        }
        // Right cut vertical (a chord when b lies inside a corner zone)
        p.addLine(to: CGPoint(x: b, y: (bFlat && q > 0) ? H - q : H - topY(b)))
        // Bottom edge, right to left
        if bFlat {
            if q > 0 {
                p.addArc(center: CGPoint(x: b - q, y: H - q), radius: q,
                         startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            }
        } else if b > W - r {
            let s = max(a, W - r)
            p.addArc(center: CGPoint(x: W - r, y: H - r), radius: r,
                     startAngle: ang(W - r, H - r, b, H - topY(b)), endAngle: ang(W - r, H - r, s, H - topY(s)), clockwise: false)
        }
        // Bottom edge to the left cut
        if aFlat {
            p.addLine(to: CGPoint(x: a + q, y: H))
            if q > 0 {
                p.addArc(center: CGPoint(x: a + q, y: H - q), radius: q,
                         startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            }
        } else if a < r {
            // Only a leading-zone left cut returns through the bottom-left arc; a
            // span living entirely in the trailing corner zone skips this branch
            // and closes with its own chord, instead of jumping to the far left.
            if b > r { p.addLine(to: CGPoint(x: r, y: H)) }
            let e = min(b, r)
            p.addArc(center: CGPoint(x: r, y: H - r), radius: r,
                     startAngle: ang(r, H - r, e, H - topY(e)), endAngle: ang(r, H - r, a, H - topY(a)), clockwise: false)
        }
        p.closeSubpath()  // left cut vertical
        return p
    }
}


// The partition bar, orientation-agnostic: horizontal in compact mode,
// vertical in the fused history chart, one code path. Boundaries are rounded
// cumulative cuts (integer joints, deltas summing exactly to length), with
// no liveness floors anywhere: accuracy is paramount and both orientations
// must render the identical geometry. The hover outline is the same
// SpanOutline in both worlds, rotated for the vertical case, so corner
// rounding matches the horizontal original as closely as one shape can.
struct PartitionBarView: View {
    let vertical: Bool
    let length: CGFloat     // dimension along the partition
    let thickness: CGFloat  // dimension across it
    let fracs: [Double]
    let keys: [String]
    let colors: [Color]
    @Binding var hoveredAllocKeys: Set<String>

    var body: some View {
        let bnd: (Int) -> CGFloat = { i in (length * CGFloat(fracs.prefix(i).reduce(0, +))).rounded() }
        let sFor: (Int) -> CGFloat = { i in max(0, bnd(i + 1) - bnd(i)) }
        return Group {
            if vertical {
                // Reserved at the bottom: bar order reversed top-to-bottom.
                VStack(spacing: 0) {
                    ForEach(Array((0..<keys.count).reversed()), id: \.self) { i in segment(i).frame(height: sFor(i)) }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(0..<keys.count), id: \.self) { i in segment(i).frame(width: sFor(i)) }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: vertical ? thickness : length, height: vertical ? length : thickness)
        .background(Color.primary.opacity(0.06))
        // Orientation-needed difference: the vertical bar's left side faces the
        // zero-second axis and fuses square; its right side keeps the rounding.
        .clipShape(vertical
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 6, topTrailingRadius: 6))
            : AnyShape(RoundedRectangle(cornerRadius: 6)))
        .overlay(alignment: .topLeading) {
            if !hoveredAllocKeys.isEmpty {
                let idxs = (0..<keys.count).filter { hoveredAllocKeys.contains(keys[$0]) }
                if let lo = idxs.min(), let hi = idxs.max() {
                    let off: CGFloat = 0.5
                    SpanOutline(radius: 6 + off, x0: bnd(lo), x1: bnd(hi + 1) + 2 * off, squareTop: vertical)
                        .stroke(Color.white, lineWidth: 2.0)
                        .frame(width: length + 2 * off, height: thickness + 2 * off)
                        .rotationEffect(.degrees(vertical ? -90 : 0))
                        .offset(x: vertical ? (thickness - length) / 2 - off : -off,
                                y: vertical ? (length - thickness) / 2 - off : -off)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func segment(_ i: Int) -> some View {
        Rectangle()
            .fill(colors[i])
            .contentShape(Rectangle())
            .onHover { h in if h { hoveredAllocKeys = [keys[i]] } else if hoveredAllocKeys == [keys[i]] { hoveredAllocKeys = [] } }
    }
}

// Allocation-legend entry: swatch beside a label-over-value stack. The fixed
// two-line shape is the standardized return; labels never wrap mid-phrase.
struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.primary)
    }
}

// Swap rates: one decimal below 10 MB/s, whole numbers above.
func swapRateStr(_ v: Double) -> String { String(format: v < 10 ? "%.1f" : "%.0f", v) }

struct StatItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Never wrap and never shrink: text renders at declared size, and
            // column floors are sized so every cell fits. Shrink-to-fit hid
            // sizing bugs by quietly rescaling; the doctrine is fit by design.
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)

        }
    }
}


struct SortButton: View {
    let label: String
    let key: ProcessSortKey
    @Binding var currentKey: ProcessSortKey
    @Binding var ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            if currentKey == key {
                ascending.toggle()
            } else {
                currentKey = key
                ascending = false
            }
            action()
        }) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: currentKey == key ? .bold : .medium))
                if currentKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundColor(currentKey == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ProcessRowView: View {
    let proc: ProcessMemory
    let maxMB: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(proc.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if abs(proc.growthMB) > 50 {
                    Text(String(format: "%+.0f MB", proc.growthMB))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(proc.growthMB > 0 ? .orange : .teal)
                }
                Text(formatMB(proc.residentMB))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            HStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(processRed.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(processRed.opacity(0.5))
                            .frame(width: max(0, geo.size.width * CGFloat(proc.residentMB / max(maxMB, 1))))
                    }
                }
                .frame(height: 4)
                if proc.cpuPercent > 0 {
                    Text(String(format: "%.1f%% CPU", proc.cpuPercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// Aggregate load bar for a core cluster (performance or efficiency).

// Vertical mini-bars, one per logical core; efficiency cores (first N) colored teal.
struct PerCoreBarsView: View {
    let perCore: [Double]
    let efficiencyCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(perCore.enumerated()), id: \.offset) { idx, usage in
                let isEfficiency = idx < efficiencyCount
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isEfficiency ? Color.teal : Color.blue)
                            .frame(height: max(2, 50 * CGFloat(min(usage, 1))))
                    }
                    .frame(height: 50)
                    Text("\(Int((usage * 100).rounded()))%")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// Fixed three-column layout: memory (500) + CPU (360) + processes (320) + 2 dividers.
// Column width floors: the single source of truth. Column frames, the window
// minimum, and the launch width all derive from these; change a floor here and
// everything follows.
let memoryColMinWidth: CGFloat = 500  // sized to the five-chip readout row, which never wraps
let gpuColMinWidth: CGFloat = 402
let cpuColMinWidth: CGFloat = 402
let processesColMinWidth: CGFloat = 220
// Launch width: the three launch-visible columns at their floors (Processes launches hidden).
let windowWidth: CGFloat = memoryColMinWidth + gpuColMinWidth + cpuColMinWidth
// Launch height before the fit-to-content correction: the layout measures its
// tallest metric column once at launch and posts the deficit; see launch fit.
let windowHeight: CGFloat = 720

// GPU family: two solid shades on one royal-violet ladder; every GPU element
// and WIRED derive from these two constants.
// Primary (light purple): active claims, utilization, WIRED.
let gpuPurple = Color(red: 0.78, green: 0.42, blue: 1.00)
// Secondary (one step darker): mapped/idle claims; solid so text stays readable.
let gpuPurpleDark = Color(red: 0.58, green: 0.30, blue: 0.88)
// Reserved carveout: deep brown, kept well apart from Compressed orange.
let reservedBrown = Color(red: 0.60, green: 0.42, blue: 0.26)
// Process-list accent: dark red. (SwiftUI's .pink renders as a red on macOS;
// named for what it looks like, not the API token.)
let processRed = Color.pink

struct StatusPill: View {
    let title: String   // neutral subject, e.g. "Thermal"
    let state: String   // colored state, e.g. "normal"
    let icon: String    // compact-mode symbol, e.g. "thermometer"
    let color: Color
    var compact: Bool = false

    var body: some View {
        if compact {
            // Icon-only chip: the state still speaks through the color.
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(5)
                .help("\(title): \(state.capitalized)")
        } else {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(state.capitalized)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.15))
                    .foregroundColor(color)
                    .cornerRadius(5)
            }
        }
    }
}

// Pressure-event forensics: growers captured at each event surface in the
// ledger card's pressure cell and the report; the app cannot see events from
// before its own launch. The banner UI that once carried this is retired.
// A labeled full-width trend row: metric name (with units), current value inline,
// sparkline beneath, optional caption. Replaces the old unlabeled side-by-side charts.

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var reportCopied = false
    // Column visibility; HSplitView redistributes width among whatever remains.
    @State private var showMemory = true
    @State private var showGPU = true
    @State private var showCPU = true
    @State private var showProcesses = false
    // Allocation hover: keys of bar segments to outline, driven by the
    // readout row and the legend. WIRED and AVAILABLE map to their groups.
    @State private var hoveredAllocKeys: Set<String> = []
    // Allocation chart mode: launches compact (the horizontal bar); the
    // fused 5-minute history is opt-in via the header toggle, so the
    // vertical spend is always a choice. Session-scoped, like column toggles.
    @State private var allocShowHistory = false
    // Scrub position over the allocation area chart, local to the canvas.
    @State private var allocScrub: CGPoint? = nil
    // Short names for the dense slice readout, in bar order.
    private let allocShortNames = ["Reserved", "Wired \u{00B7} GPU In-Use", "Wired \u{00B7} other", "App", "Compressed", "Purgeable", "Speculative", "File-backed", "Unallocated"]
    // Launch fit state: corrections converge during a short launch window,
    // comparing the content's and viewport's BOTTOM EDGES in global space, so
    // any inset between the measured boxes cancels instead of hiding overflow
    // (a trailing .padding(.top) after the reporter was exactly such a bug).
    // The deadline guarantees user resizes are never fought.
    @State private var launchFitContentH: CGFloat = 0
    @State private var launchFitViewportH: CGFloat = 0
    @State private var launchFitPassScheduled = false
    private let launchFitDeadline = Date().addingTimeInterval(3)

    private func postLaunchFitIfReady() {
        // Coalesce: both preference callbacks fire in one layout transaction;
        // posting from each would apply the same deficit twice. One async
        // evaluation per transaction reads the settled pair exactly once.
        guard Date() < launchFitDeadline, !launchFitPassScheduled else { return }
        launchFitPassScheduled = true
        DispatchQueue.main.async {
            launchFitPassScheduled = false
            guard launchFitContentH > 0, launchFitViewportH > 0 else { return }
            // Fit margin: converge to content plus a few points of slack, so
            // sub-point rounding can never leave a sliver of overflow that
            // summons the scroll indicator over otherwise-visible content.
            let deficit = launchFitContentH + 4 - launchFitViewportH
            guard deficit > 0.5 else { return }
            NotificationCenter.default.post(name: .puerLaunchHeightDeficit, object: nil, userInfo: ["deficit": deficit])
        }
    }

    // Headline stat cell: natural-size content in an equal-width frame.
    @ViewBuilder
    private func headlineStat(_ label: String, _ value: String, _ color: Color) -> some View {
        StatItem(label: label, value: value, color: color)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Combo-card header: the readout is the graph's own title, so identity is
    // stated exactly once; the window or denominator rides as an annotation.
    @ViewBuilder
    private func graphHeader(_ label: String, _ value: String, _ color: Color, note: String, valueSize: CGFloat = 20) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                // An empty note renders nothing at all: Text("") would still
                // occupy a full line box and pad the header with a phantom line.
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // Bubble quadrant cells: primary (large colored value) and secondary
    // (standard stat), equal-width so the plus hairline's center is the
    // true column boundary.

    // Legend chip: a LegendItem in the same hoverable-bubble chrome as the
    // readout row, locked at natural size.
    @ViewBuilder
    private func legendChip(color: Color, label: String, value: String, keys: Set<String>) -> some View {
        LegendItem(color: color, label: label, value: value)
            .fixedSize()
            // Natural width is the floor (fixedSize); the frame lets the chip
            // expand so each row equalizes and fills when space allows. The
            // tighter, dimmer chrome marks this tier as the readout row's child.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hoveredAllocKeys == keys ? 0.09 : 0.04)))
            .contentShape(Rectangle())
            .onHover { h in if h { hoveredAllocKeys = keys } else if hoveredAllocKeys == keys { hoveredAllocKeys = [] } }
    }

    // Two-layer compression restriction: the window can never shrink below the
    // top bar's fully compacted (tier-3) width, and never below the summed
    // minimums of whichever columns are visible. Fewer columns, more compression.
    private var minWindowWidth: CGFloat {
        let topBarMin: CGFloat = 480  // final tier: title, icon toggles, icon pills, report icon; no variable-width text remains
        var columns: CGFloat = 0
        if showMemory { columns += memoryColMinWidth }
        if showGPU { columns += gpuColMinWidth }
        if showCPU { columns += cpuColMinWidth }
        if showProcesses { columns += processesColMinWidth }
        return max(topBarMin, columns)
    }

    @ViewBuilder
    private func topBar(reportCompact: Bool, infoSegments: Int, togglesCompact: Bool, pillsCompact: Bool) -> some View {
        HStack(spacing: 12) {
            Text("Puer")
                .font(.system(size: 18, weight: .bold))
                .lineLimit(1)
                .fixedSize()
            Divider()
                .frame(height: 16)
            HStack(spacing: 6) {
                ColumnToggle(title: "Unified Memory", icon: "memorychip", compact: togglesCompact, isOn: $showMemory)
                ColumnToggle(title: "GPU", icon: "cube.transparent", compact: togglesCompact, isOn: $showGPU)
                ColumnToggle(title: "CPU", icon: "cpu", compact: togglesCompact, isOn: $showCPU)
                ColumnToggle(title: "Processes", icon: "list.bullet.rectangle", compact: togglesCompact, isOn: $showProcesses)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            if infoSegments > 0 {
                Divider()
                    .frame(height: 16)
                Text(deviceInfo(segments: infoSegments))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Divider()
                .frame(height: 16)
            StatusPill(title: "Thermal", state: thermalStateName(monitor.thermalState), icon: "thermometer",
                       color: monitor.thermalState == .nominal ? .green : (monitor.thermalState == .fair ? .yellow : .red),
                       compact: pillsCompact)
            Divider()
                .frame(height: 16)
            StatusPill(title: "Power", state: monitor.lowPowerMode ? "low power" : "normal", icon: "bolt.fill",
                       color: monitor.lowPowerMode ? .orange : .green,
                       compact: pillsCompact)
            Spacer(minLength: 8)
            Button(action: {
                copyPerformanceReport(monitor: monitor)
                reportCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reportCopied = false }
            }) {
                if reportCompact {
                    Image(systemName: reportCopied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Label(reportCopied ? "Copied" : "Copy Report",
                          systemImage: reportCopied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(.bordered)
            .help("Copy a plaintext performance report (snapshot + 5 min history) for troubleshooting")
        }
        .padding(.leading, 76)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    // Device info split into individually collapsible segments, dropped from the
    // right: [name, CPU, GPU cores].
    private func deviceInfo(segments: Int) -> String {
        let parts = [monitor.gpuStats.model,
                     "\(monitor.cpuStats.performanceCoreCount)P/\(monitor.cpuStats.efficiencyCoreCount)E CPU",
                     "\(monitor.gpuStats.coreCount) GPU cores"]
        return parts.prefix(segments).joined(separator: " \u{2022} ")
    }

    private var availableGB: Double {
        Double(monitor.memoryStats.availableBytes) / 1_073_741_824
    }
    private var totalGB: Double {
        Double(monitor.memoryStats.totalBytes) / 1_073_741_824
    }
    private var headroomColor: Color {
        let frac = monitor.memoryStats.availableFraction
        if frac > 0.3 { return .green }
        if frac > 0.15 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 0) {
            // TOP BAR, responsive. Collapse order as width shrinks: Copy Report label
            // first, then device info a segment at a time (GPU cores, CPU, name),
            // and only after all of that do the column toggles drop to icons.
            ViewThatFits(in: .horizontal) {
                topBar(reportCompact: false, infoSegments: 3, togglesCompact: false, pillsCompact: false)
                topBar(reportCompact: true, infoSegments: 3, togglesCompact: false, pillsCompact: false)
                topBar(reportCompact: true, infoSegments: 2, togglesCompact: false, pillsCompact: false)
                topBar(reportCompact: true, infoSegments: 1, togglesCompact: false, pillsCompact: false)
                topBar(reportCompact: true, infoSegments: 0, togglesCompact: false, pillsCompact: false)
                topBar(reportCompact: true, infoSegments: 0, togglesCompact: true, pillsCompact: false)
                topBar(reportCompact: true, infoSegments: 0, togglesCompact: true, pillsCompact: true)
            }

            Divider()

            // HSplitView gives each column a draggable divider so the user can resize sections.
            HSplitView {
            if showMemory {
            // LEFT COLUMN
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Unified Memory", icon: "memorychip")

                    // HEADLINE: 2x2 verdict bubble. Left column, primary: Used (Strict)
                    // over Available. Right column, secondary: Used (Loose) over Total.
                    // A dark plus-shaped hairline separates the quadrants, inset so it
                    // never quite reaches the bubble's edges.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Overview")
                            .font(.system(size: 13, weight: .semibold))
                        let usedLooseValue = formatMemory(monitor.memoryStats.usedBytes + monitor.memoryStats.purgeableBytes)
                        let peakUsedFrac = monitor.memoryHistory.max() ?? monitor.memoryStats.usedFraction
                        let minAvailValue = formatMemory(UInt64(Double(monitor.memoryStats.totalBytes) * max(0, 1 - peakUsedFrac)))
                        let pressureColor: Color = monitor.memoryStats.kernelPressureLevel > 2 ? .red : (monitor.memoryStats.kernelPressureLevel > 1 ? .orange : .green)
                        let lastPressure = monitor.lastPressureEvent.map { d -> String in
                            let m = Int(Date().timeIntervalSince(d) / 60)
                            return m < 1 ? "<1 min ago" : "\(m) min ago"
                        } ?? "-"
                        let lastPressureColor: Color = monitor.lastPressureEvent != nil ? .orange : .secondary
                        VStack(alignment: .leading, spacing: 8) {
                            // The hero in the global grammar at last: standard header,
                            // Total and the window folded into the note, the value
                            // prominent and alone top right, hover lighting its segments.
                            graphHeader("MEMORY USED (STRICT)", formatMemory(monitor.memoryStats.usedBytes), headroomColor,
                                        note: "of \(formatMemory(monitor.memoryStats.totalBytes)) \u{00B7} last 5 min", valueSize: 25)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["reserved", "app", "gpuInUse", "wiredOther", "compressed"] ? 0.10 : 0.05)))
                                .contentShape(Rectangle())
                                .onHover { h in if h { hoveredAllocKeys = ["reserved", "app", "gpuInUse", "wiredOther", "compressed"] } else if hoveredAllocKeys == ["reserved", "app", "gpuInUse", "wiredOther", "compressed"] { hoveredAllocKeys = [] } }
                            SparklineView(data: monitor.memoryHistory, color: headroomColor, maxValue: 1.0,
                                          showGrid: true, yQuarterLabel: { f in String(format: "%.0fG", f * totalGB) },
                                          hoverLabel: { f in String(format: "%.1f GB", f * totalGB) })
                                .frame(height: 60)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(headroomColor.opacity(0.12)))
                        // The readout pair: Available and the loose convention side by
                        // side, cells equalized in height, each carrying its satellite
                        // note in the fold grammar and its hover into the allocation bar.
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("USED (LOOSE)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text(usedLooseValue)
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("activity monitor (strict + purgeable)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["reserved", "app", "gpuInUse", "wiredOther", "compressed", "purgeable"] ? 0.10 : 0.05)))
                            .contentShape(Rectangle())
                            .onHover { h in if h { hoveredAllocKeys = ["reserved", "app", "gpuInUse", "wiredOther", "compressed", "purgeable"] } else if hoveredAllocKeys == ["reserved", "app", "gpuInUse", "wiredOther", "compressed", "purgeable"] { hoveredAllocKeys = [] } }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("AVAILABLE")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text(formatMemory(monitor.memoryStats.availableBytes))
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(headroomColor)
                                Text("5-min low: \(minAvailValue)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["purgeable", "speculative", "fileBacked", "unallocated"] ? 0.10 : 0.05)))
                            .contentShape(Rectangle())
                            .onHover { h in if h { hoveredAllocKeys = ["purgeable", "speculative", "fileBacked", "unallocated"] } else if hoveredAllocKeys == ["purgeable", "speculative", "fileBacked", "unallocated"] { hoveredAllocKeys = [] } }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        // The status band: one slim row. Pressure's pill, the event
                        // clock, then the forensics with the row's remaining width so a
                        // process name can speak on one line.
                        VStack(alignment: .leading, spacing: 6) {
                            // Verdict row: the kernel's pill and the event clock.
                            HStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    Text("PRESSURE")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    Text(kernelPressureName(monitor.memoryStats.kernelPressureLevel).capitalized)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(pressureColor)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(pressureColor.opacity(0.15)))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 8) {
                                    Text("LAST EVENT")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    Text(lastPressure)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(lastPressureColor)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Forensic row: its own register, so the growers list has the
                            // band's full width; with room to speak, the top three return.
                            HStack(spacing: 8) {
                                Text("GREW BEFORE")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Text(monitor.lastEventGrowers.isEmpty ? "n/a" : monitor.lastEventGrowers.joined(separator: ", "))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)

                    // UNIFIED MEMORY POOL
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Allocation details")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(action: { allocShowHistory.toggle() }) {
                                Image(systemName: allocShowHistory ? "rectangle.split.3x1" : "chart.bar.xaxis")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                            .help(allocShowHistory ? "Switch to the compact bar" : "Switch to the 5-minute history view")
                        }

                        // The five primary readouts head the card they caption; the chart
                        // and its cache-tier legend follow.
                        HStack(spacing: 6) {
                            StatItem(label: "RESERVED", value: formatMemory(monitor.memoryStats.kernelOtherBytes), color: reservedBrown)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["reserved"] ? 0.10 : 0.05)))
                                .contentShape(Rectangle())
                                .onHover { h in if h { hoveredAllocKeys = ["reserved"] } else if hoveredAllocKeys == ["reserved"] { hoveredAllocKeys = [] } }
                            StatItem(label: "WIRED", value: formatMemory(monitor.memoryStats.wiredBytes), color: gpuPurple)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["gpuInUse", "wiredOther"] ? 0.10 : 0.05)))
                                .contentShape(Rectangle())
                                .onHover { h in if h { hoveredAllocKeys = ["gpuInUse", "wiredOther"] } else if hoveredAllocKeys == ["gpuInUse", "wiredOther"] { hoveredAllocKeys = [] } }
                            StatItem(label: "APP", value: formatMemory(monitor.memoryStats.appBytes), color: .blue)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["app"] ? 0.10 : 0.05)))
                                .contentShape(Rectangle())
                                .onHover { h in if h { hoveredAllocKeys = ["app"] } else if hoveredAllocKeys == ["app"] { hoveredAllocKeys = [] } }
                            StatItem(label: "COMPRESSED", value: formatMemory(monitor.memoryStats.compressedBytes), color: .orange)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["compressed"] ? 0.10 : 0.05)))
                                .contentShape(Rectangle())
                                .onHover { h in if h { hoveredAllocKeys = ["compressed"] } else if hoveredAllocKeys == ["compressed"] { hoveredAllocKeys = [] } }
                            StatItem(label: "AVAILABLE", value: formatMemory(monitor.memoryStats.availableBytes), color: .secondary)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hoveredAllocKeys == ["purgeable", "speculative", "fileBacked", "unallocated"] ? 0.10 : 0.05)))
                                .contentShape(Rectangle())
                                .onHover { h in if h { hoveredAllocKeys = ["purgeable", "speculative", "fileBacked", "unallocated"] } else if hoveredAllocKeys == ["purgeable", "speculative", "fileBacked", "unallocated"] { hoveredAllocKeys = [] } }
                        }

                        let total = Double(max(monitor.memoryStats.totalBytes, 1))
                        // Coherence clamp for the partition (chips and legend still show
                        // the driver's raw counter): see the sampler's matching clamp.
                        let gpuActive = min(Double(monitor.gpuStats.inUseMemory), Double(monitor.memoryStats.wiredBytes))
                        // Wired splits into exactly two measurable parts: GPU In-Use
                        // (driver counter; actively-worked GPU memory is pinned by nature)
                        // and everything else that is pinned. A finer GPU-vs-OS attribution
                        // would be an unvalidatable guess, so it is deliberately not made.
                        let wiredOther = max(0, Double(monitor.memoryStats.wiredBytes) - gpuActive)
                        let appUsed = Double(monitor.memoryStats.appBytes)
                        let compUsed = Double(monitor.memoryStats.compressedBytes)
                        // Available, decomposed into its reclaimable tiers plus the kernel
                        // remainder (pages in no named queue). Throttled is folded into
                        // Unallocated; it is ~0 on desktop macOS. With these, the chart is
                        // a complete partition of physical memory.
                        let purgeableB = Double(monitor.memoryStats.purgeableBytes)
                        let speculativeB = Double(monitor.memoryStats.speculativeBytes)
                        let fileCacheB = max(0, Double(monitor.memoryStats.activeBytes) + Double(monitor.memoryStats.inactiveBytes) - Double(monitor.memoryStats.appBytes) - purgeableB)
                        let kernelRemB = Double(monitor.memoryStats.kernelOtherBytes)
                        let unallocatedB = Double(monitor.memoryStats.freeCountBytes + monitor.memoryStats.throttledBytes)
                        // Shared partition inputs: both chart modes read these; the bar
                        // component and the area canvas can never disagree on them.
                        let allocKeys = ["reserved", "gpuInUse", "wiredOther", "app", "compressed", "purgeable", "speculative", "fileBacked", "unallocated"]
                        let allocColors: [Color] = [reservedBrown, gpuPurple, gpuPurpleDark, .blue, .orange,
                                                    Color.gray.opacity(0.42), Color.gray.opacity(0.32), Color.gray.opacity(0.22), Color.gray.opacity(0.10)]
                        let fracs: [Double] = [kernelRemB / total, gpuActive / total, wiredOther / total,
                                               appUsed / total, compUsed / total, purgeableB / total,
                                               speculativeB / total, fileCacheB / total, unallocatedB / total]

                        if allocShowHistory {
                        // The partition, now and over time: a 100% stacked area chart
                        // of all nine components across the 5-minute window (right edge
                        // is now, matching the sparklines), fused at the zero-second
                        // axis into the live partition bar, vertical, Reserved at the
                        // bottom. Axes speak the sparkline grammar: 7-point quarter
                        // labels in a left gutter, time ticks below.
                        GeometryReader { geo in
                            let w = geo.size.width
                            // Square-at-the-floor sizing, minus the axis gutters, derived
                            // from the single-source floor constant.
                            let chartH: CGFloat = memoryColMinWidth - 64
                            let barW: CGFloat = 36
                            let gutterW: CGFloat = 26
                            let axisH: CGFloat = 11
                            let insetTop: CGFloat = 5
                            let plotH = chartH - axisH - insetTop
                            let areaW = w - gutterW - barW - 1
                            ZStack(alignment: .topLeading) {
                                // Y-axis unit labels: quarters of total, sparkline grammar.
                                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                                    Text(String(format: "%.0fG", f * totalGB))
                                        .font(.system(size: 7))
                                        .foregroundColor(.secondary.opacity(0.7))
                                        .position(x: gutterW / 2, y: insetTop + plotH * CGFloat(1 - f))
                                }
                                // Time ticks: the sparklines' 300-second window picks the
                                // 120-second interval, so the shared vocabulary is -2m, -4m.
                                ForEach([120.0, 240.0], id: \.self) { t in
                                    Text("-\(Int(t / 60))m")
                                        .font(.system(size: 7))
                                        .foregroundColor(.secondary.opacity(0.7))
                                        .position(x: gutterW + areaW * CGFloat(1 - t / 300), y: chartH - axisH / 2)
                                }
                                HStack(spacing: 0) {
                                    Canvas { ctx, size in
                                        let hist = monitor.allocHistory
                                        let n = hist.count
                                        guard n > 0 else { return }
                                        // Integer column boundaries from the age mapping: each
                                        // poll owns [xb(j), xb(j+1)) and holds its value across
                                        // it (step semantics, honest for sampled data). Column
                                        // widths differ by at most one point where the division
                                        // does not come out even: the nearest-full-pixel
                                        // approximation, never a blended edge.
                                        let xb: (Int) -> CGFloat = { j in
                                            let age = Double(n - 1 - j) * 2.0
                                            return (areaW * CGFloat(max(0, 1 - age / 300))).rounded()
                                        }
                                        for j in 0..<n {
                                            let x0 = xb(j)
                                            let x1 = j + 1 < n ? xb(j + 1) : areaW.rounded()
                                            guard x1 > x0 else { continue }
                                            var acc: Double = 0
                                            var yPrev = size.height
                                            for i in 0..<9 {
                                                acc += hist[j][i]
                                                let yTop = size.height - (size.height * CGFloat(min(1, acc))).rounded()
                                                if yPrev - yTop > 0 {
                                                    ctx.fill(Path(CGRect(x: x0, y: yTop, width: x1 - x0, height: yPrev - yTop)),
                                                             with: .color(allocColors[i]))
                                                }
                                                yPrev = yTop
                                            }
                                        }
                                    }
                                    .frame(width: max(0, areaW), height: plotH)
                                    .background(Color.primary.opacity(0.03))
                                    // The area's outer left edge rounds like every card
                                    // surface; its right edge stays square into the axis.
                                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 0, topTrailingRadius: 0))
                                    // Scrub: track the cursor, snap to the sample column, and
                                    // put the band under the cursor into the app-wide hover
                                    // system so bar, chips, and legend light up with history.
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let p): allocScrub = p
                                        case .ended: allocScrub = nil
                                        }
                                    }
                                    .overlay(alignment: .topLeading) {
                                        let hist = monitor.allocHistory
                                        if let pt = allocScrub, !hist.isEmpty, areaW > 0 {
                                            let n = hist.count
                                            let age = Double(max(0, 1 - pt.x / areaW)) * 300
                                            let j = n - 1 - Int((age / 2.0).rounded())
                                            // The void before history fills has no samples: no
                                            // line, no panel, the sparklines' own honesty.
                                            if j >= 0 && j < n {
                                                let x0 = (areaW * CGFloat(max(0, 1 - Double(n - 1 - j) * 2.0 / 300))).rounded()
                                                let x1 = j + 1 < n ? (areaW * CGFloat(max(0, 1 - Double(n - 2 - j) * 2.0 / 300))).rounded() : areaW.rounded()
                                                let cx = ((x0 + x1) / 2).rounded()
                                                let ageS = (n - 1 - j) * 2
                                                // Band under the cursor, for the panel's local
                                                // emphasis only; the graph never drives the
                                                // app-wide highlight, which belongs to the bar.
                                                let fb = Double(max(0, min(1, 1 - pt.y / plotH)))
                                                let band: Int = {
                                                    var acc = 0.0
                                                    for i in 0..<9 { acc += hist[j][i]; if fb < acc { return i } }
                                                    return 8
                                                }()
                                                ZStack(alignment: .topLeading) {
                                                Rectangle()
                                                    .fill(Color.primary.opacity(0.25))
                                                    .frame(width: 1, height: plotH)
                                                    .offset(x: cx)
                                                    .allowsHitTesting(false)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(ageS < 60 ? "-\(ageS)s" : "-\(ageS / 60)m \(ageS % 60)s")
                                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                                        .foregroundColor(.secondary)
                                                    ForEach(Array((0..<9).reversed()), id: \.self) { i in
                                                        HStack(spacing: 4) {
                                                            RoundedRectangle(cornerRadius: 1)
                                                                .fill(allocColors[i])
                                                                .frame(width: 6, height: 6)
                                                            Text(allocShortNames[i])
                                                                .font(.system(size: 8))
                                                                .foregroundColor(band == i ? .primary : .secondary)
                                                            Spacer(minLength: 6)
                                                            Text(formatMemory(UInt64(max(0, hist[j][i]) * Double(monitor.memoryStats.totalBytes))))
                                                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                                                .foregroundColor(band == i ? .primary : .secondary)
                                                        }
                                                    }
                                                }
                                                .padding(6)
                                                .frame(width: 150)
                                                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                                .offset(x: min(max(cx + 8, 4), areaW - 154),
                                                        y: min(max(pt.y + 8, 4), plotH - 122))
                                                .allowsHitTesting(false)
                                                }
                                            }
                                        }
                                    }
                                    // The zero-second axis: the seam where history becomes now.
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.35))
                                        .frame(width: 1, height: plotH)
                                    // BAR: the shared partition component, vertical.
                                    PartitionBarView(vertical: true, length: plotH, thickness: barW,
                                                     fracs: fracs, keys: allocKeys, colors: allocColors,
                                                     hoveredAllocKeys: $hoveredAllocKeys)
                                }
                                .padding(.leading, gutterW)
                                .padding(.top, insetTop)
                            }
                        }
                        .frame(height: memoryColMinWidth - 64)
                        } else {
                        // The shared partition component, horizontal: the identical
                        // code path as the vertical bar; only orientation differs.
                        GeometryReader { geo in
                            PartitionBarView(vertical: false, length: geo.size.width, thickness: 36,
                                             fracs: fracs, keys: allocKeys, colors: allocColors,
                                             hoveredAllocKeys: $hoveredAllocKeys)
                        }
                        .frame(height: 36)
                        }

                        // Legend
                        // Two layouts only: all six chips on one row when width allows,
                            // otherwise grouped by master section: Wired pair, then the
                            // four Available tiers.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    legendChip(color: gpuPurple, label: "Wired - GPU In-Use", value: formatMemory(monitor.gpuStats.inUseMemory), keys: ["gpuInUse"])
                                    legendChip(color: gpuPurpleDark, label: "Wired - GPU Idle / Non-GPU", value: formatMemory(UInt64(wiredOther)), keys: ["wiredOther"])
                                    legendChip(color: .gray.opacity(0.42), label: "Purgeable", value: formatMemory(UInt64(purgeableB)), keys: ["purgeable"])
                                    legendChip(color: .gray.opacity(0.32), label: "Speculative", value: formatMemory(UInt64(speculativeB)), keys: ["speculative"])
                                    legendChip(color: .gray.opacity(0.22), label: "File-Backed", value: formatMemory(UInt64(fileCacheB)), keys: ["fileBacked"])
                                    legendChip(color: .gray.opacity(0.10), label: "Unallocated", value: formatMemory(UInt64(unallocatedB)), keys: ["unallocated"])
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        legendChip(color: gpuPurple, label: "Wired - GPU In-Use", value: formatMemory(monitor.gpuStats.inUseMemory), keys: ["gpuInUse"])
                                        legendChip(color: gpuPurpleDark, label: "Wired - GPU Idle / Non-GPU", value: formatMemory(UInt64(wiredOther)), keys: ["wiredOther"])
                                    }
                                    HStack(spacing: 6) {
                                        legendChip(color: .gray.opacity(0.42), label: "Purgeable", value: formatMemory(UInt64(purgeableB)), keys: ["purgeable"])
                                        legendChip(color: .gray.opacity(0.32), label: "Speculative", value: formatMemory(UInt64(speculativeB)), keys: ["speculative"])
                                        legendChip(color: .gray.opacity(0.22), label: "File-Backed", value: formatMemory(UInt64(fileCacheB)), keys: ["fileBacked"])
                                        legendChip(color: .gray.opacity(0.10), label: "Unallocated", value: formatMemory(UInt64(unallocatedB)), keys: ["unallocated"])
                                    }
                                }
                            }
                        .foregroundColor(.secondary)

                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)

                    // SWAP: overflow out of unified memory onto disk
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Swap (disk overflow)")
                            .font(.system(size: 13, weight: .semibold))
                        let sessionOut = monitor.memoryStats.swapOutsBytes > monitor.launchSwapOutsBytes ? monitor.memoryStats.swapOutsBytes - monitor.launchSwapOutsBytes : 0
                        let sessionIn = monitor.memoryStats.swapInsBytes > monitor.launchSwapInsBytes ? monitor.memoryStats.swapInsBytes - monitor.launchSwapInsBytes : 0
                        // Exact counters: zero session traffic plus an idle LAST I/O clock
                        // is proof the on-disk swap is cold residue for this session.
                        let swapIOActive = monitor.swapInRateMBs > 0.05 || monitor.swapOutRateMBs > 0.05
                        let lastIO = swapIOActive ? "now" : (monitor.lastSwapIODate.map { d -> String in
                            let m = Int(Date().timeIntervalSince(d) / 60)
                            return m < 1 ? "<1 min ago" : (m < 60 ? "\(m) min ago" : "\(m / 60) hr ago")
                        } ?? "-")
                        HStack(spacing: 0) {
                            // Cells hug content; the flexible gaps between them are
                            // what compress, down to a 12-point minimum at the floor.
                            StatItem(label: "ON DISK", value: formatMemory(monitor.memoryStats.swapUsedBytes), color: .secondary)
                            Spacer(minLength: 12)
                            // Adaptive decimals: one tenth below 10 MB/s (the 0.5 alert
                            // threshold lives there), whole numbers above, so the cell's
                            // worst case fits the floor without truncation.
                            StatItem(label: "RATE IN / OUT",
                                     value: "\(swapRateStr(monitor.swapInRateMBs)) / \(swapRateStr(monitor.swapOutRateMBs)) MB/s",
                                     color: monitor.swapOutRateMBs > 0.5 ? .orange : .secondary)
                            Spacer(minLength: 12)
                            StatItem(label: "SESSION IN / OUT", value: "\(formatMemory(sessionIn)) / \(formatMemory(sessionOut))", color: .secondary)
                            Spacer(minLength: 12)
                            StatItem(label: "LAST I/O", value: lastIO, color: swapIOActive ? .orange : .secondary)
                                // Reserve the worst case ("59 min ago") so the cell holds
                                // constant width as the value shifts between forms.
                                .frame(minWidth: 84, alignment: .leading)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)

                }
                .padding([.horizontal, .bottom], 16)
                .background(GeometryReader { g in Color.clear.preference(key: ColumnContentHeightKey.self, value: g.frame(in: .global).maxY) })
                .padding(.top, 12)
            }
            .frame(minWidth: memoryColMinWidth, idealWidth: memoryColMinWidth, maxWidth: .infinity, maxHeight: .infinity)  // ideal = floor so launch opens at minimum
            .background(GeometryReader { g in Color.clear.preference(key: ColumnViewportHeightKey.self, value: g.frame(in: .global).maxY) })
            }

            if showGPU {
            // GPU COLUMN
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "GPU", icon: "cube.transparent")

                    // Overview: the hero combo card, tinted with the column color; the
                    // readout heads its own graph so the identity is stated once.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Overview")
                            .font(.system(size: 13, weight: .semibold))
                        VStack(alignment: .leading, spacing: 8) {
                            graphHeader("GPU UTILIZATION", "\(monitor.gpuStats.deviceUtilization)%", gpuPurple, note: "last 5 min", valueSize: 25)
                            SparklineView(data: monitor.gpuHistory.map { Double($0) }, color: gpuPurple, maxValue: 100.0,
                                          showGrid: true, yQuarterLabel: { f in "\(Int(f * 100))" },
                                          hoverLabel: { f in "\(Int((f * 100).rounded()))%" })
                                .frame(height: 60)
                        }
                        .padding(12)
                        .background(gpuPurple.opacity(0.08))
                        .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 12) {
                            // Pipeline stages of the one GPU engine: the tiler bins
                            // geometry into tiles, the renderer shades them; read the
                            // pair relatively to spot geometry-bound vs fill-bound work.
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    graphHeader("RENDERER UTIL.", "\(monitor.gpuStats.rendererUtilization)%", gpuPurple, note: "")
                                    UsageBarView(segments: [(Double(monitor.gpuStats.rendererUtilization) / 100.0, gpuPurple)], height: 8)
                                }
                                .frame(maxWidth: .infinity)
                                VStack(alignment: .leading, spacing: 6) {
                                    graphHeader("TILER UTIL.", "\(monitor.gpuStats.tilerUtilization)%", gpuPurple, note: "")
                                    UsageBarView(segments: [(Double(monitor.gpuStats.tilerUtilization) / 100.0, gpuPurple)], height: 8)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)

                    // Memory budget: the GPU's allowance and the spend against it. The
                    // wired limit pair heads the card as the budget line; each claim
                    // beneath is one combo card, the readout heading its own history.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Memory budget")
                            .font(.system(size: 13, weight: .semibold))
                        let inUseCapBytes = monitor.wiredLimitMB > 0 ? UInt64(monitor.wiredLimitMB) * 1_048_576 : (monitor.defaultWiredLimitBytes > 0 ? monitor.defaultWiredLimitBytes : monitor.memoryStats.totalBytes)
                        // The driver's leash, reunited with the graph it caps: the limit
                        // is the GPU's own parameter (Apple files it under the iogpu
                        // namespace) and headroom is limit minus In-Use, both GPU-side
                        // quantities. A parameter governing an actor is not pool state,
                        // which is why this does not live in the Unified Memory column.
                        HStack(spacing: 12) {
                            if monitor.wiredLimitMB > 0 {
                                let limitBytes = UInt64(monitor.wiredLimitMB) * 1_048_576
                                let gpuWiredNow = monitor.gpuStats.inUseMemory
                                let wiredAvail = limitBytes > gpuWiredNow ? limitBytes - gpuWiredNow : 0
                                StatItem(label: "WIRED LIMIT HEADROOM", value: "\u{2264} " + formatMemory(wiredAvail), color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                StatItem(label: "WIRED LIMIT", value: formatMemory(limitBytes), color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if monitor.defaultWiredLimitBytes > 0 {
                                // The sysctl is unset, so the effective limit is the macOS
                                // default, read from Metal rather than guessed.
                                let limitBytes = monitor.defaultWiredLimitBytes
                                let wiredAvail = limitBytes > monitor.gpuStats.inUseMemory ? limitBytes - monitor.gpuStats.inUseMemory : 0
                                StatItem(label: "WIRED LIMIT HEADROOM", value: "\u{2264} " + formatMemory(wiredAvail), color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                StatItem(label: "WIRED LIMIT (DEFAULT)", value: formatMemory(limitBytes), color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                StatItem(label: "WIRED LIMIT HEADROOM", value: "n/a", color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                StatItem(label: "WIRED LIMIT", value: "macOS default", color: .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                        let inUseCapFrac = Double(inUseCapBytes) / Double(monitor.memoryStats.totalBytes)
                        let inUseCapGB = Double(inUseCapBytes) / 1_073_741_824
                        VStack(alignment: .leading, spacing: 8) {
                            // IN-USE is resident, resident is wired, and wired is capped, so the
                            // wired limit is this chart's true ceiling (fallback: total if unset).
                            graphHeader("GPU MEM IN-USE", formatMemory(monitor.gpuStats.inUseMemory), gpuPurple,
                                        note: monitor.wiredLimitMB > 0 ? "of \(formatMemory(inUseCapBytes)) wired limit" : "of \(formatMemory(monitor.memoryStats.totalBytes))")
                            SparklineView(data: monitor.gpuMemHistory, color: gpuPurple, maxValue: inUseCapFrac,
                                          showGrid: true, yQuarterLabel: { f in String(format: "%.0fG", f * inUseCapGB) },
                                          hoverLabel: { f in String(format: "%.1f GB", f * inUseCapGB) })
                                .frame(height: 60)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 8) {
                            // MAPPED is reservation, not residency: file-backed mappings are not
                            // wired, so the limit does not bound it and mapped can even exceed
                            // total. Total is the largest honest denominator; clamp pins overflow
                            // at the ceiling rather than drawing past the axis.
                            graphHeader("GPU MEM MAPPED", formatMemory(monitor.gpuStats.allocatedMemory), gpuPurpleDark,
                                        note: "of \(formatMemory(monitor.memoryStats.totalBytes))")
                            SparklineView(data: monitor.gpuMappedHistory.map { min($0, 1.0) }, color: gpuPurpleDark, maxValue: 1.0,
                                          showGrid: true, yQuarterLabel: { f in String(format: "%.0fG", f * totalGB) },
                                          hoverLabel: { f in String(format: "%.1f GB", f * totalGB) })
                                .frame(height: 60)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)
                }
                .padding([.horizontal, .bottom], 16)
                .background(GeometryReader { g in Color.clear.preference(key: ColumnContentHeightKey.self, value: g.frame(in: .global).maxY) })
                .padding(.top, 12)
            }
            .frame(minWidth: gpuColMinWidth, idealWidth: gpuColMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { g in Color.clear.preference(key: ColumnViewportHeightKey.self, value: g.frame(in: .global).maxY) })
            }

            if showCPU {
            // MIDDLE COLUMN: CPU
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "CPU", icon: "cpu")

                    // Overview: the whole CPU story; the hero combo card is tinted,
                    // and the cluster bars are already readout-headed charts, so the
                    // cores card needs no separate stat row.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Overview")
                            .font(.system(size: 13, weight: .semibold))
                        VStack(alignment: .leading, spacing: 8) {
                            graphHeader("CPU UTILIZATION", "\(Int((monitor.cpuStats.overall * 100).rounded()))%", .blue, note: "last 5 min", valueSize: 25)
                            SparklineView(data: monitor.cpuHistory.map { $0 * 100 }, color: .blue, maxValue: 100.0,
                                          showGrid: true, yQuarterLabel: { f in "\(Int(f * 100))" },
                                          hoverLabel: { f in "\(Int((f * 100).rounded()))%" })
                                .frame(height: 60)
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(8)
                        VStack(alignment: .leading, spacing: 12) {
                            // Two cluster halves in the combo grammar: each header carries
                            // the identity, count, and the large value; the bar colors bind
                            // the per-core chart below, so no legend is needed.
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    graphHeader("E-CORE UTIL.", "\(Int((monitor.cpuStats.efficiency * 100).rounded()))%", .teal, note: "")
                                    UsageBarView(segments: [(monitor.cpuStats.efficiency, .teal)], height: 8)
                                }
                                .frame(maxWidth: .infinity)
                                VStack(alignment: .leading, spacing: 6) {
                                    graphHeader("P-CORE UTIL.", "\(Int((monitor.cpuStats.performance * 100).rounded()))%", .blue, note: "")
                                    UsageBarView(segments: [(monitor.cpuStats.performance, .blue)], height: 8)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            Text("PER-CORE")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            PerCoreBarsView(perCore: monitor.cpuStats.perCore,
                                            efficiencyCount: monitor.cpuStats.efficiencyCoreCount)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)

                }
                .padding([.horizontal, .bottom], 16)
                .background(GeometryReader { g in Color.clear.preference(key: ColumnContentHeightKey.self, value: g.frame(in: .global).maxY) })
                .padding(.top, 12)
            }
            .frame(minWidth: cpuColMinWidth, idealWidth: cpuColMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { g in Color.clear.preference(key: ColumnViewportHeightKey.self, value: g.frame(in: .global).maxY) })
            }

            if showProcesses {
            // RIGHT COLUMN: Process footprints
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(title: "Processes", icon: "list.bullet.rectangle")
                    Spacer()
                    let totalProc = monitor.processes.reduce(0.0) { $0 + $1.residentMB }
                    Text("\(monitor.processes.count) \u{2022} \(formatMB(totalProc))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("Sort:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    ForEach(ProcessSortKey.allCases, id: \.self) { key in
                        SortButton(
                            label: key.rawValue, key: key,
                            currentKey: $monitor.processSortKey,
                            ascending: $monitor.processSortAscending,
                            action: { monitor.resortProcesses() }
                        )
                    }
                }

                let maxMB = monitor.processes.map(\.residentMB).max() ?? 1.0

                if monitor.processes.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading...")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(monitor.processes) { proc in
                                ProcessRowView(proc: proc, maxMB: maxMB)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom], 12)
            .padding(.top, 12)
            .frame(minWidth: processesColMinWidth, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            // Rebuild the splits whenever the visible set changes: HSplitView
            // otherwise restores stale divider offsets from the previous set,
            // which can clip the first column off the left edge.
            .id("\(showMemory)\(showGPU)\(showCPU)\(showProcesses)")
        }
        .onPreferenceChange(ColumnContentHeightKey.self) { h in launchFitContentH = h; postLaunchFitIfReady() }
        .onPreferenceChange(ColumnViewportHeightKey.self) { h in launchFitViewportH = h; postLaunchFitIfReady() }
        // Columns no longer need traffic-light clearance; the top bar carries it.
        // No fixed height floor: with column toggles, the honest minimum is whatever
        // is visible, so bar-only mode can shrink to just the bar.
        .frame(minWidth: minWindowWidth, idealWidth: windowWidth, minHeight: 0, idealHeight: windowHeight)
        .background(.background)
    }
}

// MARK: - App Delegate (windowed, lives in the Dock)

class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here (not by the SwiftUI view) so monitoring keeps running while the
    // window is closed. The app stays in the Dock and keeps collecting data.
    let monitor = SystemMonitor()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // Dock icon + standard app menu, not a menu-bar extra

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Puer"
        // Seamless titlebar: transparent, no title text, content flows underneath.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
        // Assigning a hosting controller shrinks the window to the layout's fitting size;
        // force it back to the intended size so columns open at their ideal widths.
        window.setContentSize(NSSize(width: windowWidth, height: windowHeight))
        // Launch fit: absorb the one-time deficit the layout reports, so the
        // window opens tall enough that no metric column scrolls at launch.
        NotificationCenter.default.addObserver(forName: .puerLaunchHeightDeficit, object: nil, queue: .main) { [weak self] note in
            guard let self, let d = note.userInfo?["deficit"] as? CGFloat, d > 0 else { return }
            let content = self.window.contentRect(forFrameRect: self.window.frame).size
            let screenCap = ((self.window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude) - 40
            let target = min(content.height + d, screenCap)
            guard target > content.height + 0.5 else { return }
            self.window.setContentSize(NSSize(width: content.width, height: target))
            self.window.center()
        }
        window.center()
        window.isReleasedWhenClosed = false  // closing just hides it; we reopen the same window
        self.window = window

        showWindow()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep the app (and the monitor's timers) alive after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the Dock icon with no visible window reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }
}

// MARK: - App Entry Point

@main
struct PuerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
