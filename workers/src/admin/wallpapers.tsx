/**
 * CMS — wallpapers authoring (mounted at /admin/wallpapers).
 *
 * Create: browser uploads bytes to a canonical R2 key (presigned PUT) BEFORE the
 * row is inserted, so a failed insert only leaves a benign orphan object (which
 * we also clean up). Every mutation bumps content_version in the same
 * transaction as the row write, then rebuilds the wallpapers catalog + purges
 * the version pointer.
 *
 * The operator-set fields are the title, the CATEGORY (Arul's browse axis —
 * free text, also the R2 key partition) and the media file; `type`
 * (static vs live) is DERIVED from the uploaded MIME (image → static, mp4 →
 * live). tags / sort_order are unused in v1, so they keep their DB defaults and
 * are not surfaced here. Publish state is owned by the list Publish/Unpublish
 * button, so it is only set at create time.
 *
 * UI: list + a centered "New" modal (inline form) + an HTMX-loaded "Edit" modal.
 */

import { Hono } from "hono";
import type { FC } from "hono/jsx";
import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { Badge, Flash, Layout, Modal, PageHead } from "./ui.js";
import { rebuildOk } from "./publish.js";
import { categorySlug } from "./media.js";
import { formStr, parseBool } from "./util.js";

export const wallpapersApp = new Hono<{ Bindings: Env }>();

interface WpRow {
  id: string;
  title: string;
  type: string;
  category: string;
  full_key: string;
  is_published: boolean;
}

/** The seeded categories — offered as datalist suggestions; free text is allowed
 *  (a 7th category is an insert, not a migration — CLAUDE.md §5b). */
const KNOWN_CATEGORIES = ["amman", "ayyappan", "murugan", "perumal", "sivan", "temples"];

