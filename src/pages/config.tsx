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

    return c.html(
      <Layout title={`App config · ${app.label}`} active={navKey}>
        <PageHead title={`${app.label} app config`} sub={`content_version v${version}`}>
          <form method="post" action={`${base}/rebuild`}>
            <button type="submit" class="btn sec">
              Rebuild catalog now
            </button>
          </form>
        </PageHead>
        <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
        {dbError ? <div class="note danger">Could not load app_config.</div> : null}

        <form class="card" method="post" action={base} style="max-width:760px">
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
