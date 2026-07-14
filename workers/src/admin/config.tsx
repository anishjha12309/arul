/**
 * CMS — app_config editor + manual rebuild (mounted at /admin/config).
 *
 * Edits the singleton app_config row (id=1): support_email, min_supported_version,
 * and the JSON blobs prices / policy_urls / feature_flags. The PUBLIC subset is
 * baked to catalog/app_config.json on every build — content_version and any
 * secret are NEVER written there (handled by build-catalog).
 *
 * Saving bumps content_version and rebuilds all scopes so the new app_config.json
 * ships immediately. A separate "Rebuild now" button forces a rebuild without an
 * edit (e.g. after a manual DB change).
 */

import { Hono } from "hono";
import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { Flash, Layout, PageHead } from "./ui.js";
import { rebuildOk } from "./publish.js";
import { formStr } from "./util.js";

export const configApp = new Hono<{ Bindings: Env }>();

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

configApp.get("/", async (c) => {
  const sql = getDb(c.env);
  let cfg: CfgRow | null = null;
  let dbError = false;
  let inSync = false;
  try {
    const rows = (await sql`
      SELECT content_version, prices, support_email, policy_urls, feature_flags, min_supported_version
      FROM app_config WHERE id = 1 LIMIT 1
    `) as unknown as CfgRow[];
    cfg = rows[0] ?? null;
    if (cfg) {
      const ver = cfg.content_version === null ? "0" : String(cfg.content_version);
      const lastBuilt = await c.env.KV.get("catalog_version:wallpapers");
      inSync = lastBuilt === ver;
    }
  } catch (err) {
    console.error("[admin/config] load error:", err);
    dbError = true;
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }

  const version = cfg?.content_version == null ? "0" : String(cfg.content_version);

  return c.html(
    <Layout title="App config" active="config">
      <PageHead title="App config" sub={`content_version v${version}`}>
        <form method="post" action="/admin/config/rebuild">
          <button type="submit" class="btn sec">
            Rebuild catalog now
          </button>
        </form>
      </PageHead>
      <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
      {dbError ? <div class="note danger">Could not load app_config.</div> : null}
      {!inSync && !dbError ? (
        <div class="note warn">The edge catalog is behind the current version — rebuild to sync.</div>
      ) : null}

      <form class="card" method="post" action="/admin/config" style="max-width:760px">
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
          <span class="lab">prices (JSON object)</span>
          <textarea class="mono" name="prices" rows={5}>{pretty(cfg?.prices)}</textarea>
        </label>

        <label class="field">
          <span class="lab">policy_urls (JSON object)</span>
          <textarea class="mono" name="policy_urls" rows={4}>{pretty(cfg?.policy_urls)}</textarea>
        </label>

        <label class="field">
          <span class="lab">feature_flags (JSON object)</span>
          <textarea class="mono" name="feature_flags" rows={5}>{pretty(cfg?.feature_flags)}</textarea>
        </label>

        <div class="row" style="margin-top:8px">
          <button type="submit" class="btn">
            Save &amp; rebuild
          </button>
        </div>
      </form>
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
    return c.redirect("/admin/config?err=" + encodeURIComponent((err as Error).message));
  }

  const sql = getDb(c.env);
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
    console.error("[admin/config] save error:", err);
    c.executionCtx.waitUntil(sql.end());
    return c.redirect("/admin/config?err=" + encodeURIComponent("Could not save config"));
  }
  c.executionCtx.waitUntil(sql.end());

  const ok = await rebuildOk(c.env, null);
  return c.redirect(
    "/admin/config?" +
      (ok
        ? "ok=" + encodeURIComponent("Config saved & catalog rebuilt")
        : "err=" + encodeURIComponent("Config saved, but the catalog rebuild failed — it will sync within the hour")),
  );
});

configApp.post("/rebuild", async (c) => {
  const ok = await rebuildOk(c.env, null);
  return c.redirect(
    "/admin/config?" +
      (ok ? "ok=" + encodeURIComponent("Catalog rebuilt") : "err=" + encodeURIComponent("Rebuild failed")),
  );
});
