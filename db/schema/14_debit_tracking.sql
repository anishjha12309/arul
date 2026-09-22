-- Arul — per-row debit tracking, read by the unified CMS's subscriptions page and nothing else.
-- The subscriptions row is overwritten on every settle, so without these the date of a user's first
-- ₹199, how many months they have paid and how much cannot be recovered once a renewal lands.
-- Every Worker statement that grants a PAID period writes all three (cron settle, webhook redemption,
-- operator run-redemptions, and the repeat-subscriber setup that debits ₹199 up front).
-- first_debit_at is COALESCEd -> stamped once, a renewal never moves it. NULL = never debited.
-- Additive and idempotent: safe on a fresh install (after 01_identity.sql) and on the live DB alone.
-- Apply BEFORE deploying the Worker that writes them, or every settle UPDATE fails while PhonePe keeps the money.
alter table subscriptions add column if not exists first_debit_at timestamptz;
alter table subscriptions add column if not exists debit_count    integer not null default 0;
alter table subscriptions add column if not exists paid_paise     bigint  not null default 0;
