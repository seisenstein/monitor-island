import Foundation
import IOKit

// MARK: - DiskTracking

// When this install first began accumulating host-write bytes. Persisted once (UserDefaults) and
// shown next to the cumulative figure so "written" is always scoped to a real start date — never
// presented as the drive's true lifetime (which is not readable sudoless on Apple Silicon).
enum DiskTracking {
    private static let key = "MonitorIsland.diskTrackingSince"

    // ISO-8601 date tracking began; created (now) on first access if absent.
    static var sinceISO: String {
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let now = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set(now, forKey: key)
        return now
    }
}

// MARK: - DiskSampler

// Block-layer host write/read throughput + cumulative host bytes written, read sudolessly from
// IOBlockStorageDriver Statistics (no SMART, no sudo).
//
// IMPORTANT semantics: "Bytes (Write)" in IOBlockStorageDriver Statistics is "bytes written since
// the block storage driver was instantiated" — i.e. it RESETS on every reboot. It is NOT a drive
// lifetime odometer. So the only honest cumulative number we can build is "host bytes Monitor
// Island has OBSERVED since it first started tracking": we start the baseline at 0 (never anchor to
// the arbitrary since-boot value), accumulate forward deltas, and persist the running total via
// DamageLogger so it survives reboots (the boot-counter reset is absorbed by the persisted total).
// True NAND wear / drive lifetime is intentionally not estimated — see the project's honesty rule.
final class DiskSampler {
    private var prevWrite: UInt64 = 0
    private var prevRead:  UInt64 = 0
    private var prevTime:  Date   = Date()
    private var primed:    Bool   = false

    // Cumulative observed total = persisted baseline (prior runs) + this run's forward deltas.
    private var totalBaseline:  UInt64
    private var sessionWritten: UInt64 = 0

    init() {
        // Resume the cumulative observed total from prior runs. First-ever run -> 0 (NOT the live
        // since-boot counter), so the figure means exactly "bytes observed since tracking began".
        totalBaseline = DamageLogger.readPersistedTotalBytes()
    }

    // Returns (writeBps, readBps, sessionWrittenBytes, totalWrittenBytes).
    func sample() -> (writeBps: Double, readBps: Double, sessionWrittenBytes: UInt64, totalWrittenBytes: UInt64) {
        let cur     = readInternalTotals()
        let now     = Date()
        let elapsed = max(0.001, now.timeIntervalSince(prevTime))
        var wbps    = 0.0
        var rbps    = 0.0

        if primed {
            wbps = max(0, Double(cur.write &- prevWrite) / elapsed)
            rbps = max(0, Double(cur.read  &- prevRead)  / elapsed)
            // Counter resets on reboot (and can dip if a volume unmounts) -> only count forward deltas.
            sessionWritten &+= (cur.write >= prevWrite ? cur.write &- prevWrite : 0)
        }

        prevWrite = cur.write
        prevRead  = cur.read
        prevTime  = now
        primed    = true

        let total = totalBaseline &+ sessionWritten
        return (wbps, rbps, sessionWritten, total)
    }

    // Sum Bytes(Write)/(Read) over the IOBlockStorageDriver(s) that belong to the INTERNAL NVMe
    // controller(s) only — so mounted disk images (IOHDIXController), external USB/Thunderbolt
    // drives, and synthesized volumes are not folded into the internal-SSD write total. Falls back
    // to summing every IOBlockStorageDriver if no NVMe-scoped driver is found (defensive: never 0).
    private func readInternalTotals() -> (write: UInt64, read: UInt64) {
        var totalWrite: UInt64 = 0
        var totalRead:  UInt64 = 0
        var found = false

        var nvmeIter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeController"), &nvmeIter) == KERN_SUCCESS {
            defer { IOObjectRelease(nvmeIter) }
            var controller = IOIteratorNext(nvmeIter)
            while controller != 0 {
                defer { IOObjectRelease(controller); controller = IOIteratorNext(nvmeIter) }
                // Walk every descendant of this NVMe controller; the IOBlockStorageDriver sits a few
                // levels below it (IONVMeBlockStorageDevice -> IOBlockStorageDriver).
                var childIter: io_iterator_t = 0
                guard IORegistryEntryCreateIterator(controller, kIOServicePlane,
                                                    IOOptionBits(kIORegistryIterateRecursively),
                                                    &childIter) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(childIter) }
                var node = IOIteratorNext(childIter)
                while node != 0 {
                    defer { IOObjectRelease(node); node = IOIteratorNext(childIter) }
                    guard IOObjectConformsTo(node, "IOBlockStorageDriver") != 0 else { continue }
                    if let s = readStats(node) {
                        totalWrite &+= s.write
                        totalRead  &+= s.read
                        found = true
                    }
                }
            }
        }

        if found { return (totalWrite, totalRead) }
        return readAllBlockTotals()   // fallback: older/edge layouts
    }

    // Fallback used only if the NVMe-scoped walk finds nothing: sum ALL IOBlockStorageDrivers.
    private func readAllBlockTotals() -> (write: UInt64, read: UInt64) {
        var totalWrite: UInt64 = 0
        var totalRead:  UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let s = readStats(service) {
                totalWrite &+= s.write
                totalRead  &+= s.read
            }
        }
        return (totalWrite, totalRead)
    }

    // Read Bytes(Write)/(Read) from one IOBlockStorageDriver's Statistics dictionary.
    private func readStats(_ service: io_object_t) -> (write: UInt64, read: UInt64)? {
        var props: Unmanaged<CFMutableDictionary>? = nil
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let stats = dict["Statistics"] as? [String: Any] else { return nil }
        let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        let r = (stats["Bytes (Read)"]  as? NSNumber)?.uint64Value ?? 0
        return (w, r)
    }
}

