'use strict';
// Unit tests for billflow.js (DOM-free core). Run: node --test tests/js
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const BillFlow = require(path.join(__dirname, '../../app/static/billflow.js'));
const { encodePayInvoice, encodeApprove, encodeAllowance, parseCheckoutUrl } = BillFlow._internals;

const TOKEN = 'T'.repeat(40);
const USDT = '0x' + '11'.repeat(20), PAYMENTS = '0x' + '22'.repeat(20), PAYER = '0x' + 'bb'.repeat(20), MERCHANT = '0x' + 'aa'.repeat(20);
const TX_APPROVE = '0x' + 'a1'.repeat(32), TX_PAY = '0x' + 'a2'.repeat(32);

test('payInvoice calldata equals the independently computed ABI vector (same vector the Flutter test uses)', () => {
  const q = { invoiceId: '0x' + '01'.repeat(32), invoiceHash: '0x' + '02'.repeat(32), merchant: '0x' + 'aa'.repeat(20), payer: '0x' + 'bb'.repeat(20),
    amount: '100000000', invoiceTotal: '100000000', nonce: '12345', expiry: '1893456000' };
  const sig = '0x' + Array.from({ length: 65 }, (_, i) => i.toString(16).padStart(2, '0')).join('');
  const hex = (n) => BigInt(n).toString(16).padStart(64, '0');
  const expected = '0xa87ce778' + '01'.repeat(32) + '02'.repeat(32) + '00'.repeat(12) + 'aa'.repeat(20) + '00'.repeat(12) + 'bb'.repeat(20) +
    hex(100000000) + hex(100000000) + hex(12345) + hex(1893456000) + hex(0x120) + hex(65) + sig.slice(2).padEnd(192, '0');
  assert.equal(encodePayInvoice(q, sig), expected);
});

test('approve / allowance calldata', () => {
  assert.equal(encodeApprove(PAYMENTS, 5), '0x095ea7b3' + '00'.repeat(12) + '22'.repeat(20) + (5).toString(16).padStart(64, '0'));
  assert.equal(encodeAllowance(PAYER, PAYMENTS), '0xdd62ed3e' + '00'.repeat(12) + 'bb'.repeat(20) + '00'.repeat(12) + '22'.repeat(20));
});

test('encoders reject malformed input instead of producing bad calldata', () => {
  assert.throws(() => encodeApprove('0x12', 1));
  assert.throws(() => encodeApprove(PAYMENTS, -1));
  assert.throws(() => encodeApprove(PAYMENTS, 2n ** 256n));
  assert.throws(() => encodePayInvoice({ invoiceId: '0x1' }, '0x00'));
  assert.throws(() => encodePayInvoice({ invoiceId: '0x' + '01'.repeat(32) }, 'nothex'));
});

test('parseCheckoutUrl', () => {
  const p = parseCheckoutUrl(`https://pay.example/pay/${TOKEN}`);
  assert.deepEqual(p, { token: TOKEN, apiBase: 'https://pay.example/api/v1' });
  assert.equal(parseCheckoutUrl(`https://pay.example/pay/${TOKEN}/`, 'https://api.example/api/v1/').apiBase, 'https://api.example/api/v1');
  assert.throws(() => parseCheckoutUrl('https://pay.example/other'), { code: 'bad_checkout_url' });
  assert.throws(() => parseCheckoutUrl('https://pay.example/pay/short'), { code: 'bad_checkout_url' });
});

