-- Meta SDK anonymous app device GUID (Android: "XZ" + UUID) — the device join
-- key the Conversions API needs so the Worker can report the FIRST trial→paid
-- conversion (Meta Subscribe) for debits that settle with the app closed.
-- Uploaded by the app on /auth/login and /payments/initiate; read by
-- lib/meta.ts. Nullable: absent until a build that sends it logs in — lib/meta.ts
-- then matches on hashed email/external_id alone.
alter table users add column if not exists meta_anon_id text;
