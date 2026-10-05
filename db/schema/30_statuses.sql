-- Its own table, never rows in `wallpapers` -> fielded builds' catalogs are built from that table alone.
-- Wallpaper column names wherever the meaning matches -> build-catalog, the sweep and the CMS reuse them.
-- Two counters keep the share/save split; the feed orders on their sum.
create table if not exists statuses (
  id                     uuid        primary key default gen_random_uuid(),
  title                  text        not null,
  category               text        not null,
  full_key               text        not null unique,
  mime                   text        not null default 'video/mp4' check (mime = 'video/mp4'),
  duration_ms            integer,
  width                  integer,
  height                 integer,
  bytes                  bigint,
  is_published           boolean     not null default false,
  feed_rank              integer,
  share_count            bigint      not null default 0,
  download_count         bigint      not null default 0,
  published_at           timestamptz,
  renewed_at             timestamptz,
  pre_renew_published_at timestamptz,
  created_at             timestamptz not null default now()
);
create index if not exists statuses_published_idx on statuses (is_published, category);

-- The function is 15_published_at.sql's -> same first-publish-only debut as the other two tables.
create or replace trigger statuses_stamp_published_at
  before insert or update of is_published, published_at on statuses
  for each row execute function stamp_published_at();

-- Widen, never narrow: the guard reads the live definition, so a second apply is a no-op and a fresh
-- install widens the constraint 12_categories.sql just added.
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'categories_kind_check'
      and pg_get_constraintdef(oid) not like '%status%'
  ) then
    alter table categories drop constraint categories_kind_check;
    alter table categories
      add constraint categories_kind_check check (kind in ('wallpaper', 'ringtone', 'status'));
  end if;
end
$$;
