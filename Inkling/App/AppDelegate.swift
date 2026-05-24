import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var panel: FloatingPanel?
    private let bridge = BridgeProcess()
    private let sessions = SessionManager()
    /// 最近一次被激活的非自身 app。用 NSWorkspace 通知维护，这样即使 Inkling 自己
    /// 卡在前台（导致 frontmostApplication == self），我们仍知道用户原本在哪个 app。
    /// 唤起时优先把它作为读选区的目标——按 PID 走 AX，绕开 systemWide focus 的卡死。
    /// 用强引用：弱引用一旦被提前回收，fallback 路径会跳空。读取时再判 isTerminated。
    private var lastUserApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

        // 启动时如果当前前台已经是用户 app，先记一笔，省得首次唤起还要兜底。
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastUserApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            diagLog.notice("DidActivate \(app.localizedName ?? "nil", privacy: .public) pid=\(app.processIdentifier, privacy: .public) isSelf=\(app.bundleIdentifier == Bundle.main.bundleIdentifier ? "true" : "false", privacy: .public)")
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastUserApp = app
        }

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
        let front = NSWorkspace.shared.frontmostApplication
        diagLog.notice("Summon front=\(front?.localizedName ?? "nil", privacy: .public) frontPid=\(front?.processIdentifier ?? -1, privacy: .public) lastUserApp=\(self.lastUserApp?.localizedName ?? "nil", privacy: .public) lastUserPid=\(self.lastUserApp?.processIdentifier ?? -1, privacy: .public) panelVisible=\((self.panel?.isVisible ?? false) ? "true" : "false", privacy: .public)")
        // ⌘⇧Space 是 toggle：浮窗已显示时再按一次直接关掉。
        if let panel, panel.isVisible {
            diagLog.notice("Summon toggle-close")
            panel.close()
            return
        }
        // 确定"读哪个 app 的选区"：当前前台 app（排除自身），否则用最近记录的非自身 app。
        // 后者兜住"Inkling 卡前台导致 frontmostApplication 是自己"的情况。lastUserApp 已退出的话
        // 也别用——AX 已经查不到了。
        let targetApp: NSRunningApplication? = {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                return front
            }
            if let last = lastUserApp, !last.isTerminated {
                return last
            }
            return nil
        }()
        diagLog.notice("Summon targetApp=\(targetApp?.localizedName ?? "nil", privacy: .public) pid=\(targetApp?.processIdentifier ?? -1, privacy: .public)")
        // 有选区就带选区进来；没有也唤起一个空会话，让用户直接输入问题。
        let selection = SelectionReader.currentSelection(for: targetApp)
            ?? Selection(text: "", sourceApp: nil)
        diagLog.notice("Summon selection len=\(selection.text.count, privacy: .public) source=\(selection.sourceApp ?? "nil", privacy: .public)")
        present(selection: selection, at: CursorTracker.location(), targetApp: targetApp)
    }

    private func present(selection: Selection, at point: NSPoint, targetApp: NSRunningApplication?) {
        let panel = panel ?? FloatingPanel(bridge: bridge, sessions: sessions)
        self.panel = panel
        panel.present(at: point, with: selection, targetApp: targetApp)
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
