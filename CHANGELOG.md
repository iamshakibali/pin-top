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