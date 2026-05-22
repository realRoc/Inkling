import SwiftUI

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isStreaming: Bool = false

    private var bridge: BridgeProcess?
    private var sessions: SessionManager?
    private var sessionId: String?

    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    func reset(selection: Selection, bridge: BridgeProcess, sessions: SessionManager) {
        self.bridge = bridge
        self.sessions = sessions
        self.messages = []
        self.input = ""
        self.sessionId = sessions.newSession()

        // 第一轮：默认让 Claude 解释选中文本
        send(prompt: "请简要解释这段内容：\n\n\(selection.text)")
    }

    func send(prompt: String) {
        guard let bridge, let sessionId else { return }
        messages.append(Message(role: .user, text: prompt))
        messages.append(Message(role: .assistant, text: ""))
        isStreaming = true

        bridge.send(sessionId: sessionId, text: prompt) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .delta(let chunk):
                    self.messages[self.messages.count - 1].text += chunk
                case .done:
                    self.isStreaming = false
                case .error(let msg):
                    self.messages[self.messages.count - 1].text += "\n[error] \(msg)"
                    self.isStreaming = false
                }
            }
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject var viewModel: ConversationViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .frame(width: 420, height: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            quickButton("解释", "请解释这段内容")
            quickButton("翻译", "请翻译成中文/英文，自动判断")
            quickButton("总结", "请用要点总结这段")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func quickButton(_ label: String, _ prompt: String) -> some View {
        Button(label) { viewModel.send(prompt: prompt) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var messagesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.messages) { msg in
                    HStack {
                        if msg.role == .user { Spacer() }
                        Text(msg.text)
                            .padding(10)
                            .background(msg.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                        if msg.role == .assistant { Spacer() }
                    }
                }
            }
            .padding(12)
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("继续追问…", text: $viewModel.input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Button("发送") { submit() }
                .disabled(viewModel.input.isEmpty || viewModel.isStreaming)
        }
        .padding(12)
    }

    private func submit() {
        let text = viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.input = ""
        viewModel.send(prompt: text)
    }
}
