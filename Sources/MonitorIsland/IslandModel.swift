import Foundation
import SwiftUI
import Combine

// Semantic corner in ISLAND space (SwiftUI top-left origin, y-down). The mapping
// to a screen corner (bottom-left origin, y-up) is done in AppDelegate, never here,
// so the SwiftUI view stays free of any AppKit coordinate logic.
enum IslandCorner {
    case topLeft, topRight, bottomLeft, bottomRight
}

// What the double-tap gesture wants. The island is split into a 3-column × 2-row grid:
// outer columns -> screen corners; middle column -> centered sticky snaps.
enum SnapRequest {
    case corner(IslandCorner)   // outer columns -> screen corner
    case topCenter              // top-middle -> under the camera/notch (sticky)
    case bottomCenter           // bottom-middle -> centered at screen bottom (sticky)
}

// Observable model: runs the Sampler on a background queue and publishes snapshots.
// Feeds the Smoother targets each tick; the view reads smoothed values for animation.
@MainActor
final class IslandModel: ObservableObject {
    @Published var snap = Snapshot()
    @Published var expanded = false
    @Published var showOverlay = true
    @Published var snapped = false                 // centered under the camera
    var onSnapToggle: (() -> Void)?                // wired by AppDelegate
    var onCornerSnap: ((SnapRequest) -> Void)?     // wired by AppDelegate
    // Bracket a pill<->card expand/collapse so AppDelegate can suppress its per-frame
    // reactive reposition for the duration of the resize spring and clamp ONCE on settle.
    var onTransitionBegin: (() -> Void)?           // wired by AppDelegate
    var onTransitionEnd: (() -> Void)?             // wired by AppDelegate

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
