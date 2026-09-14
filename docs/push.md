# Campaign push — CMS composes, the Worker sends

Read before touching `workers/src/lib/fcm.ts`, `workers/src/cron/push-dispatch.ts`,
`lib/features/push/**` or the CMS's Notifications page. Local reminders are a different feature with
its own rules: [notifications.md](notifications.md).

## The one path

```
CMS composer ──insert──▶ push_campaigns (Arul Neon)              status: scheduled
      └─POST /internal/push/dispatch (ARUL_API binding, PUSH_SECRET)   "send now" only
Arul Worker cron "* * * * *"
      ├─ claims campaigns due (send_at <= now(), status scheduled) → fans the audience out
      ├─ claims ≤600 pending deliveries per batch FOR UPDATE SKIP LOCKED, sends at concurrency 6
      └─ no pending rows left → status = sent
FCM HTTP v1 → phone shows it → tap → getInitialMessage()/onMessageOpenedApp
      → deep-link target → POST /me/push-opened → GA4 `push_opened`
```

**No topics, no Queues.** The audiences on offer ("hasn't opened in 30 days", "is paying") are not
expressible as topics and are one join away in the registry; once every send is a per-device request,
topics are a second code path buying nothing. The claim loop is plain SQL on the table the CMS already
reads for progress, so it needs no new binding, and the wall clock bounds a tick, not the subrequest
cap. **Its own cron trigger**, like autopay: a 60k-phone drain must never share a budget with the
catalog rebuild, and a send that stops halfway is invisible — nobody reports a notification that never
arrived.

## The fid is the IDENTITY, the token is the TARGET

FCM's REST reference marks `message.token` deprecated in favour of `message.fid`, so this shipped
targeting the fid — and a real registered phone refused it. Identical payload, same minute:

```
{ fid:   "eme780…" }               -> HTTP 404 { errorCode: "UNREGISTERED" }
{ token: "eme780…:APA91b…" }       -> HTTP 200
```

**Believe the device over the reference.** `SEND_BY` in `lib/fcm.ts` is the one switch and it is
`"token"`; retest both before flipping it back, and never hedge with a per-device fallback — a silent
second path is how "it works on some phones" starts. The fid still earns the primary key: it survives
token rotation, so a phone keeps one row through a refresh instead of one row per token.

A row with no token is registered but **unreachable** until `onTokenRefresh` fills it in. `sendPush`
fails that delivery with `NO_TOKEN` rather than putting the fid in the token field — that comes back
UNREGISTERED, and the caller would delete a row that was only ever missing a column.

## Notification messages by default — never a Dart background handler

About 70% of this base runs a vivo/Xiaomi/OPPO/realme battery manager that kills a background isolate
on sight. A notification message is posted by Google Play services without waking the app, so it
survives everything short of a user force-stop. It is also what keeps `priority: HIGH` honest:
Android 13 downgrades an app that consistently sends high-priority messages producing no
notification, and every message here produces one.

**The one exception is a coloured campaign, decided per campaign AND per phone.** FCM's `color`
tints the small icon only, so a true card background means the app draws the notification. When
`push_campaigns.color` is set AND the phone's build number is `>= COLOR_MIN_BUILD` (76, `lib/fcm.ts`)
— `app_build % 1000`, because per-ABI builds register 1000 × abiCode + build (a build-75 phone in the
production registry reports 2075),
the Worker sends a data-only message: no `notification` block, the texts, picture, colour, channel
and tag in `data`, `android.collapse_key` = the campaign id. Every other campaign, and a coloured
one to an older or unknown build, is the notification message above, unchanged. The plain path stays
the default because it is the one that needs no app code alive; the coloured path trades that for the
look and is only as reliable as `ArulMessagingService` getting its short `onMessageReceived` window.

