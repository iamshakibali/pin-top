# Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Settings window (opened from a new "Settings…" menu-bar item) with Launch-at-Login, automatic update checks, a user-recordable global shortcut for pick mode, version display, manual update check, and a GitHub repo link.

**Architecture:** Three new files (`SettingsStore`, `HotKeyManager`+`HotKeyCombo`, `SettingsWindow`+`HotKeyRecorderControl`) and two modified (`PinTopApp`, `AppUpdater`). Pure AppKit matching the existing `AboutWindow` idiom; Carbon `RegisterEventHotKey` for the global shortcut; `SMAppService` for launch-at-login; `UserDefaults` for persistence. Spec: `docs/superpowers/specs/2026-08-16-settings-menu-design.md`.

**Tech Stack:** Swift 5.9, AppKit, Carbon (system framework), ServiceManagement (system framework), SwiftPM. No third-party dependencies.

## Global Constraints

- Platform floor: macOS 14 (`platforms: [.macOS(.v14)]` in Package.swift). Do not raise it.
- Zero third-party dependencies. `import Carbon` and `import ServiceManagement` auto-link — never add them to Package.swift dependencies.
- Pure AppKit. No SwiftUI views anywhere.
- Never call `close()` on overlay windows — `orderOut(nil)` only (auto-termination quirk, CLAUDE.md §Critical Quirks 2).
- Never box Swift structs into `NSMenuItem.representedObject` (CLAUDE.md §Critical Quirks 3).
- The Quit menu item's target must stay `nil` (CLAUDE.md, PinTopApp.swift:121-124).
- Bundle ID: `com.shakib.pintop` (for `defaults` commands in manual tests).
- App smoke tests: quit Pin Top from its menu bar first, then `./run.sh`. Unit tests: `swift test --filter PinTopTests`.
- New unit tests live in `Tests/PinTopTests/`. Only pure-logic units get tests (HotKeyCombo, SettingsStore). GUI/Carbon/SMAppService paths are manually verified — the project has no UI test infrastructure.
- Commit after every task. Do not push.

---

### Task 1: Test target + `HotKeyCombo` model (TDD)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PinTop/HotKeyManager.swift`
- Create: `Tests/PinTopTests/HotKeyComboTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 2, 3, 6, 7):
  - `struct HotKeyCombo: Equatable` with `let keyCode: UInt32` and `let carbonModifiers: UInt32`
  - `HotKeyCombo.default` — ⌥⌘P (keyCode 35)
  - `HotKeyCombo.storageString: String` and `HotKeyCombo.init?(storageString: String)`
  - `HotKeyCombo.displayText: String`
  - `HotKeyCombo.isValid(keyCode: UInt32, carbonModifiers: UInt32) -> Bool`
  - `HotKeyCombo.isFunctionKey(_ keyCode: UInt32) -> Bool`

- [ ] **Step 1: Add the test target to Package.swift**

Replace the `targets:` array contents so the file reads:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PinTop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PinTop",
            targets: ["PinTop"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "PinTop",
            path: "Sources/PinTop",
            resources: [.copy("Resources/PinTop.icns")]
        ),
        .testTarget(
            name: "PinTopTests",
            dependencies: ["PinTop"],
            path: "Tests/PinTopTests"
        ),
    ]
)
```

