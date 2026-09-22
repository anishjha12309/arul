-- Arul — push journey audiences, campaign colour, campaign expiry. Read docs/push.md first.
--
-- WHY `push_devices.user_id` WENT NULLABLE. The app now registers on first launch, before sign-in, so
-- the CMS can reach "joined in the last hour" and "never signed in". A NULL user_id is exactly that
-- phone. "One phone is one signed-in user" still holds: sign-in re-points the row through
-- /me/device, and nothing ever nulls it again — sign-out leaves the last account on the row, and the
-- anonymous /push/device upsert never touches the column. The FK and its delete-account cascade stay.
--
-- WHY `color` IS A SWITCH AND NOT DECORATION. FCM's notification `color` tints the icon only. A true
-- card background needs the app to draw the notification itself, so a non-NULL colour makes the
-- sender go data-only for builds that carry the native renderer; NULL keeps the notification-message
-- path byte for byte. Lowercase `#rrggbb` only — the Kotlin parser and the CMS contrast rule both
-- assume it.
--
-- WHY `expires_hours` IS BOUNDED. It becomes `android.ttl`. The CMS offers 1 / 6 / 24 hours, and 24 is
-- what every campaign before this file was sent with, hence the default; anything else is a value
-- the editor never chose.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_name = 'push_devices' and column_name = 'user_id' and is_nullable = 'NO') then
    alter table push_devices alter column user_id drop not null;
  end if;
end $$;

alter table push_campaigns add column if not exists color text;
alter table push_campaigns add column if not exists expires_hours int not null default 24;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'push_campaigns_color_check') then
    alter table push_campaigns add constraint push_campaigns_color_check
      check (color is null or color ~ '^#[0-9a-f]{6}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'push_campaigns_expires_hours_check') then
    alter table push_campaigns add constraint push_campaigns_expires_hours_check
      check (expires_hours in (1, 6, 24));
  end if;
end $$;

-- The "joined in the last …" audiences bound on created_at.
create index if not exists push_devices_created_idx on push_devices(created_at);
