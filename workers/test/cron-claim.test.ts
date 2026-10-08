/**
 * The cron slot claim — Cloudflare delivered every tick twice (two colos, `scheduledTime` ~27 s apart) and re-delivers
 * a killed run, so each guarded trigger must run once per slot. The jobs themselves are mocked; only the claim is real
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { makeEnv } from "./_ctx.js";

vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return { ...actual, getDb: (env: { _testSql: unknown }) => env._testSql };
});
vi.mock("../src/cron/autopay-notify.js", () => ({ runAutopayNotify: vi.fn().mockResolvedValue(undefined) }));
vi.mock("../src/cron/build-catalog.js", () => ({
  buildCatalog: vi.fn().mockResolvedValue({}),
  refreshPopularityOrder: vi.fn().mockResolvedValue({}),
}));
vi.mock("../src/cron/sweep-canonical.js", () => ({ sweepCanonical: vi.fn().mockResolvedValue({}) }));
vi.mock("../src/cron/sweep-submissions.js", () => ({ sweepSubmissions: vi.fn().mockResolvedValue({}) }));
vi.mock("../src/cron/push-dispatch.js", () => ({
  runPushDispatch: vi.fn().mockResolvedValue({ started: 0, attempted: 0 }),
  sweepPush: vi.fn().mockResolvedValue({}),
}));

import { slotFor, claimCronSlot } from "../src/lib/cron-claim.js";
import { runAutopayNotify } from "../src/cron/autopay-notify.js";
import { buildCatalog } from "../src/cron/build-catalog.js";
import { runPushDispatch } from "../src/cron/push-dispatch.js";
import worker from "../src/index.js";

const at = (iso: string) => Date.parse(iso);

/** A cron_runs table in memory -> the INSERT … ON CONFLICT DO NOTHING RETURNING answers like Postgres would */
function claimSql(opts: { failTimes?: number } = {}) {
  const claimed = new Set<string>();
  let failsLeft = opts.failTimes ?? 0;
  const inserts: unknown[][] = [];
  const fn = vi.fn((strings: TemplateStringsArray, ...values: unknown[]) => {
    const text = strings.join("?");
    if (!text.includes("INSERT INTO cron_runs")) return Promise.resolve([]);
    inserts.push(values);
    if (failsLeft > 0) {
      failsLeft -= 1;
      return Promise.reject(new Error("Network connection lost."));
    }
    const key = `${values[0]}|${values[1]}`;
    if (claimed.has(key)) return Promise.resolve([]);
    claimed.add(key);
    return Promise.resolve([{ slot: values[1] }]);
  });
  const sql = Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
  return { sql, inserts };
}

function envWith(sql: unknown) {
  return { ...makeEnv(), _testSql: sql } as ReturnType<typeof makeEnv>;
}

const ctx = () => {
  const pending: Promise<unknown>[] = [];
  return {
    ctx: { waitUntil: (p: Promise<unknown>) => pending.push(p), passThroughOnException: () => {} },
    settle: () => Promise.all(pending),
  };
};

const tick = (cron: string, scheduledTime: number) => ({ cron, scheduledTime, noRetry: () => {} });

beforeEach(() => {
  vi.mocked(runAutopayNotify).mockClear();
  vi.mocked(buildCatalog).mockClear();
  vi.mocked(runPushDispatch).mockClear();
  vi.spyOn(console, "log").mockImplementation(() => {});
});

