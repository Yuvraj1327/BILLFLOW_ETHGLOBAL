# BillFlow backend — Step 3 (FastAPI · Supabase · Anthropic · Whitechain indexer)

Interactive docs: `GET /docs` (Swagger) and `GET /redoc`. Base path `/api/v1`. All errors use one envelope:
`{"error": {"code", "message", "details"}}`. Auth: `Authorization: Bearer <Supabase access token>`.

> **Honest scope note.** Everything below was exercised by 119 automated tests against a **real local PostgreSQL 16 with migrations
> 0001–0003 applied**, using **mocks** for Supabase Auth/Storage, Anthropic and the Whitechain RPC (a `FakeChain` that produces real
> ABI-encoded logs). Nothing was run against live Supabase, live Anthropic, or the live chain: no contracts are deployed and the
> sandbox cannot reach the Whitechain RPC. The example payloads in this file were captured from those mock-backed runs
> (contract addresses like `0x3333…` are test fixtures, not deployments).

## 1. Architecture
```
Flutter ──JWT──▶ FastAPI (api/ → services/ → repositories/ → Postgres)
                    │  services/blockchain_service  ── RPC ──▶ Whitechain Sepolia (1874)
                    │  services/event_processor  ◀── workers/blockchain_indexer (polls logs)
                    │                            ◀── also called by /payments/verify and /financing/verify-transaction
                    │  services/anthropic_service ── Claude (forced tool-use + strict Pydantic validation)
                    └─ services/supabase_client  ── GoTrue + Storage (service-role key, server only)
```
* **Role comes from the database** (`profiles.role`), never from the JWT body or the request. `admin` cannot be self-assigned.
* **One write path for chain-derived state:** `event_processor.process_event` — shared by the indexer and the tx-hash endpoints.
  Only it can set invoice `PARTIALLY_PAID/PAID` or financing `LISTED/FUNDED/SETTLED/EXPIRED/DEFAULTED`.
* The backend **never** holds user keys, signs user transactions, or moves funds. Its only key is the EIP-712 *quote signer*, which signs
  authorisations that `BillFlowPayments` checks; the payer's own wallet sends the transaction.

## 2. Endpoints (77, plus `GET /health`)

### AI (advisory only)
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/ai/extract-invoice` | Extract invoice fields from a PDF. Nothing is saved or approved; the merchant reviews the result. |
| POST | `/api/v1/ai/invoice-summary` | Plain-language invoice summary |
| POST | `/api/v1/ai/payment-reminder` | Draft a reminder (never sent automatically) |
| POST | `/api/v1/ai/validate-invoice` | Deterministic checks + AI warnings; advisory only |

### Admin
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/admin/audit-logs` | Audit log |
| GET | `/api/v1/admin/businesses` | List businesses |
| GET | `/api/v1/admin/events` | Indexed contract events (processed or not) |
| GET | `/api/v1/admin/indexer` | Indexer status |
| GET | `/api/v1/admin/invoices/{invoice_id}/documents` | Admin: documents of any invoice (financing review) |
| GET | `/api/v1/admin/invoices/{invoice_id}/documents/{doc_id}/url` | Admin: 60-second signed URL for a document |
| GET | `/api/v1/admin/settings` | Platform settings |
| GET | `/api/v1/admin/transactions` | Tracked blockchain transactions |
| GET | `/api/v1/admin/users` | List users |
| PATCH | `/api/v1/admin/users/{user_id}/investor-verification` | Verify or reject an investor (off-chain record) |
| PATCH | `/api/v1/admin/users/{user_id}/role` | Change a user's role (the ONLY way to create an admin) |
| POST | `/api/v1/admin/businesses/{business_id}/review` | Verify or reject a business |
| POST | `/api/v1/admin/indexer/retry` | Retry parked (unprocessed) events now |
| POST | `/api/v1/admin/invoices/{invoice_id}/review` | Mark an invoice verified/flagged (off-chain advisory record) |
| PUT | `/api/v1/admin/settings/{key}` | Change a platform setting |

