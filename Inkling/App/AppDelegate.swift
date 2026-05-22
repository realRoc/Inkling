import AppKit
import KeyboardShortcuts

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var panel: FloatingPanel?
    private let bridge = BridgeProcess()
    private let sessions = SessionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

        HotKeyManager.register(name: .summon) { [weak self] in
            self?.handleSummon()
        }

        ensureAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdown()
    }

    private func handleSummon() {
        guard let selection = SelectionReader.currentSelection(), !selection.text.isEmpty else {
            // TODO: 给个轻提示 "没读到选中文本"
            return
        }
        let cursor = CursorTracker.location()
        let panel = panel ?? FloatingPanel(bridge: bridge, sessions: sessions)
        self.panel = panel
        panel.present(at: cursor, with: selection)
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
    static let summon = Self("summonInkling", default: .init(.space, modifiers: [.command, .shift]))
}
