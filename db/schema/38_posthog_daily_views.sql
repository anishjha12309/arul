-- Daily totals for PostHog's warehouse (posthog_reader): renewal outcomes and the ₹99 win-back pushes. Totals only,
-- never a person's row: order_outcomes' 12-month prune and account-deletion cascade cannot reach a synced copy, and
-- a view recomputed on every full-refresh sync carries both (docs/order-outcomes.md §Retention and privacy).
create or replace view posthog_renewal_outcomes_daily as
select (coalesce(occurred_at, observed_at) at time zone 'Asia/Kolkata')::date as on_date,
       phonepe_state                                                      as final_state,
       coalesce(error_source, '')                                         as error_source,
       coalesce(detailed_error_code, error_code, '')                      as error_code,
       amount_paise,
       count(*)                                                           as orders,
       count(distinct user_id)                                            as people
from order_outcomes
where event = 'closed'
group by 1, 2, 3, 4, 5;

create or replace view posthog_winback_daily as
select (created_at at time zone 'Asia/Kolkata')::date as on_date, 'series'::text as kind, day + 1 as series_day, state,
       coalesce(skip_reason, '') as skip_reason, count(*) as people
from winback_series
group by 1, 2, 3, 4, 5
union all
select (coalesce(resolved_at, created_at) at time zone 'Asia/Kolkata')::date,
       case when prior_status = 'trialing' then 'revoke_trial' else 'revoke_paid' end, null::int, state,
       coalesce(skip_reason, ''), count(*)
from winback_pushes
group by 1, 2, 3, 4, 5;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'posthog_reader') then
    grant select on posthog_renewal_outcomes_daily, posthog_winback_daily to posthog_reader;
  end if;
end $$;
