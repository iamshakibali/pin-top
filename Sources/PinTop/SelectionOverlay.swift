import Cocoa
import CoreGraphics

// MARK: - SelectionOverlayWindow

class SelectionOverlayWindow: NSWindow {
    private let onComplete: (CGPoint?) -> Void
    /// Quartz bounds of the window under a Quartz point, nil if none.
    private let windowAt: (CGPoint) -> CGRect?
    private let screenFrame: NSRect
    private let dimMask = CAShapeLayer()
    private static let hoverCornerRadius: CGFloat = 26
    private var isActive = true

    init(
        screen: NSScreen,
        windowAt: @escaping (CGPoint) -> CGRect?,
        onComplete: @escaping (CGPoint?) -> Void
    ) {
        self.onComplete = onComplete
        self.windowAt = windowAt
        self.screenFrame = screen.frame
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        // One above pin overlays' level. Pin overlays absorb clicks
        // while their source window is buried, and the refresh loop keeps
        // re-fronting them — at the same level they could sit over the
        // picker and swallow its clicks, reading as "picker dead" (#5).
        self.level = .statusBar + 2
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = false

        // Dark tint layer
        let tintView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        // Mask the dim so the window under the cursor shows through undimmed.
        // The mask's path is a full-screen rect with a hole (even-odd) over it.
        dimMask.frame = tintView.bounds
        dimMask.fillRule = .evenOdd
        tintView.layer?.mask = dimMask
        self.contentView = tintView
        updateDimMask(hole: nil)

        // Crosshair: the system resets the cursor to an arrow on every move
        // unless a cursor-update tracking area keeps setting it. Works on
        // non-key screens too, which a one-time push does not. mouseMoved
        // drives the hover highlight.
        tintView.addTrackingArea(NSTrackingArea(
            rect: tintView.bounds,
            options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        // Instruction label
        let label = NSTextField(labelWithString: "Click a window to pin it")
        label.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.sizeToFit()
        let labelX = (screen.frame.width - label.frame.width) / 2
        let labelY = screen.frame.height - 60
        label.frame.origin = CGPoint(x: labelX, y: labelY)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        tintView.addSubview(label)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActive else { return }
        let appKitPoint = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        guard screenFrame.contains(appKitPoint) else { return }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: appKitPoint.x, y: mainHeight - appKitPoint.y)

        // Convert the hovered window's Quartz bounds into this overlay's
        // local coordinates (AppKit, bottom-left origin, offset by screen).
        var hole: CGRect?
        if let bounds = windowAt(quartzPoint) {
            let appKitRect = CGRect(
                x: bounds.minX - screenFrame.minX,
                y: (mainHeight - bounds.maxY) - screenFrame.minY,
                width: bounds.width,
                height: bounds.height
            )
            hole = appKitRect
        }
        updateDimMask(hole: hole)
    }

    private func updateDimMask(hole: CGRect?) {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screenFrame.size))
        // Rounded hole to match the window's corners. Radius is a fixed guess
        // because the real one is only measured after capture (see
        // measuredCornerRadius). ponytail: ~macOS 26 window radius, not per-window.
        if let hole {
            path.addRoundedRect(in: hole, cornerWidth: Self.hoverCornerRadius, cornerHeight: Self.hoverCornerRadius)
        }
        // Implicit animation would lag behind the cursor.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimMask.path = path
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        let appKitPoint = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        let screenPoint = CGPoint(
            x: appKitPoint.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - appKitPoint.y
        )

        orderOut(nil)
        onComplete(screenPoint)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        orderOut(nil)
        onComplete(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
