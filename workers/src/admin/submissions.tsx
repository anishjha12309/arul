/**
 * CMS — user submission moderation (mounted at /admin/submissions).
 *
 * Lists ALL submissions (the app's /me/submissions is self-only) and lets the
 * operator approve (promote into a published wallpapers row) or reject.
 *
 * Approve copies the bytes from the submitter's
 * user/<sub>/submissions/… path to a canonical catalog key FIRST, then INSERT
 * the published row + flip the submission + bump content_version in one
 * transaction, then rebuild + purge. The submitter's original object is then
 * deleted (the canonical copy holds the bytes) — reject deletes it too; the
 * hourly sweep cron is the backstop for any lost inline delete.
 *
 * Arul delta: canonical keys are CATEGORY-partitioned (wallpapers/<category>/…),
 * so approve copies to the submission's category prefix and carries `category`
 * onto the wallpapers row. The approve form lets the operator set/fix it.
 *
 * UI: status tab-strip + table; "Review"/"View" loads the detail (media preview +
 * approve/reject) into a centered modal via HTMX, with a full-page fallback.
 * Presentation-only — action URLs and field names are unchanged.
 */

import { Hono } from "hono";
import type { FC } from "hono/jsx";
import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { presignGet, r2Copy } from "../lib/r2.js";
import { Flash, Layout, Modal, PageHead } from "./ui.js";
import { rebuildOk } from "./publish.js";
import { categorySlug } from "./media.js";
import { formStr } from "./util.js";
import { EXT_BY_MIME as CT_EXT } from "../lib/media-constraints.js";

export const submissionsApp = new Hono<{ Bindings: Env }>();

interface SubRow {
  id: string;
  kind: string;
  file_key: string;
  title: string | null;
  category: string | null;
  status: string;
  rejection_reason: string | null;
  created_at: string | null;
}

const STATUSES = ["pending", "approved", "rejected"] as const;

function extOf(key: string): string {
  return (key.split(".").pop() ?? "").toLowerCase();
}

// Canonical extension for a (validated, stored) content-type comes from the
// shared EXT_BY_MIME map. We derive the key extension + wallpaper type from the
// object's REAL content-type — read via R2 HEAD — never from the
// submitter-controlled filename, so the build-catalog live↔video/mp4 integrity
// guard stays meaningful.

// ── List ──────────────────────────────────────────────────────────────────────
submissionsApp.get("/", async (c) => {
  const status = (c.req.query("status") ?? "pending").toLowerCase();
  const active = (STATUSES as readonly string[]).includes(status) ? status : "pending";

  const sql = getDb(c.env);
  let rows: SubRow[] = [];
  let dbError = false;
  try {
    rows = (await sql`
      SELECT id, kind, file_key, title, category, status, rejection_reason, created_at
      FROM content_submissions
      WHERE status = ${active}
      ORDER BY created_at DESC
    `) as unknown as SubRow[];
  } catch (err) {
    console.error("[admin/submissions] list error:", err);
    dbError = true;
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }

  return c.html(
    <Layout title="Submissions" active="submissions">
      <PageHead title="User submissions" sub="Moderate community uploads" />
      <Flash ok={c.req.query("ok")} err={c.req.query("err")} />

      <div class="tabs">
        {STATUSES.map((s) => (
          <a class={s === active ? "on" : ""} href={`/admin/submissions?status=${s}`}>
            {s}
          </a>
        ))}
      </div>

      {dbError ? <div class="note danger">Could not load submissions.</div> : null}

      {rows.length === 0 ? (
        <div class="empty">
          <span class="emoji">📥</span>
          No {active} submissions.
        </div>
      ) : (
        <div data-listview data-page="1">
          <div class="toolbar">
            <input class="search" type="text" data-search placeholder="Search submissions…" />
            <span class="grow" />
            <select data-page-size aria-label="Rows per page">
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
                  <th class="sortable" data-type="text">
                    Kind <span class="arrow" />
                  </th>
                  <th class="sortable" data-type="text">
                    Title <span class="arrow" />
                  </th>
                  <th>Category</th>
                  <th class="sortable" data-type="text">
                    Submitted <span class="arrow" />
                  </th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr>
                    <td>{r.kind}</td>
                    <td class="coltitle">
                      <strong>{r.title ?? "(untitled)"}</strong>
                    </td>
                    <td class="muted" style="color:var(--muted)">
                      {r.category ?? "—"}
                    </td>
                    <td class="muted" style="color:var(--muted)">
                      {r.created_at ? String(r.created_at).slice(0, 10) : "—"}
                    </td>
                    <td>
                      <div class="rowact">
                        <button
                          type="button"
                          class="btn sec sm"
                          data-dialog-target="sub-review"
                          hx-get={`/admin/submissions/${r.id}`}
                          hx-target="#sub-review-body"
                          hx-swap="innerHTML"
                        >
                          {active === "pending" ? "Review" : "View"}
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div class="note muted" data-empty-filtered style="display:none">
            No submissions match your search.
          </div>
          <div class="pager" />
        </div>
      )}

      <Modal id="sub-review" title="Review submission" wide>
        <div id="sub-review-body">
          <div class="modal-loading">Loading…</div>
        </div>
      </Modal>
    </Layout>,
  );
});

