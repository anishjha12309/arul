/**
 * The win-back resolver, first on the "* * * * *" push trigger. SQL only: a due revoke becomes push_deliveries on this
 * month's automated campaign row, and runPushDispatch drains them like any campaign (docs/push.md §Win-back)
 */

import type postgres from "postgres";
import type { Env } from "../env.js";
import { getDb, toDate } from "../lib/db.js";
import { premiumPredicate } from "../lib/entitlement.js";
import { reachableDevice } from "../lib/push-audience.js";
import { winbackOfferEligible } from "../lib/subscription-state.js";
import {
  autoKeyFor,
  isQuietHourIST,
  istDayStart,
  PAID_LEAD_MS,
  SERIES_DAYS,
  seriesAutoKey,
  seriesDecision,
  seriesTexts,
  WINBACK_DELAY_MS,
  WINBACK_DEST,
  WINBACK_EXPIRES_HOURS,
  WINBACK_MIN_BUILD,
  type WinbackGroup,
  winbackDecision,
  winbackGroup,
  winbackTexts,
} from "../lib/winback-push.js";
import { pushEnabled } from "./push-dispatch.js";

type Sql = postgres.Sql;
type Fragment = postgres.PendingQuery<postgres.Row[]>;

/** A revoke is one person, not a campaign -> a minute's worth is a handful, and the next tick takes the rest. */
const BATCH = 100;

export interface WinbackResult {
  skipped?: string;
  resolved: number;
  sent: number;
  reasons: Record<string, number>;
}

/** `"true"` and nothing else -> until the owner flips it, due rows resolve as `disabled`, which is the baseline. */
export function winbackLive(env: Env): boolean {
  return env.WINBACK_PUSH_ENABLED === "true";
}

interface DueRow {
  mandate_id: string;
  user_id: string;
  prior_status: string | null;
  due_at: Date | string;
  live_mandate_id: string | null;
  status: string | null;
  eligible: boolean;
  internal: boolean;
  phones: number | string;
  new_phones: number | string;
  pushed_today: boolean;
}

export async function runWinbackPushes(env: Env, now: Date): Promise<WinbackResult> {
  const result: WinbackResult = { resolved: 0, sent: 0, reasons: {} };
  if (!pushEnabled(env)) return { ...result, skipped: "disabled" };
  if (isQuietHourIST(now)) return { ...result, skipped: "quiet_hours" };

  const sql = getDb(env);
  try {
    await sql.begin(async (tx) => resolveDue(tx as unknown as Sql, now, winbackLive(env), result));
    await sql.begin(async (tx) => resolveSeries(tx as unknown as Sql, now, winbackLive(env), result));
    await reopenStranded(sql);
    return result;
  } finally {
    await sql.end().catch(() => {});
  }
}

/** One win-back a day per person, revoke push and series alike (owner): a sent row of either since IST midnight. */
function pushedToday(tx: Sql, userId: Fragment, now: Date): Fragment {
  const since = istDayStart(now).toISOString();
  return tx`(
    EXISTS (SELECT 1 FROM winback_pushes p
            WHERE p.user_id = ${userId} AND p.state = 'sent' AND p.resolved_at >= ${since}::timestamptz)
    OR EXISTS (SELECT 1 FROM winback_series ws
               WHERE ws.user_id = ${userId} AND ws.state = 'sent' AND ws.created_at >= ${since}::timestamptz)
  )`;
}

