import Cocoa
import CoreGraphics
import Combine

// MARK: - WindowInfo

struct WindowInfo: Identifiable, Equatable, Hashable {
    let id: CGWindowID
    let name: String
    let ownerName: String
    let pid: pid_t
    let bounds: CGRect

    static func fromDictionary(_ dict: [String: Any]) -> WindowInfo? {
        guard
            let windowNumber = dict[kCGWindowNumber as String] as? CGWindowID,
            let ownerName = dict[kCGWindowOwnerName as String] as? String,
            let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
            let layer = dict[kCGWindowLayer as String] as? Int, layer == 0
        else { return nil }

        let name = dict[kCGWindowName as String] as? String ?? "(untitled)"
        let x = boundsDict["X"] ?? 0
        let y = boundsDict["Y"] ?? 0
        let w = boundsDict["Width"] ?? 0
        let h = boundsDict["Height"] ?? 0

        guard w > 10 && h > 10 else { return nil }

        return WindowInfo(
            id: windowNumber,
            name: name,
            ownerName: ownerName,
            pid: pid,
            bounds: CGRect(x: x, y: y, width: w, height: h)
        )
    }
}

// Diagnostic file log — NSLog from this app doesn't reliably reach the
// unified log store. Temporary; strip before merging.
func visLog(_ message: String) {
    let path = "/tmp/pintop-vis.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    handle.seekToEndOfFile()
    handle.write("\(Date()) \(message)\n".data(using: .utf8)!)
    try? handle.close()
}

// MARK: - WindowManager

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var pinnedWindows: Set<WindowInfo> = []
    @Published private(set) var isSelecting: Bool = false

    private var overlays: [CGWindowID: PinOverlayWindow] = [:]
    // Last bounds we applied to each overlay, in CGWindow (top-left) space.
    // Tracking this lets us skip work when nothing moved and detect resize
    // so we can recapture the snapshot immediately (no stale-stretch).
    private var lastAppliedBounds: [CGWindowID: CGRect] = [:]
    private var refreshTimer: DispatchSourceTimer?
    // Time-based fallback recapture so a pinned-but-idle window still picks
    // up live content changes (typing, video, scrolling) ~5×/sec even when
    // its bounds aren't changing.
    private var lastRecaptureTime: [CGWindowID: TimeInterval] = [:]
    private let idleRecaptureInterval: TimeInterval = 0.5
    // During active resize we throttle the snapshot recapture — captures run
    // on the background captureQueue, so the rate can stay high (≈12×/sec);
    // at the old 0.25s the stretched-between-captures bitmap accumulated
    // visible aspect distortion (stretched text, squashed rows).
    private var lastResizeRecaptureTime: [CGWindowID: TimeInterval] = [:]
    private let resizeRecaptureInterval: TimeInterval = 0.08
    // When bounds stop changing, force one final crisp recapture after this
    // delay so the overlay shows correct (un-stretched) content post-resize.
    private var lastBoundsChangeTime: [CGWindowID: TimeInterval] = [:]
    private let settleRecaptureDelay: TimeInterval = 0.1
    // ponytail: track which overlays are hidden because their source app is
    // frontmost. Avoids calling orderOut/orderFront every tick — only on
    // actual visibility transitions. Hidden overlays don't block input and
    // don't need recapture (the real window covers them entirely).
    private var hiddenOverlays: Set<CGWindowID> = []
    // Occlusion scan state: throttled front-to-back check per pinned window
    // that decides overlay visibility (see occlusionCheck).
    private var lastOcclusionScanTime: [CGWindowID: TimeInterval] = [:]
    private var lastOcclusionResult: [CGWindowID: Bool] = [:]
    private var lastOcclusionReason: [CGWindowID: String] = [:]
    private let occlusionScanInterval: TimeInterval = 0.2
    // Consecutive scans finding the window absent from the on-screen list
    // (other Space / minimized) vs a momentary Space-transition blip.
    private var offScreenStreaks: [CGWindowID: Int] = [:]
    // Consecutive windowByID misses before a pin is treated as closed — one
    // nil can be a transient CG glitch (Space switch, Mission Control).
    private var windowMissStreaks: [CGWindowID: Int] = [:]
    private let maxWindowMissTicks = 45 // ~0.75s at 16ms per tick

    // Set once we've prompted the user about Screen Recording permission this
    // session, so we don't keep badgering them every time they click the menu.
    private var hasPromptedScreenCaptureThisSession = false
    // ponytail: capture off main. Sync CGWindowListCreateImage on the main
    // runloop blocks the source app's Mach ports — that's the freeze root.
    private let captureQueue = DispatchQueue(label: "windowpin.capture", qos: .userInitiated)

    private init() {
        startRefreshTimer()
    }

    deinit {
        refreshTimer?.cancel()
    }

    // MARK: - Window Enumeration

    func enumerateWindows() -> [WindowInfo] {
        guard let infoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier

        return infoList.compactMap { dict -> WindowInfo? in
            guard let info = WindowInfo.fromDictionary(dict) else { return nil }
            guard info.pid != ourPID else { return nil } // exclude our own windows
            return info
        }
    }

    // Cheap path used by the ~60 Hz refresh loop: fetch just one window's
    // info by ID instead of enumerating every window on screen. Returns nil
    // when the window has been closed (so the caller can clean it up).
    func windowByID(_ windowID: CGWindowID) -> WindowInfo? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] else {
            return nil
        }
        for dict in infoList {
            if let info = WindowInfo.fromDictionary(dict), info.id == windowID {
                return info
            }
        }
        return nil
    }

    // MARK: - Selection Mode

    // Always enter the picker. The picker itself uses only
    // CGWindowListCopyWindowInfo, which doesn't require Screen Recording
    // permission. We surface the permission prompt only if an actual
    // snapshot capture returns nothing, so we don't keep blocking the menu.
    func enterSelectionMode() -> Bool {
        isSelecting = true
        return true
    }

