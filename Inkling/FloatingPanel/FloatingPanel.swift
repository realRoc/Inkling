import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    private let bridge: BridgeProcess
    private let sessions: SessionManager
    private let viewModel = ConversationViewModel()

    init(bridge: BridgeProcess, sessions: SessionManager) {
        self.bridge = bridge
        self.sessions = sessions
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        hasShadow = true

        let root = ConversationView(viewModel: viewModel)
            .environmentObject(viewModel)
        contentView = NSHostingView(rootView: root)
    }

    func present(at point: NSPoint, with selection: Selection) {
        viewModel.reset(selection: selection, bridge: bridge, sessions: sessions)

        let size = frame.size
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)

        // 屏幕边界回绕
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            if origin.x + size.width > f.maxX { origin.x = point.x - size.width - 12 }
            if origin.y < f.minY { origin.y = point.y + 12 }
        }

        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
