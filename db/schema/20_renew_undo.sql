-- Never read by the app: build-catalog deletes it from the JSON (a CMS bookkeeping column, not content).

alter table wallpapers add column if not exists pre_renew_published_at timestamptz;
alter table ringtones  add column if not exists pre_renew_published_at timestamptz;
