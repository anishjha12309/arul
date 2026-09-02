-- Arul — operator-authored categories, staged in the CMS until published.
--
-- The app DERIVES its chips from the catalog (`categoriesProvider` / `ringtoneCategoriesProvider`:
-- the distinct categories of the items in it) and build-catalog emits `where is_published = true`.
-- So a category is LIVE exactly when a published row carries it -> a category needs no app release,
-- and it needs no catalog field either -> build-catalog does not read this table and must not start.
-- This table exists so the CMS can hold a category BEFORE that: its rows stay unpublished while
-- `is_published = false` here, so no published row carries the slug, so no chip appears.
-- The CMS's Publish button flips this flag AND publishes the rows in one transaction + version bump.
--
-- Only OPERATOR-CREATED categories live here. The six seeded slugs (registry `knownCategories` /
-- `knownRingtoneCategories`) and anything already on a content row are implicitly live and are never
-- inserted -> nothing that ships today can be retracted, deleted, or made undeployable by this table.
--
-- (slug, kind) is the key, not slug alone -> the two sets deliberately differ (wallpapers have
-- `temples`, ringtones have `others`) and one slug may be staged for one kind while live for the other.
-- `picker_order` orders the CMS pickers ONLY -> the app sorts chips by `compareBrowseCategories`
-- (Sivan first, then alphabetical by label), which is client-side and reaches no column here.
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
