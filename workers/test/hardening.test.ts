/**
 * Tests for the hardening pass (ported from the reference app):
 *   #7  money routes gated by OPS_SECRET, not CATALOG_BUILD_SECRET
 *   #9  thumbs/ orphan reclamation (derived keys)
 *   #16 atomic refresh-token rotation
 *   #19 rate limiting (must fail OPEN)
 *   #20 refund amount cap + order-ownership check
 *
 * The monotonic-version-pointer suite lives in admin-version.test.ts.
 */

import { describe, it, expect, vi } from "vitest";
import { makeEnv, makeCtx, makeMockKV } from "./_ctx.js";
import { thumbKeyFor, selectCanonicalKeysToDelete } from "../src/cron/sweep-canonical.js";
import { claimRefreshJti } from "../src/lib/jwt.js";
import { allowRequest, clientIp, tooManyRequests } from "../src/lib/ratelimit.js";
import { handleRunRedemptions, handleRefund } from "../src/routes/internal.js";

// ── #7 money routes require OPS_SECRET ───────────────────────────────────────

describe("money routes are NOT authorized by CATALOG_BUILD_SECRET", () => {
  // CATALOG_BUILD_SECRET is handed to the CMS worker for rebuild triggers, so it
  // must not also authorize "charge every subscriber ₹199".
  it("run-redemptions rejects the catalog secret", async () => {
    const env = makeEnv();
    const res = await handleRunRedemptions(
      makeCtx({ env, token: "test-catalog-secret", jsonBody: { force: true } }),
    );
    expect(res.status).toBe(401);
  });

  it("refund rejects the catalog secret", async () => {
    const env = makeEnv();
    const res = await handleRefund(
      makeCtx({ env, token: "test-catalog-secret", jsonBody: { originalMerchantOrderId: "X" } }),
    );
    expect(res.status).toBe(401);
  });

  it("both reject when OPS_SECRET is unset (fail closed)", async () => {
    const env = makeEnv({ OPS_SECRET: "" });
    expect(
      (await handleRunRedemptions(makeCtx({ env, token: "", jsonBody: {} }))).status,
    ).toBe(401);
    expect(
      (await handleRefund(makeCtx({ env, token: "anything", jsonBody: {} }))).status,
    ).toBe(401);
  });

  it("refund refuses an amount above one month", async () => {
    const env = makeEnv();
    const res = await handleRefund(
      makeCtx({
        env,
        token: "test-ops-secret",
        jsonBody: { originalMerchantOrderId: "DKS_R_X", amountPaise: 1_000_000 },
      }),
    );
    expect(res.status).toBe(400);
    expect((await res.json() as { error: { code: string } }).error.code).toBe(
      "amount_too_large",
    );
  });
});

// ── #9 thumbs/ reclamation ───────────────────────────────────────────────────

describe("thumb key derivation + sweep scoping", () => {
  it("derives a category-partitioned poster key from a wallpaper key", () => {
    expect(thumbKeyFor("wallpapers/murugan/abc.mp4")).toBe("thumbs/murugan/abc.jpg");
    // Over-inclusive BY DESIGN (unlike the reference app): a static .jpg also
    // maps — its thumb may simply not exist, and the sweep tolerates absent
    // keys. Only non-wallpaper prefixes are excluded.
    expect(thumbKeyFor("wallpapers/sivan/abc.jpg")).toBe("thumbs/sivan/abc.jpg");
    expect(thumbKeyFor("ringtones/murugan/abc.mp3")).toBeNull();
    expect(thumbKeyFor("ringtones/covers/murugan/abc.jpg")).toBeNull();
  });

  it("keeps a poster whose wallpaper still exists, deletes a stranded one", () => {
    const NOW = 1_700_000_000_000;
    const OLD = NOW - 13 * 60 * 60 * 1000;
    const expected = new Set(["thumbs/murugan/kept.jpg"]);
    const out = selectCanonicalKeysToDelete(
      [
        { key: "thumbs/murugan/kept.jpg", uploadedMs: OLD },
        { key: "thumbs/murugan/stranded.jpg", uploadedMs: OLD },
      ],
      expected,
      NOW,
      undefined,
      "thumbs/",
    );
    expect(out).toEqual(["thumbs/murugan/stranded.jpg"]);
  });

  it("the active-prefix scope stops one prefix judging another's keys", () => {
    const NOW = 1_700_000_000_000;
    const OLD = NOW - 13 * 60 * 60 * 1000;
    // Sweeping wallpapers/ must ignore a thumbs/ key entirely, even though it is
    // absent from the wallpaper reference set.
    const out = selectCanonicalKeysToDelete(
      [{ key: "thumbs/murugan/x.jpg", uploadedMs: OLD }],
      new Set(["wallpapers/murugan/x.mp4"]),
      NOW,
      undefined,
      "wallpapers/",
    );
    expect(out).toEqual([]);
  });
});

