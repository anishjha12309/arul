---
name: verify-payments
description: Verify the PhonePe Autopay billing path end-to-end without spending real money — mandate setup, notify, the ₹199 debit, renewal, failure/dunning and the referral reward. Use when changing anything under workers/src/routes/payments.ts, workers/src/cron/autopay-notify.ts, workers/src/lib/phonepe.ts, or before a release that touches subscriptions.
---

# Verify PhonePe payments without spending money

## Why this exists

The billing path is the least-tested and most expensive-to-get-wrong code in the
app, because exercising it normally means real ₹199 debits on the live gateway.
Two things make free verification possible:

1. **PhonePe UAT accepts the whole protocol.** OAuth, mandate setup, mandate
   status, `notify` and `redeem` all work against `api-preprod.phonepe.com` with
   the **Test** credentials. UAT even auto-activates mandates.
2. **UAT will not settle a redemption.** It holds redemptions `PENDING` through
   its own retry cycle with no way to force a terminal state. So the branches
   that actually change a user's entitlement — `COMPLETED` and `FAILED` — are
   unreachable against UAT alone.

So the harness is split: **the PhonePe protocol is proven live against UAT**, and
**our own terminal-state handling is proven against a local stub**. Be explicit
about which half proved what when reporting results.

## Safety rules — read before running

- **Never point the harness at Neon.** It seeds rows with a past `next_debit_at`.
  In production the deployed hourly cron would pick those up and fire real
  PhonePe calls. `scripts/sbx.mjs` hard-refuses any host matching `neon.tech`.
- **Check `PHONEPE_ENV` and the client id before every run.** `workers/.dev.vars`
  must hold `PHONEPE_ENV=SANDBOX` and the **Test** client id (merchant-name form,
  e.g. `AUTOGRAMAPPSONLINE_26051` if Arul shares the HSR merchant — verify in the
  PhonePe business dashboard). The **Live** client id is the `SU…` form and
  exists only in `wrangler secret`. If you ever see an `SU…` id in `.dev.vars`,
  stop.
- **`PHONEPE_BASE_URL_OVERRIDE` is ignored when `PHONEPE_ENV=PRODUCTION`** — the
  production host is returned before the var is read (`getPgBase`). That property
  is covered by `workers/test/phonepe-base.test.ts`; do not weaken it.
- Back up `workers/.dev.vars` before editing and restore it afterwards.

## One-time setup

```bash
cd .claude/skills/verify-payments/scripts
npm init -y && npm i @electric-sql/pglite @electric-sql/pglite-socket postgres jose
```

## Run

### 1. Isolated Postgres with the production schema

```bash
node scripts/pgserver.mjs          # add --reset to wipe
# [pg] schema loaded: (db/schema/01→04 — expect app_config, content_submissions,
#      referrals, ringtones, subscriptions, trial_tombstones, users, wallpapers)
# [pg] listening on 127.0.0.1:5433
```

### 2. Point wrangler dev at it

The connection string must be a **real process env var** — wrangler does *not*
read it from `.dev.vars`, and it wants the `CLOUDFLARE_` prefix, not `WRANGLER_`:

```bash
cd workers
CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="postgresql://postgres:postgres@127.0.0.1:5433/postgres" \
  npx wrangler dev --test-scheduled --port 8787
```

Only ONE instance may hold 8787. If cron output goes missing, check for a
second listener (`netstat -ano | grep :8787`) — a stale process will silently
serve your requests with the old config.

### 3. Create a real UAT mandate

```bash
node scripts/sbx.mjs seed-user
TOK=$(node scripts/sbx.mjs token)
curl -s -X POST http://127.0.0.1:8787/payments/initiate \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"plan":"monthly"}'
```

Expect `trialEligible:true`, `amountPaise:200`, `environment:"SANDBOX"`. UAT
returns the mandate as `ACTIVE` immediately — no device needed for the cron
tests below.

**Only if you need an intent-backed mandate** (a real UPI instrument behind it),
do the setup through the app — see "On-device mandate" at the end.

### 4. Drive the cron

`--test-scheduled` exposes the real scheduled handler:

```bash
node scripts/sbx.mjs due <merchantSubscriptionId>
curl -s "http://127.0.0.1:8787/__scheduled?cron=0+*+*+*+*"
node scripts/sbx.mjs subs
```