async function resolveDue(tx: Sql, now: Date, live: boolean, result: WinbackResult): Promise<void> {
  const at = now.toISOString();
  const delay = `${WINBACK_DELAY_MS / 1000} seconds`;
  const lead = `${PAID_LEAD_MS / 1000} seconds`;
  const dueAt = tx`greatest(wp.created_at + ${delay}::interval, s.current_period_end - ${lead}::interval)`;
  // `phones` ignores the build gate on purpose: winbackDecision checks it before `disabled`, the baseline's group
  const due = (await tx`
    SELECT wp.mandate_id, wp.user_id, wp.prior_status, ${dueAt} AS due_at,
           s.merchant_subscription_id AS live_mandate_id, s.status,
           coalesce(${winbackOfferEligible(tx)}, false) AS eligible,
           coalesce(owner.is_internal, false) AS internal,
           (SELECT count(*)::int FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
            WHERE d.user_id = wp.user_id AND ${reachableDevice(tx)}) AS phones,
           (SELECT count(*)::int FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
            WHERE d.user_id = wp.user_id AND ${reachableDevice(tx)}
              AND coalesce(d.app_build, 0) % 1000 >= ${WINBACK_MIN_BUILD}) AS new_phones,
           ${pushedToday(tx, tx`wp.user_id`, now)} AS pushed_today
    FROM winback_pushes wp
    LEFT JOIN subscriptions s ON s.user_id = wp.user_id
    LEFT JOIN users owner ON owner.id = wp.user_id
    WHERE wp.state = 'queued' AND ${dueAt} <= ${at}::timestamptz
    ORDER BY wp.created_at
    LIMIT ${BATCH}
    FOR UPDATE OF wp SKIP LOCKED
  `) as unknown as DueRow[];
  if (due.length === 0) return;

  const toSend: DueRow[] = [];
  for (const row of due) {
    const verdict = winbackDecision(
      {
        group: winbackGroup(row.prior_status),
        mandateId: row.mandate_id,
        dueAt: toDate(row.due_at) ?? now,
        liveMandateId: row.live_mandate_id,
        status: row.status,
        eligible: row.eligible === true,
        phones: Number(row.phones),
        newPhones: Number(row.new_phones),
      },
      now,
      live,
    );
    if (verdict === "send" && row.pushed_today === true)
      await resolve(tx, row.mandate_id, "capped", at, result);
    else if (verdict === "send") toSend.push(row);
    else await resolve(tx, row.mandate_id, verdict, at, result);
  }
  if (toSend.length === 0) return;

  const campaigns = await ensureAutoCampaigns(
    tx,
    now,
    new Set(toSend.map((r) => winbackGroup(r.prior_status))),
  );
  for (const row of toSend) {
    const campaignId = campaigns.get(winbackGroup(row.prior_status)) as string;
    // A phone already on this month's row (a second revoke) conflicts on the delivery key -> `capped`
    const inserted = (await tx`
      INSERT INTO push_deliveries (campaign_id, fid, lang)
      SELECT ${campaignId}, d.fid, d.lang
      FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
      WHERE d.user_id = ${row.user_id} AND ${reachableDevice(tx)}
        AND coalesce(d.app_build, 0) % 1000 >= ${WINBACK_MIN_BUILD}
      ON CONFLICT DO NOTHING
      RETURNING fid
    `) as unknown as { fid: string }[];
    if (inserted.length === 0) {
      await resolve(tx, row.mandate_id, "capped", at, result);
      continue;
    }
    // A test account's phones get it but stay out of `total`, as on every campaign that is not `internal`
    await tx`
      UPDATE push_campaigns
      SET status = 'sending', total = total + ${row.internal ? 0 : inserted.length}
      WHERE id = ${campaignId}
    `;
    await tx`
      UPDATE winback_pushes
      SET state = 'sent', campaign_id = ${campaignId}, resolved_at = ${at}::timestamptz
      WHERE mandate_id = ${row.mandate_id}
    `;
    result.resolved += 1;
    result.sent += 1;
  }
}

async function resolve(
  tx: Sql,
  mandateId: string,
  reason: string,
  at: string,
  result: WinbackResult,
): Promise<void> {
  await tx`
    UPDATE winback_pushes
    SET state = 'skipped', skip_reason = ${reason}, resolved_at = ${at}::timestamptz
    WHERE mandate_id = ${mandateId}
  `;
  result.resolved += 1;
  result.reasons[reason] = (result.reasons[reason] ?? 0) + 1;
}

interface SeriesRow {
  user_id: string;
  /**
   * Text both ways, bound `::text::timestamptz`: a JS Date, or postgres.js serializing a timestamptz param, drops
   * the microseconds, the key never matches its own row, and that row refills every minute's batch
   */
  lapsed_at: string;
  day: number | string;
  internal: boolean;
  phones: number | string;
  new_phones: number | string;
  pushed_today: boolean;
}

/**
 * The daily series: everyone the app's ₹99 sheets reach (premium run out, offered ₹99, not mid-checkout) gets one push
 * a day for SERIES_DAYS days from the moment premium ran out. Each evaluated day writes one row, sent or skipped, so
 * a day is decided once, and a purchase or a new setup ends the series by leaving the ₹99 rule
 */
