/**
 * Campaign push — the audience SQL, the FCM send mapping, the claim loop's two exits, and the auth
 * gates on both new route families. No network, no live DB: every fetch and every query is mocked.
 *
 * The audience assertions render the COMPOSED fragment text rather than a single template, because
 * the whole point of audienceQuery is that it nests `premiumPredicate` instead of copying the rule —
 * a test that only saw the outer template could not tell the difference.
 */

import { describe, it, expect, vi, beforeAll, beforeEach, afterEach } from "vitest";
import type postgres from "postgres";

import { audienceLabel, audienceQuery, parseAudience, type PushAudience } from "../src/lib/push-audience.js";
import {
  COLOR_MIN_BUILD,
  HEADSUP_MIN_BUILD,
  isDeadRegistration,
  sendPush,
  textFor,
  type PushCampaign,
  type PushResult,
} from "../src/lib/fcm.js";
import { handleRegisterDevice, handleRegisterAnonDevice, handlePushOpened } from "../src/routes/me.js";
import { handlePushCount, handlePushDispatch, handlePushTest } from "../src/routes/internal.js";
import { signAccessToken } from "../src/lib/jwt.js";
import { makeEnv, makeCtx, makeMockKV } from "./_ctx.js";

const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";
const USER_ID = "11111111-1111-1111-1111-111111111111";
const CAMPAIGN_ID = "22222222-2222-2222-2222-222222222222";

// postgres.js inlines an interpolated query as a fragment; the shared makeMockSql resolves every tag
// to rows, which loses that nesting. This one keeps the tree so the composed text is assertable.

interface Frag {
  __frag: true;
  strings: readonly string[];
  values: unknown[];
}

function isFrag(v: unknown): v is Frag {
  return !!v && typeof v === "object" && (v as Frag).__frag === true;
}

/** Render a fragment tree to SQL text; every bound value becomes `?`. */
function render(node: unknown): string {
  if (!isFrag(node)) return "?";
  return node.strings.reduce(
    (acc, s, i) => acc + s + (i < node.values.length ? render(node.values[i]) : ""),
    "",
  );
}

/** Collapse whitespace so an assertion is about the SQL, not the indentation. */
function flat(node: unknown): string {
  return render(node).replace(/\s+/g, " ").trim();
}

function fragmentSql(): postgres.Sql {
  const fn = (strings: readonly string[], ...values: unknown[]): Frag => ({
    __frag: true,
    strings,
    values,
  });
  return fn as unknown as postgres.Sql;
}

describe("audienceQuery", () => {
  const sql = fragmentSql();

  it("test accounts get real campaigns — only Play's robots are left out of every kind", () => {
    const kinds: PushAudience[] = [
      { kind: "all" },
      { kind: "lang", lang: "ta" },
      { kind: "inactive", days: 7 },
      { kind: "premium", state: "free" },
      { kind: "premium", state: "trialing" },
      { kind: "premium", state: "paid" },
      { kind: "premium", state: "lapsed" },
      { kind: "filter", lang: "ta" },
      { kind: "filter", signed_in: false },
      { kind: "filter", plan: "paid", idle_days: 14, joined_hours: 168, signed_in: true },
    ];
    for (const kind of kinds) {
      const text = flat(audienceQuery(sql, kind));
      // Through coalesce: a phone that never signed in has no users row, and `NOT NULL` is NULL,
      // which would silently drop every anonymous phone from every audience.
      expect(text, JSON.stringify(kind)).toContain(
        "NOT coalesce(u.email ILIKE '%@cloudtestlabaccounts.com', false)",
      );
      // A team member who sends to Everyone must get it; the flag only moves the numbers now.
      expect(text, JSON.stringify(kind)).not.toContain("is_internal");
      // SEND_BY is the token: a row without one can only inflate total and Failed.
      expect(text, JSON.stringify(kind)).toContain("AND d.token IS NOT NULL");
    }
  });

  it("every kind leaves out Android 13+ phones that never signed in; includeWaiting drops only that", () => {
    const clause = "AND NOT (d.user_id IS NULL AND coalesce(d.android_sdk, 0) >= 33)";
    const kinds: PushAudience[] = [
      { kind: "all" },
      { kind: "internal" },
      { kind: "lang", lang: "ta" },
      { kind: "inactive", days: 7 },
      { kind: "premium", state: "paid" },
      { kind: "filter", signed_in: false },
      { kind: "filter", lang: "hi", joined_hours: 24 },
    ];
    for (const kind of kinds) {
      const sent = flat(audienceQuery(sql, kind));
      // Through coalesce: `NULL >= 33` is NULL, and NOT NULL would drop every phone whose SDK is unknown.
      expect(sent, JSON.stringify(kind)).toContain(clause);
      const counted = flat(audienceQuery(sql, kind, { includeWaiting: true }));
      expect(counted, JSON.stringify(kind)).not.toContain("android_sdk");
      expect(counted, JSON.stringify(kind)).toBe(sent.replace(` ${clause}`, ""));
    }
  });

  it("`internal` targets ONLY test accounts, and never the tokenless robots", () => {
    const text = flat(audienceQuery(sql, { kind: "internal" }));
    expect(text).toContain(
      "WHERE u.is_internal AND NOT coalesce(u.email ILIKE '%@cloudtestlabaccounts.com', false) AND d.token IS NOT NULL",
    );
    expect(text).not.toContain("NOT u.is_internal");
  });

  it("every kind selects fids off push_devices LEFT JOINed to users — anonymous phones included", () => {
    const kinds: PushAudience[] = [{ kind: "all" }, { kind: "internal" }, { kind: "filter", lang: "hi" }];
    for (const kind of kinds) {
      expect(flat(audienceQuery(sql, kind)), JSON.stringify(kind)).toContain(
        "SELECT d.fid FROM push_devices d LEFT JOIN users u ON u.id = d.user_id",
      );
    }
  });

  it("a plan is never satisfied by a phone with no account — `free` would otherwise match it", () => {
    for (const state of ["free", "trialing", "paid", "lapsed"] as const) {
      expect(flat(audienceQuery(sql, { kind: "premium", state })), state).toContain(
        "d.user_id IS NOT NULL AND",
      );
      expect(flat(audienceQuery(sql, { kind: "filter", plan: state })), state).toContain(
        "d.user_id IS NOT NULL AND",
      );
    }
  });

  it("trialing includes a cancelled mandate whose trial is still running, and only that cancelled row", () => {
    // A cancelled trial with trial_end ahead is entitled (premiumPredicate), so `lapsed` cannot take
    // it; without this arm it sat in no plan at all.
    const text = flat(audienceQuery(sql, { kind: "filter", plan: "trialing" }));
    expect(text).toContain("s.status = 'trialing'");
    expect(text).toContain("OR (s.status = 'cancelled' AND s.trial_end IS NOT NULL AND s.trial_end > now())");
    for (const state of ["free", "paid", "lapsed"] as const) {
      expect(flat(audienceQuery(sql, { kind: "filter", plan: state })), state).not.toContain("s.trial_end");
    }
  });

  it("filter ANDs every picked row and nothing else", () => {
    const text = flat(
      audienceQuery(sql, {
        kind: "filter",
        lang: "ta",
        plan: "free",
        idle_days: 7,
        joined_hours: 24,
        signed_in: true,
      }),
    );
    expect(text).toContain("AND d.lang = ?");
    expect(text).toContain("NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = d.user_id)");
    expect(text).toContain("AND d.last_seen_at < now() - (? || ' days')::interval");
    expect(text).toContain("AND d.created_at >= now() - (? || ' hours')::interval");
    expect(text).toContain("AND d.user_id IS NOT NULL");

    const langOnly = flat(audienceQuery(sql, { kind: "filter", lang: "ta" }));
    expect(langOnly).toBe(
      "SELECT d.fid FROM push_devices d LEFT JOIN users u ON u.id = d.user_id WHERE NOT coalesce(u.email ILIKE '%@cloudtestlabaccounts.com', false) AND d.token IS NOT NULL AND NOT (d.user_id IS NULL AND coalesce(d.android_sdk, 0) >= 33) AND d.lang = ?",
    );
  });

  it("signed_in maps to the device's user_id, both ways", () => {
    expect(flat(audienceQuery(sql, { kind: "filter", signed_in: true }))).toMatch(
      /AND d\.user_id IS NOT NULL$/,
    );
    const no = flat(audienceQuery(sql, { kind: "filter", signed_in: false }));
    expect(no).toMatch(/AND d\.user_id IS NULL$/);
    expect(no).not.toContain("d.user_id IS NOT NULL");
  });

  it("joined bounds on created_at with a bound interval, never interpolated text", () => {
    const text = flat(audienceQuery(sql, { kind: "filter", joined_hours: 168 }));
    expect(text).toContain("d.created_at >= now() - (? || ' hours')::interval");
    expect(text).not.toContain("168");
  });

  it("lang filters on the device's stored language", () => {
    expect(flat(audienceQuery(sql, { kind: "lang", lang: "ta" }))).toContain("d.lang = ?");
  });

  it("inactive bounds on last_seen_at with a bound interval, never interpolated text", () => {
    const text = flat(audienceQuery(sql, { kind: "inactive", days: 30 }));
    expect(text).toContain("d.last_seen_at < now() - (? || ' days')::interval");
    expect(text).not.toContain("30");
  });

  it("paid and lapsed both INLINE premiumPredicate rather than re-deriving the rule", () => {
    // reward_premium_until and the 6h debit grace live only inside premiumPredicate -> seeing them
    // here is the proof the fragment was nested, not copied.
    for (const state of ["paid", "lapsed"] as const) {
      const text = flat(audienceQuery(sql, { kind: "premium", state }));
      expect(text, state).toContain("u.reward_premium_until");
      expect(text, state).toContain("interval '6 hours'");
      // Correlated against the OUTER device row, not a bound user id.
      expect(text, state).toContain("u.id = d.user_id");
    }
  });

  it("lapsed is `subscribed once AND not entitled now` — a cancelled-but-still-paid user is excluded", () => {
    const text = flat(audienceQuery(sql, { kind: "premium", state: "lapsed" }));
    expect(text).toContain("AND EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = d.user_id)");
    expect(text).toContain("AND NOT EXISTS");
  });

  it("free means no subscription row AND no live reward credit", () => {
    const text = flat(audienceQuery(sql, { kind: "premium", state: "free" }));
    expect(text).toContain("NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = d.user_id)");
    expect(text).toContain("u.reward_premium_until IS NULL OR u.reward_premium_until <= now()");
  });
});

