-- Which UPI app the mandate was handed to at /payments/initiate: the Android package on the direct
-- intent path, the literal `phonepe_page` on the SDK/hosted-page path (including the fallback after a
-- failed intent setup). Written at initiate, overwritten if the flow falls back, read at the FIRST
-- trial->paid settle so PostHog `subscription_active` can say which app completed the mandate.
-- Nullable: rows that predate the column report `unknown`.
alter table subscriptions add column if not exists upi_target_app text;
