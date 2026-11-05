# BillFlow — Smart contract design (Step 2, implemented)

Status: **implemented and unit-tested locally; NOT deployed to Whitechain Sepolia; USDT address NOT verified.**
Code: `contracts/src/BillFlowPayments.sol`, `contracts/src/InvoiceFinancing.sol` · Foundry · Solidity 0.8.28 · OpenZeppelin v5.1.0 (git submodule) · EVM target `shanghai`.

## Network facts (from Whitechain docs)
Whitechain Sepolia: OP Stack L2, chain ID **1874**, RPC `https://rpc.testnet.whitechain.io`, WebSocket `wss://rpc.testnet.whitechain.io/ws`, explorer `https://explorer.testnet.whitechain.io`, gas token WBT (18 decimals), 1 s blocks, min base fee 5 gwei. Chain 2625 / `rpc-testnet.whitechain.io` is the *legacy L1* — never use it.
**Not verified:** the USDT address (candidate supplied by the team: `0xcedfB56113143d55b2358b8CFbB0dEB5Ad2f55a7`; no Whitechain document found that lists it), its decimals/behaviour, the explorer verification API, and the chain's EVM version support (hence the conservative `shanghai` target). `script/CheckUsdt.s.sol` reads name/symbol/decimals so you can verify before deploying. Contract logic is decimals-agnostic.

## Changes vs the Step 1 draft (and why)
| Change | Reason |
|---|---|
| `InvoiceRegistry` merged into `InvoiceFinancing` | Registration, verification, token and offer share one state machine and one uniqueness index; a second contract would add cross-contract calls and trust boundaries with no benefit. |
| Offer key is a sequential `invoiceId` (= ERC-721 `tokenId`), plus `invoiceIdByHash` | Removes the separate offerId; one id everywhere. DB `financing_offers.onchain_offer_id` stores this id. |
| Roles split: `ISSUER`, `VERIFIER`, `OPERATOR`, `PAUSER` (+ admin) | Separation of duties: verification (human trust decision) is not held by the same key as day-to-day operations. |
| On-chain registration + verification + business/investor approval | Your Step 2 brief requires the contract to prevent financing of unverified invoices and to restrict who may issue/fund. |
| Business may publish its own offer (`createOffer`); operator may do it on behalf | Keeps the Step 1 admin-approval flow working (backend/operator) while allowing the business wallet to publish directly. |
| `repay` is deliberately **not** pausable | Completing an existing obligation must stay possible during an emergency pause. New risk (register, offer, fund, pay) is pausable. |
| Discount cap (`maxDiscountBps`, default 20%, ceiling 50%) | Prevents absurd terms being listed. |
| `InvoicePaid` event has no `status` field | Status is derivable: `totalPaid == invoiceTotal` ⇒ Paid. (Event also carries `paymentId`.) |

## 1. BillFlowPayments (Operate)
Never holds funds: `payInvoice` calls `safeTransferFrom(msg.sender → merchant)`. Authorisation is an **EIP-712 quote** signed by `quoteSigner` (the backend):
`Quote(bytes32 invoiceId, bytes32 invoiceHash, address merchant, address payer, uint256 amount, uint256 invoiceTotal, uint256 nonce, uint64 expiry)`, domain `name="BillFlowPayments"`, `version="1"`, `chainId`, `verifyingContract`.

| Function | Who | Notes |
|---|---|---|
| `payInvoice(Quote, bytes sig) → paymentId` | the quoted payer | checks payer, nonzero merchant, merchant≠payer, amount>0, expiry, single-use nonce, signature; first payment fixes merchant/hash/total, later quotes must match; `amount ≤ remaining`; effects before interaction; balance-delta check rejects fee-on-transfer tokens |
| `getPayment(id)`, `getInvoicePaymentStatus(invoiceId)`, `isInvoicePaid`, `remainingAmount`, `hashQuote`, `DOMAIN_SEPARATOR` | view | |
| `setQuoteSigner`, `pause/unpause`, `revokeNonce` | admin / pauser / signer-or-admin | `revokeNonce` kills an outstanding quote (e.g. invoice cancelled) |

Status: `None → PartiallyPaid → Paid`. Partial payments are supported (cumulative cap, no overpayment, no payment after `Paid`).
Event: `InvoicePaid(invoiceId idx, paymentId idx, payer idx, merchant, amount, totalPaid, invoiceTotal, invoiceHash)`.