describe("parseAudience", () => {
  it("accepts every shape the CMS can compose", () => {
    expect(parseAudience({ kind: "all" })).toEqual({ kind: "all" });
    expect(parseAudience({ kind: "internal" })).toEqual({ kind: "internal" });
    expect(parseAudience({ kind: "lang", lang: "ml" })).toEqual({ kind: "lang", lang: "ml" });
    expect(parseAudience({ kind: "premium", state: "paid" })).toEqual({ kind: "premium", state: "paid" });
    expect(parseAudience({ kind: "inactive", days: 14 })).toEqual({ kind: "inactive", days: 14 });
  });

  it("returns null rather than defaulting — a mistyped audience must never become `everyone`", () => {
    expect(parseAudience(null)).toBeNull();
    expect(parseAudience({})).toBeNull();
    expect(parseAudience({ kind: "everyone" })).toBeNull();
    expect(parseAudience({ kind: "lang", lang: "fr" })).toBeNull();
    expect(parseAudience({ kind: "premium", state: "vip" })).toBeNull();
    expect(parseAudience({ kind: "inactive", days: 3 })).toBeNull();
  });

  it("accepts every filter shape, keeping only the keys that were picked", () => {
    expect(parseAudience({ kind: "filter", lang: "ta" })).toEqual({ kind: "filter", lang: "ta" });
    expect(parseAudience({ kind: "filter", plan: "trialing" })).toEqual({ kind: "filter", plan: "trialing" });
    expect(parseAudience({ kind: "filter", idle_days: 30 })).toEqual({ kind: "filter", idle_days: 30 });
    for (const h of [1, 24, 168]) {
      expect(parseAudience({ kind: "filter", joined_hours: h })).toEqual({ kind: "filter", joined_hours: h });
    }
    expect(parseAudience({ kind: "filter", signed_in: false })).toEqual({ kind: "filter", signed_in: false });
    expect(
      parseAudience({
        kind: "filter",
        lang: "hi",
        plan: "paid",
        idle_days: 7,
        joined_hours: 24,
        signed_in: true,
      }),
    ).toEqual({ kind: "filter", lang: "hi", plan: "paid", idle_days: 7, joined_hours: 24, signed_in: true });
    // Unknown keys are dropped, not carried into the row the dispatcher reads.
    expect(parseAudience({ kind: "filter", lang: "ta", extra: 1 })).toEqual({ kind: "filter", lang: "ta" });
  });

  it("a filter with nothing picked is null — it would silently mean everyone", () => {
    expect(parseAudience({ kind: "filter" })).toBeNull();
    expect(parseAudience({ kind: "filter", nonsense: "x" })).toBeNull();
  });

  it("a filter carrying a value the CMS never offers is null", () => {
    expect(parseAudience({ kind: "filter", lang: "fr" })).toBeNull();
    expect(parseAudience({ kind: "filter", plan: "vip" })).toBeNull();
    expect(parseAudience({ kind: "filter", idle_days: 3 })).toBeNull();
    expect(parseAudience({ kind: "filter", idle_days: "7" })).toBeNull();
    expect(parseAudience({ kind: "filter", joined_hours: 2 })).toBeNull();
    expect(parseAudience({ kind: "filter", signed_in: "no" })).toBeNull();
    // One bad key sinks the whole audience; it is never quietly narrowed to the good ones.
    expect(parseAudience({ kind: "filter", lang: "ta", joined_hours: 48 })).toBeNull();
  });

  it("a plan asked of phones that never signed in is a contradiction and parses to null", () => {
    expect(parseAudience({ kind: "filter", plan: "free", signed_in: false })).toBeNull();
    expect(parseAudience({ kind: "filter", plan: "free", signed_in: true })).toEqual({
      kind: "filter",
      plan: "free",
      signed_in: true,
    });
  });
});

describe("audienceLabel", () => {
  it("joins a filter's parts in the CMS's words", () => {
    expect(
      audienceLabel({ kind: "filter", lang: "ta", plan: "free", joined_hours: 24, signed_in: false }),
    ).toBe("Tamil · Free · Joined last 24 hours · Not signed in");
    expect(audienceLabel({ kind: "filter", idle_days: 14, joined_hours: 1, signed_in: true })).toBe(
      "Last opened 14+ days ago · Joined last hour · Signed in",
    );
    expect(audienceLabel({ kind: "filter", joined_hours: 168 })).toBe("Joined last 7 days");
    expect(audienceLabel({ kind: "filter", plan: "paid" })).toBe("Paying");
  });

  it("labels the old kinds in the same words for historical rows", () => {
    expect(audienceLabel({ kind: "all" })).toBe("Everyone");
    expect(audienceLabel({ kind: "internal" })).toBe("Test accounts");
    expect(audienceLabel({ kind: "premium", state: "lapsed" })).toBe("Stopped paying");
    expect(audienceLabel({ kind: "premium", state: "free" })).toBe("Free");
    expect(audienceLabel({ kind: "inactive", days: 30 })).toBe("Last opened 30+ days ago");
  });
});

const CAMPAIGN: PushCampaign = {
  id: CAMPAIGN_ID,
  texts: { en: { title: "Hello", body: "World" }, ta: { title: "வணக்கம்", body: "உலகம்" } },
  dest: "category",
  dest_id: "ganapathi",
  image_url: "https://arul-cdn.hsrutility.com/thumbs/ganapathi/a.jpg",
};

const DEVICE = { fid: "fid-1", token: "tok-1", lang: "en" };

function fcmOk() {
  return new Response(JSON.stringify({ name: "projects/arul-test/messages/1" }), { status: 200 });
}

function fcmErr(status: number, errorCode: string) {
  return new Response(
    JSON.stringify({ error: { message: "nope", status: "INVALID", details: [{ errorCode }] } }),
    { status },
  );
}

