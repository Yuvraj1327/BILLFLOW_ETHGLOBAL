# BillFlow

**Business Payments & Invoice Financing, Powered by Blockchain.** ETHGlobal Mumbai · Whitechain tracks **Operate** (stablecoin payments for business) and **Tokenize** (real-world finance).

> **Status: testnet prototype, partially verified.** The code, contracts and backend are tested locally (see below). **Nothing has been deployed to or
> transacted on Whitechain Sepolia yet**, the Flutter app has **never been compiled**, and no screenshots exist. Sections marked ⏳ need the manual steps in
> [`docs/DEPLOYMENT_GUIDE.md`](docs/DEPLOYMENT_GUIDE.md). Not production-ready; not audited; the on-chain claim token does **not** transfer legal ownership of an invoice.

## Problem
Small businesses invoice in PDFs, get paid late through slow rails, and cannot easily turn an unpaid invoice into working capital. Payers need a checkout that
works with just a wallet; investors need verifiable, on-chain evidence of what they fund.

## Solution
1. **Operate** — a merchant issues an invoice (optionally pre-filled from a PDF by Claude, human-reviewed) and shares a payment link. The customer opens a public
   checkout, connects a wallet, approves USDT and pays through `BillFlowPayments`; the contract sends USDT **directly to the merchant**, only against a server-signed
   EIP-712 quote bound to the payer, invoice, amount and expiry. The backend independently re-reads the receipt and events before anything is marked paid.
2. **Tokenize** — an unpaid invoice can be registered in `InvoiceFinancing` (hashes only), verified by a human role, listed as an offer, funded by an investor in USDT
   (advance goes straight to the business), and settled when the debtor repays (face value goes straight to the investor). A restricted ERC-721 represents the claim.

## Features and honest status
| Feature | Status | Evidence |
|---|---|---|
| Smart contracts (payments, financing, **refunds**) | **Unit/fuzz/invariant tested locally**; Slither run | 92 Foundry tests |
| FastAPI backend (auth, RBAC, invoices, AI, payments, financing, admin, indexer, **checkout API, refunds, webhooks, CSV**) | **Integration tested** against real Postgres, mocked Supabase/Claude | 185 pytest tests |
| **Embeddable checkout widget** (`billflow.js`), hosted `/pay/<token>`, Node SDK, **independent demo merchant** | Core flow tested against a **local Anvil chain** through the real backend; widget UI tested with a DOM stub only — **not yet in a real browser with a real wallet** | `backend/tests/js/`, `backend/tests/test_step6_local_chain.py`, `demo-merchant/` |
| Contracts ⇄ backend verification | **Integration tested on a local Anvil chain (id 1874)** with the compiled contracts, real web3 client, real event decoding — *not Whitechain* | `backend/tests/test_local_chain_e2e.py` |
| Claude invoice extraction/summary/reminder/validation | Tested with a **fake LLM**; never run against the live Anthropic API | `backend/tests/test_ai.py` |
| Flutter app (web + mobile UI) | **Written, never compiled or run** | `app/` |
| Mobile wallet (WalletConnect) | **Not implemented** (browser wallets on Flutter Web only) | — |
| Live Whitechain deployment, USDT payment, financing, settlement | ⏳ **Not done** (sandbox could not reach the RPC) | `docs/deployments.md` is empty on purpose |
| Contract verification on the explorer | ⏳ Not done | |
| Backend hosting | ⏳ Config prepared (`backend/Dockerfile`, `render.yaml`), **not deployed, image never built** | |
| Android APK/AAB | ⏳ **Not built** (no Flutter SDK available) | |

## Operate track — BillFlow Checkout (drop-in USDT payments)
Any merchant app integrates in ~20 lines: create a session server-side with an API key, open the widget (or redirect to the hosted
page), receive a **signed webhook**, and refund (full/partial, on-chain) when needed. The customer pays **official testnet USDT on
Whitechain Sepolia straight to the merchant**; a payment counts only after the backend verifies it on-chain. See
[`docs/CHECKOUT_INTEGRATION.md`](docs/CHECKOUT_INTEGRATION.md), the working independent store in [`demo-merchant/`](demo-merchant/),
and the server SDK in [`sdk/billflow-node/`](sdk/billflow-node/). Extras: partial payments, `BillFlowRefunds` (merchant-signed,
refund-to-original-payer, capped, replay-protected), HMAC-signed webhooks with retries, accountant CSV export.
*Why on-chain:* the refund ledger, the payer/merchant binding and the payment record are public and tamper-evident, and settlement is
final USDT movement rather than a processor's promise.

