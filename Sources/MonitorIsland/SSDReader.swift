import SwiftUI

// The cohesive "SSD reader" — the disk story as one unit: the best-effort wear estimate, the
// cumulative host-bytes-written ("life"), and a live write-activity sparkline. It is the single
// disk surface (Net and raw Disk-throughput rows were removed) and appears directly below the
// GPU/CPU/MEM/SWAP block in BOTH states: a tidy one-liner in the compact pill, and a grouped
// block (with the write sparkline) at the top of the expanded card.
struct SSDReader: View {
    var writeHistory: [Double]   // smoothed write-rate ring (Smoother.diskWriteHistory)
    var wearPercent: Double      // derived best-effort wear estimate (Snapshot.diskWearPercent)
    var lifetimeGB: Double       // cumulative host bytes written, "life" (Snapshot.diskLifetimeWrittenGB)
    var accent: Color
    var wearColor: Color         // accent → amber → red with wear (diskWearColor)
    var compact: Bool

    private var wearText: String { String(format: "~%.2f%% est", wearPercent) }
    private var lifeText: String {
        lifetimeGB >= 1000 ? String(format: "%.2f TB", lifetimeGB / 1000)
                           : String(format: "%.0f GB", lifetimeGB)
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
            Text(wearText)
                .font(.mono(10.5, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(wearColor)
            if !writeHistory.isEmpty {
                Sparkline(data: writeHistory, accent: accent, height: 14)
                    .frame(maxWidth: .infinity)
                    .opacity(0.9)
            } else {
                Spacer(minLength: 0)
            }
            Text(lifeText)
                .font(.mono(10.5, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.textFaint)
        }
    }

    // Expanded card: a grouped block — header line + the write-activity sparkline — read as one
    // thing via a subtle inner fill, positioned at the top (below the rings, above Memory/Temp).
    private var fullBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SSD")
                    .font(.brand(8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 30, alignment: .leading)
                Text(wearText)
                    .font(.mono(12, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(wearColor)
                Spacer(minLength: 0)
                Text(lifeText + " life")
                    .font(.mono(11, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textSecondary)
            }
            if !writeHistory.isEmpty {
                Sparkline(data: writeHistory, accent: accent, height: 26)
            }
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
    }
}
