#!/usr/bin/env node
/**
 * Regenerate the Android launcher PNGs + splash art from RASTER masters
 * (the 2026-08 red/gold gopuram icon is AI-generated art — there is no SVG).
 * Masters live OUTSIDE the repo (docs/ui-direction.md §Launcher icon).
 *
 *   node assets/brand/icon_from_png.mjs <icon_1024.png> <splash_portrait.png>
 *
 * Rasterises with headless Chrome (no npm install).
 *
 * Outputs, under android/app/src/main/res/ :
 *   mipmap-*\/ic_launcher_foreground.png  108dp canvas; gold mark chroma-keyed
 *                                         off the red field, scaled into the
 *                                         66dp adaptive safe zone
 *   mipmap-*\/ic_launcher_monochrome.png  same geometry, white silhouette
 *   mipmap-*\/ic_launcher_background.png  radial red field sampled from master
 *   mipmap-*\/ic_launcher.png             48dp legacy, central 90% crop
 * and assets/images/splash_bg.jpg         portrait splash art, JPEG q92
 * Prints the sampled hexes to keep colors.xml / pubspec / ArulTokens in sync.
 */
import fs from 'fs';
import path from 'path';
import os from 'os';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RES = path.resolve(HERE, '../../android/app/src/main/res');
const IMAGES = path.resolve(HERE, '../images');

const [iconPath, splashPath] = process.argv.slice(2);
if (!iconPath || !splashPath) {
  console.error('usage: node icon_from_png.mjs <icon.png> <splash.png>');
  process.exit(1);
}

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

const b64 = (p) => fs.readFileSync(p).toString('base64');
const ICON = `data:image/png;base64,${b64(iconPath)}`;
const SPLASH = `data:image/png;base64,${b64(splashPath)}`;

