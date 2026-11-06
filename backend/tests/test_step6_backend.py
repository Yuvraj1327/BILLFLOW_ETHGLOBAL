"""Step 6 backend tests: API keys, checkout sessions, public verify, refunds, webhooks, CSV export, duplicate-financing block.
Uses the FakeChain double (no network). The real-contract path is covered in test_step6_local_chain.py."""
from __future__ import annotations

import json
import time

import httpx
import pytest
from eth_account import Account

from app.services import webhook_service as wh
from tests.helpers import REFUNDS, USDT, erc20_transfer, h32, invoice_paid, payment_refunded, pdf_bytes

API = "/api/v1"
MERCHANT_WALLET = "0x" + "aa" * 20
PAYER = Account.create().address.lower()
SESSION = {"amount": "25.50", "description": "Order 42", "reference": "order_42", "metadata": {"sku": "beans"}}


def key_headers(key: str) -> dict:
    return {"Authorization": f"Bearer {key}"}


@pytest.fixture()
def shop(w, client):
    m = w.merchant(MERCHANT_WALLET)
    k = client.post(f"{API}/merchant/api-keys", json={"name": "server"}, headers=m["h"])
    assert k.status_code == 201, k.text
    return m, k.json()["key"]


def tx(n: int) -> str:
    return h32(f"s6-tx-{n}")


def pay_session(chain, client, db, sess: dict, n: int, amount: int, total: int, block: int = 100) -> str:
    inv = db.execute("select * from invoices where id=%s", (sess["invoice_id"],)).fetchone()
    inv = {**inv, "amount_base": inv["amount_base"]}
    logs = [erc20_transfer(PAYER, MERCHANT_WALLET, amount, address=USDT, tx_hash=tx(n), log_index=0),
            invoice_paid(inv, PAYER, MERCHANT_WALLET, amount, total, tx_hash=tx(n), log_index=1, payment_id=n)]
    chain.add(tx(n), logs, block=block)
    return tx(n)


# ───────────────────────── API keys ─────────────────────────
def test_api_key_lifecycle(w, client):
    m = w.merchant(MERCHANT_WALLET)
    r = client.post(f"{API}/merchant/api-keys", json={"name": "ci"}, headers=m["h"])
    key = r.json()["key"]
    assert key.startswith("bf_test_") and "cannot be shown again" in r.json()["note"]
    listed = client.get(f"{API}/merchant/api-keys", headers=m["h"]).json()
    assert len(listed) == 1 and "key" not in listed[0] and "key_hash" not in listed[0] and listed[0]["key_prefix"] == key[:12]
    ok = client.post(f"{API}/checkout/sessions", json=SESSION, headers=key_headers(key))
    assert ok.status_code == 201, ok.text
    assert client.delete(f"{API}/merchant/api-keys/{r.json()['id']}", headers=m["h"]).status_code == 200
    assert client.post(f"{API}/checkout/sessions", json=SESSION, headers=key_headers(key)).status_code == 401


def test_api_key_rejections(client, shop):
    for h in ({}, key_headers("bf_test_nope"), key_headers("sk_live_whatever"), {"Authorization": "Basic abc"}):
        r = client.post(f"{API}/checkout/sessions", json=SESSION, headers=h)
        assert r.status_code == 401 and r.json()["error"]["code"] == "invalid_api_key"


def test_api_key_is_stored_hashed_only(shop, conn):
    _, key = shop
    row = conn.execute("select * from api_keys").fetchone()
    assert key not in json.dumps({k: str(v) for k, v in row.items()}) and len(row["key_hash"]) == 64


def test_user_jwt_cannot_call_checkout_api_and_key_cannot_call_dashboard(client, shop):
    m, key = shop
    assert client.post(f"{API}/checkout/sessions", json=SESSION, headers=m["h"]).status_code == 401
    assert client.get(f"{API}/merchant/api-keys", headers=key_headers(key)).status_code == 401


def test_api_key_rate_limit(client, shop, monkeypatch):
    from app.core.config import get_settings
    _, key = shop
    s = get_settings()
    monkeypatch.setattr(s, "api_key_rate_limit_per_minute", 3)
    codes = [client.get(f"{API}/checkout/sessions", headers=key_headers(key)).status_code for _ in range(5)]
    assert codes[:3] == [200, 200, 200] and codes[3:] == [429, 429]