## 2. InvoiceFinancing (Tokenize)
**What the token is.** One ERC-721 per invoice (`tokenId = invoiceId`), minted to the contract when the offer is listed, moved to the investor when funded. It is a restricted, non-transferable record of *who is entitled to the repayment under this contract's rules*. All wallet transfers and approvals revert (`TransfersRestricted`); only the contract's own lifecycle can mint/move/burn. **It is not a legal assignment** of the invoice and does not prove legal ownership. Legal assignment and debtor acknowledgement are separate off-chain requirements; only an evidence hash is recorded (`debtorAckRef`). Testnet prototype, with illustrative terms that are not guaranteed returns.

**Lifecycle:** `Registered → Verified → Listed → Funded → Settled`; exits `Rejected`, `Cancelled`, `Expired`, `Defaulted` (late repayment still settles).

| Step | Function | Who | Key rules |
|---|---|---|---|
| Register | `registerInvoice(RegisterParams)` | approved business (self) or `ISSUER_ROLE` | business approved; face>0; invoiceHash/documentHash/debtorRef nonzero; issueDate≤now<dueDate; **hash unique** (`DuplicateInvoice`) |
| Verify | `verifyInvoice(id, debtorAckRef)` / `rejectInvoice` | `VERIFIER_ROLE` (human) | needs nonzero ack evidence hash; not past due; rejected hash stays used |
| Withdraw | `cancelInvoice` | business / operator | only Registered/Verified |
| Offer | `createOffer(id, advance, fundingDeadline)` | invoice business or `OPERATOR_ROLE` | must be Verified; 0<advance<face; deadline in future and ≤ dueDate; discount ≤ cap (exact integer comparison); mints token to contract |
| Fund | `fund(id)` | approved investor (allowlist toggle) | Listed only (⇒ one-time funding), before deadline, not the business; advance goes straight to business; token → investor; balance-delta check |
| Repay | `repay(id)` | anyone (debtor or third party) | Funded/Defaulted only; full face value straight to current token holder; → Settled; early/on-time/late allowed |
| Expire / cancel | `expireOffer` (anyone after deadline), `cancelOffer` (business/operator) | | burn token; unfunded so no money to return |
| Default | `markDefaulted(id)` | `OPERATOR_ROLE` | only after dueDate + grace (default 7d, max 90d); state flag only, moves no funds |

Config (admin): `setInvestorAllowlistEnabled` (default **on**), `setMaxDiscountBps`, `setGracePeriod`, `pause/unpause` (pauser), `setBusinessApproved`/`setInvestorApproved` (verifier).
Events: `InvoiceRegistered, InvoiceVerified, InvoiceRejected, InvoiceCancelled, OfferCreated, OfferFunded, OfferRepaid, OfferSettled, OfferCancelled, OfferExpired, OfferDefaulted, BusinessApprovalUpdated, InvestorApprovalUpdated, InvestorAllowlistToggled, MaxDiscountUpdated, GracePeriodUpdated` (+ ERC-721 `Transfer`).

## 3. Security properties and decisions
- **No custody ⇒ no withdrawal bug class.** Neither contract holds user USDT. `rescueERC20` (admin) can recover other tokens but reverts for the payment token. No admin function can move investor, merchant or debtor funds or bypass obligations.
- Reentrancy: `nonReentrant` on `payInvoice`, `fund`, `repay`; checks-effects-interactions; tested with a re-entering token.
- SafeERC20 everywhere; fee-on-transfer/short-delivery tokens revert (`UnexpectedTransferAmount`).
- Signature safety: EIP-712 domain (chain + contract), expiry, single-use nonce, payer bound to `msg.sender`, tamper tests for amount/merchant/payer.
- Anti-duplication: unique invoice hash (also locked after reject/cancel), one-time funding via status, cumulative payment cap, duplicate-settlement guard.
- Access control: OpenZeppelin `AccessControl`; roles can be separate keys; admin renounce supported by the deploy script.
- Time: `block.timestamp` used at day scale only.
- Known limitations: centralised verifier/operator/signer (hot keys on testnet); pause could delay (not bypass) new activity; `repay` has no partial payments; one investor per invoice; no on-chain legal enforceability; no formal audit; USDT behaviour unverified.
- A financed invoice must not also be payable via `BillFlowPayments`: the **backend must not sign quotes** for invoices with a financing row (off-chain rule; the contracts are independent).

## 4. Example (illustrative, not a guaranteed return)
Face 10,000, advance 9,500, 30 days ⇒ 500 bps (5.00%) discount. Investor pays 9,500 → business; debtor repays 10,000 → investor; investor gross gain 500 if the debtor pays, and bears default risk otherwise. Covered by `test_fullLifecycle_registerVerifyListFundRepaySettle`.
