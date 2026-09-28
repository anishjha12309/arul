-- How each paywall view ENDED (`back`, `cta`, `background`) and how long it lasted -> the look-and-leave
-- half that `views` cannot show. Reset to NULL by the next view of the same gate.
alter table paywall_views add column if not exists last_exit text;
alter table paywall_views add column if not exists last_dwell_s integer;

-- Append-only checkout outcomes the app reports (a failure and its reason, time in the UPI app, the link),
-- for PostHog's warehouse. Never folded into subscriptions: its trigger bumps updated_at, which also bounds
-- the in-flight checkout window. No payment or entitlement path reads this table.
create table if not exists checkout_events (
  id                bigserial   primary key,
  user_id           uuid        not null references users(id) on delete cascade,
  merchant_order_id text,
  kind              text        not null check (char_length(kind) between 1 and 60),
  at                timestamptz not null default now(),
  context           jsonb
);
create index if not exists checkout_events_at_idx on checkout_events (at);

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'posthog_reader') then
    grant select on checkout_events to posthog_reader;
  end if;
end $$;
