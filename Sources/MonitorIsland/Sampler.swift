import Foundation

// Single sampler that holds previous state and produces one Snapshot per tick.
final class Sampler {
    let sys = SysInfo()
    private let cpuMem: CPUMemSampler
    private let gpu = GPUSampler()
    private let temp = TemperatureSampler()
    private let power = PowerSampler()
    private let net = NetworkSampler()
    private let workloads = WorkloadSampler()
    private let disk = DiskSampler()
    private let damageLog = DamageLogger()
    private lazy var diskCapacityBytes: UInt64 = SSDCapacity.bytes()   // read once, cached (0 if unavailable)

    init() {
        cpuMem = CPUMemSampler(sys: sys)
    }

    // Prime the delta-based samplers (call once before the first real tick).
    func prime() {
        _ = cpuMem.samplePerCore()
        _ = net.sample()
        _ = disk.sample()
    }

    func tick(detectWorkloads: Bool = true) -> Snapshot {
        var snap = Snapshot()
        let fmt = ISO8601DateFormatter()
        snap.timestamp = fmt.string(from: Date())
        snap.chip = sys.chipDisplay

        // CPU
        let perCore = cpuMem.samplePerCore()
        let clusters = cpuMem.clusterUsage(perCore: perCore)
        snap.coreTypes = clusters
        snap.cpuTotalPercent = perCore.isEmpty ? 0 : round1(perCore.reduce(0,+) / Double(perCore.count))

        // Memory
        let mem = cpuMem.sampleMemory()
        snap.memTotalGB = mem.totalGB
        snap.memUsedGB = mem.usedGB
        snap.memUsedPercent = mem.usedPercent
        snap.headroomGB = mem.headroomGB
        snap.swapUsedGB = mem.swapUsedGB
        snap.swapTotalGB = mem.swapTotalGB
        snap.swapUsedPercent = mem.swapUsedPercent
        snap.pressurePercent = mem.pressurePercent
        snap.pressureLevel = mem.pressureLevel
        snap.memoryPressure = mem.pressure

        // GPU
        let g = gpu.sample()
        snap.gpuPercent = g.busy.map(round1) ?? 0
        snap.gpuInUseMemMB = g.inUseMB.map(round1)

        // Temperature
        let sensors = temp.sampleAll()
        snap.temps = sensors
        let tmap = ThermalMap.clusterTemps(sensors)
        snap.cpuTempC = tmap.cpu
        snap.gpuTempC = tmap.gpu
        snap.tempBestEffort = tmap.bestEffort

        // Power
        let p = power.sample()
        snap.cpuWatts = p.cpuWatts
        snap.gpuWatts = p.gpuWatts
        snap.aneWatts = p.aneWatts
        snap.ramWatts = p.ramWatts
        snap.packageWatts = p.packageWatts
        if p.aneWatts != nil { snap.aneEstimateNote = "ANE occupancy is not exposed; figure is power only" }

        // Network
        let nrate = net.sample()
        snap.netDownBytesPerSec = round1(nrate.down)
        snap.netUpBytesPerSec = round1(nrate.up)

        // Workloads
        if detectWorkloads {
            let wl = workloads.sample()
            snap.workloads = wl.entries
            snap.localModelName = wl.localModelName
            snap.localModelMemoryMB = wl.localModelMemoryMB
        }

        // Disk (host writes to the internal NVMe block layer; cumulative observed total survives
        // reboot via Disk.swift's JSONL baseline). No wear % is derived: true NAND wear (NVMe SMART
        // PERCENTAGE_USED / Data Units Written) is not readable sudoless on Apple Silicon, so any
        // wear figure would be fabricated — see the project honesty rule.
        let d = disk.sample()
        snap.diskWriteBytesPerSec = round1(d.writeBps)
        snap.diskReadBytesPerSec  = round1(d.readBps)
        snap.diskSessionWrittenGB = round2(Double(d.sessionWrittenBytes) / 1e9)
        snap.diskTotalWrittenGB   = round2(Double(d.totalWrittenBytes)   / 1e9)
        snap.diskTrackingSince    = DiskTracking.sinceISO
        snap.diskCapacityGB       = diskCapacityBytes > 0 ? round1(Double(diskCapacityBytes) / 1e9) : 0
        snap.diskWriteNote        = "Host bytes written to the internal SSD that Monitor Island has observed since it started tracking — a lower bound, not the drive's total lifetime. True NAND wear (SMART) is not readable without admin on Apple Silicon."

        // Per-workload attribution: copy each label's session bytes into its Snapshot entry
        // (host writes, a lower bound; ri_diskio_byteswritten, same-user only).
        for i in snap.workloads.indices {
            let bytes = workloads.sessionWrittenBytes(forLabel: snap.workloads[i].label)
            snap.workloads[i].diskWrittenSessionMB = round2(Double(bytes) / (1024 * 1024))
        }

        // Low-frequency write log (append-only JSON-lines; DamageLogger self-throttles to <= once / 5 min)
        // — also the persistence that lets the cumulative observed total survive reboots.
        let claudeMB = round2(Double(workloads.sessionWrittenBytes(forLabel: "Claude Code")) / (1024 * 1024))
        let codexMB  = round2(Double(workloads.sessionWrittenBytes(forLabel: "Codex"))       / (1024 * 1024))
        damageLog.maybeAppend(sessionWrittenGB: snap.diskSessionWrittenGB,
                              totalWrittenGB: snap.diskTotalWrittenGB,
                              claudeCodeMB: claudeMB, codexMB: codexMB)

        return snap
    }

    // Flush the in-memory damage record to disk now (called on app quit; the 5-min throttle bounds loss otherwise).
    func flushDamageLog() { damageLog.flushNow() }
}
