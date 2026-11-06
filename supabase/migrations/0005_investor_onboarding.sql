-- BillFlow — migration 0005: investor onboarding & verification. Additive only.
-- Flow: signup (investor) -> submit onboarding (profiles.investor_verification: unverified -> pending)
--       -> admin verifies/rejects -> verified investors may use the marketplace.

create table if not exists investor_profiles (
  user_id           uuid primary key references profiles(id) on delete cascade,
  full_name         text not null check (char_length(full_name) between 2 and 160),
  country           text not null check (char_length(country) between 2 and 80),
  investor_type     text not null check (investor_type in ('individual','institution')),
  organization      text check (organization is null or char_length(organization) <= 160),
  tax_id            text check (tax_id is null or char_length(tax_id) <= 80),
  accepted_terms_at timestamptz not null,
  accepted_risk_at  timestamptz not null,
  submitted_at      timestamptz not null default now(),
  review_notes      text,
  reviewed_by       uuid references profiles(id),
  reviewed_at       timestamptz,
  updated_at        timestamptz not null default now()
);
create trigger trg_investor_profiles_updated before update on investor_profiles
  for each row execute function set_updated_at();

-- Backend-only writes; an investor may read their own row through Supabase.
alter table investor_profiles enable row level security;
drop policy if exists investor_profiles_select_own on investor_profiles;
create policy investor_profiles_select_own on investor_profiles for select to authenticated
  using (user_id = auth.uid() or is_admin());
