/**
 * HSR unified CMS — shared server-rendered UI (Hono JSX + HTMX).
 *
 * Copied from the shipped per-app CMS UI (Apple "Liquid Glass" dark design
 * system). Deltas for the unified CMS:
 *   - the sidebar shows BOTH apps as groups (Pakiza · Arul) plus a combined
 *     dashboard; nav keys are namespaced "slug:section"
 *   - EVERY URL is /admin-prefixed (ADMIN_BASE): the Worker is routed at
 *     api.hsrutility.com/admin*, so login/logout actions live at /admin/login
 *     and /admin/logout and page links go through appPath()
 *   - the uploader posts the presign request to the form's data-presign URL
 *     (each app's /admin/{slug}/media/upload-url), so uploads always target
 *     the right app's bucket + key scheme
 *
 * IMPORTANT — presentation only otherwise: no form `action`, `method`, field
 * `name`, or `data-*` attribute the upload script and POST handlers depend on
 * differs from the reference beyond the deltas above.
 */

import type { FC, PropsWithChildren } from "hono/jsx";
import type { AppDef } from "./registry.js";
import { APPS } from "./registry.js";
import { ADMIN_BASE } from "./env.js";

// Self-hosted htmx (served by index.ts from src/vendor/htmx.ts) — no unpkg.
const HTMX_SRC = `${ADMIN_BASE}/assets/htmx.min.js`;

// Inline SVG favicon (data-URI): rounded-square #121013 tile, bold gold "H".
const FAVICON_SVG =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">' +
      '<rect width="32" height="32" rx="7" fill="#121013"/>' +
      '<text x="16" y="23" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif" ' +
      'font-size="21" font-weight="700" fill="#d9a441" text-anchor="middle">H</text>' +
      "</svg>",
  );

