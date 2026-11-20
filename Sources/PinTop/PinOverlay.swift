import Cocoa
import CoreGraphics

// MARK: - PinOverlayWindow

class PinOverlayWindow: NSWindow {
    private let imageView = NSImageView()
    let windowID: CGWindowID
    private let pid: pid_t

    // No drawn edge: the pin is sized exactly to the source window's bounds
    // and shows only the snapshot (plus the window-server shadow). Kept as a
    // named constant so the frame math below stays in one place.
    static let outlineMargin: CGFloat = 0

    init(frame: CGRect, snapshot: NSImage, windowID: CGWindowID, pid: pid_t, cornerRadius: CGFloat) {
        self.windowID = windowID
        self.pid = pid
        let margin = Self.outlineMargin
        super.init(
            contentRect: frame.insetBy(dx: -margin, dy: -margin),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        // The snapshot bitmap ends at the source window's bounds — the real
        // window's drop shadow is drawn by the window server OUTSIDE those
        // bounds, so it never makes it into the capture. Without a shadow here
        // the floating pin reads flat/blended against whatever covers the real
        // window. The window server derives a shadow from this window's
        // non-opaque content shape (the rounded snapshot), so the pin keeps a
        // native window-like edge. Moves go through setFrameOrigin (pure
        // surface translation), which carries the shadow along instead of
        // recomputing it — no repeat of the #6 drag-trail artifact.
        self.hasShadow = true
        // .floating, NOT statusBar+1: windows above ~level 100 are excluded
        // from Mission Control's zoom-out and stay frozen full-size ON TOP of
        // the overview — the pin read as a duplicate window floating over
        // the grid. At .floating the overlay still sits above every normal
        // window (level 0), but Mission Control zooms it away together with
        // the real window — they're pixel-aligned, so they shrink as one and
        // the pin appears exactly once in the overview.
        self.level = .floating
        // ponytail: default click-through. A click only needs us when the real
        // pinned window is buried under some other app — then the click would
        // fall straight through to the *covering* app (the bug). When that's the
        // case we briefly swallow the click, re-front the real window (via the
        // owner app + raise on its windowID), then drop back to passthrough so
        // subsequent clicks reach the now-frontmost real window normally.
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = false

        // Configure content. The image view is sized to the bitmap's own
        // point size (never stretched to the window frame) so every draw is
        // 1:1 — see updateSnapshot.
        let container = NSView(frame: NSRect(origin: .zero, size: self.frame.size))
        container.wantsLayer = true

        imageView.image = snapshot
        imageView.frame = NSRect(origin: CGPoint(x: margin, y: margin), size: snapshot.size)
        imageView.imageScaling = .scaleNone
        imageView.autoresizingMask = []
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        // Clip to the SOURCE window's own corner radius, measured from the
        // capture's alpha channel (see measuredCornerRadius) — not a guessed
        // constant. The bitmap's rounded corners are transparent (the window
        // server masks the shape out), so a clip smaller than the true
        // radius leaves those transparent corners + the real window's drop
        // shadow showing through as sharp dark notches at all four corners;
        // a clip larger would let square bitmap corners poke out.
        imageView.layer?.cornerRadius = cornerRadius
        imageView.layer?.masksToBounds = true

        container.addSubview(imageView)
        self.contentView = container
    }

    func updateSnapshot(_ snapshot: NSImage) {
        imageView.image = snapshot
        // Size the view to the BITMAP's point size, not the window frame.
        // Stretching even a fraction of a point resamples every pixel and
        // softens the whole image ("pin looks blurry / not native"). The
        // frame tracks the window; the view draws the bitmap 1:1 inside it.
        imageView.frame = NSRect(origin: CGPoint(x: Self.outlineMargin, y: Self.outlineMargin), size: snapshot.size)
    }

    // WindowManager speaks in SOURCE WINDOW coordinates (kCGWindowBounds);
    // the overlay window itself is outlineMargin larger on every side.
    func setContentFrame(_ contentFrame: CGRect, display: Bool) {
        let margin = Self.outlineMargin
        super.setFrame(contentFrame.insetBy(dx: -margin, dy: -margin), display: display)
    }

    func setContentOrigin(_ contentOrigin: CGPoint) {
        let margin = Self.outlineMargin
        super.setFrameOrigin(CGPoint(x: contentOrigin.x - margin, y: contentOrigin.y - margin))
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
        // Defer activation until after the current click event finishes
        // resolving. Activating synchronously inside mouseDown gets undone
        // by AppKit's post-event focus resolution — focus bounced back to
        // the previously active app within a second, flapping the overlay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.bringSourceToFront()
        }
    }

    private func bringSourceToFront() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // activate alone makes the app key but does NOT raise a window that's
        // buried under another app — the overlay then stays visible +
        // absorbing and every further click just re-activates the
        // already-active app, so the pinned window becomes un-clickable and
        // un-draggable. activateAllWindows actually lifts the app's windows
        // above whatever covers them.
        app.activate(options: [.activateAllWindows])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
