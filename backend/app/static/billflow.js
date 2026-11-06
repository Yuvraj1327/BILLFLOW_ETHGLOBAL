/*! BillFlow Checkout widget v0.1 — dependency-free (no build step). Testnet only: Whitechain Sepolia (chain 1874), official USDT.
 *
 *   <script src="https://YOUR-BILLFLOW-HOST/billflow.js"></script>
 *   BillFlow.checkout({ url: session.checkout_url, onSuccess: (receipt) => ..., onError: (err) => ... });
 *
 * Security model: the wallet signs only (1) USDT.approve(BillFlowPayments, amount) and (2) BillFlowPayments.payInvoice(quote, sig),
 * where the quote was signed by the BillFlow backend and binds payer/merchant/amount/invoice. `onSuccess` fires ONLY after the
 * BillFlow backend has independently verified the transaction on-chain (receipt, confirmations, event, USDT transfer). A wallet's
 * "success" is never trusted. No private keys, secrets or API keys ever reach this script.
 */
(function (root, factory) {
  var api = factory(root);
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.BillFlow = api;
})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this), function (root) {
  'use strict';

  var SEL = { approve: '0x095ea7b3', allowance: '0xdd62ed3e', payInvoice: '0xa87ce778' };
  var QUOTE_OFFSET = 9 * 32; // 8 static quote words + 1 offset word precede the dynamic `bytes signature`

  // ───────────────────────── ABI helpers (exported for tests) ─────────────────────────
  function word(big) {
    var n = BigInt(big);
    if (n < 0n) throw new Error('negative value');
    var h = n.toString(16);
    if (h.length > 64) throw new Error('value exceeds 256 bits');
    return '0'.repeat(64 - h.length) + h;
  }
  function addrWord(a) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error('bad address');
    return '0'.repeat(24) + a.slice(2).toLowerCase();
  }
  function b32Word(h) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(h)) throw new Error('bad bytes32');
    return h.slice(2).toLowerCase();
  }
  function encodeApprove(spender, amount) { return SEL.approve + addrWord(spender) + word(amount); }
  function encodeAllowance(owner, spender) { return SEL.allowance + addrWord(owner) + addrWord(spender); }
  function encodePayInvoice(q, sig) {
    if (!/^0x([0-9a-fA-F]{2})+$/.test(sig)) throw new Error('bad signature');
    var len = (sig.length - 2) / 2;
    var padded = sig.slice(2).toLowerCase() + '0'.repeat((64 - ((len * 2) % 64)) % 64);
    return SEL.payInvoice + b32Word(q.invoiceId) + b32Word(q.invoiceHash) + addrWord(q.merchant) + addrWord(q.payer) +
      word(q.amount) + word(q.invoiceTotal) + word(q.nonce) + word(q.expiry) + word(QUOTE_OFFSET) + word(len) + padded;
  }

  // ───────────────────────── plumbing ─────────────────────────
  function BillFlowError(code, message, extra) {
    var e = new Error(message); e.name = 'BillFlowError'; e.code = code;
    if (extra) for (var k in extra) e[k] = extra[k];
    return e;
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function parseCheckoutUrl(url, apiBase) {
    var u = new URL(url, typeof location !== 'undefined' ? location.href : undefined);
    var m = u.pathname.match(/\/pay\/([A-Za-z0-9_\-]{32,128})\/?$/);
    if (!m) throw BillFlowError('bad_checkout_url', 'Not a BillFlow checkout URL');
    return { token: m[1], apiBase: (apiBase || u.origin + '/api/v1').replace(/\/$/, '') };
  }

  function makeApi(apiBase, token, fetchImpl) {
    var f = fetchImpl || (root && root.fetch ? root.fetch.bind(root) : fetch);
    var base = apiBase + '/public/invoices/' + token;
    return function call(method, path, body) {
      return f(base + path, {
        method: method, headers: body ? { 'Content-Type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined, credentials: 'omit'
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (j) {
          if (!res.ok) {
            var err = (j && j.error) || {};
            throw BillFlowError(err.code || 'http_' + res.status, err.message || 'Request failed (' + res.status + ')', { status: res.status });
          }
          return j;
        });
      });
    };
  }

  function rpc(provider, method, params) {
    return provider.request({ method: method, params: params || [] }).catch(function (e) {
      if (e && (e.code === 4001 || e.code === 'ACTION_REJECTED')) throw BillFlowError('user_rejected', 'You rejected the request in your wallet');
      throw e;
    });
  }

  async function waitMined(provider, hash, timeoutMs) {
    var until = Date.now() + timeoutMs;
    while (Date.now() < until) {
      var r = await rpc(provider, 'eth_getTransactionReceipt', [hash]);
      if (r) {
        if (r.status !== '0x1') throw BillFlowError('tx_reverted', 'The transaction was reverted on-chain', { txHash: hash });
        return r;
      }
      await sleep(1500);
    }
    throw BillFlowError('tx_timeout', 'The transaction was not mined in time', { txHash: hash });
  }

  async function ensureChain(provider, chainId) {
    var want = '0x' + chainId.toString(16);
    var have = await rpc(provider, 'eth_chainId');
    if (String(have).toLowerCase() === want) return;
    try {
      await rpc(provider, 'wallet_switchEthereumChain', [{ chainId: want }]);
    } catch (e) {
      if (e && e.name === 'BillFlowError') throw e;
      throw BillFlowError('wrong_network', 'Switch your wallet to Whitechain Sepolia (chain ' + chainId + ') and try again');
    }
    have = await rpc(provider, 'eth_chainId');
    if (String(have).toLowerCase() !== want) throw BillFlowError('wrong_network', 'Wallet is not on chain ' + chainId);
  }

  // ───────────────────────── the payment flow (DOM-free; this is what tests drive) ─────────────────────────
  /**
   * pay({ url|token, apiBase?, provider, amount?, onStatus?, fetch?, verifyTimeoutMs?, pollMs? }) -> receipt
   * Resolves only after the BillFlow backend verified the payment on-chain. Rejects with BillFlowError{code}.
   */
  async function pay(opts) {
    var parsed = opts.token ? { token: opts.token, apiBase: (opts.apiBase || '').replace(/\/$/, '') } : parseCheckoutUrl(opts.url, opts.apiBase);
    var call = makeApi(parsed.apiBase, parsed.token, opts.fetch);
    var status = opts.onStatus || function () {};
    var provider = opts.provider || (root && root.ethereum);
    if (!provider) throw BillFlowError('no_wallet', 'No EIP-1193 wallet found. Install a wallet such as MetaMask.');

    status('loading');
    var inv = await call('GET', '');
    if (!inv.payable) throw BillFlowError('not_payable', inv.payable_reason || 'This invoice cannot be paid right now');

    status('connect');
    var accounts = await rpc(provider, 'eth_requestAccounts');
    if (!accounts || !accounts.length) throw BillFlowError('no_account', 'No wallet account available');
    var payer = accounts[0];
    await ensureChain(provider, inv.chain_id);

    status('quote');
    var intent = await call('POST', '/payment-intent', { payer_wallet: payer, amount: opts.amount || null });
    if (intent.chain_id !== inv.chain_id) throw BillFlowError('wrong_network', 'Server returned an unexpected chain');
    if (intent.usdt_address.toLowerCase() !== inv.usdt_address.toLowerCase() ||
        intent.payments_contract.toLowerCase() !== inv.payments_contract.toLowerCase()) {
      throw BillFlowError('contract_mismatch', 'Quote does not match the checkout configuration');
    }
    if (intent.quote.payer.toLowerCase() !== payer.toLowerCase()) throw BillFlowError('quote_mismatch', 'Quote was issued for another wallet');

    var need = BigInt(intent.approve_amount_base);
    var allowance = BigInt(await rpc(provider, 'eth_call', [{ to: intent.usdt_address, data: encodeAllowance(payer, intent.payments_contract) }, 'latest']));
    if (allowance < need) {
      status('approve');
      var ah = await rpc(provider, 'eth_sendTransaction', [{ from: payer, to: intent.usdt_address, data: encodeApprove(intent.payments_contract, need) }]);
      await waitMined(provider, ah, opts.minedTimeoutMs || 120000);
    }

    status('pay');
    var txHash = await rpc(provider, 'eth_sendTransaction', [{ from: payer, to: intent.payments_contract, data: encodePayInvoice(intent.quote, intent.signature) }]);
    status('mining', { txHash: txHash });
    await waitMined(provider, txHash, opts.minedTimeoutMs || 120000);

    // The wallet says "mined". The BillFlow backend decides whether it counts.
    status('verifying', { txHash: txHash });
    var until = Date.now() + (opts.verifyTimeoutMs || 180000), last = null;
    while (Date.now() < until) {
      last = await call('POST', '/verify-tx', { tx_hash: txHash });
      if (last.stage === 'verified' && last.paid_for_this_invoice) {
        status('done', { txHash: txHash });
        return last.receipt;
      }
      if (last.stage === 'failed' || last.stage === 'rejected' || (last.stage === 'verified' && !last.paid_for_this_invoice)) {
        throw BillFlowError('verification_failed', last.detail || 'Payment could not be verified', { txHash: txHash, stage: last.stage });
      }
      status('verifying', { txHash: txHash, confirmations: last.confirmations, required: last.required_confirmations });
      await sleep(opts.pollMs || 3000);
    }
    throw BillFlowError('verify_timeout', 'Payment sent; verification is still pending. Check the status page.', { txHash: txHash });
  }

  // ───────────────────────── UI (Shadow DOM; no innerHTML with server data) ─────────────────────────
  var CSS = ':host{all:initial}*{box-sizing:border-box;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}' +
    '.ov{position:fixed;inset:0;background:rgba(15,23,42,.55);display:flex;align-items:center;justify-content:center;z-index:2147483647}' +
    '.ov.inline{position:static;background:none;min-height:100vh}' +
    '.card{background:#fff;color:#0f172a;width:min(420px,92vw);border-radius:16px;padding:24px;box-shadow:0 20px 50px rgba(0,0,0,.25)}' +
    'h2{margin:0 0 4px;font-size:18px}.sub{color:#64748b;font-size:13px;margin-bottom:16px}' +
    '.amt{font-size:32px;font-weight:700;margin:8px 0}.row{display:flex;justify-content:space-between;font-size:13px;color:#475569;margin:4px 0}' +
    'button{width:100%;padding:12px;border:0;border-radius:10px;background:#4f46e5;color:#fff;font-size:15px;font-weight:600;cursor:pointer;margin-top:14px}' +
    'button[disabled]{opacity:.55;cursor:default}button.ghost{background:#e2e8f0;color:#0f172a}' +
    '.msg{margin-top:12px;font-size:13px;min-height:18px;color:#334155}.err{color:#b91c1c}.ok{color:#15803d;font-weight:600}' +
    'a{color:#4f46e5;word-break:break-all}.net{font-size:11px;color:#94a3b8;margin-top:12px;text-align:center}';

  var STEP_TEXT = { loading: 'Loading invoice…', connect: 'Connect your wallet…', quote: 'Preparing your payment…',
    approve: 'Approve USDT in your wallet…', pay: 'Confirm the payment in your wallet…', mining: 'Waiting for the transaction to be mined…',
    verifying: 'Verifying the payment on-chain…', done: 'Payment verified.' };

  function el(tag, props, children) {
    var e = document.createElement(tag);
    if (props) for (var k in props) { if (k === 'text') e.textContent = props[k]; else e.setAttribute(k, props[k]); }
    (children || []).forEach(function (c) { e.appendChild(c); });
    return e;
  }

  function checkout(opts) {
    if (!opts || (!opts.url && !opts.token)) throw BillFlowError('bad_options', 'checkout() needs { url } (the session checkout_url)');
    var inline = opts.mode === 'inline';
    var parsed = opts.token ? { token: opts.token, apiBase: (opts.apiBase || '').replace(/\/$/, '') } : parseCheckoutUrl(opts.url, opts.apiBase);
    var call = makeApi(parsed.apiBase, parsed.token, opts.fetch);
    var host = el('div'); var shadow = host.attachShadow({ mode: 'open' });
    shadow.appendChild(el('style', { text: CSS }));
    var ov = el('div', { class: 'ov' + (inline ? ' inline' : '') }); shadow.appendChild(ov);
    var title = el('h2', { text: 'Loading…' }), sub = el('div', { class: 'sub' });
    var amt = el('div', { class: 'amt' }), rows = el('div'), msg = el('div', { class: 'msg' });
    var btn = el('button', { text: 'Connect wallet & pay' }), close = el('button', { class: 'ghost', text: 'Close' });
    var net = el('div', { class: 'net', text: 'Whitechain Sepolia testnet · official USDT · no real funds' });
    ov.appendChild(el('div', { class: 'card', role: 'dialog', 'aria-modal': 'true' }, [title, sub, amt, rows, btn, msg, close, net]));
    (inline && opts.container ? opts.container : document.body).appendChild(host);

    var view = null, busy = false, finished = false;
    function say(text, cls) { msg.className = 'msg' + (cls ? ' ' + cls : ''); msg.textContent = text; }
    function row(k, v) { rows.appendChild(el('div', { class: 'row' }, [el('span', { text: k }), el('span', { text: v })])); }
    function destroy() { if (host.parentNode) host.parentNode.removeChild(host); }
    function doClose() { destroy(); if (opts.onClose) opts.onClose({ paid: finished }); }
    close.addEventListener('click', function () { if (!busy) { if (!finished && view && view.cancel_url && opts.redirect) location.href = view.cancel_url; else doClose(); } });
    if (!inline) ov.addEventListener('click', function (e) { if (e.target === ov && !busy) doClose(); });

    function safeUrl(u) { try { var x = new URL(u); return (x.protocol === 'https:' || x.protocol === 'http:') ? x.href : null; } catch (e) { return null; } }

    call('GET', '').then(function (v) {
      view = v; title.textContent = 'Pay ' + v.merchant_name; sub.textContent = 'Invoice ' + v.invoice_number + (v.description ? ' · ' + v.description : '');
      amt.textContent = v.remaining_amount + ' ' + v.currency;
      row('Status', v.status); row('Network', 'Whitechain Sepolia (' + v.chain_id + ')');
      if (!v.payable) { btn.disabled = true; say(v.payable_reason || 'This invoice cannot be paid right now', 'err'); }
      if (v.status === 'PAID') { finished = true; say('This invoice is already paid.', 'ok'); }
    }).catch(function (e) { btn.disabled = true; say(e.message, 'err'); if (opts.onError) opts.onError(e); });

    btn.addEventListener('click', function () {
      if (busy || !view) return;
      busy = true; btn.disabled = true; close.disabled = true;
      pay({ token: parsed.token, apiBase: parsed.apiBase, provider: opts.provider, amount: opts.amount, fetch: opts.fetch,
        verifyTimeoutMs: opts.verifyTimeoutMs, pollMs: opts.pollMs,
        onStatus: function (s, info) {
          var t = STEP_TEXT[s] || s;
          if (s === 'verifying' && info && info.required) t += ' (' + info.confirmations + '/' + info.required + ' confirmations)';
          say(t);
        } }).then(function (receipt) {
        finished = true; busy = false; close.disabled = false; close.textContent = 'Done';
        say('Payment verified on-chain. Thank you!', 'ok');
        var link = safeUrl(receipt.explorer_url);
        if (link) { var a = el('a', { href: link, target: '_blank', rel: 'noopener noreferrer', text: 'View transaction receipt' }); msg.appendChild(el('div')); msg.lastChild.appendChild(a); }
        try { if (opts.onSuccess) opts.onSuccess(receipt); } catch (e) { /* merchant callback errors must not break the widget */ }
        var ok = view && safeUrl(view.success_url);
        if (opts.redirect && ok) {
          var u = new URL(ok); u.searchParams.set('billflow_status', 'paid'); u.searchParams.set('billflow_tx', receipt.tx_hash);
          if (view.reference) u.searchParams.set('billflow_reference', view.reference);
          setTimeout(function () { location.href = u.href; }, 1800);
        }
      }).catch(function (e) {
        busy = false; btn.disabled = false; close.disabled = false; btn.textContent = 'Try again';
        say(e.message || 'Payment failed', 'err');
        if (e.txHash && safeUrl(view && view.explorer_url)) { /* keep tx hash visible for support */ say((e.message || 'Payment failed') + ' (tx ' + e.txHash + ')', 'err'); }
        if (opts.onError) opts.onError(e);
      });
    });
    return { close: doClose };
  }

  // Hosted page bootstrap: <div id="billflow-hosted"></div> on /pay/<token>
  function bootHosted() {
    var c = typeof document !== 'undefined' && document.getElementById('billflow-hosted');
    if (c) checkout({ url: location.href, mode: 'inline', container: c, redirect: true });
  }
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bootHosted); else bootHosted();
  }

  return { version: '0.1.0', checkout: checkout, pay: pay,
    _internals: { encodePayInvoice: encodePayInvoice, encodeApprove: encodeApprove, encodeAllowance: encodeAllowance, parseCheckoutUrl: parseCheckoutUrl, SEL: SEL } };
});
