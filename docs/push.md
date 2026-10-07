# Campaign push — the CMS composes, the Worker sends

Read before touching `workers/src/lib/{fcm,push-audience}.ts`, `workers/src/cron/push-dispatch.ts` or
`lib/features/push/**`. The channel, the permission and the per-Android rules:
[notifications.md](notifications.md). Registration, the fid/token split and the prune:
[push-registry.md](push-registry.md).

## The one path

```
CMS ──insert──▶ push_campaigns    (+ POST /internal/push/dispatch over ARUL_API for "send now")
cron "* * * * *" ─ claims due campaigns → fans out push_deliveries → claims them SKIP LOCKED → FCM v1
phone → tap → getInitialMessage()/onMessageOpenedApp → target → POST /me/push-opened
```

**No topics, no Queues:** the audiences are one join away in the registry and not expressible as topics,
so topics would be a second code path buying nothing. **Its own cron trigger** ([cron.md](cron.md)): a
send that stops halfway is invisible — nobody reports a notification that never arrived.

## Notification messages for older builds — never a Dart background handler

From `HEADSUP_MIN_BUILD` every campaign is data-only (§Drawn campaigns); this section is why the rest
stay notification messages. Most of this base runs a vivo/Xiaomi/OPPO/realme battery manager that kills
a background isolate on sight. A notification message is posted by Google Play services without waking the app, so it survives
everything short of a force-stop. It also keeps `priority: HIGH` honest: Android 13 downgrades an app
whose high-priority messages produce no notification, and every message here produces one.

**Registering no handler is what keeps the isolate out — the plugin does not check first.**
`FlutterFirebaseMessagingReceiver` starts the background service for every message, so the PROCESS
does start; finding no stored callback handle, it starts no Flutter isolate (verified: process up, zero
Dart frames). Register `onBackgroundMessage` anywhere and that gate opens for every message.

- **An offline phone gets only the LATEST plain campaign.** FCM keeps notification messages collapsible
  per package and ignores `collapse_key` (measured: two sends in airplane mode, one arrived, both rows
  `sent`). Sent counts what FCM accepted, never what a phone showed.
- **Expiry is `android.ttl`** from `push_campaigns.expires_hours` (1, 6 or 24); a phone offline longer
  never gets the campaign.
- **A force-stopped app receives nothing** — Android's stopped flag refuses the broadcast until a human
  launches the app. Test the killed path with `adb shell am kill`, never `am force-stop`.
- **The foreground is ignored** for plain campaigns — `onMessage` logs one line.

## Drawn campaigns

A true card colour, a heads-up and the lock-screen rule need the app to draw the card, so the Worker
sends data-only (`lib/fcm.ts`; build = `app_build % 1000`, as per-ABI builds register 1000 × abiCode +
build): texts, picture, colour, channel, tag and `visibility` in `data`, `android.collapse_key` = the
campaign id. This path is only as reliable as `ArulMessagingService`'s short `onMessageReceived` window.

- **Build >= `HEADSUP_MIN_BUILD`: every campaign**, with `channel_id: arul_campaigns_v1`; the service
  posts there only if Dart created it, else on `arul_updates_v1` ([notifications.md](notifications.md)).
  Plain = BigPicture (FCM's thumbnail-then-picture, which the CMS preview draws) or BigText.
- **`COLOR_MIN_BUILD` to below it: coloured campaigns only**; older or unknown builds get plain messages.
- **`HEADSUP_MIN_BUILD` = the versionCode of the release that ships the channel.** Set lower, a plain
  campaign to the builds in between posts NOTHING: their service skips a data message with no colour.
- **Lock screen:** content campaigns are PUBLIC (`android.notification.visibility` on the plain path);
  a `premium` campaign keeps Android's PRIVATE default — nothing may monetize the locked display (Play
  Ads policy). Never a full-screen intent, a category, another app's promo or an OS look-alike.

- `ArulMessagingService` subclasses the plugin's `FlutterFirebaseMessagingService` and replaces its
  manifest entry — one service may own `MESSAGING_EVENT`, and the inherited `onNewToken` keeps Dart's
  `onTokenRefresh` alive. The picture gets one 5 s deadline and is dropped, never the notification.
- **Before posting it writes the message into `FlutterFirebaseMessagingStore` and puts
  `google.message_id` on the tap intent** — the plugin stores only messages with a notification block,
  and those two are all `getInitialMessage()`/`onMessageOpenedApp` read. That keeps the tap path and
  `/me/push-opened` identical on both paths. FCM's automatic `notification_open` exists for plain
  campaigns only.
