import Cocoa
import CoreGraphics
import Combine

// MARK: - WindowInfo

/// Identity of a window is its CGWindowID. Name and bounds are mutable
/// attributes (windows move, resize, retitle — a pinned window can drift by
/// a single pixel between pins), so equality/hashing must key on `id` only.
/// Field-wise equality made `pinnedWindows.contains` miss a re-selected
/// window and pin it twice, stranding the first overlay on screen (#5).
struct WindowInfo: Identifiable, Equatable, Hashable {
    let id: CGWindowID
    let name: String
    let ownerName: String
    let pid: pid_t
    let bounds: CGRect

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func fromDictionary(_ dict: [String: Any]) -> WindowInfo? {
        guard
            let windowNumber = dict[kCGWindowNumber as String] as? CGWindowID,
            let ownerName = dict[kCGWindowOwnerName as String] as? String,
            let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
            let layer = dict[kCGWindowLayer as String] as? Int, layer == 0
        else { return nil }

        let name = dict[kCGWindowName as String] as? String ?? "(untitled)"
        let x = boundsDict["X"] ?? 0
        let y = boundsDict["Y"] ?? 0
        let w = boundsDict["Width"] ?? 0
        let h = boundsDict["Height"] ?? 0

        guard w > 10 && h > 10 else { return nil }

        return WindowInfo(
            id: windowNumber,
            name: name,
            ownerName: ownerName,
            pid: pid,
            bounds: CGRect(x: x, y: y, width: w, height: h)
        )
    }
}

// MARK: - Inactive-appearance correction

/// A downsampled RGBA8 copy of a capture, small enough to run robust pixel
/// statistics on without touching the full-resolution bitmap.
struct DownsampledBitmap {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

/// Robust per-channel statistics of a snapshot plus a coarse luma grid.
/// Feeds both halves of the inactive-appearance measurement: the channel
/// stats define the inverse transform to fit, and the luma grid gates the
/// measurement on the content being static (a global tone shift moves every
/// grid cell by the same amount; real content edits don't).
struct AppearanceStats: Equatable {
    var channelMedian = SIMD3<Float>(repeating: 0)
    /// MAD × 1.4826 (a robust std) per channel, in 0...1 units.
    var channelSpread = SIMD3<Float>(repeating: 0)
    /// Mean max−min channel distance, 0...1. Drops to near zero when a
    /// Chromium-style app desaturates its inactive content.
    var chromaMean: Float = 0
    /// Median luma (median of the cell medians), 0...1. Cheap direction
    /// signal: did the window get brighter or darker than the anchor.
    var lumaMedian: Float = 0
    /// Per-cell median luma over a ≤12×12 grid, 0...1.
    var cellLuma: [Float] = []
    var cellsX = 0
    var cellsY = 0
}

/// Per-window inverse of the source app's dimmed-window appearance, fitted
/// by comparing a capture against the anchor stats (see correctorDecision).
/// All values are in 0...1 sRGB units and are applied per-channel in the
/// same space (see applyCorrection), so no color-space conversion sits
/// between measurement and application.
struct AppearanceCorrection: Equatable {
    /// CIColorControls-style saturation boost applied before the affine
    /// stage, undoing lerp-toward-gray desaturation the affine can't.
    var saturation: Float = 1
    var channelScale = SIMD3<Float>(repeating: 1)
    var channelBias = SIMD3<Float>(repeating: 0)

    var isIdentity: Bool {
        saturation == 1
            && channelScale == SIMD3<Float>(repeating: 1)
            && channelBias == SIMD3<Float>(repeating: 0)
    }
}

/// What the appearance corrector decided about one fresh capture. The pin's
/// contract is "always read like the ACTIVE window": dimming shifts get
/// inverted against the anchor, brightening shifts re-anchor, mid-animation
/// or ambiguous frames freeze on the current bitmap until stable.
enum AppearanceDecision: Equatable {
    /// Content change (or no appearance change) — display the capture with
    /// the current correction; no corrector state changes.
    case flow(AppearanceCorrection)
    /// A new transform was confirmed by two consecutive captures — store it
    /// as the window's correction and display with it.
    case adopt(AppearanceCorrection)
    /// Appearance is mid-change (deactivation/focus animation, video fade):
    /// keep displaying the current bitmap, remember this candidate fit.
    case freeze(candidate: AppearanceCorrection)
    /// The window brightened beyond the anchor (key/focus regained): display
    /// raw and adopt these stats as the new anchor.
    case reanchor(AppearanceStats)
}

// MARK: - WindowManager

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var pinnedWindows: Set<WindowInfo> = []
    @Published private(set) var isSelecting: Bool = false

