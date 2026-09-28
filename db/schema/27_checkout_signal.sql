-- Analytics columns for PostHog's warehouse (posthog_reader). Written from app-sent context, never read
-- by a payment or entitlement path.

-- What the app knew at the LATEST Start-trial tap: the path to it, the phone, the link. Overwritten by
-- every later tap, like the rest of the row.
alter table subscriptions add column if not exists checkout_context jsonb;

-- One row per user per paywall source (the gate that opened it) -> the people who look and never tap
-- are visible without a PostHog event.
create table if not exists paywall_views (
  user_id  uuid        not null references users(id) on delete cascade,
  source   text        not null check (char_length(source) between 1 and 40),
  views    integer     not null default 1,
  first_at timestamptz not null default now(),
  last_at  timestamptz not null default now(),
  context  jsonb,
  primary key (user_id, source)
);
create index if not exists paywall_views_last_at_idx on paywall_views (last_at);

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'posthog_reader') then
    grant select on paywall_views to posthog_reader;
  end if;
end $$;
