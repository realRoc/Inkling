import AppKit
import SwiftUI

@MainActor
final class ConversationViewModel: ObservableObject {
    enum Mode: Equatable {
        case toolbar(selection: String?)
        case conversation(title: String, icon: String)
    }

    enum QuickAction { case translate, explain }

    @Published var mode: Mode = .toolbar(selection: nil)
    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isStreaming: Bool = false
    @Published var hintMessage: String?
    private var hintClearWorkItem: DispatchWorkItem?

    private var bridge: BridgeProcess?
    private var sessions: SessionManager?
    private var sessionId: String?
    private(set) var currentSelection: String?

    var hasSelection: Bool { currentSelection != nil }

    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    /// 唤起时调用——准备状态，从工具栏开始。
    func prepare(selection: Selection, bridge: BridgeProcess, sessions: SessionManager) {
        if let old = sessionId {
            (self.bridge ?? bridge).endSession(old)
        }
        self.bridge = bridge
        self.sessions = sessions
        self.messages = []
        self.input = ""
        self.isStreaming = false
        self.sessionId = sessions.newSession()

        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentSelection = text.isEmpty ? nil : text
        self.mode = .toolbar(selection: currentSelection)
    }

    func runQuickAction(_ action: QuickAction) {
        // 点击瞬间再尝试抓一次选区——窗口 nonactivating，原前台 app 仍是活跃的
        refreshSelectionIfNeeded()
        let sel = currentSelection ?? ""

        // 无选区时保持在 toolbar 闪个提示，避免切到空 conversation 卡片让用户困惑
        guard !sel.isEmpty else {
            flashHint("请先选中文本")
            return
        }

        switch action {
        case .translate:
            mode = .conversation(title: "翻译", icon: "character.book.closed")
            send(prompt: "请翻译下面这段内容（中文↔英文，根据原文自动判断方向）：\n\n\(sel)")
        case .explain:
            mode = .conversation(title: "解释", icon: "questionmark.circle")
            send(prompt: "请简要解释下面这段内容：\n\n\(sel)")
        }
    }

    private func flashHint(_ text: String) {
        hintMessage = text
        hintClearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hintMessage = nil }
        hintClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func refreshSelectionIfNeeded() {
        guard currentSelection == nil else { return }
        guard let selection = SelectionReader.currentSelection() else { return }
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            self.currentSelection = text
            self.mode = .toolbar(selection: text)  // 顺便刷新 UI 状态
        }
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

    /// 复制选区文本到系统剪贴板。
    func copySelectionToPasteboard() {
        guard let sel = currentSelection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sel, forType: .string)
    }

    /// 复制最近一次 assistant 回复到系统剪贴板。
    func copyLastAssistantMessage() {
        guard let last = messages.last(where: { $0.role == .assistant }), !last.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.text, forType: .string)
    }
}

// MARK: - 主视图

struct ConversationView: View {
    @EnvironmentObject var viewModel: ConversationViewModel
    @State private var pinned: Bool = false

    var body: some View {
        Group {
            switch viewModel.mode {
            case .toolbar(let selection):
                ToolbarBar(hasSelection: selection != nil)
            case .conversation(let title, let icon):
                ConversationCard(title: title, icon: icon, pinned: $pinned)
            }
        }
    }
}

// MARK: - 工具栏（图3）

private struct ToolbarBar: View {
    let hasSelection: Bool
    @EnvironmentObject var viewModel: ConversationViewModel

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                DragHandle()

                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)

                ToolbarSeparator()

                ToolbarButton(icon: "character.book.closed", label: "翻译", action: .translate, disabled: !hasSelection)
                ToolbarButton(icon: "questionmark.circle", label: "解释", action: .explain, disabled: !hasSelection)
                ToolbarButton(icon: "doc.on.doc", label: "复制", action: .copy, disabled: !hasSelection)

                ToolbarSeparator()

                CloseButton()
                    .padding(.horizontal, 8)
            }
            .frame(height: 40)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)

            if let hint = viewModel.hintMessage {
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.black.opacity(0.78))
                    )
                    .offset(y: -22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.hintMessage)
        .padding(8)  // 给阴影留出渲染空间
        .fixedSize()
    }
}

private struct DragHandle: View {
    var body: some View {
        Image(systemName: "circle.grid.2x2.fill")
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
    }
}

private struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

private enum ToolbarAction {
    case translate, explain, copy
}

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: ToolbarAction?
    var disabled: Bool = false

    @EnvironmentObject var viewModel: ConversationViewModel
    @State private var hovered = false

    var body: some View {
        Button(action: trigger) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? AnyShapeStyle(Color.secondary.opacity(0.5)) : AnyShapeStyle(.primary))
        .disabled(disabled)
        .onHover { hovered = $0 }
    }

    private func trigger() {
        guard let action else { return }
        switch action {
        case .translate: viewModel.runQuickAction(.translate)
        case .explain: viewModel.runQuickAction(.explain)
        case .copy: viewModel.copySelectionToPasteboard()
        }
    }
}

private struct CloseButton: View {
    @State private var hovered = false
    var body: some View {
        Button(action: { NSApp.keyWindow?.close() }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(hovered ? .secondary : .tertiary)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - 对话卡片（图6）

private struct ConversationCard: View {
    let title: String
    let icon: String
    @Binding var pinned: Bool

    @EnvironmentObject var viewModel: ConversationViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.primary.opacity(0.08))
            content
            footer
        }
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DragHandle()
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { pinned.toggle() }) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinned ? "取消固定" : "固定窗口")

            Button(action: { NSApp.keyWindow?.close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.messages.isEmpty {
                        Text(viewModel.hasSelection
                             ? "等待回复…"
                             : "未读取到选中文本。请在下方直接输入需要\(title)的内容。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 280)
            .onChange(of: viewModel.messages.last?.text) { _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("继续提问", text: $viewModel.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .onSubmit { submit() }

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(viewModel.input.isEmpty || viewModel.isStreaming ? 0.3 : 1.0))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.input.isEmpty || viewModel.isStreaming)

            Button(action: { viewModel.copyLastAssistantMessage() }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text("复制")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func submit() {
        let text = viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.input = ""
        viewModel.send(prompt: text)
    }
}

private struct MessageBubble: View {
    let message: ConversationViewModel.Message

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 32) }
            Text(message.text)
                .font(.system(size: 13))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.15)
                              : Color.primary.opacity(0.06))
                )
                .textSelection(.enabled)
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }
}
