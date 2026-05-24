import AppKit
import ApplicationServices

struct Selection {
    let text: String
    let sourceApp: String?
}

enum SelectionReader {
    /// 读取当前选中文本。
    /// - Parameter app: 已知的目标 app（用户唤起 Inkling 之前所在的那个）。若提供，优先
    ///   按 PID 直接读它的 focused element——这条路绕开 systemWide focus，即使 Inkling
    ///   把自己卡成前台（macOS 14+ 协作式激活下，deactivate 经常 no-op）也能拿到选区。
    static func currentSelection(for app: NSRunningApplication? = nil) -> Selection? {
        let front = NSWorkspace.shared.frontmostApplication
        diagLog.notice("SelectionReader.entry targetApp=\(app?.localizedName ?? "nil", privacy: .public) pid=\(app?.processIdentifier ?? -1, privacy: .public) front=\(front?.localizedName ?? "nil", privacy: .public) frontPid=\(front?.processIdentifier ?? -1, privacy: .public)")
        if let app, !app.isTerminated {
            if let viaApp = readViaAccessibility(for: app) {
                diagLog.notice("SelectionReader.PID_AX_HIT len=\(viaApp.text.count, privacy: .public)")
                return viaApp
            }
            diagLog.notice("SelectionReader.PID_AX_MISS")
            // 目标 app 与当前前台不一致时不能走 systemWide / pasteboard fallback：
            // pasteboard 路径会 Cmd+C 给前台 app（很可能是 Inkling 自己），把面板
            // TextField 或旧剪贴板内容误当成用户选区。前台一致时再回落，Cmd+C 才会发给目标 app。
            guard front?.processIdentifier == app.processIdentifier else {
                diagLog.notice("SelectionReader.GATE_BLOCKED front!=target, return nil")
                return nil
            }
        }
        if let viaAX = readViaAccessibility() {
            diagLog.notice("SelectionReader.SYSTEM_AX_HIT len=\(viaAX.text.count, privacy: .public)")
            return viaAX
        }
        diagLog.notice("SelectionReader.SYSTEM_AX_MISS, fallback to pasteboard")
        let result = readViaPasteboard()
        diagLog.notice("SelectionReader.PB_RESULT \(result.map { "HIT len=\($0.text.count)" } ?? "MISS", privacy: .public)")
        return result
    }

    // MARK: - AX

    /// 按 PID 直接读指定 app 的 focused element。
    /// systemWide focus 跟前台 app 走；若 Inkling 自己卡在前台（panel 被点过没让出 active），
    /// systemWide 路径会读到 Inkling 自身的 TextField。这条路用 AXUIElementCreateApplication
    /// 锁定目标 app，跟前台无关。
    private static func readViaAccessibility(for app: NSRunningApplication) -> Selection? {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            diagLog.notice("PID_AX skip: target is Inkling self")
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else {
            diagLog.notice("PID_AX no focused element err=\(err.rawValue, privacy: .public)")
            return nil
        }
        let axElement = element as! AXUIElement
        if let text = copyString(axElement, kAXSelectedTextAttribute) {
            diagLog.notice("PID_AX got selected text via AXSelectedText")
            return Selection(text: text, sourceApp: app.localizedName)
        }
        if let text = sliceFromRange(axElement) {
            diagLog.notice("PID_AX got selected text via range slice")
            return Selection(text: text, sourceApp: app.localizedName)
        }
        diagLog.notice("PID_AX focused element has no selection")
        return nil
    }

    private static func readViaAccessibility() -> Selection? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let element = focused else { return nil }
        let axElement = element as! AXUIElement

        // systemWide focused element 跟前台 app 走。若 Inkling 自己仍卡在 active 状态
        // （deactivate 在 macOS 14+ 上常常没生效），focus 会指到自家的 TextField——
        // 那读出来的不是用户选区。直接判无效，让 caller 走 PID 路径或 pasteboard。
        var pid: pid_t = 0
        if AXUIElementGetPid(axElement, &pid) == .success,
           pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        // 1) 标准路径：直接读 AXSelectedText（很多原生 NSTextView/NSTextField 都支持）
        if let text = copyString(axElement, kAXSelectedTextAttribute) {
            return Selection(text: text, sourceApp: frontApp())
        }

