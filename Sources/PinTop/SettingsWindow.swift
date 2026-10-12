import Cocoa
import Carbon
import ServiceManagement

class SettingsWindow: NSWindow {
    private static let contentWidth: CGFloat = 400

    private let statusLabel = NSTextField(labelWithString: "")
    private let loginItemSwitch = NSSwitch()
    private let autoUpdateSwitch = NSSwitch()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Settings"
        isReleasedWhenClosed = false
        buildUI()
        center()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // General
        loginItemSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItemSwitch.target = self
        loginItemSwitch.action = #selector(toggleLoginItem)

        autoUpdateSwitch.state = SettingsStore.shared.autoCheckUpdates ? .on : .off
        autoUpdateSwitch.target = self
        autoUpdateSwitch.action = #selector(toggleAutoUpdate)

        let general = makeSection("General", rows: [
            makeRow(makeLabel("Launch at Login"), loginItemSwitch),
            makeRow(makeLabel("Check for Updates Automatically"), autoUpdateSwitch),
        ])

        // Shortcuts
        let recorder = HotKeyRecorderControl(combo: SettingsStore.shared.hotkey)
        recorder.onComboChanged = { [weak self, weak recorder] combo in
            do {
                // Register first, persist only on success. On failure the
                // manager keeps the old combo registered, and the store was
                // never touched — just reset the display.
                try HotKeyManager.shared.updateCombo(combo, for: .pin)
                SettingsStore.shared.hotkey = combo
            } catch {
                recorder?.setCombo(SettingsStore.shared.hotkey)
                self?.showStatusError(
                    "Couldn't register shortcut — it may conflict with macOS or another app."
                )
            }
        }

        let unpinRecorder = HotKeyRecorderControl(combo: SettingsStore.shared.unpinHotkey)
        unpinRecorder.onComboChanged = { [weak self, weak unpinRecorder] combo in
            do {
                try HotKeyManager.shared.updateCombo(combo, for: .unpin)
                SettingsStore.shared.unpinHotkey = combo
            } catch {
                unpinRecorder?.setCombo(SettingsStore.shared.unpinHotkey)
                self?.showStatusError(
                    "Couldn't register shortcut — it may duplicate the pin shortcut or conflict with macOS."
                )
            }
        }

        let shortcuts = makeSection("Shortcuts", rows: [
            makeRow(makeLabel("Toggle Pin Mode"), recorder),
            makeRow(makeLabel("Unpin All"), unpinRecorder),
        ])

        // About
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let versionValue = makeLabel(version)
        versionValue.textColor = .secondaryLabelColor

        let updateButton = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded

        let repoButton = NSButton(title: "Open", target: self, action: #selector(openGitHub))
        repoButton.bezelStyle = .rounded

        let about = makeSection("About", rows: [
            makeRow(makeLabel("Version"), versionValue),
            makeRow(makeLabel("Updates"), updateButton),
            makeRow(makeLabel("Source Code on GitHub"), repoButton),
        ])

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        let outer = NSStackView(views: [general, shortcuts, about, statusLabel])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.setCustomSpacing(22, after: general)
        outer.setCustomSpacing(22, after: shortcuts)
        outer.setCustomSpacing(10, after: about)
        outer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outer)

        // Stack alignment doesn't stretch children to a common width, so pin
        // every section to the outer stack's left and right edges explicitly.
        for view in [general, shortcuts, about, statusLabel] {
            view.leadingAnchor.constraint(equalTo: outer.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: outer.trailingAnchor).isActive = true
        }

        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthConstraint,
            outer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            outer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            outer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        contentView.layoutSubtreeIfNeeded()
        setContentSize(contentView.fittingSize)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A titled, rounded group of rows with hairline dividers, like System Settings.
    private func makeSection(_ title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor

        let headerRow = NSStackView(views: [header])
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        headerRow.orientation = .vertical
        headerRow.alignment = .leading

        var items: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                items.append(divider)
            }
            items.append(row)
        }
        let rowStack = NSStackView(views: items)
        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let group = NSView()
        group.wantsLayer = true
        group.layer?.cornerRadius = 10
        group.layer?.cornerCurve = .continuous
        group.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        group.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: group.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])

        // Pin header and box to the section's edges so every section is the
        // same width regardless of how wide its rows happen to be.
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        let section = NSStackView(views: [headerRow, group])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.translatesAutoresizingMaskIntoConstraints = false
        for view in [headerRow, group] {
            view.leadingAnchor.constraint(equalTo: section.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: section.trailingAnchor).isActive = true
        }
        return section
    }

    /// Label on the left, control on the right, inside a group.
    private func makeRow(_ label: NSView, _ control: NSView) -> NSView {
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return row
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.isHidden = text.isEmpty
    }

    // MARK: - Actions

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
            loginItemSwitch.state = service.status == .enabled ? .on : .off
        }
    }

    @objc private func toggleAutoUpdate() {
        SettingsStore.shared.autoCheckUpdates = (autoUpdateSwitch.state == .on)
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates { [weak self] state in
            guard let self else { return }
            let color: NSColor
            switch state {
            case .error: color = .systemRed
            case .upToDate: color = .systemGreen
            default: color = .secondaryLabelColor
            }
            setStatus(state.displayText, color: color)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/iamshakibali/pin-top") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showStatusError(_ text: String) {
        setStatus(text, color: .systemRed)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - HotKeyRecorderControl

/// Click-to-record shortcut field. Click → "Press shortcut..." → keyDown with a
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
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 4, y: 6, width: 138, height: 16)
        addSubview(label)
        refreshLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 146, height: 28) }

    func setCombo(_ newCombo: HotKeyCombo) {
        combo = newCombo
        refreshLabel()
    }

    private func refreshLabel() {
        label.stringValue = recording ? "Press shortcut..." : combo.displayText
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
