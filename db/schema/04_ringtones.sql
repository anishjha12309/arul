create table if not exists ringtones (
  id           uuid        primary key default gen_random_uuid(),
  title        text        not null,
  category     text        not null,
  tags         text[]      not null default '{}',
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
