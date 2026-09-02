-- Arul — Neon ringtone catalog schema.
-- `category` is THE browse axis here too -> chips filter by it -> never All/New tabs (CLAUDE.md §5b).
-- Ringtone categories are NOT the wallpaper set -> five deities plus `others` -> no `temples`.
-- cover_key is null everywhere and no cover file exists -> nothing reads it -> do not build a cover pipeline.
-- Row art is a bundled lossless WebP picked by `deity` -> bundled art cannot 404 -> the list has no failure state.
-- `sort_order` is stored and CMS-editable -> nothing reads it for feed order -> see 06_popularity.sql.
-- No is_premium column -> ALL content is premium-gated in the Worker -> never add a per-row premium flag.
-- audio_key is PUBLIC in the catalog -> preview is free -> the gate is /media/signed-url, kind='ringtone'.
-- Keys stay under the ringtones/ prefix -> audio and covers share it -> one sweep prefix covers both.
--   audio  ringtones/<category>/<uuid>.mp3
--   cover  ringtones/covers/<category>/<uuid>.jpg
create table if not exists ringtones (
  id           uuid        primary key default gen_random_uuid(),
  title        text        not null,
  category     text        not null,               -- free text like wallpapers; new category = insert, not migration
  tags         text[]      not null default '{}',  -- free-form extras; browse uses `category`
  audio_key    text        not null,
  cover_key    text,
  mime         text,
  duration_ms  integer,
  bytes        bigint,
  is_published boolean     not null default false,
  sort_order   integer     not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists ringtones_tags_gin           on ringtones using gin (tags);
create index if not exists ringtones_published_sort_idx on ringtones (is_published, sort_order);
create index if not exists ringtones_category_idx       on ringtones (category);
create index if not exists ringtones_pub_cat_sort_idx   on ringtones (is_published, category, sort_order);
create index if not exists ringtones_created_at_idx     on ringtones (created_at desc);
