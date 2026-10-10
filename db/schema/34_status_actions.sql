-- One row per status Share or Save the Worker GRANTED (`/media/signed-url`), beside the counters on `statuses`:
-- the counters say how many, this says who and when, so the CMS can rank by distinct users over a window.
-- Both FKs cascade: the CMS deletes statuses and account deletion deletes users -> a plain FK fails both (23503).
create table if not exists status_actions (
  id         bigserial   primary key,
  status_id  uuid        not null references statuses(id) on delete cascade,
  user_id    uuid        not null references users(id) on delete cascade,
  action     text        not null check (action in ('share', 'download')),
  at         timestamptz not null default now()
);
-- The CMS windows on `at`; the two FK indexes keep the status-delete and account-delete cascades cheap.
create index if not exists status_actions_at_idx     on status_actions (at);
create index if not exists status_actions_status_idx on status_actions (status_id);
create index if not exists status_actions_user_idx   on status_actions (user_id);
