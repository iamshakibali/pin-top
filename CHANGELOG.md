# Changelog

All notable changes to **Pin Top** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Per-window live refresh
- Multi-monitor / Space awareness
- Migrate from deprecated `CGWindowListCreateImage` to ScreenCaptureKit for forward compatibility with future macOS releases

## [0.3.1] — 2026-08-12

### Fixed
- **Screen Recording permission now survives rebuilds.** The app now ships with
  `setup-signing.sh` to create a persistent self-signed code-signing identity.
  Previously, every `run.sh` rebuild used ad-hoc signing, which invalidated the
  macOS TCC grant — PinTop would still appear checked in System Settings but
  capture would silently fail. The new identity is stable across rebuilds so
  the grant persists.
- **Permission alert explains the real cause.** When capture fails, the alert
  now detects whether PinTop is already listed in Screen Recording settings and
  tells the user to *remove and re-add* it if the grant is stale after a
  signature change.
- **Added debug logging** to the capture path (`NSLog` in `pin()`) so future
  permission issues are diagnosable from Console.app.

### macOS Tahoe (26) Compatibility
- App continues to build and run on macOS 15 (Sequoia) and is forward-compatible
  with macOS 26 (Tahoe). The deprecation warning for `CGWindowListCreateImage`
  is documented; the API remains functional on Tahoe Beta 1. A ScreenCaptureKit
  migration is planned for a future release.

## [0.3.2] — 2026-08-16

### Fixed
- **Menu bar icon unresponsive on click.** The launch cleanup that closes the
  auto-opened SwiftUI Settings window was also closing the status item's own
  `NSStatusBarWindow`. ControlCenter kept rendering the icon, but clicks had no
  target — the app looked frozen. The cleanup now skips status bar windows.

## [0.3.0] — 2026-07-22

### Added
- **About panel** — accessible from the menu bar. Shows app icon, version, developer info ("by Shakib" with GitHub link), and an integrated **Check for Updates** button.
- **In-app auto-update** — checks GitHub Releases for newer versions, downloads the update, and atomically replaces the app bundle. No browser or manual download required.
- Global hotkey to toggle pin mode (planned, moved to next release).

## [0.2.0] — 2026-07-21

### Fixed
- **Typing/interaction lag eliminated (#7).** The overlay now hides entirely when
  the pinned window's app is frontmost (user actively editing). This removes
  `CGWindowListCreateImage` ⟷ text-invalidation contention that caused
  noticeable keystroke delay in Notes, TextEdit, and other live-edit apps.
  The overlay reappears instantly when another app covers the source window,
  with a fresh snapshot so content is never stale.
- Overlay no longer blocks mouse or keyboard input to the real window while
  the user is actively interacting with it.

### Added
- App icon — PinTop.icns wired into the `.app` bundle via `run.sh` and
  `release.sh`. Visible in Finder, Get Info, and the app switcher.
- Icon displayed in README header.

## [0.1.1] — 2026-07-21

Maintenance update over the first beta.

### Fixed
- Clicking a pinned overlay when another app covers it no longer selects the
  covering app. The overlay now detects when the source window is buried and
  re-activates the source app to bring the real window forward, so you can
  interact with the pinned window's contents (buttons, fields) instead of the
  overlapping app underneath.
- Reduced refresh-loop cost: burial detection is now an O(1) frontmost-app
  check instead of a 60 Hz full-window enumeration, so the click-to-front
  response feels immediate.

### Known limitations
- Minor: in a multi-window app, if the source app is already frontmost but a
  **sibling** window of that app covers the pinned one, the click-through
  still falls to that sibling rather than re-fronting the exact pinned window.
  We'll address sibling-window coverage in a follow-up.

## [0.1.0] — 2026-07-17

First public beta.

### Added
- Menu-bar app (LSUIElement): pin icon in the status bar, no Dock icon.
- Click-to-pick window selection with full-screen crosshair overlay.
- True always-on-top via a snapshot overlay placed at maximum window level — nothing can cover it.
- Pin multiple windows at once; each is listed in the menu bar with an **Unpin** submenu action.
- **Clear All** to unpin everything in one click.
- **Quit Pin Top** (⌘Q).
- Screen Recording + Accessibility permission flow.
- `run.sh` for one-command build, sign, and launch.
- `setup-signing.sh` for a stable self-signed signing identity so TCC grants persist across rebuilds.

### Known limitations
- The pinned overlay is a **snapshot**, not a live view — it does not update if the source window changes. Live refresh is planned.
- Selection currently targets the main screen / frontmost Space.
- Codesigning is local (self-signed) for this beta; Gatekeeper may warn on first launch — use right-click **Open**.