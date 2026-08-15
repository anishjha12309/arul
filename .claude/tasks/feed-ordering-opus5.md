# Task: Revive admin feed ordering (three-tier) — Arul wallpapers + ringtones

You are Claude Opus 5 working in `c:\Anish\Arul` (Flutter app + `workers/` Cloudflare Worker) and `c:\Anish\Unified CMS` (the `hsr-cms` worker, separate repo). Read each repo's CLAUDE.md before touching it. This brief is the decided spec — the owner has already answered the design questions below; do not re-open them.

Deliver what was asked, at the scope intended. Make routine judgment calls yourself, and check in only when different readings of the request would lead to materially different work. If the request seems mistaken or a better approach exists, say so in a sentence and continue with the task as asked rather than quietly narrowing, widening, or transforming it. Delegate to a subagent only for genuinely independent, sizeable tracks (e.g. the CMS repo vs. the Flutter client); do not delegate work you can finish yourself in a handful of tool calls, and keep spawn counts low.

## Objective

Bring back hand-curated feed ordering, retired earlier (CLAUDE.md §5b says `feed_rank` and the CMS Feed-order page are RETIRED — this task un-retires them; update the docs accordingly). The order everywhere becomes three strict tiers:

1. **Admin rank** — `feed_rank` (integer, ascending, `NULL` = unpinned). Pins-with-fallthrough: the admin ranks any subset; pinned items sort first by rank, everything unpinned falls through to tier 2. New imports arrive with `NULL` rank and land in tier 2/3 automatically — this is the fix for the old trap where every import broke the hand-written order.
2. **Popularity** — `apply_count` (wallpapers) / `set_count` (ringtones), DESC, from Neon as today.
3. **Newest per category** — catalog position: newest-first within a category, `interleaveByCategory` across them (All view). Ties MUST keep breaking on explicit catalog index — `List.sort` is not stable and an unstable order re-points the pager and video pool under a scrolling user.

One **global** rank per item, wallpapers and ringtones each: the All chip sorts by it, and a category chip shows its members in the same relative order (a filtered view can never contradict All). No per-chip ranks. The comparator is identical for every chip: `feed_rank ASC NULLS LAST → use-count DESC → catalog position ASC`, and it stays a pure function of catalog content (apply-restore resolves indices through it).

Scope limits: Arul only — no Pakiza-side behavior changes (ordering is a deliberate Arul delta; the CMS repo serves both apps, so keep shared plumbing untouched). No changes to what is gated/free, no analytics-derived ranking (counts come from Neon via the existing path, never PostHog/GA4).

## Current state (verify, then build)

- Neon: `wallpapers.feed_rank` still exists (kept when retired); `ringtones` has no rank column.
- `workers/src/cron/build-catalog.ts` — `interleaveByCategory` at :573 (read its idempotence contract); `feed_rank` is explicitly deleted from the public rows at :746 with the retirement rationale at :721–727.
- App: `lib/features/wallpapers/providers/catalog_providers.dart` — `feedOrder()` :314 / `orderedByUse()` :351 are the ONE ordering function for both tabs; ringtones reuse `orderedByUse` (`ringtone_catalog_providers.dart` :251). `apply_restore.dart` resolves through `feedOrder`.
- CMS: the old Feed-order page was deleted — recover its bones from `hsr-cms` git history rather than designing from scratch; it already solved rank-write + `content_version` bump in one transaction.

## Work plan

**1. Neon migration (additive only).** `ALTER TABLE ringtones ADD COLUMN feed_rank integer` (nullable, no default, no backfill). Verify `wallpapers.feed_rank` type/nullability first and reuse it as-is. Use the `neon-migration` skill — psql is not installed; apply via `workers/tools/prod-sql.mjs`. Schema files ARE the migration record (no `db/migrations`).

**2. `build-catalog` (this repo).** Emit `feed_rank` for both scopes (remove it from the wallpaper drop list; keep it out of the ringtone drop list; normalize like the count columns — postgres.js may hand integers back as strings, and a string in a field the Dart model casts to `int?` bricks catalog parsing). Change page order to: pinned rows first (`feed_rank ASC`, cross-category), then `interleaveByCategory` over the unpinned remainder. This keeps the composition idempotent and — critically — means **existing installs** get the pinned order in category chips with no app update (their All chip still client-sorts by count until they update). Extend the vitest coverage for the new order.

**3. Flutter client.** Add `feedRank` (`int?`) to the wallpaper and ringtone models (freezed + codegen; absent field must parse as null so old catalogs stay readable). Extend `orderedByUse`/`feedOrder` with the rank tier ahead of the count tier — one comparator, both tabs, explicit index tiebreak preserved. `flutter analyze` clean, tests updated.

**4. CMS (`hsr-cms` repo).** Revive the ordering page for Arul — two lists (wallpapers, ringtones): pin/unpin and reorder pinned items; writes set `feed_rank` and bump the app's `content_version` in ONE transaction, then fire the async rebuild via the existing service binding `/internal/build-catalog` (self-heals via hourly cron; never purge). Match the existing CMS page idioms.

**5. Docs.** Update CLAUDE.md §5b and `docs/edge-cases.md` §Browse (and any other doc the doc-sync hook names) per the `doc-update` skill: `feed_rank` is live again, with the pins-with-fallthrough semantics and the import-safety property stated. Keep every touched doc under 100 lines.

## Authorization and hard gates

You are authorized to run these normally-restricted actions unattended, on the owner's own infrastructure:
- The **additive** prod-Neon migration in step 1. Nothing beyond it: no `DROP`, no type changes, no `UPDATE` of existing rows, no touching any table this task doesn't name.
- Read-only prod queries needed to verify schema/state.

**Hard gate — deploys.** Do NOT run `wrangler deploy` for either worker on your own. The owner's flow: build everything, verify locally (`cd workers && npx tsc --noEmit && npx vitest run`, `wrangler dev` against `.dev.vars` for the catalog build; CMS repo's own checks; `flutter analyze` + `flutter test`), then STOP and present the evidence — what changed, what the local run produced, sample catalog JSON showing the new order. Deploy `arul-api` only after the owner's explicit go-ahead, and ask separately for `hsr-cms` (it serves live Pakiza admin; it ALWAYS needs its own sign-off). Deploy of `workers/` is part of "done" — the task is not complete until both are approved and deployed, but the approval is the owner's, not yours.

Other standing rules that bind here: never commit before human approval · secrets stay in `env/` + `.dev.vars`, never hardcoded · never share a bucket/KV/DB across apps · stale catalog is fixed by rebuilding, never purging.

## Definition of done

Three-tier order live in both tabs and both chips-styles after deploy; a CMS rank edit reflected in the app within the `?v=` propagation path; an unrelated bulk import leaves existing pins untouched; all checks green in both repos plus the app; docs updated; changes committed only after owner approval. Keep your final report focused: what shipped, what the owner must click/approve next, and any deviation from this brief — no padded summaries.
