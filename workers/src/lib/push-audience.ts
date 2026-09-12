/**
 * Who a campaign reaches — THE one home for the segment SQL (docs/push.md).
 *
 * The CMS never writes a line of this: it POSTs the audience JSON to /internal/push/count and to the
 * campaign row, and both the count and the delivery fan-out run this same builder. A second copy in
 * the CMS would be a count that disagrees with the send.
 *
 * INTERNAL ACCOUNTS ARE EXCLUDED FROM EVERY KIND BUT `internal`. The owner's own test accounts and
 * Google Play's pre-launch robots share the tables with real users, and a real campaign must never
 * land on one. `internal` is the other half of the same rule: it is what "Send to my phone" targets,
 * and it reaches nobody else. The flag is set by hand — NEVER match an account by email substring
 * ('%anish%' matches ~35 real paying users).
 */

import type postgres from "postgres";
import { premiumPredicate } from "./entitlement.js";

export type PushAudience =
  | { kind: "all" }
  | { kind: "lang"; lang: string }
  | { kind: "premium"; state: "free" | "trialing" | "paid" | "lapsed" }
  | { kind: "inactive"; days: number }
  | { kind: "internal" };

/** The six shipped app languages. Mirrors Dart's `supportedAppLocales` and the Worker's LANG_RE. */
export const PUSH_LANGS = ["en", "ta", "te", "kn", "ml", "hi"] as const;

const PREMIUM_STATES = ["free", "trialing", "paid", "lapsed"] as const;
const INACTIVE_DAYS = [7, 14, 30] as const;

/**
 * Narrow untrusted JSON to an audience, or null.
 *
 * Returns null rather than defaulting to `all`: an audience the CMS mistyped must fail the request,
 * never silently become "everyone".
 */
export function parseAudience(raw: unknown): PushAudience | null {
  if (!raw || typeof raw !== "object") return null;
  const a = raw as Record<string, unknown>;
  switch (a["kind"]) {
    case "all":
      return { kind: "all" };
    case "internal":
      return { kind: "internal" };
    case "lang": {
      const lang = typeof a["lang"] === "string" ? a["lang"] : "";
      return (PUSH_LANGS as readonly string[]).includes(lang) ? { kind: "lang", lang } : null;
    }
    case "premium": {
      const state = PREMIUM_STATES.find((s) => s === a["state"]);
      return state ? { kind: "premium", state } : null;
    }
    case "inactive": {
      const days = Number(a["days"]);
      return (INACTIVE_DAYS as readonly number[]).includes(days) ? { kind: "inactive", days } : null;
    }
    default:
      return null;
  }
}

/** A one-line description for the campaign card's "who got it" chip. */
export function audienceLabel(a: PushAudience): string {
  switch (a.kind) {
    case "all":
      return "Everyone";
    case "lang":
      return LANG_LABELS[a.lang] ?? a.lang;
    case "premium":
      return PLAN_LABELS[a.state];
    case "inactive":
      return `Haven't opened in ${a.days} days`;
    case "internal":
      return "My own phones";
  }
}

const LANG_LABELS: Record<string, string> = {
  en: "English",
  ta: "Tamil",
  te: "Telugu",
  kn: "Kannada",
  ml: "Malayalam",
  hi: "Hindi",
};

const PLAN_LABELS: Record<string, string> = {
  free: "Free users",
  trialing: "On trial",
  paid: "Paying users",
  lapsed: "Stopped paying",
};

/**
 * `SELECT d.fid FROM push_devices d …` for one audience, as a composable fragment.
 *
 * Callers wrap it: `SELECT count(*) FROM (${audienceQuery(sql, a)}) q` for the CMS's live count, and
 * `INSERT INTO push_deliveries … SELECT … FROM (${audienceQuery(sql, a)}) q` for the fan-out, so tens
 * of thousands of rows never travel through the Worker.
 */
export function audienceQuery(
  sql: postgres.Sql,
  audience: PushAudience,
): postgres.PendingQuery<postgres.Row[]> {
  const base = sql`SELECT d.fid FROM push_devices d JOIN users u ON u.id = d.user_id`;

  switch (audience.kind) {
    case "internal":
      return sql`${base} WHERE u.is_internal`;
    case "all":
      return sql`${base} WHERE NOT u.is_internal`;
    case "lang":
      return sql`${base} WHERE NOT u.is_internal AND d.lang = ${audience.lang}`;
    case "inactive":
      // A cast, not string interpolation: the day counts are a closed set but the interval still
      // arrives as a bound value, so this stays one prepared statement whatever the caller passes.
      return sql`
        ${base}
        WHERE NOT u.is_internal
          AND d.last_seen_at < now() - (${String(audience.days)} || ' days')::interval
      `;
    case "premium":
      return sql`${base} WHERE NOT u.is_internal AND ${planPredicate(sql, audience.state)}`;
  }
}

/**
 * The four plan states the CMS shows, expressed against `d.user_id`.
 *
 * `paid` and `lapsed` both read `premiumPredicate` rather than re-deriving the rule (CLAUDE.md §5).
 * A copy here would drift the moment reward credit or the debit grace changed, and the audience would
 * quietly disagree with what the app's own gate lets those people do.
 */
function planPredicate(
  sql: postgres.Sql,
  state: "free" | "trialing" | "paid" | "lapsed",
): postgres.PendingQuery<postgres.Row[]> {
  const premium = premiumPredicate(sql, sql`d.user_id`);
  const hasRow = sql`EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = d.user_id)`;
  switch (state) {
    case "free":
      // Never subscribed AND holds no referral-reward credit — the people a trial offer is FOR.
      return sql`
        NOT ${hasRow}
        AND (u.reward_premium_until IS NULL OR u.reward_premium_until <= now())
      `;
    case "trialing":
      return sql`EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = d.user_id AND s.status = 'trialing')`;
    case "paid":
      return sql`
        ${premium}
        AND EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = d.user_id AND s.status = 'active')
      `;
    case "lapsed":
      // Subscribed once, entitled no longer. Cancelled-but-still-inside-the-paid-period is NOT here:
      // premiumPredicate still says yes for them, and telling a person who is paying today that their
      // subscription stopped is the one message this segment must never send.
      return sql`${hasRow} AND NOT ${premium}`;
  }
}
