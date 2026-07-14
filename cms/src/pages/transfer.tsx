/**
 * CMS — Category Transfer (Arul only; mounted at /arul/transfer).
 *
 * Moves wallpapers from one category to another. Because Arul's R2 keys are
 * category-partitioned (wallpapers/<category>/<file>) a category change is a
 * KEY change, so the flow is copy-before-update, per selected wallpaper:
 *
 *   1. R2 (binding): copy wallpapers/<src>/<file> → wallpapers/<dst>/<file>
 *      (get+put), and thumbs/<src>/<stem>.jpg → thumbs/<dst>/<stem>.jpg IF the
 *      thumb exists (a missing thumb is NOT an error — thumbs are optional).
 *   2. One DB transaction for the whole batch: UPDATE each successfully-copied
 *      row (category + full_key) and bump content_version ONCE.
 *   3. Delete the OLD R2 objects (media + thumb) only AFTER the txn commits.
 *   4. Trigger the Arul Worker's catalog rebuild.
 *
 * Partial-failure semantics:
 *   - an item whose copy fails is excluded from the DB update and reported
 *     per-item; the other items still move (rows stay valid at every point
 *     because the new key exists before the row points at it).
 *   - if the DB txn itself fails nothing moved: new MEDIA copies are left for
 *     the app Worker's hourly canonical sweep (self-healing — it deletes
 *     unreferenced wallpapers/ objects), but new THUMB copies are explicitly
 *     deleted here because thumbs/ is NOT swept.
 *   - old-object deletion only happens after commit, so a crash before commit
 *     leaves the original objects untouched.
 */

import { Hono } from "hono";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";
import { arulThumbKey } from "../registry.js";
import { getDb } from "../lib/db.js";
import { Badge, Flash, Layout, PageHead, appPath } from "../ui.js";
import { triggerRebuild, REBUILD_FAILED_MSG } from "../rebuild.js";
import { formStr, formList, categorySlug, toPgTextArray } from "../lib/util.js";

interface WpRow {
  id: string;
  title: string;
  type: string;
  category: string;
  full_key: string;
}

interface ItemResult {
  id: string;
  title: string;
  fromKey: string;
  toKey: string;
  status: "moved" | "copy_failed" | "db_failed";
  detail?: string;
}

/** Copy one R2 object to a new key via the binding (get+put). Returns false when
 *  the source is missing. Throws on a put failure. */
async function bindingCopy(r2: R2Bucket, srcKey: string, dstKey: string): Promise<boolean> {
  const obj = await r2.get(srcKey);
  if (!obj) return false;
  await r2.put(dstKey, obj.body, obj.httpMetadata ? { httpMetadata: obj.httpMetadata } : {});
  return true;
}

