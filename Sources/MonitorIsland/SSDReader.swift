import SwiftUI

// The cohesive "SSD reader" — the internal-SSD write story as one unit: the live write rate, a
// write-activity sparkline, and the cumulative host bytes Monitor Island has OBSERVED since it
// started tracking (honestly scoped to a start date, never presented as drive lifetime). No wear %:
// true NAND wear is not readable sudoless on Apple Silicon, so any wear figure would be invented.
// It is the single disk surface and appears directly below the GPU/CPU/MEM/SWAP block in BOTH
// states: a tidy one-liner in the compact pill, and a grouped block (with the sparkline) in the
// expanded card.
struct SSDReader: View {
    var writeHistory: [Double]    // smoothed write-rate ring (Smoother.diskWriteHistory)
    var writeBytesPerSec: Double  // smoothed current write rate (Smoother.diskWrite)
    var totalWrittenGB: Double    // cumulative observed host writes (Snapshot.diskTotalWrittenGB)
    var since: String             // formatted tracking-start date, "" if unknown
    var capacityGB: Double        // internal SSD capacity for context; 0 hides it
    var note: String              // honest caveat (tooltip)
    var accent: Color
    var compact: Bool

    private var rateText: String {
        let bps = writeBytesPerSec
        if bps < 1 { return "idle" }
        if bps < 1_000_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.1f MB/s", bps / 1_000_000)
    }
    private var totalText: String {
        if totalWrittenGB >= 1000 { return String(format: "%.2f TB", totalWrittenGB / 1000) }
        if totalWrittenGB < 10    { return String(format: "%.1f GB", totalWrittenGB) }
        return String(format: "%.0f GB", totalWrittenGB)
    }
    private var sinceLine: String {
        var s = since.isEmpty ? "written" : "written since \(since)"
        if capacityGB > 0 {
            let cap = capacityGB >= 1000 ? String(format: "%.0f TB", capacityGB / 1000)
                                         : String(format: "%.0f GB", capacityGB)
            s += " · \(cap) drive"
        }
        return s
    }

    var body: some View {
        if compact { compactRow } else { fullBlock }
    }

    // Compact pill: one tidy row spanning the pill width, directly under GPU/CPU/MEM/SWAP.
    private var compactRow: some View {
        HStack(spacing: 8) {
            Text("SSD")
                .font(.brand(8, weight: .semibold)).tracking(0.6)
                .foregroundStyle(accent.opacity(0.95))
            Text(rateText)
                .font(.mono(10.5, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(accent)
            if !writeHistory.isEmpty {
                Sparkline(data: writeHistory, accent: accent, height: 14)
                    .frame(maxWidth: .infinity)
                    .opacity(0.9)
            } else {
                Spacer(minLength: 0)
            }
            Text(totalText)
                .font(.mono(10.5, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.textFaint)
        }
        .help(note)
    }

    // Expanded card: a grouped block — header line + write-activity sparkline + a faint "written
    // since <date>" line — read as one thing via a subtle inner fill, below the rings.
    private var fullBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SSD")
                    .font(.brand(8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 30, alignment: .leading)
                Text(rateText)
                    .font(.mono(12, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                Text(totalText)
                    .font(.mono(11, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textSecondary)
            }
            if !writeHistory.isEmpty {
                Sparkline(data: writeHistory, accent: accent, height: 26)
            }
            Text(sinceLine)
                .font(.mono(8.5, weight: .regular)).monospacedDigit()
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.snow.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
        .help(note)
    }
}