// ── Media preview ───────────────────────────────────────────────────────────────
const Preview: FC<{ kind: string; ext: string; url: string }> = (props) => {
  if (props.ext === "mp4") {
    // Approve publishes the bytes VERBATIM, so catch the green-edge trap here.
    // Root cause (verified on-device 2026-07-06, SD695 + Dimensity 900): when a
    // feed slot silently falls back to the SOFTWARE decoder, gralloc pads the
    // output buffer width to 128px and Flutter's ImageReader consumer samples
    // the full padded buffer ignoring the crop rect (flutter/flutter#174026) —
    // the padding renders as a green edge strip. Also: widths >1088 or heights
    // >1920 exceed budget hw-decoder caps (e.g. SD695 max 1920x1088) and force
    // permanent sw decode. Rule: w%128==0, h%32==0, fits 1088×1920 caps —
    // canonical 1024×1824 (docs/media-conventions.md).
    // Checked client-side off the preview's own metadata — no MP4 parsing here.
    const dimCheck =
      "var vw=this.videoWidth,vh=this.videoHeight;" +
      "if(vw%128||vh%32||Math.min(vw,vh)>1088||Math.max(vw,vh)>1920){" +
      "var w=this.parentElement.querySelector('.dim-warn');" +
      "if(w){w.style.display='block';" +
      "w.textContent='⚠ '+vw+'×'+vh+" +
      "' — needs width%128==0, height%32==0, within 1088×1920 (hw decoder cap): " +
      "else green edge lines / forced software decode on budget phones. " +
      "Re-encode to 1024×1824 (docs/media-conventions.md) before approving.';}}";
    return (
      <>
        <video controls src={props.url} onloadedmetadata={dimCheck} />
        <div class="note danger dim-warn" style="display:none;margin-top:10px"></div>
      </>
    );
  }
  return <img src={props.url} alt="" />;
};

// ── Review body (shared by the modal fragment + the full-page fallback) ─────────
const ReviewBody: FC<{ row: SubRow; signedUrl: string; ext: string; err?: string | undefined }> = (
  props,
) => {
  const { row, signedUrl, ext } = props;
  const isPending = row.status === "pending";
  return (
    <div>
      {props.err ? <div class="note danger">{props.err}</div> : null}
      <div class="card preview-media" style="margin-bottom:18px">
        {signedUrl ? (
          <Preview kind={row.kind} ext={ext} url={signedUrl} />
        ) : (
          <div class="note warn">Could not generate a preview URL for this file.</div>
        )}
        <div class="muted" style="font-size:13px;margin-top:10px;color:var(--muted)">
          {row.kind} · {row.status} · {row.file_key}
        </div>
      </div>

      {row.status === "rejected" && row.rejection_reason ? (
        <div class="note danger">Rejected: {row.rejection_reason}</div>
      ) : null}

      {!isPending ? (
        <div class="note muted">
          This submission is <strong>{row.status}</strong> — no further action.
        </div>
      ) : (
        <div class="grid" style="grid-template-columns:1fr 1fr;align-items:start">
          <form class="card" method="post" action={`/admin/submissions/${row.id}/approve`}>
            <div class="card-title">Approve &amp; publish</div>
            <label class="field" style="margin-top:12px">
              <span class="lab">Title</span>
              <input name="title" type="text" value={row.title ?? ""} required />
            </label>
            <label class="field">
              <span class="lab">Category</span>
              <input name="category" type="text" value={row.category ?? ""} required />
              <span class="hint">Browse axis + canonical key prefix (wallpapers/&lt;category&gt;/…).</span>
            </label>
            <button type="submit" class="btn" style="margin-top:8px">
              Approve &amp; publish
            </button>
          </form>

          <form class="card" method="post" action={`/admin/submissions/${row.id}/reject`}>
            <div class="card-title">Reject</div>
            <label class="field" style="margin-top:12px">
              <span class="lab">Reason (optional, stored on the submission)</span>
              <textarea name="reason" rows={3}></textarea>
            </label>
            <button type="submit" class="btn danger" style="margin-top:8px">
              Reject
            </button>
          </form>
        </div>
      )}
    </div>
  );
};

