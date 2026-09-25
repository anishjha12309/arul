-- Arul — the after-sign-in paywall test is over; nothing writes or reads its column any more.
-- Idempotent on both paths: a fresh install never had the column (24_paywall_test.sql is deleted),
-- the live DB drops it once. The 3,545 rows that were split lose their side with it (owner's call).
alter table users drop column if exists paywall_test;
