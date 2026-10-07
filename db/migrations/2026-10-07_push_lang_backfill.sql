-- One-off fill of push_campaign_langs for campaigns sent before the Worker counted per language. Not a
-- schema file: a fresh database has no sent campaigns, so replaying it there is pointless.
-- Apply BEFORE the Worker that writes push_campaign_langs deploys. After it, the first tap on an old
-- campaign gives that campaign a row, and this file then skips the campaign for good.
-- approximate: deliveries are grouped by the phone's CURRENT language, and the daily sweep has already
-- deleted deliveries over 30 days old, so an older campaign gets its opens and nothing else.
-- Idempotent: a campaign that has any row is skipped, so a re-run inserts nothing.

with todo as (
  select c.id, c.audience->>'kind' = 'internal' as counts_test_accounts
  from push_campaigns c
  where c.status = 'sent'
    and not exists (select 1 from push_campaign_langs l where l.campaign_id = c.id)
),
delivered as (
  select d.campaign_id, coalesce(pd.lang, 'unknown') as lang, d.status,
         -- The error text sendOneBatch writes for a dead registration (lib/fcm.ts isDeadRegistration).
         coalesce(d.error = 'device_gone'
                  or starts_with(d.error, 'UNREGISTERED:')
                  or starts_with(d.error, 'INVALID_ARGUMENT:'), false) as dead
  from push_deliveries d
  join todo t on t.id = d.campaign_id
  left join push_devices pd on pd.fid = d.fid
  left join users u on u.id = pd.user_id
  where t.counts_test_accounts or not coalesce(u.is_internal, false)
),
by_lang as (
  select campaign_id, lang,
         count(*) filter (where status = 'sent') as sent,
         count(*) filter (where status = 'failed' and not dead) as failed,
         count(*) filter (where status = 'failed' and dead) as gone
  from delivered
  group by campaign_id, lang
),
opens as (
  select o.campaign_id, coalesce(latest.lang, 'unknown') as lang, count(*) as opened
  from push_opens o
  join todo t on t.id = o.campaign_id
  left join users u on u.id = o.user_id
  left join lateral (
    select pd.lang from push_devices pd
    where pd.user_id = o.user_id
    order by pd.last_seen_at desc
    limit 1
  ) latest on true
  where t.counts_test_accounts or not coalesce(u.is_internal, false)
  group by o.campaign_id, coalesce(latest.lang, 'unknown')
)
insert into push_campaign_langs (campaign_id, lang, sent, failed, gone, opened, approximate)
select coalesce(b.campaign_id, o.campaign_id), coalesce(b.lang, o.lang),
       coalesce(b.sent, 0), coalesce(b.failed, 0), coalesce(b.gone, 0), coalesce(o.opened, 0), true
from by_lang b
full join opens o on o.campaign_id = b.campaign_id and o.lang = b.lang
on conflict (campaign_id, lang) do nothing;