describe("sendPush", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("200 -> ok, and the message carries the campaign's channel, tag and analytics label", async () => {
    const fetchMock = vi.fn(async (_url: unknown, _init: RequestInit) => fcmOk());
    vi.stubGlobal("fetch", fetchMock);
    const res = await sendPush(makeEnv(), "tok", DEVICE, CAMPAIGN);
    expect(res.ok).toBe(true);

    const body = JSON.parse(String(fetchMock.mock.calls[0]![1].body)) as {
      message: Record<string, unknown>;
    };
    const m = body.message;
    expect(m["token"]).toBe("tok-1");
    expect(m["fid"]).toBeUndefined();
    const android = m["android"] as Record<string, unknown>;
    const notif = android["notification"] as Record<string, string>;
    expect(notif["channel_id"]).toBe("arul_updates_v1");
    expect(notif["tag"]).toBe(CAMPAIGN_ID);
    // Applies on Android 7.1 and lower; the channel decides from 8.0.
    expect(notif["notification_priority"]).toBe("PRIORITY_DEFAULT");
    expect(android["priority"]).toBe("HIGH");
    expect((m["fcm_options"] as Record<string, string>)["analytics_label"]).toBe(CAMPAIGN_ID);
    // FCM requires string data values.
    for (const v of Object.values(m["data"] as Record<string, unknown>)) {
      expect(typeof v).toBe("string");
    }
    expect((m["data"] as Record<string, string>)["id"]).toBe("ganapathi");
  });

  describe("plain vs coloured", () => {
    async function sent(device: typeof DEVICE & { app_build?: number | null }, campaign: PushCampaign) {
      const fetchMock = vi.fn(async (_url: unknown, _init: RequestInit) => fcmOk());
      vi.stubGlobal("fetch", fetchMock);
      await sendPush(makeEnv(), "tok", device, campaign);
      return (JSON.parse(String(fetchMock.mock.calls[0]![1].body)) as { message: Record<string, unknown> })
        .message;
    }

    it("a campaign with no colour is today's notification message; only ttl follows the expiry", async () => {
      const m = await sent(
        { ...DEVICE, app_build: HEADSUP_MIN_BUILD - 1 },
        { ...CAMPAIGN, color: null, expires_hours: 6 },
      );
      expect(Object.keys(m)).toEqual(["token", "notification", "data", "fcm_options", "android"]);
      expect(m["notification"]).toEqual({ title: "Hello", body: "World", image: CAMPAIGN.image_url });
      expect(m["data"]).toEqual({ campaign_id: CAMPAIGN_ID, dest: "category", lang: "en", id: "ganapathi" });
      expect(m["android"]).toEqual({
        priority: "HIGH",
        ttl: "21600s",
        notification: {
          channel_id: "arul_updates_v1",
          icon: "ic_notification",
          color: "#D4A017",
          tag: CAMPAIGN_ID,
          notification_priority: "PRIORITY_DEFAULT",
          visibility: "PUBLIC",
        },
      });
    });

    it("a row read before the expiry column existed keeps the old 24 h ttl", async () => {
      const m = await sent(DEVICE, CAMPAIGN);
      expect((m["android"] as Record<string, unknown>)["ttl"]).toBe("86400s");
    });

    it("a coloured campaign to a build with the renderer goes data-only", async () => {
      const m = await sent(
        { ...DEVICE, app_build: COLOR_MIN_BUILD },
        { ...CAMPAIGN, color: "#2b3a8a", expires_hours: 1 },
      );
      expect(m["notification"]).toBeUndefined();
      expect(m["data"]).toEqual({
        campaign_id: CAMPAIGN_ID,
        dest: "category",
        lang: "en",
        id: "ganapathi",
        title: "Hello",
        body: "World",
        image: CAMPAIGN.image_url,
        color: "#2b3a8a",
        channel_id: "arul_updates_v1",
        tag: CAMPAIGN_ID,
        visibility: "public",
      });
      expect(m["android"]).toEqual({ priority: "HIGH", ttl: "3600s", collapse_key: CAMPAIGN_ID });
      expect((m["fcm_options"] as Record<string, string>)["analytics_label"]).toBe(CAMPAIGN_ID);
      for (const v of Object.values(m["data"] as Record<string, unknown>)) expect(typeof v).toBe("string");
    });

    it("a coloured campaign to an older or unknown build falls back to the plain message", async () => {
      const devices = [{ ...DEVICE, app_build: COLOR_MIN_BUILD - 1 }, { ...DEVICE, app_build: null }, DEVICE];
      for (const device of devices) {
        const app_build = "app_build" in device ? device.app_build : undefined;
        const m = await sent(device, { ...CAMPAIGN, color: "#2b3a8a", expires_hours: 24 });
        expect(m["notification"], String(app_build)).toBeDefined();
        expect((m["data"] as Record<string, string>)["color"], String(app_build)).toBeUndefined();
        expect((m["android"] as Record<string, unknown>)["ttl"]).toBe("86400s");
      }
    });

    it("reads the build number out of a per-ABI versionCode — 2075 is build 75, not newer than 76", async () => {
      const coloured = { ...CAMPAIGN, color: "#2b3a8a" };
      const old = await sent({ ...DEVICE, app_build: 2075 }, coloured);
      expect(old["notification"], "2075 is build 75: no renderer").toBeDefined();
      for (const app_build of [2076, 1076, 4077]) {
        const m = await sent({ ...DEVICE, app_build }, coloured);
        expect(m["notification"], String(app_build)).toBeUndefined();
      }
    });

    it("a coloured campaign with no picture sends no image key", async () => {
      const m = await sent(
        { ...DEVICE, app_build: COLOR_MIN_BUILD },
        { ...CAMPAIGN, image_url: null, color: "#1b1b2f" },
      );
      expect(m["data"]).not.toHaveProperty("image");
    });
  });

  describe("heads-up builds", () => {
    async function sent(device: typeof DEVICE & { app_build?: number | null }, campaign: PushCampaign) {
      const fetchMock = vi.fn(async (_url: unknown, _init: RequestInit) => fcmOk());
      vi.stubGlobal("fetch", fetchMock);
      await sendPush(makeEnv(), "tok", device, campaign);
      return (JSON.parse(String(fetchMock.mock.calls[0]![1].body)) as { message: Record<string, unknown> })
        .message;
    }

    it("a plain campaign to a heads-up build is data-only on the campaign channel", async () => {
      const m = await sent(
        { ...DEVICE, app_build: HEADSUP_MIN_BUILD },
        { ...CAMPAIGN, color: null, expires_hours: 6 },
      );
      expect(m["notification"]).toBeUndefined();
      expect(m["data"]).toEqual({
        campaign_id: CAMPAIGN_ID,
        dest: "category",
        lang: "en",
        id: "ganapathi",
        title: "Hello",
        body: "World",
        image: CAMPAIGN.image_url,
        channel_id: "arul_campaigns_v1",
        tag: CAMPAIGN_ID,
        visibility: "public",
      });
      expect(m["android"]).toEqual({ priority: "HIGH", ttl: "21600s", collapse_key: CAMPAIGN_ID });
      for (const v of Object.values(m["data"] as Record<string, unknown>)) expect(typeof v).toBe("string");
    });

    it("a coloured campaign to a heads-up build keeps its colour on the campaign channel", async () => {
      const m = await sent(
        { ...DEVICE, app_build: 2000 + HEADSUP_MIN_BUILD },
        { ...CAMPAIGN, color: "#7a1f2b" },
      );
      expect(m["notification"]).toBeUndefined();
      const data = m["data"] as Record<string, string>;
      expect(data["color"]).toBe("#7a1f2b");
      expect(data["channel_id"]).toBe("arul_campaigns_v1");
    });

    it("older builds are unchanged: plain stays a notification, coloured stays on the old channel", async () => {
      const plain = await sent({ ...DEVICE, app_build: 2000 + HEADSUP_MIN_BUILD - 1 }, CAMPAIGN);
      const android = plain["android"] as Record<string, Record<string, string>>;
      expect(plain["notification"]).toBeDefined();
      expect(android["notification"]!["channel_id"]).toBe("arul_updates_v1");
      const coloured = await sent(
        { ...DEVICE, app_build: HEADSUP_MIN_BUILD - 1 },
        { ...CAMPAIGN, color: "#7a1f2b" },
      );
      expect((coloured["data"] as Record<string, string>)["channel_id"]).toBe("arul_updates_v1");
      for (const device of [{ ...DEVICE, app_build: null }, DEVICE]) {
        const m = await sent(device, CAMPAIGN);
        expect(m["notification"], JSON.stringify(device)).toBeDefined();
      }
    });

    it("a premium-screen campaign keeps Android's private lock-screen default on both paths", async () => {
      const premium = { ...CAMPAIGN, dest: "premium", dest_id: null };
      const plain = await sent({ ...DEVICE, app_build: HEADSUP_MIN_BUILD - 1 }, premium);
      expect((plain["android"] as Record<string, unknown>)["notification"]).not.toHaveProperty("visibility");
      const drawn = await sent({ ...DEVICE, app_build: HEADSUP_MIN_BUILD }, premium);
      expect(drawn["data"]).not.toHaveProperty("visibility");
      for (const dest of ["home", "wallpaper", "ringtone", "category"]) {
        const m = await sent({ ...DEVICE, app_build: HEADSUP_MIN_BUILD }, { ...CAMPAIGN, dest });
        expect((m["data"] as Record<string, string>)["visibility"], dest).toBe("public");
      }
    });
  });

  it("a device row with no token fails the delivery WITHOUT deleting the row", async () => {
    const fetchMock = vi.fn(async () => fcmOk());
    vi.stubGlobal("fetch", fetchMock);
    const res = await sendPush(makeEnv(), "tok", { ...DEVICE, token: null }, CAMPAIGN);
    expect(res.ok).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
    // Sending the fid in the token field would come back UNREGISTERED, and the caller would delete a
    // row that was only ever missing one column.
    expect(isDeadRegistration(res)).toBe(false);
  });

  it("404 UNREGISTERED is a dead registration; a 500 is not", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcmErr(404, "UNREGISTERED")),
    );
    const dead = await sendPush(makeEnv(), "tok", DEVICE, CAMPAIGN);
    expect(dead.ok).toBe(false);
    expect(isDeadRegistration(dead)).toBe(true);

    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcmErr(503, "UNAVAILABLE")),
    );
    vi.useFakeTimers();
    const pending = sendPush(makeEnv(), "tok", DEVICE, CAMPAIGN);
    await vi.advanceTimersByTimeAsync(1100);
    expect(isDeadRegistration(await pending)).toBe(false);
  });

  it("429 is retried exactly once, after a second", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(fcmErr(429, "QUOTA_EXCEEDED"))
      .mockResolvedValueOnce(fcmOk());
    vi.stubGlobal("fetch", fetchMock);
    vi.useFakeTimers();
    const pending = sendPush(makeEnv(), "tok", DEVICE, CAMPAIGN);
    await vi.advanceTimersByTimeAsync(1100);
    expect((await pending).ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("a 4xx that is not retryable is never retried — a second identical request cannot help", async () => {
    const fetchMock = vi.fn(async () => fcmErr(400, "INVALID_ARGUMENT"));
    vi.stubGlobal("fetch", fetchMock);
    const res = await sendPush(makeEnv(), "tok", DEVICE, CAMPAIGN);
    expect(res.ok).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(isDeadRegistration(res)).toBe(true);
  });
});

