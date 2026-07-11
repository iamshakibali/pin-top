import Cocoa
import CoreGraphics

// MARK: - SelectionOverlayWindow

class SelectionOverlayWindow: NSWindow {
    private let onComplete: (CGPoint?) -> Void
    private var isActive = true
    private var cursorPushed = false

    init(screen: NSScreen, onComplete: @escaping (CGPoint?) -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.level = .statusBar + 1
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = false

        // Dark tint layer
        let tintView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        self.contentView = tintView

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

        // Crosshair cursor
        NSCursor.crosshair.push()
        cursorPushed = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        let appKitPoint = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        let screenPoint = CGPoint(
            x: appKitPoint.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - appKitPoint.y
        )

        popCursor()
        orderOut(nil)
        onComplete(screenPoint)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        popCursor()
        orderOut(nil)
        onComplete(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        popCursor()
        super.close()
    }

    deinit {
        popCursor()
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
