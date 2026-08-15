-- Arul — ringtone deity (row artwork + subtitle). Apply after 06_popularity.sql.
--
-- WHY a second axis when `category` already exists: category is THE browse axis
-- and must stay coarse (CLAUDE.md §5b — six chips, `others` catching everything
-- outside the five deities). But 35 Perumal tracks span Venkateswara, Krishna,
-- Rama, Narasimha and generic Narayana, and 15 Amman tracks span six goddesses.
-- One tile per category would put Lakshmi's art on a Chamundeshwari chant.
-- `deity` is display-only — art + the row's subtitle. It is NEVER a browse axis:
-- no chip filters on it, and nothing may start ordering by it.
--
-- Free text like `category`, and nullable on purpose. A null deity is legal and
-- resolves in the APP: deity asset → the category's default asset → fallback.png
-- (lib/features/ringtones/presentation/deity_art.dart). That chain is why a row
-- authored in the CMS without a deity degrades to sensible art instead of a
-- broken tile, and why a new deity slug is an insert here plus an app release
-- for its PNG — never a migration.
alter table ringtones add column if not exists deity text;

-- Not for filtering (nothing queries by deity) — it keeps the catalog build's
-- eventual `SELECT DISTINCT deity` coverage cheap and costs one small btree.
create index if not exists ringtones_deity_idx on ringtones (deity);