        // 2) Fallback：拿 AXSelectedTextRange + AXValue 自己切片。
        //    Safari / 部分 Web view / Pages / Sublime 之类只暴露这条。
        if let text = sliceFromRange(axElement) {
            return Selection(text: text, sourceApp: frontApp())
        }

        return nil
    }

    private static func copyString(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : s
    }

    /// 通过 AXSelectedTextRange + AXValue 切片。range 是 CFRange (location/length)。
    private static func sliceFromRange(_ element: AXUIElement) -> String? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              CFGetTypeID(rangeValue!) == AXValueGetTypeID() else { return nil }

        var range = CFRange(location: 0, length: 0)
        let axValue = rangeValue as! AXValue
        guard AXValueGetValue(axValue, .cfRange, &range), range.length > 0 else { return nil }

        var fullValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullValue) == .success,
              let full = fullValue as? String else { return nil }

        // 用 UTF-16 视图切片——AX range 是 UTF-16 单位。
        let utf16 = Array(full.utf16)
        let start = max(0, range.location)
        let end = min(utf16.count, range.location + range.length)
        guard start < end else { return nil }
        let slice = Array(utf16[start..<end])
        let text = String(utf16CodeUnits: slice, count: slice.count)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func frontApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Pasteboard 回退
    //
    // 思路：
    // 1. 等用户从快捷键里松开 ⌘/⇧/⌥/⌃（否则 Cmd+C 会被污染成 ⌘⇧C 等）
    // 2. 备份当前 pasteboard
    // 3. clear → sendCommandC → 用 changeCount 检测「真的发生过一次新的写入」
    // 4. 读出新内容；若 changeCount 没增加，说明 Cmd+C 没生效，返回 nil（避免把用户的旧剪贴板当成"选中文本"）
    // 5. 恢复 pasteboard

    private static func readViaPasteboard() -> Selection? {
        let frontAtStart = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        diagLog.notice("PB.start front=\(frontAtStart, privacy: .public)")
        waitForModifiersToClear(timeout: 0.4)

        let pasteboard = NSPasteboard.general
        let backup = backupPasteboard(pasteboard)

        let baseline = pasteboard.changeCount
        pasteboard.clearContents()
        let afterClear = pasteboard.changeCount

        sendCommandC()

        // 轮询等待 Cmd+C 真的把数据写进 pasteboard
        let deadline = Date().addingTimeInterval(0.5)
        var copied = false
        while Date() < deadline {
            if pasteboard.changeCount > afterClear {
                copied = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        diagLog.notice("PB.cmdC copied=\(copied ? "true" : "false", privacy: .public) frontAfter=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil", privacy: .public)")

        let text: String? = copied ? pasteboard.string(forType: .string) : nil

        restorePasteboard(pasteboard, backup: backup, baseline: baseline)

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagLog.notice("PB.empty_or_whitespace")
            return nil
        }
        return Selection(text: text, sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// 等所有按住的 modifier 松开。最长等 timeout 秒。
    /// 必要时主线程 sleep —— 但 panel 还没显示，体感上是「快捷键按下 → 短暂等待 → 弹窗」。
    private static func waitForModifiersToClear(timeout: TimeInterval) {
        let modifiersToWatch: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(modifiersToWatch).isEmpty {
                // 让事件队列再 settle 一会儿
                Thread.sleep(forTimeInterval: 0.02)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
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

    // MARK: - Pasteboard 备份/恢复

    private struct PasteboardBackup {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func backupPasteboard(_ pb: NSPasteboard) -> PasteboardBackup {
        let items = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        } ?? []
        return PasteboardBackup(items: items)
    }

    private static func restorePasteboard(_ pb: NSPasteboard, backup: PasteboardBackup, baseline: Int) {
        // 只在 pasteboard 实际被我们污染过时才恢复
        guard pb.changeCount != baseline else { return }
        pb.clearContents()
        let restored = backup.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty {
            pb.writeObjects(restored)
        }
    }
}
