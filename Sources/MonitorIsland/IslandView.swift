import SwiftUI

// Ring gauge: trimmed circle with a centered label.
struct RingGauge: View {
    var value: Double      // 0..100
    var label: String
    var accent: Color
    var caption: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 100) / 100.0))
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            VStack(spacing: 0) {
                Text(label).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(caption).font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 58, height: 58)
    }
}

struct Sparkline: View {
    var data: [Double]
    var accent: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard data.count > 1 else { return }
                let maxV = max(data.max() ?? 1, 1)
                let stepX = geo.size.width / CGFloat(data.count - 1)
                for (i, v) in data.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 22)
    }
}

func tempColor(_ c: Double) -> Color {
    // green to amber shift.
    if c < 55 { return .green }
    if c < 75 { return .yellow }
    return .orange
}

struct WorkloadDot: View {
    var on: Bool
    var color: Color
    var body: some View {
        Circle().fill(on ? color : Color.white.opacity(0.15))
            .frame(width: 7, height: 7)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel

    var snap: Snapshot { model.snap }

    var hasModel: Bool { snap.localModelName != nil }
    var hasClaude: Bool { snap.workloads.contains { $0.label == "Claude Code" } }
    var hasCodex: Bool { snap.workloads.contains { $0.label == "Codex" } }

    var body: some View {
        Group {
            if model.expanded { expanded } else { compact }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.expanded.toggle() }
        }
    }

    // Compact pill.
    var compact: some View {
        HStack(spacing: 12) {
            metric("GPU", String(format: "%.0f%%", snap.gpuPercent), .cyan)
            metric("MEM", String(format: "%.0f%%", snap.memUsedPercent), .purple)
            if let t = snap.cpuTempC {
                metric("TEMP", String(format: "%.0f\u{00b0}", t), tempColor(t))
            }
            HStack(spacing: 4) {
                WorkloadDot(on: hasModel, color: .green)
                WorkloadDot(on: hasClaude, color: .orange)
                WorkloadDot(on: hasCodex, color: .blue)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .fixedSize()
    }

    func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(label).font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(color.opacity(0.9))
        }
    }

    // Expanded card.
    var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                RingGauge(value: snap.gpuPercent, label: String(format: "%.0f%%", snap.gpuPercent),
                          accent: .cyan, caption: "GPU")
                RingGauge(value: snap.cpuTotalPercent, label: String(format: "%.0f%%", snap.cpuTotalPercent),
                          accent: .green, caption: "CPU")
                RingGauge(value: snap.memUsedPercent, label: String(format: "%.0f%%", snap.memUsedPercent),
                          accent: .purple, caption: "MEM")
            }

            // Core-type split (Super / Performance / ...).
            HStack(spacing: 10) {
                ForEach(snap.coreTypes, id: \.name) { ct in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ct.name).font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(String(format: "%.0f%%", ct.usagePercent))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }

            row("Memory", String(format: "%.1f / %.0f GB  -  %.1f GB free", snap.memUsedGB, snap.memTotalGB, snap.headroomGB),
                warn: snap.memoryPressure)
            if snap.swapUsedGB > 0 {
                row("Swap", String(format: "%.2f GB used", snap.swapUsedGB), warn: snap.memoryPressure)
            }
            if let ct = snap.cpuTempC, let gt = snap.gpuTempC {
                row("Temp", String(format: "CPU %.0f\u{00b0}  GPU %.0f\u{00b0}%@", ct, gt, snap.tempBestEffort ? " (best-effort)" : ""))
            } else if let ct = snap.cpuTempC {
                row("Temp", String(format: "die %.0f\u{00b0}%@", ct, snap.tempBestEffort ? " (best-effort)" : ""))
            }
            powerRow

            HStack {
                Text("NET").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                Text(String(format: "\u{2193} %@  \u{2191} %@", fmtRate(snap.netDownBytesPerSec), fmtRate(snap.netUpBytesPerSec)))
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            }

            if !model.gpuHistory.isEmpty {
                Sparkline(data: model.gpuHistory, accent: .cyan)
            }

            if !snap.workloads.isEmpty || snap.localModelName != nil {
                Divider().overlay(Color.white.opacity(0.1))
                if let name = snap.localModelName {
                    workloadRow("Local model", name + (snap.localModelMemoryMB.map { String(format: "  %.0f MB", $0) } ?? ""), .green)
                }
                ForEach(snap.workloads, id: \.label) { w in
                    workloadRow(w.count > 1 ? "\(w.label) x\(w.count)" : w.label,
                                String(format: "%.0f MB", w.memoryMB),
                                w.label.contains("Claude") ? .orange : (w.label.contains("Codex") ? .blue : .gray))
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    var powerRow: some View {
        let parts = [
            snap.cpuWatts.map { String(format: "CPU %.1fW", $0) },
            snap.gpuWatts.map { String(format: "GPU %.1fW", $0) },
            snap.aneWatts.map { String(format: "ANE %.2fW", $0) }
        ].compactMap { $0 }
        return Group {
            if !parts.isEmpty { row("Power", parts.joined(separator: "  ")) }
        }
    }

    func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label.uppercased()).font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5)).frame(width: 44, alignment: .leading)
            Text(value).font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(warn ? Color.orange : .white.opacity(0.9))
            Spacer(minLength: 0)
        }
    }

    func workloadRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
        }
    }

    func fmtRate(_ bps: Double) -> String {
        if bps > 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps > 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }
}
