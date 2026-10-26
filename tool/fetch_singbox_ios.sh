#!/bin/bash
# 构建 sing-box 的 iOS 内核框架（Libbox.xcframework）到 ios/ 供 Xcode 链接。
#
# 为什么需要它：iOS 上内核不能作为子进程运行，必须以 gomobile 静态框架链进
# PacketTunnel 扩展（详见 ios/PacketTunnel/PacketTunnelProvider.swift）。
# 框架约 100MB/切片，不入库，构建前生成/下载。
#
# 用法:
#   bash tool/fetch_singbox_ios.sh [版本号，默认 1.14.4]
#   # 已存在则跳过；FORCE=1 强制重建
#
# 产物来源二选一：
#   A) gomobile 本地编译（默认；需要 Go + Xcode + gomobile）
#   B) 自定义发布仓的 Libbox.xcframework.zip（设置 SINGBOX_IOS_ZIP 覆盖 URL）
set -euo pipefail

VERSION="${1:-1.14.4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ios"

if [ -d "$DEST/Libbox.xcframework" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "✓ ios/Libbox.xcframework 已存在（FORCE=1 可重新构建）"
  exit 0
fi

if [ -n "${SINGBOX_IOS_ZIP:-}" ]; then
  echo "== 从 $SINGBOX_IOS_ZIP 下载 =="
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fL --max-time 1800 -o "$TMP/libbox.zip" "$SINGBOX_IOS_ZIP"
  unzip -oq "$TMP/libbox.zip" -d "$TMP/x"
  FOUND="$(find "$TMP/x" -maxdepth 3 -name 'Libbox.xcframework' -type d | head -1)"
  [ -n "$FOUND" ] || { echo "压缩包内未找到 Libbox.xcframework"; exit 1; }
  rm -rf "$DEST/Libbox.xcframework"
  cp -R "$FOUND" "$DEST/Libbox.xcframework"
  echo "✓ 已安装 $DEST/Libbox.xcframework"
  exit 0
fi

echo "== gomobile 编译 sing-box v$VERSION 的 Libbox.xcframework =="
command -v go >/dev/null || {
  echo "缺少 go（CI 上由 actions/setup-go 提供；本机用 brew install go）"; exit 1;
}
# GOPATH/bin 不一定在 PATH 里（CI runner 就是这种情况），先补进 PATH 再判断，
# 否则会出现「刚装完 gomobile 又找不到」的循环安装。
export PATH="$PATH:$(go env GOPATH)/bin"
if ! command -v gomobile >/dev/null || ! command -v gobind >/dev/null; then
  echo "安装 gomobile / gobind ..."
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
  command -v gomobile >/dev/null || { echo "gomobile 安装失败"; exit 1; }
  gomobile init
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 --branch "v$VERSION" https://github.com/SagerNet/sing-box "$TMP/sing-box"
cd "$TMP/sing-box"
# Go 1.24+ 起 gomobile bind 要求 x/mobile 进入模块依赖图（tool 指令）
go get -tool golang.org/x/mobile/cmd/gobind || go get golang.org/x/mobile/cmd/gomobile
# -target=ios 产出 Libbox.xcframework（arm64 device + simulator 切片）
gomobile bind -target=ios -o "$TMP/Libbox.xcframework" ./experimental/libbox
rm -rf "$DEST/Libbox.xcframework"
cp -R "$TMP/Libbox.xcframework" "$DEST/Libbox.xcframework"
echo "✓ 已生成 $DEST/Libbox.xcframework（$(du -sh "$DEST/Libbox.xcframework" | cut -f1)）"
