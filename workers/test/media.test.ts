/**
 * Unit tests for the media route handlers. The DB is mocked; R2 presigning runs
 * for real (aws4fetch / Web Crypto). These cover validation, lookup, and the
 * premium-gated signed URL path. ALL content requires premium to
 * apply/set/save. /media/signed-url answers the content lookup AND the
 * entitlement check in ONE combined query (private_key + is_premium in a
 * single row), so the mock row carries both columns — the 403-deny path is
 * covered here with is_premium: false (the CMS repo's live smoke plan,
 * c:\Anish\Unified CMS\test\LIVE-SMOKE-PLAN.md, also exercises it against the
 * deployed worker). (There is no PREMIUM_TEST_USER_IDS
 * bypass — it was removed; premium comes solely from a live Neon subscription
 * row.)
 */

import { describe, it, expect, vi } from "vitest";
import { makeEnv, makeCtx, makeMockSql } from "./_ctx.js";
import { makeQcR2, jpegFixture, mp4Fixture, mp3Fixture } from "./_media.js";
import { signAccessToken } from "../src/lib/jwt.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

import {
  handleSignedUrl,
  handleUploadUrl,
  handleConfirmUpload,
} from "../src/routes/media.js";

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
    // The combined query returns the content key and the live entitlement in
    // one row — the mock row mirrors that shape.
    const { env } = envWithSql([
      { private_key: "wallpapers/murugan/live.mp4", is_premium: true },
    ]);
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
    // The key exists and is published, but the entitlement half of the combined
    // row is false — entitlement is read live from Neon, never from the JWT, so
    // a lapsed/refunded user is refused even with a valid token.
    const { env } = envWithSql([
      { private_key: "wallpapers/murugan/live.mp4", is_premium: false },
    ]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "w1", kind: "wallpaper" } }),
    );
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe(
      "premium_required",
    );
  });

  it("resolves kind=ringtone via audio_key and returns a signed URL for a premium user", async () => {
    // Same combined-row shape as the wallpaper success path: the ringtones
    // lookup surfaces audio_key AS private_key next to the live entitlement.
    const { env } = envWithSql([
      { private_key: "ringtones/murugan/abc.mp3", is_premium: true },
    ]);
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
        // Valid owner prefix, wrong shape — sweep-submissions only reclaims
        // objects containing "/submissions/", so accepting this would strand
        // the bytes in R2 forever.
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

  it("invalid_kind for kind=ringtone (user submissions stay wallpaper-only in Arul)", async () => {
    const { env } = envWithSql([]);
    const res = await handleConfirmUpload(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { kind: "ringtone", fileKey: `user/${USER_ID}/submissions/x.mp3` },
      }),
    );
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_kind");
  });

  it("invalid_kind when kind is not wallpaper", async () => {
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
    // The shared mock returns the same rows for every query, so the pending
    // count reads n=10 — at the cap — and the handler must refuse before insert.
    // The object must pass QC first, or the 400 arrives before the cap check.
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
    // Right geometry, wrong codec: budget-SoC fleets only hw-decode avc1/avc3;
    // an HEVC clip would force permanent software decode (CLAUDE.md gotcha 1).
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
    // The presign endpoint only validates the CLAIMED size; the QC gate is the
    // first place the actual byte count is checked. Simulate a 11MB jpeg by
    // inflating the head() report rather than allocating 11MB of fixture.
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
    // Phone encoders commonly emit moov at the end; the box walk must skip the
    // multi-MB mdat and still find it, or every such upload is a false reject.
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
    // One object = one submission row (edge-cases §Upload). Postgres enforces
    // this via the unique file_key index; the unit-level guarantee is that the
    // insert really is an ON CONFLICT upsert with RETURNING, and that a repeat
    // confirm answers 200 with the same row instead of erroring.
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
    expect(((await first.json()) as { id: string }).id).toBe(
      ((await second.json()) as { id: string }).id,
    );

    const insertSql = capturedArgs
      .map((args) => (args[0] as unknown as string[]).join(" "))
      .filter((text) => text.includes("INSERT INTO content_submissions"));
    expect(insertSql).toHaveLength(2);
    for (const text of insertSql) {
      expect(text).toContain("ON CONFLICT (file_key) DO UPDATE");
      expect(text).toContain("RETURNING");
    }
  });

  it("auto-rejects audio bytes submitted as a wallpaper (Arul is wallpaper-only)", async () => {
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
});
