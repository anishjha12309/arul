---
name: verify-payments
description: Answer "are payments working?" against live production in one read-only command, or prove a billing change without spending real money. Use when money looks wrong, before a release touching subscriptions, or when changing payments or autopay-notify.
---

# Verify PhonePe payments

Two different questions live here. Pick the one you are actually asking — they share almost nothing.

| Question | Mode | Cost |
| --- | --- | --- |
| Is production healthy **right now**? | [A — production read](#mode-a--production-read) | seconds, read-only |
| Will this change break billing? | [B — sandbox harness](#mode-b--sandbox-harness) | ~30 min, local |

Never answer the first with the second. A green sandbox run says nothing about whether money moved
last night, and it is the question that gets asked when a payer complains.

## Mode A — production read

```bash
cd workers && node tools/payments-health.mjs        # exit 0 = healthy, 1 = needs a human
```

One screen, four independent signals, a verdict and an exit code. **Read the `[db]` banner first** —
it names the branch, and the whole report is worthless against the wrong one (see Traps).

- **CRON** — when the quarter-hour autopay scan last notified and wrote. A dead cron looks perfectly
  healthy in a revenue chart for a day.
- **MONEY** — first debits in 24 h and 7 d, renewals, lifetime collected, and a whole-day series with
  a same-hour column so a partial day is readable. **The daily count is printed, never alarmed on**:
  that series is statistically indistinguishable from a coin flip, so one low day means nothing.
- **BACKLOG** — WAITING / IN FLIGHT / STUCK. Only STUCK is a fault; the other two are vendor clocks
  still running. Boundaries and their derivation: `workers/tools/lib/debit-phases.mjs`.
- **POPULATION** — status counts.

It fails on exactly two things, both unambiguous: a row STUCK past PhonePe's 72 h settle deadline, and
zero settles in 24 h **while debits were due** (the starvation signature that once cost 30+ hours of
conversions). Everything else is printed, not alarmed on — an alarm that fires before the vendor has
broken a promise trains everyone to ignore the one that matters.

On a STUCK verdict: `node tools/verify-debits.mjs` lists the rows. A row there **may already have been
debited** — read its order state before touching it, and never re-notify a paid order
([autopay-debits.md](../../../docs/autopay-debits.md)).

### Cross-checking the gateway

Neon looking busy does not prove PhonePe still accepts our credentials. `--phonepe <envfile>` verifies
OAuth, then reads the newest settled row back from PhonePe and flags any disagreement with Neon.

**The live credentials are NOT in `.dev.vars`** — that file holds the SANDBOX set, correct for local
dev. They live only in `wrangler secret`, so a production probe must be handed them. The live client
id is the `SU…` form; the Test id is the merchant-name form `AUTOGRAMAPPSONLINE_…`.

```bash
cat > "$TMPDIR/pp.env" <<'EOF'                      # a scratchpad path, never the repo
PP_ENV=PRODUCTION
PP_CLIENT_ID=…
PP_CLIENT_SECRET=…
PP_CLIENT_VERSION=1
EOF
cd workers && node tools/payments-health.mjs --phonepe "$TMPDIR/pp.env"
rm "$TMPDIR/pp.env"                                 # delete it in the same session
```

**Credentials never go on the command line** — a shell records argv in its history and it lands in any
transcript. That is the only reason the env-file form exists. To probe specific subscriptions instead:

```bash
node tools/phonepe-status.mjs --env-file <path> <merchantSubscriptionId>[,<merchantOrderId>] …
```

Both read GET status only. Nothing under `tools/lib/phonepe-read.mjs` may ever gain notify, redeem or
cancel — a helper that can move money is one typo from charging every subscriber.

The other read-only tools: [reference.md](reference.md) §Production tools.

## Mode B — sandbox harness

Exercising billing normally means real ₹199 debits. **PhonePe UAT accepts the whole protocol** —
OAuth, setup, status, `notify`, `redeem` — against `api-preprod.phonepe.com` with the Test
credentials. UAT *can* settle a redemption, but only behind a simulator-backed mandate and only along
the Test-Case Template the merchant is configured for; a mandate from `/payments/initiate` alone has
no payer, so its redemption never terminates. Forcing `COMPLETED` and `FAILED` on demand — the two
outcomes that change entitlement — is what the local stub is for. Report which half proved what;
"verified" without that split is worthless. Stub modes, referral, device walkthrough, idle marker:
[reference.md](reference.md).

### Safety rules — read before running

- **Never point the harness at Neon.** It seeds rows with a past `next_debit_at`; against production
  the deployed cron picks those up and fires real PhonePe calls. `sbx.mjs` hard-refuses any host
  matching `neon.tech`.
- **Check `workers/.dev.vars` before every run** (back it up before editing). It must hold
  `PHONEPE_ENV=SANDBOX` and the **Test** client id — the merchant-name form `AUTOGRAMAPPSONLINE_…`
  (Arul shares the HSR merchant with Pakiza; the `DKS_` prefix keeps the order streams distinct).
  **Anything that is not that form is not the Test id: stop.**
- **`PHONEPE_BASE_URL_OVERRIDE` is ignored when `PHONEPE_ENV=PRODUCTION`** — `getPgBase` returns the
  production host before reading it; `workers/test/phonepe-base.test.ts` pins that behaviour.
- **Never call `POST /internal/run-redemptions` against prod with `force:true` or without
  `merchantSubscriptionId`.** Unscoped `force` drops the due filter and charges every
  `trialing`/`active` subscriber ₹199, `LIMIT 50`. Scoped to one `merchantSubscriptionId` you own, it
  is the same one-row operation the harness does locally — still a real debit, never a dry run. It
  takes `OPS_SECRET`, not `CATALOG_BUILD_SECRET`. This is discipline, not enforcement: the route is
  deployed and `OPS_SECRET` is set in prod, so only that string stands between a curl and a debit.

### Run — every `node *.mjs` from `.claude/skills/verify-payments/scripts`

`npm i` there once (pglite, pglite-socket, postgres, jose). Paths written `workers/…` are repo-root.

**1. Isolated Postgres with the production schema**

```bash
node pgserver.mjs   # → 127.0.0.1:5433, schema from db/schema/*.sql in filename order; loads only
                    # into a fresh ./pgdata, so --reset is the only way to pick up a change
```

**2. Point wrangler dev at it.** The connection string must be a **real process env var** — wrangler
does not read it from `.dev.vars`, and it wants the `CLOUDFLARE_` prefix, not the `WRANGLER_` one that
file still carries:

```bash
cd workers
CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="postgresql://postgres:postgres@127.0.0.1:5433/postgres" \
  npx wrangler dev --test-scheduled --port 8787
```

Only ONE instance may hold 8787. Missing cron output means a second listener
(`netstat -ano | grep :8787`) is silently serving your requests with the old config.

**3. Create a real UAT mandate**

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

**4. Drive the cron.** Autopay owns the **quarter-hour** trigger alone — `0 * * * *` is the catalog
rebuild and runs no billing at all, so the expression must be the autopay one or nothing happens:

```bash
node sbx.mjs due <merchantSubscriptionId>
curl -s "http://127.0.0.1:8787/__scheduled?cron=*%2F15+*+*+*+*"
node sbx.mjs subs
```

Confirm it fired by the log line `[cron] Running quarter-hour autopay scan`. No line = the expression
did not match and nothing ran.

Against UAT this proves notify and redeem **for real**: `Notified … state=NOTIFICATION_IN_PROGRESS`,
`Execute … state=PENDING`, and the redemption order carries `amount: 19900`. A PENDING redeem is NOT
the end — the row keeps `notified_at`, so every later `/__scheduled` re-executes it and logs
`Execute PENDING … waiting for STANDARD retry` (Pass C reconciles once it is 2 h overdue). Only a
**settled** debit writes the KV idle marker `autopay:next_work_at`, which then short-circuits later
runs — clear it between scenarios ([reference.md](reference.md) §idle marker).

**5. Terminal states via the stub**

```bash
node ppstub.mjs &                 # 127.0.0.1:8799, re-reads mode.txt per request
echo "PHONEPE_BASE_URL_OVERRIDE=http://127.0.0.1:8799" >> workers/.dev.vars
# RESTART wrangler dev — it does not hot-reload .dev.vars
echo COMPLETED > mode.txt         # switch outcome without restarting the stub
```

Teardown, and the checks to run afterwards: [reference.md](reference.md) §Teardown.

## Traps

- **A read-only report against the wrong database is indistinguishable from a correct one.**
  `.dev.vars` holds four postgres strings and the Hyperdrive ones sit *above* `DATABASE_URL`, so a
  tool taking "the first `postgres://` in the file" reads the **debug** branch. `verify-debits.mjs`
  did that and cried 209 STUCK while production had zero — and would as silently have said HEALTHY
  through a real outage. Tools now select by name via `tools/lib/neon-branch.mjs` and print the
  branch. **If a payments tool does not name its branch, do not trust it.**
- Endpoint facts, the exact-string-compare on `PHONEPE_ENV`, the cached OAuth token that survives an
  env flip, and the traps that return 200 while broken: [phonepe.md](../../../docs/phonepe.md).
