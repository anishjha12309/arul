/**
 * The media route handlers. The DB is mocked; R2 presigning runs FOR REAL on aws4fetch and Web Crypto.
 *
 * ALL content requires premium to apply/set/save -> there is no per-row flag and no test-user bypass
 * /media/signed-url answers the content lookup AND the entitlement check in ONE combined query
 * So the mock row carries both columns -> the 403-deny path sets the entitlement half false
 * The CMS repo's live smoke plan exercises the same path against the deployed worker
 */

import { describe, it, expect, vi } from "vitest";
import { makeEnv, makeCtx, makeMockSql } from "./_ctx.js";
import { makeQcR2, jpegFixture, mp4Fixture, mp3Fixture } from "./_media.js";
import { signAccessToken } from "../src/lib/jwt.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

import { handleSignedUrl, handleUploadUrl, handleConfirmUpload } from "../src/routes/media.js";
import { verifyMediaObject } from "../src/lib/media-verify.js";

const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";
const USER_ID = "11111111-1111-1111-1111-111111111111";

function envWithSql(rows: unknown[], extraEnv: Record<string, unknown> = {}) {
  const env = makeEnv({ JWT_SECRET, ...extraEnv });
  const { sql, capturedArgs } = makeMockSql(rows);
  (env as unknown as { _testSql: unknown })._testSql = sql;
  return { env, capturedArgs };
}

const token = () => signAccessToken(USER_ID, JWT_SECRET);

// ── POST /media/signed-url ────────────────────────────────────────────────────

