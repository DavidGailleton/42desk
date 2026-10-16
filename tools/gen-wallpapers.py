"""Generates rices/<id>/wallpaper.jpg from each rice's palette (no third-party art).

Usage: python3 tools/gen-wallpapers.py [id...]   (needs Pillow; run from the repo root)
"""
import random
import re
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

W, H = 2560, 1440
RICES = Path("rices")

# Blocky "42" on a 5x7 grid per digit, for the 42 rice.
DIGITS = {
    "4": ["1...1", "1...1", "1...1", "11111", "....1", "....1", "....1"],
    "2": ["11111", "....1", "....1", "11111", "1....", "1....", "11111"],
}


def palette(conf):
    text = conf.read_text()
    get = lambda k: re.search(rf'^{k}="(#[0-9a-fA-F]{{6}})"', text, re.M).group(1)
    return {k: get(k) for k in ("BG", "BG_ALT", "ACCENT", "ACCENT2", "FG_DIM")}


def rgb(h):
    return tuple(int(h[i : i + 2], 16) for i in (1, 3, 5))


def gradient(top, bottom):
    """Vertical gradient from <top> to <bottom>."""
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def glow(img, colors, seed, count=5):
    """Large blurred blobs of the accent colors (an aurora-like light)."""
    rnd = random.Random(seed)
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for i in range(count):
        c = colors[i % len(colors)]
        r = rnd.randint(H // 5, H // 2)
        x, y = rnd.randint(0, W), rnd.randint(-H // 4, H)
        draw.ellipse([x - r * 2, y - r, x + r * 2, y + r], fill=tuple(int(v * 0.22) for v in c))
    layer = layer.filter(ImageFilter.GaussianBlur(H // 8))
    # Screen: the blobs light the gradient up, never darken it.
    return ImageChops.screen(img, layer)


def draw_42(img, color):
    draw = ImageDraw.Draw(img)
    cell = H // 18
    width = (5 * 2 + 1) * cell
    x0, y0 = (W - width) // 2, (H - 7 * cell) // 2
    for d, digit in enumerate("42"):
        for row, line in enumerate(DIGITS[digit]):
            for col, on in enumerate(line):
                if on == "1":
                    x = x0 + (d * 6 + col) * cell
                    y = y0 + row * cell
                    draw.rectangle([x + 2, y + 2, x + cell - 3, y + cell - 3], fill=color)


def main(ids):
    for conf in sorted(RICES.glob("*/rice.conf")):
        rid = conf.parent.name
        if ids and rid not in ids:
            continue
        p = palette(conf)
        img = gradient(rgb(p["BG_ALT"]), rgb(p["BG"]))
        # 42's second accent is white: only its teal glows.
        accents = [rgb(p["ACCENT"])] if rid == "42" else [rgb(p["ACCENT"]), rgb(p["ACCENT2"])]
        img = glow(img, accents, seed=rid)
        if rid == "42":
            draw_42(img, rgb(p["ACCENT"]))
        out = conf.parent / "wallpaper.jpg"
        img.save(out, quality=88, optimize=True)
        print(f"{out}: {out.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    main(set(sys.argv[1:]))
