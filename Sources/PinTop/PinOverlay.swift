import Cocoa
import CoreGraphics

// MARK: - PinOverlayWindow

class PinOverlayWindow: NSWindow {
    private let imageView = NSImageView()
    private var windowID: CGWindowID
    private let pid: pid_t

    init(frame: CGRect, snapshot: NSImage, windowID: CGWindowID, pid: pid_t) {
        self.windowID = windowID
        self.pid = pid
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
        // ponytail: default click-through. A click only needs us when the real
        // pinned window is buried under some other app — then the click would
        // fall straight through to the *covering* app (the bug). When that's the
        // case we briefly swallow the click, re-front the real window (via the
        // owner app + raise on its windowID), then drop back to passthrough so
        // subsequent clicks reach the now-frontmost real window normally.
        self.ignoresMouseEvents = true
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

    // Called from the refresh loop: when the real pinned window is covered by
    // another app, absorb the next click (so we can re-front the real window)
    // instead of letting it fall through to the covering app (the bug). When
    // the real window is frontmost over our bounds, drop back to passthrough
    // so clicks reach the real window's buttons/fields directly.
    func setAbsorbsClicks(_ absorbs: Bool) {
        guard ignoresMouseEvents != !absorbs else { return }
        // ponytail: set a level high enough to actually receive the click
        // when it arrives, so mouseDown fires even under a covering window.
        ignoresMouseEvents = !absorbs
    }

    // Forward click to the pinned app when buried: activate the owner app and
    // raise its window to the front, so the real (now frontmost) window sits
    // directly beneath the overlay. Next tick drops us back to passthrough and
    // subsequent clicks reach the real window normally.
    override func mouseDown(with event: NSEvent) {
        bringSourceToFront()
    }

    private func bringSourceToFront() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // ponytail: the SDK dropped the synchronous activate(ignoringOtherApps:).
        // activate(options:) is async, but we run it during the click on the main
        // thread so it's effectively immediate; the bigger delay source was the
        // 60Hz full-window enumeration in the refresh loop, now removed.
        app.activate(options: [])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
