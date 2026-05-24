---
name: deploy
description: 把 Inkling 项目当前 main 的最新稳定代码本地构建并装到 /Applications/Inkling.app。仅适用于本仓库。
---

# deploy（Inkling 本地部署）

把 GitHub 上 `main` 分支最新稳定代码拉下来、Release 构建、装进 `/Applications/Inkling.app`。
**仅在本仓库（Inkling）内可用**——这个 skill 是项目本地的，其他项目自己定义自己的 `/deploy`。

## 何时调用

用户说：
- "部署"、"deploy"、"装最新版"、"装一下"、"上 main"
- "/deploy"、"/deploy main"
- "本地装上 main"、"更新到最新"

## 步骤

直接调仓库里自带的脚本：

```bash
./scripts/deploy.sh
```

如果用户明确说"用当前分支部署"或"不切到 main"、"试一下当前改的"，加 `--here`：

```bash
./scripts/deploy.sh --here
```

脚本做的事（按顺序）：

1. 检查 worktree 是否干净——有未提交改动直接 abort
2. 切到 `main` 并 `git pull --ff-only origin main`（`--here` 模式跳过这步，部署当前 HEAD）
3. 缺 `bridge/dist/index.js` 或 `bridge/node_modules` 就 `npm install + npm run build`
4. 装了 xcodegen 就跑 `xcodegen` 同步 `project.yml`（没装就跳过）
5. `xcodebuild -configuration Release` 构建到 `build-deploy/`
6. `osascript … to quit` 优雅关闭运行中的 Inkling，1 秒后 `pkill -x` 兜底
7. `rm -rf /Applications/Inkling.app && cp -R … /Applications/`
8. 切回用户原本所在的分支

任何一步失败，脚本会 `set -e` 退出并把分支切回去（通过 EXIT trap）。

## 完成后给用户的提示

脚本自己会打印部署成功信息和下一步。无需重复，但要确保用户知道两件事：

1. **启动**：`open /Applications/Inkling.app`
2. **重新授权**：每次替换 `.app`，macOS TCC 都会清掉 Accessibility 权限。需要去
   `系统设置 → 隐私与安全性 → 辅助功能` 把 Inkling 重新勾上。
   这是 macOS 的安全机制，不是项目 bug，不要建议用户去查 Inkling 代码。

## 报错处理

按脚本的错误信息回给用户，不要自己重写部署流程：

- "worktree 有未提交改动" → 提醒 commit 或 stash
- "构建失败" → 把 `build-deploy.log` 路径告诉用户，让他们自己看完整 xcodebuild 日志
- `git pull --ff-only` 失败 → 通常是本地 main 有未推送的提交，让用户自己 rebase

## 不要做

- **不要改成往别的目录装**。`/Applications/` 是 macOS 应用的标准位置，别整 `~/Applications/` 或别的什么。
- **不要 `git push`**。这个 skill 是"读 main、装本地"，纯本地操作。
- **不要跳过 worktree 干净检查**。脏 worktree 时切 main 会丢工作。
- **不要把 deploy 跟 ship/PR 流程混在一起**。`/ship` 管推代码 + 开 PR；`/deploy` 管装到本地。两件事。
- **不要把构建产物 commit 进 repo**。`build-deploy/` 和 `build-deploy.log` 不要 `git add`。
