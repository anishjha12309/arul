/**
 * The win-back push (docs/push.md §Win-back): its rules as pure functions, and the minute resolver read as SQL text and
 * bound values. vitest has no Postgres; OPUS55-PHONEPE-HARNESS/suite-r-revoke proves the semantics on PGlite
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import { makeEnv } from "./_ctx.js";

vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return { ...actual, getDb: (env: { _testSql: unknown }) => env._testSql };
});

import { runWinbackPushes } from "../src/cron/winback-push.js";
import {
  autoKeyFor,
  type DueWinback,
  isQuietHourIST,
  istDayStart,
  monthKeyIST,
  SERIES_DAYS,
  seriesAutoKey,
  seriesDay,
  seriesDecision,
  seriesTexts,
  WINBACK_MIN_BUILD,
  winbackDecision,
  winbackGroup,
  winbackRecordFor,
  winbackTexts,
  withWinbackRecord,
} from "../src/lib/winback-push.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const OTHER_USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const TRIAL_ID = "11111111-1111-4111-8111-111111111111";
const PAID_ID = "22222222-2222-4222-8222-222222222222";
/** 12:00 IST — outside the quiet hours. */
const NOON_IST = new Date("2026-10-11T06:30:00Z");
const MIN = 60 * 1000;
const HOUR = 60 * MIN;

interface Stmt {
  text: string;
  values: unknown[];
}
type Answer = unknown[] | Error | undefined;

function routedSql(route: (text: string, values: unknown[]) => Answer = () => undefined) {
  const stmts: Stmt[] = [];
  const tag = (strings: TemplateStringsArray, ...vals: unknown[]) => {
    let text = strings[0];
    const values: unknown[] = [];
    vals.forEach((v, k) => {
      const frag = v as { sqlFragment?: boolean; text?: string; values?: unknown[] } | null;
      if (frag !== null && typeof frag === "object" && frag.sqlFragment === true) {
        text += `(${frag.text})`;
        values.push(...(frag.values ?? []));
      } else {
        text += "?";
        values.push(v);
      }
      text += strings[k + 1];
    });
    const stmt: Stmt = { text: text.replace(/\s+/g, " ").trim(), values };
    let run: Promise<unknown[]> | null = null;
    const exec = (): Promise<unknown[]> => {
      if (!run) {
        stmts.push(stmt);
        const answer = route(stmt.text, stmt.values);
        run = answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer ?? []);
      }
      return run;
    };
    return {
      sqlFragment: true,
      text: stmt.text,
      values: stmt.values,
      // biome-ignore lint/suspicious/noThenProperty: postgres.js queries are lazy thenables; the mock must be one too
      then: (ok?: (v: unknown[]) => unknown, bad?: (e: unknown) => unknown) => exec().then(ok, bad),
      catch: (bad: (e: unknown) => unknown) => exec().catch(bad),
    };
  };
  const sql = Object.assign(tag, {
    end: vi.fn(async () => undefined),
    begin: vi.fn(async (cb: (tx: unknown) => Promise<unknown>) => cb(tag)),
  });
  const ran = (needle: RegExp | string) =>
    stmts.filter((s) => (typeof needle === "string" ? s.text.includes(needle) : needle.test(s.text)));
  return { sql, stmts, ran };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("winbackRecordFor — only the payer's own revoke queues", () => {
  it.each([
    ["REVOKED", "webhook", { state: "queued", skipReason: null }],
    ["CANCELLED", "webhook", { state: "skipped", skipReason: "merchant_cancel" }],
    ["REVOKED", "status_route", { state: "queued", skipReason: null }],
    ["REVOKED", "offer_gate", { state: "skipped", skipReason: "in_app_cancel" }],
    ["CANCELLED", "offer_gate", { state: "skipped", skipReason: "in_app_cancel" }],
  ] as const)("%s seen by %s -> %j", (state, source, want) => {
    expect(winbackRecordFor(state, source)).toEqual({ ...want, phonepeState: state, detectedBy: source });
  });

  it.each([["EXPIRED"], ["FAILED"], ["ACTIVE"], [null], [undefined]])("%s -> no row at all", (state) => {
    expect(winbackRecordFor(state, "pass_a")).toBeNull();
  });
});

