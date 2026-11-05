# BillFlow

Business payments and invoice financing on Whitechain Sepolia (ETHGlobal Mumbai — Whitechain *Operate* and *Tokenize* tracks).

Status: **Step 1 of 5 — architecture & foundation (draft, nothing deployed).**

```
contracts/   Solidity + Foundry (Step 2)
backend/     FastAPI + indexer + Claude services (Step 3)
app/         Flutter mobile + web checkout (Step 4)
supabase/    SQL migrations (schema + RLS)
docs/        ARCHITECTURE, DATABASE_SCHEMA, API_SPECIFICATION, SMART_CONTRACT_DESIGN, SECURITY, DEVELOPMENT_ROADMAP
```

Testnet only. Illustrative financing terms are not guaranteed returns, and the on-chain position token does not by itself transfer legal ownership of an invoice.

## Step 2 — contracts
`contracts/` holds `BillFlowPayments` and `InvoiceFinancing` (Foundry, OpenZeppelin v5.1.0 submodule). Run `cd contracts && ./install-deps.sh && forge test`. Not deployed; see `docs/CONTRACT_INTEGRATION.md` and `docs/deployments.md`.

## Step 3 — backend
`backend/` is the FastAPI service (Supabase Auth/Postgres/Storage, Claude, Whitechain indexer). Setup, endpoints, examples, status mapping, manual configuration and
limitations: `docs/BACKEND_API.md`. Quick start: `cd backend && cp .env.example .env && pip install -r requirements.txt && uvicorn app.main:app` → `/docs`.
Tests: `pytest` (real local Postgres; mocked Supabase/Anthropic/chain). Migration `supabase/migrations/0003_backend_support.sql` is additive and must be run after 0001/0002.
