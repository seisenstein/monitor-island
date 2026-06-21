import SwiftUI

// Ring gauge: trimmed circle with a centered mono number and a brand caption.
struct RingGauge: View {
    var value: Double      // 0..100
    var accent: Color
    var caption: String

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 100) / 100.0))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [accent.opacity(0.7), accent]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(value.rounded()))")
                        .font(.mono(16, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.mono(10, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                Text(caption)
                    .font(.brand(9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 62, height: 62)
    }
}

// Sparkline with smooth Catmull-Rom curves (rounded peaks and dips), a gradient
// stroke and a soft area fill.
struct Sparkline: View {
    var data: [Double]

    // Smooth curve through the points (Catmull-Rom -> cubic bezier, tension 1/6).
    private func curve(_ pts: [CGPoint], closedTo bottom: CGFloat?) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        if let bottom = bottom {
            path.move(to: CGPoint(x: pts[0].x, y: bottom))
            path.addLine(to: pts[0])
        } else {
            path.move(to: pts[0])
        }
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        if let bottom = bottom {
            path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: bottom))
            path.closeSubpath()
        }
        return path
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let maxV = max(data.max() ?? 1, 1)
            let count = data.count
            let stepX = count > 1 ? geo.size.width / CGFloat(count - 1) : 0
            // Inset the curve a touch vertically so rounded peaks are not clipped.
            let topPad: CGFloat = 3
            let pts: [CGPoint] = data.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX,
                        y: topPad + (h - topPad) * (1 - CGFloat(v / maxV)))
            }
            ZStack {
                if count > 1 {
                    curve(pts, closedTo: h)
                        .fill(LinearGradient(
                            colors: [Theme.sky.opacity(0.30), Theme.sky.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    curve(pts, closedTo: nil)
                        .stroke(
                            LinearGradient(colors: [Theme.sky.opacity(0.85), Theme.sky],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 30)
    }
}

// Temperature color: success green -> amber -> danger (input in Fahrenheit).
func tempColorF(_ f: Double) -> Color {
    if f < 131 { return Theme.success }   // ~55C
    if f < 167 { return Theme.amber }     // ~75C
    return Theme.danger
}

struct WorkloadDot: View {
    var on: Bool
    var color: Color
    var body: some View {
        Circle().fill(on ? color : Theme.textFaint.opacity(0.25))
            .frame(width: 7, height: 7)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var s: Smoother
    @State private var expandedWorkloads: Set<String> = []

    init(model: IslandModel, preExpand: Set<String> = []) {
        self.model = model
        self.s = model.smoother
        _expandedWorkloads = State(initialValue: preExpand)
    }

    var snap: Snapshot { model.snap }

    var hasModel: Bool { snap.localModelName != nil }
    var hasClaude: Bool { snap.workloads.contains { $0.label.contains("Claude") } }
    var hasCodex: Bool { snap.workloads.contains { $0.label.contains("Codex") } }

    var body: some View {
        Group {
            if model.expanded { expanded } else { compact }
        }
        .background(glassBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Theme.specular.opacity(0.30), Theme.specular.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
        )
        // The glass background, warm tint, and specular border are all applied BEFORE
        // this clip, so the rounded corners are truly transparent. No SwiftUI .shadow
        // here: that required transparent window padding (the invisible drag buffer).
        // The soft rounded drop shadow is now drawn by AppKit via win.hasShadow = true,
        // which follows this clipped alpha so the shadow is rounded with zero buffer.
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                model.expanded.toggle()
            }
        }
    }

    // Real Liquid Glass on macOS 26 (almost clear), with a very light cool tint so it
    // reads as light-mode frosted glass. Light material fallback below.
    @ViewBuilder
    var glassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(in: shape)
                .overlay(shape.fill(Theme.glassTint.opacity(Theme.glassTintOpacity)))
        } else {
            shape
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(shape.fill(Theme.glassTint.opacity(Theme.glassTintOpacity + 0.1)))
        }
    }

    // Compact pill.
    var compact: some View {
        HStack(spacing: 13) {
            metric("GPU", Int(s.gpu.rounded()), "%", Theme.teal)
            metric("MEM", Int(s.memUsedPercent.rounded()), "%", Theme.energy)
            if snap.cpuTempC != nil {
                metric("TEMP", Int(s.cpuTempF.rounded()), "\u{00b0}", tempColorF(s.cpuTempF))
            }
            HStack(spacing: 4) {
                WorkloadDot(on: hasModel, color: Theme.success)
                WorkloadDot(on: hasClaude, color: Theme.energy)
                WorkloadDot(on: hasCodex, color: Theme.teal)
            }
            snapButton
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .fixedSize()
    }

    // In-island control to center the island under the camera (notch). Tapping it
    // does not toggle expand/collapse because a Button consumes the tap.
    var snapButton: some View {
        Button { model.onSnapToggle?() } label: {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(model.snapped ? Theme.accent : Theme.textFaint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.snapped ? "Unsnap (drag freely)" : "Snap under camera")
    }

    func metric(_ label: String, _ value: Int, _ suffix: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("\(value)")
                    .font(.mono(15, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(suffix).font(.mono(11, weight: .bold))
            }
            .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.brand(8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(color.opacity(0.95))
        }
    }

    // Expanded card.
    var expanded: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 16) {
                RingGauge(value: s.gpu, accent: Theme.teal, caption: "GPU")
                RingGauge(value: s.cpuTotal, accent: Theme.success, caption: "CPU")
                RingGauge(value: s.memUsedPercent, accent: Theme.energy, caption: "MEM")
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { snapButton.offset(x: 6, y: -6) }

            // Core-type split (Super / Performance / ...).
            HStack(spacing: 18) {
                ForEach(snap.coreTypes, id: \.name) { ct in
                    let v = s.coreUsage[ct.name] ?? ct.usagePercent
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ct.name.uppercased())
                            .font(.brand(8, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 0) {
                            Text("\(Int(v.rounded()))")
                                .font(.mono(13, weight: .medium))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("%").font(.mono(10, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
                Spacer(minLength: 0)
            }

            row("Memory",
                String(format: "%.2f / %.2f GB", s.memUsedGB, snap.memTotalGB),
                trailing: String(format: "%.2f free", s.headroomGB),
                warn: snap.memoryPressure)
            if snap.swapUsedGB > 0 {
                row("Swap", String(format: "%.2f GB used", snap.swapUsedGB), warn: snap.memoryPressure)
            }
            if snap.cpuTempC != nil {
                row("Temp", String(format: "%.0f\u{00b0}F", s.cpuTempF))
            }

            row("Net",
                String(format: "\u{2193} %@", fmtRate(s.netDown)),
                trailing: String(format: "\u{2191} %@", fmtRate(s.netUp)))

            if !s.gpuHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPU ACTIVITY")
                        .font(.brand(8, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textFaint)
                    Sparkline(data: s.gpuHistory)
                }
            }

            if !snap.workloads.isEmpty || snap.localModelName != nil {
                Rectangle().fill(Theme.textFaint.opacity(0.18)).frame(height: 1)
                if let name = snap.localModelName {
                    workloadRow("Local model",
                                name + (snap.localModelMemoryMB != nil ? "  " + fmtMem(s.localModelMem) : ""),
                                Theme.success)
                }
                ForEach(snap.workloads, id: \.label) { w in
                    workloadGroup(w)
                }
            }
        }
        .padding(18)
        .frame(width: 292)
    }

    func row(_ label: String, _ value: String, trailing: String? = nil, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.brand(8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textFaint)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.mono(11, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(warn ? Theme.danger : Theme.textPrimary)
            Spacer(minLength: 0)
            if let trailing = trailing {
                Text(trailing)
                    .font(.mono(11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(warn ? Theme.danger : Theme.textSecondary)
            }
        }
    }

    func workloadColor(_ label: String) -> Color {
        if label.contains("Claude") { return Theme.energy }
        if label.contains("Codex") { return Theme.teal }
        if label.contains("llama") || label.contains("model") || label.contains("LM Studio") { return Theme.success }
        return Theme.textSecondary
    }

    // A workload group row with an optional drill-down into individual instances.
    @ViewBuilder
    func workloadGroup(_ w: WorkloadEntry) -> some View {
        let color = workloadColor(w.label)
        let canDrill = w.instances.count > 1
        let isOpen = expandedWorkloads.contains(w.label)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard canDrill else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if isOpen { expandedWorkloads.remove(w.label) }
                    else { expandedWorkloads.insert(w.label) }
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(w.count > 1 ? "\(w.label) x\(w.count)" : w.label)
                        .font(.brand(12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if canDrill {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    Spacer(minLength: 4)
                    Text(fmtMem(s.workloadMem[w.label] ?? w.memoryMB))
                        .font(.mono(11, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canDrill && isOpen {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(w.instances, id: \.pid) { inst in
                        HStack(spacing: 8) {
                            Circle().fill(color.opacity(0.55)).frame(width: 5, height: 5)
                            Text(inst.label)
                                .font(.mono(11.5, weight: .regular))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(fmtMem(s.instanceMem[inst.pid] ?? inst.memoryMB))
                                .font(.mono(11.5, weight: .medium))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.leading, 15)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    func workloadRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.brand(12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            Text(value)
                .font(.mono(11, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.textSecondary)
        }
    }

    func fmtMem(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024.0) }
        return String(format: "%.2f MB", mb)
    }

    func fmtRate(_ bps: Double) -> String {
        if bps > 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps > 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }
}
