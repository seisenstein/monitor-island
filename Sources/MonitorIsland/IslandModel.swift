import Foundation
import SwiftUI
import Combine

// Observable model: runs the Sampler on a background queue and publishes snapshots.
final class IslandModel: ObservableObject {
    @Published var snap = Snapshot()
    @Published var expanded = false
    @Published var showOverlay = true
    @Published var gpuHistory: [Double] = []

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "monitorisland.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private(set) var interval: TimeInterval = 1.0

    func start() {
        queue.async { [weak self] in self?.sampler.prime() }
        restartTimer()
    }

    func setInterval(_ s: TimeInterval) {
        interval = s
        restartTimer()
    }

    private func restartTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.4, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let s = self.sampler.tick(detectWorkloads: true)
            DispatchQueue.main.async {
                self.snap = s
                self.gpuHistory.append(s.gpuPercent)
                if self.gpuHistory.count > 60 { self.gpuHistory.removeFirst(self.gpuHistory.count - 60) }
            }
        }
        t.resume()
        timer = t
    }
}
