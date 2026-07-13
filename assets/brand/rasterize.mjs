#!/usr/bin/env node
/**
 * Regenerate the Android launcher PNGs from the brand SVGs.
 *
 *   node assets/brand/rasterize.mjs
 *
 * Rasterises with headless Chrome (no npm install, no ImageMagick/Inkscape needed).
 * Set CHROME=/path/to/chrome if it is not found automatically.
 *
 * Outputs, under android/app/src/main/res/ :
 *   mipmap-{m,h,xh,xxh,xxx}dpi/ic_launcher_foreground.png   108dp -> 108/162/216/324/432 px
 *   mipmap-{m,h,xh,xxh,xxx}dpi/ic_launcher_monochrome.png   108dp, white silhouette
 *   mipmap-{m,h,xh,xxh,xxx}dpi/ic_launcher.png               48dp legacy, mark on solid ink
 */
import fs from 'fs';
import path from 'path';
import os from 'os';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RES = path.resolve(HERE, '../../android/app/src/main/res');
const INK = '#14090C'; // keep in sync with values/colors.xml -> ic_launcher_background

const DENSITIES = [
  ['mdpi', 1], ['hdpi', 1.5], ['xhdpi', 2], ['xxhdpi', 3], ['xxxhdpi', 4],
];

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const c = [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    `${os.homedir()}/AppData/Local/Google/Chrome/Application/chrome.exe`,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ];
  const hit = c.find((p) => fs.existsSync(p));
  if (!hit) throw new Error('Chrome not found — set CHROME=/path/to/chrome');
  return hit;
}
const CHROME = findChrome();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'arul-brand-'));

/** Render `svg` markup at exactly size x size px. Transparent unless the svg paints a bg. */
function png(svg, size, out) {
  const html = path.join(TMP, 'p.html');
  fs.writeFileSync(html, `<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}` +
    `svg{display:block}</style>${svg}`);
  execFileSync(CHROME, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--default-background-color=00000000', `--window-size=${size},${size}`,
    `--screenshot=${out}`, `file:///${html.replace(/\\/g, '/')}`,
  ], { stdio: 'pipe' });
}

const read = (f) => fs.readFileSync(path.join(HERE, f), 'utf8');
/** strip the XML comment header and force an explicit pixel size */
const at = (svg, size, viewBox = '0 0 108 108') => svg
  .replace(/<!--[\s\S]*?-->\s*/g, '')
  .replace(/<svg([^>]*)>/, `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="${viewBox}">`);

const mark = read('logo_mark.svg');
const mono = read('logo_mono.svg');

for (const [dpi, k] of DENSITIES) {
  const dir = path.join(RES, `mipmap-${dpi}`);
  fs.mkdirSync(dir, { recursive: true });

  const fg = Math.round(108 * k);   // adaptive foreground: full 108dp canvas
  png(at(mark, fg), fg, path.join(dir, 'ic_launcher_foreground.png'));
  png(at(mono, fg), fg, path.join(dir, 'ic_launcher_monochrome.png'));

  // legacy 48dp: crop to the central 80dp so the mark fills ~82% of the square, on solid ink
  const lg = Math.round(48 * k);
  const legacy = at(mark, lg, '14 14 80 80')
    .replace(/(<svg[^>]*>)/, `$1<rect x="14" y="14" width="80" height="80" fill="${INK}"/>`);
  png(legacy, lg, path.join(dir, 'ic_launcher.png'));

  console.log(`mipmap-${dpi}: foreground/monochrome ${fg}px, legacy ${lg}px`);
}

fs.rmSync(TMP, { recursive: true, force: true });
console.log('done');
