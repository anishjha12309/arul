"""Build the paywall's bundled font cuts (`assets/fonts/`) — the ONLY way to
regenerate them; do not hand-edit the TTFs.

Google Fonts ships these three as VARIABLE fonts and publishes no statics, so
each weight the design uses is instanced out of the variable master and then
subset to Latin + punctuation + the currency block. English-by-decision on
`/premium` (CLAUDE.md §5) is what makes a Latin-only subset safe; the upstream
Lora's Cyrillic and Vietnamese would otherwise be dead weight in the APK.

Gelasio is the numerals cut, subset harder still. It stands in for the handoff's
Georgia — metric-compatible with it, same old-style figures — and is the only
serif here that carries U+20B9 ₹, which is why it is also the `fontFamilyFallback`
behind every paywall Lora style. See docs/ui-direction.md §Type.

    pip install fonttools
    mkdir src && cd src   # then, from https://github.com/google/fonts/raw/main/ofl/
    #   cinzel/Cinzel[wght].ttf  →  Cinzel.ttf
    #   lora/Lora[wght].ttf      →  Lora.ttf
    #   lora/Lora-Italic[wght].ttf → Lora-Italic.ttf
    #   gelasio/Gelasio[wght].ttf  → Gelasio.ttf
    python tools/build-fonts.py     # writes out/, copy over assets/fonts/

The per-glyph ink metrics printed at the end are what `PriceLockup._gelasioInk`
holds — re-copy them if Gelasio is ever rebuilt from a newer upstream, or the
rupee stops being centred against the amount.
"""

import os
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.subset import Subsetter, Options

SRC = "src"
OUT = "out"
os.makedirs(OUT, exist_ok=True)

UNICODES = []
for lo, hi in [
    (0x0020, 0x007E),  # basic latin
    (0x00A0, 0x00FF),  # latin-1 supplement (· × ° é …)
    (0x2010, 0x2015),  # dashes
    (0x2018, 0x201F),  # curly quotes
    (0x2020, 0x2022),  # dagger, bullet
    (0x2026, 0x2026),  # ellipsis
    (0x2039, 0x203A),  # single guillemets
    (0x20A0, 0x20BF),  # currency block (incl. U+20B9 ₹)
    (0x2122, 0x2122),  # trademark
]:
    UNICODES.extend(range(lo, hi + 1))

# Gelasio is a numerals-only cut: it exists to supply the price lockup and the
# one glyph Lora/Cinzel/Marcellus all lack, U+20B9 ₹.
NUMERALS = [ord(c) for c in " 0123456789.,/-+₹"]

JOBS = [
    ("Cinzel.ttf", 500, "Cinzel-Medium.ttf", UNICODES),
    ("Lora.ttf", 400, "Lora-Regular.ttf", UNICODES),
    ("Lora.ttf", 500, "Lora-Medium.ttf", UNICODES),
    ("Lora.ttf", 600, "Lora-SemiBold.ttf", UNICODES),
    ("Lora-Italic.ttf", 400, "Lora-Italic.ttf", UNICODES),
    ("Gelasio.ttf", 400, "Gelasio-Regular.ttf", NUMERALS),
]


def metrics(font, label):
    upem = font["head"].unitsPerEm
    os2 = font["os2"] if "os2" in font else font["OS/2"]
    cap = getattr(os2, "sCapHeight", None)
    glyf = font["glyf"]
    cmap = font.getBestCmap()
    out = {"upem": upem, "capHeight": cap}
    for key, ch in [("rupee", "₹"), ("1", "1"), ("2", "2"), ("9", "9")]:
        name = cmap.get(ord(ch))
        if name is None:
            out[key] = "MISSING"
            continue
        g = glyf[name]
        out[key] = None if g.numberOfContours == 0 else (g.yMin, g.yMax)
    print(f"  metrics[{label}]: {out}")


for src, wght, dst, charset in JOBS:
    font = TTFont(os.path.join(SRC, src))
    # updateFontNames=False: Cinzel's STAT has no named value at wght 500, and
    # Flutter resolves the family from pubspec.yaml, not from the name table.
    instancer.instantiateVariableFont(font, {"wght": wght}, inplace=True)
    opts = Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.recalc_bounds = True
    sub = Subsetter(options=opts)
    sub.populate(unicodes=charset)
    sub.subset(font)
    path = os.path.join(OUT, dst)
    font.save(path)
    print(f"{dst}: {os.path.getsize(path) // 1024} KB")
    metrics(font, dst)