const CSS = `
/* ════════════════════════════════════════════════════════════════════════
   HSR CMS — "Warm Sanctum Dark" design system.
   Opaque warm-charcoal surfaces, hairline borders, gold accent used
   sparingly, system type. See design_handoff_hsr_cms/README.md — tokens and
   screens below implement it exactly.
   ════════════════════════════════════════════════════════════════════════ */
:root{
  color-scheme:dark;

  /* ── Gold accent (≤8% of any screen — README §Accent gold) ── */
  --accent:#d9a441;
  --accent-h:#e8b854;
  --accent-d:#c1912f;
  --accent-ink:#1a1408;
  --accent-text:#e8b854;
  --accent-soft:rgba(217,164,65,.14);

  /* ── Brand tie-in (same gold — one accent, no second hue) ── */
  --brand:#d9a441;

  /* ── Ink (warm whites, never pure) ── */
  --ink:#ece8e1;
  --body:rgba(240,235,228,.8);
  --muted:rgba(240,235,228,.6);
  --faint:rgba(240,235,228,.45);
  --label:rgba(240,235,228,.4);

  /* ── Opaque surfaces — no glass-on-glass ── */
  --page:#121013;
  --glass:#191619;              /* card / table / sidebar */
  --glass-2:#262126;            /* hover surfaces */
  --glass-elev:#201c20;         /* elevated / modal */
  --row-hover:#1e1a1e;
  --glass-thin:#191619;         /* topbar */
  --input:#100e10;              /* inset: inputs, JSON panels */
  --hairline:rgba(255,255,255,.08);
  --hairline-strong:rgba(255,255,255,.14);
  --edge:rgba(255,255,255,.14);
  --active-nav-bg:#1d191d;

  /* ── Semantics ── */
  --ok:#6faa78;      --ok-bg:rgba(111,170,120,.14);
  --warn:#d9a441;    --warn-bg:rgba(217,164,65,.14);
  --danger:#e06c5f;  --danger-bg:rgba(224,108,95,.12);
  --info:#e8b854;    --info-bg:rgba(217,164,65,.14);
  --draft-dot:rgba(240,235,228,.35);

  /* Scrim survives on exactly TWO layers: modal + mobile drawer. */
  --backdrop:rgba(10,8,8,.55);

  /* ── Shape + shadow ── */
  --radius:10px;
  --radius-sm:10px;
  --radius-modal:14px;
  --radius-pill:999px;
  --radius-btn:6px;
  --radius-check:4px;
  --blur:none;
  --blur-strong:none;
  --shadow-card:none;
  --shadow-pop:0 0 0 1px rgba(255,255,255,.06),0 8px 24px rgba(0,0,0,.45);

  --sidebar-w:232px;
}
*{box-sizing:border-box}
html,body{margin:0}
body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
  color:var(--ink);-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
  min-height:100vh;background:var(--page)}
a{color:var(--accent-text);text-decoration:none}
a:hover{color:var(--accent-h)}
:focus-visible{outline:2px solid rgba(217,164,65,.55);outline-offset:2px;border-radius:4px}
::selection{background:rgba(217,164,65,.3);color:#fff}
html{scrollbar-color:rgba(240,235,228,.14) transparent;scrollbar-width:thin}
::-webkit-scrollbar{width:10px;height:10px}
::-webkit-scrollbar-thumb{background:rgba(240,235,228,.14);border-radius:999px;border:3px solid var(--page);background-clip:padding-box}
::-webkit-scrollbar-thumb:hover{background:rgba(240,235,228,.28)}
::-webkit-scrollbar-track{background:transparent}
strong,b{font-weight:600}

/* ── App shell ── */
.app{display:grid;grid-template-columns:var(--sidebar-w) 1fr;min-height:100vh}
.side{position:sticky;top:0;height:100vh;overflow-y:auto;display:flex;flex-direction:column;
  background:var(--glass);border-right:1px solid var(--hairline);z-index:30}
.side .brand{position:relative;display:flex;flex-direction:column;align-items:flex-start;gap:0;padding:20px 20px 14px;flex:0 0 auto}
.side-close{display:none}
.side .brand > span{font-weight:700;font-size:16px;letter-spacing:-.01em;color:var(--ink)}
.side .brand .bar{width:22px;height:2px;background:var(--accent);border-radius:2px;margin:6px 0 5px}
.side .brand small{display:block;font-weight:700;font-size:10px;letter-spacing:.08em;
  text-transform:uppercase;color:var(--label)}
.navgroups{flex:1;display:flex;flex-direction:column;gap:18px;padding:6px 0 12px}
.navgroup{display:flex;flex-direction:column;gap:1px}
.navgroup .label{font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;
  color:var(--label);padding:12px 20px 4px}
.nav a{display:flex;align-items:center;gap:8px;justify-content:space-between;
  min-height:36px;margin:0;padding:8px 20px 8px 18px;border-left:2px solid transparent;
  color:var(--muted);font-weight:600;font-size:13.5px;transition:background .12s,color .12s,border-color .12s}
.nav a:hover{color:var(--ink)}
.nav a.on{background:var(--active-nav-bg);color:var(--ink);border-left-color:var(--accent)}
.nav a .ic{display:none}
.navdot{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--accent);flex:0 0 auto;margin-left:6px}
.navcount{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;color:var(--accent-text)}
.side .foot{border-top:1px solid var(--hairline);padding:14px 16px;margin-top:auto}
.side .foot form{margin:0}
.logout{width:100%;background:transparent;border:1px solid var(--hairline-strong);
  color:var(--body);padding:8px 0;border-radius:var(--radius-btn);cursor:pointer;font:inherit;font-weight:600;
  white-space:nowrap;transition:border-color .12s,color .12s}
.logout:hover{border-color:rgba(255,255,255,.22);color:var(--ink)}
.main{min-width:0;padding:30px 36px 96px;max-width:1400px;width:100%}

/* ── Mobile top bar + drawer scrim (hidden on desktop) ── */
.topbar{display:none}
.scrim{display:none}

/* ── Page header ── */
.head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:24px}
.head .htext h1{font-size:24px;line-height:1.2;margin:0;font-weight:700;letter-spacing:-.02em;
  color:var(--ink);word-break:break-word}
.head .sub{color:var(--muted);font-size:14px;margin-top:6px}
.head .sub.sub-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;
  color:rgba(240,235,228,.55);margin-top:4px}
.head .actions{display:flex;gap:10px;align-items:center;margin-left:auto;flex-wrap:wrap}

/* ── Cards + grid ── */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:14px}
.card{background:var(--glass);border:1px solid var(--hairline);border-radius:var(--radius);padding:16px;
  position:relative;transition:border-color .12s}
.card .card-title{font-weight:600;font-size:15px;color:var(--ink);letter-spacing:-.01em}
.card .card-desc{font-size:13px;color:var(--muted);margin-top:4px}
.stat{display:flex;flex-direction:column;gap:6px}
.stat .n{font-size:28px;font-weight:700;line-height:1;color:var(--ink);letter-spacing:-.01em;font-variant-numeric:tabular-nums}
.stat .l{color:var(--muted);font-size:13px;font-weight:500}
.stat .hint{font-size:12.5px;color:var(--faint);margin-top:2px}

/* ── Buttons ── */
.btn{display:inline-flex;align-items:center;gap:7px;border:1px solid transparent;cursor:pointer;font:inherit;font-weight:600;
  border-radius:var(--radius-btn);padding:9px 16px;line-height:1.1;letter-spacing:-.005em;white-space:nowrap;
  background:var(--accent);color:var(--accent-ink);
  transition:background .12s,border-color .12s,color .12s,opacity .12s}
.btn:hover{background:var(--accent-h)}
.btn:active{background:var(--accent-d)}
.btn.sec{background:transparent;color:var(--body);border:1px solid var(--hairline-strong)}
.btn.sec:hover{border-color:rgba(255,255,255,.35);color:var(--ink)}
.btn.gold-outline{background:transparent;color:var(--accent-text);border:1px solid rgba(217,164,65,.5)}
.btn.gold-outline:hover{border-color:var(--accent);background:rgba(217,164,65,.08)}
.btn.danger{background:transparent;color:var(--danger);border:1px solid var(--hairline-strong)}
.btn.danger:hover{border-color:var(--danger);background:rgba(224,108,95,.08)}
.btn.sm{padding:6px 12px;font-size:12.5px}
.btn[disabled],.btn.busy{background:var(--glass-2);color:var(--faint);border-color:var(--hairline);
  cursor:default;opacity:1}
.btn.sec[disabled]{color:var(--faint);border-color:var(--hairline)}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}

/* ── Badges (status = dot + word) ── */
.badge{display:inline-flex;align-items:center;gap:6px;font-size:13px;font-weight:500;line-height:1.4;
  color:var(--body);white-space:nowrap}
.badge::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--draft-dot);flex:0 0 auto}
.badge{color:var(--body)}
.badge.ok::before{background:var(--ok)}
.badge.warn{color:var(--warn)}
.badge.warn::before{background:var(--warn)}
.badge.muted::before{background:var(--draft-dot)}
.badge.danger{color:var(--danger)}
.badge.danger::before{background:var(--danger)}
.badge.info{color:var(--info)}
/* pill chips (version chip, LIVE/draft) — the ONLY pill-radius usage besides bulk pill */
.chip{display:inline-flex;align-items:center;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  font-size:12px;color:var(--muted);border:1px solid var(--hairline-strong);border-radius:var(--radius-pill);
  padding:2px 10px;white-space:nowrap}

/* ── Tables ── */
.tablewrap{overflow-x:auto;border:1px solid var(--hairline);border-radius:var(--radius);background:var(--glass)}
table{width:100%;border-collapse:collapse;font-size:13.5px}
thead{position:sticky;top:0;z-index:1;background:var(--glass)}
thead th{background:var(--glass);color:var(--faint);font-size:11px;font-weight:700;
  text-transform:uppercase;letter-spacing:.06em;text-align:left;padding:9px 14px;
  border-bottom:1px solid var(--hairline);white-space:nowrap;height:40px;box-sizing:border-box}
tbody td{padding:9px 14px;border-bottom:1px solid rgba(255,255,255,.05);vertical-align:middle;color:var(--ink);
  height:40px;box-sizing:border-box}
tbody tr:last-child td{border-bottom:0}
tbody tr{transition:background .12s}
tbody tr:hover{background:var(--row-hover)}
td.coltitle strong,td strong{color:var(--ink);font-weight:600}
td.coltitle strong{display:inline-block;max-width:320px;overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap;vertical-align:middle}
/* Category cell: plain muted text, ellipsized so a long free-text category
   never breaks the 40px row rhythm. */
td.colcat{color:var(--muted);max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
td .thumb{width:44px;height:44px;border-radius:var(--radius-btn);object-fit:cover;background:var(--input);
  border:1px solid var(--hairline);display:block}
td .filemark{width:44px;height:44px;border-radius:var(--radius-btn);display:grid;place-items:center;
  background:var(--glass-2);border:1px solid var(--hairline);color:var(--faint);font-size:15px}
/* Lazy-thumb shimmer — the loading gradient shows through until the <img>
   paints its content on top. */
td .thumb,.pick img,.rtcard .rtcover img{background:linear-gradient(100deg,#1a171a 40%,#221d22 50%,#1a171a 60%);
  background-size:200% 100%;animation:imgload 1.4s linear infinite}
@keyframes imgload{from{background-position:200% 0}to{background-position:-200% 0}}
@media(prefers-reduced-motion:reduce){td .thumb,.pick img,.rtcard .rtcover img{animation:none}}
.rowact{display:flex;gap:6px;align-items:center;opacity:.5;transition:opacity .12s}
tbody tr:hover .rowact,tbody tr:focus-within .rowact{opacity:1}
.rowact form{margin:0}
/* Touch devices have no hover — keep the row actions always visible. */
@media(pointer:coarse){.rowact{opacity:1}}
/* Desktop only: bound the table height so the sticky thead has something to
   stick within (mobile hides the table entirely — see the max-width:900px block). */
@media(min-width:901px){.tablewrap{max-height:max(340px,calc(100vh - 240px));overflow:auto}}

/* ── List toolbar / search / sort / pagination (client-side) ── */
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:16px}
.toolbar .searchwrap{position:relative;flex:1;min-width:220px;max-width:380px}
.toolbar .searchwrap::before{content:"";position:absolute;left:11px;top:50%;transform:translateY(-50%);
  width:14px;height:14px;pointer-events:none;
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='14' height='14' viewBox='0 0 14 14'%3E%3Ccircle cx='6' cy='6' r='4.75' fill='none' stroke='%23a89f93' stroke-width='1.4'/%3E%3Cpath d='M9.6 9.6 13 13' fill='none' stroke='%23a89f93' stroke-width='1.4' stroke-linecap='round'/%3E%3C/svg%3E");
  background-repeat:no-repeat;background-position:center}
.toolbar .search{width:100%;padding-left:30px;padding-right:28px}
.toolbar .search-clear{display:none;position:absolute;right:8px;top:50%;transform:translateY(-50%);
  border:0;background:transparent;color:var(--faint);cursor:pointer;font-size:15px;line-height:1;padding:4px;
  border-radius:50%}
.toolbar .search-clear:hover{color:var(--ink)}
.toolbar .searchwrap.has-value .search-clear{display:block}
.grow{flex:1}
.toolbar select{width:auto;min-width:120px}
th.sortable{cursor:pointer;user-select:none}
th.sortable:hover{color:var(--body)}
th.sortable .arrow{opacity:.35;margin-left:6px;font-size:10px}
th.sortable[data-dir="asc"] .arrow{opacity:1}
th.sortable[data-dir="asc"] .arrow::after{content:"\\2191"}
th.sortable[data-dir="desc"] .arrow{opacity:1}
th.sortable[data-dir="desc"] .arrow::after{content:"\\2193"}
th.sortable .arrow::after{content:"\\2195"}
tr.filtered-out,tr.paged-out{display:none}
.pager{display:flex;gap:10px;align-items:center;justify-content:flex-end;margin-top:16px;color:var(--muted);font-size:13px}
.pager .btn.sm{min-width:36px;justify-content:center}
.pager .pginfo{margin-right:auto;color:var(--muted);font-variant-numeric:tabular-nums}

/* ── Forms ── */
.form{max-width:620px}
.field{display:block;margin:0 0 18px}
.field .lab{display:block;font-weight:600;font-size:13px;margin:0 0 7px;color:var(--ink)}
.json-lab{display:block;font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;
  color:var(--label);margin:0 0 7px}
.json-lab-hint{text-transform:none;letter-spacing:0;font-weight:400;color:var(--faint)}
.field .hint{display:block;font-size:12.5px;color:var(--muted);margin-top:6px}
.field .hint.keyline{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;
  color:rgba(240,235,228,.55);word-break:break-all}
label{font-weight:600;font-size:13px;color:var(--ink)}
input[type=text],input[type=number],input[type=password],input[type=email],select,textarea{
  width:100%;padding:10px 13px;background:var(--input);color:var(--ink);
  border:1px solid var(--hairline-strong);border-radius:var(--radius-sm);font:inherit;
  transition:border-color .15s}
textarea{resize:vertical}
textarea.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;line-height:1.55;
  background:var(--input)}
/* Native <select> popups paint from the control's background-color, so give it
   an opaque dark fill + a custom chevron, and theme the option list to match. */
select{appearance:none;-webkit-appearance:none;cursor:pointer;padding-right:28px;
  background-color:#201c20;
  background-repeat:no-repeat;background-position:right 10px center;
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%23a89f93' stroke-width='1.5'/%3E%3C/svg%3E")}
option,optgroup{background-color:#201c20;color:var(--ink)}
input::placeholder,textarea::placeholder{color:var(--faint)}
input:focus,select:focus,textarea:focus{outline:none;border-color:rgba(217,164,65,.55)}
input:focus-visible,select:focus-visible,textarea:focus-visible{outline:2px solid rgba(217,164,65,.55);outline-offset:2px}

/* Dropzone-styled file input: the real <input type=file data-slot> stays,
   wrapped by .dropzone for the dashed-hairline look; drag&drop handled by
   DROPZONE_JS without changing the input's name/attributes. */
.dropzone{position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;
  gap:6px;text-align:center;padding:22px 16px;border:1px dashed rgba(255,255,255,.18);border-radius:var(--radius-sm);
  background:var(--input);cursor:pointer;transition:border-color .12s,background .12s}
.dropzone:hover,.dropzone.drag{border-color:rgba(217,164,65,.45)}
.dropzone .dz-ic{font-size:20px;color:var(--faint)}
.dropzone .dz-text{font-size:13px;color:var(--muted)}
.dropzone input[type=file]{position:absolute;inset:0;width:100%;height:100%;opacity:0;cursor:pointer;
  padding:0;border:0;background:transparent}
.dropzone.has-file .dz-text{color:var(--ink)}
input[type=file]::file-selector-button{display:none}
.check{display:flex;align-items:flex-start;gap:10px;margin:16px 0}
.check input{width:auto;margin-top:3px;accent-color:var(--accent)}
.check label,.check span{margin:0;font-weight:500;color:var(--ink)}
.formgrid{display:grid;grid-template-columns:1fr 1fr;gap:0 18px}
@media(max-width:560px){.formgrid{grid-template-columns:1fr}}

/* ── Notes (inline) / toasts (flash rendered as a toast — see TOAST_JS) ── */
.note{padding:11px 14px;border-radius:var(--radius-sm);font-size:13.5px;margin:0 0 18px;display:flex;gap:9px;
  align-items:flex-start;border:1px solid transparent;background:var(--glass)}
.note::before{font-weight:800;line-height:1.4}
.note.ok{color:var(--ok);border-color:rgba(111,170,120,.3)}
.note.ok::before{content:"\\2713"}
.note.warn{color:var(--warn);border-color:rgba(217,164,65,.3)}
.note.warn::before{content:"!"}
.note.danger{color:var(--danger);border-color:rgba(224,108,95,.3)}
.note.danger::before{content:"!"}
.note.info{color:var(--info);border-color:rgba(217,164,65,.3)}
.note.muted{color:var(--muted);border-color:var(--hairline)}
.note[data-flash]{display:none} /* hidden inline; TOAST_JS moves its content into a toast */

.toast-stack{position:fixed;right:18px;bottom:18px;z-index:80;display:flex;flex-direction:column;gap:10px;
  max-width:360px;pointer-events:none}
.toast{pointer-events:auto;display:flex;align-items:flex-start;gap:10px;background:var(--glass-elev);
  border:1px solid var(--hairline-strong);border-left:2px solid var(--accent);border-radius:var(--radius-sm);
  padding:11px 12px 11px 14px;font-size:13.5px;color:var(--ink);box-shadow:var(--shadow-pop);
  animation:toastin .2s cubic-bezier(0.16,1,0.3,1)}
.toast.danger{border-left-color:var(--danger);color:var(--danger)}
.toast .toast-msg{flex:1}
.toast .toast-x{background:transparent;border:0;color:var(--faint);cursor:pointer;font-size:16px;line-height:1;padding:2px}
.toast .toast-x:hover{color:var(--ink)}
@keyframes toastin{from{transform:translateY(10px);opacity:0}to{transform:translateY(0);opacity:1}}

/* ── Empty state ── */
.empty{padding:56px 24px;text-align:center;color:var(--muted);
  background:var(--glass);border:1px solid var(--hairline);border-radius:var(--radius)}
.empty .emoji{font-size:32px;display:block;margin-bottom:12px;opacity:.7}
.empty .cta{margin-top:18px;display:flex;justify-content:center}

/* ── Tabs (submissions status — segmented control language) ── */
.tabs{display:flex;gap:2px;margin-bottom:20px;flex-wrap:wrap;padding:4px;border-radius:var(--radius-btn);
  background:var(--glass);border:1px solid var(--hairline);width:fit-content;max-width:100%}
.tabs a{padding:7px 15px;color:var(--muted);font-weight:600;font-size:13.5px;
  border-radius:calc(var(--radius-btn) - 2px);transition:background .15s,color .15s}
.tabs a:hover{color:var(--ink)}
.tabs a.on{color:var(--ink);background:var(--glass-2)}

/* ── Modal (native dialog) ── */
dialog.modal{border:0;padding:0;max-width:min(92vw,520px);width:100%;color:var(--ink);
  background:var(--glass-elev);border:1px solid var(--hairline-strong);border-radius:var(--radius-modal);
  box-shadow:var(--shadow-pop)}
dialog.modal.wide{max-width:min(94vw,620px)}
dialog.modal::backdrop{background:var(--backdrop);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px)}
html:has(dialog[open]){overflow:hidden}
.dlg-head{display:flex;align-items:center;justify-content:space-between;gap:12px;
  padding:20px 20px 0}
.dlg-head h2{margin:0;font-size:18px;font-weight:700;letter-spacing:-.01em;color:var(--ink)}
.dlg-x{background:transparent;border:0;color:var(--muted);font-size:22px;cursor:pointer;line-height:1;
  border-radius:50%;width:32px;height:32px;display:grid;place-items:center;transition:background .12s,color .12s}
.dlg-x:hover{background:var(--glass-2);color:var(--ink)}
.dlg-body{padding:18px 20px 20px;max-height:72vh;overflow-y:auto}
.dlg-body .form{max-width:none}
.dlg-foot{display:flex;justify-content:flex-end;gap:10px;padding:0 20px 20px}
.modal-loading{padding:0}
@media(prefers-reduced-motion:no-preference){
  dialog.modal[open]{animation:dlgin .22s cubic-bezier(0.16,1,0.3,1)}
  @keyframes dlgin{from{opacity:0;transform:translateY(14px) scale(.985)}to{opacity:1;transform:none}}
}

/* ── Skeleton (modal-loading + list shimmer) ── */
.skel-line{height:12px;border-radius:4px;background:rgba(240,235,228,.1);
  animation:shimmer 1.6s ease-in-out infinite}
.skel-row{display:flex;align-items:center;gap:10px;padding:9px 2px}
.skel-row .skel-thumb{width:36px;height:36px;border-radius:6px;background:rgba(240,235,228,.1);
  animation:shimmer 1.6s ease-in-out infinite;flex:0 0 auto}
.skel-row .skel-line{flex:1}
@keyframes shimmer{0%{opacity:.55}50%{opacity:.75}100%{opacity:.55}}

/* ── Media preview (submissions review) — fills the 180×320 (9/16) box ── */
.preview-media img,.preview-media video{width:100%;height:100%;object-fit:cover;display:block}
.preview-media audio{width:100%;max-width:440px;margin:auto;display:block}

/* ── Hover-zoom preview box (PREVIEW_JS) — floating thumbnail/clip near the
      hovered element on fine pointers only. ── */
#hoverzoom{position:fixed;z-index:70;width:230px;border-radius:10px;overflow:hidden;
  border:1px solid var(--hairline-strong);box-shadow:var(--shadow-pop);background:var(--glass-elev);
  pointer-events:none;display:none}
#hoverzoom img,#hoverzoom video{display:block;width:100%;height:auto;max-height:70vh;object-fit:cover}

/* ── Media lightbox (PREVIEW_JS) — bigger centered preview of an img/video/audio. ── */
dialog.lightbox{max-width:min(94vw,560px)}
.lb-body{display:grid;place-items:center;padding:0 20px}
.lb-body img,.lb-body video{max-width:100%;max-height:68vh;border-radius:10px;display:block}
.lb-body audio{width:100%;margin:20px 0}

/* ── Upload progress bar (UPLOAD_JS) — overall bytes across all files. ── */
.progress{height:4px;border-radius:2px;background:var(--glass-2);overflow:hidden;margin:10px 0 0;display:none}
.progress.on{display:block}
.progress i{display:block;height:100%;width:0;background:var(--accent);transition:width .15s}

/* ── Pre-upload file list (UPLOAD_JS) — one row per selected file + probe status. ── */
.filelist{display:flex;flex-direction:column;gap:6px;margin-top:10px;max-height:220px;overflow-y:auto}
.filelist .fl-row{display:flex;gap:10px;align-items:center;font-size:12.5px;background:var(--input);
  border:1px solid var(--hairline);border-radius:var(--radius-btn);padding:6px 10px}
.fl-name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;color:var(--body)}
.fl-size{color:var(--faint);white-space:nowrap}
.fl-stat{white-space:nowrap}
.fl-stat.ok{color:var(--ok)}
.fl-stat.warn{color:var(--warn)}
.fl-x{background:transparent;border:0;color:var(--faint);cursor:pointer;font-size:14px;line-height:1;
  padding:2px;border-radius:50%}
.fl-x:hover{color:var(--ink)}

.microlabel-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;
  letter-spacing:.06em;color:var(--muted);margin-bottom:10px}

/* ── Transfer picker grid (Arul category transfer) + wallpapers grid view ── */
.pickgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:12px;margin:16px 0}
/* Wallpapers grid view (data-grid) uses larger cards than the transfer picker. */
.pickgrid[data-grid]{grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}
.pick{position:relative;display:block;cursor:pointer;border-radius:var(--radius-sm);overflow:hidden;
  border:1px solid var(--hairline);background:var(--glass);transition:border-color .12s,box-shadow .12s;
  aspect-ratio:9/16}
.pick:hover,.gcard:hover{border-color:var(--hairline-strong)}
.pick img{display:block;width:100%;height:100%;aspect-ratio:9/16;object-fit:cover;background:var(--input)}
/* Card hover-video overlay (PREVIEW_JS injects video.hoverplay into the .pick). */
.pick video.hoverplay{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;background:#000}
.pick .pick-live{position:absolute;top:8px;left:8px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  text-transform:uppercase;background:rgba(16,14,16,.75);color:var(--ink);border:1px solid var(--hairline-strong);
  border-radius:var(--radius-pill);font-size:10px;font-weight:700;padding:2px 8px;letter-spacing:.04em}
.pick .pick-title{position:absolute;left:0;right:0;bottom:0;padding:22px 8px 6px;font-size:12px;
  color:#fff;background:linear-gradient(transparent,rgba(10,8,8,.85));white-space:nowrap;
  overflow:hidden;text-overflow:ellipsis;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.pick-title small{display:block;font-size:10px;letter-spacing:.05em;text-transform:uppercase;color:rgba(255,255,255,.62)}
.pick input[type=checkbox]{appearance:none;-webkit-appearance:none;position:absolute;cursor:pointer}
/* Visible grid/card checkbox — 22px, always legible over any cover image. The
   pick-hide-cb transfer picker keeps its own full-card invisible box (below). */
.pick:not(.pick-hide-cb) input[type=checkbox]{top:8px;right:8px;width:22px;height:22px;opacity:1;
  border-radius:var(--radius-check);border:1.5px solid rgba(255,255,255,.7);background:rgba(16,14,16,.72);
  box-shadow:0 1px 5px rgba(0,0,0,.5);transition:background .12s,border-color .12s}
/* Expand the hit area without moving the visual box (appearance:none paints
   the pseudo-elements). */
.pick:not(.pick-hide-cb) input[type=checkbox]::before{content:"";position:absolute;inset:-8px}
.pick:not(.pick-hide-cb) input[type=checkbox]:checked{background:var(--accent);border-color:var(--accent)}
.pick:not(.pick-hide-cb) input[type=checkbox]:checked::after{content:"";position:absolute;left:7px;top:3px;
  width:5px;height:10px;border:solid var(--accent-ink);border-width:0 2px 2px 0;transform:rotate(45deg)}
.pick:not(.pick-hide-cb) input[type=checkbox]:indeterminate{border-color:var(--accent)}
.pick:not(.pick-hide-cb) input[type=checkbox]:indeterminate::after{content:"";position:absolute;left:6px;top:9px;
  width:8px;height:2px;background:var(--accent)}
/* Transfer picker: whole card is the click target (label) — no visible
   checkbox square, just the gold ring + .pick-check badge when selected. */
.pick.pick-hide-cb input[type=checkbox]{opacity:0;width:100%;height:100%;top:0;right:0;border-radius:var(--radius-sm)}
/* Selected ring drawn as an overlay (an inset box-shadow would be hidden
   behind the cover image). */
.pick:has(input:checked)::after{content:"";position:absolute;inset:0;border:2px solid var(--accent);
  border-radius:inherit;pointer-events:none}
.pick .pick-check{position:absolute;top:8px;right:8px;width:16px;height:16px;border-radius:var(--radius-check);
  background:var(--accent);color:var(--accent-ink);display:none;place-items:center;font-size:11px;font-weight:700}
.pick:has(input:checked) .pick-check{display:grid}
.pick .gfmark{position:absolute;inset:0;display:grid;place-items:center;cursor:pointer;
  font-size:28px;color:rgba(240,235,228,.35);background:var(--glass-elev)}
.pick-fallback{position:absolute;inset:0;display:grid;place-items:center;background:var(--glass-elev);color:rgba(240,235,228,.35);font-size:28px}

/* ── List page: bulk selection, id column, view toggle, grid cards ── */
input.rowsel[type=checkbox]{appearance:none;-webkit-appearance:none;width:18px;height:18px;
  border:1px solid rgba(255,255,255,.25);border-radius:var(--radius-check);cursor:pointer;position:relative;
  background:transparent;vertical-align:middle;transition:background .12s,border-color .12s;flex:0 0 auto}
input.rowsel[type=checkbox]:checked{background:var(--accent);border-color:var(--accent)}
input.rowsel[type=checkbox]:checked::after{content:"";position:absolute;left:5px;top:2px;width:4px;height:9px;
  border:solid var(--accent-ink);border-width:0 2px 2px 0;transform:rotate(45deg)}
input.rowsel[type=checkbox]:indeterminate{border-color:var(--accent)}
input.rowsel[type=checkbox]:indeterminate::after{content:"";position:absolute;left:5px;top:8px;
  width:8px;height:2px;background:var(--accent)}
td .idcode{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;color:rgba(240,235,228,.65)}
td .idcode[data-copy]{cursor:pointer}
td .idcode[data-copy]:hover{color:var(--accent-text)}
.keysearch{display:none}
.coldate{color:var(--muted);font-size:13px;white-space:nowrap;font-variant-numeric:tabular-nums}

/* Floating bulk-actions pill — bottom-center of the content column, NOT a banner. */
/* Centered on the CONTENT column (sidebar offset + 1400px main cap), not the viewport. */
.bulkbar{display:none;position:fixed;
  left:calc(var(--sidebar-w) + min(100vw - var(--sidebar-w), 1400px)/2);bottom:22px;
  transform:translate(-50%,0);z-index:40;
  align-items:center;gap:10px;flex-wrap:wrap;padding:10px 14px;max-width:calc(100% - 32px);
  border-radius:var(--radius-pill);background:var(--glass-elev);border:1px solid var(--hairline-strong);
  box-shadow:var(--shadow-pop);animation:bulkup .2s cubic-bezier(0.16,1,0.3,1)}
@keyframes bulkup{from{transform:translate(-50%,64px);opacity:0}to{transform:translate(-50%,0);opacity:1}}
.bulkbar[data-bulk-bar-visible]{display:flex}
.bulkbar [data-bulk-count]{font-weight:600;color:var(--ink);font-variant-numeric:tabular-nums;white-space:nowrap;
  padding-left:4px}
.bulkbar .bulk-div{width:1px;height:18px;background:var(--hairline-strong)}
.bulkbar .bulk-x{background:transparent;border:0;color:var(--faint);cursor:pointer;font-size:16px;line-height:1;
  padding:4px;border-radius:50%}
.bulkbar .bulk-x:hover{color:var(--ink)}

.viewtoggle{display:flex;gap:2px;padding:3px;border-radius:var(--radius-btn);
  background:var(--glass);border:1px solid var(--hairline)}
.viewtoggle button{border:0;cursor:pointer;font:inherit;font-weight:600;font-size:12.5px;
  padding:6px 12px;border-radius:calc(var(--radius-btn) - 2px);background:transparent;color:var(--muted);
  transition:background .12s,color .12s;white-space:nowrap}
.viewtoggle button:hover{color:var(--ink)}
.viewtoggle button.on{background:var(--glass-2);color:var(--ink)}

.gcard{aspect-ratio:9/16}
.gcard.draft{border-color:rgba(217,164,65,.45)}
.gcard.draft img{opacity:.75}
.gcard .gdraft{color:var(--warn);border-color:rgba(217,164,65,.45)}
.gcard .gimg{cursor:pointer}
.gcard .gfmark{position:absolute;inset:0;display:grid;place-items:center;cursor:pointer;
  font-size:28px;color:rgba(240,235,228,.35);background:var(--glass-elev)}
.gcard .gdraft{position:absolute;top:8px;left:8px;background:rgba(16,14,16,.75);color:var(--muted);
  border:1px solid var(--hairline-strong);text-transform:uppercase;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  border-radius:var(--radius-pill);font-size:10px;font-weight:700;padding:2px 8px;letter-spacing:.04em}
.gcard .pick-live ~ .gdraft{top:32px}

/* ── Login ── */
.login{min-height:100vh;display:grid;place-items:center;padding:20px}
.login .box{width:380px;max-width:100%;border-radius:var(--radius-modal);padding:32px 28px 28px;color:var(--ink);
  background:var(--glass);box-shadow:none;border:1px solid var(--hairline)}
.login h1{margin:0 0 10px;font-size:20px;font-weight:700;letter-spacing:-.02em}
.login p{margin:0 0 0;color:var(--muted);font-size:14px;display:none}
.login .field{margin-bottom:15px}
.login .btn{width:100%;justify-content:center;margin-top:6px;padding:11px}
.bar{width:28px;height:3px;border-radius:2px;margin:0 0 6px;background:var(--accent)}
.login .microlabel{font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;
  color:var(--label);margin-bottom:22px}
.pw-toggle{position:absolute;right:8px;top:50%;transform:translateY(-50%);background:transparent;border:0;
  color:var(--faint);cursor:pointer;font:inherit;font-size:12px;font-weight:600;padding:4px 6px}
.pw-toggle:hover{color:var(--ink)}

/* ── Responsive: off-canvas drawer + mobile top bar ── */
@media(max-width:900px){
  .app{grid-template-columns:1fr}
  .topbar{display:flex;align-items:center;gap:12px;position:sticky;top:0;z-index:25;
    height:58px;padding:0 14px;border-bottom:1px solid var(--hairline);background:var(--glass-thin)}
  .topbar .tb-brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:15px;letter-spacing:-.01em}
  .hamburger{width:36px;height:36px;flex:0 0 auto;display:grid;place-items:center;cursor:pointer;
    border-radius:var(--radius-btn);border:1px solid var(--hairline-strong);background:transparent;
    color:var(--ink);font-size:18px}
  .hamburger:active{transform:scale(.96)}
  .side{position:fixed;top:0;left:0;height:100dvh;width:272px;max-width:82vw;
    transform:translateX(-100%);transition:transform .22s cubic-bezier(0.16,1,0.3,1);
    box-shadow:var(--shadow-pop);border-right:1px solid var(--edge)}
  .side-close{display:grid;place-items:center;position:absolute;top:18px;right:16px;
    width:28px;height:28px;background:transparent;border:0;color:var(--muted);font-size:18px;cursor:pointer;padding:0}
  .side-close:hover{color:var(--ink)}
  body.nav-open .side{transform:none}
  .scrim{display:block;position:fixed;inset:0;z-index:20;background:var(--backdrop);
    -webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);opacity:0;visibility:hidden;
    transition:opacity .22s,visibility .22s}
  body.nav-open .scrim{opacity:1;visibility:visible}
  body.nav-open{overflow:hidden}
  .main{padding:22px 18px 96px}
  .head .htext h1{font-size:21px}
  /* Table view + view toggle disappear — grid only, exactly 2 columns. */
  .viewtoggle{display:none}
  .tablewrap{display:none !important}
  [data-grid]{display:grid !important;grid-template-columns:repeat(2,1fr) !important}
  .bulkbar{left:16px;right:16px;transform:translate(0,0);width:auto;max-width:none;justify-content:center}
  .bulkbar[data-bulk-bar-visible]{display:flex}
  @keyframes bulkup{from{transform:translateY(64px);opacity:0}to{transform:translateY(0);opacity:1}}
}
@media(max-width:480px){
  .main{padding:18px 14px 88px}
  .head{margin-bottom:20px}
  .head .actions{width:100%}
  .head .actions .btn{flex:1;justify-content:center}
  .stat .n{font-size:24px}
}
`;

