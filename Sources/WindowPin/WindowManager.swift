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

// MARK: - WindowManager

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var pinnedWindows: Set<WindowInfo> = []
    @Published private(set) var isSelecting: Bool = false

    private var overlays: [CGWindowID: PinOverlayWindow] = [:]
    private var refreshTimer: DispatchSourceTimer?

    // ponytail: CGEventTap is an Obj-C type; Swift sees it as CFMachPort.
    private var eventTap: Any?

    private init() {
        startRefreshTimer()
    }

    deinit {
        refreshTimer?.cancel()
        stopEventTap()
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

    // MARK: - Selection Mode

    func enterSelectionMode() {
        isSelecting = true
        startEventTap()
    }

    func exitSelectionMode() {
        isSelecting = false
        stopEventTap()
    }

    func selectWindow(at screenPoint: CGPoint) -> WindowInfo? {
        let windows = enumerateWindows()
        // Iterate in reverse so topmost windows are tried first
        for window in windows.reversed() {
            if window.bounds.contains(screenPoint) {
                return window
            }
        }
        return nil
    }

    // MARK: - Snapshot Capture

    func captureSnapshot(of windowInfo: WindowInfo) -> NSImage? {
        // ponytail: CGWindowListCreateImage is deprecated in macOS 14,
        // but ScreenCaptureKit requires full-screen-access entitlement and
        // can only capture the current process's windows. This remains the
        // simplest way to grab any window on screen.
        guard let cgImage = CGWindowListCreateImage(
            windowInfo.bounds,
            .optionOnScreenBelowWindow,
            windowInfo.id,
            []
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: windowInfo.bounds.size)
    }

    // MARK: - Pin / Unpin

    func pin(_ window: WindowInfo) {
        guard !pinnedWindows.contains(window) else { return }

        pinnedWindows.insert(window)

        // Capture initial snapshot
        guard let snapshot = captureSnapshot(of: window) else {
            pinnedWindows.remove(window)
            return
        }

        // Create overlay window
        let overlay = PinOverlayWindow(
            frame: window.bounds,
            snapshot: snapshot,
            windowID: window.id
        )
        overlay.orderFront(nil)
        overlays[window.id] = overlay
    }

    func unpin(_ window: WindowInfo) {
        overlays[window.id]?.close()
        overlays.removeValue(forKey: window.id)
        pinnedWindows.remove(window)
    }

    func unpinAll() {
        for (_, overlay) in overlays {
            overlay.close()
        }
        overlays.removeAll()
        pinnedWindows.removeAll()
    }

    // MARK: - Accessibility

    func requestAccessibilityPermission() {
        // Priming AX call triggers macOS permission dialog on first run.
        _ = AXIsProcessTrusted()
    }

    // MARK: - Event Tap (local click capture for selection mode)

    private func startEventTap() {
        // Install a local event tap to intercept left mouse clicks
        let eventMask: CGEventMask = 1 << CGEventType.leftMouseDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else { return }

        eventTap = tap
        // Create and add a run loop source for the event tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }

    private func stopEventTap() {
        // ponytail: CGEventTap bridges to CFMachPort in Swift; downcast always succeeds.
        let tap = eventTap as! CFMachPort
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        eventTap = nil
    }

    // MARK: - Refresh Timer (snapshot live update + stale cleanup)

    private func startRefreshTimer() {
        refreshTimer = DispatchSource.makeTimerSource(queue: .main)
        refreshTimer?.schedule(deadline: .now(), repeating: .milliseconds(500))
        refreshTimer?.setEventHandler { [weak self] in
            self?.refreshOverlays()
        }
        refreshTimer?.resume()
    }

    private func refreshOverlays() {
        guard !pinnedWindows.isEmpty else { return }

        let currentIDs = Set(enumerateWindows().map(\.id))

        for window in pinnedWindows {
            guard let overlay = overlays[window.id] else {
                pinnedWindows.remove(window)
                continue
            }

            // Window was closed — clean up
            if !currentIDs.contains(window.id) {
                overlay.close()
                overlays.removeValue(forKey: window.id)
                pinnedWindows.remove(window)
                continue
            }

            // Update snapshot so live content stays current
            if let newSnapshot = captureSnapshot(of: window) {
                overlay.updateSnapshot(newSnapshot)
            }
        }
    }
}

// MARK: - Event Tap Callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }

    // Extract window manager from refcon
    let opaque = Unmanaged<WindowManager>.fromOpaque(
        UnsafeRawPointer(refcon!)
    )
    let wm = opaque.takeUnretainedValue()

    // Get mouse location in global CG coordinates (matches CGWindowList bounds)
    let location = event.location
    let screenPoint = CGPoint(x: location.x, y: location.y)

    // Select and pin the window under the click
    if let window = wm.selectWindow(at: screenPoint) {
        wm.pin(window)
    }

    // Exit selection mode
    wm.exitSelectionMode()

    // Consume the event (return nil to prevent it from reaching other apps)
    return nil
}
