import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let model = IslandModel()
    private let originKey = "MonitorIsland.windowOrigin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
        buildWindow()
        buildStatusItem()
        model.start()
    }

    private func buildWindow() {
        let hosting = NSHostingView(rootView: IslandView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = true

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        win.isMovableByWindowBackground = true
        win.contentView = hosting
        win.contentView?.wantsLayer = true

        // Restore position, with off-screen fallback.
        let origin = restoreOrigin()
        win.setFrameOrigin(origin)
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved(_:)),
                                               name: NSWindow.didMoveNotification, object: win)

        // Print the window flags for the phase-0 gate.
        let cb = win.collectionBehavior
        FileHandle.standardError.write("""
        [phase0] window flags:
          level == .floating : \(win.level == .floating)
          isOpaque : \(win.isOpaque)
          backgroundColor clear : \(win.backgroundColor == .clear)
          isMovableByWindowBackground : \(win.isMovableByWindowBackground)
          canJoinAllSpaces : \(cb.contains(.canJoinAllSpaces))
          stationary : \(cb.contains(.stationary))
          fullScreenAuxiliary : \(cb.contains(.fullScreenAuxiliary))
          ignoresCycle : \(cb.contains(.ignoresCycle))
          origin : \(origin.x), \(origin.y)\n
        """.data(using: .utf8)!)
    }

    private func defaultOrigin() -> NSPoint {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            return NSPoint(x: f.maxX - 240, y: f.maxY - 80)
        }
        return NSPoint(x: 100, y: 100)
    }

    private func restoreOrigin() -> NSPoint {
        guard let s = UserDefaults.standard.string(forKey: originKey) else { return defaultOrigin() }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return defaultOrigin() }
        let pt = NSPoint(x: parts[0], y: parts[1])
        // Off-screen check.
        let onScreen = NSScreen.screens.contains { $0.frame.contains(pt) }
        return onScreen ? pt : defaultOrigin()
    }

    @objc private func windowMoved(_ note: Notification) {
        let o = window.frame.origin
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: originKey)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MI"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide", action: #selector(toggleVisible), keyEquivalent: "s"))

        let intervalMenu = NSMenu()
        for (title, val) in [("1 second", 1.0), ("2 seconds", 2.0), ("5 seconds", 5.0)] {
            let mi = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.representedObject = val
            mi.state = (val == model.interval) ? .on : .off
            intervalMenu.addItem(mi)
        }
        let intervalItem = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        menu.addItem(intervalItem)
        menu.setSubmenu(intervalMenu, for: intervalItem)

        let overlayItem = NSMenuItem(title: "Local-model overlay", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        overlayItem.state = model.showOverlay ? .on : .off
        menu.addItem(overlayItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Monitor Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleVisible() {
        if window.isVisible { window.orderOut(nil) } else { window.makeKeyAndOrderFront(nil) }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        model.setInterval(v)
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
    }

    @objc private func toggleOverlay(_ sender: NSMenuItem) {
        model.showOverlay.toggle()
        sender.state = model.showOverlay ? .on : .off
    }
}
