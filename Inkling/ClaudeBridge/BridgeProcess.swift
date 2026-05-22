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
        let nodePath = "/usr/local/bin/node"  // TODO: 探测 / 内嵌 node

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [bridgeURL.path]
        proc.currentDirectoryURL = PreferenceStore.appSupportDirectory()

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
            self.write(.createSession(id: sessionId, model: "claude-haiku-4-5", systemPrompt: nil))
            self.write(.send(id: sessionId, text: text))
        }
    }

    func shutdown() {
        queue.sync {
            process?.terminate()
            process = nil
            stdin = nil
            stdout = nil
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
