from datetime import date, timedelta

from tests.helpers import pdf_bytes

API = "/api/v1"


def test_create_get_list_update_delete(w, client):
    m = w.merchant()
    c = w.customer(m)
    inv = w.invoice(m, c, issue=False, amount="1000.50")
    assert inv["status"] == "DRAFT" and inv["amount_base"] == "1000500000" and inv["amount"] == "1000.5"
    assert inv["invoice_hash"].startswith("0x") and len(inv["onchain_invoice_id"]) == 66
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["invoice_number"] == "INV-1"
    lst = client.get(f"{API}/invoices?status=DRAFT&q=Glob", headers=m["h"]).json()
    assert lst["total"] == 1 and lst["items"][0]["customer_name"] == "Globex"
    up = client.patch(f"{API}/invoices/{inv['id']}", json={"amount": "2000"}, headers=m["h"]).json()
    assert up["amount_base"] == "2000000000" and up["invoice_hash"] != inv["invoice_hash"]  # hash tracks the data
    assert client.delete(f"{API}/invoices/{inv['id']}", headers=m["h"]).status_code == 204
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).status_code == 404


def test_issued_invoice_is_immutable_and_not_deletable(w, client):
    m = w.merchant(); c = w.customer(m)
    inv = w.invoice(m, c)
    assert inv["status"] == "PENDING"
    assert client.patch(f"{API}/invoices/{inv['id']}", json={"description": "x"}, headers=m["h"]).status_code == 409
    d = client.delete(f"{API}/invoices/{inv['id']}", headers=m["h"])
    assert d.status_code == 409 and d.json()["error"]["code"] == "invoice_not_deletable"
    cx = client.post(f"{API}/invoices/{inv['id']}/cancel", json={"reason": "mistake"}, headers=m["h"])
    assert cx.status_code == 200 and cx.json()["status"] == "CANCELLED"
    assert client.post(f"{API}/invoices/{inv['id']}/issue", headers=m["h"]).status_code == 409  # no resurrection


def test_validation_errors(w, client):
    m = w.merchant(); c = w.customer(m)
    base = {"customer_id": c["id"], "invoice_number": "X", "due_date": str(date.today() + timedelta(days=5))}
    assert client.post(f"{API}/invoices", json={**base}, headers=m["h"]).status_code == 422  # no amount
    assert client.post(f"{API}/invoices", json={**base, "amount": "0"}, headers=m["h"]).status_code == 400
    assert client.post(f"{API}/invoices", json={**base, "amount": "1.1234567"}, headers=m["h"]).status_code == 400  # > 6 decimals
    assert client.post(f"{API}/invoices", json={**base, "amount": "-5"}, headers=m["h"]).status_code == 400
    assert client.post(f"{API}/invoices", json={**base, "amount": "1e3"}, headers=m["h"]).status_code == 400
    assert client.post(f"{API}/invoices", json={**base, "amount": "5", "amount_base": "5"}, headers=m["h"]).status_code == 422
    past = {**base, "amount": "5", "issue_date": str(date.today()), "due_date": str(date.today() - timedelta(days=1))}
    assert client.post(f"{API}/invoices", json=past, headers=m["h"]).status_code == 400
    assert client.post(f"{API}/invoices", json={**base, "amount": "5", "status": "PAID"}, headers=m["h"]).status_code == 422  # cannot set status


