import Foundation

/// 集中管理 UserDefaults 键与默认值。
/// SwiftUI 侧用 @AppStorage(AppSettings.xxxKey) 绑定，非 SwiftUI 侧（BridgeProcess、
/// SelectionWatcher 等）通过下面的便捷访问器读。
enum AppSettings {
    // MARK: - Keys

    static let modelKey = "defaultModel"
    static let watcherEnabledKey = "watcherEnabled"

    // MARK: - Defaults

    static let defaultModel = "claude-haiku-4-5"

    // MARK: - Accessors (非 SwiftUI 侧用)

    static var model: String {
        let value = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return value.isEmpty ? defaultModel : value
    }

    /// 是否启用划词监听。首次启动当作 true。
    static var watcherEnabled: Bool {
        if UserDefaults.standard.object(forKey: watcherEnabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: watcherEnabledKey)
    }

    static func setWatcherEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: watcherEnabledKey)
    }
}
