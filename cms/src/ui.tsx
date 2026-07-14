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
   HSR CMS — Apple "Liquid Glass" design system (DARK ONLY).
   Frosted translucent surfaces (backdrop-filter), hairline borders, soft
   layered shadows, SF system type, Apple system-colour accents.
   ════════════════════════════════════════════════════════════════════════ */
:root{
  color-scheme:dark;

  /* ── Apple system accent (blue) ── */
  --accent:#0a84ff;          /* primary fill / active */
  --accent-h:#409cff;        /* hover */
  --accent-d:#0a6fd6;        /* pressed */
  --accent-ink:#ffffff;      /* text on accent fill */
  --accent-text:#5ab0ff;     /* accent as link/text */
  --accent-soft:rgba(10,132,255,.22);

  /* ── Brand tie-in ── */
  --brand:#d4a017;           /* HSR gold — login accent bar */

  /* ── Ink ── */
  --ink:#f5f5f7;             /* primary text */
  --muted:#a1a1a6;           /* secondary text */
  --faint:#86868b;

  /* ── Glass surfaces (translucent; sit over the gradient backdrop) ── */
  --glass:rgba(28,28,32,.58);           /* cards / table / sidebar */
  --glass-2:rgba(44,44,50,.66);         /* elevated / hover / modal */
  --glass-thin:rgba(28,28,32,.5);       /* topbar / chips */
  --input:rgba(255,255,255,.07);        /* form inputs */
  --hairline:rgba(255,255,255,.1);      /* dividers */
  --hairline-strong:rgba(255,255,255,.16); /* control borders */
  --edge:rgba(255,255,255,.14);         /* bright top edge on glass */

  /* ── Semantics (Apple system colours; -bg = soft tint) ── */
  --ok:#34c759;     --ok-bg:rgba(52,199,89,.18);
  --warn:#ff9f0a;   --warn-bg:rgba(255,159,10,.18);
  --danger:#ff453a; --danger-bg:rgba(255,69,58,.2);
  --info:#5ab0ff;   --info-bg:rgba(10,132,255,.2);

  --backdrop:rgba(0,0,0,.55);

  /* ── Shape + shadow (soft, layered, Apple-ish) ── */
  --radius:20px;
  --radius-sm:12px;
  --radius-pill:999px;
  --blur:saturate(180%) blur(22px);
  --blur-strong:saturate(190%) blur(40px);
  --shadow-card:0 1px 1px rgba(0,0,0,.3),0 10px 30px rgba(0,0,0,.4);
  --shadow-pop:0 24px 80px rgba(0,0,0,.6),0 2px 10px rgba(0,0,0,.5);

  --sidebar-w:256px;
}
*{box-sizing:border-box}
html,body{margin:0}
body{font:15px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  color:var(--ink);-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
  min-height:100vh;background:#0a0a0c}
/* Fixed decorative gradient wash that the glass surfaces blur. */
body::before{content:"";position:fixed;inset:0;z-index:-1;pointer-events:none;
  background:
    radial-gradient(50rem 38rem at 12% -8%, rgba(10,132,255,.26), transparent 60%),
    radial-gradient(46rem 40rem at 102% 4%, rgba(52,199,89,.16), transparent 58%),
    radial-gradient(60rem 50rem at 78% 110%, rgba(175,82,222,.18), transparent 60%),
    linear-gradient(180deg,#0a0a0c,#101015);}
a{color:var(--accent-text);text-decoration:none}
a:hover{color:var(--accent-h)}
:focus-visible{outline:2.5px solid var(--accent);outline-offset:2px;border-radius:6px}
::selection{background:rgba(10,132,255,.36);color:#fff}
html{scrollbar-color:rgba(255,255,255,.22) transparent;scrollbar-width:thin}
::-webkit-scrollbar{width:12px;height:12px}
::-webkit-scrollbar-thumb{background:rgba(255,255,255,.16);border-radius:9px;border:3px solid transparent;background-clip:content-box}
::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,.3);background-clip:content-box}
::-webkit-scrollbar-track{background:transparent}

/* ── App shell ── */
.app{display:grid;grid-template-columns:var(--sidebar-w) 1fr;min-height:100vh}
.side{position:sticky;top:0;height:100vh;overflow-y:auto;display:flex;flex-direction:column;
  background:var(--glass);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur);
  border-right:1px solid var(--hairline);z-index:30}
.side .brand{display:flex;align-items:center;gap:12px;height:66px;padding:0 20px;flex:0 0 auto;
  font-weight:650;font-size:18px;color:var(--ink);letter-spacing:-.01em;
  border-bottom:1px solid var(--hairline)}
.side .brand small{display:block;font-weight:500;font-size:10px;letter-spacing:.8px;
  text-transform:uppercase;color:var(--faint);margin-top:1px}
.navgroups{flex:1;display:flex;flex-direction:column;gap:22px;padding:20px 0}
.navgroup{display:flex;flex-direction:column;gap:2px}
.navgroup .label{font-size:11px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;
  color:var(--faint);padding:0 24px;margin-bottom:7px}
.nav a{display:flex;align-items:center;gap:10px;justify-content:space-between;
  height:40px;margin:0 12px;padding:0 12px;border-radius:12px;
  color:var(--ink);font-weight:500;font-size:14.5px;transition:background .15s,color .15s}
.nav a:hover{background:var(--glass-2);color:var(--ink)}
.nav a.on{background:var(--accent-soft);color:var(--accent-text);font-weight:600;
  box-shadow:inset 0 0 0 1px rgba(10,132,255,.22)}
.nav a .ic{width:20px;text-align:center;opacity:.8;flex:0 0 auto;font-size:15px}
.nav a.on .ic{opacity:1}
.nav a .count{background:var(--accent);color:var(--accent-ink);font-size:11px;font-weight:700;
  border-radius:var(--radius-pill);padding:1px 8px;min-width:20px;text-align:center}
.side .foot{border-top:1px solid var(--hairline);padding:14px}
.side .foot form{margin:0}
.logout{width:100%;background:var(--glass-thin);border:1px solid var(--hairline-strong);
  color:var(--ink);padding:10px;border-radius:12px;cursor:pointer;font:inherit;font-weight:600;
  transition:background .15s}
.logout:hover{background:var(--glass-2)}
.main{min-width:0;padding:30px 36px 72px}

/* ── Mobile top bar + drawer scrim (hidden on desktop) ── */
.topbar{display:none}
.scrim{display:none}

/* ── Page header ── */
.head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:26px}
.head .htext h1{font-size:30px;line-height:1.15;margin:0;font-weight:700;letter-spacing:-.02em;
  color:var(--ink);word-break:break-word}