describe("textFor", () => {
  it("uses the phone's own language when the editor wrote it", () => {
    expect(textFor(CAMPAIGN, "ta").title).toBe("வணக்கம்");
  });

  it("falls back to English for a language left empty, and for an unknown one", () => {
    expect(textFor(CAMPAIGN, "te")).toEqual({ title: "Hello", body: "World" });
    expect(textFor(CAMPAIGN, "fr")).toEqual({ title: "Hello", body: "World" });
    expect(textFor({ ...CAMPAIGN, texts: { en: { title: "T", body: "B" }, ta: {} } }, "ta").title).toBe("T");
  });
});

// runPushDispatch reaches the DB through getDb -> route the mock per statement so the loop's two
// exits (nothing pending, wall clock spent) can be told apart.

interface RoutedSql {
  sql: postgres.Sql;
  statements: string[];
  /** Every BOUND value, unstringified. `String(["a","b"])` is `"a,b"` — the exact shape the
   *  array bug produced — so a test that only sees the rendered text cannot tell them apart. */
  bound: unknown[];
  /** Per statement: its text, its bound values, and which `sql.begin` it ran on (null = outside one). */
  calls: { text: string; values: unknown[]; tx: number | null }[];
  text: () => string;
}

function routedSql(
  routes: { match: RegExp; rows?: unknown[]; throws?: string; once?: boolean }[],
): RoutedSql {
  const fired = new Set<unknown>();
  const statements: string[] = [];
  const bound: unknown[] = [];
  const calls: RoutedSql["calls"] = [];
  let transactions = 0;
  const tagged =
    (tx: number | null) =>
    (strings: readonly string[], ...values: unknown[]) => {
      const text = strings.join("?");
      statements.push(text + " :: " + values.map((v) => String(v)).join(","));
      bound.push(...values);
      calls.push({ text, values, tx });
      const hit = routes.find((r) => r.match.test(text));
      // A route may fail instead of answering — the only way to exercise what happens when a query
      // blows up mid-drain, which is exactly how the malformed-array bug reached production unseen.
      if (hit?.throws && !(hit.once && fired.has(hit))) {
        fired.add(hit);
        return Promise.reject(new Error(hit.throws));
      }
      return Promise.resolve(hit?.rows ?? []);
    };
  const sql = Object.assign(tagged(null), {
    end: vi.fn().mockResolvedValue(undefined),
    begin: vi.fn(async (cb: (tx: unknown) => unknown) => cb(tagged(++transactions))),
  });
  return {
    sql: sql as unknown as postgres.Sql,
    statements,
    bound,
    calls,
    text: () => statements.join("\n"),
  };
}

// Spread the REAL module and swap only getDb. `toPgTextArray` is the thing the array-literal guard
// below is testing, and a mock that dropped it would assert against a stub instead of shipped code.
vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return { ...actual, getDb: (env: { _testSql: unknown }) => env._testSql };
});

describe("runPushDispatch", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('claims nothing at all while PUSH_ENABLED is not exactly "true"', async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const routed = routedSql([]);
    for (const value of ["false", "TRUE", "1", undefined]) {
      const env = makeEnv({ PUSH_ENABLED: value, _testSql: routed.sql });
      const result = await runPushDispatch(env);
      expect(result.skipped, String(value)).toBe("disabled");
    }
    expect(routed.statements).toHaveLength(0);
  });

  it("marks a campaign sent once nothing is pending, and never re-sends it", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [{ ...CAMPAIGN, last_error: null }],
      },
      // Nothing left to claim.
      { match: /FROM push_deliveries\s+WHERE campaign_id = \?\s+AND status = 'pending'/, rows: [] },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    const fetchMock = vi.fn(async () => fcmOk());
    vi.stubGlobal("fetch", fetchMock);

    const result = await runPushDispatch(env);
    expect(result.completed).toBe(1);
    expect(routed.text()).toContain("SET status = 'sent', sent_at = now()");
    // The guard on that UPDATE is what stops a second tick re-finishing it.
    expect(routed.text()).toContain("AND status = 'sending'");
    // Nothing was pending -> not one message left the Worker.
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("stops at the wall-clock budget and leaves the next campaign for the next tick", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const OTHER = "33333333-3333-3333-3333-333333333333";
    const claim = { match: /AND status = 'pending'\s+LIMIT/, rows: [{ fid: "fid-1" }] };
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [
          { ...CAMPAIGN, last_error: null },
          { ...CAMPAIGN, id: OTHER, last_error: null },
        ],
      },
      claim,
      { match: /SELECT d\.fid, d\.token, d\.lang, d\.app_build/, rows: [DEVICE] },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });

    // Spending the whole budget inside the first send is the only way a tick ever runs out.
    vi.useFakeTimers();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        vi.setSystemTime(Date.now() + 11 * 60 * 1000);
        return fcmOk();
      }),
    );
    const result = await runPushDispatch(env);
    vi.useRealTimers();

    expect(result.sent).toBe(1);
    // The second campaign was never touched — it is simply still 'sending' for the next minute.
    expect(routed.text()).not.toContain(OTHER);
  });
});

function recordingSql(rows: unknown[] = []) {
  const captured: unknown[][] = [];
  const fn = vi.fn((...args: unknown[]) => {
    captured.push(args);
    return Promise.resolve(rows);
  });
  return {
    sql: Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) }),
    captured,
    text: () => captured.map((a) => (a[0] as string[]).join("?")).join("\n"),
    values: () => captured.flatMap((a) => a.slice(1)),
  };
}

