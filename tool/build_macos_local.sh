#!/usr/bin/env bash
# 本地 macOS 构建 + 稳定签名
#
# 为什么需要它：Xcode 的 CodeSign 是构建的最后一步，任何"构建阶段脚本"里做的
# 签名都会被它覆盖回 ad-hoc（本仓库 2026-10-31 实测：加了脚本阶段仍产出 adhoc）。
# 所以必须在 flutter build 结束**之后**再签一次。
#
# 目的：让 App 的 designated requirement 锚定证书（而非 cdhash），
# 这样重新构建后钥匙串授权依然有效，不会反复弹「想使用钥匙串机密信息」。
# CI 上没有该证书，本脚本不参与 CI，构建流程不受影响。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/macos/Build/Products/Release/MBox.app"
IDENT="${APPLE_SIGN_IDENTITY:-LocalDev}"
ENT="macos/Runner/Release.entitlements"

flutter build macos --release

if [ ! -d "$APP" ]; then
  echo "找不到产物: $APP" >&2
  exit 1
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENT"; then
  echo "未找到签名身份 $IDENT → 保持 Xcode 的 ad-hoc 签名" >&2
  exit 0
fi

if [ -s "$ENT" ]; then
  codesign --force --deep --sign "$IDENT" --timestamp=none --entitlements "$ENT" "$APP"
else
  codesign --force --deep --sign "$IDENT" --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✅ 已用 $IDENT 签名: $APP"

if [ "${1:-}" = "--install" ]; then
  echo "安装到 /Applications …"
  rm -rf "/Applications/MBox.app"
  ditto "$APP" "/Applications/MBox.app"
  codesign --verify --deep --strict "/Applications/MBox.app"
  echo "✅ 已安装: /Applications/MBox.app"
fi
