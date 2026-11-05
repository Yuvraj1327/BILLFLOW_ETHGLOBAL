# BillFlow Flutter app — Step 4 notes

## Principles enforced in code
* **The backend decides.** Payment/financing success is shown only when `/public/invoices/{token}/status`, `/payments/verify` or
  `/financing/verify-transaction` reports it. A wallet returning a tx hash only moves the UI to "pending".
* **Roles come from `GET /users/me`** (database). Router guards (`computeRedirect`) are UX only; every admin/merchant/investor call is authorised by the backend.
* **No keys in the app.** Transactions are built as calldata (hand-written ABI encoder) and signed by the user's wallet (EIP-1193). Wallet linking uses EIP-191 `personal_sign`.
* **No invented endpoints**; see gaps below.
* **Duplicate-payment protection:** in-flight guard, a re-check of `/status` just before paying, and the submitted tx hash persisted per link (`PendingTx`) so a refresh resumes tracking instead of paying again.
* **Fresh quote:** the signed payment-intent is requested *after* the allowance step, and the response is checked against the invoice payload (chain, contract, USDT) before sending.

## Route map
`/splash /welcome /login /register /forgot /setup-error` · public: `/pay/:token`, `/receipt/:token/:tx` · `/onboarding/business`
Merchant: `/merchant` (+`invoices`, `invoices/new`, `invoices/:id`, `invoices/:id/edit`, `customers`, `customers/:id`, `financing`, `financing/new`, `financing/:id`, `business`)
Investor: `/investor` (+`offers/:id`, `portfolio`) · Customer: `/customer` · Admin: `/admin` (+`users`, `businesses`, `financing`, `financing/:id`, `monitoring`)
Shared: `/transactions /notifications /profile /settings`

## Backend gaps / blockers (not mocked)
1. No dashboard aggregate endpoint → merchant stats are computed client-side from up to 500 invoices (BigInt-exact; flagged when truncated).
2. Business has no logo/address/contact fields; invoices have no line-item/tax/discount fields → line items are composed into `amount` + `description`; the invoice PDF is generated client-side.
3. No public "verify this tx hash" endpoint → anonymous checkout depends on the **indexer** to flip status. Signed-in payers also call `/payments/verify`.
4. `/blockchain/config` requires auth → checkout uses chain/contract values embedded in the public invoice payload.
5. No admin invoice-list endpoint → admin reviews invoices via the financing queue (`/admin/invoices/{id}/documents`, `/review` are wired).
6. No separate AI "categorize" endpoint → category comes from the summary response.
7. Financing on-chain steps (`registerInvoice` / `verifyInvoice` / `createOffer`) need wallets holding ISSUER / VERIFIER / OPERATOR roles; the admin screen sends them from the connected wallet.
8. Debtor `repay` and the investor "claim" paths are not exposed in the UI (settlement is driven by verified chain events).
9. Mobile WalletConnect not implemented (web wallet only).
10. No contracts are deployed in this environment → **no live on-chain test has been done**.

## Testing status
| Area | Status |
|---|---|
| `flutter analyze` | **NOT RUN** (no SDK) |
| `flutter test` (5 files, ~30 cases) | **Written, NOT RUN** |
| ABI encoder | Selectors and the `payInvoice` vector were computed independently in Python from docs/abi; the Dart test asserts them but has not run |
| Backend integration | Backend is covered by its own 119 tests (Step 3, mocked chain); the Flutter app has **never** talked to it |
| Live Whitechain | **NOT TESTED** (no deployment, no wallet) |
