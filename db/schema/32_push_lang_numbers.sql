-- Read docs/push.md first.
-- Per-language numbers outlive push_deliveries, which the daily sweep deletes after 30 days.
-- lang = the phone's app language when the campaign fanned out (en ta te kn ml hi).
alter table push_deliveries add column if not exists lang text;

-- One row per (campaign, app language). Counted by the campaign counters' own test-account rule, so a
-- campaign's rows sum to its sent / failed / gone. approximate = filled once from older records.
create table if not exists push_campaign_langs (
  campaign_id  uuid    not null references push_campaigns(id) on delete cascade,
  lang         text    not null,
  sent         integer not null default 0,
  failed       integer not null default 0,
  gone         integer not null default 0,
  opened       integer not null default 0,
  approximate  boolean not null default false,
  primary key (campaign_id, lang)
);
