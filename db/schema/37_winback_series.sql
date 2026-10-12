-- The ₹99 win-back series (docs/winback-push.md §The daily series): one row per person per lapse per series day, sent
-- or skipped with its reason. The primary key is the race lock (overlapping minute ticks send a day once) and, with
-- the switch off, the `disabled` rows are the baseline the pushed weeks are measured against.
create table if not exists winback_series (
  user_id     uuid        not null references users(id) on delete cascade,
  lapsed_at   timestamptz not null,
  day         smallint    not null check (day between 0 and 13),
  state       text        not null check (state in ('sent', 'skipped')),
  skip_reason text,
  campaign_id uuid        references push_campaigns(id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (user_id, lapsed_at, day)
);
-- "Pushed today" reads a person's sent rows by time; the primary key's leading user_id serves the delete cascade.
create index if not exists winback_series_sent_idx on winback_series (user_id, created_at) where state = 'sent';
