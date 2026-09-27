-- Unpublishing does NOT clear it: a row renewed, pulled and put back inside the 7 days returns to tier 1.
-- Nullable, no default, NO backfill: null means never renewed, the ordinary state.
-- No index: nothing server-side filters or sorts on it — build-catalog's SELECT * carries it into the
-- JSON and the app windows it client-side, exactly like published_at.

alter table wallpapers add column if not exists renewed_at timestamptz;
alter table ringtones  add column if not exists renewed_at timestamptz;
