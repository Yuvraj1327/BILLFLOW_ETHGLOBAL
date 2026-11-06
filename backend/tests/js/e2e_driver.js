'use strict';
// LOCAL-CHAIN TEST DRIVER (not shipped to users): runs the real billflow.js pay() flow with a wallet shim that forwards to a local
// Anvil node. Anvil's dev accounts are unlocked, so eth_sendTransaction needs no signing here. After each tx the shim mines extra
// blocks so the backend's confirmation requirement is met.  env: CHECKOUT_URL, ANVIL_RPC, PAYER
const path = require('node:path');
const BillFlow = require(path.join(__dirname, '../../app/static/billflow.js'));
const { CHECKOUT_URL, ANVIL_RPC, PAYER } = process.env;

async function rpc(method, params) {
  const r = await fetch(ANVIL_RPC, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; throw e; }
  return j.result;
}
const provider = {
  request: async ({ method, params }) => {
    if (method === 'eth_requestAccounts') return [PAYER];
    if (method === 'wallet_switchEthereumChain') return null;
    const out = await rpc(method, params);
    if (method === 'eth_sendTransaction') await rpc('anvil_mine', ['0x4']);
    return out;
  },
};
const steps = [];
BillFlow.pay({ url: CHECKOUT_URL, provider, pollMs: 100, onStatus: (s) => steps.push(s) })
  .then((receipt) => { console.log(JSON.stringify({ ok: true, receipt, steps })); })
  .catch((e) => { console.log(JSON.stringify({ ok: false, code: e.code, message: e.message, txHash: e.txHash, steps })); process.exitCode = 1; });
