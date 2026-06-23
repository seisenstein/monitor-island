import SwiftUI
import AppKit

// The Promptable wordmark, loaded from the bundled transparent template and tinted with the
// current accent (it is an alpha-mask template, so `.renderingMode(.template)` + a foreground
// color recolors it perfectly to any accent). Asset: Resources/PromptableWordmark.png.
enum PromptableAsset {
    // Loaded once. Mirrors FontLoader's candidate-path strategy so it resolves in the release
    // .app bundle, in `swift run` from the repo root, and next to the executable.
    static let wordmark: NSImage? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("PromptableWordmark.png"))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Sources/MonitorIsland/Resources/PromptableWordmark.png"))
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent()
            .appendingPathComponent("../Resources/PromptableWordmark.png").standardizedFileURL)
        for c in candidates {
            if fm.fileExists(atPath: c.path), let img = NSImage(contentsOf: c) {
                img.isTemplate = true   // alpha mask → tintable via foregroundStyle
                return img
            }
        }
        return nil
    }()

    // The wordmark's intrinsic aspect ratio (width / height) for fixed-height layout.
    static let wordmarkAspect: CGFloat = {
        guard let s = wordmark?.size, s.height > 0 else { return 1200.0 / 204.0 }
        return s.width / s.height
    }()
}

// A fixed-height Promptable wordmark tinted with `accent`. Falls back to a serif text wordmark
// if the asset is missing, so the UI never shows an empty gap.
struct PromptableLogo: View {
    var accent: Color
    var height: CGFloat = 20

    var body: some View {
        Group {
            if let img = PromptableAsset.wordmark {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(accent)
            } else {
                Text("Promptable")
                    .font(.system(size: height * 0.82, weight: .semibold, design: .serif))
                    .foregroundStyle(accent)
            }
        }
        .frame(height: height)
        .frame(width: height * PromptableAsset.wordmarkAspect)
        .accessibilityLabel("Promptable")
    }
}
