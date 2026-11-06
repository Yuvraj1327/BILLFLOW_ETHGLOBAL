# Step 6 completion report — competitive strengthening for Whitechain (Operate + Tokenize)

Everything below was verified **locally** (Foundry, pytest with real Postgres, Node, and a local Anvil chain with chain id 1874 and a
mock token). **Nothing has run on Whitechain Sepolia.** No live deployment, transaction, explorer link or official-USDT payment exists yet;
those are your manual steps (end of this report) and are what the prize actually requires.

## What was built (against the approved scope)

### P0 — hackathon-critical
| Item | State |
|---|---|
| Reusable checkout widget | `backend/app/static/billflow.js` (dependency-free, Shadow-DOM modal or inline) |
| Hosted checkout page | `GET /pay/<token>` served by the API (strict CSP, no framing) |
| Merchant API keys + checkout session API | `POST /merchant/api-keys`; `POST/GET /checkout/sessions…`, idempotency keys, rate limit |
| Independent demo merchant | `demo-merchant/` (+ `sdk/billflow-node/`) — verified end to end on the local chain |
| Existing payment flow | **Untouched contract** (`BillFlowPayments` bytecode/ABI unchanged); backend change is additive (stores the on-chain payment id) |
| Actual USDT payment on Whitechain, deployment, explorer verification, public repo | ⏳ **Yours to do** — see manual steps |
| Full RWA lifecycle live | ⏳ Yours to do (lifecycle itself is locally E2E-tested from Step 5; re-run after redeploy) |

### P1 — important
| Item | State |
|---|---|
| `BillFlowRefunds` (full + partial) | Done, 14 tests incl. fuzz + reentrancy; Slither reviewed |
| Backend refund verification + records | Done: prepare → merchant wallet signs → verify (receipt, confirmations, merchant→payer transfer, payment/party/amount checks) → `CONFIRMED`; chain-check endpoint |
| Hard duplicate financing prevention | Done (same PDF hash / same invoice identity, cross-business), audited |
| Debtor acknowledgement document hash | Done: optional `document_sha256` is anchored on-chain verbatim |
| Per-business exposure cap + per-invoice max advance | Done in `InvoiceFinancing`, invariant-tested; **requires redeploy** |
| Signed webhooks with retry protection | Done (HMAC, timestamp, dedupe id, backoff, SSRF guard) |

### P2 — if time permitted
| Item | State |
|---|---|
| CSV / accountant export | **Done** |
| Maturity countdown + due-date notifications | **Done** (API field `days_to_maturity`; indexer sends due-soon/overdue notices once). **No Flutter UI** |
| Permissionless default marking | **Done** in contract. **Keeper script not written** — anyone can call `markDefaulted`; a one-line `cast send` loop works |
| AI extraction confirmation audit records | **Not done** |
| Minimal Flutter improvements | **Not done** — Flutter has still never been compiled; I did not add unverifiable UI code |
| Gasless USDT | **Not implemented** by decision — see `docs/GASLESS_USDT.md` and run `ProbeUsdtSignatures.s.sol` |

## Files
New: `contracts/src/BillFlowRefunds.sol`, `contracts/test/BillFlowRefunds.t.sol`, `contracts/script/ProbeUsdtSignatures.s.sol`,
`supabase/migrations/0004_checkout_refunds_webhooks.sql`, `backend/app/{api/merchant_api.py,api/static_pages.py,core/public_cors.py,repositories/{refunds,webhooks}.py,schemas/merchant_api.py,services/{checkout,refund,webhook}_service.py,static/{billflow.js,pay.html},abi/BillFlowRefunds.json}`,
`backend/tests/{test_step6_backend.py,test_step6_local_chain.py,test_js_widget.py,js/*}`, `demo-merchant/`, `sdk/billflow-node/`, `docs/{CHECKOUT_INTEGRATION,GASLESS_USDT,STEP6_COMPLETION_REPORT}.md`, `docs/abi/BillFlowRefunds.json`.
Changed (additive unless noted): `InvoiceFinancing.sol` (+limits, permissionless `markDefaulted` — **behaviour change**, test updated), `Deploy.s.sol`, the two Foundry
test files, `config.py`, `main.py`, `public.py`, `event_processor.py`, `blockchain_service.py`, `financing_service.py` (+repo/schema), `payments` repo,
`blockchain_indexer.py`, test `conftest/helpers/test_misc`, `.env.example`, `README.md`, deployment/testing/security/checklist docs.

## Test results (all local)
Foundry **92 pass** · pytest **185 pass** (real Postgres) · Node widget/SDK/demo **25 pass** · local-chain E2E (real contracts + real uvicorn + real Node widget
logic + real demo store) **stable over 3 consecutive runs**. Details and the bugs these found: `docs/TESTING_REPORT.md`.

## Honest limitations
* Widget UI never run in a real browser with a real wallet (DOM stub + real local-chain core only). Do this first when you have a wallet.
* The Whitechain RPC/explorer/USDT behaviour is unverified (decimals, gas, confirmation time, explorer verification flow). `evm_version=shanghai` still a guess.
* Refunds work only for payments indexed **after** this change (the on-chain payment id is stored from now on).
* Webhook SSRF guard doesn't pin the resolved IP (DNS-rebinding window); webhook secrets are stored plaintext (HMAC needs them).
* `InvoiceFinancing` and its ABI changed: **all prior addresses are obsolete** — redeploy; `docs/abi` and `backend/app/abi` were updated together (a test enforces equality).
* No formal audit. No git commits exist in the repo (still a submission risk).

## Manual steps remaining (in order)
1. **Commit** the repo in logical chunks now (judges look at history; do not backdate).
2. Fund wallets (deployer/admin, quote signer, merchant payout, payer, investor) with WBT + official USDT.
3. `forge script script/CheckUsdt.s.sol …` (confirms decimals; set `USDT_DECIMALS` accordingly) and optionally `ProbeUsdtSignatures.s.sol`.
4. `forge script script/Deploy.s.sol … --broadcast` → three contracts; record addresses/tx hashes in `docs/deployments.md`; **verify all three on the explorer**.
5. Supabase: run migrations `0001`–`0004` (0004 is new) if not yet applied; check storage bucket `invoice-documents`.
6. Deploy backend + indexer (`render.yaml`); env incl. `WHITECHAIN_REFUNDS_CONTRACT`, `INDEXER_START_BLOCK`; `GET /blockchain/health` all ok.
7. Operate evidence: create merchant → verify business → API key → webhook → run `demo-merchant` → pay via widget with real USDT → webhook → partial + full refund (approve + refund) → verify → CSV. Paste explorer links in README.
8. Tokenize evidence: register → verify → offer → fund → repay, with explorer links (the exposure cap can be set via env in the deploy script).
9. Record the 2–4 min video (customer, merchant, investor), take screenshots, finish `WHITECHAIN_FEEDBACK.md`, fill the README before/during section, push the repo public, submit.