def test_duplicate_number_conflict(w, client):
    m = w.merchant(); c = w.customer(m)
    w.invoice(m, c, number="DUP")
    r = client.post(f"{API}/invoices", json={"customer_id": c["id"], "invoice_number": "DUP", "amount": "1",
                                              "due_date": str(date.today() + timedelta(days=3))}, headers=m["h"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "duplicate_invoice_number"


def test_cross_business_isolation(w, client):
    a, b = w.merchant(), w.merchant("0x" + "bb" * 20)
    ca = w.customer(a); inv = w.invoice(a, ca)
    # B cannot read/modify/delete/cancel/upload/link/see status of A's invoice: always 404 (no existence oracle)
    for method, path, kw in [("get", "", {}), ("patch", "", {"json": {"description": "x"}}), ("delete", "", {}),
                             ("post", "/cancel", {}), ("post", "/issue", {}), ("post", "/payment-link", {}), ("get", "/payment-status", {})]:
        r = getattr(client, method)(f"{API}/invoices/{inv['id']}{path}", headers=b["h"], **kw)
        assert r.status_code == 404, (method, path, r.status_code)
    assert client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("a.pdf", pdf_bytes(), "application/pdf")}, headers=b["h"]).status_code == 404
    assert client.get(f"{API}/invoices", headers=b["h"]).json()["total"] == 0
    # B cannot create an invoice for A's customer
    r = client.post(f"{API}/invoices", json={"customer_id": ca["id"], "invoice_number": "Z", "amount": "1",
                                              "due_date": str(date.today() + timedelta(days=3))}, headers=b["h"])
    assert r.status_code == 404
    assert client.get(f"{API}/customers/{ca['id']}", headers=b["h"]).status_code == 404


def test_team_member_shares_business(w, client):
    owner = w.merchant(); c = w.customer(owner)
    staff = w.user("merchant")
    r = client.post(f"{API}/businesses/me/members", json={"email": staff["email"]}, headers=owner["h"])
    assert r.status_code == 201
    inv = w.invoice(owner, c)
    assert client.get(f"{API}/invoices/{inv['id']}", headers=staff["h"]).status_code == 200
    assert client.patch(f"{API}/businesses/me", json={"legal_name": "Hijack"}, headers=staff["h"]).status_code == 403  # owner only


def test_upload_pdf_valid_and_invalid(w, client, storage):
    m = w.merchant(); c = w.customer(m); inv = w.invoice(m, c)
    f = pdf_bytes("one")
    ok = client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("a.pdf", f, "application/pdf")}, headers=m["h"])
    assert ok.status_code == 201
    body = ok.json()
    assert body["document_hash"] == "0x" + body["sha256"] and len(storage.objects) == 1
    assert next(iter(storage.objects)).startswith(f"{m['business']['id']}/{inv['id']}/")  # business-scoped private path
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["document_hash"] == body["document_hash"]
    again = client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("a.pdf", f, "application/pdf")}, headers=m["h"])
    assert again.status_code == 409
    # same file on another invoice -> succeeds with a duplicate warning
    inv2 = w.invoice(m, c, number="INV-2")
    dup = client.post(f"{API}/invoices/{inv2['id']}/upload", files={"file": ("a.pdf", f, "application/pdf")}, headers=m["h"])
    assert dup.status_code == 201 and dup.json()["duplicate_warnings"]
    bad = [("x.pdf", b"", "application/pdf", 400), ("x.pdf", b"hello world", "application/pdf", 415),
           ("x.png", pdf_bytes(), "image/png", 415), ("x.pdf", b"%PDF-1.4 garbage not really", "application/pdf", 400)]
    for name, data, ctype, code in bad:
        r = client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": (name, data, ctype)}, headers=m["h"])
        assert r.status_code == code, (name, r.status_code, r.text)


def test_upload_too_large(w, client, monkeypatch):
    from app.core.config import get_settings
    m = w.merchant(); c = w.customer(m); inv = w.invoice(m, c)
    monkeypatch.setenv("MAX_UPLOAD_BYTES", "100"); get_settings.cache_clear()
    try:
        r = client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("a.pdf", pdf_bytes(), "application/pdf")}, headers=m["h"])
        assert r.status_code == 413
    finally:
        monkeypatch.delenv("MAX_UPLOAD_BYTES"); get_settings.cache_clear()


