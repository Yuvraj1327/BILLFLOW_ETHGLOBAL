-- BillFlow — migration 0001: core schema
-- Money is stored as integer token base units (numeric(38,0)) + token_decimals.
-- Token decimals for the Whitechain Sepolia USDT are NOT yet verified; the
-- default of 6 below is a placeholder that MUST be confirmed before Step 2.

create extension if not exists "pgcrypto";

-- ───────────────────────── enums ─────────────────────────
create type user_role           as enum ('merchant','customer','investor','admin');
create type verification_status as enum ('unverified','pending','verified','rejected');
create type invoice_status      as enum ('DRAFT','PENDING','PARTIALLY_PAID','PAID','OVERDUE','CANCELLED');
create type payment_status      as enum ('PENDING','CONFIRMED','FAILED');
create type financing_status    as enum (
  'REQUESTED','UNDER_REVIEW','APPROVED','LISTED','FUNDED',
  'SETTLED','REJECTED','EXPIRED','CANCELLED','DEFAULTED'
);
create type investment_status   as enum ('PENDING','CONFIRMED','SETTLED','FAILED');
create type tx_status           as enum ('SUBMITTED','CONFIRMED','FAILED');

-- ───────────────────── helper: updated_at ─────────────────────
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ───────────────────────── profiles ─────────────────────────
create table profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  role           user_role not null default 'customer',
  display_name   text,
  email          text,
  wallet_address text unique check (wallet_address ~ '^0x[0-9a-f]{40}$'),  -- stored lowercase
  investor_verification verification_status not null default 'unverified',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger trg_profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- Create a profile on signup. The client may only *request* merchant or