// All pixel work happens in-page; results come back as data URLs via dump-dom.
const SCRIPT = `
const DENSITIES = [['mdpi',1],['hdpi',1.5],['xhdpi',2],['xxhdpi',3],['xxxhdpi',4]];
// Gold-vs-red key: gold has G far above B, every red/maroon tone has G <= B.
const goldScore = (r,g,b) => Math.max(0, Math.min(1, ((g - b) - 25) / 50));
const hex = (c) => '#' + c.map(v => Math.round(v).toString(16).padStart(2,'0')).join('').toUpperCase();

function load(src) {
  return new Promise((res, rej) => {
    const i = new Image();
    i.onload = () => res(i);
    i.onerror = rej;
    i.src = src;
  });
}
function draw(img) {
  const c = document.createElement('canvas');
  c.width = img.naturalWidth; c.height = img.naturalHeight;
  const x = c.getContext('2d', { willReadFrequently: true });
  x.drawImage(img, 0, 0);
  return [c, x.getImageData(0, 0, c.width, c.height)];
}
function avg(d, w, x0, y0, x1, y1) {
  let r=0,g=0,b=0,n=0;
  for (let y=y0; y<y1; y++) for (let x=x0; x<x1; x++) {
    const i=(y*w+x)*4; r+=d.data[i]; g+=d.data[i+1]; b+=d.data[i+2]; n++;
  }
  return [r/n, g/n, b/n];
}

(async () => {
  const files = {};
  const icon = await load('${ICON}');
  const [ic, idata] = draw(icon);
  const W = ic.width, H = ic.height;

  // Extract the gold mark (straight alpha = gold score) + white mono variant,
  // and measure its bounding box.
  const ext = document.createElement('canvas'); ext.width = W; ext.height = H;
  const mono = document.createElement('canvas'); mono.width = W; mono.height = H;
  const ed = new ImageData(W, H), md = new ImageData(W, H);
  let bx0=W, by0=H, bx1=0, by1=0;
  for (let i = 0; i < idata.data.length; i += 4) {
    const a = goldScore(idata.data[i], idata.data[i+1], idata.data[i+2]) * 255;
    ed.data[i]=idata.data[i]; ed.data[i+1]=idata.data[i+1]; ed.data[i+2]=idata.data[i+2]; ed.data[i+3]=a;
    md.data[i]=255; md.data[i+1]=255; md.data[i+2]=255; md.data[i+3]=a;
    if (a > 40) {
      const p = i/4, x = p % W, y = (p - x) / W;
      if (x<bx0) bx0=x; if (x>bx1) bx1=x; if (y<by0) by0=y; if (y>by1) by1=y;
    }
  }
  ext.getContext('2d').putImageData(ed, 0, 0);
  mono.getContext('2d').putImageData(md, 0, 0);
  const bw = bx1-bx0+1, bh = by1-by0+1;

  // Background field samples along the mark-free left mid-line + corner.
  const cy = Math.round(H/2);
  const sInner = avg(idata, W, Math.round(W*0.17), cy-3, Math.round(W*0.17)+6, cy+3);
  const sMid   = avg(idata, W, Math.round(W*0.06), cy-3, Math.round(W*0.06)+6, cy+3);
  const sEdge  = avg(idata, W, 2, 2, 8, 8);
  const sC0 = sInner.map((v,i) => Math.min(255, v + (v - sMid[i]) * 0.7));

  for (const [dpi, k] of DENSITIES) {
    // Adaptive foreground + monochrome: mark height = 58/108 of the canvas so
    // the whole glyph sits inside the 66dp safe-zone circle (tall mark: the
    // 34dp-wide base corners land at r≈33dp).
    const s = Math.round(108 * k);
    const dh = s * (58/108), dw = dh * (bw/bh);
    const dx = (s-dw)/2, dy = (s-dh)/2;
    for (const [name, src] of [['foreground', ext], ['monochrome', mono]]) {
      const c = document.createElement('canvas'); c.width = s; c.height = s;
      c.getContext('2d').drawImage(src, bx0, by0, bw, bh, dx, dy, dw, dh);
      files['mipmap-' + dpi + '/ic_launcher_' + name + '.png'] = c.toDataURL('image/png');
    }

    // Adaptive background: the master's radial red field, re-rendered clean.
    const bg = document.createElement('canvas'); bg.width = s; bg.height = s;
    const bgx = bg.getContext('2d');
    const grad = bgx.createRadialGradient(s/2, s/2, 0, s/2, s/2, s * 0.7071);
    grad.addColorStop(0, hex(sC0));
    grad.addColorStop(0.43, hex(sInner));
    grad.addColorStop(0.62, hex(sMid));
    grad.addColorStop(1, hex(sEdge));
    bgx.fillStyle = grad; bgx.fillRect(0, 0, s, s);
    files['mipmap-' + dpi + '/ic_launcher_background.png'] = bg.toDataURL('image/png');

    // Legacy 48dp: central 90% crop of the full master (mark ends ~82% tall).
    const lg = Math.round(48 * k), m = W * 0.05;
    const c = document.createElement('canvas'); c.width = lg; c.height = lg;
    c.getContext('2d').drawImage(ic, m, m, W - 2*m, W - 2*m, 0, 0, lg, lg);
    files['mipmap-' + dpi + '/ic_launcher.png'] = c.toDataURL('image/png');
  }

  // Splash art → JPEG q92 (opaque gradient art; PNG master is 10x the bytes).
  const splash = await load('${SPLASH}');
  const sc = document.createElement('canvas');
  sc.width = splash.naturalWidth; sc.height = splash.naturalHeight;
  sc.getContext('2d').drawImage(splash, 0, 0);
  files['SPLASH:splash_bg.jpg'] = sc.toDataURL('image/jpeg', 0.92);
  const [spc, spd] = draw(splash);
  const w = spc.width, h = spc.height;
  const samples = {
    iconInner: hex(sInner), iconMid: hex(sMid), iconEdge: hex(sEdge),
    splashCenter: hex(avg(spd, w, Math.round(w*0.3), Math.round(h*0.35), Math.round(w*0.7), Math.round(h*0.65))),
    splashTop: hex(avg(spd, w, 0, 0, w, Math.round(h*0.06))),
    splashBottom: hex(avg(spd, w, 0, Math.round(h*0.94), w, h)),
    markBbox: [bx0, by0, bw, bh], master: [W, H],
  };
  document.body.textContent =
    '@@BEGIN@@' + JSON.stringify({ files, samples }) + '@@END@@';
})();
`;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'arul-brand-'));
const html = path.join(TMP, 'gen.html');
fs.writeFileSync(html, `<body><script>${SCRIPT}<\/script></body>`);

const out = execFileSync(findChrome(), [
  '--headless=new', '--disable-gpu', '--hide-scrollbars',
  '--virtual-time-budget=20000', '--dump-dom',
  `file:///${html.replace(/\\/g, '/')}`,
], { maxBuffer: 512 * 1024 * 1024 }).toString();
fs.rmSync(TMP, { recursive: true, force: true });

const m = out.match(/@@BEGIN@@([\s\S]*?)@@END@@/);
if (!m) throw new Error('page did not finish — raise --virtual-time-budget');
const { files, samples } = JSON.parse(m[1]);

for (const [rel, dataUrl] of Object.entries(files)) {
  const bytes = Buffer.from(dataUrl.split(',')[1], 'base64');
  const dest = rel.startsWith('SPLASH:')
    ? path.join(IMAGES, rel.slice('SPLASH:'.length))
    : path.join(RES, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, bytes);
  console.log(`${rel}  ${(bytes.length / 1024).toFixed(0)} KB`);
}
console.log(JSON.stringify(samples, null, 2));
