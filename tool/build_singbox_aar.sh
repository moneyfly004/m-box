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
  if [ -n "${SINGBOX_SRC:-}" ]; then
    # 复用已有的 sing-box 源码检出（网络不稳/离线时用；CI 不用这个分支）
    echo "使用本地源码: $SINGBOX_SRC"
    cd "$SINGBOX_SRC"
  else
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    git clone --depth 1 --branch "v$VERSION" https://github.com/SagerNet/sing-box "$TMP/sing-box"
    cd "$TMP/sing-box"
  fi
  # Go 1.24+ 起 gomobile bind 要求 x/mobile 进入模块依赖图（tool 指令），
  # 否则报 "gomobile bind requires golang.org/x/mobile in the current module"。
  export PATH="$PATH:$(go env GOPATH)/bin"
  go get -tool golang.org/x/mobile/cmd/gobind || go get golang.org/x/mobile/cmd/gomobile
  # 注意两点（都是踩出来的）：
  # 1) 参数名是 `-javapkg`（不是 -java-package），写错只会打印 usage 就退出；
  # 2) `-javapkg` 是**包前缀**，Go 包名 libbox 会被追加：写 top.moneyfly 才得到
  #    `top.moneyfly.libbox.*`（写 top.moneyfly.libbox 会变成
  #    `top.moneyfly.libbox.libbox.*`，App 侧 import 全部解析不到）；
  # 3) libbox 用 `//go:linkname` 摸了标准库的 os.checkPidfdOnce
  #    （experimental/libbox/pidfd_android.go，绕 Go 的 pidfd 阻塞 bug），
  #    Go 1.23+ 默认校验 linkname 目标 → 报
  #    「invalid reference to os.checkPidfdOnce」，c-shared 直接构建失败。
  #    官方发布包也是靠关掉这项校验构建的。
  gomobile bind -target android -androidapi 21 \
    -javapkg top.moneyfly \
    -ldflags "-checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$VERSION" \
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

# 完整性快检：必须是 zip（aar），且含内核 native 库。
# 自己 gomobile 编出来的叫 libgojni.so；sing-box-lib 发布的预编译包叫
# libmoneyfly.so —— 两种都算正常（Java 侧按 gojni 名加载）。
unzip -l "$DEST/libmbox.aar" | grep -qE "lib(gojni|moneyfly)\.so" \
  || { echo "错误: AAR 内容异常（没有内核 native 库）"; exit 1; }
echo "OK"
