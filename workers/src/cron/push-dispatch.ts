/**
 * Campaign push dispatch — the "* * * * *" cron's whole job. Read docs/push.md before changing it.
 *
 * ITS OWN TRIGGER, never folded into another (.claude/rules/worker-infra.md): a separate cron
 * expression gets a separate invocation, so a draining campaign and the catalog rebuild each get a
 * full subrequest budget and a full wall clock. Sharing one is exactly what blew the cap mid-scan for
 * autopay, and a send stopping halfway is invisible — nobody complains about a notification that
 * never arrived.
 *
 * THE CLAIM IS THE SAFETY. `SELECT … FOR UPDATE SKIP LOCKED` inside one batch transaction means two
 * overlapping ticks divide the work instead of racing it, and a tick killed mid-batch rolls back to
 * 'pending' rather than losing the rows. (campaign_id, fid) is the primary key, so the retry cannot
 * create a second delivery for the same phone, and `collapse_key`/`tag` make even a genuine duplicate
 * replace itself in the drawer rather than stack.
 *
 * PUSH_ENABLED IS THE KILL SWITCH and it gates THIS function, not the send helper: with it off the
 * cron claims nothing at all, while /internal/push/test still reaches the owner's own phones.
 */

import type postgres from "postgres";
import type { Env } from "../env.js";
import { getDb, toPgTextArray } from "../lib/db.js";
import {
  getFcmAccessToken,
  isDeadRegistration,
  sendPush,
  type PushCampaign,
  type PushDevice,
} from "../lib/fcm.js";
import { audienceQuery, parseAudience, type PushAudience } from "../lib/push-audience.js";

/** Rows claimed per batch transaction. The lock is held only while the batch's sends are in flight. */
const BATCH = 600;

/** In-flight sends per batch. FCM's own scaling guidance; the ceiling here is Neon, not FCM's quota. */
const CONCURRENCY = 6;

/**
 * Wall clock one tick may spend claiming, well inside the runtime's 15-minute cron ceiling.
 * The next minute's tick continues from the same 'pending' rows — there is nothing to hand over.
 */
const TICK_BUDGET_MS = 10 * 60 * 1000;

/**
 * Ticks a campaign may fail to mint an access token before it is given up on.
 *
 * Counted in `failed` on the campaign only when NOTHING could be sent, so a wrong service-account key
 * surfaces as a campaign that says why instead of one that sits in 'sending' forever.
 */
const MAX_TOKEN_FAILURES = 30;

export interface PushDispatchResult {
  skipped?: string;
  started: number;
  attempted: number;
  sent: number;
  failed: number;
  completed: number;
}

/**
 * Whether a campaign's Sent/Failed/total count the test accounts' phones.
 *
 * Test accounts receive every real campaign (lib/push-audience.ts) but stay out of its numbers: a
 * team that opens every send on reinstalled phones would otherwise move Failed and Opened on each
 * one. A campaign aimed AT them is the exception — there they are the only phones, and "Sent 0"
 * would hide whether the test went out.
 */
export function countsTestAccounts(audience: PushAudience | null): boolean {
  return audience?.kind === "internal";
}

/** `"true"` and nothing else. An unset or misspelt var reads as OFF — this switch fails closed. */
export function pushEnabled(env: Env): boolean {
  return env.PUSH_ENABLED === "true";
}

export async function runPushDispatch(env: Env): Promise<PushDispatchResult> {
  const empty: PushDispatchResult = { started: 0, attempted: 0, sent: 0, failed: 0, completed: 0 };
  // SILENT while disabled. This runs 1,440 times a day and every failure path in this Worker is a
  // bare console.error -> a line per tick would bury them inside the log retention window. The
  // caller logs the disabled state once an hour so the switch still leaves a breadcrumb.
  if (!pushEnabled(env)) return { ...empty, skipped: "disabled" };

  const sql = getDb(env);
  const deadline = Date.now() + TICK_BUDGET_MS;
  const result: PushDispatchResult = { ...empty };

  try {
    result.started = await startDueCampaigns(sql);

    // Oldest first: a campaign already half-sent finishes before a newer one starts consuming ticks.
    const running = (await sql`
      SELECT id, texts, dest, dest_id, image_url, color, expires_hours, last_error, audience
      FROM push_campaigns
      WHERE status = 'sending'
      ORDER BY started_at ASC NULLS FIRST
    `) as unknown as (PushCampaign & { last_error: string | null; audience?: unknown })[];

    for (const campaign of running) {
      if (Date.now() >= deadline) break;
      try {
        const drained = await drainCampaign(sql, env, campaign, deadline);
        result.attempted += drained.attempted;
        result.sent += drained.sent;
        result.failed += drained.failed;
        if (drained.completed) result.completed += 1;
      } catch (err) {
        // A throw here used to take the whole pass down having written NOTHING to the row. The
        // campaign stayed 'sending' for ever, the CMS showed "Sending…" with no reason, and because
        // the dispatch route runs this inside waitUntil the error surfaced only in `wrangler tail`.
        // That is how a malformed array literal hid: the one place it was visible was a log nobody
        // was watching. Record it on the campaign and carry on — one broken campaign must not stop
        // the rest, and a stuck campaign that cannot say why is the worst of both.
        console.error(`[push] campaign ${campaign.id}: drain failed:`, err);
        await sql`
          UPDATE push_campaigns SET last_error = ${`Sending failed: ${String(err)}`.slice(0, 300)}
          WHERE id = ${campaign.id}
        `.catch(() => {});
      }
    }
    return result;
  } finally {
    await sql.end().catch(() => {});
  }
}

