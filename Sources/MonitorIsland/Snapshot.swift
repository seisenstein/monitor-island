import Foundation

// One core-type (perflevel) usage entry. Name is read live from
// hw.perflevelN.name (e.g. "Super", "Performance", "Efficiency").
struct CoreTypeUsage: Codable {
    var name: String
    var logicalCount: Int
    var usagePercent: Double   // 0..100 average across this cluster
}

struct TempSensor: Codable {
    var name: String
    var celsius: Double
}

// One running instance of a workload (e.g. a single Claude Code session).
struct WorkloadInstance: Codable {
    var pid: Int32
    var memoryMB: Double
    var label: String          // working-dir basename if known, else "pid N"
}

struct WorkloadEntry: Codable {
    var label: String          // "Claude Code", "Codex", "LM Studio", "llama-server", ...
    var count: Int
    var cpuPercent: Double      // aggregate, best-effort
    var memoryMB: Double        // aggregate resident
    var detail: String?         // e.g. model name, kind
    var instances: [WorkloadInstance] = []  // per-process breakdown for drill-down
}

// The single observable snapshot the UI reads and --dump serializes.
struct Snapshot: Codable {
    var timestamp: String = ""

    // CPU
    var cpuTotalPercent: Double = 0
    var coreTypes: [CoreTypeUsage] = []

    // Memory (GB unless noted)
    var memTotalGB: Double = 0
    var memUsedGB: Double = 0
    var memUsedPercent: Double = 0
    var headroomGB: Double = 0
    var swapUsedGB: Double = 0
    var swapTotalGB: Double = 0
    var swapUsedPercent: Double = 0    // exact swap used as % of unified memory (ground truth)
    var pressurePercent: Double = 0    // 0..100 "distance to swap" proxy (gauge fill, best-effort)
    var pressureLevel: Int = 1         // kernel: 1 normal, 2 warning, 4 critical (exact)
    var memoryPressure: Bool = false

    // GPU
    var gpuPercent: Double = 0
    var gpuInUseMemMB: Double? = nil

    // Temperature
    var temps: [TempSensor] = []
    var cpuTempC: Double? = nil
    var gpuTempC: Double? = nil
    var tempBestEffort: Bool = false   // true if cluster mapping not confidently verified

    // Power (watts)
    var cpuWatts: Double? = nil
    var gpuWatts: Double? = nil
    var aneWatts: Double? = nil
    var aneEstimateNote: String? = nil
    var packageWatts: Double? = nil
    var ramWatts: Double? = nil

    // Network (bytes/sec)
    var netDownBytesPerSec: Double = 0
    var netUpBytesPerSec: Double = 0

    // Workloads
    var workloads: [WorkloadEntry] = []
    var localModelName: String? = nil
    var localModelMemoryMB: Double? = nil

    var chip: String = ""
}

func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
