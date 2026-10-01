# The ₹99 offers — a second mandate, never a cheaper notify

Two offers share one price: `cancel_99` switches a live ₹199 plan, `winback_99` re-sets up a returning user with no
live plan (§The winback). Read before touching `workers/src/lib/subscription-state.ts`, the offer path of
`routes/payments.ts`, or `features/premium/presentation/cancel_offer_sheet.dart`. Setup and cancel:
[phonepe.md](phonepe.md) · the hourly sweeps: [autopay-debits.md](autopay-debits.md) · the app's picker and poll:
[checkout.md](checkout.md).

## A new ₹99 mandate, never a ₹99 notify on the ₹199 one

PhonePe has no mandate-modify API and its docs say nothing on a FIXED mandate taking a lower notify, so the switch
sets up a NEW mandate (`PENNY_DROP` ₹2, `maxAmount` 9900) and revokes the ₹199 once it is approved. UAT accepted a
19900 notify on a FIXED 9900 mandate: the sandbox enforces nothing at notify, so the amount is right only because
every notify, settle and `paid_paise` stamp reads the row's `price_paise`, never a literal.

## Eligibility is ONE fragment

`cancelOfferEligible` (GET /me and initiate, re-checked under the users-row lock): trialing/active with a live
period, a live mandate, `next_debit_at` more than an hour out, nothing parked, `price_paise = 19900`. NOT
`notified_at IS NULL`: Pass A notifies a 1-day trial minutes after it starts, and with `autoDebit:false` a notified
order moves no money until Pass B redeems it at `next_debit_at`.

Initiate also reads the live mandate first: anything but ACTIVE syncs the row with the status route's own writes and
answers 409 `offer_unavailable` — distinct from `setup_in_progress`, and never `already_subscribed`, which the app
reads as success.

## Claim, switch, release

- The claim parks the ₹199 with `superseded_price_paise`, writes `price_paise = 9900` and `offer_switch = true`, and
  touches NO ladder column, so a release hands `next_debit_at`, `notified_at` and the order back exactly.
- `grantCompletedSetup` runs the switch FIRST on every grant surface (setup webhook, status reconcile, claim sweep).
  The ₹2 check is not a paid month: the release CASE picks the status, no debit stamps, no referral, no
  `subscription_active`. `next_debit_at` becomes `GREATEST(next_debit_at, now() + 25 h)` and the period — and a
  trial's `trial_end`, so it still reads unconverted — moves with it: PhonePe refuses a debit inside 24 h of its
  notice, and premium must never lapse over our switch.
- The switch clears `redemption_order_id`: a legacy order left on an hsr row names two merchants and throws.
- The replaced ₹199 is revoked at ITS merchant after the response; one PhonePe keeps live goes to
  `revoke_retry_mandate_id` (hourly retry). Never notified, so it cannot debit — this is about what the user sees in
  their UPI app. The ALARM fires 72 h after `revoke_retry_at`, the first failed revoke: set and NULLed with the id,
  kept on a re-note of the same id, restarted for another id — an older date would alarm on a new id's first retry.
