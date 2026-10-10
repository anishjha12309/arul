#!/usr/bin/env python
"""Cut static instances out of the device-pulled VARIABLE fonts.

Why this exists: `FontLoader` registers a variable font at its DEFAULT axis
instance, and Flutter's `fontWeight:` does NOT drive a `wght` axis. So a
w600/w700 slot measured against a raw `-VF` file measures at 400 — falsely
NARROW, which would let real overflows pass the l10n matrix. Every weight the
theme actually asks for therefore needs its own static face.

Weight clamping is deliberate fidelity, not a shortcut: the Noto Indic faces
Android ships expose wght[400..700], so a `w800` slot renders at 700 on a real
phone too. We emit nothing for a weight the axis cannot reach and let the
font matcher pick the nearest face, exactly as Android does.

Regenerate:  python tools/l10n/instance_fonts.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "test" / "fixtures" / "fonts" / "device-android36"
OUT = SRC / "instanced"

# Every weight > 400 the theme requests (grep FontWeight over lib/), plus 400
# itself so the regular face is an instance too and the whole family is cut
# from one source under one process.
WEIGHTS = [400, 500, 600, 700, 800]

# RobotoFlex is a 1.7 MB superset we do not need (Roboto-Regular.ttf is the
# face Android actually resolves for Latin UI); RobotoStatic is already static.
SKIP = {"RobotoFlex-Regular.ttf", "RobotoStatic-Regular.ttf"}


def main() -> int:
    if not SRC.is_dir():
        print(f"missing font fixtures: {SRC}", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)

    made: list[str] = []
    for src in sorted(SRC.glob("*.ttf")):
        if src.name in SKIP:
            continue
        font = TTFont(src)
        if "fvar" not in font:
            continue
        axes = {a.axisTag: a for a in font["fvar"].axes}
        wght = axes.get("wght")
        if wght is None:
            continue

        seen: set[int] = set()
        for want in WEIGHTS:
            got = int(min(max(want, wght.minValue), wght.maxValue))
            if got in seen:
                # Clamped onto a weight we already cut — emitting a second
                # identical face under a different usWeightClass would let the
                # matrix measure a bold the device cannot render.
                continue
            seen.add(got)

            # Pin every axis, not just wght: Roboto also carries wdth/ital and
            # an unpinned axis would stay variable (and load at its default).
            pins = {"wght": got}
            for tag, ax in axes.items():
                if tag != "wght":
                    pins[tag] = ax.defaultValue

            inst = instancer.instantiateVariableFont(
                TTFont(src), pins, inplace=True, updateFontNames=False
            )
            inst["OS/2"].usWeightClass = got
            # macStyle bold bit — Skia reads it when scoring a family match.
            inst["head"].macStyle = (inst["head"].macStyle & ~0b1) | (
                1 if got >= 600 else 0
            )
            dst = OUT / f"{src.stem}-w{got}.ttf"
            inst.save(dst)
            made.append(f"{dst.name}  ({dst.stat().st_size // 1024} KB)")

    for line in made:
        print(line)
    print(f"\n{len(made)} static instances -> {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