func exitSelectionMode() {
    isSelecting = false
}

    func selectWindow(at screenPoint: CGPoint) -> WindowInfo? {
        let windows = enumerateWindows()
        // CGWindowListCopyWindowInfo returns windows front-to-back.
        for window in windows {
            if window.bounds.contains(screenPoint) {
                return window
            }
        }
        return nil
    }

    // MARK: - Snapshot Capture

    func captureSnapshot(of windowInfo: WindowInfo) -> NSImage? {
        guard let fullImage = CGWindowListCreateImage(
            windowInfo.bounds,
            .optionIncludingWindow,
            windowInfo.id,
            .bestResolution
        ) else {
            NSLog("[PinTop] captureSnapshot returned NIL — preflight=\(CGPreflightScreenCaptureAccess()) id=\(windowInfo.id)")
            return nil
        }

        // Use the EXACT backing scale of the display hosting the window.
        // Deriving it as pixels/points of the (often fractional) window rect
        // leaves the NSImage with a fractional dpi — every later draw then
        // resamples the whole bitmap by a fraction of a percent, which
        // softens all text. A whole-number dpi lets the view draw 1:1.
        let displayScale = Self.backingScale(for: windowInfo.bounds)
        // Crop the outer 1pt from every side. The capture includes the
        // source window's edge stroke — a light-gray hairline on INACTIVE
        // windows — which reads as an artifact on the floating pin.
        let inset = displayScale // one point's worth of device pixels
        let cropRect = CGRect(
            x: inset, y: inset,
            width: CGFloat(fullImage.width) - inset * 2,
            height: CGFloat(fullImage.height) - inset * 2
        ).integral
        let cgImage = fullImage.cropping(to: cropRect) ?? fullImage

        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: cropRect.width / displayScale, height: cropRect.height / displayScale)
        )
    }

    // Whole-number backing scale (1 or 2) of the display containing the
    // rect's center; Retina is the sensible fallback if no display matches.
    private static func backingScale(for rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for id in ids.prefix(Int(count)) where CGDisplayBounds(id).contains(center) {
            guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
            return (CGFloat(mode.pixelWidth) / CGDisplayBounds(id).width).rounded()
        }
        return 2
    }

    // MARK: - Pin / Unpin

    func pin(_ window: WindowInfo) {
        guard !pinnedWindows.contains(window) else { return }

        // Capture initial snapshot. A nil result reliably means Screen
        // Recording permission is missing on macOS 10.15+ — surface the
        // prompt, but only once per session so the user isn't badgered.
        guard let snapshot = captureSnapshot(of: window) else {
            if !hasPromptedScreenCaptureThisSession {
                hasPromptedScreenCaptureThisSession = true
                requestScreenCapturePermission()
                showScreenCapturePermissionAlert()
            }
            return
        }

        pinnedWindows.insert(window)

        // Create overlay window
        let overlay = PinOverlayWindow(
            frame: appKitFrame(for: window.bounds),
            snapshot: snapshot,
            windowID: window.id,
            pid: window.pid
        )
        overlay.orderFront(nil)
        overlays[window.id] = overlay
    }

    func unpin(_ window: WindowInfo) {
        // Detach from dictionaries first so the 60Hz timer can't touch the
        // overlay. orderOut only — no close() — keeps the NSWindow alive but
        // hidden, avoiding the auto-termination "last window closed" hook.
        let overlay = overlays.removeValue(forKey: window.id)
        pinnedWindows.remove(window)
        clearTrackingState(for: window.id)
        overlay?.orderOut(nil)
    }

    func unpinAll() {
        // ponytail: orderOut only, no close(). NSWindow.close() decrements the
        // app's window count; LSUIElement + auto-terminate hook was treating
        // the last overlay close as "last window closed → quit". orderOut
        // keeps the window alive (just hidden), so the status item stays
        // resident and the app survives.
        let snapshot = Array(overlays.values)
        overlays.removeAll()
        pinnedWindows.removeAll()
        lastAppliedBounds.removeAll()
        lastRecaptureTime.removeAll()
        lastResizeRecaptureTime.removeAll()
        lastBoundsChangeTime.removeAll()
        hiddenOverlays.removeAll()
        lastOcclusionScanTime.removeAll()
        lastOcclusionResult.removeAll()
        lastOcclusionReason.removeAll()
        offScreenStreaks.removeAll()
        windowMissStreaks.removeAll()
        for overlay in snapshot {
            overlay.orderOut(nil)
        }
    }

    private func clearTrackingState(for windowID: CGWindowID) {
        lastAppliedBounds.removeValue(forKey: windowID)
        lastRecaptureTime.removeValue(forKey: windowID)
        lastResizeRecaptureTime.removeValue(forKey: windowID)
        lastBoundsChangeTime.removeValue(forKey: windowID)
        hiddenOverlays.remove(windowID)
        lastOcclusionScanTime.removeValue(forKey: windowID)
        lastOcclusionResult.removeValue(forKey: windowID)
        lastOcclusionReason.removeValue(forKey: windowID)
        offScreenStreaks.removeValue(forKey: windowID)
        windowMissStreaks.removeValue(forKey: windowID)
    }

    // MARK: - Accessibility

    func requestScreenCapturePermission() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: - Refresh Timer (snapshot live update + stale cleanup)

    private func startRefreshTimer() {
        // ~60 Hz so move/resize feel like they're glued to the source window.
        // Each tick only looks up the specific pinned windows by ID (cheap);
        // the expensive full-screen CGWindowListCreateImage run only fires
        // when the window's bounds changed or the idle fallback interval lapses.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            // CGWindowListCopyWindowInfo / CGWindowListCreateImage autoreleased
            // CoreFoundation intermediates can pile up in AppKit's runloop
            // pool if we drain them lazily. Wrap each tick in its own pool so
            // they're released at tick end, before any tear-down could race
            // the runloop's outer pool. This stops the SIGSEGV at
            // _CFAutoreleasePoolPop where a stale CG object was being
            // released against state we'd already moved on from.
            autoreleasepool {
                self?.refreshOverlays()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func refreshOverlays() {
        guard !pinnedWindows.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate

        // O(1) burial proxy: if the source window's owner app isn't the
        // frontmost app, some other app's window is covering it → absorb the
        // next click so we can re-front the source instead of letting the
        // click fall through to the covering app (the reported bug). We avoid
        // enumerating all onscreen windows every tick — the original loop went
        // out of its way to use a cheap per-window lookup for exactly this
        // reason; a full scan at 60Hz made the click→front path feel delayed.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Iterate over a copy: removing from a Set while iterating it can crash.
        for window in Array(pinnedWindows) {
            guard let overlay = overlays[window.id] else {
                pinnedWindows.remove(window)
                clearTrackingState(for: window.id)
                continue
            }

            // Cheap single-window lookup instead of enumerating everything.
            guard let currentWindow = windowByID(window.id) else {
                // A single nil lookup can be a transient glitch (Space switch,
                // Mission Control); only treat the window as closed after a
                // sustained absence, or the pin silently vanishes.
                let misses = (windowMissStreaks[window.id] ?? 0) + 1
                windowMissStreaks[window.id] = misses
                if misses >= maxWindowMissTicks {
                    // Window was closed — clean up. orderOut instead of close to
                    // avoid decrementing the app's window count (Clear All chain
                    // was triggering auto-termination).
                    overlay.orderOut(nil)
                    overlays.removeValue(forKey: window.id)
                    pinnedWindows.remove(window)
                    clearTrackingState(for: window.id)
                    windowMissStreaks[window.id] = nil
                }
                continue
            }
            windowMissStreaks[window.id] = nil

            // ponytail: overlay visibility tracks whether the real window is
            // actually EXPOSED (top-most over its own bounds), checked with a
            // throttled front-to-back scan. The old frontmost-APP proxy broke
            // twice: clicking the desktop activates Finder without raising the
            // buried pinned window (pin vanished — "always-on-top not
            // working"), and a raised-but-not-focused window got the overlay
            // re-shown over the exposed real window (flash/double image).
            let sourceIsFrontmost = frontmostPID == currentWindow.pid
            if (now - (lastOcclusionScanTime[window.id] ?? 0)) >= occlusionScanInterval {
                lastOcclusionScanTime[window.id] = now
                var hide: Bool
                var reason: String
                switch occlusionCheck(currentWindow) {
                case .exposed:
                    offScreenStreaks[window.id] = 0
                    hide = true
                    reason = "top of stack"
                case .covered(let why):
                    offScreenStreaks[window.id] = 0
                    hide = false
                    reason = why
                case .offScreen:
                    let streak = (offScreenStreaks[window.id] ?? 0) + 1
                    offScreenStreaks[window.id] = streak
                    hide = streak >= 3 // ~0.6s sustained — ride out Space transitions
                    reason = "off-screen streak=\(streak)"
                }
                if lastOcclusionResult[window.id] != hide {
                    visLog("scan wid=\(window.id) hide=\(hide) reason=\(reason) srcFrontmost=\(sourceIsFrontmost)")
                }
                lastOcclusionResult[window.id] = hide
                lastOcclusionReason[window.id] = reason
            }
            let shouldHide = lastOcclusionResult[window.id] ?? false
            if shouldHide {
                if !hiddenOverlays.contains(window.id) {
                    visLog("HIDE wid=\(window.id) reason=\(lastOcclusionReason[window.id] ?? "?")")
                    overlay.orderOut(nil)
                    hiddenOverlays.insert(window.id)
                }
                continue
            } else if hiddenOverlays.contains(window.id) {
                // Source just became buried — show the overlay, take a fresh
                // snapshot so it isn't stale from before we hid it.
                visLog("SHOW wid=\(window.id)")
                overlay.orderFront(nil)
                hiddenOverlays.remove(window.id)
                lastRecaptureTime[window.id] = 0 // force immediate recapture
            }

            // Not hidden = the pinned window is (at least partly) covered.
            // Absorb the next click so we re-front the source app instead of
            // letting the click fall through to the covering app.
            overlay.setAbsorbsClicks(true)

            let prevBounds = lastAppliedBounds[window.id]
        let boundsChanged = prevBounds != currentWindow.bounds
        // Distinguish move from resize: on a move the content bitmap is
        // identical, so we never need to recapture — just reposition the
        // overlay. Resizing changes content layout, so we recapture there.
        let sizeChanged = boundsChanged && prevBounds != nil && currentWindow.bounds.size != prevBounds!.size
        let prevIdleRecapture = lastRecaptureTime[window.id] ?? 0
        let idleRecaptureDue = (now - prevIdleRecapture) >= idleRecaptureInterval

        // Skip everything if nothing changed and we're not due for an
        // idle refresh — keeps the main loop nearly free for an idle pin.
        guard boundsChanged || idleRecaptureDue else { continue }

        let prevResizeRecapture = lastResizeRecaptureTime[window.id] ?? 0
        let resizeRecaptureDue = (now - prevResizeRecapture) >= resizeRecaptureInterval
        let lastChange = lastBoundsChangeTime[window.id] ?? 0
        // Trigger a crisp recapture shortly after a resize stops so we don't
        // leave a stretched bitmap at the final size.
        let settleRecaptureDue = !boundsChanged && lastChange > 0 && (now - lastChange) < settleRecaptureDelay && (now - prevResizeRecapture) >= resizeRecaptureInterval

        if boundsChanged {
            // display:false — let AppKit repaint at the next vsync instead of
            // forcing a synchronous redraw here.画面 is smoother because we're
            // not blocking the main thread on paint during a burst of moves.
            overlay.setFrame(appKitFrame(for: currentWindow.bounds), display: false)
            lastAppliedBounds[window.id] = currentWindow.bounds
            if sizeChanged {
                lastBoundsChangeTime[window.id] = now
            }
        }

        // Recapture decision:
        //  - move (size unchanged): NEVER recapture — bitmap is already valid
        //  - idle pinned window: every idleRecaptureInterval (~5×/sec) so
        //    live content (typing, video) keeps updating
        //  - actively resizing: every resizeRecaptureInterval (~12×/sec) so
        //    the stretched-between-captures bitmap never accumulates visible
        //    aspect distortion; captures are off-main, the cost is fine
        //  - just stopped resizing: one final crisp recapture
        // ponytail: suppress idle recapture while bounds are actively changing.
        // Content is identical on a move, so the existing bitmap is still valid —
        // a mid-move bitmap swap only flickers. Idle refresh resumes once stationary.
        let idleRecaptureActive = idleRecaptureDue && !boundsChanged
        let shouldRecapture = idleRecaptureActive || (sizeChanged && resizeRecaptureDue) || settleRecaptureDue
        if shouldRecapture {
            // Stamp recapture time NOW so we don't queue back-to-back captures
            // for the same window if the capture itself takes a while.
            lastRecaptureTime[window.id] = now
            lastResizeRecaptureTime[window.id] = now
            if settleRecaptureDue {
                lastBoundsChangeTime[window.id] = 0
            }
            // Off-main capture. Snapshot is read-only against the source's
            // CGWindowID, so it's safe to run on a background queue. The
            // bitmap apply hops back to main, where NSImageView lives.
            let wid = window.id
            let overlayRef = overlay
            captureQueue.async { [weak self] in
                guard let snapshot = self?.captureSnapshot(of: currentWindow) else { return }
                DispatchQueue.main.async {
                    // Bail if the pin was released while we were capturing.
                    guard self?.overlays[wid] === overlayRef else { return }
                    overlayRef.updateSnapshot(snapshot)
                }
            }
        }
        }
    }

    // Occlusion tri-state for a pinned window:
    //  - .exposed: it's the top-most window over its own bounds → the real
    //    window is visible, hide the overlay.
    //  - covered: another on-screen window draws over it (same Space) → show
    //    the overlay mirror on top. This is the core pin feature.
    //  - offScreen: not in the on-screen list at all — different Space (e.g.
    //    a fullscreen app active), minimized, or mid-transition. Floating a
    //    frozen snapshot over an unrelated Space reads as a ghost, so the
    //    overlay hides; it reappears when the window's Space returns.
    private enum OcclusionState {
        case exposed
        case covered(reason: String)
        case offScreen
    }

    private func occlusionCheck(_ window: WindowInfo) -> OcclusionState {
        for candidate in enumerateWindows() {
            guard candidate.bounds.intersects(window.bounds) else { continue }
            if candidate.id == window.id { return .exposed }
            return .covered(reason: "under [\(candidate.id)] \(candidate.ownerName) '\(candidate.name)'")
        }
        return .offScreen
    }

    // CGWindow bounds use a top-left global origin; AppKit windows use bottom-left.
    private func appKitFrame(for quartzFrame: CGRect) -> CGRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = CGRect(
            x: quartzFrame.minX,
            y: mainDisplayHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        // Pixel-align: CG window bounds are often fractional (half-point
        // window positions), and rendering the snapshot at a subpixel offset
        // softens text and smears the window's 1px edge stroke into a
        // hairline. Snap to whole points.
        return CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    private func showScreenCapturePermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is required"
        // If the app was rebuilt with a new code signature, the old TCC grant
        // no longer applies even though PinTop may still appear checked in
        // System Settings. Removing and re-adding is the only fix.
        let preflight = CGPreflightScreenCaptureAccess()
        let alreadyListed = preflight ? " (appears granted but invalid after rebuild — remove & re-add)" : ""
        alert.informativeText = "Allow Pin Top in System Settings > Privacy & Security > Screen Recording\(alreadyListed), then quit and reopen Pin Top."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
