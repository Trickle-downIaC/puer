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
    let appBytes: UInt64  // approximate app-associated memory
    let swapUsedBytes: UInt64
    let pressure: Double  // derived from 1 - system-wide free percentage

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

struct ProcessMemory: Identifiable {
    let id: String
    let name: String
    let pid: Int
    let residentMB: Double
    let cpuPercent: Double
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
                           wiredBytes: 0, compressedBytes: 0, freeBytes: total, appBytes: 0,
                           swapUsedBytes: 0, pressure: 0)
    }

    let active = UInt64(vm.active_count) * pageSize
    let inactive = UInt64(vm.inactive_count) * pageSize
    let wired = UInt64(vm.wire_count) * pageSize
    let compressed = UInt64(vm.compressor_page_count) * pageSize
    let speculative = UInt64(vm.speculative_count) * pageSize
    let free = UInt64(vm.free_count) * pageSize
    let purgeable = UInt64(vm.purgeable_count) * pageSize

    // Approximate used memory = total - free - speculative - purgeable
    let usedApprox = total - free - speculative - purgeable
    let appMem = active + inactive - purgeable
    let swap = getSwapUsage()
    let pressure = getMemoryPressure()

    return MemoryStats(
        totalBytes: total, usedBytes: usedApprox, activeBytes: active,
        inactiveBytes: inactive, wiredBytes: wired, compressedBytes: compressed,
        freeBytes: free + speculative + purgeable, appBytes: appMem,
        swapUsedBytes: swap, pressure: pressure
    )
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

// MARK: - Physical Footprint (accurate memory, same metric as Activity Monitor)

func getPhysFootprint(_ pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), reboundPtr)
        }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

// MARK: - Top Processes by Memory

func readTopProcesses(limit: Int = 30) -> [ProcessMemory] {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-eo", "pid,rss,pcpu,comm", "-r"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var results: [ProcessMemory] = []
    let lines = output.split(separator: "\n").dropFirst() // skip header

    for line in lines.prefix(200) {
        let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard cols.count >= 4 else { continue }
        guard let pid = Int(cols[0]) else { continue }
        guard let rssKB = Double(cols[1]) else { continue }
        guard let cpu = Double(cols[2]) else { continue }
        var name = String(cols[3])
        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        }
        // Use physical footprint (accurate) instead of RSS (inflated by shared pages)
        let footprint = getPhysFootprint(Int32(pid))
        let mb = footprint > 0 ? Double(footprint) / 1_048_576.0 : rssKB / 1024.0
        if mb < 1 { continue }
        results.append(ProcessMemory(id: "\(name).\(pid)", name: name, pid: pid, residentMB: mb, cpuPercent: cpu))
    }

    // Aggregate by process name
    var aggregated: [String: (totalMB: Double, totalCPU: Double, pids: [Int], count: Int)] = [:]
    for p in results {
        var entry = aggregated[p.name] ?? (totalMB: 0, totalCPU: 0, pids: [], count: 0)
        entry.totalMB += p.residentMB
        entry.totalCPU += p.cpuPercent
        entry.pids.append(p.pid)
        entry.count += 1
        aggregated[p.name] = entry
    }

    return aggregated.map { name, data in
        let displayName = data.count > 1 ? "\(name) (\(data.count))" : name
        return ProcessMemory(id: name, name: displayName, pid: data.pids.first ?? 0,
                      residentMB: data.totalMB, cpuPercent: data.totalCPU)
    }
    .sorted { $0.residentMB > $1.residentMB }
    .prefix(limit)
    .map { $0 }
}

// MARK: - Monitor

class SystemMonitor: ObservableObject {
    @Published var memoryStats = MemoryStats(totalBytes: 0, usedBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, freeBytes: 0, appBytes: 0, swapUsedBytes: 0, pressure: 0)
    @Published var gpuStats = GPUStats(deviceUtilization: 0, rendererUtilization: 0, tilerUtilization: 0, inUseMemory: 0, allocatedMemory: 0, coreCount: 0, model: "")
    @Published var processes: [ProcessMemory] = []
    @Published var processSortKey: ProcessSortKey = .memory
    @Published var processSortAscending: Bool = false
    @Published var memoryHistory: [Double] = []  // used fraction
    @Published var gpuHistory: [Int] = []  // device utilization %
    @Published var gpuMemHistory: [Double] = []  // in-use GPU memory fraction

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private let maxHistory = 60

