# Schema (Neon) — the column rules

`db/schema/*.sql`, applied in filename order, then `db/seed.sql`, IS the schema and carries each
column's reasoning in its header comment — read the file before changing a column. Writing a change:
`.claude/skills/neon-migration/`. An additive column the Worker writes is applied BEFORE the Worker
deploys, or every UPDATE naming it fails. **No RLS**: the Worker is the only client and scopes every
parameterized query to the verified `sub`; the app never reaches the DB.

## Identity and entitlement

- **`subscriptions.trial_end` is the one-trial consumed-marker** — written once, never cleared. One row
  per user (`user_id` unique). The entitlement rule over these columns has ONE home,
  `premiumPredicate` ([architecture.md](architecture.md) §Entitlement).
- **`trial_tombstones`** holds `HMAC-SHA256(google_sub, TRIAL_TOMBSTONE_SECRET)` and `trial_end`, no PII —
  written by `DELETE /me`, read by `/auth/login` to pre-seed a consumed trial. The secret never rotates.
- **`users.reward_premium_until`** is referral credit, ORed into entitlement and decoupled from
  subscriptions. The referrer's reward lands on the friend's first paid debit, once; a later
  cancellation never claws it back.
- **`users.is_internal` is set BY HAND and read only for reporting and test sends** (the CMS
  subscriptions page; campaign push's test audience and counts — [push.md](push.md)). No entitlement,
  payment or catalog path reads it. **Enumerate exact addresses — never match by email substring**:
  `%anish%` hits real paying users. The one safe pattern is `%@cloudtestlabaccounts.com` (Google's Test
  Lab robots).
- `users.app_instance_id` and `users.meta_anon_id` are VESTIGIAL — their only readers were the deleted
  server-side GA4/Meta reporters. Never revive them.
- `subscriptions.upi_target_app` names the flow that RAN (re-stamped when an intent setup falls back to
  `phonepe_page`); NULL predates the column and reports `unknown`.
- `subscriptions.superseded_mandate_id` is the still-billing mandate a re-subscribe parked
  ([phonepe.md](phonepe.md)); NULL = nothing parked.

## Debit tracking — `first_debit_at` · `debit_count` · `paid_paise`

Written by EVERY statement that grants a paid period — both settles, `run-redemptions`, the webhook's
redemption branch and the repeat-subscriber ₹199 setup — on the same statement as the `active` flip,
and read only by the CMS subscriptions page. `first_debit_at` is COALESCEd, so a renewal never moves it.
Rows debited before the columns existed were backfilled once (`23_debit_backfill.sql`).

- The CMS counts CONVERSION off the period (`current_period_end > trial_end`), true across all history,
  and spends the stamps only on Renewed (`debit_count`) and Revenue (`paid_paise`). If it ever shows a
  "≥" lower bound again, a paid row lacks a stamp — a grant path stopped stamping.
- **`addOneMonth` uses JavaScript's `setMonth`, which overflows**: 31 Aug + 1 month is 1 Oct. SQL that
  walks a period end back to a settle date must not assume `interval '1 month'`.

## Content rows (`wallpapers`, `ringtones`)

- `type` (static|live) is a rendering hint, never a filter. `category` is free text, so a new category
  is an insert, not a migration. Ringtones have their OWN category set; `deity` is display only
  ([ringtones.md](ringtones.md)). No `is_premium` — the gate is the Worker's.
- `is_published`, not `published`, is the flag — a query on `published` silently matches nothing.
- **`published_at` is stamped by a TRIGGER on the FIRST publish only** — never by a caller, because three
  unrelated paths publish. It is the New chip's debut date, deliberately not `created_at` (import time).
- **`renewed_at` has ONE writer, the CMS Renew**, which re-stamps `published_at` in the same UPDATE and
  keeps the overwritten date in `pre_renew_published_at` (first renew of a chain only) for Undo.
  Deliberately not a trigger: resurfacing is an act, never a side effect of publishing.
- `feed_rank` (the nullable hand pin, NULL = unpinned) and `sort_order` (orders nothing a user sees):
  the rules are [browse.md](browse.md) §Order is ONE SQL clause.
- `apply_count` / `set_count` are the feed's popularity key — see §Popularity counters.
  `apply_score`, `set_score` and `scored_at` are retired: frozen, unread, never sorted on.
- `ringtones.cover_key` stays null ([ringtones.md](ringtones.md) §Row art).

## `categories` — CMS-only

Written and read ONLY by the unified CMS; no Worker route or cron touches it, and `build-catalog` must
never start. A category reaches the app by being on a PUBLISHED row — chips derive from the catalog's
items. The table holds only operator-created categories staged unpublished; seeded slugs and anything
already on a row are never inserted, so nothing live can be retracted from here. `picker_order` sorts
the CMS dropdowns only.

## Popularity counters

`apply_count` / `set_count` are incremented in `/media/signed-url` **after** the entitlement check, on
`waitUntil`, so the most latency-sensitive route never waits. They mean **a PREMIUM user was GRANTED
the file**: a blocked user never reaches the route, the OS chooser can still be cancelled, and wallpaper
SHARES are excluded via the request's `action` — a request with no `action` counts for nothing, so old
builds cannot pollute it. Every ringtone grant counts. No index: `build-catalog` full-scans hourly.

## Paths

User uploads live under `user/<sub>/submissions/…`; approval copies to a canonical key, then deletes the
original. `content_submissions.file_key` is unique, so confirm-upload retries are idempotent.
Campaign push tables: [push.md](push.md).