describe("withWinbackRecord — the row change and its win-back row in ONE statement", () => {
  it("no record -> the update runs exactly as before", () => {
    const db = routedSql();
    const update = db.sql`UPDATE subscriptions AS s SET status = ${"cancelled"}`;
    expect(withWinbackRecord(db.sql as never, update as never, null)).toBe(update);
  });

  it("wraps the update in a CTE that inserts only for a live plan, once per mandate", () => {
    const db = routedSql();
    const update = db.sql`UPDATE subscriptions AS s SET status = ${"cancelled"} RETURNING s.user_id`;
    const wrapped = withWinbackRecord(
      db.sql as never,
      update as never,
      winbackRecordFor("REVOKED", "webhook"),
    ) as unknown as Stmt;
    expect(wrapped.text).toMatch(
      /^WITH c AS \(\(UPDATE subscriptions AS s SET status = \? RETURNING s\.user_id\)\), w AS/,
    );
    expect(wrapped.text).toContain("WHERE c.prior_status IN ('trialing', 'active', 'paused')");
    expect(wrapped.text).toContain("AND c.merchant_subscription_id IS NOT NULL");
    expect(wrapped.text).toContain("ON CONFLICT (mandate_id) DO NOTHING ) SELECT * FROM c");
    expect(wrapped.text).toContain("(NULL::timestamptz)");
    expect(wrapped.values).toEqual(["cancelled", "REVOKED", "webhook", "queued", null]);
  });

  it("a skipped record is resolved at once", () => {
    const db = routedSql();
    const update = db.sql`UPDATE subscriptions AS s SET status = ${"cancelled"}`;
    const wrapped = withWinbackRecord(
      db.sql as never,
      update as never,
      winbackRecordFor("CANCELLED", "pass_d"),
    ) as unknown as Stmt;
    expect(wrapped.text).toContain("(now())");
    expect(wrapped.values).toEqual(["cancelled", "CANCELLED", "pass_d", "skipped", "merchant_cancel"]);
  });
});

describe("IST clock — quiet hours and the month a row counts under", () => {
  it.each([
    ["2026-10-11T16:29:00Z", "21:59 IST", false],
    ["2026-10-11T16:30:00Z", "22:00 IST", true],
    ["2026-10-11T20:00:00Z", "01:30 IST", true],
    ["2026-10-12T03:29:00Z", "08:59 IST", true],
    ["2026-10-12T03:30:00Z", "09:00 IST", false],
  ])("%s (%s) quiet = %s", (iso, _ist, quiet) => {
    expect(isQuietHourIST(new Date(iso))).toBe(quiet);
  });

  it("the month turns at midnight IST, not UTC", () => {
    expect(monthKeyIST(new Date("2026-10-31T18:29:59Z"))).toBe("2026-10");
    expect(monthKeyIST(new Date("2026-10-31T18:30:00Z"))).toBe("2026-11");
    expect(autoKeyFor("trial", new Date("2026-12-31T19:00:00Z"))).toBe("winback:trial:2027-01");
  });

  it("a day starts at midnight IST, not UTC", () => {
    expect(istDayStart(new Date("2026-10-11T18:29:59Z")).toISOString()).toBe("2026-10-10T18:30:00.000Z");
    expect(istDayStart(new Date("2026-10-11T18:30:00Z")).toISOString()).toBe("2026-10-11T18:30:00.000Z");
    expect(istDayStart(NOON_IST).toISOString()).toBe("2026-10-10T18:30:00.000Z");
  });

  it("a trialing revoker is the trial group; active and paused are paid", () => {
    expect(winbackGroup("trialing")).toBe("trial");
    expect(winbackGroup("active")).toBe("paid");
    expect(winbackGroup("paused")).toBe("paid");
  });
});

