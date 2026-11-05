# Security report (Step 5)

**This is an internal engineering review plus automated tooling. It is NOT a formal or third-party audit and gives no certification.** Testnet prototype only.

## What was done
* Manual review of `BillFlowPayments.sol` and `InvoiceFinancing.sol` (access control, reentrancy, accounting, state machine, token handling, signatures).
* Foundry: 70 tests incl. fuzz (512 runs) and a new stateful **invariant suite** (random register/verify/list/fund/repay/cancel/expire/time-warp sequences: the financing contract never holds the payment token; the business receives exactly the funded advances; every settled invoice paid its face value exactly once; a non-vacuity test proves the handler reaches `Settled`).
* Slither (default detectors, `lib/test/script` excluded): 8 results, **all `timestamp` comparisons** (see F-6). No reentrancy, access-control, arbitrary-send or unchecked-transfer findings.
* Backend review: JWT, RBAC, SQL, uploads, rate limiting, CORS, error handling, secrets; 125 tests (incl. RLS and isolation tests).
* Repository scan for committed credentials (pattern scan for Anthropic/JWT/64-hex private keys outside libs/tests): **none found**; `.env*` git-ignored. The repo has no commits yet, so history was not scanned.

**Not done:** third-party audit, formal verification, Echidna/Medusa/Mythril, mutation testing, pen-test, load test, review of the Flutter app by a compiler.

## Findings and status
| ID | Sev | Area | Finding | Status |
|---|---|---|---|---|
| F-1 | Med | Backend | Public rate-limit table (`_hits`) grew without bound with distinct IPs (memory DoS). | **Fixed** (purges stale keys past 10k entries) + test |
| F-2 | Med | Backend | Behind Railway/Render every request shares the proxy IP, so the per-IP limit would throttle everyone together or be bypassed. | **Mitigated**: Dockerfile starts uvicorn with `--proxy-headers`; set `FORWARDED_ALLOW_IPS` to the platform proxy range. Limiter is still **per process, in memory** (not shared across instances) |
| F-3 | Low | Backend | `/docs`, `/openapi.json` always exposed. | **Fixed**: `ENABLE_DOCS=false` disables them (render.yaml sets it) + test |
| F-4 | Med | Design | After the advance is paid to the business, nothing on-chain obliges the *business* to repay; only the debtor (or any third party) can. Default is an informational flag. Investors bear credit risk. | **Accepted / disclosed** in UI and README; needs legal wrapper for anything real |
| F-5 | Med | Ops | Quote-signer key is a hot backend key. If stolen, an attacker can sign quotes (arbitrary merchant/amount) that payers might then pay, if they are lured to a crafted call. Funds still move only from a payer who signs the transaction. | **Mitigated** by short TTL, nonce/revoke, `setQuoteSigner` rotation, throwaway key; the checkout also validates chain/contract/token against the invoice payload. Rotate after the event |
| F-6 | Info | Contracts | `block.timestamp` comparisons (deadlines, maturity, grace) flagged by Slither. | Accepted: day-scale windows on an L2; sequencer-time skew is immaterial |
| F-7 | Low | Contracts | Single `DEFAULT_ADMIN_ROLE` (deployer) can grant roles, change signer/limits and pause. | Accepted for testnet; deploy script supports handing admin to another address; use a multisig for anything real |
| F-8 | Low | Contracts | Fee-on-transfer / reentrant tokens. | Handled: balance-delta checks (`UnexpectedTransferAmount`), `nonReentrant`, tested with fee and reentrant mocks; payment token cannot be rescued |
| F-9 | Info | Backend | Backend DB role bypasses RLS by design (all writes via API). RLS only protects direct client access. | Verified by `test_rls.py`; authorization correctness therefore rests on service-layer checks, covered by tests |
| F-10 | Info | Process | Git history absent; hackathon rules require visible steady progress. | **Open** — see checklist |

## Controls confirmed present
Role read from DB per request (not from JWT); `none`/unknown algs and wrong audience rejected; cross-tenant lookups 404; strict pydantic schemas; parameterised SQL; PDF magic-byte/size/page validation and private storage with 60 s signed URLs; public checkout reveals only checkout fields; idempotent verification (unique tx/log keys); reorg detection flags events; AI output is schema-validated and advisory only (no code path from AI to payment/financing/approval); contracts: EIP-712 quotes bound to payer/invoice/amount/expiry with nonce, pausable payments, `repay` intentionally not pausable.

## Residual risks
Live deployment unverified · Flutter never compiled · live Claude path untested · hot signer key · centralized admin · credit risk · testnet token has no value.
