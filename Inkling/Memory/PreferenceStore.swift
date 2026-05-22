import Foundation

/// 管理 ~/Library/Application Support/Inkling/ 下的 CLAUDE.md 与知识库目录。
/// CLAUDE.md 内容会被 Claude Agent SDK 自动作为项目指令加载（启动 bridge 时 cwd 指向该目录）。
enum PreferenceStore {
    static func appSupportDirectory() -> URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Inkling", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ensureSeedFiles(in: dir)
        return dir
    }

    static var claudeMdURL: URL { appSupportDirectory().appendingPathComponent("CLAUDE.md") }
    static var knowledgeDirURL: URL { appSupportDirectory().appendingPathComponent("knowledge", isDirectory: true) }

    static func readPreferences() -> String {
        (try? String(contentsOf: claudeMdURL, encoding: .utf8)) ?? ""
    }

    static func writePreferences(_ text: String) throws {
        try text.write(to: claudeMdURL, atomically: true, encoding: .utf8)
    }

    private static func ensureSeedFiles(in dir: URL) {
        let claudeMd = dir.appendingPathComponent("CLAUDE.md")
        if !FileManager.default.fileExists(atPath: claudeMd.path) {
            try? seedClaudeMd.write(to: claudeMd, atomically: true, encoding: .utf8)
        }
        let knowledge = dir.appendingPathComponent("knowledge", isDirectory: true)
        try? FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
    }

    private static let seedClaudeMd: String = """
    # Inkling 用户偏好

    你是一个划词助手。用户选中文本后调用你来解释、翻译、追问。

    ## 风格
    - 默认用简体中文回答
    - 解释要直接，不要重复 prompt
    - 代码片段用 markdown code block，并标语言
    - 一两段就够，除非用户问"再展开"

    ## 我的背景
    （在这里写你的角色、领域、惯用词汇、想被怎么对待。Inkling 启动时会自动把这份内容作为指令送给 Claude。）

    ## 我常做的任务
    - 解释技术文档里的英文术语
    - 翻译中英互译
    - 把命令行报错粘进来让你诊断

    """
}
