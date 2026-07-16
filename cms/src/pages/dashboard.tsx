/**
 * Combined dashboard — app picker + per-app content counts, one card row per
 * app. Each app's stats come from ITS OWN DB (via the registry); a failure in
 * one app's DB never blanks the other's stats.
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";
import { APPS } from "../registry.js";
import { getDb } from "../lib/db.js";
import { Layout, PageHead, StatCard, appPath } from "../ui.js";

interface CatCount {
  category: string;
  pub: string;
  total: string;
}

interface AppStats {
  app: AppDef;
  wpTotal: string;
  wpPub: string;
  rtTotal: string | null; // null when the app has no ringtones
  rtPub: string | null;
  pending: string;
  version: string;
  cats: CatCount[] | null; // null when the app has no category axis
  dbError: boolean;
}

async function loadStats(c: Context<{ Bindings: Env }>, app: AppDef): Promise<AppStats> {
  const stats: AppStats = {
    app,
    wpTotal: "0",
    wpPub: "0",
    rtTotal: app.hasRingtones ? "0" : null,
    rtPub: app.hasRingtones ? "0" : null,
    pending: "0",
    version: "0",
    cats: app.hasCategories ? [] : null,
    dbError: false,
  };
  const sql = getDb(c.env, app);
  try {
    const rows = app.hasRingtones
      ? await sql`
          SELECT
            (SELECT count(*) FROM wallpapers)                                 AS wp_total,
            (SELECT count(*) FROM wallpapers WHERE is_published)              AS wp_pub,
            (SELECT count(*) FROM ringtones)                                  AS rt_total,
            (SELECT count(*) FROM ringtones WHERE is_published)               AS rt_pub,
            (SELECT count(*) FROM content_submissions WHERE status='pending') AS pending,
            (SELECT content_version FROM app_config WHERE id=1)               AS version
        `
      : await sql`
          SELECT
            (SELECT count(*) FROM wallpapers)                                 AS wp_total,
            (SELECT count(*) FROM wallpapers WHERE is_published)              AS wp_pub,
            (SELECT count(*) FROM content_submissions WHERE status='pending') AS pending,
            (SELECT content_version FROM app_config WHERE id=1)               AS version
        `;
    const r = (rows as unknown as Record<string, unknown>[])[0] ?? {};
    stats.wpTotal = String(r.wp_total ?? "0");
    stats.wpPub = String(r.wp_pub ?? "0");
    if (app.hasRingtones) {
      stats.rtTotal = String(r.rt_total ?? "0");
      stats.rtPub = String(r.rt_pub ?? "0");
    }
    stats.pending = String(r.pending ?? "0");
    stats.version = r.version == null ? "0" : String(r.version);
    if (app.hasCategories) {
      const cats = (await sql`
        SELECT category,
               count(*) FILTER (WHERE is_published) AS pub,
               count(*)                             AS total
        FROM wallpapers
        GROUP BY category
        ORDER BY category
      `) as unknown as { category: string; pub: unknown; total: unknown }[];
      stats.cats = cats.map((row) => ({
        category: row.category,
        pub: String(row.pub ?? "0"),
        total: String(row.total ?? "0"),
      }));
    }
  } catch (err) {
    console.error(`[cms/dashboard] ${app.slug} DB error:`, err);
    stats.dbError = true;
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
  return stats;
}

export async function handleDashboard(c: Context<{ Bindings: Env }>): Promise<Response> {
  const all = await Promise.all(APPS.map((app) => loadStats(c, app)));

  return c.html(
    <Layout title="Dashboard" active="dashboard">
      <PageHead title="Dashboard" sub="Pakiza + Arul content overview" />

      {all.map((s) => {
        const pendingN = Number(s.pending) || 0;
        return (
          <section style="margin-bottom:34px">
            <div class="row" style="margin-bottom:16px;gap:12px">
              <span style="font-size:17px;font-weight:700">{s.app.label}</span>
              <span class="chip">v{s.version}</span>
              <span class="grow" />
              <div class="actions">
                <a class="btn sec" href={appPath(s.app, "/wallpapers")}>
                  Wallpapers
                </a>
                {s.app.hasRingtones ? (
                  <a class="btn sec" href={appPath(s.app, "/ringtones")}>
                    Ringtones
                  </a>
                ) : null}
                {s.app.hasCategories ? (
                  <a class="btn sec" href={appPath(s.app, "/transfer")}>
                    Category transfer
                  </a>
                ) : null}
                <a class="btn gold-outline" href={appPath(s.app, "/submissions")}>
                  Review submissions{pendingN > 0 ? ` (${s.pending})` : ""}
                  {pendingN > 0 ? <span class="navdot" /> : null}
                </a>
              </div>
            </div>
            {s.dbError ? (
              <div class="note danger">
                Could not reach the {s.app.label} database. Check Hyperdrive / Neon.
              </div>
            ) : (
              <div class="grid">
                <StatCard n={s.wpPub} label="Published wallpapers" hint={`${s.wpTotal} total`} />
                {s.rtTotal !== null ? (
                  <StatCard n={s.rtPub ?? "0"} label="Published ringtones" hint={`${s.rtTotal} total`} />
                ) : null}
                <StatCard n={s.pending} label="Pending submissions" hint="awaiting review" />
                <StatCard n={`v${s.version}`} label="Catalog version" hint="content_version" />
                {s.cats && s.cats.length > 0 ? (
                  <div class="card" style="grid-column:span 2;min-width:260px">
                    <div
                      style="font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;
                        color:var(--label);margin-bottom:10px"
                    >
                      Published by category
                    </div>
                    <div style="display:flex;flex-direction:column;gap:7px">
                      {s.cats.map((cat) => {
                        const total = Number(cat.total) || 0;
                        const pub = Number(cat.pub) || 0;
                        const pct = total > 0 ? Math.round((pub / total) * 100) : 0;
                        return (
                          <div style="position:relative;display:flex;justify-content:space-between;align-items:center;padding:3px 8px;border-radius:4px;overflow:hidden">
                            <div
                              style={`position:absolute;inset:0;width:${pct}%;background:var(--accent-soft);border-right:2px solid rgba(217,164,65,.55)`}
                            />
                            <span style="position:relative;text-transform:capitalize;color:var(--body)">
                              {cat.category}
                            </span>
                            <span style="position:relative;font-variant-numeric:tabular-nums">
                              <strong>{cat.pub}</strong>
                              <span style="color:var(--faint);font-weight:500"> / {cat.total}</span>
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                ) : null}
              </div>
            )}
          </section>
        );
      })}
    </Layout>,
  );
}
