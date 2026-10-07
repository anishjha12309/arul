-- Read docs/push.md first.
-- Phones a campaign skipped because they cannot show it yet (Android 13+, never signed in), stamped
-- at fan-out. NULL = a campaign from before the rule. The Worker writes it -> apply BEFORE its deploy.
alter table push_campaigns add column if not exists left_out int;
