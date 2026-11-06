'use strict';
/**
 * "Bean Counter" — an INDEPENDENT demo merchant store that sells one product and accepts USDT through BillFlow.
 * It shares no code or database with BillFlow: it only calls the public Checkout API with an API key (server side),
 * embeds billflow.js in the browser, and receives signed webhooks. Zero npm dependencies.
 *
 *   BILLFLOW_URL=http://localhost:8000 BILLFLOW_API_KEY=bf_test_... BILLFLOW_WEBHOOK_SECRET=whsec_... node server.js
 */
const http = require('node:http');
const crypto = require('node:crypto');
const { create, verify } = require('../sdk/billflow-node');

const PORT = Number(process.env.PORT || 4000);
const BILLFLOW_URL = (process.env.BILLFLOW_URL || 'http://localhost:8000').replace(/\/$/, '');
const API_KEY = process.env.BILLFLOW_API_KEY || '';
const WEBHOOK_SECRET = process.env.BILLFLOW_WEBHOOK_SECRET || '';
const PUBLIC_URL = process.env.PUBLIC_URL || `http://localhost:${PORT}`;
const PRICE = process.env.PRICE || '1.00';

const bf = API_KEY ? create({ baseUrl: BILLFLOW_URL, apiKey: API_KEY }) : null;
const orders = new Map();      // orderId -> { id, status, amount, tx, refunded, sessionId }
const seenEvents = new Set();  // webhook dedupe (delivery is at-least-once)

const page = (body) => `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Bean Counter (BillFlow demo merchant)</title><style>body{font:16px system-ui;max-width:640px;margin:40px auto;padding:0 16px;color:#0f172a}
button{padding:12px 18px;border:0;border-radius:10px;background:#4f46e5;color:#fff;font-size:16px;cursor:pointer}
table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #e2e8f0;padding:6px;text-align:left;font-size:14px}code{font-size:12px}</style>${body}`;

const storefront = () => page(`
<h1>☕ Bean Counter</h1><p>Single-origin test beans — <b>${PRICE} USDT</b> (Whitechain Sepolia testnet)</p>
<button id="buy">Pay with BillFlow</button> <span id="msg"></span>
<p><a href="/orders">Merchant view →</a></p>
<script src="${BILLFLOW_URL}/billflow.js"></script>
<script>
document.getElementById('buy').onclick = async () => {
  const { checkout_url, order_id } = await (await fetch('/api/checkout', { method: 'POST' })).json();
  BillFlow.checkout({ url: checkout_url,
    onSuccess: (r) => { location.href = '/thanks?order=' + order_id + '&tx=' + r.tx_hash; },
    onError: (e) => { document.getElementById('msg').textContent = e.code + ': ' + e.message; } });
};
</script>`);

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function ordersPage() {
  const rows = [...orders.values()].reverse().map((o) =>
    `<tr><td><code>${esc(o.id)}</code></td><td>${esc(o.status)}</td><td>${esc(o.amount)}</td><td>${o.tx ? `<code>${esc(o.tx.slice(0, 12))}…</code>` : ''}</td><td>${esc(o.refunded || '')}</td></tr>`).join('');
  return page(`<h1>Merchant view</h1><p>Status changes only when a <b>signed BillFlow webhook</b> arrives.</p>
  <table><tr><th>Order</th><th>Status</th><th>USDT</th><th>Tx</th><th>Refunded</th></tr>${rows || '<tr><td colspan=5>No orders yet</td></tr>'}</table><p><a href="/">← Store</a></p>`);
}

async function readBody(req, limit = 1_000_000) {
  const chunks = []; let n = 0;
  for await (const c of req) { n += c.length; if (n > limit) throw new Error('body too large'); chunks.push(c); }
  return Buffer.concat(chunks).toString('utf8');
}
const send = (res, code, body, type = 'text/html; charset=utf-8') => { res.writeHead(code, { 'Content-Type': type }); res.end(body); };

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, PUBLIC_URL);
    if (req.method === 'GET' && url.pathname === '/') return send(res, 200, storefront());
    if (req.method === 'GET' && url.pathname === '/orders') return send(res, 200, ordersPage());
    if (req.method === 'GET' && url.pathname === '/api/orders') return send(res, 200, JSON.stringify([...orders.values()]), 'application/json');
    if (req.method === 'GET' && url.pathname === '/thanks') {
      return send(res, 200, page(`<h1>Thank you!</h1><p>Order <code>${esc(url.searchParams.get('order'))}</code> — BillFlow verified your payment on-chain.</p><p><a href="/">← Store</a></p>`));
    }
    if (req.method === 'POST' && url.pathname === '/api/checkout') {
      if (!bf) return send(res, 500, JSON.stringify({ error: 'Set BILLFLOW_API_KEY' }), 'application/json');
      const orderId = 'order_' + crypto.randomBytes(5).toString('hex');
      const session = await bf.checkout.createSession(
        { amount: PRICE, description: 'Single-origin test beans', reference: orderId, success_url: `${PUBLIC_URL}/thanks?order=${orderId}`, cancel_url: PUBLIC_URL },
        { idempotencyKey: orderId + '-session' });
      orders.set(orderId, { id: orderId, status: 'awaiting_payment', amount: PRICE, sessionId: session.id });
      return send(res, 200, JSON.stringify({ checkout_url: session.checkout_url, order_id: orderId }), 'application/json');
    }
    if (req.method === 'POST' && url.pathname === '/webhooks/billflow') {
      const raw = await readBody(req);                           // verify the RAW body, before JSON parsing
      try { verify(raw, req.headers['billflow-signature'], WEBHOOK_SECRET); }
      catch (e) { return send(res, 400, JSON.stringify({ error: e.code || 'invalid' }), 'application/json'); }
      const ev = JSON.parse(raw);
      if (!seenEvents.has(ev.id)) {
        seenEvents.add(ev.id);
        const o = orders.get(ev.data.reference);
        if (o && ev.type === 'invoice.paid') { o.status = 'paid'; o.tx = ev.data.tx_hash; }
        if (o && ev.type === 'refund.confirmed') {
          // Webhooks can arrive out of order: use the CUMULATIVE total from the event (monotonic max), never "add up" deliveries.
          const total = BigInt(ev.data.total_refunded_base);
          if (total > BigInt(o.refundedBase || 0)) { o.refundedBase = total.toString(); o.refunded = (Number(total) / 1e6).toFixed(6); }
          if (ev.data.fully_refunded) o.status = 'refunded';
          else if (o.status !== 'refunded') o.status = 'partially_refunded';
        }
      }
      return send(res, 200, '{"received":true}', 'application/json');
    }
    send(res, 404, 'not found', 'text/plain');
  } catch (e) {
    send(res, 500, JSON.stringify({ error: String(e.message || e) }), 'application/json');
  }
});

if (require.main === module) server.listen(PORT, () => console.log(`Bean Counter demo merchant on ${PUBLIC_URL} → BillFlow ${BILLFLOW_URL}`));
module.exports = { server, orders };
