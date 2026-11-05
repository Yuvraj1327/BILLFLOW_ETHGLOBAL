# Whitechain feedback

> **DRAFT — to be completed by the team after the live run.** The prompt asks for honest feedback; I (the AI assistant that built most of the code) have **not** deployed to or
> transacted on Whitechain, so I will not invent a developer experience. What is genuinely known so far:

**Worked / helpful**
* The prize page states the chain ID (1874) and the official test-USDT address, which let us hard-wire a preflight check (`/blockchain/health`) and a deploy script that refuses any other chain.
* OP Stack / plain EVM meant standard Foundry + OpenZeppelin + web3.py tooling compiled and tested with no chain-specific changes (verified only on a local Anvil node using chain id 1874).

**Gaps / questions to resolve live (fill in)**
* Is `evm_version = shanghai` right for the sequencer, or does it support newer opcodes? (We used the conservative setting.)
* Which explorer API/verifier does `forge verify-contract` need (Blockscout/Etherscan-style)? Not confirmed in docs we could read.
* Official USDT `decimals()` — we read it on-chain rather than assume; confirm in docs.
* Faucet limits for WBT and test USDT; RPC rate limits for an indexer polling `eth_getLogs` (the prize page mentions a free Ankr RPC).
* The sandbox we built in could not reach `rpc.testnet.whitechain.io` (HTTP 403 from our own egress proxy — not a Whitechain issue).

**TODO before submitting:** replace this draft with what actually worked and where you got stuck during deployment, verification and the USDT payment.