describe("winbackDecision — first match wins", () => {
  const due = (patch: Partial<DueWinback> = {}): DueWinback => ({
    group: "trial",
    mandateId: "DKS_HS_A",
    dueAt: new Date(NOON_IST.getTime() - MIN),
    liveMandateId: "DKS_HS_A",
    status: "cancelled",
    eligible: true,
    phones: 1,
    newPhones: 1,
    ...patch,
  });

  it.each([
    ["everything holds", {}, true, "send"],
    ["the switch is off", {}, false, "disabled"],
    ["due more than a day ago", { dueAt: new Date(NOON_IST.getTime() - 25 * HOUR) }, true, "stale"],
    ["a debit in flight settled after the revoke", { status: "active" }, true, "live_again"],
    ["…on a trial", { status: "trialing" }, true, "live_again"],
    ["a new mandate since", { liveMandateId: "DKS_HS_B", status: "active" }, true, "new_setup"],
    ["a setup in progress", { status: "pending" }, true, "new_setup"],
    ["not winback-eligible", { eligible: false }, true, "not_eligible"],
    ["no subscription row", { status: null, liveMandateId: null, eligible: false }, true, "not_eligible"],
    ["no reachable phone", { phones: 0, newPhones: 0 }, true, "no_phone"],
    ["no reachable phone, switch off", { phones: 0, newPhones: 0 }, false, "no_phone"],
    ["only old builds", { newPhones: 0 }, true, "old_build"],
    ["a paid revoker: the series asks once their days run out", { group: "paid" }, true, "series"],
    ["…even one that would be stale", { group: "paid", dueAt: new Date(0) }, true, "series"],
  ] as const)("%s -> %s", (_why, patch, live, want) => {
    expect(winbackDecision(due(patch), NOON_IST, live)).toBe(want);
  });
});

describe("the copy — six languages, the same promise in each", () => {
  it.each([["trial"], ["paid"]] as const)(
    "%s: every language has a title and a body naming both prices",
    (group) => {
      const texts = winbackTexts(group);
      expect(Object.keys(texts).sort()).toEqual(["en", "hi", "kn", "ml", "ta", "te"]);
      for (const { title, body } of Object.values(texts)) {
        expect(title.length).toBeGreaterThan(0);
        expect(body).toContain("₹99");
        expect(body).toContain("₹199");
      }
    },
  );

  it("the groups differ in the title only", () => {
    expect(winbackTexts("trial").en.title).not.toBe(winbackTexts("paid").en.title);
    expect(winbackTexts("trial").en.body).toBe(winbackTexts("paid").en.body);
  });

  it("the series: three messages, each in six languages, within the CMS's 50/150 limits, naming the price", () => {
    const messages = [0, 1, 2].map(seriesTexts);
    expect(new Set(messages.map((m) => m.en.title)).size).toBe(3);
    for (const texts of messages) {
      expect(Object.keys(texts).sort()).toEqual(["en", "hi", "kn", "ml", "ta", "te"]);
      for (const { title, body } of Object.values(texts)) {
        expect(title.length).toBeGreaterThan(0);
        expect(title.length).toBeLessThanOrEqual(50);
        expect(body.length).toBeLessThanOrEqual(150);
        expect(body).toContain("₹99");
      }
      // A lapse can be a failed debit, so nothing claims the person turned autopay off
      expect(texts.en.body.toLowerCase()).not.toContain("autopay");
      expect(texts.en.body).toContain("Cancel anytime in the app.");
    }
  });

  it("the series' messages take turns by day", () => {
    expect(seriesTexts(3)).toEqual(seriesTexts(0));
    expect(seriesTexts(13)).toEqual(seriesTexts(1));
  });
});