### Auth
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/auth/me` | Current user (role comes from the database) |
| POST | `/api/v1/auth/login` | Log in with e-mail and password |
| POST | `/api/v1/auth/logout` | Revoke the current session |
| POST | `/api/v1/auth/refresh` | Exchange a refresh token |
| POST | `/api/v1/auth/signup` | Create an account |
| POST | `/api/v1/auth/wallet/challenge` | Start wallet-ownership proof |
| POST | `/api/v1/auth/wallet/verify` | Link a wallet by signing the challenge (EIP-191) |

### Blockchain
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/blockchain/config` | Public chain configuration for wallets/clients (no secrets) |
| GET | `/api/v1/blockchain/health` | Admin: preflight against the live chain (addresses really are the expected contracts) |
| GET | `/api/v1/blockchain/transactions/{tx_hash}` | Tracked status of a transaction hash |

### Business & Customers
| Method | Path | Purpose |
|---|---|---|
| DELETE | `/api/v1/businesses/me/members/{user_id}` | Remove a member (owner only) |
| DELETE | `/api/v1/customers/{customer_id}` | Archive customer (soft delete; invoices keep their history) |
| GET | `/api/v1/businesses/me` | My business |
| GET | `/api/v1/businesses/me/members` | List members |
| GET | `/api/v1/customers` | List customers |
| GET | `/api/v1/customers/{customer_id}` | Get customer |
| PATCH | `/api/v1/businesses/me` | Update my business (owner only) |
| PATCH | `/api/v1/customers/{customer_id}` | Update customer |
| POST | `/api/v1/businesses` | Create my business (merchants without one) |
| POST | `/api/v1/businesses/me/members` | Add an existing merchant user (owner only) |
| POST | `/api/v1/customers` | Create customer |

### Financing
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/financing/investments` | Investments (investor: mine; merchant: on my invoices; admin: all) |
| GET | `/api/v1/financing/investments/{investment_id}` | One investment |
| GET | `/api/v1/financing/invoices/{invoice_id}` | Financing offer of an invoice |
| GET | `/api/v1/financing/offers` | Offers visible to me (merchant: mine; investor: LISTED/active; admin: all) |
| GET | `/api/v1/financing/offers/{offer_id}` | One offer |
| GET | `/api/v1/financing/settlements` | Settled investments |
| POST | `/api/v1/financing/offers/{offer_id}/cancel` | Cancel a not-yet-registered request |
| POST | `/api/v1/financing/offers/{offer_id}/publish` | Returns the exact on-chain steps a role-holding wallet must send (the backend never signs) |
| POST | `/api/v1/financing/offers/{offer_id}/verify` | Admin review: start_review / approve / reject |
| POST | `/api/v1/financing/submit` | Merchant requests financing for an invoice (status REQUESTED; nothing happens on-chain) |
| POST | `/api/v1/financing/verify-transaction` | Verify a financing tx hash on-chain; state changes only from verified contract events |

### Investors
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/investors/me/portfolio` | Portfolio summary (computed from verified on-chain data only) |

### Invoices
| Method | Path | Purpose |
|---|---|---|
| DELETE | `/api/v1/invoices/{invoice_id}` | Delete a DRAFT invoice (issued invoices must be cancelled) |
| GET | `/api/v1/invoices` | List my business's invoices |
| GET | `/api/v1/invoices/{invoice_id}` | Get an invoice |
| GET | `/api/v1/invoices/{invoice_id}/documents` | Documents attached to an invoice |
| GET | `/api/v1/invoices/{invoice_id}/documents/{doc_id}/url` | 60-second signed URL for a private document |
| GET | `/api/v1/invoices/{invoice_id}/payment-status` | Status derived from verified on-chain payments |
| PATCH | `/api/v1/invoices/{invoice_id}` | Edit a DRAFT invoice |
| POST | `/api/v1/invoices` | Create an invoice (DRAFT, or PENDING with issue=true) |
| POST | `/api/v1/invoices/{invoice_id}/cancel` | Cancel an unpaid, un-financed invoice |
| POST | `/api/v1/invoices/{invoice_id}/issue` | DRAFT -> PENDING |
| POST | `/api/v1/invoices/{invoice_id}/payment-link` | Create the public checkout link (revokes the previous one) |
| POST | `/api/v1/invoices/{invoice_id}/upload` | Attach the invoice PDF (private storage) |