/**
 * Claim every due campaign and fan its audience out into delivery rows.
 *
 * The status flip and the fan-out are separate statements on purpose: the flip is the claim (a second
 * tick sees 'sending' and does not re-fan), and the INSERT … ON CONFLICT DO NOTHING is idempotent, so
 * a tick that dies between them is repaired by the next one rather than double-inserting.
 */
async function startDueCampaigns(sql: postgres.Sql): Promise<number> {
  const due = (await sql`
    UPDATE push_campaigns
    SET status = 'sending', started_at = now()
    WHERE status = 'scheduled' AND send_at <= now()
    RETURNING id, audience
  `) as unknown as { id: string; audience: unknown }[];

  for (const row of due) {
    const audience = parseAudience(row.audience);
    if (!audience) {
      console.error(`[push] campaign ${row.id}: unreadable audience — marking failed`);
      await sql`
        UPDATE push_campaigns
        SET status = 'failed', last_error = 'This notification had no valid audience.'
        WHERE id = ${row.id}
      `;
      continue;
    }
    await sql`
      INSERT INTO push_deliveries (campaign_id, fid)
      SELECT ${row.id}, q.fid FROM (${audienceQuery(sql, audience)}) q
      ON CONFLICT DO NOTHING
    `;
    // An audience of zero phones is finished the moment it starts. Saying "Sent 0" honestly beats a
    // card that sits on "Sending" forever because nothing will ever drain it. That test is on EVERY
    // delivery; only `total` leaves test accounts out, like `sent` and `failed` below.
    const countedTotal = countsTestAccounts(audience)
      ? sql`SELECT count(*) FROM push_deliveries d WHERE d.campaign_id = c.id`
      : sql`
          SELECT count(*) FROM push_deliveries d
          LEFT JOIN push_devices pd ON pd.fid = d.fid
          LEFT JOIN users u ON u.id = pd.user_id
          WHERE d.campaign_id = c.id AND NOT coalesce(u.is_internal, false)
        `;
    const counted = (await sql`
      UPDATE push_campaigns c
      SET total = (${countedTotal}),
          status = CASE
            WHEN (SELECT count(*) FROM push_deliveries d WHERE d.campaign_id = c.id) = 0
            THEN 'sent' ELSE 'sending' END,
          sent_at = CASE
            WHEN (SELECT count(*) FROM push_deliveries d WHERE d.campaign_id = c.id) = 0
            THEN now() ELSE NULL END
      WHERE c.id = ${row.id}
      RETURNING total
    `) as unknown as { total: number }[];
    console.log(`[push] campaign ${row.id} started — ${counted[0]?.total ?? 0} phones`);
  }
  return due.length;
}

interface DrainResult {
  attempted: number;
  sent: number;
  failed: number;
  completed: boolean;
}

