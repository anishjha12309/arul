-- Arul — Neon Postgres schema (2/3: content). Apply after 01_identity.sql.
-- Wallpapers-only: NO ringtones table (differs from the reference — the Worker
-- copy must have its ringtone paths stripped per docs/port-map.md, or
-- build-catalog crashes querying a table that does not exist).

-- wallpapers — static (JPG) + live (MP4), mixed together in one feed. full_key is
-- the sole content key and is PUBLIC in the catalog (preview is free; applying it
-- is the premium gate). No is_premium column: ALL content is premium-gated in the
-- Worker (/media/signed-url), never on the row.
--
-- `category` is FIRST-CLASS in Arul (a delta vs the reference, whose tabs were
-- All/New): it is THE browse axis — the feed filters by category, never by
-- static/live. Free text + index, no check constraint and no categories table, so
-- adding a category is a plain insert, not a migration. Launch set (matches the R2
-- key prefixes): amman · ayyappan · murugan · perumal · sivan · temples.
create table if not exists wallpapers (
  id           uuid        primary key default gen_random_uuid(),
  title        text        not null,
  type         text        not null check (type in ('static','live')),  -- rendering hint, NOT a filter
  category     text        not null,
  tags         text[]      not null default '{}',   -- free-form extras; browse uses `category`
  full_key     text        not null,
  mime         text,
  duration_ms  integer,                             -- null for static
  width        integer,
  height       integer,
  bytes        bigint,
  is_published boolean     not null default false,
  sort_order   integer     not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists wallpapers_tags_gin           on wallpapers using gin (tags);
create index if not exists wallpapers_published_sort_idx on wallpapers (is_published, sort_order);
create index if not exists wallpapers_type_idx           on wallpapers (type);
create index if not exists wallpapers_category_idx       on wallpapers (category);
create index if not exists wallpapers_pub_cat_sort_idx   on wallpapers (is_published, category, sort_order);

-- content_submissions — user uploads awaiting moderation (kind = 'wallpaper' only
-- in Arul; the Worker validates).
create table if not exists content_submissions (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references users(id) on delete cascade,
  kind             text        not null,
  file_key         text        not null,
  title            text,
  category         text,
  status           text        not null default 'pending' check (status in ('pending','approved','rejected')),
  rejection_reason text,
  reviewed_by      uuid        references users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists content_submissions_user_id_idx     on content_submissions (user_id);
create index if not exists content_submissions_reviewed_by_idx on content_submissions (reviewed_by);
create index if not exists content_submissions_status_idx      on content_submissions (status);
-- One R2 object = one submission row; confirm-upload upserts on this
-- (ON CONFLICT DO UPDATE … RETURNING) so retried confirms stay idempotent.
create unique index if not exists content_submissions_file_key_uidx on content_submissions (file_key);
