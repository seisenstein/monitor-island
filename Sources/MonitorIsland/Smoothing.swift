import Foundation
import Combine
import SwiftUI

// A 60Hz display smoother. IslandModel feeds targets from each Snapshot tick;
// the view reads the smoothed values so numbers glide instead of snapping.
// Each frame: displayed += (target - displayed) * k, with k = 0.18.
@MainActor
final class Smoother: ObservableObject {
    // Smoothing factor per frame.
    private let k: Double = 0.18
    private let fps: Double = 60.0

    // Published smoothed values (what the view reads).
    @Published var cpuTotal: Double = 0
    @Published var coreUsage: [String: Double] = [:]   // core-type name -> smoothed %
    @Published var gpu: Double = 0
    @Published var memUsedGB: Double = 0
    @Published var memUsedPercent: Double = 0
    @Published var headroomGB: Double = 0
    @Published var cpuTempF: Double = 0
    @Published var netDown: Double = 0
    @Published var netUp: Double = 0
    @Published var swapPressure: Double = 0   // smoothed "distance to swap" proxy (SWAP ring fill)

    // Smoothed workload memory: aggregate per label, and per individual instance pid.
    @Published var workloadMem: [String: Double] = [:]
    @Published var instanceMem: [Int32: Double] = [:]
    @Published var localModelMem: Double = 0

    // GPU history ring for the sparkline (smoothed samples pushed at the tick rate).
    @Published var gpuHistory: [Double] = []
    private let historyCap = 60

    // Targets (latest sample).
    private var tCpuTotal: Double = 0
    private var tCore: [String: Double] = [:]
    private var tGpu: Double = 0
    private var tMemUsedGB: Double = 0
    private var tMemUsedPercent: Double = 0
    private var tHeadroomGB: Double = 0
    private var tCpuTempF: Double = 0
    private var tNetDown: Double = 0
    private var tNetUp: Double = 0
    private var tSwapPressure: Double = 0
    private var tWorkloadMem: [String: Double] = [:]
    private var tInstanceMem: [Int32: Double] = [:]
    private var tLocalModelMem: Double = 0

