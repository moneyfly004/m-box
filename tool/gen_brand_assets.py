#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 MBox 品牌图标（macOS / Windows / Android / iOS / Flutter 资源 + 托盘）。

设计：圆角方形渐变徽标（靛蓝 → 青），中央白色「M」由两道上行折线构成
（速度 / 转发），右上角一颗青色节点点（中继节点）。
所有尺寸从 4096 超采样画布降采样，保证小尺寸边缘干净。
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 4096          # 超采样画布
SCALE = S / 1024  # 设计坐标 → 画布坐标

C1 = (79, 70, 229)    # indigo-600
C2 = (6, 182, 212)    # cyan-500
C3 = (56, 189, 248)   # sky-400 (节点点)


def design_canvas():
    """返回 1024 设计坐标系下的 RGBA 画布（Pillow 直绘）。"""
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # ---- 背景：圆角方形 + 对角渐变 ----
    radius = int(228 * SCALE)
    margin = int(40 * SCALE)
    box = (margin, margin, S - margin, S - margin)

    grad = Image.new('RGB', (S, S))
    gd = ImageDraw.Draw(grad)
    # 对角渐变：左上 C1 → 右下 C2，叠加一点垂直亮度变化
    for y in range(S):
        t = y / (S - 1)
        r = int(C1[0] + (C2[0] - C1[0]) * t)
        g = int(C1[1] + (C2[1] - C1[1]) * t)
        b = int(C1[2] + (C2[2] - C1[2]) * t)
        gd.line([(0, y), (S, y)], fill=(r, g, b))
    # 斜向叠一层更亮的渐变，做出「光从左上打来」的感觉
    sheen = Image.new('L', (S, S), 0)
    sd = ImageDraw.Draw(sheen)
    for i in range(0, S, 4):
        alpha = int(70 * (1 - i / S))
        sd.polygon([(i, 0), (i + 4, 0), (i + 4 - S, S), (i - S, S)], fill=alpha)
    sheen = sheen.filter(ImageFilter.GaussianBlur(8 * SCALE))
    overlay = Image.new('RGB', (S, S), (255, 255, 255))
    grad = Image.composite(overlay, grad, sheen.point(lambda v: v)).convert('RGB') \
        if False else grad

    mask = Image.new('L', (S, S), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle(box, radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # ---- 内描边（让图标在深色背景上不糊） ----
    stroke = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(stroke)
    sd2.rounded_rectangle(box, radius=radius, outline=(255, 255, 255, 64),
                          width=int(6 * SCALE))
    img = Image.alpha_composite(img, stroke)
    d = ImageDraw.Draw(img)

    # ---- 中央「M」：两道上行折线（速度感），两端圆角 ----
    w = int(84 * SCALE)          # 线宽
    top = int(360 * SCALE)
    bottom = int(700 * SCALE)
    left = int(300 * SCALE)
    right = int(724 * SCALE)
    mid = (left + right) // 2

    white = (255, 255, 255, 255)
    pts = [
        (left, bottom),
        (left, top),
        (mid, int(560 * SCALE)),
        (right, top),
        (right, bottom),
    ]
    d.line(pts, fill=white, width=w, joint='curve')
    # 两端补圆头
    for p in (pts[0], pts[-1]):
        r = w // 2
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=white)

    # ---- 右上角中继节点 ----
    cx, cy = int(790 * SCALE), int(250 * SCALE)
    r = int(58 * SCALE)
    ring = int(10 * SCALE)
    d.ellipse([cx - r - ring, cy - r - ring, cx + r + ring, cy + r + ring],
              outline=(255, 255, 255, 150), width=ring)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=C3 + (255,))

    # ---- 轻微内阴影，增加层次 ----
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    shd = ImageDraw.Draw(shadow)
    shd.rounded_rectangle(box, radius=radius, outline=(0, 0, 0, 50),
                          width=int(18 * SCALE))
    shadow = shadow.filter(ImageFilter.GaussianBlur(10 * SCALE))
    img = Image.alpha_composite(shadow, img)
    return img


def rounded(img, size, radius_ratio=0.0):
    """缩放到 size；radius_ratio>0 时裁圆角（用于 iOS/Android 非透明需求）。"""
    out = img.resize((size, size), Image.LANCZOS)
    if radius_ratio > 0:
        mask = Image.new('L', (size, size), 0)
        md = ImageDraw.Draw(mask)
        md.rounded_rectangle((0, 0, size - 1, size - 1),
                             radius=int(size * radius_ratio), fill=255)
        out = Image.composite(out, Image.new('RGBA', (size, size), (0, 0, 0, 0)), mask)
    return out


def save(img, path, size, radius_ratio=0.0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rounded(img, size, radius_ratio).save(path, 'PNG')
    print(f"  {os.path.relpath(path, ROOT)}  {size}x{size}")


def main():
    master = design_canvas()

    # ---- macOS AppIcon ----
    mac = f'{ROOT}/macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for n in (16, 32, 64, 128, 256, 512, 1024):
        save(master, f'{mac}/app_icon_{n}.png', n)

    # ---- iOS AppIcon ----
    ios = f'{ROOT}/ios/Runner/Assets.xcassets/AppIcon.appiconset'
    # iOS 图标不能带透明通道 → 铺白底后转 RGB
    flat = Image.new('RGB', (S, S), (255, 255, 255))
    flat.paste(master, (0, 0), master)
    for name, px in {
        'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
        'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
        'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
        'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
        'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }.items():
        os.makedirs(ios, exist_ok=True)
        rounded(flat, px).convert('RGB').save(f'{ios}/{name}', 'PNG')
        print(f"  {os.path.relpath(ios + '/' + name, ROOT)}  {px}x{px}")

    # ---- Android mipmap（自适应图标用不到，直接给方形+圆角） ----
    res = f'{ROOT}/android/app/src/main/res'
    for d, px in {'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
                  'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192}.items():
        save(master, f'{res}/{d}/ic_launcher.png', px, radius_ratio=0.22)

    # ---- Windows .ico（多尺寸） ----
    ico_path = f'{ROOT}/windows/runner/resources/app_icon.ico'
    os.makedirs(os.path.dirname(ico_path), exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    frames = [rounded(master, s) for s in sizes]
    frames[0].save(ico_path, format='ICO', sizes=[(s, s) for s in sizes],
                   append_images=frames[1:])
    print(f"  {os.path.relpath(ico_path, ROOT)}  ICO {sizes}")

    # ---- Flutter 资源：应用内 logo（保留原文件名，避免改动业务代码） ----
    assets = f'{ROOT}/assets'
    master.resize((512, 512), Image.LANCZOS).save(f'{assets}/moneyfly-logo.png', 'PNG')
    print(f"  assets/moneyfly-logo.png  512x512")
    # 托盘图标（Windows 只认 ico；macOS 用 png）
    tray = [16, 32, 48, 64]
    tf = [rounded(master, s) for s in tray]
    tf[0].save(f'{assets}/tray_icon.ico', format='ICO',
               sizes=[(s, s) for s in tray], append_images=tf[1:])
    print(f"  assets/tray_icon.ico  ICO {tray}")

    # ---- 设计稿留档 ----
    master.resize((1024, 1024), Image.LANCZOS).save(f'{ROOT}/design/mbox-logo.png', 'PNG')
    os.makedirs(f'{ROOT}/design', exist_ok=True)
    print(f"  design/mbox-logo.png  1024x1024")


if __name__ == '__main__':
    os.makedirs(f'{ROOT}/design', exist_ok=True)
    main()
    print("完成")