    private var overlays: [CGWindowID: PinOverlayWindow] = [:]
    // Last bounds we applied to each overlay, in CGWindow (top-left) space.
    // Tracking this lets us skip work when nothing moved and detect resize
    // so we can recapture the snapshot immediately (no stale-stretch).
    private var lastAppliedBounds: [CGWindowID: CGRect] = [:]
    private var refreshTimer: DispatchSourceTimer?
    // Time-based fallback recapture so a pinned-but-idle window still picks
    // up live content changes (typing, video, scrolling) ~5×/sec even when
    // its bounds aren't changing.
    private var lastRecaptureTime: [CGWindowID: TimeInterval] = [:]
    private let idleRecaptureInterval: TimeInterval = 0.5
    // While the source is exposed AND its app is frontmost, the always-
    // visible overlay is covering a live window the user is interacting
    // with — refresh at interaction rate so typing/scrolling reads live.
    private let activeUseRecaptureInterval: TimeInterval = 0.08
    // During active resize we throttle the snapshot recapture — captures run
    // on the background captureQueue, so the rate can stay high (≈12×/sec);
    // at the old 0.25s the stretched-between-captures bitmap accumulated
    // visible aspect distortion (stretched text, squashed rows).
    private var lastResizeRecaptureTime: [CGWindowID: TimeInterval] = [:]
    private let resizeRecaptureInterval: TimeInterval = 0.08
    // When bounds stop changing, force one final crisp recapture after this
    // delay so the overlay shows correct (un-stretched) content post-resize.
    private var lastBoundsChangeTime: [CGWindowID: TimeInterval] = [:]
    private let settleRecaptureDelay: TimeInterval = 0.1
    // ponytail: track which overlays are hidden because their source left
    // the screen (other Space / minimized). Avoids calling orderOut/
    // orderFront every tick — only on actual transitions. Hidden overlays
    // don't block input and don't need recapture.
    private var hiddenOverlays: Set<CGWindowID> = []
    private var appSwitchObserver: NSObjectProtocol?
    // Occlusion scan state: throttled front-to-back check per pinned window
    // that decides overlay visibility (see occlusionCheck).
    private var lastOcclusionScanTime: [CGWindowID: TimeInterval] = [:]
    private var lastOcclusionResult: [CGWindowID: Bool] = [:]
    private var lastOcclusionReason: [CGWindowID: String] = [:]
    // Whether the source window was top-over-its-own-bounds at the last
    // scan — drives click pass-through vs absorption (NOT visibility).
    private var lastOcclusionExposed: [CGWindowID: Bool] = [:]
    // Mission Control / App Exposé state, probed at the scan cadence. While
    // a system overview is up, the overlay must hide: it would otherwise
    // float ABOVE the overview UI, showing a full-size frozen copy over the
    // shrunken real window — reads as a duplicated window. The real window
    // already represents the pin in the overview grid.
    // Signature measured on this machine (macOS 26): the overview's UI is
    // owned by the Dock, and while it is up the Dock's on-screen window
    // count bursts from a resting 2-4 to 14-15. (The classic owner="Dock" +
    // layer≥1000 signature does NOT match — those windows sit at other
    // layers.) Mid-overview redraws can momentarily read low again, so
    // re-showing is debounced by consecutive samples.
    private var systemOverviewActive = false
    private var lastOverviewProbeTime: TimeInterval = 0
    private var overviewCloseStreak = 0
    // Faster than the occlusion scan: hiding must land within the first
    // frames of the overview's zoom animation or it reads as the pin
    // "showing, then disappearing after a delay". The window-list call is
    // ~2ms; at 30ms cadence that's a few percent of a core while pins exist.
    private let overviewProbeInterval: TimeInterval = 0.03
    // After the overview closes, hold the overlay hidden this many samples
    // (~300ms) so it never pops back mid exit-animation.
    private let overviewCloseDebounce = 10
    private let occlusionScanInterval: TimeInterval = 0.2
    // Consecutive scans finding the window absent from the on-screen list
    // (other Space / minimized) vs a momentary Space-transition blip.
    private var offScreenStreaks: [CGWindowID: Int] = [:]
    // Consecutive windowByID misses before a pin is treated as closed — one
    // nil can be a transient CG glitch (Space switch, Mission Control).
    private var windowMissStreaks: [CGWindowID: Int] = [:]
    private let maxWindowMissTicks = 45 // ~0.75s at 16ms per tick

    // MARK: Appearance corrector state (per pinned window)
    // Apps restyle their windows when they stop being the key/focused
    // window — the system dims chrome on app deactivation, and Chromium/
    // Electron apps (Figma plugin windows, Slack, VS Code…) fade their
    // whole content EVEN WHILE THE APP STAYS FRONTMOST (per-window focus,
    // not app activation — clicking the Figma canvas behind a pinned plugin
    // window dims it with no NSWorkspace signal at all). Those pixels are
    // baked into the capture, so a naive recapture visibly changes the
    // pin's color (the reported bug). Keyed-on-activation detection misses
    // the intra-app case, so instead EVERY recapture runs through
    // correctorDecision: a uniform tone shift vs the previous capture with
    // static content = appearance change → freeze while it animates, then
    // adopt the measured inverse once two captures agree; a shift toward
    // brighter/more-chromatic = focus regained → re-anchor raw; anything
    // non-uniform = real content change → flow through the current
    // correction.
    private enum AppearanceConstants {
        /// Consecutive frozen frames before giving up on confirmation
        /// (a video fade drifts every frame and would freeze the pin
        /// forever; a real deactivation animation settles within ~4).
        static let maxFreezeStreak = 6
    }
    /// The appearance the pin should keep showing: stats of the window in
    /// its most-active observed state. Ratchets up on brighten, tracks
    /// content through adopted corrections (mappedStats).
    private var anchorStats: [CGWindowID: AppearanceStats] = [:]
    /// Confirmed correction currently applied to dimmed captures.
    private var activeFit: [CGWindowID: AppearanceCorrection] = [:]
    /// Unconfirmed candidate fit (waiting for a second agreeing capture).
    private var pendingFit: [CGWindowID: AppearanceCorrection] = [:]
    /// Stats of the last RAW capture (adjacent-frame gate reference — raw
    /// to raw, so adopted corrections don't bias the gate).
    private var lastCaptureStats: [CGWindowID: AppearanceStats] = [:]
    private var freezeStreaks: [CGWindowID: Int] = [:]

    // Set once we've prompted the user about Screen Recording permission this
    // session, so we don't keep badgering them every time they click the menu.
    private var hasPromptedScreenCaptureThisSession = false
    // ponytail: capture off main. Sync CGWindowListCreateImage on the main
    // runloop blocks the source app's Mach ports — that's the freeze root.
    private let captureQueue = DispatchQueue(label: "windowpin.capture", qos: .userInitiated)

    private init() {
        startRefreshTimer()
        startAppSwitchObserver()
    }

    deinit {
        refreshTimer?.cancel()
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // App switches are the only moments the window server can demote our
    // (inactive-app) overlay below the newly active app's windows. Re-assert
    // immediately instead of waiting for the next covered/exposed transition.
    private func startAppSwitchObserver() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let visible = self.overlays.filter { !self.hiddenOverlays.contains($0.key) }
            for (_, overlay) in visible {
                overlay.orderFrontRegardless()
            }
        }
    }

    // MARK: - Window Enumeration

    func enumerateWindows() -> [WindowInfo] {
        guard let infoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier

        return infoList.compactMap { dict -> WindowInfo? in
            guard let info = WindowInfo.fromDictionary(dict) else { return nil }
            guard info.pid != ourPID else { return nil } // exclude our own windows
            return info
        }
    }

    // Cheap path used by the ~60 Hz refresh loop: fetch just one window's
    // info by ID instead of enumerating every window on screen. Returns nil
    // when the window has been closed (so the caller can clean it up).
    func windowByID(_ windowID: CGWindowID) -> WindowInfo? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] else {
            return nil
        }
        for dict in infoList {
            if let info = WindowInfo.fromDictionary(dict), info.id == windowID {
                return info
            }
        }
        return nil
    }

    // MARK: - Selection Mode

    // Always enter the picker. The picker itself uses only
    // CGWindowListCopyWindowInfo, which doesn't require Screen Recording
    // permission. We surface the permission prompt only if an actual
    // snapshot capture returns nothing, so we don't keep blocking the menu.
    func enterSelectionMode() -> Bool {
        isSelecting = true
        return true
    }

