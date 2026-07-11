import Cocoa
import CoreGraphics

// MARK: - PinOverlayWindow

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
        // ponytail: no shadow — recompute on every reposition causes ghost trail
        // during move. Spec said false; the rounded-corner clip is the only edge.
        self.hasShadow = false
        self.level = .statusBar + 1 // above all normal windows
        self.ignoresMouseEvents = true // clicks pass through to the window below
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = false

        // Configure image view
        imageView.image = snapshot
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        // Modern macOS windows clip their content to a ~10pt rounded
        // rectangle. Without matching that here the overlay's square
        // corners poke out past the source window's rounded ones.
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true

        self.contentView = imageView
    }

    func updateSnapshot(_ snapshot: NSImage) {
        imageView.image = snapshot
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
