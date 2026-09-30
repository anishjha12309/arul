---
description: The ₹99 cancel offer and the shared subscription transitions — one grant, one release, row-priced debits.
paths:
  - "workers/src/lib/subscription-state.ts"
  - "workers/src/lib/pricing.ts"
  - "workers/src/cron/autopay-sweeps.ts"
  - "lib/features/premium/presentation/cancel_offer_sheet.dart"
  - "lib/features/premium/domain/cancel_offer.dart"
---

- **The switch is a NEW ₹99 mandate, never a ₹99 notify on the ₹199 one.** Every notify, settle and `paid_paise`
  stamp reads the row's `price_paise`; UAT enforces nothing at notify.
- **One home each:** eligibility is `cancelOfferEligible`, a grant is `grantCompletedSetup` (the switch FIRST), a
  release is `releaseClaim`, a heal is `healSettledDebit`, a park is `parkSubscription`. Never copy one into a route.
- **`AND status = 'pending'` stays load-bearing** in every grant; the resurrect grant never matches `offer_switch`.
- **A switch books no paid month**: no debit stamps, no referral, no `subscription_active`, no `trial_started`.
- **A failed or abandoned accept never spends the offer**; only the explicit decline flag, the retry sheet's cancel
  or a switch stamps `users.cancel_offer_at`.
- The hourly sweeps read a row once and move it out of their own selection, or it heads the pass forever.

Read [docs/cancel-offer.md](../../docs/cancel-offer.md) before changing any of it; the sweeps are
[docs/autopay-debits.md](../../docs/autopay-debits.md) §The hourly sweeps.