`ArulMessagingService` (Kotlin, `android/…/push/`) subclasses the plugin's
`FlutterFirebaseMessagingService` and replaces its manifest entry — one service may own
`MESSAGING_EVENT`, and the inherited `onNewToken` is what keeps Dart's `onTokenRefresh` alive. It
posts on `arul_updates_v1` with `DecoratedCustomViewStyle`: collapsed and expanded `RemoteViews`
whose root background is the colour, text white when white reaches a 3.0 contrast ratio, else
`#1b1b1f` (the CMS preview runs the same formula). The picture downloads under one 5 s deadline and
is dropped, never the notification, when it misses. Before posting it writes the message into
`FlutterFirebaseMessagingStore` and puts `google.message_id` on the tap intent — the plugin's
receiver stores only messages with a notification block, and that store plus that extra are all
`getInitialMessage()` / `onMessageOpenedApp` read. So the tap path, `/me/push-opened` and GA4
`push_opened` are identical on both paths. FCM's own automatic `notification_open` Analytics event
exists only for notification messages; coloured campaigns do not produce it.

- **Android 12+ keeps the header system-styled.** A decorated custom view sits inside the system
  template: the icon, app name and time row are the system's, the content area carries the colour.
  That is the accepted result, not a bug to chase with an undecorated view.
- **A coloured campaign posts even while the app is open** — a data message always reaches the
  service. Plain campaigns are still ignored in the foreground.

**Registering no handler is what keeps the isolate out — the plugin does not check first.**
`FlutterFirebaseMessagingReceiver` enqueues `FlutterFirebaseMessagingBackgroundService`
unconditionally for every background message, so the app PROCESS does start. The executor then reads
the stored callback handle and, finding none, starts no Flutter isolate (verified on device: process
up, zero Dart frames). Register `onBackgroundMessage` anywhere and that gate opens for every message.

**An offline phone gets only the LATEST plain campaign.** FCM keeps notification messages
collapsible, keyed by package, and ignores `collapse_key` — measured with a shared key and a
per-campaign key alike: two sends in airplane mode, one arrived, both delivery rows `sent`. The price
of the rule above; Sent counts what FCM accepted, never what a phone showed.

**Expiry is `android.ttl`.** The editor picks 1, 6 or 24 hours (`push_campaigns.expires_hours`, a
checked column defaulting to 24, what every earlier campaign was sent with); a phone that stays
offline longer than that never gets the campaign.

**A force-stopped app receives nothing at all.** `adb shell am force-stop` sets Android's stopped
flag and the FCM broadcast is refused outright (`GCM: broadcast intent callback: result=CANCELLED`)
until a human launches the app again. To test the killed-app path use `adb shell am kill`, which drops
the process without the flag.

**The foreground is ignored.** `onMessage` logs one line — a notification over the app someone is
already using answers nothing.

## Data model (`db/schema/17_push.sql`, `18_push_journey.sql`)

`push_devices` (fid PK, user_id NULLABLE, token, lang, app_build, android_sdk, last_seen_at, created_at) ·
`push_campaigns` (status, texts jsonb, dest, dest_id, image_url, audience jsonb, color, expires_hours,
send_at, counters) · `push_deliveries` ((campaign_id, fid) PK, status, error) ·
`push_opens` ((campaign_id, user_id) PK).

**Phones register before sign-in.** The app registers on every launch: signed out through the
unauthenticated `POST /push/device` (2 KB body cap, upsert on `fid` that NEVER writes `user_id`),
signed in through `/me/device` (which re-points it). A `user_id` of NULL is a phone that has never
signed in; sign-out never nulls it, so "one phone is one signed-in user" still holds. Junk rows from
the open route cost nothing: an unroutable token comes back UNREGISTERED on its first send and is
deleted. `push_opens.user_id` stays NOT NULL, so a never-signed-in phone's tap is not recorded
server-side — GA4 `push_opened` still fires.

**The permission prompt did not move** (below), so on Android 13+ a phone that never signed in is
counted in every audience that includes it and shows nothing until it signs in and allows
notifications. The CMS says so under the audience picker.

