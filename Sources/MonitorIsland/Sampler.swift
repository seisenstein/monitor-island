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

    init() {
        cpuMem = CPUMemSampler(sys: sys)
    }

    // Prime the delta-based samplers (call once before the first real tick).
    func prime() {
        _ = cpuMem.samplePerCore()
        _ = net.sample()
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

        return snap
    }
}
