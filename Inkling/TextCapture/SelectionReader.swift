import AppKit
import ApplicationServices

struct Selection {
    let text: String
    let sourceApp: String?
}

enum SelectionReader {
    /// 读取当前选中文本。先走 AX，失败则回退到 pasteboard 复制法。
    static func currentSelection() -> Selection? {
        if let viaAX = readViaAccessibility() { return viaAX }
        return readViaPasteboard()
    }

    // MARK: - AX

    private static func readViaAccessibility() -> Selection? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let element = focused else { return nil }

        var selected: AnyObject?
        let selErr = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        guard selErr == .success, let text = selected as? String, !text.isEmpty else {
            return nil
        }

        return Selection(text: text, sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    // MARK: - Pasteboard 回退

    private static func readViaPasteboard() -> Selection? {
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { snapshot[type] = data }
            }
            return snapshot
        }

        sendCommandC()
        // 等 pasteboard 更新
        Thread.sleep(forTimeInterval: 0.08)

        let text = pasteboard.string(forType: .string)

        // 恢复剪贴板
        if let oldItems {
            pasteboard.clearContents()
            let restored = oldItems.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }

        guard let text, !text.isEmpty else { return nil }
        return Selection(text: text, sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    private static func sendCommandC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08 /* C */, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