/**
 * Sidebar navigation: one Overview group + one group per app, built from the
 * registry so a section only appears where the app actually has it. Nav keys
 * are namespaced ("dashboard" | "<slug>:<section>").
 */
interface NavItem {
  key: string;
  href: string;
  label: string;
  ic: string;
  /** App slug for the pending-submissions nav dot (submissions items only). */
  sub?: string;
}
function navGroups(): { label: string; items: NavItem[] }[] {
  const groups: { label: string; items: NavItem[] }[] = [
    {
      label: "Overview",
      items: [{ key: "dashboard", href: ADMIN_BASE, label: "Dashboard", ic: "▣" }],
    },
  ];
  for (const app of APPS) {
    const items: NavItem[] = [
      { key: `${app.slug}:wallpapers`, href: appPath(app, "/wallpapers"), label: "Wallpapers", ic: "▦" },
    ];
    if (app.hasRingtones) {
      items.push({ key: `${app.slug}:ringtones`, href: appPath(app, "/ringtones"), label: "Ringtones", ic: "♪" });
    }
    items.push({ key: `${app.slug}:submissions`, href: appPath(app, "/submissions"), label: "Submissions", ic: "⇪", sub: app.slug });
    if (app.hasCategories) {
      items.push({ key: `${app.slug}:transfer`, href: appPath(app, "/transfer"), label: "Category transfer", ic: "⇄" });
    }
    items.push({ key: `${app.slug}:config`, href: appPath(app, "/config"), label: "App config", ic: "⚙" });
    groups.push({ label: app.label, items });
  }
  return groups;
}

/**
 * The shared destructive-confirmation dialog + the modal/list controller
 * scripts — copied byte-for-byte from the reference CMS (see its ui.tsx for the
 * full rationale). Rendered once per page inside Layout.
 */
