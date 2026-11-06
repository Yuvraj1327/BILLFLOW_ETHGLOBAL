import json
from pathlib import Path

from eth_account import Account

from tests.helpers import FINANCING, PAYMENTS, SIGNER_KEY, USDT, erc20_transfer, h32, invoice_paid, REFUNDS

API = "/api/v1"
ROOT = Path(__file__).resolve().parents[2]


def test_shipped_abis_match_step2_artifacts():
    for n in ("BillFlowPayments", "InvoiceFinancing", "BillFlowRefunds"):
        shipped = json.loads((ROOT / "backend/app/abi" / f"{n}.json").read_text())
        step2 = json.loads((ROOT / "docs/abi" / f"{n}.json").read_text())
        assert shipped == step2, f"{n}: backend ABI drifted from the Step 2 ABI"


def test_decoder_knows_every_contract_event():
    from app.core.config import get_settings
    from app.services.blockchain_service import EventDecoder, load_abi
    d = EventDecoder(get_settings())
    for kind, name in (("payments", "BillFlowPayments"), ("financing", "InvoiceFinancing"), ("refunds", "BillFlowRefunds")):
        want = {e["name"] for e in load_abi(name) if e["type"] == "event"}
        assert want == {e["name"] for e in d.events[kind].values()}


def test_error_envelope(w, client):
    m = w.merchant()
    r = client.get(f"{API}/invoices/not-a-uuid", headers=m["h"])
    assert r.status_code == 422 and set(r.json()["error"]) == {"code", "message", "details"} and r.json()["error"]["code"] == "validation_error"
    r = client.get(f"{API}/nope")
    assert r.status_code == 404 and r.json()["error"]["code"]


def test_unhandled_exception_hides_details(w, client, monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import create_app
    import app.services.invoice_service as svc
    monkeypatch.setattr(svc, "list_", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("secret-internal-detail postgres://user:pw@host")))
    m = w.merchant()
    with TestClient(create_app(), raise_server_exceptions=False) as tc:
        r = tc.get(f"{API}/invoices", headers=m["h"])
    assert r.status_code == 500 and "secret-internal-detail" not in r.text and "pw@host" not in r.text


def test_sql_injection_and_sort_whitelist(w, client):
    m = w.merchant(); c = w.customer(m); w.invoice(m, c)
    r = client.get(f"{API}/invoices", params={"q": "'; drop table invoices; --"}, headers=m["h"])
    assert r.status_code == 200 and r.json()["total"] == 0
    assert client.get(f"{API}/invoices", params={"sort": "amount_base; drop table invoices"}, headers=m["h"]).status_code == 422
    assert client.get(f"{API}/invoices", headers=m["h"]).json()["total"] == 1


def test_customers_crud_and_archive(w, client):
    m = w.merchant()
    c = w.customer(m, "Initech")
    assert client.patch(f"{API}/customers/{c['id']}", json={"name": "Initech 2"}, headers=m["h"]).json()["name"] == "Initech 2"
    assert client.patch(f"{API}/customers/{c['id']}", json={"wallet_address": "bad"}, headers=m["h"]).status_code == 400
    inv = w.invoice(m, c)
    assert client.delete(f"{API}/customers/{c['id']}", headers=m["h"]).status_code == 204
    assert client.get(f"{API}/customers", headers=m["h"]).json()["total"] == 0
    assert client.get(f"{API}/customers?include_archived=true", headers=m["h"]).json()["total"] == 1
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["customer_name"] == "Initech 2"  # history intact
    r = client.post(f"{API}/invoices", json={"customer_id": c["id"], "invoice_number": "N2", "amount": "1", "due_date": "2099-01-01"}, headers=m["h"])
    assert r.status_code == 404  # archived customers cannot get new invoices


