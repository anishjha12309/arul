-- Arul — a dead registration is not a failure; the registry prunes itself between campaigns.
-- Read docs/push.md first.
--
-- WHY `push_campaigns.gone` IS ITS OWN COUNTER, OUTSIDE `total`. A 404 UNREGISTERED is a phone that
-- uninstalled — nobody there could have been reached by any campaign, so counting it in Failed told
-- the editor the send went wrong when the audience had simply shrunk. The drain moves such a
-- delivery here and takes it OUT of total, so at completion total = sent + failed and the card's
-- progress bar still reads (sent + failed) / total mid-drain. The delivery row keeps status 'failed'
-- and its error string: that is the audit trail, and this column is only the card's number.
--
-- WHY `push_devices.token_checked_at` EXISTS. Until now a dead registration was found only during a
-- send, so between campaigns the dead rows piled up and every one cost a failed delivery on the
-- next one. The every-minute dispatch tick, when idle, dry-runs a slice of the registry against FCM
-- (`validate_only`) and stamps the survivors here; ordering by it NULLS FIRST is the cursor that
-- walks every row before revisiting any. NULL means never checked, which is what every row starts as.
alter table push_campaigns add column if not exists gone integer not null default 0;
alter table push_devices add column if not exists token_checked_at timestamptz;
