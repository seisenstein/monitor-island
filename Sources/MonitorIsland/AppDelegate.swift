import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let model = IslandModel()
    private let originKey = "MonitorIsland.windowOrigin"
    private let snappedKey = "MonitorIsland.snappedUnderCamera"
    private var snapMenuItem: NSMenuItem?
    private var snappedUnderCamera = false
    private var repositioning = false   // true while we move the window programmatically

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
        buildWindow()
        buildStatusItem()
        model.start()
    }

    private func buildWindow() {
        // Build a window that is borderless FROM CREATION. Using
        // NSWindow(contentViewController:) creates a titled window and then mutating
        // styleMask to .borderless can leave a frame/border artifact (the spurious
        // rectangular outline). Instead we construct a borderless window directly and
        // attach the hosting controller afterward. The root view has NO transparent
        // padding, so the window frame hugs the visible glass card exactly (the card
        // can be dragged flush to the screen edges with no invisible buffer). The drop
        // shadow is drawn by AppKit (win.hasShadow = true): on a borderless, transparent
        // window whose content is clipped to a rounded shape, the window shadow follows
        // the clipped content alpha and is therefore correctly rounded with no buffer.
        let host = NSHostingController(rootView: IslandView(model: model))
        let win = NSWindow(contentRect: .zero, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        win.isMovableByWindowBackground = true
        // Ensure the hosting view layer is fully transparent so no opaque rectangle shows.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView?.wantsLayer = true

        // Restore position, with off-screen fallback.
        let origin = restoreOrigin()
        win.setFrameOrigin(origin)
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved(_:)),
                                               name: NSWindow.didMoveNotification, object: win)
        // Keep it centered under the camera as it grows/shrinks while snapped.
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized(_:)),
                                               name: NSWindow.didResizeNotification, object: win)

        // Restore snapped-under-camera mode across launches.
        if UserDefaults.standard.bool(forKey: snappedKey) {
            snappedUnderCamera = true
            DispatchQueue.main.async { [weak self] in self?.positionUnderCamera() }
        }

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
        // Ignore moves we triggered ourselves (snap / recenter).
        if repositioning { return }
        // A manual drag breaks the snap so the user can place it freely.
        if snappedUnderCamera {
            snappedUnderCamera = false
            UserDefaults.standard.set(false, forKey: snappedKey)
            snapMenuItem?.state = .off
        }
        let o = window.frame.origin
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: originKey)
    }

    @objc private func windowResized(_ note: Notification) {
        if snappedUnderCamera { positionUnderCamera() }
    }

    // The built-in (notched) display if present, else the main screen.
    private func cameraScreen() -> NSScreen? {
        if #available(macOS 12.0, *),
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }

    // Center the window horizontally under the camera/notch, tucked just below the
    // menu bar. Re-applied on resize so it stays centered in both pill and card states.
    private func positionUnderCamera() {
        guard let win = window, let screen = cameraScreen() else { return }
        let size = win.frame.size
        let x = (screen.frame.midX - size.width / 2).rounded()
        let topGap: CGFloat = 3
        let y = (screen.visibleFrame.maxY - size.height - topGap).rounded()
        repositioning = true
        win.setFrameOrigin(NSPoint(x: x, y: y))
        UserDefaults.standard.set("\(x),\(y)", forKey: originKey)
        DispatchQueue.main.async { [weak self] in self?.repositioning = false }
    }

    @objc private func snapUnderCamera() {
        // Unobtrusive: collapse to the compact pill, then center under the camera.
        if model.expanded {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.expanded = false }
        }
        snappedUnderCamera = true
        UserDefaults.standard.set(true, forKey: snappedKey)
        snapMenuItem?.state = .on
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        DispatchQueue.main.async { [weak self] in self?.positionUnderCamera() }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MI"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide", action: #selector(toggleVisible), keyEquivalent: "s"))

        let snapItem = NSMenuItem(title: "Snap under camera", action: #selector(snapUnderCamera), keyEquivalent: "c")
        snapItem.state = snappedUnderCamera ? .on : .off
        menu.addItem(snapItem)
        snapMenuItem = snapItem

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