- Every release (abandon, failed-setup webhook, status FAILED/EXPIRED, the claim sweep, a revoked/cancelled webhook
  for the claim's own id while a mandate is parked) restores the parked id AND its price and keeps the ₹99 id in
  `offer_mandate_id`.
- A failed offer initiate releases its claim at once: left `pending`, the user's "Try again" reads as ineligible.
- The in-flight guard runs BEFORE eligibility, so a double tap answers `setup_in_progress`, never
  `offer_unavailable`; an older claim of their own switch is released first, so a retry is judged on the ₹199.
- Cancel and account deletion mid-switch MUST revoke the parked ₹199 but revoke the unapproved ₹99 best effort:
  an in-progress setup refuses a merchant cancel, and waiting on it blocked both until the claim sweep.

## Late approval

The payer can approve in the UPI app after the app gave up. `honourLateOfferApproval` (the hsr webhook, and the
hourly watch of `offer_mandate_id`) switches a row still trialing/active on its ₹199 and not due within the hour —
they approved ₹99, so charging ₹199 after that is the worst outcome. Anywhere else the ₹99 is revoked; an in-progress
one older than 24 h (its id's own timestamp) too.

Never the resurrect grant: it excludes `offer_switch` rows, and a cancel mid-switch puts the ₹199 id back on the row
with the ₹99 in `offer_mandate_id`, so a late approval there can only be revoked — never a month off a ₹2 check.

## No per-person record

Owner: either offer, as often as they like, and nothing records an answer — no users column, nothing on the trial
tombstone. `price_paise = 19900` alone keeps a ₹99 subscriber off the switch; one whose ₹99 dies re-subscribes at
₹199 (every claim writes `price_paise`) and is offered it again. `/payments/cancel` never reads its body: fielded
builds post `{offer_declined:true}`, and it must still cancel.

## The winback — a paid re-setup at ₹99

- `winbackOfferEligible` (GET /me `winback_offer_eligible`, initiate, re-checked under the lock): `trial_end` set
  (trialled or paid before), status `cancelled`/`expired`/`pending`, nothing parked — a parked mandate is a live plan
  still billing. A new user (no row, `trial_end` NULL) keeps the free trial then ₹199; trialing/active keep the switch.
- The in-flight guard runs first (`setup_in_progress`), then eligibility (`offer_unavailable`), then the settled-debit
  heal: an order that already took money answers `already_subscribed`, never a second charge at ₹99.
- It is NOT a switch: `offer_switch` stays false, nothing new is parked, and the setup is a ₹99 TRANSACTION
  (`maxAmount` = first debit = 9900). The grant is the ordinary one — a paid month, debit stamps and referral off the
  row's price — and a failed attempt keeps its claim pending like any paid re-setup. `offer_switch` is the ONLY
  switch marker: never infer a switch from 9900, a pending or released winback reads 9900 too.
- A released winback keeps 9900: with nothing parked the row still names the winback's mandate, and a late approval
  resurrects a paid month on it. Reset to 19900, that month would stamp ₹199 for a ₹99 debit and every later notify
  would ask 19900 of a FIXED 9900 mandate. The next claim rewrites the price anyway.
- Server events tag `offer: cancel_99` only on a ₹99 trial (a winback is never a trial); a paid ₹99 row may be either
  offer and carries `price_paise` alone (`offerOfPrice`).

## Two merchants

New setups follow `chooseSetupMerchant`, never the parked id, so the usual switch is legacy ₹199 → hsr ₹99 and every
later call routes by `merchantOf` of the id it touches. The legacy keys stay live while any legacy mandate does,
parked ones included. The payer's UPI app shows the ₹99 payee as `hsrutilityonline@ybl`, not the ₹199's merchant.

## Contracts

- [ ] Cancel → the offer sheet first when eligible, else the confirm; any dismissal opens the confirm; a decline alone
  never cancels
- [ ] The hold counts down from 10:00 per sheet; at 00:00 Get discount disables; the next Cancel tap is a fresh 10:00
- [ ] Declined or switched before, now on ₹199 → offered again
- [ ] Returning with no live plan → winback: a ₹99 first debit, then ₹99 monthly; a new user → trial, then ₹199
- [ ] A released winback's late approval grants a ₹99 month, never ₹199
- [ ] A failed or abandoned accept restores the ₹199 exactly (id, price, ladder); the retry sheet's back changes nothing,
  its cancel goes through the confirm
- [ ] Premium never lapses across a switch; the first ₹99 is notified fresh, ≥ 24 h out
- [ ] A late ₹99 approval switches only a row still on its ₹199; on a cancelled row it is revoked
- [ ] A switch attempt never fires `trial_started`, never arms the trial marker, is never resumable
- [ ] No PhonePe call names ids of two merchants
