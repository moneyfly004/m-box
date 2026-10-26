#!/bin/bash
# 获取 Android 内核 AAR（sing-box gomobile 静态库，Java 包名 top.moneyfly.libbox）。
#
# 两种模式：
#   1) 默认：直接下载官方/自建 release 里已编译好的 AAR（资产名 libmoneyfly-<ver>.aar）
#      （需要 NDK 才能自建，日常开发/CI 用预编译包即可）
#   2) FORCE_BUILD=1：本地用 gomobile 从 sing-box 源码编译（需 NDK + gomobile）
#
# 用法:
#   bash tool/build_singbox_aar.sh [版本号，默认 1.14.0]
#   FORCE_BUILD=1 bash tool/build_singbox_aar.sh 1.14.4
#
# 产物落到 android/app/libs/libmbox.aar（gradle 直接引用该文件名）。
set -euo pipefail

VERSION="${1:-1.14.0}"
REPO="${SINGBOX_LIB_REPO:-moneyfly004/sing-box-lib}"   # 自建 AAR 发布仓
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/android/app/libs"
mkdir -p "$DEST"

if [ "${FORCE_BUILD:-0}" = "1" ]; then
  echo "== 从 sing-box v$VERSION 源码编译 AAR（需要 NDK + gomobile） =="
  command -v gomobile >/dev/null || { echo "缺少 gomobile: go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init"; exit 1; }
  [ -n "${ANDROID_NDK_HOME:-}" ] || { echo "缺少 ANDROID_NDK_HOME（需要 r26+）"; exit 1; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 --branch "v$VERSION" https://github.com/SagerNet/sing-box "$TMP/sing-box"
  cd "$TMP/sing-box"
  gomobile bind -target=android -androidapi 21 \
    -java-package top.moneyfly.libbox \
    -o "$DEST/libmbox.aar" ./experimental/libbox
  echo "已生成 $DEST/libmbox.aar"
else
  # 资产名由发布仓库决定：sing-box-lib 的 release 里叫 libmoneyfly-<ver>.aar
  ASSET="libmoneyfly-${VERSION}.aar"
  URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"
  echo "下载 $URL"
  curl -fL --max-time 1800 -o "$DEST/libmbox.aar" "$URL"
  echo "已下载 $DEST/libmbox.aar ($(du -h "$DEST/libmbox.aar" | cut -f1))"
fi

# 完整性快检：必须是 zip（aar），且含 sing-box 的 native 库 libmoneyfly.so
unzip -l "$DEST/libmbox.aar" | grep -q "libmoneyfly.so" \
  || { echo "错误: AAR 内容异常（缺 libmoneyfly.so）"; exit 1; }
echo "OK"
