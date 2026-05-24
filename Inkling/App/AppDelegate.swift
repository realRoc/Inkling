import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var panel: FloatingPanel?
    private let bridge = BridgeProcess()
    private let sessions = SessionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

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
        bridge.shutdown()
    }

    private func handleManualSummon() {
        // ⌘⇧Space 是 toggle：浮窗已显示时再按一次直接关掉。
        if let panel, panel.isVisible {
            panel.close()
            return
        }
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
        // 不传 prompt，否则系统会自己弹一个浅信息量的辅助功能对话框，和下面自定义的弹窗叠一起。
        if !AXIsProcessTrusted() {
            NSLog("Inkling: Accessibility 权限未授予，划词功能将无法工作。")
            DispatchQueue.main.async { Self.promptForAccessibility() }
        }
    }

    /// 没 AX 权限时弹窗引导，并提供一键跳系统设置。
    private static func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "需要 Accessibility 权限"
        alert.informativeText = """
        Inkling 需要 Accessibility 权限才能读取你选中的文本。
        请在「系统设置 → 隐私与安全 → 辅助功能」里把 Inkling 打开。
        每次重新安装 Inkling.app 后都需要重新勾选。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
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