async function drainCampaign(
  sql: postgres.Sql,
  env: Env,
  campaign: PushCampaign & { last_error: string | null; audience?: unknown },
  deadline: number,
): Promise<DrainResult> {
  const out: DrainResult = { attempted: 0, sent: 0, failed: 0, completed: false };
  const countTestPhones = countsTestAccounts(parseAudience(campaign.audience));

  let accessToken: string;
  try {
    accessToken = await getFcmAccessToken(env);
  } catch (err) {
    // Leave it 'sending' and let the next tick retry: a token exchange fails for reasons that pass
    // (a Google blip, a key not yet installed), and burning the campaign on the first one is wrong.
    const failures = tokenFailureCount(campaign.last_error) + 1;
    const message =
      failures >= MAX_TOKEN_FAILURES
        ? "Could not reach Firebase to send. Check the notification key in the Worker's secrets."
        : `${TOKEN_FAILURE_PREFIX}${failures}: ${String(err)}`;
    await sql`
      UPDATE push_campaigns
      SET last_error = ${message},
          status = ${failures >= MAX_TOKEN_FAILURES ? "failed" : "sending"}
      WHERE id = ${campaign.id}
    `;
    console.error(`[push] campaign ${campaign.id}: no access token (attempt ${failures}):`, err);
    return out;
  }

  const deadFids: string[] = [];
  while (Date.now() < deadline) {
    const batch = await sendOneBatch(sql, env, campaign, accessToken, deadFids, countTestPhones);
    out.attempted += batch.attempted;
    out.sent += batch.sent;
    out.failed += batch.failed;
    if (batch.attempted === 0) break;
  }

  // Outside the batch transaction: dropping a registration is not part of the delivery's atomicity,
  // and holding the lock across it would stretch every batch for no gain.
  if (deadFids.length > 0) {
    await sql`DELETE FROM push_devices WHERE fid = ANY(${toPgTextArray(deadFids)}::text[])`;
    console.log(`[push] campaign ${campaign.id}: dropped ${deadFids.length} dead registrations`);
  }

  const remaining = (await sql`
    SELECT count(*)::int AS n FROM push_deliveries
    WHERE campaign_id = ${campaign.id} AND status IN ('pending', 'sending')
  `) as unknown as { n: number }[];
  if ((remaining[0]?.n ?? 0) === 0) {
    await sql`
      UPDATE push_campaigns SET status = 'sent', sent_at = now(), last_error = NULL
      WHERE id = ${campaign.id} AND status = 'sending'
    `;
    out.completed = true;
    console.log(`[push] campaign ${campaign.id} complete — sent ${out.sent}, failed ${out.failed}`);
  }
  return out;
}

const TOKEN_FAILURE_PREFIX = "token attempt ";

function tokenFailureCount(lastError: string | null): number {
  if (!lastError?.startsWith(TOKEN_FAILURE_PREFIX)) return 0;
  const n = parseInt(lastError.slice(TOKEN_FAILURE_PREFIX.length), 10);
  return Number.isFinite(n) ? n : 0;
}

/**
 * One claim-send-record batch, inside ONE transaction.
 *
 * The claim flips the rows to 'sending' as well as locking them, so the row state is legible to
 * anyone reading the table mid-drain; the lock is what makes a concurrent tick skip them.
 */
async function sendOneBatch(
  sql: postgres.Sql,
  env: Env,
  campaign: PushCampaign,
  accessToken: string,
  deadFids: string[],
  countTestPhones: boolean,
): Promise<{ attempted: number; sent: number; failed: number }> {
  return sql.begin(async (tx) => {
    const claimed = (await tx`
      SELECT fid FROM push_deliveries
      WHERE campaign_id = ${campaign.id} AND status = 'pending'
      LIMIT ${BATCH}
      FOR UPDATE SKIP LOCKED
    `) as unknown as { fid: string }[];
    if (claimed.length === 0) return { attempted: 0, sent: 0, failed: 0 };

    const fids = claimed.map((r) => r.fid);
    const devices = (await tx`
      SELECT d.fid, d.token, d.lang, d.app_build, coalesce(u.is_internal, false) AS internal
      FROM push_devices d LEFT JOIN users u ON u.id = d.user_id
      WHERE d.fid = ANY(${toPgTextArray(fids)}::text[])
    `) as unknown as (PushDevice & { internal?: boolean })[];
    const byFid = new Map(devices.map((d) => [d.fid, d]));
    // A row whose device is gone cannot say whose it was, so it counts: it is a real failure.
    const counts = (fid: string) => countTestPhones || !byFid.get(fid)?.internal;

    const sentFids: string[] = [];
    const failures: { fid: string; error: string }[] = [];

    await forEachWithConcurrency(fids, CONCURRENCY, async (fid) => {
      const device = byFid.get(fid);
      if (!device) {
        // The row outlived its device: a reinstall re-pointed the FID, or the 270-day sweep took it.
        failures.push({ fid, error: "device_gone" });
        return;
      }
      const res = await sendPush(env, accessToken, device, campaign);
      if (res.ok) {
        sentFids.push(fid);
        return;
      }
      failures.push({ fid, error: `${res.code}: ${res.message}`.slice(0, 300) });
      if (isDeadRegistration(res)) deadFids.push(fid);
    });

    if (sentFids.length > 0) {
      await tx`
        UPDATE push_deliveries SET status = 'sent', sent_at = now(), error = NULL
        WHERE campaign_id = ${campaign.id} AND fid = ANY(${toPgTextArray(sentFids)}::text[])
      `;
    }
    for (const f of failures) {
      await tx`
        UPDATE push_deliveries SET status = 'failed', error = ${f.error}
        WHERE campaign_id = ${campaign.id} AND fid = ${f.fid}
      `;
    }
    // One counter write per batch, not per row: the CMS card reads these two numbers every 5 s while
    // a campaign is sending, and they only have to be right at batch granularity.
    const sentCount = sentFids.filter(counts).length;
    const failedCount = failures.filter((f) => counts(f.fid)).length;
    await tx`
      UPDATE push_campaigns
      SET sent = sent + ${sentCount}, failed = failed + ${failedCount}
      WHERE id = ${campaign.id}
    `;
    return { attempted: fids.length, sent: sentFids.length, failed: failures.length };
  }) as Promise<{ attempted: number; sent: number; failed: number }>;
}

