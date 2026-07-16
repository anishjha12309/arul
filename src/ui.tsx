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

const HTMX_SRC = "https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js";

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
td .thumb{width:36px;height:36px;border-radius:var(--radius-btn);object-fit:cover;background:var(--input);
  border:1px solid var(--hairline);display:block}
td .filemark{width:36px;height:36px;border-radius:var(--radius-btn);display:grid;place-items:center;
  background:var(--glass-2);border:1px solid var(--hairline);color:var(--faint);font-size:15px}
.rowact{display:flex;gap:6px;align-items:center;opacity:.5;transition:opacity .12s}
tbody tr:hover .rowact,tbody tr:focus-within .rowact{opacity:1}
.rowact form{margin:0}

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

.microlabel-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;
  letter-spacing:.06em;color:var(--muted);margin-bottom:10px}

/* ── Transfer picker grid (Arul category transfer) + wallpapers grid view ── */
.pickgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:12px;margin:16px 0}
/* Wallpapers grid view (data-grid) uses larger cards than the transfer picker. */
.pickgrid[data-grid]{grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}
.pick{position:relative;display:block;cursor:pointer;border-radius:var(--radius-sm);overflow:hidden;
  border:1px solid var(--hairline);background:var(--glass);transition:border-color .12s,box-shadow .12s;
  aspect-ratio:9/16}
.pick img{display:block;width:100%;height:100%;aspect-ratio:9/16;object-fit:cover;background:var(--input)}
.pick .pick-live{position:absolute;top:8px;left:8px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  text-transform:uppercase;background:rgba(16,14,16,.75);color:var(--ink);border:1px solid var(--hairline-strong);
  border-radius:var(--radius-pill);font-size:10px;font-weight:700;padding:2px 8px;letter-spacing:.04em}
