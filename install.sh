#!/usr/bin/env bash
# 安装 voice-input：检查依赖、准备常用词表、在 ~/.hammerspoon/init.lua 里加载本仓库。
# 重复运行没有副作用。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/voice-input"
HS_INIT="$HOME/.hammerspoon/init.lua"

echo "==> 检查依赖"
missing=()
for bin in ffmpeg jq; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
[ -d /Applications/Hammerspoon.app ] || missing+=("--cask hammerspoon")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "缺少依赖，先装上：" >&2
  for m in "${missing[@]}"; do echo "  brew install $m" >&2; done
  exit 1
fi

echo "==> 常用词表"
mkdir -p "$CONFIG_DIR"
if [ -e "$CONFIG_DIR/vocab.txt" ]; then
  echo "    已有 $CONFIG_DIR/vocab.txt，不覆盖"
else
  cp "$REPO/vocab.example.txt" "$CONFIG_DIR/vocab.txt"
  echo "    复制示例到 $CONFIG_DIR/vocab.txt"
fi

echo "==> 在 Hammerspoon 里加载"
mkdir -p "$HOME/.hammerspoon"
touch "$HS_INIT"
if grep -q 'require("voice")' "$HS_INIT"; then
  echo "    $HS_INIT 里已经加载过了"
else
  cat >>"$HS_INIT" <<LUA

-- voice-input：按键说话，转写后粘贴到光标处（${REPO}）
package.path = "$REPO/hammerspoon/?.lua;" .. package.path
require("voice")
LUA
  echo "    已追加到 $HS_INIT"
fi

cat <<'MSG'

装好了。接下来：
  1. 打开 Hammerspoon（已开着就点菜单栏图标 → Reload Config）
  2. 系统设置 → 隐私与安全性：给 Hammerspoon 打开「辅助功能」和「麦克风」
  3. 菜单栏麦克风图标 → 打开面板 → 设置：填阿里云百炼 Key（或 Gemini Key），点「测试」
  4. 按一下右 Command 开始说话，再按一下结束，文字会粘贴到光标处
MSG