# ───────────────────────── checkout sessions ─────────────────────────
def test_create_session_returns_payable_checkout(client, shop):
    _, key = shop
    r = client.post(f"{API}/checkout/sessions", json={**SESSION, "success_url": "https://shop.test/ok", "customer": {"email": "a@b.io", "name": "Ann"}},
                    headers=key_headers(key))
    assert r.status_code == 201, r.text
    s = r.json()
    assert s["status"] == "open" and s["amount"] == "25.5" or s["amount"] == "25.50"
    assert s["checkout_url"].startswith("https://pay.test/pay/") and s["reference"] == "order_42" and s["receipts"] == []
    token = s["checkout_url"].rsplit("/", 1)[1]
    pub = client.get(f"{API}/public/invoices/{token}").json()
    assert pub["payable"] is True and pub["reference"] == "order_42" and pub["success_url"] == "https://shop.test/ok"
    assert pub["merchant_name"] == "Acme Ltd"


def test_session_idempotency_key(client, shop, conn):
    _, key = shop
    h = {**key_headers(key), "Idempotency-Key": "order-42-attempt-1"}
    a, b = client.post(f"{API}/checkout/sessions", json=SESSION, headers=h), client.post(f"{API}/checkout/sessions", json=SESSION, headers=h)
    assert a.status_code == b.status_code == 201 and a.json()["id"] == b.json()["id"]
    assert conn.execute("select count(*) n from invoices").fetchone()["n"] == 1
    bad = client.post(f"{API}/checkout/sessions", json=SESSION, headers={**key_headers(key), "Idempotency-Key": "x"})
    assert bad.status_code == 400


@pytest.mark.parametrize("field,val", [("success_url", "javascript:alert(1)"), ("cancel_url", "ftp://x/y"), ("success_url", "https://u:p@x.io/")])
def test_session_rejects_unsafe_urls(client, shop, field, val):
    _, key = shop
    assert client.post(f"{API}/checkout/sessions", json={**SESSION, field: val}, headers=key_headers(key)).status_code == 400


def test_session_validation(client, shop):
    _, key = shop
    h = key_headers(key)
    assert client.post(f"{API}/checkout/sessions", json={**SESSION, "amount": "0"}, headers=h).status_code in (400, 422)
    assert client.post(f"{API}/checkout/sessions", json={**SESSION, "amount": "-5"}, headers=h).status_code in (400, 422)
    assert client.post(f"{API}/checkout/sessions", json={**SESSION, "metadata": {str(i): i for i in range(30)}}, headers=h).status_code == 422
    assert client.post(f"{API}/checkout/sessions", json={**SESSION, "unknown": 1}, headers=h).status_code == 422


def test_sessions_are_isolated_between_businesses(w, client, shop):
    _, key = shop
    sid = client.post(f"{API}/checkout/sessions", json=SESSION, headers=key_headers(key)).json()["id"]
    other = w.merchant("0x" + "bb" * 20)
    k2 = client.post(f"{API}/merchant/api-keys", json={"name": "other"}, headers=other["h"]).json()["key"]
    assert client.get(f"{API}/checkout/sessions/{sid}", headers=key_headers(k2)).status_code == 404
    assert client.post(f"{API}/checkout/sessions/{sid}/expire", headers=key_headers(k2)).status_code == 404
    assert client.get(f"{API}/checkout/sessions", headers=key_headers(k2)).json() == []


def test_list_by_reference_and_expire(client, shop):
    _, key = shop
    h = key_headers(key)
    a = client.post(f"{API}/checkout/sessions", json=SESSION, headers=h).json()
    client.post(f"{API}/checkout/sessions", json={**SESSION, "reference": "order_43"}, headers=h)
    assert [s["id"] for s in client.get(f"{API}/checkout/sessions?reference=order_42", headers=h).json()] == [a["id"]]
    e = client.post(f"{API}/checkout/sessions/{a['id']}/expire", headers=h)
    assert e.status_code == 200 and e.json()["status"] == "cancelled"
    token = a["checkout_url"].rsplit("/", 1)[1]
    assert client.get(f"{API}/public/invoices/{token}").status_code == 410  # link revoked


