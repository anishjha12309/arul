# verify-payments — reference

Lookup tables for a run already in progress. The procedure is in [SKILL.md](SKILL.md).

## Stub modes → expected row state

`ppstub.mjs` reads `scripts/mode.txt` on every request, so switch outcomes mid-run with
`echo <MODE> > mode.txt` — no restart.

| mode | expected result on the `subscriptions` row |
| --- | --- |
| `COMPLETED` | `status='active'`; `current_period_end` and `next_debit_at` +1 month; `notified_at` and `redemption_order_id` cleared; `retry_count=0`; referral rewarded |
| `FAILED` | `retry_count` +1 and `notified_at` cleared so Pass A re-notifies; at `MAX_RETRIES` (5) `status='expired'` and the row stops being picked up |
| `PENDING` | nothing changes — an unsettled debit must never grant premium |

## The idle marker blocks repeat runs

After a successful debit the cron caches `autopay:next_work_at` in KV and short-circuits every later
run with `Nothing due before <date> — skipping DB`. Clear it between scenarios, targeting the
**preview** namespace — that is what `wrangler dev` binds. `--preview false` hits the *other* local
namespace: it reports success and changes nothing.

```bash
yes | npx wrangler kv key delete --binding KV --local --preview "autopay:next_work_at"
```

## Referral — granted once, never on renewal

```bash
node sbx.mjs referral
node sbx.mjs rewards      # baseline
# run a COMPLETED debit
node sbx.mjs rewards      # rewarded, reward_days=30, reward_premium_until +30d
# run a SECOND COMPLETED debit — reward_premium_until must NOT move
```

The reward lives on `users.reward_premium_until`, decoupled from the subscription row, so a later
cancellation does not claw it back.

## On-device mandate — only when you need a real UPI instrument

A mandate created by `/payments/initiate` alone is `ACTIVE` but has no payer behind it, so its
redemption falls back to a `UPI_QR` nobody pays. To authorize one properly:

1. `adb reverse tcp:8787 tcp:8787`
2. Copy `env/dev.json` to `env/sbx.json` and set `API_BASE_URL=http://127.0.0.1:8787`. Only
   `android/app/src/debug/res/xml/network_security_config.xml` permits cleartext to loopback —
   release builds still forbid all cleartext, so this must be a debug build.
3. `flutter run --dart-define-from-file=env/sbx.json`
4. Sign in (creates the user row), then Premium → Start Free Trial.
5. **Disable the real PhonePe app first** — it grabs the UPI intent and fails, because it cannot
   process a sandbox order:
   ```bash
   adb shell pm disable-user --user 0 com.phonepe.app
   ```
   Choose **Apps & UPI QR → Other UPI Apps → PhonePe Simulator**, pick a Test Bank, enter any 4-digit
   PIN. Re-enable afterwards: `adb shell pm enable com.phonepe.app`.

The simulator's *Test Case Templates → Subscription V2* screen shows which UAT behaviour the merchant
is configured for. It must read *"Setup, notify & redemption success with PhonePe retries auto debit
false"* — matching our `redemptionRetryStrategy:"STANDARD"` + `autoDebit:false`. Any other template
makes UAT's responses disagree with the code for reasons that look like bugs.

## Known-good baseline

`docs/billing-verified.md` (2026-07-29, worker `cc00fb34`) lists every step already proven against
UAT plus the local stub, what UAT refuses to settle, and the cheap way to re-run each one — time is
the only thing simulated, so backdating `next_debit_at` is indistinguishable from waiting. Read it
before re-running anything; Pakiza holds an equivalent baseline from 2026-07-25.

Endpoint facts and the traps that return 200 while broken: `docs/phonepe.md`.
