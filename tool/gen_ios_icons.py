#!/usr/bin/env python3
"""生成 iOS App 图标（AppIcon.appiconset）。

**历史与现状**：本脚本原先"取 macOS 1024 画稿 → 裁掉透明留白 → 合成到不透明
**黑底** → 按 19 个尺寸缩放"。用户要求图标背景改为**白色**（与其他软件一致），
且 macOS / Android / Windows 的图标已由 `tool/gen_app_icons_white.py` 统一改成
白底 + 品牌色标记，因此这里不再自己实现合成逻辑，而是**直接复用**那个生成器：

  - 底色：白（不再是黑）；
  - 标记：品牌蓝 #455FE9；
  - iOS 要求满幅且不透明 → 裁掉画稿的透明留白后铺满，不留 alpha。

为什么必须复用同一份代码：`.github/workflows/release.yml` 的 iOS 作业会跑本脚本
重建图标，再与仓库里的文件做**像素级**比对（防止有人把图标改回 Flutter 默认
模板）。两条路径一旦不同构，就会因重采样细节差异误判为"图标被改坏"。

用法： python3 tool/gen_ios_icons.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_app_icons_white import render  # noqa: E402  (需要上面的 sys.path)

ICONSET = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
CONTENTS = ICONSET / 'Contents.json'


def main() -> None:
    contents = json.loads(CONTENTS.read_text())
    seen: set[str] = set()
    count = 0
    for entry in contents['images']:
        fn = entry['filename']
        if fn in seen:
            continue
        seen.add(fn)
        base = float(entry['size'].split('x')[0])
        scale = int(entry['scale'].rstrip('x'))
        px = round(base * scale)
        # iOS 图标不允许带 alpha：满幅不透明（白底 + 品牌色标记）
        render(px, full_bleed=True).convert('RGB').save(ICONSET / fn)
        count += 1
    print(f'✓ 生成 {count} 张 iOS 图标（白底 + 品牌色标记，满幅不透明）')


if __name__ == '__main__':
    main()
