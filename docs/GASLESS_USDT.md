# Priority 7 — gasless USDT checkout (Whitechain Scale): investigation, NOT implemented

**Decision: not implemented.** The instruction was to implement only if the official USDT supports the needed signature mechanism
and implementation is straightforward. That could not be established:

* The sandbox cannot reach the Whitechain RPC (HTTP 403 from the egress proxy), so the token's bytecode/ABI could not be read.
* The ETHGlobal prize page names the token address but does not document `permit` (EIP-2612) or `transferWithAuthorization` (EIP-3009).
* A guess is not acceptable here: a relayer built on an unsupported mechanism would simply not work, and a relayer that moves user
  funds needs spending limits, nonces and abuse controls that must be tested against the real token's domain separator.

**How to settle it in two minutes (you run it — read-only, no transaction):**
```bash
cd contracts
export USDT_ADDRESS=0xcedfB56113143d55b2358b8CFbB0dEB5Ad2f55a7 WHITECHAIN_SEPOLIA_RPC_URL=<rpc>
forge script script/ProbeUsdtSignatures.s.sol --rpc-url $WHITECHAIN_SEPOLIA_RPC_URL
```
It prints whether `DOMAIN_SEPARATOR()`, `nonces(address)`, `authorizationState(address,bytes32)`, `eip712Domain()` exist. A getter is a
hint, not proof — confirm with the verified token source on the explorer.

**If `permit` exists**, the straightforward design is: payer signs `Permit(owner, spender=BillFlowPayments, value, nonce, deadline)`;
a merchant-sponsored relayer submits `permit` + `payInvoice` (needs a small `payInvoiceWithPermit` wrapper contract — `payInvoice`
requires `msg.sender == payer`, so the existing contract would stay untouched). Required controls: per-merchant daily gas budget,
per-tx value cap, deadline ≤ 15 min, relayer only calls the allow-listed contract, nonce from the token (replay-safe),
rate limiting, and a kill switch. **If only EIP-3009 exists**, `transferWithAuthorization` pays the merchant directly but bypasses the
BillFlow quote/invoice binding, so it would need a wrapper that consumes the authorization and emits the invoice event — more work;
not recommended inside this hackathon window.

Mention in `WHITECHAIN_FEEDBACK.md` (if you run the probe): whether the testnet USDT exposes permit/3009 and that it was unclear from the docs.