.head .sub{color:var(--muted);font-size:14.5px;margin-top:7px}
.head .actions{display:flex;gap:10px;align-items:center;margin-left:auto;flex-wrap:wrap}

/* ── Cards + grid ── */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:18px}
.card{background:var(--glass);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur);
  border:1px solid var(--hairline);border-radius:var(--radius);padding:22px;
  box-shadow:var(--shadow-card);position:relative}
.card::before{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;
  border-top:1px solid var(--edge);-webkit-mask:linear-gradient(180deg,#000,transparent 40%);
  mask:linear-gradient(180deg,#000,transparent 40%)}
.card .card-title{font-weight:650;font-size:15.5px;color:var(--ink);letter-spacing:-.01em}
.card .card-desc{font-size:13px;color:var(--muted);margin-top:4px}
.stat{display:flex;flex-direction:column;gap:7px}
.stat .n{font-size:36px;font-weight:700;line-height:1;color:var(--ink);letter-spacing:-.02em}
.stat .l{color:var(--muted);font-size:14px;font-weight:500}
.stat .hint{font-size:12.5px;color:var(--faint);margin-top:2px}

/* ── Buttons ── */
.btn{display:inline-flex;align-items:center;gap:7px;border:0;cursor:pointer;font:inherit;font-weight:600;
  border-radius:var(--radius-pill);padding:10px 18px;line-height:1.1;letter-spacing:-.01em;
  background:linear-gradient(180deg,var(--accent-h),var(--accent));color:var(--accent-ink);
  box-shadow:0 2px 8px rgba(10,132,255,.32),inset 0 1px 0 rgba(255,255,255,.3);
  transition:filter .15s,transform .06s,box-shadow .15s}
.btn:hover{filter:brightness(1.05);color:var(--accent-ink)}
.btn:active{transform:translateY(1px);background:var(--accent-d)}
.btn.sec{background:var(--glass-2);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur);
  color:var(--ink);border:1px solid var(--hairline-strong);box-shadow:var(--shadow-card)}
.btn.sec:hover{background:var(--glass);color:var(--ink);filter:none}
.btn.danger{background:linear-gradient(180deg,#ff6961,var(--danger));color:#fff;
  box-shadow:0 2px 8px rgba(215,0,21,.32),inset 0 1px 0 rgba(255,255,255,.25)}
.btn.danger:hover{filter:brightness(1.06)}
.btn.sm{padding:6px 13px;font-size:13px}
.btn[disabled]{opacity:.5;cursor:not-allowed;filter:none;box-shadow:none}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}

/* ── Badges ── */
.badge{display:inline-flex;align-items:center;gap:6px;padding:4px 11px;border-radius:var(--radius-pill);
  font-size:12px;font-weight:600;line-height:1.4;border:1px solid transparent}
.badge::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
.badge.ok{background:var(--ok-bg);color:var(--ok);border-color:rgba(52,199,89,.3)}
.badge.warn{background:var(--warn-bg);color:var(--warn);border-color:rgba(255,159,10,.3)}
.badge.muted{background:var(--glass-2);color:var(--muted);border-color:var(--hairline)}
.badge.danger{background:var(--danger-bg);color:var(--danger);border-color:rgba(255,59,48,.3)}
.badge.info{background:var(--info-bg);color:var(--info);border-color:rgba(10,132,255,.3)}

/* ── Tables ── */
.tablewrap{overflow-x:auto;border:1px solid var(--hairline);border-radius:var(--radius);
  background:var(--glass);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur);
  box-shadow:var(--shadow-card)}
table{width:100%;border-collapse:collapse;font-size:14px}
thead th{background:transparent;color:var(--faint);font-size:11px;font-weight:700;
  text-transform:uppercase;letter-spacing:.5px;text-align:left;padding:14px 18px;
  border-bottom:1px solid var(--hairline);white-space:nowrap}
tbody td{padding:13px 18px;border-bottom:1px solid var(--hairline);vertical-align:middle;color:var(--ink)}
tbody tr:last-child td{border-bottom:0}
tbody tr{transition:background .12s}
tbody tr:hover{background:var(--glass-2)}
td .coltitle strong,td strong{color:var(--ink);font-weight:600}
td .thumb{width:48px;height:48px;border-radius:10px;object-fit:cover;background:var(--input);
  border:1px solid var(--hairline);display:block}
td .filemark{width:48px;height:48px;border-radius:10px;display:grid;place-items:center;
  background:var(--accent-soft);border:1px solid var(--hairline);color:var(--accent-text);font-size:19px}
.rowact{display:flex;gap:8px;align-items:center;opacity:.7;transition:opacity .12s}
tbody tr:hover .rowact{opacity:1}
.rowact form{margin:0}

/* ── List toolbar / search / sort / pagination (client-side) ── */
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:16px}
.toolbar .search{flex:1;min-width:200px;max-width:360px}
.toolbar .grow{flex:1}
.toolbar select{width:auto;min-width:140px}
th.sortable{cursor:pointer;user-select:none}
th.sortable:hover{color:var(--ink)}
th.sortable .arrow{opacity:.35;margin-left:6px;font-size:10px}
th.sortable[data-dir="asc"] .arrow{opacity:1}
th.sortable[data-dir="asc"] .arrow::after{content:"\\2191"}
th.sortable[data-dir="desc"] .arrow{opacity:1}
th.sortable[data-dir="desc"] .arrow::after{content:"\\2193"}
th.sortable .arrow::after{content:"\\2195"}
tr.filtered-out,tr.paged-out{display:none}
.pager{display:flex;gap:6px;align-items:center;justify-content:flex-end;margin-top:16px;color:var(--muted);font-size:13px}
.pager .btn.sm{min-width:36px;justify-content:center}
.pager .pginfo{margin-right:auto;color:var(--muted)}

