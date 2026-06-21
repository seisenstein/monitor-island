import SwiftUI
import AppKit

// Render the live IslandView (expanded card) to a PNG. This captures the actual
// SwiftUI UI with live sampled values without needing Screen Recording permission.
enum Shot {
    @MainActor
    static func render(to path: String) {
        let sampler = Sampler()
        sampler.prime()
        usleep(400_000)
        // Build a short real GPU history for the sparkline.
        var history: [Double] = []
        var last = Snapshot()
        for _ in 0..<14 {
            last = sampler.tick(detectWorkloads: false)
            history.append(last.gpuPercent)
            usleep(120_000)
        }
        last = sampler.tick(detectWorkloads: true) // final tick incl. workloads

        let model = IslandModel()
        model.snap = last
        model.expanded = true
        model.gpuHistory = history

        let content = IslandView(model: model)
            .frame(width: 260)
            .padding(24)
            .background(Color(red: 0.05, green: 0.06, blue: 0.09))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("shot: render failed\n".data(using: .utf8)!)
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("shot written: \(path)  (\(png.count) bytes)")
        } catch {
            FileHandle.standardError.write("shot: write failed \(error)\n".data(using: .utf8)!)
        }
    }
}
