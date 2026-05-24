#!/usr/bin/env bash
#
# Inkling 本地部署：拉 main 最新 → 构建 Release → 装到 /Applications。
#
# 用法：
#   ./scripts/deploy.sh           # 部署 origin/main 最新
#   ./scripts/deploy.sh --here    # 不切分支，部署当前 HEAD（开发态自测用）
#
# 假定：
#   - macOS，本机已装 Xcode / xcodebuild
#   - bridge/ 子项目能 npm install
#   - 你愿意在每次替换 .app 后重新授予 Accessibility 权限（macOS TCC 强制要求）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MODE="main"
if [ "${1:-}" = "--here" ]; then
    MODE="here"
elif [ -n "${1:-}" ]; then
    echo "✗ 未知参数：$1（只支持 --here）"
    exit 1
fi

step() { echo "→ $*"; }
ok()   { echo "✓ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

# ---- 1. worktree 干净检查 ----
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ 当前 worktree 有未提交改动，先 commit / stash 再部署。"
    git status --short
    exit 1
fi

# ---- 2. 切到 main 并拉最新（除非 --here） ----
ORIGINAL_BRANCH=$(git branch --show-current || echo "")
if [ "$MODE" = "main" ]; then
    step "切到 main 并 git pull --ff-only"
    git checkout main
    git pull --ff-only origin main
else
    step "保留当前分支 ($ORIGINAL_BRANCH)，部署当前 HEAD"
fi
HEAD_SHA=$(git rev-parse --short HEAD)
HEAD_BRANCH=$(git branch --show-current || echo "detached")

# 失败时把分支切回去，避免把用户晾在 main 上
restore_branch() {
    if [ "$MODE" = "main" ] && [ -n "$ORIGINAL_BRANCH" ] && [ "$ORIGINAL_BRANCH" != "main" ]; then
        git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
    fi
}
trap restore_branch EXIT

# ---- 3. Node bridge（缺产物才重建） ----
if [ ! -f bridge/dist/index.js ] || [ ! -d bridge/node_modules ]; then
    step "构建 Node bridge"
    (cd bridge && npm install --no-audit --no-fund && npm run build)
else
    ok "bridge/dist 已存在，跳过重建"
fi

# ---- 4. xcodegen 同步 project.yml（装了才跑） ----
if command -v xcodegen >/dev/null 2>&1; then
    step "xcodegen 同步 project.yml"
    xcodegen 2>&1 | tail -3
else
    ok "未装 xcodegen，跳过；如果 project.yml 改过请手动跑一次"
fi

# ---- 5. xcodebuild Release ----
BUILD_DIR="$REPO_ROOT/build-deploy"
APP_PATH="$BUILD_DIR/Build/Products/Release/Inkling.app"

step "xcodebuild Release（输出留在 $BUILD_DIR）"
set +e
xcodebuild \
    -project Inkling.xcodeproj \
    -scheme Inkling \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    build 2>&1 | tee "$BUILD_DIR.log" | \
    grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | \
    grep -v "appintentsmetadataprocessor" || true
BUILD_EXIT=${PIPESTATUS[0]}
set -e

if [ "$BUILD_EXIT" -ne 0 ] || [ ! -d "$APP_PATH" ]; then
    echo
    die "构建失败。完整日志：$BUILD_DIR.log"
fi

# ---- 6. 关掉运行中的实例 ----
if pgrep -x Inkling >/dev/null 2>&1; then
    step "退出当前运行的 Inkling"
    osascript -e 'tell application "Inkling" to quit' 2>/dev/null || true
    sleep 1
    pgrep -x Inkling >/dev/null 2>&1 && pkill -x Inkling 2>/dev/null || true
    sleep 0.5
fi

# ---- 7. 装到 /Applications ----
DEST="/Applications/Inkling.app"
step "安装到 $DEST"
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"

# ---- 8. 收尾 ----
restore_branch
trap - EXIT

cat <<EOF

✅ 已部署 $HEAD_BRANCH @ $HEAD_SHA 到 $DEST

下一步：
  open /Applications/Inkling.app

⚠️  替换 .app 后 macOS TCC 会清掉 Accessibility 权限。
   去 系统设置 → 隐私与安全性 → 辅助功能，把 Inkling 重新勾上。
EOF
