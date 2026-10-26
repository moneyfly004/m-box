#!/bin/bash
# 下载 sing-box 离线分流规则集到 assets/rules/（智能模式 CN 直连用）。
# 发布包由 CI 自动下载（见 .github/workflows/release.yml）；本地开发/测试用本脚本。
#
# 来源：SagerNet 官方规则集仓库的 rule-set 分支（binary .srs，sing-box 1.12+
# 唯一支持的规则集格式；官方 Release 只发 .db，1.14 尚不支持）
#   geosite-cn.srs  域名分类（~56KB，zlib+succinct）
#   geoip-cn.srs    IP 国家库（~34KB）
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/assets/rules"
mkdir -p "$DIR"

fetch() { # $1=文件名 $2=url
  local f="$1" url="$2"
  if [ -s "$DIR/$f" ]; then
    echo "已存在: $DIR/$f ($(du -h "$DIR/$f" | cut -f1))，跳过"
    return 0
  fi
  echo "下载 $f ..."
  curl -fL --max-time 300 -o "$DIR/$f" "$url"
  # 校验：SRS 魔数 + 合理体积
  if [ "$(head -c 3 "$DIR/$f")" != "SRS" ]; then
    echo "错误: $f 不是有效的 binary rule-set（拿到的是错误页？）"
    rm -f "$DIR/$f"
    return 1
  fi
  ls -lh "$DIR/$f"
}

fetch geosite-cn.srs \
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
fetch geoip-cn.srs \
  "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"

echo "完成。assets/rules/ 内容："
ls -lh "$DIR"
