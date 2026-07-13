# Arul brand assets

The mark is a **lotus bloom with a deepam flame rising from its heart** — non-denominational
across all six deity categories. Sources of truth are the SVGs here; the Android PNGs are generated.

| File | What it is |
| --- | --- |
| `logo_mark.svg` | The mark, gold on transparent. 108x108 viewBox = the Android adaptive-icon foreground. |
| `logo_mono.svg` | Same geometry, one flat `#FFFFFF` fill — source for the Android 13+ themed icon. |
| `wordmark.svg` | Mark + **ARUL**. All letterforms are outlined paths (no font dependency). |
| `wordmark_tagline.svg` | Wordmark + `SOUTH INDIAN WALLPAPERS`. |

## Regenerating the Android launcher icons

```bash
node assets/brand/rasterize.mjs        # set CHROME=/path/to/chrome if not auto-found
```

Rasterises with headless Chrome (no npm install, no ImageMagick/Inkscape) and writes
`ic_launcher_foreground.png` + `ic_launcher_monochrome.png` (108dp → 108/162/216/324/432 px)
and the legacy `ic_launcher.png` (48dp → 48/72/96/144/192 px) into
`android/app/src/main/res/mipmap-{m,h,xh,xxh,xxx}dpi/`. Run it after ANY edit to the SVGs.

## Rules the geometry must keep

- **Retint** = change the four gradient stops in `logo_mark.svg` (gold `#E0A82E`→`#F5C95C`).
  The icon background is `ic_launcher_background` in `res/values/colors.xml` (`#14090C`, the brand ink).
- **Safe zone**: all ink sits within r=32.7 of centre (54,54) — inside the 66dp safe circle, so no
  OEM adaptive-icon mask can clip it.
- **Nonzero fill**: every subpath of the bloom winds the same direction so they union. Reverse one
  and the overlaps cancel into holes.
- **The flame must stay a separate lobe**, clearing the bloom by ≥5 units (~2.2px at 48dp). That gap
  is the only thing making the monochrome silhouette readable — never close it.
