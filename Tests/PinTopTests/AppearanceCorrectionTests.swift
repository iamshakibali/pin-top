import XCTest
@testable import PinTop

/// Tests for the appearance corrector: a synthetic "window" whose pixels
/// transform a known way when it loses key/focus must be detected, measured
/// and inverted back to (approximately) its anchored statistics — the
/// mathematical core of the pin-doesn't-change-color fix. Covers both
/// triggers: app deactivation and Chromium-style per-window dimming (which
/// happens with the app still frontmost, so no app-level signal exists).
final class AppearanceCorrectionTests: XCTestCase {

    private func syntheticBitmap(
        width: Int = 48,
        height: Int = 32,
        transform: (Float, Float, Float) -> (Float, Float, Float)
    ) -> DownsampledBitmap {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // Gradients + channel separation so medians, spreads, chroma
                // and the luma grid all carry signal.
                let r = 0.15 + 0.5 * Float(x) / Float(width)
                let g = 0.25 + 0.4 * Float(y) / Float(height)
                let b = 0.35 + 0.3 * (1 - Float(x) / Float(width))
                let (tr, tg, tb) = transform(r, g, b)
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8(min(255, max(0, tr * 255)))
                rgba[offset + 1] = UInt8(min(255, max(0, tg * 255)))
                rgba[offset + 2] = UInt8(min(255, max(0, tb * 255)))
                rgba[offset + 3] = 255
            }
        }
        return DownsampledBitmap(width: width, height: height, rgba: rgba)
    }

    private func solidBitmap(color: Float, width: Int = 48, height: Int = 32) -> DownsampledBitmap {
        syntheticBitmap { _, _, _ in (color, color, color) }
    }

    /// Chromium-style inactive restyle: desaturate toward luma, then dim.
    private func dimmingTransform(desat: Float, brightness: Float) -> (Float, Float, Float) -> (Float, Float, Float) {
        { r, g, b in
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (
                (luma + desat * (r - luma)) * brightness,
                (luma + desat * (g - luma)) * brightness,
                (luma + desat * (b - luma)) * brightness
            )
        }
    }

    private func cgImage(from bitmap: DownsampledBitmap) -> CGImage? {
        var rgba = bitmap.rgba
        return rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: bitmap.width,
                    height: bitmap.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bitmap.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
    }

    private func decision(
        anchor: AppearanceStats,
        activeFit: AppearanceCorrection = AppearanceCorrection(),
        pendingFit: AppearanceCorrection? = nil,
        lastCapture: AppearanceStats,
        freezeStreak: Int = 0,
        capture: DownsampledBitmap
    ) -> AppearanceDecision {
        WindowManager.correctorDecision(
            anchor: anchor,
            activeFit: activeFit,
            pendingFit: pendingFit,
            lastCapture: lastCapture,
            freezeStreak: freezeStreak,
            capture: capture,
            captureStats: WindowManager.computeStats(capture)
        )
    }

    // MARK: - Fit + apply round trips

    func testMeasuresAndInvertsHeavyDimming() {
        let active = syntheticBitmap(transform: { ($0, $1, $2) })
        let inactive = syntheticBitmap(transform: dimmingTransform(desat: 0.2, brightness: 0.55))
        let activeStats = WindowManager.computeStats(active)

        guard let correction = WindowManager.measureCorrection(active: activeStats, inactive: inactive) else {
            return XCTFail("gate rejected a static, uniformly dimmed window")
        }
        XCTAssertFalse(correction.isIdentity, "heavy dimming must produce a non-identity correction")

        // Round trip: the corrected bitmap must land back on the active
        // statistics — that is the whole point of the transform.
        guard let image = cgImage(from: inactive),
              let corrected = WindowManager.applyCorrection(correction, to: image),
              let correctedDown = WindowManager.downsample(corrected)
        else { return XCTFail("correction pipeline returned nil") }
        let correctedStats = WindowManager.computeStats(correctedDown)

        // 1/desat = 5 in theory; heavy desat leaves chroma near the 8-bit
        // noise floor, which inflates the ratio up to the clamp at 6 — the
        // affine stage absorbs whatever the saturation factor overshoots.
        XCTAssertTrue((4.5...6.0).contains(correction.saturation), "saturation factor \(correction.saturation) out of range")
        for channel in 0..<3 {
            XCTAssertEqual(correctedStats.channelMedian[channel], activeStats.channelMedian[channel], accuracy: 0.03)
            XCTAssertEqual(correctedStats.channelSpread[channel], activeStats.channelSpread[channel], accuracy: 0.03)
        }
        XCTAssertEqual(correctedStats.chromaMean, activeStats.chromaMean, accuracy: activeStats.chromaMean * 0.2)
    }

    func testModerateSystemStyleDimming() {
        // The subtle system-level change (inactive chrome dimming).
        let active = syntheticBitmap(transform: { ($0, $1, $2) })
        let inactive = syntheticBitmap(transform: dimmingTransform(desat: 0.77, brightness: 0.95))
        let activeStats = WindowManager.computeStats(active)

        guard let correction = WindowManager.measureCorrection(active: activeStats, inactive: inactive),
              let image = cgImage(from: inactive),
              let corrected = WindowManager.applyCorrection(correction, to: image),
              let correctedDown = WindowManager.downsample(corrected)
        else { return XCTFail("pipeline returned nil for moderate dimming") }
        let correctedStats = WindowManager.computeStats(correctedDown)
        for channel in 0..<3 {
            XCTAssertEqual(correctedStats.channelMedian[channel], activeStats.channelMedian[channel], accuracy: 0.03)
        }
    }

    func testNoDimmingYieldsIdentity() {
        let active = syntheticBitmap(transform: { ($0, $1, $2) })
        let activeStats = WindowManager.computeStats(active)
        XCTAssertEqual(WindowManager.measureCorrection(active: activeStats, inactive: active), AppearanceCorrection())
    }

    func testContentChangeFailsGate() {
        // A localized content edit between captures must NOT be mistaken
        // for an appearance change — the measurement returns nil.
        let active = syntheticBitmap(transform: { ($0, $1, $2) })
        let activeStats = WindowManager.computeStats(active)

        // Brighten one quadrant the way real content (video frame, new
        // message) would — spatially non-uniform, unlike a tone shift.
        var rgba = active.rgba
        for y in 16..<active.height {
            for x in 24..<active.width {
                let offset = (y * active.width + x) * 4
                for channel in 0..<3 {
                    rgba[offset + channel] = UInt8(min(255, Float(rgba[offset + channel]) + 76))
                }
            }
        }
        let edited = DownsampledBitmap(width: active.width, height: active.height, rgba: rgba)
        XCTAssertNil(WindowManager.measureCorrection(active: activeStats, inactive: edited))
    }

    func testCorrectionsMatchTolerances() {
        var a = AppearanceCorrection()
        a.saturation = 5
        a.channelScale = SIMD3<Float>(repeating: 1.8)
        var b = a
        b.saturation = 5.2
        b.channelBias = SIMD3<Float>(repeating: 0.03)
        XCTAssertTrue(WindowManager.correctionsMatch(a, b))
        b.saturation = 5.6
        XCTAssertFalse(WindowManager.correctionsMatch(a, b))
    }

    // MARK: - Corrector decisions

    func testDimmingFreezesThenAdopts() {
        // The reported bug scenario: window dims (intra-app focus loss).
        // Frame 1: uniform shift vs the previous (bright) capture → freeze,
        // the pin keeps its bright bitmap. Frame 2: nothing changed since
        // frame 1, pending candidate re-fits identically → adopt.
        let bright = syntheticBitmap(transform: { ($0, $1, $2) })
        let anchor = WindowManager.computeStats(bright)
        let dimmed = syntheticBitmap(transform: dimmingTransform(desat: 0.2, brightness: 0.55))
        let dimStats = WindowManager.computeStats(dimmed)

        let first = decision(anchor: anchor, lastCapture: anchor, capture: dimmed)
        guard case .freeze(let candidate) = first else {
            return XCTFail("first dimmed frame should freeze, got \(first)")
        }
        XCTAssertFalse(candidate.isIdentity)
        let second = decision(anchor: anchor, pendingFit: candidate, lastCapture: dimStats, freezeStreak: 1, capture: dimmed)
        guard case .adopt = second else {
            return XCTFail("confirmation frame should adopt, got \(second)")
        }
    }

    func testBrighteningReanchors() {
        // Focus regained: the window comes back brighter than the anchor →
        // show raw and ratchet the anchor (also the self-heal path for a
        // pin created while the window was dimmed).
        let dimmed = syntheticBitmap(transform: dimmingTransform(desat: 0.2, brightness: 0.55))
        let dimStats = WindowManager.computeStats(dimmed)
        let bright = syntheticBitmap(transform: { ($0, $1, $2) })
        let brightStats = WindowManager.computeStats(bright)

        // Simulate the adopted-dim state: anchor already maps to the bright
        // look, capture goes BRIGHT past it.
        let anchor = WindowManager.mappedStats(dimStats, through: WindowManager.measureCorrection(active: brightStats, inactive: dimmed)!)
        let result = decision(anchor: anchor, lastCapture: dimStats, capture: bright)
        guard case .reanchor(let stats) = result else {
            return XCTFail("brightened window should reanchor, got \(result)")
        }
        XCTAssertEqual(stats, brightStats)
    }

    func testLocalizedContentChangeFlowsWithCurrentCorrection() {
        // While dimmed with an adopted fit, a real content edit (chat
        // message, terminal output) must flow through WITH the correction —
        // content freshness without losing the active look.
        let bright = syntheticBitmap(transform: { ($0, $1, $2) })
        let anchor = WindowManager.computeStats(bright)
        let dimmed = syntheticBitmap(transform: dimmingTransform(desat: 0.2, brightness: 0.55))
        let fit = WindowManager.measureCorrection(active: anchor, inactive: dimmed)!

        var rgba = dimmed.rgba
        for y in 16..<dimmed.height {
            for x in 24..<dimmed.width {
                let offset = (y * dimmed.width + x) * 4
                for channel in 0..<3 {
                    rgba[offset + channel] = UInt8(min(255, Float(rgba[offset + channel]) + 60))
                }
            }
        }
        let editedDim = DownsampledBitmap(width: dimmed.width, height: dimmed.height, rgba: rgba)

        let result = decision(anchor: anchor, activeFit: fit, lastCapture: WindowManager.computeStats(dimmed), capture: editedDim)
        guard case .flow(let flowed) = result else {
            return XCTFail("content change should flow, got \(result)")
        }
        XCTAssertEqual(flowed, fit, "content frames must keep the adopted correction")
    }

    func testSolidFrameFlowsWithoutBiasLift() {
        // Fullscreen near-solid video frame (fade to black): must flow with
        // the current correction, never get a bias-only "lift" that would
        // repaint it at the anchor's brightness.
        let previousSolid = solidBitmap(color: 0.25)
        let blackSolid = solidBitmap(color: 0.02)
        let anchorStats = WindowManager.computeStats(syntheticBitmap(transform: { ($0, $1, $2) }))
        let result = decision(anchor: anchorStats,
                              lastCapture: WindowManager.computeStats(previousSolid),
                              capture: blackSolid)
        guard case .flow = result else {
            return XCTFail("solid frame should flow, got \(result)")
        }
    }

    func testFreezeStreakBoundFlows() {
        // A continuously-drifting appearance (video fade) must not freeze
        // the pin forever: past the streak bound we flow with the last
        // confirmed correction.
        let bright = syntheticBitmap(transform: { ($0, $1, $2) })
        let anchor = WindowManager.computeStats(bright)
        let dimmed = syntheticBitmap(transform: dimmingTransform(desat: 0.3, brightness: 0.7))
        let result = decision(anchor: anchor,
                              pendingFit: nil,
                              lastCapture: anchor,
                              freezeStreak: 6,
                              capture: dimmed)
        guard case .flow = result else {
            return XCTFail("exceeded freeze streak should flow, got \(result)")
        }
    }

    func testMappedStatsTracksContentThroughFit() {
        // After adopting a fit, the anchor must describe the CURRENT
        // content at the TARGET appearance, or future fits gate against
        // stale content and never fire.
        let bright = syntheticBitmap(transform: { ($0, $1, $2) })
        let anchor = WindowManager.computeStats(bright)
        let dimmed = syntheticBitmap(transform: dimmingTransform(desat: 0.2, brightness: 0.55))
        let fit = WindowManager.measureCorrection(active: anchor, inactive: dimmed)!
        let mapped = WindowManager.mappedStats(WindowManager.computeStats(dimmed), through: fit)
        XCTAssertEqual(mapped.lumaMedian, anchor.lumaMedian, accuracy: 0.05)
        XCTAssertEqual(mapped.chromaMean, anchor.chromaMean, accuracy: anchor.chromaMean * 0.25)
        for channel in 0..<3 {
            XCTAssertEqual(mapped.channelMedian[channel], anchor.channelMedian[channel], accuracy: 0.05)
        }
    }

    func testSteadyDimmedStateFlowsWithoutRefitting() {
        // Once adopted, an unchanged capture must flow with the stored fit —
        // re-fitting against the remapped anchor is not a fixed point and
        // would oscillate between slightly different corrections.
        let bright = syntheticBitmap(transform: { ($0, $1, $2) })
        let anchor = WindowManager.computeStats(bright)
        let dimmed = syntheticBitmap(transform: dimmingTransform(desat: 0.2, brightness: 0.55))
        let dimStats = WindowManager.computeStats(dimmed)
        let fit = WindowManager.measureCorrection(active: anchor, inactive: dimmed)!
        let result = decision(anchor: WindowManager.mappedStats(dimStats, through: fit),
                              activeFit: fit,
                              lastCapture: dimStats,
                              capture: dimmed)
        guard case .flow(let flowed) = result else {
            return XCTFail("steady dimmed state should flow, got \(result)")
        }
        XCTAssertEqual(flowed, fit)
    }
}