## Tokenize track — hardening added in Step 6
Hard duplicate-financing block (same PDF hash or same invoice identity, across businesses), debtor-acknowledgement **document hash**
anchored on-chain verbatim, per-business **exposure cap** and per-invoice **maximum advance** enforced in the contract, permissionless
default marking after maturity + grace, maturity countdown (`days_to_maturity`) and due-soon/overdue notifications.

## Stack
Flutter · FastAPI · Supabase (Auth, Postgres, Storage) · Anthropic Claude (via backend only) · Solidity 0.8.28 + Foundry + OpenZeppelin 5.1 · Whitechain Sepolia (OP Stack, chain 1874) · USDT.

## Architecture
```
Flutter ──JWT──▶ FastAPI ──▶ Supabase Postgres/Storage        Claude (server-side only)
   │                │  ▲
   │ wallet signs   │  └── indexer + /verify endpoints re-read receipts & events from the chain
   ▼                ▼
 Whitechain Sepolia: BillFlowPayments · InvoiceFinancing · USDT
```
The database is **not** the source of truth for money: invoice `PAID` and financing `FUNDED/SETTLED` change only from verified contract events. Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Local setup
```bash
# contracts (needs Foundry; if solc cannot be downloaded: export FOUNDRY_SOLC=/path/to/solc-0.8.28)
cd contracts && ./install-deps.sh && forge build && forge test
# backend
cd backend && pip install -r requirements-dev.txt && cp .env.example .env     # fill in
pytest                                   # needs a local Postgres (see tests/conftest.py); local-chain e2e needs anvil + forge build
uvicorn app.main:app --reload            # http://localhost:8000/docs
# app
cd app && flutter create . --platforms=web,android,ios && flutter pub get && flutter analyze && flutter test
flutter run -d chrome --dart-define-from-file=env.json
```
Apply `supabase/migrations/0001…0003` in order to a Supabase project.

## Whitechain configuration
Chain ID **1874** · RPC `https://rpc.testnet.whitechain.io` · Explorer `https://explorer.testnet.whitechain.io` · native token WBT · official test USDT
`0xcedfB56113143d55b2358b8CFbB0dEB5Ad2f55a7` (from the ETHGlobal Mumbai Whitechain prize page; the deploy script still reads `decimals()` from the chain before use).

## Contract addresses and transactions
⏳ **None yet.** Fill `docs/deployments.md` after you deploy. Do not copy addresses from anywhere else. The required evidence for the prize (explorer links to a real USDT payment,
registration, funding and settlement) must be pasted here after the live run.

## API
Interactive docs at `/docs` (disable in production with `ENABLE_DOCS=false`); endpoint reference and examples in [`docs/BACKEND_API.md`](docs/BACKEND_API.md).

## Why on-chain stablecoin settlement on Whitechain
Payment proof and the financing lifecycle must be verifiable by three parties who do not trust each other (merchant, payer, investor). A USDT transfer on Whitechain gives final,
publicly checkable settlement with the payment reference (invoice id/hash) in the event, which a card or bank rail cannot give an investor or an accountant.

## Before / during the hackathon
⏳ To be completed by the team with real dates from the git history (see checklist).

## Known limitations
No live testnet evidence yet · Flutter never compiled · browser-wallet only · AI path untested against the real API · in-memory rate limiter (per process) · indexer must run as an
always-on worker · single admin key controls roles/pause (use a multisig for anything real) · after the advance, the business has no on-chain repayment obligation (recourse is off-chain) ·
no refunds/renewals/exports · formal security audit **not** performed.

## Docs
`docs/TESTING_REPORT.md` · `docs/SECURITY_REPORT.md` · `docs/DEPLOYMENT_GUIDE.md` · `docs/DEMO_SCRIPT.md` · `docs/SUBMISSION_CHECKLIST.md` · `WHITECHAIN_FEEDBACK.md`
