import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let toggleItem: NSMenuItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggleItem = NSMenuItem(
            title: "启用划词",
            action: #selector(toggleWatcher),
            keyEquivalent: ""
        )
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Inkling")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let title = NSMenuItem(title: "Inkling", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        toggleItem.target = self
        toggleItem.state = AppSettings.watcherEnabled ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let summon = NSMenuItem(
            title: "唤起 Inkling",
            action: #selector(summonPanel),
            keyEquivalent: ""
        )
        summon.target = self
        menu.addItem(summon)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        // Quit 让 NSApplication 自己处理，不设 target。
        menu.addItem(quit)

        statusItem.menu = menu

        // 外部（比如 Settings 里直接改 UserDefaults）切换时，菜单勾选状态同步。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshToggleState),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func summonPanel() {
        NotificationCenter.default.post(name: .inklingManualSummon, object: nil)
    }

    @objc private func toggleWatcher() {
        let next = !AppSettings.watcherEnabled
        AppSettings.setWatcherEnabled(next)
        toggleItem.state = next ? .on : .off
    }

    @objc private func refreshToggleState() {
        toggleItem.state = AppSettings.watcherEnabled ? .on : .off
    }

    @objc private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // macOS 14+ 用 showSettingsWindow:，13 还在用 showPreferencesWindow:。
        // 两个都试一下，谁能响应谁打开。
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
