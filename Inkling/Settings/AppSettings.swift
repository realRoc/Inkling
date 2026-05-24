import Foundation

/// 集中管理 UserDefaults 键与默认值。
/// SwiftUI 侧用 @AppStorage(AppSettings.xxxKey) 绑定，非 SwiftUI 侧（BridgeProcess 等）
/// 通过下面的便捷访问器读。
enum AppSettings {
    // MARK: - Keys

    static let modelKey = "defaultModel"

    // MARK: - Defaults

    static let defaultModel = "claude-haiku-4-5"

    // MARK: - Accessors (非 SwiftUI 侧用)

    static var model: String {
        let value = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return value.isEmpty ? defaultModel : value
    }
}