describe("a drain that blows up", () => {
  // THE defect that let the malformed-array bug hide. A throw inside drainCampaign propagated out
  // of runPushDispatch, which the dispatch route runs inside waitUntil — so it wrote NOTHING to the
  // row, the campaign sat 'sending' for ever, and the CMS showed "Sending…" with no reason. The
  // only trace was in `wrangler tail`. These two were missing when I claimed this path was covered.
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  const running = (extra: Record<string, unknown> = {}) => ({
    match: /FROM push_campaigns\s+WHERE status = 'sending'/,
    rows: [{ ...CAMPAIGN, last_error: null, ...extra }],
  });

  it("records the reason on the campaign instead of swallowing it", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      running(),
      { match: /AND status = 'pending'\s+LIMIT/, throws: 'malformed array literal: "fid-1"' },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 1 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcmOk()),
    );

    // The pass itself must not reject — one broken campaign is not a broken tick.
    const result = await runPushDispatch(env);
    expect(result.sent).toBe(0);

    expect(routed.text()).toContain("SET last_error");
    const written = routed.bound.find((v) => typeof v === "string" && v.startsWith("Sending failed:")) as
      | string
      | undefined;
    expect(written, "the failure must reach the row, not just the log").toBeTruthy();
    expect(written).toContain("malformed array literal");
    // And it must NOT be marked sent: nothing was delivered.
    expect(routed.text()).not.toContain("SET status = 'sent'");
  });

  it("one broken campaign does not stop the next one", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const OTHER = "44444444-4444-4444-4444-444444444444";
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [
          { ...CAMPAIGN, last_error: null },
          { ...CAMPAIGN, id: OTHER, last_error: null },
        ],
      },
      // Fails for the first campaign only; the second gets a clean, empty claim.
      { match: /AND status = 'pending'\s+LIMIT/, throws: "connection lost", once: true },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcmOk()),
    );

    const result = await runPushDispatch(env);
    // The second campaign still finished, which is the whole point of catching per campaign.
    expect(result.completed).toBe(1);
    expect(routed.bound.some((v) => typeof v === "string" && v.includes("connection lost"))).toBe(true);
  });
});

describe("array parameters", () => {
  it("toPgTextArray renders a literal, not a JS array", async () => {
    const { toPgTextArray } = await import("../src/lib/db.js");
    expect(toPgTextArray(["a", "b"])).toBe('{"a","b"}');
    // One element is the case that actually bit — `String(["a"])` is just `a`, so it looks fine.
    expect(toPgTextArray(["a"])).toBe('{"a"}');
    // Empty must match nothing rather than throw: deadFids is empty on almost every batch.
    expect(toPgTextArray([])).toBe("{}");
    expect(toPgTextArray(['he said "hi"'])).toBe('{"he said \\"hi\\""}');
  });

  it("a full drain binds array literals and never a JS array", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    // The claim yields one phone, then nothing — otherwise the drain loop never exits.
    let claims = 0;
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [{ ...CAMPAIGN, last_error: null }],
      },
      {
        match: /AND status = 'pending'\s+LIMIT/,
        get rows() {
          return claims++ === 0 ? [{ fid: "fid-1" }] : [];
        },
      },
      { match: /SELECT d\.fid, d\.token, d\.lang, d\.app_build/, rows: [DEVICE] },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcmOk()),
    );

    const result = await runPushDispatch(env);
    expect(result.sent).toBe(1);

    // The whole defect in one assert: a JS array must never reach the driver.
    const arrays = routed.bound.filter((v) => Array.isArray(v));
    expect(arrays, `these were bound as JS arrays: ${JSON.stringify(arrays)}`).toEqual([]);
    // And the value that replaced it is a real literal, cast at the call site.
    expect(routed.bound).toContain('{"fid-1"}');
    expect(routed.text()).toContain("::text[]");
  });
});

describe("test accounts in a campaign's numbers", () => {
  // Test accounts now receive every real campaign, but a team opening each send on reinstalled
  // phones must not move Sent/Failed — except on a campaign aimed at them, where "Sent 0" would hide
  // whether the test went out at all.
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  async function drainTwoPhones(audience: unknown) {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    let claims = 0;
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [{ ...CAMPAIGN, last_error: null, audience }],
      },
      {
        match: /AND status = 'pending'\s+LIMIT/,
        get rows() {
          return claims++ === 0 ? [{ fid: "fid-real" }, { fid: "fid-test" }] : [];
        },
      },
      {
        match: /SELECT d\.fid, d\.token, d\.lang, d\.app_build/,
        rows: [
          { ...DEVICE, fid: "fid-real", internal: false },
          { ...DEVICE, fid: "fid-test", internal: true },
        ],
      },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcmOk()),
    );
    const result = await runPushDispatch(env);
    const counter = routed.statements.find((s) => s.includes("SET sent = sent +"));
    return { result, counter };
  }

  it("a real campaign sends to both phones but counts only the real one", async () => {
    const { result, counter } = await drainTwoPhones({ kind: "all" });
    expect(result.sent).toBe(2);
    expect(counter).toMatch(/ :: 1,0,/);
  });

  it("a campaign aimed at test accounts counts them", async () => {
    const { result, counter } = await drainTwoPhones({ kind: "internal" });
    expect(result.sent).toBe(2);
    expect(counter).toMatch(/ :: 2,0,/);
  });

  it("the fan-out total leaves test accounts out of a real campaign only", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    for (const [audience, excludes] of [
      [{ kind: "all" }, true],
      [{ kind: "internal" }, false],
    ] as const) {
      const routed = routedSql([
        {
          match: /SET status = 'sending', started_at/,
          rows: [{ id: CAMPAIGN_ID, audience }],
        },
      ]);
      const env = makeEnv({ PUSH_ENABLED: "true", _testSql: routed.sql });
      await runPushDispatch(env);
      // The routed mock records a nested fragment as its own statement, not inside the UPDATE's text.
      const excluding = routed.statements.some(
        (s) => s.includes("LEFT JOIN push_devices pd") && s.includes("NOT coalesce(u.is_internal, false)"),
      );
      expect(excluding, audience.kind).toBe(excludes);
      const totalWrite = routed.statements.find((s) => s.includes("SET total ="))!;
      // Whether it is finished is decided on EVERY delivery: a real campaign that only reached test
      // phones still has rows to drain.
      expect(totalWrite).toContain(
        "WHEN (SELECT count(*) FROM push_deliveries d WHERE d.campaign_id = c.id) = 0",
      );
      // The phones the send skipped, in the same write: the wider count minus what fanned out.
      expect(totalWrite.replace(/\s+/g, " ")).toContain(
        "left_out = greatest((?) - (SELECT count(*) FROM push_deliveries d WHERE d.campaign_id = c.id), 0)",
      );
      const wider = routed.statements.map((s) => s.replace(/\s+/g, " "));
      expect(wider.some((s) => s.includes("SELECT count(*) FROM (?) w"))).toBe(true);
    }
  });
});

describe("a dead registration is not a failure", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  async function drain(audience: unknown, fcm: () => Response) {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    let claims = 0;
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [{ ...CAMPAIGN, last_error: null, audience }],
      },
      {
        match: /AND status = 'pending'\s+LIMIT/,
        get rows() {
          return claims++ === 0 ? [{ fid: "fid-real" }, { fid: "fid-test" }, { fid: "fid-orphan" }] : [];
        },
      },
      // fid-orphan has no device row: the delivery outlived its registration.
      {
        match: /SELECT d\.fid, d\.token, d\.lang, d\.app_build/,
        rows: [
          { ...DEVICE, fid: "fid-real", internal: false },
          { ...DEVICE, fid: "fid-test", internal: true },
        ],
      },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => fcm()),
    );
    const result = await runPushDispatch(env);
    const counter = routed.statements.find((s) => s.includes("SET sent = sent +"))!;
    return { result, counter, routed };
  }

  it("404 UNREGISTERED and a row with no device count as gone, out of total, never as failed", async () => {
    const { result, counter, routed } = await drain({ kind: "all" }, () => fcmErr(404, "UNREGISTERED"));
    expect(result.failed).toBe(0);
    expect(result.gone).toBe(3);
    // Bound: sent, failed, gone, the total decrement, id. The test phone's dead registration moves
    // nothing — the same rule as sent and failed.
    expect(counter).toContain("gone = gone + ?");
    expect(counter).toContain("total = greatest(total - ?, 0)");
    expect(counter).toMatch(/ :: 0,0,2,2,/);
    // The delivery rows keep the audit trail…
    const audit = routed.statements.filter((s) => s.includes("SET status = 'failed', error = ?"));
    expect(audit.some((s) => s.includes(":: UNREGISTERED: nope,"))).toBe(true);
    expect(audit.some((s) => s.includes(":: device_gone,"))).toBe(true);
    // …and the dead registrations still leave the registry, the orphan having nothing to delete.
    const deleted = routed.statements.find((s) => s.includes("DELETE FROM push_devices"))!;
    expect(deleted).toContain('"fid-real"');
    expect(deleted).toContain('"fid-test"');
    expect(deleted).not.toContain("orphan");
  });

  it("a campaign aimed at test accounts counts their dead phones too", async () => {
    const { counter } = await drain({ kind: "internal" }, () => fcmErr(404, "UNREGISTERED"));
    expect(counter).toMatch(/ :: 0,0,3,3,/);
  });

  it("a transient FCM error is still a failure — an outage must never shrink total", async () => {
    const { result, counter } = await drain({ kind: "all" }, () => fcmErr(503, "UNAVAILABLE"));
    expect(result.failed).toBe(2);
    expect(result.gone).toBe(1);
    expect(counter).toMatch(/ :: 0,1,1,1,/);
  });
});

