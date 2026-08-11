import SwiftUI
import AppKit
import Combine

@main
struct PinTopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windowManager: WindowManager?
    private var statusMenu: NSMenu!
    private var selectionOverlayWindows: [SelectionOverlayWindow] = []
    private var aboutWindow: AboutWindow?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        ProcessInfo.processInfo.disableAutomaticTermination("Pin Top runs in the menu bar")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Pin Top runs in the menu bar")

        setupStatusBar()

        // Close SwiftUI's auto-opened Settings window.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if !(window is PinOverlayWindow) && !(window is AboutWindow) {
                    window.close()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupStatusBar() {
        guard statusItem == nil else { return }
        NSLog("[PinTop] setupStatusBar: starting")

        statusMenu = buildMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSLog("[PinTop] ERROR: no status item button")
            return
        }

        if let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin Top") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "Pin"
        }

        // Standard AppKit pattern: attach the menu directly to the status item.
        // target/action on NSStatusBarButton under SwiftUI can be unreliable;
        // the menu-pop pattern is the stable path.
        item.menu = statusMenu

        statusItem = item
        windowManager = WindowManager.shared
        configure(with: WindowManager.shared)
    }

    // Not used when the menu is attached directly to the status item.
    // Kept in case we ever need programmatic menu popup.
    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        menu.popUp(
            positioning: menu.item(at: 0),
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let selectItem = NSMenuItem(title: "Enable Pin", action: #selector(selectMenuItem), keyEquivalent: "")
        selectItem.target = self
        selectItem.tag = -1
        menu.addItem(selectItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem.separator()) // placeholder for pinned-window items

        let clearItem = NSMenuItem(title: "Clear All", action: #selector(clearAllMenuItem), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Pin Top", action: #selector(aboutMenuItem), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkUpdatesMenuItem), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())

        // target must stay nil — terminate(_:) walks the responder chain to
        // NSApplication. Setting it to appDelegate shadows that and the quit
        // item becomes a no-op.
        let quitItem = NSMenuItem(title: "Quit Pin Top", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    private func configure(with windowManager: WindowManager) {
        self.windowManager = windowManager
        windowManager.$pinnedWindows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)
    }

    @objc func selectMenuItem() {
        guard let windowManager else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard windowManager.enterSelectionMode() else { return }
        showSelectionOverlay()
    }

    @objc func clearAllMenuItem() {
        windowManager?.unpinAll()
        // orderOut (not close) keeps the NSWindow alive but hidden,
        // avoiding the auto-termination "last window closed" hook.
        DispatchQueue.main.async { [weak self] in self?.updateMenu() }
    }

    @objc func aboutMenuItem() {
        if aboutWindow == nil { aboutWindow = AboutWindow() }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkUpdatesMenuItem() {
        AppUpdater.shared.checkForUpdates { state in
            switch state {
            case .upToDate:
                let alert = NSAlert()
                alert.messageText = "You're up to date!"
                alert.informativeText = "Pin Top is already running the latest version."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .available(let version):
                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "Pin Top \(version) is being downloaded and installed."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .error(let msg):
                let alert = NSAlert()
                alert.messageText = "Update Check Failed"
                alert.informativeText = msg
                alert.addButton(withTitle: "OK")
                alert.runModal()
            default:
                break
            }
        }
    }

    private func updateMenu() {
        guard let menu = statusMenu, let wm = windowManager else { return }

        for i in (0..<menu.items.count).reversed() {
            if (menu.item(at: i)?.tag ?? 0) <= -2 { menu.removeItem(at: i) }
        }

        let sorted = wm.pinnedWindows.sorted { $0.name < $1.name }
        for (index, window) in sorted.enumerated() {
            let item = NSMenuItem(title: "\(window.ownerName): \(window.name)", action: nil, keyEquivalent: "")
            item.tag = -2 - index

            let unpinMenu = NSMenu()
            let unpinAction = NSMenuItem(title: "Unpin", action: #selector(unpinMenuItem(_:)), keyEquivalent: "")
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

        if let first = menu.item(at: 0) {
            first.title = wm.pinnedWindows.isEmpty ? "Enable Pin" : "Pin Another"
        }
    }

    @objc func unpinMenuItem(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let wm = windowManager else { return }
        let windowID = CGWindowID(id)
        guard let window = wm.pinnedWindows.first(where: { $0.id == windowID }) else { return }
        wm.unpin(window)
        DispatchQueue.main.async { [weak self] in self?.updateMenu() }
    }

    private func showSelectionOverlay() {
        hideSelectionOverlay()
        guard let wm = windowManager else { return }
        for screen in NSScreen.screens {
            let overlay = SelectionOverlayWindow(screen: screen) { [weak self, weak wm] point in
                self?.hideSelectionOverlay()
                guard let wm else { return }
                if let point, let window = wm.selectWindow(at: point) { wm.pin(window) }
                wm.exitSelectionMode()
            }
            overlay.makeKeyAndOrderFront(nil)
            selectionOverlayWindows.append(overlay)
        }
    }

    private func hideSelectionOverlay() {
        let overlays = selectionOverlayWindows
        selectionOverlayWindows.removeAll()
        overlays.forEach { $0.orderOut(nil) }
    }
}
