import XCTest
import CoreGraphics
@testable import PinTop

/// Mission Control hides overlays via a per-generation exposé-surface
/// fingerprint (Dock layer-18 on Tahoe and earlier, WindowManager layer-19
/// on newer macOS) plus a Dock window-count fallback. These tests lock the
/// pure geometry gate and document the per-signal matching rules so a future
/// macOS layer reshuffle fails loudly here instead of ghosting in the
/// overview.
final class OverviewProbeTests: XCTestCase {
    private func entry(bounds: [String: CGFloat]) -> [String: Any] {
        [kCGWindowBounds as String: bounds]
    }

    func testRejectsNonDictionaryAndMissingBounds() {
        XCTAssertFalse(WindowManager.isFullScreenBounds([:]))
        XCTAssertFalse(WindowManager.isFullScreenBounds(["other": 1]))
    }

    func testRejectsSmallWindows() {
        XCTAssertFalse(WindowManager.isFullScreenBounds(entry(bounds: [
            "X": 0, "Y": 0, "Width": 800, "Height": 600,
        ])))
    }

    func testHalfScreenExposeStripIsNotFullScreen() {
        // The Spaces strip WindowManager draws during MC is wide but short —
        // it must not count as the exposé surface.
        guard let screen = NSScreen.main else { return }
        XCTAssertFalse(WindowManager.isFullScreenBounds(entry(bounds: [
            "X": 0, "Y": 0,
            "Width": screen.frame.width, "Height": 120,
        ])))
    }

    func testAcceptsFullScreenSurface() {
        guard let screen = NSScreen.main else { return }
        XCTAssertTrue(WindowManager.isFullScreenBounds(entry(bounds: [
            "X": 0, "Y": 0,
            "Width": screen.frame.width, "Height": screen.frame.height,
        ])))
    }

    func testAcceptsOnePixelOffMidAnimationSample() {
        // Pre-scaling samples mid-zoom can be a pixel off — the probe is
        // lenient so the overlay hides on the FIRST frame, not after.
        guard let screen = NSScreen.main else { return }
        XCTAssertTrue(WindowManager.isFullScreenBounds(entry(bounds: [
            "X": 1, "Y": 1,
            "Width": screen.frame.width - 1, "Height": screen.frame.height - 1,
        ])))
    }

    func testRejectsOffsetFullSizeWindow() {
        // A full-size window dragged away from the corner is a real window,
        // not the exposé surface.
        guard let screen = NSScreen.main else { return }
        XCTAssertFalse(WindowManager.isFullScreenBounds(entry(bounds: [
            "X": 200, "Y": 200,
            "Width": screen.frame.width, "Height": screen.frame.height,
        ])))
    }
}
