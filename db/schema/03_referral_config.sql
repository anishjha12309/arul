-- Arul — Neon Postgres schema (3/3: referral + tombstones + config).
-- Apply after 02_content.sql; then run ../seed.sql.

-- referrals — one row per referred user. Created at signup (status 'pending')
-- when a new user arrives with a valid referrer code; flipped to 'rewarded'
-- (reward_days = 30) on the referred user's first paid debit.
create table if not exists referrals (
  id               uuid        primary key default gen_random_uuid(),
  referrer_id      uuid        not null references users(id) on delete cascade,
  referred_user_id uuid        not null references users(id) on delete cascade,
  status           text        not null default 'pending' check (status in ('pending','subscribed','rewarded')),
  reward_days      integer     not null default 0,
  created_at       timestamptz not null default now()
);
create index if not exists referrals_referrer_id_idx on referrals (referrer_id);
-- A user can only ever be referred once → unique. Enables ON CONFLICT on capture
-- and makes the reward-grant UPDATE unambiguous.
create unique index if not exists referrals_referred_user_id_uidx on referrals (referred_user_id);
create index if not exists referrals_status_idx on referrals (status);

-- trial_tombstones — survives account deletion so the one-free-trial guard can't
-- be reset by delete → re-signup (trial farming). google_sub_hash =
-- HMAC-SHA256(google_sub, TRIAL_TOMBSTONE_SECRET), hex — pseudonymous, no PII.
-- Written by DELETE /me when trial was consumed; read by /auth/login's new-user
-- branch to pre-seed a consumed-trial subscriptions row. The secret NEVER rotates.
create table if not exists trial_tombstones (
  google_sub_hash text        primary key,
  trial_end       timestamptz not null,
  deleted_at      timestamptz not null default now()
);

-- app_config — singleton (id=1). content_version is bumped on any content change;
-- build-catalog compares it against Workers KV to skip no-op rebuilds.
create table if not exists app_config (
  id                    smallint primary key default 1 check (id = 1),
  content_version       bigint   not null default 0,
  prices                jsonb    not null default '{}',
  support_email         text,
  policy_urls           jsonb    not null default '{}',
  feature_flags         jsonb    not null default '{}',
  min_supported_version text
);
