from pathlib import Path
from PIL import Image, ImageFilter, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
IN_DIR = ROOT / "tmp" / "ringtone-deities-keyed"
OUT_DIR = ROOT / "output" / "ringtone-deities"
NAMES = [
    "murugan", "ayyappan", "sivan", "venkateswara", "krishna", "rama",
    "narasimha", "vishnu", "lakshmi", "mariamman", "durga", "meenakshi",
    "parvati", "devi", "ganesha", "hanuman", "fallback",
]
GOLD = (235, 214, 163)
TARGET_EXTENT = {
    # Broad/seated or unusually detailed subjects are slightly smaller so the
    # full vertical strip carries a consistent optical mass.
    "ayyappan": 330,
    "sivan": 315,
    "narasimha": 300,
    "lakshmi": 320,
    "durga": 315,
    "ganesha": 330,
    "fallback": 340,
}


def finish(name: str) -> None:
    src = Image.open(IN_DIR / f"{name}.png").convert("RGBA")
    alpha = src.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        raise RuntimeError(f"{name}: empty alpha")
    alpha = alpha.crop(bbox)
    extent = TARGET_EXTENT.get(name, 360)
    scale = min(extent / alpha.width, extent / alpha.height)
    size = (max(1, round(alpha.width * scale)), max(1, round(alpha.height * scale)))
    alpha = alpha.resize(size, Image.Resampling.LANCZOS)
    # Restore the requested 10-16 px visual stroke after downscaling the model output.
    alpha = alpha.filter(ImageFilter.MaxFilter(9))
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.35))
    canvas_a = Image.new("L", (512, 512), 0)
    x = (512 - alpha.width) // 2
    y = (512 - alpha.height) // 2
    canvas_a.paste(alpha, (x, y))
    canvas = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    visible = canvas_a.point(lambda value: 255 if value else 0)
    canvas.paste(Image.new("RGBA", (512, 512), (*GOLD, 255)), (0, 0), visible)
    canvas.putalpha(canvas_a)
    canvas.save(OUT_DIR / f"{name}.png", optimize=True)


def composite(bg):
    strip = Image.new("RGB", (156, 156 * len(NAMES)), bg)
    for i, name in enumerate(NAMES):
        art = Image.open(OUT_DIR / f"{name}.png").convert("RGBA")
        art = art.resize((156, 156), Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (156, 156), (*bg, 255))
        tile.alpha_composite(art)
        strip.paste(tile.convert("RGB"), (0, i * 156))
    return strip


def previews() -> None:
    black = composite((0, 0, 0))
    maroon = composite((70, 8, 26))
    both = Image.new("RGB", (312, black.height))
    both.paste(black, (0, 0))
    both.paste(maroon, (156, 0))
    both.save(OUT_DIR / "set-preview-black-maroon.png", optimize=True)

    cols, rows = 5, 4
    panels = []
    for bg in [(0, 0, 0), (70, 8, 26)]:
        panel = Image.new("RGB", (cols * 156, rows * 156), bg)
        for i, name in enumerate(NAMES):
            art = Image.open(OUT_DIR / f"{name}.png").convert("RGBA")
            art = art.resize((156, 156), Image.Resampling.LANCZOS)
            tile = Image.new("RGBA", (156, 156), (*bg, 255))
            tile.alpha_composite(art)
            panel.paste(tile.convert("RGB"), ((i % cols) * 156, (i // cols) * 156))
        panels.append(panel)
    grid = Image.new("RGB", (panels[0].width, panels[0].height * 2))
    grid.paste(panels[0], (0, 0))
    grid.paste(panels[1], (0, panels[0].height))
    grid.save(OUT_DIR / "set-preview-grid.png", optimize=True)


def validate() -> None:
    failures = []
    rows = []
    for name in NAMES:
        path = OUT_DIR / f"{name}.png"
        im = Image.open(path).convert("RGBA")
        a = im.getchannel("A")
        bbox = a.getbbox()
        rgb_values = {p[:3] for p in im.getdata() if p[3]}
        ok = (
            im.size == (512, 512)
            and im.mode == "RGBA"
            and rgb_values == {GOLD}
            and bbox is not None
            and bbox[0] >= 66 and bbox[1] >= 66
            and bbox[2] <= 446 and bbox[3] <= 446
            and all(a.getpixel(pt) == 0 for pt in [(0, 0), (511, 0), (0, 511), (511, 511)])
        )
        rows.append(f"{name}: {'PASS' if ok else 'FAIL'} bbox={bbox} colors={rgb_values}")
        if not ok:
            failures.append(name)
    (OUT_DIR / "validation.txt").write_text("\n".join(rows) + "\n", encoding="utf-8")
    if failures:
        raise RuntimeError("Validation failed: " + ", ".join(failures))


if __name__ == "__main__":
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for item in NAMES:
        finish(item)
    previews()
    validate()