/* ── Forms ── */
.form{max-width:620px}
.field{display:block;margin:0 0 18px}
.field .lab{display:block;font-weight:600;font-size:13px;margin:0 0 7px;color:var(--ink)}
.field .hint{display:block;font-size:12.5px;color:var(--muted);margin-top:6px}
label{font-weight:600;font-size:13px;color:var(--ink)}
input[type=text],input[type=number],input[type=password],input[type=email],select,textarea{
  width:100%;padding:11px 14px;background:var(--input);color:var(--ink);
  border:1px solid var(--hairline-strong);border-radius:var(--radius-sm);font:inherit;
  -webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);transition:border-color .15s,box-shadow .15s}
textarea{resize:vertical}
textarea.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
/* Native <select> popups paint from the control's background-color, so give it
   an opaque dark fill (translucent glass would render a light popup) + a custom
   chevron, and theme the option list to match the dark glass UI. */
select{appearance:none;-webkit-appearance:none;cursor:pointer;padding-right:38px;
  background-color:#1c1c22;-webkit-backdrop-filter:none;backdrop-filter:none;
  background-repeat:no-repeat;background-position:right 13px center;
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='8' viewBox='0 0 12 8'%3E%3Cpath d='M1 1.5 6 6.5 11 1.5' stroke='%23a1a1a6' stroke-width='1.8' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E")}
option,optgroup{background-color:#1c1c22;color:var(--ink)}
input::placeholder,textarea::placeholder{color:var(--faint)}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent);
  box-shadow:0 0 0 3.5px var(--accent-soft)}