// ── #16 atomic refresh rotation ──────────────────────────────────────────────

describe("claimRefreshJti", () => {
  const exp = Math.floor(Date.now() / 1000) + 3600;

  it("the first claimant wins", async () => {
    const kv = makeMockKV();
    expect(await claimRefreshJti(kv, "jti-1", exp)).toBe(true);
  });

  it("a second claim on the same jti loses (no session fork)", async () => {
    const kv = makeMockKV();
    expect(await claimRefreshJti(kv, "jti-2", exp)).toBe(true);
    expect(await claimRefreshJti(kv, "jti-2", exp)).toBe(false);
  });

  it("an already-denylisted jti cannot be claimed", async () => {
    const kv = makeMockKV(new Map([["jti:revoked", "1"]]));
    expect(await claimRefreshJti(kv, "revoked", exp)).toBe(false);
  });
});

// ── #19 rate limiting must fail OPEN ─────────────────────────────────────────

describe("rate limiting", () => {
  it("allows when the binding is not configured", async () => {
    expect(await allowRequest(undefined, "k")).toBe(true);
  });

  it("allows when the limiter throws (never take the app down)", async () => {
    const broken = { limit: vi.fn(async () => { throw new Error("nope"); }) } as unknown as RateLimit;
    expect(await allowRequest(broken, "k")).toBe(true);
  });

  it("blocks only when the limiter explicitly says no", async () => {
    const deny = { limit: vi.fn(async () => ({ success: false })) } as unknown as RateLimit;
    const allow = { limit: vi.fn(async () => ({ success: true })) } as unknown as RateLimit;
    expect(await allowRequest(deny, "k")).toBe(false);
    expect(await allowRequest(allow, "k")).toBe(true);
  });

  it("prefers CF-Connecting-IP and degrades to a shared bucket, never to no limit", () => {
    expect(clientIp({ header: (n) => (n === "CF-Connecting-IP" ? "1.2.3.4" : undefined) })).toBe("1.2.3.4");
    expect(clientIp({ header: () => undefined })).toBe("unknown");
  });

  it("429 carries the app's error envelope and Retry-After", async () => {
    const res = tooManyRequests();
    expect(res.status).toBe(429);
    expect(res.headers.get("Retry-After")).toBe("60");
    expect((await res.json() as { error: { code: string } }).error.code).toBe("rate_limited");
  });
});

// ── Refresh reuse-grace: a retried refresh must NOT sign a user out ──────────

describe("refresh rotation reuse grace", () => {
  it("replays the same pair to a retry of an already-rotated token", async () => {
    const { storeRotationReplay, readRotationReplay } = await import("../src/lib/jwt.js");
    const kv = makeMockKV();
    const pair = { accessToken: "acc-1", refreshToken: "ref-1" };
    await storeRotationReplay(kv, "old-jti", pair);
    expect(await readRotationReplay(kv, "old-jti")).toEqual(pair);
  });

  it("returns null for a token that was never rotated (genuine revocation)", async () => {
    const { readRotationReplay } = await import("../src/lib/jwt.js");
    expect(await readRotationReplay(makeMockKV(), "never-seen")).toBeNull();
  });

  it("ignores a malformed replay entry rather than handing back junk", async () => {
    const { readRotationReplay } = await import("../src/lib/jwt.js");
    const kv = makeMockKV(new Map([["rot:bad", JSON.stringify({ accessToken: 1 })]]));
    expect(await readRotationReplay(kv, "bad")).toBeNull();
  });
});
