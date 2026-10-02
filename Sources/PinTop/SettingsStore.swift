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

    /// Unpin-all shortcut (#16). Nil = never customized: returns
    /// `.defaultUnpin` (⌥⌘U) so existing installs pick up the new hotkey.
    var unpinHotkey: HotKeyCombo {
        get {
            guard let raw = defaults.string(forKey: "unpinHotkey"),
                  let combo = HotKeyCombo(storageString: raw) else { return .defaultUnpin }
            return combo
        }
        set { defaults.set(newValue.storageString, forKey: "unpinHotkey") }
    }

    var lastAutoUpdateCheck: Date {
        get { defaults.object(forKey: "lastAutoUpdateCheck") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "lastAutoUpdateCheck") }
    }
}
