/**
 * CMS — app_config editor + manual rebuild, one factory serving both apps
 * (mounted at /{slug}/config). Copied from the shipped per-app CMSes.
 *
 * Edits the singleton app_config row (id=1): support_email,
 * min_supported_version, and the JSON blobs prices / policy_urls /
 * feature_flags. Saving bumps content_version in the same transaction, then
 * triggers the app Worker's rebuild so the new app_config.json ships
 * immediately. A separate "Rebuild now" button forces a rebuild without an
 * edit (also the retry path after a "rebuild failed" banner).
 */

import { Hono } from "hono";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";
import { getDb } from "../lib/db.js";
import { Flash, Layout, PageHead, appPath } from "../ui.js";
import { triggerRebuild, REBUILD_FAILED_MSG } from "../rebuild.js";
import { formStr } from "../lib/util.js";

interface CfgRow {
  content_version: string | number | null;
  prices: unknown;
  support_email: string | null;
  policy_urls: unknown;
  feature_flags: unknown;
  min_supported_version: string | null;
}

function pretty(v: unknown): string {
  try {
    if (typeof v === "string") {
      // fetch_types:false returns jsonb as text — re-pretty it for the editor.
      return JSON.stringify(JSON.parse(v), null, 2);
    }
    return JSON.stringify(v ?? {}, null, 2);
  } catch {
    return "{}";
  }
}

