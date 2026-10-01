-- The monthly debit of THIS row's mandate. A ₹99 cancel-save mandate and a ₹199 one live on the same row over
-- time, so every notify, settle and paid_paise stamp reads it, never a literal. superseded_price_paise is the
-- parked mandate's price: set, restored and NULLed together with superseded_mandate_id.
alter table subscriptions add column if not exists price_paise             bigint  not null default 19900;
alter table subscriptions add column if not exists superseded_price_paise  bigint;
-- TRUE only while a cancel_99 setup is pending: the grant and every release branch on it, never on amounts.
alter table subscriptions add column if not exists offer_switch            boolean not null default false;
-- The ₹99 mandate of a RELEASED switch, watched until PhonePe answers terminal or ACTIVE (a late approval is honoured).
alter table subscriptions add column if not exists offer_mandate_id        text;
-- A parked ₹199 the switch grant could not revoke; the hourly sweep retries it.
alter table subscriptions add column if not exists revoke_retry_mandate_id text;
-- The first failed revoke of revoke_retry_mandate_id, set and NULLed with it: it dates the sweep's 72 h ALARM.
alter table subscriptions add column if not exists revoke_retry_at         timestamptz;

-- The offer keeps no per-person record (owner). Drop AFTER the Worker that stops writing these is live.
alter table users            drop column if exists cancel_offer_at;
alter table trial_tombstones drop column if exists cancel_offer_at;
