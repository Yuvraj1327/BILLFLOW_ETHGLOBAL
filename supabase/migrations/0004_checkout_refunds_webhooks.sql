-- BillFlow — migration 0004 (Step 6): merchant API keys, checkout sessions, refunds, signed webhooks.
-- Additive only: no drops, no data deletion. All new tables are backend-only (RLS enabled, no policies).

-- payments: keep the on-chain payment id (needed to reference a payment in BillFlowRefunds)
alter table payments add column if not exists onchain_payment_id numeric(38,0);
alter table payments add column if not exists refunded_amount_base numeric(38,0) not null default 0 check (refunded_amount_base >= 0);
-- not UNIQUE on purpose: after a chain reorg the same payment id can legitimately be re-indexed from a different tx/log
create index if not exists idx_payments_onchain_id on payments(onchain_payment_id) where onchain_payment_id is not null;

-- ───────── merchant API keys (only a SHA-256 of the key is stored; the key is shown once) ─────────
create table if not exists api_keys (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id) on delete cascade,
  name         text not null check (length(name) between 1 and 80),
  key_prefix   text not null,                       -- first chars, for display only
  key_hash     text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  created_by   uuid references profiles(id),
  last_used_at timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists idx_api_keys_business on api_keys(business_id);

-- ───────── checkout sessions created through the API (one invoice + one payment link each) ─────────
create table if not exists checkout_sessions (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references businesses(id) on delete cascade,
  invoice_id      uuid not null unique references invoices(id) on delete cascade,
  reference       text,                              -- merchant's own order id
  metadata        jsonb not null default '{}'::jsonb,
  success_url     text,
  cancel_url      text,
  idempotency_key text,
  api_key_id      uuid references api_keys(id) on delete set null,
  created_at      timestamptz not null default now()
);
create unique index if not exists uq_checkout_idem on checkout_sessions(business_id, idempotency_key) where idempotency_key is not null;
create index if not exists idx_checkout_reference on checkout_sessions(business_id, reference);

-- ───────── refunds (mirror of on-chain BillFlowRefunds.PaymentRefunded) ─────────
do $$ begin
  if not exists (select 1 from pg_type where typname = 'refund_status') then
    create type refund_status as enum ('PENDING','CONFIRMED','CANCELLED');
  end if;
end $$;

create table if not exists refunds (
  id                uuid primary key default gen_random_uuid(),
  payment_id        uuid not null references payments(id),
  invoice_id        uuid not null references invoices(id),
  business_id       uuid not null references businesses(id),
  amount_base       numeric(38,0) not null check (amount_base > 0),
  refund_ref        text not null unique check (refund_ref ~ '^0x[0-9a-f]{64}$'),  -- on-chain idempotency key
  reason            text,                                                          -- private, off-chain
  reason_hash       text not null check (reason_hash ~ '^0x[0-9a-f]{64}$'),
  status            refund_status not null default 'PENDING',
  onchain_refund_id numeric(38,0),
  tx_hash           text check (tx_hash ~ '^0x[0-9a-f]{64}$'),
  log_index         integer,
  block_number      bigint,
  requested_by      uuid references profiles(id),
  refunded_at       timestamptz,
  created_at        timestamptz not null default now(),
  unique (tx_hash, log_index)
);
create index if not exists idx_refunds_payment on refunds(payment_id);
create index if not exists idx_refunds_business on refunds(business_id, created_at desc);

-- ───────── webhooks ─────────
create table if not exists webhook_endpoints (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  url         text not null check (length(url) <= 2000),
  secret      text not null,                         -- HMAC key; backend-only table, shown to the merchant once
  events      text[] not null default array['*'],
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_webhook_endpoints_business on webhook_endpoints(business_id);

create table if not exists webhook_deliveries (
  id              uuid primary key default gen_random_uuid(),
  endpoint_id     uuid not null references webhook_endpoints(id) on delete cascade,
  event_id        text not null,                     -- stable, e.g. 'payment.confirmed:<payment uuid>'
  event_type      text not null,
  payload         jsonb not null,
  status          text not null default 'PENDING' check (status in ('PENDING','DELIVERED','FAILED')),
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_status     integer,
  last_error      text,
  delivered_at    timestamptz,
  created_at      timestamptz not null default now(),
  unique (endpoint_id, event_id)                     -- an event is enqueued at most once per endpoint
);
create index if not exists idx_webhook_due on webhook_deliveries(next_attempt_at) where status = 'PENDING';

alter table api_keys           enable row level security;
alter table checkout_sessions  enable row level security;
alter table refunds            enable row level security;
alter table webhook_endpoints  enable row level security;
alter table webhook_deliveries enable row level security;

-- Merchants may read their own refunds through Supabase directly (read-only); everything else is backend-only.
drop policy if exists refunds_select_own on refunds;
create policy refunds_select_own on refunds for select to authenticated
  using (business_id in (select id from businesses where owner_id = auth.uid()
                         union select business_id from business_members where user_id = auth.uid()));
