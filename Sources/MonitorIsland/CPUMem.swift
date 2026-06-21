import Foundation
import Darwin

// Per-core CPU usage from host_processor_info, plus memory from host_statistics64.
// Holds previous tick state to compute deltas (the single-sampler pattern).
final class CPUMemSampler {
    private var prevTicks: [[UInt32]] = []   // [cpu][state]
    let sys: SysInfo

    init(sys: SysInfo) { self.sys = sys }

    // Returns per-logical-core usage 0..100 (index aligned to processor array).
    func samplePerCore() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let states = Int(CPU_STATE_MAX)
        let n = Int(cpuCount)
        var cur: [[UInt32]] = []
        cur.reserveCapacity(n)
        for c in 0..<n {
            var s = [UInt32](repeating: 0, count: states)
            for st in 0..<states {
                s[st] = UInt32(bitPattern: info[c * states + st])
            }
            cur.append(s)
        }

        var usage = [Double](repeating: 0, count: n)
        if prevTicks.count == n {
            for c in 0..<n {
                let u = Double(cur[c][Int(CPU_STATE_USER)] &- prevTicks[c][Int(CPU_STATE_USER)])
                let s = Double(cur[c][Int(CPU_STATE_SYSTEM)] &- prevTicks[c][Int(CPU_STATE_SYSTEM)])
                let nice = Double(cur[c][Int(CPU_STATE_NICE)] &- prevTicks[c][Int(CPU_STATE_NICE)])
                let idle = Double(cur[c][Int(CPU_STATE_IDLE)] &- prevTicks[c][Int(CPU_STATE_IDLE)])
                let busy = u + s + nice
                let total = busy + idle
                usage[c] = total > 0 ? (busy / total) * 100.0 : 0
            }
        }
        prevTicks = cur
        return usage
    }

    // Split per-core usage into perflevel clusters.
    // Verified empirically on this M5 Pro (see _findings_metrics.md): under a
    // 4-thread load the busy cores were indices 12..17 while macmon reported the
    // Super cluster (perflevel0, 6 cores) busy and Performance (perflevel1, 12)
    // idle. So host_processor_info lists the HIGHER perflevel first (Performance
    // x12 at 0..11) and perflevel0 (Super x6) last. Hence reversed = true.
    static let processorOrderReversed = true

    func clusterUsage(perCore: [Double]) -> [CoreTypeUsage] {
        var result: [CoreTypeUsage] = []
        let levels = sys.perfLevels
        // Build the order of clusters as they appear in the processor array.
        let ordered = CPUMemSampler.processorOrderReversed ? levels.reversed() : Array(levels)
        var idx = 0
        for lvl in ordered {
            let cnt = lvl.logicalCount
            guard idx + cnt <= perCore.count else { break }
            let slice = perCore[idx..<(idx + cnt)]
            let avg = slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
            result.append(CoreTypeUsage(name: lvl.name, logicalCount: cnt, usagePercent: round1(avg)))
            idx += cnt
        }
        // Reorder result back to perflevel index order for stable display.
        return result.sorted { a, b in
            let ai = levels.firstIndex { $0.name == a.name } ?? 0
            let bi = levels.firstIndex { $0.name == b.name } ?? 0
            return ai < bi
        }
    }

    func printMemoryDebug() {
        let total = sysctlUInt64("hw.memsize") ?? 0
        let pageSize = UInt64(vm_kernel_page_size)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, iptr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { print("  host_statistics64 failed"); return }
        let gb = 1024.0 * 1024.0 * 1024.0
        func g(_ pages: UInt64) -> String { String(format: "%.2f GiB", Double(pages) * Double(pageSize) / gb) }
        let active = UInt64(stats.active_count), inactive = UInt64(stats.inactive_count)
        let wired = UInt64(stats.wire_count), compressed = UInt64(stats.compressor_page_count)
        let free = UInt64(stats.free_count), speculative = UInt64(stats.speculative_count)
        let purgeable = UInt64(stats.purgeable_count), external = UInt64(stats.external_page_count)
        let intern = UInt64(stats.internal_page_count)
        print("  total=\(String(format: "%.2f GiB", Double(total)/gb))")
        print("  active=\(g(active)) inactive=\(g(inactive)) wired=\(g(wired)) compressed=\(g(compressed))")
        print("  free=\(g(free)) speculative=\(g(speculative)) purgeable=\(g(purgeable)) external=\(g(external)) internal=\(g(intern))")
        let f1 = active + wired + compressed
        // Apple Activity Monitor "Memory Used" = App(internal-purgeable) + wired + compressed
        let fApple = intern - purgeable + wired + compressed
        print("  used [active+wired+compressed] = \(g(f1))")
        print("  used [Apple: internal-purgeable+wired+compressed] = \(g(fApple))")
    }

    struct MemReading {
        var totalGB: Double
        var usedGB: Double
        var usedPercent: Double
        var headroomGB: Double
        var swapUsedGB: Double
        var swapTotalGB: Double
        var pressure: Bool
    }

    private var prevSwapUsed: UInt64 = 0

    func sampleMemory() -> MemReading {
        let total = sysctlUInt64("hw.memsize") ?? 0
        let pageSize = UInt64(vm_kernel_page_size)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, iptr, &count)
            }
        }
        var usedBytes: UInt64 = 0
        if kr == KERN_SUCCESS {
            // Apple "Memory Used" = App(internal - purgeable) + wired + compressed.
            // Verified to match macmon and Activity Monitor on this machine.
            let intern = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let wired = UInt64(stats.wire_count)
            let compressed = UInt64(stats.compressor_page_count)
            usedBytes = (intern &- purgeable &+ wired &+ compressed) * pageSize
        }

        // Swap from vm.swapusage
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }

        let gb = 1024.0 * 1024.0 * 1024.0
        let totalGB = Double(total) / gb
        let usedGB = Double(usedBytes) / gb
        let usedPct = total > 0 ? Double(usedBytes) / Double(total) * 100.0 : 0
        let headroom = totalGB - usedGB

        let swapGrowing = swapUsed > prevSwapUsed
        prevSwapUsed = swapUsed
        let pressure = swapGrowing || usedPct > 90.0

        return MemReading(totalGB: round2(totalGB), usedGB: round2(usedGB),
                          usedPercent: round1(usedPct), headroomGB: round2(headroom),
                          swapUsedGB: round2(Double(swapUsed) / gb),
                          swapTotalGB: round2(Double(swapTotal) / gb),
                          pressure: pressure)
    }
}