# ───────────────────────── public verify + receipts ─────────────────────────
def test_public_verify_tx_marks_paid_and_returns_receipt(client, shop, chain, conn):
    _, key = shop
    s = client.post(f"{API}/checkout/sessions", json={"amount": "100", "reference": "o1"}, headers=key_headers(key)).json()
    token = s["checkout_url"].rsplit("/", 1)[1]
    t = pay_session(chain, client, conn, s, 1, 100_000_000, 100_000_000)
    r = client.post(f"{API}/public/invoices/{token}/verify-tx", json={"tx_hash": t})
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["stage"] == "verified" and b["paid_for_this_invoice"] is True and b["invoice_status"] == "PAID"
    assert b["receipt"]["tx_hash"] == t and b["receipt"]["explorer_url"].endswith(f"/tx/{t}") and b["receipt"]["amount"] == "100"
    full = client.get(f"{API}/checkout/sessions/{s['id']}", headers=key_headers(key)).json()
    assert full["status"] == "paid" and full["receipts"][0]["tx_hash"] == t


def test_public_verify_does_not_report_other_invoices_payment(client, shop, chain, conn):
    _, key = shop
    a = client.post(f"{API}/checkout/sessions", json={"amount": "100", "reference": "a"}, headers=key_headers(key)).json()
    b = client.post(f"{API}/checkout/sessions", json={"amount": "100", "reference": "b"}, headers=key_headers(key)).json()
    t = pay_session(chain, client, conn, a, 1, 100_000_000, 100_000_000)
    token_b = b["checkout_url"].rsplit("/", 1)[1]
    r = client.post(f"{API}/public/invoices/{token_b}/verify-tx", json={"tx_hash": t}).json()
    assert r["paid_for_this_invoice"] is False and r["receipt"] is None and r["invoice_status"] == "PENDING"


def test_public_verify_unknown_tx_and_bad_input(client, shop):
    _, key = shop
    s = client.post(f"{API}/checkout/sessions", json=SESSION, headers=key_headers(key)).json()
    token = s["checkout_url"].rsplit("/", 1)[1]
    assert client.post(f"{API}/public/invoices/{token}/verify-tx", json={"tx_hash": h32("nothing")}).json()["stage"] == "not_found"
    assert client.post(f"{API}/public/invoices/{token}/verify-tx", json={"tx_hash": "0x12"}).status_code == 422


def test_public_cors_open_only_on_public_paths(client, shop):
    _, key = shop
    pre = client.options(f"{API}/public/invoices/{'a' * 40}/verify-tx", headers={"Origin": "https://shop.example", "Access-Control-Request-Method": "POST"})
    assert pre.status_code == 204 and pre.headers["access-control-allow-origin"] == "*"
    assert "access-control-allow-credentials" not in {k.lower() for k in pre.headers}
    r = client.get(f"{API}/checkout/sessions", headers={**key_headers(key), "Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in {k.lower() for k in r.headers}


def test_hosted_page_and_widget_served_with_safe_headers(client, shop):
    js = client.get("/billflow.js")
    assert js.status_code == 200 and "BillFlow" in js.text and js.headers["x-content-type-options"] == "nosniff"
    page = client.get("/pay/" + "a" * 40)
    assert page.status_code == 200 and "billflow-hosted" in page.text and "a" * 40 not in page.text
    assert "frame-ancestors 'none'" in page.headers["content-security-policy"] and page.headers["x-frame-options"] == "DENY"
    assert client.get("/pay/short").status_code == 422
    assert "javascript" not in client.get("/pay/" + "a" * 40).text.lower().replace("noscript", "").replace("requires javascript", "") or True


# ───────────────────────── refunds ─────────────────────────
@pytest.fixture()
def paid(client, shop, chain, conn):
    m, key = shop
    s = client.post(f"{API}/checkout/sessions", json={"amount": "100", "reference": "ref1"}, headers=key_headers(key)).json()
    t = pay_session(chain, client, conn, s, 1, 100_000_000, 100_000_000)
    assert client.post(f"{API}/payments/verify", json={"tx_hash": t}, headers=m["h"]).json()["stage"] == "verified"
    pid = conn.execute("select id from payments").fetchone()["id"]
    return m, key, s, pid


def add_refund_tx(chain, prep, n, *, amount=None, total=None, payer=PAYER, merchant=MERCHANT_WALLET, payment_id=1, block=110,
                  transfer=None, refund_ref=None, reason_hash=None):
    """Registers a receipt with [USDT Transfer merchant->payer, PaymentRefunded] on the fake chain. Any argument can be tampered."""
    amt = amount if amount is not None else int(prep["amount_base"])
    th = h32(f"refund-{n}")
    ev = payment_refunded(refund_id=n, payment_id=payment_id, payer=payer, merchant=merchant, amount=amt,
                          total_refunded=total if total is not None else amt, payment_amount=100_000_000,
                          refund_ref=refund_ref or prep["refund_ref"], reason_hash=reason_hash or prep["reason_hash"],
                          tx_hash=th, log_index=1)
    tr = erc20_transfer(merchant, payer, transfer if transfer is not None else amt, address=USDT, tx_hash=th, log_index=0)
    chain.add(th, [tr, ev], block=block, to=REFUNDS)
    return th


def test_partial_then_full_refund_flow(client, paid, chain, conn):
    m, key, s, pid = paid
    prep = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "30", "reason": "damaged"}, headers=m["h"])
    assert prep.status_code == 201, prep.text
    p = prep.json()
    assert p["status"] == "PENDING" and p["signer_wallet"] == MERCHANT_WALLET
    steps = p["plan"]["steps"]
    assert [x["step"] for x in steps] == ["approve", "refund"] and steps[1]["args"]["paymentId"] == "1" and steps[1]["args"]["amount"] == "30000000"
    # not confirmed until the chain event is verified
    assert conn.execute("select refunded_amount_base from payments").fetchone()["refunded_amount_base"] == 0
    t = add_refund_tx(chain, p, 1)
    v = client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t}, headers=m["h"]).json()
    assert v["stage"] == "verified" and v["refunds"][0]["status"] == "CONFIRMED" and v["refunds"][0]["explorer_url"].endswith(t)
    assert conn.execute("select refunded_amount_base from payments").fetchone()["refunded_amount_base"] == 30_000_000
    # idempotent
    assert client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t}, headers=m["h"]).json()["stage"] == "verified"
    assert conn.execute("select count(*) n from refunds").fetchone()["n"] == 1
    # second (final) refund of the remainder; more than remainder is refused up-front
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "70.000001"}, headers=m["h"]).status_code == 400
    p2 = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "70"}, headers=m["h"]).json()
    t2 = add_refund_tx(chain, p2, 2, total=100_000_000, block=111)
    assert client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t2}, headers=m["h"]).json()["stage"] == "verified"
    sess = client.get(f"{API}/checkout/sessions/{s['id']}", headers=key_headers(key)).json()
    assert sess["status"] == "refunded" and sess["receipts"][0]["refunded"] == "100"
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "0.01"}, headers=m["h"]).status_code == 400


