import Foundation
import Darwin

// System-wide network throughput via getifaddrs, delta per tick.
final class NetworkSampler {
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var prevTime: Date = Date()
    private var primed = false

    // Returns (downBytesPerSec, upBytesPerSec).
    func sample() -> (down: Double, up: Double) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = cur.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self)
            rx &+= UInt64(stats.pointee.ifi_ibytes)
            tx &+= UInt64(stats.pointee.ifi_obytes)
        }

        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(prevTime))
        var down = 0.0, up = 0.0
        if primed {
            down = Double(rx &- prevRx) / elapsed
            up = Double(tx &- prevTx) / elapsed
        }
        prevRx = rx; prevTx = tx; prevTime = now; primed = true
        return (max(0, down), max(0, up))
    }
}