(Test targets can depend on executable targets since swift-tools 5.5; this project is on 5.9.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/PinTopTests/HotKeyComboTests.swift`:

```swift
import XCTest
import Carbon
@testable import PinTop

final class HotKeyComboTests: XCTestCase {
    func testDefaultComboIsOptionCommandP() {
        XCTAssertEqual(HotKeyCombo.default.keyCode, 35)
        XCTAssertEqual(HotKeyCombo.default.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(HotKeyCombo.default.displayText, "⌥⌘P")
    }

    func testStorageStringRoundTrip() {
        let combo = HotKeyCombo(keyCode: 7, carbonModifiers: UInt32(cmdKey)) // ⌘X
        let restored = HotKeyCombo(storageString: combo.storageString)
        XCTAssertEqual(restored, combo)
    }

    func testInvalidStorageStringReturnsNil() {
        XCTAssertNil(HotKeyCombo(storageString: "not-a-combo"))
        XCTAssertNil(HotKeyCombo(storageString: "35"))
        XCTAssertNil(HotKeyCombo(storageString: "-1:2304"))
    }

    func testDisplayTextOrdersModifiersControlOptionShiftCommand() {
        let combo = HotKeyCombo(
            keyCode: 35,
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(combo.displayText, "⌃⌥⇧⌘P")
    }

    func testUnknownKeyCodeFallsBack() {
        let combo = HotKeyCombo(keyCode: 999, carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(combo.displayText, "⌘Key 999")
    }

    func testValidation() {
        XCTAssertTrue(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: UInt32(cmdKey | optionKey))) // ⌥⌘P
        XCTAssertTrue(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: UInt32(controlKey)))         // ⌃P
        XCTAssertTrue(HotKeyCombo.isValid(keyCode: 122, carbonModifiers: 0))                        // bare F1
        XCTAssertFalse(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: 0))                        // bare P
        XCTAssertFalse(HotKeyCombo.isValid(keyCode: 35, carbonModifiers: UInt32(shiftKey)))         // ⇧P only
    }

    func testFunctionKeyNames() {
        XCTAssertEqual(HotKeyCombo.keyName(for: 122), "F1")
        XCTAssertEqual(HotKeyCombo.keyName(for: 111), "F12")
        XCTAssertEqual(HotKeyCombo.keyName(for: 35), "P")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter HotKeyComboTests 2>&1 | tail -5`
Expected: compile error — `cannot find 'HotKeyCombo' in scope`.

- [ ] **Step 4: Implement `HotKeyCombo` in `Sources/PinTop/HotKeyManager.swift`**

```swift
import Carbon
import Cocoa

// MARK: - HotKeyCombo

/// A global-shortcut combination: a Carbon keycode plus Carbon modifier flags
/// (cmdKey / optionKey / controlKey / shiftKey). Persisted to UserDefaults as
/// a "keyCode:modifiers" string.
struct HotKeyCombo: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    /// Default shortcut: ⌥⌘P (P is ANSI keycode 35).
    static let `default` = HotKeyCombo(keyCode: 35, carbonModifiers: UInt32(cmdKey | optionKey))

    var storageString: String { "\(keyCode):\(carbonModifiers)" }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]) else { return nil }
        self.init(keyCode: keyCode, carbonModifiers: modifiers)
    }

    var displayText: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += Self.keyName(for: keyCode) ?? "Key \(keyCode)"
        return text
    }

    /// Valid shortcuts carry at least one of ⌘/⌥/⌃, or are a bare function key.
    static func isValid(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        let hasRealModifier = carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        return hasRealModifier || isFunctionKey(keyCode)
    }

    /// ANSI keycodes for F1–F14.
    static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107,
    ]

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    /// ANSI (US layout) keycode → display name. Enough for shortcuts; unknown
    /// codes fall back to "Key <n>". F10=109, F11=103, F12=111.
    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 24: "=", 30: "]", 31: "O", 32: "U",
        33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
        49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func keyName(for keyCode: UInt32) -> String? {
        keyNames[keyCode]
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HotKeyComboTests 2>&1 | tail -5`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 6: Verify the app still builds and commit**

Run: `swift build 2>&1 | tail -3` — expected success (new file compiles standalone).

```bash
git add Package.swift Sources/PinTop/HotKeyManager.swift Tests/PinTopTests/HotKeyComboTests.swift
git commit -m "feat: add HotKeyCombo model with validation and display text (with tests)"
```

---

### Task 2: `SettingsStore` (TDD)

**Files:**
- Create: `Sources/PinTop/SettingsStore.swift`
- Create: `Tests/PinTopTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `HotKeyCombo` (Task 1).
- Produces (used by Tasks 4, 5, 6, 7):
  - `final class SettingsStore` with `static let shared`
  - `init(defaults: UserDefaults = .standard)` (injectable for tests)
  - `var autoCheckUpdates: Bool` (default `true`), persisted under key `autoCheckUpdates`
  - `var hotkey: HotKeyCombo` (default `.default`), persisted under key `pinHotkey` as a storage string; corrupt value falls back to `.default`
  - `var lastAutoUpdateCheck: Date` (default `.distantPast`), persisted under key `lastAutoUpdateCheck`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PinTopTests/SettingsStoreTests.swift`:

```swift
import XCTest
import Carbon
@testable import PinTop

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "PinTopTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
    }

    func testDefaultsOnFreshInstall() {
        let store = SettingsStore(defaults: suite)
        XCTAssertTrue(store.autoCheckUpdates)
        XCTAssertEqual(store.hotkey, .default)
        XCTAssertEqual(store.lastAutoUpdateCheck, .distantPast)
    }

    func testAutoCheckUpdatesPersists() {
        let store = SettingsStore(defaults: suite)
        store.autoCheckUpdates = false
        XCTAssertFalse(SettingsStore(defaults: suite).autoCheckUpdates)
    }

    func testHotkeyPersistsRoundTrip() {
        let store = SettingsStore(defaults: suite)
        let combo = HotKeyCombo(keyCode: 7, carbonModifiers: UInt32(cmdKey)) // ⌘X
        store.hotkey = combo
        XCTAssertEqual(SettingsStore(defaults: suite).hotkey, combo)
    }

    func testCorruptHotkeyStringFallsBackToDefault() {
        suite.set("garbage", forKey: "pinHotkey")
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.hotkey, .default)
    }

    func testLastAutoUpdateCheckPersists() {
        let store = SettingsStore(defaults: suite)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.lastAutoUpdateCheck = stamp
        XCTAssertEqual(SettingsStore(defaults: suite).lastAutoUpdateCheck, stamp)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsStoreTests 2>&1 | tail -5`
Expected: compile error — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Implement `SettingsStore`**

Create `Sources/PinTop/SettingsStore.swift`:

```swift
import Foundation

/// Persisted user settings, backed by UserDefaults. Launch-at-login is
/// deliberately absent: SMAppService.mainApp.status is the source of truth
/// for that, so the Settings checkbox reads/writes the system directly.
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var autoCheckUpdates: Bool {
        get {
            if defaults.object(forKey: "autoCheckUpdates") == nil { return true }
            return defaults.bool(forKey: "autoCheckUpdates")
        }
        set { defaults.set(newValue, forKey: "autoCheckUpdates") }
    }

    var hotkey: HotKeyCombo {
        get {
            guard let raw = defaults.string(forKey: "pinHotkey"),
                  let combo = HotKeyCombo(storageString: raw) else { return .default }
            return combo
        }
        set { defaults.set(newValue.storageString, forKey: "pinHotkey") }
    }

    var lastAutoUpdateCheck: Date {
        get { defaults.object(forKey: "lastAutoUpdateCheck") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "lastAutoUpdateCheck") }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsStoreTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PinTop/SettingsStore.swift Tests/PinTopTests/SettingsStoreTests.swift
git commit -m "feat: add SettingsStore for persisted settings (with tests)"
```

---

### Task 3: `HotKeyManager` (Carbon registration)

**Files:**
- Modify: `Sources/PinTop/HotKeyManager.swift` (append below `HotKeyCombo`)

**Interfaces:**
- Consumes: `HotKeyCombo` (Task 1).
- Produces (used by Tasks 6, 7):
  - `final class HotKeyManager` with `static let shared`
  - `enum RegistrationError: Error { case registrationFailed(OSStatus) }`
  - `func setCombo(_ combo: HotKeyCombo?, fires action: @escaping () -> Void)` — stores the action, replaces any existing registration; logs (never crashes) on failure
  - `func updateCombo(_ combo: HotKeyCombo) throws` — re-registers keeping the stored action; throws `RegistrationError` on failure and leaves the previous combo registered

Carbon registration cannot be unit-tested (it needs a real runloop/app); it is manually verified in Tasks 6 and 7.

- [ ] **Step 1: Append the manager to `Sources/PinTop/HotKeyManager.swift`**

```swift
// MARK: - HotKeyManager

/// File-scope trampoline: the Carbon event handler is a C function pointer
/// and cannot capture context, so the action is stashed here.
private var currentHotKeyAction: (() -> Void)?

/// Registers one global hotkey via Carbon RegisterEventHotKey — the standard
/// zero-dependency approach (no extra TCC permissions needed).
final class HotKeyManager {
    static let shared = HotKeyManager()

    enum RegistrationError: Error {
        case registrationFailed(OSStatus)
    }

    /// 'PINT' — matches the hotkey signature the event handler filters on.
    private static let hotKeySignature = OSType(0x50494E54)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Launch-time wiring: store the action and register `combo`.
    /// Pass nil to unregister (teardown only — the UI always holds a combo).
    func setCombo(_ combo: HotKeyCombo?, fires action: @escaping () -> Void) {
        currentHotKeyAction = action
        unregister()
        guard let combo else { return }
        let status = register(combo)
        if status != noErr {
            NSLog("[PinTop] hotkey registration failed with OSStatus \(status)")
        }
    }

    /// Settings-time re-registration; the action set by setCombo is kept.
    /// On failure the previous registration is left untouched.
    func updateCombo(_ combo: HotKeyCombo) throws {
        let status = register(combo)
        if status != noErr {
            throw RegistrationError.registrationFailed(status)
        }
    }

    // Register the new hotkey BEFORE dropping the old one, so a failure never
    // leaves us with nothing registered.
    @discardableResult
    private func register(_ combo: HotKeyCombo) -> OSStatus {
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return status }
        unregister()
        hotKeyRef = ref
        return noErr
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if hotKeyID.signature == HotKeyManager.hotKeySignature {
                DispatchQueue.main.async { currentHotKeyAction?() }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }
}
```

- [ ] **Step 2: Build and run all tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds; all 12 tests pass (Carbon symbols resolve via `import Carbon` at the top of the file).

- [ ] **Step 3: Commit**

```bash
git add Sources/PinTop/HotKeyManager.swift
git commit -m "feat: add Carbon-backed HotKeyManager for the global shortcut"
```

---

### Task 4: `AppUpdater` manual/auto split

**Files:**
- Modify: `Sources/PinTop/AppUpdater.swift:39-87` (the `checkForUpdates` body) and add `promptToInstall`

**Interfaces:**
- Consumes: `SettingsStore.shared.lastAutoUpdateCheck` (Task 2).
- Produces (used by Tasks 5, 7): `checkForUpdates(manual: Bool = true, onStateChange: ((UpdateState) -> Void)? = nil)` — existing call sites (menu item, About window) compile unchanged thanks to the default.

Behavior matrix:
- `manual: true` (default): identical to today — `.available` state then immediate `downloadAndInstall`.
- `manual: false`: `.available` → stamp `lastAutoUpdateCheck`, then an app-modal alert **Install Update / Later**; Later does nothing. Downloading/installing/upToDate/error produce no UI from here (the auto caller in Task 7 handles terminal-state stamping and logging).

- [ ] **Step 1: Change the signature and the update-found branch**

In `Sources/PinTop/AppUpdater.swift`, change the method declaration at line 39 from:

```swift
    func checkForUpdates(onStateChange: ((UpdateState) -> Void)? = nil) {
```

to:

```swift
    func checkForUpdates(manual: Bool = true, onStateChange: ((UpdateState) -> Void)? = nil) {
```

Then find this block near the end of the URL-session callback (around line 83):

```swift
            self.currentState = .available(latestVersion)
            self.downloadAndInstall(from: downloadURL)
```

and replace it with:

```swift
            if manual {
                self.currentState = .available(latestVersion)
                self.downloadAndInstall(from: downloadURL)
            } else {
                // Stamp before prompting so "Later" won't re-nag inside the
                // 24h window (see SettingsStore).
                SettingsStore.shared.lastAutoUpdateCheck = Date()
                self.currentState = .available(latestVersion)
                self.promptToInstall(version: latestVersion, downloadURL: downloadURL)
            }
```

- [ ] **Step 2: Add the prompt helper**

Add this method to `AppUpdater` (directly after `checkForUpdates`):

```swift
    /// Automatic-check update prompt. App-modal only pins our own app, which
    /// has no other windows — the user's other apps stay usable.
    private func promptToInstall(version: String, downloadURL: URL) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Update Available"
            alert.informativeText = "Pin Top \(version) is ready to install."
            alert.addButton(withTitle: "Install Update")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                self.downloadAndInstall(from: downloadURL)
            }
        }
    }
