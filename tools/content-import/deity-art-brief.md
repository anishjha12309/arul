# Ringtone deity art — generation brief

Generate **17 transparent PNGs**: 16 deity line-art pieces plus one neutral
fallback. They become the row artwork in the Ringtones tab of Arul, a South
Indian devotional wallpaper/ringtone app.

Read the whole brief before generating anything. The set is judged as a SET —
17 pieces that look like one artist drew them in one sitting — not as 17
individual images. All 17 appear stacked in a single vertical scrolling list,
so any piece that is heavier, lighter, larger or busier than the others is
immediately visible as wrong.

## How the art is used (this is why the spec is what it is)

Each PNG is composited by the app, at runtime, as the TOP layer of a small
rounded tile ~52dp square (about 156px on a real phone):

```
  layer 3   your PNG            gold line art, transparent everywhere else
  layer 2   kolam dot ring      drawn by the app, just outside your safe area
  layer 1   jewel-tone ground   drawn by the app, dark gradient + hairline rim
```

The ground is one of ten dark jewel tones (maroon, temple green, indigo,
peacock teal, turmeric ochre, aubergine, brick, deep rose, olive, navy) chosen
per track, so **the same PNG must sit well on all ten**. That is the reason for
every rule below: transparent background, one light ink colour, clear corners.

## Hard technical spec

| | |
|---|---|
| Format | PNG, RGBA, true alpha |
| Canvas | 512 × 512 px, square |
| Background | **Fully transparent (alpha 0).** Not white, not near-white, not a light checker, not a solid colour you intend to be keyed out later |
| Ink colour | `#EBD6A3` (warm pale gold) — this exact value, flat, no gradient |
| Secondary detail | Same `#EBD6A3` at 60–75% alpha. No second hue anywhere |
| Technique | **Line art / stroke work.** Open contours, not filled silhouettes. Small solid fills (an eye, a dot, a finial) are fine |
| Stroke weight | 10–16 px at 512. **Uniform across all 17.** Nothing below 8 px |
| Subject box | Centred, max **380 × 380 px** — at least 66 px of clear space on every side |
| Corners | The four corners must be **empty**. The app draws a ring of dots through that zone |
| Filename | the deity slug, lowercase, `.png` — e.g. `murugan.png` |

### Forbidden

No background of any kind · no frame, border, enclosing circle, mandorla or
halo disc · no text, letterforms, signature or watermark · no drop shadow, glow
or blur · no gradients · no colour other than `#EBD6A3` · no photographic or 3D
rendering · no paper/canvas texture.

### Legibility

The tile is ~156 px on screen — a third of the canvas you are drawing on.
Squint test: at 1/3 scale every element must still read. Practically that means
no region of ~60 × 60 px at 512 should contain more than three or four strokes.
Ornament that turns to mush at a third size is worse than no ornament.

## Style

South Indian temple line art — the register of a brass plate etching or a
kolam: frontal, symmetric, calm, single-weight ink, generous negative space.
Devotional and reverent, never cartoon, never cute, never fierce-for-effect.

Attributes must be **iconographically correct** — these are gods people
worship, and a wrong attribute reads as carelessness to the audience. Where the
figure is hard to keep legible at a third scale, prefer the deity's **emblem**
over a full figure; a clean vel reads better than a muddy Murugan.

**Work in this order:** generate `murugan.png` first and settle the style on it
— stroke weight, level of detail, optical size, how much of the 380 px box the
subject fills. Then generate the other 16 against that exact reference. Do not
let detail density drift upward across the batch.

## The 17 pieces

Optical size must match across all of them: every subject should read as
occupying roughly the same visual mass, whether it is a standing figure or a
seated one.

