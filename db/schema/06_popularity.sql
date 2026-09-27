-- `not null default 0` is load-bearing -> at zero data every row ties -> the sort collapses to newest-first.
alter table wallpapers add column if not exists apply_count bigint not null default 0;
alter table ringtones  add column if not exists set_count   bigint not null default 0;
