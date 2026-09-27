alter table ringtones add column if not exists deity text;

-- Nothing filters by deity -> the index only keeps SELECT DISTINCT cheap -> one small btree, kept on purpose.
create index if not exists ringtones_deity_idx on ringtones (deity);
