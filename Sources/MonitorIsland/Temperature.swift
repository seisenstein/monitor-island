import Foundation
import CIOReport

// Thermal sensors via IOHIDEventSystemClient (private, sudoless).
// Matches Apple thermal sensors (PrimaryUsagePage 0xff00, PrimaryUsage 5).
final class TemperatureSampler {
    private let kIOHIDEventTypeTemperature: Int64 = 15
    private var tempField: Int32 { Int32(kIOHIDEventTypeTemperature << 16) } // IOHIDEventFieldBase

    private var client: CFTypeRef?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        guard let client = client else { return }
        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    }

    // Returns all temperature sensors with name + current value (degC).
    func sampleAll() -> [TempSensor] {
        guard let client = client else { return [] }
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return [] }
        var out: [TempSensor] = []
        let count = CFArrayGetCount(services)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = unsafeBitCast(raw, to: CFTypeRef.self)
            let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)
            let name = (nameRef as? String) ?? "unknown"
            guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(event, tempField)
            if value.isFinite && value > -50 && value < 200 {
                out.append(TempSensor(name: name, celsius: round1(value)))
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}

// Verified labeling for this chip is established in the transcript via --sensors.
// On Apple Silicon the CPU/GPU die sensors are commonly named with these prefixes.
// We compute cluster averages from the matching sensors and mark best-effort when
// confidence is low.
struct ThermalMap {
    // clusterTemps returns (cpu, gpu, bestEffort). On chips that expose named
    // cluster sensors we map them confidently; on this M5 Pro the HID layer
    // exposes only unlabeled "PMU tdieN" die sensors (verified via --sensors),
    // so a confident CPU-vs-GPU split is not possible and we report a die
    // average as a best-effort reading, cross-checked against macmon's SMC
    // cpu_temp_avg. We do NOT guess a fake CPU/GPU mapping (PRD requirement).
    static func clusterTemps(_ sensors: [TempSensor]) -> (cpu: Double?, gpu: Double?, bestEffort: Bool) {
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0,+)/Double(xs.count) }
        let lower = sensors.map { ($0, $0.name.lowercased()) }

        // Path 1: chips that expose named cluster sensors (older Apple Silicon / Stats tables).
        let namedCPU = lower.filter { (_, n) in
            n.contains("pacc") || n.contains("eacc") || n.contains("sacc") ||
            (n.contains("cpu") && !n.contains("gpu") && !n.contains("nand"))
        }.map { $0.0.celsius }
        let namedGPU = lower.filter { (_, n) in n.contains("gpu") }.map { $0.0.celsius }
        if !namedCPU.isEmpty && !namedGPU.isEmpty {
            return (avg(namedCPU).map(round1), avg(namedGPU).map(round1), false)
        }

        // Path 2: M5 exposes unlabeled "PMU tdieN" die sensors only -> best-effort die avg.
        let tdie = sensors.filter { $0.name.lowercased().contains("tdie") }.map { $0.celsius }
        if !tdie.isEmpty {
            return (avg(tdie).map(round1), nil, true)
        }
        // Last resort: any non-battery, non-NAND, non-calibration sensor.
        let other = lower.filter { (_, n) in !n.contains("battery") && !n.contains("nand") && !n.contains("tcal") }
            .map { $0.0.celsius }
        return (avg(other).map(round1), nil, true)
    }
}
