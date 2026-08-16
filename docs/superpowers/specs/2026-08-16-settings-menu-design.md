# Settings Window & Supporting Features — Design

Date: 2026-08-16
Status: Approved (user approved design in brainstorming session)
Branch: `feat/settings-menu`, stacked on `fix/pin-vanishes-on-desktop-click` (2 unmerged fix commits live there; branching off its HEAD keeps those fixes in test builds — rebase onto `main` once the fix branch merges)

## Goal

Give Pin Top a proper Settings window, opened from a new **“Settings…”** menu-bar item (⌘,), containing:

1. **Launch at Login** checkbox
2. **Check for Updates Automatically** checkbox (background check on launch, throttled to once per 24h)
3. **Global keyboard shortcut** recorder for toggling pick mode (default ⌥⌘P, user-recordable)
4. **Version display**, **Check for Updates…** button, and **GitHub Repo** link (`https://github.com/iamshakibali/pin-top`)

## Decisions (from brainstorming)

- **UI form**: dedicated Settings window — not a menu-bar submenu, not merged into About.
- **Implementation approach**: pure AppKit `NSWindow` matching `AboutWindow`'s style. Chosen over SwiftUI `Settings` scene because `LSUIElement` (menu-bar-only) apps have known focus/activation quirks with SwiftUI settings scenes and there is no main menu bar to host ⌘,. A recorder control would need an `NSViewRepresentable` shim anyway, so SwiftUI saves little.
- **Shortcut behavior**: toggle pick mode — if selection overlays are visible, cancel them; otherwise start the same flow as the menu item. One action, predictable.
- **Shortcut config**: user-recordable via a recorder control; persisted; live re-registration.
- **Auto-update behavior**: check + prompt. Background check is silent; on a found update show an app-modal alert with **Install Update / Later**. Manual check keeps today's instant download-and-install flow unchanged.
- **Launch at Login state**: `SMAppService.mainApp.status` is the single source of truth — no mirrored UserDefaults bool. Checkbox reads system status, writes via `register()`/`unregister()`.

## Architecture

Three new files plus two modified files. No new dependencies, no Package.swift changes (`import Carbon` and `import ServiceManagement` auto-link under SwiftPM), no entitlement changes.

```
Sources/PinTop/
├── PinTopApp.swift        (modified)  — Settings… menu item, toggleSelectionMode(),
│                                        launch-time auto-check, cleanup guard
├── AppUpdater.swift       (modified)  — manual: flag; prompt-on-available for auto checks
├── SettingsStore.swift    (new)       — persisted settings (UserDefaults-backed)
├── SettingsWindow.swift   (new)       — window + controls + HotKeyRecorderControl
└── HotKeyManager.swift    (new)       — Carbon RegisterEventHotKey wrapper
```

## Components

### 1. `SettingsStore` (new)

`final class SettingsStore` with a `static let shared` instance. Backed by `UserDefaults` (standard suite). Exposes:

