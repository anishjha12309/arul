/**
 * CMS — wallpapers authoring, one factory serving both apps (mounted at
 * /{slug}/wallpapers). Copied from the shipped per-app CMSes; the ONLY
 * structural difference between the two apps is the category axis:
 *
 *   arul   — wallpapers HAVE a NOT NULL category (browse axis + R2 key
 *            partition wallpapers/<category>/…): the form shows a category
 *            field (datalist, free text), list/create/update carry it.
 *   pakiza — NO category column (tags only, not surfaced in v1); keys use the
 *            posters/full split (owned by media.ts / the registry key scheme).
 *
 * Create: browser uploads bytes to a canonical R2 key (presigned PUT) BEFORE
 * the row is inserted, so a failed insert only leaves a benign orphan object
 * (which we also clean up). Every mutation bumps content_version in the same
 * transaction as the row write, then triggers the app Worker's rebuild.
 * Replaced/deleted media is removed from R2 only after a confirmed rebuild.
 */

import { Hono } from "hono";
import type { FC } from "hono/jsx";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";
import { getDb } from "../lib/db.js";
import { Badge, Flash, Layout, Modal, PageHead, appPath } from "../ui.js";
import { triggerRebuild, REBUILD_FAILED_MSG } from "../rebuild.js";
import { formStr, parseBool, categorySlug } from "../lib/util.js";

interface WpRow {
  id: string;
  title: string;
  type: string;
  category?: string;
  full_key: string;
  is_published: boolean;
}