/** Bounded fan-out — `Promise.all` over 600 sends would open 600 sockets at once. */
async function forEachWithConcurrency<T>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++]!;
      await fn(item);
    }
  });
  await Promise.all(workers);
}

/**
 * Send a campaign's texts to the owner's own phones WITHOUT touching its counters or status.
 *
 * The "Send to my phone" button, and the one path that ignores PUSH_ENABLED: the whole point of the
 * switch is that the owner can prove the chain on their own phones while production stays dark.
 */
export async function runPushTest(
  env: Env,
  campaign: PushCampaign,
): Promise<{ sent: number; failed: number; errors: string[] }> {
  const sql = getDb(env);
  try {
    const devices = (await sql`
      SELECT d.fid, d.token, d.lang, d.app_build
      FROM push_devices d JOIN users u ON u.id = d.user_id
      WHERE u.is_internal AND NOT coalesce(u.email ILIKE '%@cloudtestlabaccounts.com', false)
    `) as unknown as PushDevice[];
    if (devices.length === 0) {
      return { sent: 0, failed: 0, errors: ["No test phone has opened the app yet."] };
    }
    const accessToken = await getFcmAccessToken(env);
    let sent = 0;
    let failed = 0;
    const errors: string[] = [];
    await forEachWithConcurrency(devices, CONCURRENCY, async (device) => {
      const res = await sendPush(env, accessToken, device, campaign);
      if (res.ok) {
        sent += 1;
      } else {
        failed += 1;
        errors.push(`${res.code}: ${res.message}`);
      }
    });
    return { sent, failed, errors };
  } finally {
    await sql.end().catch(() => {});
  }
}

/**
 * Daily retention, run from the 21:30 UTC cron.
 *
 * 270 days on a device is Firebase's own number: FCM garbage-collects an Android registration after
 * 270 days of inactivity, so a row older than that cannot be sent to and only inflates every count
 * the CMS shows. Deliveries are kept 30 days — long enough to explain a campaign, short enough that
 * the table does not grow without bound at tens of thousands of rows per send.
 */
export async function sweepPush(
  env: Env,
): Promise<{ deliveries: number; devices: number; images: number }> {
  const sql = getDb(env);
  try {
    const deliveries = (await sql`
      DELETE FROM push_deliveries d
      USING push_campaigns c
      WHERE d.campaign_id = c.id AND c.created_at < now() - interval '30 days'
      RETURNING d.fid
    `) as unknown as unknown[];
    const devices = (await sql`
      DELETE FROM push_devices WHERE last_seen_at < now() - interval '270 days' RETURNING fid
    `) as unknown as unknown[];
    const images = await sweepPushImages(sql, env);
    return { deliveries: deliveries.length, devices: devices.length, images };
  } finally {
    await sql.end().catch(() => {});
  }
}

/** `push/` objects are older than this before they are eligible — a composer draft is not an orphan. */
const IMAGE_GRACE_MS = 90 * 24 * 60 * 60 * 1000;

/**
 * Reclaim uploaded campaign pictures nothing references any more.
 *
 * `push/` sits OUTSIDE `CANONICAL_PREFIXES`, so the canonical sweep can never see these objects — it
 * would read "no wallpaper row references it" as "delete it" on every pass. This is their only
 * cleanup, and it is deliberately timid: only an object older than 90 days whose campaign row is gone.
 * Nothing here may abort on an empty reference set the way sweep-canonical must, because an Arul with
 * no campaigns genuinely references no pictures.
 */
async function sweepPushImages(sql: postgres.Sql, env: Env): Promise<number> {
  const referenced = new Set(
    (
      (await sql`
        SELECT image_url FROM push_campaigns WHERE image_url IS NOT NULL
      `) as unknown as { image_url: string }[]
    ).map((r) => r.image_url.split("/").pop() ?? ""),
  );

  const cutoff = Date.now() - IMAGE_GRACE_MS;
  const doomed: string[] = [];
  let cursor: string | undefined;
  do {
    const opts: R2ListOptions = { prefix: "push/", limit: 1000 };
    if (cursor) opts.cursor = cursor;
    const listed = await env.R2.list(opts);
    for (const o of listed.objects) {
      if (o.uploaded.getTime() >= cutoff) continue;
      if (referenced.has(o.key.split("/").pop() ?? "")) continue;
      doomed.push(o.key);
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);

  if (doomed.length > 0) await env.R2.delete(doomed);
  return doomed.length;
}
