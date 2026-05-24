---
name: ship
description: Inkling 端到端发版：推分支、开 PR、合 main、等 GitHub Action 部署完，再把构建出来的 .app 装到 /Applications/Inkling.app。覆盖全局 gstack /ship，仅本仓库适用。
---

# ship（Inkling 端到端发版）

把当前改动一路推到生产并装到本地。一个命令端到端：
**push → PR → 合 main → GitHub Action 部署 → 本地构建 Release → 装到 `/Applications/Inkling.app`**。

这个 skill 覆盖全局 gstack `/ship`，因为 Inkling 是 macOS 桌面 App——远端 Action 部署完不算结束，本机那份 `.app` 也得换上最新的。

## 何时调用

用户说：
- "ship"、"/ship"、"发版"、"发一版"、"推上去"
- "部署"、"deploy"、"装最新版"（在本仓库内 deploy = ship，没有独立的 /deploy）
- "上 main"、"推到 main"、"开 PR"

## 步骤

按顺序走完三段：

### 1. 标准 ship 流程（沿用 gstack /ship 的做法）

- 跑测试 / review diff
- 必要时 bump VERSION + 更新 CHANGELOG
- commit 当前改动
- push 当前分支
- `gh pr create` 开 PR（base = main）

### 2. land-and-deploy（沿用 gstack /land-and-deploy 的做法）

- 合并 PR（auto-merge 或人工 merge）
- 等 CI 跑过
- 等 GitHub Action 的部署 job 跑完
- 不要在 Action 还没跑完就往下走——下一步要拉的 main 必须是已部署的那个 commit

### 3. 本地装包

PR 已经合到 main、Action 已经跑完，再跑：

```bash
./scripts/deploy.sh
```

脚本做的事：

1. 检查 worktree 干净（脏的直接 abort）
2. 切到 `main` 并 `git pull --ff-only origin main`
3. 缺 `bridge/dist/index.js` 或 `bridge/node_modules` 就 `npm install + npm run build`
4. 装了 xcodegen 就跑 `xcodegen` 同步 `project.yml`
5. `xcodebuild -configuration Release` 构建到 `build-deploy/`
6. `osascript … to quit` 优雅关掉运行中的 Inkling，1 秒后 `pkill -x` 兜底
7. `rm -rf /Applications/Inkling.app && cp -R … /Applications/`
8. 切回用户原本所在的分支（EXIT trap 兜底）

## --here 旁路（不上 main，先本地试一下当前分支）

用户明确说"先在本地试一下"、"不上 main"、"用当前分支部署"时，跳过第 1、2 步，直接：

```bash
./scripts/deploy.sh --here
```

`--here` 模式不切分支、不拉 main，部署当前 HEAD。开发态自测用。

## 完成后给用户的提示

`scripts/deploy.sh` 自己会打印部署成功信息。无需重复，但要确保用户知道两件事：

1. **启动**：`open /Applications/Inkling.app`
2. **重新授权**：每次替换 `.app`，macOS TCC 都会清掉 Accessibility 权限。需要去
   `系统设置 → 隐私与安全性 → 辅助功能` 把 Inkling 重新勾上。
   这是 macOS 的安全机制，不是项目 bug，不要建议用户去查 Inkling 代码。

## 报错处理

按脚本/工具的错误信息回给用户，不要自己重写流程：

- "worktree 有未提交改动" → 提醒 commit 或 stash
- "构建失败" → 把 `build-deploy.log` 路径告诉用户，让他们自己看完整 xcodebuild 日志
- `git pull --ff-only` 失败 → 通常是本地 main 有未推送的提交，让用户自己 rebase
- PR 没合上、Action 没跑完 → 停在第 2 步，**不要**跳过去直接本地装包，本地装的会比 main 旧

## 不要做

- **不要拆成两个命令**。Inkling 的 ship 就是端到端，包括本地装包。如果用户说 `/deploy`，按 `/ship` 处理；本仓库没有独立的 deploy。
- **不要在 PR 没合、Action 没跑完时就本地装包**。本地拉到的 main 会落后，意义不大。
- **不要 force push**、**不要 `--no-verify` 跳 hook**，除非用户明确要求。
- **不要把构建产物 commit 进 repo**。`build-deploy/` 和 `build-deploy.log` 不要 `git add`。
- **不要改成往别的目录装**。`/Applications/` 是 macOS 应用的标准位置。
- **不要跳过 worktree 干净检查**。脏 worktree 时切 main 会丢工作。
