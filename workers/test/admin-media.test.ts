/**
 * Unit tests for the admin media presign handler. R2 presigning runs for real
 * (aws4fetch / Web Crypto); the handler returns the server-chosen canonical key.
 */

import { describe, it, expect } from "vitest";
import { makeCtx, makeEnv } from "./_ctx.js";
import { handleAdminUploadUrl } from "../src/admin/media.js";

async function call(body: unknown, invalidJson = false) {
  const env = makeEnv();
  const res = await handleAdminUploadUrl(
    makeCtx({ env, jsonBody: body, invalidJson }),
  );
  return res;
}

describe("POST /admin/media/upload-url", () => {
  it("400 on invalid JSON body", async () => {
    const res = await call(undefined, true);
    expect(res.status).toBe(400);
  });

  it("400 when kind, contentType or category missing", async () => {
    expect((await call({ contentType: "image/jpeg", category: "murugan" })).status).toBe(400);
    expect((await call({ kind: "wallpaper", category: "murugan" })).status).toBe(400);
    // category is REQUIRED — it is the canonical key partition (browse axis)
    expect((await call({ kind: "wallpaper", contentType: "image/jpeg" })).status).toBe(400);
  });

  it("400 on a disallowed content type", async () => {
    const res = await call({ kind: "wallpaper", contentType: "image/gif", category: "murugan" });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("bad_type");
  });

  it("400 when the file exceeds the type limit", async () => {
    const res = await call({
      kind: "wallpaper",
      contentType: "video/mp4",
      size: 999 * 1024 * 1024,
      category: "murugan",
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("too_large");
  });

  it("400 on a bad kind/type combination", async () => {
    // wallpaper with an audio type
    expect(
      (await call({ kind: "wallpaper", contentType: "audio/mpeg", category: "murugan" })).status,
    ).toBe(400);
    // ringtone is not a kind in Arul
    expect(
      (await call({ kind: "ringtone", contentType: "audio/mpeg", category: "murugan" })).status,
    ).toBe(400);
    // unknown kind
    expect(
      (await call({ kind: "bogus", contentType: "image/jpeg", category: "murugan" })).status,
    ).toBe(400);
  });

  it("static wallpaper image → wallpapers/<category>/<uuid>.jpg + signed URL", async () => {
    const res = await call({
      kind: "wallpaper",
      contentType: "image/jpeg",
      size: 1234,
      category: "murugan",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; key: string; uploadUrl: string };
    expect(body.key).toMatch(/^wallpapers\/murugan\/[0-9a-f-]{36}\.jpg$/);
    expect(body.uploadUrl).toContain("X-Amz-Signature=");
  });

  it("live wallpaper mp4 → wallpapers/<category>/<uuid>.mp4", async () => {
    const res = await call({
      kind: "wallpaper",
      contentType: "video/mp4",
      size: 1234,
      category: "temples",
    });
    const body = (await res.json()) as { key: string };
    expect(body.key).toMatch(/^wallpapers\/temples\/[0-9a-f-]{36}\.mp4$/);
  });

  it("normalizes a free-text category into the key segment", async () => {
    const res = await call({
      kind: "wallpaper",
      contentType: "image/jpeg",
      category: "  New Deity  ",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { key: string };
    expect(body.key).toMatch(/^wallpapers\/new-deity\/[0-9a-f-]{36}\.jpg$/);
  });
});