Why each key is shaped that way is in the schema file's own comments. The two rules that are NOT
there: cleanup rides the `30 21 * * *` cron (deliveries over 30 days, devices idle over **270 days**
— FCM garbage-collects an Android registration at that age — and `push/` objects over 90 days whose
campaign row is gone); and **only a 404 `UNREGISTERED` or a 400 `INVALID_ARGUMENT` deletes a device
row**, never a quota error or an outage.

## Audience — ONE home

`audienceQuery` in `workers/src/lib/push-audience.ts`, and nowhere else. The CMS never writes a line
of it: it POSTs the audience JSON to `/internal/push/count` and stores the same JSON on the row, so
the count and the send can never disagree. `premium` states import `premiumPredicate` and pass
`sql`d.user_id`` so the EXISTS correlates per row — **never re-derive entitlement** (CLAUDE.md §5).
`lapsed` is "subscribed once AND not entitled now", excluding a cancelled user still inside a paid
period: telling someone who is paying today that their subscription stopped is the one message this
segment must never send. `trialing` is the `trialing` status OR a `cancelled` row whose `trial_end`
is still ahead — removing the mandate mid-trial flips the status, and until 2026-09-14 that person
belonged to no plan at all (not lapsed, because still entitled; not free, because a row exists).

**Every kind LEFT JOINs users**, reading the flag as `NOT coalesce(u.is_internal, false)`, so `all`
now includes phones that never signed in. Every plan state also requires `d.user_id IS NOT NULL` —
a phone with no account has no subscription row and would otherwise read as `free`. The composer
builds one combinable kind, `{kind:"filter", lang?, plan?, idle_days?: 7|14|30, joined_hours?:
1|24|168, signed_in?}`, ANDing whatever was picked; `joined_hours` bounds `d.created_at` through a
bound interval like `inactive`. A filter with nothing picked parses to null (it would mean everyone),
and so does `plan` with `signed_in:false` (a contradiction). `lang`, `premium` and `inactive` keep
parsing: scheduled and historical rows carry them.

**Internal accounts are excluded from every kind but `internal`.** That kind reaches nobody else,
and it is offered TWO ways: the "Send to my phone" button (send-now, writes a `cancelled` draft) and
"My own phones" in the audience picker. The picker entry is what makes a SCHEDULED notification
testable at all — every other audience excludes the owner, so without it the cron path could never be
walked on a real device. Never match an account by email substring.

## Permission — once, after sign-in, on the feed

Asked on the first home-feed frame after a successful sign-in. **Never on the sign-in wall, never
during the Google flow**: a dialog stacked on Credential Manager is the interruption that costs
sign-ins, the number this app is judged on. `arul_push_prompted` is set the moment the OS answers,
whatever it answered — Android stops showing the dialog after two refusals, so a third ask reads back
as a fresh refusal. The reminders toggle keeps its own separate opt-in.

## The channel is created at launch, not at opt-in

`arul_updates_v1`, `Importance.defaultImportance`, no custom sound, created in
`NotificationService.initialize()` on every launch. Three load-bearing reasons: FCM falls back to the
manifest's `default_notification_channel_id` when the payload's channel was never created, so it must
exist before any message arrives; on Android 8–12 there is no runtime permission, so the **channel is**
the user's only control; and a phone upgrading to 13 is pre-granted only if a channel already exists.

**The id is immutable once a device has seen it** — a new one appears as a second, empty toggle in
system settings. The NAME is mutable, which is how `pushChannelNameProvider` localizes it.

## Per Android version

| Android | What governs delivery |
| --- | --- |
| 7.0–7.1 (24–25, the `minSdk`) | No channels. `notification_priority: PRIORITY_DEFAULT` in the payload is what applies; from 8.0 the channel importance overrides it. No permission. |
| 8.0–12 (26–32) | The `arul_updates_v1` channel governs visibility and the user's mute. `requestPermission()` returns authorized with no dialog. |
| 12+ (31+) | **Notification trampolines**: the tap must be a PendingIntent straight to an activity. FCM's default click opens the launcher activity. Never route a tap through a BroadcastReceiver or Service. |
| 13+ (33+) | Runtime `POST_NOTIFICATIONS`, off by default on a fresh install. The FCM SDK declares the permission in its own manifest — ours merges with it; check the merged manifest lists it ONCE. |
| 14–16+ (34+) | Nothing changes for plain notifications. Never set `ongoing` (14 lets users dismiss it anyway); an app in a locked Private Space showing none (15) is expected, not a bug. |