    init() {
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
            let mem = readMemoryStats()
            let gpu = readGPUStats()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.memoryStats = mem
                self.gpuStats = gpu

                self.memoryHistory.append(mem.usedFraction)
                if self.memoryHistory.count > self.maxHistory { self.memoryHistory.removeFirst() }

                self.gpuHistory.append(gpu.deviceUtilization)
                if self.gpuHistory.count > self.maxHistory { self.gpuHistory.removeFirst() }

                let totalMem = mem.totalBytes
                let gpuMemFrac = totalMem > 0 ? Double(gpu.inUseMemory) / Double(totalMem) : 0
                self.gpuMemHistory.append(gpuMemFrac)
                if self.gpuMemHistory.count > self.maxHistory { self.gpuMemHistory.removeFirst() }
            }
        }
    }

    func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let procs = readTopProcesses()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.processes = self.sortProcesses(procs)
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

    init(data: [Double], color: Color, maxValue: Double? = nil) {
        self.data = data
        self.color = color
        self.maxValue = maxValue
    }

    var body: some View {
        GeometryReader { geo in
            let maxVal = maxValue ?? max((data.max() ?? 1), 0.001)
            let w = geo.size.width
            let h = geo.size.height

            if data.count > 1 {
                Path { path in
                    for (i, val) in data.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(data.count - 1)
                        let y = h - (h * CGFloat(val / maxVal))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, lineWidth: 1.5)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, val) in data.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(data.count - 1)
                        let y = h - (h * CGFloat(val / maxVal))
                        if i == 0 { path.addLine(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))
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
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
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
                            .fill(Color.purple.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.purple.opacity(0.5))
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

struct ContentView: View {
    @StateObject private var monitor = SystemMonitor()

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
        HStack(alignment: .top, spacing: 0) {
            // LEFT COLUMN
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gpuer")
                                .font(.system(size: 20, weight: .bold))
                            Text("\(monitor.gpuStats.model) \u{2022} \(monitor.gpuStats.coreCount) GPU cores")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    // HEADLINE: Available memory
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.0f", availableGB))
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(headroomColor)
                            Text("GB Available")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(headroomColor.opacity(0.8))
                        }
                        Text("of \(formatMemory(monitor.memoryStats.totalBytes)) unified memory")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        let appsEstimate = max(1, Int(availableGB / 2))
                        Text("Room for ~\(appsEstimate) more large apps before pressure")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(headroomColor.opacity(0.06))
                    .cornerRadius(12)

                    // Swap warning
                    if monitor.memoryStats.swapUsedBytes > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11))
                            Text("\(formatMemory(monitor.memoryStats.swapUsedBytes)) pushed to disk \u{2014} system was under pressure recently")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(6)
                    }

                    // UNIFIED MEMORY POOL
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where your memory is going")
                            .font(.system(size: 13, weight: .semibold))

                        let total = Double(max(monitor.memoryStats.totalBytes, 1))
                        let gpuAlloc = Double(monitor.gpuStats.allocatedMemory)
                        let gpuActive = Double(monitor.gpuStats.inUseMemory)
                        let available = Double(monitor.memoryStats.availableBytes)
                        let gpuShown = min(gpuAlloc, total - available)
                        let otherUsed = max(0, total - gpuShown - available)

                        // Thick unified bar
                        GeometryReader { geo in
                            let w = geo.size.width
                            HStack(spacing: 0) {
                                // GPU active (bright green)
                                Rectangle()
                                    .fill(Color.green)
                                    .frame(width: max(gpuActive > 0 ? 2 : 0, w * CGFloat(gpuActive / total)))
                                // GPU mapped idle (lighter green)
                                Rectangle()
                                    .fill(Color.green.opacity(0.3))
                                    .frame(width: max(0, w * CGFloat(max(0, gpuShown - gpuActive) / total)))
                                // Other used (blue)
                                Rectangle()
                                    .fill(Color.blue.opacity(0.6))
                                    .frame(width: max(0, w * CGFloat(otherUsed / total)))
                                // Available (empty space)
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
                                    RoundedRectangle(cornerRadius: 2).fill(.green).frame(width: 10, height: 10)
                                    Text("GPU active \(formatMemory(monitor.gpuStats.inUseMemory))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.green.opacity(0.3)).frame(width: 10, height: 10)
                                    Text("GPU mapped \(formatMemory(monitor.gpuStats.allocatedMemory))")
                                        .font(.system(size: 10))
                                }
                            }
                            HStack(spacing: 14) {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(.blue.opacity(0.6)).frame(width: 10, height: 10)
                                    Text("Apps & OS \(formatMemory(UInt64(otherUsed)))")
                                        .font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(width: 10, height: 10)
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                    Text("Available \(formatMemory(UInt64(available)))")
                                        .font(.system(size: 10))
                                }
                            }
                        }
                        .foregroundColor(.secondary)

                        // Contextual explanation
                        if monitor.gpuStats.allocatedMemory > 10_000_000_000 {
                            Text("GPU has mapped \(formatMemory(monitor.gpuStats.allocatedMemory)) of your unified memory (likely model weights for local AI). This isn\u{2019}t separate VRAM \u{2014} it\u{2019}s your RAM, shared with the GPU.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    // GPU UTILIZATION
                    RateCardView(
                        title: "GPU UTILIZATION",
                        value: "\(monitor.gpuStats.deviceUtilization)%",
                        subtitle: "Renderer \(monitor.gpuStats.rendererUtilization)% \u{2022} Tiler \(monitor.gpuStats.tilerUtilization)%",
                        icon: "gpu",
                        color: .green
                    )

                    // HISTORY
                    VStack(alignment: .leading, spacing: 8) {
                        Text("History (2 min)")
                            .font(.system(size: 12, weight: .semibold))

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Available")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                SparklineView(data: monitor.memoryHistory.map { 1.0 - $0 }, color: headroomColor, maxValue: 1.0)
                                    .frame(height: 44)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("GPU Utilization")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                SparklineView(data: monitor.gpuHistory.map { Double($0) }, color: .green, maxValue: 100.0)
                                    .frame(height: 44)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
                .padding(16)
            }
            .frame(width: 520)

            Divider()

            // RIGHT COLUMN: Process footprints
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(title: "Memory Footprint", icon: "cpu")
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
            .padding(12)
            .frame(width: 320)
        }
        .frame(width: 840, height: 700)
        .background(.background)
    }
}

// MARK: - App Delegate for Menu Bar

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Gpuer")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 840, height: 700)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover

        NSApp.setActivationPolicy(.accessory)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - App Entry Point

@main
struct GpuerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