- Android 12+ keeps the header row system-styled — accepted. A coloured campaign posts even in the
  foreground: a data message always reaches the service.

## Audience — ONE home

`audienceQuery` in `workers/src/lib/push-audience.ts`, nowhere else. The CMS POSTs the audience JSON to
`/internal/push/count` and stores the same JSON on the row, so the count and the send cannot disagree.
Plan states import `premiumPredicate` — **never re-derive entitlement** (CLAUDE.md §1).

- `lapsed` = subscribed once AND not entitled now, excluding a cancelled user still inside a paid
  period: telling someone paying today that their subscription stopped is the one message this segment
  must never send. `trialing` = the status OR a `cancelled` row whose `trial_end` is still ahead —
  removing the mandate mid-trial flips the status.
- Every kind LEFT JOINs users, so `all` includes never-signed-in phones; every plan state requires
  `d.user_id IS NOT NULL`, or a phone with no account reads as `free`.
- **No kind includes an Android 13+ phone that never signed in:** the permission is asked only after
  sign-in, so it cannot show anything. NULL `android_sdk` stays in (through `coalesce`, or NOT NULL would
  drop it). `includeWaiting` drops only that clause, to count: `/internal/push/count` adds
  `waiting_sign_in`, fan-out stamps `push_campaigns.left_out` (db/schema/31 lands BEFORE the Worker).
- The composer builds one combinable `filter` kind, ANDing what was picked. Nothing picked parses to
  null (it would mean everyone), and so does `plan` with `signed_in:false`. Legacy kinds keep parsing.
- **Test accounts (`users.is_internal`) receive every real campaign; Play's robots
  (`%@cloudtestlabaccounts.com`) receive none.** The flag only moves numbers: `total`, `sent`/`failed`
  (`countsTestAccounts`) and Opened skip test phones, except on an `internal` campaign ("Send to test
  accounts" = a send-now `internal` campaign through `/internal/push/dispatch`).
- **Per-language numbers live in `push_campaign_langs`**: the daily sweep deletes deliveries at 30 days.
  A batch adds them by the same rule under each delivery's `lang` (stamped at fan-out — the device row
  can be gone by the batch), in the counters' transaction and from the same tallies, so the rows sum to
  the counters. An open adds one only when `push_opens` inserts. `approximate` = filled once from
  current phone languages.

## Taps

- **Every tap routes through `PushTapRouter`.** Past the launch it ends in a `go`, which replaces whatever
  covers the shell — a target that only PARKED stayed behind `/premium` or a pushed screen. On the
  splash or sign-in the destination is HELD until the launch reaches another screen: phones register
  signed out, so an immediate `go` would skip the wall. `home` routes nowhere.
- **Both tap paths need proving on a real phone** — `clearTaskOnLaunch` is on MainActivity and
  `onNewIntent` does not fire on a launcher relaunch: killed → `getInitialMessage()`, backgrounded →
  `onMessageOpenedApp`.
- An unreadable payload (unknown `dest`, a deleted wallpaper, a retired category) opens the app:
  `pushTargetFor` never throws and never shows an error screen.

## CMS ↔ Worker contract

- **The Firebase service-account key lives in the Worker and never reaches the CMS** — a bug on the page
  can mis-address a campaign but cannot send one. `PUSH_SECRET` guards `/internal/push/*`, fails closed
  when unset; the CMS holds it as `ARUL_PUSH_SECRET`.
- Uploaded pictures land at `push/<uuid>.jpg`, **outside `CANONICAL_PREFIXES`**, so only the daily push
  sweep reclaims them. A campaign bumps no `content_version` — a notification is not content.
- **A campaign in `sending` cannot be deleted** — its delivery rows ARE the idempotency record, and a
  cascade under a running batch lets the retry send twice. The guard lives in the CMS DELETE's own
  WHERE, so the cron cannot claim the row in between; the CMS edits only `scheduled` rows the same way.

## Going live

`PUSH_ENABLED` (`[vars]` in `workers/wrangler.toml`) is the kill switch: anything but exactly `"true"`
and the cron and `/internal/push/dispatch` claim nothing, while `/internal/push/test` and `count` still
work. **Flipping it is the owner's call.** Rehearsal: [cron.md](cron.md) — nothing local can intercept
an FCM send, so the debug branch's registry bounds the blast.
