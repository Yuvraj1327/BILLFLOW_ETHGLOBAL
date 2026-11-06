# ETHGlobal Mumbai × Whitechain submission checklist

Requirements below come from the official prize page (ethglobal.com/events/mumbai/prizes, read 2026-11-05) and event rules. **Re-check the page and the submission deadline yourself** — I could not open the event info page directly and did not find a deadline.

## Rules that apply
* Up to **3 partner prizes** per submission; Whitechain has 4 tracks (Operate $5k, Tokenize $4k, Scale, Continuity). We target **Operate** and **Tokenize** — qualify for each independently.
* Classic "from scratch" track: **all work must start after the hackathon starts** (Nov 5, 2026) or you lose partner-prize/finalist eligibility.
* Public GitHub repo showing **steady progress, not one big upload**.
* Demo video **2–4 min**, showing each party involved; ≥720p; not sped up.
* `WHITECHAIN_FEEDBACK.md` in the repo.
* README explaining setup, architecture, limitations; a line on **why this flow needs onchain stablecoin settlement on Whitechain**.

## Operate qualification
- [ ] Contracts deployed on 1874 **and verified on the Whitechain explorer**
- [ ] ≥1 payment in the **official USDT `0xcedfB56113143d55b2358b8CFbB0dEB5Ad2f55a7`** in the main flow, **explorer link in README** (a self-minted token does not count — the local mock used in tests does not count)
- [ ] Both merchant and paying-customer views in the video
- [ ] README "why onchain" line ✅ (written)

## Tokenize qualification
- [ ] Register → verify → offer → fund (USDT) → repay/settle done live with tx links
- [ ] Contracts verified; all payments in USDT

## Repo / submission hygiene
- [ ] `git log` shows many commits across Nov 5–7 (the repo currently has **no commits**: commit in logical chunks; do not rewrite dates)
- [ ] README "before/during hackathon" section completed with real dates
- [ ] No secrets committed (scan done: none; re-run before pushing); rotate any throw-away keys after the event
- [ ] Screenshots added to README (none exist yet)
- [ ] Flutter compiles (`flutter analyze` clean), APK/web build produced
- [ ] Backend deployed, `/blockchain/health` all ok, indexer worker running
- [ ] Video uploaded; submission form: select Whitechain (and others ≤3 total)

## Step 6 (Operate / Tokenize strengthening)
- [ ] Contracts redeployed from the Step 6 sources (Payments, **Refunds**, Financing) and all three verified on the explorer
- [ ] Migration 0004 applied; `WHITECHAIN_REFUNDS_CONTRACT` set; `/blockchain/health` all ok
- [ ] Demo store (`demo-merchant/`) running against the deployed backend with a real API key + webhook secret
- [ ] Real USDT payment made through `billflow.js` on chain 1874 (explorer link in README)
- [ ] Signed webhook received by the demo store (screenshot of the merchant view)
- [ ] Partial + full refund executed on-chain and verified (explorer links in README)
- [ ] CSV export screenshot
- [ ] Video shows **three parties**: customer (widget), merchant (dashboard/store/refund), investor (financing)
- [ ] 20-line integration snippet visible in README (done) and in the video
- [ ] `WHITECHAIN_FEEDBACK.md` finished (include: USDT permit/3009 support unknown; docs gaps you hit)