/** Parse + validate a JSON-object textarea; throws a friendly message on failure. */
function parseJsonObject(label: string, raw: string): Record<string, unknown> {
  const text = raw.trim();
  if (text === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`${label} is not valid JSON`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${label} must be a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

/**
 * CFG_JS — client-side JSON validation for the config editor.
 *
 * The server rejects bad JSON with a redirect that DROPS the operator's edits
 * (F1). This validates each textarea.mono on input (debounced) + blur, and
 * blocks submit until prices / policy_urls / feature_flags all parse to a plain
 * object. Empty is valid (treated as {} server-side). The form carries
 * data-own-busy so the shared BUSY_JS (which can't see this listener's
 * preventDefault) leaves the submit button alone — on a valid submit we set the
 * busy state ourselves.
 */
const CFG_JS = `
(function(){
  var form=document.getElementById('config-form'); if(!form)return;
  var areas=Array.prototype.slice.call(form.querySelectorAll('textarea.mono'));
  function errEl(ta,make){
    var el=ta.parentNode.querySelector('[data-json-err]');
    if(!el&&make){
      el=document.createElement('span'); el.className='hint'; el.setAttribute('data-json-err','');
      el.style.color='var(--danger)'; ta.parentNode.appendChild(el);
    }
    return el;
  }
  function mark(ta,msg){ ta.style.borderColor='var(--danger)'; var el=errEl(ta,true); el.textContent=msg; el.style.display='block'; }
  function clear(ta){ ta.style.borderColor=''; var el=errEl(ta,false); if(el){ el.textContent=''; el.style.display='none'; } }
  function validate(ta){
    var raw=(ta.value||'').trim();
    if(raw===''){ clear(ta); return true; }
    var parsed;
    try{ parsed=JSON.parse(raw); }catch(e){ mark(ta,'Invalid JSON: '+e.message); return false; }
    if(typeof parsed!=='object'||parsed===null||Array.isArray(parsed)){ mark(ta,'Must be a JSON object'); return false; }
    clear(ta); return true;
  }
  areas.forEach(function(ta){
    var t;
    ta.addEventListener('input',function(){ clearTimeout(t); t=setTimeout(function(){ validate(ta); },300); });
    ta.addEventListener('blur',function(){ clearTimeout(t); validate(ta); });
  });
  form.addEventListener('submit',function(e){
    var bad=null;
    areas.forEach(function(ta){ if(!validate(ta)&&!bad)bad=ta; });
    if(bad){
      e.preventDefault();
      bad.focus();
      if(window.cmsToast)window.cmsToast('Fix the invalid JSON before saving',{danger:true});
      return;
    }
    var btn=form.querySelector('[type=submit]');
    if(btn){ if(btn.dataset.origText==null)btn.dataset.origText=btn.textContent; btn.disabled=true; btn.classList.add('busy'); btn.textContent='Working\\u2026'; }
  });
})();
`;

export function makeConfigApp(app: AppDef): Hono<{ Bindings: Env }> {
  const configApp = new Hono<{ Bindings: Env }>();
  const base = appPath(app, "/config");
  const navKey = `${app.slug}:config`;

  configApp.get("/", async (c) => {
    const sql = getDb(c.env, app);
    let cfg: CfgRow | null = null;
    let dbError = false;
    try {
      const rows = (await sql`
        SELECT content_version, prices, support_email, policy_urls, feature_flags, min_supported_version
        FROM app_config WHERE id = 1 LIMIT 1
      `) as unknown as CfgRow[];
      cfg = rows[0] ?? null;
    } catch (err) {
      console.error(`[cms/${app.slug}/config] load error:`, err);
      dbError = true;
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }

    const version = cfg?.content_version == null ? "0" : String(cfg.content_version);

    // ── Live catalog pointer (C6): what version is actually published to the
    //    CDN right now vs the DB's content_version above. build-catalog writes
    //    catalog/version.json no-store as { content_version, built_at }.
    //    Best-effort with a short timeout — never blocks the page render. ──
    let live: { version: string; builtAt: string | null } | null = null;
    try {
      const res = await fetch(`${app.cdnBase.replace(/\/$/, "")}/catalog/version.json`, {
        cf: { cacheTtl: 0 },
        signal: AbortSignal.timeout(2500),
      });
      if (res.ok) {
        const j = (await res.json()) as { content_version?: unknown; built_at?: unknown };
        if (j && j.content_version != null) {
          live = {
            version: String(j.content_version),
            builtAt: typeof j.built_at === "string" ? j.built_at : null,
          };
        }
      }
    } catch {
      live = null;
    }

    return c.html(
      <Layout title={`App config · ${app.label}`} active={navKey}>
        <PageHead title={`${app.label} app config`} sub={`content_version v${version}`} subMono>
          <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px">
            <form method="post" action={`${base}/rebuild`} style="margin:0">
              <button type="submit" class="btn sec">
                Rebuild catalog now
              </button>
            </form>
            <span style="color:var(--muted);font-size:12px;text-align:right">
              Rebuild republishes the catalog JSON to the CDN.
            </span>
          </div>
        </PageHead>
        <div class="row" style="margin:-8px 0 20px">
          {live ? (
            <span class="chip">
              Live catalog: v{live.version}
              {live.builtAt ? ` · built ${live.builtAt}` : ""}
            </span>
          ) : (
            <span class="chip" style="color:var(--faint)">
              Live catalog: unreachable
            </span>
          )}
        </div>
        <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
        {dbError ? <div class="note danger">Could not load app_config.</div> : null}

        <form id="config-form" class="card" method="post" action={base} style="max-width:760px" data-own-busy>
          <div class="formgrid">
            <label class="field">
              <span class="lab">Support email</span>
              <input
                name="support_email"
                type="email"
                value={cfg?.support_email ?? ""}
                placeholder="support@hsrutility.com"
              />
            </label>
            <label class="field">
              <span class="lab">Minimum supported app version</span>
              <input
                name="min_supported_version"
                type="text"
                value={cfg?.min_supported_version ?? ""}
                placeholder="e.g. 1.0.0"
              />
            </label>
          </div>

          <label class="field">
            <span class="json-lab">
              prices <span class="json-lab-hint">(JSON object)</span>
            </span>
            <textarea class="mono" name="prices" rows={5} spellcheck={false}>{pretty(cfg?.prices)}</textarea>
          </label>

          <label class="field">
            <span class="json-lab">
              policy_urls <span class="json-lab-hint">(JSON object)</span>
            </span>
            <textarea class="mono" name="policy_urls" rows={4} spellcheck={false}>{pretty(cfg?.policy_urls)}</textarea>
          </label>

          <label class="field">
            <span class="json-lab">
              feature_flags <span class="json-lab-hint">(JSON object)</span>
            </span>
            <textarea class="mono" name="feature_flags" rows={5} spellcheck={false}>{pretty(cfg?.feature_flags)}</textarea>
          </label>

          <div class="row" style="margin-top:8px">
            <button type="submit" class="btn">
              Save &amp; rebuild
            </button>
          </div>
        </form>
        <script dangerouslySetInnerHTML={{ __html: CFG_JS }} />
      </Layout>,
    );
  });

  configApp.post("/", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const supportEmail = formStr(form, "support_email");
    const minVersion = formStr(form, "min_supported_version");

    let prices: Record<string, unknown>;
    let policyUrls: Record<string, unknown>;
    let featureFlags: Record<string, unknown>;
    try {
      prices = parseJsonObject("prices", formStr(form, "prices"));
      policyUrls = parseJsonObject("policy_urls", formStr(form, "policy_urls"));
      featureFlags = parseJsonObject("feature_flags", formStr(form, "feature_flags"));
    } catch (err) {
      return c.redirect(`${base}?err=` + encodeURIComponent((err as Error).message));
    }

    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        await tx`
          UPDATE app_config SET
            support_email = ${supportEmail || null},
            min_supported_version = ${minVersion || null},
            prices = ${JSON.stringify(prices)}::jsonb,
            policy_urls = ${JSON.stringify(policyUrls)}::jsonb,
            feature_flags = ${JSON.stringify(featureFlags)}::jsonb,
            content_version = content_version + 1
          WHERE id = 1
        `;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/config] save error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}?err=` + encodeURIComponent("Could not save config"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Config saved & catalog rebuilt")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  configApp.post("/rebuild", async (c) => {
    const ok = await triggerRebuild(c.env, app);
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Catalog rebuilt")
          : "err=" + encodeURIComponent("Rebuild failed — the app Worker did not accept the request")),
    );
  });

  return configApp;
}
