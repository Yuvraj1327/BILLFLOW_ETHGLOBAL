'use strict';
// Exercises checkout() UI code paths with a minimal DOM stub (no jsdom dependency). NOT a substitute for a real-browser check.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

class Node_ {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.listeners = {}; this._text = ''; this.className = ''; this.parentNode = null; this.disabled = false; }
  setAttribute(k, v) { this.attrs[k] = v; if (k === 'class') this.className = v; }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); c.parentNode = null; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  attachShadow() { this.shadow = new Node_('#shadow'); return this.shadow; }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  get lastChild() { return this.children[this.children.length - 1]; }
  click() { (this.listeners.click || []).forEach((f) => f({ target: this })); }
  find(pred) { if (pred(this)) return this; for (const c of this.children) { const r = c.find(pred); if (r) return r; } for (const r of this.shadow ? [this.shadow.find(pred)] : []) if (r) return r; return null; }
}
global.document = { createElement: (t) => new Node_(t), body: new Node_('body'), readyState: 'complete', getElementById: () => null };
global.location = { href: 'https://shop.example/', origin: 'https://shop.example' };
const BillFlow = require(path.join(__dirname, '../../app/static/billflow.js'));

const TOKEN = 'T'.repeat(40);
const USDT = '0x' + '11'.repeat(20), PAYMENTS = '0x' + '22'.repeat(20), PAYER = '0x' + 'bb'.repeat(20);
const tick = () => new Promise((r) => setTimeout(r, 5));

function mocks(viewOver = {}) {
  const view = { merchant_name: 'Acme <b>Ltd</b>', invoice_number: 'I-1', description: 'Beans', remaining_amount: '1.00', currency: 'USDT', status: 'PENDING', payable: true,
    chain_id: 1874, usdt_address: USDT, payments_contract: PAYMENTS, ...viewOver };
  const intent = { chain_id: 1874, usdt_address: USDT, payments_contract: PAYMENTS, approve_amount_base: '1', signature: '0x' + '07'.repeat(65),
    quote: { invoiceId: '0x' + '01'.repeat(32), invoiceHash: '0x' + '02'.repeat(32), merchant: '0x' + 'aa'.repeat(20), payer: PAYER, amount: '1', invoiceTotal: '1', nonce: '1', expiry: '9' } };
  const fetch = async (url) => ({ ok: true, status: 200, json: async () => url.endsWith('/verify-tx') ? { stage: 'verified', paid_for_this_invoice: true, receipt: { tx_hash: '0x' + 'a2'.repeat(32), explorer_url: 'https://explorer.test/tx/1' } } : url.endsWith('/payment-intent') ? intent : view });
  const provider = { request: async ({ method }) => ({ eth_requestAccounts: [PAYER], eth_chainId: '0x752', eth_call: '0x' + 'f'.repeat(64), eth_sendTransaction: '0x' + 'a2'.repeat(32), eth_getTransactionReceipt: { status: '0x1' } })[method] };
  return { fetch, provider };
}

test('modal renders merchant data as TEXT (no HTML injection), pays, and calls onSuccess once', async () => {
  document.body.children = [];
  const m = mocks(); let got = null, count = 0;
  const h = BillFlow.checkout({ url: `https://pay.example/pay/${TOKEN}`, fetch: m.fetch, provider: m.provider, pollMs: 1, onSuccess: (r) => { got = r; count++; } });
  await tick();
  const root = document.body.children[0].shadow;
  const title = root.find((n) => n.tag === 'h2');
  assert.equal(title.textContent, 'Pay Acme <b>Ltd</b>', 'merchant name must be inserted as text, tags stay literal');
  assert.equal(root.find((n) => n.className === 'amt').textContent, '1.00 USDT');
  const btn = root.find((n) => n.tag === 'button' && !n.className);
  btn.click(); await tick(); await tick(); await tick();
  assert.equal(count, 1); assert.equal(got.tx_hash, '0x' + 'a2'.repeat(32));
  assert.match(root.find((n) => n.className.startsWith('msg')).textContent, /Payment verified on-chain/);
  const link = root.find((n) => n.tag === 'a');
  assert.equal(link.attrs.href, 'https://explorer.test/tx/1'); assert.equal(link.attrs.rel, 'noopener noreferrer');
  h.close(); assert.equal(document.body.children.length, 0);
});

test('non-payable invoice disables the pay button and shows why', async () => {
  document.body.children = [];
  const m = mocks({ payable: false, payable_reason: 'Invoice is CANCELLED' });
  BillFlow.checkout({ url: `https://pay.example/pay/${TOKEN}`, fetch: m.fetch, provider: m.provider });
  await tick();
  const root = document.body.children[0].shadow;
  assert.equal(root.find((n) => n.tag === 'button' && !n.className).disabled, true);
  assert.match(root.find((n) => n.className.startsWith('msg')).textContent, /CANCELLED/);
});

test('javascript: explorer links are never rendered as hrefs', async () => {
  document.body.children = [];
  const m = mocks(); const f = m.fetch;
  m.fetch = async (url, i) => { const r = await f(url, i); if (url.endsWith('/verify-tx')) { const j = await r.json(); j.receipt.explorer_url = 'javascript:alert(1)'; return { ...r, json: async () => j }; } return r; };
  BillFlow.checkout({ url: `https://pay.example/pay/${TOKEN}`, fetch: m.fetch, provider: m.provider, pollMs: 1 });
  await tick();
  const root = document.body.children[0].shadow;
  root.find((n) => n.tag === 'button' && !n.className).click(); await tick(); await tick(); await tick();
  assert.equal(root.find((n) => n.tag === 'a'), null);
});

test('checkout() validates its options', () => {
  assert.throws(() => BillFlow.checkout({}), { code: 'bad_options' });
  assert.throws(() => BillFlow.checkout({ url: 'https://x/not-checkout' }), { code: 'bad_checkout_url' });
});