- `var autoCheckUpdates: Bool` — default `true`. Key: `autoCheckUpdates`.
- `var hotkey: HotKeyCombo?` — default `.default` (⌥⌘P). Key: `pinHotkey` stored as `"keyCode:carbonModifiers"` string; absent → default. Keycode for P is 35; Carbon modifiers `optionKey | cmdKey`.
- `var lastAutoUpdateCheck: Date` — Key: `lastAutoUpdateCheck`. Default `.distantPast so the first launch checks.

`HotKeyCombo` is a small struct (in `HotKeyManager.swift`): `keyCode: UInt32`, `carbonModifiers: UInt32`, with `static let default = HotKeyCombo(keyCode: 35, carbonModifiers: Int(cmdKey | optionKey))`, Codable-style string round-trip for UserDefaults, and a `displayText` (e.g. "⌥⌘P") built from the keycode and modifiers.

### 2. `HotKeyManager` (new)

`final class HotKeyManager` with `static let shared`:

- `func setCombo(_ combo: HotKeyCombo?, fires action: @escaping () -> Void)` — stores the action, unregisters any existing hotkey, registers the new one via Carbon `RegisterEventHotKey`, and installs one `InstallEventHandler` (kEventClassKeyboard / kEventHotKeyPressed) once that dispatches to the stored action on the main thread. AppDelegate calls this once at launch with `toggleSelectionMode`.
- `func updateCombo(_ combo: HotKeyCombo) throws` — re-registers the hotkey, keeping the action set by the initial `setCombo` call. This is what the recorder uses; it never touches the action.
- Passing a nil combo to `setCombo` only unregisters (shortcut-disabled is **not** in scope — the recorder always holds a valid combo; nil is only for teardown).
- Registration failure throws so the settings UI can restore the previous combo.

The toggling action is supplied by `AppDelegate` (`toggleSelectionMode()`), not hardcoded in the manager.

### 3. `SettingsWindow` (new)

`class SettingsWindow: NSWindow` modeled on `AboutWindow`: `styleMask: [.titled, .closable]`, `isReleasedWhenClosed = false`, centered, fixed content width ~360pt, `canBecomeKey/Main = true`. AppDelegate owns an optional instance, creates lazily, `makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps: true)`.

Layout, top to bottom (manual frames, secondary-label captions like About):

- **Launch at Login** — `NSButton` checkbox. Initial state from `SMAppService.mainApp.status == .enabled`. Toggle on → `register()`; off → `unregister()`. On thrown error: revert checkbox to the actual status and show the error text in the window's status label (red).
- **Check for Updates Automatically** — `NSButton` checkbox bound to `SettingsStore.shared.autoCheckUpdates`.
- **Shortcut row** — caption "Toggle Pin Mode" + `HotKeyRecorderControl` showing the current combo (e.g. "⌥⌘P").
- **Version row** — "Version {CFBundleShortVersionString}" secondary label.
- **Check for Updates… button + status label** — calls `AppUpdater.shared.checkForUpdates(manual: true)`; status label mirrors `state.displayText` with the same color coding as `AboutWindow` (red error, green up-to-date).
- **GitHub Repo link** — borderless inline `NSButton` opening `https://github.com/iamshakibali/pin-top`.

`HotKeyRecorderControl` (same file): a bordered `NSView`-backed control. Idle → shows current combo, click enters recording ("Press shortcut…", capture on `keyDown`/`flagsChanged`). Accepted combos: at least one of ⌥/⌘/⌃, or a bare function key. Esc cancels recording (keeps previous combo); invalid combos (no modifier, shift-only) are rejected with a brief red hint and stay in recording mode. On accept: persist to `SettingsStore`, re-register via `HotKeyManager`, exit recording. Registration failure → show error, restore previous combo in store and manager.

### 4. `PinTopApp` changes (modified)

