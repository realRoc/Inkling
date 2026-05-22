import Foundation

/// 极简会话登记表。Inkling 侧只关心生成唯一 sessionId；
/// 真正的对话历史由 Claude Agent SDK 在 bridge 侧维护。
final class SessionManager {
    func newSession() -> String {
        UUID().uuidString
    }
}
