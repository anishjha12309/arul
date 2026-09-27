-- The subscriptions row is overwritten on every settle, so without these the date of a user's first
-- ₹199, how many months they have paid and how much cannot be recovered once a renewal lands.
alter table subscriptions add column if not exists first_debit_at timestamptz;
alter table subscriptions add column if not exists debit_count    integer not null default 0;
alter table subscriptions add column if not exists paid_paise     bigint  not null default 0;
