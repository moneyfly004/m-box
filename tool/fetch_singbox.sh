#!/bin/bash
# 开发环境获取 sing-box 内核二进制（发布包由 CI 自动内置，见 .github/workflows/release.yml）
# 用法: bash tool/fetch_singbox.sh [版本号，默认 1.14.4]
# 下载源: SagerNet/sing-box 官方 release（预编译产物，无需自行编译）
set -euo pipefail

VERSION="${1:-1.14.4}"
BASE="${SINGBOX_DL_BASE:-https://github.com/SagerNet/sing-box/releases/download}/v$VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$(uname -s)" in
  Darwin)
    ARCH="$(uname -m)"
    case "$ARCH" in
      arm64) A="arm64" ;;
      x86_64) A="amd64" ;;
      *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    ASSET="sing-box-$VERSION-darwin-$A.tar.gz"
    echo "下载 $ASSET ..."
    curl -fL --max-time 300 -o "$TMP/sb.tar.gz" "$BASE/$ASSET"
    tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
    BIN="$(find "$TMP" -type f -name sing-box | head -1)"
    [ -n "$BIN" ] || { echo "解压后未找到 sing-box"; exit 1; }
    chmod +x "$BIN"
    # 放入已构建的 app bundle（Debug 与 Release 都放，flutter run / build 均可直接连接）
    for CONF in Debug Release; do
      APP="build/macos/Build/Products/$CONF/MBox.app"
      if [ -d "$APP" ]; then
        mkdir -p "$APP/Contents/MacOS"
        cp "$BIN" "$APP/Contents/MacOS/sing-box"
        chmod +x "$APP/Contents/MacOS/sing-box"
        codesign --force -s - "$APP/Contents/MacOS/sing-box" 2>/dev/null || true
        echo "已放入 $APP/Contents/MacOS/sing-box"
      fi
    done
    # 同时复制一份到 build/singbox 备用（可用 MONEYFLY_SINGBOX 环境变量指向）
    mkdir -p build/singbox
    cp "$BIN" "build/singbox/sing-box"
    chmod +x build/singbox/sing-box
    echo "备用: build/singbox/sing-box（export MONEYFLY_SINGBOX=$(pwd)/build/singbox/sing-box）"
    echo "如果刚才没有构建过 App，请先 flutter build macos --debug 再重跑本脚本。"
    ;;
  *)
    echo "本脚本目前支持 macOS 开发环境；Windows 开发机请手动下载:"
    echo "  $BASE/sing-box-$VERSION-windows-amd64.zip"
    echo "解压后将 sing-box.exe 放到与 mbox.exe 同目录（build/windows/x64/runner/Release/）。"
    ;;
esac
