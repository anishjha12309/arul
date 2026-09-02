-- Arul — ringtone deity: row artwork + subtitle, a display-only second axis.
--
-- category stays coarse for browse -> 35 Perumal tracks span five gods -> one category tile mis-attributes art.
-- deity is display-only (art + subtitle) -> never a browse axis -> no chips filter on it, nothing orders by it.
-- Nullable on purpose -> art resolves deity → category default → fallback.webp -> a null degrades, never breaks.
-- Chain lives in lib/features/ringtones/presentation/deity_art.dart.
-- Art ships in the binary as lossless WebP -> a new deity slug needs an app release -> an insert, never a migration.
alter table ringtones add column if not exists deity text;

-- Nothing filters by deity -> the index only keeps SELECT DISTINCT cheap -> one small btree, kept on purpose.
create index if not exists ringtones_deity_idx on ringtones (deity);
