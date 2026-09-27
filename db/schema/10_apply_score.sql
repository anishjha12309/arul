alter table wallpapers add column if not exists apply_score double precision not null default 0;
alter table wallpapers add column if not exists scored_at   timestamptz;
alter table ringtones  add column if not exists set_score   double precision not null default 0;
alter table ringtones  add column if not exists scored_at   timestamptz;

-- Seeded once from the lifetime counters -> guarded on scored_at IS NULL -> a re-apply cannot re-seed a row.
update wallpapers set apply_score = apply_count, scored_at = now()
  where apply_count > 0 and scored_at is null;
update ringtones  set set_score   = set_count,   scored_at = now()
  where set_count   > 0 and scored_at is null;
