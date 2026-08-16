import Cocoa
import Carbon
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