describe("the series clock — day 0 is the moment premium ran out", () => {
  const lapsed = new Date("2026-10-11T12:00:00Z");
  it.each([
    [-1, null],
    [0, 0],
    [24 * HOUR - 1, 0],
    [24 * HOUR, 1],
    [(SERIES_DAYS - 1) * 24 * HOUR, SERIES_DAYS - 1],
    [SERIES_DAYS * 24 * HOUR, null],
  ])("%d ms after the lapse -> day %s", (after, want) => {
    expect(seriesDay(lapsed, new Date(lapsed.getTime() + after))).toBe(want);
  });

  it("a day's row is keyed day 1..14 by IST month, as the CMS shows it", () => {
    expect(seriesAutoKey(0, NOON_IST)).toBe("winback:day01:2026-10");
    expect(seriesAutoKey(13, new Date("2026-10-31T18:30:00Z"))).toBe("winback:day14:2026-11");
  });

  it.each([
    [{ phones: 1, newPhones: 1 }, true, "send"],
    [{ phones: 1, newPhones: 1 }, false, "disabled"],
    [{ phones: 0, newPhones: 0 }, false, "no_phone"],
    [{ phones: 1, newPhones: 0 }, true, "old_build"],
  ] as const)("%o live=%s -> %s", (row, live, want) => {
    expect(seriesDecision(row, live)).toBe(want);
  });
});

