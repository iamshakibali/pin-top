import Cocoa

class AboutWindow: NSWindow {
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let windowSize = NSSize(width: 340, height: 420)
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

        title = "About Pin Top"
        isReleasedWhenClosed = false
        center()
        buildUI()
    }

    private func buildUI() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // App icon — larger, centered
        let iconSize: CGFloat = 128
        let iconX = (340 - iconSize) / 2
        let iconView = NSImageView(frame: NSRect(x: iconX, y: 260, width: iconSize, height: iconSize))
        let appIcon = NSImage(named: "PinTop") ?? NSWorkspace.shared.icon(forFileType: "app")
        iconView.image = appIcon
        iconView.image?.size = NSSize(width: iconSize, height: iconSize)
        contentView.addSubview(iconView)

        // App name — bold, centered
        let nameLabel = NSTextField(labelWithString: "Pin Top")
        nameLabel.font = .systemFont(ofSize: 18, weight: .bold)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: 220, width: 340, height: 24)
        contentView.addSubview(nameLabel)

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: 198, width: 340, height: 18)
        contentView.addSubview(versionLabel)

        // Developer credit with GitHub link
        let creditButton = NSButton(title: "by Shakib", target: self, action: #selector(openGitHub))
        creditButton.bezelStyle = .inline
        creditButton.isBordered = false
        creditButton.font = .systemFont(ofSize: 13)
        creditButton.frame = NSRect(x: 110, y: 170, width: 120, height: 20)
        contentView.addSubview(creditButton)

        // Check for Updates button
        let updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        updateButton.font = .systemFont(ofSize: 13)
        updateButton.frame = NSRect(x: 95, y: 130, width: 150, height: 30)
        contentView.addSubview(updateButton)

        // Status label
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 10, y: 100, width: 320, height: 16)
        contentView.addSubview(statusLabel)
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/iamshakibali/pin-top") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates { [weak self] state in
            self?.statusLabel.stringValue = state.displayText
            // Color-code the status
            switch state {
            case .error:
                self?.statusLabel.textColor = .systemRed
            case .upToDate:
                self?.statusLabel.textColor = .systemGreen
            default:
                self?.statusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
