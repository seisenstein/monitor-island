import SwiftUI
import AppKit

// Render the live IslandView (expanded card) to a PNG. This captures the actual
// SwiftUI UI with live sampled values without needing Screen Recording permission.
enum Shot {
    @MainActor
    static func render(to path: String, compact: Bool = false, settings: Bool = false) {
        FontLoader.register()

        let sampler = Sampler()
        sampler.prime()
        usleep(400_000)

        let model = IslandModel()
        model.expanded = !compact

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

        // Preview over the real mountain photo so the light glass can be judged on a
        // representative backdrop.
        let bg: AnyView = {
            if let img = NSImage(contentsOfFile: "/tmp/mountains.jpg") {
                return AnyView(Image(nsImage: img).resizable().scaledToFill())
            }
            return AnyView(Color(red: 0.10, green: 0.16, blue: 0.24))
        }()
        let content = ZStack {
            bg
            IslandView(model: model,
                       preExpand: settings ? [] : ["Claude Code"],
                       preShowSettings: settings).frame(width: compact ? nil : 292)
        }
        .frame(width: 380, height: compact ? 210 : (settings ? 560 : 900))
        .clipped()

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
