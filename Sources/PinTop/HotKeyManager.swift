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

    /// Default unpin shortcut: ⌥⌘U (U is ANSI keycode 32). Pairs with
    /// the pin shortcut so both are memorable and conflict-free (#16).
    static let defaultUnpin = HotKeyCombo(keyCode: 32, carbonModifiers: UInt32(cmdKey | optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

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

// MARK: - HotKeyManager

/// File-scope trampoline: the Carbon event handler is a C function pointer
/// and cannot capture context, so actions are stashed here keyed by hotkey id.
private var currentHotKeyActions: [UInt32: () -> Void] = [:]

/// Registers global hotkeys via Carbon RegisterEventHotKey — the standard
/// zero-dependency approach (no extra TCC permissions needed).
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Which action a registered hotkey fires.
    enum HotKeyID: UInt32 {
        case pin = 1
        case unpin = 2
    }

    enum RegistrationError: Error {
        case registrationFailed(OSStatus)
    }

    /// 'PINT' — matches the hotkey signature the event handler filters on.
    private static let hotKeySignature = OSType(0x50494E54)

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    /// Launch-time wiring: store both actions and register both combos (#16).
    /// Pass nil for a combo to leave that hotkey unregistered.
    func setCombos(
        pin pinCombo: HotKeyCombo?,
        unpin unpinCombo: HotKeyCombo?,
        onPin pinAction: @escaping () -> Void,
        onUnpin unpinAction: @escaping () -> Void
    ) {
        currentHotKeyActions[HotKeyID.pin.rawValue] = pinAction
        currentHotKeyActions[HotKeyID.unpin.rawValue] = unpinAction
        unregisterAll()
        if let pinCombo {
            let status = register(pinCombo, id: .pin)
            if status != noErr {
                NSLog("[PinTop] pin hotkey registration failed with OSStatus \(status)")
            }
        }
        if let unpinCombo {
            let status = register(unpinCombo, id: .unpin)
            if status != noErr {
                NSLog("[PinTop] unpin hotkey registration failed with OSStatus \(status)")
            }
        }
    }

    /// Launch-time wiring: store the action and register `combo`.
    /// Pass nil to unregister (teardown only — the UI always holds a combo).
    func setCombo(_ combo: HotKeyCombo?, fires action: @escaping () -> Void) {
        currentHotKeyActions[HotKeyID.pin.rawValue] = action
        unregister(id: .pin)
        guard let combo else { return }
        let status = register(combo, id: .pin)
        if status != noErr {
            NSLog("[PinTop] hotkey registration failed with OSStatus \(status)")
        }
    }

    /// Settings-time re-registration for the given hotkey; the actions set by
    /// setCombo(s) are kept. On failure the previous registration is left
    /// untouched. Throws when the candidate duplicates the *other* hotkey so
    /// the two can never shadow each other.
    func updateCombo(_ combo: HotKeyCombo, for id: HotKeyID = .pin) throws {
        if combo == comboForOtherHotKey(than: id) {
            throw RegistrationError.registrationFailed(OSStatus(eventAlreadyPostedErr))
        }
        let status = register(combo, id: id)
        if status != noErr {
            throw RegistrationError.registrationFailed(status)
        }
    }

    /// The persisted combo currently backing the *other* hotkey, used to
    /// reject duplicates before touching Carbon registration.
    private func comboForOtherHotKey(than id: HotKeyID) -> HotKeyCombo? {
        switch id {
        case .pin: SettingsStore.shared.unpinHotkey
        case .unpin: SettingsStore.shared.hotkey
        }
    }

    // Register the new hotkey BEFORE dropping the old one, so a failure never
    // leaves us with nothing registered.
    @discardableResult
    private func register(_ combo: HotKeyCombo, id: HotKeyID) -> OSStatus {
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: id.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return status }
        unregister(id: id)
        hotKeyRefs[id.rawValue] = ref
        return noErr
    }

    private func unregister(id: HotKeyID) {
        if let ref = hotKeyRefs.removeValue(forKey: id.rawValue) {
            UnregisterEventHotKey(ref)
        }
    }

    private func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func unregister() {
        unregisterAll()
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
                let id = hotKeyID.id
                DispatchQueue.main.async { currentHotKeyActions[id]?() }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }
}