// ── Detail / review ──────────────────────────────────────────────────────────────
submissionsApp.get("/:id", async (c) => {
  const id = c.req.param("id");
  const sql = getDb(c.env);
  let row: SubRow | null = null;
  try {
    const rows = (await sql`
      SELECT id, kind, file_key, title, category, status, rejection_reason, created_at
      FROM content_submissions WHERE id = ${id} LIMIT 1
    `) as unknown as SubRow[];
    row = rows[0] ?? null;
  } catch (err) {
    console.error("[admin/submissions] detail error:", err);
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }

  const isHx = c.req.header("HX-Request") === "true";
  if (!row) {
    if (isHx) return c.html(<div class="note danger">Submission not found — it may have been removed.</div>);
    return c.redirect("/admin/submissions?err=" + encodeURIComponent("Submission not found"));
  }

  const ext = extOf(row.file_key);
  let signedUrl = "";
  try {
    signedUrl = await presignGet(c.env, row.file_key, 300);
  } catch (err) {
    console.error("[admin/submissions] presign error:", err);
  }

  if (isHx) {
    return c.html(<ReviewBody row={row} signedUrl={signedUrl} ext={ext} err={c.req.query("err")} />);
  }
  return c.html(
    <Layout title="Review submission" active="submissions">
      <PageHead title="Review submission" sub={`${row.kind} · ${row.status}`}>
        <a class="btn sec" href="/admin/submissions">
          Back
        </a>
      </PageHead>
      <ReviewBody row={row} signedUrl={signedUrl} ext={ext} err={c.req.query("err")} />
    </Layout>,
  );
});

