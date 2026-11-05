-- BillFlow — migration 0003: backend support (Step 3). Additive only: no drops, no data deletion.

-- customers: archive instead of delete
alter table customers add column if not exists archived_at timestamptz;

-- invoices: cancellation metadata
alter table invoices add column if not exists cancelled_at timestamptz;
alter table invoices add column if not exists cancel_reason text;

-- financing: debtor wallet is optional on-chain (zero address = any payer may repay)
alter table financing_offers alter column debtor_wallet drop not null;
alter table financing_offers add column if not exists debtor_ref text check (debtor_ref ~ '^0x[0-9a-f]{64}$');
alter table financing_offers add column if not exists debtor_ack_hash text check (debtor_ack_hash ~ '^0x[0-9a-f]{64}$');
alter table financing_offers add column if not exists document_hash text check (document_hash ~ '^0x[0-9a-f]{64}$');
alter table financing_offers add column if not exists onchain_registered_at timestamptz;
alter table financing_offers add column if not exists onchain_verified_at timestamptz;
alter table financing_offers add column if not exists onchain_listed_at timestamptz;

-- blockchain tracking: distinguish submitted / confirmed / verified
alter table blockchain_transactions add column if not exists block_hash text;
alter table blockchain_transactions add column if not exists confirmations integer not null default 0;
alter table blockchain_transactions add column if not exists error text;
alter table blockchain_transactions add column if not exists verified_at timestamptz;
alter table blockchain_events add column if not exists process_error text;
alter table blockchain_events add column if not exists attempts integer not null default 0;
alter table blockchain_events add column if not exists reorged_at timestamptz;

-- signed payment quotes issued to payers (nonce is the on-chain single-use nonce)
create table if not exists payment_quotes (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references invoices(id) on delete cascade,
  payer_wallet text not null check (payer_wallet ~ '^0x[0-9a-f]{40}$'),
  amount_base  numeric(38,0) not null check (amount_base > 0),
  nonce        numeric(78,0) not null unique,
  expiry       timestamptz not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_payment_quotes_invoice on payment_quotes(invoice_id);

-- wallet ownership proofs (single-use nonce, EIP-191 signature)
create table if not exists wallet_challenges (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  wallet_address text not null check (wallet_address ~ '^0x[0-9a-f]{40}$'),
  nonce          text not null unique,
  expires_at     timestamptz not null,
  used_at        timestamptz,
  created_at     timestamptz not null default now()
);

alter table payment_quotes    enable row level security;   -- no policies: backend only
alter table wallet_challenges enable row level security;   -- no policies: backend only

insert into platform_settings (key, value) values ('max_discount_bps', '2000'::jsonb)
on conflict (key) do nothing;
