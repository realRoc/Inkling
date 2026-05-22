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
        menu.addItem(.init(title: "Inkling", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
