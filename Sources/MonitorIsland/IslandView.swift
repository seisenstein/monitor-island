import SwiftUI

// Ring gauge: trimmed circle with a centered mono number and a brand caption.
// `fill` decouples the arc from the centered number: when nil the arc tracks
// `value` (the default for GPU/CPU/MEM). The SWAP ring passes a separate `fill`
// (the memory-pressure proxy) so the arc shows "how close to swapping" while the
// number stays exact swap-used %.
struct RingGauge: View {
    var value: Double      // 0..100 (centered number)
    var accent: Color
    var caption: String
    var fill: Double? = nil   // 0..100 arc; defaults to `value`
    var size: CGFloat = 62    // diameter; stroke + fonts scale with it so 4 rings can share a row

    var body: some View {
        let lw = size * 0.097                 // ~6 at 62
        let numFont = min(16, size * 0.28)    // big number stays readable as the ring shrinks
        let capFont = min(9, size * 0.155)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lw)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fill ?? value, 0), 100) / 100.0))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [accent.opacity(0.7), accent]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%02d", Int(value.rounded())))
                        .font(.mono(numFont, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.mono(numFont * 0.625, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                Text(caption)
                    .font(.brand(capFont, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
    }
}

// Sparkline with smooth Catmull-Rom curves (rounded peaks and dips), a gradient
// stroke and a soft area fill.
struct Sparkline: View {
    var data: [Double]
    var accent: Color = Theme.sky

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
                            colors: [accent.opacity(0.30), accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    curve(pts, closedTo: nil)
                        .stroke(
                            LinearGradient(colors: [accent.opacity(0.85), accent],
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
    @ObservedObject private var settings = AppSettings.shared
    @State private var expandedWorkloads: Set<String> = []
    @State private var showSettings = false
    @State private var islandSize: CGSize = .zero   // rendered island size for quadrant math
    @State private var tapGeneration = 0            // bumped on every tap; invalidates a pending deferred expand
    @State private var lastTapAt: Date = .distantPast

    // Disambiguation window for single-tap-expand vs double-tap-corner. SPEED vs RELIABILITY:
    // because the single-tap expand resizes+repositions the window (moving content out from
    // under a second tap), it MUST be deferred until the double-tap window passes — so this
    // deferral is also the dead time before an expand fires. A fixed 0.20s felt snappy but was
    // shorter than many users' actual double-click cadence: a slower double-tap let the deferred
    // expand fire first, so the second tap became a fresh first tap and NO snap ever happened —
    // for corners AND the new center snaps alike. Bind it to the user's real system double-click
    // interval (NSEvent.doubleClickInterval, what the OS itself uses) so every genuine double-tap
    // is caught; the cost is a slightly longer expand delay for users with a slow setting.
    private let tapDeferral: TimeInterval = NSEvent.doubleClickInterval
    // The pill<->card grow/shrink spring. Tighter `response` finishes the resize faster so
    // there is less time for any reactive system to fight it; high damping avoids overshoot.
    private let expandSpring: Animation = .spring(response: 0.28, dampingFraction: 0.82)

    init(model: IslandModel, preExpand: Set<String> = []) {
        self.model = model
        self.s = model.smoother
        _expandedWorkloads = State(initialValue: preExpand)
    }

    var snap: Snapshot { model.snap }

    // The single user-customizable accent (default: promptable teal). Everything that
    // was the blue accent now reads from here, so the color picker recolors it all.
    private var accent: Color { settings.accent }

    // SWAP gauge color: the dynamic accent at normal pressure, escalating to the fixed
    // amber/red warning colors as the kernel pressure level climbs.
    private func swapColor(_ level: Int) -> Color {
        level == 4 ? Theme.pressureCritical : (level == 2 ? Theme.pressureWarn : accent)
    }

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
                .overlay(shape.fill(Theme.glassTint.opacity(min(Theme.glassTintOpacity + 0.04, 1.0))))
        }
    }

    // Compact pill. A dropdown caret signals it expands; tap anywhere to expand.
    var compact: some View {
        HStack(spacing: 11) {
            metric("GPU", Int(s.gpu.rounded()), "%", accent)
            metric("MEM", Int(s.memUsedPercent.rounded()), "%", accent)
            metric("CPU", Int(s.cpuTotal.rounded()), "%", accent)
            // 4th metric: SWAP. Number is exact swap-used % (ground truth, 0 until the
            // machine actually pages to SSD); the label color escalates accent->amber->red
            // with the kernel pressure level, so the pill warns you well before that.
            metric("SWAP", Int(snap.swapUsedPercent.rounded()), "%",
                   swapColor(snap.pressureLevel))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .fixedSize()
    }

    func metric(_ label: String, _ value: Int, _ suffix: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                // Fixed-width number slot: a hidden "100" reserves the widest possible
                // value's width in the real font, and the visible number is trailing-
                // aligned within it. This keeps the pill from changing width as values
                // cross digit counts (0 -> 70 -> 100). monospacedDigit keeps the digits
                // from jiggling inside the slot.
                ZStack(alignment: .trailing) {
                    Text("100").hidden()
                    // Zero-padded to two digits (00, 01, ... 99, 100) so every metric
                    // reads as a stable two-digit percentage.
                    Text(String(format: "%02d", value))
                        .contentTransition(.numericText())
                }
                .font(.mono(15, weight: .bold))
                .monospacedDigit()
                Text(suffix).font(.mono(11, weight: .bold))
            }
            .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.brand(8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(color.opacity(0.95))
        }
    }

    // Expanded card. A gear in the corner swaps the content for the settings panel
    // (the accent color picker); the panel's own close control returns here.
    var expanded: some View {
        ZStack(alignment: .topTrailing) {
            if showSettings {
                SettingsPanel(settings: settings,
                              onClose: { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { showSettings = false } })
                    .padding(18)
                    .frame(width: 292)
            } else {
                expandedContent
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { showSettings = true }
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
            }
        }
    }

    // The normal expanded body: a single row of four rings (GPU / CPU / MEM / SWAP),
    // then the detail rows, sparkline and workloads. SWAP's arc is the pressure proxy
    // (how close to swapping) while its number is exact swap-used %.
    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                RingGauge(value: s.gpu, accent: accent, caption: "GPU", size: 54)
                RingGauge(value: s.cpuTotal, accent: accent, caption: "CPU", size: 54)
                RingGauge(value: s.memUsedPercent, accent: accent, caption: "MEM", size: 54)
                RingGauge(value: snap.swapUsedPercent,
                          accent: swapColor(snap.pressureLevel),
                          caption: "SWAP",
                          fill: s.swapPressure,
                          size: 54)
            }
            .frame(maxWidth: .infinity)

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
                    Sparkline(data: s.gpuHistory, accent: accent)
                }
            }

            if !snap.workloads.isEmpty || snap.localModelName != nil {
                Rectangle().fill(Theme.textFaint.opacity(0.18)).frame(height: 1)
                if let name = snap.localModelName {
                    workloadRow("Local model",
                                name + (snap.localModelMemoryMB != nil ? "  " + fmtMem(s.localModelMem) : ""),
                                accent)
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
                .foregroundStyle(warn ? accent : Theme.textPrimary)
            Spacer(minLength: 0)
            if let trailing = trailing {
                Text(trailing)
                    .font(.mono(11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(warn ? accent : Theme.textSecondary)
            }
        }
    }

    func workloadColor(_ label: String) -> Color {
        if label.contains("Claude") { return accent }
        if label.contains("Codex") { return accent }
        if label.contains("llama") || label.contains("model") || label.contains("LM Studio") { return accent }
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
