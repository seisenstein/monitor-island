import Foundation
import SwiftUI
import Combine

// Observable model: runs the Sampler on a background queue and publishes snapshots.
// Feeds the Smoother targets each tick; the view reads smoothed values for animation.
@MainActor
final class IslandModel: ObservableObject {
    @Published var snap = Snapshot()
    @Published var expanded = false
    @Published var showOverlay = true

    let smoother = Smoother()

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "monitorisland.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private(set) var interval: TimeInterval = 1.0

    func start() {
        queue.async { [weak self] in self?.sampler.prime() }
        smoother.start()
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
        let sampler = self.sampler
        t.setEventHandler { [weak self] in
            let s = sampler.tick(detectWorkloads: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.snap = s
                    self.smoother.setTargets(from: s)
                }
            }
        }
        t.resume()
        timer = t
    }
}