def test_payment_link_lifecycle_and_public_view(w, client):
    m = w.merchant(); c = w.customer(m); inv = w.invoice(m, c)
    l1 = client.post(f"{API}/invoices/{inv['id']}/payment-link", headers=m["h"]).json()
    assert l1["url"] == f"https://pay.test/pay/{l1['token']}" and len(l1["token"]) >= 32
    pub = client.get(f"{API}/public/invoices/{l1['token']}")  # no auth header
    assert pub.status_code == 200
    p = pub.json()
    assert p["merchant_name"] == "Acme Ltd" and p["payable"] is True and p["remaining_amount"] == "100"
    assert "tax_id" not in p and "customer_id" not in p and "business_id" not in p  # minimal public data
    l2 = client.post(f"{API}/invoices/{inv['id']}/payment-link", headers=m["h"]).json()
    assert client.get(f"{API}/public/invoices/{l1['token']}").status_code == 410  # old link revoked
    assert client.get(f"{API}/public/invoices/{l2['token']}").status_code == 200
    assert client.get(f"{API}/public/invoices/{'z' * 43}").status_code == 404
    assert client.get(f"{API}/public/invoices/short").status_code == 422


def test_draft_cannot_get_payment_link(w, client):
    m = w.merchant(); c = w.customer(m); inv = w.invoice(m, c, issue=False)
    r = client.post(f"{API}/invoices/{inv['id']}/payment-link", headers=m["h"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "invoice_not_payable"


def test_payout_wallet_locked_while_invoices_open(w, client):
    m = w.merchant(); c = w.customer(m); w.invoice(m, c)
    r = client.patch(f"{API}/businesses/me", json={"payout_wallet": "0x" + "cc" * 20}, headers=m["h"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "open_invoices"


def test_public_rate_limit(w, client, monkeypatch):
    from app.core.config import get_settings
    monkeypatch.setenv("PUBLIC_RATE_LIMIT_PER_MINUTE", "3"); get_settings.cache_clear()
    try:
        codes = [client.get(f"{API}/public/invoices/{'q' * 43}").status_code for _ in range(5)]
        assert codes[:3] == [404, 404, 404] and codes[3:] == [429, 429]
    finally:
        monkeypatch.delenv("PUBLIC_RATE_LIMIT_PER_MINUTE"); get_settings.cache_clear()


def test_usdt_decimals_must_be_configured(w, client, monkeypatch):
    from app.core.config import get_settings
    m = w.merchant(); c = w.customer(m)
    monkeypatch.delenv("USDT_DECIMALS"); get_settings.cache_clear()
    try:
        r = client.post(f"{API}/invoices", json={"customer_id": c["id"], "invoice_number": "Q", "amount": "1",
                                                  "due_date": str(date.today() + timedelta(days=3))}, headers=m["h"])
        assert r.status_code == 503 and r.json()["error"]["code"] == "usdt_decimals_not_configured"
    finally:
        monkeypatch.setenv("USDT_DECIMALS", "6"); get_settings.cache_clear()


def test_document_signed_url_scoped(w, client, storage):
    a, b = w.merchant(), w.merchant("0x" + "bb" * 20)
    inv = w.invoice(a, w.customer(a))
    d = client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("a.pdf", pdf_bytes(), "application/pdf")}, headers=a["h"]).json()
    assert client.get(f"{API}/invoices/{inv['id']}/documents", headers=a["h"]).json()[0]["id"] == d["id"]
    u = client.get(f"{API}/invoices/{inv['id']}/documents/{d['id']}/url", headers=a["h"])
    assert u.status_code == 200 and u.json()["url"].startswith("https://storage.test/") and "expires_at" in u.json()
    assert client.get(f"{API}/invoices/{inv['id']}/documents/{d['id']}/url", headers=b["h"]).status_code == 404
    assert client.get(f"{API}/invoices/{inv['id']}/documents", headers=b["h"]).status_code == 404
    adm = w.user("admin")
    assert client.get(f"{API}/admin/invoices/{inv['id']}/documents/{d['id']}/url", headers=adm["h"]).status_code == 200
    assert client.get(f"{API}/admin/invoices/{inv['id']}/documents/{d['id']}/url", headers=a["h"]).status_code == 403
    import uuid
    assert client.get(f"{API}/invoices/{inv['id']}/documents/{uuid.uuid4()}/url", headers=a["h"]).status_code == 404