interface LangRow {
  lang: string;
  sent: number;
  failed: number;
  gone: number;
}

describe("per-language numbers", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("the fan-out stamps every delivery with its phone's language, off the one audience builder", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const routed = routedSql([
      {
        match: /SET status = 'sending', started_at/,
        rows: [{ id: CAMPAIGN_ID, audience: { kind: "all" } }],
      },
    ]);
    await runPushDispatch(makeEnv({ PUSH_ENABLED: "true", _testSql: routed.sql }));
    const fanOut = routed.calls.find((c) => c.text.includes("INSERT INTO push_deliveries"))!;
    expect(fanOut.text.replace(/\s+/g, " ").trim()).toBe(
      "INSERT INTO push_deliveries (campaign_id, fid, lang) SELECT ?, q.fid, pd.lang FROM (?) q JOIN push_devices pd ON pd.fid = q.fid ON CONFLICT DO NOTHING",
    );
    expect(
      routed.statements.some((s) =>
        s.includes("SELECT d.fid FROM push_devices d LEFT JOIN users u ON u.id = d.user_id"),
      ),
    ).toBe(true);
  });

  /** One batch covering every way a delivery ends, then nothing left to claim. */
  async function drainMixed(audience: unknown) {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    let claims = 0;
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [{ ...CAMPAIGN, last_error: null, audience }],
      },
      {
        match: /AND status = 'pending'\s+LIMIT/,
        get rows() {
          return claims++ === 0
            ? [
                { fid: "ta-sent", lang: "ta" },
                { fid: "ta-failed", lang: "ta" },
                { fid: "hi-dead", lang: "hi" },
                // The device row is gone: the stamp is the only language left.
                { fid: "kn-orphan", lang: "kn" },
                // Fanned out before deliveries carried a language: the phone's own, else English.
                { fid: "old-sent", lang: null },
                { fid: "old-orphan", lang: null },
                { fid: "te-test", lang: "te" },
              ]
            : [];
        },
      },
      {
        match: /SELECT d\.fid, d\.token, d\.lang, d\.app_build/,
        rows: [
          { fid: "ta-sent", token: "tok-ok", lang: "ta", internal: false },
          // No token: NO_TOKEN without a request, a failure rather than a dead registration.
          { fid: "ta-failed", token: null, lang: "ta", internal: false },
          { fid: "hi-dead", token: "tok-dead", lang: "hi", internal: false },
          { fid: "old-sent", token: "tok-ok", lang: "ml", internal: false },
          // Switched to English after the fan-out; the stamp still decides.
          { fid: "te-test", token: "tok-ok", lang: "en", internal: true },
        ],
      },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: unknown, init: RequestInit) => {
        const body = JSON.parse(String(init.body)) as { message: { token: string } };
        return body.message.token === "tok-dead" ? fcmErr(404, "UNREGISTERED") : fcmOk();
      }),
    );
    await runPushDispatch(env);

    const counter = routed.calls.find((c) => c.text.includes("SET sent = sent +"))!;
    const upsert = routed.calls.find((c) => c.text.includes("INSERT INTO push_campaign_langs"))!;
    const json = upsert.values.find((v) => typeof v === "string" && v.startsWith("[")) as string;
    const rows = (JSON.parse(json) as LangRow[]).sort((a, b) => a.lang.localeCompare(b.lang));
    const [sent, failed, gone] = counter.values as number[];
    return { routed, counter, upsert, rows, campaign: { sent, failed, gone } };
  }

  function sums(rows: LangRow[]) {
    return {
      sent: rows.reduce((n, r) => n + r.sent, 0),
      failed: rows.reduce((n, r) => n + r.failed, 0),
      gone: rows.reduce((n, r) => n + r.gone, 0),
    };
  }

  it("a real campaign counts each outcome under its delivery's language and leaves the test phone out", async () => {
    const { rows, campaign } = await drainMixed({ kind: "all" });
    expect(rows).toEqual([
      { lang: "en", sent: 0, failed: 0, gone: 1 },
      { lang: "hi", sent: 0, failed: 0, gone: 1 },
      { lang: "kn", sent: 0, failed: 0, gone: 1 },
      { lang: "ml", sent: 1, failed: 0, gone: 0 },
      { lang: "ta", sent: 1, failed: 1, gone: 0 },
    ]);
    expect(campaign).toEqual({ sent: 2, failed: 1, gone: 3 });
    expect(sums(rows)).toEqual(campaign);
  });

  it("a campaign aimed at test accounts counts the test phone, under its stamped language", async () => {
    const { rows, campaign } = await drainMixed({ kind: "internal" });
    expect(rows.find((r) => r.lang === "te")).toEqual({ lang: "te", sent: 1, failed: 0, gone: 0 });
    expect(rows.find((r) => r.lang === "en")).toEqual({ lang: "en", sent: 0, failed: 0, gone: 1 });
    expect(campaign).toEqual({ sent: 3, failed: 1, gone: 3 });
    expect(sums(rows)).toEqual(campaign);
  });

  it("the language upsert adds to the row and runs on the batch's own transaction", async () => {
    const { routed, counter, upsert } = await drainMixed({ kind: "all" });
    const claim = routed.calls.find((c) => /AND status = 'pending'\s+LIMIT/.test(c.text))!;
    expect(claim.text).toContain("SELECT fid, lang FROM push_deliveries");
    expect(upsert.tx).not.toBeNull();
    expect(upsert.tx).toBe(counter.tx);
    expect(upsert.tx).toBe(claim.tx);
    const text = upsert.text.replace(/\s+/g, " ");
    expect(text).toContain("FROM jsonb_to_recordset(?::text::jsonb)");
    expect(text).toContain(
      "ON CONFLICT (campaign_id, lang) DO UPDATE SET sent = push_campaign_langs.sent + EXCLUDED.sent, failed = push_campaign_langs.failed + EXCLUDED.failed, gone = push_campaign_langs.gone + EXCLUDED.gone",
    );
    expect(upsert.values).toContain(CAMPAIGN_ID);
    expect(routed.bound.filter((v) => Array.isArray(v))).toEqual([]);
  });
});

