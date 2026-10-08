-- Read docs/cron.md first.
-- Cloudflare delivers a cron tick at least once (twice from two colos, or again after a killed run), so each
-- non-idempotent trigger claims its slot here: the first INSERT wins, every other delivery of that slot skips.
create table if not exists cron_runs (
  cron        text        not null,
  slot        timestamptz not null,
  claimed_at  timestamptz not null default now(),
  primary key (cron, slot)
);