const MODAL_JS = `
(function(){
  function open(d){ if(d&&d.showModal&&!d.open){ try{d.showModal();}catch(e){} } }
  function loading(t){ if(t) t.innerHTML='<div class="modal-loading">Loading\\u2026</div>'; }

  // ── cmsConfirm: promise-based confirm on #confirm-dlg (single resolver, never
  //    two pending at once). Resolves true on Confirm, false otherwise. ──
  var confirmResolver=null;
  function cmsConfirm(message){
    return new Promise(function(resolve){
      var dlg=document.getElementById('confirm-dlg');
      if(!dlg){ resolve(window.confirm(message||'Are you sure?')); return; }
      if(confirmResolver){ var prev=confirmResolver; confirmResolver=null; prev(false); }
      confirmResolver=resolve;
      var msg=document.getElementById('confirm-msg'); if(msg)msg.textContent=message||'Are you sure?';
      dlg.returnValue='';
      open(dlg);
    });
  }
  window.cmsConfirm=cmsConfirm;
  var cdlg=document.getElementById('confirm-dlg');
  if(cdlg){
    var go=document.getElementById('confirm-go');
    if(go)go.addEventListener('click',function(){ try{cdlg.close('confirm');}catch(e){} });
    cdlg.addEventListener('close',function(){
      var r=confirmResolver; confirmResolver=null; if(r)r(cdlg.returnValue==='confirm');
    });
  }

  // ── Dirty / busy close guard ──
  function isGuarded(dlg){
    if(!dlg||dlg.id==='confirm-dlg'||dlg.id==='media-lightbox')return false;
    if(dlg.getAttribute('data-dirty')!=null)return true;
    if(dlg.querySelector&&dlg.querySelector('form[data-busy-upload]'))return true;
    return false;
  }
  function doClose(dlg){ try{dlg.close('cancel');}catch(e){} }
  function guardedClose(dlg){
    if(!dlg||!dlg.open)return;
    if(!isGuarded(dlg)){ doClose(dlg); return; }
    var busy=dlg.querySelectorAll('form[data-busy-upload]');
    cmsConfirm(busy.length?'Cancel the upload in progress?':'Discard your changes?').then(function(ok){
      if(!ok)return;
      if(busy.length&&window.cmsAbortUpload){ Array.prototype.forEach.call(busy,function(f){ window.cmsAbortUpload(f); }); }
      dlg.removeAttribute('data-dirty');
      doClose(dlg);
    });
  }
  // Stamp data-dirty on the open dialog whenever its fields change.
  document.addEventListener('input',function(e){
    var dlg=e.target.closest&&e.target.closest('dialog[open]');
    if(dlg&&dlg.id!=='confirm-dlg'&&dlg.id!=='media-lightbox')dlg.setAttribute('data-dirty','1');
  });
  // A submit means the operator kept the changes — drop the dirty flag.
  document.addEventListener('submit',function(e){
    var f=e.target; if(f&&f.closest){ var d=f.closest('dialog'); if(d)d.removeAttribute('data-dirty'); }
  });
  // Esc (native dialog 'cancel', non-bubbling → capture) routes through the guard.
  document.addEventListener('cancel',function(e){
    var dlg=e.target;
    if(dlg&&dlg.tagName==='DIALOG'&&isGuarded(dlg)){ e.preventDefault(); guardedClose(dlg); }
  },true);

  // ── Open / close via delegation ──
  document.addEventListener('click',function(e){
    var t=e.target.closest&&e.target.closest('[data-dialog-target]');
    if(t){
      var d=document.getElementById(t.getAttribute('data-dialog-target'));
      if(d){
        if(t.tagName==='A')e.preventDefault();
        var sel=t.getAttribute('hx-target'); if(sel) loading(document.querySelector(sel));
        open(d);
      }
    }
    var x=e.target.closest&&e.target.closest('[data-dialog-close]');
    if(x){ var dd=x.closest('dialog'); if(dd) guardedClose(dd); return; }
  });
  // Backdrop close: only when BOTH mousedown and click land on the <dialog>
  // element itself — a text-selection drag out of a form must not close it.
  var mdTarget=null;
  document.addEventListener('mousedown',function(e){ mdTarget=e.target; });
  document.addEventListener('click',function(e){
    if(e.target.tagName==='DIALOG'&&e.target.open&&mdTarget===e.target) guardedClose(e.target);
  });

  // ── data-confirm forms → cmsConfirm ──
  document.addEventListener('submit',function(e){
    var f=e.target;
    if(f.getAttribute&&f.getAttribute('data-confirm')!=null&&f.getAttribute('data-confirmed')!=='1'){
      e.preventDefault(); e.stopImmediatePropagation();
      cmsConfirm(f.getAttribute('data-confirm')||'Are you sure?').then(function(ok){
        if(!ok)return;
        f.setAttribute('data-confirmed','1');
        if(f.requestSubmit)f.requestSubmit(); else f.submit();
      });
    }
  },true);
})();
`;

const LIST_JS = `
(function(){
  function rows(v){ var tb=v.querySelector('tbody'); return tb?Array.prototype.slice.call(tb.querySelectorAll('tr')):[]; }
  function cellText(r,i){ var c=r.children[i]; return c?(c.textContent||'').trim().toLowerCase():''; }
  function searchText(r){ var s=''; for(var i=0;i<r.children.length;i++){ var c=r.children[i]; if(c.querySelector&&c.querySelector('.rowact'))continue; s+=' '+(c.textContent||''); } return s.toLowerCase(); }
  function storeKey(){ return 'cms-list:'+location.pathname; }
  function filterEls(v){ return Array.prototype.slice.call(v.querySelectorAll('[data-filter]')); }
  function setSelVal(sel,val){
    if(sel.tagName==='SELECT'){
      var has=false; for(var i=0;i<sel.options.length;i++){ if(sel.options[i].value===val){has=true;break;} }
      if(!has){ var o=document.createElement('option'); o.value=val; o.textContent=val; sel.appendChild(o); }
    }
    sel.value=val;
  }

  function save(v){
    try{
      var si=v.querySelector('[data-search]');
      var f={}; filterEls(v).forEach(function(el){ var k=el.getAttribute('data-filter-key'); if(k)f[k]=el.value; });
      var ps=v.querySelector('[data-page-size]');
      sessionStorage.setItem(storeKey(),JSON.stringify({
        q:si?si.value:'', filters:f, page:parseInt(v.getAttribute('data-page')||'1',10), size:ps?ps.value:''
      }));
    }catch(e){}
  }
  function seed(v){
    var st=null; try{ st=JSON.parse(sessionStorage.getItem(storeKey())||'null'); }catch(e){}
    var si=v.querySelector('[data-search]'); var ps=v.querySelector('[data-page-size]'); var filters=filterEls(v);
    if(st){
      if(si&&typeof st.q==='string')si.value=st.q;
      if(st.filters)filters.forEach(function(el){ var k=el.getAttribute('data-filter-key'); if(k&&st.filters[k]!=null)setSelVal(el,st.filters[k]); });
      if(ps&&st.size!=null&&st.size!=='')setSelVal(ps,String(st.size));
      if(st.page)v.setAttribute('data-page',String(st.page));
    }
    try{
      var p=new URLSearchParams(location.search);
      if(p.has('q')&&si)si.value=p.get('q');
      filters.forEach(function(el){ var k=el.getAttribute('data-filter-key'); if(k&&p.has(k))setSelVal(el,p.get(k)); });
      if(p.has('size')&&ps)setSelVal(ps,p.get('size'));
      if(p.has('page'))v.setAttribute('data-page',String(parseInt(p.get('page'),10)||1));
    }catch(e){}
  }

  function paginate(v,visible){
    var sizeSel=v.querySelector('[data-page-size]');
    var size=sizeSel?parseInt(sizeSel.value,10):0;
    var pager=v.querySelector('.pager'); var page=parseInt(v.getAttribute('data-page')||'1',10);
    if(!size||!pager){ visible.forEach(function(r){r.classList.remove('paged-out');}); if(pager)pager.innerHTML=''; return; }
    var pages=Math.max(1,Math.ceil(visible.length/size));
    if(page>pages)page=pages; if(page<1)page=1; v.setAttribute('data-page',String(page));
    visible.forEach(function(r,i){ r.classList.toggle('paged-out', Math.floor(i/size)!==(page-1)); });
    var from=visible.length?((page-1)*size+1):0, to=Math.min(page*size,visible.length);
    pager.innerHTML='';
    var info=document.createElement('span'); info.className='pginfo';
    info.textContent=visible.length?(from+'\\u2013'+to+' of '+visible.length):'0 results';
    pager.appendChild(info);
    function go(target){
      v.setAttribute('data-page',String(target)); apply(v,'page');
      if(v.getBoundingClientRect().top<0)v.scrollIntoView();
    }
    function nav(label,target,disabled){
      var b=document.createElement('button'); b.type='button'; b.className='btn sec sm'; b.textContent=label;
      if(disabled)b.disabled=true; else b.addEventListener('click',function(){go(target);});
      pager.appendChild(b);
    }
    function num(p){
      var b=document.createElement('button'); b.type='button'; b.className='btn sec sm'; b.textContent=String(p);
      if(p===page){ b.classList.add('on'); b.disabled=true; } else b.addEventListener('click',function(){go(p);});
      pager.appendChild(b);
    }
    function ell(){ var s=document.createElement('span'); s.textContent='\\u2026'; s.style.padding='0 4px'; pager.appendChild(s); }
    nav('\\u00ab First',1,page<=1);
    nav('\\u2039 Prev',page-1,page<=1);
    var start=Math.max(1,page-2), end=Math.min(pages,page+2);
    if(start>1)ell();
    for(var pp=start;pp<=end;pp++)num(pp);
    if(end<pages)ell();
    nav('Next \\u203a',page+1,page>=pages);
    nav('Last \\u00bb',pages,page>=pages);
  }
  // Mirror the table's post-filter/sort/paginate state onto the optional grid
  // view: cards (matched by data-grid-id ↔ tr data-id) follow row order and
  // visibility, so search/filters/pagination work identically in both views.
  function syncGrid(v){
    var g=v.querySelector('[data-grid]'); if(!g)return;
    var map={};
    Array.prototype.slice.call(g.querySelectorAll('[data-grid-id]')).forEach(function(c){map[c.getAttribute('data-grid-id')]=c;});
    rows(v).forEach(function(r){
      var c=map[r.getAttribute('data-id')]; if(!c)return;
      g.appendChild(c);
      c.style.display=(r.classList.contains('filtered-out')||r.classList.contains('paged-out'))?'none':'';
    });
  }
  function apply(v,reason){
    var si=v.querySelector('[data-search]'); var q=si?(si.value||'').trim().toLowerCase():'';
    var wrap=si&&si.closest?si.closest('.searchwrap'):null;
    if(wrap) wrap.classList.toggle('has-value',q.length>0);
    var filters=filterEls(v);
    var all=rows(v); var visible=[];
    all.forEach(function(r){
      var ok=true;
      if(q && searchText(r).indexOf(q)<0) ok=false;
      if(ok) for(var i=0;i<filters.length;i++){ var f=filters[i]; var val=f.value;
        if(val){ var col=parseInt(f.getAttribute('data-filter'),10); var cv=cellText(r,col); var want=val.toLowerCase().trim();
          if(f.getAttribute('data-filter-exact')!=null){ if(cv.trim()!==want){ok=false;break;} }
          else if(cv.indexOf(want)<0){ok=false;break;} } }
      r.classList.toggle('filtered-out',!ok); if(ok)visible.push(r);
    });
    paginate(v,visible);
    syncGrid(v);
    var empty=v.querySelector('[data-empty-filtered]');
    if(empty) empty.style.display=(all.length>0&&visible.length===0)?'block':'none';
    save(v);
    v.dispatchEvent(new CustomEvent('cms:listchange',{detail:{reason:reason||'init'}}));
  }
  function sortBy(v,th){
    var tb=v.querySelector('tbody'); if(!tb)return;
    var idx=Array.prototype.indexOf.call(th.parentNode.children,th);
    var dir=th.getAttribute('data-dir')==='asc'?'desc':'asc';
    Array.prototype.slice.call(v.querySelectorAll('th.sortable')).forEach(function(o){o.removeAttribute('data-dir');o.removeAttribute('aria-sort');});
    th.setAttribute('data-dir',dir);
    th.setAttribute('aria-sort',dir==='asc'?'ascending':'descending');
    var num=th.getAttribute('data-type')==='num';
    var rs=rows(v).sort(function(a,b){
      var x=cellText(a,idx),y=cellText(b,idx);
      if(num){ x=parseFloat(x)||0; y=parseFloat(y)||0; return dir==='asc'?x-y:y-x; }
      return dir==='asc'?x.localeCompare(y):y.localeCompare(x);
    });
    rs.forEach(function(r){tb.appendChild(r);});
    apply(v,'sort');
  }
  function wire(v){
    seed(v);
    var si=v.querySelector('[data-search]');
    if(si){ var t; si.addEventListener('input',function(){clearTimeout(t);t=setTimeout(function(){v.setAttribute('data-page','1');apply(v,'search');},120);}); }
    var sc=v.querySelector('[data-search-clear]');
    if(sc&&si){ sc.addEventListener('click',function(){si.value='';si.focus();v.setAttribute('data-page','1');apply(v,'search');}); }
    filterEls(v).forEach(function(f){f.addEventListener('change',function(){v.setAttribute('data-page','1');apply(v,'filter');});});
    var ps=v.querySelector('[data-page-size]'); if(ps)ps.addEventListener('change',function(){v.setAttribute('data-page','1');apply(v,'size');});
    v.querySelectorAll('th.sortable').forEach(function(th){
      th.setAttribute('tabindex','0'); th.setAttribute('role','button');
      th.addEventListener('click',function(){sortBy(v,th);});
      th.addEventListener('keydown',function(e){ if(e.key==='Enter'||e.key===' '||e.key==='Spacebar'){ e.preventDefault(); sortBy(v,th); } });
    });
    apply(v,'init');
  }
  // Search focus shortcut: "/" or Ctrl/Cmd+K (unless typing / a dialog is open).
  document.addEventListener('keydown',function(e){
    var slash=e.key==='/'; var cmdk=(e.ctrlKey||e.metaKey)&&(e.key==='k'||e.key==='K');
    if(!slash&&!cmdk)return;
    var t=e.target;
    if(t&&(t.tagName==='INPUT'||t.tagName==='TEXTAREA'||t.tagName==='SELECT'||t.isContentEditable))return;
    if(document.querySelector('dialog[open]'))return;
    var s=document.querySelector('[data-search]');
    if(s){ e.preventDefault(); s.focus(); }
  });
  function init(){ document.querySelectorAll('[data-listview]').forEach(wire); }
  if(document.readyState!=='loading')init(); else document.addEventListener('DOMContentLoaded',init);
})();
`;

