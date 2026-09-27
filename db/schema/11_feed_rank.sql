-- The CMS writes it as a full rewrite per scope per save -> sparse ranks (10, 20, 30 …) -> a reorder never cascades.
alter table wallpapers add column if not exists feed_rank integer;
alter table ringtones  add column if not exists feed_rank integer;