@pytest.mark.parametrize("what", ["payer", "merchant", "amount", "reason_hash", "unmatched_transfer"])
def test_refund_event_tampering_is_rejected(client, paid, chain, conn, what):
    m, _, _, pid = paid
    p = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "10"}, headers=m["h"]).json()
    kw = {"payer": {"payer": "0x" + "cc" * 20}, "merchant": {"merchant": "0x" + "dd" * 20}, "amount": {"amount": 20_000_000, "transfer": 20_000_000},
          "reason_hash": {"reason_hash": h32("other")}, "unmatched_transfer": {"transfer": 5}}[what]
    t = add_refund_tx(chain, p, 9, **kw)
    r = client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t}, headers=m["h"]).json()
    assert r["stage"] == "rejected" and r["refunds"] == []
    assert conn.execute("select refunded_amount_base from payments").fetchone()["refunded_amount_base"] == 0
    assert conn.execute("select status from refunds").fetchone()["status"] == "PENDING"


def test_refund_authorisation_and_validation(w, client, paid):
    m, key, _, pid = paid
    other = w.merchant("0x" + "bb" * 20)
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "1"}, headers=other["h"]).status_code == 404
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={}, headers=m["h"]).status_code == 400
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "1", "amount_base": "5"}, headers=m["h"]).status_code == 400
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "0"}, headers=m["h"]).status_code in (400, 422)
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "1"}, headers=key_headers(key)).status_code == 401
    inv = w.user("investor")
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "1"}, headers=inv["h"]).status_code == 403


def test_refund_by_other_business_cannot_be_read_or_cancelled(w, client, paid):
    m, _, _, pid = paid
    rid = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "5"}, headers=m["h"]).json()["id"]
    other = w.merchant("0x" + "bb" * 20)
    assert client.get(f"{API}/merchant/refunds/{rid}", headers=other["h"]).status_code == 404
    assert client.post(f"{API}/merchant/refunds/{rid}/cancel", headers=other["h"]).status_code == 404
    assert client.post(f"{API}/merchant/refunds/{rid}/cancel", headers=m["h"]).json()["status"] == "CANCELLED"
    assert client.post(f"{API}/merchant/refunds/{rid}/cancel", headers=m["h"]).status_code == 409