input[type=file]{width:100%;padding:11px;background:var(--input);border:1.5px dashed var(--hairline-strong);
  border-radius:var(--radius-sm);color:var(--muted)}
input[type=file]::file-selector-button{font:inherit;font-weight:600;cursor:pointer;margin-right:12px;
  padding:7px 14px;border-radius:var(--radius-pill);border:1px solid var(--hairline-strong);
  background:var(--glass-2);color:var(--ink);transition:background .15s}
input[type=file]::file-selector-button:hover{background:var(--glass)}
.check{display:flex;align-items:flex-start;gap:10px;margin:16px 0}
.check input{width:auto;margin-top:3px;accent-color:var(--accent)}
.check label,.check span{margin:0;font-weight:500;color:var(--ink)}
.formgrid{display:grid;grid-template-columns:1fr 1fr;gap:0 18px}
@media(max-width:560px){.formgrid{grid-template-columns:1fr}}

/* ── Notes / flash ── */
.note{padding:13px 16px;border-radius:14px;font-size:14px;margin:0 0 20px;display:flex;gap:10px;
  align-items:flex-start;border:1px solid transparent;-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px)}
.note::before{font-weight:800;line-height:1.4}
.note.ok{background:var(--ok-bg);color:var(--ok);border-color:rgba(52,199,89,.35)}
.note.ok::before{content:"\\2713"}
.note.warn{background:var(--warn-bg);color:var(--warn);border-color:rgba(255,159,10,.35)}
.note.warn::before{content:"!"}
.note.danger{background:var(--danger-bg);color:var(--danger);border-color:rgba(255,59,48,.35)}
.note.danger::before{content:"!"}
.note.info{background:var(--info-bg);color:var(--info);border-color:rgba(10,132,255,.35)}
.note.muted{background:var(--glass-2);color:var(--muted);border-color:var(--hairline)}

