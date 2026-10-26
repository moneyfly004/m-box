#!/bin/bash
# CI 用：下载（或复用缓存的）sing-box 内核到 build/singbox。
#
# 为什么要这个脚本：原来每个 job 都自己 curl 一遍 30~90MB 的 release 包，
# 一次 tag 构建要下 7 份（3 个 macOS 构建 + 3 个校验 + Windows），既慢又容易被
# GitHub 限速/断流搞红。现在统一入口：
#   1) build/singbox 由 actions/cache 缓存（见 release.yml 的「缓存 sing-box 内核」）；
#   2) 这里先做**命中判断**（二进制在、版本对 → 直接退出，不下载）；
#   3) 只有真缺才下载，且带重试与解包后定位（zip / tar.gz 两种发布包）。
#
# 用法: SINGBOX_VERSION=1.14.4 bash tool/fetch_kernel_ci.sh <darwin-arm64|darwin-amd64|windows-amd64>
set -euo pipefail

ARCH="${1:?用法: fetch_kernel_ci.sh <darwin-arm64|darwin-amd64|windows-amd64>}"
VERSION="${SINGBOX_VERSION:?需要设置 SINGBOX_VERSION（如 1.14.4）}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/build/singbox"
mkdir -p "$DEST"

case "$ARCH" in
  windows-*) EXE="sing-box.exe" ;;
  *)         EXE="sing-box" ;;
esac
TARGET="$DEST/$EXE"

# ---- 1. 缓存命中判断：文件在 + 版本对得上 ----
if [ -f "$TARGET" ]; then
  if "$TARGET" version 2>/dev/null | grep -q "version $VERSION"; then
    echo "✓ 复用已缓存的内核：${TARGET}（$("${TARGET}" version 2>/dev/null | head -1)）"
    exit 0
  fi
  echo "缓存的内核版本不符，重新下载"
  rm -f "$TARGET"
fi

# ---- 2. 下载 ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$ARCH" in
  windows-*) ASSET="sing-box-$VERSION-$ARCH.zip" ;;
  *)         ASSET="sing-box-$VERSION-$ARCH.tar.gz" ;;
esac
URL="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/$ASSET"

echo "下载 ${URL}"
ok=0
for i in 1 2 3 4; do
  if curl -fL --retry 3 --retry-delay 3 --retry-all-errors --max-time 600 \
       -o "$TMP/$ASSET" "$URL"; then
    ok=1
    break
  fi
  echo "第 $i 次下载失败，重试…"
  sleep 3
done
[ "$ok" = 1 ] || { echo "错误: 下载失败 $URL"; exit 1; }

# ---- 3. 解包并定位可执行文件 ----
case "$ASSET" in
  *.zip)    unzip -oq "$TMP/$ASSET" -d "$TMP/x" ;;
  *.tar.gz) mkdir -p "$TMP/x" && tar -xzf "$TMP/$ASSET" -C "$TMP/x" ;;
esac
FOUND="$(find "$TMP/x" -maxdepth 3 -type f -name "$EXE" | head -1)"
[ -n "$FOUND" ] || { echo "错误: 解包后未找到 ${EXE}"; exit 1; }
cp "$FOUND" "$TARGET"
chmod +x "$TARGET" 2>/dev/null || true
"$TARGET" version
echo "✓ 已就位 ${TARGET}"