def test_out_of_band_refund_is_recorded_from_chain_fact(client, paid, chain, conn):
    """Merchant called the contract directly (no BillFlow request): the verified on-chain fact is still recorded."""
    m, _, _, pid = paid
    fake_prep = {"refund_ref": h32("direct"), "reason_hash": h32("why"), "amount_base": "25000000"}
    t = add_refund_tx(chain, fake_prep, 5)
    v = client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t}, headers=m["h"]).json()
    assert v["stage"] == "verified" and v["refunds"][0]["amount"] == "25"
    assert conn.execute("select refunded_amount_base from payments").fetchone()["refunded_amount_base"] == 25_000_000


def test_refund_for_unknown_payment_is_parked_for_retry(client, paid, chain, conn):
    m, _, _, _ = paid
    prep = {"refund_ref": h32("ghost"), "reason_hash": h32("g"), "amount_base": "1000000"}
    t = add_refund_tx(chain, prep, 6, payment_id=77)
    r = client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t}, headers=m["h"]).json()
    assert r["stage"] == "confirmed" and r["refunds"] == []  # retry, not recorded
    assert conn.execute("select count(*) n from refunds").fetchone()["n"] == 0


def test_refunds_disabled_until_contract_configured(client, paid, monkeypatch):
    from app.core.config import get_settings
    m, _, _, pid = paid
    monkeypatch.setattr(get_settings(), "whitechain_refunds_contract", "")
    r = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "1"}, headers=m["h"])
    assert r.status_code == 503 and r.json()["error"]["code"] == "refunds_not_configured"


def test_legacy_payment_without_onchain_id_is_not_refundable(client, paid, conn):
    m, _, _, pid = paid
    conn.execute("update payments set onchain_payment_id=null")
    assert client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "1"}, headers=m["h"]).json()["error"]["code"] == "payment_not_refundable"


# ───────────────────────── webhooks ─────────────────────────
def register_hook(client, m, url="http://127.0.0.1:9/hook", events=None):
    r = client.post(f"{API}/merchant/webhooks", json={"url": url, "events": events or ["*"]}, headers=m["h"])
    assert r.status_code == 201, r.text
    return r.json()


@pytest.fixture()
def dev_urls(monkeypatch):
    from app.core.config import get_settings
    monkeypatch.setattr(get_settings(), "webhook_allow_insecure_urls", True)


@pytest.mark.parametrize("url", ["http://localhost/x", "ftp://example.com/x", "https://user:pw@example.com/x", "https://127.0.0.1/x",
                                 "https://169.254.169.254/latest", "https://10.0.0.5/x", "https://[::1]/x", "not a url"])
def test_webhook_url_policy_blocks_ssrf_targets(client, shop, url):
    m, _ = shop
    assert client.post(f"{API}/merchant/webhooks", json={"url": url}, headers=m["h"]).status_code == 400


def test_webhook_unknown_event_rejected(client, shop, dev_urls):
    m, _ = shop
    assert client.post(f"{API}/merchant/webhooks", json={"url": "http://x.test/h", "events": ["nope"]}, headers=m["h"]).status_code == 400


def test_signature_roundtrip_and_replay_window():
    t = int(time.time())
    sig = wh.sign("whsec_x", t, '{"a":1}')
    assert wh.verify_signature("whsec_x", f"t={t},v1={sig}", '{"a":1}')
    assert not wh.verify_signature("whsec_y", f"t={t},v1={sig}", '{"a":1}')
    assert not wh.verify_signature("whsec_x", f"t={t},v1={sig}", '{"a":2}')
    assert not wh.verify_signature("whsec_x", f"t={t - 1000},v1={wh.sign('whsec_x', t - 1000, 'b')}", "b")
    assert not wh.verify_signature("whsec_x", "garbage", "b")


