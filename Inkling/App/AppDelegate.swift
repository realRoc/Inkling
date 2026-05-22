import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var panel: FloatingPanel?
    private let bridge = BridgeProcess()
    private let sessions = SessionManager()
    private let watcher = SelectionWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

        // 主触发：拖选文本 → 自动弹出
        watcher.onSelection = { [weak self] selection, point in
            self?.present(selection: selection, at: point)
        }
        watcher.start()

        // 可选辅助：用户可在 Settings 自定义一个快捷键，默认不设
        HotKeyManager.register(name: .summon) { [weak self] in
            self?.handleManualSummon()
        }

        ensureAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        bridge.shutdown()
    }

    private func handleManualSummon() {
        guard let selection = SelectionReader.currentSelection(), !selection.text.isEmpty else { return }
        present(selection: selection, at: CursorTracker.location())
    }

    private func present(selection: Selection, at point: NSPoint) {
        let panel = panel ?? FloatingPanel(bridge: bridge, sessions: sessions)
        self.panel = panel
        panel.present(at: point, with: selection)
    }

    private func ensureAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted {
            NSLog("Inkling: Accessibility 权限未授予，划词功能将无法工作。")
        }
    }
}

extension KeyboardShortcuts.Name {
    /// 可选的手动唤起快捷键。默认不设，让用户在 Settings 里自己绑。
    static let summon = Self("summonInkling")
}
