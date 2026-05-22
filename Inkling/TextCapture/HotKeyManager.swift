import KeyboardShortcuts

enum HotKeyManager {
    static func register(name: KeyboardShortcuts.Name, handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name, action: handler)
    }
}
