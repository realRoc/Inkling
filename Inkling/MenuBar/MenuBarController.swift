import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    }

    @objc private func summonPanel() {
        NotificationCenter.default.post(name: .inklingManualSummon, object: nil)
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
