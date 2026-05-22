# Inkling

> 一个 Mac 划词工具：选中任意文本，按快捷键唤出悬浮窗，让 Claude 给出解释、翻译、追问。所有对话记忆和你的偏好通过 Claude Agent SDK 沉淀到本地知识库。

## 是什么

- 拖动鼠标选中任意文本 → 松手即弹出悬浮窗 → 默认调 Haiku 出解释
- 支持继续追问（多轮对话），会话由 Claude Agent SDK 维护
- 你的语气偏好、专业领域、常用任务模板写入本地 `CLAUDE.md`，每次自动加载
- （可选）在 Settings 里给"对刚才选的文本重新唤起"绑一个快捷键

## 快速开始

```bash
# 1. 装依赖
brew install xcodegen node
cd bridge && npm install && npm run build && cd ..

# 2. 生成 Xcode 工程
xcodegen

# 3. 用 Xcode 打开
open Inkling.xcodeproj
```

首次运行会要求授予 **Accessibility 权限**（用于读取选中文本）。在 `系统设置 → 隐私与安全性 → 辅助功能` 里勾上 Inkling。

## 技术栈

- **App 壳**：Swift + SwiftUI + AppKit（NSPanel 悬浮窗、NSStatusItem 状态栏）
- **文本捕获**：macOS Accessibility API (`AXUIElement`) 读 `kAXSelectedTextAttribute`
- **全局快捷键**：[sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- **LLM 桥**：Node sidecar 进程，内嵌 `@anthropic-ai/claude-agent-sdk`，通过 stdio JSON-RPC 与 Swift 通信
- **记忆**：Claude Code 原生机制（session + `CLAUDE.md`），路径在 `~/Library/Application Support/Inkling/`

## 架构

详见 [ARCHITECTURE.md](./ARCHITECTURE.md)。简版：

```
┌─────────────────── Inkling.app (Swift) ───────────────────┐
│  MenuBar ── HotKey ── SelectionReader ── FloatingPanel    │
│                                              │             │
│                                              ▼             │
│                                        BridgeProcess       │
│                                              │             │
└──────────────────────────────────────────────│─────────────┘
                                               │ stdio JSON
                                               ▼
                                      ┌─── bridge (Node) ────┐
                                      │ @anthropic-ai/       │
                                      │ claude-agent-sdk     │
                                      └──────┬───────────────┘
                                             ▼
                                      Anthropic API
                                      (复用 Claude Code 订阅 token)
```

## 状态

仓库刚初始化。完成度按模块：

- [x] 目录结构 + 文档
- [ ] Swift 主 App（骨架已就位，待 XcodeGen 生成工程后接通）
- [ ] AX 选中文本读取
- [ ] 全局快捷键
- [ ] 悬浮窗 UI
- [ ] Node bridge 主循环
- [ ] 多轮会话状态管理
- [ ] CLAUDE.md 偏好编辑器
- [ ] 设置面板

## 协议

详见 [docs/PROTOCOL.md](./docs/PROTOCOL.md)：Swift ↔ Node bridge 的 JSON-RPC over stdio。
