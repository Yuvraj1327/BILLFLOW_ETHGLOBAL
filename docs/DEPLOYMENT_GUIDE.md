# Deployment guide and live-testing runbook

Nothing here has been executed against Whitechain. **Never use mainnet.** Never commit keys. Prefer a Foundry keystore (`cast wallet import`).

## 0. Wallets (manual)
Create/fund: **deployer/admin**, **quote signer** (throw-away; backend env only), **merchant payout wallet**, **customer/payer**, **investor**, optionally separate issuer/verifier/operator (deploy script can use one). Get WBT (gas) and test USDT from the Whitechain faucet/ETHGlobal instructions. The payer needs ≥1,000 USDT for the demo, the investor ≥ the advance.

## 1. Contracts (Whitechain Sepolia, chain 1874)
```bash
cd contracts && ./install-deps.sh && export FOUNDRY_SOLC=$(which solc)   # 0.8.28
export WHITECHAIN_SEPOLIA_RPC_URL=https://rpc.testnet.whitechain.io       # or your Ankr URL
forge script script/CheckUsdt.s.sol --rpc-url $WHITECHAIN_SEPOLIA_RPC_URL           # confirm code + decimals of 0xcedf…55a7
export USDT_ADDRESS=0xcedfB56113143d55b2358b8CFbB0dEB5Ad2f55a7 ADMIN_ADDRESS=… QUOTE_SIGNER_ADDRESS=… PAUSER_ADDRESS=… ISSUER_ADDRESS=… VERIFIER_ADDRESS=… OPERATOR_ADDRESS=…
forge script script/Deploy.s.sol --rpc-url $WHITECHAIN_SEPOLIA_RPC_URL --account <keystore> --broadcast
```
The script refuses any chain other than 1874. Record addresses and tx hashes in `docs/deployments.md`. `evm_version = shanghai` is a conservative guess for an OP Stack L2: if the deploy fails, report it.
**Verify on the Whitechain explorer** (`forge verify-contract … --verifier blockscout --verifier-url <explorer>/api/` if it is Blockscout — unconfirmed; otherwise use the explorer's UI with the flattened source). Verified contracts are a prize requirement.
After deploy: grant `setBusinessApproved(merchantPayout)` and `setInvestorApproved(investor)` (VERIFIER role) before financing.

## 2. Supabase (manual)
Create a project; run `supabase/migrations/0001…0003` in order; Auth → email+password, set Site URL/redirects to your web origin; copy URL, anon key, service-role key, JWT secret, pooled Postgres URL. Bucket `invoice-documents` is private (created by migration 0002).

## 3. Backend (Render shown; Railway similar)
`backend/Dockerfile` + `render.yaml` (repo root) (blueprint). Secrets are `sync:false`: enter in the dashboard: `SUPABASE_*`, `DATABASE_URL`, `ANTHROPIC_API_KEY`, `QUOTE_SIGNER_PRIVATE_KEY`, `WHITECHAIN_*_ADDRESS`, `CORS_ORIGINS` (your web origin), `PUBLIC_CHECKOUT_BASE_URL`. Run **two** services: the web API and the always-on **indexer worker** (`python -m app.workers.blockchain_indexer`); without it anonymous checkout will not flip to confirmed. Health check: `GET /health`. Then, as admin: `GET /api/v1/blockchain/health` must show every check `ok` (chain id, contract code, USDT decimals, quote-signer match). Set `FORWARDED_ALLOW_IPS` to the platform proxy range. **Not tested:** the Docker image has never been built.

## 4. Flutter (manual)
```bash
cd app && flutter create . --platforms=web,android,ios && flutter pub get && flutter analyze && flutter test
cp env.example.json env.json   # API_BASE_URL, SUPABASE_URL, SUPABASE_ANON_KEY (public values only)
flutter build web --dart-define-from-file=env.json          # host with SPA rewrite so /pay/:token works
flutter build apk --release --dart-define-from-file=env.json  # Android: wallet connect is NOT available on mobile yet
```
Fix compile errors first: the code has never been compiled. For the Android release set app name/icon/signing config yourself.

## 5. Live evidence run (for the submission)
1. Merchant signs up, creates business (payout wallet = merchant wallet), an admin verifies it.
2. Invoice **1,000 USDT** → upload PDF → payment link.
3. Customer opens link in a desktop browser with a wallet → connect → switch to 1874 → approve → pay. Copy the tx hash; confirm backend shows `Verified` and the invoice `PAID`. **Paste the explorer link in README/deployments.md.**
4. Second invoice → financing request → admin approves with evidence → admin wallet (roles) sends register/verify/createOffer from the admin screen → investor links wallet (Profile), funds → advance reaches merchant → debtor/test wallet repays → status `SETTLED`. Record each tx hash.
5. Run `GET /blockchain/health`; keep screenshots.

## 6. Step 6 additions (BillFlowRefunds, limits, checkout API) — manual steps
1. **Redeploy** with the updated `Deploy.s.sol` (it now also deploys `BillFlowRefunds` and applies optional limits). `InvoiceFinancing`
   changed (exposure cap, max advance, permissionless `markDefaulted`), so the financing contract must be redeployed too — do NOT reuse an
   address from before Step 6. Optional env: `MAX_ADVANCE_PER_INVOICE`, `DEFAULT_BUSINESS_EXPOSURE_CAP` (token base units; 0/unset = unlimited).
2. Verify **all three** contracts on the explorer. Record addresses in `docs/deployments.md`.
3. Backend env: add `WHITECHAIN_REFUNDS_CONTRACT=<BillFlowRefunds>`; run migration `supabase/migrations/0004_checkout_refunds_webhooks.sql`
   in the Supabase SQL editor (additive). Set `INDEXER_START_BLOCK` to the new deployment block. Redeploy backend + indexer
   (the indexer worker also delivers webhooks and sends due-date notifications).
4. `GET /api/v1/blockchain/health` must show `refunds_has_code`, `refunds_token_matches`, `refunds_points_at_payments` all `ok`.
5. Merchant: create an API key and a webhook endpoint (`docs/CHECKOUT_INTEGRATION.md`); run `demo-merchant/` with
   `BILLFLOW_URL`, `BILLFLOW_API_KEY`, `BILLFLOW_WEBHOOK_SECRET`. For a webhook receiver on localhost during the demo use a public
   HTTPS tunnel (webhook URLs must be https and non-private in production), or run the backend with `APP_ENV=development WEBHOOK_ALLOW_INSECURE_URLS=true`.
6. Live evidence for Operate: pay the demo store's checkout with the widget (real USDT tx link) → webhook arrives → refund part of it
   (merchant wallet `approve` + `refund`) → `/merchant/refunds/verify` → CSV export. Paste the tx links into README/deployments.md.
7. Optional (Priority 7): run `forge script script/ProbeUsdtSignatures.s.sol` and read `docs/GASLESS_USDT.md`.
