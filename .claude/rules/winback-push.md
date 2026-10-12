---
description: The win-back push — REVOKED only, recorded in the park's own statement, the minute resolver, month rows.
paths:
  - "workers/src/lib/winback-push.ts"
  - "workers/src/cron/winback-push.ts"
  - "db/schema/35_winback_push.sql"
---

- **REVOKED queues, CANCELLED never does**: CANCELLED is the merchant cancel API, which only we call. Every park
  passes PhonePe's raw state; EXPIRED, FAILED or none writes no row.
- **One home:** `withWinbackRecord` wraps the park's UPDATE in one CTE. Never a second `INSERT INTO winback_pushes`
  beside a park — a lost insert loses the push, a split one doubles it.
- **The insert rides the revoke**: no CHECK on its free-text columns, every bind `?? null`, and
  `35_winback_push.sql` lands before the Worker that writes it.
- **`handleCancel` claims its live and parked ids before PhonePe**, best effort, never blocking the cancel.
- **`now` is the tick's `scheduledTime`, bound — never `now()`**; quiet hours are IST 22:00–09:00.
- **`disabled` stays after `no_phone`** (the dark-launch rows are the baseline); `series` (a paid row) then `stale`
  stay first.
- **Upsert the trial month row before the paid one, always** (deadlock); reopen only a `sent` auto row.
- **The series: one `winback_series` row per evaluated day** (its key is the race lock), `lapsed_at` bound
  `::text::timestamptz` (a timestamptz param drops microseconds and the row refills every batch), day rows upserted in ascending order.
- One win-back a day per person, revoke push and series alike (`pushedToday`). `WINBACK_MIN_BUILD` = the release
  that opens the ₹99 sheet from `offer=winback_99`. Flipping `WINBACK_PUSH_ENABLED` is the owner's call.

Read [docs/winback-push.md](../../docs/winback-push.md) before changing any of it.