- Menu: insert `Settings…` (key equivalent `,` with ⌘ modifier) between the pinned-windows section and **About Pin Top** (i.e., right before About). Action lazily creates and shows `settingsWindow`, mirroring `aboutMenuItem`.
- Add `func toggleSelectionMode()`: if `selectionOverlayWindows` is non-empty → `hideSelectionOverlay()` + `windowManager.exitSelectionMode()`; else the body of `selectMenuItem()` (activate, `enterSelectionMode()`, `showSelectionOverlay()`). Refactor `selectMenuItem` to call it.
- In `applicationDidFinishLaunching`, after `setupStatusBar()`: register the hotkey (`HotKeyManager.shared.setCombo(SettingsStore.shared.hotkey) { toggleSelectionMode() }`), and if `autoCheckUpdates` and `Date().timeIntervalSince(lastAutoUpdateCheck) > 24h` → `AppUpdater.shared.checkForUpdates(manual: false)` and set `lastAutoUpdateCheck = Date()` when the check completes (any terminal state).
- Launch-cleanup guard: add `!(window is SettingsWindow)` alongside AboutWindow/PinOverlayWindow (defensive; the window is created lazily so it normally won't exist at launch).

### 5. `AppUpdater` changes (modified)

- `checkForUpdates(manual: Bool = true, onStateChange: ...)` — signature grows a `manual` flag, defaulting to `true` so both existing call sites (menu item, About window) are unchanged.
- Manual path: behavior identical to today, including the automatic download-and-install once an update is found.
- Auto path (`manual: false`): `stateHandler` still drives UI, but the caller differs —
  - `.checking` / `.downloading` / `.installing`: no UI.
  - `.upToDate`, `.error`: no alert. AppDelegate's state handler stamps `SettingsStore.lastAutoUpdateCheck = Date()` on these terminal states; errors additionally `NSLog`.
  - `.available(version)`: `AppUpdater` itself stamps `lastAutoUpdateCheck = Date()` (before alerting, so "Later" won't re-nag within the window), then — if `manual == false` — shows an app-modal `NSAlert` on the main thread after `NSApp.activate(ignoringOtherApps: true)`: "Update Available — Pin Top {version} is ready to install." Buttons: **Install Update** (default) → `downloadAndInstall`; **Later** → nothing. The alert is app-modal (`runModal`); Pin Top has no other windows at that moment, so the user's work in other apps is unaffected.
- Manual path never stamps `lastAutoUpdateCheck` — the throttle applies to automatic checks only.

## Data flow

- Checkbox toggles → `SettingsStore`/`SMAppService` → immediate effect. No OK/Apply button (live, standard for small macOS settings windows).
- Hotkey record → validate → persist to `SettingsStore.hotkey` → `HotKeyManager.setCombo` re-registers → next press anywhere fires `toggleSelectionMode()`.
- Launch → read `SettingsStore` → register hotkey → maybe auto-check (silent) → prompt only if newer.

## Error handling

| Failure | Behavior |
|---|---|
| SMAppService register/unregister throws | Revert checkbox to actual `SMAppService.status`; red text in status label |
| Hotkey registration fails | Recorder shows error; previous combo restored in store + manager |
| Invalid recorded combo | Rejected in recorder (red hint), recording continues; nothing persisted |
| Auto-check network error | Silent, logged via NSLog; timestamp still stamped |
| Manual check error | Existing alert flow unchanged |

## Constraints & quirks honored

- No `close()` on overlay windows — unchanged; Settings window is `isReleasedWhenClosed = false` and owned by AppDelegate (same as About).
- No Swift structs boxed into `representedObject` — new menu item uses target/action only.
- Auto-termination guards already in place; settings window closing cannot terminate the app (`applicationShouldTerminateAfterLastWindowClosed` is already `false`).
- Carbon import is a system module — no third-party dependency introduced (project rule: zero dependencies).
- `SMAppService` requires macOS 13+; app targets macOS 14+. OK.

## Out of scope (YAGNI)

- Per-window or multiple shortcuts, unpin shortcut
- Sparkle or any update framework
- Settings for overlay behavior (refresh rate, corner radius, etc.)
- Changes to the About window
- README repo-URL fix (`window-pin` → `pin-top`) — separate trivial commit if wanted
- Disabling the hotkey entirely (recorder always holds a valid combo)

## Testing (manual — project has no unit tests)

1. `./run.sh`, open Settings from menu (and via ⌘, while menu open) — window centers, focus works.
2. Toggle **Launch at Login** on → appears in System Settings → General → Login Items; off → disappears. (Dev-build note: registers the debug bundle path; expected.)
3. Record ⌥⌘X in the recorder → from any other app, press it → pick-mode overlays appear; press again → cancel.
4. Esc during recording cancels; a bare-letter combo is rejected with hint.
5. To test the throttle: quit the app, run `defaults delete <bundle-id> lastAutoUpdateCheck` (or wait 24h), relaunch → silent check runs; if a newer release exists on GitHub, the Install/Later prompt appears.
6. **Check for Updates…** button: up-to-date path shows green status; error path shows red.
7. GitHub button opens the repo in browser.
8. Quit/restart — hotkey and checkboxes persist.
