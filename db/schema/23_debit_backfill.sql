-- Arul — one-time backfill of first_debit_at / debit_count / paid_paise for rows debited before
-- those columns existed.
--
-- db/schema/14_debit_tracking.sql (8 Sep 2026) added the three columns, and every paid grant since
-- stamps them. The unified CMS's Subscriptions page reads all three for the day-by-day ledger AND
-- for a retention-by-first-payment-month table, and 281 payers from trials of 16 Aug to 4 Sep 2026
-- predate the columns: first_debit_at IS NULL, debit_count = 0, yet current_period_end > trial_end
-- proves a paid period was granted, not just a trial. (284 rows including 3 internal accounts; a
-- fourth-class row, a hand-granted comp running to 2037, is excluded by the 90-day guard below.)
--
-- PhonePe cannot supply the missing settle time — its subscription-status API returns mandate state
-- only, and every settle nulls redemption_order_id — so the row itself has to answer, from three facts:
--
--   1. Each such row was debited exactly ONCE before 8 Sep. A second debit after 8 Sep would have
--      stamped the row (it wouldn't be in this WHERE clause), so debit_count becomes 1 and
--      paid_paise becomes 19900 (one ₹199 charge) on every row this touches, unconditionally.
--   2. Every grant sets current_period_end to settle time + 1 month via JavaScript's
--      Date.setMonth(getMonth()+1) (addOneMonth, workers/src/cron/autopay-notify.ts ~L822), and
--      JavaScript OVERFLOWS a short month instead of clamping: 31 Aug + 1 month lands on 1 Oct — a
--      31-day step — not 1 Oct via 30 Sep. Postgres does not know this: current_period_end -
--      interval '1 month' gives 1 Sep for a row that actually settled 31 Aug — wrong day AND wrong
--      month. 28 of these 281 rows settled 31 Aug 2026 and carry current_period_end = 1 Oct 2026.
--   3. updated_at still equals the settle time on 274 of the 281 rows: the settle UPDATE sets
--      updated_at = now() in the very same statement, and nothing has touched those rows since. On
--      those, current_period_end - updated_at is a whole number of days (28..31) to within 5 seconds,
--      so updated_at recovers the true settle time exactly and sidesteps the JS-month trap in fact 2
--      entirely — it is preferred over the interval-arithmetic fallback for that reason. The other 7
--      rows (6 cancelled, 1 pending) were touched again after settling, so updated_at on those is a
--      later cancel/touch time, not the settle time; they fall back to current_period_end -
--      interval '1 month', which repeats the fact-2 error on any row that actually settled on the
--      29th, 30th or 31st of a month.
--
-- Additive and idempotent: it only UPDATEs existing rows, adds no column, and its WHERE clause
-- matches nothing once a row is stamped — re-running this after it has already run touches zero rows.
--
-- Internal accounts (users.is_internal) are included here ON PURPOSE. These three columns are ledger
-- data carried on the subscriptions row, not a user-facing metric — the CMS's own subscriptions
-- queries filter is_internal out where that matters. Excluding internal rows here would just leave a
-- handful of them permanently unstamped for no reason.
--
-- Apply by hand on Neon, same as every migration in this directory.

update subscriptions
set
  first_debit_at = case
    when current_period_end - updated_at
           between interval '27 days 23 hours' and interval '31 days 1 hour'
     and (
           mod(extract(epoch from (current_period_end - updated_at))::numeric, 86400) < 5
        or mod(extract(epoch from (current_period_end - updated_at))::numeric, 86400) > 86395
         )
    then updated_at
    else current_period_end - interval '1 month'
  end,
  debit_count = 1,
  paid_paise = 19900
where first_debit_at is null
  and debit_count = 0
  and trial_end is not null
  and current_period_end is not null
  and current_period_end > trial_end
  -- One debit grants one month, and the ladder runs 45 days, so a real single-debit row ends within
  -- 76 days of its trial. A period further out was granted by hand (one comp row runs to 2037) and
  -- was never a ₹199; it stays unstamped.
  and current_period_end - trial_end < interval '90 days';

-- Proof, run by hand before and after on Neon:
--
-- -- (i) rows this migration will touch — 281 before, 0 after.
-- select count(*)
-- from subscriptions
-- where first_debit_at is null
--   and debit_count = 0
--   and trial_end is not null
--   and current_period_end is not null
--   and current_period_end > trial_end
--   and current_period_end - trial_end < interval '90 days';
--
-- -- (ii) per-month tally of first payments, IST, non-internal only — the August and September
-- -- cohorts this backfill recovers.
-- select to_char(s.first_debit_at at time zone 'Asia/Kolkata', 'YYYY-MM') as month,
--        count(*)
-- from subscriptions s
-- join users u on u.id = s.user_id
-- where s.debit_count = 1
--   and not u.is_internal
-- group by 1
-- order by 1;

-- One row's month is genuinely ambiguous and is accepted as-is: a `pending` row with trial_end
-- 31 Aug 2026 07:45 UTC and current_period_end 1 Oct 2026 08:15 UTC, touched again on 2 Sep (so
-- updated_at cannot be used). The fallback places its first_debit_at on 1 Sep 2026, though it could
-- just as well have settled 31 Aug 2026 — the same JS-month overflow that makes fact 2 true elsewhere
-- makes this one row's true day unrecoverable. It is one row; the fallback's answer is accepted.