.pick .pick-title{position:absolute;left:0;right:0;bottom:0;padding:22px 8px 6px;font-size:12px;
  color:#fff;background:linear-gradient(transparent,rgba(10,8,8,.85));white-space:nowrap;
  overflow:hidden;text-overflow:ellipsis;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.pick input[type=checkbox]{appearance:none;-webkit-appearance:none;position:absolute;top:8px;right:8px;
  width:16px;height:16px;border-radius:var(--radius-check);border:1px solid rgba(255,255,255,.25);
  background:transparent;cursor:pointer;opacity:.45;transition:opacity .12s,background .12s,border-color .12s}
.pick:hover input[type=checkbox],.pick input[type=checkbox]:checked{opacity:1}
.pick input[type=checkbox]:checked{background:var(--accent);border-color:var(--accent)}
.pick input[type=checkbox]:checked::after{content:"";position:absolute;left:4px;top:1px;width:4px;height:8px;
  border:solid var(--accent-ink);border-width:0 2px 2px 0;transform:rotate(45deg)}
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
input.rowsel[type=checkbox]{appearance:none;-webkit-appearance:none;width:16px;height:16px;
  border:1px solid rgba(255,255,255,.25);border-radius:var(--radius-check);cursor:pointer;position:relative;
  background:transparent;vertical-align:middle;transition:background .12s,border-color .12s;flex:0 0 auto}
input.rowsel[type=checkbox]:checked{background:var(--accent);border-color:var(--accent)}
input.rowsel[type=checkbox]:checked::after{content:"";position:absolute;left:4px;top:1px;width:4px;height:8px;
  border:solid var(--accent-ink);border-width:0 2px 2px 0;transform:rotate(45deg)}
td .idcode{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;color:rgba(240,235,228,.65)}
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
.gcard.draft img{opacity:.6}
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
    items.push({ key: `${app.slug}:submissions`, href: appPath(app, "/submissions"), label: "Submissions", ic: "⇪" });
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
    if(x){ var dd=x.closest('dialog'); if(dd) dd.close('cancel'); return; }
  });
  document.addEventListener('click',function(e){
    if(e.target.tagName==='DIALOG'&&e.target.open) e.target.close('cancel');
  });
  var pending=null;
  document.addEventListener('submit',function(e){
    var f=e.target;
    if(f.getAttribute&&f.getAttribute('data-confirm')!=null&&f.getAttribute('data-confirmed')!=='1'){
      e.preventDefault(); e.stopImmediatePropagation();
      pending=f;
      var msg=document.getElementById('confirm-msg'); if(msg) msg.textContent=f.getAttribute('data-confirm')||'Are you sure?';
      open(document.getElementById('confirm-dlg'));
    }
  },true);
  var go=document.getElementById('confirm-go');
  if(go) go.addEventListener('click',function(){
    var dlg=document.getElementById('confirm-dlg'); if(dlg) dlg.close('confirm');
    if(pending){
      pending.setAttribute('data-confirmed','1');
      if(pending.requestSubmit) pending.requestSubmit(); else pending.submit();
      pending=null;
    }
  });
})();
`;

const LIST_JS = `
(function(){
  function rows(v){ var tb=v.querySelector('tbody'); return tb?Array.prototype.slice.call(tb.querySelectorAll('tr')):[]; }
  function cellText(r,i){ var c=r.children[i]; return c?(c.textContent||'').trim().toLowerCase():''; }
  function searchText(r){ var s=''; for(var i=0;i<r.children.length;i++){ var c=r.children[i]; if(c.querySelector&&c.querySelector('.rowact'))continue; s+=' '+(c.textContent||''); } return s.toLowerCase(); }
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
    function nav(label,target,disabled){
      var b=document.createElement('button'); b.type='button'; b.className='btn sec sm'; b.textContent=label;
      if(disabled){b.disabled=true;} else {b.addEventListener('click',function(){v.setAttribute('data-page',String(target));apply(v);});}
      pager.appendChild(b);
    }
    nav('Prev',page-1,page<=1);
    var cur=document.createElement('span'); cur.textContent='Page '+page+' / '+pages; cur.style.padding='0 4px';
    pager.appendChild(cur);
    nav('Next',page+1,page>=pages);
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
  function apply(v){
    var si=v.querySelector('[data-search]'); var q=si?(si.value||'').trim().toLowerCase():'';
    var wrap=si&&si.closest?si.closest('.searchwrap'):null;
    if(wrap) wrap.classList.toggle('has-value',q.length>0);
    var filters=Array.prototype.slice.call(v.querySelectorAll('[data-filter]'));
    var all=rows(v); var visible=[];
    all.forEach(function(r){
      var ok=true;
      if(q && searchText(r).indexOf(q)<0) ok=false;
      if(ok) for(var i=0;i<filters.length;i++){ var f=filters[i]; var val=f.value;
        if(val){ var col=parseInt(f.getAttribute('data-filter'),10); if(cellText(r,col).indexOf(val.toLowerCase())<0){ok=false;break;} } }
      r.classList.toggle('filtered-out',!ok); if(ok)visible.push(r);
    });
    paginate(v,visible);
    syncGrid(v);
    var empty=v.querySelector('[data-empty-filtered]');
    if(empty) empty.style.display=(all.length>0&&visible.length===0)?'block':'none';
  }
  function sortBy(v,th){
    var tb=v.querySelector('tbody'); if(!tb)return;
    var idx=Array.prototype.indexOf.call(th.parentNode.children,th);
    var dir=th.getAttribute('data-dir')==='asc'?'desc':'asc';
    Array.prototype.slice.call(v.querySelectorAll('th.sortable')).forEach(function(o){o.removeAttribute('data-dir');});
    th.setAttribute('data-dir',dir);
    var num=th.getAttribute('data-type')==='num';
    var rs=rows(v).sort(function(a,b){
      var x=cellText(a,idx),y=cellText(b,idx);
      if(num){ x=parseFloat(x)||0; y=parseFloat(y)||0; return dir==='asc'?x-y:y-x; }
      return dir==='asc'?x.localeCompare(y):y.localeCompare(x);
    });
    rs.forEach(function(r){tb.appendChild(r);});
    apply(v);
  }
  function wire(v){
    var si=v.querySelector('[data-search]');
    if(si){ var t; si.addEventListener('input',function(){clearTimeout(t);t=setTimeout(function(){v.setAttribute('data-page','1');apply(v);},120);}); }
    var sc=v.querySelector('[data-search-clear]');
    if(sc&&si){ sc.addEventListener('click',function(){si.value='';si.focus();v.setAttribute('data-page','1');apply(v);}); }
    v.querySelectorAll('[data-filter]').forEach(function(f){f.addEventListener('change',function(){v.setAttribute('data-page','1');apply(v);});});
    var ps=v.querySelector('[data-page-size]'); if(ps)ps.addEventListener('change',function(){v.setAttribute('data-page','1');apply(v);});
    v.querySelectorAll('th.sortable').forEach(function(th){th.addEventListener('click',function(){sortBy(v,th);});});
    apply(v);
  }
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
  async function uploadOne(form,input,f,status){
    var ct=f.type||infer(f.name);
    var probe=null;
    if(ct==='video/mp4')probe=await probeVideo(f);
    else if(ct.indexOf('image/')===0)probe=await probeImage(f);
    var warn=dimWarning(ct,probe);
    if(warn&&!confirm(f.name+'\\n\\n'+warn+'\\n\\nUpload anyway?'))throw new Error('Upload cancelled: '+f.name);
    if(status) status.textContent='Uploading '+f.name+'\\u2026 ('+Math.round(f.size/1024)+' KB)';
    var catEl=form.querySelector('[name="category"]');var cat=catEl?catEl.value:'';
    var pres=await fetch(form.dataset.presign,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({kind:form.dataset.kind,slot:input.dataset.slot,contentType:ct,size:f.size,category:cat})});
    var pj=await pres.json().catch(function(){return{};});
    if(!pres.ok) throw new Error((pj.error&&pj.error.message)||('upload-url failed ('+pres.status+')'));
    var put=await fetch(pj.uploadUrl,{method:'PUT',headers:{'content-type':ct},body:f});
    if(!put.ok) throw new Error('R2 upload failed ('+put.status+')');
    // Best-effort thumb PUT: a failure only means the admin list shows \\u25b6.
    if(pj.thumbUploadUrl&&probe&&probe.thumb){
      try{await fetch(pj.thumbUploadUrl,{method:'PUT',headers:{'content-type':'image/jpeg'},body:probe.thumb});}catch(e){}
    }
    return {key:pj.key,mime:ct,id:pj.id};
  }
  async function run(form){
    var status=form.querySelector('[data-upload-status]');
    var inputs=form.querySelectorAll('input[type=file][data-slot]');
    for(var i=0;i<inputs.length;i++){
      var input=inputs[i];var files=input.files?Array.prototype.slice.call(input.files):[];
      if(!files.length){ if(input.hasAttribute('data-required')) throw new Error('Select a file for "'+input.dataset.slot+'"'); else continue; }
      var multi=form.querySelector('[name="items_json"]');
      if(files.length>1){
        if(!multi) throw new Error('This form accepts a single file');
        var items=[];
        for(var j=0;j<files.length;j++){
          if(status)status.textContent='File '+(j+1)+' of '+files.length+'\\u2026';
          items.push(await uploadOne(form,input,files[j],status));
        }
        multi.value=JSON.stringify(items);
        set(form,'key_'+input.dataset.slot,'');set(form,'mime_'+input.dataset.slot,'');set(form,'id_'+input.dataset.slot,'');
      }else{
        var r=await uploadOne(form,input,files[0],status);
        set(form,'key_'+input.dataset.slot,r.key);set(form,'mime_'+input.dataset.slot,r.mime);set(form,'id_'+input.dataset.slot,r.id);
        if(multi)multi.value='';
      }
    }
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
    run(form).then(function(){form.dataset.uploaded='1';if(status)status.textContent='Saving\\u2026';if(btn)btn.textContent='Saving\\u2026';form.submit();})
    .catch(function(err){if(status)status.textContent='';if(btn){btn.disabled=false;btn.classList.remove('busy');btn.textContent=origLabel;}
      if(box){box.style.display='block';box.textContent=err.message;}else{alert(err.message);}});
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
  var VKEY='cms-list-view';
  function scope(el){return el.closest&&el.closest('[data-listview]');}
  function update(v){
    var seen={},ids=[];
    v.querySelectorAll('[data-bulk-id]').forEach(function(b){
      var id=b.getAttribute('data-bulk-id');
      if(b.checked&&!seen[id]){seen[id]=1;ids.push(id);}
    });
    var bar=v.querySelector('[data-bulk-bar]'); if(!bar)return;
    bar.style.display=ids.length?'flex':'none';
    var lab=bar.querySelector('[data-bulk-count]'); if(lab)lab.textContent=ids.length+' selected';
    var inp=bar.querySelector('[name="ids"]'); if(inp)inp.value=ids.join(',');
  }
  document.addEventListener('change',function(e){
    var t=e.target;
    if(t.matches&&t.matches('[data-bulk-id]')){
      var v=scope(t); if(!v)return;
      v.querySelectorAll('[data-bulk-id="'+t.getAttribute('data-bulk-id')+'"]').forEach(function(x){x.checked=t.checked;});
      if(!t.checked){var all=v.querySelector('[data-bulk-all]');if(all)all.checked=false;}
      update(v); return;
    }
    if(t.matches&&t.matches('[data-bulk-all]')){
      var v2=scope(t); if(!v2)return;
      v2.querySelectorAll('tbody tr').forEach(function(r){
        if(r.classList.contains('filtered-out'))return;
        var cb=r.querySelector('[data-bulk-id]'); if(!cb)return;
        v2.querySelectorAll('[data-bulk-id="'+cb.getAttribute('data-bulk-id')+'"]').forEach(function(x){x.checked=t.checked;});
      });
      update(v2);
    }
  });
  document.addEventListener('click',function(e){
    var btn=e.target.closest&&e.target.closest('[data-bulk-act]');
    if(btn){
      var form=btn.closest('form'); if(!form)return;
      var act=btn.getAttribute('data-bulk-act');
      var n=(form.querySelector('[name="ids"]').value||'').split(',').filter(Boolean).length;
      if(!n)return;
      if(act==='delete'&&!confirm('Delete '+n+' wallpaper'+(n===1?'':'s')+'? This removes them from the app.'))return;
      form.querySelector('[name="bulk_action"]').value=act;
      form.submit();
      return;
    }
    var vb=e.target.closest&&e.target.closest('[data-view]');
    if(vb){ var v=scope(vb); if(v){ setView(v,vb.getAttribute('data-view')); try{localStorage.setItem(VKEY,vb.getAttribute('data-view'));}catch(err){} } }
  });
  function setView(v,mode){
    var g=v.querySelector('[data-grid]'); var tw=v.querySelector('.tablewrap'); if(!g||!tw)return;
    var grid=mode==='grid';
    tw.style.display=grid?'none':''; g.style.display=grid?'':'none';
    v.querySelectorAll('[data-view]').forEach(function(b){b.classList.toggle('on',b.getAttribute('data-view')===mode);});
  }
  function init(){
    document.querySelectorAll('[data-listview]').forEach(function(v){
      if(v.querySelector('[data-grid]')){
        var m='table'; try{m=localStorage.getItem(VKEY)||'table';}catch(err){}
        setView(v,m);
      }
      update(v);
    });
  }
  if(document.readyState!=='loading')init(); else document.addEventListener('DOMContentLoaded',init);
})();
`;

/**
 * TOAST_JS: turns a hidden ?ok=/?err= Flash note (rendered server-side with
 * data-flash) into a bottom-right toast — 200ms slide-in, auto-dismiss 3.2s,
 * ghost ×. No client-side toast bus: this is the ONLY toast source (see
 * README §Interactions — scope note: Undo-on-delete is explicitly OUT of
 * scope, so toasts never carry an Undo action here).
 */
const TOAST_JS = `
(function(){
  function show(msg,danger){
    var stack=document.getElementById('toast-stack'); if(!stack)return;
    var t=document.createElement('div'); t.className='toast'+(danger?' danger':'');
    var m=document.createElement('span'); m.className='toast-msg'; m.textContent=msg;
    var x=document.createElement('button'); x.type='button'; x.className='toast-x'; x.setAttribute('aria-label','Dismiss'); x.textContent='\\u00d7';
    function dismiss(){ if(t.parentNode) t.parentNode.removeChild(t); }
    x.addEventListener('click',dismiss);
    t.appendChild(m); t.appendChild(x); stack.appendChild(t);
    setTimeout(dismiss,3200);
  }
  function init(){
    document.querySelectorAll('[data-flash]').forEach(function(el){
      var danger=el.classList.contains('danger');
      show(el.textContent,danger);
      el.parentNode&&el.parentNode.removeChild(el);
    });
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

/** LOGIN_JS: keep the submit button disabled until both fields are filled. */
const LOGIN_JS = `
(function(){
  var f=document.querySelector('[data-login-form]'); if(!f)return;
  var u=f.querySelector('[name=username]'); var p=f.querySelector('[name=password]');
  var btn=f.querySelector('[data-login-submit]');
  function sync(){ btn.disabled=!(u.value.trim()&&p.value); }
  [u,p].forEach(function(el){ el.addEventListener('input',sync); });
  sync();
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
        <style dangerouslySetInnerHTML={{ __html: CSS }} />
        <script src={HTMX_SRC} defer></script>
      </head>
      <body>
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
                      <a href={n.href} class={props.active === n.key ? "on" : ""}>
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
        <script dangerouslySetInnerHTML={{ __html: UPLOAD_JS }} />
        <script dangerouslySetInnerHTML={{ __html: MODAL_JS }} />
        <script dangerouslySetInnerHTML={{ __html: NAV_JS }} />
        <script dangerouslySetInnerHTML={{ __html: LIST_JS }} />
        <script dangerouslySetInnerHTML={{ __html: SELECT_ALL_JS }} />
        <script dangerouslySetInnerHTML={{ __html: BULK_JS }} />
        <script dangerouslySetInnerHTML={{ __html: TOAST_JS }} />
        <script dangerouslySetInnerHTML={{ __html: DROPZONE_JS }} />
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

/** Standalone login page (no sidebar). One login manages both apps. */
export const LoginView: FC<{ error?: string }> = (props) => (
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="robots" content="noindex, nofollow" />
      <title>Sign in · HSR CMS</title>
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
            <input name="password" type="password" autocomplete="current-password" required />
          </label>
          <button type="submit" class="btn" data-login-submit disabled>
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
