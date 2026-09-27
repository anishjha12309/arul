
-- One row per referred user -> created 'pending' at signup with a valid referrer code.
-- The referred user's FIRST paid debit -> flips the row to 'rewarded', reward_days = 30.
create table if not exists referrals (
  id               uuid        primary key default gen_random_uuid(),
  referrer_id      uuid        not null references users(id) on delete cascade,
  referred_user_id uuid        not null references users(id) on delete cascade,
  status           text        not null default 'pending' check (status in ('pending','subscribed','rewarded')),
  reward_days      integer     not null default 0,
  created_at       timestamptz not null default now()
);
create index if not exists referrals_referrer_id_idx on referrals (referrer_id);
-- A user is referred at most once -> capture ON CONFLICTs, the reward UPDATE is unambiguous -> keep it unique.
create unique index if not exists referrals_referred_user_id_uidx on referrals (referred_user_id);
create index if not exists referrals_status_idx on referrals (status);

create table if not exists trial_tombstones (
  google_sub_hash text        primary key,
  trial_end       timestamptz not null,
  deleted_at      timestamptz not null default now()
);

create table if not exists app_config (
  id                    smallint primary key default 1 check (id = 1),
  content_version       bigint   not null default 0,
  prices                jsonb    not null default '{}',
  support_email         text,
  policy_urls           jsonb    not null default '{}',
  feature_flags         jsonb    not null default '{}',
  min_supported_version text
);