describe("the idle tick prunes the registry", () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  /** A tick with nothing due and nothing sending, and this slice waiting to be checked. */
  function idle(slice: { fid: string; token: string }[]) {
    return routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      { match: /FROM push_campaigns\s+WHERE status = 'sending'/, rows: [] },
      { match: /ORDER BY token_checked_at ASC NULLS FIRST/, rows: slice },
    ]);
  }

  it("dry-runs a slice, deletes what FCM calls dead, stamps the rest, drops week-old token-less rows", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const routed = idle([
      { fid: "dead", token: "tok-dead" },
      { fid: "live", token: "tok-live" },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    const fetchMock = vi.fn(async (_url: unknown, init: RequestInit) => {
      const body = JSON.parse(String(init.body)) as { message: { token: string } };
      return body.message.token === "tok-dead" ? fcmErr(404, "UNREGISTERED") : fcmOk();
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await runPushDispatch(env);
    expect(result.started).toBe(0);
    // Every request is a dry run. Nothing on this path may ever deliver.
    expect(fetchMock).toHaveBeenCalledTimes(2);
    for (const call of fetchMock.mock.calls) {
      expect(JSON.parse(String(call[1].body))).toMatchObject({ validate_only: true });
    }
    const text = routed.text();
    expect(text).toContain("WHERE token IS NOT NULL");
    expect(text).toMatch(/LIMIT \?\s+:: 200/);
    expect(routed.statements.find((s) => s.includes("DELETE FROM push_devices WHERE fid = ANY"))).toContain(
      '{"dead"}',
    );
    expect(routed.statements.find((s) => s.includes("SET token_checked_at = now()"))).toContain('{"live"}');
    expect(text).toContain("WHERE token IS NULL AND last_seen_at < now() - interval '7 days'");
  });

  it("stays out of a tick that is draining a campaign", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    let claims = 0;
    const routed = routedSql([
      { match: /SET status = 'sending', started_at/, rows: [] },
      {
        match: /FROM push_campaigns\s+WHERE status = 'sending'/,
        rows: [{ ...CAMPAIGN, last_error: null }],
      },
      {
        match: /AND status = 'pending'\s+LIMIT/,
        get rows() {
          return claims++ === 0 ? [{ fid: "fid-1" }] : [];
        },
      },
      { match: /SELECT d\.fid, d\.token, d\.lang, d\.app_build/, rows: [DEVICE] },
      { match: /count\(\*\)::int AS n FROM push_deliveries/, rows: [{ n: 0 }] },
      { match: /ORDER BY token_checked_at ASC NULLS FIRST/, rows: [{ fid: "x", token: "tok-x" }] },
    ]);
    const kv = makeMockKV(new Map([["fcm:access_token", "cached-token"]]));
    const env = makeEnv({ PUSH_ENABLED: "true", KV: kv, _testSql: routed.sql });
    const fetchMock = vi.fn(async () => fcmOk());
    vi.stubGlobal("fetch", fetchMock);
    await runPushDispatch(env);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(routed.text()).not.toContain("token_checked_at");
  });

  it("a token it cannot mint is logged once and swallowed — the tick still returns", async () => {
    const { runPushDispatch } = await import("../src/cron/push-dispatch.js");
    const routed = idle([{ fid: "live", token: "tok-live" }]);
    const env = makeEnv({ PUSH_ENABLED: "true", KV: makeMockKV(), _testSql: routed.sql });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("{}", { status: 500 })),
    );
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    await expect(runPushDispatch(env)).resolves.toMatchObject({ started: 0 });
    expect(error).toHaveBeenCalledTimes(1);
    expect(routed.text()).not.toContain("token_checked_at = now()");
    error.mockRestore();
  });
});

describe("POST /me/device", () => {
  it("401 without a token — the registry is never written from an unverified caller", async () => {
    const db = recordingSql();
    const res = await handleRegisterDevice(
      makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: db.sql }), jsonBody: { fid: "f" } }),
    );
    expect(res.status).toBe(401);
    expect(db.captured).toHaveLength(0);
  });

  it("upserts on fid and RE-POINTS the row to the verified user", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const db = recordingSql();
    const res = await handleRegisterDevice(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: db.sql }),
        token,
        jsonBody: { fid: "fid-1", token: "tok", lang: "ta", appBuild: 76, androidSdk: 34 },
      }),
    );
    expect(res.status).toBe(200);
    expect(db.text()).toContain("ON CONFLICT (fid) DO UPDATE");
    expect(db.text()).toContain("user_id      = EXCLUDED.user_id");
    // The user id comes from the VERIFIED sub, never from the body.
    expect(db.values()).toContain(USER_ID);
    expect(db.values()).toContain("ta");
    expect(db.values()).toContain(76);
  });

  it("accepts a body carrying only fid — a later build may send less without a Worker deploy", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const db = recordingSql();
    const res = await handleRegisterDevice(
      makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: db.sql }), token, jsonBody: { fid: "fid-1" } }),
    );
    expect(res.status).toBe(200);
    // Unknown / missing language becomes English rather than dropping the phone out of every audience.
    expect(db.values()).toContain("en");
    // A token the build did not send must not erase one already stored.
    expect(db.text()).toContain("COALESCE(EXCLUDED.token, push_devices.token)");
  });

  it("normalises a region tag and rejects a body with no fid", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const db = recordingSql();
    await handleRegisterDevice(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: db.sql }),
        token,
        jsonBody: { fid: "fid-1", lang: "hi-IN" },
      }),
    );
    expect(db.values()).toContain("hi");

    const res = await handleRegisterDevice(
      makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: db.sql }), token, jsonBody: {} }),
    );
    expect(res.status).toBe(400);
  });
});

describe("POST /push/device", () => {
  it("registers a signed-out phone without a JWT and NEVER writes user_id", async () => {
    const db = recordingSql();
    const res = await handleRegisterAnonDevice(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: db.sql }),
        jsonBody: { fid: "fid-anon", token: "tok", lang: "ta-IN", appBuild: 76, androidSdk: 36 },
      }),
    );
    expect(res.status).toBe(200);
    expect(db.text()).toContain(
      "INSERT INTO push_devices (fid, token, lang, app_build, android_sdk, last_seen_at)",
    );
    expect(db.text()).toContain("ON CONFLICT (fid) DO UPDATE");
    // The whole safety property: an unauthenticated caller cannot detach a phone from its account.
    expect(db.text()).not.toContain("user_id");
    expect(db.text()).toContain("COALESCE(EXCLUDED.token, push_devices.token)");
    expect(db.values()).toEqual(["fid-anon", "tok", "ta", 76, 36]);
  });

  it("ignores a user id smuggled into the body", async () => {
    const db = recordingSql();
    await handleRegisterAnonDevice(
      makeCtx({ env: makeEnv({ _testSql: db.sql }), jsonBody: { fid: "f", user_id: USER_ID, sub: USER_ID } }),
    );
    expect(db.values()).not.toContain(USER_ID);
  });

  it("413s on a body over 2 KB and 400s on no fid or bad JSON, writing nothing", async () => {
    const db = recordingSql();
    const env = makeEnv({ _testSql: db.sql });
    const big = await handleRegisterAnonDevice(
      makeCtx({ env, rawBody: JSON.stringify({ fid: "f", token: "x".repeat(2100) }) }),
    );
    expect(big.status).toBe(413);
    expect((await handleRegisterAnonDevice(makeCtx({ env, jsonBody: {} }))).status).toBe(400);
    expect((await handleRegisterAnonDevice(makeCtx({ env, jsonBody: { fid: "" } }))).status).toBe(400);
    expect((await handleRegisterAnonDevice(makeCtx({ env, invalidJson: true }))).status).toBe(400);
    expect((await handleRegisterAnonDevice(makeCtx({ env, rawBody: "[1,2]" }))).status).toBe(400);
    expect(db.captured).toHaveLength(0);
  });
});

describe("POST /me/push-opened", () => {
  it("records one open per user and dedupes a replayed tap", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const db = recordingSql();
    const res = await handlePushOpened(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: db.sql }),
        token,
        jsonBody: { campaign_id: CAMPAIGN_ID },
      }),
    );
    expect(res.status).toBe(200);
    expect(db.text()).toContain("INSERT INTO push_opens");
    expect(db.text()).toContain("ON CONFLICT DO NOTHING");
    expect(db.values()).toContain(USER_ID);
  });

  async function openedStatement() {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const db = recordingSql();
    const res = await handlePushOpened(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: db.sql }),
        token,
        jsonBody: { campaign_id: CAMPAIGN_ID },
      }),
    );
    return { res, db, text: db.text().replace(/\s+/g, " ") };
  }

  it("adds one open to one language off the insert's own RETURNING, in the same statement", async () => {
    const { res, db, text } = await openedStatement();
    expect(await res.json()).toEqual({ ok: true });
    expect(db.captured).toHaveLength(1);
    // A replayed tap conflicts, so RETURNING is empty and the language row is not touched.
    expect(text).toContain("WITH opened AS ( INSERT INTO push_opens (campaign_id, user_id)");
    expect(text).toContain("ON CONFLICT DO NOTHING RETURNING campaign_id )");
    expect(text).toContain("INSERT INTO push_campaign_langs (campaign_id, lang, opened)");
    expect(text).toContain("FROM opened o JOIN push_campaigns c ON c.id = o.campaign_id");
    expect(text).toContain(
      "ON CONFLICT (campaign_id, lang) DO UPDATE SET opened = push_campaign_langs.opened + 1",
    );
    // Every user id in it is the verified sub; the body only ever names the campaign.
    expect(db.values()).toEqual([CAMPAIGN_ID, USER_ID, CAMPAIGN_ID, USER_ID, USER_ID, USER_ID]);
  });

  it("the language is the user's delivery's, then their latest phone's, then English", async () => {
    const { text } = await openedStatement();
    expect(text).toContain(
      "coalesce( (SELECT coalesce(d.lang, pd.lang) FROM push_deliveries d JOIN push_devices pd ON pd.fid = d.fid WHERE d.campaign_id = o.campaign_id AND pd.user_id = ?",
    );
    expect(text).toContain(
      "(SELECT pd.lang FROM push_devices pd WHERE pd.user_id = ? ORDER BY pd.last_seen_at DESC LIMIT 1), 'en'), 1",
    );
  });

  it("a test account's open moves the language numbers only on an `internal` campaign", async () => {
    const { text } = await openedStatement();
    expect(text).toContain(
      "WHERE c.audience->>'kind' = 'internal' OR NOT coalesce((SELECT u.is_internal FROM users u WHERE u.id = ?), false)",
    );
  });

  it("a database error is still a 500 server_error", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const routed = routedSql([{ match: /push_opens/, throws: "connection lost" }]);
    const res = await handlePushOpened(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: routed.sql }),
        token,
        jsonBody: { campaign_id: CAMPAIGN_ID },
      }),
    );
    expect(res.status).toBe(500);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("server_error");
  });

  it("400s on anything that is not a campaign uuid, and writes nothing", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const db = recordingSql();
    for (const body of [{}, { campaign_id: "" }, { campaign_id: "not-a-uuid" }]) {
      const res = await handlePushOpened(
        makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: db.sql }), token, jsonBody: body }),
      );
      expect(res.status).toBe(400);
    }
    expect(db.captured).toHaveLength(0);
  });
});

