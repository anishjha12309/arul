
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

-- users — google_sub is the identity anchor -> the Worker upserts on /auth/login.
create table if not exists users (
  id                  uuid        primary key default gen_random_uuid(),
  google_sub          text        unique not null,
  email               text,
  display_name        text        check (char_length(display_name) <= 200),
  display_name_custom boolean     not null default false,  -- true once user edits; login stops syncing from Google
  referral_code       text        unique not null,
  referred_by         uuid        references users(id) on delete set null,
  reward_premium_until timestamptz,
  app_instance_id     text,
  created_at          timestamptz not null default now()
);
alter table users add column if not exists app_instance_id text;
create index if not exists users_referred_by_idx   on users (referred_by);
create index if not exists users_referral_code_idx on users (referral_code);

create table if not exists subscriptions (
  id                       uuid        primary key default gen_random_uuid(),
  user_id                  uuid        not null unique references users(id) on delete cascade,
  status                   text        not null check (status in ('pending','trialing','active','paused','cancelled','expired')),
  plan                     text,
  phonepe_subscription_id  text,
  merchant_subscription_id text,
  merchant_order_id        text,
  phonepe_order_id         text,
  redemption_order_id      text,
  trial_end                timestamptz,
  current_period_end       timestamptz,
  next_debit_at            timestamptz,
  notified_at              timestamptz,
  retry_count              integer     not null default 0,
  updated_at               timestamptz not null default now()
);
create index if not exists subscriptions_user_id_idx       on subscriptions (user_id);
create index if not exists subscriptions_status_idx        on subscriptions (status);
create index if not exists subscriptions_phonepe_id_idx    on subscriptions (phonepe_subscription_id);
create index if not exists subscriptions_merchant_id_idx   on subscriptions (merchant_subscription_id);
create index if not exists idx_subscriptions_next_debit_at on subscriptions (next_debit_at) where status in ('trialing','active');
create index if not exists idx_subscriptions_notified_at   on subscriptions (notified_at)   where notified_at is not null;
create or replace trigger subscriptions_set_updated_at before update on subscriptions
  for each row execute function set_updated_at();
