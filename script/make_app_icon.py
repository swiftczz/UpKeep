#!/usr/bin/env python3
"""绘制 Upkeep 的应用图标，输出 AppIcon.png 与 AppIcon.icns。

用法：
    python3 script/make_app_icon.py [输出目录]

图标完全由下面的参数生成，不依赖外部图稿：调参数后重跑即可。

关于画布：macOS 26 只要在 .icns 里发现透明像素，就会把它判定成旧格式图标，
塞进一块灰色玻璃底板里缩小显示。所以这里必须交满幅、完全不透明的方图，
圆角、投影、玻璃边缘一律交给系统合成，不要自己烘焙。
"""

from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
SUPERSAMPLE = 4

# 底色以 rgb(226,55,50) 的正红为基调，上下只差一档明度，保持接近平面的观感。
GRADIENT_TOP = (228, 69, 64)
GRADIENT_BOTTOM = (203, 50, 45)
GLYPH_COLOR = (255, 255, 255)

# 图形是一个开口在右侧的环形更新箭头，外加中心圆点。
# RING_RADIUS（圆弧中心线）、STROKE_WIDTH、DOT_RADIUS 相对画布边长，箭头尺寸相对笔画宽度。
RING_RADIUS = 0.250
STROKE_WIDTH = 0.076
# PIL 角度：0 为 3 点方向、顺时针递增。
# 圆弧顺时针从 3 点略上方一路画到 12 点，开口留在右上；终点切线正好水平，箭头因此完全轴对齐。
ARC_START_DEG = -20.0
ARC_END_DEG = 270.0
ARROW_HALF_WIDTH = 1.05
ARROW_LENGTH = 1.60
# 底边相对圆弧端面回退的比例，留一点重叠避免接缝。
ARROW_BASE_INSET = 0.12
DOT_RADIUS = 0.053

# 图形下方一层极淡的投影，只为和底色分层，不做玻璃高光。
GLYPH_SHADOW_ALPHA = 30
GLYPH_SHADOW_OFFSET = 0.006
GLYPH_SHADOW_BLUR = 0.0085

ICONSET_ENTRIES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    column = [
        tuple(round(a + (b - a) * y / (size - 1)) for a, b in zip(top, bottom))
        for y in range(size)
    ]
    gradient = Image.new("RGB", (1, size))
    gradient.putdata(column)
    return gradient.resize((size, size), Image.Resampling.BILINEAR)


def glyph_mask(size: int) -> Image.Image:
    """绘制环形更新箭头：圆弧 + 一端圆头收尾、一端三角箭头，中心一个圆点。"""
    hi = size * SUPERSAMPLE
    mask = Image.new("L", (hi, hi), 0)
    draw = ImageDraw.Draw(mask)

    center = hi / 2
    radius = RING_RADIUS * hi
    stroke = STROKE_WIDTH * hi
    # PIL 的圆弧描边由外沿向内生长，外沿要放到中心线之外半个笔画宽。
    outer = radius + stroke / 2
    box = (center - outer, center - outer, center + outer, center + outer)
    draw.arc(box, ARC_START_DEG, ARC_END_DEG, fill=255, width=round(stroke))

    # PIL 的圆弧是平头，起点补一个圆盘做成圆头收尾。
    start = math.radians(ARC_START_DEG)
    cap = (center + radius * math.cos(start), center + radius * math.sin(start))
    draw.ellipse(
        (cap[0] - stroke / 2, cap[1] - stroke / 2, cap[0] + stroke / 2, cap[1] + stroke / 2),
        fill=255,
    )

    # 箭头沿圆弧终点的顺时针切线方向，底边与半径方向对齐。
    end = math.radians(ARC_END_DEG)
    tip_anchor = (center + radius * math.cos(end), center + radius * math.sin(end))
    tangent = (-math.sin(end), math.cos(end))
    radial = (math.cos(end), math.sin(end))
    length = ARROW_LENGTH * stroke
    half = ARROW_HALF_WIDTH * stroke
    base = (
        tip_anchor[0] - tangent[0] * length * ARROW_BASE_INSET,
        tip_anchor[1] - tangent[1] * length * ARROW_BASE_INSET,
    )
    draw.polygon(
        [
            (base[0] + radial[0] * half, base[1] + radial[1] * half),
            (base[0] - radial[0] * half, base[1] - radial[1] * half),
            (base[0] + tangent[0] * length, base[1] + tangent[1] * length),
        ],
        fill=255,
    )

    dot = DOT_RADIUS * hi
    draw.ellipse((center - dot, center - dot, center + dot, center + dot), fill=255)

    # 箭头肩部让图形上下不对称，按外接框重新居中。
    box = mask.getbbox()
    if box is not None:
        mask = ImageChops.offset(
            mask,
            round(center - (box[0] + box[2]) / 2),
            round(center - (box[1] + box[3]) / 2),
        )

    return mask.resize((size, size), Image.Resampling.LANCZOS)


def build_master() -> Image.Image:
    art = vertical_gradient(CANVAS, GRADIENT_TOP, GRADIENT_BOTTOM)
    glyph = glyph_mask(CANVAS)

    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, GLYPH_SHADOW_ALPHA), (0, round(CANVAS * GLYPH_SHADOW_OFFSET)), glyph)
    art.paste(
        Image.new("RGB", (CANVAS, CANVAS), (0, 0, 0)),
        (0, 0),
        shadow.filter(ImageFilter.GaussianBlur(CANVAS * GLYPH_SHADOW_BLUR)).getchannel("A"),
    )

    art.paste(GLYPH_COLOR, (0, 0), glyph)
    return art


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Resources")
    out_dir.mkdir(parents=True, exist_ok=True)

    master = build_master()
    png_path = out_dir / "AppIcon.png"
    master.save(png_path)

    iconset = out_dir / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for name, size in ICONSET_ENTRIES:
        master.resize((size, size), Image.Resampling.LANCZOS).save(iconset / name)

    icns_path = out_dir / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "--convert", "icns", str(iconset), "--output", str(icns_path)],
        check=True,
    )

    print(f"已生成 {png_path} 与 {icns_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
