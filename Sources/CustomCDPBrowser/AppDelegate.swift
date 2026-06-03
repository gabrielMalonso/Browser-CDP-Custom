import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self(
        "toggleOverlay",
        default: .init(.z, modifiers: [.control, .shift])
    )
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var isShowing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LinkRouter.shared.onShowOverlay = { [weak self] in
            self?.showPanel()
        }

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        if let icnsURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: icnsURL) {
            NSApp.applicationIconImage = icon
        }

        KeyboardShortcuts.onKeyDown(for: .toggleOverlay) { [weak self] in
            self?.togglePanel()
        }

        DispatchQueue.main.async {
            self.togglePanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return false
    }

    func togglePanel() {
        if isShowing, let panel {
            panel.close()
            isShowing = false
            return
        }

        showPanel()
    }

    func showPanel() {
        if isShowing {
            panel?.orderFrontRegardless()
            panel?.makeKey()
            NSApp.activate()
            return
        }

        let panel = FloatingPanel {
            ProfilePickerView {
                self.closePanel()
            }
        }
        self.panel = panel

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = panel.frame
            let x = screenFrame.midX - panelFrame.width / 2
            let y = screenFrame.midY - panelFrame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate()
        isShowing = true
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else {
            return
        }

        LinkRouter.shared.handleIncomingURL(url)
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        isShowing = false
    }
}
