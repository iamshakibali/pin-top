# Fix Write-Up: Menu Bar Icon Visible but Frozen on macOS Tahoe

**Date:** 2026-08-16
**Affected version:** 0.3.0 dev build (uncommitted refactor of `PinTopApp.swift`)
**Status:** Fixed — verified via unified log and live interaction

## Symptom

After refactoring `PinTopApp.swift`, the app launches and the pin icon shows in
the menu bar, but clicking the icon does nothing. No menu drops down, and it
feels like the whole app is frozen. The main thread, however, is perfectly
healthy — the app is not hung.

## Root Cause

The app was **closing its own menu bar icon's window at launch**.

`AppDelegate.applicationDidFinishLaunching` contains a cleanup loop whose
original purpose is to dismiss the SwiftUI `Settings` scene window that
auto-opens on launch:

```swift
DispatchQueue.main.async {
    for window in NSApp.windows {
        if !(window is PinOverlayWindow) && !(window is AboutWindow) {
            window.close()
        }
    }
}
```

That loop doesn't just catch the Settings window — it also catches the
**`NSStatusBarWindow`**, the window that hosts the menu bar item and receives
its clicks. Once it is closed:

- ControlCenter keeps rendering the icon, so it still *looks* alive.
- The click target is gone, so clicks never reach the app.

Result: icon visible, clicks dead — the "frozen" symptom.

### Why the refactor made it bite

The refactor moved `setupMenuBar()` from `PinTopApp.init()` into
`applicationDidFinishLaunching`, immediately before the cleanup loop. With that
ordering, the freshly created status item's window is already present in
`NSApp.windows` when the loop runs on the next runloop turn, so it gets swept
up and closed. In the old layout the status item escaped the sweep only by a
timing accident — the loop was always one refactor away from breaking the app.

## Evidence (unified log, `log show --predicate 'processID == <pid>'`)

Broken launch — the status window is closed moments after creation, then AppKit
scrambles to recover:

```
19:14:30.726  AppKit:Scene        Created scene DD4D0A3D-…-Aux[1]-NSStatusItemView of class NSHostedViewScene
19:14:30.726  AppKit:Scene        Created scene DD4D0A3D-… of class NSStatusItemScene
19:14:30.746  AppKit:Window       window <NSStatusBarWindow: 0x70ca14280> windowNumber=100000000 finishing close   ← our loop did this
19:14:30.772  FrontBoardServices  Requesting scene …-Replicant[1]-Aux[1]-NSStatusItemView …                       ← recovery attempt, never clickable
```

The broken launch closed **exactly one window** — the status bar window. The
Settings window it was meant to catch never even opened.

A process sample (`sample <pid> 3`) showed the main thread idle in
`mach_msg` the whole time, ruling out a hang, deadlock, or busy 60 Hz refresh
loop.

## The Fix

### 1. Skip status bar windows in the cleanup loop (root cause)

```swift
DispatchQueue.main.async {
    for window in NSApp.windows {
        // NSStatusBarWindow isn't exposed to Swift, so match by class
        // name. It hosts the menu-bar icon's click target — closing it
        // leaves the icon rendered by ControlCenter but dead to clicks
        // (the "icon visible but frozen" bug).
        if window.className == "NSStatusBarWindow" { continue }
        if !(window is PinOverlayWindow) && !(window is AboutWindow) {
            window.close()
        }
    }
}
```

`NSStatusBarWindow` is a public AppKit class but is not imported into Swift,
so `window is NSStatusBarWindow` does not compile. Matching on
`window.className` is the standard workaround.

### 2. Related regressions (fixed alongside, in the v0.3.1 branch)

While chasing this locally, the same refactor was also found to have dropped
the `AppDelegate.configure(with:)` call (leaving `windowManager` nil, so every
menu item silently did nothing) and to have left a debug artifact writing to
`/tmp/pintop.log`. The published v0.3.1 branch already restored the
`configure(with:)` wiring in `setupStatusBar()`, so the only code change
shipping in 0.3.2 for this issue is the status-window skip above.

## Verification

- Rebuilt with `./run.sh`; the launch log no longer contains
  `NSStatusBarWindow … finishing close`.
- Live interaction in the unified log: three `NSPopupMenuWindow` open/close
  cycles (the menu dropping down and dismissing), `PinTop.AboutWindow` opened
  and closed, and a clean `Termination commencing → complete` from the Quit
  menu item — no crash reports.
- A relaunch instance shows the same healthy pattern.

## Lessons

1. Never blanket-close windows in an app that owns special AppKit windows
   (`NSStatusBarWindow`, panels, popups). Filter by *what you want to close*,
   not by what you don't recognize.
2. SwiftUI scene timing changes (init → `didFinishLaunching`) can flip
   long-standing races. A hack that worked "by accident" is a bug that hasn't
   fired yet.
3. "Icon visible but dead" on macOS almost never means the process is hung —
   WindowServer renders status items even for a stuck app. Sample the process
   before assuming a freeze; the unified log (`AppKit:Window … finishing
   close`) tells you exactly who closed what.
