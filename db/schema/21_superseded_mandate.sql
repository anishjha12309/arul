-- Arul — the mandate a re-subscribe REPLACES, kept alive until the replacement is approved.
-- A user whose trial debit is failing taps Subscribe again; initiate claims the user's ONE row for the
-- new setup and used to revoke the old mandate on the spot. 95% of those new setups are never approved,
-- so a mandate still climbing the dunning ladder died for nothing (155 of 179 checked at PhonePe).
-- Now initiate parks that id here. A grant on the new mandate revokes it and clears this; a failed or
-- abandoned setup hands the row back to it (merchant_subscription_id = this, status trialing/active)
-- so the ladder resumes. NULL = nothing parked. Additive and idempotent; apply BEFORE deploying the
-- Worker that reads it.
alter table subscriptions add column if not exists superseded_mandate_id text;
