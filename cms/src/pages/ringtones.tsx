/**
 * CMS — ringtones authoring (Pakiza only; mounted at /pakiza/ringtones).
 * Copied from the shipped Pakiza CMS. A ringtone is a SINGLE audio file: one
 * upload, one R2 object (ringtones/audio/{id}.{ext}), one column (audio_key).
 * Mutations bump content_version in the same transaction, then trigger the
 * Pakiza Worker's rebuild. Arul never mounts this module (no ringtones table).
 */

import { Hono } from "hono";
import type { FC } from "hono/jsx";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";
import { getDb } from "../lib/db.js";
import { Badge, Flash, Layout, Modal, PageHead, appPath } from "../ui.js";
import { triggerRebuild, REBUILD_FAILED_MSG } from "../rebuild.js";
import { formStr, parseBool } from "../lib/util.js";

interface RtRow {
  id: string;
  title: string;
  audio_key: string;
  mime: string | null;
  is_published: boolean;
}

export function makeRingtonesApp(app: AppDef): Hono<{ Bindings: Env }> {
  if (!app.hasRingtones) {
    throw new Error(`ringtones pages mounted for an app without ringtones: ${app.slug}`);
  }
  const ringtonesApp = new Hono<{ Bindings: Env }>();
  const base = appPath(app, "/ringtones");
  const navKey = `${app.slug}:ringtones`;

  // ── Form — fields only; hosted in a modal or a full page ────────────────────
  const RingtoneForm: FC<{ mode: "new" | "edit"; row?: RtRow }> = (props) => {
    const r = props.row;
    const isEdit = props.mode === "edit";
    const action = isEdit ? `${base}/${r!.id}` : base;
    const accept = "audio/mpeg,audio/mp4,audio/aac,.mp3,.m4a,.aac";
    return (
      <form
        class="form"
        method="post"
        action={action}
        data-upload-form
        data-kind="ringtone"
        data-presign={appPath(app, "/media/upload-url")}
      >
        <div class="note danger" data-upload-error style="display:none"></div>

        <label class="field">
          <span class="lab">Title</span>
          <input name="title" type="text" required autofocus value={r?.title ?? ""} />
        </label>

        <label class="field">
          <span class="lab">{isEdit ? "Replace audio (optional)" : "Audio file"}</span>
          <input type="file" data-slot="audio" {...(isEdit ? {} : { "data-required": "1" })} accept={accept} />
          <span class="hint">
            The single ringtone file (mp3/m4a/aac) — played in the feed and set on the device.
          </span>
        </label>
        <input type="hidden" name="key_audio" value="" />
        <input type="hidden" name="mime_audio" value="" />

        {isEdit ? null : (
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

  // Full-page fallback wrapper (direct URL / no-JS); the modal path uses the form alone.
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
    </Layout>
  );

  // ── List ────────────────────────────────────────────────────────────────────
  ringtonesApp.get("/", async (c) => {
    const sql = getDb(c.env, app);
    let rows: RtRow[] = [];
    let dbError = false;
    try {
      rows = (await sql`
        SELECT id, title, audio_key, mime, is_published
        FROM ringtones
        ORDER BY created_at DESC NULLS LAST
      `) as unknown as RtRow[];
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] list error:`, err);
      dbError = true;
    } finally {
      c.executionCtx.waitUntil(sql.end());
    }

    return c.html(
      <Layout title={`Ringtones · ${app.label}`} active={navKey}>
        <PageHead
          title={`${app.label} ringtones`}
          sub={`${rows.length} ${rows.length === 1 ? "entry" : "entries"}`}
        >
          <button type="button" class="btn" data-dialog-target="rt-new">
            + New ringtone
          </button>
        </PageHead>
        <Flash ok={c.req.query("ok")} err={c.req.query("err")} />
        {dbError ? <div class="note danger">Could not load ringtones.</div> : null}

        {rows.length === 0 && !dbError ? (
          <div class="empty">
            <span class="emoji">🎵</span>
            No ringtones yet. Create the first one.
            <div class="cta">
              <button type="button" class="btn" data-dialog-target="rt-new">
                + New ringtone
              </button>
            </div>
          </div>
        ) : null}
        {rows.length > 0 ? (
          <div data-listview data-page="1">
            <div class="toolbar">
              <div class="searchwrap">
                <input class="search" type="text" data-search placeholder="Search title, ID or file key…" />
                <button type="button" class="search-clear" aria-label="Clear search" data-search-clear>
                  ×
                </button>
              </div>
              <select data-filter="2" data-filter-key="status" aria-label="Filter by status">
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
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr data-id={r.id} data-rowedit>
                      <td style="padding:4px 14px">
                        <span class="filemark">♪</span>
                      </td>
                      <td class="coltitle">
                        <strong>{r.title}</strong>
                      </td>
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
                            data-dialog-target="rt-edit"
                            hx-get={`${base}/${r.id}/edit`}
                            hx-target="#rt-edit-body"
                            hx-swap="innerHTML"
                          >
                            Edit
                          </button>
                          <form method="post" action={`${base}/${r.id}/publish`}>
                            <input type="hidden" name="set" value={r.is_published ? "0" : "1"} />
                            <button type="submit" class="btn sec sm">
                              {r.is_published ? "Unpublish" : "Publish"}
                            </button>
                          </form>
                          <form
                            method="post"
                            action={`${base}/${r.id}/delete`}
                            data-confirm={`Delete "${r.title}"? This removes it from the app.`}
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
              No ringtones match your search.
            </div>
            <div class="pager" />
          </div>
        ) : null}

        <Modal id="rt-new" title="New ringtone" wide>
          <RingtoneForm mode="new" />
        </Modal>
        <Modal id="rt-edit" title="Edit ringtone" wide>
          <div id="rt-edit-body">
            <div class="modal-loading">Loading…</div>
          </div>
        </Modal>
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
        SELECT id, title, audio_key, mime, is_published
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

  // ── Create ──────────────────────────────────────────────────────────────────
  ringtonesApp.post("/", async (c) => {
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const title = formStr(form, "title");
    const audioKey = formStr(form, "key_audio");
    const mime = formStr(form, "mime_audio");

    if (!title) return c.redirect(`${base}/new?err=` + encodeURIComponent("Title is required"));
    if (!audioKey) {
      return c.redirect(`${base}/new?err=` + encodeURIComponent("The audio upload must complete"));
    }

    const published = parseBool(form.is_published);
    const id = crypto.randomUUID();

    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        // tags keep their DB default ('{}') — the app filters All/New by created_at.
        await tx`
          INSERT INTO ringtones (id, title, audio_key, mime, is_published)
          VALUES (${id}, ${title}, ${audioKey}, ${mime || null}, ${published})
        `;
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] create error:`, err);
      c.executionCtx.waitUntil(app.r2(c.env).delete(audioKey).catch(() => {}));
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

  // ── Update ──────────────────────────────────────────────────────────────────
  // Publish state is owned by the list-page Publish/Unpublish button, so it is
  // NOT edited here (and is deliberately preserved by leaving it out of the UPDATE).
  ringtonesApp.post("/:id", async (c) => {
    const id = c.req.param("id");
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const title = formStr(form, "title");
    if (!title) {
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Title is required"));
    }

    const newAudio = formStr(form, "key_audio");
    const newMime = formStr(form, "mime_audio");
    const replaceAudio = newAudio !== "";

    const sql = getDb(c.env, app);
    let oldAudio: string | null = null;
    try {
      if (replaceAudio) {
        const prev = (await sql`SELECT audio_key FROM ringtones WHERE id = ${id} LIMIT 1`) as unknown as {
          audio_key: string;
        }[];
        oldAudio = prev[0]?.audio_key ?? null;
      }
      await sql.begin(async (tx) => {
        await tx`
          UPDATE ringtones SET title = ${title}
          WHERE id = ${id}
        `;
        if (replaceAudio) {
          await tx`UPDATE ringtones SET audio_key = ${newAudio}, mime = ${newMime || null} WHERE id = ${id}`;
        }
        await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
      });
    } catch (err) {
      console.error(`[cms/${app.slug}/ringtones] update error:`, err);
      if (replaceAudio) c.executionCtx.waitUntil(app.r2(c.env).delete(newAudio).catch(() => {}));
      c.executionCtx.waitUntil(sql.end());
      return c.redirect(`${base}/${id}/edit?err=` + encodeURIComponent("Could not save changes"));
    }
    c.executionCtx.waitUntil(sql.end());

    const ok = await triggerRebuild(c.env, app);
    // Delete the replaced object only after a CONFIRMED rebuild; on failure keep
    // the old bytes so the live (still-stale) catalog never points at a missing object.
    if (ok && replaceAudio && oldAudio && oldAudio !== newAudio) {
      c.executionCtx.waitUntil(app.r2(c.env).delete(oldAudio).catch(() => {}));
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
    // Idempotent set (list toggle sends set=0/1); fall back to NOT-toggle when
    // absent (direct POST / older clients).
    const form = (await c.req.parseBody()) as Record<string, unknown>;
    const set = formStr(form, "set");
    const sql = getDb(c.env, app);
    try {
      await sql.begin(async (tx) => {
        if (set === "0" || set === "1") {
          await tx`UPDATE ringtones SET is_published = ${set === "1"} WHERE id = ${id}`;
        } else {
          await tx`UPDATE ringtones SET is_published = NOT is_published WHERE id = ${id}`;
        }
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
    try {
      const rows = (await sql`SELECT audio_key FROM ringtones WHERE id = ${id} LIMIT 1`) as unknown as {
        audio_key: string;
      }[];
      if (rows.length === 0) {
        c.executionCtx.waitUntil(sql.end());
        return c.redirect(`${base}?err=` + encodeURIComponent("Ringtone not found"));
      }
      audioKey = rows[0]!.audio_key;
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

    const ok = await triggerRebuild(c.env, app);
    // On rebuild failure keep the bytes — the still-stale catalog may reference them.
    if (ok && audioKey) c.executionCtx.waitUntil(app.r2(c.env).delete(audioKey).catch(() => {}));
    return c.redirect(
      `${base}?` +
        (ok
          ? "ok=" + encodeURIComponent("Ringtone deleted")
          : "err=" + encodeURIComponent(REBUILD_FAILED_MSG)),
    );
  });

  return ringtonesApp;
}
