import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    init<Content: View>(@ViewBuilder view: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenAuxiliary]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        animationBehavior = .utilityWindow

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        contentView = NSHostingView(rootView: view().ignoresSafeArea())
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }
}
