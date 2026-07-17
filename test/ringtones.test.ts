/**
 * ARUL ringtones page (pages/ringtones-arul.tsx): render, create validation
 * (missing cover), batch items_json validation, transactional version bump +
 * rebuild, and the "R2 bytes go only after a confirmed rebuild" rule — plus
 * the pure batch stem-pairing helpers (lib/ringtone-batch.ts) that the page's
 * inline uploader script mirrors.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { makeEnv, execCtx, stubFetch, capturedSqlText } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import { makeArulRingtonesApp } from "../src/pages/ringtones-arul.js";
import { pairByStem, prettifyStem, stemOf } from "../src/lib/ringtone-batch.js";
import { ARUL, PAKIZA } from "../src/registry.js";

beforeEach(() => {
  vi.unstubAllGlobals();
});

const ID_A = "1c237f37-e962-470b-99a8-9be57c080f88";
const ID_B = "303dc99d-4018-49bb-8506-b160673c22f5";

const post = (
  app: ReturnType<typeof makeArulRingtonesApp>,
  env: Env,
  path: string,
  body: Record<string, string>,
) =>
  app.fetch(
    new Request(`https://hsr-cms.example.com${path}`, {
      method: "POST",
      body: new URLSearchParams(body),
    }),
    env,
    execCtx,
  );

describe("batch stem pairing (lib/ringtone-batch)", () => {
  it("pairs by case-insensitive stem and derives prettified titles", () => {
    const r = pairByStem(["song-one_final.mp3", "Bell.m4a"], ["Song-One_Final.jpg", "bell.jpeg"]);
    expect(r.errors).toEqual([]);
    expect(r.pairs).toHaveLength(2);
    expect(r.pairs[0]).toMatchObject({
      audio: "song-one_final.mp3",
      cover: "Song-One_Final.jpg",
      title: "Song One Final",
    });
    expect(r.pairs[1]!.title).toBe("Bell");
  });

  it("an audio without a cover gets a specific per-file error", () => {
    const r = pairByStem(["song1.mp3", "song2.mp3"], ["song1.jpg"]);
    expect(r.pairs).toHaveLength(1);
    expect(r.errors).toContain("song2.mp3: no matching cover image (expected song2.jpg)");
  });

  it("a cover without an audio gets a specific per-file error", () => {
    const r = pairByStem(["song1.mp3"], ["song1.jpg", "art9.jpg"]);
    expect(r.pairs).toHaveLength(1);
    expect(r.errors).toContain("art9.jpg: no matching audio file");
  });

  it("wrong extensions and duplicate stems are rejected per file", () => {
    const r = pairByStem(
      ["a.wav", "b.mp3", "b.mp3"],
      ["b.jpg", "b.jpg", "c.png"],
    );
    expect(r.errors.some((e) => e.startsWith("a.wav: unsupported audio type"))).toBe(true);
    expect(r.errors.some((e) => e.startsWith("c.png: covers must be JPEG"))).toBe(true);
    expect(r.errors.some((e) => e.includes('same name stem "b"'))).toBe(true);
    // The ambiguous cover stem also blocks its audio from silently pairing.
    expect(r.pairs).toHaveLength(0);
  });

  it("stemOf / prettifyStem behave on edge inputs", () => {
    expect(stemOf("noext")).toBe("noext");
    expect(stemOf("a.b.mp3")).toBe("a.b");
    expect(prettifyStem("om__namah--shivaya")).toBe("Om Namah Shivaya");
  });
});

describe("arul ringtones factory", () => {
  it("refuses to mount for Pakiza (legacy factory owns that page)", () => {
    expect(() => makeArulRingtonesApp(PAKIZA)).toThrow();
  });
});

describe("create validation", () => {
  it("rejects a create whose cover upload is missing, cleans the audio orphan, never writes", async () => {
    stubFetch(200);
    const { env, arulSql, arulR2 } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);

    const res = await post(app, env, "/", {
      title: "Om Bell",
      category: "murugan",
      key_audio: "ringtones/murugan/x.mp3",
      mime_audio: "audio/mpeg",
      // key_cover deliberately absent
    });
    expect(res.status).toBe(302);
    const loc = decodeURIComponent(res.headers.get("location") ?? "");
    expect(loc).toContain("err=");
    expect(loc).toContain("cover");
    expect(arulSql.beginCalls).toBe(0);
    // the already-uploaded audio object is removed (benign orphan cleanup)
    expect(arulR2.calls.delete).toContain("ringtones/murugan/x.mp3");
  });

  it("rejects a create with no category before anything else", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/", { title: "X" });
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("Category is required");
    expect(arulSql.beginCalls).toBe(0);
  });

  it("a valid create inserts + bumps content_version in ONE txn and rebuilds Arul", async () => {
    const fetchFn = stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);

    const res = await post(app, env, "/", {
      title: "Temple Bell",
      category: "temples",
      key_audio: "ringtones/temples/a.mp3",
      mime_audio: "audio/mpeg",
      key_cover: "ringtones/covers/temples/a.jpg",
      mime_cover: "image/jpeg",
      duration_ms: "32000",
      bytes_audio: "540000",
      is_published: "on",
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("ok=");
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("INSERT INTO ringtones");
    expect(text).toContain("content_version = content_version + 1");
    expect(fetchFn).toHaveBeenCalledTimes(1);
    const [input, init] = fetchFn.mock.calls[0]! as [string, RequestInit];
    expect(String(input)).toBe(
      "https://arul-api.twilight-smoke-d495.workers.dev/internal/build-catalog",
    );
    expect((init.headers as Record<string, string>)["Authorization"]).toBe(
      "Bearer test-arul-catalog-secret",
    );
  });

  it("a DB failure on create deletes BOTH orphaned objects (audio + cover)", async () => {
    stubFetch(200);
    const { makeMockSql } = await import("./_ctx.js");
    const arulSql = makeMockSql([], { failBegin: true });
    const { env, arulR2 } = makeEnv({ arulSql });
    const app = makeArulRingtonesApp(ARUL);

    const res = await post(app, env, "/", {
      title: "Temple Bell",
      category: "temples",
      key_audio: "ringtones/temples/a.mp3",
      mime_audio: "audio/mpeg",
      key_cover: "ringtones/covers/temples/a.jpg",
    });
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain(
      "Could not save ringtone",
    );
    expect(arulR2.calls.delete).toContain("ringtones/temples/a.mp3");
    expect(arulR2.calls.delete).toContain("ringtones/covers/temples/a.jpg");
  });
});

describe("batch create (items_json)", () => {
  const item = (over: Record<string, unknown> = {}) => ({
    id: ID_A,
    title: "Song One",
    audio_key: "ringtones/amman/u1.mp3",
    cover_key: "ringtones/covers/amman/u1.jpg",
    mime: "audio/mpeg",
    duration_ms: 30000,
    bytes: 500000,
    ...over,
  });

  it("inserts N rows in ONE txn with ONE rebuild", async () => {
    const fetchFn = stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/", {
      category: "amman",
      is_published: "on",
      items_json: JSON.stringify([
        item(),
        item({ id: ID_B, title: "Song Two", audio_key: "ringtones/amman/u2.m4a", cover_key: "ringtones/covers/amman/u2.jpg", mime: "audio/mp4" }),
      ]),
    });
    expect(res.status).toBe(302);
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("2 ringtones created");
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("INSERT INTO ringtones");
    expect(text).toContain("content_version = content_version + 1");
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("an item without a cover key is rejected with a specific message, pre-write", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/", {
      category: "amman",
      items_json: JSON.stringify([item({ cover_key: "" })]),
    });
    const loc = decodeURIComponent(res.headers.get("location") ?? "");
    expect(loc).toContain("has no cover image key");
    expect(loc).toContain("Song One");
    expect(arulSql.beginCalls).toBe(0);
  });

  it("a path-traversal key is rejected pre-write with a specific message", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/", {
      category: "amman",
      items_json: JSON.stringify([item({ audio_key: "../../etc" })]),
    });
    const loc = decodeURIComponent(res.headers.get("location") ?? "");
    expect(loc).toContain("illegal path segment");
    expect(arulSql.beginCalls).toBe(0);
  });

  it("a non-audio mime is rejected pre-write naming the mime", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/", {
      category: "amman",
      items_json: JSON.stringify([item({ mime: "application/pdf" })]),
    });
    const loc = decodeURIComponent(res.headers.get("location") ?? "");
    expect(loc).toContain("unsupported audio type");
    expect(loc).toContain("application/pdf");
    expect(arulSql.beginCalls).toBe(0);
  });

  it("a batch DB failure removes every uploaded audio AND cover object", async () => {
    stubFetch(200);
    const { makeMockSql } = await import("./_ctx.js");
    const arulSql = makeMockSql([], { failBegin: true });
    const { env, arulR2 } = makeEnv({ arulSql });
    const app = makeArulRingtonesApp(ARUL);
    await post(app, env, "/", {
      category: "amman",
      items_json: JSON.stringify([
        item(),
        item({ id: ID_B, audio_key: "ringtones/amman/u2.mp3", cover_key: "ringtones/covers/amman/u2.jpg" }),
      ]),
    });
    for (const k of [
      "ringtones/amman/u1.mp3",
      "ringtones/covers/amman/u1.jpg",
      "ringtones/amman/u2.mp3",
      "ringtones/covers/amman/u2.jpg",
    ]) {
      expect(arulR2.calls.delete).toContain(k);
    }
  });
});

describe("delete / replace — bytes only after a confirmed rebuild", () => {
  const row = { audio_key: "ringtones/amman/gone.mp3", cover_key: "ringtones/covers/amman/gone.jpg" };

  it("delete removes audio AND cover after a successful rebuild", async () => {
    stubFetch(200);
    const { env, arulR2 } = makeEnv({ arulRows: [row] });
    const app = makeArulRingtonesApp(ARUL);
    await post(app, env, `/${ID_A}/delete`, {});
    expect(arulR2.calls.delete).toContain(row.audio_key);
    expect(arulR2.calls.delete).toContain(row.cover_key);
  });

  it("delete keeps ALL bytes when the rebuild fails", async () => {
    stubFetch(500);
    const { env, arulR2 } = makeEnv({ arulRows: [row] });
    const app = makeArulRingtonesApp(ARUL);
    await post(app, env, `/${ID_A}/delete`, {});
    expect(arulR2.calls.delete).toHaveLength(0);
  });

  it("replacing only the cover deletes only the old cover, post-rebuild", async () => {
    stubFetch(200);
    const { env, arulR2 } = makeEnv({ arulRows: [row] });
    const app = makeArulRingtonesApp(ARUL);
    await post(app, env, `/${ID_A}`, {
      title: "Renamed",
      category: "amman",
      key_cover: "ringtones/covers/amman/new.jpg",
      mime_cover: "image/jpeg",
    });
    expect(arulR2.calls.delete).toContain(row.cover_key);
    expect(arulR2.calls.delete).not.toContain(row.audio_key);
  });
});

describe("bulk actions", () => {
  it("bulk category change updates rows + bumps version in ONE txn, ONE rebuild", async () => {
    const fetchFn = stubFetch(200);
    const { env, arulSql } = makeEnv({
      arulRows: [
        { id: ID_A, audio_key: "ringtones/amman/a.mp3", cover_key: null },
        { id: ID_B, audio_key: "ringtones/amman/b.mp3", cover_key: "ringtones/covers/amman/b.jpg" },
      ],
    });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/bulk", {
      bulk_action: "category",
      bulk_category: "sivan",
      ids: `${ID_A},${ID_B}`,
    });
    expect(res.status).toBe(302);
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain(
      "2 ringtones moved to sivan",
    );
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("UPDATE ringtones SET category =");
    expect(text).toContain("content_version = content_version + 1");
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("bulk category without a target is rejected pre-write", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);
    const res = await post(app, env, "/bulk", { bulk_action: "category", ids: ID_A });
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain(
      "Choose a target category",
    );
    expect(arulSql.beginCalls).toBe(0);
  });

  it("bulk delete removes each row's audio + cover after a confirmed rebuild", async () => {
    stubFetch(200);
    const { env, arulR2 } = makeEnv({
      arulRows: [
        { id: ID_A, audio_key: "ringtones/amman/a.mp3", cover_key: "ringtones/covers/amman/a.jpg" },
        { id: ID_B, audio_key: "ringtones/amman/b.mp3", cover_key: null },
      ],
    });
    const app = makeArulRingtonesApp(ARUL);
    await post(app, env, "/bulk", { bulk_action: "delete", ids: `${ID_A},${ID_B}` });
    expect(arulR2.calls.delete).toContain("ringtones/amman/a.mp3");
    expect(arulR2.calls.delete).toContain("ringtones/covers/amman/a.jpg");
    expect(arulR2.calls.delete).toContain("ringtones/amman/b.mp3");
  });

  it("unknown bulk action / malformed ids are rejected pre-write", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeArulRingtonesApp(ARUL);

    let res = await post(app, env, "/bulk", { bulk_action: "nuke", ids: ID_A });
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("Unknown bulk action");

    res = await post(app, env, "/bulk", { bulk_action: "publish", ids: "1; DROP TABLE ringtones" });
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain(
      "Select at least one ringtone",
    );
    expect(arulSql.beginCalls).toBe(0);
  });
});
