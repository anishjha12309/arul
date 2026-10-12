/**
 * The order-outcome log (db/schema/36_order_outcomes.sql, docs/order-outcomes.md): what PhonePe said
 * about each renewal order, kept after the row's redemption_order_id moves on. Diagnosis only -> no billing path reads it
 */

import type { Env } from "../env.js";
import { getDb } from "./db.js";

type Sql = ReturnType<typeof getDb>;

/** The owner's retention: a row is kept 12 months, then the daily cron deletes it. */
export async function pruneOrderOutcomes(env: Env): Promise<number> {
  const sql = getDb(env);
  try {
    const rows = await sql`
      DELETE FROM order_outcomes
      WHERE observed_at < now() - interval '12 months'
      RETURNING id
    `;
    return rows.length;
  } finally {
    await sql.end().catch(() => {});
  }
}

export type OrderEvent =
  | "minted"
  | "redeem_accepted"
  | "redeem_rejected"
  | "reconciled"
  | "recycled"
  | "closed";

export interface OrderOutcomeInput {
  event: OrderEvent;
  observedBy: string;
  merchantOrderId: unknown;
  userId: unknown;
  mandateId?: unknown;
  amountPaise?: unknown;
  retryRung?: unknown;
  /** Epoch ms, a Date or an ISO string. */
  expireAt?: unknown;
  phonepeState?: unknown;
  mandateState?: unknown;
  /** A PhonePe order-status body: its state, codes, errorContext and last attempt time are read from it. */
  order?: unknown;
  /** A failed PhonePe call: its HTTP status and the `code`/`message` in its body. */
  error?: unknown;
}

/** Never rejects or throws: a lost diagnosis row must never become a lost debit. */
export async function recordOrderOutcome(sql: Sql, input: OrderOutcomeInput): Promise<void> {
  try {
    // Every bind is coerced to string | number | null: postgres.js throws on undefined
    const orderId = text(input.merchantOrderId, 63);
    const userId = text(input.userId, 36);
    if (orderId === null || userId === null) return;

    const order = isRecord(input.order) ? input.order : null;
    const context = order && isRecord(order.errorContext) ? order.errorContext : null;
    const error = apiError(input.error);

    const row = {
      mandateId: text(input.mandateId, 63),
      phonepeState: text(input.phonepeState ?? order?.state, 40),
      errorCode: text(context?.errorCode ?? order?.errorCode ?? error.code, 100),
      detailedErrorCode: text(context?.detailedErrorCode ?? order?.detailedErrorCode, 100),
      errorSource: text(context?.source, 40),
      errorStage: text(context?.stage, 40),
      errorDescription: text(context?.description ?? error.message, 300),
      mandateState: text(input.mandateState, 40),
      httpStatus: int(error.status),
      amountPaise: int(input.amountPaise ?? order?.amount),
      retryRung: int(input.retryRung),
      expireAt: iso(input.expireAt ?? order?.expireAt),
      occurredAt: iso(lastAttemptAt(order)),
    };

    await sql`
      INSERT INTO order_outcomes (
        merchant_order_id, mandate_id, user_id, event, phonepe_state, error_code, detailed_error_code,
        error_source, error_stage, error_description, mandate_state, http_status, amount_paise, retry_rung,
        expire_at, occurred_at, observed_by
      ) VALUES (
        ${orderId}, ${row.mandateId}, ${userId}, ${input.event}, ${row.phonepeState}, ${row.errorCode},
        ${row.detailedErrorCode}, ${row.errorSource}, ${row.errorStage}, ${row.errorDescription}, ${row.mandateState},
        ${row.httpStatus}, ${row.amountPaise}, ${row.retryRung}, ${row.expireAt}, ${row.occurredAt},
        ${text(input.observedBy, 40) ?? "unknown"}
      )
      ON CONFLICT DO NOTHING
    `;
  } catch (err) {
    console.warn(`[order-outcomes] ${String(input?.event)} not recorded:`, err);
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function text(v: unknown, max: number): string | null {
  if (typeof v === "number" && Number.isFinite(v)) return String(v).slice(0, max);
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t === "" ? null : t.slice(0, max);
}

function int(v: unknown): number | null {
  if (v === null || v === undefined || v === "" || typeof v === "boolean") return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

function iso(v: unknown): string | null {
  let d: Date | null = null;
  if (v instanceof Date) d = v;
  else if (typeof v === "number" && Number.isFinite(v) && v > 0) d = new Date(v);
  else if (typeof v === "string" && v.trim() !== "") d = new Date(v);
  return d !== null && !Number.isNaN(d.getTime()) ? d.toISOString() : null;
}

// The newest attempt's timestamp; null when PhonePe never attempted (a skipped debit)
function lastAttemptAt(order: Record<string, unknown> | null): number | null {
  const attempts = order?.paymentDetails;
  if (!Array.isArray(attempts)) return null;
  let latest: number | null = null;
  for (const a of attempts) {
    const t = isRecord(a) ? Number(a.timestamp) : Number.NaN;
    if (Number.isFinite(t) && t > 0 && (latest === null || t > latest)) latest = t;
  }
  return latest;
}

// PhonePe's 4xx body is `{ code, message }` JSON; anything else keeps only the status
function apiError(err: unknown): { status: unknown; code: unknown; message: unknown } {
  if (!isRecord(err) && !(err instanceof Error)) return { status: null, code: null, message: null };
  const e = err as { status?: unknown; body?: unknown };
  let parsed: Record<string, unknown> | null = null;
  if (typeof e.body === "string") {
    try {
      const j: unknown = JSON.parse(e.body);
      parsed = isRecord(j) ? j : null;
    } catch {
      parsed = null;
    }
  }
  return { status: e.status ?? null, code: parsed?.code ?? null, message: parsed?.message ?? null };
}
