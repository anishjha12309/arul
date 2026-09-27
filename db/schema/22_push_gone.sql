-- Read docs/push.md first.
alter table push_campaigns add column if not exists gone integer not null default 0;
alter table push_devices add column if not exists token_checked_at timestamptz;
