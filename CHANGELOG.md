# Changelog

All notable changes to **Pin Top** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Global hotkey to toggle pin mode
- Per-window live refresh
- Multi-monitor / Space awareness
- Sparkle-based auto-update

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