/* ── Empty state ── */
.empty{padding:56px 24px;text-align:center;color:var(--muted);
  background:var(--glass);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur);
  border:1px solid var(--hairline);border-radius:var(--radius);box-shadow:var(--shadow-card)}
.empty .emoji{font-size:38px;display:block;margin-bottom:12px;opacity:.9}
.empty .cta{margin-top:18px;display:flex;justify-content:center}

/* ── Tabs (submissions status) ── */
.tabs{display:flex;gap:6px;margin-bottom:20px;flex-wrap:wrap;padding:5px;border-radius:var(--radius-pill);
  background:var(--glass);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur);
  border:1px solid var(--hairline);width:fit-content;max-width:100%}
.tabs a{padding:8px 16px;color:var(--muted);font-weight:600;font-size:14px;
  border-radius:var(--radius-pill);text-transform:capitalize;transition:background .15s,color .15s}
.tabs a:hover{color:var(--ink)}
.tabs a.on{color:var(--accent-ink);background:linear-gradient(180deg,var(--accent-h),var(--accent));
  box-shadow:0 2px 8px rgba(10,132,255,.3)}

/* ── Modal (native dialog) ── */
dialog.modal{border:0;padding:0;max-width:min(92vw,560px);width:100%;color:var(--ink);
  background:var(--glass-2);-webkit-backdrop-filter:var(--blur-strong);backdrop-filter:var(--blur-strong);
  border:1px solid var(--edge);border-radius:var(--radius);box-shadow:var(--shadow-pop)}
dialog.modal.wide{max-width:min(94vw,820px)}
dialog.modal::backdrop{background:var(--backdrop);-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px)}
html:has(dialog[open]){overflow:hidden}
.dlg-head{display:flex;align-items:center;justify-content:space-between;gap:12px;
  padding:20px 22px;border-bottom:1px solid var(--hairline)}
.dlg-head h2{margin:0;font-size:19px;font-weight:700;letter-spacing:-.01em;color:var(--ink)}
.dlg-x{background:transparent;border:0;color:var(--muted);font-size:24px;cursor:pointer;line-height:1;
  border-radius:50%;width:34px;height:34px;display:grid;place-items:center;transition:background .15s}
.dlg-x:hover{background:var(--glass);color:var(--ink)}
.dlg-body{padding:22px;max-height:72vh;overflow-y:auto}
.dlg-body .form{max-width:none}
.dlg-foot{display:flex;justify-content:flex-end;gap:10px;padding:16px 22px;border-top:1px solid var(--hairline)}
.modal-loading{padding:28px;text-align:center;color:var(--muted)}
.htmx-request .modal-loading{opacity:.7}
@media(prefers-reduced-motion:no-preference){
  dialog.modal[open]{animation:dlgin .2s cubic-bezier(.32,.72,0,1)}
  @keyframes dlgin{from{opacity:0;transform:translateY(12px) scale(.98)}to{opacity:1;transform:none}}
}

/* ── Media preview (submissions) ── */
.preview-media img,.preview-media video{max-width:300px;border-radius:14px;border:1px solid var(--hairline)}
.preview-media audio{width:100%;max-width:440px}

/* ── Transfer picker grid (Arul category transfer) ── */
.pickgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:12px;margin:16px 0}
.pick{position:relative;display:block;cursor:pointer;border-radius:14px;overflow:hidden;
  border:2px solid var(--hairline);background:var(--glass);transition:border-color .12s}
.pick img{display:block;width:100%;aspect-ratio:9/16;object-fit:cover;background:var(--input)}
.pick .pick-live{position:absolute;top:8px;left:8px;background:var(--accent-soft);color:var(--accent-text);
  border-radius:var(--radius-pill);font-size:11px;font-weight:700;padding:2px 8px}
.pick .pick-title{position:absolute;left:0;right:0;bottom:0;padding:20px 8px 6px;font-size:12px;
  color:#fff;background:linear-gradient(transparent,rgba(0,0,0,.75));white-space:nowrap;
  overflow:hidden;text-overflow:ellipsis}
