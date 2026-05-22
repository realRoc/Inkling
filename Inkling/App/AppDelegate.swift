import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var panel: FloatingPanel?
    private let bridge = BridgeProcess()
    private let sessions = SessionManager()
    private let watcher = SelectionWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 一次性把旧的"拖选自动弹"开关清掉——新默认是关。用户想要可以从菜单重新开。
        let watcherMigratedKey = "watcherEnabledMigratedV2"
        if !UserDefaults.standard.bool(forKey: watcherMigratedKey) {
            UserDefaults.standard.removeObject(forKey: AppSettings.watcherEnabledKey)
            UserDefaults.standard.set(true, forKey: watcherMigratedKey)
        }

        menuBar = MenuBarController()

        // 拖选自动弹出已停用——容易误触。仅靠快捷键 / 状态栏主动唤起。
        // watcher.onSelection 仍保留接线，方便将来在 Settings 里加开关重新启用。
        watcher.onSelection = { [weak self] selection, point in
            self?.present(selection: selection, at: point)
        }
        if AppSettings.watcherEnabled { watcher.start() }

        // 默认快捷键 ⌘⇧Space。用 V2 迁移键覆盖之前默认的 ⌘⇧E 一次，之后用户改的就不再被覆盖。
        let defaultMigratedKey = "summonShortcutDefaultV2"
        if !UserDefaults.standard.bool(forKey: defaultMigratedKey) {
            KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.command, .shift]), for: .summon)
            UserDefaults.standard.set(true, forKey: defaultMigratedKey)
        }
        HotKeyManager.register(name: .summon) { [weak self] in
            self?.handleManualSummon()
        }

        // 状态栏菜单的"唤起 Inkling"项发出此通知
        NotificationCenter.default.addObserver(
            forName: .inklingManualSummon,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleManualSummon()
        }

        ensureAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        bridge.shutdown()
    }

    private func handleManualSummon() {
        // 有选区就带选区进来；没有也唤起一个空会话，让用户直接输入问题。
        let selection = SelectionReader.currentSelection()
            ?? Selection(text: "", sourceApp: nil)
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
    /// 手动唤起快捷键。首次启动给个默认值（⌘⇧E），用户可在 Settings 里改。
    static let summon = Self("summonInkling")
}

extension Notification.Name {
    /// 状态栏菜单点"唤起 Inkling"时发出。
    static let inklingManualSummon = Notification.Name("inklingManualSummon")
}