// ───────────── pay() with a mocked backend + mocked wallet ─────────────
function view(over = {}) {
  return { merchant_name: 'Acme', invoice_number: 'I-1', payable: true, chain_id: 1874, usdt_address: USDT, payments_contract: PAYMENTS, ...over };
}
function intent(over = {}) {
  return { chain_id: 1874, usdt_address: USDT, payments_contract: PAYMENTS, approve_amount_base: '1000000', signature: '0x' + '07'.repeat(65),
    quote: { invoiceId: '0x' + '01'.repeat(32), invoiceHash: '0x' + '02'.repeat(32), merchant: MERCHANT, payer: PAYER, amount: '1000000',
      invoiceTotal: '1000000', nonce: '9', expiry: '1893456000' }, ...over };
}
function backend({ v = view(), i = intent(), verify = [{ stage: 'verified', paid_for_this_invoice: true, receipt: { tx_hash: TX_PAY, explorer_url: 'https://x/tx/1' } }] } = {}) {
  const calls = [];
  let n = 0;
  const fetch = async (url, init) => {
    calls.push({ url, method: init.method, body: init.body ? JSON.parse(init.body) : null });
    const respond = (b, status = 200) => ({ ok: status < 400, status, json: async () => b });
    if (url.endsWith('/verify-tx')) return respond(verify[Math.min(n++, verify.length - 1)]);
    if (url.endsWith('/payment-intent')) return respond(i);
    return respond(v);
  };
  return { fetch, calls };
}
function wallet({ chain = '0x752', allowance = 0n, rejectOn = null, revertPay = false, accounts = [PAYER] } = {}) {
  const sent = [];
  const w = {
    sent, chain,
    request: async ({ method, params }) => {
      if (rejectOn === method) { const e = new Error('nope'); e.code = 4001; throw e; }
      switch (method) {
        case 'eth_requestAccounts': return accounts;
        case 'eth_chainId': return w.chain;
        case 'wallet_switchEthereumChain': w.chain = params[0].chainId; return null;
        case 'eth_call': return '0x' + allowance.toString(16).padStart(64, '0');
        case 'eth_sendTransaction': sent.push(params[0]); return sent.length === 1 && params[0].data.startsWith('0x095ea7b3') ? TX_APPROVE : TX_PAY;
        case 'eth_getTransactionReceipt': return { status: (revertPay && params[0] === TX_PAY) ? '0x0' : '0x1' };
        default: throw new Error('unexpected ' + method);
      }
    },
  };
  return w;
}
const opts = (b, w, extra = {}) => ({ url: `https://pay.example/pay/${TOKEN}`, fetch: b.fetch, provider: w, pollMs: 1, ...extra });

test('happy path: approve then pay, success only after backend verification', async () => {
  const b = backend({ verify: [{ stage: 'submitted', confirmations: 1, required_confirmations: 3 }, { stage: 'verified', paid_for_this_invoice: true, receipt: { tx_hash: TX_PAY } }] });
  const w = wallet(); const steps = [];
  const receipt = await BillFlow.pay(opts(b, w, { onStatus: (s) => steps.push(s) }));
  assert.equal(receipt.tx_hash, TX_PAY);
  assert.equal(w.sent.length, 2);
  assert.equal(w.sent[0].to, USDT); assert.ok(w.sent[0].data.startsWith('0x095ea7b3'));
  assert.equal(w.sent[1].to, PAYMENTS); assert.ok(w.sent[1].data.startsWith('0xa87ce778'));
  assert.equal(w.sent[1].from, PAYER);
  assert.deepEqual(steps.filter((s, i) => steps.indexOf(s) === i), ['loading', 'connect', 'quote', 'approve', 'pay', 'mining', 'verifying', 'done']);
  assert.equal(b.calls.filter((c) => c.url.endsWith('/verify-tx')).length, 2);
  assert.deepEqual(b.calls.find((c) => c.url.endsWith('/payment-intent')).body, { payer_wallet: PAYER, amount: null });
});

test('sufficient allowance skips the approve transaction', async () => {
  const w = wallet({ allowance: 10n ** 12n });
  await BillFlow.pay(opts(backend(), w));
  assert.equal(w.sent.length, 1); assert.ok(w.sent[0].data.startsWith('0xa87ce778'));
});

test('switches the wallet to the right chain', async () => {
  const w = wallet({ chain: '0x1' });
  await BillFlow.pay(opts(backend(), w));
  assert.equal(w.chain, '0x752');
});

