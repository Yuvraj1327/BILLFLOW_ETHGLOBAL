# BillFlow — Development roadmap, configuration checklist & manual actions

Everything marked **YOU** is a manual action that only you can perform (accounts, credentials, funding, approvals).

## A. Accounts & credentials (YOU)
- [ ] **Supabase** project → copy `SUPABASE_URL`, anon key, service-role key; note whether JWT signing is asymmetric (JWKS) or legacy HS256 secret (Settings → API / JWT).
- [ ] Run `supabase/migrations/0001_init.sql` then `0002_rls.sql` in the SQL editor (or `supabase db push`). Verify bucket `invoice-documents` exists and is **private**.
- [ ] **Anthropic** API key with billing enabled.
- [ ] **GitHub** account ≥ 30 days old + non-zero Ethereum mainnet balance on the wallet/address you use (faucet requirement).
- [ ] Create **3 testnet wallets** (never reuse mainnet keys): deployer/admin, backend quote-signer + operator (can be 2 keys), demo merchant/customer/investor accounts.
- [ ] Claim test **WBT** (gas) at faucet.testnet.whitechain.io — 0.1 WBT per 24h per account, so claim early.
- [ ] Obtain **official testnet USDT**: address, decimals, and source of test tokens (Whitechain docs/team). Record in `docs/deployments.md`.
- [ ] Add Whitechain Sepolia to MetaMask: chain ID 1874, RPC `https://rpc.testnet.whitechain.io`, symbol WBT, explorer `https://explorer.testnet.whitechain.io`.

## B. Tooling (YOU, locally)
- [ ] Foundry (`foundryup`), Flutter SDK (stable, web enabled), Python 3.11+, Git.
- [ ] Hosting accounts for FastAPI (Railway/Render/Fly) and Flutter Web (any static host). Public GitHub repo.

## C. Environment variables
See `backend/.env.example`, `contracts/.env.example`, `app/.env.example`. Secrets (service-role key, Anthropic key, private keys) are **backend/contracts only** — never in Flutter.

## D. Items to verify against official sources before building on them
1. USDT address/decimals/interface. 2. Explorer verification route. 3. Final Whitechain bounty text for both tracks (re-check right before submission; submission deadline reportedly Sun 8 Nov 09:00 IST — unconfirmed). 4. Supabase JWT mode.

## E. Roadmap (each step ends with a review gate)
| Step | Output | Gate |
|---|---|---|
| 1 (this) | Architecture, schema + RLS migrations, API & contract specs, config | Your review of docs, schema, contract design |
| 2 | Contracts + Foundry tests, deployed & verified on 1874, one real USDT payment tx and one real financing cycle | Tx hashes + explorer links |
| 3 | FastAPI + indexer + Supabase integration + Claude services, API tests | Swagger + passing tests |
| 4 | Flutter app (all roles) + Flutter Web checkout wired to real backend/wallet | Click-through demo |
| 5 | E2E test, security pass, deployment, README/FEEDBACK/video | Submission package |

Time note: if the deadline is truly 8 Nov 09:00 IST, the steps must be compressed. Proposed priority inside each step: Operate flow first, Tokenize second, AI third, admin panel minimal (verification + approval only).
