import Foundation

enum BridgeEvent {
    case delta(String)
    case done
    case error(String)
}

/// 管理 Node sidecar 子进程。按需启动、自动清理。
final class BridgeProcess {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private let queue = DispatchQueue(label: "inkling.bridge")
    private var handlers: [String: (BridgeEvent) -> Void] = [:]
    private var createdSessions: Set<String> = []
    private var buffer = Data()

    func ensureRunning() {
        queue.sync {
            guard process == nil else { return }
            startLocked()
        }
    }

    private func startLocked() {
        let bridgeURL = Bundle.main.resourceURL!
            .appendingPathComponent("bridge/dist/index.js")
        guard let nodePath = Self.resolveNodePath() else {
            NSLog("Inkling: 找不到 node 可执行文件，请安装 Node.js (brew install node)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [bridgeURL.path]
        proc.currentDirectoryURL = PreferenceStore.appSupportDirectory()
        proc.environment = Self.buildChildEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let s = String(data: handle.availableData, encoding: .utf8), !s.isEmpty {
                NSLog("Inkling bridge stderr: %@", s)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.process = nil
                self?.stdin = nil
                self?.stdout = nil
                self?.createdSessions.removeAll()
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.stdin = stdinPipe.fileHandleForWriting
            self.stdout = stdoutPipe.fileHandleForReading
        } catch {
            NSLog("Inkling: failed to start bridge: %@", error.localizedDescription)
        }
    }

    func send(sessionId: String, text: String, handler: @escaping (BridgeEvent) -> Void) {
        ensureRunning()
        queue.async {
            self.handlers[sessionId] = handler
            if self.createdSessions.insert(sessionId).inserted {
                self.write(.createSession(id: sessionId, model: AppSettings.model, systemPrompt: nil))
            }
            self.write(.send(id: sessionId, text: text))
        }
    }

    func endSession(_ sessionId: String) {
        queue.async {
            guard self.createdSessions.remove(sessionId) != nil else { return }
            self.write(.endSession(id: sessionId))
            self.handlers.removeValue(forKey: sessionId)
        }
    }

    func shutdown() {
        queue.sync {
            process?.terminate()
            process = nil
            stdin = nil
            stdout = nil
            createdSessions.removeAll()
        }
    }

    // MARK: - IO

    private func write(_ msg: BridgeOutbound) {
        guard let stdin else { return }
        do {
            var data = try JSONEncoder().encode(msg)
            data.append(0x0A)  // \n
            try stdin.write(contentsOf: data)
        } catch {
            NSLog("Inkling: bridge write error: %@", error.localizedDescription)
        }
    }

    private func handleStdout(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            while let range = self.buffer.range(of: Data([0x0A])) {
                let line = self.buffer.subdata(in: 0..<range.lowerBound)
                self.buffer.removeSubrange(0..<range.upperBound)
                self.dispatch(line)
            }
        }
    }

    // MARK: - Node 路径探测 / 环境注入

    /// 探测 node 可执行文件。
    /// 顺序：内嵌 (Inkling.app/Contents/MacOS/node) → /opt/homebrew/bin/node →
    /// /usr/local/bin/node → 通过登录 shell 解析 `command -v node`。
    private static func resolveNodePath() -> String? {
        if let embedded = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("node").path,
           FileManager.default.isExecutableFile(atPath: embedded) {
            return embedded
        }
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return resolveViaLoginShell("node")
    }

    /// GUI 启动的进程不继承用户 shell 的 PATH，这里跑一次登录 shell 解析。
    private static func resolveViaLoginShell(_ binary: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v \(binary)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// 构造子进程环境：继承父进程、补齐 GUI 启动时缺失的 PATH、兜底 HOME。
    /// Inkling 永远走 Claude Code 订阅 OAuth：HOME 指向真实家目录后，
    /// Claude Agent SDK 自动读 ~/.claude/.credentials.json。
    /// 同时显式抹掉 ANTHROPIC_API_KEY，避免用户 shell 里的 key 抢了订阅 token 的路。
    private static func buildChildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // GUI 进程的 PATH 通常只有 /usr/bin:/bin:/usr/sbin:/sbin，
        // 补上 Homebrew 与 ~/.npm-global 等常见位置，确保 `claude` CLI 可见。
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.local/bin",
        ]
        let currentPath = env["PATH"] ?? ""
        let pathSegments = currentPath.split(separator: ":").map(String.init)
        let merged = (extraPaths + pathSegments)
            .reduce(into: [String]()) { acc, p in if !acc.contains(p) { acc.append(p) } }
        env["PATH"] = merged.joined(separator: ":")

        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        env.removeValue(forKey: "ANTHROPIC_API_KEY")

        return env
    }

    private func dispatch(_ line: Data) {
        guard !line.isEmpty else { return }
        do {
            let msg = try JSONDecoder().decode(BridgeInbound.self, from: line)
            switch msg {
            case .sessionCreated:
                break
            case .delta(let id, let text):
                handlers[id]?(.delta(text))
            case .done(let id):
                handlers[id]?(.done)
            case .error(let id, let message):
                handlers[id]?(.error(message))
            }
        } catch {
            NSLog("Inkling: bridge decode error: %@ line=%@",
                  error.localizedDescription,
                  String(data: line, encoding: .utf8) ?? "")
        }
    }
}
