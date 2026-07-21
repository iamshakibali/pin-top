import SwiftUI
import AppKit
import Combine

@main
struct PinTopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let windowManager = WindowManager.shared

    init() {
        setupMenuBar()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin Top")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = createMenuBar()
        appDelegate.statusItem = statusItem
        appDelegate.windowManager = windowManager
        appDelegate.configure(with: windowManager)
    }

    private func createMenuBar() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let selectItem = NSMenuItem(title: "Enable Pin", action: #selector(AppDelegate.selectMenuItem), keyEquivalent: "")
        selectItem.target = appDelegate
        menu.addItem(selectItem)
        selectItem.tag = -1

        menu.addItem(NSMenuItem.separator())

        // Pinned-window items are inserted by updateMenu()
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear All", action: #selector(AppDelegate.clearAllMenuItem), keyEquivalent: "")
        clearItem.target = appDelegate
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Pin Top", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        // target must stay nil — terminate(_:) walks the responder chain to
        // NSApplication. Setting it to appDelegate shadows that and the quit
        // item becomes a no-op.
        menu.addItem(quitItem)

        return menu
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windowManager: WindowManager?
    private var selectionOverlayWindows: [SelectionOverlayWindow] = []

    override init() {
        super.init()
        // LSUIElement menu-bar apps have no Dock icon, so AppKit treats them
        // as auto-terminatable when their last window closes. Without this,
        // "Clear All" closing the only overlay tears the whole app down and
        // the menu-bar pin icon vanishes. Disabling prevents that.
        ProcessInfo.processInfo.disableAutomaticTermination("Pin Top runs in the menu bar")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: SwiftUI may reset state after init.
        ProcessInfo.processInfo.disableAutomaticTermination("Pin Top runs in the menu bar")
        // Menu-bar only app — SwiftUI's Settings scene auto-opens on launch.
        // Close any non-overlay window immediately.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if !(window is PinOverlayWindow) {
                    window.close()
                }
            }
        }
    }

    // Never quit just because the last NSWindow went away — the menu bar icon
    // is the UI, not the windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func configure(with windowManager: WindowManager) {
        self.windowManager = windowManager

        // Listen for pinned window changes to refresh the menu
        windowManager.$pinnedWindows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)

    }

    private var cancellables = Set<AnyCancellable>()

    @objc func selectMenuItem() {
        guard let windowManager else { return }
        // LSUIElement apps aren't the active app when their menu is clicked.
        // Activate before showing any UI so modal alerts and the picker
        // actually appear in front of the foreground app's windows.
        NSApp.activate(ignoringOtherApps: true)
        guard windowManager.enterSelectionMode() else { return }
        showSelectionOverlay()
    }

    @objc func clearAllMenuItem() {
        windowManager?.unpinAll()
        DispatchQueue.main.async { [weak self] in
            self?.updateMenu()
        }
    }

    private func updateMenu() {
        guard let menu = statusItem?.menu, let wm = windowManager else { return }

        // Remove all pinned-window items. "Enable Pin"/"Pin Another" is tag -1,
        // so pinned items start at tag -2; the condition must include -2 or
        // the first pinned entry is never reaped, duplicating on every refresh.
        let count = menu.items.count
        for i in (0..<count).reversed() {
            let tag = menu.item(at: i)?.tag ?? 0
            if tag <= -2 {
                menu.removeItem(at: i)
            }
        }

        let sorted = wm.pinnedWindows.sorted { $0.name < $1.name }
        for (index, window) in sorted.enumerated() {
            let title = "\(window.ownerName): \(window.name)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = -2 - index

            let unpinMenu = NSMenu()
            let unpinAction = NSMenuItem(title: "Unpin", action: #selector(AppDelegate.unpinMenuItem(_:)), keyEquivalent: "")
            unpinAction.target = self
            // Store the CGWindowID (NSNumber) rather than the WindowInfo
            // struct. Boxing a Swift struct into representedObject produces
            // a _SwiftValue that AppKit may release out from under its own
            // dispatch when the menu is rebuilt inside the action handler —
            // that caused the SIGSEGV at _CFAutoreleasePoolPop. Look up the
            // full WindowInfo from windowManager at unpin time instead.
            unpinAction.representedObject = NSNumber(value: window.id)
            unpinMenu.addItem(unpinAction)

            item.submenu = unpinMenu
            menu.insertItem(item, at: 2 + index)
        }

        // Update "Enable Pin" → "Pin Another" label
        if let firstItem = menu.item(at: 0) {
            firstItem.title = wm.pinnedWindows.count > 0 ? "Pin Another" : "Enable Pin"
        }
    }

    @objc func unpinMenuItem(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let wm = windowManager else { return }
        // Find the matching pinned WindowInfo by CGWindowID. We stash only
        // the ID in representedObject instead of the WindowInfo struct to
        // avoid boxing a Swift struct (see updateMenu() for why).
        let windowID = CGWindowID(id)
        guard let window = wm.pinnedWindows.first(where: { $0.id == windowID }) else { return }
        wm.unpin(window)
        DispatchQueue.main.async { [weak self] in
            self?.updateMenu()
        }
    }

    private func showSelectionOverlay() {
        hideSelectionOverlay()
        guard let wm = windowManager else { return }

        for screen in NSScreen.screens {
            let overlayWindow = SelectionOverlayWindow(screen: screen) { [weak self, weak wm] point in
                // Hide every selection window before capture. This avoids
                // capturing the picker and ensures each overlay is dismissed once.
                self?.hideSelectionOverlay()

                guard let wm else { return }
                if let point, let window = wm.selectWindow(at: point) {
                    wm.pin(window)
                }
                wm.exitSelectionMode()
            }
            overlayWindow.makeKeyAndOrderFront(nil)
            selectionOverlayWindows.append(overlayWindow)
        }
    }

    private func hideSelectionOverlay() {
        // Ordering out is safe while a mouse event is still being handled.
        // Removing the last strong references lets ARC clean up after the
        // event returns, rather than closing the clicked window twice.
        let overlays = selectionOverlayWindows
        selectionOverlayWindows.removeAll()
        overlays.forEach { $0.orderOut(nil) }
    }
}