```

- [ ] **Step 3: Build and run tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds (menu item and About window call sites unchanged — default parameter); tests pass.

- [ ] **Step 4: Smoke-test the manual path is unchanged**

Quit Pin Top if running, then `./run.sh`. Menu bar → **Check for Updates** → expect the same modal behavior as before (up-to-date alert on latest version).

- [ ] **Step 5: Commit**

```bash
git add Sources/PinTop/AppUpdater.swift
git commit -m "feat: add automatic-check update path with Install/Later prompt"
```

---

### Task 5: `SettingsWindow` + "Settings…" menu item

**Files:**
- Create: `Sources/PinTop/SettingsWindow.swift`
- Modify: `Sources/PinTop/PinTopApp.swift`

**Interfaces:**
- Consumes: `SettingsStore.shared` (Task 2), `AppUpdater.checkForUpdates(manual:onStateChange:)` (Task 4).
- Produces: `class SettingsWindow: NSWindow` (consumed by Task 6, which adds the shortcut row, and Task 7's launch guard).

The shortcut section's space is reserved in this task's layout; the recorder row itself lands in Task 6.

- [ ] **Step 1: Create `Sources/PinTop/SettingsWindow.swift`**

```swift
import Cocoa
import ServiceManagement

class SettingsWindow: NSWindow {
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginItemCheckbox = NSButton(
        checkboxWithTitle: "Launch at Login", target: nil, action: nil
    )
    private let autoUpdateCheckbox = NSButton(
        checkboxWithTitle: "Check for Updates Automatically", target: nil, action: nil
    )

