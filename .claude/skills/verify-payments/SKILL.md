---
name: verify-payments
description: Verify the PhonePe Autopay billing path end-to-end without spending real money — mandate setup, notify, the ₹199 debit, renewal, failure/dunning and the referral reward. Use when changing anything under workers/src/routes/payments.ts, workers/src/cron/autopay-notify.ts, workers/src/lib/phonepe.ts, or before a release that touches subscriptions.
---

# Verify PhonePe payments without spending money

Exercising billing normally means real ₹199 debits on the live gateway. **PhonePe UAT accepts the
whole protocol** — OAuth, setup, status, `notify`, `redeem` all work against `api-preprod.phonepe.com`
with the Test credentials, and mandates auto-activate — but **UAT will not settle a redemption**: it
holds them `PENDING` with no way to force a terminal state, so `COMPLETED` and `FAILED`, the only
branches that change entitlement, need a local stub. Report which half proved what; "verified"
without that split is worthless. Stub modes, referral check, device walkthrough, the idle marker —
all in [reference.md](reference.md).

## Safety rules — read before running

- **Never point the harness at Neon.** It seeds rows with a past `next_debit_at`; against production
  the deployed hourly cron picks those up and fires real PhonePe calls. `sbx.mjs` hard-refuses any
  host matching `neon.tech`.
- **Check `workers/.dev.vars` before every run** (back it up before editing). It must hold
  `PHONEPE_ENV=SANDBOX` and the **Test** client id — the merchant-name form `AUTOGRAMAPPSONLINE_…`
  (Arul shares the HSR merchant with Pakiza; the `DKS_` prefix keeps the order streams distinct). The
  **Live** id is the `SU…` form, lives only in `wrangler secret`, and seeing it here means stop.
- **`PHONEPE_BASE_URL_OVERRIDE` is ignored when `PHONEPE_ENV=PRODUCTION`** — `getPgBase` returns the
  production host before reading it; `workers/test/phonepe-base.test.ts` pins that behaviour.
- **Never call `POST /internal/run-redemptions` against prod.** `force:true` charges every due
  subscriber ₹199 immediately. It takes `OPS_SECRET`, not `CATALOG_BUILD_SECRET`; local only.

## Run — every `node *.mjs` from `.claude/skills/verify-payments/scripts`

`npm i` there once (pglite, pglite-socket, postgres, jose). Paths written `workers/…` are repo-root.

### 1. Isolated Postgres with the production schema

```bash
node pgserver.mjs   # → 127.0.0.1:5433, schema from db/schema/*.sql (01→04); loads only
                    # into a fresh ./pgdata, so --reset is the only way to pick up a change
```

### 2. Point wrangler dev at it

The connection string must be a **real process env var** — wrangler does not read it from
`.dev.vars`, and it wants the `CLOUDFLARE_` prefix, not the `WRANGLER_` one that file still carries:

```bash
cd workers
CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="postgresql://postgres:postgres@127.0.0.1:5433/postgres" \
  npx wrangler dev --test-scheduled --port 8787
```

Only ONE instance may hold 8787. Missing cron output means a second listener
(`netstat -ano | grep :8787`) is silently serving your requests with the old config.

### 3. Create a real UAT mandate

```bash
node sbx.mjs seed-user
TOK=$(node sbx.mjs token)
curl -s -X POST http://127.0.0.1:8787/payments/initiate \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{"plan":"monthly"}'
```

Expect `trialEligible:true`, `amountPaise:200`, `environment:"SANDBOX"`. A second concurrent initiate
must return 409 `setup_in_progress` — deliberately distinct from 409 `already_subscribed`, which the
app treats as success. UAT returns the mandate `ACTIVE` at once; only a real UPI instrument behind it
needs the device walkthrough in reference.md.

### 4. Drive the cron

```bash
# --test-scheduled exposes the real scheduled handler
node sbx.mjs due <merchantSubscriptionId>
curl -s "http://127.0.0.1:8787/__scheduled?cron=0+*+*+*+*"
node sbx.mjs subs
```

Against UAT this proves notify and redeem **for real**: `Notified … state=NOTIFICATION_IN_PROGRESS`,
`Execute … state=PENDING`, and the redemption order carries `amount: 19900`. A KV marker
(`autopay:next_work_at`) then short-circuits every later run — clear it between scenarios exactly as
reference.md shows.

### 5. Terminal states via the stub

```bash
node ppstub.mjs &                 # 127.0.0.1:8799, re-reads mode.txt per request
echo "PHONEPE_BASE_URL_OVERRIDE=http://127.0.0.1:8799" >> workers/.dev.vars
# RESTART wrangler dev — it does not hot-reload .dev.vars
echo COMPLETED > mode.txt         # switch outcome without restarting the stub
```

## Teardown

```bash
cp <backup> workers/.dev.vars       # drops PHONEPE_BASE_URL_OVERRIDE, restores the Neon string
adb shell pm enable com.phonepe.app # only if you disabled it
adb reverse --remove tcp:8787
```

Then `cd workers && npx tsc --noEmit && npx vitest run`. Already proven: `docs/billing-verified.md`.
