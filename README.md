# Pin Top

> Pin any window to stay truly always-on-top on macOS.

<b>Pin Top</b> is a lightweight menu-bar app that keeps a chosen window floating above every other app on your screen. Unlike workarounds that periodically "raise" a window (which visibly bumps every few seconds and still gets covered between raises), Pin Top places a live overlay copy of the window at the maximum window level — so nothing can ever cover it.

- **True always-on-top.** An overlay window sits above all other windows; nothing goes on top of it.
- **Menu-bar only.** No Dock icon. Lives in your status bar, out of the way.
- **One click to pin.** Pick any window, it stays pinned. Unpin anytime.
- **Zero dependencies.** Pure Swift + AppKit, built with Swift Package Manager.

> **Status: Beta (v0.1.0).** First public beta. This is an early preview — more features are coming.

---

## How it works

macOS offers no public API to change another app's window level. The common workaround — periodically raising the window — flickers and still lets other windows cover it between raises.

Pin Top takes a different route: it captures the selected window and renders a borderless overlay copy of it at the highest window level available. That overlay can never be covered, giving you genuinely always-on-top behavior without flicker.

Format: text only.

---

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon or Intel
- Permissions: **Screen Recording** (to capture window snapshots) and **Accessibility** (to enumerate windows)

---

## Install

### Option A — Download (recommended)

Grab the latest `PinTop.app.zip` from the [Releases page](https://github.com/iamshakibali/window-pin/releases), unzip, and move `PinTop.app` to your Applications folder.

First launch: right-click → **Open** (macOS Gatekeeper blocks unsigned apps on first run). Approve the **Screen Recording** and **Accessibility** prompts.

### Option B — Build from source

```bash
git clone https://github.com/iamshakibali/window-pin.git
cd window-pin
./run.sh
```

`run.sh` builds the app (debug), signs it, and launches it. For Screen Recording / Accessibility grants to persist across rebuilds, create a stable local signing identity once:

```bash
./setup-signing.sh   # creates a self-signed "Pin Top Local Signing" identity
```

Then rebuild with `./run.sh` — grants stick.

See [BUILD.md](BUILD.md) for more on releases.

---

## Usage

1. Click the **pin icon** in your menu bar.
2. Choose **Enable Pin** (or **Pin Another**).
3. Click the window you want to keep on top.
4. That window now stays above everything.

To unpin: open the menu bar → hover the pinned window → **Unpin**. Or **Clear All** to unpin everything. **Quit Pin Top** (⌘Q) to exit.

---

## Roadmap

This is the first beta — more is planned:

- Global hotkey to toggle pin mode
- Per-window live refresh (currently a snapshot)
- Multi-monitor/workspace awareness
- Menu bar quick-actions and tooltips
- Sparkle-based auto-update

See the [open issues](https://github.com/iamshakibali/window-pin/issues) for what's next.

---

## Project structure

```
Sources/PinTop/
├── PinTopApp.swift        # @main, NSStatusItem menu bar, menu, app lifecycle
├── WindowManager.swift    # Window enumeration, pin/unpin, snapshot capture
├── PinOverlay.swift       # Borderless overlay window holding the pinned snapshot
└── SelectionOverlay.swift # Full-screen crosshair picker for selecting a window
```

No third-party dependencies. SwiftPM only.

---

## Permissions

Pin Top requests two permissions, both required:

- **Screen Recording** — needed to capture snapshots of other windows.
- **Accessibility** — needed to enumerate and identify windows.

These are standard for macOS window tools. Pin Top does not transmit any data — all capture stays local on your machine.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Acknowledgements

Built with AppKit and the CoreGraphics window-list APIs. No external libraries.