    init() {
        let windowSize = NSSize(width: 360, height: 372)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Settings"
        isReleasedWhenClosed = false
        center()
        buildUI()
    }

    private func makeCaption(_ text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 24, y: y, width: 312, height: 14)
        return label
    }

    private func buildUI() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // MARK: General

        contentView.addSubview(makeCaption("General", y: 344))

        loginItemCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItemCheckbox.target = self
        loginItemCheckbox.action = #selector(toggleLoginItem)
        loginItemCheckbox.frame = NSRect(x: 24, y: 314, width: 312, height: 22)
        contentView.addSubview(loginItemCheckbox)

        autoUpdateCheckbox.state = SettingsStore.shared.autoCheckUpdates ? .on : .off
        autoUpdateCheckbox.target = self
        autoUpdateCheckbox.action = #selector(toggleAutoUpdate)
        autoUpdateCheckbox.frame = NSRect(x: 24, y: 288, width: 312, height: 22)
        contentView.addSubview(autoUpdateCheckbox)

        // Space for the Shortcut section (rows added in a later task):
        // caption at y=252, label/recorder at y≈220.

        // MARK: About

        contentView.addSubview(makeCaption("About", y: 184))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 24, y: 162, width: 312, height: 16)
        contentView.addSubview(versionLabel)

        let updateButton = NSButton(
            title: "Check for Updates…",
            target: self,
            action: #selector(checkForUpdates)
        )
        updateButton.bezelStyle = .rounded
        updateButton.font = .systemFont(ofSize: 13)
        updateButton.frame = NSRect(x: 100, y: 118, width: 160, height: 30)
        contentView.addSubview(updateButton)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 10, y: 94, width: 340, height: 16)
        contentView.addSubview(statusLabel)

        let repoButton = NSButton(title: "GitHub Repo", target: self, action: #selector(openGitHub))
        repoButton.bezelStyle = .inline
        repoButton.isBordered = false
        repoButton.font = .systemFont(ofSize: 13)
        repoButton.frame = NSRect(x: 110, y: 58, width: 140, height: 20)
        contentView.addSubview(repoButton)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        Task { @MainActor in
            do {
                if service.status == .enabled {
                    try await service.unregister()
                } else {
                    try await service.register()
                }
            } catch {
                showStatusError("Launch at Login failed: \(error.localizedDescription)")
            }
            // The system is the source of truth — always resync to it.
            loginItemCheckbox.state = service.status == .enabled ? .on : .off
        }
    }

    @objc private func toggleAutoUpdate() {
        SettingsStore.shared.autoCheckUpdates = (autoUpdateCheckbox.state == .on)
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates { [weak self] state in
            guard let self else { return }
            statusLabel.stringValue = state.displayText
            switch state {
            case .error:
                statusLabel.textColor = .systemRed
            case .upToDate:
                statusLabel.textColor = .systemGreen
            default:
                statusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/iamshakibali/pin-top") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showStatusError(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = .systemRed
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

- [ ] **Step 2: Add the menu item and window property to `PinTopApp.swift`**

In `Sources/PinTop/PinTopApp.swift`:

1. Add a property next to `private var aboutWindow: AboutWindow?` (line 21):

```swift
    private var settingsWindow: SettingsWindow?
```

2. In `buildMenu()`, insert directly **above** the `aboutItem` declaration (line 111):

```swift
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(settingsMenuItem),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
```

3. Add the action next to `aboutMenuItem` (line 152):

```swift
    @objc func settingsMenuItem() {
        if settingsWindow == nil { settingsWindow = SettingsWindow() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

4. In `applicationDidFinishLaunching`'s window-cleanup loop (line 42), extend the guard so a settings window is never force-closed:

```swift
                if !(window is PinOverlayWindow) && !(window is AboutWindow)
                    && !(window is SettingsWindow) {
                    window.close()
                }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: success.

- [ ] **Step 4: Manual verification**

Quit Pin Top if running, then `./run.sh`:

1. Menu bar → **Settings…** → window opens centered, focused, titled "Settings".
2. ☑ Launch at Login on → System Settings → General → Login Items lists Pin Top; uncheck → it disappears. (Note: a dev build registers the debug bundle path — expected.)
3. Un/check "Check for Updates Automatically", quit and reopen Settings → state persists. Verify via `defaults read com.shakib.pintop autoCheckUpdates`.
4. "Check for Updates…" → status label shows up-to-date (green) or error (red).
5. "GitHub Repo" → opens `https://github.com/iamshakibali/pin-top` in the browser.
6. Menu-bar icon, pin/unpin, Quit still work (no regressions from the menu edit).

- [ ] **Step 5: Commit**

```bash
git add Sources/PinTop/SettingsWindow.swift Sources/PinTop/PinTopApp.swift
git commit -m "feat: add Settings window with login-item, auto-update, and about controls"
```

---

### Task 6: `HotKeyRecorderControl` + shortcut row

**Files:**
- Modify: `Sources/PinTop/SettingsWindow.swift` (append the control class; add the row in `buildUI`)

**Interfaces:**
- Consumes: `HotKeyCombo` (Task 1), `HotKeyManager.shared.updateCombo(_:)` (Task 3), `SettingsStore.shared.hotkey` (Task 2).
- Produces: `final class HotKeyRecorderControl: NSView` with `init(combo: HotKeyCombo)`, `func setCombo(_ combo: HotKeyCombo)`, and `var onComboChanged: ((HotKeyCombo) -> Void)?`.

- [ ] **Step 1: Append the recorder class to `SettingsWindow.swift`**

```swift
// MARK: - HotKeyRecorderControl

/// Click-to-record shortcut field. Click → "Press shortcut…" → keyDown with a
/// valid combo applies it live; Esc cancels; invalid combos show a hint and
/// keep recording. Becoming/resigning first responder drives recording state.
final class HotKeyRecorderControl: NSView {
    var onComboChanged: ((HotKeyCombo) -> Void)?

    private var combo: HotKeyCombo
    private var recording = false
    private let label = NSTextField(labelWithString: "")

    init(combo: HotKeyCombo) {
        self.combo = combo
        super.init(frame: NSRect(x: 0, y: 0, width: 146, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 4, y: 6, width: 138, height: 16)
        addSubview(label)
        refreshLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCombo(_ newCombo: HotKeyCombo) {
        combo = newCombo
        refreshLabel()
    }

    private func refreshLabel() {
        label.stringValue = recording ? "Press shortcut…" : combo.displayText
        layer?.borderColor = recording
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        refreshLabel()
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        refreshLabel()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        // Esc cancels recording, keeping the previous combo.
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        let candidate = HotKeyCombo(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: Self.carbonModifiers(from: event.modifierFlags)
        )
        guard HotKeyCombo.isValid(
            keyCode: candidate.keyCode,
            carbonModifiers: candidate.carbonModifiers
        ) else {
            label.stringValue = "Use ⌘, ⌥, or ⌃"
            return
        }
        combo = candidate
        refreshLabel()
        onComboChanged?(combo)
        window?.makeFirstResponder(nil)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
```

Add `import Carbon` at the top of `SettingsWindow.swift` (Carbon modifier constants are used by `carbonModifiers(from:)`).

- [ ] **Step 2: Add the shortcut row to `buildUI()`**

In `SettingsWindow.buildUI()`, replace the placeholder comment:

```swift
        // Space for the Shortcut section (rows added in a later task):
        // caption at y=252, label/recorder at y≈220.
```

with:

```swift
        // MARK: Shortcut

        contentView.addSubview(makeCaption("Shortcut", y: 252))

        let shortcutLabel = NSTextField(labelWithString: "Toggle Pin Mode")
        shortcutLabel.font = .systemFont(ofSize: 13)
        shortcutLabel.frame = NSRect(x: 24, y: 225, width: 160, height: 17)
        contentView.addSubview(shortcutLabel)

        let recorder = HotKeyRecorderControl(combo: SettingsStore.shared.hotkey)
        recorder.frame = NSRect(x: 190, y: 218, width: 146, height: 28)
        recorder.onComboChanged = { [weak self, weak recorder] combo in
            do {
                // Register first, persist only on success. On failure the
                // manager keeps the old combo registered, and the store was
                // never touched — just reset the display.
                try HotKeyManager.shared.updateCombo(combo)
                SettingsStore.shared.hotkey = combo
            } catch {
                recorder?.setCombo(SettingsStore.shared.hotkey)
                self?.showStatusError(
                    "Couldn't register shortcut — it may conflict with macOS or another app."
                )
            }
        }
        contentView.addSubview(recorder)
```

- [ ] **Step 3: Build and run tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build success, all tests pass.

- [ ] **Step 4: Manual verification**

Note: the hotkey is not registered at launch yet (Task 7 wires that), so verify the recorder UI only in this task:

1. Quit Pin Top if running, then `./run.sh` → **Settings…**
2. Recorder shows "⌥⌘P" (or the persisted combo).
3. Click it → "Press shortcut…" with an accent border; press `P` alone → hint "Use ⌘, ⌥, or ⌃", still recording; press Esc → back to the old combo.
4. Record ⌥⌘X → label shows "⌥⌘X"; `defaults read com.shakib.pintop pinHotkey` → `7:2304` (X=7, ⌥⌘=2304).
5. Re-record back to ⌥⌘P to restore the default.

- [ ] **Step 5: Commit**

```bash
git add Sources/PinTop/SettingsWindow.swift
git commit -m "feat: add hotkey recorder control to Settings"
```

---

### Task 7: Launch wiring — global hotkey + auto-check + `toggleSelectionMode`

**Files:**
- Modify: `Sources/PinTop/PinTopApp.swift`

**Interfaces:**
- Consumes: `HotKeyManager.shared.setCombo(_:fires:)` (Task 3), `SettingsStore.shared` (Task 2), `AppUpdater.checkForUpdates(manual:onStateChange:)` (Task 4).
- Produces: `func toggleSelectionMode()` on `AppDelegate` (public behavior: toggles pick mode; also becomes the hotkey action).

- [ ] **Step 1: Add `toggleSelectionMode` and refactor `selectMenuItem`**

Replace `selectMenuItem` (line 138) with:

```swift
    /// Toggles pick mode: starts selection if none is active, cancels if one is.
    /// Invoked by the menu item and the global hotkey.
    func toggleSelectionMode() {
        if selectionOverlayWindows.isEmpty {
            guard let windowManager else { return }
            NSApp.activate(ignoringOtherApps: true)
            guard windowManager.enterSelectionMode() else { return }
            showSelectionOverlay()
        } else {
            hideSelectionOverlay()
            windowManager?.exitSelectionMode()
        }
    }

    @objc func selectMenuItem() {
        toggleSelectionMode()
    }
```

- [ ] **Step 2: Wire launch-time hotkey registration and the auto-check**

In `applicationDidFinishLaunching` (line 29), directly after `setupStatusBar()` add:

```swift
        registerHotkey()
        maybeAutoCheckUpdates()
```

And add these methods to `AppDelegate` (next to `clearAllMenuItem`):

```swift
    private func registerHotkey() {
        HotKeyManager.shared.setCombo(SettingsStore.shared.hotkey) { [weak self] in
            self?.toggleSelectionMode()
        }
    }

    private func maybeAutoCheckUpdates() {
        guard SettingsStore.shared.autoCheckUpdates else { return }
        guard Date().timeIntervalSince(SettingsStore.shared.lastAutoUpdateCheck) > 24 * 60 * 60
        else { return }
        AppUpdater.shared.checkForUpdates(manual: false) { state in
            switch state {
            case .upToDate, .error:
                // Terminal states stamp the throttle; ".available" is stamped
                // by AppUpdater itself right before it prompts.
                SettingsStore.shared.lastAutoUpdateCheck = Date()
                if case .error(let message) = state {
                    NSLog("[PinTop] automatic update check failed: \(message)")
                }
            default:
                break
            }
        }
    }
```

- [ ] **Step 3: Build and run tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build success, all tests pass.

- [ ] **Step 4: Manual verification**

Quit Pin Top if running, then `./run.sh`:

1. **Hotkey**: from any other app, press ⌥⌘P (or your recorded combo) → crosshair overlays appear on every screen; press it again → they cancel. Clicking a window still pins it.
2. **Hotkey live-change**: Settings → record ⌥⌘X → press ⌥⌘X anywhere → pick mode toggles (no relaunch needed).
3. **Auto-check throttle**: `defaults delete com.shakib.pintop lastAutoUpdateCheck`, quit and relaunch Pin Top → no UI appears while checking; if a newer GitHub release exists, the Install/Later prompt appears; choose Later → relaunch again → no second prompt (throttle stamped; verify `defaults read com.shakib.pintop lastAutoUpdateCheck`).
4. **Auto-check opt-out**: uncheck "Check for Updates Automatically", `defaults delete com.shakib.pintop lastAutoUpdateCheck`, relaunch → no check happens.
5. Menu: ⌘, (with the menu open) opens Settings; Enable Pin / Pin Another still work via the menu.

- [ ] **Step 5: Commit**

```bash
git add Sources/PinTop/PinTopApp.swift
git commit -m "feat: wire global hotkey, Settings menu item, and launch update check"
```

---

### Task 8: Full QA pass against the spec checklist

**Files:**
- Modify: only if QA finds defects.

**Interfaces:**
- Consumes: everything above.
- Produces: verified feature.

- [ ] **Step 1: Run the spec's manual checklist end-to-end**

From `docs/superpowers/specs/2026-08-16-settings-menu-design.md` §Testing, execute items 1–8:

1. `./run.sh` (quit Pin Top first), open Settings from menu (and via ⌘, while the menu is open) — window centers, takes focus.
2. Launch at Login on/off ↔ System Settings → General → Login Items.
3. Record ⌥⌘X → from another app it toggles pick mode; again cancels.
4. Esc during recording cancels; bare-letter combos rejected with hint.
5. `defaults delete com.shakib.pintop lastAutoUpdateCheck`, relaunch → silent check; Install/Later prompt if newer release exists.
6. Check for Updates… → green up-to-date or red error status.
7. GitHub button opens the repo.
8. Quit/restart (menu Quit, relaunch via `./run.sh`) → hotkey and both checkboxes persist.

- [ ] **Step 2: Regression checks**

- Pin a window, move/resize it — overlay still follows (Tasks 5–7 touched `PinTopApp`, confirm no menu-refresh regression: pinned window submenus list/unpin correctly).
- Quit via menu bar still terminates the app (Quit item untouched, target nil).

- [ ] **Step 3: Fix anything found, commit**

```bash
git add -A ':!graphify-out' ':!PinTop.app' ':!dist'
git commit -m "fix: settings QA fixes"
```

(Skip this commit if QA found nothing to change.)
