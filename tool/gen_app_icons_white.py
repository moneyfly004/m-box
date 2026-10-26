#!/usr/bin/env python3
"""生成 App 图标：**白色圆角底 + 品牌色标记**（原来是蓝紫→青渐变底）。

用户要求：「图标背景要做成白色，和其他软件类似，不能是带颜色的」。
所以这里只做**一件事**：把底色从渐变蓝换成纯白，**图形的形状与大小完全不动**
（同一份画稿 `design/mbox-logo.png`：把其中的白色标记原样提取出来，重新上成
品牌蓝 `#455FE9`，底换成白；轮廓/留白/圆角沿用原画稿 alpha 通道，逐像素一致）。

为什么不用 `assets/mbox-logo.svg` 重画：那条 path 的 M 比现用画稿的标记大
（实测占宽 71% vs 现用 50%），重画会顺手把 logo 放大一圈 —— 用户只要求换底色，
不该夹带改设计。

各平台约定（沿用仓库既有做法，尺寸/留白与改动前一致）：
- macOS / Android 传统图标 / Windows：四周透明留白 + 圆角（原画稿 alpha）；
- iOS：**满幅不透明**（iOS 自己裁圆角；图标内不能有透明像素）；
- Android 8+ 自适应图标：白色背景色层 + 只含标记的透明前景层（收在 72/108 安全区）。

用法： python3 tool/gen_app_icons_white.py
自检：打印每份产物的「白底/标记/透明占比 + 角 alpha」，并核对标记包围盒不变。
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'design/mbox-logo.png'   # 原画稿：渐变底 + 白色标记（1024, RGBA）

WHITE = (255, 255, 255)
BRAND = (0x45, 0x5F, 0xE9)            # 品牌蓝紫（与 assets/mbox-logo.svg 的 stroke 同色）
SS = 4                                # 超采样

# 白度阈值：实测画稿里标记 min(r,g,b)>=240，底色 <160，中间只有 AA 边缘
LO, HI = 176.0, 240.0


def _load_brand_layer(size: tuple[int, int] | None = None):
    """返回 (白色底版, 品牌色标记层)，均为 RGBA，带原画稿的圆角轮廓。"""
    src = Image.open(SRC).convert('RGBA')
    if size is not None and src.size != size:
        src = src.resize(size, Image.LANCZOS)
    w, h = src.size
    silhouette = src.getchannel('A')                       # 圆角方轮廓（含留白/圆角）
    r, g, b, _ = src.split()
    # 白度 = 三通道最小值：蓝色底 ~30，白色标记 255
    minc = ImageChops.darker(ImageChops.darker(r, g), b)
    scale = 255.0 / (HI - LO)
    # 软过渡：LO 以下全透明、HI 以上全不透明（抗锯齿边缘平滑混色）
    mark_alpha = minc.point(
        lambda v: 0 if v <= LO else (255 if v >= HI else int((v - LO) * scale)))
    mark_alpha = ImageChops.multiply(mark_alpha, silhouette)  # 只在轮廓内

    white_layer = Image.new('RGBA', (w, h), WHITE + (255,))
    white_layer.putalpha(silhouette)

    brand_layer = Image.new('RGBA', (w, h), BRAND + (255,))
    brand_layer.putalpha(mark_alpha)
    return white_layer, brand_layer, silhouette, mark_alpha


def _compose_native(*, full_bleed: bool) -> Image.Image:
    """在画稿原生分辨率下合成一张完整图标（白底 + 品牌色标记）。

    **必须原生尺寸合成再缩放**：图层是 1024×1024，若直接贴到更大的画布上，
    内容只会落在左上角（早期版本就踩了这个坑：白底占比只有 4%，图标整体偏位）。
    """
    white_layer, brand_layer, silhouette, _ = _load_brand_layer()
    if full_bleed:
        box = silhouette.getbbox() or (0, 0, *white_layer.size)
        white_layer = white_layer.crop(box)
        brand_layer = brand_layer.crop(box)
    canvas = Image.new('RGBA', white_layer.size, (0, 0, 0, 0))
    canvas.alpha_composite(white_layer)
    canvas.alpha_composite(brand_layer)
    return canvas


def _downscale(img: Image.Image, size: int) -> Image.Image:
    """单步 LANCZOS 缩放。

    **刻意不做逐级减半**：CI 的 iOS 作业会用 `tool/gen_ios_icons.py` 重建图标并
    与仓库里的文件做**像素级**比对，两条路径必须完全同构，否则会因重采样细节不同
    而误判失败。
    """
    return img.resize((size, size), Image.LANCZOS)


def render(size: int, *, full_bleed: bool) -> Image.Image:
    """满幅（iOS）或带透明留白（macOS/Android/Win）的图标。"""
    return _downscale(_compose_native(full_bleed=full_bleed), size)


def render_adaptive_foreground(size: int = 432, fill: float = 0.60) -> Image.Image:
    """Android 自适应前景：只保留标记，按 [fill] 比例收在 72/108 安全区内。"""
    big = size * SS
    _, brand_layer, _, mark_alpha = _load_brand_layer()
    mbox = mark_alpha.getbbox() or (0, 0, big, big)
    mw, mh = mbox[2] - mbox[0], mbox[3] - mbox[1]
    target = big * fill
    k = min(target / mw, target / mh)
    mark = brand_layer.crop(mbox).resize((max(1, round(mw * k)), max(1, round(mh * k))),
                                        Image.LANCZOS)
    canvas = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    canvas.alpha_composite(mark, ((big - mark.width) // 2, (big - mark.height) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def summarize(path: Path) -> str:
    im = Image.open(path).convert('RGBA')
    w, h = im.size
    px = im.load()
    total = w * h
    white = brand = transparent = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 10:
                transparent += 1
            elif r > 235 and g > 235 and b > 235:
                white += 1
            elif b > 120 and b - r > 40:
                brand += 1
    return (f'{w}x{h} 白底={white * 100 / total:.1f}% 标记={brand * 100 / total:.1f}% '
            f'透明={transparent * 100 / total:.1f}% 角alpha={px[1, 1][3]} '
            f'alpha_min={im.getchannel("A").getextrema()[0]}')


def mark_bbox_ratio(path: Path) -> tuple[float, float]:
    im = Image.open(path).convert('RGBA')
    w, h = im.size
    _, brand_layer, _, _ = _load_brand_layer()
    mbox = brand_layer.getchannel('A').getbbox()
    if not mbox:
        return (0.0, 0.0)
    return ((mbox[2] - mbox[0]) / w, (mbox[3] - mbox[1]) / h)


def main() -> None:
    written: list[Path] = []

    mac = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for name, size in [('app_icon_16.png', 16), ('app_icon_32.png', 32),
                       ('app_icon_64.png', 64), ('app_icon_128.png', 128),
                       ('app_icon_256.png', 256), ('app_icon_512.png', 512),
                       ('app_icon_1024.png', 1024)]:
        p = mac / name
        render(size, full_bleed=False).save(p)
        written.append(p)

    ios = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    contents = json.loads((ios / 'Contents.json').read_text())
    done: set[str] = set()
    for entry in contents['images']:
        fn = entry['filename']
        if fn in done:
            continue
        done.add(fn)
        px = round(float(entry['size'].split('x')[0]) * int(entry['scale'].rstrip('x')))
        render(px, full_bleed=True).convert('RGB').save(ios / fn)  # iOS 不允许 alpha
        written.append(ios / fn)

    res = ROOT / 'android/app/src/main/res'
    for folder, px in [('mipmap-mdpi', 48), ('mipmap-hdpi', 72), ('mipmap-xhdpi', 96),
                       ('mipmap-xxhdpi', 144), ('mipmap-xxxhdpi', 192)]:
        p = res / folder / 'ic_launcher.png'
        render(px, full_bleed=False).save(p)
        written.append(p)

    fg = res / 'drawable-nodpi/ic_launcher_foreground.png'
    fg.parent.mkdir(parents=True, exist_ok=True)
    render_adaptive_foreground().save(fg)
    written.append(fg)

    (res / 'values').mkdir(parents=True, exist_ok=True)
    (res / 'values/colors.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <!-- 图标底色：白（前景层见 drawable-nodpi/ic_launcher_foreground.png） -->\n'
        '    <color name="ic_launcher_background">#FFFFFF</color>\n'
        '</resources>\n')
    anydpi = res / 'mipmap-anydpi-v26'
    anydpi.mkdir(parents=True, exist_ok=True)
    for fn in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        (anydpi / fn).write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background"/>\n'
            '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
            '</adaptive-icon>\n')

    ico = ROOT / 'windows/runner/resources/app_icon.ico'
    render(256, full_bleed=False).save(
        ico, format='ICO',
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

    # ---- App 内部用的品牌图（首页左上角 / 登录页 / 托盘）----------------
    # 为什么必须单独出这一份：桌面/任务栏图标换了白底之后，App 内部如果还在
    # 用旧画稿（渐变蓝底），同一个软件会出现两套 logo —— 用户实测就是这样。
    # 内部图用**同一份白底圆角图形**，和图标逐像素一致，不存在「两套视觉」。
    inner = ROOT / 'assets/mbox-logo.png'
    inner.parent.mkdir(parents=True, exist_ok=True)
    render(512, full_bleed=False).save(inner)
    written.append(inner)

    # 托盘（macOS 菜单栏）：只留标记、透明底。菜单栏高度只有 22pt，白底方块
    # 在那里显得又重又糊；纯标记在任何壁纸/明暗菜单栏上都干净。
    tray_png = ROOT / 'assets/tray_icon.png'
    _, brand_layer, _, mark_alpha = _load_brand_layer((256, 256))
    mark_only = Image.new('RGBA', brand_layer.size, BRAND + (255,))
    mark_only.putalpha(mark_alpha)
    bbox = mark_only.getbbox()
    mark_only = mark_only.crop(bbox) if bbox else mark_only
    side = 80
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    mw, mh = mark_only.size
    scale = min(side * 0.92 / mw, side * 0.92 / mh)
    mark_only = mark_only.resize((max(1, round(mw * scale)), max(1, round(mh * scale))),
                                 Image.LANCZOS)
    canvas.alpha_composite(mark_only, ((side - mark_only.width) // 2,
                                       (side - mark_only.height) // 2))
    canvas.save(tray_png)
    written.append(tray_png)

    # Windows 托盘：tray_manager 只认 .ico，同样换成白底新版（旧的是渐变底）
    tray_ico = ROOT / 'assets/tray_icon.ico'
    render(256, full_bleed=False).save(
        tray_ico, format='ICO',
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    written.append(tray_ico)

    print('== 生成的图标（白底 + 品牌色标记，形状/大小与原画稿一致）==')
    for p in written:
        print(f'{p.relative_to(ROOT)}  {summarize(p)}')
    print(f'{ico.relative_to(ROOT)}  (ICO 多尺寸)')
    print('== Android 自适应图标 ==')
    print(f'  drawable-nodpi/ic_launcher_foreground.png  {summarize(fg)}')
    print('  values/colors.xml → ic_launcher_background=#FFFFFF')
    print('  mipmap-anydpi-v26/ic_launcher.xml, ic_launcher_round.xml')
    wratio, hratio = mark_bbox_ratio(mac / 'app_icon_1024.png')
    print(f'== 自检：标记占宽 {wratio * 100:.1f}% 占高 {hratio * 100:.1f}%（与改动前一致）==')


if __name__ == '__main__':
    main()
