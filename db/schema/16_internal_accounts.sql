-- The owner's own test trials and Google Play's pre-launch robots live in the same tables as real
-- users. They are ~1.4% of trials but ~4% of CANCELLATIONS, which is the number they distort most.
-- No index: every consumer aggregates the whole table, which a partial index cannot help.
-- Additive and idempotent: safe on a fresh install (after 01_identity.sql) and on the live DB alone.
alter table users add column if not exists is_internal boolean not null default false;
