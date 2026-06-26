import AppKit
import SwiftUI

// Which point of the window is pinned during resize / where a snap lands. Four corners PLUS
// the two horizontal-center edges, so a center snap is just another anchor — snap once, pin
// the point, grow symmetrically — the EXACT same machinery as the corners (no sticky mode).
enum Anchor {
    case topLeft, topRight, bottomLeft, bottomRight, topCenter, bottomCenter
    init(_ c: IslandCorner) {
        switch c {
        case .topLeft:     self = .topLeft
        case .topRight:    self = .topRight
        case .bottomLeft:  self = .bottomLeft
        case .bottomRight: self = .bottomRight
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let model = IslandModel()
    private let originKey = "MonitorIsland.windowOrigin"
    private let snappedKey = "MonitorIsland.snappedUnderCamera"
    private var snapMenuItem: NSMenuItem?
    private var showHideItem: NSMenuItem?
    private var snappedUnderCamera = false
    private var repositioning = false   // true while we move the window programmatically
    private var isTransitioning = false // true during a pill<->card expand/collapse spring
    private var anchor: Anchor = .topRight   // anchor pinned during resize (R2)
    private let edgeMargin: CGFloat = 8                   // R3 snap inset & R1 clamp margin
    private var anchorPointBeforeResize: NSPoint?   // the pinned corner in screen space, captured pre-resize
    private var lastProgrammaticMoveAt: Date = .distantPast  // when we last finished a programmatic move (see windowMoved)

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
        model.onSnapToggle = { [weak self] in self?.toggleSnap() }
        model.onCornerSnap = { [weak self] request in self?.snapToCorner(request) }
        model.onHide = { [weak self] in self?.hideIsland() }
        // Bracket the expand/collapse: hold off the per-frame reactive reposition while the
        // resize spring runs, then clamp the settled size on-screen exactly once.
        model.onTransitionBegin = { [weak self] in self?.isTransitioning = true }
        model.onTransitionEnd = { [weak self] in
            guard let self else { return }
            self.isTransitioning = false
            self.confineNow(animated: false)   // single settle-clamp keeps the card on-screen (R1)
        }
        buildWindow()
        buildStatusItem()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Force a final damage-log flush so the last few minutes of writes are persisted
        // (the in-memory accumulator otherwise only flushes every 5 min).
        model.flushDamageLog()
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
        // Re-confine when displays are connected/disconnected or the Dock/menu bar moves.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        // First layout pass: once the hosting view has sized the pill, seed the anchor
        // from the restored frame and clamp it on-screen. Skipped when a sticky center
        // mode will reposition it anyway (handled below).
        //
        // The hosting controller sizes the window asynchronously, so on the very next
        // runloop hop win.frame.size can still be ~.zero. Seeding the anchor from that
        // degenerate frame would store the bare origin as a topRight anchor point and the
        // first real resize would then yank the pill width/height off the restored origin.
        // Force layout first and, if the frame is still unsized, re-schedule until it is.
        let restoringSticky = UserDefaults.standard.bool(forKey: snappedKey)
        if !restoringSticky {
            seedAnchorWhenSized()
        }

        // Restore snapped-under-camera mode across launches.
        if UserDefaults.standard.bool(forKey: snappedKey) {
            setSnapped(true)
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

    // Seed the resize anchor from the FIRST correctly-sized pill frame, then clamp.
    // Forces a synchronous layout so the hosting controller resizes the window; if the
    // frame is still degenerate (size not yet applied) we re-schedule rather than seed
    // a zero-size anchor that would jump the pill on the first real resize.
    private func seedAnchorWhenSized() {
        guard let win = window else { return }
        win.contentView?.layoutSubtreeIfNeeded()
        guard win.frame.width > 1, win.frame.height > 1 else {
            DispatchQueue.main.async { [weak self] in self?.seedAnchorWhenSized() }
            return
        }
        let vf = activeScreen(for: win.frame).visibleFrame
        anchor = nearestCorner(of: win.frame, in: vf)
        anchorPointBeforeResize = anchorPoint(anchor, of: win.frame)
        confineNow(animated: false)
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
        // Reject an origin whose corner lands on no current screen (display disconnected,
        // arrangement changed). visibleFrame clamp of the full frame happens after the
        // window sizes, in confineNow() called from buildWindow's deferred pass.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(pt) }
        return onScreen ? pt : defaultOrigin()
    }

    @objc private func windowMoved(_ note: Notification) {
        guard let win = window else { return }
        let dt = Date().timeIntervalSince(lastProgrammaticMoveAt)
        // Ignore moves we triggered ourselves (snap / recenter / clamp).
        if repositioning {
            return
        }
        // Ignore the trailing didMove that NSWindow's animator coalesces and delivers AFTER
        // the animation completion handler has already cleared `repositioning`. Without this,
        // that stray programmatic move would release the just-set sticky center mode and
        // recompute the anchor from the (still mid-flight) frame. A real user drag always
        // begins >100ms after our programmatic move settles, so this never swallows a drag.
        if dt < 0.10 {
            return
        }
        // A manual drag breaks snap-under-camera so the user can place it freely.
        if snappedUnderCamera {
            setSnapped(false)
        }
        // R1: clamp a user drag so no edge leaves the active screen's visibleFrame.
        // Use margin 0 here (let the user push flush to the edge); R3 snap uses edgeMargin.
        let screen = activeScreen(for: win.frame)
        let safe = clampedOrigin(win.frame.origin, size: win.frame.size,
                                 in: screen.visibleFrame, margin: 0)
        if safe != win.frame.origin {
            applyOrigin(safe, animated: false)            // re-enters guarded; persists inside
        } else {
            UserDefaults.standard.set("\(safe.x),\(safe.y)", forKey: originKey)
        }
        // R2: a settled drag re-chooses the anchor so the NEXT expand grows inward.
        let frameNow = window.frame
        anchor = nearestCorner(of: frameNow, in: screen.visibleFrame)
        anchorPointBeforeResize = anchorPoint(anchor, of: frameNow)
    }

    @objc private func windowResized(_ note: Notification) {
        guard let win = window else { return }
        // A resize that lands mid-reposition (e.g. expand during a 0.28s corner-snap
        // animation, or during the brief async guard-clear of a non-animated move) would
        // otherwise be dropped, leaving the final card size unclamped and possibly
        // off-screen. Instead of early-returning, coalesce a confine onto the next runloop
        // so it runs AFTER the guard clears and the resize settles (R1).
        if repositioning {
            scheduleConfineCatchUp()
            return
        }
        if snappedUnderCamera {
            positionUnderCamera(); return
        }
        let size = win.frame.size
        // Pin the stored anchor point if we have one (set on drag-end / corner-snap);
        // otherwise fall back to the live nearest corner.
        let corner = anchor
        let p = anchorPointBeforeResize ?? anchorPoint(corner, of: win.frame)
        // During a pill<->card spring, NSHostingController drives the window size every
        // frame from a FIXED bottom-left origin, so an unanchored card grows OUTWARD (up and
        // to the right) — past the menu bar / right edge for a top/right-anchored island —
        // and only the onTransitionEnd settle would yank it back, a visible off-screen
        // fly-out. So we must still re-pin the anchored corner every frame so it grows
        // INWARD (R2). The previous jitter came from the extra clamp churn fighting the
        // spring; during the transition we place the anchored origin WITHOUT the per-frame
        // clamp (the single onTransitionEnd confine clamps the settled size on-screen, R1).
        if isTransitioning {
            applyOrigin(origin(placing: corner, at: p, size: size), animated: false)
            return
        }
        // Clamp into the screen that OWNS the anchor point, not the post-resize frame's
        // screen: a card growing past a shared display edge overlaps the neighbour more
        // and activeScreen(for: frame) would pick the wrong display (R2).
        let screen = screen(containing: p)
        let placed = origin(placing: corner, at: p, size: size)
        let safe = clampedOrigin(placed, size: size, in: screen.visibleFrame, margin: edgeMargin)
        applyOrigin(safe, animated: false)
    }

    // Coalesce a single confine pass onto the next runloop. Used when a resize arrives
    // while `repositioning` is set; the flag is cleared on a later hop / animation
    // completion, so by the time this fires the move has settled and confineNow() can
    // pull the final size on-screen. Guarded so repeated resizes coalesce to one pass.
    private var confineCatchUpScheduled = false
    private func scheduleConfineCatchUp() {
        guard !confineCatchUpScheduled else { return }
        confineCatchUpScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.confineCatchUpScheduled = false
            // If still repositioning, try again next hop rather than skipping the clamp.
            if self.repositioning { self.scheduleConfineCatchUp(); return }
            guard let win = self.window, !self.snappedUnderCamera else { return }
            // Only act if the current frame is not already safely inside its screen.
            let p = self.anchorPointBeforeResize ?? self.anchorPoint(self.anchor, of: win.frame)
            let vf = self.screen(containing: p).visibleFrame
            let placed = self.origin(placing: self.anchor, at: p, size: win.frame.size)
            let safe = self.clampedOrigin(placed, size: win.frame.size, in: vf, margin: self.edgeMargin)
            if safe != win.frame.origin { self.applyOrigin(safe, animated: false) }
        }
    }

    @objc private func screensChanged(_ note: Notification) {
        if snappedUnderCamera { positionUnderCamera(); return }
        // The screen that held the window may have vanished; activeScreen() falls back to
        // the nearest by center, and confineNow() pulls a now-off-screen island back on.
        confineNow(animated: true)
    }

    // The built-in (notched) display if present, else the main screen.
    private func cameraScreen() -> NSScreen? {
        if #available(macOS 12.0, *),
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }

    // MARK: - Confinement geometry (all in macOS bottom-left / y-up screen coordinates)

    @inline(__always)
    private func clampValue(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        // Degenerate (window bigger than the usable box): hi < lo -> pin the LOW edge
        // (left / bottom), keeping that edge on-screen rather than producing NaN/oscillation.
        lo <= hi ? min(max(v, lo), hi) : lo
    }

    // Clamp a bottom-left origin so the whole frame fits inside `vf`, inset by `margin`.
    private func clampedOrigin(_ origin: NSPoint, size: NSSize,
                               in vf: NSRect, margin m: CGFloat = 0) -> NSPoint {
        let loX = vf.minX + m, hiX = vf.maxX - m - size.width
        let loY = vf.minY + m, hiY = vf.maxY - m - size.height
        return NSPoint(x: clampValue(origin.x, loX, hiX).rounded(),
                       y: clampValue(origin.y, loY, hiY).rounded())
    }

    // Origin that puts anchor `a` of a window of `size` at point `p` (screen space).
    private func origin(placing a: Anchor, at p: NSPoint, size: NSSize) -> NSPoint {
        switch a {
        case .bottomLeft:   return NSPoint(x: p.x,                y: p.y)
        case .bottomRight:  return NSPoint(x: p.x - size.width,   y: p.y)
        case .topLeft:      return NSPoint(x: p.x,                y: p.y - size.height)
        case .topRight:     return NSPoint(x: p.x - size.width,   y: p.y - size.height)
        case .bottomCenter: return NSPoint(x: p.x - size.width/2, y: p.y)
        case .topCenter:    return NSPoint(x: p.x - size.width/2, y: p.y - size.height)
        }
    }

    // Screen-space coordinate of anchor `a` of frame `f`.
    private func anchorPoint(_ a: Anchor, of f: NSRect) -> NSPoint {
        switch a {
        case .bottomLeft:   return NSPoint(x: f.minX, y: f.minY)
        case .bottomRight:  return NSPoint(x: f.maxX, y: f.minY)
        case .topLeft:      return NSPoint(x: f.minX, y: f.maxY)
        case .topRight:     return NSPoint(x: f.maxX, y: f.maxY)
        case .bottomCenter: return NSPoint(x: f.midX, y: f.minY)
        case .topCenter:    return NSPoint(x: f.midX, y: f.maxY)
        }
    }

    // Snap target origin: put anchor `a` of the window at the matching point of `vf`, inset by `m`.
    private func snapOrigin(to a: Anchor, size: NSSize, in vf: NSRect, margin m: CGFloat) -> NSPoint {
        switch a {
        case .bottomLeft:   return NSPoint(x: vf.minX + m,                 y: vf.minY + m)
        case .bottomRight:  return NSPoint(x: vf.maxX - m - size.width,    y: vf.minY + m)
        case .topLeft:      return NSPoint(x: vf.minX + m,                 y: vf.maxY - m - size.height)
        case .topRight:     return NSPoint(x: vf.maxX - m - size.width,    y: vf.maxY - m - size.height)
        case .bottomCenter: return NSPoint(x: (vf.midX - size.width/2).rounded(), y: vf.minY + m)
        case .topCenter:    return NSPoint(x: (vf.midX - size.width/2).rounded(), y: vf.maxY - m - size.height)
        }
    }

    // Horizontal-half / vertical-half test (NOT Euclidean) so an island near the top
    // edge but centered horizontally still pins the TOP and grows DOWN.
    private func nearestCorner(of f: NSRect, in vf: NSRect) -> Anchor {
        let left   = f.midX < vf.midX
        let bottom = f.midY < vf.midY
        switch (left, bottom) {
        case (true,  true):  return .bottomLeft
        case (false, true):  return .bottomRight
        case (true,  false): return .topLeft
        case (false, false): return .topRight
        }
    }

    // The screen the window MOSTLY overlaps (area-max), with a center-distance fallback
    // when the window is fully off every screen. Never NSScreen.main (R4).
    private func activeScreen(for frame: NSRect) -> NSScreen {
        var best = NSScreen.main ?? NSScreen.screens.first!
        var bestArea: CGFloat = -1
        for s in NSScreen.screens {
            let inter = s.frame.intersection(frame)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea { bestArea = area; best = s }
        }
        if bestArea <= 0 {
            best = NSScreen.screens.min(by: {
                hypot($0.frame.midX - frame.midX, $0.frame.midY - frame.midY) <
                hypot($1.frame.midX - frame.midX, $1.frame.midY - frame.midY)
            }) ?? best
        }
        return best
    }

    // The screen that OWNS a point (contains it in its full frame), with a
    // center-distance fallback. Used to clamp into the anchor's screen rather than the
    // post-resize frame's screen, so a card growing across a shared display edge does
    // not get yanked onto the neighbouring display (R2).
    private func screen(containing p: NSPoint) -> NSScreen {
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) { return s }
        return activeScreen(for: NSRect(origin: p, size: .zero))
    }

    // The ONE place (besides positionUnderCamera) that programmatically moves the window.
    // Wraps the move in the `repositioning` envelope so our own didMove/didResize are
    // ignored, persists the new origin in the existing "x,y" format, and no-ops if the
    // origin is already correct (value-based loop breaker).
    private func applyOrigin(_ origin: NSPoint, animated: Bool) {
        guard let win = window else { return }
        let target = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        guard target != win.frame.origin else { return }   // no-op short-circuit (kills resize loop)
        repositioning = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrameOrigin(target)
            }, completionHandler: { [weak self] in
                // NSAnimationContext fires its completion on the main thread; assert the
                // main-actor isolation so we can clear the guard synchronously here (NOT via
                // a runloop hop) and keep `repositioning` true across all animator() frames.
                MainActor.assumeIsolated { self?.persistAndClearGuard(target) }
            })
        } else {
            win.setFrameOrigin(target)
            UserDefaults.standard.set("\(target.x),\(target.y)", forKey: originKey)
            // Clear the guard SYNCHRONOUSLY. setFrameOrigin does not post didResize, so
            // there is no re-entrancy to guard against here; the value-based no-op
            // short-circuit above already breaks any move loop. A deferred (async) clear
            // left a window in which a subsequent didResize tick — including the FINAL one
            // at the end card size near an edge — would be swallowed and never clamped.
            repositioning = false
            // NOTE: do NOT stamp lastProgrammaticMoveAt here. A non-animated setFrameOrigin
            // posts its didMove SYNCHRONOUSLY while `repositioning` is still true above, so it
            // is already guarded — there is no trailing move to suppress. Stamping here would
            // make the in-drag edge clamp (windowMoved -> applyOrigin(animated:false)) swallow
            // the next drag frame within 100ms and weaken the on-screen clamp during edge drags.
        }
    }

    private func persistAndClearGuard(_ origin: NSPoint) {
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: originKey)
        repositioning = false
        // Mark the instant so the animator's trailing didMove (delivered AFTER this
        // completion handler) is ignored by windowMoved rather than releasing sticky mode.
        lastProgrammaticMoveAt = Date()
        // Catch-up confine: a content-size change (expand/collapse) that landed inside the
        // animated move's window was dropped by windowResized's repositioning guard, with
        // no event afterwards to re-confine it. Now the guard is clear, run one confine if
        // the current frame is not already inside its screen (R1). No-ops when nothing
        // changed thanks to applyOrigin's value-based short-circuit.
        guard let win = window, !snappedUnderCamera else { return }
        let p = anchorPointBeforeResize ?? anchorPoint(anchor, of: win.frame)
        let vf = screen(containing: p).visibleFrame
        let placed = self.origin(placing: anchor, at: p, size: win.frame.size)
        let safe = clampedOrigin(placed, size: win.frame.size, in: vf, margin: edgeMargin)
        if safe != win.frame.origin { applyOrigin(safe, animated: false) }
    }

    // Clamp the current frame onto the active screen using the current anchor.
    private func confineNow(animated: Bool) {
        guard let win = window, !snappedUnderCamera else { return }
        let p = anchorPointBeforeResize ?? anchorPoint(anchor, of: win.frame)
        // Clamp into the screen that owns the anchor point (R2), not the live frame's
        // screen, so a card overlapping a shared edge is not yanked across displays.
        let screen = screen(containing: p)
        let placed = origin(placing: anchor, at: p, size: win.frame.size)
        let safe = clampedOrigin(placed, size: win.frame.size, in: screen.visibleFrame, margin: edgeMargin)
        applyOrigin(safe, animated: animated)
    }

    // Centered horizontally under the notch, tucked below the menu bar (camera screen).
    private func underCameraOrigin(size: NSSize) -> NSPoint? {
        guard let screen = cameraScreen() else { return nil }
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = (screen.visibleFrame.maxY - size.height - 3).rounded()
        return NSPoint(x: x, y: y)
    }

    // Center the window horizontally under the camera/notch, tucked just below the
    // menu bar. Re-applied on resize so it stays centered in both pill and card states.
    private func positionUnderCamera() {
        guard let win = window, let o = underCameraOrigin(size: win.frame.size) else { return }
        repositioning = true
        win.setFrameOrigin(o)
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: originKey)
        // Mark the instant so the trailing programmatic didMove is ignored by windowMoved.
        lastProgrammaticMoveAt = Date()
        DispatchQueue.main.async { [weak self] in self?.repositioning = false }
    }

    private func setSnapped(_ on: Bool) {
        snappedUnderCamera = on
        model.snapped = on
        snapMenuItem?.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: snappedKey)
    }

    // Toggled from the menu item AND the in-island snap button.
    @objc private func toggleSnap() {
        if snappedUnderCamera {
            setSnapped(false)   // release; leave the island where it is
            return
        }
        // Unobtrusive: collapse to the compact pill, then center under the camera.
        if model.expanded {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { model.expanded = false }
        }
        setSnapped(true)
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        DispatchQueue.main.async { [weak self] in self?.positionUnderCamera() }
    }

    // Manual snap from the view's double-tap gesture. ALL SIX snaps are identical now: release
    // the menu's sticky under-camera mode, pick the anchor, place it on-screen, and pin that
    // anchor so expand/collapse grows correctly. Centers are first-class anchor positions, NOT
    // a bolted-on sticky mode.
    private func snapToCorner(_ request: SnapRequest) {
        guard let win = window else { return }
        if snappedUnderCamera { setSnapped(false) }
        let a: Anchor
        switch request {
        case .corner(let c): a = Anchor(c)
        case .topCenter:     a = .topCenter
        case .bottomCenter:  a = .bottomCenter
        }
        let screen = activeScreen(for: win.frame)
        let target = snapOrigin(to: a, size: win.frame.size, in: screen.visibleFrame, margin: edgeMargin)
        let safe = clampedOrigin(target, size: win.frame.size, in: screen.visibleFrame, margin: edgeMargin)
        anchor = a
        anchorPointBeforeResize = anchorPoint(a, of: NSRect(origin: safe, size: win.frame.size))
        applyOrigin(safe, animated: true)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MI"
        let menu = NSMenu()
        // Title reflects state so it's obvious how to bring a hidden island back.
        let showHide = NSMenuItem(title: window.isVisible ? "Hide Monitor Island" : "Show Monitor Island",
                                  action: #selector(toggleVisible), keyEquivalent: "s")
        menu.addItem(showHide)
        showHideItem = showHide

        let snapItem = NSMenuItem(title: "Snap under camera", action: #selector(toggleSnap), keyEquivalent: "c")
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
        setIslandVisible(!window.isVisible)
    }

    // Hide button on the island: collapse to the compact pill so the next reveal is the
    // unobtrusive state, then order the window out. Reopen from the MI menu-bar item.
    private func hideIsland() {
        model.expanded = false
        setIslandVisible(false)
    }

    // Single place that shows/hides the window and keeps the menu item title in sync.
    private func setIslandVisible(_ visible: Bool) {
        guard let win = window else { return }
        if visible { win.makeKeyAndOrderFront(nil) } else { win.orderOut(nil) }
        showHideItem?.title = visible ? "Hide Monitor Island" : "Show Monitor Island"
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
