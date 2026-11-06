'use strict';
// Tests the Node SDK's webhook verification and the demo merchant's webhook endpoint (real HTTP on an ephemeral port).
process.env.BILLFLOW_WEBHOOK_SECRET = 'whsec_test_secret';
process.env.BILLFLOW_API_KEY = 'bf_test_dummy';
process.env.PUBLIC_URL = 'http://localhost:0';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { verify, constructEvent, create } = require('../../sdk/billflow-node');
const { server, orders } = require('../server');

const SECRET = 'whsec_test_secret';
const sign = (body, t = Math.floor(Date.now() / 1000), secret = SECRET) => `t=${t},v1=${crypto.createHmac('sha256', secret).update(`${t}.${body}`).digest('hex')}`;

test('SDK verify: valid, tampered body, wrong secret, stale, malformed', () => {
  const body = '{"id":"e1"}';
  assert.equal(verify(body, sign(body), SECRET), true);
  assert.throws(() => verify(body + ' ', sign(body), SECRET), { code: 'bad_signature' });
  assert.throws(() => verify(body, sign(body, undefined, 'other'), SECRET), { code: 'bad_signature' });
  assert.throws(() => verify(body, sign(body, Math.floor(Date.now() / 1000) - 3600), SECRET), { code: 'stale_signature' });
  assert.throws(() => verify(body, 'nonsense', SECRET), { code: 'bad_signature' });
  assert.throws(() => verify(body, undefined, SECRET), { code: 'bad_signature' });
  assert.deepEqual(constructEvent(body, sign(body), SECRET), { id: 'e1' });
});

test('SDK client sends bearer key + idempotency key and maps errors', async () => {
  const seen = [];
  const bf = create({ baseUrl: 'https://bf.test/', apiKey: 'bf_test_k', fetchImpl: async (url, init) => { seen.push({ url, init });
    return { ok: seen.length === 1, status: seen.length === 1 ? 201 : 400, json: async () => (seen.length === 1 ? { id: 's1' } : { error: { code: 'invalid_url', message: 'bad' } }) }; } });
  assert.deepEqual(await bf.checkout.createSession({ amount: '1' }, { idempotencyKey: 'order-1-session' }), { id: 's1' });
  assert.equal(seen[0].url, 'https://bf.test/api/v1/checkout/sessions');
  assert.equal(seen[0].init.headers.Authorization, 'Bearer bf_test_k'); assert.equal(seen[0].init.headers['Idempotency-Key'], 'order-1-session');
  await assert.rejects(bf.checkout.createSession({ amount: '1' }), { code: 'invalid_url', status: 400 });
  assert.throws(() => create({ baseUrl: 'x' }));
});

async function post(port, body, header) {
  return fetch(`http://127.0.0.1:${port}/webhooks/billflow`, { method: 'POST', body, headers: { 'Content-Type': 'application/json', ...(header ? { 'BillFlow-Signature': header } : {}) } });
}

test('demo merchant webhook endpoint: rejects unsigned/forged, applies paid + refunds once', async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  try {
    orders.set('order_1', { id: 'order_1', status: 'awaiting_payment', amount: '10.00' });
    const paid = JSON.stringify({ id: 'invoice.paid:1', type: 'invoice.paid', data: { reference: 'order_1', tx_hash: '0x' + 'ab'.repeat(32) } });
    assert.equal((await post(port, paid)).status, 400, 'missing signature');
    assert.equal((await post(port, paid, sign(paid, undefined, 'attacker'))).status, 400, 'forged signature');
    assert.equal(orders.get('order_1').status, 'awaiting_payment');
    assert.equal((await post(port, paid, sign(paid))).status, 200);
    assert.equal(orders.get('order_1').status, 'paid');

    const refund = JSON.stringify({ id: 'refund.confirmed:9', type: 'refund.confirmed', data: { reference: 'order_1', amount: '4.000000', total_refunded_base: '4000000', fully_refunded: false } });
    for (let i = 0; i < 3; i++) assert.equal((await post(port, refund, sign(refund))).status, 200); // at-least-once delivery
    assert.equal(orders.get('order_1').refunded, '4.000000', 'duplicate delivery must not refund twice');
    assert.equal(orders.get('order_1').status, 'partially_refunded');
    const rest = JSON.stringify({ id: 'refund.confirmed:10', type: 'refund.confirmed', data: { reference: 'order_1', amount: '6.000000', total_refunded_base: '10000000', fully_refunded: true } });
    await post(port, rest, sign(rest));
    assert.equal(orders.get('order_1').status, 'refunded');
    // an OLD partial event arriving late must not downgrade the order or the refunded total
    await post(port, refund, sign(refund));
    assert.equal(orders.get('order_1').status, 'refunded'); assert.equal(orders.get('order_1').refunded, '10.000000');
    // orders page escapes content
    orders.set('x', { id: '<script>alert(1)</script>', status: 'paid', amount: '1' });
    const html = await (await fetch(`http://127.0.0.1:${port}/orders`)).text();
    assert.ok(!html.includes('<script>alert(1)</script>'));
  } finally { server.close(); }
});
