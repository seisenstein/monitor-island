import Foundation
import CoreText
import AppKit

// Registers bundled TTF fonts so both the GUI and dev --shot renders use them.
// Registers every .ttf found in the FIRST existing directory per the spec's
// font loading strategy.
enum FontLoader {
    private static var didRegister = false
    private(set) static var brandAvailable = false
    private(set) static var monoAvailable = false

    static func register() {
        if didRegister { return }
        didRegister = true

        guard let dir = firstExistingFontDir() else {
            evaluateAvailability()
            return
        }

        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension.lowercased() == "ttf" {
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                // Already-registered or harmless errors are ignored; we never crash.
                err?.release()
            }
        }
        evaluateAvailability()
    }

    private static func firstExistingFontDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 1. Bundle.main: Contents/Resources/fonts (release .app)
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("fonts"))
        }
        // 2. <cwd>/Sources/MonitorIsland/Resources/fonts (dev: run from repo root)
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Sources/MonitorIsland/Resources/fonts"))
        // 3. <executable dir>/../Resources/fonts
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("../Resources/fonts").standardizedFileURL)

        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue {
                return c
            }
        }
        return nil
    }

    private static func evaluateAvailability() {
        // Verify the faces actually resolve (graceful fallback if not).
        let available = Set(NSFontManager.shared.availableFonts)
        brandAvailable = available.contains("Fraunces-9ptBlack")
            || available.contains("Fraunces")
            || NSFont(name: "Fraunces", size: 12) != nil
        monoAvailable = NSFont(name: "JetBrainsMono-Regular", size: 12) != nil
    }
}
