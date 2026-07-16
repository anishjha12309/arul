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
  /** created_at as YYYY-MM-DD (list column; absent on edit-form loads). */
  created?: string;
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
          <input name="title" type="text" required autofocus value={r?.title ?? ""} />
        </label>

        {app.hasCategories ? (
          <label class="field">
            <span class="lab">Category</span>
            <input
              name="category"
              type="text"
              required
              list="wp-cats"
              placeholder="e.g. murugan"
              value={r?.category ?? ""}
            />
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
          <span class="lab">{isEdit ? "Replace media (optional)" : "Media file(s)"}</span>
          <input
            type="file"
            data-slot="main"
            {...(isEdit ? {} : { "data-required": "1", multiple: true })}
            accept="image/jpeg,image/png,image/webp,video/mp4"
          />
          {isEdit && r ? <span class="hint keyline">Current: {r.full_key}</span> : null}
          <span class="hint">
            JPG/PNG/WebP = static · MP4 = live. Run ffmpeg locally first (no server transcode).
            {isEdit ? "" : " Select several files to create a batch — the title gets numbered per file."}
          </span>
        </label>
        <input type="hidden" name="key_main" value="" />
        <input type="hidden" name="mime_main" value="" />
        <input type="hidden" name="id_main" value="" />
        {isEdit ? null : <input type="hidden" name="items_json" value="" />}

        {isEdit ? null : (
          <label class="check">
            <input name="is_published" type="checkbox" checked />
            <span>Published (visible in the app feed)</span>
          </label>
        )}

        <div class="row" style="margin-top:18px;justify-content:flex-end">
          <span class="muted" data-upload-status style="color:var(--accent-text);margin-right:auto"></span>
          <button type="button" class="btn sec" data-dialog-close>
            Cancel
          </button>
          <button type="submit" class="btn">
            {isEdit ? "Save changes" : "Create wallpaper"}
          </button>
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
          SELECT id, title, type, category, full_key, is_published,
                 to_char(created_at, 'YYYY-MM-DD') AS created
          FROM wallpapers
          ORDER BY sort_order ASC, created_at DESC
        `) as unknown as WpRow[];
      } else {
        rows = (await sql`
          SELECT id, title, type, full_key, is_published,
                 to_char(created_at, 'YYYY-MM-DD') AS created
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
              <select data-filter="3" aria-label="Filter by type">
                <option value="">All types</option>
                <option value="static">Static</option>
                <option value="live">Live</option>
              </select>
              <select data-filter={app.hasCategories ? "5" : "4"} aria-label="Filter by status">
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
            {/* Bulk bar — hidden until a row is selected; buttons stamp bulk_action. */}
            <form method="post" action={`${base}/bulk`} class="bulkbar" data-bulk-bar>
              <span data-bulk-count>0 selected</span>
              <input type="hidden" name="ids" value="" />
              <input type="hidden" name="bulk_action" value="" />
              <button type="button" class="btn sec sm" data-bulk-act="publish">
                Publish
              </button>
              <button type="button" class="btn sec sm" data-bulk-act="unpublish">
                Unpublish
              </button>
              <button type="button" class="btn danger sm" data-bulk-act="delete">
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
                      Type <span class="arrow" />
                    </th>
                    {app.hasCategories ? (
                      <th class="sortable" data-type="text">
                        Category <span class="arrow" />
                      </th>
                    ) : null}
                    <th>Status</th>
                    <th>ID</th>
                    <th class="sortable" data-type="text">
                      Added <span class="arrow" />
                    </th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
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
                      <td style="color:var(--muted)">{r.type}</td>
                      {app.hasCategories ? (
                        <td class="colcat" title={r.category ?? ""}>
                          {r.category ?? "—"}
                        </td>
                      ) : null}
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
                        {/* Short id for the eye; hidden full id + R2 key feed the
                            client-side search, so pasting either finds the row. */}
                        <span class="idcode" title={r.id}>
                          {r.id.slice(0, 8)}
                        </span>
                        <span class="keysearch">
                          {r.id} {r.full_key}
                        </span>
                      </td>
                      <td class="coldate">{r.created ?? "—"}</td>
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
            {/* Grid view — same rows as visual cards. LIST_JS mirrors filter/sort/
                page state onto it (data-grid-id ↔ tr data-id); BULK_JS keeps the
                card checkbox in sync with the table one. Click a card to edit. */}
            <div class="pickgrid" data-grid style="display:none">
              {rows.map((r) => {
                const thumbSrc =
                  r.type === "static"
                    ? `${cdn}/${r.full_key}`
                    : app.thumbKeyFor?.(r.full_key)
                      ? `${cdn}/${app.thumbKeyFor?.(r.full_key)}`
                      : null;
                const hx = {
                  "data-dialog-target": "wp-edit",
                  "hx-get": `${base}/${r.id}/edit`,
                  "hx-target": "#wp-edit-body",
                  "hx-swap": "innerHTML",
                };
                return (
                  <div class={`pick gcard${r.is_published ? "" : " draft"}`} data-grid-id={r.id}>
                    {thumbSrc ? (
                      <img
                        class="gimg"
                        src={thumbSrc}
                        alt=""
                        loading="lazy"
                        onerror={`this.onerror=null;this.outerHTML='<span class="gfmark">\\u25b6</span>'`}
                        {...hx}
                      />
                    ) : (
                      <span class="gfmark" {...hx}>
                        ▶
                      </span>
                    )}
                    {r.type === "live" ? <span class="pick-live">LIVE</span> : null}
                    {r.is_published ? null : <span class="gdraft">draft</span>}
                    <span class="pick-title">
                      {r.title} · {r.id.slice(0, 8)}
                    </span>
                    <input type="checkbox" data-bulk-id={r.id} aria-label="Select" />
                  </div>
                );
              })}
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
    // ── Batch create ── the uploader put N files directly to R2 and posted the
    // whole set as items_json: N rows + ONE version bump + ONE rebuild.
    const itemsJson = formStr(form, "items_json");
    if (itemsJson) {
      let items: { key: string; mime: string; id: string }[];
      try {
        const parsed = JSON.parse(itemsJson) as unknown;
        if (!Array.isArray(parsed) || parsed.length === 0) throw new Error("empty");
        items = parsed.map((raw) => {
          const o = raw as Record<string, unknown>;
          const key = typeof o.key === "string" ? o.key : "";
          const m = typeof o.mime === "string" ? o.mime : "";
          const iid =
            typeof o.id === "string" && /^[0-9a-f-]{36}$/i.test(o.id) ? o.id : crypto.randomUUID();
          if (!key || key.includes("..") || key.length > 300) throw new Error("bad key");
          if (m !== "video/mp4" && !m.startsWith("image/")) throw new Error("bad mime");
          return { key, mime: m, id: iid };
        });
      } catch {
        return c.redirect(`${base}/new?err=` + encodeURIComponent("Batch upload data was invalid"));
      }

      const publishedB = parseBool(form.is_published);
      const sqlB = getDb(c.env, app);
      try {
        await sqlB.begin(async (tx) => {
          for (let i = 0; i < items.length; i++) {
            const it = items[i]!;
            const rowTitle = items.length > 1 ? `${title} ${i + 1}` : title;
            const rowType = it.mime === "video/mp4" ? "live" : "static";
            if (app.hasCategories) {
              await tx`
                INSERT INTO wallpapers (id, title, type, category, full_key, mime, is_published)
                VALUES (${it.id}, ${rowTitle}, ${rowType}, ${category}, ${it.key}, ${it.mime}, ${publishedB})
              `;
            } else {
              await tx`
                INSERT INTO wallpapers (id, title, type, full_key, mime, is_published)
                VALUES (${it.id}, ${rowTitle}, ${rowType}, ${it.key}, ${it.mime}, ${publishedB})
              `;
            }
          }
          await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
        });
      } catch (err) {
        console.error(`[cms/${app.slug}/wallpapers] batch create error:`, err);
        // Nothing was inserted — clean up every uploaded object (+ video thumbs).
        const r2 = app.r2(c.env);
        for (const it of items) {
          c.executionCtx.waitUntil(r2.delete(it.key).catch(() => {}));
          const tk = it.mime === "video/mp4" ? app.thumbKeyFor?.(it.key) : null;
          if (tk) c.executionCtx.waitUntil(r2.delete(tk).catch(() => {}));
        }
        c.executionCtx.waitUntil(sqlB.end());
        return c.redirect(`${base}/new?err=` + encodeURIComponent("Could not save wallpapers"));
      }
      c.executionCtx.waitUntil(sqlB.end());

      const okB = await triggerRebuild(c.env, app);
      return c.redirect(
        `${base}?` +
          (okB
            ? "ok=" + encodeURIComponent(`${items.length} wallpapers created`)
            : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
      );
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
      const failedThumb = mime === "video/mp4" ? app.thumbKeyFor?.(fullKey) : null;
      if (failedThumb) c.executionCtx.waitUntil(app.r2(c.env).delete(failedThumb).catch(() => {}));
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

  // ── Bulk actions ────────────────────────────────────────────────────────────
  // POST /bulk — publish | unpublish | delete a set of ids in ONE transaction
  // with ONE version bump + ONE rebuild. Delete removes R2 media (+ derived
  // thumbs) only after a confirmed rebuild, mirroring the single-row flow.
  // MUST be registered before POST /:id — Hono matches in registration order,
  // so the param route would otherwise capture "bulk" as an id.
  wallpapersApp.post("/bulk", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const action = formStr(form, "bulk_action");
    const ids = formStr(form, "ids")
      .split(",")
      .map((s) => s.trim())
      .filter((s) => /^[0-9a-f-]{36}$/i.test(s));
    if (ids.length === 0 || !["publish", "unpublish", "delete"].includes(action)) {
      return c.redirect(`${base}?err=` + encodeURIComponent("Nothing selected"));
    }

    const sql = getDb(c.env, app);
    let keys: string[] = [];
    try {
      if (action === "delete") {
        const rows = (await sql`
          SELECT full_key FROM wallpapers WHERE id = ANY(${ids})
        `) as unknown as { full_key: string }[];
        keys = rows.map((r) => r.full_key);
      }
      await sql.begin(async (tx) => {
        if (action === "delete") {
          await tx`DELETE FROM wallpapers WHERE id = ANY(${ids})`;
        } else {
          await tx`
            UPDATE wallpapers SET is_published = ${action === "publish"} WHERE id = ANY(${ids})
          `;
        }
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/wallpapers] bulk ${action} error:`, err);
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}?err=` + encodeURIComponent("Bulk action failed"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    if (ok && action === "delete") {
      const r2 = app.r2(c.env);
      for (const key of keys) {
        c.executionCtx.waitUntil(r2.delete(key).catch(() => {}));
        const tk = app.thumbKeyFor?.(key);
        if (tk) c.executionCtx.waitUntil(r2.delete(tk).catch(() => {}));
      }
    }
    const verb =
      action === "delete" ? "deleted" : action === "publish" ? "published" : "unpublished";
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent(`${ids.length} wallpaper${ids.length === 1 ? "" : "s"} ${verb}`)
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
      if (hasNewMedia) {
        c.executionCtx.waitUntil(app.r2(c.env).delete(newKey).catch(() => {}));
        const nt = newMime === "video/mp4" ? app.thumbKeyFor?.(newKey) : null;
        if (nt) c.executionCtx.waitUntil(app.r2(c.env).delete(nt).catch(() => {}));
      }
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Could not save changes"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    // Delete the replaced object only after a CONFIRMED rebuild that no longer
    // references it; on rebuild failure keep the old bytes (benign) so nothing breaks.
    if (ok && hasNewMedia && oldKey && oldKey !== newKey) {
      c.executionCtx.waitUntil(app.r2(c.env).delete(oldKey).catch(() => {}));
      // Thumb keys are derived, never stored — clean the replaced video's thumb
      // too (delete is a no-op when the old media had none).
      const ot = app.thumbKeyFor?.(oldKey);
      if (ot) c.executionCtx.waitUntil(app.r2(c.env).delete(ot).catch(() => {}));
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
    if (ok && key) {
      c.executionCtx.waitUntil(app.r2(c.env).delete(key).catch(() => {}));
      // Derived thumb (live videos) — sweep never covers thumbs/, so the CMS
      // is the only cleaner. No-op when none exists.
      const tk = app.thumbKeyFor?.(key);
      if (tk) c.executionCtx.waitUntil(app.r2(c.env).delete(tk).catch(() => {}));
    }
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Wallpaper deleted")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  return wallpapersApp;
}
