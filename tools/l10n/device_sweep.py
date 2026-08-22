#!/usr/bin/env python3
"""Drive the installed DEBUG app through every locale and display config on a
real phone, and check what it actually renders.

    python tools/l10n/device_sweep.py --serial <s> --package com.hsrutility.arul \
        --arb-dir lib/app/l10n --plan tools/l10n/sweep_plan_arul.json

Two findings come out of it, both mechanical:

  * OVERFLOW — Flutter's overflow banner, found in the SCREENSHOT by
    `scan_overflow_banner.py`, not in logcat.

    Logcat was the first design and it was silently useless: `lib/main.dart`
    assigns `FlutterError.onError = FirebaseCrashlytics...recordFlutterFatalError`,
    which REPLACES the default handler, so layout errors go to Crashlytics and
    never reach the console. The sweep reported zero overflows across every
    locale and configuration while the screenshots plainly showed the banner.
    Pixels cannot be intercepted; the text channel can.

    Debug build either way — the banner is painted inside an `assert`, so a
    release build clips silently and shows nothing. Truncation (an ellipsis) is
    a legal render and produces no banner at all: that half belongs to the
    widget matrix in `test/l10n/`, which measures intrinsic width against the
    slot.

  * ENGLISH LEAK — a string rendered on screen that equals the English ARB
    value for a key the active locale *does* translate. That is the on-device
    proof of a hardcoded literal, and it is the one thing the widget matrix
    cannot see, because the matrix pumps widgets rather than the shipped tree.

## Why this is not a screenshot-diffing script

`uiautomator dump` makes Flutter publish its SEMANTICS TREE, so every row comes
back as a labelled node with bounds — in the active locale, at the active
density. So navigation is by ARB KEY, not by pixel: the plan says "tap the node
whose text is `settingsLanguage`", the driver looks that key up in the ARB for
whichever locale is live and taps whatever bounds the phone reports. One plan
replays across every locale and every density without a coordinate ever being
written down, which is what makes this a sweep rather than a recording.

Density and font scale are read before anything is touched and restored in a
`finally`, including on Ctrl-C — leaving someone's phone at 560dpi is not an
acceptable failure mode.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time

from scan_overflow_banner import scan as scan_banner

_OVERFLOW = re.compile(r"A Render(\w+) overflowed by ([\d.]+) pixels on the (\w+)")
# One <node .../> element. The attributes are pulled out INDEPENDENTLY rather
# than with one alternation, because Flutter emits `text=""` before the real
# `content-desc="..."` on every node — an alternation matches the empty one
# first, every label parses as "", and the sweep concludes that no screen has
# any buttons on it.
_NODE = re.compile(r"<node\s[^>]*>")
_ATTR = re.compile(r'(\w[\w-]*)="([^"]*)"')
_ENTITIES = {
    "&#10;": "\n",
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": '"',
    "&apos;": "'",
}


def _unescape(s: str) -> str:
    for k, v in _ENTITIES.items():
        s = s.replace(k, v)
    return s


class Node:
    __slots__ = ("text", "cx", "cy")

    def __init__(self, text: str, cx: int, cy: int):
        self.text, self.cx, self.cy = text, cx, cy


class Device:
    def __init__(self, serial: str):
        self.serial = serial

    def _bytes(self, args: list[str]) -> bytes:
        return subprocess.run(
            ["adb", "-s", self.serial, *args], capture_output=True
        ).stdout

    def _run(self, args: list[str]) -> str:
        return self._bytes(args).decode("utf-8", "replace")

    def shell(self, cmd: str) -> str:
        return self._run(["shell", cmd])

    # ── display config ───────────────────────────────────────────────────
    def density(self) -> str:
        out = self.shell("wm density")
        m = re.search(r"Override density: (\d+)", out) or re.search(
            r"Physical density: (\d+)", out
        )
        return m.group(1) if m else "420"

    def set_density(self, dpi: str | None):
        self.shell("wm density reset" if dpi is None else f"wm density {dpi}")

    def font_scale(self) -> str:
        return (self.shell("settings get system font_scale") or "1.0").strip()

    def set_font_scale(self, scale: str):
        self.shell(f"settings put system font_scale {scale}")

    # ── app ──────────────────────────────────────────────────────────────
    def set_locale(self, pkg: str, tag: str):
        self.shell(f"cmd locale set-app-locales {pkg} --locales {tag}")

    def restart(self, pkg: str):
        self.shell(f"am force-stop {pkg}")
        self.shell(f"monkey -p {pkg} -c android.intent.category.LAUNCHER 1")

    def clear_log(self):
        self._bytes(["logcat", "-c"])

    def log(self) -> str:
        return self._run(["logcat", "-d", "-v", "brief"])

    def tap(self, x: int, y: int):
        self.shell(f"input tap {x} {y}")

    def back(self):
        self.shell("input keyevent KEYCODE_BACK")

    def screenshot(self, path: str):
        with open(path, "wb") as f:
            f.write(self._bytes(["exec-out", "screencap", "-p"]))

    def _dump_once(self) -> list[Node]:
        self.shell("uiautomator dump /sdcard/_sweep.xml")
        xml = self.shell("cat /sdcard/_sweep.xml")
        out = []
        for el in _NODE.findall(xml):
            attrs = dict(_ATTR.findall(el))
            label = _unescape(attrs.get("content-desc") or attrs.get("text") or "").strip()
            bounds = attrs.get("bounds", "")
            m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
            if not label or not m:
                continue
            x1, y1, x2, y2 = (int(g) for g in m.groups())
            out.append(Node(label, (x1 + x2) // 2, (y1 + y2) // 2))
        return out

    def nodes(self, retries: int = 3) -> list[Node]:
        """The live semantics tree, as labelled nodes with centres.

        Flutter turns semantics ON only when an accessibility client asks for
        them, and the FIRST `uiautomator dump` after a cold start is what asks —
        so it comes back with the FlutterView and nothing inside it. Reading
        that empty tree as "the screen has no such button" is what made the
        first version of this sweep report 60 unreachable steps and zero
        findings, which looks exactly like a clean run. Hence the retry.
        """
        for attempt in range(retries):
            out = self._dump_once()
            if out:
                return out
            time.sleep(1.0 + attempt)
        return []

    def installed(self, pkg: str) -> bool:
        return f"package:{pkg}" in self.shell(f"pm list packages {pkg}")


def load_arbs(arb_dir: str, locales: list[str], template: str) -> dict:
    def read(loc):
        p = os.path.join(arb_dir, f"app_{loc}.arb")
        d = json.load(open(p, encoding="utf-8"))
        return {
            k: v
            for k, v in d.items()
            if not k.startswith("@") and isinstance(v, str)
        }

    base = read(template)
    # A demoted key is absent from a locale ARB and gen_l10n back-fills English,
    # so the effective catalog is English updated by the locale's own values —
    # exactly what the user sees.
    return {template: base, **{l: {**base, **read(l)} for l in locales if l != template}}


def find(nodes: list[Node], candidates: list[str]) -> Node | None:
    """The node showing any of [candidates].

    Navigation has to work while the app is still in the PREVIOUS language —
    the locale is changed from inside the app, so the Settings row you must tap
    to get there is not yet in the language you are heading for. So a hop names
    an ARB key and the driver accepts that key's value in ANY supported locale.

    Semantics merge a row's title and subtitle into one label separated by
    newlines, hence containment rather than equality.
    """
    wanted = [c for c in candidates if c]
    for c in wanted:
        for n in nodes:
            if n.text == c:
                return n
    for c in wanted:
        for n in nodes:
            if c in n.text:
                return n
    return None


def pick_language(dev, plan, arbs, locale: str) -> bool:
    """Settings -> Language -> the tile for [locale]. Returns success.

    Verifies by re-reading the tree afterwards rather than trusting the tap: a
    sweep that thinks it switched language and did not is the failure mode this
    whole function exists to prevent.
    """
    english_name = plan["language_names"][locale]
    for key in plan["language_path"]:
        node = find(dev.nodes(), [a.get(key, "") for a in arbs.values()])
        if node is None:
            return False
        dev.tap(node.cx, node.cy)
        time.sleep(1.2)

    tile = find(dev.nodes(), [english_name])
    if tile is None:
        return False
    dev.tap(tile.cx, tile.cy)
    time.sleep(1.5)

    # Proof, not optimism: a key that IS translated in the target locale must
    # now be on screen in that language. Without this the sweep happily
    # measures English six times and reports a clean run.
    key = plan["verify_key"]
    expected = arbs[locale].get(key, "")
    if locale != plan.get("template", "en") and expected == arbs[plan.get("template", "en")].get(key):
        raise SystemExit(
            f"verify_key '{key}' reads the same in {locale} as in the template, "
            "so it cannot prove a language switch — pick a key that is translated."
        )
    return find(dev.nodes(), [expected]) is not None


def sweep_screen(dev, step, arbs, shot_dir, tag) -> dict:
    """Navigates to one screen and records what it renders."""
    missed = None
    for key in step.get("path", []):
        node = find(dev.nodes(), [a.get(key, "") for a in arbs.values()])
        if node is None:
            missed = key
            break
        dev.tap(node.cx, node.cy)
        time.sleep(step.get("settle", 1.2))

    rendered = [n.text for n in dev.nodes()]
    shot = os.path.join(shot_dir, f"{tag}.png")
    dev.screenshot(shot)
    banner = scan_banner(shot, 150)
    # Only unwind a path we actually walked. Pressing BACK at the feed root
    # exits to the launcher, and every later step in the run then fails against
    # the home screen instead of the app.
    if missed is None:
        for _ in range(step.get("back", 0)):
            dev.back()
            time.sleep(0.7)
    return {"rendered": rendered, "unreachable": missed, "overflow": banner}


def reanchor(dev, plan, arbs, package: str) -> None:
    """Puts the app back on a known screen after a step failed to navigate.

    Without this a single missed tap poisons the rest of the locale: the app is
    left on whatever screen the failed hop landed on, every later step is
    measured against the wrong tree, and the screenshots are filed under names
    that no longer describe them. The first run had a `language_sheet` capture
    that was actually the Ringtones tab.
    """
    anchor = plan.get("anchor_key")
    if anchor:
        node = find(dev.nodes(), [a.get(anchor, "") for a in arbs.values()])
        if node is not None:
            dev.tap(node.cx, node.cy)
            time.sleep(1.0)
            return
    dev.restart(package)
    time.sleep(plan.get("launch_settle", 7))


def english_leaks(rendered: list[str], strings: dict, en: dict) -> list[dict]:
    """Strings on screen that are the ENGLISH value of a key this locale
    translates. A hardcoded literal is the usual cause.

    AMBIGUOUS VALUES ARE NEVER REPORTED. Two keys can share one English string
    — `uploadTitle` and `settingsUpload` are both "Upload your content" — and
    when one of the pair is demoted (English everywhere) that string is SUPPOSED
    to render in English. Mapping the sighting to the other, translated key
    turns a correct render into a defect: this reported five, one per locale,
    before the check went in. If a rendered string cannot be traced to exactly
    one key, it proves nothing about that screen.
    """
    by_value: dict[str, list[str]] = {}
    for key, v_en in en.items():
        by_value.setdefault(v_en, []).append(key)

    # Only keys whose translation actually differs from English can leak
    # detectably; a demoted key rendering English is the design, not a defect.
    translated = {
        v_en: keys[0]
        for v_en, keys in by_value.items()
        if len(keys) == 1 and strings.get(keys[0]) != v_en
    }
    out = []
    for text in rendered:
        for line in text.split("\n"):
            line = line.strip()
            key = translated.get(line)
            if key:
                out.append({"key": key, "english": line, "expected": strings[key]})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--package", required=True)
    ap.add_argument("--arb-dir", required=True)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--out", default="build/l10n_audit/device_sweep")
    ap.add_argument(
        "--configs",
        default="420:1.0,420:1.3,560:1.0",
        help="density:font_scale. 420 is this phone's native ~411dp; "
        "560 squeezes it to ~308dp, under the 320dp gating width.",
    )
    args = ap.parse_args()

    plan = json.load(open(args.plan, encoding="utf-8"))
    locales, template = plan["locales"], plan.get("template", "en")
    arbs = load_arbs(args.arb_dir, locales, template)

    dev = Device(args.serial)
    if not dev.installed(args.package):
        print(f"{args.package} is not installed", file=sys.stderr)
        return 2

    shot_dir = os.path.join(args.out, "shots")
    os.makedirs(shot_dir, exist_ok=True)

    orig_dpi, orig_scale = dev.density(), dev.font_scale()
    print(f"device: density={orig_dpi} font_scale={orig_scale} — will restore")

    overflows, leaks, unreachable, transcript = [], [], [], []
    try:
        for cfg in args.configs.split(","):
            dpi, scale = cfg.split(":")
            dev.set_density(dpi)
            dev.set_font_scale(scale)
            time.sleep(2)

            for locale in locales:
                strings = arbs[locale]
                dev.restart(args.package)
                time.sleep(plan.get("launch_settle", 7))

                # THE APP OWNS ITS LOCALE. `LocaleNotifier` reads a persisted
                # preference and defaults to English; it never consults the
                # platform locale, so `cmd locale set-app-locales` changes
                # nothing and a sweep driven that way silently measures English
                # six times. Drive the in-app picker instead. Its tiles are
                # labelled with the endonym over the English language name, and
                # the ENGLISH name is what this matches on, because it is the
                # one label that does not move when the language does.
                if not pick_language(dev, plan, arbs, locale):
                    unreachable.append(
                        {
                            "locale": locale,
                            "config": f"{dpi}x{scale}",
                            "screen": "(language picker)",
                            "stuck_at_key": "could not switch language in-app",
                        }
                    )
                    continue
                dev.clear_log()

                for step in plan["screens"]:
                    tag = f"{locale}_{dpi}x{scale}_{step['name']}"
                    r = sweep_screen(dev, step, arbs, shot_dir, tag)
                    transcript.append(
                        {
                            "locale": locale,
                            "config": f"{dpi}x{scale}",
                            "screen": step["name"],
                            "reached": r["unreachable"] is None,
                            "rendered": r["rendered"],
                            "overflow": r["overflow"],
                        }
                    )
                    if r["overflow"]:
                        overflows.append(
                            {
                                "locale": locale,
                                "config": f"{dpi}x{scale}",
                                "screen": step["name"],
                                **r["overflow"],
                            }
                        )
                    if r["unreachable"]:
                        unreachable.append(
                            {
                                "locale": locale,
                                "config": f"{dpi}x{scale}",
                                "screen": step["name"],
                                "stuck_at_key": r["unreachable"],
                            }
                        )
                        reanchor(dev, plan, arbs, args.package)
                        continue
                    for lk in english_leaks(r["rendered"], strings, arbs[template]):
                        leaks.append(
                            {
                                "locale": locale,
                                "config": f"{dpi}x{scale}",
                                "screen": step["name"],
                                **lk,
                            }
                        )

                n = sum(
                    1
                    for t in transcript
                    if t["locale"] == locale
                    and t["config"] == f"{dpi}x{scale}"
                    and t.get("overflow")
                )
                print(f"  {locale} @{dpi}/{scale}: {n} overflowing screen(s)")
    finally:
        dev.set_locale(args.package, "")
        dev.set_density(None)
        dev.set_font_scale(orig_scale)
        print(f"restored: density=reset font_scale={orig_scale}")

    # Deduplicate leaks: the same hardcoded literal shows up once per config.
    seen, unique_leaks = set(), []
    for l in leaks:
        sig = (l["locale"], l["screen"], l["key"])
        if sig not in seen:
            seen.add(sig)
            unique_leaks.append(l)

    result = {
        "package": args.package,
        "overflows": overflows,
        "english_leaks": unique_leaks,
        "unreachable": unreachable,
        # Everything each screen actually rendered, so the analysis above can be
        # redone or argued with WITHOUT another 50-minute pass on the phone.
        "transcript": transcript,
    }
    path = os.path.join(args.out, f"{args.package.split('.')[-1]}-device-sweep.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(
        f"\n{len(overflows)} overflow(s), {len(unique_leaks)} english leak(s), "
        f"{len(unreachable)} unreachable step(s) -> {path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
