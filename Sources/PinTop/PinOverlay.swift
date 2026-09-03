import Cocoa
import CoreGraphics

// MARK: - PinOverlayWindow

class PinOverlayWindow: NSWindow {
    private let imageView = NSImageView()
    let windowID: CGWindowID
    private let pid: pid_t

    // macOS 26 draws a 1pt black outline just OUTSIDE kCGWindowBounds and a
    // 1pt gray hairline OVER the window's outermost content row/col (measured
    // against exposed windows: black at minX-1/minY-1/maxX/maxY, gray at the
    // bounds edge). The captured bitmap contains neither — it is pure window
    // buffer — so a pin sized exactly to the bounds shows the real window's
    // black outline peeking out behind it on all sides (the "double edge"),
    // and its own edge reads raw where the real window shows the gray ring.
    // The overlay therefore grows 1pt past the bounds on every side and
    // draws both rings itself: when the pin sits pixel-aligned over the real
    // window the rings land exactly on the real ones; when it floats, the
    // pin still reads as a native window edge.
    static let outlineMargin: CGFloat = 1

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

        // Configure content. The container hosts the snapshot at a 1pt inset
        // (the outline margin) and draws the two edge rings above it. The
        // image view is sized to the bitmap's own point size (never stretched
        // to the window frame) so every draw is 1:1 — see updateSnapshot.
        let container = OutlineContainerView(frame: NSRect(origin: .zero, size: self.frame.size))
        container.wantsLayer = true
        container.cornerRadius = cornerRadius
        // Outer edge = filled black shape, not a 1pt stroke. The real window's
        // outline follows Apple's continuous corner curve, which a circular
        // stroke path can't track — at corners the stroke diverges and the
        // real outline (also black) peeked out as a second arc. A filled shape
        // whose radius runs 2pt ahead of the bitmap's clip covers the whole
        // mismatch with black: on straight edges only the outermost 1pt shows
        // (the bitmap sits above the fill), at corners a slightly thicker
        // black crescent shows — exactly where the real outline is black too.
        container.cornerFill.fillColor = NSColor.black.cgColor
        container.cornerFill.strokeColor = NSColor.clear.cgColor
        container.innerRing.strokeColor = NSColor(calibratedRed: 0.32, green: 0.335, blue: 0.35, alpha: 1).cgColor
        container.innerRing.fillColor = NSColor.clear.cgColor
        container.innerRing.lineWidth = 1

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
        // Edge layers added AFTER the image view so they composite above the
        // snapshot's edge — the black fill shows in the 1pt margin and at the
        // bitmap's transparent corners, the gray ring overdraws the bitmap's
        // outermost row/col exactly where the real window wears its hairline.
        container.layer?.addSublayer(container.cornerFill)
        container.layer?.addSublayer(container.innerRing)
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

// MARK: - OutlineContainerView

/// Hosts the snapshot plus the two edge rings (see outlineMargin on
/// PinOverlayWindow). Rebuilds the ring paths on every layout pass so they
/// track resizes; the paths are stroked at half-pixel insets so each 1pt
/// ring lands exactly on one pixel row of the window surface.
private final class OutlineContainerView: NSView {
    let cornerFill = CAShapeLayer()
    let innerRing = CAShapeLayer()
    var cornerRadius: CGFloat = 0

    override func layout() {
        super.layout()
        let b = bounds
        cornerFill.frame = b
        innerRing.frame = b
        let r = cornerRadius
        // Fill: covers the full inflated frame minus nothing — the bitmap
        // (inset 1) hides all of it except the outer 1pt rim and the corner
        // crescents beyond the bitmap's own rounded-corner alpha.
        cornerFill.path = CGPath(
            roundedRect: b,
            cornerWidth: r + 2,
            cornerHeight: r + 2,
            transform: nil
        )
        innerRing.path = CGPath(
            roundedRect: b.insetBy(dx: 1.5, dy: 1.5),
            cornerWidth: max(r - 0.5, 0),
            cornerHeight: max(r - 0.5, 0),
            transform: nil
        )
    }
}
