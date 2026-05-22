import AppKit

/// 监听全局鼠标拖选：down + up 之间距离 > 阈值，且选区非空 → 触发回调。
///
/// 之所以不用 `kAXSelectedTextChangedNotification`：
///   1) 要给每个 frontmost app 重新挂 AXObserver，App 切换时管理复杂
///   2) 输入光标本身也会发该通知（高频噪音）
///
/// mouse-up 之后短延时再读 AX 选区，避免抢在系统更新前读到旧值。
final class SelectionWatcher {
    private var globalDownMonitor: Any?
    private var globalUpMonitor: Any?
    private var dragStart: NSPoint?
    private var lastTrigger: Date = .distantPast

    /// 拖动距离阈值（点）。小于此值视为点击，不触发。
    private let minDragDistance: CGFloat = 6
    /// 两次触发的最小间隔（秒）。
    private let throttleInterval: TimeInterval = 0.2
    /// mouse-up 后等待系统更新选区的延时（秒）。
    private let selectionSettleDelay: TimeInterval = 0.05

    var onSelection: ((Selection, NSPoint) -> Void)?

    func start() {
        globalDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dragStart = NSEvent.mouseLocation
        }
        globalUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.handleMouseUp()
        }
    }

    func stop() {
        [globalDownMonitor, globalUpMonitor]
            .compactMap { $0 }
            .forEach(NSEvent.removeMonitor)
        globalDownMonitor = nil
        globalUpMonitor = nil
    }

    private func handleMouseUp() {
        let upPoint = NSEvent.mouseLocation
        defer { dragStart = nil }
        guard let start = dragStart else { return }

        // 单纯点击不算划词
        guard hypot(upPoint.x - start.x, upPoint.y - start.y) >= minDragDistance else { return }

        // 节流
        let now = Date()
        guard now.timeIntervalSince(lastTrigger) >= throttleInterval else { return }

        // 等系统选区更新到位再读
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionSettleDelay) { [weak self] in
            guard let self else { return }
            guard let selection = SelectionReader.currentSelection() else { return }
            let trimmed = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.lastTrigger = Date()
            self.onSelection?(selection, upPoint)
        }
    }
}