    private var timer: DispatchSourceTimer?
    // The lerp is asymptotic, so at idle the 60Hz frame() never goes quiet on its own and
    // re-renders the whole island (rings, sparkline, numericText) 60x/sec for the app's
    // lifetime — stealing frame budget from the expand spring. We SUSPEND the timer once all
    // channels have converged and RESUME it whenever a new sample moves a target. `running`
    // tracks the suspend/resume balance so we never over-suspend a DispatchSourceTimer (which
    // traps). `epsilon` is the convergence threshold for the %/GB-scale channels.
    private var running = false
    private let epsilon: Double = 0.01

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.frame() }
        }
        t.resume()
        timer = t
        running = true
    }

    func stop() {
        // A suspended timer cannot be cancelled cleanly; resume it first to balance.
        if let t = timer, !running { t.resume() }
        timer?.cancel()
        timer = nil
        running = false
    }

    // Resume ticking if currently quiesced (called when new targets arrive).
    private func resumeIfNeeded() {
        guard let t = timer, !running else { return }
        running = true
        t.resume()
    }

    // Convert temp C -> F here.
    static func cToF(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }

    // Feed targets from a Snapshot tick.
    func setTargets(from s: Snapshot) {
        tCpuTotal = s.cpuTotalPercent
        for ct in s.coreTypes { tCore[ct.name] = ct.usagePercent }
        tGpu = s.gpuPercent
        tMemUsedGB = s.memUsedGB
        tMemUsedPercent = s.memUsedPercent
        tHeadroomGB = s.headroomGB
        if let c = s.cpuTempC { tCpuTempF = Smoother.cToF(c) }
        tNetDown = s.netDownBytesPerSec
        tNetUp = s.netUpBytesPerSec
        tSwapPressure = s.pressurePercent

        // Workload memory targets (aggregate per label + per-instance per pid).
        var wm: [String: Double] = [:]
        var im: [Int32: Double] = [:]
        for w in s.workloads {
            wm[w.label] = w.memoryMB
            for inst in w.instances { im[inst.pid] = inst.memoryMB }
        }
        tWorkloadMem = wm
        tInstanceMem = im
        tLocalModelMem = s.localModelMemoryMB ?? 0
        // Drop displayed entries for processes that no longer exist.
        workloadMem = workloadMem.filter { wm[$0.key] != nil }
        instanceMem = instanceMem.filter { im[$0.key] != nil }

        // Push a history sample (the displayed gpu glides; the ring stores its target
        // sampled at tick rate so the sparkline reflects real cadence).
        gpuHistory.append(s.gpuPercent)
        if gpuHistory.count > historyCap {
            gpuHistory.removeFirst(gpuHistory.count - historyCap)
        }

        // New sample may have moved a target away from its displayed value; wake the glide.
        resumeIfNeeded()
    }

    // Snap all displayed values straight to targets (used to settle a render).
    func snapToTargets() {
        cpuTotal = tCpuTotal
        for (k, v) in tCore { coreUsage[k] = v }
        gpu = tGpu
        memUsedGB = tMemUsedGB
        memUsedPercent = tMemUsedPercent
        headroomGB = tHeadroomGB
        cpuTempF = tCpuTempF
        netDown = tNetDown
        netUp = tNetUp
        swapPressure = tSwapPressure
        workloadMem = tWorkloadMem
        instanceMem = tInstanceMem
        localModelMem = tLocalModelMem
    }

    // Advance one frame manually (used by --shot to settle before capture).
    func step() { frame() }

    private func frame() {
        // Track the largest remaining gap; when everything is within epsilon we snap to the
        // targets and suspend the timer so an idle island stops re-rendering at 60Hz. Net
        // channels (bytes/sec) get a coarser threshold since their magnitudes dwarf epsilon.
        var maxDelta = 0.0
        func gap(_ d: Double) { let a = abs(d); if a > maxDelta { maxDelta = a } }

        gap(tCpuTotal - cpuTotal);          cpuTotal += (tCpuTotal - cpuTotal) * k
        for (name, target) in tCore {
            let cur = coreUsage[name] ?? target
            gap(target - cur)
            coreUsage[name] = cur + (target - cur) * k
        }
        gap(tGpu - gpu);                    gpu += (tGpu - gpu) * k
        gap(tMemUsedGB - memUsedGB);        memUsedGB += (tMemUsedGB - memUsedGB) * k
        gap(tMemUsedPercent - memUsedPercent); memUsedPercent += (tMemUsedPercent - memUsedPercent) * k
        gap(tHeadroomGB - headroomGB);      headroomGB += (tHeadroomGB - headroomGB) * k
        gap(tCpuTempF - cpuTempF);          cpuTempF += (tCpuTempF - cpuTempF) * k
        // Net rates: scale the gap down to the %/GB epsilon basis (1 unit per ~1KB/s).
        gap((tNetDown - netDown) / 1000.0); netDown += (tNetDown - netDown) * k
        gap((tNetUp - netUp) / 1000.0);     netUp += (tNetUp - netUp) * k
        gap(tSwapPressure - swapPressure);  swapPressure += (tSwapPressure - swapPressure) * k
        for (key, target) in tWorkloadMem {
            let cur = workloadMem[key] ?? target
            gap((target - cur) / 1000.0)
            workloadMem[key] = cur + (target - cur) * k
        }
        for (pid, target) in tInstanceMem {
            let cur = instanceMem[pid] ?? target
            gap((target - cur) / 1000.0)
            instanceMem[pid] = cur + (target - cur) * k
        }
        gap((tLocalModelMem - localModelMem) / 1000.0)
        localModelMem += (tLocalModelMem - localModelMem) * k

        // Converged: pin everything to target (kill the asymptotic tail) and quiesce until
        // the next sample wakes us via resumeIfNeeded(). Skip during step() (no live timer).
        if maxDelta < epsilon, running, let t = timer {
            snapToTargets()
            running = false
            t.suspend()
        }
    }
}