describe("runWinbackPushes — the minute resolver", () => {
  const CLAIM = /FROM winback_pushes wp LEFT JOIN subscriptions s/;
  const SERIES = /^WITH l AS \(/;
  const ENSURE = /^INSERT INTO push_campaigns \(auto_key/;
  const DELIVER = /^INSERT INTO push_deliveries \(campaign_id, fid, lang\)/;
  const OPEN = /^UPDATE push_campaigns SET status = 'sending', total = total \+ \?/;
  const SENT = /^UPDATE winback_pushes SET state = 'sent'/;
  const SKIP = /^UPDATE winback_pushes SET state = 'skipped'/;
  const REOPEN =
    /^UPDATE push_campaigns c SET status = 'sending' WHERE c\.auto_key IS NOT NULL AND c\.status = 'sent'/;

  const dueRow = (patch: Record<string, unknown> = {}) => ({
    mandate_id: "DKS_HS_A",
    user_id: USER_ID,
    prior_status: "trialing",
    due_at: new Date(NOON_IST.getTime() - MIN).toISOString(),
    live_mandate_id: "DKS_HS_A",
    status: "cancelled",
    eligible: true,
    internal: false,
    phones: 1,
    new_phones: 1,
    pushed_today: false,
    ...patch,
  });

  const run = async (
    rows: unknown[],
    opts: {
      live?: boolean;
      push?: boolean;
      now?: Date;
      delivered?: (values: unknown[]) => unknown[];
      series?: unknown[];
    } = {},
  ) => {
    const db = routedSql((t, v) => {
      if (CLAIM.test(t)) return rows;
      if (SERIES.test(t)) return opts.series ?? [];
      if (/^INSERT INTO winback_series/.test(t)) return [{ user_id: v[0] }];
      if (ENSURE.test(t)) return [{ id: String(v[0]).startsWith("winback:trial") ? TRIAL_ID : PAID_ID }];
      if (DELIVER.test(t)) return opts.delivered ? opts.delivered(v) : [{ fid: "fid-1" }];
      return undefined;
    });
    const env = makeEnv({
      _testSql: db.sql,
      PUSH_ENABLED: opts.push === false ? "false" : "true",
      WINBACK_PUSH_ENABLED: opts.live === false ? undefined : "true",
    });
    const result = await runWinbackPushes(env, opts.now ?? NOON_IST);
    return { db, result };
  };

  it("PUSH_ENABLED off -> touches nothing", async () => {
    const { db, result } = await run([dueRow()], { push: false });
    expect(result.skipped).toBe("disabled");
    expect(db.stmts).toEqual([]);
  });

  it("inside 22:00–09:00 IST -> touches nothing, the rows wait for the morning", async () => {
    const { db, result } = await run([dueRow()], { now: new Date("2026-10-11T17:00:00Z") });
    expect(result.skipped).toBe("quiet_hours");
    expect(db.stmts).toEqual([]);
  });

  it("claims due queued rows under SKIP LOCKED, timed by the pinned clock", async () => {
    const { db } = await run([]);
    const claim = db.ran(CLAIM)[0];
    expect(claim.text).toContain("greatest(wp.created_at + ?::interval, s.current_period_end - ?::interval)");
    expect(claim.text).toContain("WHERE wp.state = 'queued'");
    expect(claim.text).toMatch(/ORDER BY wp\.created_at LIMIT \? FOR UPDATE OF wp SKIP LOCKED$/);
    expect(claim.values).toContain(NOON_IST.toISOString());
    expect(claim.values).toContain("1200 seconds");
    expect(claim.values).toContain("86400 seconds");
    expect(claim.values).toContain(WINBACK_MIN_BUILD);
    // An idle tick reads the series too, still revives a stranded delivery, and writes nothing else
    expect(db.stmts).toHaveLength(3);
    expect(db.ran(SERIES)).toHaveLength(1);
    expect(db.ran(REOPEN)).toHaveLength(1);
  });

  it("dark launch -> an eligible, reachable row resolves as `disabled`, and no campaign row is made", async () => {
    const { db, result } = await run([dueRow()], { live: false });
    expect(result).toMatchObject({ resolved: 1, sent: 0, reasons: { disabled: 1 } });
    expect(db.ran(SKIP)[0].values).toEqual(["disabled", NOON_IST.toISOString(), "DKS_HS_A"]);
    expect(db.ran(ENSURE)).toEqual([]);
  });

  it("live -> a trial revoke gets its month row, one delivery set and one counted open; a paid one waits for the series", async () => {
    const { db, result } = await run([
      dueRow({ mandate_id: "DKS_HS_P", live_mandate_id: "DKS_HS_P", prior_status: "active" }),
      dueRow({ mandate_id: "DKS_HS_T", live_mandate_id: "DKS_HS_T" }),
      dueRow({ mandate_id: "DKS_HS_N", live_mandate_id: "DKS_HS_N", phones: 0, new_phones: 0 }),
      dueRow({ mandate_id: "DKS_HS_B", live_mandate_id: "DKS_HS_NEW", status: "active" }),
    ]);
    expect(result).toMatchObject({ resolved: 4, sent: 1, reasons: { series: 1, no_phone: 1, new_setup: 1 } });

    const ensure = db.ran(ENSURE);
    expect(ensure.map((e) => e.values[0])).toEqual(["winback:trial:2026-10"]);
    expect(ensure[0].text).toContain(
      "ON CONFLICT (auto_key) DO UPDATE SET texts = EXCLUDED.texts RETURNING id",
    );
    expect(ensure[0].values.slice(1)).toEqual([
      JSON.stringify(winbackTexts("trial")),
      "premium",
      "winback_99",
      JSON.stringify({ kind: "winback", group: "trial" }),
      6,
      NOON_IST.toISOString(),
      NOON_IST.toISOString(),
      NOON_IST.toISOString(),
    ]);

    const deliver = db.ran(DELIVER);
    expect(deliver.map((d) => [d.values[0], d.values[1]])).toEqual([[TRIAL_ID, USER_ID]]);
    expect(deliver[0].text).toContain("ON CONFLICT DO NOTHING RETURNING fid");
    expect(deliver[0].text).toContain("d.token IS NOT NULL");
    expect(db.ran(OPEN).map((o) => o.values)).toEqual([[1, TRIAL_ID]]);
    expect(db.ran(SENT).map((s) => [s.values[0], s.values[2]])).toEqual([[TRIAL_ID, "DKS_HS_T"]]);
    expect(db.ran(SKIP).find((k) => k.values[2] === "DKS_HS_P")?.values[0]).toBe("series");
  });

  it("a paused revoker is paid -> no month row, the series takes over", async () => {
    const { db, result } = await run([dueRow({ prior_status: "paused" })]);
    expect(db.ran(ENSURE)).toEqual([]);
    expect(result.reasons).toEqual({ series: 1 });
  });

  it("already pushed today (series or revoke) -> `capped` before any delivery", async () => {
    const { db, result } = await run([dueRow({ pushed_today: true })]);
    expect(result.reasons).toEqual({ capped: 1 });
    expect(db.ran(DELIVER)).toEqual([]);
    const claim = db.ran(CLAIM)[0];
    expect(claim.text).toContain(
      "FROM winback_series ws WHERE ws.user_id = (wp.user_id) AND ws.state = 'sent'",
    );
    expect(claim.values).toContain("2026-10-10T18:30:00.000Z");
  });

  it("every phone already on this month's row -> `capped`, and the row is not reopened", async () => {
    const { db, result } = await run([dueRow()], { delivered: () => [] });
    expect(result.reasons).toEqual({ capped: 1 });
    expect(db.ran(OPEN)).toEqual([]);
    expect(db.ran(SENT)).toEqual([]);
  });

  it("a test account's phones get it, but stay out of `total`", async () => {
    const { db } = await run([dueRow({ internal: true, user_id: OTHER_USER })]);
    expect(db.ran(OPEN)[0].values).toEqual([0, TRIAL_ID]);
  });
});

describe("runWinbackPushes — the daily series", () => {
  const SERIES = /^WITH l AS \(/;
  const SERIES_CLAIM = /^INSERT INTO winback_series \(user_id, lapsed_at, day, state, campaign_id/;
  const SERIES_SKIP = /^INSERT INTO winback_series \(user_id, lapsed_at, day, state, skip_reason/;
  const SERIES_CAPPED = /^UPDATE winback_series SET state = 'skipped', skip_reason = 'capped'/;
  const ENSURE = /^INSERT INTO push_campaigns \(auto_key/;
  const DELIVER = /^INSERT INTO push_deliveries \(campaign_id, fid, lang\)/;
  const OPEN = /^UPDATE push_campaigns SET status = 'sending', total = total \+ \?/;
  const LAPSED = "2026-10-08 06:00:00.123456+00";

  const seriesRow = (patch: Record<string, unknown> = {}) => ({
    user_id: USER_ID,
    lapsed_at: LAPSED,
    day: 3,
    internal: false,
    phones: 1,
    new_phones: 1,
    pushed_today: false,
    ...patch,
  });

  const run = async (
    series: unknown[],
    opts: { live?: boolean; claimed?: boolean; delivered?: unknown[] } = {},
  ) => {
    const db = routedSql((t, v) => {
      if (SERIES.test(t)) return series;
      if (SERIES_CLAIM.test(t)) return opts.claimed === false ? [] : [{ user_id: v[0] }];
      if (SERIES_SKIP.test(t)) return [{ user_id: v[0] }];
      if (ENSURE.test(t)) return [{ id: `camp-${String(v[0])}` }];
      if (DELIVER.test(t)) return opts.delivered ?? [{ fid: "fid-1" }];
      return undefined;
    });
    const env = makeEnv({
      _testSql: db.sql,
      PUSH_ENABLED: "true",
      WINBACK_PUSH_ENABLED: opts.live === false ? undefined : "true",
    });
    return { db, result: await runWinbackPushes(env, NOON_IST) };
  };

  it("reads the app's ₹99 rule: premium run out, offered ₹99, not mid-checkout, inside the 14 days, day not yet decided", async () => {
    const { db } = await run([]);
    const read = db.ran(SERIES)[0];
    expect(read.text).toContain("s.status IN ('cancelled', 'expired', 'pending')");
    expect(read.text).toContain("AND s.status <> 'pending'");
    expect(read.text).toContain("AND NOT (");
    expect(read.text).toContain(
      "greatest(coalesce(s.current_period_end, s.trial_end), owner.reward_premium_until)",
    );
    expect(read.text).toContain("l.lapsed_at::text AS lapsed_at");
    expect(read.text).toContain("ws.user_id = l.user_id AND ws.lapsed_at = l.lapsed_at AND ws.day =");
    expect(read.values).toContain("14 days");
    expect(read.values).toContain(NOON_IST.toISOString());
    expect(read.values).toContain(WINBACK_MIN_BUILD);
  });

  it("dark launch -> the day is recorded `disabled`, the baseline, and nothing is sent", async () => {
    const { db, result } = await run([seriesRow()], { live: false });
    expect(result).toMatchObject({ sent: 0, reasons: { disabled: 1 } });
    expect(db.ran(SERIES_SKIP)[0].values).toEqual([USER_ID, LAPSED, 3, "disabled", NOON_IST.toISOString()]);
    expect(db.ran(ENSURE)).toEqual([]);
  });

  it.each([
    ["no reachable phone", { phones: 0, new_phones: 0 }, "no_phone"],
    ["only old builds", { new_phones: 0 }, "old_build"],
    ["already pushed today", { pushed_today: true }, "capped"],
  ])("%s -> recorded `%s`", async (_why, patch, reason) => {
    const { db, result } = await run([seriesRow(patch)]);
    expect(result.reasons).toEqual({ [reason]: 1 });
    expect(db.ran(DELIVER)).toEqual([]);
  });

  it("live -> day rows upserted in ascending order, each with its day's message, then claim, deliver and count", async () => {
    const { db, result } = await run([
      seriesRow({ day: 4, user_id: OTHER_USER }),
      seriesRow({ day: 0 }),
      seriesRow({ day: 4, internal: true, user_id: "9a3c1d2e-0000-4000-8000-000000000001" }),
    ]);
    expect(result).toMatchObject({ resolved: 3, sent: 3 });
    const ensure = db.ran(ENSURE);
    expect(ensure.map((e) => e.values[0])).toEqual(["winback:day01:2026-10", "winback:day05:2026-10"]);
    expect(ensure[1].values.slice(1, 5)).toEqual([
      JSON.stringify(seriesTexts(4)),
      "premium",
      "winback_99",
      JSON.stringify({ kind: "winback", group: "series", day: 5 }),
    ]);
    expect(db.ran(SERIES_CLAIM)[0].values).toEqual([
      OTHER_USER,
      LAPSED,
      4,
      "camp-winback:day05:2026-10",
      NOON_IST.toISOString(),
    ]);
    expect(db.ran(OPEN).map((o) => o.values[0])).toEqual([1, 1, 0]);
  });

  it("an overlapping tick already claimed the day -> nothing is delivered twice", async () => {
    const { db, result } = await run([seriesRow()], { claimed: false });
    expect(result.sent).toBe(0);
    expect(db.ran(DELIVER)).toEqual([]);
  });

  it("every phone already had this day key this month -> the claimed row turns `capped`", async () => {
    const { db, result } = await run([seriesRow()], { delivered: [] });
    expect(result.reasons).toEqual({ capped: 1 });
    expect(db.ran(SERIES_CAPPED)[0].values).toEqual([USER_ID, LAPSED, 3]);
    expect(db.ran(OPEN)).toEqual([]);
  });
});

describe("the message a month row turns into — what runPushDispatch hands FCM", () => {
  it("a new-build Tamil phone gets a data-only card that opens the ₹99 sheet and stays off the lock screen", async () => {
    const { sendPush } = await import("../src/lib/fcm.js");
    const posted: { message: Record<string, unknown> }[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, init: RequestInit) => {
        posted.push(JSON.parse(String(init.body)));
        return Response.json({ name: "projects/arul-test/messages/1" });
      }),
    );
    const res = await sendPush(
      makeEnv(),
      "token",
      { fid: "fid-1", token: "tok-1", lang: "ta", app_build: 2000 + WINBACK_MIN_BUILD },
      {
        id: TRIAL_ID,
        texts: winbackTexts("trial"),
        dest: "premium",
        dest_id: "winback_99",
        image_url: null,
        color: null,
        expires_hours: 6,
      },
    );
    vi.unstubAllGlobals();

    expect(res.ok).toBe(true);
    const message = posted[0].message as {
      notification?: unknown;
      data: Record<string, string>;
      android: Record<string, unknown>;
    };
    expect(message.notification).toBeUndefined();
    expect(message.data).toMatchObject({
      campaign_id: TRIAL_ID,
      dest: "premium",
      id: "winback_99",
      lang: "ta",
      title: winbackTexts("trial").ta.title,
      body: winbackTexts("trial").ta.body,
      channel_id: "arul_campaigns_v1",
      tag: TRIAL_ID,
    });
    expect(message.data).not.toHaveProperty("visibility");
    expect(message.android).toEqual({ priority: "HIGH", ttl: "21600s", collapse_key: TRIAL_ID });
  });
});