def test_notifications_flow(w, client, chain):
    m = w.merchant("0x" + "aa" * 20); c = w.customer(m); inv = w.invoice(m, c)
    t = h32("n1")
    chain.add(t, [erc20_transfer("0x" + "99" * 20, "0x" + "aa" * 20, 100_000_000, tx_hash=t, log_index=0),
                  invoice_paid(inv, "0x" + "99" * 20, "0x" + "aa" * 20, 100_000_000, 100_000_000, tx_hash=t, log_index=1)])
    client.post(f"{API}/payments/verify", json={"tx_hash": t}, headers=m["h"])
    n = client.get(f"{API}/notifications?unread_only=true", headers=m["h"]).json()
    assert n["total"] == 1 and n["items"][0]["type"] == "invoice_payment_received"
    nid = n["items"][0]["id"]
    other = w.merchant("0x" + "bb" * 20)
    assert client.post(f"{API}/notifications/{nid}/read", headers=other["h"]).status_code == 404  # not theirs
    assert client.post(f"{API}/notifications/{nid}/read", headers=m["h"]).status_code == 200
    assert client.get(f"{API}/notifications?unread_only=true", headers=m["h"]).json()["total"] == 0


def test_admin_endpoints(w, client, chain, conn):
    adm = w.user("admin"); m = w.merchant(verified=False); h = adm["h"]
    biz = m["business"]["id"]
    assert client.get(f"{API}/admin/businesses?status=unverified", headers=h).json()["total"] == 1
    r = client.post(f"{API}/admin/businesses/{biz}/review", json={"decision": "verify"}, headers=h)
    assert r.json()["verification_status"] == "verified"
    target = w.user("customer")
    assert client.patch(f"{API}/admin/users/{target['id']}/role", json={"role": "investor"}, headers=h).json()["role"] == "investor"
    assert client.patch(f"{API}/admin/users/{target['id']}/role", json={"role": "root"}, headers=h).status_code == 422
    w.c.execute("insert into investor_profiles (user_id, full_name, country, investor_type, accepted_terms_at, accepted_risk_at) "
                "values (%s,'T I','UK','individual',now(),now())", (target["id"],))
    assert client.patch(f"{API}/admin/users/{target['id']}/investor-verification", json={"decision": "verify"}, headers=h).json()["investor_verification"] == "verified"
    assert client.get(f"{API}/admin/users?role=investor", headers=h).json()["total"] == 1
    assert client.put(f"{API}/admin/settings/max_discount_bps", json={"value": 99999}, headers=h).status_code == 400
    assert any(s["key"] == "max_discount_bps" for s in client.get(f"{API}/admin/settings", headers=h).json())
    acts = {a["action"] for a in client.get(f"{API}/admin/audit-logs?page_size=100", headers=h).json()["items"]}
    assert {"business_verified", "role_changed", "investor_verified"} <= acts
    for p in ("transactions", "events", "indexer"):
        assert client.get(f"{API}/admin/{p}", headers=h).status_code == 200
        assert client.get(f"{API}/admin/{p}", headers=m["h"]).status_code == 403
    i = w.invoice(m, w.customer(m))
    assert client.post(f"{API}/admin/invoices/{i['id']}/review", json={"decision": "reject", "notes": "suspicious"}, headers=h).json()["review_status"] == "rejected"
    assert client.get(f"{API}/invoices/{i['id']}", headers=m["h"]).json()["status"] == "PENDING"  # review never changes payment status


def test_business_without_payout_wallet_cannot_be_verified(w, client):
    adm = w.user("admin"); m = w.user("merchant")
    b = client.post(f"{API}/businesses", json={"legal_name": "NoWallet"}, headers=m["h"]).json()
    r = client.post(f"{API}/admin/businesses/{b['id']}/review", json={"decision": "verify"}, headers=adm["h"])
    assert r.status_code == 400 and r.json()["error"]["code"] == "no_payout_wallet"


# ───────────── blockchain config / preflight ─────────────
def test_config_has_no_secrets(w, client):
    u = w.user("customer")
    r = client.get(f"{API}/blockchain/config", headers=u["h"])
    body = r.json()
    assert body["chain_id"] == 1874 and body["usdt_decimals"] == 6 and body["configured"] is True
    assert body["quote_signer"] == Account.from_key(SIGNER_KEY).address.lower()
    assert SIGNER_KEY[2:] not in r.text and "service-test" not in r.text and "test-jwt-secret" not in r.text