Cross-version: **pictures** are downloaded and shown by the FCM SDK itself, no app code running (a
catalog thumb renders as `BigPictureStyle`, verified on device); JPEG and PNG have full support, WebP
"varies", so the CMS stores JPEG only, and a failed download degrades to text-only, never to nothing.
**No Google Play services** → registration throws, is caught, and the phone is silently unreachable.

`MainActivity` carries `clearTaskOnLaunch` (it fixes a stale-Google-picker defect — do not remove it)
and `onNewIntent` does not fire on a launcher relaunch, so **both tap paths need proving on a real
phone**: app killed → `getInitialMessage()`, and app backgrounded → `onMessageOpenedApp`.

## Backwards compatibility

Only additive routes and tables; `GET /me` untouched; no new required field. Builds already in the
field keep working and simply cannot be reached — **a registration exists only once the app asks for
one, so no backfill is possible**; expect about a fortnight to reach most of the active base.

An unreadable payload — unknown `dest`, a deleted wallpaper, a retired category — opens the app.
`pushTargetFor` never throws and never returns an error screen: the person tapped a notification we
chose to send them.

## CMS ↔ Worker contract

The CMS writes `push_campaigns` and reads counts; the Worker sends. **The Firebase service-account key
lives in the Worker and never reaches the CMS**, so a bug on the page can mis-address a campaign but
cannot send one. `PUSH_SECRET` guards `/internal/push/{count,dispatch,test}` and is a THIRD secret,
never `CATALOG_BUILD_SECRET` — one string must not authorize both "rebuild the catalog" and "message
every user". It fails closed when unset; the CMS holds it as `ARUL_PUSH_SECRET`.

Uploaded pictures land at `push/<uuid>.jpg`, **outside `CANONICAL_PREFIXES`**, so the orphan sweep can
never reclaim them; the daily push sweep is their only cleanup. A campaign bumps no `content_version`
and triggers no rebuild — a notification is not content.

**The history filters in SQL, never in the page.** Scheduled date (IST), language and audience kind
are read off the query string, checked against closed sets and bound; the clauses no-op on NULL so
one prepared statement serves every combination. Filtering the rendered list instead would lie the
moment the history passed the 100-row cap — the match would sit at row 140 and never be fetched. A
filtered view is a URL, so it survives a reload and can be shared, and the 5 s send poll carries the
filters or it would swap the filtered list for the whole history mid-read. `audience->>'kind'` on a
legacy double-encoded row returns NULL rather than erroring, so such a row drops out of a filter
instead of breaking the page.

**Delete removes the record, not the message.** A campaign already delivered stays in the drawer on
every phone that has it; the row's Sent and Opened numbers are what go. `push_deliveries` and
`push_opens` follow on `on delete cascade`, and an uploaded picture is left to the daily sweep, which
already reclaims a `push/` object whose campaign row is gone. A campaign in `sending` cannot be
deleted: those delivery rows ARE the idempotency record, and cascading them out from under a running
batch would let the retry send the same notification to the same phone twice. The guard lives in the
DELETE's own WHERE, never in a read before it, so the cron cannot claim the row in between.

## Going live

`PUSH_ENABLED` (`[vars]` in `workers/wrangler.toml`) must be exactly `"true"` or the cron and
`/internal/push/dispatch` claim nothing; `/internal/push/test` and `/internal/push/count` work either
way, which is what lets the chain be proven on internal phones while production stays dark.
**Flipping it is the owner's call.** Rehearse with `node tools/cron-rehearse.mjs push --allow-push` —
nothing local can intercept an FCM send, so the debug branch's registry is what bounds the blast.
