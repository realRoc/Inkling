import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var preferences: String = PreferenceStore.readPreferences()
    @State private var model: String = "claude-haiku-4-5"

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gear") }
            preferencesTab
                .tabItem { Label("偏好", systemImage: "brain") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }

    private var generalTab: some View {
        Form {
            Section("快捷键") {
                KeyboardShortcuts.Recorder("唤出 Inkling", name: .summon)
            }
            Section("模型") {
                Picker("默认模型", selection: $model) {
                    Text("Haiku 4.5（最快、最便宜）").tag("claude-haiku-4-5")
                    Text("Sonnet 4.6").tag("claude-sonnet-4-6")
                    Text("Opus 4.7").tag("claude-opus-4-7")
                }
                .pickerStyle(.menu)
            }
        }
        .padding(20)
    }

    private var preferencesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("用户偏好（CLAUDE.md）")
                .font(.headline)
            Text("这份内容会作为指令在每次对话开始时加载。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $preferences)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("打开知识库目录") {
                    NSWorkspace.shared.open(PreferenceStore.knowledgeDirURL)
                }
                Button("保存") {
                    try? PreferenceStore.writePreferences(preferences)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "highlighter")
                .font(.system(size: 48))
            Text("Inkling").font(.title)
            Text("一个划词工具，复用 Claude Code 订阅的 token。")
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