def _healthy(chain):
    sg = Account.from_key(SIGNER_KEY).address
    for a in (USDT, PAYMENTS, FINANCING, REFUNDS):
        chain.code[a] = b"\x60\x80"
    chain.calls.update({(USDT, "decimals"): 6, (PAYMENTS, "PAYMENT_TOKEN"): USDT, (PAYMENTS, "quoteSigner"): sg,
                        (FINANCING, "PAYMENT_TOKEN"): USDT, (FINANCING, "invoiceCount"): 0,
                        (REFUNDS, "PAYMENT_TOKEN"): USDT, (REFUNDS, "PAYMENTS"): PAYMENTS})


def test_preflight_detects_refunds_contract_pointing_at_wrong_payments(w, client, chain):
    adm = w.user("admin")
    _healthy(chain)
    chain.calls[(REFUNDS, "PAYMENTS")] = "0x" + "77" * 20
    body = client.get(f"{API}/blockchain/health", headers=adm["h"]).json()
    assert body["ok"] is False and body["checks"]["refunds_points_at_payments"]["ok"] is False


def test_preflight_ok_and_each_mismatch_detected(w, client, chain):
    adm = w.user("admin")
    _healthy(chain)
    r = client.get(f"{API}/blockchain/health", headers=adm["h"]).json()
    assert r["ok"] is True, r
    chain.calls[(USDT, "decimals")] = 18
    assert client.get(f"{API}/blockchain/health", headers=adm["h"]).json()["checks"]["usdt_decimals"]["ok"] is False
    chain.calls[(USDT, "decimals")] = 6
    chain.calls[(PAYMENTS, "PAYMENT_TOKEN")] = "0x" + "44" * 20
    assert client.get(f"{API}/blockchain/health", headers=adm["h"]).json()["checks"]["payments_token_matches"]["ok"] is False
    chain.calls[(PAYMENTS, "PAYMENT_TOKEN")] = USDT
    chain.calls[(PAYMENTS, "quoteSigner")] = "0x" + "12" * 20
    assert client.get(f"{API}/blockchain/health", headers=adm["h"]).json()["checks"]["quote_signer_matches"]["ok"] is False
    chain.code[PAYMENTS] = b""  # nothing deployed there
    assert client.get(f"{API}/blockchain/health", headers=adm["h"]).json()["checks"]["payments_has_code"]["ok"] is False
    chain.cid = 2625
    assert client.get(f"{API}/blockchain/health", headers=adm["h"]).json()["checks"]["chain_id"]["ok"] is False
    assert client.get(f"{API}/blockchain/health", headers=w.user("merchant")["h"]).status_code == 403


def test_logging_redacts_secrets():
    import logging
    from app.core.logging import RedactFilter
    rec = logging.LogRecord("x", logging.INFO, "f", 1, "key=%s db=%s", ("0x" + "ab" * 32, "postgresql://u:pass@h/db"), None)
    RedactFilter().filter(rec)
    out = rec.getMessage()
    assert "ab" * 32 not in out and "pass@" not in out
    tx = "0x" + "cd" * 32  # public tx hashes stay readable
    rec2 = logging.LogRecord("x", logging.INFO, "f", 1, "tx %s jwt %s", (tx, "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3OCJ9.abcdefgh"), None)
    RedactFilter().filter(rec2)
    assert tx in rec2.getMessage() and "eyJhbGci" not in rec2.getMessage()


def test_no_private_key_material_in_source():
    import re
    pat = re.compile(r"0x[0-9a-fA-F]{64}")
    for p in (ROOT / "backend/app").rglob("*.py"):
        assert not pat.search(p.read_text()), f"64-hex literal in {p}"
    assert "ANTHROPIC_API_KEY=sk" not in (ROOT / "backend/.env.example").read_text()
