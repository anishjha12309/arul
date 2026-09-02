---
description: The premium predicate has exactly one home; never re-derive it client-side.
paths:
  - "workers/src/lib/entitlement.ts"
  - "workers/src/routes/me.ts"
  - "workers/src/routes/media.ts"
  - "lib/features/premium/providers/**"
---

Entitlement decides whether a paying user can use what they paid for, so a second copy of the rule is
a revenue bug in either direction.

- **`premiumPredicate` in `workers/src/lib/entitlement.ts` is the rule's ONE home.** The app consumes
  the `premium` flag `GET /me` computes from it and NEVER re-derives it from the subscription row. A
  client copy drifted once — it missed `reward_premium_until` — and paywalled reward-only referrers.
- **Entitlement is never authoritative in the JWT.** The `prm` claim is a UI hint only; every gated
  action live-reads Neon, so purchase, refund and expiry apply instantly.
- The 6 h debit grace past `current_period_end` is for `trialing`/`active` ONLY, because the renewal
  debit rides the cron. `cancelled` keeps premium to period end with NO grace; `pending` with a live
  period counts; `paused`/`expired` get nothing; `reward_premium_until` is ORed in.
- **`ensurePremium()` must AWAIT `entitlementProvider.future`** — a loading snapshot must never bounce
  a premium user. A blocked action tracks `${action}_blocked_premium` and routes STRAIGHT to
  `/premium?source=`: no nudge, no teaser sheet, no interstitial.
- Re-applying or re-sharing an already-cached file still calls `/media/signed-url` — a cache must
  never become a permanent licence. Offline with bytes on disk is the one allowed pass-through.

Read [docs/architecture.md](../../docs/architecture.md) §Entitlement before changing any of it.
