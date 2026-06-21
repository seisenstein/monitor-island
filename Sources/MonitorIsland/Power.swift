import Foundation
import CIOReport

struct PowerReading {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var ramWatts: Double?
    var packageWatts: Double?
    var rawChannels: [(group: String, name: String, watts: Double, unit: String)]
}

// CPU/GPU/ANE power via IOReport "Energy Model" group (private, sudoless),
// driven by the mi_ioreport_* C helpers. Diffs against the previous sample.
final class PowerSampler {
    private var ctx: UnsafeMutableRawPointer?
    private var prevTime: Date = Date()

    init() {
        ctx = mi_ioreport_subscribe("Energy Model" as CFString)
        prevTime = Date()
    }

    private func unitToJoules(_ unit: String) -> Double {
        let u = unit.lowercased()
        if u.contains("nj") { return 1e-9 }
        if u.contains("uj") || u.contains("\u{00b5}j") { return 1e-6 }
        if u.contains("mj") { return 1e-3 }
        if u == "j" || u.contains("joule") { return 1.0 }
        return 1e-9 // Apple energy counters are typically nJ
    }

    func sample() -> PowerReading {
        guard let ctx = ctx else {
            return PowerReading(cpuWatts: nil, gpuWatts: nil, aneWatts: nil, ramWatts: nil,
                                packageWatts: nil, rawChannels: [])
        }
        let elapsed = max(0.001, Date().timeIntervalSince(prevTime))
        var raw: [(group: String, name: String, watts: Double, unit: String)] = []
        mi_ioreport_sample(ctx) { g, n, u, v in
            let group = (g as String?) ?? ""
            let name = (n as String?) ?? ""
            let unit = (u as String?) ?? ""
            let joules = Double(v) * self.unitToJoules(unit)
            raw.append((group, name, joules / elapsed, unit))
        }
        prevTime = Date()

        // Match the aggregate Energy Model channels by exact name. The per-core
        // channels (MCPU*, PACC*, PCPU*, *DTL*, *SRAM) all contain "CPU" so a
        // substring match would multiply-count; the discovered aggregates are
        // "CPU Energy", "GPU"/"GPU Energy", "ANE", "DRAM".
        var cpu: Double? = nil, gpu: Double? = nil, gpuAlt: Double? = nil
        var ane: Double? = nil, ram: Double? = nil
        for c in raw {
            switch c.name.lowercased() {
            case "cpu energy": cpu = c.watts
            case "gpu energy": gpu = c.watts
            case "gpu":        gpuAlt = c.watts
            case "ane":        ane = c.watts
            case "dram":       ram = c.watts
            default: break
            }
        }
        if gpu == nil { gpu = gpuAlt }
        let pkg = [cpu, gpu, ane].compactMap { $0 }.reduce(0, +)
        return PowerReading(cpuWatts: cpu.map(round2), gpuWatts: gpu.map(round2),
                            aneWatts: ane.map(round2), ramWatts: ram.map(round2),
                            packageWatts: pkg > 0 ? round2(pkg) : nil, rawChannels: raw)
    }

    // Full channel enumeration across multiple groups for --sensors.
    static func enumerateAllGroups() -> [(group: String, name: String, unit: String, watts: Double)] {
        let groups = ["Energy Model", "CPU Stats", "GPU Stats",
                      "CPU Core Performance States", "GPU Performance States"]
        var out: [(String, String, String, Double)] = []
        for g in groups {
            guard let ctx = mi_ioreport_subscribe(g as CFString) else { continue }
            let t0 = Date()
            usleep(200_000)
            let elapsed = max(0.001, Date().timeIntervalSince(t0))
            mi_ioreport_sample(ctx) { grp, name, unit, v in
                let group = (grp as String?) ?? g
                let nm = (name as String?) ?? ""
                let u = (unit as String?) ?? ""
                // For Energy Model show watts; for state groups the value is residency ticks.
                let isEnergy = u.lowercased().contains("j")
                let val = isEnergy ? (Double(v) * Self.unitToJoulesStatic(u) / elapsed) : Double(v)
                out.append((group, nm, u, val))
            }
        }
        return out
    }

    private static func unitToJoulesStatic(_ unit: String) -> Double {
        let u = unit.lowercased()
        if u.contains("nj") { return 1e-9 }
        if u.contains("uj") || u.contains("\u{00b5}j") { return 1e-6 }
        if u.contains("mj") { return 1e-3 }
        return 1.0
    }
}