/** NAV_JS: mobile off-canvas drawer toggle (copied from the reference CMS). */
const NAV_JS = `
(function(){
  function set(open){ document.body.classList.toggle('nav-open',open); var h=document.querySelector('[data-nav-toggle]'); if(h)h.setAttribute('aria-expanded',open?'true':'false'); }
  document.addEventListener('click',function(e){
    if(e.target.closest&&e.target.closest('[data-nav-toggle]')){ set(!document.body.classList.contains('nav-open')); return; }
    if(e.target.closest&&e.target.closest('[data-nav-close]')){ set(false); return; }
    if(e.target.closest&&e.target.closest('.side .nav a')){ set(false); }
  });
  document.addEventListener('keydown',function(e){ if(e.key==='Escape')set(false); });
})();
`;

/**
 * Browser uploader for forms marked data-upload-form. For each
 * <input type=file data-slot="X">, it presigns via the form's data-presign URL
 * (the app-scoped /{slug}/media/upload-url endpoint — the ONE unified-CMS
 * delta vs the reference script), PUTs the bytes directly to R2 (zero-egress),
 * then fills hidden fields key_X / mime_X / id_X and submits the form. File
 * inputs carry no `name`, so the bytes are never posted to the Worker.
 *
 * Unified-CMS additions on top of the reference behavior:
 *   - dimension pre-check against the media conventions (warn + confirm, never
 *     silently blocks) for images and videos;
 *   - video uploads capture a first-frame JPEG on a canvas and PUT it to the
 *     presign response's thumbUploadUrl (best-effort — no thumb, no failure);
 *   - a multi-select file input plus a hidden items_json field switches the
 *     form into batch mode: every file is uploaded, then the create POST
 *     carries the whole batch as JSON (one txn / one rebuild server-side).
 *
 * Delegated off `document` submit, so it also handles forms rendered inside a
 * <dialog> / swapped in by HTMX. The presign body also carries the form's
 * `category` value when present (Arul keys are category-partitioned).
 */
const UPLOAD_JS = `
(function(){
  function infer(name){var e=(name.split('.').pop()||'').toLowerCase();return ({jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png',webp:'image/webp',mp4:'video/mp4',mp3:'audio/mpeg',m4a:'audio/mp4',aac:'audio/aac'})[e]||'';}
  function set(form,n,v){var el=form.querySelector('[name="'+n+'"]');if(el)el.value=v;}
  function slug(s){return (s||'').trim().toLowerCase().replace(/\\s+/g,'-').replace(/[^a-z0-9_-]/g,'');}
  function stem(n){var i=n.lastIndexOf('.');return i>0?n.slice(0,i):n;}
  function pretty(s){return s.replace(/[-_]+/g,' ').split(' ').filter(function(w){return w.length;}).map(function(w){return w.charAt(0).toUpperCase()+w.slice(1);}).join(' ');}
  function fmtSize(b){return b>=1048576?((b/1048576).toFixed(1)+' MB'):(Math.round(b/1024)+' KB');}
  // Probe a video file: dimensions + a first-frame JPEG (scaled to 540w) for the
  // admin thumbnail. Resolves null on any failure — the thumb is best-effort.
  function probeVideo(f){return new Promise(function(resolve){
    var url=URL.createObjectURL(f);var v=document.createElement('video');var done=false;
    function fin(r){if(done)return;done=true;URL.revokeObjectURL(url);resolve(r);}
    v.muted=true;v.preload='auto';
    v.addEventListener('error',function(){fin(null);});
    v.addEventListener('loadeddata',function(){
      var w=v.videoWidth,h=v.videoHeight;
      if(!w||!h)return fin(null);
      try{
        var tw=540,th=Math.round(tw*h/w);
        var cv=document.createElement('canvas');cv.width=tw;cv.height=th;
        cv.getContext('2d').drawImage(v,0,0,tw,th);
        cv.toBlob(function(b){fin({w:w,h:h,thumb:b});},'image/jpeg',0.82);
      }catch(e){fin({w:w,h:h,thumb:null});}
    });
    v.src=url;
    setTimeout(function(){fin(null);},8000);
  });}
  function probeImage(f){return new Promise(function(resolve){
    var url=URL.createObjectURL(f);var im=new Image();
    im.onload=function(){var r={w:im.naturalWidth,h:im.naturalHeight,thumb:null};URL.revokeObjectURL(url);resolve(r);};
    im.onerror=function(){URL.revokeObjectURL(url);resolve(null);};
    im.src=url;
  });}
  // Cache probe results on the file object so the list render and the upload
  // share one decode.
  function probeFile(f){
    if(f._probe!==undefined)return Promise.resolve(f._probe);
    var ct=f.type||infer(f.name),p;
    if(ct==='video/mp4')p=probeVideo(f); else if(ct.indexOf('image/')===0)p=probeImage(f); else p=Promise.resolve(null);
    return p.then(function(r){f._probe=r;return r;});
  }
  // Media-convention dimension check (docs/media-conventions.md). Warn-and-
  // confirm rather than block: the operator may knowingly upload an exception.
  function dimWarning(ct,d){
    if(!d)return null;
    if(ct==='video/mp4'&&(d.w!==1024||d.h!==1824))
      return 'Video is '+d.w+'\\u00d7'+d.h+' \\u2014 the live-wallpaper convention is 1024\\u00d71824 (width%128==0, height%32==0, fits the 1088\\u00d71920 hw-decoder cap). Off-spec dims risk the green-edge bug on budget phones.';
    if(ct.indexOf('image/')===0&&(d.w!==1080||d.h!==1920))
      return 'Image is '+d.w+'\\u00d7'+d.h+' \\u2014 the static-wallpaper convention is 1080\\u00d71920.';
    return null;
  }
  function shortReason(ct,d){
    if(!d)return 'unreadable';
    if(ct==='video/mp4')return d.w+'\\u00d7'+d.h+' (want 1024\\u00d71824)';
    if(ct.indexOf('image/')===0)return d.w+'\\u00d7'+d.h+' (want 1080\\u00d71920)';
    return 'off-spec';
  }

  // ── Pre-upload file list (opt-in via [data-file-list]) ──
  function fileListBox(form){ return form.querySelector('[data-file-list]'); }
  function removeFile(form,input,idx){
    try{
      var dt=new DataTransfer();
      Array.prototype.forEach.call(input.files,function(f,i){ if(i!==idx)dt.items.add(f); });
      input.files=dt.files;
      input.dispatchEvent(new Event('change'));
    }catch(e){}
  }
  function renderList(form){
    var box=fileListBox(form); if(!box)return;
    box.innerHTML='';
    form.querySelectorAll('input[type=file][data-slot]').forEach(function(input){
      var files=input.files?Array.prototype.slice.call(input.files):[];
      files.forEach(function(f,idx){
        var row=document.createElement('div'); row.className='fl-row';
        var name=document.createElement('span'); name.className='fl-name'; name.textContent=f.name;
        var size=document.createElement('span'); size.className='fl-size'; size.textContent=fmtSize(f.size);
        var stat=document.createElement('span'); stat.className='fl-stat'; stat.textContent='\\u2026';
        var x=document.createElement('button'); x.type='button'; x.className='fl-x'; x.setAttribute('aria-label','Remove'); x.textContent='\\u00d7';
        x.addEventListener('click',function(){ removeFile(form,input,idx); });
        row.appendChild(name);row.appendChild(size);row.appendChild(stat);row.appendChild(x);
        box.appendChild(row);
        probeFile(f).then(function(d){
          var ct=f.type||infer(f.name),w=dimWarning(ct,d);
          if(w){ stat.textContent='\\u26a0 '+shortReason(ct,d); stat.className='fl-stat warn'; stat.title=w; }
          else { stat.textContent='\\u2713'; stat.className='fl-stat ok'; }
        });
      });
    });
  }
  document.addEventListener('change',function(e){
    var input=e.target;
    if(input.matches&&input.matches('input[type=file][data-slot]')){
      var form=input.closest('form[data-upload-form]');
      if(form&&fileListBox(form))renderList(form);
    }
  });

  // ── Slug preview (opt-in via [data-slug-preview] → [data-slug-preview-out]) ──
  document.addEventListener('input',function(e){
    var el=e.target;
    if(!el.matches||!el.matches('[data-slug-preview]'))return;
    var form=el.closest('form')||document;
    var outs=Array.prototype.slice.call(form.querySelectorAll('[data-slug-preview-out]'));
    var out=null;
    for(var i=0;i<outs.length;i++){ if(el.compareDocumentPosition(outs[i])&Node.DOCUMENT_POSITION_FOLLOWING){out=outs[i];break;} }
    if(!out)out=outs[0];
    if(out){ var tpl=out.getAttribute('data-slug-template')||''; out.textContent=el.value?tpl.split('{slug}').join(slug(el.value)):''; }
  });

  // ── Abort control ──
  window.cmsAbortUpload=function(form){
    if(!form)return;
    form.dataset.aborted='1';
    if(form._xhr){ try{form._xhr.abort();}catch(e){} }
  };
  function aborted(form){ return form.dataset.aborted==='1'; }
  function progressEls(form){ var p=form.querySelector('[data-upload-progress]'); return p?{box:p,bar:p.querySelector('i')}:null; }
  function hideProgress(form){ var pe=progressEls(form); if(pe){pe.box.classList.remove('on'); if(pe.bar)pe.bar.style.width='0%';} }
  function makeCtx(form,total){
    var done=0, pe=progressEls(form);
    if(pe){pe.box.classList.add('on'); if(pe.bar)pe.bar.style.width='0%';}
    function render(cur){ if(pe&&pe.bar){ var pct=total>0?Math.min(100,Math.round((done+(cur||0))/total*100)):0; pe.bar.style.width=pct+'%'; } }
    return { setLoaded:function(l){render(l);}, addDone:function(s){done+=s;render(0);}, finish:function(){ if(pe&&pe.bar)pe.bar.style.width='100%'; } };
  }
  function putXHR(form,url,ct,body,onprog){
    return new Promise(function(resolve,reject){
      var xhr=new XMLHttpRequest(); form._xhr=xhr;
      xhr.open('PUT',url); xhr.setRequestHeader('content-type',ct);
      if(xhr.upload&&onprog)xhr.upload.onprogress=function(ev){ if(ev.lengthComputable)onprog(ev.loaded); };
      xhr.onload=function(){ form._xhr=null; if(xhr.status>=200&&xhr.status<300)resolve(); else reject(new Error('R2 upload failed ('+xhr.status+')')); };
      xhr.onerror=function(){ form._xhr=null; reject(new Error('R2 upload failed (network)')); };
      xhr.onabort=function(){ form._xhr=null; reject(new Error('__aborted__')); };
      xhr.send(body);
    });
  }
  async function uploadOne(form,input,f,ctx){
    var ct=f.type||infer(f.name);
    var probe=await probeFile(f);
    var catEl=form.querySelector('[name="category"]');var cat=catEl?catEl.value:'';
    var pres=await fetch(form.dataset.presign,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({kind:form.dataset.kind,slot:input.dataset.slot,contentType:ct,size:f.size,category:cat})});
    var pj=await pres.json().catch(function(){return{};});
    if(!pres.ok) throw new Error((pj.error&&pj.error.message)||('upload-url failed ('+pres.status+')'));
    if(aborted(form))throw new Error('__aborted__');
    await putXHR(form,pj.uploadUrl,ct,f,function(loaded){ if(ctx)ctx.setLoaded(loaded); });
    if(ctx)ctx.addDone(f.size);
    // Best-effort thumb PUT: a failure only means the admin list shows \\u25b6.
    if(pj.thumbUploadUrl&&probe&&probe.thumb){
      try{await fetch(pj.thumbUploadUrl,{method:'PUT',headers:{'content-type':'image/jpeg'},body:probe.thumb});}catch(e){}
    }
    return {key:pj.key,mime:ct,id:pj.id};
  }
  // Category guards run BEFORE any upload, in order (new category, then dup title).
  async function categoryGuards(form){
    var catIn=form.querySelector('input[data-warn-new-category]');
    if(catIn&&catIn.getAttribute('list')){
      var listEl=document.getElementById(catIn.getAttribute('list'));
      var s=slug(catIn.value);
      if(s){
        var known=[]; if(listEl)Array.prototype.forEach.call(listEl.querySelectorAll('option'),function(o){known.push(slug(o.value));});
        if(known.indexOf(s)<0){
          var ok=await window.cmsConfirm('Create the NEW category "'+s+'"? It will appear as a new chip in the app.');
          if(!ok)return false;
        }
      }
    }
    var dupSrc=form.getAttribute('data-dup-source');
    if(dupSrc){
      var scriptEl=document.getElementById(dupSrc);
      var arr=[]; if(scriptEl){ try{arr=JSON.parse(scriptEl.textContent||'[]');}catch(e){arr=[];} }
      var nfiles=0; form.querySelectorAll('input[type=file][data-slot]').forEach(function(inp){ nfiles+=inp.files?inp.files.length:0; });
      var titleEl=form.querySelector('[name="title"]'); var catEl=form.querySelector('[name="category"]');
      if(nfiles===1&&titleEl&&catEl){
        var key=slug(catEl.value)+'|'+titleEl.value.trim().toLowerCase();
        if(arr.indexOf(key)>=0){
          var ok2=await window.cmsConfirm('"'+titleEl.value.trim()+'" already exists in this category. Create it anyway?');
          if(!ok2)return false;
        }
      }
    }
    return true;
  }
  async function run(form){
    form.dataset.aborted='';
    form.setAttribute('data-busy-upload','1');
    var status=form.querySelector('[data-upload-status]');
    var inputs=form.querySelectorAll('input[type=file][data-slot]');
    var total=0,pfiles=[];
    Array.prototype.forEach.call(inputs,function(input){ var files=input.files?Array.prototype.slice.call(input.files):[]; files.forEach(function(f){total+=f.size;pfiles.push(f);}); });
    // Ensure all probes are done, then confirm ONCE if anything is off-spec.
    var warnItems=[];
    for(var pi=0;pi<pfiles.length;pi++){
      var d=await probeFile(pfiles[pi]); var ct=pfiles[pi].type||infer(pfiles[pi].name); var w=dimWarning(ct,d);
      if(w)warnItems.push(pfiles[pi].name+': '+w);
    }
    if(aborted(form))throw new Error('__aborted__');
    if(warnItems.length){
      var okw=await window.cmsConfirm(warnItems.length+' file(s) are off-spec:\\n'+warnItems.join('\\n')+'\\n\\nUpload anyway?');
      if(!okw)return false;
    }
    if(!(await categoryGuards(form)))return false;
    if(aborted(form))throw new Error('__aborted__');
    var ctx=makeCtx(form,total);
    var titlesFromFilenames=!!form.querySelector('input[name="titles_from_filenames"]:checked');
    for(var i=0;i<inputs.length;i++){
      if(aborted(form))throw new Error('__aborted__');
      var input=inputs[i];var files=input.files?Array.prototype.slice.call(input.files):[];
      if(!files.length){ if(input.hasAttribute('data-required')) throw new Error('Select a file for "'+input.dataset.slot+'"'); else continue; }
      var multi=form.querySelector('[name="items_json"]');
      if(files.length>1){
        if(!multi) throw new Error('This form accepts a single file');
        var items=[];
        for(var j=0;j<files.length;j++){
          if(aborted(form))throw new Error('__aborted__');
          if(status)status.textContent='File '+(j+1)+' of '+files.length+'\\u2026';
          var r1=await uploadOne(form,input,files[j],ctx);
          var obj={key:r1.key,mime:r1.mime,id:r1.id};
          if(titlesFromFilenames)obj.title=pretty(stem(files[j].name));
          items.push(obj);
        }
        multi.value=JSON.stringify(items);
        set(form,'key_'+input.dataset.slot,'');set(form,'mime_'+input.dataset.slot,'');set(form,'id_'+input.dataset.slot,'');
      }else{
        if(status)status.textContent='Uploading '+files[0].name+'\\u2026 ('+Math.round(files[0].size/1024)+' KB)';
        var r=await uploadOne(form,input,files[0],ctx);
        set(form,'key_'+input.dataset.slot,r.key);set(form,'mime_'+input.dataset.slot,r.mime);set(form,'id_'+input.dataset.slot,r.id);
        if(multi)multi.value='';
      }
    }
    ctx.finish();
    return true;
  }
  document.addEventListener('submit',function(e){
    var form=e.target;
    if(!form.matches||!form.matches('form[data-upload-form]'))return;
    if(form.dataset.uploaded==='1')return;
    e.preventDefault();
    var btn=form.querySelector('[type=submit]');var status=form.querySelector('[data-upload-status]');var box=form.querySelector('[data-upload-error]');
    if(box){box.style.display='none';box.textContent='';}
    var origLabel=btn?btn.textContent:'';
    if(btn){btn.disabled=true;btn.classList.add('busy');btn.textContent='Uploading\\u2026';}
    run(form).then(function(go){
      form.removeAttribute('data-busy-upload');
      if(go===false){ if(btn){btn.disabled=false;btn.classList.remove('busy');btn.textContent=origLabel;} if(status)status.textContent=''; hideProgress(form); return; }
      form.dataset.uploaded='1';if(status)status.textContent='Saving\\u2026';if(btn)btn.textContent='Saving\\u2026';form.submit();
    }).catch(function(err){
      form.removeAttribute('data-busy-upload'); hideProgress(form);
      if(err&&err.message==='__aborted__'){
        form.dataset.aborted='';
        if(status)status.textContent='Upload cancelled'; if(btn){btn.disabled=false;btn.classList.remove('busy');btn.textContent=origLabel;}
        return;
      }
      if(status)status.textContent='';if(btn){btn.disabled=false;btn.classList.remove('busy');btn.textContent=origLabel;}
      if(box){box.style.display='block';box.textContent=err.message;}
      else if(window.cmsToast){window.cmsToast(err.message,{danger:true});}
      else alert(err.message);
    });
  });
})();
`;