test('user rejection -> user_rejected, nothing further is sent', async () => {
  const w = wallet({ rejectOn: 'eth_sendTransaction' });
  await assert.rejects(BillFlow.pay(opts(backend(), w)), { code: 'user_rejected' });
  assert.equal(w.sent.length, 0);
});

test('no wallet', async () => {
  await assert.rejects(BillFlow.pay({ url: `https://pay.example/pay/${TOKEN}`, fetch: backend().fetch, provider: null }), { code: 'no_wallet' });
});

test('not payable invoice never reaches the wallet', async () => {
  const w = wallet();
  await assert.rejects(BillFlow.pay(opts(backend({ v: view({ payable: false, payable_reason: 'Invoice is PAID' }) }), w)), { code: 'not_payable', message: 'Invoice is PAID' });
  assert.equal(w.sent.length, 0);
});

test('a quote for a different contract / token / wallet is refused before signing', async () => {
  for (const bad of [intent({ payments_contract: '0x' + '99'.repeat(20) }), intent({ usdt_address: '0x' + '98'.repeat(20) }),
                      intent({ chain_id: 1 }), intent({ quote: { ...intent().quote, payer: '0x' + 'cc'.repeat(20) } })]) {
    const w = wallet();
    await assert.rejects(BillFlow.pay(opts(backend({ i: bad }), w)));
    assert.equal(w.sent.length, 0, 'wallet must not be asked to sign a mismatching quote');
  }
});

test('a wallet-side success is NOT success: rejected verification => error, never a receipt', async () => {
  const w = wallet({ allowance: 10n ** 12n });
  await assert.rejects(BillFlow.pay(opts(backend({ verify: [{ stage: 'rejected', detail: 'No matching transfer' }] }), w)), { code: 'verification_failed', txHash: TX_PAY });
});

test('verified tx that paid a DIFFERENT invoice is not accepted', async () => {
  const w = wallet({ allowance: 10n ** 12n });
  await assert.rejects(BillFlow.pay(opts(backend({ verify: [{ stage: 'verified', paid_for_this_invoice: false, detail: 'did not pay this invoice' }] }), w)), { code: 'verification_failed' });
});

test('reverted payment transaction', async () => {
  const w = wallet({ allowance: 10n ** 12n, revertPay: true });
  await assert.rejects(BillFlow.pay(opts(backend(), w)), { code: 'tx_reverted' });
});

test('verification never completing -> verify_timeout (not success)', async () => {
  const w = wallet({ allowance: 10n ** 12n });
  await assert.rejects(BillFlow.pay(opts(backend({ verify: [{ stage: 'submitted', confirmations: 0, required_confirmations: 3 }] }), w, { verifyTimeoutMs: 30 })), { code: 'verify_timeout', txHash: TX_PAY });
});

test('backend errors surface their code/message', async () => {
  const fetch = async () => ({ ok: false, status: 410, json: async () => ({ error: { code: 'link_expired', message: 'This payment link is no longer active' } }) });
  await assert.rejects(BillFlow.pay({ url: `https://pay.example/pay/${TOKEN}`, fetch, provider: wallet() }), { code: 'link_expired' });
});

test('partial amount is forwarded to the quote request', async () => {
  const b = backend(); const w = wallet({ allowance: 10n ** 12n });
  await BillFlow.pay(opts(b, w, { amount: '2.50' }));
  assert.equal(b.calls.find((c) => c.url.endsWith('/payment-intent')).body.amount, '2.50');
});

test('script contains no secret-bearing patterns', () => {
  const src = require('node:fs').readFileSync(path.join(__dirname, '../../app/static/billflow.js'), 'utf8');
  assert.ok(!/bf_test_|whsec_|\.innerHTML\s*=|\beval\(|document\.write\(|localStorage|sessionStorage/.test(src));
});
