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

# 构建标签**必须**带官方那一套（release/DEFAULT_BUILD_TAGS）：
# 少了 with_utls → 真机上 reality 节点直接报
#   `initialize outbound[1]: uTLS, which is required by reality is not included
#    in this build, rebuild with -tags with_utls`
# 少了 with_gvisor → tun.stack=gvisor 不可用；少了 with_quic → hysteria2/tuic 不可用；
# 少了 with_clash_api → 控制面（/version、切节点、测速）全废。
# 注意：iOS 侧不能照搬 Android 的完整标签 ——
#   with_naive_outbound → 依赖 sagernet/cronet-go，iOS 切片没有对应 cgo 库，
#   实测编译直接失败（build constraints exclude all Go files in cronet-go/all）。
# 这里只保留 MBox 真正用到、且纯 Go / 有 iOS 支持的能力。
SINGBOX_TAGS="${SINGBOX_TAGS:-with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_ccm,with_ocm,with_openvpn,badlinkname,tfogo_checklinkname0}"

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
if [ -n "${SINGBOX_SRC:-}" ]; then
  echo "使用本地源码: $SINGBOX_SRC"
  cd "$SINGBOX_SRC"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 --branch "v$VERSION" https://github.com/SagerNet/sing-box "$TMP/sing-box"
  cd "$TMP/sing-box"
fi
# Go 1.24+ 起 gomobile bind 要求 x/mobile 进入模块依赖图（tool 指令）
go get -tool golang.org/x/mobile/cmd/gobind || go get golang.org/x/mobile/cmd/gomobile
# -target=ios 产出 Libbox.xcframework（arm64 device + simulator 切片）
# 版本号必须注入：不注入的话 LibboxVersion() 返回 unknown（日志里一直是「内核版本 unknown」）
OUT_DIR="$(mktemp -d)"
echo "构建标签: $SINGBOX_TAGS"
gomobile bind -target=ios \
  -tags "$SINGBOX_TAGS" \
  -ldflags "-checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$VERSION" \
  -o "$OUT_DIR/Libbox.xcframework" ./experimental/libbox
rm -rf "$DEST/Libbox.xcframework"
cp -R "$OUT_DIR/Libbox.xcframework" "$DEST/Libbox.xcframework"
rm -rf "$OUT_DIR"
echo "✓ 已生成 $DEST/Libbox.xcframework（$(du -sh "$DEST/Libbox.xcframework" | cut -f1)）"
