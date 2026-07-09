import Cocoa
import CoreGraphics

class SelectionOverlayWindow: NSWindow {
    private let onComplete: (CGPoint) -> Void
    private var isActive = true

    init(screen: NSScreen, onComplete: @escaping (CGPoint) -> Void) {
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
        let tintView = NSView(frame: screen.frame)
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
        let labelY = screen.frame.height - 60 // near top from bottom-origin
        label.frame.origin = CGPoint(x: labelX, y: labelY)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        tintView.addSubview(label)

        // Crosshair cursor
        NSCursor.crosshair.push()
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        let locationInWindow = event.locationInWindow
        let screenPoint = CGPoint(x: locationInWindow.x, y: locationInWindow.y)

        NSCursor.pop()
        close()
        onComplete(screenPoint)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        NSCursor.pop()
        close()
        onComplete(.zero) // Cancel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        NSCursor.pop()
        super.close()
    }

    deinit {
        NSCursor.pop()
    }
}
