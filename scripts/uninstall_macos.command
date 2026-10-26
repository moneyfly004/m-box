#!/bin/bash
# MBox macOS 彻底卸载脚本
#
# 双击运行（或终端执行）即可：删除 App 本体 + 全部应用数据
# （配置/订阅节点/缓存/日志/偏好/Keychain 令牌/内核临时目录），
# 卸载后重装即为全新状态，不沿用旧配置、旧节点。
#
# 数据落点依据：
#   - path_provider_foundation 在 macOS 用 Bundle.main.bundleIdentifier
#     作为 Application Support / Caches 子目录（top.mbox.app）
#   - SharedPreferences → ~/Library/Preferences/<bundle-id>.plist
#   - flutter_secure_storage → Keychain（access_token / refresh_token）
#   - 崩溃日志 → ~/Documents/crash_logs
#   - 内核工作目录 → $TMPDIR/mbox_core
set -u

BUNDLE_ID="top.mbox.app"
APP="/Applications/MBox.app"
HOME_APP="$HOME/Applications/MBox.app"

echo "=============================================="
echo "  MBox 彻底卸载（macOS）"
echo "=============================================="
echo "将删除以下内容："
echo "  · 应用本体：$APP / $HOME_APP"
echo "  · 应用数据：~/Library/Application Support/$BUNDLE_ID"
echo "  · 缓存：    ~/Library/Caches/$BUNDLE_ID"
echo "  · 偏好：    ~/Library/Preferences/$BUNDLE_ID.plist"
echo "  · 崩溃日志：~/Documents/crash_logs"
echo "  · Keychain：access_token / refresh_token"
echo "  · 内核临时：\${TMPDIR}/mbox_core"
echo "=============================================="
read -r -p "确认删除以上全部内容？[y/N] " yn
case "$yn" in
  [Yy] | [Yy][Ee][Ss]) ;;
  *) echo "已取消。"; exit 0 ;;
esac

# 1) 结束运行中的进程
if pkill -x "MBox" 2>/dev/null; then
  echo "✓ 已结束运行中的 MBox"
fi
sleep 1

# 2) 应用本体
rm -rf "$APP" "$HOME_APP"
echo "✓ 已删除应用本体"

# 3) 应用数据（配置/订阅节点/缓存/偏好/崩溃日志）
rm -rf "$HOME/Library/Application Support/$BUNDLE_ID"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist"
rm -rf "$HOME/Documents/crash_logs"
# 兜底：历史版本可能残留的其它命名目录
rm -rf "$HOME/Library/Application Support/MBox"
rm -rf "$HOME/Library/Caches/MBox"
echo "✓ 已删除应用数据（配置/节点/缓存/偏好/日志）"

# 4) Keychain 登录令牌（尽力而为，可能因服务名差异清不掉，不影响文件数据清理）
for svc in access_token refresh_token; do
  security delete-generic-password -s "$svc" >/dev/null 2>&1 && \
    echo "✓ 已删除 Keychain 项：$svc" || true
  security delete-generic-password -a "$svc" >/dev/null 2>&1 && \
    echo "✓ 已删除 Keychain 项（account）：$svc" || true
done

# 5) 内核临时工作目录
rm -rf "${TMPDIR:-/tmp}/mbox_core" /tmp/mbox_core
echo "✓ 已删除内核临时目录"

echo "=============================================="
echo "  卸载完成。MBox 及其数据已彻底删除。"
echo "=============================================="