// MARK: - SSDCapacity

// Internal SSD capacity in bytes, for context only (e.g. "1 TB drive"). Reads the first
// IONVMeController with a non-zero "capacity" value; returns 0 if unavailable (caller hides it).
enum SSDCapacity {
    static func bytes() -> UInt64 {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeController"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let cc = dict["Controller Characteristics"] as? [String: Any] else { continue }
            if let cap = (cc["capacity"] as? NSNumber)?.uint64Value, cap > 0 {
                return cap
            }
        }
        return 0
    }
}

// MARK: - DamageLogger

// Append-only JSONL log of observed disk-write totals. Written at most once per flushInterval
// (default 5 min) to avoid self-wear. Also used by DiskSampler.init to recover the cumulative
// observed total after a reboot (when the IOBlockStorageDriver counter resets to zero).
//
// Uses a fresh file ("disk_writes.jsonl") with the corrected "totalWrittenGB" semantics; the old
// "disk_damage.jsonl" (which stored an arbitrary since-boot-anchored "lifetime") is left untouched
// and ignored, so upgrades start a clean, honest count from 0.
final class DamageLogger {
    let flushInterval: TimeInterval = 300

    private var lastFlush: Date = .distantPast
    private var pending:   Record?

    private static var logURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("MonitorIsland", isDirectory: true)
            .appendingPathComponent("disk_writes.jsonl")
    }()

    private struct Record: Codable {
        let ts:                String
        let sessionWrittenGB:  Double
        let totalWrittenGB:    Double   // cumulative host bytes observed since tracking began (NOT drive lifetime)
        let claudeCodeMB:      Double?
        let codexMB:           Double?
    }

    init() {
        precondition(flushInterval >= 60, "write log flush interval must be >= 60s to avoid self-wear")
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
        totalWrittenGB: Double,
        claudeCodeMB: Double,
        codexMB: Double
    ) {
        let rec = Record(
            ts:                ISO8601DateFormatter().string(from: Date()),
            sessionWrittenGB:  sessionWrittenGB,
            totalWrittenGB:    totalWrittenGB,
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

    // Recover the cumulative observed total after a restart/reboot (when the IOKit counter has
    // reset). Reads the last ~4 KB of the log and returns the MAX totalWrittenGB across those
    // lines: the observed total is monotonic, so the max is the true latest and is immune to a
    // split partial first line or to stray total=0 lines that one-shot CLI modes (--dump/--shot)
    // append. Returns 0 if the file is absent (first-ever run -> baseline 0).
    static func readPersistedTotalBytes() -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return 0 }
        defer { try? fh.close() }

        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else { return 0 }
        let tail: UInt64 = min(4096, fileSize)
        try? fh.seek(toOffset: fileSize - tail)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return 0 }

        var maxGB = 0.0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let rec = try? JSONDecoder().decode(Record.self, from: lineData) else { continue }
            if rec.totalWrittenGB > maxGB { maxGB = rec.totalWrittenGB }
        }
        return UInt64(maxGB * 1e9)
    }

    // Append a single JSON line to the log file (single-line JSON — JSONL format, no pretty-print).
    private func append(_ rec: Record) {
        guard var line = try? JSONEncoder().encode(rec) else { return }
        line.append(0x0A) // newline byte

        if let fh = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: line)
        } else {
            try? line.write(to: Self.logURL, options: .atomic)
        }
    }
}
