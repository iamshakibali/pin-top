# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Development: build debug binary, bundle into PinTop.app in place, sign, and open
./run.sh

# Release build: optimized binary, strip, sign, zip to dist/PinTop-<version>.zip
./release.sh

# Raw SwiftPM (usually prefer run.sh)
swift build                 # debug
swift build -c release      # release
```

Run `./setup-signing.sh` once per machine to create a self-signed "Pin Top Local Signing" identity. Without it, macOS resets Screen Recording / Accessibility grants on every rebuild because the ad-hoc signature changes.

## What This Project Is

**Pin Top** is a menu-bar-only (`LSUIElement`) macOS app that pins any window to stay always-on-top. It uses **zero third-party dependencies** — pure Swift + AppKit, built with Swift Package Manager (no Xcode project).

### The Window-Pinning Trick

macOS has no public API to change another app's window level. Instead of periodically raising the window (which flickers), Pin Top:
1. Enumerates on-screen windows via `CGWindowListCopyWindowInfo`
2. Captures a live snapshot via `CGWindowListCreateImage`
3. Renders it in a borderless `NSWindow` at level `.statusBar + 1`
4. Refreshes the snapshot ~60×/sec while the source window moves/resizes

## Architecture

```
@main PinTopApp → AppDelegate (menu bar, events)
                → WindowManager (singleton, ObservableObject)
                  → PinOverlayWindow (borderless snapshot overlay)
                  → SelectionOverlayWindow (full-screen picker)
                → AboutWindow
                → AppUpdater (GitHub releases, auto-update)
```

- **`PinTopApp.swift`**: `@main` entry, `NSStatusItem` setup, `AppDelegate`. All menu bar items are `NSMenuItem` wired to `AppDelegate` selectors. The "Quit" item targets `nil` so `terminate(_:)` walks the responder chain to `NSApplication` — setting it to `appDelegate` silently breaks quit.
- **`WindowManager.swift`**: Core engine. `enumerateWindows()` filters to normal-layer windows (`layer == 0`), excludes self. `windowByID(_:)` is a cheap single-window lookup used by the 60Hz refresh loop instead of enumerating everything. Snapshot recapture is throttled: **move** → only reposition overlay; **resize** → recapture every 0.25s; **idle** → recapture every 0.5s.
- **`PinOverlay.swift`**: Borderless overlay with rounded corners matching macOS's ~10pt default. Default `ignoresMouseEvents = true` (passthrough). When the source app is buried under another app, the overlay briefly absorbs the next click, re-fronts the source app, then drops back to passthrough.
- **`SelectionOverlay.swift`**: One full-screen overlay per `NSScreen`, dark tint, crosshair cursor. Click records the CG point (top-left origin), right-click cancels.
- **`AppUpdater.swift`**: Checks GitHub releases API, downloads the `.zip` asset, extracts with `ditto`, replaces the running bundle via a helper shell script, then restarts.

## Critical Quirks

1. **TCC grant persistence**: Screen Recording / Accessibility grants are tied to the bundle path *and* a TCC designator. `run.sh` and `release.sh` **rewrite the Mach-O and Info.plist in place** inside the existing `PinTop.app` bundle instead of deleting and recreating it. Deleting the bundle resets grants on recent macOS.

2. **Auto-termination**: `LSUIElement` apps quit when their last window closes. To keep the menu-bar icon alive: (a) `ProcessInfo.disableAutomaticTermination` at launch, (b) `applicationShouldTerminateAfterLastWindowClosed` returns `false`, (c) **never `close()` an overlay** — always `orderOut(nil)`. `close()` decrements the app's window count and triggers auto-termination.

3. **Never box Swift structs into `representedObject`**: Menu items for pinned windows store only an `NSNumber` (the `CGWindowID`) in `representedObject`. Boxing a struct like `WindowInfo` produces `_SwiftValue` that AppKit releases out-of-order during menu rebuild, causing a `SIGSEGV` at `_CFAutoreleasePoolPop`. Look up the full `WindowInfo` from `WindowManager` at action time.

4. **Capture must be off the main thread**: `CGWindowListCreateImage` on the main runloop blocks the source app's Mach ports, causing freeze/typing lag. The 60Hz timer decides *whether* to recapture on main, then dispatches `captureSnapshot(of:)` to a background `DispatchQueue`, applying the `NSImage` back on main.

5. **Hide overlay when source app is frontmost**: When the source app is frontmost, the real window covers the overlay entirely. Keeping the overlay visible at `.statusBar+1` blocks all mouse/keyboard input to the real window (a past typing-lag regression). Overlays are hidden when frontmost and reappear (with a fresh snapshot) the moment another app covers the source.

6. **Coordinate space conversion**: `CGWindowListCopyWindowInfo` returns bounds in top-left-origin global space. `NSWindow` uses bottom-left-origin. `WindowManager.appKitFrame(for:)` converts using `CGMainDisplayID()` height. This currently only handles the **main display** — multi-monitor support is a known gap.

7. **Autoreleasepool per refresh tick**: The 60Hz loop wraps `refreshOverlays()` in `autoreleasepool { }` because CoreGraphics autoreleased intermediates pile up in AppKit's lazy pool and race stale state on teardown.

## Version & Release

- Version is in `Resources/Info.plist` (`CFBundleShortVersionString`).
- Build number is `CFBundleVersion` in the same file.
- `release.sh` reads the version from the plist and outputs `dist/PinTop-<version>.zip`.

## Required Permissions

- **Screen Recording** — `CGWindowListCreateImage` snapshot capture
- **Accessibility** — `CGWindowListCopyWindowInfo` window enumeration

Both are declared in `Resources/Info.plist` (`NSScreenCaptureUsageDescription`).

## Testing

This project has no unit tests. All testing is manual: build with `./run.sh`, interact with the menu bar, pin/unpin windows, move and resize them, verify input isn't blocked, verify overlays hide when source app is frontmost.
