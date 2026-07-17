/**
 * CMS — ARUL ringtones authoring (mounted at /admin/arul/ringtones).
 *
 * Built on the wallpapers.tsx interaction patterns (search + keysearch spans,
 * table AND grid views, floating bulk pill, batch upload with per-file specific
 * errors), NOT on Pakiza's bare legacy page (src/pages/ringtones.tsx) — that
 * module stays byte-identical for Pakiza. This factory is a separate module
 * with page-scoped CSS + JS so nothing in the shared ui.tsx changes.
 *
 * Data model (fixed contract): Neon table `ringtones` (id, title, category
 * NOT NULL, tags, audio_key, cover_key nullable, mime, duration_ms, bytes,
 * is_published, sort_order, created_at). R2 keys: audio
 * ringtones/<category>/<uuid>.<ext> (mp3 canonical; m4a/aac accepted, 15MB
 * cap), cover ringtones/covers/<category>/<uuid>.jpg (512×512 JPG, ≤300KB
 * soft target). cover_key is STORED — never derived from the audio key.
 *
 * Every mutation = row write + app_config.content_version bump in ONE
 * transaction, then triggerRebuild. Replaced/deleted R2 bytes are removed only
 * AFTER a confirmed rebuild (same rule as wallpapers.tsx).
 */

import { Hono } from "hono";
import type { FC } from "hono/jsx";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";
import { getDb } from "../lib/db.js";
import { Badge, Flash, Layout, Modal, PageHead, appPath } from "../ui.js";
import { triggerRebuild, REBUILD_FAILED_MSG } from "../rebuild.js";
import { formStr, parseBool, categorySlug, toPgTextArray, fromPgTextArray } from "../lib/util.js";

interface RtRow {
  id: string;
  title: string;
  category: string;
  tags?: unknown;
  audio_key: string;
  cover_key: string | null;
  mime: string | null;
  duration_ms: number | string | null;
  sort_order?: number | string | null;
  is_published: boolean;
  /** created_at as YYYY-MM-DD (list column; absent on edit-form loads). */
  created?: string;
}

