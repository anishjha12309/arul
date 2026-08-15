-- One-off backfill of ringtones.deity for the library that existed before the
-- column did (132 published rows, 2026-08-15). NOT part of db/schema/ — a fresh
-- install has no rows to backfill; the schema change itself is 07_ringtone_deity.sql.
--
-- Idempotent, and safe to re-run after an import: every statement is an absolute
-- assignment, so the end state is the same however many times it runs.
--
-- Shape: set each category's DEFAULT deity first, then override by explicit
-- title. Titles are matched exactly and a missing one simply matches no rows, so
-- this survives tracks being added or removed between runs. Deliberately NOT
-- filtered on is_published — an unpublished draft should already carry its art.
--
-- Titles that name no deity (Guardian Mother, Ferocious Roar, Amme Narayana …)
-- are intentionally left on their category default rather than guessed at; that
-- is the owner's rule, and it is why `vishnu` and `devi` must stay generic.

-- Single-deity categories.
update ringtones set deity = 'murugan'  where category = 'murugan';
update ringtones set deity = 'ayyappan' where category = 'ayyappan';
update ringtones set deity = 'sivan'    where category = 'sivan';

-- Category defaults for the multi-deity categories.
update ringtones set deity = 'vishnu' where category = 'perumal';
update ringtones set deity = 'devi'   where category = 'amman';

-- Perumal → named forms.
update ringtones set deity = 'venkateswara' where category = 'perumal' and title in (
  'Balaji Chant', 'Balaji Kripa', 'Govinda Govinda', 'Govinda Hari',
  'Govinda Veena', 'Jay Srinivasa Jay Venkatesha', 'Karunagara Govinda',
  'Namo Venkatesaya', 'Om Namo Venkateshaye', 'Om Venkatesa Meditation',
  'Seven Hills Govinda', 'Sri Hari Govinda', 'Srinivasa Govinda',
  'Suprabhatam Venkateswara', 'Tirumalai Vaasaa Balaji', 'Tirupati Balaji',
  'Tirupati Balaji Govinda', 'Venkat Ramana Govinda', 'Venkatesa Suprabhatam',
  'Venkatesha Garuda Dhvaja', 'Venkatesha Krupasindhu', 'Venkatesha Mangalam'
);
update ringtones set deity = 'krishna' where category = 'perumal' and title in (
  'Brindavana Lola', 'Hare Krishna Kirtan', 'Unni Kanna'
);
update ringtones set deity = 'rama' where category = 'perumal' and title in (
  'Bhadradri Ramayya', 'Bhaja Ramam Satatam', 'Sita Ramula Pattabhishekam'
);
update ringtones set deity = 'narasimha' where category = 'perumal' and title in (
  'Jaya Narasimha'
);

-- Amman → named goddesses.
update ringtones set deity = 'lakshmi' where category = 'amman' and title in (
  'Lakshmi Gayatri Mantra', 'Maha Lakshmi Mantra'
);
update ringtones set deity = 'mariamman' where category = 'amman' and title in (
  'Angalamman', 'Attukal Amma', 'Irukkankudi Mariamma'
);
update ringtones set deity = 'durga' where category = 'amman' and title in (
  'Jaya Jaya Chamundeshwari', 'Kanaka Durga'
);
update ringtones set deity = 'meenakshi' where category = 'amman' and title in (
  'Meenakshi Thaye'
);
update ringtones set deity = 'parvati' where category = 'amman' and title in (
  'Ardhanareeswarar', 'Sakthi Sangamam', 'Sivasakthi Thandavam'
);

-- Others → the catch-all category has no sensible default (its members are
-- deliberately unlike each other), so every row is named explicitly. Anything
-- new landing here stays null and renders fallback.png until it is assigned.
update ringtones set deity = 'ganesha' where category = 'others' and title in (
  'Ganapathi Mantra', 'Vinayaga Arul', 'Vinayaka Namam'
);
update ringtones set deity = 'hanuman' where category = 'others' and title in (
  'Jaya Mukhyaprana', 'Veera Anjaneya'
);
