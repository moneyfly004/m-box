#!/bin/bash
# 把 universal .app 裁剪为单一架构（用于发布 Apple 芯片版 / Intel 版）
# 用法: scripts/thin_app.sh <arm64|x86_64> <MBox.app 路径>
set -euo pipefail

ARCH="$1"
APP="$2"

if [[ ! -d "$APP" ]]; then
  echo "错误: 找不到 $APP" >&2
  exit 1
fi

echo "裁剪 $APP → 仅保留 $ARCH"

# 递归处理所有 Mach-O 二进制（主程序 + App.framework + 插件 dylib）
while IFS= read -r -d '' f; do
  if file "$f" | grep -q 'Mach-O'; then
    archs=$(lipo -archs "$f")
    if echo "$archs" | grep -q "$ARCH"; then
      lipo -thin "$ARCH" "$f" -output "$f.thin"
      mv "$f.thin" "$f"
    else
      echo "警告: $f 不包含 $ARCH（archs: $archs）"
    fi
  fi
done < <(find "$APP" -type f -print0)

# 裁剪后重新 ad-hoc 签名（直接分发模式；正式分发请换 Developer ID 证书）
codesign --force --deep -s - "$APP"
echo "完成: $APP ($(lipo -archs "$APP/Contents/MacOS/MBox"))"
