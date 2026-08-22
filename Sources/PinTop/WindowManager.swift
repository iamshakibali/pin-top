import Cocoa
import CoreGraphics
import Combine

// MARK: - WindowInfo

/// Identity of a window is its CGWindowID. Name and bounds are mutable
/// attributes (windows move, resize, retitle — a pinned window can drift by
/// a single pixel between pins), so equality/hashing must key on `id` only.
/// Field-wise equality made `pinnedWindows.contains` miss a re-selected
/// window and pin it twice, stranding the first overlay on screen (#5).
struct WindowInfo: Identifiable, Equatable, Hashable {
    let id: CGWindowID
    let name: String
    let ownerName: String
    let pid: pid_t
    let bounds: CGRect

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

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
    // While the source is exposed AND its app is frontmost, the always-
    // visible overlay is covering a live window the user is interacting
    // with — refresh at interaction rate so typing/scrolling reads live.
    private let activeUseRecaptureInterval: TimeInterval = 0.08
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
    // ponytail: track which overlays are hidden because their source left
    // the screen (other Space / minimized). Avoids calling orderOut/
    // orderFront every tick — only on actual transitions. Hidden overlays
    // don't block input and don't need recapture.
    private var hiddenOverlays: Set<CGWindowID> = []
    private var appSwitchObserver: NSObjectProtocol?
    // Occlusion scan state: throttled front-to-back check per pinned window
    // that decides overlay visibility (see occlusionCheck).
    private var lastOcclusionScanTime: [CGWindowID: TimeInterval] = [:]
    private var lastOcclusionResult: [CGWindowID: Bool] = [:]
    private var lastOcclusionReason: [CGWindowID: String] = [:]
    // Whether the source window was top-over-its-own-bounds at the last
    // scan — drives click pass-through vs absorption (NOT visibility).
    private var lastOcclusionExposed: [CGWindowID: Bool] = [:]
    // Mission Control / App Exposé state, probed at the scan cadence. While
    // a system overview is up, the overlay must hide: it would otherwise
    // float ABOVE the overview UI, showing a full-size frozen copy over the
    // shrunken real window — reads as a duplicated window. The real window
    // already represents the pin in the overview grid.
    // Signature measured on this machine (macOS 26): the overview's UI is
    // owned by the Dock, and while it is up the Dock's on-screen window
    // count bursts from a resting 2-4 to 14-15. (The classic owner="Dock" +
    // layer≥1000 signature does NOT match — those windows sit at other
    // layers.) Mid-overview redraws can momentarily read low again, so
    // re-showing is debounced by consecutive samples.
    private var systemOverviewActive = false
    private var lastOverviewProbeTime: TimeInterval = 0
    private var overviewCloseStreak = 0
    // Faster than the occlusion scan: hiding must land within the first
    // frames of the overview's zoom animation or it reads as the pin
    // "showing, then disappearing after a delay". The window-list call is
    // ~2ms; at 30ms cadence that's a few percent of a core while pins exist.
    private let overviewProbeInterval: TimeInterval = 0.03
    // After the overview closes, hold the overlay hidden this many samples
    // (~300ms) so it never pops back mid exit-animation.
    private let overviewCloseDebounce = 10
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
        startAppSwitchObserver()
    }

    deinit {
        refreshTimer?.cancel()
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // App switches are the only moments the window server can demote our
    // (inactive-app) overlay below the newly active app's windows. Re-assert
    // immediately instead of waiting for the next covered/exposed transition.
    private func startAppSwitchObserver() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let visible = self.overlays.filter { !self.hiddenOverlays.contains($0.key) }
            for (_, overlay) in visible {
                overlay.orderFrontRegardless()
            }
        }
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

    func captureSnapshot(of windowInfo: WindowInfo, sourceIsActive: Bool = true) -> NSImage? {
        // Quantize the capture rect to whole points. Window bounds are often
        // fractional; letting CG round a fractional rect makes the bitmap's
        // pixel size wobble between captures (visible as the pin shifting a
        // few px and its edge sitting wrong).
        let captureRect = CGRect(
            x: windowInfo.bounds.minX.rounded(),
            y: windowInfo.bounds.minY.rounded(),
            width: windowInfo.bounds.width.rounded(),
            height: windowInfo.bounds.height.rounded()
        )
        guard let fullImage = CGWindowListCreateImage(
            captureRect,
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
        var cgImage = fullImage

        // The pin must keep reading like the ACTIVE window — it's the whole
        // point of pinning. When the snapshot is taken while the source app
        // is inactive, macOS has already dimmed/desaturated the content in
        // the window's own backing store, so invert that measured transform
        // (inactive loses ~23% saturation, gains ~0.003 brightness and loses
        // ~9% luma contrast — measured empirically). Without this the pin
        // visibly changes color the moment the overlay takes over from the
        // real window. Active-state captures get NO lift or colors would
        // overshoot into over-saturation.
        if !sourceIsActive, let lifted = Self.activeAppearanceLift(cgImage) {
            cgImage = lifted
        }

        // No edge crop: the capture's 1px window stroke stays in the bitmap
        // and the bitmap fills the overlay edge to edge. Cropping it created
        // a 1pt transparent rim through which the real window's stroke (or
        // the covering app) peeked — the actual "wrong edge" artifact.
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: CGFloat(cgImage.width) / displayScale, height: CGFloat(cgImage.height) / displayScale)
        )
    }

    // Whole-number backing scale (1 or 2) of the display containing the
    // rect's center; Retina is the sensible fallback if no display matches.
    private static let ciContext = CIContext()

    // Inverse of macOS's inactive-window dimming, measured empirically:
    // an inactive window's content averages sat ×0.77, V +0.0034, luma
    // contrast ×0.91 versus its active render. These values undo exactly
    // that — see captureSnapshot for when the lift is applied.
    private static func activeAppearanceLift(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(input, forKey: kCIInputImageKey)
        controls.setValue(1.27, forKey: "inputSaturation")
        controls.setValue(-0.02, forKey: "inputBrightness")
        controls.setValue(1.10, forKey: "inputContrast")
        guard let output = controls.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

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
        let sourceActiveAtPin = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        guard let snapshot = captureSnapshot(of: window, sourceIsActive: sourceActiveAtPin) else {
            if !hasPromptedScreenCaptureThisSession {
                hasPromptedScreenCaptureThisSession = true
                requestScreenCapturePermission()
                showScreenCapturePermissionAlert()
            }
            return
        }

        pinnedWindows.insert(window)

        // If an overlay for this id somehow survives (e.g. state left by an
        // older build), retire it before installing the new one — replacing
        // the dict entry alone would strand the old window on screen, where
        // it keeps absorbing clicks until the app restarts.
        overlays[window.id]?.orderOut(nil)

        // Create overlay window
        let overlay = PinOverlayWindow(
            frame: appKitFrame(for: window.bounds),
            snapshot: snapshot,
            windowID: window.id,
            pid: window.pid
        )
        // orderFrontRegardless, not orderFront: PinTop is a background app,
        // and ordering front from a NON-active application is only advisory —
        // AppKit warns the window "may order beneath the active application's
        // windows". Every click on another app makes that app active, so a
        // plain orderFront lets the system demote the pin under the covering
        // window on each app switch — visible as the pin "blinking" between
        // floating and sunk. orderFrontRegardless is the documented way to
        // put a floating window above the active app's windows.
        overlay.orderFrontRegardless()
        overlays[window.id] = overlay
        // Seed bounds tracking with the frame just applied so the first
        // refresh tick can already tell a move apart from a resize.
        lastAppliedBounds[window.id] = window.bounds
    }

    func unpin(_ window: WindowInfo) {
        // Detach from dictionaries first so the 60Hz timer can't touch the
        // overlay. orderOut only — no close() — keeps the NSWindow alive but
        // hidden, avoiding the auto-termination "last window closed" hook.
        let overlay = overlays.removeValue(forKey: window.id)
        pinnedWindows.remove(window)
        clearTrackingState(for: window.id)
        overlay?.orderOut(nil)
        // Also retire any untracked overlay for the same window — an orphan
        // stranded by a double-pin in an older build would otherwise keep
        // swallowing clicks in its frame after this unpin (#5).
        for case let stray as PinOverlayWindow in NSApp.windows where stray.windowID == window.id {
            stray.orderOut(nil)
        }
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
        lastOcclusionExposed.removeAll()
        lastOcclusionReason.removeAll()
        offScreenStreaks.removeAll()
        windowMissStreaks.removeAll()
        for overlay in snapshot {
            overlay.orderOut(nil)
        }
        // Sweep any overlay windows no longer tracked in `overlays` — e.g.
        // orphans stranded by double-pinning in older builds. They sit at
        // pin level and swallow every click in their frame, which read as
        // "picker dead until restart" (#5). orderOut (not close) on purpose.
        for case let overlay as PinOverlayWindow in NSApp.windows {
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
        lastOcclusionExposed.removeValue(forKey: windowID)
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
        // Probe the system-overview state once per scan window, not per pin.
        // Open on the FIRST high sample (hide fast); require three
        // consecutive low samples to close (mid-overview redraws dip low
        // momentarily — re-showing on one would blink during the overview).
        if (now - lastOverviewProbeTime) >= overviewProbeInterval {
            lastOverviewProbeTime = now
            if systemOverviewProbe() {
                overviewCloseStreak = 0
                systemOverviewActive = true
            } else if systemOverviewActive {
                overviewCloseStreak += 1
                if overviewCloseStreak >= overviewCloseDebounce {
                    systemOverviewActive = false
                    overviewCloseStreak = 0
                }
            }
        }
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
                var exposed: Bool
                switch occlusionCheck(currentWindow) {
                case .exposed:
                    offScreenStreaks[window.id] = 0
                    hide = false
                    exposed = true
                    reason = "top of stack"
                case .covered(let why):
                    offScreenStreaks[window.id] = 0
                    hide = false
                    exposed = false
                    reason = why
                case .offScreen:
                    let streak = (offScreenStreaks[window.id] ?? 0) + 1
                    offScreenStreaks[window.id] = streak
                    hide = streak >= 3 // ~0.6s sustained — ride out Space transitions
                    exposed = false
                    reason = "off-screen streak=\(streak)"
                }
                // An exposure flip means the source was just raised or
                // buried — its ACTIVE/INACTIVE rendering changed with it.
                // Force the next recapture so the overlay matches.
                let prevExposed = lastOcclusionExposed[window.id]
                if prevExposed != nil && prevExposed != exposed {
                    lastRecaptureTime[window.id] = 0
                }
                lastOcclusionResult[window.id] = hide
                lastOcclusionExposed[window.id] = exposed
                lastOcclusionReason[window.id] = reason
            }
    // ponytail: overlay visibility now only tracks whether the source is
    // on-screen AT ALL. The exposed/covered distinction no longer hides the
    // overlay — every covered↔exposed flip used to orderOut/orderFront the
    // pin, and each flip is visible (snapshot↔real swap: shadow redraw,
    // tint, edge), so clicking behind (or on) the pin blinked it. The pin
    // is "always on top": it stays put, pixel-aligned over the real window
    // when exposed (identical bitmap — no double image) and floating above
    // covers when buried. Only clicks change behavior with exposure.
    // EXCEPTION: while Mission Control / App Exposé is up, the overlay
    // hides — it would otherwise float ABOVE the system overview, showing
    // a full-size frozen copy over the shrunken real window.
    let offScreenNow = lastOcclusionResult[window.id] ?? false
    if offScreenNow || systemOverviewActive {
        if !hiddenOverlays.contains(window.id) {
            overlay.orderOut(nil)
            hiddenOverlays.insert(window.id)
        }
        continue
    } else if hiddenOverlays.contains(window.id) {
        overlay.orderFrontRegardless()
        hiddenOverlays.remove(window.id)
        lastRecaptureTime[window.id] = 0 // force immediate recapture
    }

    // Re-assert ordering when another app activates: the system
    // re-evaluates stacking on every app switch and may demote an
    // inactive app's window below the newly active app's windows.
    // Handled via NSWorkspace.didActivateApplicationNotification
    // (see startAppSwitchObserver) — event-driven, not polled.

    // Click handling DOES follow exposure: pass clicks through to the real
    // window while it's top over its own bounds (normal interaction —
    // focus, drag, type), absorb them to re-front the source only when
    // it's buried under another window.
    let exposedNow = lastOcclusionExposed[window.id] ?? true
    overlay.setAbsorbsClicks(!exposedNow)

            let prevBounds = lastAppliedBounds[window.id]
        let boundsChanged = prevBounds != currentWindow.bounds
        // Distinguish move from resize: on a move the content bitmap is
        // identical, so we never need to recapture — just reposition the
        // overlay. Resizing changes content layout, so we recapture there.
        let sizeChanged = boundsChanged && prevBounds != nil && currentWindow.bounds.size != prevBounds!.size
        let activeUse = (frontmostPID == currentWindow.pid) && (lastOcclusionExposed[window.id] ?? false)
        let recaptureInterval = activeUse ? activeUseRecaptureInterval : idleRecaptureInterval
        let prevIdleRecapture = lastRecaptureTime[window.id] ?? 0
        let idleRecaptureDue = (now - prevIdleRecapture) >= recaptureInterval

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
            let newFrame = appKitFrame(for: currentWindow.bounds)
            if sizeChanged {
                // Resize: redraw synchronously at the new size. With
                // display:false the resized backing store stayed unflushed and
                // the window server kept compositing stale intermediate
                // surfaces — the stuck full-opacity frames of issue #6.
                overlay.setFrame(newFrame, display: true)
            } else {
                // Pure move: setFrameOrigin translates the window's surface
                // inside the window server without touching the backing store,
                // so there is no lazily-unpainted region to leave behind along
                // the movement path (issue #6). Also cheaper than setFrame,
                // which keeps 60Hz move tracking smooth.
                overlay.setFrameOrigin(newFrame.origin)
            }
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
            // sourceIsFrontmost decides whether the inactive-dimming lift
            // applies — sampled at enqueue time, close enough to capture.
            let wid = window.id
            let overlayRef = overlay
            captureQueue.async { [weak self] in
                guard let snapshot = self?.captureSnapshot(of: currentWindow, sourceIsActive: sourceIsFrontmost) else { return }
                DispatchQueue.main.async {
                    // Bail if the pin was released while we were capturing.
                    guard self?.overlays[wid] === overlayRef else { return }
                    overlayRef.updateSnapshot(snapshot)
                }
            }
        }
        }
    }

    // Mission Control / App Exposé detection — see the measured signature on
    // the systemOverviewActive property above.
    private func systemOverviewProbe() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        var dockCount = 0
        for dict in list {
            if (dict[kCGWindowOwnerName as String] as? String) == "Dock" {
                dockCount += 1
            }
        }
        return dockCount >= 8
    }

    // Occlusion tri-state for a pinned window:
    //  - .exposed: it's the top-most window over its own bounds → clicks
    //    pass through the overlay to the real window.
    //  - covered: another on-screen window draws over it (same Space) → the
    //    overlay floats the mirror on top and absorbs clicks (re-fronting
    //    the source). This is the core pin feature.
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
