-- Arul — Neon Postgres schema (ringtones). Apply after 03_referral_config.sql.
--   · `category` is first-class (CLAUDE.md §5b — the browse axis, same as
--     wallpapers; never All/New tabs).
--   · `cover_key` nullable and UNUSED — every live row ships null and nothing
--     has ever been written under `ringtones/covers/`. Row art is a PNG bundled
--     in the app, picked by `deity` (07_ringtone_deity.sql); art that ships with
--     the binary cannot 404, so the list has no image failure state at all.
--   · `sort_order` matches wallpapers ordering (sort_order ASC, created_at DESC).
--   · No is_premium column: ALL content is premium-gated in the Worker
--     (/media/signed-url with kind='ringtone'), never on the row.
--
-- audio_key is the sole audio key and is PUBLIC in the catalog (preview is
-- free; setting it as the ringtone is the premium gate). Keys are
-- category-partitioned under the `ringtones/` canonical prefix so the hourly
-- sweep covers audio AND covers with one prefix:
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
