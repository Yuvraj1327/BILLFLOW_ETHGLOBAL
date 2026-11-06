# BillFlow Checkout — merchant integration guide (testnet)

BillFlow Checkout lets any website or server accept **USDT on Whitechain Sepolia** with a hosted page or an embeddable widget,
signed webhooks, refunds and accountant exports. Funds go **directly from the customer wallet to the merchant payout wallet**
(`BillFlowPayments`); BillFlow never custodies money.

## The ~20-line integration

**Server (Node, using `sdk/billflow-node`)**
```js
const bf = require('@billflow/node').create({ baseUrl: process.env.BILLFLOW_URL, apiKey: process.env.BILLFLOW_API_KEY });

app.post('/api/checkout', async (req, res) => {
  const session = await bf.checkout.createSession(
    { amount: '25.00', reference: order.id, success_url: `${SITE}/thanks`, cancel_url: SITE },
    { idempotencyKey: `${order.id}-session` });
  res.json({ checkout_url: session.checkout_url });
});

app.post('/webhooks/billflow', express.raw({ type: '*/*' }), (req, res) => {
  const event = bf.webhooks.constructEvent(req.body.toString(), req.headers['billflow-signature'], WEBHOOK_SECRET); // throws if forged
  if (event.type === 'invoice.paid') markOrderPaid(event.data.reference, event.data.tx_hash);   // dedupe on event.id
  res.sendStatus(200);
});
```
**Browser**
```html
<script src="https://YOUR-BILLFLOW-HOST/billflow.js"></script>
<script>
  async function pay() {
    const { checkout_url } = await (await fetch('/api/checkout', { method: 'POST' })).json();
    BillFlow.checkout({ url: checkout_url, onSuccess: (receipt) => location.href = '/thanks?tx=' + receipt.tx_hash,
                        onError: (e) => console.warn(e.code, e.message) });
  }
</script>
```
Or skip the widget: redirect the customer to `checkout_url` (the **hosted page** `/pay/<token>`); BillFlow sends them to your
`success_url` with `?billflow_status=paid&billflow_tx=…` after verification.

A complete, independent example is in `demo-merchant/` (zero npm dependencies).

## What `onSuccess` means
The widget calls `onSuccess(receipt)` **only after the BillFlow backend has verified the transaction on-chain**: receipt status,
required confirmations, canonical block, event from the configured `BillFlowPayments`, a matching transfer from the configured USDT,
and that it paid *this* invoice. A wallet saying "success" is never trusted. Treat the **webhook** (or `GET /checkout/sessions/{id}`)
as the source of truth for fulfilling orders — the browser can be closed mid-payment.

`receipt = { payment_id, tx_hash, explorer_url, amount, currency, payer_wallet, merchant_name, invoice_number, confirmed_at, chain_id }`

Widget errors have a stable `code`: `no_wallet`, `user_rejected`, `wrong_network`, `not_payable`, `link_expired`, `contract_mismatch`,
`quote_mismatch`, `tx_reverted`, `tx_timeout`, `verification_failed`, `verify_timeout`. After `verify_timeout` the payment may still
confirm — wait for the webhook.

## API (server-to-server, `Authorization: Bearer bf_test_…`)
| Call | Purpose |
|---|---|
| `POST /api/v1/checkout/sessions` | Create invoice + payment link. Body: `amount` (USDT decimal string), `description`, `reference`, `customer{name,email}`, `metadata` (≤20 keys/4 KB), `success_url`, `cancel_url`, `due_in_days`. Header `Idempotency-Key` makes retries safe. |
| `GET /api/v1/checkout/sessions/{id}` | Status (`open`/`partially_paid`/`paid`/`refunded`/`cancelled`) + **receipts** (tx hash, explorer link, refunds). |
| `GET /api/v1/checkout/sessions?reference=` | Look up by your order id. |
| `POST /api/v1/checkout/sessions/{id}/expire` | Cancel an unpaid session. |

API keys are created in the merchant dashboard API (`POST /api/v1/merchant/api-keys`), shown **once**, stored only as a SHA-256 hash,
revocable. Keep them on your server — never in a browser or mobile app. They are testnet-only (`bf_test_` prefix).

## Webhooks
Register: `POST /api/v1/merchant/webhooks {url, events}`; the signing secret (`whsec_…`) is returned once.
Events: `payment.confirmed`, `invoice.paid`, `refund.confirmed` (or `*`). Delivered **at least once**, retried with backoff
(30 s, 2 min, 10 min, 1 h, 6 h; then `FAILED`, re-queue with `POST /merchant/webhook-deliveries/{id}/retry`).
Events are created only from chain events the backend verified, in the same transaction, and are unique per endpoint.

Header: `BillFlow-Signature: t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>` and `BillFlow-Event-Id`.
Verify against the **raw** body, constant-time, reject timestamps older than 5 minutes, and dedupe on `event.id`.
Out-of-order delivery is possible — `refund.confirmed` carries the cumulative `total_refunded_base`; use that, don't add up deliveries.
Webhook URLs must be `https` and must not resolve to private/loopback/link-local addresses (SSRF guard, re-checked at send time,
redirects not followed). `WEBHOOK_ALLOW_INSECURE_URLS=true` relaxes this for local development only.

## Refunds (full or partial)
`BillFlowPayments` forwards funds straight to the merchant, so a refund is a transaction **the merchant signs**, paid from the
merchant wallet to the **original payer recorded on-chain**, through the separate `BillFlowRefunds` contract:

1. `POST /api/v1/merchant/payments/{payment_id}/refunds {amount | amount_base, reason}` → a `PENDING` request and the exact two
   transactions to sign from the payout wallet: `USDT.approve(BillFlowRefunds, amount)` then `BillFlowRefunds.refund(paymentId, amount, refundRef, reasonHash)`.
2. Merchant wallet sends them. (BillFlow never holds merchant keys.)
3. `POST /api/v1/merchant/refunds/verify {tx_hash}` (or the indexer) → the refund becomes `CONFIRMED` **only after** the
   `PaymentRefunded` event is verified (receipt, confirmations, matching merchant→payer USDT transfer, payment/merchant/payer/amount checks).
4. `GET /api/v1/merchant/refunds/{id}/chain-check` re-reads the refund from the contract and compares it to our record.

Contract guarantees: only the payment's merchant can refund it; the recipient is always the recorded payer; the sum of refunds can
never exceed the amount paid; `refundRef` is single-use (a retried transaction cannot double refund); pausable; no funds held.
Payments made before refund support (no on-chain payment id recorded) are not refundable through this path.

## Accountant export
`GET /api/v1/merchant/exports/payments.csv?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD` — one row per confirmed payment and per
confirmed refund (refunds negative), with tx hash, explorer link, on-chain ids, your `reference`. Text cells are guarded against
spreadsheet formula injection (`=`, `+`, `-`, `@` prefixes are quoted; plain numbers are untouched).

## Notes and limits (honest)
* Testnet only: Whitechain Sepolia (chain 1874) and the official testnet USDT. No mainnet support.
* The widget needs a browser EIP-1193 wallet (`window.ethereum`) — no WalletConnect/mobile deep-link yet.
* The widget UI was exercised with a DOM stub and the payment core with a real local chain, **not yet in a real browser with a real wallet**.
* The public checkout endpoints allow any origin (CORS `*`, no credentials) so the widget works on any site; they are token-scoped and rate limited.
