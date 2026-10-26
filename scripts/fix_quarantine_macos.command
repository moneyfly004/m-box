#!/bin/bash
# MBox macOS：修复「“MBox”已损坏，无法打开。您应该将它移到废纸篓。」
#
# 为什么会「已损坏」：本 App 用的是 **ad-hoc 签名**（没有付费 Apple 开发者证书，
# TeamIdentifier 为空）。macOS 的 Gatekeeper 对这类 App 只有两种情况：
#   · 文件没有 com.apple.quarantine 隔离标记 → 正常启动；
#   · 文件带隔离标记（凡是从浏览器下载、或从浏览器下载的 DMG 里拖出来的都会有）
#     → 一律拒绝，且报的文案就是「已损坏」。
#
# 所以修复动作只有一个：把隔离属性清掉。App 内部自动更新时就是这么做的
# （ditto --noqtn + xattr -dr），本脚本是给「手动从浏览器下载安装」的用户兜底。
#
# 用法：双击运行；或终端执行：bash fix_quarantine_macos.command [App路径]
set -u

APP="${1:-/Applications/MBox.app}"

echo "=============================================="
echo "  MBox 修复「已损坏，无法打开」"
echo "=============================================="

if [ ! -d "$APP" ]; then
  echo "找不到 $APP"
  echo "如果装在其它的地方，请把 App 拖到本脚本上，或用："
  echo "  bash \"$0\" /你的路径/MBox.app"
  exit 1
fi

echo "目标：$APP"
echo "清理前的扩展属性："
xattr -l "$APP" 2>/dev/null || echo "  (无)"

xattr -dr com.apple.quarantine "$APP" 2>/dev/null
echo "✓ 已清除隔离属性（com.apple.quarantine）"

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "✓ 签名结构完整（ad-hoc）"
else
  echo "！签名结构校验未通过：安装包/App 可能不完整，建议重新下载安装。"
fi

# 顺带清掉下载目录里那些 DMG 的隔离标记，免得下次又拖出一个带标记的 App
for f in "$HOME/Downloads"/MBox-*.dmg; do
  [ -e "$f" ] || continue
  xattr -dr com.apple.quarantine "$f" 2>/dev/null && echo "✓ 已清除隔离属性：$(basename "$f")"
done

echo "=============================================="
echo "  完成：现在可以正常打开 MBox 了。"
echo "  （下次在 App 内点「立即更新」会由 App 自己完成安装，"
echo "   不会再要求你手动拖拽，也不会再出现「已损坏」）"
echo "=============================================="
read -r -p "按回车关闭…" _ || true
