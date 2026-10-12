-- What PhonePe said about each renewal order, kept after redemption_order_id moves on (docs/order-outcomes.md).
-- Never folded into subscriptions: its trigger bumps updated_at, which orders Pass B. No billing path reads it.
-- PhonePe's free-text columns carry no CHECK -> an unpublished code (UPI_BACKBONE_ERROR, NU) must never fail an insert.
create table if not exists order_outcomes (
  id                  bigserial   primary key,
  merchant_order_id   text        not null,
  mandate_id          text,
  user_id             uuid        not null references users(id) on delete cascade,
  event               text        not null check (event in (
                        'minted', 'redeem_accepted', 'redeem_rejected', 'reconciled', 'recycled', 'closed')),
  phonepe_state       text,
  error_code          text,
  detailed_error_code text,
  error_source        text,
  error_stage         text,
  error_description   text,
  mandate_state       text,
  http_status         integer,
  amount_paise        integer,
  retry_rung          integer,
  expire_at           timestamptz,
  occurred_at         timestamptz,
  observed_by         text        not null,
  observed_at         timestamptz not null default now()
);
-- The dedupe: a PENDING read is never recorded, so one order yields a handful of rows however many ticks read it.
create unique index if not exists order_outcomes_dedupe_idx on order_outcomes (
  merchant_order_id, event, coalesce(phonepe_state, ''), coalesce(error_code, ''), coalesce(detailed_error_code, ''));
-- One mint and one final word per order, whichever writer (Pass A, a backfill) and whatever state it saw first.
create unique index if not exists order_outcomes_minted_idx on order_outcomes (merchant_order_id) where event = 'minted';
create unique index if not exists order_outcomes_closed_idx on order_outcomes (merchant_order_id) where event = 'closed';
-- The closing sweep's queue, the account-delete cascade and the 12-month purge.
create index if not exists order_outcomes_open_idx     on order_outcomes (expire_at) where event = 'minted';
create index if not exists order_outcomes_user_idx     on order_outcomes (user_id);
create index if not exists order_outcomes_observed_idx on order_outcomes (observed_at);