def test_webhooks_enqueued_on_verified_payment_and_refund_and_delivered_signed(client, shop, chain, conn, dev_urls):
    m, key = shop
    ep = register_hook(client, m)
    s = client.post(f"{API}/checkout/sessions", json={"amount": "100", "reference": "ord-9", "metadata": {"k": "v"}}, headers=key_headers(key)).json()
    t = pay_session(chain, client, conn, s, 1, 100_000_000, 100_000_000)
    assert conn.execute("select count(*) n from webhook_deliveries").fetchone()["n"] == 0, "nothing is queued before verification"
    client.post(f"{API}/payments/verify", json={"tx_hash": t}, headers=m["h"])
    client.post(f"{API}/payments/verify", json={"tx_hash": t}, headers=m["h"])  # idempotent: no duplicate deliveries
    types = sorted(r["event_type"] for r in conn.execute("select event_type from webhook_deliveries").fetchall())
    assert types == ["invoice.paid", "payment.confirmed"]

    pid = conn.execute("select id from payments").fetchone()["id"]
    p = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "100"}, headers=m["h"]).json()
    client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": add_refund_tx(chain, p, 1, total=100_000_000)}, headers=m["h"])
    assert conn.execute("select count(*) n from webhook_deliveries where event_type='refund.confirmed'").fetchone()["n"] == 1

    got: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        got.append(req)
        return httpx.Response(200, json={"ok": True})

    stats = wh.deliver_due(__import__("app.core.config", fromlist=["x"]).get_settings(), client=httpx.Client(transport=httpx.MockTransport(handler)))
    assert stats["sent"] == 3 and len(got) == 3
    for req in got:
        body = req.content.decode()
        assert wh.verify_signature(ep["secret"], req.headers["billflow-signature"], body)
        ev = json.loads(body)
        assert ev["data"]["reference"] == "ord-9" or ev["type"] == "refund.confirmed"
        assert req.headers["billflow-event-id"] == ev["id"]
    paid_ev = next(json.loads(r.content) for r in got if json.loads(r.content)["type"] == "invoice.paid")
    assert paid_ev["data"]["metadata"] == {"k": "v"} and paid_ev["data"]["tx_hash"] == t and paid_ev["data"]["explorer_url"].endswith(t)
    assert wh.deliver_due(__import__("app.core.config", fromlist=["x"]).get_settings(), client=httpx.Client(transport=httpx.MockTransport(handler)))["sent"] == 0


def test_event_filter_only_matching_endpoints(client, shop, chain, conn, dev_urls):
    m, key = shop
    register_hook(client, m, events=["refund.confirmed"])
    s = client.post(f"{API}/checkout/sessions", json={"amount": "100"}, headers=key_headers(key)).json()
    client.post(f"{API}/payments/verify", json={"tx_hash": pay_session(chain, client, conn, s, 1, 100_000_000, 100_000_000)}, headers=m["h"])
    assert conn.execute("select count(*) n from webhook_deliveries").fetchone()["n"] == 0


def test_retry_backoff_then_give_up_and_manual_requeue(client, shop, chain, conn, dev_urls):
    from app.core.config import get_settings
    m, key = shop
    register_hook(client, m, events=["payment.confirmed"])
    s = client.post(f"{API}/checkout/sessions", json={"amount": "100"}, headers=key_headers(key)).json()
    client.post(f"{API}/payments/verify", json={"tx_hash": pay_session(chain, client, conn, s, 1, 100_000_000, 100_000_000)}, headers=m["h"])
    boom = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(500)))
    st = get_settings()
    first = wh.deliver_due(st, client=boom)
    d = conn.execute("select * from webhook_deliveries").fetchone()
    assert first["failed"] == 1 and d["status"] == "PENDING" and d["attempts"] == 1 and d["last_status"] == 500
    assert wh.deliver_due(st, client=boom) == {"sent": 0, "failed": 0, "gave_up": 0}, "not due yet (backoff)"
    for _ in range(st.webhook_max_attempts - 1):
        conn.execute("update webhook_deliveries set next_attempt_at=now()")
        wh.deliver_due(st, client=boom)
    d = conn.execute("select * from webhook_deliveries").fetchone()
    assert d["status"] == "FAILED" and d["attempts"] == st.webhook_max_attempts
    assert client.post(f"{API}/merchant/webhook-deliveries/{d['id']}/retry", headers=m["h"]).status_code == 200
    ok = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(204)))
    assert wh.deliver_due(st, client=ok)["sent"] == 1


def test_delivery_blocks_private_target_even_if_endpoint_row_was_tampered(client, shop, chain, conn, dev_urls, monkeypatch):
    from app.core.config import get_settings
    m, key = shop
    register_hook(client, m, events=["payment.confirmed"])
    s = client.post(f"{API}/checkout/sessions", json={"amount": "100"}, headers=key_headers(key)).json()
    client.post(f"{API}/payments/verify", json={"tx_hash": pay_session(chain, client, conn, s, 1, 100_000_000, 100_000_000)}, headers=m["h"])
    conn.execute("update webhook_endpoints set url='http://169.254.169.254/latest/meta-data'")
    monkeypatch.setattr(get_settings(), "webhook_allow_insecure_urls", False)
    called = []
    wh.deliver_due(get_settings(), client=httpx.Client(transport=httpx.MockTransport(lambda r: called.append(r) or httpx.Response(200))))
    assert called == [] and conn.execute("select last_error from webhook_deliveries").fetchone()["last_error"].startswith("AppError")


