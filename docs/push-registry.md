# Push registry — which phones a campaign can reach

Read before touching `POST /push/device`, `POST /me/device` (`workers/src/routes/me.ts`) or the prune
and sweep in `workers/src/cron/push-dispatch.ts`. Sending and audiences: [push.md](push.md).

## The fid is the IDENTITY, the token is the TARGET

FCM's reference deprecates `message.token` for `message.fid`, yet a registered phone refused the fid —
same payload, same minute: `{fid}` → 404 `UNREGISTERED`, `{token}` → 200.
**Believe the device over the reference.** `SEND_BY` in `lib/fcm.ts` is the one switch and it is
`"token"`; retest both before flipping it, and never hedge with a per-device fallback — a silent second
path is how "it works on some phones" starts. The fid still earns the primary key: it survives token
rotation, so a phone keeps one row.

A row with no token is registered but unreachable until `onTokenRefresh` fills it. `sendPush` fails
that delivery `NO_TOKEN` rather than putting the fid in the token field — that answers UNREGISTERED and
the row would be deleted for a missing column. Such a row is in NO audience.

## The registry

**Phones register before sign-in, on every launch:** signed out through the public `POST /push/device`
(upsert on `fid` that NEVER writes `user_id`), signed in through `/me/device`, which re-points it.
`user_id` NULL = never signed in; sign-out never nulls it. `push_opens.user_id` stays NOT NULL, so a
never-signed-in phone's tap is recorded in GA4 only. On Android 13+ such a phone stays registered but is
in no audience until it signs in and allows notifications ([push.md](push.md) §Audience).

**Only a 404 `UNREGISTERED` or a 400 `INVALID_ARGUMENT` deletes a device row** — never a quota error or
an outage. **A dead registration is not a failure:** an UNREGISTERED delivery, or one whose device row
is gone, counts in `push_campaigns.gone` and leaves `total`, so a finished campaign reads total = sent
+ failed; the delivery row keeps `failed` and its error as the audit trail.

**The registry prunes itself between campaigns.** A `* * * * *` tick that started and drained nothing
dry-runs a slice of registrations (`validate_only: true` answers 404 for a dead token and 200 without
delivering), oldest `token_checked_at` first, deletes the dead and stamps the rest; token-less rows
unseen for 7 days go too. **So the registry mirrors who STILL HAS the app; a low row count is not a
registration defect.** Judge REGISTRATION by coverage within 30 minutes of sign-up, REACH against GA4
`first_open` minus `app_remove` — never "rows ÷ sign-ups" over a multi-day cohort.

Daily cleanup rides `30 21 * * *`: deliveries over 30 days, devices idle over **270 days** (FCM's own
garbage-collection age), and `push/` pictures whose campaign row is gone.