// ── Approve → promote ──────────────────────────────────────────────────────────
submissionsApp.post("/:id/approve", async (c) => {
  const subId = c.req.param("id");
  const form = (await c.req.parseBody()) as Record<string, unknown>;
  const titleOverride = formStr(form, "title");
  const categoryOverride = formStr(form, "category");

  const sql = getDb(c.env);
  const back = (msg: string) =>
    c.redirect(`/admin/submissions/${subId}?err=` + encodeURIComponent(msg));

  let sub: SubRow | null = null;
  try {
    const rows = (await sql`
      SELECT id, kind, file_key, title, category, status, rejection_reason, created_at
      FROM content_submissions WHERE id = ${subId} LIMIT 1
    `) as unknown as SubRow[];
    sub = rows[0] ?? null;
  } catch (err) {
    console.error("[admin/submissions] approve load error:", err);
    c.executionCtx.waitUntil(sql.end());
    return back("Could not load submission");
  }

  if (!sub) {
    c.executionCtx.waitUntil(sql.end());
    return back("Submission not found");
  }
  if (sub.status !== "pending") {
    c.executionCtx.waitUntil(sql.end());
    return back(`Submission is ${sub.status}, not pending`);
  }

  // Derive type / MIME / extension from the object's REAL stored content-type
  // (set + enforced by the signed PUT at upload time), read via R2 HEAD — NOT the
  // submitter-controlled filename. This keeps build-catalog's live↔video/mp4
  // integrity guard meaningful and prevents a mislabeled file shipping broken.
  let realCt = "";
  try {
    const head = await c.env.R2.head(sub.file_key);
    realCt = head?.httpMetadata?.contentType ?? "";
  } catch (err) {
    console.error("[admin/submissions] head error:", err);
  }
  const ext = CT_EXT[realCt];
  if (!ext) {
    c.executionCtx.waitUntil(sql.end());
    return back(realCt ? `Unsupported media type "${realCt}"` : "Could not read the uploaded file's type");
  }

  const title = titleOverride || sub.title || "Untitled submission";
  // Approve into the submission's category prefix; the operator can override/fix
  // it on the approve form. Category is REQUIRED — it is the browse axis and the
  // canonical key partition (wallpapers/<category>/…).
  const category = categorySlug(categoryOverride || sub.category);
  const newId = crypto.randomUUID();
  const createdKeys: string[] = [];

  try {
    if (sub.kind === "wallpaper") {
      if (!category) {
        c.executionCtx.waitUntil(sql.end());
        return back("A category is required to publish a wallpaper");
      }
      let wtype: "static" | "live";
      if (realCt === "video/mp4") {
        wtype = "live";
      } else if (realCt.startsWith("image/")) {
        wtype = "static";
      } else {
        c.executionCtx.waitUntil(sql.end());
        return back(`A wallpaper must be an image or mp4 video (got "${realCt}")`);
      }
      const dstKey = `wallpapers/${category}/${newId}.${ext}`;
      await r2Copy(c.env, sub.file_key, dstKey, realCt);
      createdKeys.push(dstKey);
      try {
        await sql.begin(async (tx) => {
          // tags/sort_order keep their DB defaults ('{}', 0).
          await tx`
            INSERT INTO wallpapers (id, title, type, category, full_key, mime, is_published)
            VALUES (${newId}, ${title}, ${wtype}, ${category}, ${dstKey}, ${realCt}, true)
          `;
          await tx`UPDATE content_submissions SET status = 'approved' WHERE id = ${subId}`;
          await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
        });
      } catch (err) {
        console.error("[admin/submissions] approve wallpaper insert error:", err);
        for (const k of createdKeys) c.executionCtx.waitUntil(c.env.R2.delete(k).catch(() => {}));
        c.executionCtx.waitUntil(sql.end());
        return back("Could not publish wallpaper");
      }
    } else {
      c.executionCtx.waitUntil(sql.end());
      return back(`Unsupported submission kind "${sub.kind}"`);
    }
  } catch (err) {
    console.error("[admin/submissions] approve copy error:", err);
    // A copy failed partway — remove any canonical objects already created.
    for (const k of createdKeys) c.executionCtx.waitUntil(c.env.R2.delete(k).catch(() => {}));
    c.executionCtx.waitUntil(sql.end());
    return back("Could not copy media to the catalog");
  }
  c.executionCtx.waitUntil(sql.end());

  // The canonical catalog object now holds the bytes and the row is published, so
  // the submitter's original (user/<sub>/submissions/…) is pure duplicate storage.
  // Drop it (best-effort) instead of keeping two full copies forever. The feed
  // renders the canonical key; nothing in-app reads the submission original, and
  // the sweep cron is the backstop if this fire-and-forget delete is lost.
  c.executionCtx.waitUntil(c.env.R2.delete(sub.file_key).catch(() => {}));

  const ok = await rebuildOk(c.env, null);
  return c.redirect(
    "/admin/submissions?" +
      (ok
        ? "ok=" + encodeURIComponent("Submission approved & published")
        : "err=" + encodeURIComponent("Approved, but the catalog rebuild failed — it will sync within the hour")),
  );
});

// ── Reject ──────────────────────────────────────────────────────────────────────
submissionsApp.post("/:id/reject", async (c) => {
  const subId = c.req.param("id");
  const form = (await c.req.parseBody()) as Record<string, unknown>;
  const reason = formStr(form, "reason");

  const sql = getDb(c.env);
  let fileKey: string | null = null;
  try {
    const rows = (await sql`SELECT status, file_key FROM content_submissions WHERE id = ${subId} LIMIT 1`) as unknown as {
      status: string;
      file_key: string;
    }[];
    if (rows.length === 0) {
      c.executionCtx.waitUntil(sql.end());
      return c.redirect("/admin/submissions?err=" + encodeURIComponent("Submission not found"));
    }
    if (rows[0]!.status !== "pending") {
      c.executionCtx.waitUntil(sql.end());
      return c.redirect("/admin/submissions?err=" + encodeURIComponent("Only pending submissions can be rejected"));
    }
    fileKey = rows[0]!.file_key;
    await sql`
      UPDATE content_submissions
      SET status = 'rejected', rejection_reason = ${reason || null}
      WHERE id = ${subId}
    `;
  } catch (err) {
    console.error("[admin/submissions] reject error:", err);
    c.executionCtx.waitUntil(sql.end());
    return c.redirect("/admin/submissions?err=" + encodeURIComponent("Could not reject submission"));
  }
  c.executionCtx.waitUntil(sql.end());

  // A rejected upload is never published, so its bytes have no further use —
  // drop them (best-effort) rather than letting the originals pile up in R2.
  // The row stays (for the rejected tab + audit); only the media is freed.
  if (fileKey) c.executionCtx.waitUntil(c.env.R2.delete(fileKey).catch(() => {}));

  // No catalog change — nothing was published.
  return c.redirect("/admin/submissions?ok=" + encodeURIComponent("Submission rejected"));
});