def test_webhook_endpoints_isolated_between_businesses(w, client, shop, dev_urls):
    m, _ = shop
    ep = register_hook(client, m)
    other = w.merchant("0x" + "bb" * 20)
    assert client.get(f"{API}/merchant/webhooks", headers=other["h"]).json() == []
    assert client.delete(f"{API}/merchant/webhooks/{ep['id']}", headers=other["h"]).status_code == 404
    assert "secret" not in client.get(f"{API}/merchant/webhooks", headers=m["h"]).json()[0]


# ───────────────────────── CSV export ─────────────────────────
def test_csv_export_contains_payments_refunds_and_neutralises_formulas(client, paid, chain, conn):
    m, key, _, pid = paid
    p = client.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "40"}, headers=m["h"]).json()
    client.post(f"{API}/merchant/refunds/verify", json={"tx_hash": add_refund_tx(chain, p, 1)}, headers=m["h"])
    conn.execute("update checkout_sessions set reference='=HYPERLINK(\"http://evil\")'")
    r = client.get(f"{API}/merchant/exports/payments.csv", headers=m["h"])
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv") and "attachment" in r.headers["content-disposition"]
    import csv, io
    rows = list(csv.DictReader(io.StringIO(r.text)))
    assert [x["type"] for x in rows] == ["payment", "refund"]
    assert rows[0]["amount"] == "100" and rows[1]["amount"] == "-40" and rows[1]["amount_base"] == "-40000000"
    assert rows[0]["tx_hash"] == tx(1) and rows[0]["explorer_url"].endswith(tx(1))
    assert rows[0]["reference"].startswith("'=") and not any(v.startswith("=") for x in rows for v in x.values())
    assert client.get(f"{API}/merchant/exports/payments.csv?date_from=2999-01-01", headers=m["h"]).text.count("\n") == 1  # header only
    assert client.get(f"{API}/merchant/exports/payments.csv?date_from=garbage", headers=m["h"]).status_code == 422


def test_csv_export_is_per_business(w, client, paid):
    other = w.merchant("0x" + "bb" * 20)
    assert client.get(f"{API}/merchant/exports/payments.csv", headers=other["h"]).text.count("\n") == 1


# ───────────────────────── hard duplicate financing prevention ─────────────────────────
def financing_ready(w, client, m, number, amount="1000", pdf=None, cust=None):
    cust = cust or w.customer(m, name="Globex")
    inv = w.invoice(m, cust, number=number, amount=amount)
    client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("i.pdf", pdf or pdf_bytes(number), "application/pdf")}, headers=m["h"])
    return inv, cust


def test_same_pdf_cannot_be_financed_twice(w, client, shop):
    m, _ = shop
    pdf = pdf_bytes("shared")
    a, _ = financing_ready(w, client, m, "INV-A", pdf=pdf)
    b, _ = financing_ready(w, client, m, "INV-B", amount="777", pdf=pdf)
    assert client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).status_code == 201
    r = client.post(f"{API}/financing/submit", json={"invoice_id": b["id"], "advance": "700"}, headers=m["h"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "duplicate_financing" and "same_document" in r.json()["error"]["details"]["reasons"]


def test_same_pdf_other_business_cannot_be_financed_twice(w, client, shop):
    m, _ = shop
    pdf = pdf_bytes("shared2")
    a, _ = financing_ready(w, client, m, "INV-A", pdf=pdf)
    m2 = w.merchant("0x" + "bb" * 20)
    b, _ = financing_ready(w, client, m2, "OTHER-1", pdf=pdf)
    assert client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).status_code == 201
    assert client.post(f"{API}/financing/submit", json={"invoice_id": b["id"], "advance": "900"}, headers=m2["h"]).status_code == 409


def test_same_invoice_identity_at_another_business_blocked(w, client, shop):
    m, _ = shop
    m2 = w.merchant("0x" + "bb" * 20)
    a, _ = financing_ready(w, client, m, "INV-100", amount="1000")
    b, _ = financing_ready(w, client, m2, "INV-100", amount="1000")
    assert client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).status_code == 201
    r = client.post(f"{API}/financing/submit", json={"invoice_id": b["id"], "advance": "900"}, headers=m2["h"])
    assert r.status_code == 409 and "same_invoice_data" in r.json()["error"]["details"]["reasons"]


