#!/usr/bin/env node
// adb-level UI automation for agent debugging — workflow in the on-device
// skill. Reads the screen as TEXT via `uiautomator dump` (labels + tap
// coordinates), so an agent acts by label instead of screenshot + manual
// coordinates. In-app labels need a DEBUG build (main.dart keeps the
// semantics tree built under kDebugMode; other builds dump one empty
// FlutterView). System UI — the OS wallpaper chooser, permission grants, the
// One Tap sheet — is always legible: adb operates above app scope, which is
// exactly the layer app-scoped drivers (flutter_driver / integration_test)
// cannot reach.
//
//   node tools/drive.mjs dump [--raw]             screen as text (or full XML)
//   node tools/drive.mjs tap <label> [--index N]  tap by text/content-desc
//   node tools/drive.mjs tap <x> <y>              tap raw coordinates
//   node tools/drive.mjs swipe <up|down|left|right> [--dist px] [--ms n]
//   node tools/drive.mjs type <text>              into the focused field
//   node tools/drive.mjs key <back|home|enter|del|tab|wake|power|recents|KEYCODE_*|n>
//   node tools/drive.mjs open <uri>               VIEW intent (deep/app link)
//   node tools/drive.mjs launch [pkg] | stop [pkg]  start / force-stop the app
//   node tools/drive.mjs current                  focused window — spots OS surfaces
//   node tools/drive.mjs shot [path]              PNG screencap (default: OS temp)
//   node tools/drive.mjs unlock                   wake + dismiss keyguard
//
// Several devices attached: set ANDROID_SERIAL (adb honours it).

import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const PKG = 'com.hsrutility.arul';
const DUMP = '/sdcard/arul-ui-dump.xml';

const adb = (...a) => execFileSync('adb', a, { encoding: 'utf8', maxBuffer: 1 << 26 });

function fail(msg) {
  console.error(msg);
  process.exit(2);
}

function dumpXml() {
  let why = '';
  for (let i = 0; i < 3; i++) {
    try {
      adb('shell', 'uiautomator', 'dump', DUMP);
      const xml = adb('exec-out', 'cat', DUMP);
      if (xml.includes('<node')) return xml;
      why = 'dump produced no nodes';
    } catch (e) {
      why = String(e.stderr || e.message || e).trim();
    }
  }
  return fail(
    'uiautomator dump failed: ' + why + '\n' +
      'Common causes: screen off/locked (try `unlock`), or an in-app screen ' +
      'without semantics (needs a DEBUG build — see main.dart).',
  );
}

const unesc = (s) =>
  s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(+d))
    .replace(/&amp;/g, '&');

function nodes() {
  const out = [];
  for (const tag of dumpXml().match(/<node[^>]*>/g) ?? []) {
    const attr = (n) => {
      const m = tag.match(new RegExp(' ' + n + '="([^"]*)"'));
      return m ? unesc(m[1]) : '';
    };
    const b = attr('bounds').match(/\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/);
    if (!b) continue;
    const [l, t, r, bt] = b.slice(1).map(Number);
    if (r - l <= 0 || bt - t <= 0) continue;
    out.push({
      text: attr('text'),
      desc: attr('content-desc'),
      id: attr('resource-id'),
      clickable: attr('clickable') === 'true',
      focused: attr('focused') === 'true',
      cx: (l + r) >> 1,
      cy: (t + bt) >> 1,
    });
  }
  return out;
}

const interesting = (ns) => ns.filter((n) => n.text || n.desc || n.clickable);

function fmt(n) {
  const both = n.text && n.desc && n.text !== n.desc ? ` (${n.desc})` : '';
  const id = n.id ? `  id=${n.id.replace(/^.*:id\//, '')}` : '';
  const focus = n.focused ? '  <focused>' : '';
  const tap = n.clickable ? ' [tap]' : '      ';
  return `(${n.cx},${n.cy})${tap} ${JSON.stringify(n.text || n.desc)}${both}${id}${focus}`;
}

function tapByLabel(q, index) {
  const ns = interesting(nodes());
  const ql = q.toLowerCase();
  let hits = ns.filter(
    (n) => n.text.toLowerCase().includes(ql) || n.desc.toLowerCase().includes(ql),
  );
  const exact = hits.filter(
    (n) => n.text.toLowerCase() === ql || n.desc.toLowerCase() === ql,
  );
  if (exact.length && index == null) hits = exact;
  if (!hits.length) {
    fail(
      'no node matches ' + JSON.stringify(q) + ' — on screen now:\n' +
        ns.map(fmt).join('\n'),
    );
  }
  if (hits.length > 1 && index == null) {
    fail(
      hits.length + ' nodes match ' + JSON.stringify(q) + ' — re-run with --index N:\n' +
        hits.map((n, i) => '--index ' + i + ': ' + fmt(n)).join('\n'),
    );
  }
  const n = hits[index ?? 0];
  if (!n) fail('--index out of range (' + hits.length + ' matches)');
  adb('shell', 'input', 'tap', String(n.cx), String(n.cy));
  console.log(`tapped (${n.cx},${n.cy}) ${JSON.stringify(n.text || n.desc)}`);
}

