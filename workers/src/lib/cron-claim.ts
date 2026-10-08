/**
 * Cloudflare delivers a cron tick at least once: two colos at once, or again after a killed run, each with its own
 * `scheduledTime` up to ~1 min apart. A trigger that must not run twice claims its slot in Neon (KV is not consistent
 * across colos, Hyperdrive has no advisory locks) -> docs/cron.md
 */

import type { Env } from "../env.js";
import { getDb } from "./db.js";

const MINUTE_MS = 60 * 1000;

/** Period per guarded trigger -> the slot is the scheduled time FLOORED to it, never rounded (offsets run to ~58 s) */
const SLOT_MS: Record<string, number> = {
  "*/15 * * * *": 15 * MINUTE_MS,
  "0 * * * *": 60 * MINUTE_MS,
  "30 21 * * *": 24 * 60 * MINUTE_MS,
};

export function slotFor(cron: string, scheduledTime: number): Date | null {
  const period = SLOT_MS[cron];
  if (period === undefined) return null;
  return new Date(Math.floor(scheduledTime / period) * period);
}

/**
 * true = this delivery owns the slot and runs. Fails OPEN on any error -> a claim must never stop billing or
 * publishing, and every guarded job is idempotent underneath (docs/cron.md)
 */
export async function claimCronSlot(env: Env, cron: string, scheduledTime: number): Promise<boolean> {
  const slot = slotFor(cron, scheduledTime);
  if (slot === null) return true;
  const sql = getDb(env);
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const rows = await sql`
          INSERT INTO cron_runs (cron, slot)
          VALUES (${cron}, ${slot.toISOString()})
          ON CONFLICT (cron, slot) DO NOTHING
          RETURNING slot
        `;
        if (rows.length === 0) {
          console.log(`[cron] ${cron} slot ${slot.toISOString()} already claimed — skipping this delivery`);
          return false;
        }
        return true;
      } catch (err) {
        if (attempt === 0) {
          console.warn(`[cron] ${cron} slot claim failed — retrying once on a fresh connection:`, err);
        } else {
          console.error(`[cron] ${cron} slot claim failed twice — running unclaimed:`, err);
        }
      }
    }
    return true;
  } finally {
    await sql.end().catch(() => {});
  }
}

export async function pruneCronRuns(env: Env): Promise<number> {
  const sql = getDb(env);
  try {
    const rows = await sql`
      DELETE FROM cron_runs
      WHERE slot < now() - interval '7 days'
      RETURNING slot
    `;
    return rows.length;
  } finally {
    await sql.end().catch(() => {});
  }
}
