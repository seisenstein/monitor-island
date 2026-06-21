import Foundation

func sysctlString(_ name: String) -> String? {
    var size = 0
    if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
    var buf = [CChar](repeating: 0, count: size)
    if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return nil }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int = 0
    var size = MemoryLayout<Int>.size
    if sysctlbyname(name, &value, &size, nil, 0) != 0 { return nil }
    return value
}

func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname(name, &value, &size, nil, 0) != 0 { return nil }
    return value
}

struct PerfLevel {
    var index: Int
    var name: String
    var logicalCount: Int
}

// Detect chip + topology at runtime. Reads every perflevel (do not assume two).
struct SysInfo {
    let model: String
    let brand: String
    let logicalCount: Int
    let perfLevels: [PerfLevel]

    init() {
        model = sysctlString("hw.model") ?? "unknown"
        brand = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        logicalCount = sysctlInt("hw.logicalcpu") ?? (sysctlInt("hw.ncpu") ?? 1)

        var levels: [PerfLevel] = []
        let n = sysctlInt("hw.nperflevels") ?? 0
        let count = n > 0 ? n : 8
        for i in 0..<count {
            guard let lc = sysctlInt("hw.perflevel\(i).logicalcpu"), lc > 0 else {
                if n > 0 { continue } else { break }
            }
            let name = sysctlString("hw.perflevel\(i).name") ?? "Level\(i)"
            levels.append(PerfLevel(index: i, name: name, logicalCount: lc))
        }
        perfLevels = levels
    }

    var chipDisplay: String { brand }
}
