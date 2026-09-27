
create table if not exists wallpapers (
  id           uuid        primary key default gen_random_uuid(),
  title        text        not null,
  type         text        not null check (type in ('static','live')),
  category     text        not null,
  tags         text[]      not null default '{}',
  full_key     text        not null,
  mime         text,
  duration_ms  integer,
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

-- `kind` has no CHECK -> the Worker validates it -> adding a kind stays a code change, not a migration.
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
create unique index if not exists content_submissions_file_key_uidx on content_submissions (file_key);
