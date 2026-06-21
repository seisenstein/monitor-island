import SwiftUI
import AppKit

// Render the live IslandView (expanded card) to a PNG. This captures the actual
// SwiftUI UI with live sampled values without needing Screen Recording permission.
enum Shot {
    @MainActor
    static func render(to path: String) {
        FontLoader.register()

        let sampler = Sampler()
        sampler.prime()
        usleep(400_000)

        let model = IslandModel()
        model.expanded = true

        // Build a short real GPU history for the sparkline and feed the smoother.
        var last = Snapshot()
        for _ in 0..<14 {
            last = sampler.tick(detectWorkloads: false)
            model.smoother.setTargets(from: last)
            usleep(120_000)
        }
        last = sampler.tick(detectWorkloads: true) // final tick incl. workloads
        model.snap = last
        model.smoother.setTargets(from: last)

        // Drive several smoother frames so the displayed values settle before capture.
        for _ in 0..<40 { model.smoother.step() }
        model.smoother.snapToTargets()

        let content = IslandView(model: model, preExpand: ["Claude Code"])
            .frame(width: 292)
            .padding(28)
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
