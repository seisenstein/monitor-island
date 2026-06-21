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
    private var tWorkloadMem: [String: Double] = [:]
    private var tInstanceMem: [Int32: Double] = [:]
    private var tLocalModelMem: Double = 0

    private var timer: DispatchSourceTimer?

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.frame() }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
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
        workloadMem = tWorkloadMem
        instanceMem = tInstanceMem
        localModelMem = tLocalModelMem
    }

    // Advance one frame manually (used by --shot to settle before capture).
    func step() { frame() }

    private func frame() {
        cpuTotal += (tCpuTotal - cpuTotal) * k
        for (name, target) in tCore {
            let cur = coreUsage[name] ?? target
            coreUsage[name] = cur + (target - cur) * k
        }
        gpu += (tGpu - gpu) * k
        memUsedGB += (tMemUsedGB - memUsedGB) * k
        memUsedPercent += (tMemUsedPercent - memUsedPercent) * k
        headroomGB += (tHeadroomGB - headroomGB) * k
        cpuTempF += (tCpuTempF - cpuTempF) * k
        netDown += (tNetDown - netDown) * k
        netUp += (tNetUp - netUp) * k
        for (key, target) in tWorkloadMem {
            let cur = workloadMem[key] ?? target
            workloadMem[key] = cur + (target - cur) * k
        }
        for (pid, target) in tInstanceMem {
            let cur = instanceMem[pid] ?? target
            instanceMem[pid] = cur + (target - cur) * k
        }
        localModelMem += (tLocalModelMem - localModelMem) * k
    }
}