describe("slotFor — the scheduled time FLOORED to the trigger's period", () => {
  it.each([
    // The two colos' deliveries of one tick, seconds apart
    ["*/15 * * * *", "2026-10-07T21:30:08Z", "2026-10-07T21:30:00.000Z"],
    ["*/15 * * * *", "2026-10-07T21:30:35Z", "2026-10-07T21:30:00.000Z"],
    // A delivery that ran 23 min late still names its own tick
    ["*/15 * * * *", "2026-10-08T15:00:08Z", "2026-10-08T15:00:00.000Z"],
    // 58 s offset + 27 s spread -> a minute key would straddle, the period floor does not
    ["0 * * * *", "2026-10-08T14:00:58Z", "2026-10-08T14:00:00.000Z"],
    ["0 * * * *", "2026-10-08T14:01:25Z", "2026-10-08T14:00:00.000Z"],
    ["30 21 * * *", "2026-10-07T21:30:35Z", "2026-10-07T00:00:00.000Z"],
  ])("%s at %s -> %s", (cron, scheduled, slot) => {
    expect(slotFor(cron, at(scheduled))?.toISOString()).toBe(slot);
  });

  it("the push minute is not guarded -> no slot", () => {
    expect(slotFor("* * * * *", at("2026-10-07T21:30:35Z"))).toBeNull();
  });
});

describe("claimCronSlot", () => {
  it("the first delivery of a slot runs, the second skips", async () => {
    const { sql } = claimSql();
    const env = envWith(sql);
    expect(await claimCronSlot(env, "*/15 * * * *", at("2026-10-07T21:30:08Z"))).toBe(true);
    expect(await claimCronSlot(env, "*/15 * * * *", at("2026-10-07T21:30:35Z"))).toBe(false);
    expect(await claimCronSlot(env, "*/15 * * * *", at("2026-10-07T21:45:08Z"))).toBe(true);
    expect(sql.end).toHaveBeenCalledTimes(3);
  });

  it("retries the INSERT once on a cold connection", async () => {
    const { sql, inserts } = claimSql({ failTimes: 1 });
    vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(await claimCronSlot(envWith(sql), "0 * * * *", at("2026-10-08T14:00:08Z"))).toBe(true);
    expect(inserts).toHaveLength(2);
  });

  it("fails OPEN when the claim cannot be written -> the job runs, never stalls", async () => {
    const { sql } = claimSql({ failTimes: 2 });
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await claimCronSlot(envWith(sql), "*/15 * * * *", at("2026-10-07T21:30:08Z"))).toBe(true);
  });

  it("an unguarded trigger never touches the DB", async () => {
    const { sql } = claimSql();
    expect(await claimCronSlot(envWith(sql), "* * * * *", at("2026-10-07T21:30:08Z"))).toBe(true);
    expect(sql).not.toHaveBeenCalled();
  });
});

describe("scheduled() — a second delivery of the same slot does nothing", () => {
  it("autopay runs once for two deliveries of one tick", async () => {
    const { sql } = claimSql();
    const env = envWith(sql);
    for (const scheduled of ["2026-10-07T21:30:08Z", "2026-10-07T21:30:35Z"]) {
      const { ctx: c, settle } = ctx();
      await worker.scheduled(tick("*/15 * * * *", at(scheduled)) as ScheduledController, env, c as never);
      await settle();
    }
    expect(runAutopayNotify).toHaveBeenCalledTimes(1);
  });

  it("the catalog build runs once for two deliveries of one hour", async () => {
    const { sql } = claimSql();
    const env = envWith(sql);
    for (const scheduled of ["2026-10-08T14:00:08Z", "2026-10-08T14:00:35Z"]) {
      const { ctx: c, settle } = ctx();
      await worker.scheduled(tick("0 * * * *", at(scheduled)) as ScheduledController, env, c as never);
      await settle();
    }
    expect(buildCatalog).toHaveBeenCalledTimes(1);
  });

  it("push dispatch is not claimed -> both deliveries reach it (SKIP LOCKED is its guard)", async () => {
    const { sql } = claimSql();
    const env = envWith(sql);
    for (const scheduled of ["2026-10-07T21:30:08Z", "2026-10-07T21:30:35Z"]) {
      const { ctx: c, settle } = ctx();
      await worker.scheduled(tick("* * * * *", at(scheduled)) as ScheduledController, env, c as never);
      await settle();
    }
    expect(runPushDispatch).toHaveBeenCalledTimes(2);
    expect(sql).not.toHaveBeenCalled();
  });
});