export function makeTransferApp(app: AppDef): Hono<{ Bindings: Env }> {
  if (!app.hasCategories) {
    throw new Error(`category transfer mounted for an app without categories: ${app.slug}`);
  }
  const transferApp = new Hono<{ Bindings: Env }>();
  const base = appPath(app, "/transfer");
  const navKey = `${app.slug}:transfer`;

  // ── Page: pick source → grid of its wallpapers → pick target → confirm ──────
  transferApp.get("/", async (c) => {
    const source = categorySlug(c.req.query("source"));

    const sql = getDb(c.env, app);
    let categories: string[] = [];
    let rows: WpRow[] = [];
    let dbError = false;
    try {
      const cats = (await sql`
        SELECT DISTINCT category FROM wallpapers ORDER BY category ASC
      `) as unknown as { category: string }[];
      categories = cats.map((r) => r.category);
      if (source) {
        rows = (await sql`
          SELECT id, title, type, category, full_key
          FROM wallpapers
          WHERE category = ${source}
          ORDER BY sort_order ASC, created_at DESC
        `) as unknown as WpRow[];
      }
    } catch (err) {
      console.error(`[cms/${app.slug}/transfer] load error:`, err);
      dbError = true;
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }

    const cdn = app.cdnBase.replace(/\/$/, "");
    const targetSuggestions = Array.from(new Set([...app.knownCategories, ...categories])).filter(
      (cat) => cat !== source,
    );

    return c.html(
      <Layout title={`Category transfer · ${app.label}`} active={navKey}>
        <PageHead
          title="Category transfer"
          sub="Move wallpapers between categories — media and thumbs are re-keyed in R2"
        />
        <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
        {dbError ? <div class="note danger">Could not load wallpapers.</div> : null}

        <form class="card" method="get" action={base} style="max-width:480px;margin-bottom:22px">
          <label class="field">
            <span class="lab">Source category</span>
            <select name="source">
              <option value="">Choose a category…</option>
              {categories.map((cat) => (
                <option value={cat} selected={cat === source}>
                  {cat}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" class="btn sec">
            Load wallpapers
          </button>
        </form>

        {source && rows.length === 0 && !dbError ? (
          <div class="empty">
            <span class="emoji">🗂️</span>
            No wallpapers in “{source}”.
          </div>
        ) : null}

        {source && rows.length > 0 ? (
          <form
            method="post"
            action={base}
            data-pickscope
            data-confirm={`Move the selected wallpapers out of "${source}"? Media and thumbnails are copied to the new category, then the originals are removed.`}
          >
            <input type="hidden" name="source" value={source} />
            <div class="card" style="margin-bottom:18px">
              <div class="row" style="justify-content:space-between">
                <label class="check" style="margin:0">
                  <input type="checkbox" data-select-all />
                  <span>Select all ({rows.length})</span>
                </label>
                <span class="muted" style="color:var(--muted)" data-selected-count>
                  0 selected
                </span>
              </div>

              <div class="pickgrid">
                {rows.map((r) => {
                  const thumb = r.type === "static" ? `${cdn}/${r.full_key}` : `${cdn}/${arulThumbKey(r.full_key) ?? r.full_key}`;
                  return (
                    <label class="pick">
                      <img src={thumb} alt="" loading="lazy" />
                      {r.type === "live" ? <span class="pick-live">LIVE</span> : null}
                      <span class="pick-title">{r.title}</span>
                      <input type="checkbox" name="ids" value={r.id} />
                    </label>
                  );
                })}
              </div>

              <label class="field" style="max-width:360px">
                <span class="lab">Target category</span>
                <input name="target" type="text" required list="transfer-cats" placeholder="e.g. murugan" />
                <datalist id="transfer-cats">
                  {targetSuggestions.map((cat) => (
                    <option value={cat} />
                  ))}
                </datalist>
                <span class="hint">
                  Free text — a brand-new category is allowed (it appears as a new feed chip).
                </span>
              </label>

              <div class="row" style="margin-top:8px">
                <button type="submit" class="btn" data-transfer-go disabled>
                  Move selected wallpapers
                </button>
              </div>
            </div>
          </form>
        ) : null}
      </Layout>,
    );
  });

  // ── Execute the transfer ─────────────────────────────────────────────────────
  transferApp.post("/", async (c) => {
    const form = (await c.req.parseBody({ all: true })) as Record<string, unknown>;
    const source = categorySlug(formStr(form, "source"));
    const target = categorySlug(formStr(form, "target"));
    const ids = formList(form, "ids");

    const backErr = (msg: string) =>
      c.redirect(
        `${base}?` + (source ? `source=${encodeURIComponent(source)}&` : "") + "err=" + encodeURIComponent(msg),
      );

    if (!source) return backErr("Source category is required");
    if (!target) return backErr("Target category is required");
    if (target === source) return backErr("Target category must differ from the source");
    if (ids.length === 0) return backErr("Select at least one wallpaper");

    const r2 = app.r2(c.env);
    const sql = getDb(c.env, app);

    // Load ONLY rows that match both the selection and the claimed source
    // category (guards against a stale form racing another operator tab).
    let rows: WpRow[] = [];
    try {
      rows = (await sql`
        SELECT id, title, type, category, full_key
        FROM wallpapers
        WHERE id = ANY(${toPgTextArray(ids)}::uuid[]) AND category = ${source}
      `) as unknown as WpRow[];
    } catch (err) {
      console.error(`[cms/${app.slug}/transfer] select error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return backErr("Could not load the selected wallpapers");
    }
    if (rows.length === 0) {
      c.executionCtx.waitUntil(sql.end());
      return backErr(`None of the selected wallpapers are in "${source}" any more`);
    }

    const results: ItemResult[] = [];
    interface Prepared {
      row: WpRow;
      newKey: string;
      oldThumb: string | null;
      newThumb: string | null; // set only when a thumb was actually copied
    }
    const prepared: Prepared[] = [];

    // 1) Copy phase (media + optional thumb). Failures exclude the item from
    //    the DB update; already-made copies of a FAILED item are removed
    //    best-effort (media would self-heal via the sweep anyway; thumbs won't).
    for (const row of rows) {
      const file = row.full_key.split("/").pop() ?? "";
      const newKey = `wallpapers/${target}/${file}`;
      const oldThumb = arulThumbKey(row.full_key);
      const newThumb = oldThumb ? oldThumb.replace(`thumbs/${row.category}/`, `thumbs/${target}/`) : null;
      try {
        const mediaOk = await bindingCopy(r2, row.full_key, newKey);
        if (!mediaOk) {
          results.push({
            id: row.id,
            title: row.title,
            fromKey: row.full_key,
            toKey: newKey,
            status: "copy_failed",
            detail: "Source object missing in R2",
          });
          continue;
        }
        let thumbCopied = false;
        if (oldThumb && newThumb) {
          // Missing thumb is NOT an error; a failed PUT of an existing thumb is.
          thumbCopied = await bindingCopy(r2, oldThumb, newThumb);
        }
        prepared.push({
          row,
          newKey,
          oldThumb: thumbCopied ? oldThumb : null,
          newThumb: thumbCopied ? newThumb : null,
        });
      } catch (err) {
        console.error(`[cms/${app.slug}/transfer] copy error for ${row.id}:`, err);
        // Clean up this item's partial copies (best-effort).
        c.executionCtx.waitUntil(r2.delete(newKey).catch(() => {}));
        if (newThumb) c.executionCtx.waitUntil(r2.delete(newThumb).catch(() => {}));
        results.push({
          id: row.id,
          title: row.title,
          fromKey: row.full_key,
          toKey: newKey,
          status: "copy_failed",
          detail: err instanceof Error ? err.message : "copy failed",
        });
      }
    }

    // 2) DB phase — one transaction for the whole batch, ONE version bump.
    let rebuildOk: boolean | null = null;
    if (prepared.length > 0) {
      try {
        await sql.begin(async (tx) => {
          for (const p of prepared) {
            await tx`
              UPDATE wallpapers SET category = ${target}, full_key = ${p.newKey}
              WHERE id = ${p.row.id}
            `;
          }
          await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
        });

        // 3) Old objects go away only AFTER the commit (crash-safe ordering).
        for (const p of prepared) {
          c.executionCtx.waitUntil(r2.delete(p.row.full_key).catch(() => {}));
          if (p.oldThumb) c.executionCtx.waitUntil(r2.delete(p.oldThumb).catch(() => {}));
          results.push({
            id: p.row.id,
            title: p.row.title,
            fromKey: p.row.full_key,
            toKey: p.newKey,
            status: "moved",
          });
        }

        // 4) Rebuild so the app feed reflects the new categories.
        rebuildOk = await triggerRebuild(c.env, app);
      } catch (err) {
        console.error(`[cms/${app.slug}/transfer] db txn error:`, err);
        // Nothing moved. New MEDIA copies self-heal via the hourly canonical
        // sweep; new THUMBS must be removed here (thumbs/ is not swept).
        for (const p of prepared) {
          c.executionCtx.waitUntil(r2.delete(p.newKey).catch(() => {}));
          if (p.newThumb) c.executionCtx.waitUntil(r2.delete(p.newThumb).catch(() => {}));
          results.push({
            id: p.row.id,
            title: p.row.title,
            fromKey: p.row.full_key,
            toKey: p.newKey,
            status: "db_failed",
            detail: "Database update failed — nothing was moved",
          });
        }
      }
    }
    c.executionCtx.waitUntil(sql.end());

    const moved = results.filter((r) => r.status === "moved").length;
    const failed = results.length - moved;

    // Per-item report page (rendered directly — redirect would drop the detail).
    return c.html(
      <Layout title={`Transfer result · ${app.label}`} active={navKey}>
        <PageHead
          title="Transfer result"
          sub={`${source} → ${target} · ${moved} moved · ${failed} failed`}
        >
          <a class="btn sec" href={`${base}?source=${encodeURIComponent(source)}`}>
            Back to transfer
          </a>
        </PageHead>

        {moved > 0 && rebuildOk === true ? (
          <div class="note ok">
            Moved {moved} wallpaper{moved === 1 ? "" : "s"} to “{target}” and rebuilt the catalog.
          </div>
        ) : null}
        {moved > 0 && rebuildOk === false ? <div class="note warn">{REBUILD_FAILED_MSG}</div> : null}
        {failed > 0 ? (
          <div class="note danger">
            {failed} item{failed === 1 ? "" : "s"} failed — see the per-item report below. Nothing
            half-moved: a failed item keeps its original category, key and bytes.
          </div>
        ) : null}

        <div class="tablewrap">
          <table>
            <thead>
              <tr>
                <th>Title</th>
                <th>From</th>
                <th>To</th>
                <th>Result</th>
              </tr>
            </thead>
            <tbody>
              {results.map((r) => (
                <tr>
                  <td class="coltitle">
                    <strong>{r.title}</strong>
                  </td>
                  <td class="muted" style="color:var(--muted)">
                    {r.fromKey}
                  </td>
                  <td class="muted" style="color:var(--muted)">
                    {r.toKey}
                  </td>
                  <td>
                    {r.status === "moved" ? (
                      <Badge kind="ok">moved</Badge>
                    ) : (
                      <span class="row">
                        <Badge kind="danger">{r.status === "copy_failed" ? "copy failed" : "db failed"}</Badge>
                        {r.detail ? (
                          <span class="muted" style="color:var(--muted);font-size:12.5px">
                            {r.detail}
                          </span>
                        ) : null}
                      </span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Layout>,
    );
  });

  return transferApp;
}
