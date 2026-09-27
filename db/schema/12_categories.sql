-- (slug, kind) is the key, not slug alone -> the two sets deliberately differ (wallpapers have
-- `temples`, ringtones have `others`) and one slug may be staged for one kind while live for the other.
-- NOT named `sort_order`: that name already means "the order within a category that imports own" on
-- both content tables, and the one rule about it is that curation must never be parked there.
-- A second `sort_order` with a third meaning is how that rule gets broken by accident.
create table if not exists categories (
  slug         text        not null,
  kind         text        not null,
  is_published boolean     not null default false,
  picker_order integer     not null default 0,
  created_at   timestamptz not null default now(),
  published_at timestamptz,
  primary key (slug, kind)
);

-- Postgres has no idempotent ADD CONSTRAINT -> guard it explicitly (.claude/rules/schema.md).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'categories_kind_check'
  ) then
    alter table categories
      add constraint categories_kind_check check (kind in ('wallpaper', 'ringtone'));
  end if;
end
$$;

-- The CMS reads one kind at a time, and every write path reads the DRAFT slugs for one kind.
create index if not exists categories_kind_published_idx on categories (kind, is_published);
