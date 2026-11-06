# Bean Counter — independent demo merchant for BillFlow Checkout

A tiny store (single Node file, **zero npm dependencies**, Node ≥ 18) that shares no code or database with BillFlow. It uses only:
the public **Checkout API** (server side, API key), the **`billflow.js` widget** (browser) and **signed webhooks**.

```bash
# 1) In BillFlow (merchant account): create an API key and a webhook endpoint pointing at THIS app's /webhooks/billflow
#    POST /api/v1/merchant/api-keys   POST /api/v1/merchant/webhooks   (see docs/CHECKOUT_INTEGRATION.md)
# 2) Run the store
BILLFLOW_URL=https://your-billflow-host BILLFLOW_API_KEY=bf_test_... BILLFLOW_WEBHOOK_SECRET=whsec_... node server.js
# customer view  : http://localhost:4000/         ("Pay with BillFlow" -> wallet -> USDT on Whitechain Sepolia)
# merchant view  : http://localhost:4000/orders   (status changes ONLY when a correctly signed webhook arrives)
```
For local development against a local backend: `APP_ENV=development WEBHOOK_ALLOW_INSECURE_URLS=true` on the backend (the webhook URL
`http://localhost:4000/...` is otherwise refused). The API key never leaves `server.js`; the browser only receives the `checkout_url`.

`npm test` runs the SDK/webhook tests. The real end-to-end run (this store ↔ BillFlow ↔ local Anvil chain) is
`backend/tests/test_step6_local_chain.py`. Testnet only.
