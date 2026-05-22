import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    private let bridge: BridgeProcess
    private let sessions: SessionManager
    private let viewModel = ConversationViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var anchorPoint: NSPoint = .zero

    /// SwiftUI 内部已经画了卡片+阴影，所以这里的尺寸要给阴影留 padding 空间。
    private static let toolbarSize = NSSize(width: 660, height: 56)
    private static let conversationSize = NSSize(width: 496, height: 396)

    init(bridge: BridgeProcess, sessions: SessionManager) {
        self.bridge = bridge
        self.sessions = sessions
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.toolbarSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // SwiftUI 内部画阴影，原生阴影会和它叠加显得脏
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = ConversationView()
            .environmentObject(viewModel)
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView = host

        viewModel.$mode
            .removeDuplicates()
            .sink { [weak self] mode in self?.adjustFrame(for: mode) }
            .store(in: &cancellables)
    }

    func present(at point: NSPoint, with selection: Selection) {
        anchorPoint = point
        viewModel.prepare(selection: selection, bridge: bridge, sessions: sessions)
        adjustFrame(for: viewModel.mode)
        orderFrontRegardless()
    }

    private func adjustFrame(for mode: ConversationViewModel.Mode) {
        let targetSize: NSSize
        switch mode {
        case .toolbar: targetSize = Self.toolbarSize
        case .conversation: targetSize = Self.conversationSize
        }

        let point = anchorPoint == .zero ? NSEvent.mouseLocation : anchorPoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        var origin = NSPoint(x: point.x - targetSize.width / 2, y: point.y - targetSize.height - 12)
        if let f = screen?.visibleFrame {
            origin.x = max(f.minX + 8, min(origin.x, f.maxX - targetSize.width - 8))
            if origin.y < f.minY + 8 { origin.y = point.y + 12 }
            origin.y = max(f.minY + 8, min(origin.y, f.maxY - targetSize.height - 8))
        }

        setFrame(NSRect(origin: origin, size: targetSize), display: true, animate: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