export function makeWallpapersApp(app: AppDef): Hono<{ Bindings: Env }> {
  const wallpapersApp = new Hono<{ Bindings: Env }>();
  const base = appPath(app, "/wallpapers");
  const navKey = `${app.slug}:wallpapers`;

  // ── Form (new + edit) — fields only; hosted in a modal or a full page ──────
  const WallpaperForm: FC<{ mode: "new" | "edit"; row?: WpRow }> = (props) => {
    const r = props.row;
    const isEdit = props.mode === "edit";
    const action = isEdit ? `${base}/${r!.id}` : base;
    return (
      <form
        class="form"
        method="post"
        action={action}
        data-upload-form
        data-kind="wallpaper"
        data-presign={appPath(app, "/media/upload-url")}
      >
        <div class="note danger" data-upload-error style="display:none"></div>

        <label class="field">
          <span class="lab">Title</span>
          <input name="title" type="text" required value={r?.title ?? ""} />
        </label>

        {app.hasCategories ? (
          <label class="field">
            <span class="lab">Category</span>
            <input name="category" type="text" required list="wp-cats" value={r?.category ?? ""} />
            <datalist id="wp-cats">
              {app.knownCategories.map((cat) => (
                <option value={cat} />
              ))}
            </datalist>
            <span class="hint">
              Browse axis + R2 key prefix (wallpapers/&lt;category&gt;/…). Free text — a new
              category simply appears as a new feed chip.
            </span>
          </label>
        ) : null}

        <label class="field">
          <span class="lab">{isEdit ? "Replace media (optional)" : "Media file"}</span>
          <input
            type="file"
            data-slot="main"
            {...(isEdit ? {} : { "data-required": "1" })}
            accept="image/jpeg,image/png,image/webp,video/mp4"
          />
          <span class="hint">
            JPG/PNG/WebP = static · MP4 = live. Run ffmpeg locally first (no server transcode).
            {isEdit && r ? ` Current: ${r.full_key}` : ""}
          </span>
        </label>
        <input type="hidden" name="key_main" value="" />
        <input type="hidden" name="mime_main" value="" />
        <input type="hidden" name="id_main" value="" />

        {isEdit ? null : (
          <label class="check">
            <input name="is_published" type="checkbox" checked />
            <span>Published (visible in the app feed)</span>
          </label>
        )}

        <div class="row" style="margin-top:18px">
          <button type="submit" class="btn">
            {isEdit ? "Save changes" : "Create wallpaper"}
          </button>
          <span class="muted" data-upload-status style="color:var(--muted)"></span>
        </div>
      </form>
    );
  };

  // Full-page fallback wrapper (direct URL / no-JS); the modal path uses the form alone.
  const FormPage: FC<{ mode: "new" | "edit"; row?: WpRow }> = (props) => (
    <Layout
      title={`${props.mode === "edit" ? "Edit" : "New"} wallpaper · ${app.label}`}
      active={navKey}
    >
      <PageHead title={props.mode === "edit" ? "Edit wallpaper" : "New wallpaper"} sub={app.label}>
        <a class="btn sec" href={base}>
          Back
        </a>
      </PageHead>
      <div class="card">
        <WallpaperForm mode={props.mode} {...(props.row ? { row: props.row } : {})} />
      </div>
    </Layout>
  );

  // ── List ────────────────────────────────────────────────────────────────────
  wallpapersApp.get("/", async (c) => {
    const sql = getDb(c.env, app);
    let rows: WpRow[] = [];
    let dbError = false;
    try {
      if (app.hasCategories) {
        rows = (await sql`
          SELECT id, title, type, category, full_key, is_published
          FROM wallpapers
          ORDER BY sort_order ASC, created_at DESC
        `) as unknown as WpRow[];
      } else {
        rows = (await sql`
          SELECT id, title, type, full_key, is_published
          FROM wallpapers
          ORDER BY sort_order ASC, created_at DESC
        `) as unknown as WpRow[];
      }
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] list error:`, err);
      dbError = true;
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }

    const cdn = app.cdnBase.replace(/\/$/, "");
    return c.html(
      <Layout title={`Wallpapers · ${app.label}`} active={navKey}>
        <PageHead
          title={`${app.label} wallpapers`}
          sub={`${rows.length} ${rows.length === 1 ? "entry" : "entries"}`}
        >
          <button type="button" class="btn" data-dialog-target="wp-new">
            + New wallpaper
          </button>
        </PageHead>
        <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
        {dbError ? <div class="note danger">Could not load wallpapers.</div> : null}

        {rows.length === 0 ? (
          <div class="empty">
            <span class="emoji">🖼️</span>
            No wallpapers yet. Create the first one.
            <div class="cta">
              <button type="button" class="btn" data-dialog-target="wp-new">
                + New wallpaper
              </button>
            </div>
          </div>
        ) : (
          <div data-listview data-page="1">
            <div class="toolbar">
              <input class="search" type="text" data-search placeholder="Search wallpapers…" />
              <select data-filter="2" aria-label="Filter by type">
                <option value="">All types</option>
                <option value="static">Static</option>
                <option value="live">Live</option>
              </select>
              <select data-filter={app.hasCategories ? "4" : "3"} aria-label="Filter by status">
                <option value="">All statuses</option>
                <option value="published">Published</option>
                <option value="draft">Draft</option>
              </select>
              <span class="grow" />
              <select data-page-size aria-label="Rows per page">
                <option value="10">10 / page</option>
                <option value="20" selected>
                  20 / page
                </option>
                <option value="50">50 / page</option>
                <option value="0">All</option>
              </select>
            </div>
            <div class="tablewrap">
              <table>
                <thead>
                  <tr>
                    <th></th>
                    <th class="sortable" data-type="text">
                      Title <span class="arrow" />
                    </th>
                    <th class="sortable" data-type="text">
                      Type <span class="arrow" />
                    </th>
                    {app.hasCategories ? (
                      <th class="sortable" data-type="text">
                        Category <span class="arrow" />
                      </th>
                    ) : null}
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr>
                      <td>
                        {r.type === "static" ? (
                          <img class="thumb" src={`${cdn}/${r.full_key}`} alt="" loading="lazy" />
                        ) : app.thumbKeyFor?.(r.full_key) ? (
                          <img
                            class="thumb"
                            src={`${cdn}/${app.thumbKeyFor?.(r.full_key)}`}
                            alt=""
                            loading="lazy"
                            onerror={`this.onerror=null;this.outerHTML='<span class="filemark">▶</span>'`}
                          />
                        ) : (
                          <span class="filemark">▶</span>
                        )}
                      </td>
                      <td class="coltitle">
                        <strong>{r.title}</strong>
                      </td>
                      <td>{r.type}</td>
                      {app.hasCategories ? <td>{r.category ?? "—"}</td> : null}
                      <td>
                        <div class="row">
                          {r.is_published ? (
                            <Badge kind="ok">published</Badge>
                          ) : (
                            <Badge kind="muted">draft</Badge>
                          )}
                        </div>
                      </td>
                      <td>
                        <div class="rowact">
                          <button
                            type="button"
                            class="btn sec sm"
                            data-dialog-target="wp-edit"
                            hx-get={`${base}/${r.id}/edit`}
                            hx-target="#wp-edit-body"
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
                            data-confirm="Delete this wallpaper? This removes it from the app."
                          >
                            <button type="submit" class="btn danger sm">
                              Delete
                            </button>
                          </form>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div class="note muted" data-empty-filtered style="display:none">
              No wallpapers match your search.
            </div>
            <div class="pager" />
          </div>
        )}

        {/* Centered modals (create = inline form, edit = HTMX-loaded) */}
        <Modal id="wp-new" title="New wallpaper" wide>
          <WallpaperForm mode="new" />
        </Modal>
        <Modal id="wp-edit" title="Edit wallpaper" wide>
          <div id="wp-edit-body">
            <div class="modal-loading">Loading…</div>
          </div>
        </Modal>
      </Layout>,
    );
  });

  wallpapersApp.get("/new", (c) => {
    if (c.req.header("HX-Request") === "true") return c.html(<WallpaperForm mode="new" />);
    return c.html(<FormPage mode="new" />);
  });

  wallpapersApp.get("/:id/edit", async (c) => {
    const id = c.req.param("id");
    const sql = getDb(c.env, app);
    let row: WpRow | null = null;
    try {
      const rows = (app.hasCategories
        ? await sql`
            SELECT id, title, type, category, full_key, is_published
            FROM wallpapers WHERE id = ${id} LIMIT 1
          `
        : await sql`
            SELECT id, title, type, full_key, is_published
            FROM wallpapers WHERE id = ${id} LIMIT 1
          `) as unknown as WpRow[];
      row = rows[0] ?? null;
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] edit load error:`, err);
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }
    if (!row) {
      if (c.req.header("HX-Request") === "true") {
        return c.html(<div class="note danger">Wallpaper not found — it may have been deleted.</div>);
      }
      return c.redirect(`${base}?err=` + encodeURIComponent("Wallpaper not found"));
    }
    if (c.req.header("HX-Request") === "true") return c.html(<WallpaperForm mode="edit" row={row} />);
    return c.html(<FormPage mode="edit" row={row} />);
  });

  // ── Create ──────────────────────────────────────────────────────────────────
  wallpapersApp.post("/", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const title = formStr(form, "title");
    const fullKey = formStr(form, "key_main");
    const mime = formStr(form, "mime_main");
    const id = formStr(form, "id_main") || crypto.randomUUID();

    if (!title) return c.redirect(`${base}/new?err=` + encodeURIComponent("Title is required"));
    let category: string | null = null;
    if (app.hasCategories) {
      category = categorySlug(formStr(form, "category"));
      if (!category) {
        return c.redirect(`${base}/new?err=` + encodeURIComponent("Category is required"));
      }
    }
    if (!fullKey || !mime) {
      return c.redirect(`${base}/new?err=` + encodeURIComponent("Media upload did not complete"));
    }

    // type is derived from the upload MIME; tags/sort_order keep their DB defaults.
    const type = mime === "video/mp4" ? "live" : "static";
    const published = parseBool(form.is_published);

    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        if (app.hasCategories) {
          await tx`
            INSERT INTO wallpapers (id, title, type, category, full_key, mime, is_published)
            VALUES (${id}, ${title}, ${type}, ${category}, ${fullKey}, ${mime}, ${published})
          `;
        } else {
          await tx`
            INSERT INTO wallpapers (id, title, type, full_key, mime, is_published)
            VALUES (${id}, ${title}, ${type}, ${fullKey}, ${mime}, ${published})
          `;
        }
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] create error:`, err);
      // Insert failed — remove the orphan object we just uploaded (benign cleanup).
      c.executionCtx.waitUntil(app.r2(c.env).delete(fullKey).catch(() => {}));
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}/new?err=` + encodeURIComponent("Could not save wallpaper"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Wallpaper created")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  // ── Update ──────────────────────────────────────────────────────────────────
  // Only title / category / (optionally) the media file are editable. Publish
  // state and the unused tags/sort fields stay out of the UPDATE (preserved).
  wallpapersApp.post("/:id", async (c) => {
    const id = c.req.param("id");
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const title = formStr(form, "title");
    if (!title) {
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Title is required"));
    }
    let category: string | null = null;
    if (app.hasCategories) {
      category = categorySlug(formStr(form, "category"));
      if (!category) {
        return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Category is required"));
      }
    }

    // Optional media replacement.
    const newKey = formStr(form, "key_main");
    const newMime = formStr(form, "mime_main");
    const hasNewMedia = newKey !== "" && newMime !== "";
    const newType = newMime === "video/mp4" ? "live" : "static";

    const sql = getDb(c.env, app);
    let oldKey: string | null = null;
    try {
      if (hasNewMedia) {
        const prev = (await sql`SELECT full_key FROM wallpapers WHERE id = ${id} LIMIT 1`) as unknown as {
          full_key: string;
        }[];
        oldKey = prev[0]?.full_key ?? null;
      }
      await sql.begin(async (tx) => {
        if (app.hasCategories) {
          if (hasNewMedia) {
            await tx`
              UPDATE wallpapers SET
                title = ${title}, category = ${category},
                full_key = ${newKey}, mime = ${newMime}, type = ${newType}
              WHERE id = ${id}
            `;
          } else {
            await tx`UPDATE wallpapers SET title = ${title}, category = ${category} WHERE id = ${id}`;
          }
        } else {
          if (hasNewMedia) {
            await tx`
              UPDATE wallpapers SET
                title = ${title}, full_key = ${newKey}, mime = ${newMime}, type = ${newType}
              WHERE id = ${id}
            `;
          } else {
            await tx`UPDATE wallpapers SET title = ${title} WHERE id = ${id}`;
          }
        }
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] update error:`, err);
      if (hasNewMedia) c.executionCtx.waitUntil(app.r2(c.env).delete(newKey).catch(() => {}));
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Could not save changes"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    // Delete the replaced object only after a CONFIRMED rebuild that no longer
    // references it; on rebuild failure keep the old bytes (benign) so nothing breaks.
    if (ok && hasNewMedia && oldKey && oldKey !== newKey) {
      c.executionCtx.waitUntil(app.r2(c.env).delete(oldKey).catch(() => {}));
    }
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Wallpaper updated")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  // ── Publish toggle ──────────────────────────────────────────────────────────
  wallpapersApp.post("/:id/publish", async (c) => {
    const id = c.req.param("id");
    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        await tx`UPDATE wallpapers SET is_published = NOT is_published WHERE id = ${id}`;
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] publish toggle error:`, err);
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
  wallpapersApp.post("/:id/delete", async (c) => {
    const id = c.req.param("id");
    const sql = getDb(c.env, app);
    let key: string | null = null;
    try {
      const rows = (await sql`SELECT full_key FROM wallpapers WHERE id = ${id} LIMIT 1`) as unknown as {
        full_key: string;
      }[];
      key = rows[0]?.full_key ?? null;
      if (!key) {
        c.executionCtx.waitUntil(sql.end());
        return c.redirect(`${base}?err=` + encodeURIComponent("Wallpaper not found"));
      }
      await sql.begin(async (tx) => {
        await tx`DELETE FROM wallpapers WHERE id = ${id}`;
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] delete error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}?err=` + encodeURIComponent("Could not delete wallpaper"));
    }
    c.executionCtx.waitUntil(sql.end());

    // Rebuild so the catalog no longer references the object, THEN drop the bytes.
    // On rebuild failure keep the bytes — the still-stale catalog may reference them.
    const ok = await triggerRebuild(c.env, app);
    if (ok && key) c.executionCtx.waitUntil(app.r2(c.env).delete(key).catch(() => {}));
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Wallpaper deleted")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  return wallpapersApp;
}