.pick input{position:absolute;top:8px;right:8px;width:20px;height:20px;accent-color:var(--accent)}
.pick:has(input:checked){border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}

/* ── Login ── */
.login{min-height:100vh;display:grid;place-items:center;padding:20px}
.login .box{width:380px;max-width:100%;border-radius:26px;padding:40px 36px;color:var(--ink);
  background:var(--glass-2);-webkit-backdrop-filter:var(--blur-strong);backdrop-filter:var(--blur-strong);
  box-shadow:var(--shadow-pop);border:1px solid var(--edge)}
.login h1{margin:0 0 5px;font-size:24px;font-weight:700;letter-spacing:-.02em}
.login p{margin:0 0 18px;color:var(--muted);font-size:14.5px}
.login .field{margin-bottom:15px}
.login .btn{width:100%;justify-content:center;margin-top:20px;padding:13px}
.bar{height:4px;border-radius:4px;margin:-2px 0 20px;
  background:linear-gradient(90deg,var(--accent),var(--brand))}

/* ── Responsive: off-canvas glass drawer + mobile top bar ── */
@media(max-width:900px){
  .app{grid-template-columns:1fr}
  .topbar{display:flex;align-items:center;gap:12px;position:sticky;top:0;z-index:25;
    height:58px;padding:0 14px;border-bottom:1px solid var(--hairline);
    background:var(--glass-thin);-webkit-backdrop-filter:var(--blur);backdrop-filter:var(--blur)}
  .topbar .tb-brand{display:flex;align-items:center;gap:10px;font-weight:650;font-size:16px;letter-spacing:-.01em}
  .hamburger{width:42px;height:42px;flex:0 0 auto;display:grid;place-items:center;cursor:pointer;
    border-radius:12px;border:1px solid var(--hairline-strong);background:var(--glass-2);
    color:var(--ink);font-size:20px}
  .hamburger:active{transform:scale(.96)}
  .side{position:fixed;top:0;left:0;height:100dvh;width:min(82vw,300px);
    transform:translateX(-100%);transition:transform .28s cubic-bezier(.32,.72,0,1);
    box-shadow:var(--shadow-pop);border-right:1px solid var(--edge)}
  body.nav-open .side{transform:none}
  .scrim{display:block;position:fixed;inset:0;z-index:20;background:var(--backdrop);
    -webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px);opacity:0;visibility:hidden;
    transition:opacity .28s,visibility .28s}
  body.nav-open .scrim{opacity:1;visibility:visible}
  body.nav-open{overflow:hidden}
  .main{padding:22px 18px 56px}
  .head .htext h1{font-size:25px}
}
@media(max-width:480px){
  .main{padding:18px 14px 48px}
  .head{margin-bottom:20px}
  .head .actions{width:100%}
  .head .actions .btn{flex:1;justify-content:center}
  .stat .n{font-size:30px}
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
  function apply(v){
    var si=v.querySelector('[data-search]'); var q=si?(si.value||'').trim().toLowerCase():'';
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
 * Delegated off `document` submit, so it also handles forms rendered inside a
 * <dialog> / swapped in by HTMX. The presign body also carries the form's
 * `category` value when present (Arul keys are category-partitioned).
 */
const UPLOAD_JS = `
(function(){
  function infer(name){var e=(name.split('.').pop()||'').toLowerCase();return ({jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png',webp:'image/webp',mp4:'video/mp4',mp3:'audio/mpeg',m4a:'audio/mp4',aac:'audio/aac'})[e]||'';}
  function set(form,n,v){var el=form.querySelector('[name="'+n+'"]');if(el)el.value=v;}
  async function run(form){
    var status=form.querySelector('[data-upload-status]');
    var inputs=form.querySelectorAll('input[type=file][data-slot]');
    for(var i=0;i<inputs.length;i++){
      var input=inputs[i];var f=input.files&&input.files[0];
      if(!f){ if(input.hasAttribute('data-required')) throw new Error('Select a file for "'+input.dataset.slot+'"'); else continue; }
      var ct=f.type||infer(f.name);
      if(status) status.textContent='Uploading '+input.dataset.slot+'\\u2026 ('+Math.round(f.size/1024)+' KB)';
      var catEl=form.querySelector('[name="category"]');var cat=catEl?catEl.value:'';
      var pres=await fetch(form.dataset.presign,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({kind:form.dataset.kind,slot:input.dataset.slot,contentType:ct,size:f.size,category:cat})});
      var pj=await pres.json().catch(function(){return{};});
      if(!pres.ok) throw new Error((pj.error&&pj.error.message)||('upload-url failed ('+pres.status+')'));
      var put=await fetch(pj.uploadUrl,{method:'PUT',headers:{'content-type':ct},body:f});
      if(!put.ok) throw new Error('R2 upload failed ('+put.status+')');
      set(form,'key_'+input.dataset.slot,pj.key);set(form,'mime_'+input.dataset.slot,ct);set(form,'id_'+input.dataset.slot,pj.id);
    }
  }
  document.addEventListener('submit',function(e){
    var form=e.target;
    if(!form.matches||!form.matches('form[data-upload-form]'))return;
    if(form.dataset.uploaded==='1')return;
    e.preventDefault();
    var btn=form.querySelector('[type=submit]');var status=form.querySelector('[data-upload-status]');var box=form.querySelector('[data-upload-error]');
    if(box){box.style.display='none';box.textContent='';}
    if(btn)btn.disabled=true;
    run(form).then(function(){form.dataset.uploaded='1';if(status)status.textContent='Saving\\u2026';form.submit();})
    .catch(function(err){if(status)status.textContent='';if(btn)btn.disabled=false;
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
    var go=scope.querySelector('[data-transfer-go]'); if(go)go.disabled=(n===0);
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
              <span>
                HSR
                <small>Unified CMS</small>
              </span>
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

        <ConfirmDialog />
        <script dangerouslySetInnerHTML={{ __html: UPLOAD_JS }} />
        <script dangerouslySetInnerHTML={{ __html: MODAL_JS }} />
        <script dangerouslySetInnerHTML={{ __html: NAV_JS }} />
        <script dangerouslySetInnerHTML={{ __html: LIST_JS }} />
        <script dangerouslySetInnerHTML={{ __html: SELECT_ALL_JS }} />
      </body>
    </html>
  );
};

/** Page header with title, optional subtitle, and right-aligned actions. */
export const PageHead: FC<PropsWithChildren<{ title: string; sub?: string }>> = (props) => (
  <div class="head">
    <div class="htext">
      <h1>{props.title}</h1>
      {props.sub ? <div class="sub">{props.sub}</div> : null}
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

/** Flash note rendered from a ?ok= / ?err= query param after a redirect. */
export const Flash: FC<{ ok?: string | undefined; err?: string | undefined }> = (props) => {
  if (props.err) return <div class="note danger">{props.err}</div>;
  if (props.ok) return <div class="note ok">{props.ok}</div>;
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
        <form class="box" method="post" action={`${ADMIN_BASE}/login`}>
          <h1>HSR CMS</h1>
          <p>Sign in to manage Pakiza &amp; Arul content.</p>
          <div class="bar" />
          {props.error ? <div class="note danger">{props.error}</div> : null}
          <label class="field">
            <span class="lab">Username</span>
            <input name="username" type="text" autocomplete="username" required />
          </label>
          <label class="field">
            <span class="lab">Password</span>
            <input name="password" type="password" autocomplete="current-password" required />
          </label>
          <button type="submit" class="btn">
            Sign in
          </button>
        </form>
      </div>
    </body>
  </html>
);

/** Href prefix helper — every app page URL lives under /admin/{slug}/…. */
export function appPath(app: AppDef, path: string): string {
  return `${ADMIN_BASE}/${app.slug}${path}`;
}