-- investor via signup metadata; 'admin' can never be self-assigned and is
-- only granted by an existing admin through the backend.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare requested text := new.raw_user_meta_data ->> 'role';
begin
  insert into profiles (id, email, display_name, role)
  values (
    new.id, new.email, new.raw_user_meta_data ->> 'display_name',
    case when requested in ('merchant','investor') then requested::user_role
         else 'customer'::user_role end
  );
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ───────────────────────── businesses ─────────────────────────
create table businesses (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references profiles(id),
  legal_name          text not null,
  country             text,
  tax_id              text,
  payout_wallet       text check (payout_wallet ~ '^0x[0-9a-f]{40}$'),
  verification_status verification_status not null default 'unverified',
  verified_by         uuid references profiles(id),
  verified_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_businesses_owner on businesses(owner_id);
create trigger trg_businesses_updated before update on businesses
  for each row execute function set_updated_at();

create table business_members (
  business_id uuid not null references businesses(id) on delete cascade,
  user_id     uuid not null references profiles(id) on delete cascade,
  member_role text not null default 'member' check (member_role in ('owner','member')),
  created_at  timestamptz not null default now(),
  primary key (business_id, user_id)
);
create index idx_business_members_user on business_members(user_id);

-- ───────────────────────── customers ─────────────────────────
create table customers (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id) on delete cascade,
  name           text not null,
  email          text,
  wallet_address text check (wallet_address ~ '^0x[0-9a-f]{40}$'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_customers_business on customers(business_id);
create trigger trg_customers_updated before update on customers
  for each row execute function set_updated_at();

-- ───────────────────────── invoices ─────────────────────────
create table invoices (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id),
  customer_id      uuid not null references customers(id),
  invoice_number   text not null,
  description      text,
  amount_base      numeric(38,0) not null check (amount_base > 0),
  token_decimals   smallint not null default 6 check (token_decimals between 0 and 36), -- TO VERIFY
  currency         text not null default 'USDT',
  issue_date       date not null default current_date,
  due_date         date not null,
  status           invoice_status not null default 'DRAFT',
  paid_amount_base numeric(38,0) not null default 0 check (paid_amount_base >= 0),
  review_status    verification_status not null default 'unverified',  -- admin invoice verification
  onchain_invoice_id text check (onchain_invoice_id ~ '^0x[0-9a-f]{64}$'), -- bytes32 used in contracts
  invoice_hash     text check (invoice_hash ~ '^0x[0-9a-f]{64}$'),         -- hash of canonical invoice data
  paid_tx_hash     text check (paid_tx_hash ~ '^0x[0-9a-f]{64}$'),         -- tx that completed payment
  created_by       uuid not null references profiles(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (business_id, invoice_number),
  unique (onchain_invoice_id),
  check (due_date >= issue_date),
  check (paid_amount_base <= amount_base)
);
create index idx_invoices_business_status on invoices(business_id, status);
create index idx_invoices_customer on invoices(customer_id);
create index idx_invoices_due on invoices(due_date) where status in ('PENDING','PARTIALLY_PAID');
create trigger trg_invoices_updated before update on invoices
  for each row execute function set_updated_at();

-- ───────────────────── invoice_documents ─────────────────────
create table invoice_documents (
  id             uuid primary key default gen_random_uuid(),
  invoice_id     uuid references invoices(id) on delete cascade,  -- null until extraction is confirmed
  business_id    uuid not null references businesses(id),
  storage_path   text not null unique,                             -- private bucket path
  sha256         text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  mime_type      text not null default 'application/pdf',
  size_bytes     integer not null check (size_bytes > 0),
  ai_extraction  jsonb,
  ai_confidence  numeric(4,3) check (ai_confidence between 0 and 1),
  ai_flags       jsonb not null default '[]'::jsonb,               -- advisory only
  uploaded_by    uuid not null references profiles(id),
  created_at     timestamptz not null default now()
);
create index idx_invoice_docs_invoice on invoice_documents(invoice_id);
create index idx_invoice_docs_sha on invoice_documents(sha256);   -- duplicate-document detection

-- ───────────────────────── payment_links ─────────────────────────
create table payment_links (
  id         uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  token      text not null unique check (length(token) >= 32),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_payment_links_invoice on payment_links(invoice_id);

-- ───────────────────────── payments ─────────────────────────
create table payments (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references invoices(id),
  payer_wallet text not null check (payer_wallet ~ '^0x[0-9a-f]{40}$'),
  amount_base  numeric(38,0) not null check (amount_base > 0),
  tx_hash      text not null check (tx_hash ~ '^0x[0-9a-f]{64}$'),
  log_index    integer not null,
  block_number bigint,
  status       payment_status not null default 'PENDING',
  confirmed_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (tx_hash, log_index)            -- idempotent processing / duplicate protection
);
create index idx_payments_invoice on payments(invoice_id);
create index idx_payments_payer on payments(payer_wallet);

-- ───────────────────── financing_offers ─────────────────────
create table financing_offers (
  id                 uuid primary key default gen_random_uuid(),
  invoice_id         uuid not null unique references invoices(id),  -- one financing per invoice
  business_id        uuid not null references businesses(id),
  status             financing_status not null default 'REQUESTED',
  face_value_base    numeric(38,0) not null check (face_value_base > 0),
  advance_base       numeric(38,0) not null check (advance_base > 0),
  maturity_date      date not null,
  funding_deadline   timestamptz not null,
  debtor_name        text not null,
  debtor_wallet      text not null check (debtor_wallet ~ '^0x[0-9a-f]{40}$'),
  debtor_ack         jsonb,                    -- debtor acknowledgement evidence (off-chain record)
  debtor_ack_at      timestamptz,
  assignment_notice  jsonb,                    -- legal assignment record (separate from onchain)
  reviewed_by        uuid references profiles(id),
  reviewed_at        timestamptz,
  review_notes       text,
  onchain_offer_id   numeric(38,0) unique,     -- tokenId / offerId in InvoiceFinancing
  create_tx_hash     text check (create_tx_hash ~ '^0x[0-9a-f]{64}$'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (advance_base < face_value_base)
);
create index idx_financing_status on financing_offers(status);
create index idx_financing_business on financing_offers(business_id);
create trigger trg_financing_updated before update on financing_offers
  for each row execute function set_updated_at();

-- ───────────────────────── investments ─────────────────────────
create table investments (
  id                 uuid primary key default gen_random_uuid(),
  offer_id           uuid not null references financing_offers(id),
  investor_id        uuid not null references profiles(id),
  investor_wallet    text not null check (investor_wallet ~ '^0x[0-9a-f]{40}$'),
  amount_base        numeric(38,0) not null check (amount_base > 0),
  tx_hash            text not null check (tx_hash ~ '^0x[0-9a-f]{64}$'),
  status             investment_status not null default 'PENDING',
  funded_at          timestamptz,
  repayment_base     numeric(38,0),
  repayment_tx_hash  text check (repayment_tx_hash ~ '^0x[0-9a-f]{64}$'),
  settled_at         timestamptz,
  created_at         timestamptz not null default now(),
  unique (tx_hash)
);
-- one-time funding protection mirrored in the DB: at most one live investment per offer
create unique index uq_investments_one_live_per_offer on investments(offer_id)
  where status in ('PENDING','CONFIRMED','SETTLED');
create index idx_investments_investor on investments(investor_id);

-- ─────────────────── blockchain_transactions / events ───────────────────
create table blockchain_transactions (
  id           uuid primary key default gen_random_uuid(),
  tx_hash      text not null unique check (tx_hash ~ '^0x[0-9a-f]{64}$'),
  chain_id     integer not null,
  from_address text,
  to_address   text,
  kind         text not null,       -- e.g. invoice_payment, financing_fund, financing_repay, offer_create
  related_type text,                -- 'payment' | 'investment' | 'financing_offer'
  related_id   uuid,
  status       tx_status not null default 'SUBMITTED',
  block_number bigint,
  confirmed_at timestamptz,
  created_at   timestamptz not null default now()
);
create index idx_bctx_related on blockchain_transactions(related_type, related_id);

create table blockchain_events (
  id               uuid primary key default gen_random_uuid(),
  chain_id         integer not null,
  contract_address text not null,
  event_name       text not null,
  tx_hash          text not null,
  log_index        integer not null,
  block_number     bigint not null,
  block_hash       text not null,
  payload          jsonb not null,
  processed_at     timestamptz,
  created_at       timestamptz not null default now(),
  unique (chain_id, tx_hash, log_index)     -- replaying a block range is safe
);
create index idx_bcevents_block on blockchain_events(block_number);
create index idx_bcevents_unprocessed on blockchain_events(created_at) where processed_at is null;

create table indexer_state (
  chain_id         integer not null,
  contract_address text not null,
  last_block       bigint not null,
  updated_at       timestamptz not null default now(),
  primary key (chain_id, contract_address)
);

-- ─────────────────── notifications / audit_logs ───────────────────
create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  type       text not null,
  title      text not null,
  body       text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index idx_notifications_user on notifications(user_id, created_at desc);

create table audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid references profiles(id),
  action      text not null,
  entity_type text not null,
  entity_id   text,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index idx_audit_entity on audit_logs(entity_type, entity_id);
create index idx_audit_actor on audit_logs(actor_id, created_at desc);

-- ─────────────────── platform_settings (admin-managed) ───────────────────
create table platform_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid references profiles(id),
  updated_at timestamptz not null default now()
);
insert into platform_settings (key, value) values
  ('default_funding_window_hours', '72'::jsonb),
  ('default_discount_bps',         '500'::jsonb),   -- illustrative demo default, not a guaranteed return
  ('default_grace_days',           '7'::jsonb),
  ('min_confirmations',            '3'::jsonb);