/** Cap operator/attacker-echoed values in flash messages (see wallpapers.tsx). */
function truncateForMessage(s: string, max = 60): string {
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

function capitalize(s: string): string {
  return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

/** duration_ms → whole seconds (numeric sort key), or null. */
function durSecs(ms: RtRow["duration_ms"]): number | null {
  const n = typeof ms === "string" ? parseInt(ms, 10) : ms;
  return n == null || Number.isNaN(n) ? null : Math.round(n / 1000);
}

/** 94 → "1:34". */
function fmtSecs(secs: number): string {
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

// ── Page-scoped styles: square cover cards with inline audio (the shared
//    .pickgrid card is a 9/16 wallpaper card — ringtones need their own). No
//    !important here, so the shared mobile 2-column [data-grid] override wins. ──
const RT_CSS = `
.pickgrid.rt-grid{grid-template-columns:repeat(auto-fill,minmax(190px,1fr))}
.rtcard{position:relative;border:1px solid var(--hairline);border-radius:var(--radius-sm);
  background:var(--glass);overflow:hidden;display:flex;flex-direction:column;transition:border-color .12s}
.rtcard:hover{border-color:var(--hairline-strong)}
.rtcard .rtcover{position:relative;aspect-ratio:1/1;background:var(--input)}
.rtcard .rtcover img{width:100%;height:100%;object-fit:cover;display:block;cursor:pointer}
.rtcard.draft .rtcover img{opacity:.6}
.rtcard .rtmark{position:absolute;inset:0;display:grid;place-items:center;cursor:pointer;
  font-size:34px;color:rgba(240,235,228,.35);background:var(--glass-elev)}
.rtcard .rtcover .rowsel{position:absolute;top:8px;right:8px;background:rgba(16,14,16,.6)}
.rtcard .rtdraft{position:absolute;top:8px;left:8px;background:rgba(16,14,16,.75);color:var(--muted);
  border:1px solid var(--hairline-strong);text-transform:uppercase;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace;border-radius:var(--radius-pill);
  font-size:10px;font-weight:700;padding:2px 8px;letter-spacing:.04em}
.rtcard audio{width:100%;height:34px;display:block;border-top:1px solid var(--hairline)}
.rtcard .rtmeta{padding:8px 10px 10px;display:flex;flex-direction:column;gap:3px}
.rtcard .rtname{font-weight:600;font-size:13px;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rtcard .rtsub{font-size:12px;color:var(--muted);display:flex;gap:8px;align-items:center;flex-wrap:wrap}
`;

/**
 * Page-local uploader + bulk script for the ARUL ringtones page ONLY. The
 * shared UPLOAD_JS handles form[data-upload-form]; these forms use
 * data-rt-form / data-rt-batch-form instead, because ringtones need two typed
 * presign kinds (ringtone + ringtone_cover), an audio-duration probe, a 15MB
 * pre-upload block, dedupe warnings, and filename-stem batch pairing. Bulk
 * action buttons use data-rt-bulk (not data-bulk-act) so the shared BULK_JS
 * confirm copy ("wallpapers") never fires here; BULK_JS still drives checkbox
 * sync, the pill's count/ids and the table↔grid toggle.
 *
 * The stem-pairing rules mirror src/lib/ringtone-batch.ts (the tested form).
 */
const RT_JS = `
(function(){
  var MAXA=15*1024*1024;
  var AOK={'audio/mpeg':1,'audio/mp4':1,'audio/aac':1,'audio/x-m4a':1};
  function infer(name){var e=(name.split('.').pop()||'').toLowerCase();
    return ({mp3:'audio/mpeg',m4a:'audio/mp4',aac:'audio/aac',jpg:'image/jpeg',jpeg:'image/jpeg'})[e]||'';}
  function stem(n){var i=n.lastIndexOf('.');return i>0?n.slice(0,i):n;}
  function pretty(s){
    return s.replace(/[-_]+/g,' ').split(' ').filter(function(w){return w.length;})
      .map(function(w){return w.charAt(0).toUpperCase()+w.slice(1);}).join(' ');}
  function slugify(s){return (s||'').trim().toLowerCase().split(' ').join('-').replace(/[^a-z0-9_-]/g,'');}
  function existing(){try{var el=document.getElementById('rt-existing');
    return el?JSON.parse(el.textContent||'[]'):[];}catch(e){return [];}}
  function isDup(cat,title){return existing().indexOf(cat+'|'+(title||'').trim().toLowerCase())>=0;}
  function setV(form,n,v){var el=form.querySelector('[name="'+n+'"]');if(el)el.value=v;}
  function showErr(form,msg){var box=form.querySelector('[data-upload-error]');
    if(box){box.style.display='block';box.textContent=msg;}else{alert(msg);}}
  function showWarn(form,msgs){var box=form.querySelector('[data-upload-warn]');
    if(box&&msgs.length){box.style.display='block';box.textContent=msgs.join(' \\u00b7 ');}}
  function clearNotes(form){['[data-upload-error]','[data-upload-warn]'].forEach(function(sel){
    var b=form.querySelector(sel);if(b){b.style.display='none';b.textContent='';}});}
  function probeAudio(f){return new Promise(function(res){
    var u=URL.createObjectURL(f);var a=document.createElement('audio');var done=false;
    function fin(v){if(done)return;done=true;URL.revokeObjectURL(u);res(v);}
    a.preload='metadata';
    a.addEventListener('loadedmetadata',function(){fin(isFinite(a.duration)?Math.round(a.duration*1000):null);});
    a.addEventListener('error',function(){fin(null);});
    a.src=u;setTimeout(function(){fin(null);},8000);});}
  function probeCoverWarn(f){return new Promise(function(res){
    var u=URL.createObjectURL(f);var im=new Image();
    im.onload=function(){var w=null;
      if(im.naturalWidth!==512||im.naturalHeight!==512)
        w=f.name+' is '+im.naturalWidth+'\\u00d7'+im.naturalHeight+' \\u2014 covers should be 512\\u00d7512 JPG';
      else if(f.size>300*1024)
        w=f.name+' is '+Math.round(f.size/1024)+' KB \\u2014 covers should stay \\u2264300 KB';
      URL.revokeObjectURL(u);res(w);};
    im.onerror=function(){URL.revokeObjectURL(u);res(f.name+': could not be read as an image');};
    im.src=u;});}
  async function presignPut(form,kind,f,ct){
    var catEl=form.querySelector('[name="category"]');var cat=catEl?catEl.value:'';
    var pres=await fetch(form.getAttribute('data-presign'),{method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({kind:kind,slot:kind,contentType:ct,size:f.size,category:cat})});
    var pj=await pres.json().catch(function(){return {};});
    if(!pres.ok)throw new Error(f.name+': '+((pj.error&&pj.error.message)||('upload-url failed ('+pres.status+')')));
    var put=await fetch(pj.uploadUrl,{method:'PUT',headers:{'content-type':ct},body:f});
    if(!put.ok)throw new Error(f.name+': R2 upload failed ('+put.status+')');
    return pj;
  }
  function busy(form,on,label){var btn=form.querySelector('[type=submit]');
    if(btn){btn.disabled=on;btn.classList.toggle('busy',on);if(label)btn.textContent=label;}}

  // ── Single create / edit ──
  async function runSingle(form){
    clearNotes(form);
    var status=form.querySelector('[data-upload-status]');
    var isNew=form.getAttribute('data-mode')==='new';
    var aIn=form.querySelector('input[type=file][data-slot="audio"]');
    var cIn=form.querySelector('input[type=file][data-slot="cover"]');
    var af=(aIn&&aIn.files&&aIn.files.length)?aIn.files[0]:null;
    var cf=(cIn&&cIn.files&&cIn.files.length)?cIn.files[0]:null;
    if(isNew&&!af)throw new Error('Select an audio file (MP3/M4A/AAC, \\u226415 MB)');
    if(isNew&&!cf)throw new Error('Select a cover image \\u2014 every ringtone needs a 512\\u00d7512 JPG cover');
    var act='';
    if(af){
      act=af.type||infer(af.name);
      if(!AOK[act])throw new Error(af.name+': unsupported audio type '+(act||'(unknown)')+' \\u2014 use MP3, M4A or AAC');
      if(af.size>MAXA)throw new Error(af.name+' is '+(af.size/1048576).toFixed(1)+' MB \\u2014 the audio limit is 15 MB. Compress it locally first.');
    }
    if(cf&&(cf.type||infer(cf.name))!=='image/jpeg')
      throw new Error(cf.name+': covers must be JPEG (512\\u00d7512)');
    var titleEl=form.querySelector('[name="title"]');var catEl=form.querySelector('[name="category"]');
    if(isNew&&titleEl&&catEl&&isDup(slugify(catEl.value),titleEl.value)){
      if(!confirm('A ringtone titled "'+titleEl.value+'" already exists in this category. Create it anyway?'))return false;
    }
    busy(form,true,'Uploading\\u2026');
    var warns=[];
    if(af){
      if(status)status.textContent='Reading duration\\u2026';
      var d=await probeAudio(af);
      setV(form,'duration_ms',d==null?'':String(d));
      setV(form,'bytes_audio',String(af.size));
      if(d!=null&&d>60000)warns.push(af.name+' is '+Math.round(d/1000)+'s \\u2014 ringtones are usually \\u226460s (uploading anyway)');
    }
    if(cf){var cw=await probeCoverWarn(cf);if(cw)warns.push(cw);}
    showWarn(form,warns);
    if(af){
      if(status)status.textContent='Uploading audio\\u2026 ('+Math.round(af.size/1024)+' KB)';
      var ar=await presignPut(form,'ringtone',af,act);
      setV(form,'key_audio',ar.key);setV(form,'mime_audio',act);setV(form,'id_audio',ar.id||'');
    }
    if(cf){
      if(status)status.textContent='Uploading cover\\u2026';
      var cr=await presignPut(form,'ringtone_cover',cf,'image/jpeg');
      setV(form,'key_cover',cr.key);setV(form,'mime_cover','image/jpeg');
    }
    if(status)status.textContent='Saving\\u2026';
    return true;
  }

  // ── Batch: N audio + N covers paired by filename stem ──
  async function runBatch(form){
    clearNotes(form);
    var status=form.querySelector('[data-upload-status]');
    var aIn=form.querySelector('input[type=file][data-slot="batch-audio"]');
    var cIn=form.querySelector('input[type=file][data-slot="batch-cover"]');
    var audios=(aIn&&aIn.files)?Array.prototype.slice.call(aIn.files):[];
    var covers=(cIn&&cIn.files)?Array.prototype.slice.call(cIn.files):[];
    if(!audios.length)throw new Error('Select at least one audio file (MP3/M4A/AAC)');
    if(!covers.length)throw new Error('Select the matching cover images \\u2014 one 512\\u00d7512 JPG per audio file, same filename stem');
    var catEl=form.querySelector('[name="category"]');
    var cat=slugify(catEl?catEl.value:'');
    var errs=[];var pairs=[];
    // pairing — mirrors src/lib/ringtone-batch.ts pairByStem
    var coverByStem={};var badCover={};
    covers.forEach(function(f){
      if((f.type||infer(f.name))!=='image/jpeg'){errs.push(f.name+': covers must be JPEG (.jpg) \\u2014 512\\u00d7512');return;}
      var s=stem(f.name).toLowerCase();
      if(coverByStem[s]){badCover[s]=1;errs.push(f.name+': another cover has the same name stem "'+stem(f.name)+'"');return;}
      coverByStem[s]=f;});
    var seenAudio={};
    audios.forEach(function(f){
      var ct=f.type||infer(f.name);
      if(!AOK[ct]){errs.push(f.name+': unsupported audio type \\u2014 use MP3, M4A or AAC');return;}
      var s=stem(f.name).toLowerCase();
      if(seenAudio[s]){errs.push(f.name+': another audio file has the same name stem "'+stem(f.name)+'"');return;}
      seenAudio[s]=1;
      if(badCover[s]){errs.push(f.name+': skipped \\u2014 its cover stem "'+stem(f.name)+'" is ambiguous');return;}
      if(f.size>MAXA){errs.push(f.name+' is '+(f.size/1048576).toFixed(1)+' MB \\u2014 over the 15 MB audio limit');return;}
      var cv=coverByStem[s];
      if(!cv){errs.push(f.name+': no matching cover image (expected '+stem(f.name)+'.jpg)');return;}
      var title=pretty(stem(f.name));
      if(isDup(cat,title)){errs.push(f.name+': "'+title+'" already exists in this category \\u2014 skipped');return;}
      cv._used=1;
      pairs.push({a:f,c:cv,ct:ct,title:title});});
    covers.forEach(function(f){
      var s=stem(f.name).toLowerCase();
      if(!f._used&&!seenAudio[s]&&coverByStem[s]===f)errs.push(f.name+': no matching audio file');});
    if(errs.length)showErr(form,errs.join('\\n'));
    if(!pairs.length)throw new Error('No valid audio + cover pairs \\u2014 fix the files listed above');
    if(errs.length&&!confirm(errs.length+' file(s) will be skipped:\\n\\n'+errs.join('\\n')+'\\n\\nContinue with '+pairs.length+' ringtone(s)?'))return false;
    busy(form,true,'Uploading\\u2026');
    var items=[];var warns=[];
    for(var i=0;i<pairs.length;i++){
      var p=pairs[i];
      if(status)status.textContent='Pair '+(i+1)+' of '+pairs.length+' \\u2014 '+p.a.name+'\\u2026';
      var d=await probeAudio(p.a);
      if(d!=null&&d>60000)warns.push(p.a.name+' is '+Math.round(d/1000)+'s (>60s)');
      var cw=await probeCoverWarn(p.c);if(cw)warns.push(cw);
      showWarn(form,warns);
      var ar=await presignPut(form,'ringtone',p.a,p.ct);
      var cr=await presignPut(form,'ringtone_cover',p.c,'image/jpeg');
      items.push({id:ar.id,audio_key:ar.key,mime:p.ct,cover_key:cr.key,title:p.title,
        duration_ms:d,bytes:p.a.size});
    }
    setV(form,'items_json',JSON.stringify(items));
    if(status)status.textContent='Saving '+items.length+' ringtones\\u2026';
    return true;
  }

  function wire(sel,run){
    document.addEventListener('submit',function(e){
      var form=e.target;
      if(!form.matches||!form.matches(sel))return;
      if(form.getAttribute('data-uploaded')==='1')return;
      e.preventDefault();
      var btn=form.querySelector('[type=submit]');var orig=btn?btn.textContent:'';
      run(form).then(function(go){
        if(go===false){busy(form,false,orig);return;}
        form.setAttribute('data-uploaded','1');
        busy(form,true,'Saving\\u2026');
        form.submit();
      }).catch(function(err){
        busy(form,false,orig);
        var st=form.querySelector('[data-upload-status]');if(st)st.textContent='';
        showErr(form,err.message);
      });
    });
  }
  wire('form[data-rt-form]',runSingle);
  wire('form[data-rt-batch-form]',runBatch);

  // ── Bulk pill actions (publish/unpublish/category/delete) ──
  document.addEventListener('click',function(e){
    var btn=e.target.closest&&e.target.closest('[data-rt-bulk]');
    if(!btn)return;
    var form=btn.closest('form');if(!form)return;
    var act=btn.getAttribute('data-rt-bulk');
    var n=((form.querySelector('[name="ids"]')||{}).value||'').split(',').filter(Boolean).length;
    if(!n)return;
    if(act==='delete'&&!confirm('Delete '+n+' ringtone'+(n===1?'':'s')+'? This removes them from the app.'))return;
    if(act==='category'){
      var sel=form.querySelector('[name="bulk_category"]');
      if(!sel||!sel.value){alert('Choose a target category first');return;}
    }
    form.querySelector('[name="bulk_action"]').value=act;
    form.submit();
  });
})();
`;

export function makeArulRingtonesApp(app: AppDef): Hono<{ Bindings: Env }> {
  if (!app.hasRingtones || !app.hasCategories) {
    throw new Error(`arul ringtones pages mounted for an incompatible app: ${app.slug}`);
  }
  const ringtonesApp = new Hono<{ Bindings: Env }>();
  const base = appPath(app, "/ringtones");
  const navKey = `${app.slug}:ringtones`;
  const AUDIO_ACCEPT = "audio/mpeg,audio/mp4,audio/aac,.mp3,.m4a,.aac";
  const COVER_ACCEPT = "image/jpeg,.jpg,.jpeg";

  const CategoryField: FC<{ value?: string }> = (props) => (
    <label class="field">
      <span class="lab">Category</span>
      <input
        name="category"
        type="text"
        required
        list="rt-cats"
        placeholder="e.g. murugan"
        value={props.value ?? ""}
      />
      <datalist id="rt-cats">
        {app.knownCategories.map((cat) => (
          <option value={cat} />
        ))}
      </datalist>
      <span class="hint">
        Browse axis + R2 key prefix (ringtones/&lt;category&gt;/…). Free text — a new category
        simply appears as a new chip.
      </span>
    </label>
  );

  // ── Single create / edit form ────────────────────────────────────────────────
  const RingtoneForm: FC<{ mode: "new" | "edit"; row?: RtRow }> = (props) => {
    const r = props.row;
    const isEdit = props.mode === "edit";
    const action = isEdit ? `${base}/${r!.id}` : base;
    const tags = isEdit ? fromPgTextArray(r?.tags).join(", ") : "";
    return (
      <form
        class="form"
        method="post"
        action={action}
        data-rt-form
        data-mode={props.mode}
        data-presign={appPath(app, "/media/upload-url")}
      >
        <div class="note danger" data-upload-error style="display:none;white-space:pre-line"></div>
        <div class="note warn" data-upload-warn style="display:none"></div>

        <label class="field">
          <span class="lab">Title</span>
          <input name="title" type="text" required autofocus value={r?.title ?? ""} />
        </label>

        <CategoryField {...(r?.category ? { value: r.category } : {})} />

        <label class="field">
          <span class="lab">{isEdit ? "Replace audio (optional)" : "Audio file"}</span>
          <input
            type="file"
            data-slot="audio"
            {...(isEdit ? {} : { "data-required": "1" })}
            accept={AUDIO_ACCEPT}
          />
          {isEdit && r ? <span class="hint keyline">Current: {r.audio_key}</span> : null}
          <span class="hint">MP3 preferred (M4A/AAC accepted) · max 15 MB · usually ≤60s.</span>
        </label>
        <input type="hidden" name="key_audio" value="" />
        <input type="hidden" name="mime_audio" value="" />
        <input type="hidden" name="id_audio" value="" />
        <input type="hidden" name="duration_ms" value="" />
        <input type="hidden" name="bytes_audio" value="" />

        <label class="field">
          <span class="lab">{isEdit ? "Replace cover (optional)" : "Cover image"}</span>
          <input
            type="file"
            data-slot="cover"
            {...(isEdit ? {} : { "data-required": "1" })}
            accept={COVER_ACCEPT}
          />
          {isEdit && r ? (
            <span class="hint keyline">Current: {r.cover_key ?? "(no cover — add one!)"}</span>
          ) : null}
          <span class="hint">512×512 JPG, ≤300 KB — shown on the ringtone card in the app.</span>
        </label>
        <input type="hidden" name="key_cover" value="" />
        <input type="hidden" name="mime_cover" value="" />

        {isEdit ? (
          <div class="formgrid">
            <label class="field">
              <span class="lab">Tags</span>
              <input name="tags" type="text" placeholder="comma, separated" value={tags} />
            </label>
            <label class="field">
              <span class="lab">Sort order</span>
              <input
                name="sort_order"
                type="number"
                value={String(r?.sort_order ?? 0)}
              />
            </label>
          </div>
        ) : (
          <label class="check">
            <input name="is_published" type="checkbox" checked />
            <span>Published (visible in the app)</span>
          </label>
        )}

        <div class="row" style="margin-top:18px;justify-content:flex-end">
          <span class="muted" data-upload-status style="color:var(--accent-text);margin-right:auto"></span>
          <button type="button" class="btn sec" data-dialog-close>
            Cancel
          </button>
          <button type="submit" class="btn">
            {isEdit ? "Save changes" : "Create ringtone"}
          </button>
        </div>
      </form>
    );
  };

  // ── Batch form: N audio files + N covers matched by filename stem ────────────
  const BatchForm: FC = () => (
    <form
      class="form"
      method="post"
      action={base}
      data-rt-batch-form
      data-presign={appPath(app, "/media/upload-url")}
    >
      <div class="note danger" data-upload-error style="display:none;white-space:pre-line"></div>
      <div class="note warn" data-upload-warn style="display:none"></div>

      <CategoryField />

      <label class="field">
        <span class="lab">Audio files</span>
        <input type="file" data-slot="batch-audio" multiple accept={AUDIO_ACCEPT} />
        <span class="hint">MP3 preferred · max 15 MB each · titles derive from the filenames.</span>
      </label>

      <label class="field">
        <span class="lab">Cover images</span>
        <input type="file" data-slot="batch-cover" multiple accept={COVER_ACCEPT} />
        <span class="hint">
          One 512×512 JPG per audio file, matched by filename stem (song1.mp3 ↔ song1.jpg).
          Unmatched files are skipped with a per-file error.
        </span>
      </label>
      <input type="hidden" name="items_json" value="" />

      <label class="check">
        <input name="is_published" type="checkbox" checked />
        <span>Publish all (visible in the app)</span>
      </label>

      <div class="row" style="margin-top:18px;justify-content:flex-end">
        <span class="muted" data-upload-status style="color:var(--accent-text);margin-right:auto"></span>
        <button type="button" class="btn sec" data-dialog-close>
          Cancel
        </button>
        <button type="submit" class="btn">Upload batch</button>
      </div>
    </form>
  );

  // Full-page fallback wrapper (direct URL / no-JS); modals use the forms alone.
  const FormPage: FC<{ mode: "new" | "edit"; row?: RtRow }> = (props) => (
    <Layout
      title={`${props.mode === "edit" ? "Edit" : "New"} ringtone · ${app.label}`}
      active={navKey}
    >
      <PageHead title={props.mode === "edit" ? "Edit ringtone" : "New ringtone"} sub={app.label}>
        <a class="btn sec" href={base}>
          Back
        </a>
      </PageHead>
      <div class="card">
        <RingtoneForm mode={props.mode} {...(props.row ? { row: props.row } : {})} />
      </div>
      <script dangerouslySetInnerHTML={{ __html: RT_JS }} />
    </Layout>
  );

  // ── List ────────────────────────────────────────────────────────────────────
  ringtonesApp.get("/", async (c) => {
    const sql = getDb(c.env, app);
    let rows: RtRow[] = [];
    let dbError = false;
    try {
      rows = (await sql`
        SELECT id, title, category, audio_key, cover_key, mime, duration_ms, is_published,
               to_char(created_at, 'YYYY-MM-DD') AS created
        FROM ringtones
        ORDER BY sort_order ASC, created_at DESC
      `) as unknown as RtRow[];
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] list error:`, err);
      dbError = true;
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }

    const cdn = app.cdnBase.replace(/\/$/, "");
    // Filter options: registry knownCategories + any novel category in the rows.
    const categories = Array.from(
      new Set([...app.knownCategories, ...rows.map((r) => r.category).filter(Boolean)]),
    ).sort();
    // Dedupe data for the uploader ("category|lowercased title"); </ escaped so
    // a hostile title can never close the script tag.
    const existingJson = JSON.stringify(
      rows.map((r) => `${r.category}|${r.title.toLowerCase()}`),
    ).replace(/</g, "\\u003c");

    return c.html(
      <Layout title={`Ringtones · ${app.label}`} active={navKey}>
        <style dangerouslySetInnerHTML={{ __html: RT_CSS }} />
        <PageHead
          title={`${app.label} ringtones`}
          sub={`${rows.length} ${rows.length === 1 ? "entry" : "entries"}`}
        >
          <button type="button" class="btn sec" data-dialog-target="rt-new">
            + New ringtone
          </button>
          <button type="button" class="btn" data-dialog-target="rt-batch">
            ⇪ Batch upload
          </button>
        </PageHead>
        <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
        {dbError ? <div class="note danger">Could not load ringtones.</div> : null}

        {rows.length === 0 && !dbError ? (
          <div class="empty">
            <span class="emoji">♪</span>
            No ringtones yet — batch-upload MP3s + covers to launch this surface.
            <div class="hint" style="margin-top:8px;color:var(--muted);font-size:13px">
              Audio: MP3 (M4A/AAC ok), ≤15 MB, usually ≤60s · Cover: 512×512 JPG, ≤300 KB ·
              pair files by name (song1.mp3 ↔ song1.jpg) — titles derive from the filenames.
            </div>
            <div class="cta" style="gap:10px">
              <button type="button" class="btn" data-dialog-target="rt-batch">
                ⇪ Batch upload
              </button>
              <button type="button" class="btn sec" data-dialog-target="rt-new">
                + New ringtone
              </button>
            </div>
          </div>
        ) : null}
        {rows.length > 0 ? (
          <div data-listview data-page="1">
            <div class="toolbar">
              <div class="searchwrap">
                <input
                  class="search"
                  type="text"
                  data-search
                  placeholder="Search title, category, ID or R2 key…"
                />
                <button type="button" class="search-clear" aria-label="Clear search" data-search-clear>
                  ×
                </button>
              </div>
              {/* Column 3 = Category cell, column 5 = Status cell (LIST_JS generic filters). */}
              <select data-filter="3" aria-label="Filter by category">
                <option value="">All categories</option>
                {categories.map((cat) => (
                  <option value={cat}>{capitalize(cat)}</option>
                ))}
              </select>
              <select data-filter="5" aria-label="Filter by status">
                <option value="">All statuses</option>
                <option value="published">Published</option>
                <option value="draft">Draft</option>
              </select>
              <span class="grow" />
              <div class="viewtoggle" role="group" aria-label="View">
                <button type="button" data-view="table" class="on">
                  Table
                </button>
                <button type="button" data-view="grid">Grid</button>
              </div>
              <select data-page-size aria-label="Rows per page">
                <option value="10">10 / page</option>
                <option value="20" selected>
                  20 / page
                </option>
                <option value="50">50 / page</option>
                <option value="0">All</option>
              </select>
            </div>
            {/* Floating bulk pill — buttons use data-rt-bulk (page JS) so the copy
                says "ringtones"; BULK_JS still fills ids + shows/hides the bar. */}
            <form method="post" action={`${base}/bulk`} class="bulkbar" data-bulk-bar>
              <span data-bulk-count>0 selected</span>
              <input type="hidden" name="ids" value="" />
              <input type="hidden" name="bulk_action" value="" />
              <button type="button" class="btn sec sm" data-rt-bulk="publish">
                Publish
              </button>
              <button type="button" class="btn sec sm" data-rt-bulk="unpublish">
                Unpublish
              </button>
              <span class="bulk-div" />
              <select name="bulk_category" aria-label="Target category" style="min-width:130px">
                <option value="">Category…</option>
                {categories.map((cat) => (
                  <option value={cat}>{capitalize(cat)}</option>
                ))}
              </select>
              <button type="button" class="btn sec sm" data-rt-bulk="category">
                Move
              </button>
              <span class="bulk-div" />
              <button type="button" class="btn danger sm" data-rt-bulk="delete">
                Delete
              </button>
            </form>
            <div class="tablewrap">
              <table>
                <thead>
                  <tr>
                    <th>
                      <input
                        type="checkbox"
                        class="rowsel"
                        data-bulk-all
                        aria-label="Select all visible"
                      />
                    </th>
                    <th></th>
                    <th class="sortable" data-type="text">
                      Title <span class="arrow" />
                    </th>
                    <th class="sortable" data-type="text">
                      Category <span class="arrow" />
                    </th>
                    <th class="sortable" data-type="num">
                      Duration <span class="arrow" />
                    </th>
                    <th>Status</th>
                    <th>ID</th>
                    <th class="sortable" data-type="text">
                      Added <span class="arrow" />
                    </th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => {
                    const secs = durSecs(r.duration_ms);
                    return (
                      <tr data-id={r.id}>
                        <td>
                          <input
                            type="checkbox"
                            class="rowsel"
                            data-bulk-id={r.id}
                            aria-label="Select"
                          />
                        </td>
                        <td style="padding:4px 14px">
                          {r.cover_key ? (
                            <img
                              class="thumb"
                              src={`${cdn}/${r.cover_key}`}
                              alt=""
                              loading="lazy"
                              onerror={`this.onerror=null;this.outerHTML='<span class="filemark">\\u266a</span>'`}
                            />
                          ) : (
                            <span class="filemark">♪</span>
                          )}
                        </td>
                        <td class="coltitle">
                          <strong>{r.title}</strong>
                        </td>
                        <td class="colcat" title={r.category}>
                          {r.category}
                        </td>
                        <td class="coldate">
                          {/* hidden numeric first so the num-sort parses seconds */}
                          <span class="keysearch">{secs ?? 0} </span>
                          {secs == null ? "—" : fmtSecs(secs)}
                        </td>
                        <td>
                          <div class="row">
                            {r.is_published ? (
                              <Badge kind="ok">published</Badge>
                            ) : (
                              <Badge kind="muted">draft</Badge>
                            )}
                            {r.is_published && !r.cover_key ? (
                              <Badge kind="warn">no cover</Badge>
                            ) : null}
                          </div>
                        </td>
                        <td>
                          <span class="idcode" title={r.id}>
                            {r.id.slice(0, 8)}
                          </span>
                          <span class="keysearch">
                            {r.id} {r.audio_key} {r.cover_key ?? ""}
                          </span>
                        </td>
                        <td class="coldate">{r.created ?? "—"}</td>
                        <td>
                          <div class="rowact">
                            <button
                              type="button"
                              class="btn sec sm"
                              data-dialog-target="rt-edit"
                              hx-get={`${base}/${r.id}/edit`}
                              hx-target="#rt-edit-body"
                              hx-swap="innerHTML"
                            >
                              Edit
                            </button>
                            <form method="post" action={`${base}/${r.id}/publish`}>
                              <button type="submit" class="btn sec sm">
                                {r.is_published ? "Unpublish" : "Publish"}
                              </button>
                            </form>
                            <form
                              method="post"
                              action={`${base}/${r.id}/delete`}
                              data-confirm="Delete this ringtone? This removes it from the app."
                            >
                              <button type="submit" class="btn danger sm">
                                Delete
                              </button>
                            </form>
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {/* Grid view — square cover cards with an inline audio preview. LIST_JS
                mirrors filter/sort/page state (data-grid-id ↔ tr data-id); BULK_JS
                keeps card checkboxes in sync with the table's. */}
            <div class="pickgrid rt-grid" data-grid style="display:none">
              {rows.map((r) => {
                const secs = durSecs(r.duration_ms);
                const hx = {
                  "data-dialog-target": "rt-edit",
                  "hx-get": `${base}/${r.id}/edit`,
                  "hx-target": "#rt-edit-body",
                  "hx-swap": "innerHTML",
                };
                return (
                  <div class={`rtcard${r.is_published ? "" : " draft"}`} data-grid-id={r.id}>
                    <div class="rtcover">
                      {r.cover_key ? (
                        <img
                          src={`${cdn}/${r.cover_key}`}
                          alt=""
                          loading="lazy"
                          onerror={`this.onerror=null;this.outerHTML='<span class="rtmark">\\u266a</span>'`}
                          {...hx}
                        />
                      ) : (
                        <span class="rtmark" {...hx}>
                          ♪
                        </span>
                      )}
                      {r.is_published ? null : <span class="rtdraft">draft</span>}
                      <input type="checkbox" class="rowsel" data-bulk-id={r.id} aria-label="Select" />
                    </div>
                    <audio controls preload="none" src={`${cdn}/${r.audio_key}`}></audio>
                    <div class="rtmeta">
                      <span class="rtname">{r.title}</span>
                      <span class="rtsub">
                        <span>{r.category}</span>
                        <span>{secs == null ? "" : fmtSecs(secs)}</span>
                        {r.is_published && !r.cover_key ? <Badge kind="warn">no cover</Badge> : null}
                      </span>
                    </div>
                  </div>
                );
              })}
            </div>
            <div class="note muted" data-empty-filtered style="display:none">
              No ringtones match your search.
            </div>
            <div class="pager" />
          </div>
        ) : null}

        <script
          type="application/json"
          id="rt-existing"
          dangerouslySetInnerHTML={{ __html: existingJson }}
        />
        <Modal id="rt-new" title="New ringtone" wide>
          <RingtoneForm mode="new" />
        </Modal>
        <Modal id="rt-batch" title="Batch upload ringtones" wide>
          <BatchForm />
        </Modal>
        <Modal id="rt-edit" title="Edit ringtone" wide>
          <div id="rt-edit-body">
            <div class="modal-loading">Loading…</div>
          </div>
        </Modal>
        <script dangerouslySetInnerHTML={{ __html: RT_JS }} />
      </Layout>,
    );
  });

  ringtonesApp.get("/new", (c) => {
    if (c.req.header("HX-Request") === "true") return c.html(<RingtoneForm mode="new" />);
    return c.html(<FormPage mode="new" />);
  });

  ringtonesApp.get("/:id/edit", async (c) => {
    const id = c.req.param("id");
    const sql = getDb(c.env, app);
    let row: RtRow | null = null;
    try {
      const rows = (await sql`
        SELECT id, title, category, tags, audio_key, cover_key, mime, duration_ms,
               sort_order, is_published
        FROM ringtones WHERE id = ${id} LIMIT 1
      `) as unknown as RtRow[];
      row = rows[0] ?? null;
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] edit load error:`, err);
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }
    if (!row) {
      if (c.req.header("HX-Request") === "true") {
        return c.html(<div class="note danger">Ringtone not found — it may have been deleted.</div>);
      }
      return c.redirect(`${base}?err=` + encodeURIComponent("Ringtone not found"));
    }
    if (c.req.header("HX-Request") === "true") return c.html(<RingtoneForm mode="edit" row={row} />);
    return c.html(<FormPage mode="edit" row={row} />);
  });

  // ── Create (single + batch via items_json) ──────────────────────────────────
  ringtonesApp.post("/", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const category = categorySlug(formStr(form, "category"));
    if (!category) {
      return c.redirect(`${base}/new?err=` + encodeURIComponent("Category is required"));
    }
    const published = parseBool(form.is_published);

    // ── Batch: the uploader PUT N audio+cover pairs to R2 and posted the set as
    //    items_json — N rows + ONE version bump + ONE rebuild.
    const itemsJson = formStr(form, "items_json");
    if (itemsJson) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(itemsJson);
      } catch {
        return c.redirect(`${base}?err=` + encodeURIComponent("Upload data was not valid JSON"));
      }
      if (!Array.isArray(parsed) || parsed.length === 0) {
        return c.redirect(`${base}?err=` + encodeURIComponent("No files to upload"));
      }
      interface Item {
        id: string;
        title: string;
        audioKey: string;
        coverKey: string;
        mime: string;
        durationMs: number | null;
        bytes: number | null;
      }
      let items: Item[];
      try {
        items = parsed.map((raw) => {
          const o = raw as Record<string, unknown>;
          const audioKey = typeof o.audio_key === "string" ? o.audio_key : "";
          const coverKey = typeof o.cover_key === "string" ? o.cover_key : "";
          const m = typeof o.mime === "string" ? o.mime : "";
          const title = typeof o.title === "string" ? o.title.trim() : "";
          const iid =
            typeof o.id === "string" && /^[0-9a-f-]{36}$/i.test(o.id) ? o.id : crypto.randomUUID();
          if (!audioKey) throw new Error("Upload rejected: a file is missing its audio upload key");
          if (!coverKey) {
            throw new Error(
              `Upload rejected: "${truncateForMessage(title || audioKey)}" has no cover image key — every ringtone needs a cover`,
            );
          }
          for (const key of [audioKey, coverKey]) {
            if (key.includes("..")) {
              throw new Error(
                `Upload rejected: key "${truncateForMessage(key)}" contains an illegal path segment`,
              );
            }
            if (key.length > 300) throw new Error("Upload rejected: key exceeds 300 characters");
          }
          if (!m.startsWith("audio/")) {
            throw new Error(
              `Upload rejected: unsupported audio type ${truncateForMessage(m || "(empty)")}`,
            );
          }
          if (!title) throw new Error("Upload rejected: a file produced an empty title");
          const dRaw = o.duration_ms;
          const durationMs =
            typeof dRaw === "number" && Number.isFinite(dRaw) ? Math.round(dRaw) : null;
          const bRaw = o.bytes;
          const bytes = typeof bRaw === "number" && Number.isFinite(bRaw) ? Math.round(bRaw) : null;
          return { id: iid, title, audioKey, coverKey, mime: m, durationMs, bytes };
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Upload data was invalid";
        return c.redirect(`${base}?err=` + encodeURIComponent(msg));
      }

      const sqlB = getDb(c.env, app);
      try {
        await sqlB.begin(async (tx) => {
          for (const it of items) {
            await tx`
              INSERT INTO ringtones (id, title, category, audio_key, cover_key, mime, duration_ms, bytes, is_published)
              VALUES (${it.id}, ${it.title}, ${category}, ${it.audioKey}, ${it.coverKey}, ${it.mime}, ${it.durationMs}, ${it.bytes}, ${published})
            `;
          }
          await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
        });
      } catch (err) {
        console.error(`[cms/${app.slug}/ringtones] batch create error:`, err);
        // Nothing was inserted — clean up EVERY uploaded object (audio + cover).
        const r2 = app.r2(c.env);
        for (const it of items) {
          c.executionCtx.waitUntil(r2.delete(it.audioKey).catch(() => {}));
          c.executionCtx.waitUntil(r2.delete(it.coverKey).catch(() => {}));
        }
        c.executionCtx.waitUntil(sqlB.end());
        return c.redirect(`${base}?err=` + encodeURIComponent("Could not save ringtones"));
      }
      c.executionCtx.waitUntil(sqlB.end());

      const okB = await triggerRebuild(c.env, app);
      return c.redirect(
        `${base}?` +
          (okB
            ? "ok=" + encodeURIComponent(`${items.length} ringtone${items.length === 1 ? "" : "s"} created`)
            : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
      );
    }

    // ── Single create ──
    const title = formStr(form, "title");
    const audioKey = formStr(form, "key_audio");
    const mime = formStr(form, "mime_audio");
    const coverKey = formStr(form, "key_cover");
    if (!title) return c.redirect(`${base}/new?err=` + encodeURIComponent("Title is required"));
    if (!audioKey || !mime) {
      return c.redirect(`${base}/new?err=` + encodeURIComponent("Audio upload did not complete"));
    }
    if (!coverKey) {
      // The audio object already landed in R2 — remove the orphan before rejecting.
      c.executionCtx.waitUntil(app.r2(c.env).delete(audioKey).catch(() => {}));
      return c.redirect(
        `${base}/new?err=` +
          encodeURIComponent("Cover image upload did not complete — a 512×512 JPG cover is required"),
      );
    }
    const durRaw = parseInt(formStr(form, "duration_ms"), 10);
    const durationMs = Number.isFinite(durRaw) ? durRaw : null;
    const bytesRaw = parseInt(formStr(form, "bytes_audio"), 10);
    const bytes = Number.isFinite(bytesRaw) ? bytesRaw : null;
    const id = formStr(form, "id_audio") || crypto.randomUUID();

    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        await tx`
          INSERT INTO ringtones (id, title, category, audio_key, cover_key, mime, duration_ms, bytes, is_published)
          VALUES (${id}, ${title}, ${category}, ${audioKey}, ${coverKey}, ${mime}, ${durationMs}, ${bytes}, ${published})
        `;
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] create error:`, err);
      // Insert failed — delete BOTH orphaned objects (audio + cover).
      c.executionCtx.waitUntil(app.r2(c.env).delete(audioKey).catch(() => {}));
      c.executionCtx.waitUntil(app.r2(c.env).delete(coverKey).catch(() => {}));
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}/new?err=` + encodeURIComponent("Could not save ringtone"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Ringtone created")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  // ── Bulk actions — MUST register before POST /:id (Hono matches in order) ────
  // publish | unpublish | category | delete on a set of ids: ONE transaction,
  // ONE version bump, ONE rebuild. Delete removes audio + cover bytes only
  // after a confirmed rebuild. Category change updates the row only — stored
  // keys stay valid wherever they live (keys are read from the DB, never
  // re-derived from the category).
  ringtonesApp.post("/bulk", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const action = formStr(form, "bulk_action");
    if (!["publish", "unpublish", "category", "delete"].includes(action)) {
      return c.redirect(`${base}?err=` + encodeURIComponent("Unknown bulk action"));
    }
    const ids = formStr(form, "ids")
      .split(",")
      .map((s) => s.trim())
      .filter((s) => /^[0-9a-f-]{36}$/i.test(s));
    if (ids.length === 0) {
      return c.redirect(`${base}?err=` + encodeURIComponent("Select at least one ringtone"));
    }
    let targetCategory: string | null = null;
    if (action === "category") {
      targetCategory = categorySlug(formStr(form, "bulk_category"));
      if (!targetCategory) {
        return c.redirect(`${base}?err=` + encodeURIComponent("Choose a target category"));
      }
    }

    const sql = getDb(c.env, app);
    let keys: { audio: string; cover: string | null }[] = [];
    let matchedCount = 0;
    try {
      const found = (await sql`
        SELECT id, audio_key, cover_key FROM ringtones WHERE id = ANY(${ids})
      `) as unknown as { id: string; audio_key: string; cover_key: string | null }[];
      if (found.length === 0) {
        c.executionCtx.waitUntil(sql.end());
        return c.redirect(
          `${base}?err=` + encodeURIComponent("None of the selected ringtones were found"),
        );
      }
      matchedCount = found.length;
      if (action === "delete") {
        keys = found.map((r) => ({ audio: r.audio_key, cover: r.cover_key }));
      }
      await sql.begin(async (tx) => {
        if (action === "delete") {
          await tx`DELETE FROM ringtones WHERE id = ANY(${ids})`;
        } else if (action === "category") {
          await tx`UPDATE ringtones SET category = ${targetCategory} WHERE id = ANY(${ids})`;
        } else {
          await tx`
            UPDATE ringtones SET is_published = ${action === "publish"} WHERE id = ANY(${ids})
          `;
        }
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] bulk ${action} error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}?err=` + encodeURIComponent("Bulk action failed"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    if (ok && action === "delete") {
      const r2 = app.r2(c.env);
      for (const k of keys) {
        c.executionCtx.waitUntil(r2.delete(k.audio).catch(() => {}));
        if (k.cover) c.executionCtx.waitUntil(r2.delete(k.cover).catch(() => {}));
      }
    }
    const verb =
      action === "delete"
        ? "deleted"
        : action === "publish"
          ? "published"
          : action === "unpublish"
            ? "unpublished"
            : `moved to ${targetCategory}`;
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" +
            encodeURIComponent(`${matchedCount} ringtone${matchedCount === 1 ? "" : "s"} ${verb}`)
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  // ── Update — title/category/tags/sort_order; audio and cover replaceable
  //    independently. Publish state is owned by the list-page toggle (left out
  //    of the UPDATE so it is preserved). ─────────────────────────────────────
  ringtonesApp.post("/:id", async (c) => {
    const id = c.req.param("id");
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const title = formStr(form, "title");
    if (!title) {
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Title is required"));
    }
    const category = categorySlug(formStr(form, "category"));
    if (!category) {
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Category is required"));
    }
    const tags = formStr(form, "tags")
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    const sortRaw = parseInt(formStr(form, "sort_order"), 10);
    const sortOrder = Number.isFinite(sortRaw) ? sortRaw : 0;

    const newAudio = formStr(form, "key_audio");
    const newMime = formStr(form, "mime_audio");
    const replaceAudio = newAudio !== "" && newMime !== "";
    const newCover = formStr(form, "key_cover");
    const replaceCover = newCover !== "";
    const durRaw = parseInt(formStr(form, "duration_ms"), 10);
    const durationMs = Number.isFinite(durRaw) ? durRaw : null;
    const bytesRaw = parseInt(formStr(form, "bytes_audio"), 10);
    const bytes = Number.isFinite(bytesRaw) ? bytesRaw : null;

    const sql = getDb(c.env, app);
    let oldAudio: string | null = null;
    let oldCover: string | null = null;
    try {
      if (replaceAudio || replaceCover) {
        const prev = (await sql`
          SELECT audio_key, cover_key FROM ringtones WHERE id = ${id} LIMIT 1
        `) as unknown as { audio_key: string; cover_key: string | null }[];
        oldAudio = prev[0]?.audio_key ?? null;
        oldCover = prev[0]?.cover_key ?? null;
      }
      await sql.begin(async (tx) => {
        await tx`
          UPDATE ringtones SET
            title = ${title}, category = ${category},
            tags = ${toPgTextArray(tags)}::text[], sort_order = ${sortOrder}
          WHERE id = ${id}
        `;
        if (replaceAudio) {
          await tx`
            UPDATE ringtones SET audio_key = ${newAudio}, mime = ${newMime},
              duration_ms = ${durationMs}, bytes = ${bytes}
            WHERE id = ${id}
          `;
        }
        if (replaceCover) {
          await tx`UPDATE ringtones SET cover_key = ${newCover} WHERE id = ${id}`;
        }
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] update error:`, err);
      // The replacement objects are orphans now — clean them up.
      if (replaceAudio) c.executionCtx.waitUntil(app.r2(c.env).delete(newAudio).catch(() => {}));
      if (replaceCover) c.executionCtx.waitUntil(app.r2(c.env).delete(newCover).catch(() => {}));
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Could not save changes"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    // Replaced bytes go only after a CONFIRMED rebuild — a still-stale catalog
    // must never point at a missing object.
    if (ok) {
      if (replaceAudio && oldAudio && oldAudio !== newAudio) {
        c.executionCtx.waitUntil(app.r2(c.env).delete(oldAudio).catch(() => {}));
      }
      if (replaceCover && oldCover && oldCover !== newCover) {
        c.executionCtx.waitUntil(app.r2(c.env).delete(oldCover).catch(() => {}));
      }
    }
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Ringtone updated")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  // ── Publish toggle ──────────────────────────────────────────────────────────
  ringtonesApp.post("/:id/publish", async (c) => {
    const id = c.req.param("id");
    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        await tx`UPDATE ringtones SET is_published = NOT is_published WHERE id = ${id}`;
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] publish toggle error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}?err=` + encodeURIComponent("Could not change status"));
    }
    c.executionCtx.waitUntil(sql.end());
    const ok = await triggerRebuild(c.env, app);
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Status updated")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  // ── Delete ──────────────────────────────────────────────────────────────────
  ringtonesApp.post("/:id/delete", async (c) => {
    const id = c.req.param("id");
    const sql = getDb(c.env, app);
    let audioKey: string | null = null;
    let coverKey: string | null = null;
    try {
      const rows = (await sql`
        SELECT audio_key, cover_key FROM ringtones WHERE id = ${id} LIMIT 1
      `) as unknown as { audio_key: string; cover_key: string | null }[];
      if (rows.length === 0) {
        c.executionCtx.waitUntil(sql.end());
        return c.redirect(`${base}?err=` + encodeURIComponent("Ringtone not found"));
      }
      audioKey = rows[0]!.audio_key;
      coverKey = rows[0]!.cover_key;
      await sql.begin(async (tx) => {
        await tx`DELETE FROM ringtones WHERE id = ${id}`;
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] delete error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}?err=` + encodeURIComponent("Could not delete ringtone"));
    }
    c.executionCtx.waitUntil(sql.end());

    // Rebuild so the catalog no longer references the objects, THEN drop bytes.
    const ok = await triggerRebuild(c.env, app);
    if (ok) {
      if (audioKey) c.executionCtx.waitUntil(app.r2(c.env).delete(audioKey).catch(() => {}));
      if (coverKey) c.executionCtx.waitUntil(app.r2(c.env).delete(coverKey).catch(() => {}));
    }
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Ringtone deleted")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  return ringtonesApp;
}
