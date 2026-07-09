import Cocoa
import CoreGraphics

// A borderless, always-on-top overlay window that mirrors a pinned window's snapshot.
class PinOverlayWindow: NSWindow {
    private let imageView = NSImageView()
    private var windowID: CGWindowID

    init(frame: CGRect, snapshot: NSImage, windowID: CGWindowID) {
        self.windowID = windowID
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar + 1 // above all normal windows
        self.ignoresMouseEvents = true // clicks pass through to the window below
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = false

        // Configure image view
        imageView.image = snapshot
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.backgroundColor = NSColor.clear.cgColor

        self.contentView = imageView
    }

    func updateSnapshot(_ snapshot: NSImage) {
        imageView.image = snapshot
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        contentView = nil
        super.close()
    }
}
