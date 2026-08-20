import SwiftUI
import AppKit
import Darwin
import Foundation
import IOKit

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
    let pressure: Double  // derived from 1 - system-wide free percentage
    let swapInsBytes: UInt64   // cumulative since boot (pages * pageSize)
    let swapOutsBytes: UInt64  // cumulative since boot
    let kernelPressureLevel: Int  // kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical

    var usedFraction: Double { Double(usedBytes) / Double(max(totalBytes, 1)) }
    var freeFraction: Double { Double(freeBytes) / Double(max(totalBytes, 1)) }
    var availableBytes: UInt64 { totalBytes - usedBytes }  // everything OS can reclaim
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
    case name = "Name"
    case pid = "PID"
}

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

func getMemoryPressure() -> Double {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return 0 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return 0 }
    // Derived from "System-wide memory free percentage: XX%"
    if let range = output.range(of: "free percentage: ") {
        let after = output[range.upperBound...]
        if let pctEnd = after.firstIndex(of: "%"), let pct = Int(after[after.startIndex..<pctEnd]) {
            return 1.0 - (Double(pct) / 100.0)
        }
    }
    return 0
}

func readMemoryStats() -> MemoryStats {
    let total = getPhysicalMemory()
    let pageSize = UInt64(vm_kernel_page_size)

    guard let vm = getVMStats() else {
        return MemoryStats(totalBytes: total, usedBytes: 0, activeBytes: 0, inactiveBytes: 0,
                           wiredBytes: 0, compressedBytes: 0, freeBytes: total, appBytes: 0, freeCountBytes: 0, kernelOtherBytes: 0, purgeableBytes: 0, speculativeBytes: 0, throttledBytes: 0,
                           swapUsedBytes: 0, pressure: 0,
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
    // heap on the inactive queue. Used remains the transparent bottom-up sum
    // app + wired + compressed; Activity Monitor's own "Memory Used" adds an
    // undocumented, version-drifting remainder on top and will read higher.
    let appMem = internalMem > purgeable ? internalMem - purgeable : 0
    // Pages in no named queue: kernel allocations outside the wire count.
    // This is the bucket Activity Monitor folds into its "Memory Used".
    let named = freeCount + active + inactive + speculative + wired + compressed + throttled
    let kernelOther = total > named ? total - named : 0
    let usedApprox = appMem + wired + compressed
    let swap = getSwapUsage()
    let pressure = getMemoryPressure()

    return MemoryStats(
        totalBytes: total, usedBytes: usedApprox, activeBytes: active,
        inactiveBytes: inactive, wiredBytes: wired, compressedBytes: compressed,
        freeBytes: total - usedApprox, appBytes: appMem, freeCountBytes: freeCount, kernelOtherBytes: kernelOther, purgeableBytes: purgeable, speculativeBytes: speculative, throttledBytes: throttled,
        swapUsedBytes: swap, pressure: pressure,
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
    @Published var memoryStats = MemoryStats(totalBytes: 0, usedBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, freeBytes: 0, appBytes: 0, freeCountBytes: 0, kernelOtherBytes: 0, purgeableBytes: 0, speculativeBytes: 0, throttledBytes: 0, swapUsedBytes: 0, pressure: 0, swapInsBytes: 0, swapOutsBytes: 0, kernelPressureLevel: 1)
    @Published var gpuStats = GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "")
    @Published var cpuStats = CPUStats(overall: 0, performance: 0, efficiency: 0, perCore: [], performanceCoreCount: 0, efficiencyCoreCount: 0)
    @Published var processes: [ProcessMemory] = []
    @Published var processSortKey: ProcessSortKey = .memory
    @Published var processSortAscending: Bool = false
    @Published var memoryHistory: [Double] = []  // used fraction
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
            let mem = readMemoryStats()
            let gpu = readGPUStats()
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
                                     residentMB: d.mb, cpuPercent: d.cpu)
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
    out += "used: \(gib(mem.usedBytes)) GiB (app \(gib(mem.appBytes)) + wired \(gib(mem.wiredBytes)) + compressed \(gib(mem.compressedBytes)))\n"
    // Plain file cache: file-backed pages on the active/inactive queues. With
    // purgeable and speculative this reconstructs Activity Monitor's Cached
    // Files; in Puer's model all three live inside Available.
    let fileCache = UInt64(max(0, Int64(mem.activeBytes) + Int64(mem.inactiveBytes) - Int64(mem.appBytes) - Int64(mem.purgeableBytes)))
    out += "purgeable cache: \(gib(mem.purgeableBytes)) GiB; speculative cache: \(gib(mem.speculativeBytes)) GiB; file cache: \(gib(fileCache)) GiB\n"
    // Full kernel accounting identity: every physical page in a named bucket,
    // reconciled against total, with the bookkeeping residue shown explicitly.
    out += "kernel accounting: free \(gib(mem.freeCountBytes)) + active \(gib(mem.activeBytes)) + inactive \(gib(mem.inactiveBytes)) + speculative \(gib(mem.speculativeBytes)) + wired \(gib(mem.wiredBytes)) + compressed \(gib(mem.compressedBytes)) + throttled \(gib(mem.throttledBytes)) + reserved \(gib(mem.kernelOtherBytes)) = \(gib(mem.freeCountBytes + mem.activeBytes + mem.inactiveBytes + mem.speculativeBytes + mem.wiredBytes + mem.compressedBytes + mem.throttledBytes + mem.kernelOtherBytes)) GiB (identity vs \(gib(mem.totalBytes)) total)\n"
    // Empirical fit, within ~0.1 GiB across observed states: Activity Monitor's
    // "Memory Used" counts purgeable cache and the reserved carveout in Used,
    // which is why it reads above ours and overlaps its own Cached Files.
    out += "am-style used (empirical: app + purgeable + wired + compressed + reserved): \(gib(mem.appBytes + mem.purgeableBytes + mem.wiredBytes + mem.compressedBytes + mem.kernelOtherBytes)) GiB\n"
    out += "swap used: \(gib(mem.swapUsedBytes)) GiB, pressure: \(pct(mem.pressure))\n"
    out += "kernel pressure: \(kernelPressureName(mem.kernelPressureLevel)), thermal: \(thermalStateName(monitor.thermalState)), power mode: \(monitor.lowPowerMode ? "low power" : "normal")\n"
    let sessionSwapOut = monitor.memoryStats.swapOutsBytes > monitor.launchSwapOutsBytes ? monitor.memoryStats.swapOutsBytes - monitor.launchSwapOutsBytes : 0
    let sessionSwapIn = monitor.memoryStats.swapInsBytes > monitor.launchSwapInsBytes ? monitor.memoryStats.swapInsBytes - monitor.launchSwapInsBytes : 0
    let lastIODesc = monitor.lastSwapIODate.map { "\(max(0, Int(Date().timeIntervalSince($0) / 60))) min ago" } ?? "none since launch"
    out += "swap rates: in \(String(format: "%.1f", monitor.swapInRateMBs)) MB/s, out \(String(format: "%.1f", monitor.swapOutRateMBs)) MB/s; session out: \(gib(sessionSwapOut)) GiB, session in: \(gib(sessionSwapIn)) GiB; last swap io: \(lastIODesc)\n"
    if monitor.wiredLimitMB > 0 {
        let limitBytes = UInt64(monitor.wiredLimitMB) * 1_048_576
        let headroom = limitBytes > mem.wiredBytes ? limitBytes - mem.wiredBytes : 0
        out += "wired: \(gib(mem.wiredBytes)) GiB of \(gib(limitBytes)) GiB limit (limit headroom \(gib(headroom)) GiB)\n"
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
    out += "memory used: \(seriesSummary(monitor.memoryHistory))\n"
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

    // Fixed x-axis window in grid mode; keep in sync with SystemMonitor.maxHistory
    // (150 samples at 2s). Data anchors to the right edge (now) and grows leftward.
    let windowSeconds: Double = 300

    init(data: [Double], color: Color, maxValue: Double? = nil,
         sampleInterval: Double = 2.0, showGrid: Bool = false,
         yQuarterLabel: ((Double) -> String)? = nil) {
        self.data = data
        self.color = color
        self.maxValue = maxValue
        self.sampleInterval = sampleInterval
        self.showGrid = showGrid
        self.yQuarterLabel = yQuarterLabel
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

struct StatItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Never wrap: shrink slightly instead, so label and value each stay on
            // one line and stat cells keep a shared baseline at any column width.
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct RateCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
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
struct CoreLoadRow: View {
    let label: String
    let usage: Double  // 0-1
    let count: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(label) \u{00B7} \(count) core\(count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int((usage * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            UsageBarView(segments: [(usage, color)], height: 8)
        }
    }
}

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
                    Text("\(Int((usage * 100).rounded()))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// Fixed three-column layout: memory (500) + CPU (360) + processes (320) + 2 dividers.
let windowWidth: CGFloat = 1420
let windowHeight: CGFloat = 720

// GPU family: two solid shades on one royal-violet ladder; every GPU element
// and WIRED derive from these two constants.
// Primary (light purple): active claims, utilization, WIRED.
let gpuPurple = Color(red: 0.78, green: 0.42, blue: 1.00)
// Secondary (one step darker): mapped/idle claims; solid so text stays readable.
let gpuPurpleDark = Color(red: 0.58, green: 0.30, blue: 0.88)
// Reserved carveout: deep brown, kept well apart from Compressed orange.
let reservedBrown = Color(red: 0.42, green: 0.27, blue: 0.15)
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
                .help("\(title): \(state)")
        } else {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(state)
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

// Three-state banner: ongoing pressure (red, with swap-out rate and growers),
// past event this session (orange, with when + what grew), stale residue (quiet gray).
// The app cannot see events from before its own launch; residue is labeled as such.
struct PressureBannerView: View {
    @ObservedObject var monitor: SystemMonitor

    private var ongoing: Bool {
        monitor.memoryStats.kernelPressureLevel > 1 || monitor.swapOutRateMBs > 5.0
    }

    var body: some View {
        if ongoing {
            banner(color: .red, icon: "exclamationmark.octagon.fill",
                   text: "Memory pressure ACTIVE: kernel \(kernelPressureName(monitor.memoryStats.kernelPressureLevel)), swap out \(String(format: "%.0f", monitor.swapOutRateMBs)) MB/s"
                        + (monitor.lastEventGrowers.isEmpty ? "" : " \u{2022} growing: \(monitor.lastEventGrowers.joined(separator: ", "))"))
        } else if let evt = monitor.lastPressureEvent {
            banner(color: .orange, icon: "exclamationmark.triangle.fill",
                   text: "Pressure \(minutesAgo(evt)) ago this session"
                        + (monitor.lastEventGrowers.isEmpty ? "" : " \u{2022} grew most before: \(monitor.lastEventGrowers.joined(separator: ", "))"))
        }
    }

    private func minutesAgo(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? "under a minute" : "\(m) min"
    }

    private func banner(color: Color, icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }
}

// A labeled full-width trend row: metric name (with units), current value inline,
// sparkline beneath, optional caption. Replaces the old unlabeled side-by-side charts.
struct TrendRowView: View {
    let title: String
    let current: String
    let caption: String?
    let data: [Double]
    let maxValue: Double?
    let color: Color
    let yQuarterLabel: ((Double) -> String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(current)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            SparklineView(data: data, color: color, maxValue: maxValue,
                          showGrid: true, yQuarterLabel: yQuarterLabel)
                .frame(height: 60)
            if let caption = caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var reportCopied = false
    // Column visibility; HSplitView redistributes width among whatever remains.
    @State private var showMemory = true
    @State private var showGPU = true
    @State private var showCPU = true
    @State private var showProcesses = true

    // Two-layer compression restriction: the window can never shrink below the
    // top bar's fully compacted (tier-3) width, and never below the summed
    // minimums of whichever columns are visible. Fewer columns, more compression.
    private var minWindowWidth: CGFloat {
        let topBarMin: CGFloat = 480  // final tier: title, icon toggles, icon pills, report icon; no variable-width text remains
        var columns: CGFloat = 0
        if showMemory { columns += 300 }
        if showGPU { columns += 260 }
        if showCPU { columns += 260 }
        if showProcesses { columns += 220 }
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

                    // HEADLINE: Used memory (available on the line beneath)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.1f", Double(monitor.memoryStats.usedBytes) / 1_073_741_824))
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(headroomColor)
                            Text("GB Used")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(headroomColor.opacity(0.8))
                        }
                        Text("\(formatMemory(monitor.memoryStats.availableBytes)) available of \(formatMemory(monitor.memoryStats.totalBytes)) unified memory")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Divider()
                            .padding(.vertical, 2)
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            GridRow {
                                StatItem(label: "APP", value: formatMemory(monitor.memoryStats.appBytes), color: .blue)
                                // Row theme: app memory plus the two reclaimable caches beside
                                // it, the exact trio Activity Monitor folds into its Used.
                                StatItem(label: "PURGEABLE CACHE", value: formatMemory(monitor.memoryStats.purgeableBytes), color: .secondary)
                                StatItem(label: "SPECULATIVE CACHE", value: formatMemory(monitor.memoryStats.speculativeBytes), color: .secondary)
                            }
                            Divider()
                                .gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                StatItem(label: "WIRED", value: formatMemory(monitor.memoryStats.wiredBytes), color: gpuPurple)
                                if monitor.wiredLimitMB > 0 {
                                    let limitBytes = UInt64(monitor.wiredLimitMB) * 1_048_576
                                    let wiredAvail = limitBytes > monitor.memoryStats.wiredBytes ? limitBytes - monitor.memoryStats.wiredBytes : 0
                                    StatItem(label: "WIRED LIMIT HEADROOM", value: formatMemory(wiredAvail), color: .secondary)
                                    StatItem(label: "WIRED LIMIT", value: formatMemory(limitBytes), color: .secondary)
                                } else {
                                    StatItem(label: "WIRED LIMIT HEADROOM", value: "n/a", color: .secondary)
                                    StatItem(label: "WIRED LIMIT", value: "macOS default", color: .secondary)
                                }
                            }
                            Divider()
                                .gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                StatItem(label: "COMPRESSED", value: formatMemory(monitor.memoryStats.compressedBytes), color: .orange)
                                StatItem(label: "PRESSURE", value: kernelPressureName(monitor.memoryStats.kernelPressureLevel),
                                         color: monitor.memoryStats.kernelPressureLevel > 1 ? .orange : .secondary)
                                let lastPressure = monitor.lastPressureEvent.map { d -> String in
                                    let m = Int(Date().timeIntervalSince(d) / 60)
                                    return m < 1 ? "<1 min ago" : "\(m) min ago"
                                } ?? "-"
                                StatItem(label: "LAST PRESSURE", value: lastPressure, color: monitor.lastPressureEvent != nil ? .orange : .secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(headroomColor.opacity(0.06))
                    .cornerRadius(12)

                    // Pressure story: ongoing / past-event-this-session / stale residue
                    PressureBannerView(monitor: monitor)

                    // UNIFIED MEMORY POOL
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Unified memory allocation")
                            .font(.system(size: 13, weight: .semibold))

                        let total = Double(max(monitor.memoryStats.totalBytes, 1))
                        let gpuActive = Double(monitor.gpuStats.inUseMemory)
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

                        // Thick unified bar
                        GeometryReader { geo in
                            let w = geo.size.width
                            HStack(spacing: 0) {
                                // Kernel remainder first: pinned, unreclaimable, uninfluenceable,
                                // so maximally far from Available. Then App, the wired family,
                                // Compressed, and the reclaimable grey ladder.
                                Rectangle()
                                    .fill(reservedBrown)
                                    .frame(width: max(0, w * CGFloat(kernelRemB / total)))
                                Rectangle()
                                    .fill(Color.blue)
                                    .frame(width: max(0, w * CGFloat(appUsed / total)))
                                Rectangle()
                                    .fill(gpuPurple)
                                    .frame(width: max(gpuActive > 0 ? 2 : 0, w * CGFloat(gpuActive / total)))
                                Rectangle()
                                    .fill(gpuPurpleDark)
                                    .frame(width: max(0, w * CGFloat(wiredOther / total)))
                                Rectangle()
                                    .fill(Color.orange)
                                    .frame(width: max(0, w * CGFloat(compUsed / total)))
                                // Available tiers in a grey ladder
                                Rectangle()
                                    .fill(Color.gray.opacity(0.42))
                                    .frame(width: max(0, w * CGFloat(purgeableB / total)))
                                Rectangle()
                                    .fill(Color.gray.opacity(0.32))
                                    .frame(width: max(0, w * CGFloat(speculativeB / total)))
                                Rectangle()
                                    .fill(Color.gray.opacity(0.22))
                                    .frame(width: max(0, w * CGFloat(fileCacheB / total)))
                                Rectangle()
                                    .fill(Color.gray.opacity(0.10))
                                    .frame(width: max(0, w * CGFloat(unallocatedB / total)))
                                Spacer(minLength: 0)
                            }
                            .frame(height: 36)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(height: 36)

                        // Legend
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 14) {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(reservedBrown).frame(width: 10, height: 10)
                                    Text("Reserved \(formatMemory(UInt64(kernelRemB)))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 10, height: 10)
                                    Text("App \(formatMemory(UInt64(appUsed)))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(gpuPurple).frame(width: 10, height: 10)
                                    Text("Wired - GPU In-Use \(formatMemory(monitor.gpuStats.inUseMemory))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(gpuPurpleDark).frame(width: 10, height: 10)
                                    Text("Wired - Other \(formatMemory(UInt64(wiredOther)))")
                                        .font(.system(size: 10))
                                }
                            }
                            HStack(spacing: 14) {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 10, height: 10)
                                    Text("Compressed \(formatMemory(UInt64(compUsed)))")
                                        .font(.system(size: 10))
                                }
                            }
                            HStack(spacing: 14) {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.42)).frame(width: 10, height: 10)
                                    Text("Available - Purgeable Cache \(formatMemory(UInt64(purgeableB)))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.32)).frame(width: 10, height: 10)
                                    Text("Available - Speculative Cache \(formatMemory(UInt64(speculativeB)))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.22)).frame(width: 10, height: 10)
                                    Text("Available - File Cache \(formatMemory(UInt64(fileCacheB)))")
                                        .font(.system(size: 10))
                                }
                            }
                            HStack(spacing: 14) {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.10)).frame(width: 10, height: 10)
                                    Text("Available - Unallocated \(formatMemory(UInt64(unallocatedB)))")
                                        .font(.system(size: 10))
                                }
                            }
                        }
                        .foregroundColor(.secondary)

                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

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
                            return m < 1 ? "<1 min ago" : "\(m) min ago"
                        } ?? "-")
                        HStack(spacing: 12) {
                            StatItem(label: "ON DISK", value: formatMemory(monitor.memoryStats.swapUsedBytes), color: .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatItem(label: "SESSION IN", value: formatMemory(sessionIn), color: .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatItem(label: "SESSION OUT", value: formatMemory(sessionOut), color: .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 12) {
                            StatItem(label: "LAST I/O", value: lastIO, color: swapIOActive ? .orange : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatItem(label: "IN RATE", value: String(format: "%.1f MB/s", monitor.swapInRateMBs), color: .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatItem(label: "OUT RATE", value: String(format: "%.1f MB/s", monitor.swapOutRateMBs), color: monitor.swapOutRateMBs > 0.5 ? .orange : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // Memory trend: headerless card, context folded into the row title
                    VStack(alignment: .leading, spacing: 12) {
                        let peakUsedFrac = monitor.memoryHistory.max() ?? monitor.memoryStats.usedFraction
                        let minAvailBytes = UInt64(Double(monitor.memoryStats.totalBytes) * max(0, 1 - peakUsedFrac))
                        TrendRowView(title: "MEMORY USED (last 5 min, of \(formatMemory(monitor.memoryStats.totalBytes)))",
                                     current: formatMemory(monitor.memoryStats.usedBytes),
                                     caption: "Minimum available memory seen: \(formatMemory(minAvailBytes))",
                                     data: monitor.memoryHistory,
                                     maxValue: 1.0, color: headroomColor,
                                     yQuarterLabel: { f in String(format: "%.0fG", f * totalGB) })
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)


                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
                .padding([.horizontal, .bottom], 16)
                .padding(.top, 12)
            }
            .frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }

            if showGPU {
            // GPU COLUMN
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "GPU", icon: "cube.transparent")

                    RateCardView(
                        title: "GPU UTILIZATION",
                        value: "\(monitor.gpuStats.deviceUtilization)%",
                        subtitle: "Renderer \(monitor.gpuStats.rendererUtilization)% \u{2022} Tiler \(monitor.gpuStats.tilerUtilization)%",
                        icon: "cube.transparent",
                        color: gpuPurple
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        TrendRowView(title: "GPU UTILIZATION (%, last 5 min)",
                                     current: "\(monitor.gpuStats.deviceUtilization)%",
                                     caption: nil,
                                     data: monitor.gpuHistory.map { Double($0) },
                                     maxValue: 100.0, color: gpuPurple,
                                     yQuarterLabel: { f in "\(Int(f * 100))" })
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // Memory claims on the unified pool, from the GPU's perspective
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Memory claims")
                            .font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 16) {
                            StatItem(label: "GPU MEM IN-USE", value: formatMemory(monitor.gpuStats.inUseMemory), color: gpuPurple)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatItem(label: "GPU MEM MAPPED", value: formatMemory(monitor.gpuStats.allocatedMemory), color: gpuPurpleDark)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // Trends
                    VStack(alignment: .leading, spacing: 12) {
                        // IN-USE is resident, resident is wired, and wired is capped, so the
                        // wired limit is this chart's true ceiling (fallback: total if unset).
                        let inUseCapBytes = monitor.wiredLimitMB > 0 ? UInt64(monitor.wiredLimitMB) * 1_048_576 : monitor.memoryStats.totalBytes
                        let inUseCapFrac = Double(inUseCapBytes) / Double(monitor.memoryStats.totalBytes)
                        let inUseCapGB = Double(inUseCapBytes) / 1_073_741_824
                        TrendRowView(title: monitor.wiredLimitMB > 0
                                        ? "GPU MEMORY IN-USE (of \(formatMemory(inUseCapBytes)) wired limit)"
                                        : "GPU MEMORY IN-USE (of \(formatMemory(monitor.memoryStats.totalBytes)))",
                                     current: formatMemory(monitor.gpuStats.inUseMemory),
                                     caption: nil,
                                     data: monitor.gpuMemHistory,
                                     maxValue: inUseCapFrac, color: gpuPurple,
                                     yQuarterLabel: { f in String(format: "%.0fG", f * inUseCapGB) })
                        // MAPPED is reservation, not residency: file-backed mappings are not
                        // wired, so the limit does not bound it and mapped can even exceed
                        // total. Total is the largest honest denominator; clamp pins overflow
                        // at the ceiling rather than drawing past the axis.
                        TrendRowView(title: "GPU MEMORY MAPPED (of \(formatMemory(monitor.memoryStats.totalBytes)))",
                                     current: formatMemory(monitor.gpuStats.allocatedMemory),
                                     caption: nil,
                                     data: monitor.gpuMappedHistory.map { min($0, 1.0) },
                                     maxValue: 1.0, color: gpuPurpleDark,
                                     yQuarterLabel: { f in String(format: "%.0fG", f * totalGB) })
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
                .padding([.horizontal, .bottom], 16)
                .padding(.top, 12)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }

            if showCPU {
            // MIDDLE COLUMN: CPU
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "CPU", icon: "cpu")

                    RateCardView(
                        title: "CPU UTILIZATION",
                        value: "\(Int((monitor.cpuStats.overall * 100).rounded()))%",
                        subtitle: "P-cores \(Int((monitor.cpuStats.performance * 100).rounded()))% \u{2022} E-cores \(Int((monitor.cpuStats.efficiency * 100).rounded()))%",
                        icon: "cpu",
                        color: .blue
                    )

                    // Cluster loads
                    VStack(alignment: .leading, spacing: 10) {
                        CoreLoadRow(label: "Performance", usage: monitor.cpuStats.performance,
                                    count: monitor.cpuStats.performanceCoreCount, color: .blue)
                        CoreLoadRow(label: "Efficiency", usage: monitor.cpuStats.efficiency,
                                    count: monitor.cpuStats.efficiencyCoreCount, color: .teal)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // Per-core bars
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Per-core load")
                            .font(.system(size: 12, weight: .semibold))
                        PerCoreBarsView(perCore: monitor.cpuStats.perCore,
                                        efficiencyCount: monitor.cpuStats.efficiencyCoreCount)
                        HStack(spacing: 14) {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(.teal).frame(width: 10, height: 10)
                                Text("Efficiency").font(.system(size: 10))
                            }
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 10, height: 10)
                                Text("Performance").font(.system(size: 10))
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // CPU history
                    VStack(alignment: .leading, spacing: 8) {
                        TrendRowView(title: "CPU LOAD (%, last 5 min)",
                                     current: "\(Int((monitor.cpuStats.overall * 100).rounded()))%",
                                     caption: nil,
                                     data: monitor.cpuHistory.map { $0 * 100 },
                                     maxValue: 100.0, color: .blue,
                                     yQuarterLabel: { f in "\(Int(f * 100))" })
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
                .padding([.horizontal, .bottom], 16)
                .padding(.top, 12)
            }
            .frame(minWidth: 260, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(minWidth: 220, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            // Rebuild the splits whenever the visible set changes: HSplitView
            // otherwise restores stale divider offsets from the previous set,
            // which can clip the first column off the left edge.
            .id("\(showMemory)\(showGPU)\(showCPU)\(showProcesses)")
        }
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
