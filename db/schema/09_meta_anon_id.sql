-- Meta SDK anonymous device GUID (Android: "XZ" + UUID), once the Conversions API join key.
-- Dead since the Conversions API reporter was deleted -> nothing reads or writes meta_anon_id.
-- Dropping it would be a migration -> not worth the churn -> the column stays, unread; do not revive it.
alter table users add column if not exists meta_anon_id text;
