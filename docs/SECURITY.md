# BillFlow — Security rules (Step 1)

Hackathon MVP on a testnet. These rules are design requirements for Steps 2–5; none is claimed as implemented or tested yet.

## 1. Authentication & authorization
- Supabase Auth issues sessions. FastAPI verifies the JWT signature and expiry (JWKS or HS256 secret, per project setting) on every request.
- **Role comes from `profiles.role` in Postgres per request.** JWT custom claims and client-provided roles are ignored.
- Signup can request only `merchant`/`investor`; `admin` is never self-assignable (trigger enforces it). Role changes are admin-only and audit-logged.
- Ownership checks are in the service layer (business-scoped queries). Cross-tenant lookups return 404.
- RLS is defense in depth: clients have read-only, scoped access; all writes go through FastAPI.
- Public endpoints use unguessable payment-link tokens (≥32 chars, random), are rate-limited, expose only checkout-safe fields, and never return PDFs or customer contact data.

## 2. Secrets & keys
- Secrets exist only in backend/contract env vars: Supabase service-role key, Anthropic key, quote-signer and operator keys, deployer key. Flutter holds only the public Supabase URL + anon key and public chain config.
- `.env*` is git-ignored except `.env.example` files. Use separate throwaway testnet keys; rotate after the event.
- **No user wallet private keys are ever stored or requested** — in Supabase, backend, or app. Users sign in their own wallet.
- Logs must not contain tokens, keys, full PDFs, or AI prompts with invoice content.

## 3. Private invoice PDFs
- Private bucket, no client storage policies; backend uploads and issues 60 s signed URLs after an ownership/admin check.
- Validate size, magic bytes, content type; server generates storage paths; store `sha256`.
- Only hashes/ids/amounts go on-chain; PDFs never leave Supabase except to Anthropic on an explicit user-triggered AI action.

## 4. Wallet connections
- Wallet ownership for profile linking is proven by signing a server nonce (EIP-191), single-use, short-lived.
- Always check `chainId == 1874` before any transaction; show the exact contract, token and amount; approve only the needed amount (not unlimited) by default.
- The payer in a quote is bound to the connecting wallet; the contract enforces `msg.sender == payer`.

## 5. Blockchain verification & payment integrity
- **Frontend payment-success messages are never trusted.** `POST …/tx` is a hint; status changes only from indexer-verified events.
- Verification checks: tx `status == 1`; event emitted by the expected contract address; chain id; invoice id matches; merchant matches stored payout wallet; token matches configured USDT; amount ≤ remaining; confirmations ≥ `min_confirmations`; block hash still canonical.
- Duplicate protection layers: contract nonce + cumulative `paidAmount`; DB `unique(tx_hash, log_index)`; conditional status updates; idempotency keys on API.
- Quote signer key only signs for invoices in a payable state, with short expiry (≤15 min) and per-quote nonce.

## 6. Financing, duplicates & investor permissions
- One financing per invoice: DB `unique(invoice_id)` + contract `usedInvoiceHash`.
- One-time funding: contract state check + DB partial unique index.
- A financed invoice cannot be paid through `BillFlowPayments` (no quote is signed), preventing double settlement.
- Investors: must be admin-verified; contract allowlist (toggle) enforces it on-chain; investor cannot fund their own business's offer.
- `createOffer` only by `OPERATOR_ROLE`, and the backend only calls it after a stored admin approval (`reviewed_by`, `reviewed_at`) and recorded debtor acknowledgement.
- Legal clarity: the position token is a testnet-model claim representation, **not** a legal assignment; the UI shows a disclosure and the assignment notice/debtor acknowledgement are separate records. Illustrative terms are not guaranteed returns.

- Contract roles (Step 2): VERIFIER = human trust decision (recommend admin-wallet-signed); OPERATOR/ISSUER/QUOTE_SIGNER = backend hot keys, testnet only; `repay` stays callable during pause; no admin path can move user funds.

## 7. AI-generated data
- Output treated as untrusted: JSON-schema validated, stored as `ai_extraction`/`ai_flags`, shown as "AI suggestion — verify".
- AI cannot change `review_status`, financing status, approve, sign, or send any transaction. All such actions require an authenticated human with the right role.
- Prompt-injection hygiene: PDF text is passed as data inside delimiters, with instructions in the system prompt; outputs never executed or used as instructions; no tools given to the model for these calls.
- Confidence score is informational; low confidence adds a flag, high confidence skips nothing.

## 8. Admin operations
- Admin routes require `role = admin` from the DB. Every admin action writes `audit_logs` (actor, action, entity, metadata).
- Financing needs a distinct approve step; consider two-person approval post-hackathon.
- Admin can't read private keys (none are stored) and can't move funds (contracts have no admin withdrawal over user funds; contracts hold no balances).

## 9. Application hardening
- CORS allowlist, rate limits on public routes, request size limits, strict pydantic validation, parameterized queries only, generic error messages externally with details in server logs, dependency pinning.
- Testnet-only guard: backend refuses to start with `CHAIN_ID` other than the configured testnet unless explicitly overridden.

## 10. Residual risks (accepted for MVP)
Hot operator/signer keys; centralized operator role; public RPC availability; official USDT behavior unverified; no formal audit of contracts; off-chain legal enforceability out of scope.
