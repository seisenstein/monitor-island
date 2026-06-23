import Foundation
import IOKit

// MARK: - DiskSampler

// Block-layer host write/read throughput via IOBlockStorageDriver Statistics (sudoless, no SMART).
// Counters reset on reboot; the persisted JSONL baseline in DamageLogger absorbs that reset so
// the lifetime figure survives reboots.
final class DiskSampler {
    private var prevWrite: UInt64 = 0
    private var prevRead:  UInt64 = 0
    private var prevTime:  Date   = Date()
    private var primed:    Bool   = false

    private var lifetimeBaseline:    UInt64
    private var sessionWritten:      UInt64 = 0
    private var hasPersistedBaseline: Bool

    init() {
        let persisted = DamageLogger.readLastLifetimeBytes()
        lifetimeBaseline     = persisted
        hasPersistedBaseline = (persisted > 0)
    }

    // Returns (writeBps, readBps, sessionWrittenBytes, lifetimeWrittenBytes).
    func sample() -> (writeBps: Double, readBps: Double, sessionWrittenBytes: UInt64, lifetimeWrittenBytes: UInt64) {
        let cur     = readHostTotals()
        let now     = Date()
        let elapsed = max(0.001, now.timeIntervalSince(prevTime))
        var wbps    = 0.0
        var rbps    = 0.0

        if primed {
            wbps = max(0, Double(cur.write &- prevWrite) / elapsed)
            rbps = max(0, Double(cur.read  &- prevRead)  / elapsed)
            // Counter resets on reboot → only accumulate forward deltas.
            sessionWritten &+= (cur.write >= prevWrite ? cur.write &- prevWrite : 0)
        } else if !hasPersistedBaseline {
            // FIRST-EVER RUN (no persisted JSONL history): anchor the cumulative baseline to the
            // live host write total so the lifetime figure starts at the real lower bound (~the live
            // ioreg counter, hundreds of GB) instead of 0. After this it is persisted via the JSONL
            // tail and survives reboots (the boot-counter reset is absorbed by the persisted baseline).
            lifetimeBaseline     = cur.write
            hasPersistedBaseline = true
        }

        prevWrite = cur.write
        prevRead  = cur.read
        prevTime  = now
        primed    = true

        let lifetime = lifetimeBaseline &+ sessionWritten
        return (wbps, rbps, sessionWritten, lifetime)
    }

    // Enumerate IOBlockStorageDriver services and sum their Bytes (Write) and Bytes (Read).
    private func readHostTotals() -> (write: UInt64, read: UInt64) {
        var totalWrite: UInt64 = 0
        var totalRead:  UInt64 = 0

        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            guard let stats = dict["Statistics"] as? [String: Any] else { continue }
            if let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value {
                totalWrite &+= w
            }
            if let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value {
                totalRead &+= r
            }
        }

        return (totalWrite, totalRead)
    }
}

// MARK: - SSDWear

// Derived SSD wear estimate from host-bytes-written vs rated TBW.
// Accurate capacity → rated TBW lookup; actual NAND wear is higher due to write amplification.
enum SSDWear {
    // Nearest-capacity tier table: (capacityBytes, ratedTBW).
    private static let tbwTiers: [(Double, Double)] = [
        (256e9,  300),
        (512e9,  600),
        (1e12,  1000),
        (2e12,  2000),
    ]

    static func ratedTBW(forCapacityBytes bytes: UInt64) -> Double {
        let cap = Double(bytes)
        guard !tbwTiers.isEmpty else { return 1000 }
        var best     = tbwTiers[0]
        var bestDiff = abs(cap - tbwTiers[0].0)
        for tier in tbwTiers.dropFirst() {
            let diff = abs(cap - tier.0)
            if diff < bestDiff { bestDiff = diff; best = tier }
        }
        return best.1
    }

    static func damagePercent(lifetimeBytes: UInt64, ratedTBW: Double) -> Double {
        guard ratedTBW > 0 else { return 0 }
        // TODO(NVMe SMART): if a verified sudoless NVMe SMART PERCENTAGE_USED becomes available, override this derived estimate with it and set Snapshot.diskWearBestEffort = false.
        return Double(lifetimeBytes) / (ratedTBW * 1e12) * 100.0
    }

    static func note(ratedTBW: Double) -> String {
        return "Apple does not publish TBW; estimate = host bytes / ~\(Int(ratedTBW.rounded())) TB rated; actual NAND wear is higher (write amplification)."
    }

