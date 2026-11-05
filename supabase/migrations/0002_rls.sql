-- BillFlow — migration 0002: Row Level Security
--
-- Model: the FastAPI backend connects with the service-role key (bypasses RLS)
-- and is the ONLY writer of business data. The Flutter app talks to FastAPI,
-- plus Supabase Auth directly. RLS is defense in depth: if the anon/authenticated
-- key is ever used against PostgREST directly, clients can read only their own
-- data and cannot write financial tables at all.

-- ───────────── helper functions (security definer avoids RLS recursion) ─────────────
create or replace function auth_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid()), false)
$$;

create or replace function is_business_member(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from businesses  where id = bid and owner_id = auth.uid())
      or exists (select 1 from business_members where business_id = bid and user_id = auth.uid())
$$;

-- ───────────── enable RLS everywhere ─────────────
alter table profiles                enable row level security;
alter table businesses              enable row level security;
alter table business_members        enable row level security;
alter table customers               enable row level security;
alter table invoices                enable row level security;
alter table invoice_documents       enable row level security;
alter table payment_links           enable row level security;
alter table payments                enable row level security;
alter table financing_offers        enable row level security;
alter table investments             enable row level security;
alter table blockchain_transactions enable row level security;
alter table blockchain_events       enable row level security;
alter table indexer_state           enable row level security;
alter table notifications           enable row level security;
alter table audit_logs              enable row level security;
alter table platform_settings       enable row level security;

-- ───────────── profiles ─────────────
create policy profiles_select on profiles for select
  using (id = auth.uid() or is_admin());

create policy profiles_update_self on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- Users may change only display_name and wallet_address. Role and verification
-- columns can never be changed from the client.
revoke update on profiles from authenticated, anon;
grant  update (display_name, wallet_address) on profiles to authenticated;

-- ───────────── business-scoped read access ─────────────
create policy businesses_select on businesses for select
  using (is_business_member(id) or is_admin());

create policy business_members_select on business_members for select
  using (user_id = auth.uid() or is_business_member(business_id) or is_admin());

create policy customers_select on customers for select
  using (is_business_member(business_id) or is_admin());

create policy invoices_select on invoices for select
  using (is_business_member(business_id) or is_admin());

create policy invoice_documents_select on invoice_documents for select
  using (is_business_member(business_id) or is_admin());

create policy payment_links_select on payment_links for select
  using (exists (select 1 from invoices i
                 where i.id = payment_links.invoice_id and is_business_member(i.business_id))
         or is_admin());

create policy payments_select on payments for select
  using (exists (select 1 from invoices i
                 where i.id = payments.invoice_id and is_business_member(i.business_id))
         or is_admin());

create policy financing_offers_select on financing_offers for select
  using (is_business_member(business_id) or is_admin());
-- Investors do NOT read financing_offers directly: the marketplace is served by
-- the backend, which returns a minimized, non-confidential projection.

create policy investments_select on investments for select
  using (investor_id = auth.uid()
         or exists (select 1 from financing_offers f
                    where f.id = investments.offer_id and is_business_member(f.business_id))
         or is_admin());

-- ───────────── admin-only operational tables ─────────────
create policy bctx_select_admin    on blockchain_transactions for select using (is_admin());
create policy bcevents_select_admin on blockchain_events      for select using (is_admin());
create policy audit_select_admin   on audit_logs              for select using (is_admin());
create policy settings_select_admin on platform_settings for select using (is_admin());
-- indexer_state: no policies => no client access at all.

-- ───────────── notifications ─────────────
create policy notifications_select on notifications for select using (user_id = auth.uid());
create policy notifications_update on notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke update on notifications from authenticated, anon;
grant  update (read_at) on notifications to authenticated;

-- ───────────── no client writes anywhere else ─────────────
-- No INSERT/UPDATE/DELETE policies exist on any other table, so with RLS enabled
-- all such client operations are denied. Be explicit with grants as well:
revoke insert, delete on all tables in schema public from anon, authenticated;
revoke all on all tables in schema public from anon;
grant select on all tables in schema public to authenticated;  -- still filtered by the policies above

-- ───────────── private storage bucket for invoice PDFs ─────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('invoice-documents', 'invoice-documents', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;
-- No storage.objects policies for anon/authenticated: all access goes through the
-- backend, which uploads with the service-role key and hands out short-lived signed URLs
-- only after an authorization check.
