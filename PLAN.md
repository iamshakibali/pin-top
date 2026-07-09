# Window Pin — Implementation Plan

## Context
Build a macOS native menu bar app ("Window Pin") that lets users pin windows to stay truly always-on-top by layering a snapshot overlay above all other windows. User requirement: "no window will be able to go top of it."

## Why overlay instead of periodic raise
macOS has no public API to change another app's window level. Periodic raise works but the pinned window visibly "bumps" every 2 seconds and other windows can still cover it between raises. The overlay approach creates our own borderless window showing a screenshot of the pinned content, placed at maximum window level. Nothing can cover it. Smooth, true always-on-top.

## Architecture (9 files)

```
WindowPin/
├── WindowPinApp.swift          # @main entry, NSStatusItem, app lifecycle
├── WindowManager.swift           # Singleton: window enumeration, pin/unpin, overlay management
├── PinOverlay.swift              # NSWindow-based overlay showing snapshot of pinned window
├── SelectionOverlay.swift        # Full-screen crosshair + translucent tint for window picking
├── MenuBuilder.swift             # Status bar menu: Enable Pin, pinned list, Clear All, Quit
├── Info.plist                    # LSUIElement = true (menu-bar-only, no Dock)
├── entitlements.plist            # Accessibility permission (com.apple.security.accessibility)
├── Package.swift                 # Swift Package (no external deps)
└── PLAN.md                       # The project doc
```

## Component Design

### 1. WindowManager.swift (core)
- `WindowInfo: Identifiable` — holds `id: CGWindowID`, `name`, `ownerName`, `pid`, `bounds`, `snapshot: NSImage?`
- `enumerateWindows()` → `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)`, filter `layer == 0`, exclude self
- `selectWindow(at:)` → given a screen point, find the window whose bounds contain it (iterate reverse so topmost wins)
- `captureSnapshot(of:)` → take a CGWindowListCreateImage of just that window's bounds region
- `pin(_:)` → capture snapshot, create PinOverlay, store WindowInfo
- `unpin(_:)` → destroy overlay, remove from set
- `cleanupStale()` → on each enumeration, remove pinned windows whose CGWindowID no longer exists

**Accessibility note**: Needed to launch the picker and to raise the original window briefly so the user sees something happened. The overlay itself uses our own NSWindow at maximum level, covering everything else itself.

**Launch-time behavior**: Immediately check `AXIsProcessTrusted()` and, if not trusted, trigger `AXUISystemPerformAction(kAXAccessConfirmForPromptAction)` so the macOS system dialog appears on first launch. This is the same permission Screen Sharing, Magnet, and Rectangle use.

### 2. PinOverlay.swift
- A `NSWindow` with:
  - `styleMask: .borderless`
  - `level: .statusBar + 1` (above all normal windows)
  - `backgroundColor: .clear`, `isOpaque: false`
  - `ignoresMouseEvents: true` (clicks pass through to underlying windows)
  - `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`
  - `hasShadow: false`
  - Content: an `NSImageView` showing the captured snapshot, sized to match the original window's bounds
- Position at the original window's screen coordinates; update the overlay window's frame if the original window moves
- **Refresh loop**: Every 0.5s, recapture the snapshot and update the image view so live content (typing, scrolling, web page changes) stays current in the overlay

### 3. SelectionOverlay.swift
- A full-screen borderless window covering the active screen (or all screens)
- `level: .statusBar + 1` (above everything the user can interact with)
- `backgroundColor: NSColor.black.withAlphaComponent(0.15)` (subtle dark tint)
- Cursor: `NSCursor.crosshair` pushed
- On click: capture the click point in global screen coordinates, call `WindowManager.selectWindow(at:)`, close overlay, pin result
- Edge case: if user clicks and nothing matches, dismiss with no action