| # | filename | subject | attributes to get right |
|---|---|---|---|
| 1 | `murugan.png` | Murugan / Subrahmanya, standing youth | the **vel** (leaf-bladed spear) held upright, peacock feather or peacock, crown |
| 2 | `ayyappan.png` | Ayyappan, seated yogic posture | **yoga-patta band** around knees and torso, hands in chinmudra, bell at neck |
| 3 | `sivan.png` | Shiva, seated or standing | **jata** (matted hair) with crescent moon, Ganga stream, **trishul**, damaru, third eye, neck serpent |
| 4 | `venkateswara.png` | Venkateswara / Tirupati Balaji, standing frontal | tall conical **kireetam** crown, **urdhva pundra namam** on the forehead, upper hands with shankha and chakra, lower right in abhaya |
| 5 | `krishna.png` | Krishna, standing tribhanga (hip-shifted) | **flute** at the lips, **peacock feather** in the crown, one leg crossed behind |
| 6 | `rama.png` | Rama, standing frontal | the **kodanda** longbow, arrow, crown, calm bearing |
| 7 | `narasimha.png` | Narasimha, seated | **lion head** with radiating mane, four arms, shankha and chakra |
| 8 | `vishnu.png` | Vishnu / Narayana, four-armed standing — **stays generic** (see below) | **shankha, chakra, gada, padma** — all four, clearly distinct. No Venkateswara namam, no Padmanabha couch, nothing that ties it to one form |
| 9 | `lakshmi.png` | Lakshmi, seated on an open lotus | four arms, upper two holding **lotuses**, lower in abhaya/varada, coins falling |
| 10 | `mariamman.png` | Mariamman, village goddess, frontal | crown, **neem-leaf sprigs**, karagam pot, trident |
| 11 | `durga.png` | Durga / Chamundeshwari, on her lion | multiple arms, **trident** foremost, **lion** beneath, crown |
| 12 | `meenakshi.png` | Meenakshi of Madurai, standing | **parrot** perched on the right hand, lotus in the left, crown |
| 13 | `parvati.png` | Ardhanareeswarar — Shiva and Shakti in one figure | clean **vertical split**: Shiva's half with jata and trishul, Parvati's with coiffed hair and lotus |
| 14 | `devi.png` | Generic mother goddess — deliberately non-specific | crown, four arms, lotus and trident, **no attribute unique to any one goddess** |
| 15 | `ganesha.png` | Ganesha, seated | **trunk curled to his left**, broken tusk, modak, large ears, mouse at the feet |
| 16 | `hanuman.png` | Hanuman / Anjaneya, kneeling in namaskaram | **gada** (mace), tail arched high over the head, devotional bearing |
| 17 | `fallback.png` | **Not a deity.** A three-tier South Indian gopuram (temple tower) with a kalasam finial | strictly symmetric, plain, neutral — this is what any unrecognised track gets |

## Three of these carry extra weight

Most tracks name their deity outright. The ones that don't — *Guardian Mother*,
*Cosmic Tandava*, *Divine Call* — fall back to their **category's** image
instead, and future ringtone imports that ship without a deity do the same. So
three pieces get used far more often than their own track count suggests, and
all three must be **deliberately non-specific**:

| piece | also stands for |
|---|---|
| `vishnu.png` | any Perumal track with no named form |
| `devi.png` | any Amman track with no named form |
| `fallback.png` | anything else unrecognised, and any brand-new category |

Give these three the same care as the rest, and resist the urge to make them
interesting by borrowing a specific deity's attribute — a Venkateswara namam on
`vishnu.png` or Lakshmi's coins on `devi.png` would mislabel every track that
lands on them. Murugan, Ayyappan and Sivan are each their own category's image
too, but those are unambiguous, so they need no special handling.

## Acceptance checklist

Before delivering, verify each file:

- [ ] 512 × 512, PNG, RGBA
- [ ] Background alpha is 0 — open it over a black surface AND a maroon one; no
      halo, no fringe, no off-white rectangle
- [ ] Every visible pixel is `#EBD6A3` at some alpha, nothing else
- [ ] Subject inside the centred 380 px box; all four corners empty
- [ ] Downscale to 156 px — still legible, still gold, still not mush
- [ ] Laid out as a vertical strip of all 17, the set looks like one hand: same
      stroke weight, same optical size, same detail density
