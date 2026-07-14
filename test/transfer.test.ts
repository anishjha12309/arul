/**
 * Category transfer (/arul/transfer) — copy-before-update semantics.
 *
 *   happy path       — media + thumbs copied, one batch txn (single version
 *                      bump), old objects deleted AFTER commit, rebuild fired
 *   missing thumb    — not an error; no phantom thumb copy or delete
 *   mid-batch failure— the failed item is excluded from the DB update and
 *                      reported per-item; the rest still move
 *   db txn failure   — nothing moves; new thumb copies are explicitly removed
 *                      (thumbs/ is not swept), old objects stay untouched
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { makeEnv, makeMockR2, makeMockSql, execCtx, stubFetch, capturedSqlText } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import { makeTransferApp } from "../src/pages/transfer.js";
import { ARUL, arulThumbKey } from "../src/registry.js";

const ROW_A = {
  id: "0b0b0b0b-0000-0000-0000-000000000001",
  title: "Static A",
  type: "static",
  category: "amman",
  full_key: "wallpapers/amman/aaa.jpg",
};
const ROW_B = {
  id: "0b0b0b0b-0000-0000-0000-000000000002",
  title: "Live B",
  type: "live",
  category: "amman",
  full_key: "wallpapers/amman/bbb.mp4",
};

function transferBody(ids: string[]): URLSearchParams {
  const body = new URLSearchParams();
  body.set("source", "amman");
  body.set("target", "murugan");
  for (const id of ids) body.append("ids", id);
  return body;
}

const post = (env: Env, body: URLSearchParams) =>
  makeTransferApp(ARUL).fetch(
    new Request("https://hsr-cms.example.com/", { method: "POST", body }),
    env,
    execCtx,
  );

beforeEach(() => {
  vi.unstubAllGlobals();
});

describe("arulThumbKey", () => {
  it("maps a full key to its thumbs/<category>/<stem>.jpg sibling", () => {
    expect(arulThumbKey("wallpapers/amman/aaa.jpg")).toBe("thumbs/amman/aaa.jpg");
    expect(arulThumbKey("wallpapers/amman/bbb.mp4")).toBe("thumbs/amman/bbb.jpg");
    expect(arulThumbKey("user/xyz/submissions/a.jpg")).toBeNull();
  });
});

describe("category transfer", () => {
  it("happy path: copies media + thumb, one version bump, deletes old after commit, rebuilds", async () => {
    const fetchFn = stubFetch(200);
    const arulR2 = makeMockR2({
      initial: {
        "wallpapers/amman/aaa.jpg": { contentType: "image/jpeg" },
        "thumbs/amman/aaa.jpg": { contentType: "image/jpeg" },
        "wallpapers/amman/bbb.mp4": { contentType: "video/mp4" },
        "thumbs/amman/bbb.jpg": { contentType: "image/jpeg" },
      },
    });
    const arulSql = makeMockSql([ROW_A, ROW_B]);
    const { env } = makeEnv({ arulSql, arulR2 });

    const res = await post(env, transferBody([ROW_A.id, ROW_B.id]));
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("2 moved");
    expect(html).toContain("0 failed");

    // New objects exist under the target category (media + both thumbs).
    expect(arulR2.store.has("wallpapers/murugan/aaa.jpg")).toBe(true);
    expect(arulR2.store.has("thumbs/murugan/aaa.jpg")).toBe(true);
    expect(arulR2.store.has("wallpapers/murugan/bbb.mp4")).toBe(true);
    expect(arulR2.store.has("thumbs/murugan/bbb.jpg")).toBe(true);
    // Old objects were deleted (only after the txn committed).
    expect(arulR2.store.has("wallpapers/amman/aaa.jpg")).toBe(false);
    expect(arulR2.store.has("thumbs/amman/aaa.jpg")).toBe(false);
    expect(arulR2.store.has("wallpapers/amman/bbb.mp4")).toBe(false);
    expect(arulR2.store.has("thumbs/amman/bbb.jpg")).toBe(false);

    // One batch transaction with per-row UPDATE + exactly ONE version bump.
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("UPDATE wallpapers SET category =");
    const bumps = text.match(/content_version = content_version \+ 1/g) ?? [];
    expect(bumps.length).toBe(1);

    // Rebuild fired once against Arul's API.
    expect(fetchFn).toHaveBeenCalledTimes(1);
    expect(String(fetchFn.mock.calls[0]![0])).toBe(
      "https://arul-api.twilight-smoke-d495.workers.dev/internal/build-catalog",
    );
  });

  it("a missing thumb is not an error: media moves, no phantom thumb copy/delete", async () => {
    stubFetch(200);
    const arulR2 = makeMockR2({
      initial: { "wallpapers/amman/aaa.jpg": { contentType: "image/jpeg" } }, // NO thumb
    });
    const arulSql = makeMockSql([ROW_A]);
    const { env } = makeEnv({ arulSql, arulR2 });

    const res = await post(env, transferBody([ROW_A.id]));
    const html = await res.text();
    expect(html).toContain("1 moved");
    expect(html).toContain("0 failed");

    expect(arulR2.store.has("wallpapers/murugan/aaa.jpg")).toBe(true);
    expect(arulR2.store.has("wallpapers/amman/aaa.jpg")).toBe(false);
    // The thumb was probed but never written or deleted.
    expect(arulR2.calls.put).not.toContain("thumbs/murugan/aaa.jpg");
    expect(arulR2.calls.delete).not.toContain("thumbs/amman/aaa.jpg");
  });

  it("mid-batch copy failure: failed item excluded and reported, the rest move", async () => {
    stubFetch(200);
    const arulR2 = makeMockR2({
      initial: {
        "wallpapers/amman/aaa.jpg": { contentType: "image/jpeg" },
        "wallpapers/amman/bbb.mp4": { contentType: "video/mp4" },
      },
      failPutKeys: ["wallpapers/murugan/bbb.mp4"], // B's media copy blows up
    });
    const arulSql = makeMockSql([ROW_A, ROW_B]);
    const { env } = makeEnv({ arulSql, arulR2 });

    const res = await post(env, transferBody([ROW_A.id, ROW_B.id]));
    const html = await res.text();
    expect(html).toContain("1 moved");
    expect(html).toContain("1 failed");
    expect(html).toContain("copy failed");

    // A moved; B kept its original key and bytes.
    expect(arulR2.store.has("wallpapers/murugan/aaa.jpg")).toBe(true);
    expect(arulR2.store.has("wallpapers/amman/aaa.jpg")).toBe(false);
    expect(arulR2.store.has("wallpapers/amman/bbb.mp4")).toBe(true);

    // The txn still ran for the successful item (one bump).
    expect(arulSql.beginCalls).toBe(1);
    const bumps = capturedSqlText(arulSql).match(/content_version = content_version \+ 1/g) ?? [];
    expect(bumps.length).toBe(1);
  });

  it("db txn failure: nothing moves, old objects untouched, new thumbs cleaned up", async () => {
    const fetchFn = stubFetch(200);
    const arulR2 = makeMockR2({
      initial: {
        "wallpapers/amman/aaa.jpg": { contentType: "image/jpeg" },
        "thumbs/amman/aaa.jpg": { contentType: "image/jpeg" },
      },
    });
    const arulSql = makeMockSql([ROW_A], { failBegin: true });
    const { env } = makeEnv({ arulSql, arulR2 });

    const res = await post(env, transferBody([ROW_A.id]));
    const html = await res.text();
    expect(html).toContain("0 moved");
    expect(html).toContain("1 failed");
    expect(html).toContain("db failed");

    // Originals untouched.
    expect(arulR2.store.has("wallpapers/amman/aaa.jpg")).toBe(true);
    expect(arulR2.store.has("thumbs/amman/aaa.jpg")).toBe(true);
    // The new THUMB copy was explicitly removed (thumbs/ is not swept); the
    // new media copy was also removed best-effort.
    expect(arulR2.calls.delete).toContain("thumbs/murugan/aaa.jpg");
    expect(arulR2.store.has("thumbs/murugan/aaa.jpg")).toBe(false);
    // No rebuild fired — the catalog didn't change.
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it("rejects a transfer where target equals source", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [ROW_A] });
    const body = new URLSearchParams();
    body.set("source", "amman");
    body.set("target", "amman");
    body.append("ids", ROW_A.id);

    const res = await post(env, body);
    expect(res.status).toBe(302);
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("must differ");
    expect(arulSql.capturedArgs.length).toBe(0);
  });
});
