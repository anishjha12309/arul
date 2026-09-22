-- Arul — which side of the after-sign-in paywall test an account landed on.
-- Written ONCE, by POST /auth/login, in the INSERT that creates the account, and only when the
-- client says it can show the paywall and the account can still take a free trial. NULL = not in the
-- test: every account created before it, on an older build, with the switch off, or re-created
-- after a deletion (the tombstone path — no trial to start). Never updated afterwards.
--
-- The read is one query against real trials — the side is set before either arm sees anything:
--   select paywall_test, count(*) as accounts,
--          count(s.trial_end) filter (where s.trial_end - interval '1 day' <= u.created_at + interval '24 hours') as trials_24h
--   from users u left join subscriptions s on s.user_id = u.id
--   where u.paywall_test is not null and not u.is_internal
--   group by 1;
-- Additive and idempotent: safe on a fresh install (after 01_identity.sql) and on the live DB alone.
alter table users add column if not exists paywall_test text
  check (paywall_test in ('paywall', 'control'));