describe("POST /media/signed-url", () => {
  it("401 without a token", async () => {
    const { env } = envWithSql([]);
    const res = await handleSignedUrl(makeCtx({ env, jsonBody: { id: "x", kind: "wallpaper" } }));
    expect(res.status).toBe(401);
  });

  it("400 on missing id", async () => {
    const { env } = envWithSql([]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper" } }),
    );
    expect(res.status).toBe(400);
  });

  it("400 on an invalid kind", async () => {
    const { env } = envWithSql([]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "x", kind: "sticker" } }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("invalid_kind");
  });

  it("404 when the content row is not found", async () => {
    const { env } = envWithSql([]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "x", kind: "wallpaper" } }),
    );
    expect(res.status).toBe(404);
  });

  it("404 when the private key is missing on the row", async () => {
    const { env } = envWithSql([{ private_key: null }]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "x", kind: "wallpaper" } }),
    );
    expect(res.status).toBe(404);
  });

  it("returns a 300s signed URL for a premium user", async () => {
    // The combined query returns the content key and the live entitlement in ONE row -> the mock mirrors that shape
    const { env } = envWithSql([{ private_key: "wallpapers/murugan/live.mp4", is_premium: true }]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "w1", kind: "wallpaper" } }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; expiresIn: number };
    expect(body.expiresIn).toBe(300);
    expect(body.url).toContain("X-Amz-Signature=");
    expect(body.url).toContain("wallpapers");
  });

  it("403 premium_required when the live entitlement read says not premium", async () => {
    // The key exists and is published, but the entitlement half of the row is false
    // Entitlement is read LIVE from Neon, never from the JWT -> a lapsed or refunded user is refused with a valid token
    const { env } = envWithSql([{ private_key: "wallpapers/murugan/live.mp4", is_premium: false }]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "w1", kind: "wallpaper" } }),
    );
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("premium_required");
  });

  // ── Popularity counter ─────────────────────────────────────────────────────
  // This route is the ONLY source of the counts that order the feed
  // So what it does and does not increment is a product contract, not plumbing
  describe("popularity counter", () => {
    /**
     * Everything this request handed the sql tag, as one searchable blob.
     * Flattened, not read per-statement -> dynamic identifiers go through `sql(table)`, recorded as their OWN calls
     * So the incremented column never appears inside the UPDATE's own template strings
     */
    const sqlText = (capturedArgs: unknown[][]) =>
      capturedArgs
        .flat()
        .map((a) => (Array.isArray(a) ? (a as string[]).join("?") : String(a)))
        .join(" | ");

    it("increments apply_count for an APPLY", async () => {
      const { env, capturedArgs } = envWithSql([
        { private_key: "wallpapers/murugan/live.mp4", is_premium: true },
      ]);
      await handleSignedUrl(
        makeCtx({
          env,
          token: await token(),
          jsonBody: { id: "w1", kind: "wallpaper", action: "apply" },
        }),
      );
      const text = sqlText(capturedArgs);
      expect(text).toContain("UPDATE");
      expect(text).toContain("apply_count");
    });

    it("does NOT increment for a SHARE", async () => {
      // The same route serves apply AND share -> counting a share ranks a wallpaper nobody kept to the top
      const { env, capturedArgs } = envWithSql([
        { private_key: "wallpapers/murugan/live.mp4", is_premium: true },
      ]);
      await handleSignedUrl(
        makeCtx({
          env,
          token: await token(),
          jsonBody: { id: "w1", kind: "wallpaper", action: "share" },
        }),
      );
      expect(sqlText(capturedArgs)).not.toContain("UPDATE");
    });

    it("does NOT increment when the request carries no action", async () => {
      // Older builds send no action at all -> counting those folds every share into apply_count while they stay installed
      const { env, capturedArgs } = envWithSql([
        { private_key: "wallpapers/murugan/live.mp4", is_premium: true },
      ]);
      await handleSignedUrl(
        makeCtx({ env, token: await token(), jsonBody: { id: "w1", kind: "wallpaper" } }),
      );
      expect(sqlText(capturedArgs)).not.toContain("UPDATE");
    });

    it("increments set_count for a ringtone with no action — set is its only gate", async () => {
      const { env, capturedArgs } = envWithSql([
        { private_key: "ringtones/murugan/abc.mp3", is_premium: true },
      ]);
      await handleSignedUrl(makeCtx({ env, token: await token(), jsonBody: { id: "r1", kind: "ringtone" } }));
      const text = sqlText(capturedArgs);
      expect(text).toContain("UPDATE");
      expect(text).toContain("set_count");
    });

    it("does NOT increment when entitlement refuses the grant", async () => {
      // The count means "a premium user was handed this file" -> incrementing on a 403 lets a signed-out crowd rank the feed
      const { env, capturedArgs } = envWithSql([
        { private_key: "wallpapers/murugan/live.mp4", is_premium: false },
      ]);
      const res = await handleSignedUrl(
        makeCtx({
          env,
          token: await token(),
          jsonBody: { id: "w1", kind: "wallpaper", action: "apply" },
        }),
      );
      expect(res.status).toBe(403);
      expect(sqlText(capturedArgs)).not.toContain("UPDATE");
    });
  });

  // ── Status: its own table, one counter per action ──────────────────────────
  // Share and save stay apart so the CMS can read each -> the feed orders on their sum
  describe("status kind", () => {
    const sqlText = (capturedArgs: unknown[][]) =>
      capturedArgs
        .flat()
        .map((a) => (Array.isArray(a) ? (a as string[]).join("?") : String(a)))
        .join(" | ");
    const statusRow = { private_key: "statuses/murugan/abc.mp4", is_premium: true };

    it("resolves kind=status through statuses.full_key and returns a signed URL", async () => {
      const { env, capturedArgs } = envWithSql([statusRow]);
      const res = await handleSignedUrl(
        makeCtx({ env, token: await token(), jsonBody: { id: "s1", kind: "status", action: "share" } }),
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as { url: string; expiresIn: number };
      expect(body.expiresIn).toBe(300);
      expect(body.url).toContain("statuses");
      const text = sqlText(capturedArgs);
      expect(text).toContain("statuses");
      expect(text).toContain("full_key");
    });

    // The template calls that touch status_actions -> the counter and the event must be ONE of them
    const eventWrites = (capturedArgs: unknown[][]) =>
      capturedArgs.filter(
        (a) => Array.isArray(a[0]) && (a[0] as string[]).join("?").includes("status_actions"),
      );

    it("a SHARE bumps share_count and appends a share row for this user, in ONE statement", async () => {
      const { env, capturedArgs } = envWithSql([statusRow]);
      await handleSignedUrl(
        makeCtx({ env, token: await token(), jsonBody: { id: "s1", kind: "status", action: "share" } }),
      );
      const text = sqlText(capturedArgs);
      expect(text).toContain("UPDATE");
      expect(text).toContain("share_count");
      expect(text).not.toContain("download_count");

      const writes = eventWrites(capturedArgs);
      expect(writes).toHaveLength(1);
      const [strings, ...bound] = writes[0]!;
      const stmt = (strings as string[]).join("?");
      expect(stmt).toContain("UPDATE statuses");
      expect(stmt).toContain("INSERT INTO status_actions");
      expect(bound).toContain("share");
      expect(bound).toContain(USER_ID);
      expect(bound).toContain("s1");
      // No second, counter-only UPDATE beside it -> a missing table must stop the bump, not hide
      const updates = capturedArgs.filter(
        (a) => Array.isArray(a[0]) && (a[0] as string[]).join("?").includes("UPDATE"),
      );
      expect(updates).toHaveLength(1);
    });

    it("a DOWNLOAD bumps download_count and appends a download row for this user, in ONE statement", async () => {
      const { env, capturedArgs } = envWithSql([statusRow]);
      await handleSignedUrl(
        makeCtx({ env, token: await token(), jsonBody: { id: "s1", kind: "status", action: "download" } }),
      );
      const text = sqlText(capturedArgs);
      expect(text).toContain("UPDATE");
      expect(text).toContain("download_count");
      expect(text).not.toContain("share_count");

      const writes = eventWrites(capturedArgs);
      expect(writes).toHaveLength(1);
      const [strings, ...bound] = writes[0]!;
      expect((strings as string[]).join("?")).toContain("INSERT INTO status_actions");
      expect(bound).toContain("download");
      expect(bound).not.toContain("share");
      expect(bound).toContain(USER_ID);
    });

    it("no action, or an unknown one, bumps nothing", async () => {
      for (const action of [undefined, "apply", "set"]) {
        const { env, capturedArgs } = envWithSql([statusRow]);
        const res = await handleSignedUrl(
          makeCtx({ env, token: await token(), jsonBody: { id: "s1", kind: "status", action } }),
        );
        expect(res.status).toBe(200);
        expect(sqlText(capturedArgs)).not.toContain("UPDATE");
        expect(sqlText(capturedArgs)).not.toContain("status_actions");
      }
    });

    it("403 premium_required and no bump when the live entitlement read says not premium", async () => {
      const { env, capturedArgs } = envWithSql([{ ...statusRow, is_premium: false }]);
      const res = await handleSignedUrl(
        makeCtx({ env, token: await token(), jsonBody: { id: "s1", kind: "status", action: "share" } }),
      );
      expect(res.status).toBe(403);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("premium_required");
      expect(sqlText(capturedArgs)).not.toContain("UPDATE");
      expect(sqlText(capturedArgs)).not.toContain("status_actions");
      expect(sqlText(capturedArgs)).not.toContain("INSERT");
    });

    it("wallpaper and ringtone grants never touch a status counter", async () => {
      for (const body of [
        { id: "w1", kind: "wallpaper", action: "apply" },
        { id: "w1", kind: "wallpaper", action: "share" },
        { id: "w1", kind: "wallpaper", action: "download" },
        { id: "r1", kind: "ringtone" },
      ]) {
        const { env, capturedArgs } = envWithSql([{ private_key: "k", is_premium: true }]);
        await handleSignedUrl(makeCtx({ env, token: await token(), jsonBody: body }));
        const text = sqlText(capturedArgs);
        expect(text).not.toContain("statuses");
        expect(text).not.toContain("share_count");
        expect(text).not.toContain("download_count");
        expect(text).not.toContain("status_actions");
        expect(text).not.toContain("INSERT");
      }
    });
  });

  it("resolves kind=ringtone via audio_key and returns a signed URL for a premium user", async () => {
    // The same combined-row shape as the wallpaper path -> the ringtones lookup surfaces audio_key AS private_key
    const { env } = envWithSql([{ private_key: "ringtones/murugan/abc.mp3", is_premium: true }]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "r1", kind: "ringtone" } }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; expiresIn: number };
    expect(body.expiresIn).toBe(300);
    expect(body.url).toContain("X-Amz-Signature=");
    expect(body.url).toContain("ringtones");
  });

  it("404 when the ringtone row is not found", async () => {
    const { env } = envWithSql([]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "nope", kind: "ringtone" } }),
    );
    expect(res.status).toBe(404);
  });
});

