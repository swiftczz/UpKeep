#!/usr/bin/env python3
"""把一张方形图稿转换成符合 Apple 规范的 AppIcon.png 与 AppIcon.icns。

用法：
    python3 script/make_app_icon.py <源图稿> [输出目录]

源图稿可以带白色/浅色底，脚本会识别图形本体、按 macOS 圆角规范重新裁形。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
# Big Sur 之后的 macOS 图标规范：1024 画布内图形占 824，四周留白供投影使用。
ART = 824
CORNER_RADIUS = 185.4
# 连续曲率圆角（Apple squircle）的超椭圆指数，越大越方。
SQUIRCLE_EXPONENT = 5.0
SUPERSAMPLE = 4
# 判定"这个像素属于图形本体"的色差阈值，用来剔除图稿自带的底色与外发光。
BACKDROP_TOLERANCE = 40

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


def squircle_mask(size: int, radius: float) -> Image.Image:
    """生成连续曲率圆角矩形遮罩，四角用超椭圆而非圆弧。"""
    hi = size * SUPERSAMPLE
    r = radius * SUPERSAMPLE
    mask = Image.new("L", (hi, hi), 0)
    pixels = mask.load()
    n = SQUIRCLE_EXPONENT
    for y in range(hi):
        # 只在角落区域逐像素判断，其余整行直接填充。
        dy = min(y + 0.5, hi - y - 0.5)
        if dy >= r:
            for x in range(hi):
                pixels[x, y] = 255
            continue
        ky = ((r - dy) / r) ** n
        for x in range(hi):
            dx = min(x + 0.5, hi - x - 0.5)
            if dx >= r:
                pixels[x, y] = 255
            elif ky + ((r - dx) / r) ** n <= 1.0:
                pixels[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def subject_mask(image: Image.Image) -> Image.Image:
    """标出图形本体：与画布边缘连通的底色算背景，被图形包围的高光不算。"""
    alpha = image.getchannel("A")
    if alpha.getextrema()[0] < 250:
        backdrop = alpha.point(lambda v: 255 if v <= 8 else 0)
    else:
        rgb = image.convert("RGB")
        flat = Image.new("RGB", rgb.size, rgb.getpixel((0, 0)))
        diff = ImageChops.difference(rgb, flat).convert("L")
        backdrop = diff.point(lambda v: 255 if v < BACKDROP_TOLERANCE else 0)

    if backdrop.getpixel((0, 0)) != 255:
        return Image.new("L", image.size, 255)

    ImageDraw.floodfill(backdrop, (0, 0), 128)
    return backdrop.point(lambda v: 0 if v == 128 else 255)


def square_crop(image: Image.Image, mask: Image.Image) -> tuple[Image.Image, Image.Image]:
    """按图形本体的外接正方形裁切，避免非等比缩放导致变形。"""
    box = mask.getbbox()
    if box is None:
        return image, mask
    left, top, right, bottom = box
    side = max(right - left, bottom - top)
    cx, cy = (left + right) / 2, (top + bottom) / 2
    box = (
        round(cx - side / 2),
        round(cy - side / 2),
        round(cx - side / 2) + side,
        round(cy - side / 2) + side,
    )
    return image.crop(box), mask.crop(box)


def extend_edges(rgb: Image.Image, known: Image.Image, radius: int = 40) -> Image.Image:
    """把图形边缘的颜色向外扩散，填补规范圆角比原图更方时露出的缺口。"""
    # 图稿最外圈像素混了底色，若拿来当取样源会在角落留下浅色接缝，先向内腐蚀掉。
    for _ in range(2):
        known = known.filter(ImageFilter.MinFilter(9))
    weight = np.asarray(known, dtype=np.float32) / 255.0
    premultiplied = Image.fromarray(
        (np.asarray(rgb, dtype=np.float32) * weight[:, :, None]).astype(np.uint8)
    )

    blur = ImageFilter.GaussianBlur(radius)
    spread = np.asarray(premultiplied.filter(blur), dtype=np.float32)
    coverage = np.asarray(known.filter(blur), dtype=np.float32) / 255.0
    estimate = spread / np.maximum(coverage, 1e-3)[:, :, None]

    # 羽化取样边界，否则原图与扩散色之间会留下一道硬接缝。
    blend = (
        np.asarray(known.filter(ImageFilter.GaussianBlur(8)), dtype=np.float32) / 255.0
    )[:, :, None]
    filled = blend * np.asarray(rgb, dtype=np.float32) + (1.0 - blend) * estimate
    return Image.fromarray(np.clip(filled, 0, 255).astype(np.uint8))


def build_master(source: Path) -> Image.Image:
    original = Image.open(source).convert("RGBA")
    art, mask = square_crop(original, subject_mask(original))
    art = art.resize((ART, ART), Image.LANCZOS)
    mask = mask.resize((ART, ART), Image.LANCZOS).point(lambda v: 255 if v > 127 else 0)

    shape = squircle_mask(ART, CORNER_RADIUS)
    filled = extend_edges(art.convert("RGB"), mask)
    filled.putalpha(shape)

    offset = (CANVAS - ART) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 56), (offset, offset + 10), shape)
    shadow = shadow.filter(ImageFilter.GaussianBlur(11))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(filled, (offset, offset))
    return canvas


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("Resources")
    out_dir.mkdir(parents=True, exist_ok=True)

    master = build_master(source)
    png_path = out_dir / "AppIcon.png"
    master.save(png_path)

    iconset = out_dir / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for name, size in ICONSET_ENTRIES:
        master.resize((size, size), Image.LANCZOS).save(iconset / name)

    icns_path = out_dir / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "--convert", "icns", str(iconset), "--output", str(icns_path)],
        check=True,
    )

    print(f"已生成 {png_path} 与 {icns_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
