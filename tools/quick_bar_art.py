r"""Cuts the Quick Access bar's backdrop into android/app/src/main/res/drawable-nodpi.

    pip install Pillow
    python tools/quick_bar_art.py [SOURCE_DIR]     # default ~/Anish/quickbar-art

Reads SOURCE_DIR/banner.png (any size; the ChatGPT prompt asked for 1536x1024) and writes one cut per
layout height. A missing source becomes a flat gradient placeholder, so the bar builds before the art
exists. Corners are baked into the pixels because the layouts draw it fitXY: android:clipToOutline
only exists from Android 12, and minSdk is 24. The buttons are shape drawables and need no art.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance

OUT = Path(__file__).resolve().parent.parent / "android/app/src/main/res/drawable-nodpi"

# (output name, source stem, width, height, corner radius px, dim) -> each cut keeps the aspect its
# layout shows it at (collapsed 48dp tall, expanded 100dp), so fitXY barely stretches. 720px wide:
# SystemUI decodes it on every shade draw, and a 360dp shade shows no more than that.
CUTS = [
    ("quick_bar_banner_collapsed", "banner", 720, 144, 36, 0.8),
    ("quick_bar_banner_expanded", "banner", 720, 240, 29, 0.8),
]

PLACEHOLDER = {
    "banner": ((26, 16, 51), (74, 15, 30)),
}


def gradient(size, start, end):
    w, h = size
    img = Image.new("RGB", size)
    draw = ImageDraw.Draw(img)
    for x in range(w):
        t = x / max(w - 1, 1)
        draw.line([(x, 0), (x, h - 1)], fill=tuple(round(a + (b - a) * t) for a, b in zip(start, end)))
    return img


def cover(img, w, h):
    """Centre crop to w:h, then resize — the prompts keep the subject in the middle band."""
    sw, sh = img.size
    target = w / h
    if sw / sh > target:
        nw = round(sh * target)
        img = img.crop(((sw - nw) // 2, 0, (sw - nw) // 2 + nw, sh))
    else:
        nh = round(sw / target)
        img = img.crop((0, (sh - nh) // 2, sw, (sh - nh) // 2 + nh))
    return img.resize((w, h), Image.Resampling.LANCZOS)


def rounded(img, radius):
    # 4x supersampled mask -> smooth corners without a soft edge.
    w, h = img.size
    big = Image.new("L", (w * 4, h * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * 4 - 1, h * 4 - 1), radius * 4, fill=255)
    out = img.convert("RGBA")
    out.putalpha(big.resize((w, h), Image.Resampling.LANCZOS))
    return out


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Anish" / "quickbar-art"
    OUT.mkdir(parents=True, exist_ok=True)
    for name, stem, w, h, radius, dim in CUTS:
        src = source / f"{stem}.png"
        if src.exists():
            art = cover(Image.open(src).convert("RGB"), w, h)
            origin = src.name
        else:
            art = gradient((w, h), *PLACEHOLDER[stem])
            origin = "placeholder"
        if dim != 1.0:
            # The gold-edged buttons sit on it -> a touch darker keeps their edges and labels crisp.
            art = ImageEnhance.Brightness(art).enhance(dim)
        out = OUT / f"{name}.webp"
        rounded(art, radius).save(out, "WEBP", quality=82, method=6)
        print(f"{out.name:34} {w}x{h}  {out.stat().st_size // 1024:>3} KB  from {origin}")


if __name__ == "__main__":
    main()