// ── List ──────────────────────────────────────────────────────────────────────
wallpapersApp.get("/", async (c) => {
  const sql = getDb(c.env);
  let rows: WpRow[] = [];
  let dbError = false;
  try {
    rows = (await sql`
      SELECT id, title, type, category, full_key, is_published
      FROM wallpapers
      ORDER BY sort_order ASC, created_at DESC
    `) as unknown as WpRow[];
  } catch (err) {
    console.error("[admin/wallpapers] list error:", err);
    dbError = true;
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }

  const cdn = c.env.R2_CDN_BASE_URL.replace(/\/$/, "");
  return c.html(
    <Layout title="Wallpapers" active="wallpapers">
      <PageHead title="Wallpapers" sub={`${rows.length} ${rows.length === 1 ? "entry" : "entries"}`}>
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
            <select data-filter="3" aria-label="Filter by status">
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
                      ) : (
                        <span class="filemark">▶</span>
                      )}
                    </td>
                    <td class="coltitle">
                      <strong>{r.title}</strong>
                    </td>
                    <td>{r.type}</td>
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
                          hx-get={`/admin/wallpapers/${r.id}/edit`}
                          hx-target="#wp-edit-body"
                          hx-swap="innerHTML"
                        >
                          Edit
                        </button>
                        <form method="post" action={`/admin/wallpapers/${r.id}/publish`}>
                          <button type="submit" class="btn sec sm">
                            {r.is_published ? "Unpublish" : "Publish"}
                          </button>
                        </form>
                        <form
                          method="post"
                          action={`/admin/wallpapers/${r.id}/delete`}
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

// ── Form (new + edit) — fields only; hosted in a modal or a full page ──────────
const WallpaperForm: FC<{ mode: "new" | "edit"; row?: WpRow }> = (props) => {
  const r = props.row;
  const isEdit = props.mode === "edit";
  const action = isEdit ? `/admin/wallpapers/${r!.id}` : "/admin/wallpapers";
  return (
    <form class="form" method="post" action={action} data-upload-form data-kind="wallpaper">
      <div class="note danger" data-upload-error style="display:none"></div>

      <label class="field">
        <span class="lab">Title</span>
        <input name="title" type="text" required value={r?.title ?? ""} />
      </label>

      <label class="field">
        <span class="lab">Category</span>
        <input name="category" type="text" required list="wp-cats" value={r?.category ?? ""} />
        <datalist id="wp-cats">
          {KNOWN_CATEGORIES.map((cat) => (
            <option value={cat} />
          ))}
        </datalist>
        <span class="hint">
          Browse axis + R2 key prefix (wallpapers/&lt;category&gt;/…). Free text — a new
          category simply appears as a new feed chip.
        </span>
      </label>

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
  <Layout title={props.mode === "edit" ? "Edit wallpaper" : "New wallpaper"} active="wallpapers">
    <PageHead title={props.mode === "edit" ? "Edit wallpaper" : "New wallpaper"}>
      <a class="btn sec" href="/admin/wallpapers">
        Back
      </a>
    </PageHead>
    <div class="card">
      <WallpaperForm mode={props.mode} {...(props.row ? { row: props.row } : {})} />
    </div>
  </Layout>
);

wallpapersApp.get("/new", (c) => {
  if (c.req.header("HX-Request") === "true") return c.html(<WallpaperForm mode="new" />);
  return c.html(<FormPage mode="new" />);
});

wallpapersApp.get("/:id/edit", async (c) => {
  const id = c.req.param("id");
  const sql = getDb(c.env);
  let row: WpRow | null = null;
  try {
    const rows = (await sql`
      SELECT id, title, type, category, full_key, is_published
      FROM wallpapers WHERE id = ${id} LIMIT 1
    `) as unknown as WpRow[];
    row = rows[0] ?? null;
  } catch (err) {
    console.error("[admin/wallpapers] edit load error:", err);
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
  if (!row) {
    if (c.req.header("HX-Request") === "true") {
      return c.html(<div class="note danger">Wallpaper not found — it may have been deleted.</div>);
    }
    return c.redirect("/admin/wallpapers?err=" + encodeURIComponent("Wallpaper not found"));
  }
  if (c.req.header("HX-Request") === "true") return c.html(<WallpaperForm mode="edit" row={row} />);
  return c.html(<FormPage mode="edit" row={row} />);
});

// ── Create ──────────────────────────────────────────────────────────────────────
wallpapersApp.post("/", async (c) => {
  const form = (await c.req.parseBody()) as Record<string, unknown>;
  const title = formStr(form, "title");
  const category = categorySlug(formStr(form, "category"));
  const fullKey = formStr(form, "key_main");
  const mime = formStr(form, "mime_main");
  const id = formStr(form, "id_main") || crypto.randomUUID();

  if (!title) return c.redirect("/admin/wallpapers/new?err=" + encodeURIComponent("Title is required"));
  if (!category) {
    return c.redirect("/admin/wallpapers/new?err=" + encodeURIComponent("Category is required"));
  }
  if (!fullKey || !mime) {
    return c.redirect("/admin/wallpapers/new?err=" + encodeURIComponent("Media upload did not complete"));
  }

  // type is derived from the upload MIME; tags/sort_order keep their
  // DB defaults ('{}', 0) — not surfaced in v1.
  const type = mime === "video/mp4" ? "live" : "static";
  const published = parseBool(form.is_published);

  const sql = getDb(c.env);
  try {
    await sql.begin(async (tx) => {
      await tx`
        INSERT INTO wallpapers (id, title, type, category, full_key, mime, is_published)
        VALUES (${id}, ${title}, ${type}, ${category}, ${fullKey}, ${mime}, ${published})
      `;
      await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
    });
  } catch (err) {
    console.error("[admin/wallpapers] create error:", err);
    // Insert failed — remove the orphan object we just uploaded (benign cleanup).
    c.executionCtx.waitUntil(c.env.R2.delete(fullKey).catch(() => {}));
    c.executionCtx.waitUntil(sql.end());
    return c.redirect("/admin/wallpapers/new?err=" + encodeURIComponent("Could not save wallpaper"));
  }
  c.executionCtx.waitUntil(sql.end());

  const ok = await rebuildOk(c.env, null);
  return c.redirect(
    "/admin/wallpapers?" +
      (ok
        ? "ok=" + encodeURIComponent("Wallpaper created")
        : "err=" + encodeURIComponent("Saved, but the catalog rebuild failed — it will sync within the hour")),
  );
});

// ── Update ──────────────────────────────────────────────────────────────────────
// Only the title and (optionally) the media file are editable. Publish state and
// the unused tags/sort/premium fields are deliberately left out of the UPDATE so
// they are preserved.
wallpapersApp.post("/:id", async (c) => {
  const id = c.req.param("id");
  const form = (await c.req.parseBody()) as Record<string, unknown>;
  const title = formStr(form, "title");
  if (!title) {
    return c.redirect(`/admin/wallpapers/${id}/edit?err=` + encodeURIComponent("Title is required"));
  }
  const category = categorySlug(formStr(form, "category"));
  if (!category) {
    return c.redirect(`/admin/wallpapers/${id}/edit?err=` + encodeURIComponent("Category is required"));
  }

  // Optional media replacement.
  const newKey = formStr(form, "key_main");
  const newMime = formStr(form, "mime_main");
  const hasNewMedia = newKey !== "" && newMime !== "";
  const newType = newMime === "video/mp4" ? "live" : "static";

  const sql = getDb(c.env);
  let oldKey: string | null = null;
  try {
    if (hasNewMedia) {
      const prev = (await sql`SELECT full_key FROM wallpapers WHERE id = ${id} LIMIT 1`) as unknown as {
        full_key: string;
      }[];
      oldKey = prev[0]?.full_key ?? null;
    }
    await sql.begin(async (tx) => {
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
      await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
    });
  } catch (err) {
    console.error("[admin/wallpapers] update error:", err);
    if (hasNewMedia) c.executionCtx.waitUntil(c.env.R2.delete(newKey).catch(() => {}));
    c.executionCtx.waitUntil(sql.end());
    return c.redirect(`/admin/wallpapers/${id}/edit?err=` + encodeURIComponent("Could not save changes"));
  }
  c.executionCtx.waitUntil(sql.end());

  const ok = await rebuildOk(c.env, null);
  // Delete the replaced object only after a CONFIRMED rebuild that no longer
  // references it; on rebuild failure keep the old bytes (benign) so nothing breaks.
  if (ok && hasNewMedia && oldKey && oldKey !== newKey) {
    c.executionCtx.waitUntil(c.env.R2.delete(oldKey).catch(() => {}));
  }
  return c.redirect(
    "/admin/wallpapers?" +
      (ok
        ? "ok=" + encodeURIComponent("Wallpaper updated")
        : "err=" + encodeURIComponent("Saved, but the catalog rebuild failed — it will sync within the hour")),
  );
});

// ── Publish toggle ──────────────────────────────────────────────────────────────
wallpapersApp.post("/:id/publish", async (c) => {
  const id = c.req.param("id");
  const sql = getDb(c.env);
  try {
    await sql.begin(async (tx) => {
      await tx`UPDATE wallpapers SET is_published = NOT is_published WHERE id = ${id}`;
      await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
    });
  } catch (err) {
    console.error("[admin/wallpapers] publish toggle error:", err);
    c.executionCtx.waitUntil(sql.end());
    return c.redirect("/admin/wallpapers?err=" + encodeURIComponent("Could not change status"));
  }
  c.executionCtx.waitUntil(sql.end());
  const ok = await rebuildOk(c.env, null);
  return c.redirect(
    "/admin/wallpapers?" +
      (ok
        ? "ok=" + encodeURIComponent("Status updated")
        : "err=" + encodeURIComponent("Status changed, but the catalog rebuild failed — it will sync within the hour")),
  );
});

// ── Delete ──────────────────────────────────────────────────────────────────────
wallpapersApp.post("/:id/delete", async (c) => {
  const id = c.req.param("id");
  const sql = getDb(c.env);
  let key: string | null = null;
  try {
    const rows = (await sql`SELECT full_key FROM wallpapers WHERE id = ${id} LIMIT 1`) as unknown as {
      full_key: string;
    }[];
    key = rows[0]?.full_key ?? null;
    if (!key) {
      c.executionCtx.waitUntil(sql.end());
      return c.redirect("/admin/wallpapers?err=" + encodeURIComponent("Wallpaper not found"));
    }
    await sql.begin(async (tx) => {
      await tx`DELETE FROM wallpapers WHERE id = ${id}`;
      await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
    });
  } catch (err) {
    console.error("[admin/wallpapers] delete error:", err);
    c.executionCtx.waitUntil(sql.end());
    return c.redirect("/admin/wallpapers?err=" + encodeURIComponent("Could not delete wallpaper"));
  }
  c.executionCtx.waitUntil(sql.end());

  // Rebuild so the catalog no longer references the object, THEN drop the bytes.
  // On rebuild failure keep the bytes — the still-stale catalog may reference them.
  const ok = await rebuildOk(c.env, null);
  if (ok && key) c.executionCtx.waitUntil(c.env.R2.delete(key).catch(() => {}));
  return c.redirect(
    "/admin/wallpapers?" +
      (ok
        ? "ok=" + encodeURIComponent("Wallpaper deleted")
        : "err=" + encodeURIComponent("Deleted, but the catalog rebuild failed — it will sync within the hour")),
  );
});
