# Architecture

## 设计目标

1. **零额外成本**：复用 Claude Code 订阅的 token，不接 Anthropic API key
2. **零干扰**：悬浮窗不抢焦点（`.nonactivatingPanel`），随时 Esc 关闭
3. **轻量**：常驻内存 < 50MB；Node bridge 仅在使用时按需启动
4. **可记忆**：用户偏好与会话历史通过 Claude Code 原生 session + `CLAUDE.md` 沉淀

## 模块拆分

### 1. TextCapture（文本捕获）

| 文件 | 职责 |
|------|------|
| `HotKeyManager.swift` | 注册全局快捷键（默认 `⌘⇧Space`），用 KeyboardShortcuts 库 |
| `SelectionReader.swift` | 通过 Accessibility API 读 `kAXSelectedTextAttribute`；失败回退到 `⌘C → NSPasteboard → 恢复` |
| `CursorTracker.swift` | `NSEvent.mouseLocation`，用于决定悬浮窗弹出位置 |

**关键点**：AX API 要求 App 已被授予 Accessibility 权限。首次启动时弹引导，并跳到 `系统设置 → 隐私与安全性`。

### 2. FloatingPanel（悬浮窗）

| 文件 | 职责 |
|------|------|
| `FloatingPanel.swift` | 自定义 `NSPanel`：`.nonactivatingPanel`、`.floating`、`.hidesOnDeactivate`；圆角、阴影、轻磨砂背景 |
| `ConversationView.swift` | SwiftUI 视图：顶部工具栏（解释/翻译/总结/自定义）+ 滚动对话流 + 底部输入框 |

**弹出策略**：
- 默认位置：鼠标右下 12pt 偏移
- 若超出屏幕，自动翻转到鼠标左上
- 失焦自动收起；Esc 关闭

### 3. ClaudeBridge（LLM 桥）

| 文件 | 职责 |
|------|------|
| `BridgeProcess.swift` | 管理 Node 子进程生命周期；按需启动、空闲超时关闭 |
| `BridgeProtocol.swift` | 编解码 JSON 消息（见 `docs/PROTOCOL.md`） |
| `SessionManager.swift` | 维护 Inkling 侧 sessionId 到 bridge sessionId 的映射 |

**子进程命令**：
```bash
node <App.app>/Contents/Resources/bridge/dist/index.js
```
Node 二进制内嵌在 App bundle 里（构建时通过脚本拷贝）。

**通信协议**：line-delimited JSON over stdin/stdout。stderr 走日志。

### 4. Memory（记忆）

| 文件 | 职责 |
|------|------|
| `PreferenceStore.swift` | 读写 `~/Library/Application Support/Inkling/CLAUDE.md` |
| —— | session 文件由 Claude Agent SDK 自动管理，路径见下 |

**目录布局**：
```
~/Library/Application Support/Inkling/
├── CLAUDE.md              # 用户偏好（Inkling 启动 bridge 时 cwd 设为此目录）
├── knowledge/             # 用户自己丢的笔记/文档（被 CLAUDE.md 引用即可加载）
│   └── *.md
└── sessions/              # SDK 管理的会话存档
```

启动 bridge 时把 `cwd` 设为 `~/Library/Application Support/Inkling/`，这样 Agent SDK 自动加载该目录的 `CLAUDE.md`。

### 5. Settings（设置）

| 文件 | 职责 |
|------|------|
| `SettingsView.swift` | SwiftUI Settings Scene：快捷键、默认模型、CLAUDE.md 编辑器、知识库目录入口 |

### 6. MenuBar（状态栏）

| 文件 | 职责 |
|------|------|
| `MenuBarController.swift` | 状态栏图标 + 菜单（启用/暂停、设置、退出） |

## Bridge 的内部设计

Node bridge (`bridge/src/index.ts`)：

```typescript
import { query } from '@anthropic-ai/claude-agent-sdk';

const sessions = new Map<string, AsyncIterator<...>>();

// stdin 按行读 JSON，分发到 handlers
for await (const line of readLines(process.stdin)) {
  const msg = JSON.parse(line);
  switch (msg.type) {
    case 'create_session':  await createSession(msg); break;
    case 'send':            await sendMessage(msg); break;
    case 'end_session':     await endSession(msg); break;
  }
}
```

每个 session 对应一个 `query()` 调用，bridge 持续把 SDK 流式输出写回 stdout：
```
{"type":"delta","id":"abc","text":"这段..."}
{"type":"delta","id":"abc","text":"代码"}
{"type":"done","id":"abc","usage":{"input_tokens":120,"output_tokens":45}}
```

## 权限矩阵

| 权限 | 何时需要 | 如何申请 |
|------|----------|----------|
| Accessibility | 读取选中文本 | 首次启动弹引导 |
| Input Monitoring | 可能需要（取决于快捷键库实现） | 同上 |
| Network | bridge 调 Anthropic API | 默认允许，无需特殊申请 |

## 后续可扩展

- **图片划词**：截图 + Vision 模型识别 + 解释（用 Claude Sonnet/Opus）
- **快速动作**：选中代码后右键 → "用 Claude 解释" 系统菜单项
- **多模态**：在悬浮窗里粘贴图片
- **快捷模板**：在 CLAUDE.md 里定义 `/explain-code` `/translate-zh` 等模板
- **本地 LLM 回退**：网络不通时切到 Ollama