    // Returns capacity in bytes from the first IONVMeController with a non-zero "capacity" value.
    static func capacityBytes() -> UInt64 {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IONVMeController")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return 1_000_000_000_000
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            guard let cc = dict["Controller Characteristics"] as? [String: Any] else { continue }
            if let cap = (cc["capacity"] as? NSNumber)?.uint64Value, cap > 0 {
                return cap
            }
        }

        return 1_000_000_000_000
    }
}

// MARK: - DamageLogger

// Append-only JSONL log of disk damage estimates. Written at most once per flushInterval (default
// 5 min) to avoid self-wear. Also used by DiskSampler.init to recover the lifetime baseline after
// a reboot (when the IOKit counter resets to zero).
final class DamageLogger {
    let flushInterval: TimeInterval = 300

    private var lastFlush: Date = .distantPast
    private var pending:   Record?

    private static var logURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("MonitorIsland", isDirectory: true)
            .appendingPathComponent("disk_damage.jsonl")
    }()

    private struct Record: Codable {
        let ts:                String
        let sessionWrittenGB:  Double
        let lifetimeWrittenGB: Double
        let damagePct:         Double
        let claudeCodeMB:      Double?
        let codexMB:           Double?
    }

    init() {
        precondition(flushInterval >= 60, "damage log flush interval must be >= 60s to avoid self-wear")
        try? FileManager.default.createDirectory(
            at: Self.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // Called every model tick. Cheap: always updates pending (no I/O). Writes to disk only when
    // flushInterval has elapsed since the last write (or immediately on the very first call,
    // because lastFlush is distantPast).
    func maybeAppend(
        sessionWrittenGB: Double,
        lifetimeWrittenGB: Double,
        damagePct: Double,
        claudeCodeMB: Double,
        codexMB: Double
    ) {
        let rec = Record(
            ts:                ISO8601DateFormatter().string(from: Date()),
            sessionWrittenGB:  sessionWrittenGB,
            lifetimeWrittenGB: lifetimeWrittenGB,
            damagePct:         damagePct,
            claudeCodeMB:      claudeCodeMB > 0 ? claudeCodeMB : nil,
            codexMB:           codexMB      > 0 ? codexMB      : nil
        )
        pending = rec

        let now = Date()
        guard now.timeIntervalSince(lastFlush) >= flushInterval else { return }
        lastFlush = now
        append(rec)
    }

    // Force-write the latest values (called at app quit, bypassing the interval).
    func flushNow() {
        guard let rec = pending else { return }
        lastFlush = Date()
        append(rec)
    }

    // Recover the last recorded lifetime bytes after a reboot (when the IOKit counter has reset).
    // Reads only the last ~2 KB of the log to find the most recent complete line.
    static func readLastLifetimeBytes() -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return 0 }
        defer { try? fh.close() }

        let fileSize: UInt64
        if #available(macOS 10.15.4, *) {
            guard let size = try? fh.seekToEnd(), size > 0 else { return 0 }
            fileSize = size
        } else {
            let size = fh.seekToEndOfFile()
            guard size > 0 else { return 0 }
            fileSize = size
        }

        let tail: UInt64 = min(2048, fileSize)
        let offset = fileSize - tail
        if #available(macOS 10.15.4, *) {
            try? fh.seek(toOffset: offset)
        } else {
            fh.seek(toFileOffset: offset)
        }

        let data: Data
        if #available(macOS 10.15.4, *) {
            guard let d = try? fh.readToEnd() else { return 0 }
            data = d
        } else {
            data = fh.readDataToEndOfFile()
        }

        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let lastLine = lines.last else { return 0 }
        guard let lineData = lastLine.data(using: .utf8),
              let rec = try? JSONDecoder().decode(Record.self, from: lineData) else { return 0 }
        return UInt64(max(0, rec.lifetimeWrittenGB) * 1e9)
    }

    // Append a single JSON line to the log file.
    // Creates the file if it does not exist; appends if it does.
    // NO .prettyPrinted — single-line JSON is required for the JSONL format.
    private func append(_ rec: Record) {
        guard var line = try? JSONEncoder().encode(rec) else { return }
        line.append(0x0A) // newline byte

        if let fh = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? fh.close() }
            if #available(macOS 10.15.4, *) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: line)
            } else {
                fh.seekToEndOfFile()
                fh.write(line)
            }
        } else {
            try? line.write(to: Self.logURL, options: .atomic)
        }
    }
}
