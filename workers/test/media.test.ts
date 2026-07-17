/**
 * Unit tests for the media route handlers. The DB is mocked; R2 presigning runs
 * for real (aws4fetch / Web Crypto). These cover validation, lookup, and the
 * premium-gated signed URL path. NOTE (2026-07-01): ALL content now requires
 * premium to apply/set/save. The success path is premium because the shared
 * single-rows SQL mock returns the same non-empty rows for BOTH the content
 * lookup and the entitlement query, so isPremium() reads as true. A pure
 * 403-deny test isn't expressible with that mock; the deny path is covered by
 * the live deployed-worker checks. (There is no PREMIUM_TEST_USER_IDS bypass —
 * it was removed; premium comes solely from a live Neon subscription row.)
 */

import { describe, it, expect, vi } from "vitest";
import { makeEnv, makeCtx, makeMockSql } from "./_ctx.js";
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
    // The mock returns these rows for BOTH the content lookup and the
    // entitlement query, so isPremium() reads true (premium) for this user.
    const { env } = envWithSql([{ private_key: "wallpapers/murugan/live.mp4" }]);
    const res = await handleSignedUrl(
      makeCtx({ env, token: await token(), jsonBody: { id: "w1", kind: "wallpaper" } }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; expiresIn: number };
    expect(body.expiresIn).toBe(300);
    expect(body.url).toContain("X-Amz-Signature=");
    expect(body.url).toContain("wallpapers");
  });

  it("resolves kind=ringtone via audio_key and returns a signed URL for a premium user", async () => {
    // Same shared-mock caveat as the wallpaper success path: the mock returns
    // the row for both the ringtones lookup (audio_key AS private_key) and the
    // entitlement query, so isPremium() — checked live, never from the JWT —
    // reads true.
    const { env } = envWithSql([{ private_key: "ringtones/murugan/abc.mp3" }]);
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

  it("bad_type for a disallowed content type", async () => {
    const { env } = envWithSql([]);
    const res = await handleUploadUrl(
      makeCtx({
        env,
        token: await token(),
        jsonBody: { key: `user/${USER_ID}/x.txt`, contentType: "text/plain" },
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
          key: `user/${USER_ID}/x.jpg`,
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
    const { env } = envWithSql([{ n: 10 }]);
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
    const { env } = envWithSql([{ id: "sm-1", status: "pending" }]);
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
});