async function resolveSeries(tx: Sql, now: Date, live: boolean, result: WinbackResult): Promise<void> {
  const at = now.toISOString();
  const elapsedDays = tx`floor(extract(epoch FROM (${at}::timestamptz - l.lapsed_at)) / 86400)::int`;
  const due = (await tx`
    WITH l AS (
      SELECT s.user_id,
             greatest(coalesce(s.current_period_end, s.trial_end), owner.reward_premium_until) AS lapsed_at,
             coalesce(owner.is_internal, false) AS internal
      FROM subscriptions s
      JOIN users owner ON owner.id = s.user_id
      WHERE ${winbackOfferEligible(tx)} AND s.status <> 'pending'
        AND NOT ${premiumPredicate(tx, tx`s.user_id`)}
    )
    SELECT l.user_id, l.lapsed_at::text AS lapsed_at, ${elapsedDays} AS day, l.internal,
           (SELECT count(*)::int FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
            WHERE d.user_id = l.user_id AND ${reachableDevice(tx)}) AS phones,
           (SELECT count(*)::int FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
            WHERE d.user_id = l.user_id AND ${reachableDevice(tx)}
              AND coalesce(d.app_build, 0) % 1000 >= ${WINBACK_MIN_BUILD}) AS new_phones,
           ${pushedToday(tx, tx`l.user_id`, now)} AS pushed_today
    FROM l
    WHERE l.lapsed_at <= ${at}::timestamptz
      AND l.lapsed_at > ${at}::timestamptz - ${`${SERIES_DAYS} days`}::interval
      AND NOT EXISTS (SELECT 1 FROM winback_series ws
                      WHERE ws.user_id = l.user_id AND ws.lapsed_at = l.lapsed_at AND ws.day = ${elapsedDays})
    ORDER BY l.lapsed_at
    LIMIT ${BATCH}
  `) as unknown as SeriesRow[];
  if (due.length === 0) return;

  const toSend: SeriesRow[] = [];
  for (const row of due) {
    const verdict = seriesDecision({ phones: Number(row.phones), newPhones: Number(row.new_phones) }, live);
    if (verdict === "send" && row.pushed_today === true) await recordDay(tx, row, "capped", at, result);
    else if (verdict === "send") toSend.push(row);
    else await recordDay(tx, row, verdict, at, result);
  }
  if (toSend.length === 0) return;

  const campaigns = await ensureSeriesCampaigns(tx, now, new Set(toSend.map((r) => Number(r.day))));
  for (const row of toSend) {
    const campaignId = campaigns.get(Number(row.day)) as string;
    // The day's key is the race lock: an overlapping tick that already claimed it inserts nothing here
    const claimed = (await tx`
      INSERT INTO winback_series (user_id, lapsed_at, day, state, campaign_id, created_at)
      VALUES (${row.user_id}, ${row.lapsed_at}::text::timestamptz, ${Number(row.day)}, 'sent', ${campaignId},
              ${at}::timestamptz)
      ON CONFLICT DO NOTHING
      RETURNING user_id
    `) as unknown as { user_id: string }[];
    if (claimed.length === 0) continue;
    const inserted = (await tx`
      INSERT INTO push_deliveries (campaign_id, fid, lang)
      SELECT ${campaignId}, d.fid, d.lang
      FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
      WHERE d.user_id = ${row.user_id} AND ${reachableDevice(tx)}
        AND coalesce(d.app_build, 0) % 1000 >= ${WINBACK_MIN_BUILD}
      ON CONFLICT DO NOTHING
      RETURNING fid
    `) as unknown as { fid: string }[];
    if (inserted.length === 0) {
      // Same day key a month earlier, on this month's row: a second lapse inside the month already had it
      await tx`
        UPDATE winback_series SET state = 'skipped', skip_reason = 'capped', campaign_id = NULL
        WHERE user_id = ${row.user_id} AND lapsed_at = ${row.lapsed_at}::text::timestamptz AND day = ${Number(row.day)}
      `;
      result.reasons.capped = (result.reasons.capped ?? 0) + 1;
      result.resolved += 1;
      continue;
    }
    await tx`
      UPDATE push_campaigns
      SET status = 'sending', total = total + ${row.internal ? 0 : inserted.length}
      WHERE id = ${campaignId}
    `;
    result.resolved += 1;
    result.sent += 1;
  }
}

