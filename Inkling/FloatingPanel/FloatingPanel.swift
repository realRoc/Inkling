import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    private let bridge: BridgeProcess
    private let sessions: SessionManager
    private let viewModel = ConversationViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var anchorPoint: NSPoint = .zero
    /// 唤起前的前台 app。close 时主动激活它，避免 Inkling 进程残留 active
    /// 状态把 systemWide AX focus 钉在自己身上——这是"第二次读不到选区"的根因。
    private weak var previousApp: NSRunningApplication?
    /// 点击浮窗外部自动关闭。全局 monitor 收不到自身进程的事件，
    /// 所以点 Inkling 内部按钮不会误触发。
    private var clickOutsideMonitor: Any?

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

    func present(at point: NSPoint, with selection: Selection, targetApp: NSRunningApplication?) {
        anchorPoint = point
        // 优先用调用方算好的 targetApp（含"Inkling 卡前台时退回到最近记录"的兜底）；
        // 没传就退回到当前前台。close 时用它把焦点还回去；retry 时用它直接按 PID 读 AX。
        if let target = targetApp {
            previousApp = target
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        viewModel.prepare(selection: selection, bridge: bridge, sessions: sessions, targetApp: previousApp)
        adjustFrame(for: viewModel.mode)
        orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // global monitor 只收外部进程事件；点 Inkling 自身按钮不会触发这里
            self.close()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
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

    override func close() {
        removeClickOutsideMonitor()
        viewModel.resetForClose()
        makeFirstResponder(nil)
        super.close()
        // 让 Inkling 让出 active 状态。macOS 14 起协作激活：deprecated 的 NSApp.deactivate()
        // 在新系统上经常 no-op，必须显式 yieldActivation(to:)，previousApp.activate() 才能真正生效；
        // 否则 Inkling 会卡在前台，systemWide AX focus 一直钉在自己身上，下次唤起读不到选区。
        if let prev = previousApp {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: prev)
            } else {
                NSApp.deactivate()
            }
            prev.activate(options: [])
        } else {
            NSApp.deactivate()
        }
    }
}
