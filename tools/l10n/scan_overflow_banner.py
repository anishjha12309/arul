#!/usr/bin/env python3
"""Find Flutter's overflow banner in captured screenshots.

    python tools/l10n/scan_overflow_banner.py build/l10n_audit/device_sweep/shots

## Why this exists instead of reading logcat

`device_sweep.py` originally harvested `A RenderFlex overflowed by N pixels`
from logcat and reported ZERO across every locale and configuration. It was
wrong, and wrong in the most dangerous direction — a clean bill of health.

`lib/main.dart` does:

    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

That REPLACES the default handler rather than wrapping it. The default is what
calls `FlutterError.presentError` and prints the error to the console, so with
it gone every layout error goes to Crashlytics and NOTHING reaches logcat. The
overflow banner still paints on screen; only the text channel is dead. A
detector that reads the text channel therefore reports silence no matter how
badly the screen is broken.

So this reads the pixels instead, which cannot be intercepted.

## The signature

Flutter paints the indicator from `debug_overflow_indicator.dart`:

  * hazard stripes alternating `Color(0xBFFFFF00)` and `Color(0xBF000000)`,
    drawn over whatever is behind them, and
  * a label with a white background and `Color(0xFF900000)` text.

The stripe yellow is the reliable half: at 75% alpha over an arbitrary
background it stays strongly yellow (high R, high G, low B) and nothing in
these apps' palettes — maroon, gold, ivory, deep browns — lands there. The gold
in the theme is `0xFFD4AF37`-ish, which has a much lower G:B ratio than the
overflow yellow, so the two do not collide. The label red is used as
CORROBORATION, not on its own, because dark red is plausible in a maroon app.

A screen is called overflowing when it shows a run of stripe-yellow pixels wide
enough to be a band rather than an icon detail.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

import numpy as np
from PIL import Image

# 0xBFFFFF00 over a dark ground lands around (190,190,0); over a light one
# nearer (255,255,64). Both are "R and G high, B much lower".
_MIN_RG = 150
_MAX_B = 110
_MIN_RG_OVER_B = 1.6

# 0xFF900000 — the label text.
_LABEL_RED = (0x90, 0x00, 0x00)
_LABEL_TOL = 22


def stripe_mask(a: np.ndarray) -> np.ndarray:
    r = a[:, :, 0].astype(np.int16)
    g = a[:, :, 1].astype(np.int16)
    b = a[:, :, 2].astype(np.int16)
    return (
        (r >= _MIN_RG)
        & (g >= _MIN_RG)
        & (b <= _MAX_B)
        & (np.minimum(r, g) >= (b + 1) * _MIN_RG_OVER_B)
    )


def label_mask(a: np.ndarray) -> np.ndarray:
    r = a[:, :, 0].astype(np.int16)
    g = a[:, :, 1].astype(np.int16)
    b = a[:, :, 2].astype(np.int16)
    return (
        (abs(r - _LABEL_RED[0]) <= _LABEL_TOL)
        & (g <= 18)
        & (b <= 18)
    )


def longest_run(row: np.ndarray) -> int:
    """Longest consecutive True run in a boolean row."""
    best = cur = 0
    for v in row:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    return best


def white_mask(a: np.ndarray) -> np.ndarray:
    # PURE white, not "light". The paywall is light-forced on an ivory ground
    # (~0xFFFAF6EF) with maroon type, which sailed through a >=235 threshold and
    # reported a perfectly healthy member screen as overflowing.
    return (a[:, :, 0] >= 250) & (a[:, :, 1] >= 250) & (a[:, :, 2] >= 250)


def scan(path: str, min_run: int) -> dict | None:
    """The overflow LABEL, not the stripes.

    The hazard stripes alone are not discriminative in these two apps: the
    wallpapers are devotional art full of lamp-flame gold, and the theme's own
    accent is gold, so "yellow-ish pixels in a row" fires on a perfectly healthy
    feed. It did, on the very first validation run.

    The label is specific. Flutter draws it as a SOLID WHITE rectangle carrying
    `Color(0xFF900000)` text — a long pure-white horizontal band with dark red
    inside it. Neither app has a surface like that; both are dark maroon and
    ivory, and ivory is not 235-across.
    """
    img = Image.open(path).convert("RGB")
    a = np.asarray(img)

    wm = white_mask(a)
    lm = label_mask(a)
    if not wm.any() or not lm.any():
        return None

    for y in np.flatnonzero(wm.sum(axis=1) >= min_run):
        run = longest_run(wm[y])
        if run < min_run:
            continue
        # Text sits inside the band, so look a few rows either side.
        lo, hi = max(0, int(y) - 6), min(a.shape[0], int(y) + 7)
        reds = int(lm[lo:hi].sum())
        if reds < 80:
            continue
        # The label is a THIN BAND (~14px) over the widget it is complaining
        # about, not a white surface. The premium screen is light-forced, so a
        # plain "long white run + some dark red" fires on its perfectly healthy
        # header. Require the whiteness to STOP within a dozen rows.
        above = longest_run(wm[max(0, int(y) - 14)])
        below = longest_run(wm[min(a.shape[0] - 1, int(y) + 14)])
        if max(above, below) > run * 0.4:
            continue
        sm = stripe_mask(a)
        return {
            "label_run_px": run,
            "row": int(y),
            "label_text_px": reds,
            "stripe_pixels": int(sm.sum()),
        }
    return None


# en_420x1.3_language_sheet.png -> locale, config, screen
_NAME = re.compile(r"^(?P<locale>[a-z]{2})_(?P<config>[\dx.]+)_(?P<screen>.+)\.png$")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("shots", help="directory of screenshots")
    ap.add_argument("--out", default="")
    ap.add_argument(
        "--min-run",
        type=int,
        default=120,
        help="minimum horizontal run of stripe pixels to count as a banner",
    )
    args = ap.parse_args()

    findings, scanned = [], 0
    for name in sorted(os.listdir(args.shots)):
        if not name.endswith(".png"):
            continue
        scanned += 1
        hit = scan(os.path.join(args.shots, name), args.min_run)
        if not hit:
            continue
        m = _NAME.match(name)
        findings.append(
            {
                "file": name,
                "locale": m.group("locale") if m else "",
                "config": m.group("config") if m else "",
                "screen": m.group("screen") if m else "",
                **hit,
            }
        )

    for f in findings:
        print(
            f"  OVERFLOW  {f['locale']:3} {f['config']:9} {f['screen']:16} "
            f"run={f['label_run_px']}px  text_px={f['label_text_px']}"
        )
    print(f"\n{len(findings)} of {scanned} screenshot(s) show the overflow banner")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(
                {"scanned": scanned, "findings": findings}, fh, indent=1
            )
        print(f"-> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
