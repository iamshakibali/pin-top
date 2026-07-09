import Cocoa
import Combine

/// Builds and manages the NSStatusBar menu for Window Pin.
class MenuBuilder {
    static let shared = MenuBuilder()

    private var statusItem: NSStatusItem?
    private var windowManager: WindowManager?
    private var menu: NSMenu?
    private var pinnedWindowItems: [NSMenuItem] = []
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Setup

    func configure(with windowManager: WindowManager, statusItem: NSStatusItem?) {
        self.windowManager = windowManager
        self.statusItem = statusItem

        let menu = NSMenu()
        menu.autoenablesItems = false

        // --- "Enable Pin" / "Pin Another" item ---
        let selectItem = NSMenuItem(
            title: "Enable Pin",
            action: #selector(selectMenuItem),
            keyEquivalent: ""
        )
        selectItem.target = self
        menu.addItem(selectItem)
        selectItem.tag = -1 // anchor: first item

        menu.addItem(NSMenuItem.separator())

        // --- pinned window items (inserted dynamically) ---
        // tag = -2 anchor: separator before list

        // --- "Clear All" ---
        let clearItem = NSMenuItem(
            title: "Clear All",
            action: #selector(clearAllMenuItem),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(
            title: "Quit Window Pin",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        statusItem?.menu = menu
        updateEnablePinTitle()
    }

    // MARK: - Refresh

    /// Called when pinned windows change — rebuilds the pinned window list.
    func refresh() {
        guard let menu = menu else { return }

        // Remove old pinned window items
        let itemsToRemove = pinnedWindowItems.filter { menu.item(withTag: $0.tag) != nil }
        for item in itemsToRemove {
            menu.removeItem(item)
        }
        pinnedWindowItems.removeAll()

        guard let pinned = windowManager?.pinnedWindows else { return }

        let sorted = pinned.sorted { $0.name < $1.name }
        for (index, window) in sorted.enumerated() {
            let title = "\(window.ownerName): \(window.name)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = -2 - index // unique negative tag

            // Right-side "Unpin" submenu
            let unpinMenu = NSMenu()
            let unpinAction = NSMenuItem(title: "Unpin", action: #selector(unpinMenuItem(_:)), keyEquivalent: "")
            unpinAction.target = self
            unpinAction.representedObject = window
            unpinMenu.addItem(unpinAction)

            // "Copy Window Info" helper
            let copyAction = NSMenuItem(title: "Copy Info", action: #selector(copyInfoMenuItem(_:)), keyEquivalent: "")
            copyAction.target = self
            copyAction.representedObject = window
            unpinMenu.addItem(copyAction)

            item.submenu = unpinMenu

            // Insert after the "Enable Pin" item and separator
            menu.insertItem(item, at: 2 + index)
            pinnedWindowItems.append(item)
        }

        updateEnablePinTitle()
    }

    private func updateEnablePinTitle() {
        guard let menu = menu,
              let firstItem = menu.item(withTag: -1) else { return }
        let count = windowManager?.pinnedWindows.count ?? 0
        firstItem.title = count > 0 ? "Pin Another" : "Enable Pin"
    }

    // MARK: - Actions

    @objc private func selectMenuItem() {
        windowManager?.enterSelectionMode()
    }

    @objc private func clearAllMenuItem() {
        windowManager?.unpinAll()
        refresh()
    }

    @objc private func unpinMenuItem(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        windowManager?.unpin(window)
        refresh()
    }

    @objc private func copyInfoMenuItem(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        let text = "PID: \(window.pid)\nTitle: \(window.name)\nApp: \(window.ownerName)\nBounds: \(window.bounds)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