/** SELECT_ALL_JS: the transfer picker's select-all checkbox + count label. */
const SELECT_ALL_JS = `
(function(){
  function counts(scope){
    var boxes=scope.querySelectorAll('input[name="ids"]');
    var n=0; boxes.forEach(function(b){ if(b.checked)n++; });
    var lab=scope.querySelector('[data-selected-count]'); if(lab)lab.textContent=n+' selected';
    var go=scope.querySelector('[data-transfer-go]'); if(go){ go.disabled=(n===0); go.textContent=n>0?('Move '+n+' item'+(n===1?'':'s')):'Move selected wallpapers'; }
  }
  document.addEventListener('change',function(e){
    var all=e.target.closest&&e.target.closest('[data-select-all]');
    var scope=e.target.closest&&e.target.closest('[data-pickscope]');
    if(!scope)return;
    if(all){ scope.querySelectorAll('input[name="ids"]').forEach(function(b){b.checked=all.checked;}); }
    counts(scope);
  });
  function init(){ document.querySelectorAll('[data-pickscope]').forEach(counts); }
  if(document.readyState!=='loading')init(); else document.addEventListener('DOMContentLoaded',init);
})();
`;

/**
 * BULK_JS: list-page bulk selection + table/grid view toggle.
 *   - checkboxes marked data-bulk-id select a row; the same id may appear in
 *     BOTH the table and the grid, so twins are kept in sync;
 *   - the header data-bulk-all checkbox selects every currently VISIBLE
 *     (filtered-in) row;
 *   - the data-bulk-bar form appears once anything is selected; its buttons
 *     stamp bulk_action + comma-joined ids and submit (delete via confirm);
 *   - data-view="table|grid" buttons swap .tablewrap ↔ [data-grid], persisted
 *     in localStorage so the preferred view sticks across pages.
 */
const BULK_JS = `
(function(){
  var VKEY='cms-list-view:'+location.pathname, VKEY_OLD='cms-list-view';
  var lastClicked=new WeakMap();
  function scope(el){return el.closest&&el.closest('[data-listview]');}
  function pageRows(v){ return rows(v).filter(function(r){return !r.classList.contains('filtered-out')&&!r.classList.contains('paged-out');}); }
  function filteredRows(v){ return rows(v).filter(function(r){return !r.classList.contains('filtered-out');}); }
  function rows(v){ return Array.prototype.slice.call(v.querySelectorAll('tbody tr')); }
  function setChecked(v,id,checked){ v.querySelectorAll('[data-bulk-id="'+id+'"]').forEach(function(x){x.checked=checked;}); }

  function update(v){
    var seen={},ids=[];
    v.querySelectorAll('[data-bulk-id]').forEach(function(b){
      var id=b.getAttribute('data-bulk-id');
      if(b.checked&&!seen[id]){seen[id]=1;ids.push(id);}
    });
    var pr=pageRows(v), pageChecked=0;
    pr.forEach(function(r){ var cb=r.querySelector('[data-bulk-id]'); if(cb&&cb.checked)pageChecked++; });
    var fullPage=pr.length>0&&pageChecked===pr.length;
    // Reflect the current page on both the header checkbox and the toolbar toggle.
    v.querySelectorAll('[data-bulk-all]').forEach(function(all){
      all.checked=fullPage; all.indeterminate=pageChecked>0&&!fullPage;
    });
    var bar=v.querySelector('[data-bulk-bar]'); if(!bar)return;
    bar.style.display=ids.length?'flex':'none';
    var other=0;
    ids.forEach(function(id){
      var cb=v.querySelector('tbody [data-bulk-id="'+id+'"]'); var row=cb?cb.closest('tr'):null;
      if(row&&(row.classList.contains('paged-out')||row.classList.contains('filtered-out')))other++;
    });
    var lab=bar.querySelector('[data-bulk-count]');
    if(lab)lab.textContent=other>0?(ids.length+' selected \\u00b7 '+other+' on other pages'):(ids.length+' selected');
    var inp=bar.querySelector('[name="ids"]'); if(inp)inp.value=ids.join(',');
    var match=bar.querySelector('[data-bulk-matching]');
    if(match){
      var fr=filteredRows(v);
      if(fullPage&&fr.length>pr.length&&ids.length<fr.length){ match.hidden=false; match.textContent='Select all '+fr.length+' matching'; }
      else match.hidden=true;
    }
  }
  function togglePage(v,checked){
    pageRows(v).forEach(function(r){ var cb=r.querySelector('[data-bulk-id]'); if(cb)setChecked(v,cb.getAttribute('data-bulk-id'),checked); });
    update(v);
  }
  function clearAll(v){
    v.querySelectorAll('[data-bulk-id]').forEach(function(b){b.checked=false;});
    lastClicked.delete(v); update(v);
  }
  function visibleIds(v){
    return pageRows(v).map(function(r){ var cb=r.querySelector('[data-bulk-id]'); return cb?cb.getAttribute('data-bulk-id'):null; }).filter(Boolean);
  }

  // Row checkbox clicks (handles shift-range; keyboard Space fires click too).
  document.addEventListener('click',function(e){
    var cb=e.target.closest&&e.target.closest('input[data-bulk-id]');
    if(cb){
      var v=scope(cb); if(!v)return;
      var id=cb.getAttribute('data-bulk-id'); var checked=cb.checked;
      if(e.shiftKey){
        var last=lastClicked.get(v);
        if(last!=null){
          var order=visibleIds(v); var i1=order.indexOf(last), i2=order.indexOf(id);
          if(i1>=0&&i2>=0){ var lo=Math.min(i1,i2),hi=Math.max(i1,i2); for(var k=lo;k<=hi;k++)setChecked(v,order[k],checked); }
        }
      }
      setChecked(v,id,checked);
      lastClicked.set(v,id);
      update(v);
      return;
    }
    var sp=e.target.closest&&e.target.closest('[data-bulk-select-page]');
    if(sp){ var vp=scope(sp); if(vp){ var pr=pageRows(vp); var allSel=pr.length>0&&pr.every(function(r){var c=r.querySelector('[data-bulk-id]');return c&&c.checked;}); togglePage(vp,!allSel); } return; }
    var mb=e.target.closest&&e.target.closest('[data-bulk-matching]');
    if(mb){ var vm=scope(mb); if(vm){ filteredRows(vm).forEach(function(r){var c=r.querySelector('[data-bulk-id]');if(c)setChecked(vm,c.getAttribute('data-bulk-id'),true);}); update(vm); } return; }
    var bx=e.target.closest&&e.target.closest('.bulkbar .bulk-x');
    if(bx){ var vx=scope(bx); if(vx)clearAll(vx); return; }
    var act=e.target.closest&&e.target.closest('[data-bulk-act]');
    if(act){
      var form=act.closest('form'); if(!form)return;
      var a=act.getAttribute('data-bulk-act');
      var idsField=form.querySelector('[name="ids"]');
      var n=((idsField&&idsField.value)||'').split(',').filter(Boolean).length;
      if(!n)return;
      if(a==='delete'){
        e.preventDefault();
        var noun=form.getAttribute('data-bulk-noun')||'items';
        window.cmsConfirm('Delete '+n+' '+noun+'? This removes them from the app.').then(function(ok){
          if(!ok)return; form.querySelector('[name="bulk_action"]').value=a; form.submit();
        });
        return;
      }
      form.querySelector('[name="bulk_action"]').value=a; form.submit();
      return;
    }
    var vb=e.target.closest&&e.target.closest('[data-view]');
    if(vb){ var vv=scope(vb); if(vv){ setView(vv,vb.getAttribute('data-view')); try{localStorage.setItem(VKEY,vb.getAttribute('data-view'));}catch(err){} } }
  });
  // Header select-all checkbox.
  document.addEventListener('change',function(e){
    var t=e.target;
    if(t.matches&&t.matches('[data-bulk-all]')){ var v=scope(t); if(v)togglePage(v,t.checked); }
  });
  function setView(v,mode){
    var g=v.querySelector('[data-grid]'); var tw=v.querySelector('.tablewrap'); if(!g||!tw)return;
    var grid=mode==='grid';
    tw.style.display=grid?'none':''; g.style.display=grid?'':'none';
    v.querySelectorAll('[data-view]').forEach(function(b){b.classList.toggle('on',b.getAttribute('data-view')===mode);});
  }
  function readView(){ try{ var x=localStorage.getItem(VKEY); if(x)return x; return localStorage.getItem(VKEY_OLD)||'table'; }catch(e){return 'table';} }
  function init(){
    document.querySelectorAll('[data-listview]').forEach(function(v){
      if(v.querySelector('[data-grid]'))setView(v,readView());
      v.addEventListener('cms:listchange',function(e){
        var reason=e.detail&&e.detail.reason;
        if(reason==='search'||reason==='filter'||reason==='size')clearAll(v); else update(v);
      });
      update(v);
    });
  }
  if(document.readyState!=='loading')init(); else document.addEventListener('DOMContentLoaded',init);
})();
`;

