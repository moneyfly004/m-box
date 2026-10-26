#!/bin/bash
# 打 macOS DMG（arm64 / x64 / universal 三个 job 共用）。
#
# 为什么单独成脚本：`hdiutil create` 在 GitHub macOS runner 上偶发
#   hdiutil: create failed - Resource busy
# 原因有两类，都不是「打包参数错」：
#   1) 同名卷（-volname MBox）还挂在 /Volumes 上（同一次运行里前一步挂载过、
#      或上一次失败留下的），hdiutil 认为卷名冲突；
#   2) 刚 `codesign --deep` 过的 app 正被 Spotlight / FSEvents 索引，
#      源目录被短暂占用。
# 所以这里：先卸掉所有 /Volumes/MBox* 残留卷 → 用随机卷名（不会撞名）→
# 失败重试 3 次，最后仍失败才报错退出。
#
# 用法: bash scripts/make_macos_dmg.sh <stage 目录> <输出 dmg 路径>
set -euo pipefail

STAGE="${1:?用法: make_macos_dmg.sh <stage 目录> <输出 dmg>}"
OUT="${2:?缺少输出 dmg 路径}"

[ -d "$STAGE" ] || { echo "错误: stage 目录不存在: $STAGE"; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# 1) 卸掉残留的同名卷（-force：有进程占用也卸）
STALE="$(hdiutil info | awk '/\/Volumes\/MBox/ {print $1}' | sort -u || true)"
for dev in $STALE; do
  echo "卸载残留卷 $dev"
  hdiutil detach "$dev" -force >/dev/null 2>&1 || true
done

# 2) 随机卷名 + 重试
for i in 1 2 3; do
  VOL="MBox-${RANDOM}${RANDOM}"
  if hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/tmp/hdiutil.log 2>&1; then
    echo "✓ 已生成 $OUT（$(du -h "$OUT" | cut -f1)）"
    exit 0
  fi
  echo "hdiutil 第 $i 次失败（卷名 $VOL）:"
  tail -5 /tmp/hdiutil.log || true
  # 失败时也可能留下半成品卷，顺手清掉再试
  for dev in $(hdiutil info | awk -v v="$VOL" '$0 ~ "/Volumes/" v {print $1}' | sort -u || true); do
    hdiutil detach "$dev" -force >/dev/null 2>&1 || true
  done
  rm -f "$OUT"
  sleep 3
done

echo "错误: DMG 打包失败（重试 3 次仍失败）"
exit 1
