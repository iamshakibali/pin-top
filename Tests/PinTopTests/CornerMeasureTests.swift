import CoreGraphics
import XCTest

@testable import PinTop

/// Tests for WindowManager.measuredCornerRadius — the overlay's corner clip
/// must match the source window's real corner shape or the pin grows dark
/// notches (clip too small) or square pokes (clip too large) at its corners.
final class CornerMeasureTests: XCTestCase {
    /// Render an RGBA8 bitmap: opaque inside a rounded rect of the given
    /// radius, transparent outside (what CGWindowListCreateImage returns for
    /// a rounded window).
    private func roundedImage(width: Int, height: Int, radius: Int, scale: CGFloat = 1) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let r = CGFloat(radius)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()!
    }

    private func squareImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()!
    }

    func testMeasuresRoundedCornerRadius() {
        XCTAssertEqual(WindowManager.measuredCornerRadius(of: roundedImage(width: 400, height: 300, radius: 32)), 32)
        // Retina-scale captures measure in pixels; the caller divides by scale.
        XCTAssertEqual(WindowManager.measuredCornerRadius(of: roundedImage(width: 800, height: 600, radius: 40)), 40)
    }

    func testSmallRadius() {
        XCTAssertEqual(WindowManager.measuredCornerRadius(of: roundedImage(width: 200, height: 200, radius: 10)), 10)
    }

    func testSquareCornerMeasuresZero() {
        XCTAssertEqual(WindowManager.measuredCornerRadius(of: squareImage(width: 200, height: 150)), 0)
    }
}
