import SwiftUI
import AppKit
import Combine

@main
struct WindowPinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            // Hidden settings view — app runs entirely from status bar.
            // Info.plist has LSUIElement = true so no Dock/Cmd+Tab icon.
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let windowManager = WindowManager.shared
    private var overlayObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Window Pin")
        statusItem?.button?.image?.isTemplate = true

        // Request accessibility permission on launch
        windowManager.requestAccessibilityPermission()

        // Build menu
        MenuBuilder.shared.configure(with: windowManager, statusItem: statusItem)

        // Watch selection mode to show/hide overlay
        overlayObserver = windowManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak windowManager] in
                guard let wm = windowManager else { return }
                if wm.isSelecting {
                    self?.showSelectionOverlay()
                } else {
                    self?.hideSelectionOverlay()
                }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayObserver = nil
    }

    private var selectionOverlayWindow: SelectionOverlayWindow?

    private func showSelectionOverlay() {
        // Close any existing overlay first
        hideSelectionOverlay()

        guard let screen = NSScreen.main else { return }
        let overlayWindow = SelectionOverlayWindow(screen: screen) { [weak windowManager] point in
            guard let wm = windowManager else { return }
            if let window = wm.selectWindow(at: point) {
                wm.pin(window)
            }
            wm.exitSelectionMode()
        }
        overlayWindow.makeKeyAndOrderFront(nil)
        selectionOverlayWindow = overlayWindow
    }

    private func hideSelectionOverlay() {
        selectionOverlayWindow?.close()
        selectionOverlayWindow = nil
    }
}
