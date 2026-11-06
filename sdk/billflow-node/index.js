'use strict';
/**
 * @billflow/node — tiny server-side SDK (zero dependencies, Node >= 18). Testnet only.
 *   const bf = require('@billflow/node').create({ baseUrl: 'https://billflow.example', apiKey: process.env.BILLFLOW_API_KEY });
 *   const session = await bf.checkout.createSession({ amount: '1.00', reference: 'order_42' });   // -> session.checkout_url
 *   bf.webhooks.verify(rawBody, req.headers['billflow-signature'], process.env.BILLFLOW_WEBHOOK_SECRET); // throws if invalid
 * Keep the API key on your SERVER. Never ship it to a browser or mobile app.
 */
const crypto = require('node:crypto');

class BillFlowError extends Error {
  constructor(status, code, message) { super(message); this.name = 'BillFlowError'; this.status = status; this.code = code; }
}

function create({ baseUrl, apiKey, fetchImpl }) {
  if (!baseUrl || !apiKey) throw new Error('baseUrl and apiKey are required');
  const f = fetchImpl || fetch;
  const root = baseUrl.replace(/\/$/, '') + '/api/v1';
  async function call(method, path, body, headers = {}) {
    const res = await f(root + path, {
      method, headers: { Authorization: 'Bearer ' + apiKey, ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) { const e = json.error || {}; throw new BillFlowError(res.status, e.code || 'http_' + res.status, e.message || 'request failed'); }
    return json;
  }
  return {
    checkout: {
      /** params: { amount, description?, reference?, customer?, metadata?, success_url?, cancel_url?, due_in_days? }; idempotencyKey avoids duplicate orders on retry */
      createSession: (params, { idempotencyKey } = {}) => call('POST', '/checkout/sessions', params, idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}),
      getSession: (id) => call('GET', '/checkout/sessions/' + encodeURIComponent(id)),
      listSessions: ({ reference, limit } = {}) => call('GET', '/checkout/sessions?' + new URLSearchParams({ ...(reference ? { reference } : {}), ...(limit ? { limit } : {}) })),
      expireSession: (id) => call('POST', '/checkout/sessions/' + encodeURIComponent(id) + '/expire'),
    },
    webhooks: { verify, constructEvent },
  };
}

/** Verify `BillFlow-Signature: t=<unix>,v1=<hex>` over `${t}.${rawBody}` (HMAC-SHA256). Constant-time; rejects stale timestamps (replay). */
function verify(rawBody, header, secret, toleranceSeconds = 300, now = Math.floor(Date.now() / 1000)) {
  const parts = Object.fromEntries(String(header || '').split(',').map((p) => p.split('=', 2)));
  const t = Number(parts.t), v1 = parts.v1;
  if (!Number.isFinite(t) || !v1) throw new BillFlowError(400, 'bad_signature', 'malformed BillFlow-Signature header');
  if (Math.abs(now - t) > toleranceSeconds) throw new BillFlowError(400, 'stale_signature', 'timestamp outside tolerance');
  const want = crypto.createHmac('sha256', secret).update(`${t}.${rawBody}`).digest();
  const got = Buffer.from(v1, 'hex');
  if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) throw new BillFlowError(400, 'bad_signature', 'signature mismatch');
  return true;
}

function constructEvent(rawBody, header, secret, tolerance) {
  verify(rawBody, header, secret, tolerance);
  return JSON.parse(rawBody);
}

module.exports = { create, verify, constructEvent, BillFlowError };
