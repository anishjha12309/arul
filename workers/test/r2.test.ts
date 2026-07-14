/**
 * Unit tests for R2 presigned URL generation (aws4fetch, Web Crypto only).
 * No network — sign() computes the URL locally.
 */

import { describe, it, expect } from "vitest";
import { presignGet, presignPut } from "../src/lib/r2.js";
import type { Env } from "../src/env.js";

function env(): Env {
  return {
    R2_ACCESS_KEY_ID: "AKIATESTKEY",
    R2_SECRET_ACCESS_KEY: "test-secret-access-key",
    R2_ENDPOINT: "https://acct123.r2.cloudflarestorage.com",
    R2_BUCKET: "south-indian-wallpapers",
  } as unknown as Env;
}

describe("presignGet", () => {
  it("produces a signed URL for the bucket+key with the default 300s expiry", async () => {
    const url = await presignGet(env(), "wallpapers/murugan/live.mp4");
    expect(url).toContain("acct123.r2.cloudflarestorage.com");
    expect(url).toContain("/south-indian-wallpapers/");
    expect(url).toContain("wallpapers");
    expect(url).toContain("X-Amz-Signature=");
    expect(url).toContain("X-Amz-Expires=300");
    expect(url).toContain("X-Amz-Credential=");
  });

  it("honours a custom TTL", async () => {
    const url = await presignGet(env(), "k", 60);
    expect(url).toContain("X-Amz-Expires=60");
  });

  it("url-encodes each key segment but keeps slashes as path separators", async () => {
    const url = await presignGet(env(), "user/abc def/file.jpg");
    const path = new URL(url).pathname;
    expect(path).toContain("%20"); // space within a segment is encoded
    expect(path).not.toContain("abc def");
    // slashes must remain literal (not %2F) in the PATH so S3/R2 sees real
    // separators (the X-Amz-Credential query value legitimately contains %2F).
    expect(path.toLowerCase()).not.toContain("%2f");
    expect(path).toBe("/south-indian-wallpapers/user/abc%20def/file.jpg");
  });

  it("different keys yield different signatures", async () => {
    const a = await presignGet(env(), "a.mp3");
    const b = await presignGet(env(), "b.mp3");
    expect(a).not.toBe(b);
  });
});

describe("presignPut", () => {
  it("produces a signed PUT URL that signs the content-type header", async () => {
    const url = await presignPut(env(), "user/u1/submissions/x.jpg", "image/jpeg");
    expect(url).toContain("/south-indian-wallpapers/");
    expect(url).toContain("X-Amz-Signature=");
    expect(url).toContain("X-Amz-Expires=300");
    // content-type is part of the signed headers
    expect(url.toLowerCase()).toContain("content-type");
  });
});
