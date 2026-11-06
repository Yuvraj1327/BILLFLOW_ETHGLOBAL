# Testing report (Step 5)

Environment: Linux sandbox, Python 3.13, Foundry 1.5.1 (solc 0.8.28 local binary), PostgreSQL 16, Anvil. **No Flutter SDK. No access to the Whitechain RPC (HTTP 403 from the sandbox proxy).**

Legend: **Unit** · **Integration (local)** · **Live testnet** · **Production**. Nothing below is Live testnet or Production.

| Area | Level reached | Result |
|---|---|---|
| Solidity contracts | Unit + fuzz (512 runs) + invariant (128 runs × 32 depth) | 70/70 pass |
| Backend API (auth, RBAC, isolation, invoices, AI, payments, financing, admin, indexer, RLS) | Integration (real Postgres; Supabase/Claude/chain faked) | 125/125 pass (121 existing + hardening + 4 local-chain) |
| Backend ⇄ **real compiled contracts** | Integration on a **local Anvil node, chain id 1874, mock 6-decimals token** | pass (below) |
| Flutter app | **Nothing executed** (no SDK). 5 test files written | NOT RUN |
| Claude API | Fake LLM only | live API NOT TESTED |
| Whitechain deployment / payment / financing / settlement | **NOT DONE** | — |

## Local-chain end-to-end (what it proves)
`backend/tests/test_local_chain_e2e.py` deploys the compiled `BillFlowPayments`, `InvoiceFinancing` and a mock token to Anvil, then drives the real FastAPI app:
* **Payment:** invoice 1000 → payment link → public checkout payload (no internal ids leaked) → signed EIP-712 quote → approve → `payInvoice` → backend verifies receipt + events after 3+ confirmations → invoice `PAID`, merchant balance +1000, public status shows the tx. Wrong caller using the quote is refused by the contract; a second payment with the same quote reverts; re-verifying the same tx is idempotent (one payment row).
* **Financing:** submit → duplicate request rejected → admin approve with debtor-ack evidence → publish plan → `registerInvoice` → `verifyInvoice` → `createOffer` (each sent from a role-holding key, each verified by the backend) → offer `LISTED` → investor `approve`+`fund` → business received the advance → status `FUNDED` → non-funded caller and duplicate funding revert → debtor `repay` → investor received the face value → `SETTLED` → duplicate settlement reverts → invoice `PAID`.
* **Flutter ABI check:** the Dart `payInvoice` test vector equals web3's encoding of the compiled ABI, and every selector constant in `abi.dart` equals the selector of the compiled contracts. (The Dart code itself still has not run.)

This is **not** evidence about Whitechain: different node, mock token, throw-away keys from the public Anvil mnemonic.

## Prompt checklist: what was and wasn't covered
| Prompt item | Status |
|---|---|
| Auth: roles, invalid/expired JWT, unauthorized role, business isolation | Integration tested (test_auth, test_invoices, test_rls) |
| Invoice: invalid input, duplicates, unauthorized edits, payment-link, public view | Integration tested |
| AI: invalid PDF, timeout, invalid output, missing fields, human review | Tested with fake LLM; **live Claude not tested**; AI cannot approve/pay (no code path) |
| Real USDT payment on Whitechain (steps 1–13) | **Not done** — local chain only |
| Financing lifecycle on Whitechain | **Not done** — local chain only |
| Unverified invoice rejection, duplicate financing/funding/settlement, deadline, wrong amount, insufficient balance, unauthorized | Contract unit tests + local e2e (duplicates, wrong caller) |
| Early repayment / maturity / default / overdue | Contract unit tests (`markDefaulted`, `isOverdue`, repay after default) |
| Reorg / RPC failure / duplicate event handling | Integration tested with the fake chain (test_indexer) |
| Flutter analyze/tests/UI audit, APK | **Not done** |

## How to reproduce
```bash
cd contracts && export FOUNDRY_SOLC=/path/to/solc-0.8.28 && forge test
cd backend && pytest -rs     # starts Postgres per tests/conftest.py; the local-chain tests need `anvil` and contracts/out
```


## Step 6 additions (local only — nothing here ran against Whitechain)
| Suite | Result |
|---|---|
| Foundry (all) | **92 pass** (+22: `BillFlowRefunds` 14 incl. 512-run fuzz and reentrancy; `InvoiceFinancing` +7 limits/permissionless default/countdown; +1 invariant `exposure == sum of open advances`) |
| pytest (all) | **185 pass** (+60: `test_step6_backend.py` 55, `test_step6_local_chain.py` 2, `test_js_widget.py` 2, refunds preflight 1) |
| Node: widget core + UI stub | 22 pass (`backend/tests/js/`) — calldata vs independent ABI vector, quote tampering, wallet-success-is-not-success, timeouts, XSS-as-text |
| Node: SDK + demo merchant | 3 pass (`demo-merchant/test/`) — signature verify, forged/stale rejected, duplicate/out-of-order webhooks |
| Local-chain E2E (Anvil, id 1874, real contracts) | demo store → API key → session → **real `billflow.js` pay()** → backend verification → signed webhooks → partial + full refund through `BillFlowRefunds` → chain-check → CSV → preflight. Ran 3× consecutively, stable. |

Bugs found by these tests and fixed during Step 6: negative `uint` accepted by the widget's ABI encoder (would have produced garbage calldata);
CSV guard corrupted negative refund amounts; duplicate-financing audit row rolled back with the rejected request; demo webhook handler was
order-dependent (summed deliveries instead of using the cumulative total); `payments.onchain_payment_id` unique index would have broken
reorg re-indexing (now a plain index).

**Not covered:** real browser + real wallet for the widget UI; Flutter (unchanged, still never compiled; no Flutter refund UI was added);
live Whitechain behaviour of any of this; the official USDT (all tests use a local mock token); AI extraction confirmation audit record (not built).
