# BillFlow — API specification (v1, Step 1 design; not implemented)

> Step 2 amendment: on-chain ids and approvals changed — see `SMART_CONTRACT_DESIGN.md`. Admin "approve financing" now means: verifier wallet signs `verifyInvoice`, then the business (or operator key) calls `createOffer`; `onchain_offer_id` = on-chain `invoiceId`. Admin business/investor verification also calls `setBusinessApproved` / `setInvestorApproved`.

Base path `/api/v1`. JSON over HTTPS. Roles: **M** merchant · **C** customer · **I** investor · **A** admin · **P** public (token-based, no login).
Auth for all non-public routes: `Authorization: Bearer <Supabase access token>`. FastAPI verifies the signature, then loads `profiles.role` from the database.

## Conventions

**Money.** Amounts are decimal strings of integer base units (`"10000000000"`) plus `token_decimals`. Never floats.
**Pagination.** `?page=1&page_size=20` → `{ "items": [...], "page": 1, "page_size": 20, "total": 123 }`.
**IDs.** UUIDs; addresses lowercase `0x…`; tx hashes lowercase 32-byte hex.

**Errors.** Every error uses one envelope:
```json
{ "error": { "code": "invoice_not_payable", "message": "Invoice is already paid", "details": {} } }
```
| HTTP | Meaning |
|---|---|
| 400 | malformed request |
| 401 | missing/invalid/expired token |
| 403 | authenticated but role/ownership denies it |
| 404 | not found (also used instead of 403 when existence must not leak, e.g. other businesses' invoices) |
| 409 | conflict / duplicate / invalid state transition |
| 413/415 | upload too large / not a PDF |
| 422 | validation failed (pydantic; `details` lists fields) |
| 429 | rate limited (public endpoints) |
| 502/504 | upstream failure (RPC, Anthropic, Supabase) — safe to retry |

**Validation.** Pydantic schemas on every body; strict address/hash regex; amount > 0 and ≤ configured max; dates ordered; enum values only; PDFs: size ≤ `MAX_UPLOAD_BYTES`, magic bytes `%PDF`, content-type check, filename discarded (server generates path).

**Idempotency.**
- All mutating `POST`s accept `Idempotency-Key` (UUID). The backend stores key + request hash + response for 24h; same key + same body replays the stored response, same key + different body → 409.
- Blockchain-derived writes are idempotent by construction: `unique(tx_hash, log_index)` on `payments` and `blockchain_events`; `POST …/tx` with an already-known hash returns the current state rather than erroring.
- State transitions are conditional updates (`… where status = expected`), so concurrent duplicates cannot double-apply.

**Status authority.** No endpoint accepts a payment/financing status from the client. `PAID`, `PARTIALLY_PAID`, `LISTED`, `FUNDED`, `SETTLED`, `EXPIRED`, `DEFAULTED` are set only by the indexer/verification service.

---
## 1. Authentication  (Supabase Auth handles credentials; backend adds wallet proof)
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/auth/wallet/challenge` | Get nonce to prove wallet ownership | Any user | `{ "wallet_address" }` | `{ "nonce", "message", "expires_at" }` |
| POST | `/auth/wallet/verify` | Link wallet after EIP-191 signature check | Any user | `{ "wallet_address", "signature" }` | `{ "wallet_address", "linked_at" }` |
| GET | `/health` | Liveness | P | – | `{ "status": "ok" }` |
| GET | `/config/public` | Chain + contract + token config for clients | P | – | `{ "chain_id", "rpc_url", "explorer_url", "usdt_address", "usdt_decimals", "payments_contract", "financing_contract" }` |

Sign-up/sign-in/refresh/password reset are done by Flutter directly against Supabase Auth, not through FastAPI.

## 2. Users and profiles
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| GET | `/me` | Current profile, role, business | Any | – | `{ id, email, role, display_name, wallet_address, business? }` |
| PATCH | `/me` | Update own profile | Any | `{ display_name? }` | updated profile (wallet changes only via `/auth/wallet/*`) |

## 3. Businesses
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/businesses` | Onboard business | M | `{ legal_name, country?, tax_id?, payout_wallet }` | Business (`verification_status: "unverified"`) |
| GET | `/businesses/me` | Own business | M | – | Business |
| PATCH | `/businesses/me` | Update profile / payout wallet | M | partial Business | Business |
| GET | `/dashboard/summary` | KPIs: counts and sums by status, recent payments | M | – | `{ pending, paid, overdue, partially_paid, totals{…}, recent_payments[] }` |

## 4. Customers
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/customers` | Add customer | M | `{ name, email?, wallet_address? }` | Customer |
| GET | `/customers` | List own customers | M | `?q=&page=` | Page<Customer> |
| GET / PATCH | `/customers/{id}` | View / edit (own business only) | M | partial | Customer |

## 5. Invoices
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/invoices` | Create invoice (idempotent) | M (verified or unverified business may create; financing requires verified) | `{ customer_id, invoice_number, description?, amount_base, issue_date, due_date, document_id? }` | Invoice (`DRAFT`), with `invoice_hash`, `onchain_invoice_id` |
| GET | `/invoices` | List | M (A: all) | `?status=&customer_id=&page=` | Page<Invoice> |
| GET | `/invoices/{id}` | Detail incl. payments, financing, documents | M owner / A | – | Invoice + relations |
| PATCH | `/invoices/{id}` | Edit while `DRAFT` | M | partial | Invoice |
| POST | `/invoices/{id}/issue` | `DRAFT → PENDING` | M | – | Invoice |
| POST | `/invoices/{id}/cancel` | Cancel if unpaid, not financed | M | `{ reason? }` | Invoice (`CANCELLED`) |
| POST | `/invoices/{id}/documents` | Upload PDF (multipart) | M | `file` | `{ document_id, sha256, size_bytes }` (409 if same sha256 already attached elsewhere → returned as flag, advisory) |
| GET | `/invoices/{id}/documents/{doc_id}/url` | Short-lived signed URL (60 s) | M owner / A | – | `{ url, expires_at }` |

## 6. Payment links
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/invoices/{id}/payment-link` | Create (revokes previous active link) | M | `{ expires_at? }` | `{ id, url, token, expires_at }` |
| GET | `/invoices/{id}/payment-link` | Active link | M | – | link or 404 |
| DELETE | `/payment-links/{id}` | Revoke | M | – | 204 |
| GET | `/public/pay/{token}` | Invoice view model for checkout | P | – | `{ merchant_name, invoice_number, description, amount_base, remaining_base, token_decimals, due_date, status, chain_config }` |
| POST | `/public/pay/{token}/quote` | EIP-712 quote for the payer | P (rate-limited) | `{ payer_wallet, amount_base }` | `{ quote{invoiceId, merchant, payer, amount, invoiceTotal, nonce, expiry}, signature, contract, token }`; 409 if not payable/financed/overpay |

## 7. Payments
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/public/pay/{token}/tx` | Submit tx hash hint; backend verifies on chain | P | `{ tx_hash }` | `{ status: "PENDING"\|"CONFIRMED"\|"FAILED", payment? }` (never marks PAID by itself without a matching event) |
| GET | `/public/payments/{tx_hash}` | Receipt data (no private invoice fields) | P | – | `{ invoice_number, merchant_name, amount_base, payer_wallet, tx_hash, explorer_url, confirmed_at }` |
| GET | `/payments` | History | M (own) / A (all) / C (by linked wallet) | `?invoice_id=&page=` | Page<Payment> |
| GET | `/payments/{id}` | Detail + explorer URL | M / A / C | – | Payment |
| GET | `/payments/{id}/receipt` | Receipt PDF | M / A / C | – | `application/pdf` |

## 8. Financing (merchant side)
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/financing` | Request financing | M (verified business) | `{ invoice_id, debtor_wallet, requested_advance_base? }` | FinancingOffer (`REQUESTED`) — invoice must be `PENDING`/`OVERDUE`, admin-verified, unpaid, no existing offer |
| GET | `/financing` | List own | M | `?status=` | Page<FinancingOffer> |
| GET | `/financing/{id}` | Detail + timeline | M owner / A | – | FinancingOffer + events |
| POST | `/financing/{id}/cancel` | Cancel before funding | M | – | FinancingOffer (`CANCELLED`; on-chain `cancelOffer` if listed) |

## 9. Investors
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| GET | `/marketplace` | Listed offers (minimized projection) | I | `?page=&sort=` | Page<{ id, face_value_base, advance_base, discount_pct, maturity_date, funding_deadline, merchant_verified, invoice_category?, contract, onchain_offer_id }> |
| GET | `/marketplace/{id}` | Terms and risk disclosures | I | – | Offer + `disclosure` text |
| POST | `/investments/{offer_id}/tx` | Submit `fund()` tx hash hint | I | `{ tx_hash }` | `{ status, investment? }` |
| GET | `/investments` | Portfolio | I | – | Page<Investment> with maturity/settlement state |
| GET | `/investments/{id}` | Detail | I owner / A | – | Investment |
| GET | `/investor/transactions` | Investment transaction history | I | – | Page<BlockchainTransaction> |

## 10. AI invoice processing  (advisory only; server-side key)
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| POST | `/ai/extract` | Extract fields from uploaded PDF | M | `{ document_id }` | `{ fields{invoice_number, merchant, customer, amount, currency, issue_date, due_date, description}, confidence, flags[] }` |
| POST | `/ai/invoices/{id}/validate` | Missing/inconsistent info, duplicate similarity | M / A | – | `{ issues[], duplicates[], confidence }` |
| POST | `/ai/invoices/{id}/summary` | Summary + status explanation | M | – | `{ summary, status_explanation }` |
| POST | `/ai/invoices/{id}/categorize` | Expense category | M | – | `{ category, rationale }` |
| POST | `/ai/invoices/{id}/reminder` | Draft reminder text (never auto-sent) | M | `{ tone? }` | `{ subject, body }` |
| POST | `/ai/summary` | Natural-language financial summary | M | `{ period? }` | `{ text }` |
All AI responses are schema-validated JSON; invalid output → 502 `ai_invalid_output`. Nothing here can change an approval or status.

## 11. Blockchain transactions
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| GET | `/blockchain/transactions` | Transactions related to caller's entities | M / I (own) / A (all) | `?kind=&status=&page=` | Page<BlockchainTransaction{tx_hash, kind, status, block_number, explorer_url}> |
| GET | `/blockchain/transactions/{tx_hash}` | Detail incl. decoded events | M / I / A (scoped) | – | tx + events |
| GET | `/admin/blockchain/events` | Raw indexed events | A | `?contract=&event=&page=` | Page<BlockchainEvent> |
| POST | `/admin/blockchain/reindex` | Re-scan a block range (idempotent) | A | `{ from_block, to_block }` | `{ scanned, inserted }` |

## 12. Admin  (every action writes `audit_logs`)
| Method | Route | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| GET | `/admin/users` | List users | A | `?role=&q=` | Page<Profile> |
| PATCH | `/admin/users/{id}/role` | Change role | A | `{ role }` | Profile |
| GET | `/admin/businesses` | List | A | `?verification_status=` | Page<Business> |
| POST | `/admin/businesses/{id}/verify` / `/reject` | Business verification | A | `{ notes? }` | Business |
| POST | `/admin/invoices/{id}/verify` / `/flag` | Invoice review | A | `{ notes? }` | Invoice (`review_status`) |
| POST | `/admin/investors/{id}/verify` | Verify investor, queue on-chain allowlist | A | `{ notes? }` | Profile |
| GET | `/admin/financing` | Review queue | A | `?status=` | Page<FinancingOffer> (with AI flags) |
| POST | `/admin/financing/{id}/debtor-ack` | Record debtor acknowledgement + assignment notice | A | `{ evidence, acknowledged_at, notice? }` | FinancingOffer |
| POST | `/admin/financing/{id}/approve` | Human approval → backend submits `createOffer` | A | `{ advance_base, maturity_date, funding_deadline }` | FinancingOffer (`APPROVED` → `LISTED` after event) |
| POST | `/admin/financing/{id}/reject` | Reject | A | `{ notes }` | FinancingOffer |
| POST | `/admin/financing/{id}/mark-defaulted` | After maturity + grace | A | – | FinancingOffer |
| GET | `/admin/payments` | Monitor all payments | A | filters | Page<Payment> |
| GET | `/admin/audit-logs` | Audit trail | A | `?actor=&entity=` | Page<AuditLog> |
| GET / PATCH | `/admin/settings` | Platform settings | A | `{ key, value }` | settings |

## 13. Notifications
| GET | `/notifications` | List own | Any | `?unread=` | Page<Notification> |
| POST | `/notifications/{id}/read` | Mark read | Any | – | 204 |

*Out of scope for Step 1:* implementation of any of the above. FastAPI will publish the OpenAPI schema at `/docs` in Step 3.