function screenSize() {
  const out = adb('shell', 'wm', 'size');
  const m = [...out.matchAll(/(\d+)x(\d+)/g)].pop();
  if (!m) return fail('cannot read screen size from: ' + out);
  return { w: +m[1], h: +m[2] };
}

function swipe(dir, dist, ms) {
  const { w, h } = screenSize();
  const vertical = dir === 'up' || dir === 'down';
  const d = Number.isFinite(dist) ? dist : Math.round((vertical ? h : w) * 0.45);
  const cx = w >> 1;
  const cy = h >> 1;
  const half = d >> 1;
  const pts = {
    up: [cx, cy + half, cx, cy - half],
    down: [cx, cy - half, cx, cy + half],
    left: [cx + half, cy, cx - half, cy],
    right: [cx - half, cy, cx + half, cy],
  }[dir];
  if (!pts) return fail('swipe direction must be up|down|left|right');
  const dur = Number.isFinite(ms) ? ms : 120;
  adb('shell', 'input', 'swipe', ...pts.map(String), String(dur));
  console.log(`swiped ${dir} ${d}px in ${dur}ms`);
}

function typeText(s) {
  if (!s) return fail('type <text>');
  // Device-shell escaping (adb concatenates args into one sh command);
  // `input text` renders %s as a space.
  const esc = s
    .replace(/[\\"'`&|;<>()$*?~#[\]{}!^]/g, (c) => '\\' + c)
    .replace(/ /g, '%s');
  adb('shell', 'input', 'text', esc);
  console.log('typed ' + JSON.stringify(s));
}

const KEYS = {
  back: 'KEYCODE_BACK',
  home: 'KEYCODE_HOME',
  enter: 'KEYCODE_ENTER',
  del: 'KEYCODE_DEL',
  tab: 'KEYCODE_TAB',
  wake: 'KEYCODE_WAKEUP',
  power: 'KEYCODE_POWER',
  recents: 'KEYCODE_APP_SWITCH',
};

// ---- arg parsing ----------------------------------------------------------
const argv = process.argv.slice(2);
const flags = {};
const args = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--raw') flags.raw = true;
  else if (['--index', '--dist', '--ms'].includes(argv[i])) {
    flags[argv[i].slice(2)] = Number(argv[++i]);
  } else args.push(argv[i]);
}
const [cmd, ...rest] = args;

switch (cmd) {
  case 'dump': {
    if (flags.raw) {
      console.log(dumpXml());
    } else {
      const ns = interesting(nodes());
      if (!ns.length) {
        fail(
          'dump succeeded but no labelled/clickable nodes — in-app screens ' +
            'need a DEBUG build (semantics), see main.dart.',
        );
      }
      console.log(ns.map(fmt).join('\n'));
    }
    break;
  }
  case 'tap': {
    if (rest.length === 2 && /^\d+$/.test(rest[0]) && /^\d+$/.test(rest[1])) {
      adb('shell', 'input', 'tap', rest[0], rest[1]);
      console.log(`tapped (${rest[0]},${rest[1]})`);
    } else if (rest[0]) {
      tapByLabel(rest.join(' '), Number.isFinite(flags.index) ? flags.index : null);
    } else {
      fail('tap <label> | tap <x> <y>');
    }
    break;
  }
  case 'swipe':
    swipe(rest[0], flags.dist, flags.ms);
    break;
  case 'type':
    typeText(rest.join(' '));
    break;
  case 'key': {
    if (!rest[0]) fail('key <name|KEYCODE_*|number>');
    adb('shell', 'input', 'keyevent', KEYS[rest[0]] ?? rest[0]);
    console.log('sent ' + (KEYS[rest[0]] ?? rest[0]));
    break;
  }
  case 'open': {
    const uri = rest[0];
    if (!uri) fail('open <uri>');
    if (uri.includes("'")) fail('single quote in URI unsupported');
    adb('shell', "am start -a android.intent.action.VIEW -d '" + uri + "'");
    console.log('opened ' + uri);
    break;
  }
  case 'launch':
    adb('shell', 'monkey', '-p', rest[0] ?? PKG, '-c', 'android.intent.category.LAUNCHER', '1');
    console.log('launched ' + (rest[0] ?? PKG));
    break;
  case 'stop':
    adb('shell', 'am', 'force-stop', rest[0] ?? PKG);
    console.log('force-stopped ' + (rest[0] ?? PKG));
    break;
  case 'current': {
    const win = adb('shell', 'dumpsys', 'window');
    const lines = win
      .split('\n')
      .filter((l) => /mCurrentFocus|mFocusedApp/.test(l))
      .map((l) => l.trim());
    console.log(lines.join('\n') || 'no focused window reported');
    break;
  }
  case 'shot': {
    const out = rest[0] ?? join(tmpdir(), `drive-shot-${Date.now()}.png`);
    writeFileSync(
      out,
      execFileSync('adb', ['exec-out', 'screencap', '-p'], { maxBuffer: 1 << 26 }),
    );
    console.log(out);
    break;
  }
  case 'unlock':
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP');
    adb('shell', 'wm', 'dismiss-keyguard');
    console.log('woke + dismissed keyguard (PIN/pattern still needs a human)');
    break;
  default:
    fail(
      'usage: node tools/drive.mjs <dump|tap|swipe|type|key|open|launch|stop|current|shot|unlock>\n' +
        'see the header of this file for details',
    );
}