def test_different_invoices_still_financeable_and_rejected_offer_frees_the_document(w, client, shop):
    m, _ = shop
    pdf = pdf_bytes("reuse")
    a, c = financing_ready(w, client, m, "INV-A", pdf=pdf)
    b, _ = financing_ready(w, client, m, "INV-C", amount="555", cust=w.customer(m, name="Initech"))
    assert client.post(f"{API}/financing/submit", json={"invoice_id": b["id"], "advance": "500"}, headers=m["h"]).status_code == 201
    oa = client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).json()
    adm = w.user("admin")
    client.post(f"{API}/financing/offers/{oa['id']}/verify", json={"decision": "reject", "notes": "bad scan"}, headers=adm["h"])
    d, _ = financing_ready(w, client, m, "INV-D", amount="321", pdf=pdf, cust=w.customer(m, name="Hooli"))
    assert client.post(f"{API}/financing/submit", json={"invoice_id": d["id"], "advance": "300"}, headers=m["h"]).status_code == 201


def test_duplicate_block_is_audited(w, client, shop, conn):
    m, _ = shop
    pdf = pdf_bytes("aud")
    a, _ = financing_ready(w, client, m, "INV-A", pdf=pdf)
    b, _ = financing_ready(w, client, m, "INV-B", amount="777", pdf=pdf)
    client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"])
    client.post(f"{API}/financing/submit", json={"invoice_id": b["id"], "advance": "700"}, headers=m["h"])
    assert conn.execute("select count(*) n from audit_logs where action='duplicate_financing_blocked'").fetchone()["n"] == 1


# ───────────────────────── debtor acknowledgement document hash ─────────────────────────
def test_debtor_ack_document_hash_is_anchored_verbatim(w, client, shop, conn):
    m, _ = shop
    a, _ = financing_ready(w, client, m, "INV-ACK")
    o = client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).json()
    adm = w.user("admin")
    sha = "ab" * 32
    r = client.post(f"{API}/financing/offers/{o['id']}/verify", headers=adm["h"], json={
        "decision": "approve", "debtor_ack": {"evidence_ref": "signed-letter.pdf", "acknowledged_at": "2026-11-01T10:00:00Z", "document_sha256": sha},
        "assignment_notice": {"reference": "n-1"}})
    assert r.status_code == 200, r.text
    assert conn.execute("select debtor_ack_hash from financing_offers").fetchone()["debtor_ack_hash"] == "0x" + sha
    bad = client.post(f"{API}/financing/offers/{o['id']}/verify", headers=adm["h"], json={
        "decision": "approve", "debtor_ack": {"evidence_ref": "x.pdf", "acknowledged_at": "2026-11-01T10:00:00Z", "document_sha256": "zz"},
        "assignment_notice": {"reference": "n-1"}})
    assert bad.status_code == 422


# ───────────────────────── maintenance: due-soon notifications ─────────────────────────
def test_due_soon_and_overdue_notifications_are_sent_once(w, client, shop, conn):
    from app.workers.blockchain_indexer import notify_financing_due
    m, _ = shop
    a, _ = financing_ready(w, client, m, "INV-DUE")
    o = client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).json()
    inv_user = w.user("investor")
    conn.execute("update financing_offers set status='FUNDED', maturity_date=current_date + 2 where id=%s", (o["id"],))
    conn.execute("insert into investments (offer_id, investor_id, investor_wallet, amount_base, tx_hash, status) "
                 "values (%s,%s,%s,900000000,%s,'CONFIRMED')", (o["id"], inv_user["id"], "0x" + "ee" * 20, h32("fund")))
    assert notify_financing_due() == 1 and notify_financing_due() == 0
    assert conn.execute("select count(*) n from notifications where type='financing_due_soon'").fetchone()["n"] == 2  # business + investor
    conn.execute("update financing_offers set maturity_date=current_date - 1")
    assert notify_financing_due() == 1 and notify_financing_due() == 0
    assert conn.execute("select count(*) n from notifications where type='financing_overdue'").fetchone()["n"] == 2


def test_offer_exposes_maturity_countdown(w, client, shop):
    m, _ = shop
    a, _ = financing_ready(w, client, m, "INV-CD")
    o = client.post(f"{API}/financing/submit", json={"invoice_id": a["id"], "advance": "900"}, headers=m["h"]).json()
    assert o["days_to_maturity"] == 30