### 4. MenuBuilder.swift
- Static `shared` singleton
- Builds `NSMenu` on demand:
  - **Enable Pin** / **Pin Another** → calls `WindowManager.enterSelectionMode()`
  - Separator
  - **[Owner: Window Title]** — one menu item per pinned window, with "Unpin" as its action (`representedObject = WindowInfo`)
  - Separator
  - **Clear All** → `WindowManager.unpinAll()`
  - Separator
  - **Quit Window Pin** → `NSApplication.shared.terminate(_:)`
- `refresh()` removes all items between the static anchors and rebuilds the pinned list from `windowManager.pinnedWindows`

### 5. WindowPinApp.swift
```swift
@main struct WindowPinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        EmptyScene() // LSUIElement = true, no Dock/Cmd+Tab presence
    }
}
```
`AppDelegate`:
- `applicationDidFinishLaunching`:
  1. Create `NSStatusItem` with `pin.fill` SF Symbol
  2. Call `WindowManager.shared.requestAccessibilityPermission()` → checks `AXIsProcessTrusted()`, triggers system dialog if needed
  3. Build menu via `MenuBuilder`
- Observe `windowManager.isSelecting` via KVO/Combine to show/hide `SelectionOverlay`
- When overlay completes: `windowManager.pin(result)` → `MenuBuilder.refresh()`

### 6. Package.swift & Info.plist
- `Package.swift`: swift-tools-5.9+, no external dependencies
- `Info.plist`: `LSUIElement = true` (menu bar — no Dock, no Cmd+Tab)
- `entitlements.plist`: `com.apple.security.accessibility = true`

## Overlay refresh (content stays current)
A `DispatchSourceTimer` within WindowManager fires every 0.5s and for each pinned window re-captures a CGWindow snapshot and updates the overlay's image view. This handles:
- Web page scrolling
- Text being typed
- New windows opening and then getting covered and revealed

The capture targets just the window's bounds region — a single `CGWindowListCreateImage` per pinned window per tick, no full-screen grab.

## Stale window cleanup
Every enumeration pass, compare pinned window IDs against current snapshot. If a `CGWindowID` no longer exists, the window was closed — remove from pinned set and destroy its overlay. This runs automatically as part of the refresh loop.

## Implementation order

| Step | What | Est. |
|------|------|------|
| 1 | `Package.swift`, `Info.plist`, `entitlements.plist` | 5 min |
| 2 | `WindowInfo` struct + `WindowManager.enumerateWindows()` | 30 min |
| 3 | `SelectionOverlay` + click-to-select flow | 1 hr |
| 4 | `PinOverlay` (NSWindow + snapshot image) | 1.5 hrs |
| 5 | `WindowManager.pin/unpin` wiring + refresh loop | 45 min |
| 6 | `MenuBuilder` — Enable Pin, list, Clear All, Quit | 45 min |
| 7 | `WindowPinApp` + Accessibility permission flow | 30 min |
| 8 | Stale cleanup + edge-case handling | 30 min |
| 9 | Build & smoke-test | 30 min |

Total: ~6 hours of focused implementation.

## Verification (how to test)
1. `swift build` compiles clean
2. Run the `.app` → pin icon appears in menu bar
3. macOS asks for Accessibility permission → grant it
4. Click 📌 → "Enable Pin" → crosshair appears, click a Finder window → overlay covers it
5. Open another app on top → Finder overlay stays visible above it
6. Click 📌 → "Unpin" → overlay disappears, original window is normal again
7. Pin 3+ windows, close one mid-way → it is cleaned up automatically

## Critical files
| File | Why it's critical |
|------|------------------|
| **WindowManager.swift** | All core logic: enumeration, snapshot capture, pin/unpin state, refresh timer, stale cleanup. Everything else depends on it. |
| **PinOverlay.swift** | The actual always-on-top mechanism. Correctness of frame positioning + window level is make-or-break. |
| **SelectionOverlay.swift** | User-facing interaction — crosshair + click UX. If this feels off, the whole app feels off. |