async function recordDay(
  tx: Sql,
  row: SeriesRow,
  reason: string,
  at: string,
  result: WinbackResult,
): Promise<void> {
  const recorded = (await tx`
    INSERT INTO winback_series (user_id, lapsed_at, day, state, skip_reason, created_at)
    VALUES (${row.user_id}, ${row.lapsed_at}::text::timestamptz, ${Number(row.day)}, 'skipped', ${reason},
            ${at}::timestamptz)
    ON CONFLICT DO NOTHING
    RETURNING user_id
  `) as unknown as { user_id: string }[];
  if (recorded.length === 0) return;
  result.resolved += 1;
  result.reasons[reason] = (result.reasons[reason] ?? 0) + 1;
}

/** Ascending day order, always: the upsert locks the row, and one fixed order keeps overlapping ticks from deadlocking. */
async function ensureSeriesCampaigns(tx: Sql, now: Date, days: Set<number>): Promise<Map<number, string>> {
  const at = now.toISOString();
  const ids = new Map<number, string>();
  for (const day of [...days].sort((a, b) => a - b)) {
    const key = seriesAutoKey(day, now);
    const rows = (await tx`
      INSERT INTO push_campaigns
        (auto_key, status, texts, dest, dest_id, audience, expires_hours, send_at, started_at, sent_at)
      VALUES (${key}, 'sent', ${JSON.stringify(seriesTexts(day))}::text::jsonb,
              ${WINBACK_DEST.dest}, ${WINBACK_DEST.destId},
              ${JSON.stringify({ kind: "winback", group: "series", day: day + 1 })}::text::jsonb,
              ${WINBACK_EXPIRES_HOURS}, ${at}::timestamptz, ${at}::timestamptz, ${at}::timestamptz)
      ON CONFLICT (auto_key) DO UPDATE SET texts = EXCLUDED.texts
      RETURNING id
    `) as unknown as { id: string }[];
    if (!rows[0]) throw new Error(`[winback] no campaign row for ${key}`);
    ids.set(day, rows[0].id);
  }
  return ids;
}

/**
 * Trial before paid, always: the upsert locks the month row, so one fixed order is what keeps two overlapping ticks
 * from deadlocking. `status 'sent'` keeps it out of startDueCampaigns; the delivery insert reopens it for the drain
 */
async function ensureAutoCampaigns(
  tx: Sql,
  now: Date,
  groups: Set<WinbackGroup>,
): Promise<Map<WinbackGroup, string>> {
  const at = now.toISOString();
  const ids = new Map<WinbackGroup, string>();
  for (const group of ["trial", "paid"] as const) {
    if (!groups.has(group)) continue;
    const rows = (await tx`
      INSERT INTO push_campaigns
        (auto_key, status, texts, dest, dest_id, audience, expires_hours, send_at, started_at, sent_at)
      VALUES (${autoKeyFor(group, now)}, 'sent', ${JSON.stringify(winbackTexts(group))}::text::jsonb,
              ${WINBACK_DEST.dest}, ${WINBACK_DEST.destId}, ${JSON.stringify({ kind: "winback", group })}::text::jsonb,
              ${WINBACK_EXPIRES_HOURS}, ${at}::timestamptz, ${at}::timestamptz, ${at}::timestamptz)
      ON CONFLICT (auto_key) DO UPDATE SET texts = EXCLUDED.texts
      RETURNING id
    `) as unknown as { id: string }[];
    // An upsert with DO UPDATE always returns its row -> none means the statement did not run as written
    if (!rows[0]) throw new Error(`[winback] no campaign row for ${autoKeyFor(group, now)}`);
    ids.set(group, rows[0].id);
  }
  return ids;
}

/**
 * An overlapping tick's drain can count zero pending, then flip the row to 'sent' just after this tick's insert
 * committed -> the delivery would wait for the month's next win-back. A 'failed' row stays down: its last_error
 * would restart the token-failure count
 */
async function reopenStranded(sql: Sql): Promise<void> {
  await sql`
    UPDATE push_campaigns c
    SET status = 'sending'
    WHERE c.auto_key IS NOT NULL AND c.status = 'sent'
      AND EXISTS (SELECT 1 FROM push_deliveries d WHERE d.campaign_id = c.id AND d.status = 'pending')
  `;
}
