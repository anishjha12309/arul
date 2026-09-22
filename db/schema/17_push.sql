-- Arul — campaign push notifications (CMS composes, the Worker's minute cron sends over FCM HTTP v1).
-- Read docs/push.md before changing anything here.
--
-- ADDITIVE ONLY, and that is the whole backwards-compatibility contract: no existing table or column
-- changes, so every app build already in the field keeps working against the migrated database. A
-- campaign simply cannot reach a phone whose build never registered — there is no backfill and none
-- is possible, because a Firebase Installation ID only exists once the app asks for one.
--
-- WHY A DEVICE REGISTRY AND NOT FCM TOPICS. The audiences the CMS offers are "hasn't opened the app
-- in 30 days" and "is paying" — neither is expressible as a topic, both are one join away here. Once
-- every send is a per-device request, topics would be a second code path buying nothing.
--
-- WHY `fid` IS THE KEY AND `token` IS THE TARGET — two different jobs, and both columns are needed.
-- The fid is stable across token rotation, so a phone keeps ONE row through a refresh instead of
-- accumulating one per token; that is what makes it the primary key. The token is what a send is
-- actually addressed to: FCM's REST reference marks `message.token` deprecated in favour of
-- `message.fid`, but a registered phone answered 404 UNREGISTERED to the fid and 200 to the token on
-- an identical payload (workers/src/lib/fcm.ts records the measurement). A row with no token is
-- registered but unreachable until `onTokenRefresh` fills it in — never delete it for that.
create table if not exists push_devices (
  fid            text primary key,                  -- Firebase Installation ID
  user_id        uuid not null references users(id) on delete cascade,
  token          text,                              -- FCM registration token — what sends address
  lang           text not null default 'en',        -- en ta te kn ml hi, normalised like Dart's normalizeLang
  app_build      int,
  android_sdk    int,
  last_seen_at   timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
-- One phone is ONE signed-in user: a FID that reappears under a different account is re-pointed by
-- the upsert, never duplicated. The index is what makes the delete-account cascade cheap.
create index if not exists push_devices_user_idx on push_devices(user_id);
-- The inactivity audiences and the 270-day garbage collection both bound on last_seen_at.
create index if not exists push_devices_seen_idx on push_devices(last_seen_at);

-- One row per campaign the CMS composes. `status` is the claim flag the minute cron drives:
--   scheduled -> sending -> sent | failed, or scheduled -> cancelled (only while still scheduled).
create table if not exists push_campaigns (
  id             uuid primary key default gen_random_uuid(),
  status         text not null default 'scheduled', -- scheduled | sending | sent | cancelled | failed
  texts          jsonb not null,                    -- {"en":{"title","body"},"ta":{…}} ; en required
  dest           text not null default 'home',      -- home | wallpaper | ringtone | category | premium
  dest_id        text,                              -- wallpaper/ringtone uuid or category slug
  image_url      text,                              -- absolute CDN URL or null (catalog thumb or push/<id>.jpg)
  image_source   text,                              -- null | catalog | upload  (which tile the editor chose)
  audience       jsonb not null,                    -- {"kind":"all"} | {"kind":"lang","lang":"ta"} |
                                                    -- {"kind":"premium","state":"free|trialing|paid|lapsed"} |
                                                    -- {"kind":"inactive","days":7|14|30} | {"kind":"internal"}
  send_at        timestamptz not null default now(),
  started_at     timestamptz, sent_at timestamptz, cancelled_at timestamptz,
  total          int not null default 0, sent int not null default 0, failed int not null default 0,
  last_error     text,
  created_at     timestamptz not null default now()
);
-- The cron's every-minute probe reads ONLY due-or-running campaigns; a partial index keeps that read
-- off the whole history forever.
create index if not exists push_campaigns_due_idx on push_campaigns(send_at) where status in ('scheduled','sending');

-- One row per (campaign, phone). The PRIMARY KEY is the whole idempotency story: a tick that dies
-- mid-batch rolls its transaction back, the rows return to 'pending', and the retry cannot create a
-- second delivery for the same phone. 'sending' is a CLAIM, held only inside one batch transaction.
create table if not exists push_deliveries (
  campaign_id    uuid not null references push_campaigns(id) on delete cascade,
  fid            text not null,
  status         text not null default 'pending',   -- pending | sending | sent | failed
  error          text,
  sent_at        timestamptz,
  primary key (campaign_id, fid)
);
create index if not exists push_deliveries_pending_idx on push_deliveries(campaign_id) where status = 'pending';

-- A tap, reported by the app. Keyed per USER, not per device: the same person tapping the same
-- campaign on two phones is one open, which is what "Opened 14.8%" has to mean to the editor.
create table if not exists push_opens (
  campaign_id    uuid not null references push_campaigns(id) on delete cascade,
  user_id        uuid not null,
  opened_at      timestamptz not null default now(),
  primary key (campaign_id, user_id)
);
