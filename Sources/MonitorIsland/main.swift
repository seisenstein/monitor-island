import Foundation
import AppKit
import IOKit

let args = CommandLine.arguments

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func runDump() {
    let sampler = Sampler()
    sampler.prime()
    // Let delta-based counters (CPU, power, network) accumulate.
    usleep(400_000)
    let snap = sampler.tick(detectWorkloads: true)
    printJSON(snap)
}

func runSensors() {
    print("=== Monitor Island sensor discovery (M5 verification) ===")
    let sys = SysInfo()
    print("chip: \(sys.brand)  model: \(sys.model)  logicalcpu: \(sys.logicalCount)")
    print("perflevels (read live from hw.perflevelN.name):")
    for l in sys.perfLevels {
        print("  level\(l.index): name=\(l.name) logicalcpu=\(l.logicalCount)")
    }

    print("\n=== HID temperature sensors (IOHIDEventSystemClient, PrimaryUsagePage 0xff00 usage 5) ===")
    let temp = TemperatureSampler()
    let sensors = temp.sampleAll()
    if sensors.isEmpty {
        print("  (no temperature sensors returned)")
    } else {
        for s in sensors { print(String(format: "  %-22@  %6.1f C", s.name as NSString, s.celsius)) }
    }
    let map = ThermalMap.clusterTemps(sensors)
    print("\n--- cluster mapping derived from sensor names ---")
    print("  CPU cluster avg: \(map.cpu.map { String(format: "%.1f C", $0) } ?? "unavailable")")
    print("  GPU cluster avg: \(map.gpu.map { String(format: "%.1f C", $0) } ?? "unavailable")")
    print("  bestEffort (mapping not confidently verified): \(map.bestEffort)")

    print("\n=== Per-core CPU usage (processor index -> percent), to verify cluster ordering ===")
    let cm = CPUMemSampler(sys: sys)
    _ = cm.samplePerCore()
    usleep(400_000)
    let pc = cm.samplePerCore()
    for (i, u) in pc.enumerated() { print(String(format: "  cpu[%2d] = %5.1f%%", i, u)) }
    print("  (perflevel0=\(sys.perfLevels.first?.name ?? "?") count=\(sys.perfLevels.first?.logicalCount ?? 0))")

    print("\n=== GPU IOAccelerator PerformanceStatistics (raw keys) ===")
    let graw = GPUSampler().sample()
    for (k, v) in graw.raw.sorted(by: { $0.key < $1.key }) {
        print("  \(k) = \(v)")
    }

    print("\n=== Memory vm_statistics64 breakdown (candidate 'used' formulas) ===")
    CPUMemSampler(sys: sys).printMemoryDebug()

    print("\n=== IOReport channels (group / channel / unit / value: W for energy, residency for states) ===")
    let chans = PowerSampler.enumerateAllGroups()
    if chans.isEmpty {
        print("  (no IOReport channels returned)")
    } else {
        for c in chans {
            print(String(format: "  [%-26@] %-30@ unit=%-6@ val=%.4f",
                         c.group as NSString, c.name as NSString, c.unit as NSString, c.watts))
        }
    }

    print("\n=== Disk (IOBlockStorageDriver Statistics + derived wear) ===")
    var diskIter: io_iterator_t = 0
    if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &diskIter) == KERN_SUCCESS {
        defer { IOObjectRelease(diskIter) }
        var totalWrite: UInt64 = 0, totalRead: UInt64 = 0
        var idx = 0
        var svc = IOIteratorNext(diskIter)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(diskIter) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            totalWrite &+= w; totalRead &+= r
            let marker = w > 0 ? "  <-- non-zero writer (internal SSD)" : ""
            print(String(format: "  driver[%d]  write=%@ GB  read=%@ GB%@",
                         idx,
                         String(format: "%.1f", Double(w) / 1e9),
                         String(format: "%.1f", Double(r) / 1e9),
                         marker))
            idx += 1
        }
        print(String(format: "  SUMMED host total: write=%.1f GB  read=%.1f GB", Double(totalWrite) / 1e9, Double(totalRead) / 1e9))
    } else {
        print("  (no IOBlockStorageDriver services returned)")
    }
    let capBytes = SSDWear.capacityBytes()
    let tbw = SSDWear.ratedTBW(forCapacityBytes: capBytes)
    let dsample = DiskSampler().sample()
    print(String(format: "  capacity (IONVMeController capacity): %.0f GB", Double(capBytes) / 1e9))
    print(String(format: "  chosen TBW tier: %.0f TB", tbw))
    print(String(format: "  lifetime host written (this run's baseline): %.1f GB", Double(dsample.lifetimeWrittenBytes) / 1e9))
    print(String(format: "  derived wear estimate: ~%.3f%% est (best-effort)", SSDWear.damagePercent(lifetimeBytes: dsample.lifetimeWrittenBytes, ratedTBW: tbw)))
    print("  note: \(SSDWear.note(ratedTBW: tbw))")
}

if let i = args.firstIndex(of: "--shot-settings") {
    FontLoader.register()
    let path = (i + 1 < args.count) ? args[i + 1] : "island-settings.png"
    MainActor.assumeIsolated { Shot.render(to: path, settings: true) }
    exit(0)
} else if let i = args.firstIndex(of: "--shot-compact") {
    FontLoader.register()
    let path = (i + 1 < args.count) ? args[i + 1] : "island-compact.png"
    MainActor.assumeIsolated { Shot.render(to: path, compact: true) }
    exit(0)
} else if let i = args.firstIndex(of: "--shot") {
    FontLoader.register()
    let path = (i + 1 < args.count) ? args[i + 1] : "island.png"
    MainActor.assumeIsolated { Shot.render(to: path) }
    exit(0)
} else if args.contains("--dump") {
    FontLoader.register()
    runDump()
    exit(0)
} else if args.contains("--sensors") {
    runSensors()
    exit(0)
} else if args.contains("--help") {
    print("MonitorIsland [--dump | --sensors]")
    print("  --dump     sample once, print one JSON object with every metric")
    print("  --sensors  enumerate HID temperature sensors and IOReport channels")
    print("  (no flag)  launch the floating island GUI")
    exit(0)
}

// GUI mode.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