/**
 * TOAST_JS: the shared toast bus. Exposes window.cmsToast(msg, opts) —
 * opts.danger renders the red variant AND makes it sticky by default; ok toasts
 * auto-dismiss after 4s. Hovering a toast pauses its timer (resumes 1.5s after
 * the pointer leaves). Also drains any hidden ?ok=/?err= Flash notes into toasts
 * on load, then strips ok/err from the URL (keeping every other param).
 */
const TOAST_JS = `
(function(){
  function cmsToast(msg,opts){
    opts=opts||{};
    var stack=document.getElementById('toast-stack'); if(!stack)return null;
    var danger=!!opts.danger;
    var sticky=opts.sticky!=null?opts.sticky:danger;
    var t=document.createElement('div'); t.className='toast'+(danger?' danger':'');
    var m=document.createElement('span'); m.className='toast-msg'; m.textContent=msg;
    var x=document.createElement('button'); x.type='button'; x.className='toast-x'; x.setAttribute('aria-label','Dismiss'); x.textContent='\\u00d7';
    var timer=null;
    function dismiss(){ if(timer){clearTimeout(timer);timer=null;} if(t.parentNode)t.parentNode.removeChild(t); }
    function arm(ms){ if(sticky)return; if(timer)clearTimeout(timer); timer=setTimeout(dismiss,ms); }
    x.addEventListener('click',dismiss);
    t.addEventListener('mouseenter',function(){ if(timer){clearTimeout(timer);timer=null;} });
    t.addEventListener('mouseleave',function(){ arm(1500); });
    t.appendChild(m); t.appendChild(x); stack.appendChild(t);
    arm(4000);
    return t;
  }
  window.cmsToast=cmsToast;
  function init(){
    var flashed=false;
    document.querySelectorAll('[data-flash]').forEach(function(el){
      cmsToast(el.textContent,{danger:el.classList.contains('danger')});
      el.parentNode&&el.parentNode.removeChild(el); flashed=true;
    });
    if(flashed){
      try{
        var u=new URL(location.href); u.searchParams.delete('ok'); u.searchParams.delete('err');
        var qs=u.searchParams.toString();
        history.replaceState(null,'',u.pathname+(qs?('?'+qs):'')+u.hash);
      }catch(e){}
    }
  }
  if(document.readyState!=='loading')init(); else document.addEventListener('DOMContentLoaded',init);
})();
`;

/**
 * DROPZONE_JS: wraps each data-upload-form's file input with the dashed
 * dropzone look (see .dropzone CSS) and forwards drag-and-drop files onto the
 * SAME <input type=file data-slot> — the input's name/attributes never
 * change, so UPLOAD_JS's presign flow is untouched.
 */
const DROPZONE_JS = `
(function(){
  function labelFor(input){
    var multi=input.hasAttribute('multiple');
    return multi
      ? 'Drop files or browse \\u2014 select several to create a batch'
      : 'Drop a file or browse';
  }
  function wrap(input){
    if(input.closest('.dropzone'))return;
    var box=document.createElement('div'); box.className='dropzone';
    var ic=document.createElement('div'); ic.className='dz-ic'; ic.textContent='\\u21ea';
    var txt=document.createElement('div'); txt.className='dz-text'; txt.textContent=labelFor(input);
    input.parentNode.insertBefore(box,input);
    box.appendChild(ic); box.appendChild(txt); box.appendChild(input);
    function refresh(){
      var n=input.files?input.files.length:0;
      box.classList.toggle('has-file',n>0);
      txt.textContent=n===0?labelFor(input):(n===1?input.files[0].name:n+' files selected');
    }
    input.addEventListener('change',refresh);
    ['dragenter','dragover'].forEach(function(ev){box.addEventListener(ev,function(e){e.preventDefault();box.classList.add('drag');});});
    ['dragleave','drop'].forEach(function(ev){box.addEventListener(ev,function(e){e.preventDefault();box.classList.remove('drag');});});
    box.addEventListener('drop',function(e){
      if(!e.dataTransfer||!e.dataTransfer.files||!e.dataTransfer.files.length)return;
      try{ input.files=e.dataTransfer.files; input.dispatchEvent(new Event('change')); }catch(err){}
    });
  }
  function init(){ document.querySelectorAll('input[type=file][data-slot]').forEach(wrap); }
  if(document.readyState!=='loading')init(); else document.addEventListener('DOMContentLoaded',init);
  // HTMX-swapped edit forms load their file input after DOMContentLoaded.
  document.body.addEventListener('htmx:afterSwap',function(){ init(); });
})();
`;

/**
 * PREVIEW_JS: hover-zoom + hover-video + the shared media lightbox.
 *   - [data-hoverzoom="<img>"] / [data-hovervideo="<mp4>"] show a floating
 *     #hoverzoom near the element after 275ms (fine pointers only); a
 *     data-hovervideo inside a .pick plays IN PLACE instead (one video at a
 *     time globally);
 *   - clicking [data-lightbox] opens #media-lightbox with the media, wires the
 *     "Open original" link and the optional Edit → HTMX-load flow.
 */
const PREVIEW_JS = `
(function(){
  var fine=window.matchMedia&&window.matchMedia('(pointer:fine)').matches;
  var zoom=null,timer=null,inPlace=null;
  function box(){ if(!zoom){ zoom=document.createElement('div'); zoom.id='hoverzoom'; document.body.appendChild(zoom); } return zoom; }
  function place(el){
    var b=box(); var r=el.getBoundingClientRect(); var w=230;
    var left=r.right+12; if(left+w>window.innerWidth)left=r.left-w-12; if(left<8)left=8;
    b.style.left=left+'px';
    var bh=b.offsetHeight||300; var top=r.top; if(top+bh>window.innerHeight-8)top=window.innerHeight-8-bh; if(top<8)top=8;
    b.style.top=top+'px';
  }
  function clearFloat(){ if(zoom){zoom.style.display='none';zoom.innerHTML='';} }
  function clearInPlace(){ if(inPlace){ if(inPlace.parentNode)inPlace.parentNode.removeChild(inPlace); inPlace=null; } }
  function showFloating(el,kind,url){
    clearInPlace(); var b=box(); b.innerHTML='';
    if(kind==='video'){ var v=document.createElement('video'); v.muted=true;v.loop=true;v.playsInline=true;v.autoplay=true;v.preload='metadata';v.src=url; b.appendChild(v); }
    else { var im=document.createElement('img'); im.src=url; b.appendChild(im); }
    b.style.display='block'; place(el);
  }
  function playInPlace(pick,url){
    clearFloat(); clearInPlace();
    var v=document.createElement('video'); v.className='hoverplay'; v.muted=true;v.loop=true;v.playsInline=true;v.autoplay=true;v.src=url;
    pick.appendChild(v); inPlace=v;
    pick.addEventListener('mouseleave',function h(){ if(v.parentNode)v.parentNode.removeChild(v); if(inPlace===v)inPlace=null; pick.removeEventListener('mouseleave',h); });
  }
  function onEnter(e){
    if(!fine)return;
    var el=e.target.closest&&e.target.closest('[data-hoverzoom],[data-hovervideo]'); if(!el)return;
    if(timer)clearTimeout(timer);
    var vid=el.getAttribute('data-hovervideo'), img=el.getAttribute('data-hoverzoom');
    var pick=el.closest&&el.closest('.pick');
    timer=setTimeout(function(){
      if(vid&&pick)playInPlace(pick,vid);
      else if(vid)showFloating(el,'video',vid);
      else if(img)showFloating(el,'img',img);
    },275);
  }
  function onLeave(e){
    var el=e.target.closest&&e.target.closest('[data-hoverzoom],[data-hovervideo]'); if(!el)return;
    if(timer){clearTimeout(timer);timer=null;}
    clearFloat();
  }
  document.addEventListener('mouseenter',onEnter,true);
  document.addEventListener('mouseleave',onLeave,true);
  window.addEventListener('scroll',function(){ if(timer){clearTimeout(timer);timer=null;} clearFloat(); clearInPlace(); },true);
  document.addEventListener('click',function(){ if(timer){clearTimeout(timer);timer=null;} clearFloat(); },true);

  // ── Lightbox ──
  function openLightbox(el){
    var dlg=document.getElementById('media-lightbox'); if(!dlg)return;
    var url=el.getAttribute('data-lightbox');
    var type=el.getAttribute('data-lightbox-type')||'img';
    var title=el.getAttribute('data-lightbox-title')||'Preview';
    var openUrl=el.getAttribute('data-lightbox-open')||url;
    var t=document.getElementById('media-lightbox-t'); if(t)t.textContent=title;
    var body=document.getElementById('media-lightbox-body');
    if(body){
      body.innerHTML=''; var node;
      if(type==='video'){ node=document.createElement('video'); node.src=url; node.controls=true; node.autoplay=true; }
      else if(type==='audio'){ node=document.createElement('audio'); node.src=url; node.controls=true; }
      else { node=document.createElement('img'); node.src=url; }
      body.appendChild(node);
    }
    var openA=document.getElementById('media-lightbox-open'); if(openA)openA.href=openUrl;
    var editBtn=document.getElementById('media-lightbox-edit');
    var eDlg=el.getAttribute('data-lightbox-edit-dialog'), eGet=el.getAttribute('data-lightbox-edit-get'), eTarget=el.getAttribute('data-lightbox-edit-target');
    if(editBtn){
      if(eDlg&&eGet&&eTarget){
        editBtn.hidden=false;
        editBtn.onclick=function(){
          try{dlg.close('cancel');}catch(e){}
          var ed=document.getElementById(eDlg), tgt=document.getElementById(eTarget);
          if(tgt)tgt.innerHTML='<div class="modal-loading">Loading\\u2026</div>';
          if(ed&&ed.showModal&&!ed.open){try{ed.showModal();}catch(e){}}
          if(window.htmx)window.htmx.ajax('GET',eGet,{target:'#'+eTarget,swap:'innerHTML'});
        };
      } else { editBtn.hidden=true; editBtn.onclick=null; }
    }
    if(dlg.showModal&&!dlg.open){try{dlg.showModal();}catch(e){}}
  }
  document.addEventListener('click',function(e){
    var el=e.target.closest&&e.target.closest('[data-lightbox]');
    if(el){ e.preventDefault(); openLightbox(el); }
  });
  var mlb=document.getElementById('media-lightbox');
  if(mlb)mlb.addEventListener('close',function(){ var body=document.getElementById('media-lightbox-body'); if(body)body.innerHTML=''; });
})();
`;

/**
 * AUDIO_JS: single-player policy + table play toggles.
 *   - starting any <audio>/<video> pauses every other one (and the singleton);
 *   - [data-play-audio="<url>"] buttons toggle one shared Audio(): \\u25b6 / \\u23f8.
 */
const AUDIO_JS = `
(function(){
  var shared=null,curUrl=null,curBtn=null;
  function resetBtn(){ if(curBtn){curBtn.textContent='\\u25b6';curBtn.setAttribute('aria-pressed','false');curBtn=null;} }
  function pauseDom(except){ document.querySelectorAll('audio,video').forEach(function(m){ if(m!==except&&!m.paused){try{m.pause();}catch(e){}} }); }
  // Playback failure must never be silent: a \\u23f8 button with no sound reads
  // as "the button is broken". Reset the toggle and toast the real cause.
  function fail(){
    if(curUrl==null)return; // already handled (error + rejected play both fire)
    curUrl=null; resetBtn();
    if(window.cmsToast)window.cmsToast('Could not play this audio \\u2014 the file is missing or unsupported.',{danger:true});
  }
  document.addEventListener('play',function(e){
    var t=e.target;
    pauseDom(t);
    if(shared&&shared!==t&&!shared.paused){try{shared.pause();}catch(err){}}
    resetBtn();
  },true);
  document.addEventListener('click',function(e){
    var btn=e.target.closest&&e.target.closest('[data-play-audio]'); if(!btn)return;
    var url=btn.getAttribute('data-play-audio');
    if(!shared){
      shared=new Audio();
      shared.addEventListener('ended',function(){resetBtn();curUrl=null;});
      shared.addEventListener('error',fail);
    }
    if(curUrl!==url){
      pauseDom(); resetBtn();
      shared.src=url; curUrl=url;
      curBtn=btn; btn.textContent='\\u23f8'; btn.setAttribute('aria-pressed','true');
      shared.play().catch(fail);
      return;
    }
    if(shared.paused){ pauseDom(); shared.play().catch(fail); curBtn=btn; btn.textContent='\\u23f8'; btn.setAttribute('aria-pressed','true'); }
    else { shared.pause(); btn.textContent='\\u25b6'; btn.setAttribute('aria-pressed','false'); }
  });
})();
`;

