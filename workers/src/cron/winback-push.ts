/**
 * The win-back resolver, first on the "* * * * *" push trigger. SQL only: a due revoke becomes push_deliveries on this
 * month's automated campaign row, and runPushDispatch drains them like any campaign (docs/push.md §Win-back)
 */

import type postgres from "postgres";
import type { Env } from "../env.js";
import { getDb, toDate } from "../lib/db.js";
import { reachableDevice } from "../lib/push-audience.js";
import { winbackOfferEligible } from "../lib/subscription-state.js";
import {
  autoKeyFor,
  isQuietHourIST,
  PAID_LEAD_MS,
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
}

export async function runWinbackPushes(env: Env, now: Date): Promise<WinbackResult> {
  const result: WinbackResult = { resolved: 0, sent: 0, reasons: {} };
  if (!pushEnabled(env)) return { ...result, skipped: "disabled" };
  if (isQuietHourIST(now)) return { ...result, skipped: "quiet_hours" };

  const sql = getDb(env);
  try {
    await sql.begin(async (tx) => resolveDue(tx as unknown as Sql, now, winbackLive(env), result));
    await reopenStranded(sql);
    return result;
  } finally {
    await sql.end().catch(() => {});
  }
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
              AND coalesce(d.app_build, 0) % 1000 >= ${WINBACK_MIN_BUILD}) AS new_phones
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
    if (verdict === "send") toSend.push(row);
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
    // One win-back per phone per IST month across BOTH groups: a trial revoker who came back on ₹99 and revoked
    // again that month already heard this offer (CCPA "nagging")
    const inserted = (await tx`
      INSERT INTO push_deliveries (campaign_id, fid, lang)
      SELECT ${campaignId}, d.fid, d.lang
      FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
      WHERE d.user_id = ${row.user_id} AND ${reachableDevice(tx)}
        AND coalesce(d.app_build, 0) % 1000 >= ${WINBACK_MIN_BUILD}
        AND NOT EXISTS (
          SELECT 1 FROM push_deliveries pd JOIN push_campaigns pc ON pc.id = pd.campaign_id
          WHERE pd.fid = d.fid AND pc.auto_key IN (${autoKeyFor("trial", now)}, ${autoKeyFor("paid", now)})
        )
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