Against UAT this proves **notify and redeem for real**: the log shows
`Notified … state=NOTIFICATION_IN_PROGRESS` and `Execute … state=PENDING`, and
the redemption order at PhonePe carries `amount: 19900` (= ₹199).

### 5. Terminal states via the stub

```bash
node scripts/ppstub.mjs &                 # 127.0.0.1:8799
echo "PHONEPE_BASE_URL_OVERRIDE=http://127.0.0.1:8799" >> workers/.dev.vars
# RESTART wrangler dev — it does not hot-reload .dev.vars
```

Switch outcomes without restarting the stub: `echo FAILED > scripts/mode.txt`.

| mode | expected result |
| --- | --- |
| `COMPLETED` | `status='active'`, `current_period_end` and `next_debit_at` +1 month, `notified_at` + `redemption_order_id` cleared, `retry_count=0`, referral rewarded |
| `FAILED` | `retry_count` +1 and `notified_at` cleared so Pass A re-notifies; at `MAX_RETRIES` (5) `status='expired'` and the row stops being picked up |
| `PENDING` | nothing changes — no premium granted on an unsettled debit |

Referral (grant once, never on renewal):

```bash
node scripts/sbx.mjs referral
node scripts/sbx.mjs rewards      # before
# ... run a COMPLETED debit ...
node scripts/sbx.mjs rewards      # rewarded, reward_days=30, +30d
# ... run a SECOND COMPLETED debit — reward_premium_until must NOT move ...
```

### The idle marker will block repeat runs

After a successful debit the cron caches `autopay:next_work_at` in KV and then
short-circuits every later run with `Nothing due before <date> — skipping DB`.
Clear it between scenarios — and note it must target the **preview** namespace,
which is what `wrangler dev` binds:

```bash
yes | npx wrangler kv key delete --binding KV --local --preview "autopay:next_work_at"
```

Deleting with `--preview false` silently hits the *other* local namespace and
appears to succeed while changing nothing.

## Teardown

```bash
cp <backup> workers/.dev.vars       # removes PHONEPE_BASE_URL_OVERRIDE + restores Neon string
adb shell pm enable com.phonepe.app # only if you disabled it
adb reverse --remove tcp:8787
```
Then `npx tsc --noEmit && npx vitest run`.

## On-device mandate (only when you need a real UPI instrument)

A mandate created by `/payments/initiate` alone is `ACTIVE` but has no payer
behind it, so its redemption falls back to a `UPI_QR` nobody pays. To authorize
one properly:

1. `adb reverse tcp:8787 tcp:8787`
2. Build with `API_BASE_URL=http://127.0.0.1:8787` (copy `env/dev.json` to
   `env/sbx.json` and change that one key). The debug-only
   `android/app/src/debug/res/xml/network_security_config.xml` permits cleartext
   to loopback **in debug builds only** — release still forbids all cleartext.
3. `flutter run --dart-define-from-file=env/sbx.json`
4. Sign in (creates the user row), Premium → Start Free Trial.
5. **Disable the real PhonePe app first** — it grabs the UPI intent and fails,
   since it cannot process a sandbox order:
   `adb shell pm disable-user --user 0 com.phonepe.app`
   Then choose **Apps & UPI QR → Other UPI Apps → PhonePe Simulator**, pick a
   Test Bank, and enter any 4-digit PIN.
   **Re-enable it afterwards:** `adb shell pm enable com.phonepe.app`

The simulator's *Test Case Templates → Subscription V2* screen shows which UAT
behaviour the merchant is configured for. It should read
*"Setup, notify & redemption success with PhonePe retries auto debit false"* —
which matches our `redemptionRetryStrategy:"STANDARD"` + `autoDebit:false`.

## Known-good baseline (reference app, verified 2026-07-25)

In the REFERENCE app (Pakiza), live against UAT: OAuth, mandate setup with
correct ₹2/₹199 branching, mandate status, notify, redeem creating a
**19900-paise** order, and PENDING correctly granting nothing. Via stub:
COMPLETED → active +1 month; FAILED → retries 1–4 then expiry at 5; referral
granted once and idempotent on renewal. Arul has NO baseline of its own yet —
recording one is the point of the first run.