/** COPY_JS: click [data-copy] copies the attribute value + a "Copied" toast. */
const COPY_JS = `
(function(){
  function fallback(text){
    try{ var ta=document.createElement('textarea'); ta.value=text; ta.style.position='fixed'; ta.style.opacity='0';
      document.body.appendChild(ta); ta.focus(); ta.select(); document.execCommand('copy'); document.body.removeChild(ta); }catch(e){}
  }
  function copy(text){
    if(navigator.clipboard&&navigator.clipboard.writeText)return navigator.clipboard.writeText(text).catch(function(){fallback(text);});
    fallback(text); return Promise.resolve();
  }
  document.addEventListener('click',function(e){
    var el=e.target.closest&&e.target.closest('[data-copy]'); if(!el)return;
    copy(el.getAttribute('data-copy'));
    if(window.cmsToast)window.cmsToast('Copied');
  });
})();
`;

/** ROWEDIT_JS: click anywhere on a tr[data-rowedit] (except on interactive
 *  descendants) triggers that row's Edit button. */
const ROWEDIT_JS = `
(function(){
  document.addEventListener('click',function(e){
    var row=e.target.closest&&e.target.closest('tr[data-rowedit]'); if(!row)return;
    if(e.target.closest('a,button,input,select,label,form,audio,video,[data-copy],[data-lightbox]'))return;
    var trigger=row.querySelector('.rowact [data-dialog-target]'); if(trigger)trigger.click();
  });
})();
`;

/** BUSY_JS: disable + mark busy the submit button(s) of ordinary forms on
 *  submit (uploaders own their own busy state). Re-enable on bfcache restore. */
const BUSY_JS = `
(function(){
  document.addEventListener('submit',function(e){
    var f=e.target;
    if(!f||!f.matches)return;
    if(f.matches('[data-upload-form],[data-rt-form],[data-rt-batch-form],[data-own-busy]'))return;
    f.querySelectorAll('[type=submit],button:not([type])').forEach(function(b){
      if(b.dataset.origText==null)b.dataset.origText=b.textContent;
      b.disabled=true; b.classList.add('busy'); b.textContent='Working\\u2026';
    });
  });
  window.addEventListener('pageshow',function(){
    document.querySelectorAll('button.busy').forEach(function(b){
      b.disabled=false; b.classList.remove('busy'); if(b.dataset.origText!=null)b.textContent=b.dataset.origText;
    });
  });
})();
`;

/** NAVDOT_JS: fetch /api/pending and decorate the submissions nav links; also
 *  surface HTMX network/server errors as a toast + inline note. */
const NAVDOT_JS = `
(function(){
  var base=(document.body.dataset.adminBase||'/admin');
  fetch(base+'/api/pending').then(function(r){return r.ok?r.json():null;}).then(function(data){
    if(!data)return;
    Object.keys(data).forEach(function(slug){
      var n=data[slug]; if(!n||n<=0)return;
      var link=document.querySelector('a[data-nav-sub="'+slug+'"]'); if(!link)return;
      var dot=document.createElement('span'); dot.className='navdot';
      var cnt=document.createElement('span'); cnt.className='navcount'; cnt.textContent=String(n);
      link.setAttribute('title',n+' pending submissions');
      link.appendChild(dot); link.appendChild(cnt);
    });
  }).catch(function(){});
  function onHxErr(e){
    if(window.cmsToast)window.cmsToast('Could not load \\u2014 network or server error.',{danger:true});
    var target=e.detail&&e.detail.target;
    if(target&&target.innerHTML!==undefined)target.innerHTML='<div class="note danger">Failed to load. Close this dialog and retry.</div>';
  }
  document.body.addEventListener('htmx:responseError',onHxErr);
  document.body.addEventListener('htmx:sendError',onHxErr);
})();
`;

/** LOGIN_JS: show/hide password toggle (the button relies on `required`, not
 *  a disabled-until-filled gate). */
const LOGIN_JS = `
(function(){
  var f=document.querySelector('[data-login-form]'); if(!f)return;
  var p=f.querySelector('[name=password]'); var tog=f.querySelector('[data-pw-toggle]');
  if(p&&tog){ tog.addEventListener('click',function(){
    var show=p.type==='password'; p.type=show?'text':'password';
    tog.textContent=show?'Hide':'Show'; tog.setAttribute('aria-label',show?'Hide password':'Show password');
  }); }
})();
`;

/** Top-level page chrome with the two-app grouped sidebar + shared scripts. */
export const Layout: FC<PropsWithChildren<{ title: string; active?: string }>> = (props) => {
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>{props.title} · HSR CMS</title>
        <link rel="icon" href={FAVICON_SVG} />
        <style dangerouslySetInnerHTML={{ __html: CSS }} />
        <script src={HTMX_SRC} defer></script>
      </head>
      <body data-admin-base={ADMIN_BASE}>
        <div class="topbar">
          <button type="button" class="hamburger" aria-label="Open navigation" data-nav-toggle>
            ☰
          </button>
          <span class="tb-brand">HSR CMS</span>
        </div>
        <div class="app">
          <aside class="side">
            <div class="brand">
              <span>HSR</span>
              <span class="bar" />
              <small>Unified CMS</small>
              <button type="button" class="side-close" aria-label="Close navigation" data-nav-close>
                ×
              </button>
            </div>
            <div class="navgroups">
              {navGroups().map((g) => (
                <div class="navgroup">
                  <div class="label">{g.label}</div>
                  <nav class="nav">
                    {g.items.map((n) => (
                      <a
                        href={n.href}
                        class={props.active === n.key ? "on" : ""}
                        {...(n.sub ? { "data-nav-sub": n.sub } : {})}
                      >
                        <span class="row" style="gap:10px">
                          <span class="ic">{n.ic}</span>
                          {n.label}
                        </span>
                      </a>
                    ))}
                  </nav>
                </div>
              ))}
            </div>
            <div class="foot">
              <form method="post" action={`${ADMIN_BASE}/logout`}>
                <button type="submit" class="logout">
                  Sign out
                </button>
              </form>
            </div>
          </aside>
          <main class="main">{props.children}</main>
        </div>
        <div class="scrim" data-nav-close></div>
        <div class="toast-stack" id="toast-stack"></div>

        <ConfirmDialog />
        <MediaLightbox />
        <script dangerouslySetInnerHTML={{ __html: UPLOAD_JS }} />
        <script dangerouslySetInnerHTML={{ __html: MODAL_JS }} />
        <script dangerouslySetInnerHTML={{ __html: NAV_JS }} />
        <script dangerouslySetInnerHTML={{ __html: LIST_JS }} />
        <script dangerouslySetInnerHTML={{ __html: SELECT_ALL_JS }} />
        <script dangerouslySetInnerHTML={{ __html: BULK_JS }} />
        <script dangerouslySetInnerHTML={{ __html: TOAST_JS }} />
        <script dangerouslySetInnerHTML={{ __html: DROPZONE_JS }} />
        <script dangerouslySetInnerHTML={{ __html: PREVIEW_JS }} />
        <script dangerouslySetInnerHTML={{ __html: AUDIO_JS }} />
        <script dangerouslySetInnerHTML={{ __html: COPY_JS }} />
        <script dangerouslySetInnerHTML={{ __html: ROWEDIT_JS }} />
        <script dangerouslySetInnerHTML={{ __html: BUSY_JS }} />
        <script dangerouslySetInnerHTML={{ __html: NAVDOT_JS }} />
      </body>
    </html>
  );
};

/** Page header with title, optional subtitle (subMono = mono type, e.g. content_version), and right-aligned actions. */
export const PageHead: FC<PropsWithChildren<{ title: string; sub?: string; subMono?: boolean }>> = (
  props,
) => (
  <div class="head">
    <div class="htext">
      <h1>{props.title}</h1>
      {props.sub ? <div class={props.subMono ? "sub sub-mono" : "sub"}>{props.sub}</div> : null}
    </div>
    <div class="actions">{props.children}</div>
  </div>
);

export const StatCard: FC<{ n: string | number; label: string; hint?: string }> = (props) => (
  <div class="card stat">
    <div class="n">{props.n}</div>
    <div class="l">{props.label}</div>
    {props.hint ? <div class="hint">{props.hint}</div> : null}
  </div>
);

/** Coloured status pill. */
export const Badge: FC<PropsWithChildren<{ kind: "ok" | "warn" | "muted" | "danger" | "info" }>> = (
  props,
) => <span class={`badge ${props.kind}`}>{props.children}</span>;

/**
 * Flash note rendered from a ?ok= / ?err= query param after a redirect.
 * Rendered hidden inline (data-flash, see CSS `.note[data-flash]`); TOAST_JS
 * moves it into the bottom-right toast stack on load and auto-dismisses it.
 */
export const Flash: FC<{ ok?: string | undefined; err?: string | undefined }> = (props) => {
  if (props.err) return <div class="note danger" data-flash>{props.err}</div>;
  if (props.ok) return <div class="note ok" data-flash>{props.ok}</div>;
  return null;
};

/** Accessible modal built on the native <dialog> element (see reference CMS). */
export const Modal: FC<PropsWithChildren<{ id: string; title: string; wide?: boolean }>> = (props) => (
  <dialog id={props.id} class={props.wide ? "modal wide" : "modal"} aria-labelledby={`${props.id}-t`}>
    <div class="dlg-head">
      <h2 id={`${props.id}-t`}>{props.title}</h2>
      <button type="button" class="dlg-x" aria-label="Close" data-dialog-close>
        ×
      </button>
    </div>
    <div class="dlg-body">{props.children}</div>
  </dialog>
);

/** The single shared destructive-confirmation dialog (driven by data-confirm). */
const ConfirmDialog: FC = () => (
  <dialog id="confirm-dlg" class="modal" aria-labelledby="confirm-t">
    <div class="dlg-head">
      <h2 id="confirm-t">Please confirm</h2>
      <button type="button" class="dlg-x" aria-label="Close" data-dialog-close>
        ×
      </button>
    </div>
    <div class="dlg-body">
      <p id="confirm-msg" class="muted" style="margin:0;color:var(--muted)">
        Are you sure?
      </p>
    </div>
    <div class="dlg-foot">
      <button type="button" class="btn sec" data-dialog-close autofocus>
        Cancel
      </button>
      <button type="button" class="btn danger" id="confirm-go">
        Confirm
      </button>
    </div>
  </dialog>
);

/**
 * The single shared media lightbox — a click on any [data-lightbox] element
 * fills and opens this (see PREVIEW_JS). Rendered once per page in Layout.
 */
const MediaLightbox: FC = () => (
  <dialog id="media-lightbox" class="modal lightbox" aria-labelledby="media-lightbox-t">
    <div class="dlg-head">
      <h2 id="media-lightbox-t">Preview</h2>
      <button type="button" class="dlg-x" aria-label="Close" data-dialog-close>
        ×
      </button>
    </div>
    <div class="lb-body" id="media-lightbox-body"></div>
    <div class="dlg-foot">
      <a class="btn sec" id="media-lightbox-open" target="_blank" rel="noopener">
        Open original ↗
      </a>
      <button type="button" class="btn" id="media-lightbox-edit" hidden>
        Edit
      </button>
    </div>
  </dialog>
);

/** Standalone login page (no sidebar). One login manages both apps. */
export const LoginView: FC<{ error?: string }> = (props) => (
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="robots" content="noindex, nofollow" />
      <title>Sign in · HSR CMS</title>
      <link rel="icon" href={FAVICON_SVG} />
      <style dangerouslySetInnerHTML={{ __html: CSS }} />
    </head>
    <body>
      <div class="login">
        <form class="box" method="post" action={`${ADMIN_BASE}/login`} data-login-form>
          <h1>HSR CMS</h1>
          <div class="bar" />
          <div class="microlabel">Unified CMS</div>
          {props.error ? <div class="note danger">{props.error}</div> : null}
          <label class="field">
            <span class="lab">Username</span>
            <input name="username" type="text" autocomplete="username" autofocus required />
          </label>
          <label class="field">
            <span class="lab">Password</span>
            <span style="position:relative;display:block">
              <input name="password" type="password" autocomplete="current-password" required />
              <button type="button" class="pw-toggle" data-pw-toggle aria-label="Show password">
                Show
              </button>
            </span>
          </label>
          <button type="submit" class="btn" data-login-submit>
            Sign in
          </button>
        </form>
      </div>
      <script dangerouslySetInnerHTML={{ __html: LOGIN_JS }} />
    </body>
  </html>
);

/** Href prefix helper — every app page URL lives under /admin/{slug}/…. */
export function appPath(app: AppDef, path: string): string {
  return `${ADMIN_BASE}/${app.slug}${path}`;
}