// ── POST /media/upload-url ────────────────────────────────────────────────────

describe("POST /media/upload-url", () => {
  it("401 without a token", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(makeCtx({ env, jsonBody: {} }));
    expect(res.status).toBe(401);
  });

  it("bad_key when key is missing", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(
      makeCtx({ env, token: await token(), jsonBody: { contentType: "image/jpeg" } }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_key");
  });

  it("bad_key when the key is outside the caller's user/ namespace", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { key: "user/someone-else/x.jpg", contentType: "image/jpeg" },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_key");
  });

  it("bad_key when the key is in the caller's namespace but not under submissions/", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(
      makeCtx({
        env,
        token: await token(),
        // A valid owner prefix but the wrong SHAPE -> sweep-submissions only reclaims keys containing the infix
        // Accepting this would strand the bytes in R2 forever -> no cron would ever see them
        jsonBody: { key: `user/${USER_ID}/x.jpg`, contentType: "image/jpeg" },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_key");
  });

  it("bad_type for a disallowed content type", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(
      makeCtx({
        env,
        token: await token(),
        jsonBody: {
          key: `user/${USER_ID}/submissions/x.txt`,
          contentType: "text/plain",
        },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_type");
  });

  it("too_large when size exceeds the per-type limit", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(
      makeCtx({
        env,
        token: await token(),
        jsonBody: {
          key: `user/${USER_ID}/submissions/x.jpg`,
          contentType: "image/jpeg",
          size: 11 * 1024 * 1024, // > 10MB image cap
        },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("too_large");
  });

  it("returns uploadUrl + publicUrl for a valid request", async () => {
    const { env } = envWithSql([]);
    const key = `user/${USER_ID}/submissions/x.jpg`;
    const res = await handleUploadUrl(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { key, contentType: "image/jpeg", size: 1024 },
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { uploadUrl: string; publicUrl: string };
    expect(body.uploadUrl).toContain("X-Amz-Signature=");
    expect(body.publicUrl).toBe(`https://cdn.hsrutility.com/${key}`);
  });
});

// ── POST /media/confirm-upload ────────────────────────────────────────────────

describe("POST /media/confirm-upload", () => {
  it("401 without a token", async () => {
    const { env } = envWithSql([]);
    const res = await handleConfirmUpload(makeCtx({ env, jsonBody: {} }));
    expect(res.status).toBe(401);
  });

  it("missing_field when kind or fileKey is absent", async () => {
    const { env } = envWithSql([]);
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper" } }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("missing_field");
  });

  it("bad_key when fileKey is outside the caller's namespace", async () => {
    const { env } = envWithSql([]);
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { kind: "wallpaper", fileKey: "user/other/x.jpg" },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_key");
  });

  it("invalid_kind when kind is neither wallpaper nor ringtone", async () => {
    const { env } = envWithSql([]);
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { kind: "sticker", fileKey: `user/${USER_ID}/submissions/x.jpg` },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_kind");
  });

  it("not_uploaded when the object does not exist in R2", async () => {
    const { env } = envWithSql([{ id: "sm-1", status: "pending" }]);
    (env as unknown as { R2: { head: unknown } }).R2.head = async () => null;
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { kind: "wallpaper", fileKey: `user/${USER_ID}/submissions/x.jpg` },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("not_uploaded");
  });

  it("too_many_pending once the per-user pending cap is reached", async () => {
    // The shared mock returns the same rows for every query -> the pending count reads at the cap
    // The object must pass QC FIRST, or the 400 arrives before the cap check and this proves nothing
    const { bucket } = makeQcR2({
      [`user/${USER_ID}/submissions/x.jpg`]: { bytes: jpegFixture(), contentType: "image/jpeg" },
    });
    const { env } = envWithSql([{ n: 10 }], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { kind: "wallpaper", fileKey: `user/${USER_ID}/submissions/x.jpg` },
      }),
    );
    expect(res.status).toBe(429);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("too_many_pending");
  });

  it("inserts the submission and returns its id + pending status", async () => {
    const { bucket } = makeQcR2({
      [`user/${USER_ID}/submissions/x.jpg`]: { bytes: jpegFixture(), contentType: "image/jpeg" },
    });
    const { env } = envWithSql([{ id: "sm-1", status: "pending" }], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: {
          kind: "wallpaper",
          fileKey: `user/${USER_ID}/submissions/x.jpg`,
          title: "Kaaba",
        },
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; status: string };
    expect(body.id).toBe("sm-1");
    expect(body.status).toBe("pending");
  });

  // ── Byte-level QC (auto-reject) ─────────────────────────────────────────────

  it("auto-rejects junk bytes behind an image content-type and deletes the object", async () => {
    const key = `user/${USER_ID}/submissions/x.jpg`;
    const junk = new TextEncoder().encode("<html>not an image at all</html>".repeat(4));
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: junk, contentType: "image/jpeg" },
    });
    const { env, capturedArgs } = envWithSql([{ id: "sm-1", status: "pending" }], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_type");
    expect(deletes).toContain(key); // bytes freed immediately — nothing pinned
    expect(capturedArgs).toHaveLength(0); // no submission row was ever written
  });

  it("auto-rejects a standard 1080×1920 phone video (green-edge geometry) with the reason", async () => {
    const key = `user/${USER_ID}/submissions/clip.mp4`;
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: mp4Fixture({ width: 1080, height: 1920 }), contentType: "video/mp4" },
    });
    const { env } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("bad_dimensions");
    expect(body.error.message).toContain("1024×1824");
    expect(deletes).toContain(key);
  });

  it("accepts the canonical 1024×1824 H.264 live wallpaper", async () => {
    const key = `user/${USER_ID}/submissions/clip.mp4`;
    const { bucket } = makeQcR2({
      [key]: { bytes: mp4Fixture(), contentType: "video/mp4" },
    });
    const { env } = envWithSql([{ id: "sm-2", status: "pending" }], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(200);
  });

  it("auto-rejects a non-H.264 video (bad_codec) and deletes the object", async () => {
    // Right geometry, WRONG codec -> budget SoCs only hw-decode avc1/avc3 -> an HEVC clip forces permanent software decode
    const key = `user/${USER_ID}/submissions/clip.mp4`;
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: mp4Fixture({ codec: "hev1" }), contentType: "video/mp4" },
    });
    const { env } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("bad_codec");
    expect(body.error.message).toContain("H.264");
    expect(deletes).toContain(key);
  });

  it("auto-rejects a thumbnail-sized image (below the 480px short-side floor)", async () => {
    const key = `user/${USER_ID}/submissions/tiny.jpg`;
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: jpegFixture(320, 400), contentType: "image/jpeg" },
    });
    const { env } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("bad_dimensions");
    expect(body.error.message).toContain("480");
    expect(deletes).toContain(key);
  });

  it("auto-rejects an object whose REAL size exceeds the per-mime cap (too_large)", async () => {
    // The presign endpoint validates only the CLAIMED size -> the QC gate is the first check of the real byte count
    // Inflate the head() report rather than allocating a real oversize fixture
    const key = `user/${USER_ID}/submissions/huge.jpg`;
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: jpegFixture(), contentType: "image/jpeg" },
    });
    const origHead = bucket.head.bind(bucket);
    (bucket as unknown as { head: unknown }).head = async (k: string) => {
      const h = await origHead(k);
      return h ? { ...h, size: 11 * 1024 * 1024 } : null;
    };
    const { env } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("too_large");
    expect(deletes).toContain(key);
  });

  it("accepts a canonical clip with moov AFTER mdat (non-faststart layout)", async () => {
    // Phone encoders commonly emit moov at the END -> the box walk must skip the multi-MB mdat and still find it
    // Otherwise every non-faststart upload is a false reject
    const key = `user/${USER_ID}/submissions/clip.mp4`;
    const { bucket } = makeQcR2({
      [key]: { bytes: mp4Fixture({ moovAtEnd: true }), contentType: "video/mp4" },
    });
    const { env } = envWithSql([{ id: "sm-3", status: "pending" }], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(200);
  });

  it("a retried confirm is idempotent: the insert upserts on file_key and returns the row", async () => {
    // One object = one submission row -> Postgres enforces it through the unique file_key index
    // The unit-level guarantee is that the insert really is an ON CONFLICT upsert with RETURNING
    // And that a repeat confirm answers 200 with the SAME row rather than erroring
    const key = `user/${USER_ID}/submissions/x.jpg`;
    const { bucket } = makeQcR2({
      [key]: { bytes: jpegFixture(), contentType: "image/jpeg" },
    });
    const { env, capturedArgs } = envWithSql([{ id: "sm-1", status: "pending" }], { R2: bucket });

    const body = { kind: "wallpaper", fileKey: key };
    const first = await handleConfirmUpload(makeCtx({ env, token: await token(), jsonBody: body }));
    const second = await handleConfirmUpload(makeCtx({ env, token: await token(), jsonBody: body }));

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(((await first.json()) as { id: string }).id).toBe(((await second.json()) as { id: string }).id);

    const insertSql = capturedArgs
      .map((args) => (args[0] as unknown as string[]).join(" "))
      .filter((text) => text.includes("INSERT INTO content_submissions"));
    expect(insertSql).toHaveLength(2);
    for (const text of insertSql) {
      expect(text).toContain("ON CONFLICT (file_key) DO UPDATE");
      expect(text).toContain("RETURNING");
    }
  });

  it("auto-rejects audio bytes submitted as a WALLPAPER (the role is per-kind, not global)", async () => {
    const key = `user/${USER_ID}/submissions/x.mp3`;
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: mp3Fixture(), contentType: "audio/mpeg" },
    });
    const { env } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "wallpaper", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_type");
    expect(deletes).toContain(key);
  });

  // ── kind=ringtone (user ringtone submissions) ───────────────────────────────

  it("accepts a ringtone submission and QCs it against the AUDIO rules", async () => {
    const key = `user/${USER_ID}/submissions/kavasam.mp3`;
    const { bucket } = makeQcR2({
      [key]: { bytes: mp3Fixture(), contentType: "audio/mpeg" },
    });
    const { env } = envWithSql([{ id: "sm-r1", status: "pending" }], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: {
          kind: "ringtone",
          fileKey: key,
          title: "Kanda Sasti Kavasam",
          category: "murugan",
        },
      }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; status: string };
    expect(body.id).toBe("sm-r1");
    expect(body.status).toBe("pending");
  });

  it("auto-rejects a VIDEO renamed as a ringtone (m4a container carrying a video track)", async () => {
    // The one abuse the audio branch exists to catch -> an .m4a-labelled MP4 carrying video would ship as a "ringtone"
    const key = `user/${USER_ID}/submissions/clip.m4a`;
    const { bucket, deletes } = makeQcR2({
      // withAudio -> a real renamed video carries BOTH tracks -> it clears "has an audio track" and only the video rule stops it
      [key]: { bytes: mp4Fixture({ withAudio: true }), contentType: "audio/mp4" },
    });
    const { env, capturedArgs } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "ringtone", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("bad_type");
    expect(body.error.message).toContain("audio only");
    expect(deletes).toContain(key);
    expect(capturedArgs).toHaveLength(0); // nothing pinned, no row written
  });

  it("auto-rejects a live-wallpaper mp4 submitted as a ringtone", async () => {
    const key = `user/${USER_ID}/submissions/clip.mp4`;
    const { bucket, deletes } = makeQcR2({
      [key]: { bytes: mp4Fixture(), contentType: "video/mp4" },
    });
    const { env } = envWithSql([], { R2: bucket });
    const res = await handleConfirmUpload(
      makeCtx({ env, token: await token(), jsonBody: { kind: "ringtone", fileKey: key } }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("bad_type");
    expect(deletes).toContain(key);
  });
});

