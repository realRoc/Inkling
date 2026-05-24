import AppKit
import Combine
import SwiftUI

@MainActor
final class ConversationViewModel: ObservableObject {
    enum Mode: Equatable {
        case toolbar(selection: String?)
        case conversation(title: String, icon: String)
    }

    enum QuickAction { case translate, explain }

    /// `mode` 故意**不**用 @Published：@Published 在 `willSet` 里发 `objectWillChange.send()`，
    /// 即**早于**存储更新。NSHostingView 在第二次 summon（panel close→reopen）时会同步刷 body，
    /// 那时存储还是旧值，按钮被渲染成灰；后面存储真正更新了，但 SwiftUI 不再跑第二次 body。
    /// 改成 didSet 后，objectWillChange 在存储更新**之后**才发出去，SwiftUI 同步刷 body 时
    /// 读到的就是新值。modeChanged Publisher 替代 `$mode`，供 FloatingPanel 的 sink 用。
    var mode: Mode = .toolbar(selection: nil) {
        didSet {
            objectWillChange.send()
            modeChangedSubject.send(mode)
        }
    }
    private let modeChangedSubject = PassthroughSubject<Mode, Never>()
    var modeChanged: AnyPublisher<Mode, Never> { modeChangedSubject.eraseToAnyPublisher() }

    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isStreaming: Bool = false
    @Published var hintMessage: String?
    private var hintClearWorkItem: DispatchWorkItem?

    private var bridge: BridgeProcess?
    private var sessions: SessionManager?
    private var sessionId: String?
    private(set) var currentSelection: String?
    /// 用户唤起 Inkling 之前所在的 app。后台 retry 用它按 PID 直接读 AX，避免依赖
    /// systemWide focus（panel 一旦被点击，systemWide 就指到 Inkling 自己了）。
    /// 用强引用：弱引用一旦被提前回收，retry 整轮就废了。resetForClose 会清掉。
    private var targetApp: NSRunningApplication?
    /// 给 selection retry 用的代际号。prepare / resetForClose 都会 bump，让上一轮还没跑完的
    /// asyncAfter 在回写前发现自己已过期——避免"关闭后快速换 app 再唤起，旧 retry 把旧 app
    /// 的选区写进新会话"。
    private var selectionRetryGeneration: UInt64 = 0

    var hasSelection: Bool { currentSelection != nil }

    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    /// 关闭浮窗时调用——把状态拉回初始 toolbar，避免下次唤起残留上轮对话。
    func resetForClose() {
        selectionRetryGeneration &+= 1
        if let old = sessionId {
            bridge?.endSession(old)
        }
        sessionId = nil
        currentSelection = nil
        targetApp = nil
        messages = []
        input = ""
        isStreaming = false
        hintMessage = nil
        hintClearWorkItem?.cancel()
        hintClearWorkItem = nil
        mode = .toolbar(selection: nil)
    }

    /// 唤起时调用——准备状态，从工具栏开始。
    func prepare(selection: Selection, bridge: BridgeProcess, sessions: SessionManager, targetApp: NSRunningApplication?) {
        // 让上一轮还在排队的 retry 在回写时认出自己已过期——快速 close→summon 切换关键。
        selectionRetryGeneration &+= 1
        if let old = sessionId {
            (self.bridge ?? bridge).endSession(old)
        }
        self.bridge = bridge
        self.sessions = sessions
        self.targetApp = targetApp
        self.sessionId = sessions.newSession()

        // 不要在这里重置 messages / input / isStreaming / hintMessage：resetForClose
        // 已经清过了（首次启动时也是 init 默认值）。多写一次 @Published 就多一轮 SwiftUI
        // dirty，与下面的 mode 改写产生不必要的中间渲染。

        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentSelection = text.isEmpty ? nil : text
        self.mode = .toolbar(selection: currentSelection)

        // 唤起瞬间常常抓不到选区：快捷键 modifier 还没松开，pasteboard fallback 直接放弃。
        // 后台短时间重试几次，抓到就把按钮自动点亮，避免"灰锁"。
        if currentSelection == nil {
            retrySelectionInBackground()
        }
    }

    private func retrySelectionInBackground() {
        // 节奏由密到疏。前几次密集兜住"快捷键 modifier 没松开"和"key window 没切回原 app"
        // 这两种短暂状态；后面几次拉长，处理偶发慢响应。
        let delays: [TimeInterval] = [0.08, 0.18, 0.35, 0.7, 1.2]
        let app = targetApp
        // 捕获当前代际号；resetForClose / prepare 会 bump，让后续回写在两道闸门上停下来。
        // 闸门 1：deadline 到点检查；闸门 2：跨过 .global → .main 回到主线程时再检查。
        // 第二道关键：第一道之后的全局任务可能已经读到旧 app 的选区，写回前必须再判一次。
        let generation = selectionRetryGeneration
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.selectionRetryGeneration == generation,
                      self.currentSelection == nil else { return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    // 优先按 PID 走 AX——panel 已经显示了，systemWide focus 可能已被 Inkling
                    // 自己抢走，但目标 app 自己的 focused element 仍然保留着用户的选区。
                    guard let selection = SelectionReader.currentSelection(for: app) else { return }
                    let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    DispatchQueue.main.async {
                        guard let self,
                              self.selectionRetryGeneration == generation,
                              self.currentSelection == nil else { return }
                        self.currentSelection = text
                        if case .toolbar = self.mode {
                            self.mode = .toolbar(selection: text)
                        }
                    }
                }
            }
        }
    }

    func runQuickAction(_ action: QuickAction) {
        // 点击瞬间再尝试抓一次选区——窗口 nonactivating，原前台 app 仍是活跃的
        refreshSelectionIfNeeded()
        let sel = currentSelection ?? ""

        guard !sel.isEmpty else {
            flashHint("没抓到选区，检查 Accessibility 权限或当前 app 是否支持")
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
        guard let selection = SelectionReader.currentSelection(for: targetApp) else { return }
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
    case translate, explain
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
                        MessageBubble(
                            message: msg,
                            showTypingIndicator: viewModel.isStreaming && msg.id == viewModel.messages.last?.id
                        )
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
    /// 只在"当前还在 stream"且这条是最后一条 assistant message 时为 true。
    /// 解耦了 indicator 和"text 为空"——避免 bridge 直接发 .done（没有任何 .delta）
    /// 时，空 assistant 气泡一直显示脉冲点。
    var showTypingIndicator: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 32) }
            Group {
                if message.role == .assistant && message.text.isEmpty && showTypingIndicator {
                    TypingIndicator()
                } else {
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(message.role == .user
                          ? Color.accentColor.opacity(0.15)
                          : Color.primary.opacity(0.06))
            )
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1.0 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .frame(height: 14)
        .onAppear { animating = true }
    }
}