### Payments
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/payments` | Payments visible to me (merchant: my business; others: from my wallet) |
| GET | `/api/v1/payments/invoice/{invoice_id}` | Payments of one invoice |
| GET | `/api/v1/payments/transaction/{tx_hash}` | Payments recorded for a tx hash |
| GET | `/api/v1/payments/{payment_id}` | One payment |
| POST | `/api/v1/payments/verify` | Verify a payment transaction on-chain (the client's claim of success is never trusted) |

### Public checkout
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/public/invoices/{token}` | Invoice as shown on the checkout page (minimal data) |
| GET | `/api/v1/public/invoices/{token}/status` | Payment status for the checkout page |
| POST | `/api/v1/public/invoices/{token}/payment-intent` | Get a signed, single-use, expiring quote to pay with your own wallet |

### Users
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/notifications` | My notifications |
| GET | `/api/v1/users/me` | My profile |
| PATCH | `/api/v1/users/me` | Update my display name (role/wallet cannot be set here) |
| POST | `/api/v1/notifications/read-all` | Mark all my notifications read |
| POST | `/api/v1/notifications/{notification_id}/read` | Mark one notification read |

Step 1's spec used a few different paths (`/me`, `/invoices/{id}/documents` upload, `/ai/invoices/{id}/…`); Step 3's brief paths were followed
(`/users/me`, `/invoices/{id}/upload`, `/ai/invoice-summary` …). Extra endpoints beyond the brief: `/auth/*`, `/users/me`, notifications,
`/businesses*`, `/customers*`, invoice `issue`/`cancel`/documents, `/financing/offers/{id}/cancel`, `/investors/me/portfolio`, `/blockchain/*`, `/admin/*`.
Not implemented: a separate `categorize` AI endpoint (the category is returned by `/ai/invoice-summary`).

## 3. Status mapping
| Invoice | Set by |
|---|---|
| `DRAFT → PENDING` | merchant (`issue`) |
| `PENDING/OVERDUE → CANCELLED` | merchant (`cancel`; blocked when paid or financed) |
| `→ OVERDUE` | indexer maintenance pass (due date passed) |
| `→ PARTIALLY_PAID / PAID` | **only** a verified `InvoicePaid` event (or financing `OfferSettled`) |

| Financing (DB) | Brief label | Set by |
|---|---|---|
| `REQUESTED` | SUBMITTED | merchant `submit` |
| `UNDER_REVIEW`, `APPROVED` (shown VERIFIED), `REJECTED` | UNDER_REVIEW / VERIFIED / REJECTED | admin `verify` (off-chain review) |
| `CANCELLED` | CANCELLED | merchant/admin before on-chain registration, or an `InvoiceCancelled`/`OfferCancelled` event |
| `LISTED` | AVAILABLE | **only** an `OfferCreated` event |
| `FUNDED` | ACTIVE | **only** an `OfferFunded` event |
| `SETTLED` | SETTLED | **only** an `OfferSettled` event |
| `DEFAULTED` (or FUNDED past maturity) | OVERDUE | `OfferDefaulted` event (`is_overdue` is computed) |
| `EXPIRED` | EXPIRED | `OfferExpired` event |

## 4. Examples (captured from the mock-backed test run)
### Create + issue an invoice — `POST /invoices`
`201`
```json
{
  "id": "e11e6c32-f5c9-4bca-9037-100d77490394",
  "merchant_id": "fd842ee3-3864-4f04-93d3-b0094d694581",
  "customer_id": "aae3949f-de29-4a49-bc8a-a644235051d0",
  "customer_name": "Globex Corp",
  "invoice_number": "INV-2026-001",
  "description": "Consulting, October",
  "amount": "100",
  "amount_base": "100000000",
  "token_decimals": 6,
  "currency": "USDT",
  "issue_date": "2026-11-05",
  "due_date": "2026-12-05",
  "status": "PENDING",
  "paid_amount": "0",
  "paid_amount_base": "0",
  "review_status": "unverified",
  "onchain_invoice_id": "0x1e53e53779a64743f2bf1d1d31cdf13afd9c015a49f0e608dd3d6ceceed18691",
  "invoice_hash": "0x8680c3b0e9f2bcafe8b471f6415fe5de6882e4504e15d3fa2d67d87c36c43c3c",
  "document_hash": null,
  "payment_tx_hash": null,
  "payment_explorer_url": null,
  "financing_status": null,
  "financing_offer_id": null,
  "created_at": "2026-11-05T12:57:47.450724Z",
  "updated_at": "2026-11-05T12:57:47.456435Z"
}
```

### Public payment link flow
`POST /invoices/{id}/payment-link` → `201`
```json
{
  "id": "856c1362-7254-423d-9dfd-2d46b0ff96cf",
  "token": "xlowEoRS1eYHpskwfPfY98MijtEQa4RpGb8GpzXVXT4",
  "url": "https://pay.test/pay/xlowEoRS1eYHpskwfPfY98MijtEQa4RpGb8GpzXVXT4",
  "expires_at": "2026-12-05T12:57:47.472739Z"
}
```

`GET /public/invoices/{token}` (no auth) → `200`
```json
{
  "merchant_name": "Acme Ltd",
  "invoice_number": "INV-2026-001",
  "description": "Consulting, October",
  "amount": "100",
  "paid_amount": "0",
  "remaining_amount": "100",
  "currency": "USDT",
  "due_date": "2026-12-05",
  "status": "PENDING",
  "payable": true,
  "payable_reason": null,
  "chain_id": 1874,
  "usdt_address": "0x1111111111111111111111111111111111111111",
  "usdt_decimals": 6,
  "payments_contract": "0x2222222222222222222222222222222222222222",
  "link_expires_at": "2026-12-05T12:57:47.472739Z"
}
```

`POST /public/invoices/{token}/payment-intent` with `{"payer_wallet": "0x…"}` → signed single-use quote (signature shortened):
`200`
```json
{
  "chain_id": 1874,
  "payments_contract": "0x2222222222222222222222222222222222222222",
  "usdt_address": "0x1111111111111111111111111111111111111111",
  "usdt_decimals": 6,
  "approve_amount_base": "100000000",
  "quote": {
    "invoiceId": "0x1e53e53779a64743f2bf1d1d31cdf13afd9c015a49f0e608dd3d6ceceed18691",
    "invoiceHash": "0x8680c3b0e9f2bcafe8b471f6415fe5de6882e4504e15d3fa2d67d87c36c43c3c",
    "merchant": "0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa",
    "payer": "0x9999999999999999999999999999999999999999",
    "amount": "100000000",
    "invoiceTotal": "100000000",
    "nonce": "7092746327884944339084754315827273441452288317148878471115019189032470631739",
    "expiry": "1793884367"
  },
  "signature": "0x101a946205fb42b38d\u2026",
  "quote_expires_at": "2026-11-05T13:12:47.553151Z",
  "eip712_domain": {
    "name": "BillFlowPayments",
    "version": "1",
    "chainId": 1874,
    "verifyingContract": "0x2222222222222222222222222222222222222222"
  },
  "instructions": "1) USDT.approve(payments_contract, approve_amount_base)  2) BillFlowPayments.payInvoice(quote, signature) from the payer wallet  3) report the tx hash; the backend verifies it on-chain."
}
```

### Verify a payment — `POST /payments/verify` with `{"tx_hash": "0x…"}`
`200`
```json
{
  "tx_hash": "0x76af40861b0efb2c5b67df9f775f52c94f6c43eed0f6d1a0ecafac9367087459",
  "stage": "verified",
  "detail": "",
  "confirmations": 101,
  "required_confirmations": 3,
  "block_number": 100,
  "explorer_url": "https://explorer.testnet.whitechain.io/tx/0x76af40861b0efb2c5b67df9f775f52c94f6c43eed0f6d1a0ecafac9367087459",
  "events": [
    {
      "name": "InvoicePaid",
      "log_index": 1,
      "outcome": "applied",
      "detail": "PAID"
    }
  ],
  "payment_ids": [
    "59e41824-84b8-462c-a73a-aa0f772ca033"
  ],
  "offer_ids": []
}
```

An unknown or unmined hash is never trusted and marks nothing: `200`
```json
{
  "tx_hash": "0x94cb72bbeb5c48380b31d0a74b0122e768f6fec5b74b992583dcaa9e4f7f07e2",
  "stage": "not_found",
  "detail": "Transaction not found on Whitechain yet (not mined or wrong network)",
  "confirmations": 0,
  "required_confirmations": 3,
  "block_number": null,
  "explorer_url": "https://explorer.testnet.whitechain.io/tx/0x94cb72bbeb5c48380b31d0a74b0122e768f6fec5b74b992583dcaa9e4f7f07e2",
  "events": [],
  "payment_ids": [],
  "offer_ids": []
}
```

Then `GET /invoices/{id}/payment-status` → `200`
```json
{
  "invoice_id": "e11e6c32-f5c9-4bca-9037-100d77490394",
  "status": "PAID",
  "amount": "100",
  "paid_amount": "100",
  "remaining_amount": "0",
  "payments": [
    {
      "id": "59e41824-84b8-462c-a73a-aa0f772ca033",
      "payer_wallet": "0x9999999999999999999999999999999999999999",
      "amount": "100",
      "amount_base": "100000000",
      "tx_hash": "0x76af40861b0efb2c5b67df9f775f52c94f6c43eed0f6d1a0ecafac9367087459",
      "explorer_url": "https://explorer.testnet.whitechain.io/tx/0x76af40861b0efb2c5b67df9f775f52c94f6c43eed0f6d1a0ecafac9367087459",
      "status": "CONFIRMED",
      "confirmed_at": "2026-11-05T12:57:47.568192Z"
    }
  ],
  "financing_status": null,
  "payable": false,
  "payable_reason": "Invoice is PAID"
}
```

### Financing
`POST /financing/submit` with `{"invoice_id": "…", "advance": "90"}` → `201`
```json
{
  "id": "6c94894b-092d-4edd-9905-2bcf81496b4f",
  "invoice_id": "ccdc5561-aa5c-4d88-9490-ddc55a8760dd",
  "invoice_number": "INV-2026-002",
  "business_id": "fd842ee3-3864-4f04-93d3-b0094d694581",
  "business_name": "Acme Ltd",
  "business_verified": true,
  "status": "REQUESTED",
  "display_status": "SUBMITTED",
  "is_overdue": false,
  "face_value": "100",
  "face_value_base": "100000000",
  "advance": "90",
  "advance_base": "90000000",
  "discount_bps": 1000,
  "token_decimals": 6,
  "maturity_date": "2026-12-05",
  "funding_deadline": "2026-11-08T12:57:47.620493Z",
  "onchain_offer_id": null,
  "onchain_registered_at": null,
  "onchain_verified_at": null,
  "contract_address": "0x3333333333333333333333333333333333333333",
  "debtor_ack": null,
  "assignment_notice": null,
  "review_notes": null,
  "created_at": "2026-11-05T12:57:47.617241Z",
  "disclosure": "Testnet demo. Invoice financing carries credit risk: the debtor may not repay. The discount is not a guaranteed return, and AI extraction or platform review is not a legal verification of the underlying invoice."
}
```

`POST /financing/offers/{id}/verify` (admin) with `{"decision":"approve","debtor_ack":{…},"assignment_notice":{…}}` → `200`
```json
{
  "id": "6c94894b-092d-4edd-9905-2bcf81496b4f",
  "invoice_id": "ccdc5561-aa5c-4d88-9490-ddc55a8760dd",
  "invoice_number": "INV-2026-002",
  "business_id": "fd842ee3-3864-4f04-93d3-b0094d694581",
  "business_name": "Acme Ltd",
  "business_verified": true,
  "status": "APPROVED",
  "display_status": "VERIFIED",
  "is_overdue": false,
  "face_value": "100",
  "face_value_base": "100000000",
  "advance": "90",
  "advance_base": "90000000",
  "discount_bps": 1000,
  "token_decimals": 6,
  "maturity_date": "2026-12-05",
  "funding_deadline": "2026-11-08T12:57:47.620493Z",
  "onchain_offer_id": null,
  "onchain_registered_at": null,
  "onchain_verified_at": null,
  "contract_address": "0x3333333333333333333333333333333333333333",
  "debtor_ack": {
    "notes": null,
    "evidence_ref": "email-thread-42",
    "acknowledged_at": "2026-11-01T10:00:00Z",
    "acknowledged_by": "CFO Globex"
  },
  "assignment_notice": {
    "dated": null,
    "reference": "assignment-letter-7"
  },
  "review_notes": null,
  "created_at": "2026-11-05T12:57:47.617241Z",
  "disclosure": "Testnet demo. Invoice financing carries credit risk: the debtor may not repay. The discount is not a guaranteed return, and AI extraction or platform review is not a legal verification of the underlying invoice."
}
```

`POST /financing/offers/{id}/publish` returns instructions only; **the backend sends nothing**:
`200`
```json
{
  "offer_id": "6c94894b-092d-4edd-9905-2bcf81496b4f",
  "status": "APPROVED",
  "chain_id": 1874,
  "next_step": {
    "step": "register",
    "contract": "0x3333333333333333333333333333333333333333",
    "function": "registerInvoice",
    "signer": "ISSUER role holder",
    "args": {
      "p": {
        "invoiceHash": "0xc8aba40b575bebd97443ebce3ecb575135318d2ed569697f2694c1980b91da66",
        "documentHash": "0x3a8c90fe91c37281083f772a4936cf6dc4fe16122f2f027d68a190e526fde4fc",
        "debtorRef": "0x23556588609e591c34957fcd9925764adfa4716207445b328e361d42eaa6b4b3",
        "business": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "debtor": "0x9898989898989898989898989898989898989898",
        "faceValue": "100000000",
        "issueDate": 1793836800,
        "dueDate": 1796428800
      }
    },
    "note": null
  },
  "remaining_steps": [
    "register",
    "verify",
    "list"
  ],
  "message": "The backend does not send these transactions. A wallet holding the stated role must sign them; status changes only when the resulting events are verified on-chain."
}
```

`POST /financing/verify-transaction` after a role-holding wallet sent `registerInvoice`: `200`
```json
{
  "tx_hash": "0x345249a56576ffaf760a51356ecfb3ccef7042bf9e6226f7428c055e83f14902",
  "stage": "verified",
  "detail": "",
  "confirmations": 100,
  "required_confirmations": 3,
  "block_number": 101,
  "explorer_url": "https://explorer.testnet.whitechain.io/tx/0x345249a56576ffaf760a51356ecfb3ccef7042bf9e6226f7428c055e83f14902",
  "events": [
    {
      "name": "InvoiceRegistered",
      "log_index": 0,
      "outcome": "applied",
      "detail": "registered on-chain"
    }
  ],
  "payment_ids": [],
  "offer_ids": [
    "6c94894b-092d-4edd-9905-2bcf81496b4f"
  ]
}
```

### AI — `POST /ai/extract-invoice` (multipart `file`)
`200`
```json
{
  "extracted": {
    "invoice_number": "INV-2026-003",
    "merchant_name": "Acme Ltd",
    "merchant_address": null,
    "customer_name": "Globex Corp",
    "customer_address": null,
    "amount": "1250.50",
    "currency": "USDT",
    "description": null,
    "issue_date": "2026-10-01",
    "due_date": "2026-11-01",
    "tax_amount": null,
    "tax_id": null,
    "confidence": 0.93,
    "field_confidence": {
      "amount": 0.99
    },
    "warnings": []
  },
  "sha256": "79189d17bfe53d0dabd76c041940b089470998918ee7ad5e722b2774557bb9e6",
  "document_hash": "0x79189d17bfe53d0dabd76c041940b089470998918ee7ad5e722b2774557bb9e6",
  "pages": 1,
  "duplicate_warnings": [],
  "notice": "AI extraction is not legal verification. Review every field before use."
}
```

Model output outside the schema → 502 and nothing is saved: `502`
```json
{
  "error": {
    "code": "ai_invalid_output",
    "message": "AI output did not match the expected format; nothing was saved",
    "details": {
      "fields": [
        "confidence",
        "foo"
      ]
    }
  }
}
```

### Authorisation error
`403`
```json
{
  "error": {
    "code": "role_forbidden",
    "message": "Requires role: admin",
    "details": {}
  }
}
```

## 5. Verification pipeline (payments and financing)
chain id = 1874 → receipt exists → `status == 1` → confirmations ≥ `MIN_CONFIRMATIONS` → block hash still canonical → logs decoded **only** from
the configured contract addresses → (payments) a matching `Transfer` from the configured USDT in the same receipt → invoice id/hash, merchant =
business payout wallet, invoice total and cumulative amounts checked → idempotent insert keyed `(tx_hash, log_index)` and state change in one DB transaction.
`stage`: `not_found · submitted · failed · confirmed (an event is parked for retry) · rejected · verified`.

Parked events (e.g. `OfferFunded` before the investor linked a wallet, or before the listing event was processed) stay unprocessed and the indexer
retries them (`POST /admin/indexer/retry` forces it). **Reorgs:** recent events whose block hash changes are flagged (`reorged_at`, audit row) and the
cursor rewinds; effects already applied are **not automatically reverted** — an admin must review the audit entry.

## 6. Manual configuration you must do (nothing here was done for you)
1. **Supabase:** create the project; run `supabase/migrations/0001…0003` in order in the SQL editor; copy URL, anon key, service-role key, the DB
   connection string and the JWT secret (or JWKS URL) into `backend/.env`. Make the first admin with SQL (`update profiles set role='admin' where email=…`);
   there is intentionally no API to bootstrap an admin.
2. **Anthropic:** put `ANTHROPIC_API_KEY` and an explicit `ANTHROPIC_MODEL` in `.env`.
3. **Chain:** deploy the contracts yourself (Step 2, `docs/deployments.md`); verify the USDT address on the explorer and read `decimals()`; then set
   `WHITECHAIN_USDT_ADDRESS`, `USDT_DECIMALS`, `WHITECHAIN_PAYMENT_CONTRACT`, `WHITECHAIN_FINANCING_CONTRACT`, `INDEXER_START_BLOCK`.
4. **Quote signer:** generate a fresh throwaway key, set `QUOTE_SIGNER_PRIVATE_KEY`, and call `BillFlowPayments.setQuoteSigner(<its address>)` from the
   contract admin (the address is shown by `GET /blockchain/config` → `quote_signer`). `GET /blockchain/health` (admin) should then be all green.
5. **On-chain roles:** grant ISSUER / VERIFIER / OPERATOR and approve businesses/investors on `InvoiceFinancing` from your admin wallet.
6. **Run:** `pip install -r requirements.txt && uvicorn app.main:app`; indexer: `python -m app.workers.blockchain_indexer`
   (or `INDEXER_ENABLED=true` to run it inside the API process).

## 7. Known limitations
* Live Supabase / Anthropic / Whitechain paths are unexercised. The JWKS (asymmetric) verification path is implemented but only HS256 is unit-tested.
* Rate limiting is in-process per IP (resets on restart, not shared across workers); use a proxy limiter in production.
* Reorg handling detects and flags; it does not auto-revert applied effects. The re-check window is `INDEXER_RESCAN_OVERLAP + MIN_CONFIRMATIONS` blocks.
* `blockchain_transactions` only records hashes that were submitted to a verify endpoint.
* Investor allowlist and business approval live **on-chain**; the API mirrors the events but cannot grant them (needs a role-holding wallet).
* If `USDT_DECIMALS` is unset, invoice creation returns 503 rather than guessing.
* AI output is advisory; extraction accuracy was not evaluated on real invoices.

## 8. Tests
`cd backend && pip install -r requirements-dev.txt && pytest`. Needs a local PostgreSQL superuser DSN in `TEST_PG_ADMIN_DSN`
(default `postgresql://postgres@/postgres?host=/tmp&port=54329`); the suite creates and drops its own `billflow_test` database with stub `auth`/`storage`
schemas and runs migrations 0001–0003. Files: `test_auth`, `test_invoices`, `test_payments`, `test_financing`, `test_ai`, `test_indexer`, `test_rls`, `test_misc`.