func exitSelectionMode() {
    isSelecting = false
}

    func selectWindow(at screenPoint: CGPoint) -> WindowInfo? {
        let windows = enumerateWindows()
        // CGWindowListCopyWindowInfo returns windows front-to-back.
        for window in windows {
            if window.bounds.contains(screenPoint) {
                return window
            }
        }
        return nil
    }

    // MARK: - Snapshot Capture

    /// Snapshot bookkeeping the corrector needs per capture, snapshotted on
    /// the main thread when the capture is enqueued.
    private struct AppearanceContext {
        let anchor: AppearanceStats
        let activeFit: AppearanceCorrection
        let pendingFit: AppearanceCorrection?
        let lastCapture: AppearanceStats
        let freezeStreak: Int
    }

    private struct ProcessedCapture {
        /// nil when the corrector froze — keep displaying the current bitmap.
        let image: NSImage?
        let stats: AppearanceStats
        let decision: AppearanceDecision
    }

    // The pin must keep reading like the ACTIVE window — it's the whole
    // point of pinning. Every capture runs through correctorDecision (see
    // the state block above for the model); this function does the pixel
    // half: raw capture, stats, decision, and the corrected bitmap.
    private func processCapture(of windowInfo: WindowInfo, context: AppearanceContext) -> ProcessedCapture? {
        // Quantize the capture rect to whole points. Window bounds are often
        // fractional; letting CG round a fractional rect makes the bitmap's
        // pixel size wobble between captures (visible as the pin shifting a
        // few px and its edge sitting wrong).
        let captureRect = CGRect(
            x: windowInfo.bounds.minX.rounded(),
            y: windowInfo.bounds.minY.rounded(),
            width: windowInfo.bounds.width.rounded(),
            height: windowInfo.bounds.height.rounded()
        )
        guard let rawImage = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            windowInfo.id,
            .bestResolution
        ) else {
            NSLog("[PinTop] captureSnapshot returned NIL — preflight=\(CGPreflightScreenCaptureAccess()) id=\(windowInfo.id)")
            return nil
        }
        guard let downsampled = Self.downsample(rawImage) else { return nil }
        let captureStats = Self.computeStats(downsampled)
        let decision = Self.correctorDecision(
            anchor: context.anchor,
            activeFit: context.activeFit,
            pendingFit: context.pendingFit,
            lastCapture: context.lastCapture,
            freezeStreak: context.freezeStreak,
            capture: downsampled,
            captureStats: captureStats
        )

        // Use the EXACT backing scale of the display hosting the window.
        // Deriving it as pixels/points of the (often fractional) window rect
        // leaves the NSImage with a fractional dpi — every later draw then
        // resamples the whole bitmap by a fraction of a percent, which
        // softens all text. A whole-number dpi lets the view draw 1:1.
        let displayScale = Self.backingScale(for: windowInfo.bounds)
        var displayImage: CGImage?
        switch decision {
        case .flow(let fit), .adopt(let fit):
            displayImage = Self.applyCorrection(fit, to: rawImage) ?? rawImage
        case .reanchor:
            displayImage = rawImage
        case .freeze:
            displayImage = nil
        }
        let image = displayImage.map {
            // No edge crop: the capture's 1px window stroke stays in the
            // bitmap and the bitmap fills the overlay edge to edge.
            NSImage(
                cgImage: $0,
                size: CGSize(width: CGFloat($0.width) / displayScale, height: CGFloat($0.height) / displayScale)
            )
        }
        return ProcessedCapture(image: image, stats: captureStats, decision: decision)
    }

    /// Raw snapshot for the initial pin (main thread, once per pin).
    private func captureRawSnapshot(of windowInfo: WindowInfo) -> (image: NSImage, stats: AppearanceStats)? {
        let captureRect = CGRect(
            x: windowInfo.bounds.minX.rounded(),
            y: windowInfo.bounds.minY.rounded(),
            width: windowInfo.bounds.width.rounded(),
            height: windowInfo.bounds.height.rounded()
        )
        guard let rawImage = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            windowInfo.id,
            .bestResolution
        ) else {
            NSLog("[PinTop] initial capture NIL — preflight=\(CGPreflightScreenCaptureAccess()) id=\(windowInfo.id)")
            return nil
        }
        guard let downsampled = Self.downsample(rawImage) else { return nil }
        let displayScale = Self.backingScale(for: windowInfo.bounds)
        return (
            NSImage(
                cgImage: rawImage,
                size: CGSize(width: CGFloat(rawImage.width) / displayScale, height: CGFloat(rawImage.height) / displayScale)
            ),
            Self.computeStats(downsampled)
        )
    }

    // MARK: Measured appearance correction

    /// The heart of the color-stability fix. Classifies one capture against
    /// the corrector state (pure function — unit-tested without windows):
    ///
    ///  1. Adjacent-frame gate (raw→raw): static content under a tone
    ///     shift moves every luma cell by the same amount; content edits
    ///     don't. Non-uniform → .flow (content, keep current correction).
    ///  2. At or above the anchor (not dimmer, not desaturated): the window
    ///     is in its target/active state — display raw and RE-SYNC the
    ///     anchor to actual pixel stats (mappedStats is only an
    ///     approximation; this is where drift is discarded). Also the
    ///     ratchet: a window brightened past the anchor (focus regained)
    ///     becomes the new anchor, and a pin created while dimmed
    ///     self-heals on first focus.
    ///  3. No change since the previous capture: if a candidate fit is
    ///     pending, this frame confirms it (the appearance reached a
    ///     stable state); otherwise flow with the current correction.
    ///     Re-fitting in steady state is deliberately avoided — the
    ///     two-stage fit is not a fixed point under anchor remapping and
    ///     would oscillate between slightly different corrections.
    ///  4. Near-solid frame (video black) → .flow; a bias-only "fit" would
    ///     repaint it at the anchor's brightness.
    ///  5. Dimmed vs anchor → fit the inverse (measureCorrection). Stable
    ///     across two captures → .adopt; still moving (animation, video
    ///     fade) → .freeze on the current bitmap until it settles.
    static func correctorDecision(
        anchor: AppearanceStats,
        activeFit: AppearanceCorrection,
        pendingFit: AppearanceCorrection?,
        lastCapture: AppearanceStats,
        freezeStreak: Int,
        capture: DownsampledBitmap,
        captureStats: AppearanceStats
    ) -> AppearanceDecision {
        // A resize changed the grid — stats aren't comparable; flow with the
        // current correction and let a later brighten re-anchor.
        let shift = adjacentShift(from: lastCapture, to: captureStats)
        guard shift.uniform else {
            return .flow(activeFit)
        }

        // Not dimmer and not desaturated vs the anchor → at target state.
        let dimmerLuma = captureStats.lumaMedian < anchor.lumaMedian - 0.02
        let dimmerChroma = captureStats.chromaMean < anchor.chromaMean * 0.85 - 0.004
        if !dimmerLuma, !dimmerChroma {
            return .reanchor(captureStats)
        }

        // Static appearance since the previous capture. Resolve any pending
        // candidate (this is the confirmation frame), else nothing to do.
        if abs(shift.lumaDelta) < 0.012, shift.chromaRatio <= 1.15 {
            if let pending = pendingFit {
                if let refit = measureCorrection(active: anchor, inactive: capture),
                   correctionsMatch(pending, refit) {
                    return .adopt(refit)
                }
                return .freeze(candidate: pending)
            }
            return .flow(activeFit)
        }

        if max(captureStats.channelSpread.x, captureStats.channelSpread.y, captureStats.channelSpread.z) < 0.015 {
            return .flow(activeFit)
        }

        guard let fit = measureCorrection(active: anchor, inactive: capture) else {
            // Adjacent-static but the content drifted from the anchor's
            // content (anchor cells no longer match) — keep correcting with
            // the confirmed transform instead of fitting against a stale
            // reference.
            return .flow(activeFit)
        }
        if correctionsMatch(fit, activeFit) {
            return .flow(fit)
        }
        if let pending = pendingFit, correctionsMatch(pending, fit) {
            return .adopt(fit)
        }
        if freezeStreak >= AppearanceConstants.maxFreezeStreak {
            // Churn — every capture fits a different transform (video fade).
            // Don't freeze the pin forever; flow with what we have.
            return .flow(activeFit)
        }
        return .freeze(candidate: fit)
    }

    /// Comparison of consecutive raw captures: is the frame-to-frame delta
    /// a spatially-uniform tone shift (appearance change over static
    /// content), and if so by how much? Trimmed stats ignore a blinking
    /// caret or a moved cursor occupying a few cells.
    struct AdjacentShift: Equatable {
        let uniform: Bool
        /// Trimmed mean of per-cell luma deltas (previous − current), 0...1:
        /// positive = the window got darker since the previous capture.
        let lumaDelta: Float
        /// previous.chroma / current.chroma: > 1 = desaturating.
        let chromaRatio: Float
    }

    static func adjacentShift(from previous: AppearanceStats, to current: AppearanceStats) -> AdjacentShift {
        guard previous.cellsX == current.cellsX, previous.cellsY == current.cellsY,
              !previous.cellLuma.isEmpty, previous.cellLuma.count == current.cellLuma.count
        else { return AdjacentShift(uniform: false, lumaDelta: 0, chromaRatio: 1) }
        let deltas = zip(previous.cellLuma, current.cellLuma).map { $0 - $1 }
        let (mean, std) = trimmedMeanStd(deltas)
        let ratio = current.chromaMean > 0.004 ? previous.chromaMean / current.chromaMean : 1
        return AdjacentShift(
            uniform: std <= max(0.02, 0.33 * abs(mean)),
            lumaDelta: mean,
            chromaRatio: ratio
        )
    }

    /// Anchor bookkeeping after adopting a fit: the anchor must keep
    /// describing the CURRENT content at the TARGET (active) appearance —
    /// mapped through the correction the same way applyCorrection maps
    /// pixels — or future fits would gate against stale content.
    static func mappedStats(_ stats: AppearanceStats, through fit: AppearanceCorrection) -> AppearanceStats {
        var out = stats
        let luma = stats.lumaMedian
        // Saturation stage: channels move away from luma by the factor;
        // luma itself is invariant under lerp-toward-luma.
        for channel in 0..<3 {
            out.channelMedian[channel] = luma + fit.saturation * (stats.channelMedian[channel] - luma)
            out.channelSpread[channel] = fit.saturation * stats.channelSpread[channel]
        }
        // Affine stage.
        let averageScale = (fit.channelScale.x + fit.channelScale.y + fit.channelScale.z) / 3
        for channel in 0..<3 {
            out.channelMedian[channel] = fit.channelScale[channel] * out.channelMedian[channel] + fit.channelBias[channel]
            out.channelSpread[channel] = fit.channelScale[channel] * out.channelSpread[channel]
        }
        out.chromaMean = stats.chromaMean * fit.saturation * averageScale
        out.lumaMedian = 0.2126 * out.channelMedian.x + 0.7152 * out.channelMedian.y + 0.0722 * out.channelMedian.z
        // Scalar cell luma: unchanged by the saturation stage (luma is
        // invariant), shifted/stretched by the affine stage.
        out.cellLuma = stats.cellLuma.map {
            $0 + (out.lumaMedian - stats.lumaMedian) + (averageScale - 1) * ($0 - stats.lumaMedian)
        }
        return out
    }

    /// Fit the inverse of this window's dimming: a saturation factor to
    /// undo lerp-toward-gray, then a per-channel affine (scale+bias)
    /// matching the boosted dimmed stats onto the anchor ones. Returns nil
    /// when the frames aren't comparable (grid mismatch, or non-uniform
    /// deltas meaning content changed vs the anchor). Returns identity
    /// when there is no dimming to invert.
    static func measureCorrection(active: AppearanceStats, inactive inactiveBitmap: DownsampledBitmap) -> AppearanceCorrection? {
        let inactive = computeStats(inactiveBitmap)
        guard adjacentShift(from: active, to: inactive).uniform
        else { return nil }

        let chromaRatio = inactive.chromaMean > 0.004 ? active.chromaMean / inactive.chromaMean : 1
        let deltas = zip(active.cellLuma, inactive.cellLuma).map { $0 - $1 }
        let (deltaMean, _) = trimmedMeanStd(deltas)
        if abs(deltaMean) < 0.012, chromaRatio <= 1.15 {
            return AppearanceCorrection() // no dimming to invert
        }

        var correction = AppearanceCorrection()
        correction.saturation = chromaRatio > 1.15 ? min(6, chromaRatio) : 1

        // Fit the affine on the PREDICTED saturation-boosted pixels — the
        // same operation applyCorrection runs first — so both stages
        // compose into one transform landing on the active stats.
        let count = inactiveBitmap.width * inactiveBitmap.height
        var boostedR = [Float](); boostedR.reserveCapacity(count)
        var boostedG = [Float](); boostedG.reserveCapacity(count)
        var boostedB = [Float](); boostedB.reserveCapacity(count)
        for offset in stride(from: 0, to: inactiveBitmap.rgba.count, by: 4) {
            var r = Float(inactiveBitmap.rgba[offset]) / 255
            var g = Float(inactiveBitmap.rgba[offset + 1]) / 255
            var b = Float(inactiveBitmap.rgba[offset + 2]) / 255
            if correction.saturation != 1 {
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r = min(max(luma + correction.saturation * (r - luma), 0), 1)
                g = min(max(luma + correction.saturation * (g - luma), 0), 1)
                b = min(max(luma + correction.saturation * (b - luma), 0), 1)
            }
            boostedR.append(r)
            boostedG.append(g)
            boostedB.append(b)
        }
        let boosted = [boostedR, boostedG, boostedB]
        for channel in 0..<3 {
            let median = median(of: boosted[channel])
            let spread = robustSpread(of: boosted[channel], around: median)
            var scale: Float = 1
            if spread > 0.01, active.channelSpread[channel] > 0.01 {
                scale = min(4, max(0.6, active.channelSpread[channel] / spread))
                if abs(scale - 1) < 0.03 { scale = 1 }
            }
            correction.channelScale[channel] = scale
            correction.channelBias[channel] = active.channelMedian[channel] - scale * median
        }
        return correction
    }

    /// Apply a measured correction directly on an sRGB RGBA8 bitmap — no
    /// CIFilter color-space ambiguity between how the transform was measured
    /// (sRGB stats) and how it is applied. Runs on captureQueue at idle
    /// cadence; a full Retina window is a few ms of float math.
    static func applyCorrection(_ correction: AppearanceCorrection, to image: CGImage) -> CGImage? {
        if correction.isIdentity { return image }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let saturation = correction.saturation
        let scale = correction.channelScale
        let bias = correction.channelBias
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            var r = Float(pixels[offset])
            var g = Float(pixels[offset + 1])
            var b = Float(pixels[offset + 2])
            if saturation != 1 {
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r = luma + saturation * (r - luma)
                g = luma + saturation * (g - luma)
                b = luma + saturation * (b - luma)
            }
            r = scale.x * r + bias.x * 255
            g = scale.y * g + bias.y * 255
            b = scale.z * b + bias.z * 255
            pixels[offset] = UInt8(min(255, max(0, r)))
            pixels[offset + 1] = UInt8(min(255, max(0, g)))
            pixels[offset + 2] = UInt8(min(255, max(0, b)))
        }
        return context.makeImage()
    }

    /// ≤96px RGBA8 copy for statistics. Small enough that median/MAD over
    /// all pixels is microseconds; large enough that text and chrome still
    /// influence the stats at realistic proportions.
    static func downsample(_ image: CGImage) -> DownsampledBitmap? {
        let maxDimension = 96
        let w0 = image.width, h0 = image.height
        guard w0 > 0, h0 > 0 else { return nil }
        var width = min(maxDimension, w0)
        var height = max(1, Int((CGFloat(width) * CGFloat(h0) / CGFloat(w0)).rounded()))
        if height > maxDimension {
            height = maxDimension
            width = max(1, Int((CGFloat(height) * CGFloat(w0) / CGFloat(h0)).rounded()))
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let data = context.data else { return nil }
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        return DownsampledBitmap(
            width: width,
            height: height,
            rgba: Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
        )
    }

    static func computeStats(_ bitmap: DownsampledBitmap) -> AppearanceStats {
        var stats = AppearanceStats()
        let cellsX = min(12, bitmap.width)
        let cellsY = min(12, bitmap.height)
        var cellBuckets = [[Float]](repeating: [], count: cellsX * cellsY)
        let pixelCount = bitmap.width * bitmap.height
        var reds = [Float](); reds.reserveCapacity(pixelCount)
        var greens = [Float](); greens.reserveCapacity(pixelCount)
        var blues = [Float](); blues.reserveCapacity(pixelCount)
        var chromaSum: Float = 0

        for y in 0..<bitmap.height {
            let cellY = min(cellsY - 1, y * cellsY / bitmap.height)
            for x in 0..<bitmap.width {
                let cellX = min(cellsX - 1, x * cellsX / bitmap.width)
                let offset = (y * bitmap.width + x) * 4
                let r = Float(bitmap.rgba[offset]) / 255
                let g = Float(bitmap.rgba[offset + 1]) / 255
                let b = Float(bitmap.rgba[offset + 2]) / 255
                reds.append(r)
                greens.append(g)
                blues.append(b)
                chromaSum += max(r, g, b) - min(r, g, b)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                cellBuckets[cellY * cellsX + cellX].append(luma)
            }
        }

        let channels = [reds, greens, blues]
        for channel in 0..<3 {
            let median = median(of: channels[channel])
            stats.channelMedian[channel] = median
            stats.channelSpread[channel] = robustSpread(of: channels[channel], around: median)
        }
        stats.chromaMean = pixelCount > 0 ? chromaSum / Float(pixelCount) : 0
        stats.cellLuma = cellBuckets.map { median(of: $0) }
        stats.lumaMedian = median(of: stats.cellLuma)
        stats.cellsX = cellsX
        stats.cellsY = cellsY
        return stats
    }

    /// Whether two measured corrections are close enough to count as the
    /// same transform — the confirmation step that guards against measuring
    /// mid-animation (a half-faded frame yields a systematically weaker
    /// correction than the settled one two ticks later).
    static func correctionsMatch(_ a: AppearanceCorrection, _ b: AppearanceCorrection) -> Bool {
        abs(a.saturation - b.saturation) <= 0.3
            && abs(a.channelScale.x - b.channelScale.x) <= 0.15
            && abs(a.channelScale.y - b.channelScale.y) <= 0.15
            && abs(a.channelScale.z - b.channelScale.z) <= 0.15
            && abs(a.channelBias.x - b.channelBias.x) <= 0.05
            && abs(a.channelBias.y - b.channelBias.y) <= 0.05
            && abs(a.channelBias.z - b.channelBias.z) <= 0.05
    }

    private static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// MAD × 1.4826 — a standard deviation estimate that ignores outliers
    /// (a blinking caret or moved cursor between captures must not skew the
    /// fitted transform).
    private static func robustSpread(of values: [Float], around center: Float) -> Float {
        1.4826 * median(of: values.map { abs($0 - center) })
    }

    /// Mean and std with the outer 10% trimmed from each side.
    private static func trimmedMeanStd(_ values: [Float]) -> (mean: Float, std: Float) {
        guard values.count >= 4 else { return (0, 0) }
        let sorted = values.sorted()
        let trim = sorted.count / 10
        let kept = Array(sorted[trim ..< sorted.count - trim])
        let mean = kept.reduce(0, +) / Float(kept.count)
        let variance = kept.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(kept.count)
        return (mean, variance.squareRoot())
    }

    private static func backingScale(for rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for id in ids.prefix(Int(count)) where CGDisplayBounds(id).contains(center) {
            guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
            return (CGFloat(mode.pixelWidth) / CGDisplayBounds(id).width).rounded()
        }
        return 2
    }

    // MARK: - Pin / Unpin

    func pin(_ window: WindowInfo) {
        guard !pinnedWindows.contains(window) else { return }

        // Capture initial snapshot. A nil result reliably means Screen
        // Recording permission is missing on macOS 10.15+ — surface the
        // prompt, but only once per session so the user isn't badgered.
        guard let captured = captureRawSnapshot(of: window) else {
            if !hasPromptedScreenCaptureThisSession {
                hasPromptedScreenCaptureThisSession = true
                requestScreenCapturePermission()
                showScreenCapturePermissionAlert()
            }
            return
        }
        // Seed the appearance corrector: the anchor is whatever the window
        // looks like right now (ideally its active state). If the window
        // was dimmed at pin time, the first focus regained brightens past
        // this anchor and re-anchors — the pin self-heals.
        anchorStats[window.id] = captured.stats
        lastCaptureStats[window.id] = captured.stats
        activeFit[window.id] = AppearanceCorrection()
        pendingFit[window.id] = nil
        freezeStreaks[window.id] = 0

        pinnedWindows.insert(window)

        // If an overlay for this id somehow survives (e.g. state left by an
        // older build), retire it before installing the new one — replacing
        // the dict entry alone would strand the old window on screen, where
        // it keeps absorbing clicks until the app restarts.
        overlays[window.id]?.orderOut(nil)

        // Create overlay window
        let overlay = PinOverlayWindow(
            frame: appKitFrame(for: window.bounds),
            snapshot: captured.image,
            windowID: window.id,
            pid: window.pid
        )
        // orderFrontRegardless, not orderFront: PinTop is a background app,
        // and ordering front from a NON-active application is only advisory —
        // AppKit warns the window "may order beneath the active application's
        // windows". Every click on another app makes that app active, so a
        // plain orderFront lets the system demote the pin under the covering
        // window on each app switch — visible as the pin "blinking" between
        // floating and sunk. orderFrontRegardless is the documented way to
        // put a floating window above the active app's windows.
        overlay.orderFrontRegardless()
        overlays[window.id] = overlay
        // Seed bounds tracking with the frame just applied so the first
        // refresh tick can already tell a move apart from a resize.
        lastAppliedBounds[window.id] = window.bounds
    }

    func unpin(_ window: WindowInfo) {
        // Detach from dictionaries first so the 60Hz timer can't touch the
        // overlay. orderOut only — no close() — keeps the NSWindow alive but
        // hidden, avoiding the auto-termination "last window closed" hook.
        let overlay = overlays.removeValue(forKey: window.id)
        pinnedWindows.remove(window)
        clearTrackingState(for: window.id)
        overlay?.orderOut(nil)
        // Also retire any untracked overlay for the same window — an orphan
        // stranded by a double-pin in an older build would otherwise keep
        // swallowing clicks in its frame after this unpin (#5).
        for case let stray as PinOverlayWindow in NSApp.windows where stray.windowID == window.id {
            stray.orderOut(nil)
        }
    }

    func unpinAll() {
        // ponytail: orderOut only, no close(). NSWindow.close() decrements the
        // app's window count; LSUIElement + auto-terminate hook was treating
        // the last overlay close as "last window closed → quit". orderOut
        // keeps the window alive (just hidden), so the status item stays
        // resident and the app survives.
        let snapshot = Array(overlays.values)
        overlays.removeAll()
        pinnedWindows.removeAll()
        lastAppliedBounds.removeAll()
        lastRecaptureTime.removeAll()
        lastResizeRecaptureTime.removeAll()
        lastBoundsChangeTime.removeAll()
        hiddenOverlays.removeAll()
        lastOcclusionScanTime.removeAll()
        lastOcclusionResult.removeAll()
        lastOcclusionExposed.removeAll()
        lastOcclusionReason.removeAll()
        offScreenStreaks.removeAll()
        windowMissStreaks.removeAll()
        anchorStats.removeAll()
        activeFit.removeAll()
        pendingFit.removeAll()
        lastCaptureStats.removeAll()
        freezeStreaks.removeAll()
        for overlay in snapshot {
            overlay.orderOut(nil)
        }
        // Sweep any overlay windows no longer tracked in `overlays` — e.g.
        // orphans stranded by double-pinning in older builds. They sit at
        // pin level and swallow every click in their frame, which read as
        // "picker dead until restart" (#5). orderOut (not close) on purpose.
        for case let overlay as PinOverlayWindow in NSApp.windows {
            overlay.orderOut(nil)
        }
    }

    private func clearTrackingState(for windowID: CGWindowID) {
        lastAppliedBounds.removeValue(forKey: windowID)
        lastRecaptureTime.removeValue(forKey: windowID)
        lastResizeRecaptureTime.removeValue(forKey: windowID)
        lastBoundsChangeTime.removeValue(forKey: windowID)
        hiddenOverlays.remove(windowID)
        lastOcclusionScanTime.removeValue(forKey: windowID)
        lastOcclusionResult.removeValue(forKey: windowID)
        lastOcclusionExposed.removeValue(forKey: windowID)
        lastOcclusionReason.removeValue(forKey: windowID)
        offScreenStreaks.removeValue(forKey: windowID)
        windowMissStreaks.removeValue(forKey: windowID)
        anchorStats.removeValue(forKey: windowID)
        activeFit.removeValue(forKey: windowID)
        pendingFit.removeValue(forKey: windowID)
        lastCaptureStats.removeValue(forKey: windowID)
        freezeStreaks.removeValue(forKey: windowID)
    }

    // MARK: - Accessibility

    func requestScreenCapturePermission() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: - Refresh Timer (snapshot live update + stale cleanup)

    private func startRefreshTimer() {
        // ~60 Hz so move/resize feel like they're glued to the source window.
        // Each tick only looks up the specific pinned windows by ID (cheap);
        // the expensive full-screen CGWindowListCreateImage run only fires
        // when the window's bounds changed or the idle fallback interval lapses.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            // CGWindowListCopyWindowInfo / CGWindowListCreateImage autoreleased
            // CoreFoundation intermediates can pile up in AppKit's runloop
            // pool if we drain them lazily. Wrap each tick in its own pool so
            // they're released at tick end, before any tear-down could race
            // the runloop's outer pool. This stops the SIGSEGV at
            // _CFAutoreleasePoolPop where a stale CG object was being
            // released against state we'd already moved on from.
            autoreleasepool {
                self?.refreshOverlays()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func refreshOverlays() {
        guard !pinnedWindows.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate

        // O(1) burial proxy: if the source window's owner app isn't the
        // frontmost app, some other app's window is covering it → absorb the
        // next click so we can re-front the source instead of letting the
        // click fall through to the covering app (the reported bug). We avoid
        // enumerating all onscreen windows every tick — the original loop went
        // out of its way to use a cheap per-window lookup for exactly this
        // reason; a full scan at 60Hz made the click→front path feel delayed.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Iterate over a copy: removing from a Set while iterating it can crash.
        // Probe the system-overview state once per scan window, not per pin.
        // Open on the FIRST high sample (hide fast); require three
        // consecutive low samples to close (mid-overview redraws dip low
        // momentarily — re-showing on one would blink during the overview).
        if (now - lastOverviewProbeTime) >= overviewProbeInterval {
            lastOverviewProbeTime = now
            if systemOverviewProbe() {
                overviewCloseStreak = 0
                systemOverviewActive = true
            } else if systemOverviewActive {
                overviewCloseStreak += 1
                if overviewCloseStreak >= overviewCloseDebounce {
                    systemOverviewActive = false
                    overviewCloseStreak = 0
                }
            }
        }
        for window in Array(pinnedWindows) {
            guard let overlay = overlays[window.id] else {
                pinnedWindows.remove(window)
                clearTrackingState(for: window.id)
                continue
            }

            // Cheap single-window lookup instead of enumerating everything.
            guard let currentWindow = windowByID(window.id) else {
                // A single nil lookup can be a transient glitch (Space switch,
                // Mission Control); only treat the window as closed after a
                // sustained absence, or the pin silently vanishes.
                let misses = (windowMissStreaks[window.id] ?? 0) + 1
                windowMissStreaks[window.id] = misses
                if misses >= maxWindowMissTicks {
                    // Window was closed — clean up. orderOut instead of close to
                    // avoid decrementing the app's window count (Clear All chain
                    // was triggering auto-termination).
                    overlay.orderOut(nil)
                    overlays.removeValue(forKey: window.id)
                    pinnedWindows.remove(window)
                    clearTrackingState(for: window.id)
                    windowMissStreaks[window.id] = nil
                }
                continue
            }
            windowMissStreaks[window.id] = nil

            // ponytail: overlay visibility tracks whether the real window is
            // actually EXPOSED (top-most over its own bounds), checked with a
            // throttled front-to-back scan. The old frontmost-APP proxy broke
            // twice: clicking the desktop activates Finder without raising the
            // buried pinned window (pin vanished — "always-on-top not
            // working"), and a raised-but-not-focused window got the overlay
            // re-shown over the exposed real window (flash/double image).
            if (now - (lastOcclusionScanTime[window.id] ?? 0)) >= occlusionScanInterval {
                lastOcclusionScanTime[window.id] = now
                var hide: Bool
                var reason: String
                var exposed: Bool
                switch occlusionCheck(currentWindow) {
                case .exposed:
                    offScreenStreaks[window.id] = 0
                    hide = false
                    exposed = true
                    reason = "top of stack"
                case .covered(let why):
                    offScreenStreaks[window.id] = 0
                    hide = false
                    exposed = false
                    reason = why
                case .offScreen:
                    let streak = (offScreenStreaks[window.id] ?? 0) + 1
                    offScreenStreaks[window.id] = streak
                    hide = streak >= 3 // ~0.6s sustained — ride out Space transitions
                    exposed = false
                    reason = "off-screen streak=\(streak)"
                }
                // An exposure flip means the source was just raised or
                // buried — its ACTIVE/INACTIVE rendering changed with it.
                // Force the next recapture so the overlay matches.
                let prevExposed = lastOcclusionExposed[window.id]
                if prevExposed != nil && prevExposed != exposed {
                    lastRecaptureTime[window.id] = 0
                }
                lastOcclusionResult[window.id] = hide
                lastOcclusionExposed[window.id] = exposed
                lastOcclusionReason[window.id] = reason
            }
    // ponytail: overlay visibility now only tracks whether the source is
    // on-screen AT ALL. The exposed/covered distinction no longer hides the
    // overlay — every covered↔exposed flip used to orderOut/orderFront the
    // pin, and each flip is visible (snapshot↔real swap: shadow redraw,
    // tint, edge), so clicking behind (or on) the pin blinked it. The pin
    // is "always on top": it stays put, pixel-aligned over the real window
    // when exposed (identical bitmap — no double image) and floating above
    // covers when buried. Only clicks change behavior with exposure.
    // EXCEPTION: while Mission Control / App Exposé is up, the overlay
    // hides — it would otherwise float ABOVE the system overview, showing
    // a full-size frozen copy over the shrunken real window.
    let offScreenNow = lastOcclusionResult[window.id] ?? false
    if offScreenNow || systemOverviewActive {
        if !hiddenOverlays.contains(window.id) {
            overlay.orderOut(nil)
            hiddenOverlays.insert(window.id)
        }
        continue
    } else if hiddenOverlays.contains(window.id) {
        overlay.orderFrontRegardless()
        hiddenOverlays.remove(window.id)
        lastRecaptureTime[window.id] = 0 // force immediate recapture
    }

    // Re-assert ordering when another app activates: the system
    // re-evaluates stacking on every app switch and may demote an
    // inactive app's window below the newly active app's windows.
    // Handled via NSWorkspace.didActivateApplicationNotification
    // (see startAppSwitchObserver) — event-driven, not polled.

    // Click handling DOES follow exposure: pass clicks through to the real
    // window while it's top over its own bounds (normal interaction —
    // focus, drag, type), absorb them to re-front the source only when
    // it's buried under another window.
    let exposedNow = lastOcclusionExposed[window.id] ?? true
    overlay.setAbsorbsClicks(!exposedNow)

            let prevBounds = lastAppliedBounds[window.id]
        let boundsChanged = prevBounds != currentWindow.bounds
        // Distinguish move from resize: on a move the content bitmap is
        // identical, so we never need to recapture — just reposition the
        // overlay. Resizing changes content layout, so we recapture there.
        let sizeChanged = boundsChanged && prevBounds != nil && currentWindow.bounds.size != prevBounds!.size
        let activeUse = (frontmostPID == currentWindow.pid) && (lastOcclusionExposed[window.id] ?? false)
        let recaptureInterval = activeUse ? activeUseRecaptureInterval : idleRecaptureInterval
        let prevIdleRecapture = lastRecaptureTime[window.id] ?? 0
        let idleRecaptureDue = (now - prevIdleRecapture) >= recaptureInterval

        // Skip everything if nothing changed and we're not due for an
        // idle refresh — keeps the main loop nearly free for an idle pin.
        guard boundsChanged || idleRecaptureDue else { continue }

        let prevResizeRecapture = lastResizeRecaptureTime[window.id] ?? 0
        let resizeRecaptureDue = (now - prevResizeRecapture) >= resizeRecaptureInterval
        let lastChange = lastBoundsChangeTime[window.id] ?? 0
        // Trigger a crisp recapture shortly after a resize stops so we don't
        // leave a stretched bitmap at the final size.
        let settleRecaptureDue = !boundsChanged && lastChange > 0 && (now - lastChange) < settleRecaptureDelay && (now - prevResizeRecapture) >= resizeRecaptureInterval

        if boundsChanged {
            let newFrame = appKitFrame(for: currentWindow.bounds)
            if sizeChanged {
                // Resize: redraw synchronously at the new size. With
                // display:false the resized backing store stayed unflushed and
                // the window server kept compositing stale intermediate
                // surfaces — the stuck full-opacity frames of issue #6.
                overlay.setFrame(newFrame, display: true)
            } else {
                // Pure move: setFrameOrigin translates the window's surface
                // inside the window server without touching the backing store,
                // so there is no lazily-unpainted region to leave behind along
                // the movement path (issue #6). Also cheaper than setFrame,
                // which keeps 60Hz move tracking smooth.
                overlay.setFrameOrigin(newFrame.origin)
            }
            lastAppliedBounds[window.id] = currentWindow.bounds
            if sizeChanged {
                lastBoundsChangeTime[window.id] = now
            }
        }

        // Recapture decision:
        //  - move (size unchanged): NEVER recapture — bitmap is already valid
        //  - idle pinned window: every idleRecaptureInterval (~5×/sec) so
        //    live content (typing, video) keeps updating
        //  - actively resizing: every resizeRecaptureInterval (~12×/sec) so
        //    the stretched-between-captures bitmap never accumulates visible
        //    aspect distortion; captures are off-main, the cost is fine
        //  - just stopped resizing: one final crisp recapture
        // ponytail: suppress idle recapture while bounds are actively changing.
        // Content is identical on a move, so the existing bitmap is still valid —
        // a mid-move bitmap swap only flickers. Idle refresh resumes once stationary.
        let idleRecaptureActive = idleRecaptureDue && !boundsChanged
        let shouldRecapture = idleRecaptureActive || (sizeChanged && resizeRecaptureDue) || settleRecaptureDue
        if shouldRecapture {
            // Stamp recapture time NOW so we don't queue back-to-back captures
            // for the same window if the capture itself takes a while.
            lastRecaptureTime[window.id] = now
            lastResizeRecaptureTime[window.id] = now
            if settleRecaptureDue {
                lastBoundsChangeTime[window.id] = 0
            }
            // Snapshot the corrector state for this capture; pin() seeds it,
            // so the fallbacks only matter for state left by older builds.
            let context = AppearanceContext(
                anchor: anchorStats[window.id] ?? lastCaptureStats[window.id] ?? AppearanceStats(),
                activeFit: activeFit[window.id] ?? AppearanceCorrection(),
                pendingFit: pendingFit[window.id],
                lastCapture: lastCaptureStats[window.id] ?? anchorStats[window.id] ?? AppearanceStats(),
                freezeStreak: freezeStreaks[window.id] ?? 0
            )
            let wid = window.id
            let overlayRef = overlay
            // Off-main capture. Snapshot is read-only against the source's
            // CGWindowID, so it's safe to run on a background queue. The
            // bitmap apply hops back to main, where NSImageView lives.
            captureQueue.async { [weak self] in
                guard let processed = self?.processCapture(of: currentWindow, context: context) else { return }
                DispatchQueue.main.async { [weak self] in
                    // Bail if the pin was released while we were capturing.
                    guard let self, self.overlays[wid] === overlayRef else { return }
                    self.lastCaptureStats[wid] = processed.stats
                    switch processed.decision {
                    case .flow:
                        self.pendingFit[wid] = nil
                        self.freezeStreaks[wid] = 0
                    case .adopt(let fit):
                        self.activeFit[wid] = fit
                        // Keep the anchor describing current content at the
                        // target appearance (see mappedStats).
                        self.anchorStats[wid] = Self.mappedStats(processed.stats, through: fit)
                        self.pendingFit[wid] = nil
                        self.freezeStreaks[wid] = 0
                    case .reanchor(let stats):
                        self.anchorStats[wid] = stats
                        self.activeFit[wid] = AppearanceCorrection()
                        self.pendingFit[wid] = nil
                        self.freezeStreaks[wid] = 0
                    case .freeze(let candidate):
                        self.pendingFit[wid] = candidate
                        self.freezeStreaks[wid] = (self.freezeStreaks[wid] ?? 0) + 1
                        return // keep displaying the current bitmap
                    }
                    if let image = processed.image {
                        overlayRef.updateSnapshot(image)
                    }
                }
            }
        }
        }
    }

    // Mission Control / App Exposé detection — see the measured signature on
    // the systemOverviewActive property above.
    private func systemOverviewProbe() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        var dockCount = 0
        for dict in list {
            if (dict[kCGWindowOwnerName as String] as? String) == "Dock" {
                dockCount += 1
            }
        }
        return dockCount >= 8
    }

    // Occlusion tri-state for a pinned window:
    //  - .exposed: it's the top-most window over its own bounds → clicks
    //    pass through the overlay to the real window.
    //  - covered: another on-screen window draws over it (same Space) → the
    //    overlay floats the mirror on top and absorbs clicks (re-fronting
    //    the source). This is the core pin feature.
    //  - offScreen: not in the on-screen list at all — different Space (e.g.
    //    a fullscreen app active), minimized, or mid-transition. Floating a
    //    frozen snapshot over an unrelated Space reads as a ghost, so the
    //    overlay hides; it reappears when the window's Space returns.
    private enum OcclusionState {
        case exposed
        case covered(reason: String)
        case offScreen
    }

    private func occlusionCheck(_ window: WindowInfo) -> OcclusionState {
        for candidate in enumerateWindows() {
            guard candidate.bounds.intersects(window.bounds) else { continue }
            if candidate.id == window.id { return .exposed }
            return .covered(reason: "under [\(candidate.id)] \(candidate.ownerName) '\(candidate.name)'")
        }
        return .offScreen
    }

    // CGWindow bounds use a top-left global origin; AppKit windows use bottom-left.
    private func appKitFrame(for quartzFrame: CGRect) -> CGRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = CGRect(
            x: quartzFrame.minX,
            y: mainDisplayHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        // Pixel-align: CG window bounds are often fractional (half-point
        // window positions), and rendering the snapshot at a subpixel offset
        // softens text and smears the window's 1px edge stroke into a
        // hairline. Snap to whole points.
        return CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    private func showScreenCapturePermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is required"
        // If the app was rebuilt with a new code signature, the old TCC grant
        // no longer applies even though PinTop may still appear checked in
        // System Settings. Removing and re-adding is the only fix.
        let preflight = CGPreflightScreenCaptureAccess()
        let alreadyListed = preflight ? " (appears granted but invalid after rebuild — remove & re-add)" : ""
        alert.informativeText = "Allow Pin Top in System Settings > Privacy & Security > Screen Recording\(alreadyListed), then quit and reopen Pin Top."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
