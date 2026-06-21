import Foundation
import IOKit

// GPU utilization via IOKit IOAccelerator PerformanceStatistics (no private API).
final class GPUSampler {
    // Returns (busyPercent, inUseMemoryMB?, rawStats) for the first accelerator.
    func sample() -> (busy: Double?, inUseMB: Double?, raw: [String: Any]) {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return (nil, nil, [:])
        }
        defer { IOObjectRelease(iterator) }

        var busy: Double? = nil
        var inUseMB: Double? = nil
        var rawOut: [String: Any] = [:]

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            guard let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            rawOut = perf

            // GPU busy percent: key varies; prefer "Device Utilization %".
            let busyKeys = ["Device Utilization %", "GPU Activity(%)", "Device Utilization",
                            "GPU Core Utilization", "PMU Utilization"]
            for k in busyKeys {
                if let v = perf[k] as? NSNumber { busy = v.doubleValue; break }
            }
            // In-use GPU memory if present.
            let memKeys = ["In use system memory", "Alloc system memory", "inUseMemory"]
            for k in memKeys {
                if let v = perf[k] as? NSNumber { inUseMB = v.doubleValue / (1024.0 * 1024.0); break }
            }
            if busy != nil { break }
        }
        return (busy, inUseMB, rawOut)
    }
}
