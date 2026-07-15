// Stage E — build a self-contained local review page from review-data.json.
// Opens via file:// (local thumbnails load directly). Each card has a category
// dropdown (default = classifier pick, or SKIP for likely existing-dups). The
// "Copy corrections" button yields the FINAL {base: category|"SKIP"} map.
import { readFileSync, writeFileSync } from "fs";
const ROOT = "c:/Anish/arul-import";
const CATS = ["amman", "ayyappan", "murugan", "perumal", "sivan", "temples"];
const data = JSON.parse(readFileSync(`${ROOT}/review-data.json`, "utf8"));

const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const card = (it) => {
  const media = it.kind === "video" ? `normalized/${it.thumb}` : `normalized/${it.out}`;
  const def = it.existingDup ? "SKIP" : it.category;
  const conf = (it.confidence || "med").toLowerCase();
  const badges = [];
  if (it.kind === "video") badges.push(`<span class="b vid">▶ ${it.durationS ?? "?"}s</span>`);
  badges.push(`<span class="b c-${conf}">${conf}</span>`);
  if (it.existingDup) badges.push(`<span class="b dup">DUP? ${esc(it.existMatch?.category)} d${it.existMatch?.hamming}</span>`);
  else if (it.batchNearDup) badges.push(`<span class="b near">batch-dup</span>`);
  for (const f of it.flags || []) badges.push(`<span class="b flag">${esc(f)}</span>`);
  const opts = ['<option value="SKIP">— SKIP (don\'t import) —</option>',
    ...CATS.map((c) => `<option value="${c}"${c === def ? " selected" : ""}>${c}</option>`)].join("");
  if (def === "SKIP") opts; // SKIP default handled below
  return `<div class="card" data-cat="${esc(it.category)}" data-conf="${conf}" data-dup="${it.existingDup ? 1 : 0}" data-flag="${(it.flags || []).length ? 1 : 0}">
    <div class="media" ${it.kind === "video" ? `onclick="window.open('normalized/${esc(it.out)}')"` : ""}>
      <img loading="lazy" src="${esc(media)}" alt="">
      <div class="badges">${badges.join("")}</div>
    </div>
    <select data-base="${esc(it.base)}" data-def="${esc(def)}">${def === "SKIP" ? '<option value="SKIP" selected>— SKIP (don\'t import) —</option>' + CATS.map((c) => `<option value="${c}">${c}</option>`).join("") : opts}</select>
    <div class="reason" title="${esc(it.reason)}">${esc(it.reason || "")}</div>
    <div class="fn">${esc(it.src)}</div>
  </div>`;
};

const html = `<!doctype html><html><head><meta charset="utf8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Arul import review — ${data.length} items</title>
<style>
:root{color-scheme:dark}body{margin:0;background:#14110f;color:#efe6dd;font:14px/1.4 system-ui,Segoe UI,sans-serif}
header{position:sticky;top:0;z-index:5;background:#1b1714;padding:12px 16px;border-bottom:1px solid #3a322c;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
h1{font-size:15px;margin:0 12px 0 0;font-weight:600}
.chip{background:#2a231d;border:1px solid #4a3f36;color:#d8ccbf;padding:5px 10px;border-radius:20px;cursor:pointer;font-size:12px}
.chip.on{background:#c65f5f;border-color:#c65f5f;color:#fff}
button{background:#2f7d68;color:#fff;border:0;padding:8px 14px;border-radius:8px;cursor:pointer;font-weight:600}
.out{font-size:12px;color:#b7a99a;margin-left:auto}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:14px;padding:16px}
.card{background:#1e1a16;border:1px solid #352d27;border-radius:10px;overflow:hidden;display:flex;flex-direction:column}
.media{position:relative;aspect-ratio:9/16;background:#000;cursor:default}
.media img{width:100%;height:100%;object-fit:cover;display:block}
.badges{position:absolute;top:6px;left:6px;right:6px;display:flex;flex-wrap:wrap;gap:4px}
.b{font-size:10px;padding:2px 6px;border-radius:5px;background:#000a;backdrop-filter:blur(2px)}
.b.vid{background:#1c4a8fcc}.b.dup{background:#b23b3bdd;font-weight:700}.b.near{background:#8a6d1fcc}.b.flag{background:#4a3f36cc}
.b.c-high{background:#2f7d68cc}.b.c-med{background:#7a6a25cc}.b.c-low{background:#a64b4bcc}
select{margin:8px;padding:6px;background:#2a231d;color:#f0e7de;border:1px solid #4a3f36;border-radius:6px;font-size:13px}
select.changed{border-color:#e0a24a;background:#3a2f1d}
.reason{font-size:11px;color:#9c8f80;padding:0 8px;height:28px;overflow:hidden}
.fn{font-size:9px;color:#6a5f54;padding:4px 8px;word-break:break-all}
</style></head><body>
<header>
  <h1>Arul import review</h1>
  <span class="chip on" data-f="all">All (${data.length})</span>
  <span class="chip" data-f="low">Low-confidence</span>
  <span class="chip" data-f="dup">Possible dups</span>
  <span class="chip" data-f="flag">Flagged</span>
  ${CATS.map((c) => `<span class="chip" data-f="cat:${c}">${c}</span>`).join("")}
  <button id="copy">Copy corrections</button>
  <span class="out" id="out">0 changed · 0 skipped</span>
</header>
<div class="grid">${data.map(card).join("")}</div>
<script>
const sels=[...document.querySelectorAll('select')];
function refresh(){let ch=0,sk=0;for(const s of sels){const c=s.value!==s.dataset.def;s.classList.toggle('changed',c);if(c)ch++;if(s.value==='SKIP')sk++;}document.getElementById('out').textContent=ch+' changed · '+sk+' skipped';}
sels.forEach(s=>s.addEventListener('change',refresh));refresh();
document.querySelectorAll('.chip').forEach(ch=>ch.addEventListener('click',()=>{
  document.querySelectorAll('.chip').forEach(x=>x.classList.remove('on'));ch.classList.add('on');
  const f=ch.dataset.f;document.querySelectorAll('.card').forEach(card=>{let show=true;
    if(f==='low')show=card.dataset.conf==='low';else if(f==='dup')show=card.dataset.dup==='1';
    else if(f==='flag')show=card.dataset.flag==='1';else if(f.startsWith('cat:'))show=card.dataset.cat===f.slice(4);
    card.style.display=show?'':'none';});}));
document.getElementById('copy').addEventListener('click',()=>{
  const map={};for(const s of sels)map[s.dataset.base]=s.value;
  navigator.clipboard.writeText(JSON.stringify(map)).then(()=>{const o=document.getElementById('out');const t=o.textContent;o.textContent='✓ copied — paste back to Claude';setTimeout(()=>{o.textContent=t;refresh();},2500);});
});
</script></body></html>`;

writeFileSync(`${ROOT}/review.html`, html);
console.log(`review.html written (${data.length} cards)`);
