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

A single word drives redeem AND order-status together. Token form drives endpoints separately —
needed wherever one shared answer can't express the scenario:

```
redeem:PENDING order:COMPLETED      # Pass C: redeem stuck, order actually settled
mandate:CANCELLED                   # user revoked at their PSP — status-poll detect
cancel:FAIL mandate:ACTIVE          # DELETE /me must 502-abort, user survives
```

Tokens: `redeem`/`order` (COMPLETED|FAILED|PENDING) · `mandate` (ACTIVE|CANCELLED|PAUSED…) ·
`cancel` (OK|FAIL). Unlisted tokens keep defaults (redeem/order COMPLETED, mandate ACTIVE,
cancel OK). The stub also answers `/order/{id}/status` and `/{id}/cancel` now — proven against the
2026-08-12 full-matrix run (27/27, including a REAL settle observed via Pass C on a
simulator-backed mandate).

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

Sign-in answering "Google token is invalid or expired" = `GOOGLE_WEB_CLIENT_ID` in
`workers/.dev.vars` drifted from `env/dev.json`'s (the token's `aud` is the app's define; the local
worker must expect the same id — prod already does). Fixed 2026-08-12; if it recurs, copy the value
from `env/dev.json`. A debug build cannot install over the Play build (signature + versionCode) —
`adb uninstall com.hsrutility.arul` first, reinstall from Play after.

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

The full lifecycle was proven against UAT + the local stub on 2026-07-29: trial mandate, repeat ₹199,
double-tap → 409, 24h notify with **Pass B refusing an early debit**, settle, dunning to `expired` at
retry 5, cancel keeping the period live, rebuy at ₹199, delete→re-login pre-seeding the consumed
trial. Expected behaviour per step is specified as rules in `docs/phonepe.md` — re-run THIS skill
when billing code changes rather than re-deriving. Two facts that make re-runs cheap:

- **Time is the only thing simulated.** Notify/redeem/renewal key off `next_debit_at`, so backdating
  it is indistinguishable from waiting. Never wait out a real trial day.
- **Local dev cannot receive the real S2S webhook** (`127.0.0.1` is unreachable from PhonePe). Drive
  the handler with `workers/tools/prod-webhook.mjs`; production delivery itself (PhonePe →
  `api.hsrutility.com` → `DKS_` dispatcher → arul-api) has been observed live.

Endpoint facts and the traps that return 200 while broken: `docs/phonepe.md`.
