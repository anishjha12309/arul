-- One row per mandate whose live plan ended at PhonePe, written in the SAME statement as the park (docs/push.md
-- §Win-back). The primary key is the race lock: one win-back push per mandate, ever. The free-text columns carry no
-- CHECK -> a surprise value must never fail the revoke statement this insert rides on.
create table if not exists winback_pushes (
  mandate_id    text        primary key,
  user_id       uuid        not null references users(id) on delete cascade,
  prior_status  text,
  phonepe_state text,
  detected_by   text        not null,
  state         text        not null default 'queued' check (state in ('queued', 'sent', 'skipped')),
  skip_reason   text,
  campaign_id   uuid        references push_campaigns(id) on delete set null,
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);
-- The minute sender reads only queued rows; the user index keeps the account-delete cascade cheap.
create index if not exists winback_pushes_queued_idx on winback_pushes (created_at) where state = 'queued';
create index if not exists winback_pushes_user_idx   on winback_pushes (user_id);

-- The Worker's automated campaign rows, one per group per IST month ('winback:trial:2026-10'). A PLAIN unique index:
-- NULLs stay distinct so CMS rows never collide, and ON CONFLICT (auto_key) can infer it where a partial one cannot.
alter table push_campaigns add column if not exists auto_key text;
create unique index if not exists push_campaigns_auto_key_idx on push_campaigns (auto_key);