describe("the one-off per-language backfill", () => {
  let sqlText = "";
  beforeAll(async () => {
    // tsc sees only workers-types, so Node's fs comes in untyped; vitest runs with cwd = workers/.
    const { readFileSync } = (await import(/* @vite-ignore */ "node:fs" as string)) as {
      readFileSync(file: string, encoding: "utf8"): string;
    };
    sqlText = readFileSync("../db/migrations/2026-10-07_push_lang_backfill.sql", "utf8")
      .split("\n")
      .map((line) => line.replace(/--.*$/, ""))
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
  });

  it("fills only sent campaigns with no row yet, marks them approximate, and inserts nothing twice", () => {
    expect(sqlText.match(/;/g)).toHaveLength(1);
    expect(sqlText).toContain(
      "where c.status = 'sent' and not exists (select 1 from push_campaign_langs l where l.campaign_id = c.id)",
    );
    expect(sqlText).toContain(
      "insert into push_campaign_langs (campaign_id, lang, sent, failed, gone, opened, approximate)",
    );
    expect(sqlText).toContain("coalesce(o.opened, 0), true from by_lang b");
    expect(sqlText).toMatch(/on conflict \(campaign_id, lang\) do nothing;$/);
  });

  it("applies the counters' test-account rule to deliveries and opens alike", () => {
    expect(sqlText).toContain("c.audience->>'kind' = 'internal' as counts_test_accounts");
    expect(
      sqlText.match(/where t\.counts_test_accounts or not coalesce\(u\.is_internal, false\)/g),
    ).toHaveLength(2);
  });

  it("reads a dead registration exactly as isDeadRegistration decided it", () => {
    const exact = [...sqlText.matchAll(/d\.error = '([^']+)'/g)].map((m) => m[1]!);
    const prefixes = [...sqlText.matchAll(/starts_with\(d\.error, '([^']+)'\)/g)].map((m) => m[1]!);
    expect(exact).toEqual(["device_gone"]);
    // The text sendOneBatch writes for a failed send is `${code}: ${message}`.
    const isGone = (error: string) => exact.includes(error) || prefixes.some((p) => error.startsWith(p));
    const results: PushResult[] = [
      { ok: false, status: 404, code: "UNREGISTERED", message: "Requested entity was not found." },
      { ok: false, status: 400, code: "INVALID_ARGUMENT", message: "The registration token is not valid" },
      { ok: false, status: 503, code: "UNAVAILABLE", message: "nope" },
      { ok: false, status: 429, code: "QUOTA_EXCEEDED", message: "nope" },
      { ok: false, status: 403, code: "SENDER_ID_MISMATCH", message: "nope" },
      { ok: false, status: 0, code: "NO_TOKEN", message: "Device row carries no FCM token" },
      { ok: false, status: 404, code: "NOT_FOUND", message: "nope" },
    ];
    for (const r of results) {
      if (r.ok) continue;
      expect(isGone(`${r.code}: ${r.message}`), r.code).toBe(isDeadRegistration(r));
    }
  });
});

describe("/internal/push/* auth gate", () => {
  const handlers = [
    ["count", handlePushCount, { audience: { kind: "all" } }],
    ["dispatch", handlePushDispatch, { campaign_id: CAMPAIGN_ID }],
    ["test", handlePushTest, { campaign_id: CAMPAIGN_ID }],
  ] as const;

  it("401s on a wrong secret", async () => {
    for (const [name, handler, body] of handlers) {
      const env = makeEnv({ PUSH_SECRET: "right", _testSql: recordingSql().sql });
      const res = await handler(makeCtx({ env, token: "wrong", jsonBody: body }));
      expect(res.status, name).toBe(401);
    }
  });

  it("FAILS CLOSED when PUSH_SECRET is unset — never accepts any bearer", async () => {
    for (const [name, handler, body] of handlers) {
      const env = makeEnv({ PUSH_SECRET: "", _testSql: recordingSql().sql });
      const res = await handler(makeCtx({ env, token: "anything", jsonBody: body }));
      expect(res.status, name).toBe(401);
    }
  });

  it("refuses CATALOG_BUILD_SECRET — one string must not rebuild AND message everyone", async () => {
    const env = makeEnv({ PUSH_SECRET: "push-only", CATALOG_BUILD_SECRET: "catalog-only" });
    const res = await handlePushCount(
      makeCtx({ env, token: "catalog-only", jsonBody: { audience: { kind: "all" } } }),
    );
    expect(res.status).toBe(401);
  });

  it("count rejects an unknown audience rather than counting everyone", async () => {
    const db = recordingSql([{ n: 999 }]);
    const env = makeEnv({ PUSH_SECRET: "s", _testSql: db.sql });
    const res = await handlePushCount(
      makeCtx({ env, token: "s", jsonBody: { audience: { kind: "everyone" } } }),
    );
    expect(res.status).toBe(400);
    expect(db.captured).toHaveLength(0);
  });

  it("count accepts a filter audience and counts it through the one audience builder", async () => {
    const db = recordingSql([{ n: 42 }]);
    const env = makeEnv({ PUSH_SECRET: "s", _testSql: db.sql });
    const res = await handlePushCount(
      makeCtx({
        env,
        token: "s",
        jsonBody: { audience: { kind: "filter", lang: "ta", plan: "free", joined_hours: 24 } },
      }),
    );
    expect(res.status).toBe(200);
    expect(((await res.json()) as { devices: number }).devices).toBe(42);
    expect(db.text()).toContain("SELECT (SELECT count(*)::int FROM (");
    expect(db.text()).toContain("d.created_at >= now() - (? || ' hours')::interval");

    const before = db.captured.length;
    const contradiction = await handlePushCount(
      makeCtx({
        env,
        token: "s",
        jsonBody: { audience: { kind: "filter", plan: "paid", signed_in: false } },
      }),
    );
    expect(contradiction.status).toBe(400);
    expect(db.captured).toHaveLength(before);
  });

  it("count returns the phones it reaches and, apart, the ones left out until sign-in", async () => {
    const db = recordingSql([{ n: 900, with_waiting: 1033 }]);
    const env = makeEnv({ PUSH_SECRET: "s", _testSql: db.sql });
    const res = await handlePushCount(makeCtx({ env, token: "s", jsonBody: { audience: { kind: "all" } } }));
    expect(await res.json()).toEqual({ devices: 900, waiting_sign_in: 133 });
    // One audience twice: once with the left-out clause, once without it.
    const text = db.text();
    expect(text).toContain("AS with_waiting");
    expect(text.match(/coalesce\(d\.android_sdk, 0\) >= 33/g)).toHaveLength(1);
  });

  it("dispatch is inert while PUSH_ENABLED is off, but still answers the CMS", async () => {
    const db = recordingSql();
    const env = makeEnv({ PUSH_SECRET: "s", PUSH_ENABLED: "false", _testSql: db.sql });
    const res = await handlePushDispatch(
      makeCtx({ env, token: "s", jsonBody: { campaign_id: CAMPAIGN_ID } }),
    );
    expect(res.status).toBe(202);
    expect(((await res.json()) as { dispatched: boolean }).dispatched).toBe(false);
    expect(db.captured).toHaveLength(0);
  });
});
