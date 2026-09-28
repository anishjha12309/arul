-- posthog_reader — PostHog's data-warehouse source. It reads subscriptions (no personal data: ids,
-- status, UPI app, debits) and the ids of internal accounts, nothing else, never users.email/display_name.
-- The ROLE and its password are made by hand (a password never lives in git) -> on a database without
-- the role, the grants are skipped and the file still applies.
create or replace view posthog_internal_users as select id from users where is_internal;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'posthog_reader') then
    grant usage on schema public to posthog_reader;
    grant select on subscriptions, posthog_internal_users to posthog_reader;
    alter role posthog_reader set default_transaction_read_only = on;
    alter role posthog_reader set statement_timeout = '60s';
  end if;
end $$;
