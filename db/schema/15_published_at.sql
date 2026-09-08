-- Arul — `published_at`, the debut date the "New" browse chip ages from.
--
-- NOT `created_at`, which is the row's INSERT time and in this app is IMPORT time. A batch
-- imported unpublished and published three weeks later would arrive already too old to ever
-- reach New. The chip has to age from the moment the content became VISIBLE, which is the
-- `is_published` flip and nothing else.
--
-- Stamped by a TRIGGER, never by a caller. Publishing happens from three places that do not
-- share code — the unified CMS, the bulk importers and manual SQL — and every one of them
-- publishes by flipping this one boolean. A trigger is the single home for the rule, so no
-- publish path can forget it and no two can disagree. Nothing in `workers/` writes it either.
--
-- FIRST publish ONLY (owner's call): pulling a row to fix its title and putting it back must not
-- resurface it in New. `published_at is null` is the whole guard -> only a never-published row can
-- be stamped, so the date is the debut and stays the debut.
--
-- Nullable, no default: null means "never published". No index — nothing filters on this column.
-- The app reads it out of the catalog JSON and windows client-side; build-catalog does not sort
-- or filter by it, so an index here would be dead weight the writes still pay for.

alter table wallpapers add column if not exists published_at timestamptz;
alter table ringtones  add column if not exists published_at timestamptz;

-- Backfill: whatever is live today debuts at its insert time, the only debut date that exists for
-- it. Guarded by `published_at is null`, so re-applying this file is a no-op and a fresh install
-- runs it over an empty table. Deliberately does NOT touch unpublished rows -> their debut is
-- whenever someone publishes them, and the trigger below stamps it then.
update wallpapers set published_at = created_at where is_published = true and published_at is null;
update ringtones  set published_at = created_at where is_published = true and published_at is null;

-- BEFORE, not AFTER -> it edits the row on its way in, with no second write.
-- `new.published_at is null` also leaves an explicitly-supplied value alone, which is what makes
-- clearing the column by hand the deliberate "let this resurface in New" lever.
create or replace function stamp_published_at() returns trigger language plpgsql as $$
begin
  if new.is_published and new.published_at is null then
    new.published_at := now();
  end if;
  return new;
end
$$;

-- `update of is_published, published_at` -> an ordinary title or key edit never fires this.
-- Both columns are named on purpose: the second is what re-arms the lever described above.
-- `create or replace trigger` (PG 14+), because there is no idempotent CREATE TRIGGER and a bare
-- one failing on an existing trigger would roll back every statement in this file (.claude/rules/schema.md).
create or replace trigger wallpapers_stamp_published_at
  before insert or update of is_published, published_at on wallpapers
  for each row execute function stamp_published_at();

create or replace trigger ringtones_stamp_published_at
  before insert or update of is_published, published_at on ringtones
  for each row execute function stamp_published_at();