// ── The status QC role (the CMS's copy enforces it at upload; this copy stays in step) ──
describe("verifyMediaObject — status role", () => {
  const verify = (bytes: Uint8Array, contentType = "video/mp4") =>
    verifyMediaObject(makeQcR2({ k: { bytes, contentType } }).bucket, "k", "status");

  it("accepts a 1024×1824 H.264 clip with music, at most 30 s", async () => {
    const r = await verify(mp4Fixture({ withAudio: true, durationS: 30 }));
    expect(r).toMatchObject({ ok: true, width: 1024, height: 1824, durationMs: 30000 });
  });

  it("rejects a clip with no audio track", async () => {
    expect(await verify(mp4Fixture({ durationS: 20 }))).toMatchObject({ ok: false, code: "bad_type" });
  });

  it("rejects a clip over 30 s", async () => {
    expect(await verify(mp4Fixture({ withAudio: true, durationS: 31 }))).toMatchObject({
      ok: false,
      code: "too_large",
    });
  });

  it("accepts any shape on the video rule and reports it — a 2:3 source stays 2:3", async () => {
    for (const [width, height] of [
      [1024, 1536],
      [896, 1600],
      [1024, 576],
    ] as const) {
      const r = await verify(mp4Fixture({ withAudio: true, width, height }));
      expect(r).toMatchObject({ ok: true, width, height });
    }
  });

  it("rejects a shape off the video rule, exactly as a live wallpaper would", async () => {
    for (const [width, height] of [
      [1080, 1920],
      [1024, 1830],
      [1152, 1536],
    ] as const) {
      const r = await verify(mp4Fixture({ withAudio: true, width, height }));
      expect(r).toMatchObject({ ok: false, code: "bad_dimensions" });
    }
  });

  it("rejects a file over 10 MB before reading a byte", async () => {
    const bucket = {
      head: async () => ({
        key: "k",
        size: 10 * 1024 * 1024 + 1,
        httpMetadata: { contentType: "video/mp4" },
      }),
      get: vi.fn(),
    } as unknown as R2Bucket;
    expect(await verifyMediaObject(bucket, "k", "status")).toMatchObject({ ok: false, code: "too_large" });
  });

  it("rejects an image", async () => {
    expect(await verify(jpegFixture(), "image/jpeg")).toMatchObject({ ok: false, code: "bad_type" });
  });
});
