#!/bin/bash
# 把 arm64 与 x64 两份 MBox.app 合并为 universal.app：
# 对相对路径相同的 Mach-O 文件做 lipo -create 合并，其余资源取 arm64 侧。
# 用法: scripts/merge_macos_universal.sh <arm64.app> <x64.app> <out.app> <entitlements.plist>
set -euo pipefail
ARM="$1"; X64="$2"; OUT="$3"; ENT="${4:-macos/Runner/Release.entitlements}"

rm -rf "$OUT"
cp -R "$ARM" "$OUT"

cd "$OUT"
find . -type f -print0 | while IFS= read -r -d '' f; do
  x="$X64/$f"
  [ -f "$x" ] || continue
  # 仅当两侧都是 Mach-O 才合并（资源/数据文件不处理）
  if file -b "$f" | grep -q 'Mach-O' && file -b "$x" | grep -q 'Mach-O'; then
    arm_has_x64=$(lipo -archs "$f" | tr ' ' '\n' | grep -c '^x86_64$' || true)
    x_has_arm=$(lipo -archs "$x" | tr ' ' '\n' | grep -c '^arm64$' || true)
    if [ "$arm_has_x64" = "0" ] && [ "$x_has_arm" = "0" ]; then
      lipo -create "$f" "$x" -output "$f.universal"
      mv "$f.universal" "$f"
      echo "merged: $f"
    fi
  fi
done
cd - >/dev/null

# adhoc 重签（保留 entitlements），避免 Gatekeeper/签名校验问题
if [ -f "$ENT" ]; then
  codesign --force --deep -s - --entitlements "$ENT" "$OUT" || true
else
  codesign --force --deep -s - "$OUT" || true
fi
echo "universal app ready: $OUT"
